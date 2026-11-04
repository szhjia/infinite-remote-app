import SwiftUI

@main
struct RemoteDeskApp: App {
    @State private var model = RemoteModel()

    var body: some Scene {
        Window("遥控台 · RemoteDesk", id: "workspace") {
            Workspace(model: model)
                .frame(minWidth: 890, minHeight: 640)
                .task {
                    model.refreshPermissions()
                    for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
                        .map({ _ in true }) {
                        model.refreshPermissions()
                    }
                }
        }
        .defaultSize(width: 1020, height: 720)
        MenuBarExtra("遥控台", systemImage: "dot.radiowaves.left.and.right") {
            TrayMenu(model: model)
        }
    }
}

private struct TrayMenu: View {
    @Bindable var model: RemoteModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.profile?.name ?? "遥控台")
        Button("打开遥控台") {
            openWindow(id: "workspace")
            NSApp.activate()
        }
        Toggle("允许遥控触发动作", isOn: $model.isEnabled)
        Divider()
        Button("退出遥控台") { NSApp.terminate(nil) }
    }
}
