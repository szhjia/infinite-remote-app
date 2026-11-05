import Foundation
import RemoteCore

// All device-specific package v1 adaptation stays at this input boundary.
enum LegacyRemoteCompatibility {
    static func defaults(id: String, declared: [String: AgentAction]?) -> [String: AgentAction] {
        declared ?? (id == RemoteDefinition.xiaomiID ? AgentProfile.defaults.actions : [:])
    }

    static func target(id: String, declared: AppTarget?) -> AppTarget? {
        declared ?? (id == RemoteDefinition.xiaomiID ? AgentProfile.defaults.target : nil)
    }

    static func behavior(id: String, declared: RemoteBehavior?) -> RemoteBehavior {
        declared ?? (id == RemoteDefinition.xiaomiID
            ? RemoteBehavior(coalescedKeys: ["home", "tv", "menu"], deferredKeys: ["power"],
                             nativeDictationKeys: ["voice"], consumesContextMenu: true)
            : .empty)
    }
}
