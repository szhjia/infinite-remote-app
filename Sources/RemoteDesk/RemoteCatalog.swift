import AppKit
import ImageIO
import RemoteCore
import UniformTypeIdentifiers

struct RemoteDefinition {
    static let xiaomiID = "xiaomi-2-pro"

    struct Manifest: Decodable {
        let version: Int
        let id: String
        let name: String
        let devices: [DeviceMatch]
        let front: String
        let capabilities: [Capability]
    }

    struct DeviceMatch: Decodable, Hashable {
        let vendor: Int
        let product: Int

        init(vendor: Int, product: Int) {
            self.vendor = vendor
            self.product = product
        }

        init(_ device: DeviceID) {
            self.init(vendor: device.vendor, product: device.product)
        }
    }

    struct Capability: Decodable, Identifiable {
        let id: String
        let name: String
        let symbol: String
        let description: String
    }

    struct Layout: Decodable {
        let width: Int
        let height: Int
        let visible: Bounds
        let keys: [RemoteKey]
        let anchors: [Anchor]

        var bodyRatio: CGFloat { CGFloat(visible.width) / CGFloat(visible.height) }

        struct Bounds: Decodable {
            let x: Int
            let y: Int
            let width: Int
            let height: Int

            var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        }

        struct Anchor: Decodable {
            let capability: String
            let shape: Hotspot
        }
    }

    struct InputRule: Decodable {
        let key: String
        let collectionPage: Int
        let collectionUsage: Int
        let page: Int
        let usage: Int
        let report: Int?
        let value: Int?
        let acceptsArray: Bool?

        func matches(_ input: InputCode) -> Bool {
            guard collectionPage == input.collectionPage, collectionUsage == input.collectionUsage,
                  page == input.page, report == nil || report == input.report else { return false }
            if acceptsArray == true, input.usage == Int(UInt32.max) { return input.value == usage }
            return usage == input.usage && (value.map { $0 == input.value } ?? (input.value != 0 || isHat))
        }

        var isHat: Bool { page == 1 && usage == 0x39 }

        func overlaps(_ other: Self) -> Bool {
            guard collectionPage == other.collectionPage, collectionUsage == other.collectionUsage,
                  page == other.page, usage == other.usage,
                  report == nil || other.report == nil || report == other.report else { return false }
            return value == nil || other.value == nil || value == other.value
                || (acceptsArray == true && other.acceptsArray == true)
        }
    }

    let manifest: Manifest
    let layout: Layout
    let inputs: [InputRule]
    let front: URL
    let artwork: NSImage

    var id: String { manifest.id }
    var actionSlots: Set<String> { Set(layout.keys.flatMap(\.actionSlots)) }

    func accepts(actions: [String: AgentAction]) -> Bool {
        actions.keys.allSatisfy(actionSlots.contains) && layout.keys.allSatisfy { key in
            let variants = [actions[key.doubleSlot], actions[key.holdSlot]]
            return !variants.contains(.dictation) && (actions[key.id] != .dictation || variants.allSatisfy { $0 == nil })
        }
    }
    func slot(for input: InputCode) -> String? { inputs.first { $0.matches(input) }?.key }

    static func read(_ folder: URL) throws -> Self {
        let directory = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else {
            throw RemotePackageError.invalid("型号包必须是本地文件夹。")
        }
        func file(_ name: String, maxBytes: Int) throws -> URL {
            guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\") else {
                throw RemotePackageError.invalid("资源必须是型号包中的文件名。")
            }
            let url = folder.appending(path: name, directoryHint: .notDirectory)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1...maxBytes).contains(size) else {
                throw RemotePackageError.invalid("文件无效或超过大小限制：\(name)")
            }
            return url
        }
        func decode<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
            let url = try file(name, maxBytes: 256 * 1024)
            do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
            catch { throw RemotePackageError.invalid("无法读取 \(name) 的格式。") }
        }
        let manifest = try decode("manifest.json", as: Manifest.self)
        guard manifest.version == 1, validID(manifest.id), !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.devices.isEmpty, Set(manifest.devices).count == manifest.devices.count,
              manifest.devices.allSatisfy({ (1...65535).contains($0.vendor) && (1...65535).contains($0.product) }),
              manifest.capabilities.allSatisfy({ validID($0.id) && !$0.name.isEmpty && !$0.description.isEmpty }),
              Set(manifest.capabilities.map(\.id)).count == manifest.capabilities.count else {
            throw RemotePackageError.invalid("型号、格式版本、设备标识或硬件能力无效。")
        }
        let layout = try decode("layout.json", as: Layout.self)
        let keyIDs = Set(layout.keys.map(\.id))
        let capabilities = Set(manifest.capabilities.map(\.id))
        let visible = layout.visible
        guard (1...4096).contains(layout.width), (1...4096).contains(layout.height),
              (0..<layout.width).contains(visible.x), (0..<layout.height).contains(visible.y),
              (1...(layout.width - visible.x)).contains(visible.width),
              (1...(layout.height - visible.y)).contains(visible.height),
              (1...128).contains(layout.keys.count), keyIDs.count == layout.keys.count,
              layout.keys.allSatisfy({
                  validID($0.id) && !$0.name.isEmpty && $0.shape.isInside(layout)
                      && $0.actionSlots.dropFirst().allSatisfy { !keyIDs.contains($0) }
              }),
              layout.anchors.allSatisfy({ capabilities.contains($0.capability) && $0.shape.isInside(layout) }),
              Set(layout.anchors.map(\.capability)).count == layout.anchors.count else {
            throw RemotePackageError.invalid("机身尺寸、按键或说明锚点无效。")
        }
        let inputs = try decode("inputs.json", as: [InputRule].self)
        guard inputs.count <= 512, inputs.allSatisfy({
            keyIDs.contains($0.key) && [$0.collectionPage, $0.collectionUsage, $0.page, $0.usage]
                .allSatisfy { (0...65535).contains($0) }
                && ($0.report.map { (0...255).contains($0) } ?? true)
                && ($0.value != 0 || $0.isHat)
                && ($0.acceptsArray != true || $0.usage != 0)
        }) else { throw RemotePackageError.invalid("输入规则引用了无效的按键或 HID 信号。") }
        for (index, input) in inputs.enumerated() {
            if inputs[..<index].contains(where: { $0.key != input.key && $0.overlaps(input) }) {
                throw RemotePackageError.invalid("同一 HID 信号不能指向多个按键。")
            }
        }

        let front = try file(manifest.front, maxBytes: 16 * 1024 * 1024)
        guard let image = CGImageSourceCreateWithURL(front as CFURL, nil),
              CGImageSourceGetType(image) as String? == UTType.png.identifier,
              CGImageSourceGetCount(image) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == layout.width,
              properties[kCGImagePropertyPixelHeight] as? Int == layout.height,
              let bitmap = CGImageSourceCreateImageAtIndex(image, 0, nil) else {
            throw RemotePackageError.invalid("机身图必须是尺寸与布局一致的 PNG。")
        }
        return Self(manifest: manifest, layout: layout, inputs: inputs, front: front,
                    artwork: NSImage(cgImage: bitmap, size: .zero))
    }

    private static func validID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil
    }
}

