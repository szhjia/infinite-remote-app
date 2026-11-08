import AppKit
import Darwin
import ImageIO
import RemoteCore
import UniformTypeIdentifiers

struct RemoteDefinition {
    static let xiaomiID = "xiaomi-2-pro"

    struct Manifest: Decodable {
        let version: Int
        let id: String
        let localizedName: LocalizedText
        let release: String
        let localizedSummary: LocalizedText?
        let brand: RemoteBrand?
        let devices: [DeviceMatch]
        let front: String
        let capabilities: [Capability]
        let defaults: [String: AgentAction]
        let retiredGestureSlots: [String]
        let behavior: RemoteBehavior
        let target: AppTarget?
        var name: String { localizedName.resolve() }

        private enum CodingKeys: String, CodingKey {
            case version, id, name, release, summary, brand, devices, front, capabilities, defaults, retiredGestureSlots, behavior, target
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            id = try c.decode(String.self, forKey: .id)
            localizedName = try c.decode(LocalizedText.self, forKey: .name)
            release = try c.decodeIfPresent(String.self, forKey: .release) ?? (version == 1 ? "0.0.0" : "")
            localizedSummary = try c.decodeIfPresent(LocalizedText.self, forKey: .summary)
            brand = try c.decodeIfPresent(RemoteBrand.self, forKey: .brand)
            devices = try c.decode([DeviceMatch].self, forKey: .devices)
            front = try c.decode(String.self, forKey: .front)
            capabilities = try c.decodeIfPresent([Capability].self, forKey: .capabilities) ?? []
            let declaredDefaults = try c.decodeIfPresent([String: AgentAction].self, forKey: .defaults)
            let declaredBehavior = try c.decodeIfPresent(RemoteBehavior.self, forKey: .behavior)
            let declaredTarget = try c.decodeIfPresent(AppTarget.self, forKey: .target)
            defaults = version == 1 ? LegacyRemoteCompatibility.defaults(id: id, declared: declaredDefaults) : declaredDefaults ?? [:]
            retiredGestureSlots = try c.decodeIfPresent([String].self, forKey: .retiredGestureSlots) ?? []
            behavior = version == 1 ? LegacyRemoteCompatibility.behavior(id: id, declared: declaredBehavior) : declaredBehavior ?? .empty
            target = version == 1 ? LegacyRemoteCompatibility.target(id: id, declared: declaredTarget) : declaredTarget
        }

        fileprivate init() {
            version = 2; id = ""; localizedName = LocalizedText(""); release = "0.0.0"
            localizedSummary = nil; brand = nil; devices = []; front = ""; capabilities = []
            defaults = [:]; retiredGestureSlots = []; behavior = .empty; target = nil
        }
    }

    struct DeviceMatch: Codable, Hashable {
        let vendor: Int
        let product: Int
        init(vendor: Int, product: Int) { self.vendor = vendor; self.product = product }
        init(_ device: DeviceID) { self.init(vendor: device.vendor, product: device.product) }
    }

    struct Capability: Decodable, Identifiable {
        let id: String
        let localizedName: LocalizedText
        let symbol: String
        let localizedDescription: LocalizedText
        let localizedStatus: LocalizedText?
        var name: String { localizedName.resolve() }
        var description: String { localizedDescription.resolve() }
        var status: String? { localizedStatus?.resolve() }
        var statusText: String { localizedStatus?.resolve() ?? L10n.tr("硬件具备") }
        private enum CodingKeys: String, CodingKey {
            case id, localizedName = "name", symbol, localizedDescription = "description", localizedStatus = "status"
        }
    }

    enum AnnotationSide: String, Decodable {
        case leading, trailing
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
            let annotationSide: AnnotationSide?
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
    var logo: NSImage? = nil

    static var empty: Self {
        Self(manifest: Manifest(), layout: Layout(width: 1, height: 1,
             visible: .init(x: 0, y: 0, width: 1, height: 1), keys: [], anchors: []),
             inputs: [], front: URL(fileURLWithPath: "/"), artwork: NSImage(size: NSSize(width: 1, height: 1)))
    }

