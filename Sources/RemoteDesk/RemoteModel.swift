import AppKit
import CoreGraphics
import Observation
import RemoteCore

@MainActor @Observable
final class RemoteModel {
    struct Activity: Identifiable {
        let id = UUID()
        let text: String
    }

    private(set) var config = Configuration()
    private(set) var devices: [DeviceID] = []
    private(set) var monitorState: InputMonitorState = .permission
    private(set) var learning: String?
    private(set) var activity: [Activity] = []
    private(set) var feedback: String?
    private(set) var error: String?
    private(set) var storageError: String?
    private(set) var isRunning = false
    private(set) var canPost = false
    private(set) var pulse: String?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { cancelLearning() }
        }
    }
    var isEditing = false
    var slot = "ok"

    private let hid: any RemoteInputSource
    private let storeURL: URL
    private let runAction: @MainActor (AgentAction, AppTarget?) async throws -> Void
    private var canSave = true
    private var pulseTask: Task<Void, Never>?
    private var learningTask: Task<Void, Never>?

    convenience init() {
        let directory = URL.applicationSupportDirectory.appending(path: "RemoteDesk", directoryHint: .isDirectory)
        self.init(hid: HIDMonitor(), storeURL: directory.appending(path: "configuration.json"),
                  runAction: AgentRunner.run)
    }

    init(hid: any RemoteInputSource, storeURL: URL,
         runAction: @escaping @MainActor (AgentAction, AppTarget?) async throws -> Void) {
        self.hid = hid
        self.storeURL = storeURL
        self.runAction = runAction
        var didUpgrade = false
        do {
            let decoded = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: storeURL))
            if decoded.version == Configuration.currentVersion {
                config = decoded
            } else if decoded.version == 1 {
                config = decoded
                config.upgradeFromVersionOne()
                didUpgrade = true
            } else {
                canSave = false
                storageError = "配置来自其他版本，本次更改不会覆盖原文件。"
            }
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            // The initial configuration is saved after the first edit.
        } catch {
            canSave = false
            storageError = "无法读取配置，本次更改不会覆盖原文件。"
        }
        slot = config.activeRemote?.layout == .generic ? "key1" : "ok"
        hid.selectedDevice = config.selectedDevice
        hid.onDevices = { [weak self] devices in
            guard let self else { return }
            self.devices = devices
            if !connected { cancelLearning() }
        }
        hid.onPress = { [weak self] device, input in self?.receive(device, input) }
        if didUpgrade { save() }
    }

    var connected: Bool { config.selectedDevice.map(devices.contains) ?? false }
    var canReadKeys: Bool { connected && monitorState == .listening }
    var layout: RemoteLayout { config.activeRemote?.layout ?? .xiaomi2Pro }
    var learnedCount: Int {
        let keys = Set(RemoteKey.keys(for: layout).map(\.id))
        return config.activeRemote?.keys.count(where: { keys.contains($0.slot) }) ?? 0
    }
    var profile: AgentProfile? { config.activeAgent }

    func refreshPermissions() {
        monitorState = hid.refresh()
        if !canReadKeys { cancelLearning() }
        canPost = CGPreflightPostEventAccess()
    }

    func requestListen() {
        if !CGRequestListenEventAccess() { openPrivacy("Privacy_ListenEvent") }
        refreshPermissions()
    }

    func requestPost() {
        if !CGRequestPostEventAccess() { openPrivacy("Privacy_Accessibility") }
        refreshPermissions()
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBluetooth() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    func selectDevice(_ id: DeviceID?) {
        cancelLearning()
        if let id { config.selectDevice(id) } else { config.selectedDevice = nil }
        hid.selectedDevice = id
        slot = layout == .generic ? "key1" : "ok"
        feedback = nil
        error = nil
        activity = []
        save()
    }

    func selectLayout(_ layout: RemoteLayout) {
        cancelLearning()
        config.updateRemote { $0.layout = layout }
        slot = layout == .generic ? "key1" : "ok"
        save()
    }

    func selectSlot(_ slot: String) {
        if self.slot != slot { cancelLearning() }
        self.slot = slot
    }

    func startLearning() {
        guard canReadKeys, isEnabled else { return }
        cancelLearning()
        learning = slot
        feedback = nil
        error = nil
        learningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.cancelLearning()
            self?.error = "未收到按键。检查遥控器是否已连接，然后重试。"
        }
    }

    func cancelLearning() {
        learningTask?.cancel()
        learningTask = nil
        learning = nil
    }

    func forget(_ slot: String) {
        cancelLearning()
        config.updateRemote { $0.forget(slot) }
        save()
        feedback = "已清除按键信号"
    }

    func selectAgent(_ id: String) {
        guard config.agents.contains(where: { $0.id == id }) else { return }
        cancelLearning()
        config.activeAgentID = id
        error = nil
        feedback = nil
        save()
    }

    func saveProfile(_ profile: AgentProfile) {
        if let index = config.agents.firstIndex(where: { $0.id == profile.id }) {
            config.agents[index] = profile
        } else {
            config.agents.append(profile)
        }
        selectAgent(profile.id)
    }

    func removeProfile(_ id: String) {
        guard config.agents.count > 1 else { return }
        config.agents.removeAll { $0.id == id }
        if config.activeAgentID == id, let first = config.agents.first { selectAgent(first.id) }
        else { save() }
    }

    func setAction(_ action: AgentAction?, for slot: String, in agentID: String) {
        guard let index = config.agents.firstIndex(where: { $0.id == agentID }) else { return }
        config.agents[index].actions[slot] = action
        save()
        feedback = "动作已保存"
        error = nil
    }

    func testAction(_ action: AgentAction) {
        cancelLearning()
        perform(action)
    }

    private func receive(_ device: DeviceID, _ input: InputCode) {
        guard config.selectedDevice == device, canReadKeys else { return }
        let knownSlot = config.match(device: device, input: input)
        let visibleSlot = knownSlot.flatMap { candidate in RemoteKey.keys(for: layout).first { $0.id == candidate } }
        let signal = "\(visibleSlot.map { $0.name + " · " } ?? "")\(input.label)"
        activity.insert(Activity(text: signal), at: 0)
        if activity.count > 20 { activity.removeLast() }

        if let key = learning {
            cancelLearning()
            config.updateRemote { $0.learn(input, as: key) }
            save()
            feedback = knownSlot != nil && knownSlot != key ? "已录入，信号从原键位移到此处" : "按键已录入"
            flash(key)
            return
        }
        guard let visibleSlot else { return }
        flash(visibleSlot.id)
        guard isEnabled, !isEditing, let action = profile?.actions[visibleSlot.id] else { return }
        perform(action)
    }

    private func flash(_ key: String) {
        pulseTask?.cancel()
        pulse = key
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.pulse = nil
        }
    }

    private func perform(_ action: AgentAction) {
        guard !isRunning else { return }
        error = nil
        if action == .nextAgent {
            config.nextAgent()
            save()
            feedback = "已切换到 \(profile?.name ?? "Agent")"
            return
        }
        isRunning = true
        feedback = nil
        let target = profile?.target
        Task {
            defer { isRunning = false }
            do {
                try await runAction(action, target)
                feedback = "已执行：\(action.title)"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: storeURL, options: .atomic)
            storageError = nil
        } catch {
            storageError = "配置保存失败：\(error.localizedDescription)"
        }
    }
}

