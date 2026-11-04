import AppKit
import ApplicationServices
import Observation
import RemoteCore

enum DictationSubmission {
    case waitingForTranscript, awaitingConfirmation, confirmed
}

@MainActor
protocol DictationSession: AnyObject {
    func isRecording() throws -> Bool
    func stop() throws
    func submitTranscriptIfReady() throws -> DictationSubmission
    func cancel()
}

enum DictationFailure: LocalizedError {
    case accessibilityRequired, codexNotFrontmost, conversationNotIdentifiable, composerUnavailable
    case startRejected, draft, contextChanged, recordingNotConfirmed, transcriptNotConfirmed, submitFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: "请先在系统设置中允许遥控台使用辅助功能。"
        case .codexNotFrontmost: "请先把 Codex 对话切到前台。"
        case .conversationNotIdentifiable: "无法确认当前对话。请在 Codex 中打开一条已有消息的本地对话。"
        case .composerUnavailable: "在当前 Codex 对话中未能识别可操作的输入框和听写控件。"
        case .startRejected: "Codex 未接受开始听写的操作。"
        case .draft: "当前对话已有草稿或附件，已取消听写。"
        case .contextChanged: "Codex 对话、输入框或权限已变化，未发送。"
        case .recordingNotConfirmed: "未能确认 Codex 开始听写。请检查 ChatGPT 的麦克风权限。"
        case .transcriptNotConfirmed: "未能确认同一对话的听写结果，未发送。"
        case .submitFailed: "未能确认 Codex 的发送结果，请查看原对话。"
        }
    }
}

@MainActor @Observable
final class DictationController {
    enum Phase: Equatable {
        case idle, holding, starting, recording, transcribing, submitting, sent, failed(String)

        var message: String? {
            switch self {
            case .idle, .holding: nil
            case .starting: "正在启动 Codex 听写…"
            case .recording: "录音中 · 松开发送"
            case .transcribing: "正在转写…"
            case .submitting: "正在确认发送结果…"
            case .sent: "已发送到 Codex"
            case let .failed(message): message
            }
        }

        var active: Bool {
            switch self {
            case .holding, .starting, .recording, .transcribing, .submitting: true
            default: false
            }
        }
    }

    private(set) var phase = Phase.idle
    private let begin: @MainActor () throws -> any DictationSession
    let holdDelay: Duration
    private var task: Task<Void, Never>?
    private var session: (any DictationSession)?

    init(holdDelay: Duration = .milliseconds(250),
         begin: @escaping @MainActor () throws -> any DictationSession = CodexDictationSession.begin) {
        self.holdDelay = holdDelay
        self.begin = begin
    }

    func press() {
        guard !phase.active else { return }
        phase = .holding
        task = Task { [weak self, holdDelay] in
            do { try await Task.sleep(for: holdDelay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            do {
                session = try begin()
                phase = .starting
                try await wait(upTo: .seconds(4), failure: .recordingNotConfirmed) {
                    try session?.isRecording() == true
                }
                try Task.checkCancellation()
                phase = .recording
                // A missing HID release must never result in an automatic send.
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(60))
                while clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(300))
                    try Task.checkCancellation()
                    guard try session?.isRecording() == true else { throw DictationFailure.recordingNotConfirmed }
                }
                cancel("未收到语音键松开信号，已取消听写。")
            } catch is CancellationError {
                return
            } catch {
                cancel(error.localizedDescription)
            }
        }
    }

    func release() {
        switch phase {
        case .holding:
            cancel()
        case .starting:
            cancel(DictationFailure.recordingNotConfirmed.localizedDescription)
        case .recording:
            task?.cancel()
            guard let session else { return }
            do {
                try session.stop()
                phase = .transcribing
            } catch {
                cancel(error.localizedDescription)
                return
            }
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await wait(upTo: .seconds(20), failure: .transcriptNotConfirmed) {
                        switch try session.submitTranscriptIfReady() {
                        case .waitingForTranscript: return false
                        case .awaitingConfirmation:
                            phase = .submitting
                            return false
                        case .confirmed: return true
                        }
                    }
                    self.session = nil
                    phase = .sent
                } catch is CancellationError {
                    return
                } catch {
                    cancel(error.localizedDescription)
                }
            }
        default:
            break
        }
    }

    func cancel(_ reason: String? = nil) {
        guard phase.active else { return }
        let submitted = phase == .submitting
        task?.cancel()
        task = nil
        if !submitted { session?.cancel() }
        session = nil
        phase = submitted ? .failed(DictationFailure.submitFailed.localizedDescription) : reason.map(Phase.failed) ?? .idle
    }

    private func wait(upTo timeout: Duration, failure: DictationFailure, until condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while clock.now < deadline
        throw failure
    }
}

@MainActor
private final class CodexDictationSession: DictationSession {
    private enum Control {
        static let start = ["Dictate", "听写", "聽寫"]
        static let stop = ["Stop dictation", "停止听写", "停止聽寫"]
        static let cancel = ["Cancel dictation", "取消听写", "取消聽寫"]
        static let starting = ["Starting dictation; click to cancel", "正在启动听写；点击可取消"]
        static let transcribing = ["Cancel transcription", "取消转录", "取消轉錄", "Finishing dictation", "正在完成听写"]
        static let cancelTranscription = ["Cancel transcription", "取消转录", "取消轉錄"]
        static let send = ["Send", "Send message", "Send prompt", "发送", "发送消息", "傳送", "傳送訊息"]
    }

    private let app: AXUIElement
    private let pid: pid_t
    private let window: AXUIElement
    private let webArea: AXUIElement
    private let route: URL
    private let editor: AXUIElement
    private var observedTranscribing = false
    private var submitRequested = false