    var id: String { manifest.id }
    var actionSlots: Set<String> { Set(layout.keys.flatMap(\.actionSlots)) }

    func accepts(actions: [String: AgentAction]) -> Bool {
        actions.keys.allSatisfy(actionSlots.contains)
            && !actions.values.contains(where: \.isRemovedVoiceBinding)
            && layout.keys.allSatisfy { key in
            let variants = [actions[key.doubleSlot], actions[key.holdSlot]].compactMap { $0 }
            guard !variants.contains(where: \.isVoiceTrigger) else { return false }
            guard let primary = actions[key.id], primary.isVoiceTrigger else { return true }
            if case let .voiceShortcut(_, shortcut) = primary, !shortcut.isVoiceCombination { return false }
            return variants.isEmpty
        }
    }
    func slot(for input: InputCode) -> String? { inputs.first { $0.matches(input) }?.key }

    func coalescedSlot(for input: InputCode) -> String? {
        guard let rule = inputs.first(where: { $0.matches(input) }) else { return nil }
        if manifest.behavior.coalescedKeys.contains(rule.key) { return rule.key }
        // macOS can expose a keyboard array and its per-key element for the
        // same arrow press. Only merge arrows whose rule accepts both forms.
        guard rule.acceptsArray == true, let usage = input.keyboardUsage,
              (0x4F...0x52).contains(usage) else { return nil }
        return rule.key
    }

