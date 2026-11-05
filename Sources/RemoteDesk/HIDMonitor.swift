import AppKit
import CoreGraphics
import IOKit.hid
import RemoteCore

enum InputMonitorState: Equatable {
    case permission
    case idle
    case listening
    case failed(Int32)
    case ambiguous
}

@MainActor
protocol RemoteInputSource: AnyObject {
    var onDevices: ([DeviceID]) -> Void { get set }
    var onMonitorState: (InputMonitorState) -> Void { get set }
    var onEvent: (DeviceID, RemoteInputEvent) -> Void { get set }
    var onAmbiguousDevices: (Set<DeviceID>) -> Void { get set }
    var selectedDevice: DeviceID? { get set }
    func refresh() -> InputMonitorState
}

struct RemoteInputOrigin: Hashable {
    let endpoint: UInt64
    let cookie: Int
}

enum RemoteInputEvent {
    case pressed(InputCode, origin: RemoteInputOrigin? = nil)
    case released(InputCode, origin: RemoteInputOrigin? = nil)
    case replaced(InputCode, origin: RemoteInputOrigin)
    case endpointClosed(UInt64)
}

@MainActor
final class HIDMonitor: RemoteInputSource {
    var onDevices: ([DeviceID]) -> Void = { _ in }
    var onMonitorState: (InputMonitorState) -> Void = { _ in }
    var onEvent: (DeviceID, RemoteInputEvent) -> Void = { _, _ in }
    var onAmbiguousDevices: (Set<DeviceID>) -> Void = { _ in }
    var selectedDevice: DeviceID? {
        didSet {
            guard oldValue != selectedDevice else { return }
            edges = .init()
            updateListening()
        }
    }
    private let transports = [kIOHIDTransportBluetoothValue, kIOHIDTransportBluetoothLowEnergyValue, "Bluetooth Low Energy"]
    private var manager: IOHIDManager?
    private var hasPermission = false
    private var state: InputMonitorState = .permission {
        didSet { if state != oldValue { onMonitorState(state) } }
    }
    private struct Endpoint {
        let identity: DeviceID
        let device: IOHIDDevice
        let location: Int?
    }

    private var endpoints: [UInt64: Endpoint] = [:]
    private var ambiguousDevices: Set<DeviceID> = []
    private var opened: [UInt64: IOHIDDevice] = [:]
    private var edges = InputEdges<UInt64>()

    func refresh() -> InputMonitorState {
        hasPermission = CGPreflightListenEventAccess()
        if manager == nil { startDiscovery() }
        updateListening()
        return state
    }

