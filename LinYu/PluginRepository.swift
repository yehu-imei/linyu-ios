import CoreFoundation
import CryptoKit
import Foundation

struct PluginManifest: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let author: String
    let version: String
    let description: String
    let credit: String?
    let creditGithubID: Int64?

    init(id: String, name: String, author: String, version: String, description: String,
         credit: String? = nil, creditGithubID: Int64? = nil) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.description = description
        self.credit = credit
        self.creditGithubID = creditGithubID
    }
}

struct PluginListing: Equatable, Identifiable, Sendable {
    let manifest: PluginManifest
    let path: String
    let sha256: String
    let bundled: Bool

    init(manifest: PluginManifest, path: String, sha256: String, bundled: Bool = false) {
        self.manifest = manifest
        self.path = path
        self.sha256 = sha256
        self.bundled = bundled
    }

    var id: String { manifest.id }
}

struct PluginError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum PluginRepository {
    static let roomBindingID = "room-binding"
    static let contentLimit = 128 * 1024
    static let manifestLimit = 16 * 1024
    private static let capabilities = [
        roomBindingID: "device.room-filter",
        InstalledPlugins.nearbyID: "device.nearby",
        InstalledPlugins.consumptionTrendID: "bill.consumption-trend",
        InstalledPlugins.keepScreenOnID: "usage.keep-screen-on",
        InstalledPlugins.backgroundID: "appearance.background",
        InstalledPlugins.runtimeLogID: "diagnostics.runtime-log"
    ]
    private static let baseURL = "https://raw.giteeusercontent.com/yehu-imei/linyu-plugins/raw/main/"

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static let bundledCatalog: [PluginListing] = {
        guard let url = Bundle.main.url(forResource: "linyu_bundled_plugins", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? parseCatalog(data))?.map {
            PluginListing(manifest: $0.manifest, path: $0.path, sha256: $0.sha256, bundled: true)
        } ?? []
    }()

    static func fetchCatalog() async throws -> [PluginListing] {
        let data = try await fetch("catalog.json")
        let remote = try parseCatalog(data)
        let updates = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let local = bundledCatalog.map { bundled in
            guard let entry = updates[bundled.id], isUpdate(bundled.manifest, entry.manifest) else { return bundled }
            return entry
        }
        return remote.filter { item in !local.contains(where: { $0.id == item.id }) } + local
    }

    static func download(_ listing: PluginListing) async throws -> PluginManifest {
        if listing.bundled {
            guard bundledCatalog.contains(listing) else { throw PluginError("插件清单无效") }
            return listing.manifest
        }
        guard packagePath(for: listing.manifest) == listing.path else {
            throw PluginError("插件下载地址无效")
        }
        let data = try await fetch(listing.path)
        return try verifyDownload(listing, data: data)
    }

    static func fetchGithubLogins(_ manifests: [PluginManifest]) async -> [Int64: String] {
        let ids = Set(manifests.compactMap(\.creditGithubID))
        return await withTaskGroup(of: (Int64, String?).self) { group in
            for id in ids {
                group.addTask { (id, await githubLogin(id)) }
            }
            var logins: [Int64: String] = [:]
            for await (id, login) in group { logins[id] = login }
            return logins
        }
    }

    private static func githubLogin(_ id: Int64) async -> String? {
        let key = "pluginCredit.github.\(id)"
        let defaults = UserDefaults.standard
        let cached = defaults.string(forKey: key)
        let now = Date().timeIntervalSince1970
        let age = now - defaults.double(forKey: key + ".time")
        if let cached, (0..<86_400).contains(age) { return cached }

        guard let url = URL(string: "https://api.github.com/user/\(id)") else { return cached }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= manifestLimit,
              let json = try? jsonObject(data, error: "GitHub 账户无效"),
              positiveInt(json["id"]) == id,
              let login = json["login"] as? String,
              login.range(of: "^[A-Za-z0-9-]{1,39}$", options: .regularExpression) != nil else { return cached }

        defaults.set(login, forKey: key)
        defaults.set(now, forKey: key + ".time")
        return login
    }

