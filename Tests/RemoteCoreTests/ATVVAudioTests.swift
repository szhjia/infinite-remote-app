import Foundation
import RemoteCore
import Testing

@Test
func rc003AcceptsBothObservedCapabilitiesLayouts() {
    #expect(ATVVAudio.frameLength([0x0B, 1, 0, 2, 3, 0, 120, 0, 0]) == 120)
    #expect(ATVVAudio.frameLength([0x0B, 1, 0, 0, 3, 0, 120, 0, 0]) == 120)
    #expect(ATVVAudio.frameLength([0x0B, 1, 0, 1, 3, 0, 120, 0, 0]) == nil)
    #expect(ATVVAudio.frameLength([0x0B, 1, 0, 2, 3, 0, 0]) == nil)
}

@Test
func rc003DecodesHighNibbleFirstAndMaintainsStateAcrossFrames() {
    var decoder = ATVVAudio()
    let didSync = decoder.sync([0x0A, 0, 0, 0, 0xFF, 0xF8, 0])
    #expect(didSync)
    #expect(decoder.decode(Data([0x71])) == [3, 9])
    #expect(decoder.decode(Data([0xB0])) == [-2, -1])
    let didAcceptInvalidIndex = decoder.sync([0x0A, 0, 0, 0, 0, 0, 89])
    #expect(!didAcceptInvalidIndex)
}