    private init(app: AXUIElement, pid: pid_t, window: AXUIElement, webArea: AXUIElement,
                 route: URL, editor: AXUIElement) {
        self.app = app
        self.pid = pid
        self.window = window
        self.webArea = webArea
        self.route = route
        self.editor = editor
    }

    static func begin() throws -> any DictationSession {
        guard AXIsProcessTrusted() else { throw DictationFailure.accessibilityRequired }
        guard let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier == AgentProfile.chatGPT.target?.bundleID else {
            throw DictationFailure.codexNotFrontmost
        }
        let pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = Accessibility.element(app, kAXFocusedWindowAttribute) else {
            throw DictationFailure.conversationNotIdentifiable
        }
        let candidates = elements(in: window).filter {
            Accessibility.string($0, kAXRoleAttribute) == "AXWebArea" && codexRoute($0) != nil
        }
        guard candidates.count == 1, let area = candidates.first, let route = codexRoute(area) else {
            throw DictationFailure.conversationNotIdentifiable
        }
        let nodes = elements(in: area)
        guard let editor = composer(in: nodes), let draft = Accessibility.string(editor, kAXValueAttribute),
              let send = button(Control.send, in: nodes), let start = button(Control.start, in: nodes),
              Accessibility.canPress(start) else { throw DictationFailure.composerUnavailable }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Accessibility.value(send, kAXEnabledAttribute) as? Bool == false else { throw DictationFailure.draft }
        let session = CodexDictationSession(app: app, pid: pid, window: window, webArea: area, route: route, editor: editor)
        _ = try session.currentElements()
        guard Accessibility.press(start) else { throw DictationFailure.startRejected }
        return session
    }

    func isRecording() throws -> Bool {
        guard let stop = Self.button(Control.stop, in: try currentElements()) else { return false }
        return Accessibility.canPress(stop)
    }

    func stop() throws {
        guard let stop = Self.button(Control.stop, in: try currentElements()), Accessibility.canPress(stop),
              Accessibility.press(stop) else { throw DictationFailure.recordingNotConfirmed }
        observedTranscribing = Self.button(Control.transcribing, in: try currentElements()) != nil
    }

    func submitTranscriptIfReady() throws -> DictationSubmission {
        let nodes = try currentElements()
        if submitRequested {
            guard let current = Self.composer(in: nodes), CFEqual(editor, current),
                  let draft = Accessibility.string(editor, kAXValueAttribute),
                  draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .awaitingConfirmation }
            return .confirmed
        }
        if Self.button(Control.transcribing, in: nodes) != nil {
            observedTranscribing = true
            return .waitingForTranscript
        }
        guard observedTranscribing, let current = Self.composer(in: nodes),
              CFEqual(editor, current), let transcript = Accessibility.string(editor, kAXValueAttribute),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.button(Control.start, in: nodes) != nil,
              let send = Self.button(Control.send, in: nodes), Accessibility.canPress(send) else { return .waitingForTranscript }
        // Recheck the same route, editor and value immediately before invoking the exact send control.
        let rechecked = try currentElements()
        guard let currentEditor = Self.composer(in: rechecked), CFEqual(editor, currentEditor),
              Accessibility.string(editor, kAXValueAttribute) == transcript,
              let currentSend = Self.button(Control.send, in: rechecked), CFEqual(send, currentSend),
              Accessibility.canPress(currentSend), Accessibility.press(currentSend) else {
            throw DictationFailure.submitFailed
        }
        submitRequested = true
        return .awaitingConfirmation
    }

    func cancel() {
        guard AXIsProcessTrusted(), Self.codexRoute(webArea) == route else { return }
        let nodes = Self.elements(in: webArea)
        if let button = Self.button(Control.cancel + Control.starting + Control.cancelTranscription, in: nodes),
           Accessibility.canPress(button) {
            _ = Accessibility.press(button)
        }
    }

    private func currentElements() throws -> [AXUIElement] {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = Accessibility.element(app, kAXFocusedWindowAttribute), CFEqual(window, current),
              Self.codexRoute(webArea) == route else { throw DictationFailure.contextChanged }
        return Self.elements(in: webArea)
    }

    private static func codexRoute(_ area: AXUIElement) -> URL? {
        guard let url = Accessibility.value(area, kAXURLAttribute) as? URL else { return nil }
        // The installed desktop client uses /local/:conversationId for a Codex chat.
        // ChatGPT chats and new composers must not qualify.
        let route = url.fragment?.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url.path
        let components = route.split(separator: "/")
        guard components.count == 2, components[0] == "local",
              UUID(uuidString: String(components[1])) != nil else { return nil }
        return url
    }

    private static func composer(in elements: [AXUIElement]) -> AXUIElement? {
        let editors = elements.filter {
            Accessibility.string($0, kAXRoleAttribute) == kAXTextAreaRole
                && Accessibility.string($0, kAXValueAttribute) != nil
        }
        return editors.count == 1 ? editors.first : nil
    }

    private static func button(_ labels: [String], in elements: [AXUIElement]) -> AXUIElement? {
        let matches = elements.filter { element in
            guard Accessibility.string(element, kAXRoleAttribute) == kAXButtonRole else { return false }
            return [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
                Accessibility.string(element, attribute).map(labels.contains) ?? false
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func elements(in root: AXUIElement) -> [AXUIElement] {
        var stack = [root]
        var found: [AXUIElement] = []
        while let node = stack.popLast(), found.count < 600 {
            found.append(node)
            let role = Accessibility.string(node, kAXRoleAttribute)
            if role != kAXStaticTextRole && role != kAXButtonRole && role != kAXTextAreaRole {
                stack.append(contentsOf: Accessibility.children(node))
            }
        }
        return found
    }
}