    static func readFile(_ url: URL) async throws -> PluginManifest {
        guard url.isFileURL else { throw PluginError("无法读取插件文件") }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var bytes = Data()
            while let chunk = try file.read(upToCount: 4096), !chunk.isEmpty {
                try Task.checkCancellation()
                guard bytes.count + chunk.count <= contentLimit else {
                    throw PluginError("插件文件超过大小限制")
                }
                bytes.append(chunk)
            }
            data = bytes
        } catch let error as PluginError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginError("无法读取插件文件")
        }
        return try parsePackage(data)
    }

    static func isUpdate(_ installed: PluginManifest, _ available: PluginManifest) -> Bool {
        guard installed.id == available.id,
              let current = versionParts(installed.version),
              let next = versionParts(available.version) else { return false }
        return current.lexicographicallyPrecedes(next)
    }

    static func parseCatalog(_ data: Data) throws -> [PluginListing] {
        guard data.count <= contentLimit else { throw PluginError("插件目录过大") }
        let catalog = try jsonObject(data, error: "插件目录无效")
        guard isFormatOne(catalog) else { throw PluginError("插件目录需要新版淋浴") }
        guard let entries = catalog["plugins"] as? [[String: Any]] else {
            throw PluginError("插件目录无效")
        }
        var seen = Set<String>()
        return try entries.compactMap { item in
            guard let id = item["id"] as? String, capabilities[id] != nil, isFormatOne(item) else { return nil }
            let manifest = try parseManifest(item)
            guard let path = item["path"] as? String, path == packagePath(for: manifest),
                  let checksum = item["sha256"] as? String, isSHA256(checksum) else {
                throw PluginError("插件下载信息无效")
            }
            guard seen.insert(manifest.id).inserted else {
                throw PluginError("插件目录包含重复项目")
            }
            return PluginListing(manifest: manifest, path: path, sha256: checksum)
        }
    }

    static func verifyDownload(_ listing: PluginListing, data: Data) throws -> PluginManifest {
        guard data.count <= contentLimit else { throw PluginError("插件文件过大") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
        guard listing.sha256.lowercased() == digest else {
            throw PluginError("插件校验失败，请重试")
        }
        let manifest = try parsePackage(data)
        guard manifest == listing.manifest else { throw PluginError("插件与目录信息不一致") }
        return manifest
    }

    static func parsePackage(_ data: Data) throws -> PluginManifest {
        guard data.count <= contentLimit else { throw PluginError("插件文件过大") }
        let manifestData = data.starts(with: [0x50, 0x4b, 0x03, 0x04])
            ? try PluginZip.readManifest(data, limit: manifestLimit)
            : data
        guard manifestData.count <= manifestLimit else { throw PluginError("插件清单过大") }
        return try parseManifest(jsonObject(manifestData, error: "插件清单无效"))
    }

    static func manifestData(_ manifest: PluginManifest) -> Data? {
        guard let capability = capabilities[manifest.id] else { return nil }
        var json: [String: Any] = [
            "id": manifest.id,
            "name": manifest.name,
            "author": manifest.author,
            "version": manifest.version,
            "description": manifest.description,
            "formatVersion": 1,
            "capabilities": [capability]
        ]
        if let credit = manifest.credit { json["credit"] = credit }
        if let id = manifest.creditGithubID { json["creditGithubId"] = id }
        guard (try? parseManifest(json)) == manifest else { return nil }
        return try? JSONSerialization.data(withJSONObject: json)
    }

    private static func fetch(_ path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw PluginError("插件下载地址无效") }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url == url else {
                throw PluginError("插件仓库暂不可访问，请稍后重试")
            }
            guard http.expectedContentLength <= Int64(contentLimit) else {
                throw PluginError("插件文件超过大小限制")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < contentLimit else { throw PluginError("插件文件超过大小限制") }
                data.append(byte)
            }
            return data
        } catch let error as PluginError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw PluginError("无法连接插件仓库，请稍后重试")
        }
    }

    private static func parseManifest(_ json: [String: Any]) throws -> PluginManifest {
        guard let id = json["id"] as? String, let capability = capabilities[id], isFormatOne(json),
              json["capabilities"] as? [String] == [capability] else {
            throw PluginError("当前版本不支持此插件")
        }
        guard let version = json["version"] as? String, versionParts(version) != nil else {
            throw PluginError("插件版本无效")
        }
        func required(_ key: String, limit: Int) throws -> String {
            let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty, value.utf16.count <= limit else {
                throw PluginError("插件名称、作者或描述无效")
            }
            return value
        }
        let credit: String? = json["credit"] == nil ? nil : try required("credit", limit: 48)
        let creditID = positiveInt(json["creditGithubId"])
        guard json["creditGithubId"] == nil || (creditID != nil && credit != nil) else {
            throw PluginError("插件贡献者无效")
        }
        return try PluginManifest(id: id, name: required("name", limit: 48),
                                  author: required("author", limit: 48), version: version,
                                  description: required("description", limit: 300), credit: credit,
                                  creditGithubID: creditID)
    }

    private static func packagePath(for manifest: PluginManifest) -> String? {
        guard capabilities[manifest.id] != nil, versionParts(manifest.version) != nil else { return nil }
        return "packages/\(manifest.id)-\(manifest.version).zip"
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            let bytes = part.utf8
            return (1...9).contains(bytes.count) && (bytes.count == 1 || bytes.first != 48)
                && bytes.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        return parts.compactMap { Int($0) }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func isFormatOne(_ json: [String: Any]) -> Bool {
        guard let version = json["formatVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else { return false }
        return version.stringValue == "1"
    }

    private static func positiveInt(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(number.stringValue), integer > 0 else { return nil }
        return integer
    }

    private static func jsonObject(_ data: Data, error: String) throws -> [String: Any] {
        guard let string = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
              let json = object as? [String: Any] else { throw PluginError(error) }
        return json
    }
}

enum InstalledPlugins {
    static let roomBindingID = PluginRepository.roomBindingID
    static let nearbyID = "nearby-devices"
    static let consumptionTrendID = "consumption-trend"
    static let keepScreenOnID = "keep-screen-on"
    static let backgroundID = "background"
    static let runtimeLogID = "runtime-log"
    private static let lock = NSLock()

    static var all: [PluginManifest] {
        PluginRepository.bundledCatalog.compactMap { installed($0.manifest.id) } + [RoomBindingPlugin.installed].compactMap { $0 }
    }

    static func isInstalled(_ id: String) -> Bool { installed(id) != nil }

    private static func installed(_ id: String, defaults: UserDefaults = .standard,
                                  bundled: [PluginListing] = PluginRepository.bundledCatalog) -> PluginManifest? {
        if id == roomBindingID { return RoomBindingPlugin.installed(in: defaults) }
        guard let bundled = bundled.first(where: { $0.id == id }) else { return nil }
        guard let stored = defaults.data(forKey: key(id)) else { return bundled.manifest }
        guard !stored.isEmpty, let manifest = try? PluginRepository.parsePackage(stored), manifest.id == id else { return nil }
        return manifest
    }

    @discardableResult
    static func install(_ manifest: PluginManifest, defaults: UserDefaults = .standard,
                        bundled: [PluginListing] = PluginRepository.bundledCatalog) -> Bool {
        if manifest.id == roomBindingID { return RoomBindingPlugin.install(manifest, defaults: defaults) }
        lock.lock()
        defer { lock.unlock() }
        guard bundled.contains(where: { $0.id == manifest.id }), let data = PluginRepository.manifestData(manifest) else { return false }
        if let current = installed(manifest.id, defaults: defaults, bundled: bundled),
           !PluginRepository.isUpdate(current, manifest) { return false }
        defaults.set(data, forKey: key(manifest.id))
        return true
    }

    @discardableResult
    static func uninstall(_ id: String, defaults: UserDefaults = .standard,
                          bundled: [PluginListing] = PluginRepository.bundledCatalog) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard installed(id, defaults: defaults, bundled: bundled) != nil else { return false }
        if id == roomBindingID { return RoomBindingPlugin.uninstall(defaults: defaults) }
        defaults.set(Data(), forKey: key(id))
        return true
    }

    private static func key(_ id: String) -> String { "featurePlugin.\(id)" }
}

