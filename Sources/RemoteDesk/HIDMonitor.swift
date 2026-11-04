import AppKit
import CoreGraphics
import IOKit.hid
import RemoteCore

enum InputMonitorState: Equatable {
    case permission
    case listening
    case failed(Int32)
}

@MainActor
protocol RemoteInputSource: AnyObject {
    var onDevices: ([DeviceID]) -> Void { get set }
    var onPress: (DeviceID, InputCode) -> Void { get set }
    var selectedDevice: DeviceID? { get set }
    func refresh() -> InputMonitorState
}

@MainActor
final class HIDMonitor: RemoteInputSource {
    var onDevices: ([DeviceID]) -> Void = { _ in }
    var onPress: (DeviceID, InputCode) -> Void = { _, _ in }
    var selectedDevice: DeviceID? {
        didSet { if oldValue != selectedDevice { edges = .init() } }
    }
    private let transports = [kIOHIDTransportBluetoothValue, kIOHIDTransportBluetoothLowEnergyValue, "Bluetooth Low Energy"]
    private var manager: IOHIDManager?
    private var state: InputMonitorState = .permission
    private var endpoints: [UInt64: DeviceID] = [:]
    private var edges = InputEdges<UInt64>()

    func refresh() -> InputMonitorState {
        let hasPermission = CGPreflightListenEventAccess()
        let desiredState: InputMonitorState = hasPermission ? .listening : .permission
        if manager != nil && state == desiredState {
            return state
        }
        stop()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
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
        state = .permission
        if hasPermission {
            IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
                guard result == kIOReturnSuccess, let context else { return }
                let owner = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.handle(value) }
            }, context)
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            state = result == kIOReturnSuccess ? .listening : .failed(result)
        }
        self.manager = manager
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices { attach(device, publish: false) }
        }
        publishDevices()
        return state
    }

    private func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if state != .permission { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        self.manager = nil
        endpoints.removeAll()
        edges = .init()
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
        let previous = endpoints.updateValue(identity, forKey: endpoint(device))
        if publish && previous != identity { publishDevices() }
    }

    private func detach(_ device: IOHIDDevice) {
        let id = endpoint(device)
        edges.remove(endpoint: id)
        if endpoints.removeValue(forKey: id) != nil { publishDevices() }
    }

    private func publishDevices() {
        let devices = Set(endpoints.values).sorted {
            ($0.name, $0.vendor, $0.product, $0.serial ?? "") < ($1.name, $1.vendor, $1.product, $1.serial ?? "")
        }
        onDevices(devices)
    }

    private func handle(_ value: IOHIDValue) {
        guard state == .listening else { return }
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let id = endpoint(device)
        guard let identity = endpoints[id], identity == selectedDevice,
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

        guard edges.press(endpoint: id, cookie: Int(IOHIDElementGetCookie(element)), value: raw, isActive: isActive) else { return }
        var top = element
        while let parent = IOHIDElementGetParent(top) { top = parent }

        onPress(identity, InputCode(collectionPage: Int(IOHIDElementGetUsagePage(top)),
                                    collectionUsage: Int(IOHIDElementGetUsage(top)),
                                    page: page, usage: usage, report: Int(IOHIDElementGetReportID(element)), value: raw))
    }
}
