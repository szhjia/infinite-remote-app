import Foundation
import Compression

/// ZIP reader restricted to one flat model folder. Header, bounded DEFLATE, and CRC
/// validation happens before any package is exposed to the caller.
enum PackageArchive {
    private static let maxArchive = 64 * 1024 * 1024
    private static let maxExpanded = 64 * 1024 * 1024
    private static let maxEntry = 16 * 1024 * 1024

    private struct Entry {
        let path: String
        let isDirectory: Bool
        let crc: UInt32
        let expanded: Int
        let compressed: Int
        let localOffset: Int
        let flags: UInt16
        let method: UInt16
        let rawName: Data
        var payloadOffset: Int = 0
    }

    static func extract(_ url: URL, to directory: URL) throws -> URL {
        let files = FileManager.default
        let source = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard source.isRegularFile == true, source.isSymbolicLink != true,
              let size = source.fileSize, (22...maxArchive).contains(size) else { throw invalid(L10n.tr("ZIP 资源包无效或超过大小限制。")) }
        // Snapshot first: extraction must inspect exactly the bytes that passed preflight.
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw invalid(L10n.tr("ZIP 资源包在读取期间发生了更改。")) }
        let entries = try inspect(data)
        guard let root = entries.first?.path.split(separator: "/").first.map(String.init) else { throw invalid(L10n.tr("ZIP 资源包为空。")) }
        if files.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  try files.contentsOfDirectory(atPath: directory.path).isEmpty else { throw invalid(L10n.tr("解压目标文件夹必须为空。")) }
        } else { try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let workspace = directory.appending(path: ".extract-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: workspace) }
        let output = workspace.appending(path: "contents", directoryHint: .isDirectory)
        try files.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try files.createDirectory(at: output.appending(path: root), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for entry in entries where !entry.isDirectory {
            let compressed = data.subdata(in: entry.payloadOffset..<(entry.payloadOffset + entry.compressed))
            let expanded = try decode(compressed, method: entry.method, expected: entry.expanded)
            guard crc32(expanded) == entry.crc else { throw invalid(L10n.tr("ZIP 文件校验和不匹配。")) }
            try expanded.write(to: output.appending(path: entry.path), options: .atomic)
        }
        var expected = Set<String>()
        expected.insert(root)
        for entry in entries {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            expected.insert(path.precomposedStringWithCanonicalMapping)
            let file = output.appending(path: path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw invalid(L10n.tr("ZIP 资源包包含链接文件。")) }
            if entry.isDirectory {
                guard values.isDirectory == true else { throw invalid(L10n.tr("ZIP 文件夹类型不匹配。")) }
            } else {
                guard values.isRegularFile == true, values.fileSize == entry.expanded else { throw invalid(L10n.tr("ZIP 文件大小不匹配。")) }
                let bytes = try Data(contentsOf: file)
                guard bytes.count == entry.expanded, crc32(bytes) == entry.crc else { throw invalid(L10n.tr("ZIP 文件校验和不匹配。")) }
            }
        }
        guard let enumerator = files.enumerator(at: output, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            throw invalid(L10n.tr("无法检查 ZIP 解压后的内容。"))
        }
        // Foundation's enumerator can return canonical /private/var paths even
        // when the requested URL uses /var. Compare filesystem components rather
        // than slicing one path using the length of a different representation.
        let outputComponents = output.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var actual = Set<String>()
        for case let item as URL in enumerator {
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw invalid(L10n.tr("ZIP 资源包包含链接文件。"))
            }
            let components = item.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > outputComponents.count,
                  Array(components.prefix(outputComponents.count)) == outputComponents else {
                throw invalid(L10n.tr("ZIP 解压后出现了未声明的文件。"))
            }
            let relative = components.dropFirst(outputComponents.count).joined(separator: "/").precomposedStringWithCanonicalMapping
            guard expected.contains(relative) else { throw invalid(L10n.tr("ZIP 解压后出现了未声明的文件。")) }
            actual.insert(relative)
        }
        guard actual == expected else { throw invalid(L10n.tr("ZIP 解压不完整。")) }
        let result = directory.appending(path: root, directoryHint: .isDirectory)
        try files.moveItem(at: output.appending(path: root), to: result)
        return result
    }

    private static func inspect(_ data: Data) throws -> [Entry] {
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= data.count - 2 else { throw invalid(L10n.tr("ZIP 头部数据不完整。")) }
            return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid(L10n.tr("ZIP 头部数据不完整。")) }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        func bytes(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { throw invalid(L10n.tr("ZIP 条目数据不完整。")) }
            return data.subdata(in: offset..<(offset + count))
        }
        // EOCD can occur in an archive comment: only a record ending at EOF is accepted.
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(offset) == 0x06054b50, offset + 22 + Int(try u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0,
              try u16(end + 8) == u16(end + 10) else { throw invalid(L10n.tr("不支持分卷或 ZIP64 资源包。")) }
        let count = Int(try u16(end + 10))
        let centralSize = Int(try u32(end + 12))
        let centralStart = Int(try u32(end + 16))
        guard (1...256).contains(count), centralStart <= end, centralSize == end - centralStart else { throw invalid(L10n.tr("ZIP 中央目录无效。")) }
        var cursor = centralStart
        var total = 0
        var entries: [Entry] = []
        var paths = Set<String>()
        var root: String?
        for _ in 0..<count {
            guard cursor <= end - 46, try u32(cursor) == 0x02014b50 else { throw invalid(L10n.tr("ZIP 中央目录条目无效。")) }
            let flags = try u16(cursor + 8)
            let method = try u16(cursor + 10)
            let crc = try u32(cursor + 16)
            let compressed = Int(try u32(cursor + 20))
            let expanded = Int(try u32(cursor + 24))
            let nameLength = Int(try u16(cursor + 28))
            let extraLength = Int(try u16(cursor + 30))
            let commentLength = Int(try u16(cursor + 32))
            let external = try u32(cursor + 38)
            let offset = Int(try u32(cursor + 42))
            guard try u16(cursor + 34) == 0, flags & ~UInt16(0x080e) == 0,
                  method == 0 || method == 8, nameLength > 0,
                  expanded <= maxEntry, compressed <= maxArchive,
                  expanded <= max(1024, compressed * 1000), offset < centralStart else {
                throw invalid(L10n.tr("ZIP 条目已加密、不受支持或超过大小限制。"))
            }
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end else { throw invalid(L10n.tr("ZIP 中央目录条目数据不完整。")) }
            let rawName = try bytes(cursor + 46, nameLength)
            guard let name = String(data: rawName, encoding: .utf8), !name.contains("\\"), !name.contains(":"),
                  !name.hasPrefix("/"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw invalid(L10n.tr("ZIP 文件名无效。"))
            }
            let isDirectory = name.hasSuffix("/")
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard (isDirectory && components.count == 2 && components[1].isEmpty)
                    || (!isDirectory && components.count == 2 && validPackageFilename(String(components[1]))),
                  let first = components.first, validPackageID(String(first)) else {
                throw invalid(L10n.tr("ZIP 必须只包含一个型号文件夹，且其中不能包含子文件夹。"))
            }
            let model = String(first)
            guard root == nil || root == model else { throw invalid(L10n.tr("ZIP 包含多个型号文件夹。")) }
            root = model
            let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(normalized).inserted else { throw invalid(L10n.tr("ZIP 包含重复文件名。")) }
            let mode = (external >> 16) & 0xffff
            let kind = mode & 0xf000
            guard kind == 0 || kind == (isDirectory ? 0x4000 : 0x8000),
                  external & 0x400 == 0, (external & 0x10 == 0 || isDirectory),
                  !isDirectory || (expanded == 0 && compressed <= 16 && crc == 0) else { throw invalid(L10n.tr("ZIP 包含链接或特殊文件。")) }
            try validateExtra(bytes(cursor + 46 + nameLength, extraLength))
            total += expanded
            guard total <= maxExpanded else { throw invalid(L10n.tr("ZIP 解压后的内容超过大小限制。")) }
            entries.append(Entry(path: name, isDirectory: isDirectory, crc: crc, expanded: expanded,
                                 compressed: compressed, localOffset: offset, flags: flags, method: method, rawName: rawName))
            cursor = next
        }
        guard cursor == end, entries.contains(where: { !$0.isDirectory }) else { throw invalid(L10n.tr("ZIP 中央目录大小无效。")) }
        var previousEnd = 0
        for index in entries.indices.sorted(by: { entries[$0].localOffset < entries[$1].localOffset }) {
            let entry = entries[index]
            let offset = entry.localOffset
            guard offset == previousEnd, offset <= centralStart - 30, try u32(offset) == 0x04034b50,
                  try u16(offset + 6) == entry.flags, try u16(offset + 8) == entry.method else { throw invalid(L10n.tr("ZIP 本地文件头存在冲突。")) }
            let nameLength = Int(try u16(offset + 26))
            let extraLength = Int(try u16(offset + 28))
            guard try bytes(offset + 30, nameLength) == entry.rawName else { throw invalid(L10n.tr("ZIP 本地文件名不匹配。")) }
            try validateExtra(bytes(offset + 30 + nameLength, extraLength))
            let start = offset + 30 + nameLength + extraLength
            entries[index].payloadOffset = start
            var payloadEnd = start + entry.compressed
            guard payloadEnd <= centralStart else { throw invalid(L10n.tr("ZIP 条目与中央目录重叠。")) }
            let localCRC = try u32(offset + 14)
            let localCompressed = Int(try u32(offset + 18))
            let localExpanded = Int(try u32(offset + 22))
            if entry.flags & 8 == 0 {
                guard localCRC == entry.crc, localCompressed == entry.compressed, localExpanded == entry.expanded else {
                    throw invalid(L10n.tr("ZIP 本地文件大小或校验和不匹配。"))
                }
            } else {
                guard (localCRC == 0 || localCRC == entry.crc), (localCompressed == 0 || localCompressed == entry.compressed),
                      (localExpanded == 0 || localExpanded == entry.expanded) else { throw invalid(L10n.tr("ZIP 数据描述符存在冲突。")) }
                let signed = try u32(payloadEnd) == 0x08074b50
                let descriptor = payloadEnd + (signed ? 4 : 0)
                guard try u32(descriptor) == entry.crc, try u32(descriptor + 4) == UInt32(entry.compressed),
                      try u32(descriptor + 8) == UInt32(entry.expanded) else { throw invalid(L10n.tr("ZIP 数据描述符无效。")) }
                payloadEnd = descriptor + 12
                guard payloadEnd <= centralStart else { throw invalid(L10n.tr("ZIP 数据描述符与中央目录重叠。")) }
            }
            previousEnd = payloadEnd
        }
        guard previousEnd == centralStart else { throw invalid(L10n.tr("ZIP 包含隐藏或相互重叠的本地条目。")) }
        return entries
    }

    private static func validateExtra(_ data: Data) throws {
        var cursor = 0
        while cursor < data.count {
            guard cursor <= data.count - 4 else { throw invalid(L10n.tr("ZIP 扩展数据无效。")) }
            let kind = UInt16(data[cursor]) | UInt16(data[cursor + 1]) << 8
            let length = Int(data[cursor + 2]) | Int(data[cursor + 3]) << 8
            guard length <= data.count - cursor - 4, [UInt16(0x5455), 0x5855, 0x7855, 0x7875, 0x000a].contains(kind) else {
                throw invalid(L10n.tr("不支持 ZIP64、替代路径或链接元数据。"))
            }
            cursor += length + 4
        }
    }

    private static func decode(_ data: Data, method: UInt16, expected: Int) throws -> Data {
        if method == 0 {
            guard data.count == expected else { throw invalid(L10n.tr("未压缩的 ZIP 条目大小不匹配。")) }
            return data
        }
        // ZIP method 8 is raw DEFLATE, the format consumed by COMPRESSION_ZLIB.
        // One spare output byte detects streams whose real size exceeds their headers.
        let capacity = expected + 1
        var output = [UInt8](repeating: 0, count: capacity)
        return try data.withUnsafeBytes { source in
            try output.withUnsafeMutableBytes { destination in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress,
                      let dst = destination.bindMemory(to: UInt8.self).baseAddress else { throw invalid(L10n.tr("DEFLATE 数据流为空。")) }
                // The SDK imports these buffer fields as nonoptional pointers. Keep
                // initialization, processing, and destruction within their lifetimes.
                var stream = compression_stream(dst_ptr: dst, dst_size: capacity,
                                                src_ptr: src, src_size: data.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                    throw invalid(L10n.tr("无法初始化 ZIP 解压。"))
                }
                defer { compression_stream_destroy(&stream) }
                // compression_stream_init clears the caller-managed buffer fields.
                stream.src_ptr = src; stream.src_size = data.count
                stream.dst_ptr = dst; stream.dst_size = capacity
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_END, stream.src_size == 0, stream.dst_size == 1 else {
                    throw invalid(L10n.tr("ZIP 数据流超过声明的大小或已损坏。"))
                }
                return Data(bytes: dst, count: expected)
            }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        let table = crcTable
        return data.withUnsafeBytes { bytes in
            var crc = UInt32.max
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
            }
            return crc ^ UInt32.max
        }
    }

    private static func invalid(_ message: String) -> RemotePackageError { .invalid(message) }
}
