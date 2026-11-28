import CoreFoundation
import CryptoKit
import Foundation

struct PluginManifest: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let author: String
    let version: String
    let description: String
    let details: String?
    let authorGithubID: Int64?
    let versionEpoch: Int
    /// 插件依赖的客户端能力版本；客户端只接受 `<= supportedAPI`
    let apiVersion: Int
    /// 要求的最低 App 版本（x.y.z）；低于它的客户端直接跳过该插件
    let minAppVersion: String?
    /// 插件会访问的数据/动作；不在客户端白名单里的权限一律拒绝（fail closed）
    let permissions: [String]
    /// 2 只在目录条目与包清单中使用，旧客户端会跳过。
    let formatVersion: Int

    init(id: String, name: String, author: String, version: String, description: String,
         details: String? = nil, authorGithubID: Int64? = nil, versionEpoch: Int = 0,
         apiVersion: Int = 1, minAppVersion: String? = nil, permissions: [String] = [],
         formatVersion: Int = 1) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.description = description
        self.details = details
        self.authorGithubID = authorGithubID
        self.versionEpoch = versionEpoch
        self.apiVersion = apiVersion
        self.minAppVersion = minAppVersion
        self.permissions = permissions
        self.formatVersion = formatVersion
    }
}

struct PluginListing: Equatable, Identifiable, Sendable {
    let manifest: PluginManifest
    let path: String
    let sha256: String
    let source: String?

    init(manifest: PluginManifest, path: String, sha256: String, source: String? = nil) {
        self.manifest = manifest
        self.path = path
        self.sha256 = sha256
        self.source = source
    }

    var id: String { manifest.id }
}

struct PluginError: LocalizedError {
    let message: String
    let incompatible: Bool

    init(_ message: String, incompatible: Bool = false) {
        self.message = message
        self.incompatible = incompatible
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
    /// 下载源，**按顺序尝试**：主源 Gitee，备源 GitHub raw。
    /// 两个源必须放同一份文件（同一个 sha256），否则会出现"主源能装、备源校验失败"。
    private static let sources = [
        "https://raw.giteeusercontent.com/yehu-imei/linyu-plugins/raw/main/",
        "https://raw.githubusercontent.com/yehu-imei/linyu-plugins/main/",
    ]

    /// 当前生效的下载源（按优先级），回归测试用它锁住「主 Gitee、备 GitHub」
    static var repositorySources: [String] { sources }

    /// 客户端支持的插件 API 版本上限
    static let supportedAPI = 2

    /// 允许插件声明的权限（与 Android 端保持一致）
    static let knownPermissions: Set<String> = [
        "device.nearby", "device.room-filter",
        "wallet.balance.read", "bill.list.read",
        "usage.keep-screen-on", "appearance.background", "diagnostics.runtime-log",
        "action.open-url", "action.open-recharge",
    ]

    /// 日志出口。默认丢弃，App 启动时接到 `AppLog` 上。
    ///
    /// 为什么不用 `AppLog.shared` 直接写：CI 的 swiftc 只编译
    /// `PluginRepository + PluginZip + PluginRegression` 三个文件，
    /// 引 AppLog 会把整个日志模块连带拉进来。留一个可注入的钩子最省事。
    static var log: (String) -> Void = { _ in }

    /// 测试用：覆盖当前 App 版本（swiftc 回归里没有 Bundle 版本号）
    static var appVersionOverride: String?

    /// 当前 App 版本，用于 `minAppVersion` 判定
    static var appVersion: String {
        if let override = appVersionOverride { return override }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 权限 id → 给用户看的中文说明
    static func permissionLabel(_ id: String) -> String {
        switch id {
        case "device.nearby": return "读取附近设备"
        case "device.room-filter": return "按寝室筛选设备"
        case "wallet.balance.read": return "读取钱包/一卡通余额"
        case "bill.list.read": return "读取消费账单"
        case "usage.keep-screen-on": return "用水时保持屏幕常亮"
        case "appearance.background": return "修改界面背景"
        case "diagnostics.runtime-log": return "读写运行日志"
        case "action.open-url": return "打开声明过的网页"
        case "action.open-recharge": return "打开官方充值入口"
        default: return id
        }
    }

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
        return (try? parseCatalog(data)) ?? []
    }()

    static func fetchCatalog(read: (String, String) async throws -> Data = fetchBytes) async throws -> [PluginListing] {
        try await fetchValidated("catalog.json", read: read) { data, source in
            try parseCatalog(data).map {
                PluginListing(manifest: $0.manifest, path: $0.path, sha256: $0.sha256, source: source)
            }
        }
    }

    static func download(_ listing: PluginListing,
                         read: (String, String) async throws -> Data = fetchBytes) async throws -> PluginManifest {
        guard packagePath(for: listing.manifest) == listing.path else {
            throw PluginError("插件下载地址无效")
        }
        return try await fetchValidated(listing.path, preferredSource: listing.source, read: read) { data, _ in
            try verifyDownload(listing, data: data)
        }
    }

    static func fetchGithubLogins(_ manifests: [PluginManifest]) async -> [Int64: String] {
        let ids = Set(manifests.compactMap(\.authorGithubID))
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
        if available.versionEpoch != installed.versionEpoch { return available.versionEpoch > installed.versionEpoch }
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
            guard let id = item["id"] as? String, capabilities[id] != nil, manifestFormat(item) != nil else { return nil }
            let manifest: PluginManifest
            do {
                manifest = try parseManifest(item)
            } catch let error as PluginError where error.incompatible {
                log("跳过插件 \(id)：\(error.message)")
                return nil
            }
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
            "formatVersion": manifest.formatVersion,
            "capabilities": [capability]
        ]
        if let details = manifest.details { json["details"] = details }
        if let id = manifest.authorGithubID { json["authorGithubId"] = id }
        if manifest.versionEpoch != 0 { json["versionEpoch"] = manifest.versionEpoch }
        if manifest.apiVersion != 1 { json["apiVersion"] = manifest.apiVersion }
        if let minAppVersion = manifest.minAppVersion { json["minAppVersion"] = minAppVersion }
        if !manifest.permissions.isEmpty { json["permissions"] = manifest.permissions }
        guard (try? parseManifest(json)) == manifest else { return nil }
        return try? JSONSerialization.data(withJSONObject: json)
    }

