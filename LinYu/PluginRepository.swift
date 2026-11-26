import CoreFoundation
import CryptoKit
import Foundation

struct PluginManifest: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let author: String
    let version: String
    let description: String
}

struct PluginListing: Equatable, Identifiable, Sendable {
    let manifest: PluginManifest
    let path: String
    let sha256: String

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
    private static let roomFilter = "device.room-filter"
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

    static func fetchCatalog() async throws -> [PluginListing] {
        let data = try await fetch("catalog.json")
        return try parseCatalog(data)
    }

    static func download(_ listing: PluginListing) async throws -> PluginManifest {
        guard packagePath(for: listing.manifest) == listing.path else {
            throw PluginError("插件下载地址无效")
        }
        let data = try await fetch(listing.path)
        return try verifyDownload(listing, data: data)
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
            guard item["id"] as? String == roomBindingID, isFormatOne(item) else { return nil }
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
        let json: [String: Any] = [
            "id": manifest.id,
            "name": manifest.name,
            "author": manifest.author,
            "version": manifest.version,
            "description": manifest.description,
            "formatVersion": 1,
            "capabilities": [roomFilter]
        ]
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
        guard json["id"] as? String == roomBindingID, isFormatOne(json),
              json["capabilities"] as? [String] == [roomFilter] else {
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
        return try PluginManifest(id: roomBindingID, name: required("name", limit: 48),
                                  author: required("author", limit: 48), version: version,
                                  description: required("description", limit: 300))
    }

    private static func packagePath(for manifest: PluginManifest) -> String? {
        guard manifest.id == roomBindingID, versionParts(manifest.version) != nil else { return nil }
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

    private static func jsonObject(_ data: Data, error: String) throws -> [String: Any] {
        guard let string = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
              let json = object as? [String: Any] else { throw PluginError(error) }
        return json
    }
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
            return try? PluginRepository.parsePackage(data)
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
        guard let data = PluginRepository.manifestData(manifest) else { return false }
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