    private func startDiscovery() {
        // Discovery must not open or subscribe to unrelated Bluetooth devices.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        let matching = transports.map {
            [kIOHIDTransportKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        // Callbacks run synchronously on the main run loop used to schedule this manager.
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.detach(device) }
        }, context)
        self.manager = manager
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices { attach(device, publish: false) }
        }
        publishDevices()
    }

    private func updateListening() {
        let ambiguous = selectedDevice.map(ambiguousDevices.contains) ?? false
        let selected = hasPermission && !ambiguous ? endpoints.filter { $0.value.identity == selectedDevice } : [:]
        for id in opened.keys.filter({ selected[$0] == nil }) {
            closeEndpoint(id)
        }
        if ambiguous {
            state = .ambiguous
            return
        }
        guard hasPermission else {
            state = .permission
            return
        }

        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        var firstFailure: IOReturn?
        for (id, entry) in selected where opened[id] == nil {
            let device = entry.device
            let result = IOHIDDeviceOpen(device, options)
            guard result == kIOReturnSuccess else {
                if firstFailure == nil { firstFailure = result }
                continue
            }
            opened[id] = device
            IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
                guard result == kIOReturnSuccess, let context else { return }
                let owner = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.handle(value) }
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }

        // A remote can expose multiple endpoints. Only one needs to open to read input.
        if !opened.isEmpty {
            state = .listening
        } else if let firstFailure {
            state = .failed(firstFailure)
        } else {
            state = .idle
        }
    }

    private func closeEndpoint(_ id: UInt64) {
        guard let device = opened.removeValue(forKey: id) else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        edges.remove(endpoint: id)
        if let selectedDevice { onEvent(selectedDevice, .endpointClosed(id)) }
    }

    private func endpoint(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == kIOReturnSuccess { return id }
        return UInt64(CFHash(device))
    }

    private func attach(_ device: IOHIDDevice, publish: Bool = true) {
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        guard let transport, transports.contains(transport) else { return }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let identity = DeviceID(vendor: vendor, product: product, name: name ?? "未命名蓝牙设备",
                                serial: serial?.isEmpty == false ? serial : nil)
        guard identity.isSupportedRemote else { return }
        let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int
        let previous = endpoints.updateValue(.init(identity: identity, device: device, location: location),
                                             forKey: endpoint(device))
        if publish && previous?.identity != identity {
            publishDevices()
            updateListening()
        }
    }

    private func detach(_ device: IOHIDDevice) {
        let id = endpoint(device)
        if endpoints.removeValue(forKey: id) != nil {
            publishDevices()
            updateListening()
        }
    }

    private func publishDevices() {
        let groups = Dictionary(grouping: endpoints.values, by: \.identity)
        ambiguousDevices = Set(groups.compactMap { identity, entries in
            guard entries.count > 1 else { return nil }
            // Multiple HID services can belong to one Bluetooth device.
            let locations = Set(entries.compactMap(\.location).filter { $0 != 0 })
            let shareLocation = locations.count == 1 && entries.allSatisfy { ($0.location ?? 0) != 0 }
            return shareLocation ? nil : identity
        })
        onAmbiguousDevices(ambiguousDevices)
        let devices = groups.keys.sorted {
            ($0.name, $0.vendor, $0.product, $0.serial ?? "") < ($1.name, $1.vendor, $1.product, $1.serial ?? "")
        }
        onDevices(devices)
    }

    private func handle(_ value: IOHIDValue) {
        guard state == .listening else { return }
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let id = endpoint(device)
        guard opened[id] != nil, let identity = endpoints[id]?.identity, identity == selectedDevice,
              !IOHIDElementIsRelative(element), IOHIDValueGetLength(value) <= MemoryLayout<CFIndex>.size else { return }

        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let raw = IOHIDValueGetIntegerValue(value)
        let lower = IOHIDElementGetLogicalMin(element)
        let upper = IOHIDElementGetLogicalMax(element)

        let isActive: Bool
        if page == 1 && usage == 0x39 { // D-pad hat: null values lie outside its logical range.
            isActive = (lower...max(lower, upper)).contains(raw)
        } else if page == 7 || page == 9 || page == 12 || (page == 1 && (0x80...0x93).contains(usage)) {
            guard usage != 0 else { return }
            isActive = raw != 0
        } else if page >= 0xFF00 && (lower == 0 && upper == 1) {
            isActive = raw == 1
        } else {
            return // Exclude pointer axes, sensors and vendor data streams.
        }

        let origin = RemoteInputOrigin(endpoint: id, cookie: Int(IOHIDElementGetCookie(element)))
        let changes = edges.changes(endpoint: id, cookie: origin.cookie, value: raw, isActive: isActive)
        guard !changes.isEmpty else { return }
        var top = element
        while let parent = IOHIDElementGetParent(top) { top = parent }
        func code(_ value: Int) -> InputCode {
            InputCode(collectionPage: Int(IOHIDElementGetUsagePage(top)),
                      collectionUsage: Int(IOHIDElementGetUsage(top)),
                      page: page, usage: usage, report: Int(IOHIDElementGetReportID(element)), value: value)
        }
        for change in changes {
            switch change {
            case let .pressed(value): onEvent(identity, .pressed(code(value), origin: origin))
            case let .released(value): onEvent(identity, .released(code(value), origin: origin))
            case let .replaced(value): onEvent(identity, .replaced(code(value), origin: origin))
            }
        }
    }
}
