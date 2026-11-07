import Foundation

public struct ATVVAudio: Sendable {
    public init() {}

    public static func frameLength(_ caps: [UInt8]) -> Int? {
        guard caps.count >= 7, Array(caps.prefix(3)) == [0x0B, 1, 0] else { return nil }
        let codec = caps[3] == 0 && caps[4] <= 3 ? caps[4] : caps[3]
        let size = Int(caps[5]) << 8 | Int(caps[6])
        return codec & 2 != 0 && size == 120 ? size : nil
    }

    private static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50,
        55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253,
        279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
        1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
        13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    private static let indexChange = [-1, -1, -1, -1, 2, 4, 6, 8]
    private var predictor = 0
    private var index = 0

    public mutating func sync(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 7, bytes[0] == 0x0A, bytes[6] <= 88 else { return false }
        predictor = Int(Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5])))
        index = Int(bytes[6])
        return true
    }

    public mutating func decode(_ bytes: Data) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            samples.append(sample(Int(byte >> 4)))
            samples.append(sample(Int(byte & 15)))
        }
        return samples
    }

    private mutating func sample(_ nibble: Int) -> Int16 {
        let step = Self.steps[index]
        var delta = step >> 3
        if nibble & 4 != 0 { delta += step }
        if nibble & 2 != 0 { delta += step >> 1 }
        if nibble & 1 != 0 { delta += step >> 2 }
        predictor = min(32767, max(-32768, predictor + (nibble & 8 == 0 ? delta : -delta)))
        index = min(88, max(0, index + Self.indexChange[nibble & 7]))
        return Int16(predictor)
    }

}
