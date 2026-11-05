@testable import RemoteDesk
import Testing

@Test @MainActor
func displayToggleRestoresBrightnessFirstAndRetriesAnUnreachableDisplay() async throws {
    var brightness: Float = 0.63
    var power: UInt8 = 1
    var wakeWorks = false
    var writes: [UInt8] = []
    let toggle = DisplayToggle(hardware: .init(
        hasBuiltIn: { true },
        readBrightness: { brightness },
        writeBrightness: { brightness = $0; return true },
        externalDisplays: {
            [.init(readPower: { power }, writePower: { value in
                writes.append(value)
                if value == 1 {
                    #expect(brightness == 0.63)
                    guard wakeWorks else { return false }
                }
                power = value
                return true
            })]
        }
    ))

    try await toggle.toggle()
    #expect(brightness == 0)
    #expect(power == 4)

    await #expect(throws: (any Error).self) { try await toggle.toggle() }
    #expect(brightness == 0.63)
    #expect(power == 4)

    wakeWorks = true
    try await toggle.toggle()
    #expect(power == 1)
    #expect(writes == [4, 1, 1, 1])
}

@Test @MainActor
func ignoredPowerOffReportsFailureAndLeavesRestoreAvailable() async throws {
    var brightness: Float = 0.45
    var writes: [UInt8] = []
    let toggle = DisplayToggle(hardware: .init(
        hasBuiltIn: { true },
        readBrightness: { brightness },
        writeBrightness: { brightness = $0; return true },
        externalDisplays: {
            [.init(readPower: { 1 }, writePower: { writes.append($0); return true })]
        }
    ))

    await #expect(throws: (any Error).self) { try await toggle.toggle() }
    #expect(brightness == 0)
    try await toggle.toggle()
    #expect(brightness == 0.45)
    #expect(writes == [4, 1])
}