    static func read(_ folder: URL) throws -> Self {
        let directory = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else {
            throw RemotePackageError.invalid(L10n.tr("型号包必须是本地文件夹。"))
        }
        func file(_ name: String, maxBytes: Int) throws -> URL {
            guard validPackageFilename(name) else {
                throw RemotePackageError.invalid(L10n.tr("资源必须是型号包中的文件名。"))
            }
            let url = folder.appending(path: name, directoryHint: .notDirectory)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1...maxBytes).contains(size) else {
                throw RemotePackageError.invalid(L10n.format("文件无效或超过大小限制：%@", String(describing: name)))
            }
            return url
        }
        func decode<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
            let url = try file(name, maxBytes: 256 * 1024)
            do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
            catch { throw RemotePackageError.invalid(L10n.format("无法读取 %@ 的格式。", String(describing: name))) }
        }
        let manifest = try decode("manifest.json", as: Manifest.self)
        guard [1, 2].contains(manifest.version), validPackageID(manifest.id), manifest.localizedName.isValid,
              !manifest.devices.isEmpty, Set(manifest.devices).count == manifest.devices.count,
              manifest.devices.allSatisfy({ (1...65535).contains($0.vendor) && (1...65535).contains($0.product) }),
              manifest.capabilities.allSatisfy({
                  validPackageID($0.id) && $0.localizedName.isValid && $0.localizedDescription.isValid
                      && ($0.localizedStatus?.isValid ?? true) && !$0.symbol.isEmpty
              }), Set(manifest.capabilities.map(\.id)).count == manifest.capabilities.count else {
            throw RemotePackageError.invalid(L10n.tr("型号、协议版本、设备标识或硬件能力无效。"))
        }
        _ = try PackageVersion(manifest.release)
        if manifest.version == 2 {
            guard !manifest.localizedName.isLegacy, let summary = manifest.localizedSummary, summary.isValid, !summary.isLegacy,
                  let brand = manifest.brand, validPackageID(brand.id), brand.name.isValid, !brand.name.isLegacy,
                  manifest.capabilities.allSatisfy({ !$0.localizedName.isLegacy && !$0.localizedDescription.isLegacy
                      && ($0.localizedStatus.map { !$0.isLegacy } ?? true) }) else {
                throw RemotePackageError.invalid(L10n.tr("第 2 版资源包必须包含名称、简介和品牌的本地化文本及英语回退文本。"))
            }
        }
        if let brand = manifest.brand {
            guard validPackageID(brand.id), brand.name.isValid else { throw RemotePackageError.invalid(L10n.tr("品牌信息无效。")) }
        }
        if let target = manifest.target {
            guard target.path == nil, target.bundleID.count <= 255,
                  target.bundleID.range(of: "\\A[A-Za-z0-9][A-Za-z0-9.-]+\\z", options: .regularExpression) != nil else {
                throw RemotePackageError.invalid(L10n.tr("资源包中的目标应用必须使用应用标识符。"))
            }
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
                  validPackageID($0.id) && $0.localizedName.isValid
                      && (manifest.version == 1 || !$0.localizedName.isLegacy) && $0.shape.isInside(layout)
                      && $0.actionSlots.dropFirst().allSatisfy { !keyIDs.contains($0) }
              }),
              layout.anchors.allSatisfy({ capabilities.contains($0.capability) && $0.shape.isInside(layout) }),
              Set(layout.anchors.map(\.capability)).count == layout.anchors.count else {
            throw RemotePackageError.invalid(L10n.tr("机身尺寸、按键或说明锚点无效。"))
        }
        let slots = Set(layout.keys.flatMap(\.actionSlots))
        let retired = Set(manifest.retiredGestureSlots)
        let possibleGestures = Set(layout.keys.flatMap { [$0.doubleSlot, $0.holdSlot] })
        guard retired.count == manifest.retiredGestureSlots.count,
              retired.isSubset(of: possibleGestures), retired.isDisjoint(with: slots) else {
            throw RemotePackageError.invalid(L10n.tr("停用的手势槽位无效。"))
        }
        guard manifest.defaults.keys.allSatisfy(slots.contains), manifest.defaults.values.allSatisfy({ $0.validPackageDefault(protocolVersion: manifest.version) }),
              manifest.behavior.isValid(keys: keyIDs), layout.keys.allSatisfy({ key in
                  let variants = [manifest.defaults[key.doubleSlot], manifest.defaults[key.holdSlot]]
                  return !variants.contains(.dictation) && (manifest.defaults[key.id] != .dictation || variants.allSatisfy { $0 == nil })
              }) else { throw RemotePackageError.invalid(L10n.tr("默认动作槽位、动作内容或行为按键无效。")) }
        let inputs = try decode("inputs.json", as: [InputRule].self)
        guard inputs.count <= 512, inputs.allSatisfy({
            keyIDs.contains($0.key) && [$0.collectionPage, $0.collectionUsage, $0.page, $0.usage]
                .allSatisfy { (0...65535).contains($0) }
                && ($0.report.map { (0...255).contains($0) } ?? true)
                && ($0.value != 0 || $0.isHat)
                && ($0.acceptsArray != true || $0.usage != 0)
        }) else { throw RemotePackageError.invalid(L10n.tr("输入规则引用了无效的按键或 HID 信号。")) }
        for (index, input) in inputs.enumerated() {
            if inputs[..<index].contains(where: { $0.key != input.key && $0.overlaps(input) }) {
                throw RemotePackageError.invalid(L10n.tr("同一 HID 信号不能指向多个按键。"))
            }
        }

        let front = try file(manifest.front, maxBytes: 16 * 1024 * 1024)
        // Images outlive the install staging directory. Own their bytes and eagerly
        // decode before atomic moves; SwiftUI must never resolve a deleted URL.
        guard let image = CGImageSourceCreateWithData(try Data(contentsOf: front) as CFData, nil),
              CGImageSourceGetType(image) as String? == UTType.png.identifier,
              CGImageSourceGetCount(image) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == layout.width,
              properties[kCGImagePropertyPixelHeight] as? Int == layout.height,
              let bitmap = CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw RemotePackageError.invalid(L10n.tr("机身图必须是尺寸与布局一致的 PNG。"))
        }
        var logo: NSImage?
        if let name = manifest.brand?.logo {
            let url = try file(name, maxBytes: 4 * 1024 * 1024)
            guard let source = CGImageSourceCreateWithData(try Data(contentsOf: url) as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...2048).contains(width),
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...2048).contains(height),
                  let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw RemotePackageError.invalid(L10n.tr("品牌标识必须是单张 PNG，每边不得超过 2048 像素。"))
            }
            logo = NSImage(cgImage: bitmap, size: .zero)
        }
        return Self(manifest: manifest, layout: layout, inputs: inputs, front: front,
                    artwork: NSImage(cgImage: bitmap, size: .zero), logo: logo)
    }
}

