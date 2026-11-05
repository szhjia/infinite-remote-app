import CryptoKit
import Foundation
import Observation

struct RemoteListing: Codable, Identifiable {
    let id: String
    let release: String
    let name: LocalizedText
    let summary: LocalizedText
    let brand: RemoteBrand?
    let preview: String?
    let package: String
    let packageSHA256: String
}

struct SubscriptionCatalog: Codable {
    let formatVersion: Int
    let id: String
    let name: LocalizedText
    let models: [RemoteListing]

    func validate() throws {
        guard formatVersion == 2, Self.validID(id), name.isValid, !name.isLegacy, models.count <= 1000,
              Set(models.map(\.id)).count == models.count else {
            throw RemotePackageError.invalid(L10n.tr("订阅源目录格式无效。"))
        }
        for model in models {
            guard Self.validID(model.id), Self.validRelease(model.release), model.name.isValid,
                  model.summary.isValid, !model.name.isLegacy, !model.summary.isLegacy, !model.package.isEmpty,
                  model.packageSHA256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
                  model.brand.map({ Self.validID($0.id) && $0.name.isValid && !$0.name.isLegacy }) ?? true else {
                throw RemotePackageError.invalid(L10n.tr("订阅源中的遥控器信息无效。"))
            }
        }
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil
    }
    static func validRelease(_ value: String) -> Bool { (try? PackageVersion(value)) != nil }
}

struct RemoteSubscription: Codable, Identifiable {
    let id: String
    var url: URL
    var catalog: SubscriptionCatalog?
    var refreshedAt: Date?
    var title: String { catalog?.name.resolve() ?? url.host ?? url.absoluteString }
}

/// Catalog identity is scoped by a locally assigned subscription ID, never by untrusted remote IDs.
@MainActor @Observable
final class ResourceLibrary {
    private static let maxPersistedBytes = 8 * 1024 * 1024
    static let officialURL = URL(string: "https://raw.githubusercontent.com/szhjia/infinite-remote-hub/main/catalog.json")!
    private(set) var sources: [RemoteSubscription] = []
    private(set) var refreshing: Set<String> = []
    private(set) var installing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var storageError: String?
    private var canSave = true
    private let directory: URL
    private let session: URLSession

    init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        let file = directory.appending(path: "subscriptions.json")
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maxPersistedBytes else { throw CocoaError(.fileReadCorruptFile) }
            let saved = try JSONDecoder().decode([RemoteSubscription].self, from: data)
            guard saved.count <= 50, Set(saved.map(\.id)).count == saved.count else { throw CocoaError(.fileReadCorruptFile) }
            for source in saved {
                guard Self.allowed(source.url) else { throw CocoaError(.fileReadCorruptFile) }
                try source.catalog?.validate()
            }
            sources = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            sources = [.init(id: Self.sourceID(for: Self.officialURL), url: Self.officialURL)]
        } catch {
            canSave = false
            storageError = L10n.tr("无法读取订阅设置，原文件已保留。")
        }
    }

    @discardableResult
    func addSource(_ input: String) throws -> String {
        guard sources.count < 50, let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.allowed(url) else { throw RemotePackageError.invalid(L10n.tr("请输入 HTTPS 订阅目录地址。")) }
        guard !sources.contains(where: { $0.url == url }) else {
            throw RemotePackageError.invalid(L10n.tr("此订阅源已存在。"))
        }
        let id = Self.sourceID(for: url)
        let source = RemoteSubscription(id: id, url: url)
        try persist(sources + [source])
        sources.append(source)
        return id
    }

    func removeSource(_ id: String) throws {
        guard !refreshing.contains(id), !installing.contains(where: { $0.hasPrefix(id + ":") }) else {
            throw RemotePackageError.invalid(L10n.tr("请等待当前下载完成。"))
        }
        let remaining = sources.filter { $0.id != id }
        try persist(remaining)
        sources = remaining
        errors[id] = nil
    }

    func refreshAll() async {
        for id in sources.map(\.id) { await refresh(id) }
    }

    func refresh(_ id: String) async {
        guard !refreshing.contains(id), let source = sources.first(where: { $0.id == id }) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let data = try await Self.fetch(source.url, limit: 2 * 1024 * 1024, session: session)
            let catalog = try JSONDecoder().decode(SubscriptionCatalog.self, from: data)
            try catalog.validate()
            for listing in catalog.models {
                _ = try Self.resolve(listing.package, against: source.url)
                if let preview = listing.preview { _ = try Self.resolve(preview, against: source.url) }
                if let logo = listing.brand?.logo { _ = try Self.resolve(logo, against: source.url) }
            }
            guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
            var next = sources
            next[index].catalog = catalog
            next[index].refreshedAt = .now
            try persist(next)
            sources = next
            errors[id] = nil
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    func install(_ listing: RemoteListing, from source: RemoteSubscription, into model: RemoteModel) async {
        let key = source.id + ":" + listing.id
        guard installing.isEmpty, sources.contains(where: { $0.id == source.id }) else { return }
        installing.insert(key)
        defer { installing.remove(key) }
        do {
            let url = try Self.resolve(listing.package, against: source.url)
            let data = try await Self.fetch(url, limit: 32 * 1024 * 1024, session: session)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == listing.packageSHA256.lowercased() else {
                throw RemotePackageError.invalid(L10n.tr("资源包校验失败，请刷新订阅源后重试。"))
            }
            let temporary = FileManager.default.temporaryDirectory.appending(path: "remote-download-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let archive = temporary.appending(path: "remote.zip")
            try data.write(to: archive, options: .atomic)
            let folder = try await Task.detached(priority: .userInitiated) {
                try PackageArchive.extract(archive, to: temporary.appending(path: "expanded"))
            }.value
            try Task.checkCancellation()
            let definition = try RemoteDefinition.read(folder)
            guard definition.id == listing.id, definition.manifest.release == listing.release else {
                throw RemotePackageError.invalid(L10n.tr("资源包与订阅目录中的型号或版本不一致。"))
            }
            try model.installModel(from: folder, sourceID: source.id)
            errors[key] = nil
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    func previewURL(_ listing: RemoteListing, source: RemoteSubscription) -> URL? {
        listing.preview.flatMap { try? Self.resolve($0, against: source.url) }
    }

    private func persist(_ value: [RemoteSubscription]) throws {
        guard canSave else { throw RemotePackageError.invalid(L10n.tr("无法读取订阅设置，原文件已保留。")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maxPersistedBytes else {
            throw RemotePackageError.invalid(L10n.tr("订阅目录缓存超过大小限制，请减少订阅源或目录内容。"))
        }
        try data.write(to: directory.appending(path: "subscriptions.json"), options: .atomic)
        storageError = nil
    }

    nonisolated static func sourceID(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func allowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host, !host.isEmpty else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    nonisolated static func resolve(_ path: String, against base: URL) throws -> URL {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL, allowed(url) else {
            throw RemotePackageError.invalid(L10n.tr("订阅资源地址必须使用 HTTPS。"))
        }
        return url
    }

    nonisolated static func fetch(_ url: URL, limit: Int, session: URLSession) async throws -> Data {
        guard allowed(url) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request, delegate: SubscriptionRedirectPolicy())
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              let finalURL = response.url, allowed(finalURL) else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        return data
    }
}

private final class SubscriptionRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ResourceLibrary.allowed) == true ? request : nil)
    }
}
