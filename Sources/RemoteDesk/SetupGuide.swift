import AppKit
import SwiftUI

struct SetupGuide: View {
    static let windowSize = NSSize(width: 690, height: 530)

    let model: RemoteModel
    let library: ResourceLibrary
    let showsKeyboardFocus: () -> Bool
    let saveStage: (SetupStage) -> Void
    let deferSetup: () -> Void
    let finish: () -> Void
    @State private var stage: SetupStage
    @State private var waitsForRemoteOnResume: Bool
    @State private var voiceDriverReady = false
    @AccessibilityFocusState private var headingFocused: Bool

    init(model: RemoteModel, library: ResourceLibrary, stage: SetupStage,
         showsKeyboardFocus: @escaping () -> Bool = { false },
         saveStage: @escaping (SetupStage) -> Void, deferSetup: @escaping () -> Void,
         finish: @escaping () -> Void) {
        self.model = model
        self.library = library
        self.showsKeyboardFocus = showsKeyboardFocus
        self.saveStage = saveStage
        self.deferSetup = deferSetup
        self.finish = finish
        let readiness = SetupReadiness(model: model)
        let restored = stage.restored(hasModel: model.hasRemote, readiness: readiness)
        _stage = State(initialValue: restored)
        // The Bluetooth device may appear after the guide is restored.
        _waitsForRemoteOnResume = State(initialValue: restored == .permissions
            && readiness.hasPermissions && readiness.canPostShortcuts)
    }