struct RemoteKey: Decodable, Identifiable {
    let id: String
    let localizedName: LocalizedText
    var name: String { localizedName.resolve() }
    let symbol: String
    let shape: Hotspot
    let longPress: Bool?
    let doublePress: Bool?
    let annotationSide: RemoteDefinition.AnnotationSide?

    private enum CodingKeys: String, CodingKey {
        case id, localizedName = "name", symbol, shape, longPress, doublePress, annotationSide
    }

    init(id: String, name: String, symbol: String, shape: Hotspot, longPress: Bool?, doublePress: Bool?,
         annotationSide: RemoteDefinition.AnnotationSide?) {
        self.id = id; localizedName = LocalizedText(name); self.symbol = symbol; self.shape = shape
        self.longPress = longPress; self.doublePress = doublePress; self.annotationSide = annotationSide
    }

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
    private(set) var models: [RemoteDefinition] = []
    private(set) var loadIssues: [String] = []
    private var owners: [String: String] = [:]
    let directory: URL

    private struct Installation: Codable {
        let modelID: String
        let sourceID: String
        let release: String
    }

    init(directory: URL) {
        self.directory = directory
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return }
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw RemotePackageError.invalid(L10n.tr("已安装型号的存储位置不是普通文件夹。"))
            }
            let installed = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for folder in installed.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let model = try RemoteDefinition.read(folder)
                    guard model.id == folder.lastPathComponent else { throw RemotePackageError.invalid(L10n.tr("安装文件夹与型号标识不匹配。")) }
                    try validateDeviceConflicts(model)
                    let metadata = folder.appending(path: ".installation.json")
                    let owner: String
                    if files.fileExists(atPath: metadata.path) {
                        let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4096 else {
                            throw RemotePackageError.invalid(L10n.tr("安装元数据无效。"))
                        }
                        let installed = try JSONDecoder().decode(Installation.self, from: Data(contentsOf: metadata))
                        guard installed.modelID == model.id, installed.release == model.manifest.release, !installed.sourceID.isEmpty else {
                            throw RemotePackageError.invalid(L10n.tr("安装来源或版本不匹配。"))
                        }
                        owner = installed.sourceID
                    } else { owner = "local" } // pre-v2 local folder installations
                    models.append(model)
                    owners[model.id] = owner
                } catch { loadIssues.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
            }
        } catch { loadIssues.append(error.localizedDescription) }
    }

    func model(for device: DeviceID) -> RemoteDefinition? {
        models.first { $0.manifest.devices.contains(.init(device)) }
    }

    func owner(of modelID: String) -> String? { owners[modelID] }

    mutating func install(_ source: URL, sourceID: String? = nil,
                          configuredSlotsByModel: [String: Set<String>]? = nil) throws -> RemoteDefinition {
        let owner = sourceID ?? "local"
        guard !owner.isEmpty, owner.count <= 1024 else { throw RemotePackageError.invalid(L10n.tr("资源包来源标识无效。")) }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard storage.isDirectory == true, storage.isSymbolicLink != true else {
            throw RemotePackageError.invalid(L10n.tr("已安装型号的存储位置不是普通文件夹。"))
        }
        let transaction = directory.appending(path: ".install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: transaction) }
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard sourceValues.isSymbolicLink != true else { throw RemotePackageError.invalid(L10n.tr("资源包不支持链接文件。")) }
        let package: URL
        if sourceValues.isDirectory == true { package = source }
        else if sourceValues.isRegularFile == true {
            package = try PackageArchive.extract(source, to: transaction.appending(path: "archive", directoryHint: .isDirectory))
        } else { throw RemotePackageError.invalid(L10n.tr("请导入型号文件夹或 ZIP 资源包。")) }
        // Copy only regular, package-local files to an isolated snapshot. Supplied ownership metadata is ignored.
        let staged = transaction.appending(path: "candidate", directoryHint: .isDirectory)
        try files.createDirectory(at: staged, withIntermediateDirectories: false)
        let entries = try files.contentsOfDirectory(at: package, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard entries.count <= 256 else { throw RemotePackageError.invalid(L10n.tr("资源包中的文件过多。")) }
        var total = 0
        var names = Set<String>()
        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".installation.json" { continue }
            let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard validPackageFilename(name), names.insert(normalized).inserted,
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1...16 * 1024 * 1024).contains(size) else {
                throw RemotePackageError.invalid(L10n.tr("资源包包含无效文件或链接。"))
            }
            total += size
            guard total <= 64 * 1024 * 1024 else { throw RemotePackageError.invalid(L10n.tr("解压后的资源包超过大小限制。")) }
            let data = try Data(contentsOf: entry, options: [.mappedIfSafe])
            guard data.count == size else { throw RemotePackageError.invalid(L10n.tr("资源包在复制期间发生了更改。")) }
            try data.write(to: staged.appending(path: name), options: .atomic)
        }
        let candidate = try RemoteDefinition.read(staged)
        if sourceValues.isRegularFile == true, package.lastPathComponent != candidate.id {
            throw RemotePackageError.invalid(L10n.tr("安装文件夹与型号标识不匹配。"))
        }
        try validateDeviceConflicts(candidate)
        let existing = models.first { $0.id == candidate.id }
        if let existing {
            guard owners[candidate.id] == owner else { throw RemotePackageError.invalid(L10n.tr("此型号属于其他来源。")) }
            guard try PackageVersion(candidate.manifest.release) > PackageVersion(existing.manifest.release) else {
                throw RemotePackageError.invalid(L10n.tr("更新资源包的版本必须高于已安装版本。"))
            }
            let removed = existing.actionSlots.subtracting(candidate.actionSlots)
            guard removed.isSubset(of: candidate.manifest.retiredGestureSlots) else {
                throw RemotePackageError.invalid(L10n.tr("此更新移除了现有动作槽位。"))
            }
        }
        if !candidate.manifest.retiredGestureSlots.isEmpty {
            guard let configuredSlotsByModel else {
                throw RemotePackageError.invalid(L10n.tr("无法核对已保存的配置，不能停用手势槽位。"))
            }
            guard (configuredSlotsByModel[candidate.id] ?? []).isDisjoint(with: candidate.manifest.retiredGestureSlots) else {
                throw RemotePackageError.invalid(L10n.tr("此型号包将停用自定义配置中仍在使用的手势。请先清除对应绑定。"))
            }
        }
        let destination = directory.appending(path: candidate.id, directoryHint: .isDirectory)
        let destinationExists = files.fileExists(atPath: destination.path)
        guard !destinationExists || existing != nil else {
            throw RemotePackageError.invalid(L10n.tr("此型号标识已被无法读取的安装占用。"))
        }
        let metadata = Installation(modelID: candidate.id, sourceID: owner, release: candidate.manifest.release)
        try JSONEncoder().encode(metadata).write(to: staged.appending(path: ".installation.json"), options: .atomic)
        // Re-read the private copy after all writes; never retain URLs into temporary extraction storage.
        let verified = try RemoteDefinition.read(staged)
        if destinationExists {
            // macOS exchanges the two sibling directories in one filesystem operation.
            // The old installation remains at `staged` until the successful transaction is cleaned up.
            let result = staged.path.withCString { stagedPath in
                destination.path.withCString { destinationPath in
                    renameatx_np(AT_FDCWD, stagedPath, AT_FDCWD, destinationPath, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            try files.moveItem(at: staged, to: destination)
        }
        let installed = RemoteDefinition(manifest: verified.manifest, layout: verified.layout, inputs: verified.inputs,
            front: destination.appending(path: verified.manifest.front), artwork: verified.artwork, logo: verified.logo)
        models.removeAll { $0.id == installed.id }
        models.append(installed)
        models.sort { $0.id < $1.id }
        owners[installed.id] = owner
        return installed
    }

    private func validateDeviceConflicts(_ model: RemoteDefinition) throws {
        let devices = Set(model.manifest.devices)
        guard !models.contains(where: { $0.id != model.id && !devices.isDisjoint(with: $0.manifest.devices) }) else {
            throw RemotePackageError.invalid(L10n.tr("设备标识与已安装的型号冲突。"))
        }
    }
}
