import AppKit
import ApplicationServices
import RemoteCore

extension CodexConversationCommand {
    var scrollsReply: Bool { self == .scrollUp || self == .scrollDown }

    var title: String {
        switch self {
        case .scrollUp: L10n.tr("向上滚动回复")
        case .scrollDown: L10n.tr("向下滚动回复")
        case .sendTranscript: L10n.tr("确认发送本次听写")
        case .discardConfirmation: L10n.tr("取消发送确认")
        }
    }
}

enum CodexDraftObservation: Equatable {
    case empty, starting, recording, transcribing, ready(String)
}

@MainActor
protocol CodexConversationSession: AnyObject {
    // Nil means the original composer or its state can no longer be verified.
    func observe() -> CodexDraftObservation?
    func send(_ transcript: String) -> Bool
}

@MainActor
final class CodexDraftConfirmation {
    enum Confirmation: Equatable { case unavailable, requested, unconfirmed }

    private enum Stage { case holding, recording, released, transcribing, ready(String) }
    private var stage: Stage?
    private var session: (any CodexConversationSession)?

    var active: Bool { session != nil }

    @discardableResult
    func begin(_ session: any CodexConversationSession) -> Bool {
        cancel()
        guard session.observe() == .empty else { return false }
        self.session = session
        stage = .holding
        return true
    }

    func sample() {
        guard let session, let stage, let state = session.observe() else { cancel(); return }
        switch (stage, state) {
        case (.holding, .empty), (.holding, .starting), (.recording, .recording),
             (.released, .recording), (.transcribing, .transcribing):
            break
        case (.holding, .recording): self.stage = .recording
        case (.released, .transcribing): self.stage = .transcribing
        case let (.transcribing, .ready(value)): self.stage = .ready(value)
        case let (.ready(previous), .ready(current)) where previous == current: break
        default: cancel()
        }
    }

    func release() {
        guard case .recording = stage else { cancel(); return }
        stage = .released
        sample()
    }

    func confirm() -> Confirmation {
        sample()
        guard let session, case let .ready(value) = stage else { return .unavailable }
        // Consume the confirmation before AXPress. A timeout does not prove that it failed.
        cancel()
        return session.send(value) ? .requested : .unconfirmed
    }

    func cancel() {
        session = nil
        stage = nil
    }
}

@MainActor
enum CodexConversationControl {
    struct Access {
        var session: @MainActor (ForegroundContext) -> (any CodexConversationSession)?
        // The returned operation is bound to the original transcript, even across repeated presses.
        var scroll: @MainActor (ForegroundContext, CodexConversationCommand) -> (() -> Bool)?

        static let system = Self(session: { AXSession(context: $0) }, scroll: { context, command in
            guard let surface = Surface(context), let transcript = surface.transcript() else { return nil }
            return { surface.scroll(transcript, up: command == .scrollUp) }
        })
    }

    private static let dictate = ["Dictate", "听写", "聽寫"]
    private static let starting = ["Starting dictation; click to cancel", "正在启动听写；点击可取消", "Preparing dictation"]
    private static let recording = ["Stop dictation", "停止听写", "停止聽寫"]
    private static let transcribing = ["Cancel transcription", "取消转录", "取消轉錄", "Finishing dictation", "正在完成听写", "正在完成聽寫"]
    private static let sendNames = ["Send", "Send message", "Send prompt", "发送", "发送消息", "傳送", "傳送訊息"]
    private static let transcriptNames = ["Conversation", "对话", "對話"]
    private static let approvalNames = [
        "Approve", "Approve once", "Allow", "Allow once", "Always allow", "Allow this conversation",
        "Allow similar commands", "Allow all edits", "Yes, proceed", "No, and tell Codex what to do differently",
        "Deny", "Decline",
        "批准", "允许", "允许一次", "始终允许", "允许此对话", "允许类似命令", "允许所有修改", "拒绝",
        "核准", "允許", "允許一次", "一律允許", "允許此對話", "拒絕"
    ]

