import CoreGraphics
import Foundation
import IOKit

@MainActor
final class DisplayToggle {
    struct ExternalDisplay {
        let readPower: @MainActor () async -> UInt8?
        let writePower: @MainActor (UInt8) async -> Bool
    }

    struct Hardware {
        let hasBuiltIn: @MainActor () -> Bool
        let readBrightness: @MainActor () -> Float?
        let writeBrightness: @MainActor (Float) -> Bool
        let externalDisplays: @MainActor () -> [ExternalDisplay]
    }

    private struct DisplayFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = DisplayToggle(hardware: DisplayHardware.backend, defaults: .standard)
    private static let brightnessKey = "RemoteDesk.displayToggle.savedBrightness"
    private let hardware: Hardware
    private let defaults: UserDefaults?
    private var savedBrightness: Float? {
        didSet { defaults?.set(savedBrightness, forKey: Self.brightnessKey) }
    }
    private var pendingDisplays: [ExternalDisplay] = []
    private var isToggling = false

    var needsRestoreOnQuit: Bool {
        isToggling || savedBrightness != nil || !pendingDisplays.isEmpty
    }

    init(hardware: Hardware, defaults: UserDefaults? = nil) {
        self.hardware = hardware
        self.defaults = defaults
        savedBrightness = defaults?.object(forKey: Self.brightnessKey) as? Float
    }

    func toggle() async throws {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

        if savedBrightness != nil || !pendingDisplays.isEmpty {
            try await restore()
            return
        }

        let hasBuiltIn = hardware.hasBuiltIn()
        if hasBuiltIn {
            guard let brightness = hardware.readBrightness() else {
                throw DisplayFailure(message: "无法读取内置显示器亮度。")
            }
            savedBrightness = brightness
            guard hardware.writeBrightness(0) else {
                throw DisplayFailure(message: "无法调低内置显示器亮度。再按一次可尝试恢复。")
            }
        }

        var unconfirmed = 0
        for display in hardware.externalDisplays() {
            guard await display.readPower() == 1 else {
                unconfirmed += 1
                continue
            }
            // Keep the original channel even if the display stops responding after the write.
            pendingDisplays.append(display)
            let sent = await display.writePower(4)
            let state = await display.readPower()
            if !sent && state == 1 { pendingDisplays.removeLast() }
            if !sent || state != 4 { unconfirmed += 1 }
        }
        if unconfirmed > 0 {
            throw DisplayFailure(message: "\(unconfirmed) 台外接显示器未确认关闭。")
        }
        if !hasBuiltIn && pendingDisplays.isEmpty {
            throw DisplayFailure(message: "未找到可控制的显示器。")
        }
    }

    private func restore() async throws {
        if let brightness = savedBrightness, hardware.writeBrightness(brightness) {
            savedBrightness = nil
        }
        var unavailable: [ExternalDisplay] = []
        for display in pendingDisplays {
            _ = await display.writePower(1)
            if await display.readPower() != 1 {
                _ = await display.writePower(1)
                if await display.readPower() != 1 { unavailable.append(display) }
            }
        }
        pendingDisplays = unavailable
        if savedBrightness != nil || !unavailable.isEmpty {
            let brightness = savedBrightness == nil ? [] : ["内置显示器亮度"]
            let displays = unavailable.isEmpty ? [] : ["\(unavailable.count) 台外接显示器"]
            throw DisplayFailure(message: "未能确认恢复\((brightness + displays).joined(separator: "、"))，可再按一次重试。")
        }
    }

    func restoreOnQuit() async {
        while isToggling { try? await Task.sleep(for: .milliseconds(50)) }
        isToggling = true
        defer { isToggling = false }
        try? await restore()
    }
}

@MainActor
private enum DisplayHardware {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let displayServices = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    )
    private static let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    static let backend = DisplayToggle.Hardware(
        hasBuiltIn: { builtInDisplay() != nil },
        readBrightness: {
            guard let id = builtInDisplay(), let displayServices,
                  let symbol = dlsym(displayServices, "DisplayServicesGetBrightness") else { return nil }
            var value: Float = 0
            let get = unsafeBitCast(symbol, to: GetBrightness.self)
            return get(id, &value) == 0 && (0...1).contains(value) ? value : nil
        },
        writeBrightness: { value in
            guard let id = builtInDisplay(), let displayServices,
                  let symbol = dlsym(displayServices, "DisplayServicesSetBrightness") else { return false }
            return unsafeBitCast(symbol, to: SetBrightness.self)(id, value) == 0
        },
        externalDisplays: externalDisplays
    )

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func externalDisplays() -> [DisplayToggle.ExternalDisplay] {
        guard let ioKit,
              let createSymbol = dlsym(ioKit, "IOAVServiceCreateWithService"),
              let readSymbol = dlsym(ioKit, "IOAVServiceReadI2C"),
              let writeSymbol = dlsym(ioKit, "IOAVServiceWriteI2C") else { return [] }
        let create = unsafeBitCast(createSymbol, to: CreateService.self)
        let read = unsafeBitCast(readSymbol, to: I2C.self)
        let write = unsafeBitCast(writeSymbol, to: I2C.self)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var displays: [DisplayToggle.ExternalDisplay] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)
            guard location?.takeRetainedValue() as? String == "External",
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            displays.append(.init(
                readPower: {
                    let request: [UInt8] = [0x82, 0x01, 0xD6]
                    for _ in 0..<3 {
                        guard await send(request, via: write, service: service),
                              await send(request, via: write, service: service, delay: 10) else { continue }
                        try? await Task.sleep(for: .milliseconds(10))
                        var reply = [UInt8](repeating: 0, count: 12)
                        let status = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, 12) }
                        // Some displays return the host address in the length byte
                        // but calculate their checksum with the standard reply length.
                        if reply[1] == 0x51 { reply[1] = 0x88 }
                        if status == KERN_SUCCESS, reply[1] == 0x88, reply[2] == 0x02,
                           reply[3] == 0, reply[4] == 0xD6, reply[8] == 0,
                           reply.prefix(11).reduce(0x50, ^) == 0 {
                            return reply[9]
                        }
                    }
                    return nil
                },
                writePower: { value in
                    let sent = await send([0x84, 0x03, 0xD6, 0, value], via: write, service: service)
                    try? await Task.sleep(for: .milliseconds(value == 1 ? 800 : 500))
                    return sent
                }
            ))
        }
        return displays
    }

    private static func send(_ payload: [UInt8], via write: I2C, service: CFTypeRef,
                             delay: Int = 50) async -> Bool {
        // IOAVService handles the DDC source byte separately.
        let seed: UInt8 = payload[1] == 0x03 ? (0x6E ^ 0x51) : 0x6E
        var packet = payload + [payload.reduce(seed, ^)]
        try? await Task.sleep(for: .milliseconds(delay))
        return packet.withUnsafeMutableBytes {
            write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) == KERN_SUCCESS
        }
    }
}
