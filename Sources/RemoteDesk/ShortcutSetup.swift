import AppKit
import RemoteCore
import SwiftUI

@MainActor
struct ShortcutSetup: View {
    let title: String
    let instructions: String
    let needsCombination: Bool
    let initialShortcut: RemoteCore.KeyboardShortcut?
    let cancel: () -> Void
    let save: (RemoteCore.KeyboardShortcut) -> Void
    @State private var shortcut: RemoteCore.KeyboardShortcut?

    init(title: String, instructions: String, needsCombination: Bool,
         initialShortcut: RemoteCore.KeyboardShortcut? = nil, cancel: @escaping () -> Void,
         save: @escaping (RemoteCore.KeyboardShortcut) -> Void) {
        self.title = title
        self.instructions = instructions
        self.needsCombination = needsCombination
        self.initialShortcut = initialShortcut
        self.cancel = cancel
        self.save = save
        _shortcut = State(initialValue: initialShortcut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(instructions).font(.callout).foregroundStyle(.secondary)
            if initialShortcut != nil {
                Text(L10n.tr("按下新的快捷键即可替换当前快捷键。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Recorder(label: shortcut?.label ?? L10n.tr("按下快捷键")) { shortcut = $0 }
                .frame(height: 34)
            if needsCombination, let shortcut, !shortcut.isVoiceCombination {
                Text(L10n.tr("请选择带修饰键的组合键。")).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.tr("取消"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.tr(initialShortcut == nil ? "使用快捷键" : "保存修改")) { if let shortcut { save(shortcut) } }
                    .disabled(shortcut == nil || shortcut == initialShortcut || needsCombination && shortcut?.isVoiceCombination != true)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 410)
    }

    private struct Recorder: NSViewRepresentable {
        let label: String
        let capture: (RemoteCore.KeyboardShortcut) -> Void

        func makeNSView(context: Context) -> RecordingButton {
            let button = RecordingButton(title: label, target: nil, action: nil)
            button.setButtonType(.momentaryPushIn)
            button.bezelStyle = .rounded
            button.capture = capture
            return button
        }

        func updateNSView(_ view: RecordingButton, context: Context) {
            view.title = label
            view.capture = capture
        }
    }

    private final class RecordingButton: NSButton {
        var capture: (RemoteCore.KeyboardShortcut) -> Void = { _ in }
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                window?.makeFirstResponder(self)
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if !record(event) { super.keyDown(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, record(event) { return true }
            return super.performKeyEquivalent(with: event)
        }

        private func record(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let map: [(NSEvent.ModifierFlags, RemoteCore.KeyboardShortcut.Modifier)] = [
                (.command, .command), (.option, .option), (.control, .control), (.shift, .shift)
            ]
            let modifiers = Set(map.compactMap { flags.contains($0.0) ? $0.1 : nil })
            // Keep unmodified Escape and Tab available for cancelling and keyboard focus.
            guard !event.isARepeat, !modifiers.isEmpty || ![48, 53].contains(event.keyCode) else { return false }
            capture(RemoteCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers,
                                                keyName: SystemHotKey(keyCode: event.keyCode, flags: 0).label))
            return true
        }
    }
}

@MainActor
struct MacDictationSetup: View {
    static let compatibilityTitle = "听写快捷键（兼容模式）"
    static let instructions = "当前应用无法通过菜单启动系统听写时，可录入系统「键盘」设置中已有的听写组合键。"

    let model: RemoteModel
    let dismiss: () -> Void

    private var currentShortcut: RemoteCore.KeyboardShortcut? {
        guard case let .voiceShortcut(.macOS, shortcut) = model.defaultVoice else { return nil }
        return shortcut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShortcutSetup(title: L10n.tr(Self.compatibilityTitle), instructions: L10n.tr(Self.instructions),
                          needsCombination: true, initialShortcut: currentShortcut, cancel: dismiss) { shortcut in
                if model.setDefaultVoice(.voiceShortcut(.macOS, shortcut)) { dismiss() }
            }
            if let error = model.storageError {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .bottom], 18)
                    .frame(width: 410, alignment: .leading)
            }
        }
    }
}

@MainActor
extension AppTarget {
    var displayName: String {
        if bundleID == Self.finder.bundleID { return L10n.tr("访达") }
        if bundleID == Self.chatGPT.bundleID { return "ChatGPT" }
        guard let url = AgentRunner.appURL(self) else { return bundleID }
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}