    @MainActor
    private struct Node {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let names: [String]

        func named(_ values: [String]) -> Bool { names.contains { values.contains($0) } }
        var obstructsComposer: Bool {
            let blockers = ["AXDialog", "AXAlertDialog", "AXSystemDialog", "AXSheet", "AXMenu", "AXPopover"]
            return blockers.contains(role) || subrole.map(blockers.contains) == true
                || (role == kAXButtonRole || role == kAXRadioButtonRole) && named(approvalNames)
        }
    }

    private static func nodes(in root: AXUIElement, skipWebAreas: Bool = false) -> [Node]? {
        let deadline = ContinuousClock.now + .milliseconds(180)
        var stack = [root]
        var result: [Node] = []
        while let element = stack.popLast() {
            guard result.count < 1000, ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.06)
            guard let role = Accessibility.string(element, kAXRoleAttribute) else { return nil }
            let needsName = [kAXButtonRole, kAXRadioButtonRole, kAXGroupRole, kAXScrollAreaRole].contains(role)
            let names = needsName ? [kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
                Accessibility.string(element, $0)
            } : []
            let subrole = [kAXWindowRole, kAXGroupRole].contains(role)
                ? Accessibility.string(element, kAXSubroleAttribute) : nil
            result.append(Node(element: element, role: role, subrole: subrole, names: names))
            if [kAXStaticTextRole, kAXButtonRole, kAXRadioButtonRole, kAXTextFieldRole, kAXTextAreaRole,
                kAXImageRole].contains(role) || skipWebAreas && role == "AXWebArea" { continue }
            var children: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) {
            case .success:
                guard let children = children as? [AXUIElement] else { return nil }
                stack.append(contentsOf: children.reversed())
            case .noValue, .attributeUnsupported: break
            default: return nil
            }
        }
        return result
    }

    private static func unique(_ nodes: [Node], where matches: (Node) -> Bool) -> AXUIElement? {
        let matches = nodes.filter(matches)
        return matches.count == 1 ? matches[0].element : nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        func geometry(_ attribute: String) -> AXValue? {
            guard let value = Accessibility.value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID()
            else { return nil }
            return (value as! AXValue)
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard let position = geometry(kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &point),
              let dimensions = geometry(kAXSizeAttribute), AXValueGetValue(dimensions, .cgSize, &size),
              [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    @MainActor
    private struct Surface {
        let context: ForegroundContext
        let app: AXUIElement
        let window: AXUIElement
        let webArea: AXUIElement
        let route: URL

        init?(_ context: ForegroundContext) {
            guard AXIsProcessTrusted(), context.bundleID == AppTarget.chatGPT.bundleID,
                  let window = context.window, context.matches(.current()),
                  let tree = nodes(in: window, skipWebAreas: true),
                  let area = unique(tree, where: { $0.role == "AXWebArea" && CodexDictationSession.codexRoute($0.element) != nil }),
                  let route = CodexDictationSession.codexRoute(area) else { return nil }
            self.context = context
            self.window = window
            webArea = area
            self.route = route
            app = AXUIElementCreateApplication(context.pid)
            AXUIElementSetMessagingTimeout(app, 0.06)
        }

        func isCurrent() -> Bool {
            context.matches(.current()) && CodexDictationSession.codexRoute(webArea) == route
        }

        func unobstructed() -> Bool {
            guard isCurrent(), let shell = nodes(in: window, skipWebAreas: true),
                  let current = unique(shell, where: {
                      $0.role == "AXWebArea" && CodexDictationSession.codexRoute($0.element) != nil
                  }), CFEqual(current, webArea) else { return false }
            return !shell.contains(where: \.obstructsComposer)
                && (Accessibility.value(window, kAXModalAttribute) as? Bool) != true
        }

        func transcript() -> AXUIElement? {
            guard unobstructed(), let tree = nodes(in: webArea), !tree.contains(where: \.obstructsComposer) else { return nil }
            return unique(tree) {
                [kAXGroupRole, kAXScrollAreaRole].contains($0.role) && $0.named(transcriptNames)
            }
        }

        func scroll(_ transcript: AXUIElement, up: Bool) -> Bool {
            guard unobstructed(), CGPreflightPostEventAccess(),
                  let rect = frame(transcript), let windowRect = frame(window) else { return false }
            let visible = rect.intersection(windowRect)
            guard visible.width >= 30, visible.height >= 30 else { return false }
            // Hit-test the actual visible transcript. Never scroll an overlapping pane or the composer.
            let point = CGPoint(x: visible.midX, y: visible.minY + visible.height / 3)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
                  let hit, Self.belongs(hit, to: transcript),
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: Int32(min(visible.height / 3, 1000)) * (up ? 1 : -1), wheel2: 0, wheel3: 0),
                  isCurrent() else { return false }
            event.location = point
            AgentRunner.postRemoteEvent(event, pid: context.pid)
            return true
        }

        private static func belongs(_ hit: AXUIElement, to transcript: AXUIElement) -> Bool {
            var current: AXUIElement? = hit
            for _ in 0..<32 {
                guard let node = current else { return false }
                if CFEqual(node, transcript) { return true }
                if let role = Accessibility.string(node, kAXRoleAttribute),
                   [kAXTextAreaRole, kAXTextFieldRole, kAXButtonRole, kAXScrollAreaRole, "AXWebArea"].contains(role) {
                    return false
                }
                current = Accessibility.element(node, kAXParentAttribute)
            }
            return false
        }
    }

    private final class AXSession: CodexConversationSession {
        private let surface: Surface
        private let editor: AXUIElement
        private let sendControl: AXUIElement

        init?(context: ForegroundContext) {
            guard let surface = Surface(context), let tree = nodes(in: surface.webArea),
                  let editor = Self.composer(tree),
                  let sendControl = unique(tree, where: { $0.role == kAXButtonRole && $0.named(sendNames) }) else { return nil }
            self.surface = surface
            self.editor = editor
            self.sendControl = sendControl
        }

        private static func composer(_ tree: [Node]) -> AXUIElement? {
            unique(tree) { $0.role == kAXTextAreaRole && Accessibility.string($0.element, kAXValueAttribute) != nil }
        }

        private func read() -> (CodexDraftObservation, AXUIElement?)? {
            guard surface.unobstructed(), let tree = nodes(in: surface.webArea),
                  !tree.contains(where: \.obstructsComposer), let current = Self.composer(tree),
                  CFEqual(current, editor), let value = Accessibility.string(editor, kAXValueAttribute),
                  surface.isCurrent() else { return nil }
            let controls = tree.filter { $0.role == kAXButtonRole }
            let modes: [([String], CodexDraftObservation)] = [
                (dictate, .empty), (starting, .starting), (recording, .recording), (transcribing, .transcribing)
            ]
            let matches = modes.flatMap { labels, state in
                controls.filter { $0.named(labels) }.map { ($0.element, state) }
            }
            guard matches.count == 1, let (mic, state) = matches.first else { return nil }
            let empty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if state != .empty { return empty ? (state, nil) : nil }
            guard let button = unique(controls, where: { $0.named(sendNames) }), CFEqual(button, sendControl),
                  let enabled = Accessibility.value(button, kAXEnabledAttribute) as? Bool,
                  Accessibility.canPress(mic) else { return nil }
            if empty && !enabled { return (.empty, nil) }
            guard !empty, enabled, Accessibility.canPress(button) else { return nil }
            return (.ready(value), button)
        }

        func observe() -> CodexDraftObservation? { read()?.0 }

        func send(_ transcript: String) -> Bool {
            guard let (state, button) = read(), state == .ready(transcript), let button,
                  Accessibility.string(editor, kAXValueAttribute) == transcript, surface.isCurrent() else { return false }
            return Accessibility.press(button)
        }
    }
}
