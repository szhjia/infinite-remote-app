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
    var selectedBluetoothIdentifier: UUID? { get }
    var wantsExclusiveKeyboard: Bool { get set }
    var preservesNativeF5: Bool { get set }
    var onKeyboardCapture: (Bool) -> Void { get set }
    func captures(_ input: InputCode, from origin: RemoteInputOrigin?) -> Bool
    func refresh() -> InputMonitorState
}

extension RemoteInputSource {
    var selectedBluetoothIdentifier: UUID? { nil }
    var wantsExclusiveKeyboard: Bool { get { false } set {} }
    var preservesNativeF5: Bool { get { false } set {} }
    var onKeyboardCapture: (Bool) -> Void { get { { _ in } } set {} }
    func captures(_ input: InputCode, from origin: RemoteInputOrigin?) -> Bool { false }
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
    var onKeyboardCapture: (Bool) -> Void = { _ in }
    var wantsExclusiveKeyboard = false {
        didSet {
            if oldValue != wantsExclusiveKeyboard { updateListening() }
        }
    }
    var preservesNativeF5 = false {
        didSet {
            if oldValue != preservesNativeF5, heldF5.isEmpty { updateListening() }
        }
    }
    var selectedDevice: DeviceID? {
        didSet {
            guard oldValue != selectedDevice else { return }
            edges = .init()
            heldF5.removeAll()
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
    private var exclusiveEndpoints: Set<UInt64> = []
    private var attemptedExclusive: Set<UInt64> = []
    private let keyMap: RemoteKeyboardMap
    private var mappedKeyboard: UInt64?
    private var heldF5: Set<RemoteInputOrigin> = []
    private var passesNativeF5 = false
    private var edges = InputEdges<UInt64>()

    init(recoveryURL: URL) {
        keyMap = RemoteKeyboardMap(recoveryURL: recoveryURL)
    }

    var selectedBluetoothIdentifier: UUID? {
        guard let selectedDevice, !ambiguousDevices.contains(selectedDevice) else { return nil }
        let identifiers = Set(endpoints.values.compactMap { endpoint -> UUID? in
            guard endpoint.identity == selectedDevice,
                  let value = IOHIDDeviceGetProperty(endpoint.device, kIOHIDPhysicalDeviceUniqueIDKey as CFString) as? String
            else { return nil }
            return UUID(uuidString: value)
        })
        return identifiers.count == 1 ? identifiers.first : nil
    }

    func refresh() -> InputMonitorState {
        hasPermission = CGPreflightListenEventAccess()
        if manager == nil { startDiscovery() }
        updateListening()
        return state
    }

    func captures(_ input: InputCode, from origin: RemoteInputOrigin?) -> Bool {
        guard let origin else { return false }
        if exclusiveEndpoints.contains(origin.endpoint) { return true }
        guard mappedKeyboard == origin.endpoint,
              RemoteKeyboardMap.covers(input, preservingNativeF5: passesNativeF5),
              let location = endpoints[origin.endpoint]?.location else { return false }
        if keyMap.isActive(at: UInt32(truncatingIfNeeded: location)) { return true }
        mappedKeyboard = nil
        onKeyboardCapture(false)
        return false
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
        // Keep the same delivery path for both edges of a physical F5 press.
        if heldF5.isEmpty { passesNativeF5 = preservesNativeF5 }
        let ambiguous = selectedDevice.map(ambiguousDevices.contains) ?? false
        let selected = hasPermission && !ambiguous ? endpoints.filter { $0.value.identity == selectedDevice } : [:]
        // Only try seizure for the keyboard services of the known 2 Pro, never for
        // the system keyboard, another paired device, or an unidentified service.
        let keyboard = Set(selected.compactMap { id, entry in
            entry.identity.vendor == 0x2717 && entry.identity.product == 0x32B8
                && IOHIDDeviceConformsTo(entry.device, 1, 6) ? id : nil
        })
        let requested = wantsExclusiveKeyboard ? keyboard : []
        let seizable = passesNativeF5 ? Set<UInt64>() : requested
        attemptedExclusive.formIntersection(requested)
        if passesNativeF5 { attemptedExclusive.subtract(exclusiveEndpoints) }
        for id in opened.keys.filter({
            selected[$0] == nil || exclusiveEndpoints.contains($0) && !seizable.contains($0)
                || seizable.contains($0) && !attemptedExclusive.contains($0)
        }) {
            closeEndpoint(id)
        }
        defer { updateKeyboardMap(requested: requested) }
        if ambiguous {
            state = .ambiguous
            return
        }
        guard hasPermission else {
            state = .permission
            return
        }

        var firstFailure: IOReturn?
        for (id, entry) in selected where opened[id] == nil {
            let device = entry.device
            var result = kIOReturnError
            if seizable.contains(id), attemptedExclusive.insert(id).inserted {
                result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                if result == kIOReturnSuccess { exclusiveEndpoints.insert(id) }
            }
            if result != kIOReturnSuccess {
                result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
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
        if !exclusiveEndpoints.isEmpty && !keyboard.isSubset(of: exclusiveEndpoints) {
            // A partial grab can still deliver the same physical press through a
            // second service. Restore pass-through on the whole keyboard group.
            for id in Array(exclusiveEndpoints) { closeEndpoint(id) }
            attemptedExclusive.formUnion(keyboard)
            updateListening()
            return
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

    private func updateKeyboardMap(requested: Set<UInt64>) {
        let seized = !requested.isEmpty && requested.isSubset(of: exclusiveEndpoints)
        mappedKeyboard = nil
        if !seized, requested.count == 1, let id = requested.first, opened[id] != nil,
           let location = endpoints[id]?.location,
           keyMap.capture(at: UInt32(truncatingIfNeeded: location), preservingNativeF5: passesNativeF5) {
            mappedKeyboard = id
        } else {
            keyMap.restore()
        }
        onKeyboardCapture(seized || mappedKeyboard != nil)
    }

    private func closeEndpoint(_ id: UInt64) {
        guard let device = opened.removeValue(forKey: id) else { return }
        let exclusive = exclusiveEndpoints.remove(id) != nil
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(exclusive ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        edges.remove(endpoint: id)
        heldF5 = heldF5.filter { $0.endpoint != id }
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
        let identity = DeviceID(vendor: vendor, product: product, name: name ?? L10n.tr("未命名蓝牙设备"),
                                serial: serial?.isEmpty == false ? serial : nil)
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
            case let .pressed(value):
                let input = code(value)
                if input.isKeyboardF5 { heldF5.insert(origin) }
                onEvent(identity, .pressed(input, origin: origin))
            case let .released(value):
                heldF5.remove(origin)
                onEvent(identity, .released(code(value), origin: origin))
            case let .replaced(value):
                heldF5.remove(origin)
                onEvent(identity, .replaced(code(value), origin: origin))
            }
        }
        if heldF5.isEmpty, preservesNativeF5 != passesNativeF5 {
            Task { [weak self] in
                guard let self, heldF5.isEmpty, preservesNativeF5 != passesNativeF5 else { return }
                updateListening()
            }
        }
    }
}