/// 只保存已安装清单和寝室筛选，订单和使用历史由主程序维护。
enum RoomBindingPlugin {
    private static let manifestKey = "roomBindingManifest"
    private static let roomKey = "boundRoom"
    private static let lock = NSRecursiveLock()
    private static let legacy = PluginManifest(id: PluginRepository.roomBindingID, name: "绑定寝室",
                                               author: "LinYu", version: "1.0.0",
                                               description: "为首页和桌面小组件筛选寝室设备")

    static var installed: PluginManifest? { installed(in: .standard) }
    static var effectiveRoom: String { effectiveRoom(in: .standard) }

    static func installed(in defaults: UserDefaults) -> PluginManifest? {
        lock.lock()
        defer { lock.unlock() }
        if let data = defaults.data(forKey: manifestKey) {
            let manifest = try? PluginRepository.parsePackage(data)
            return manifest?.id == PluginRepository.roomBindingID ? manifest : nil
        }
        guard defaults.object(forKey: manifestKey) == nil,
              !readRoom(defaults).isEmpty,
              let data = PluginRepository.manifestData(legacy) else { return nil }
        defaults.set(data, forKey: manifestKey)
        return legacy
    }

    static func effectiveRoom(in defaults: UserDefaults) -> String {
        lock.lock()
        defer { lock.unlock() }
        return installed(in: defaults) == nil ? "" : readRoom(defaults)
    }

    static func setRoom(_ room: String, defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        guard installed(in: defaults) != nil else { return }
        defaults.set(room.trimmingCharacters(in: .whitespacesAndNewlines), forKey: roomKey)
    }

    @discardableResult
    static func install(_ manifest: PluginManifest, defaults: UserDefaults = .standard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard manifest.id == PluginRepository.roomBindingID,
              let data = PluginRepository.manifestData(manifest) else { return false }
        if let current = installed(in: defaults), !PluginRepository.isUpdate(current, manifest) {
            return false
        }
        defaults.set(data, forKey: manifestKey)
        return true
    }

    @discardableResult
    static func uninstall(defaults: UserDefaults = .standard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: roomKey)
        defaults.removeObject(forKey: manifestKey)
        return true
    }

    private static func readRoom(_ defaults: UserDefaults) -> String {
        (defaults.string(forKey: roomKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