extension AgentAction {
    var title: String {
        switch self {
        case .openApp: "打开目标应用"
        case .openLink: "打开网页"
        case .shortcut: "发送应用快捷键"
        case .chatBar: "打开 ChatGPT Chat Bar"
        case .nextAgent: "切换到下一个 Agent"
        }
    }

    var detail: String? {
        switch self {
        case let .openLink(url): url
        case let .shortcut(keys): keys.label
        case .chatBar: "⌥Space"
        default: nil
        }
    }
}

extension RemoteLayout {
    var title: String { self == .xiaomi2Pro ? "小米蓝牙遥控器 2 Pro" : "通用蓝牙遥控器" }
}

struct RemoteKey: Identifiable {
    let id: String
    let name: String
    let symbol: String

    static let xiaomi: [Self] = [
        .init(id: "power", name: "电源", symbol: "power"),
        .init(id: "voice", name: "语音", symbol: "mic"),
        .init(id: "up", name: "方向上", symbol: "chevron.up"),
        .init(id: "left", name: "方向左", symbol: "chevron.left"),
        .init(id: "ok", name: "确定", symbol: "circle.inset.filled"),
        .init(id: "right", name: "方向右", symbol: "chevron.right"),
        .init(id: "down", name: "方向下", symbol: "chevron.down"),
        .init(id: "back", name: "返回", symbol: "chevron.left"),
        .init(id: "plus", name: "音量加", symbol: "plus"),
        .init(id: "home", name: "主页", symbol: "house"),
        .init(id: "minus", name: "音量减", symbol: "minus"),
        .init(id: "menu", name: "菜单", symbol: "line.3.horizontal"),
        .init(id: "tv", name: "直播", symbol: "tv")
    ]
    static let generic: [Self] = (1...16).map { .init(id: "key\($0)", name: "按键 \($0)", symbol: "\($0).circle") }
    static func keys(for layout: RemoteLayout) -> [Self] { layout == .xiaomi2Pro ? xiaomi : generic }
}