    private var readiness: SetupReadiness { SetupReadiness(model: model) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(stage.title).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Spacer()
                Text("\(stage.position + 1) / \(SetupStage.allCases.count)")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.format("第 %d 步，共 %d 步", stage.position + 1, SetupStage.allCases.count))
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 16)
            Group {
                switch stage {
                case .welcome: SetupBanner()
                case .voiceDriver: voiceDriver
                case .remote: SetupRemoteStep(model: model, library: library)
                case .permissions: permissions
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
            Divider()
            footer
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusEffectDisabled(!showsKeyboardFocus())
        .onChange(of: readiness.canFinish, initial: true) { _, canFinish in
            if waitsForRemoteOnResume && stage == .permissions && canFinish {
                stage = .ready
            }
        }
        .onChange(of: stage, initial: true) { previous, value in
            saveStage(value)
            if previous != value {
                waitsForRemoteOnResume = false
                headingFocused = true
            }
        }
        .task(id: stage) {
            guard stage == .voiceDriver else { return }
            while !Task.isCancelled {
                voiceDriverReady = BlackHoleDevice.currentID() != nil
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(L10n.tr("稍后继续"), action: deferSetup)
            Spacer()
            if let previous = stage.adjacent(-1) {
                Button(L10n.tr("上一步")) { stage = previous }
            }
            Button(primaryTitle, action: advance)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var primaryTitle: String {
        switch stage {
        case .welcome: L10n.tr("开始设置")
        case .voiceDriver: L10n.tr(voiceDriverReady ? "继续" : "跳过此步")
        case .remote, .permissions: L10n.tr("继续")
        case .ready: L10n.tr("配置第一个按键")
        }
    }

    private var canAdvance: Bool {
        switch stage {
        case .welcome, .voiceDriver: true
        case .remote: readiness.connected
        case .permissions, .ready: readiness.canFinish
        }
    }

    private func advance() {
        guard canAdvance else { return }
        if let next = stage.adjacent(1) { stage = next }
        else { finish() }
    }

    private var voiceDriver: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("BlackHole 2ch", systemImage: "waveform")
                .font(.title2.bold())
            Text(L10n.tr("用遥控器机身麦克风听写时，BlackHole 2ch 会把遥控器音频交给语音应用。只使用按键或 Mac 麦克风时，可以跳过。"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("1. 从 Existential Audio 下载 BlackHole 2ch。"))
                Text(L10n.tr("2. 打开安装包，用 Mac 管理员权限完成安装。"))
                Text(L10n.tr("3. 重启 Mac，再打开无限遥控器。引导会回到此页并重新检测。"))
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link(L10n.tr("下载 BlackHole 2ch"), destination: URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!)
                    .buttonStyle(.borderedProminent)
                Link(L10n.tr("打开官方下载页"), destination: URL(string: "https://existential.audio/blackhole/")!)
                Button(L10n.tr("重新检查")) { voiceDriverReady = BlackHoleDevice.currentID() != nil }
            }
            Label(L10n.tr(voiceDriverReady ? "已检测到 BlackHole 2ch" : "尚未检测到 BlackHole 2ch"),
                  systemImage: voiceDriverReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(voiceDriverReady ? Color.green : Color.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                permissionRow(.accessibility)
                Divider().padding(.leading, 52)
                permissionRow(.inputMonitoring)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            if model.shortcutsNeedRestart {
                Label(L10n.tr("请退出并重新打开无限遥控器，以启用快捷键。"), systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                Text(L10n.tr("重新打开后会回到这一步。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !readiness.connected {
                Label(L10n.tr("正在等待遥控器连接。若未连上，可返回上一步检查蓝牙。"), systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            } else if readiness.hasPermissions && !readiness.listening {
                Label(L10n.tr("已授权，但暂时无法读取按键。"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            if !readiness.canFinish {
                Button(L10n.tr("重新检查"), action: model.refreshPermissions)
            }
            Spacer(minLength: 0)
        }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = kind.status(in: model)
        let canRequest = kind == .accessibility || readiness.needsSeparateInputAuthorization
        return HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.headline)
                Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .inputMonitoring && canRequest {
                    Text(L10n.tr("macOS 可能要求重新打开应用。重新打开后会回到这一步。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            if status.isAvailable {
                Label(status.title, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if canRequest {
                Button(L10n.tr("授权…")) {
                    saveStage(.permissions)
                    kind.request(in: model)
                }
                    .accessibilityLabel(L10n.format("授予%@权限", kind.title))
                    .accessibilityHint(L10n.tr("尚未授权"))
            } else {
                Text(L10n.tr("先开启辅助功能"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var ready: some View {
        VStack(spacing: 12) {
            Image(systemName: readiness.canFinish ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(readiness.canFinish ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(L10n.tr(readiness.canFinish ? "遥控器已就绪" : "遥控器暂未就绪"))
                .font(.largeTitle.bold())
            Text(L10n.tr(readiness.canFinish
                ? "为第一个按键选一个动作，就可以试用遥控器。"
                : "请返回上一步检查连接和权限。"))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct SetupRemoteStep: View {
    let model: RemoteModel
    let library: ResourceLibrary
    @State private var selectedID: String?
    @State private var installTask: Task<Void, Never>?
    @State private var bluetoothAuthorized = false

    private var source: RemoteSubscription? { library.sources.first(where: \.isDefault) }
    private var listings: [RemoteListing] { source?.catalog?.models ?? [] }
    private var listing: RemoteListing? { listings.first { $0.id == selectedID } ?? listings.first }
    private var isRefreshing: Bool { source.map { library.refreshing.contains($0.id) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.hasRemote {
                let definition = model.remoteDefinition
                deviceCard(brand: definition.manifest.brand?.name.resolve(), name: definition.manifest.name) {
                    Image(nsImage: definition.artwork).resizable().scaledToFit().accessibilityHidden(true)
                } action: {
                    connectionStatus
                }
            } else if let source, let listing {
                if listings.count > 1 {
                    Picker(L10n.tr("遥控器型号"), selection: Binding(
                        get: { listing.id },
                        set: { selectedID = $0 }
                    )) {
                        ForEach(listings) { Text($0.name.resolve()).tag($0.id) }
                    }
                    .disabled(!library.installing.isEmpty)
                }
                deviceCard(brand: listing.brand?.name.resolve(), name: listing.name.resolve()) {
                    CatalogPreview(url: library.previewURL(listing, source: source))
                } action: {
                    installAction(listing, source: source)
                }
            } else {
                VStack(spacing: 12) {
                    if isRefreshing || source.map({ $0.catalog == nil && library.errors[$0.id] == nil }) == true {
                        ProgressView(L10n.tr("正在载入默认遥控器…"))
                    } else {
                        Text(L10n.tr("暂时没有可用的遥控器型号。")).font(.headline)
                        if let source, let error = library.errors[source.id] ?? library.storageError {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        if let source {
                            Button(L10n.tr("刷新订阅源")) { Task { await library.refresh(source.id) } }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.supportsRemoteMicrophone, BlackHoleDevice.currentID() != nil {
                HStack(spacing: 10) {
                    Label(L10n.tr(bluetoothAuthorized ? "语音蓝牙已授权" : "机身麦克风需要蓝牙权限"),
                          systemImage: bluetoothAuthorized ? "checkmark.circle.fill" : "mic")
                        .foregroundStyle(bluetoothAuthorized ? Color.green : Color.secondary)
                    if !bluetoothAuthorized {
                        Button(L10n.tr("授权…"), action: model.requestVoiceBluetooth)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if !model.hasRemote, let source, source.catalog == nil { await library.refresh(source.id) }
        }
        .task {
            while !Task.isCancelled {
                bluetoothAuthorized = RemoteMicrophone.isBluetoothAuthorized
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { installTask?.cancel() }
    }

    private func deviceCard<Artwork: View, Action: View>(
        brand: String?, name: String, @ViewBuilder artwork: () -> Artwork, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 24) {
            artwork()
                .frame(width: 132, height: 220)
                .frame(width: 164, height: 254)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                if let brand { Text(brand).font(.callout).foregroundStyle(.secondary) }
                Text(name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.tr("相关商标和产品标识归各自权利人所有。此处展示仅用于识别兼容设备。无限遥控器为独立应用。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().padding(.vertical, 6)
                action()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func installAction(_ listing: RemoteListing, source: RemoteSubscription) -> some View {
        let key = source.id + ":" + listing.id
        if library.installing.contains(key) {
            ProgressView(L10n.tr("正在添加遥控器…")).controlSize(.small)
        } else {
            if let error = library.errors[key] {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L10n.tr("添加并连接")) {
                installTask = Task { await library.install(listing, from: source, into: model) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!library.installing.isEmpty)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if model.readiness == .ambiguous {
            Label(L10n.tr("已连接 · 设备无法区分"), systemImage: "exclamationmark.circle")
            Text(L10n.tr("请只保留一台此型号的遥控器连接。")).font(.callout).foregroundStyle(.secondary)
            Button(L10n.tr("打开蓝牙设置"), action: model.openBluetooth)
        } else if model.connected {
            Label(L10n.tr("已检测到遥控器"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if model.devicesForSelectedModel.count > 1 {
                SetupDevicePicker(model: model)
                    .accessibilityLabel(L10n.tr("选择遥控器"))
            }
        } else if !model.devicesForSelectedModel.isEmpty {
            SetupDevicePicker(model: model)
                .accessibilityLabel(L10n.tr("选择遥控器"))
        } else {
            Label(L10n.tr("未检测到遥控器"), systemImage: "circle.dashed")
            Text(L10n.tr("让遥控器进入配对模式，在蓝牙设置中连接后返回。"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.tr("打开蓝牙设置"), action: model.openBluetooth)
        }
    }
}