    private static func fetchValidated<T>(
        _ path: String, preferredSource: String? = nil,
        read: (String, String) async throws -> Data,
        validate: (Data, String) throws -> T
    ) async throws -> T {
        let ordered = if let preferredSource, sources.contains(preferredSource) {
            [preferredSource] + sources.filter { $0 != preferredSource }
        } else {
            sources
        }
        var lastError: Error?
        var validationError: Error?
        for base in ordered {
            try Task.checkCancellation()
            do {
                let data = try await read(base, path)
                try Task.checkCancellation()
                do {
                    return try validate(data, base)
                } catch {
                    validationError = error
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                log("插件源不可用：\(base)（\(path)）")
                lastError = error
            }
        }
        try Task.checkCancellation()
        if let validationError { throw validationError }
        if let lastError { throw PluginError(lastError.localizedDescription) }
        throw PluginError("无法连接插件仓库，请稍后重试")
    }

    private static func fetchBytes(_ baseURL: String, _ path: String) async throws -> Data {
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

    private static func compatibility(_ json: [String: Any]) throws -> (api: Int, minimum: String?, permissions: [String]) {
        let api: Int64
        if let field = json["apiVersion"] {
            guard let value = positiveInt(field) else { throw PluginError("插件 API 版本无效", incompatible: true) }
            api = value
        } else {
            api = 1
        }
        guard api <= supportedAPI else { throw PluginError("需要新版淋浴（插件 apiVersion=\(api)）", incompatible: true) }

        var minimum: String?
        if let field = json["minAppVersion"] {
            guard let raw = (field as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let required = versionParts(raw) else { throw PluginError("插件的最低版本号无效", incompatible: true) }
            guard let current = versionParts(appVersion), compareVersions(required, current) <= 0 else {
                throw PluginError("需要淋浴 \(raw) 及以上（当前 \(appVersion)）", incompatible: true)
            }
            minimum = raw
        }

        var permissions: [String] = []
        if let field = json["permissions"] {
            guard let declared = field as? [String] else { throw PluginError("插件权限声明无效", incompatible: true) }
            if let unknown = declared.first(where: { !knownPermissions.contains($0) }) {
                throw PluginError("声明了未知权限：\(unknown)", incompatible: true)
            }
            var seen = Set<String>()
            permissions = declared.filter { seen.insert($0).inserted }
        }
        return (Int(api), minimum, permissions)
    }

    /// 逐段比较 x.y.z；a < b 返回负数
    static func compareVersions(_ a: [Int], _ b: [Int]) -> Int {
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x - y }
        }
        return 0
    }

    private static func parseManifest(_ json: [String: Any]) throws -> PluginManifest {
        let (api, minimum, permissions) = try compatibility(json)
        guard let id = json["id"] as? String, let capability = capabilities[id], let format = manifestFormat(json),
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
        let author = try required("author", limit: 48)
        let authorID = positiveInt(json["authorGithubId"])
        guard json["authorGithubId"] == nil || authorID != nil else { throw PluginError("插件作者无效") }
        let details: String? = json["details"] == nil ? nil : try required("details", limit: 800)
        // 将上一版已保存的内置清单调整为只展示作者，保留实际安装版本。
        let legacyAuthor = author == "LinYu" ? (try? required("credit", limit: 48)) : nil
        let legacyOwner = author == "LinYu" && (id == roomBindingID || id == InstalledPlugins.nearbyID)
        let legacyID = legacyAuthor != nil ? positiveInt(json["creditGithubId"]) : (legacyOwner ? 178531070 : nil)
        // 正式首版以 v1.0.0 起步，仍应更新此前已安装的预览版。
        let epoch: Int64? = json["versionEpoch"] == nil ? 0 : positiveInt(json["versionEpoch"])
        guard let epoch, (0...1).contains(epoch) else { throw PluginError("插件版本无效") }
        return try PluginManifest(id: id, name: required("name", limit: 48),
                                  author: legacyAuthor ?? (legacyOwner ? "yehu-imei" : author), version: version,
                                  description: required("description", limit: 300), details: details,
                                  authorGithubID: authorID ?? legacyID, versionEpoch: Int(epoch),
                                  apiVersion: api, minAppVersion: minimum,
                                  permissions: permissions, formatVersion: format)
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

    private static func manifestFormat(_ json: [String: Any]) -> Int? {
        guard let value = positiveInt(json["formatVersion"]), (1...2).contains(value) else { return nil }
        return Int(value)
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
                                               author: "yehu-imei", version: "1.0.0",
                                               description: "为首页和桌面小组件筛选寝室设备",
                                               authorGithubID: 178531070)

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
