import Foundation
import Darwin
import IOKit.hidsystem
import RemoteCore

/// The event service can suppress OS key delivery while IOHIDDevice keeps
/// delivering the original reports. Never take over a pre-existing user map.
@MainActor
final class RemoteKeyboardMap {
    private struct Ownership: Codable {
        let registryID: UInt64
        let location: UInt32
        let usages: [UInt64]

        var mapping: CFArray {
            usages.map {
                ["HIDKeyboardModifierMappingSrc": 0x7_0000_0000 | $0,
                 "HIDKeyboardModifierMappingDst": UInt64(0)]
            } as CFArray
        }
    }

    private static let usages: [UInt64] = [
        0x28, 0x29, 0x3E, 0x4A, 0x4F, 0x50, 0x51, 0x52, 0x65, 0x66, 0x80, 0x81, 0xF1
    ]
    private static let property = "UserKeyMapping" as CFString
    private let recoveryURL: URL
    private var eventClient: IOHIDEventSystemClient?
    private var active: (service: IOHIDServiceClient, ownership: Ownership)?
    private var lockDescriptor: Int32 = -1

    init(recoveryURL: URL) {
        self.recoveryURL = recoveryURL
    }

    static func covers(_ input: InputCode, preservingNativeF5: Bool = false) -> Bool {
        guard let usage = input.keyboardUsage, let usage = UInt64(exactly: usage) else { return false }
        return (!preservingNativeF5 || !input.isKeyboardF5) && usages.contains(usage)
    }

    func isActive(at location: UInt32) -> Bool {
        guard let active, active.ownership.location == location,
              let current = IOHIDServiceClientCopyProperty(active.service, Self.property) else { return false }
        return CFEqual(current, active.ownership.mapping)
    }

    func capture(at location: UInt32, preservingNativeF5: Bool) -> Bool {
        guard lock() else { return false }
        defer { if active == nil { unlock() } }
        let usages = preservingNativeF5 ? Self.usages.filter { $0 != 0x3E } : Self.usages
        if active?.ownership.usages == usages, isActive(at: location) { return true }
        let services = matchingServices()
        guard restore(using: services) else { return false }
        let matching = services.filter { Self.location(of: $0) == location }
        guard location != 0, matching.count == 1, let service = matching.first,
              let id = Self.registryID(of: service), let empty = isEmpty(service), empty else { return false }
        let ownership = Ownership(registryID: id, location: location, usages: usages)
        do {
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ownership).write(to: recoveryURL, options: .atomic)
        } catch { return false }

        active = (service, ownership)
        let written = IOHIDServiceClientSetProperty(service, Self.property, ownership.mapping)
        if written && isActive(at: location) { return true }
        _ = restore(using: services)
        return false
    }

    @discardableResult
    func restore() -> Bool {
        if active == nil && !FileManager.default.fileExists(atPath: recoveryURL.path) { return true }
        guard lock() else { return false }
        defer { unlock() }
        return restore(using: matchingServices())
    }

    private func lock() -> Bool {
        if lockDescriptor >= 0 { return true }
        do {
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { return false }
        let file = recoveryURL.appendingPathExtension("lock")
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return false }
        lockDescriptor = descriptor
        return true
    }

    private func unlock() {
        guard lockDescriptor >= 0 else { return }
        close(lockDescriptor)
        lockDescriptor = -1
    }

    private func restore(using services: [IOHIDServiceClient]) -> Bool {
        let owned = active?.ownership ?? (try? Data(contentsOf: recoveryURL)).flatMap {
            try? JSONDecoder().decode(Ownership.self, from: $0)
        }
        guard let owned else { return !FileManager.default.fileExists(atPath: recoveryURL.path) }
        let service = active?.service ?? services.first {
            Self.registryID(of: $0) == owned.registryID && Self.location(of: $0) == owned.location
        }
        if let service, let current = IOHIDServiceClientCopyProperty(service, Self.property),
           CFEqual(current, owned.mapping) {
            guard IOHIDServiceClientSetProperty(service, Self.property, [] as CFArray),
                  isEmpty(service) == true else { return false }
        } else if service == nil && services.isEmpty {
            // An unavailable event client cannot distinguish a disconnected
            // service from a temporary permission loss. Keep the recovery record.
            return false
        }
        do { try FileManager.default.removeItem(at: recoveryURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        catch { return false }
        active = nil
        return true
    }

    private func isEmpty(_ service: IOHIDServiceClient) -> Bool? {
        guard let map = IOHIDServiceClientCopyProperty(service, Self.property) else { return true }
        return (map as? [Any])?.isEmpty
    }

    private func matchingServices() -> [IOHIDServiceClient] {
        if eventClient == nil {
            eventClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        }
        guard let client = eventClient else { return [] }
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter {
            let vendor = IOHIDServiceClientCopyProperty($0, "VendorID" as CFString) as? Int
            let product = IOHIDServiceClientCopyProperty($0, "ProductID" as CFString) as? Int
            let transport = IOHIDServiceClientCopyProperty($0, "Transport" as CFString) as? String
            return vendor == 0x2717 && product == 0x32B8
                && ["Bluetooth", "BluetoothLowEnergy", "Bluetooth Low Energy"].contains(transport ?? "")
                && IOHIDServiceClientConformsTo($0, 1, 6) != 0
        }
    }

    private static func location(of service: IOHIDServiceClient) -> UInt32? {
        (IOHIDServiceClientCopyProperty(service, "LocationID" as CFString) as? NSNumber)?.uint32Value
    }

    private static func registryID(of service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }
}