struct RemoteKey: Decodable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let shape: Hotspot
    let longPress: Bool?
    let doublePress: Bool?

    var holdSlot: String { id + "-long" }
    var doubleSlot: String { id + "-double" }
    var actionSlots: [String] {
        [id] + (doublePress == true ? [doubleSlot] : []) + (longPress == true ? [holdSlot] : [])
    }
}

struct Hotspot: Decodable {
    enum Kind: String, Decodable { case ellipse, rectangle, sector }
    let kind: Kind
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let angle: Double?
    let innerRatio: Double?

    func isInside(_ layout: RemoteDefinition.Layout) -> Bool {
        guard width > 0, height > 0,
              layout.visible.rect.contains(CGRect(x: (x - width / 2) * Double(layout.width),
                                                   y: (y - height / 2) * Double(layout.height),
                                                   width: width * Double(layout.width),
                                                   height: height * Double(layout.height))) else { return false }
        if kind == .sector {
            return (-360...360).contains(angle ?? .infinity) && (0..<1).contains(innerRatio ?? -1)
        }
        return true
    }
}

enum RemotePackageError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case let .invalid(message): message }
    }
}

struct RemoteCatalog {
    private(set) var models: [RemoteDefinition]
    let directory: URL

    var builtIn: RemoteDefinition { models[0] }

    init(directory: URL) {
        self.directory = directory
        let packaged = Bundle.main.url(forResource: "RemoteDesk_RemoteDesk", withExtension: "bundle")
            .flatMap(Bundle.init(url:))
        let folder = (packaged ?? .module).resourceURL!.appending(path: "RemoteModels/xiaomi-2-pro")
        do {
            models = [try RemoteDefinition.read(folder)]
        } catch {
            preconditionFailure("Invalid bundled remote definition: \(error.localizedDescription)")
        }
        let installed = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)) ?? []
        for folder in installed.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let model = try? RemoteDefinition.read(folder), model.id == folder.lastPathComponent,
                  (try? validateNew(model)) != nil else { continue }
            models.append(model)
        }
    }

    func model(for device: DeviceID) -> RemoteDefinition? {
        models.first { $0.manifest.devices.contains(.init(device)) }
    }

    mutating func install(_ source: URL) throws -> RemoteDefinition {
        let candidate = try RemoteDefinition.read(source)
        try validateNew(candidate)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for name in ["manifest.json", "layout.json", "inputs.json", candidate.manifest.front] {
            try files.copyItem(at: source.appending(path: name), to: staging.appending(path: name))
        }
        let verified = try RemoteDefinition.read(staging)
        guard verified.id == candidate.id, verified.manifest.front == candidate.manifest.front else {
            throw RemotePackageError.invalid("型号包在安装期间发生了更改。")
        }
        try validateNew(verified)
        let destination = directory.appending(path: verified.id, directoryHint: .isDirectory)
        try files.moveItem(at: staging, to: destination)
        let installed = RemoteDefinition(manifest: verified.manifest, layout: verified.layout, inputs: verified.inputs,
                                         front: destination.appending(path: verified.manifest.front), artwork: verified.artwork)
        models.append(installed)
        return installed
    }

    private func validateNew(_ model: RemoteDefinition) throws {
        guard !models.contains(where: { $0.id == model.id }) else {
            throw RemotePackageError.invalid("已安装相同型号 ID 的遥控器。")
        }
        let devices = Set(model.manifest.devices)
        guard !models.contains(where: { !devices.isDisjoint(with: $0.manifest.devices) }) else {
            throw RemotePackageError.invalid("设备标识与已安装的型号冲突。")
        }
    }
}
