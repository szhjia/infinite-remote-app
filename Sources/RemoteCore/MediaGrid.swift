public struct MediaGrid: Sendable {
    public static let limit = 9
    public enum Direction: Sendable { case left, right, up, down }

    public let count: Int
    private let singleRow: Bool

    public init(count: Int, singleRow: Bool = false) {
        self.count = min(max(count, 0), Self.limit)
        self.singleRow = singleRow
    }

    public var columns: Int {
        if singleRow { return max(1, count) }
        return switch count {
        case 0...2: max(count, 1)
        case 4: 2
        default: 3
        }
    }

    public var rows: Int {
        if singleRow { return count == 0 ? 0 : 1 }
        return switch count {
        case 0: 0
        case 1...2: 1
        case 3...6: 2
        default: 3
        }
    }

    public func move(from index: Int, toward direction: Direction) -> Int {
        guard (0..<count).contains(index) else { return index }
        let column = index % columns
        let next: Int
        switch direction {
        case .left: next = column > 0 ? index - 1 : index
        case .right: next = column < columns - 1 ? index + 1 : index
        case .up: next = index - columns
        case .down: next = index + columns
        }
        return (0..<count).contains(next) ? next : index
    }
}
