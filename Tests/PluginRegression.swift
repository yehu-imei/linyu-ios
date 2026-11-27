import Foundation

@main
struct PluginRegression {
    private static let manifest = PluginManifest(
        id: "room-binding", name: "绑定寝室", author: "yehu-imei", version: "1.1.0",
        description: "为首页和桌面小组件筛选寝室设备"
    )
    private static let checksum = "f663866035bfd5c23fb6e30c91fd7ea2f68685f15f86f8065ebab7ff96f074fc"

    // The first fixture is the published Gitee package. The second has the same manifest stored without compression.
    private static let deflatedZIP = Data(base64Encoded:
        "UEsDBBQAAAAIAAAAIQAzqdlOvQAAAOYAAAANAAAAbWFuaWZlc3QuanNvbqvmUlBQykxRslJQKsrPz9VNysxLycxLV9IBiecl5qaCZJ7vnvh03ayn6+c+XbcEIpNYWpKRXwSSq0zNKNXNzE3NhEiUpRYVZ+bngWQM9Qz1DCCiKanFyUWZBSVQmSc7dr1cNu3lwq1PJ/U8W9jzcu6ipxv6n+9uebJ72/O1s182dEKserFu39Ml7RAT0vKLchNLwuCmG4JFkxMLEpMyczJLMlOLgYLRQIvKMpNT9cBeScvMKUktUorlquUCAFBLAQIUABQAAAAIAAAAIQAzqdlOvQAAAOYAAAANAAAAAAAAAAAAAACAAQAAAABtYW5pZmVzdC5qc29uUEsFBgAAAAABAAEAOwAAAOgAAAAAAA=="
    )!
    private static let storedZIP = Data(base64Encoded:
        "UEsDBBQAAAAAAAAAIQAzqdlO5gAAAOYAAAANAAAAbWFuaWZlc3QuanNvbnsKICAiaWQiOiAicm9vbS1iaW5kaW5nIiwKICAibmFtZSI6ICLnu5Hlrprlr53lrqQiLAogICJhdXRob3IiOiAieWVodS1pbWVpIiwKICAidmVyc2lvbiI6ICIxLjEuMCIsCiAgImRlc2NyaXB0aW9uIjogIuS4uummlumhteWSjOahjOmdouWwj+e7hOS7tuetm+mAieWvneWupOiuvuWkhyIsCiAgImZvcm1hdFZlcnNpb24iOiAxLAogICJjYXBhYmlsaXRpZXMiOiBbImRldmljZS5yb29tLWZpbHRlciJdCn0KUEsBAhQAFAAAAAAAAAAhADOp2U7mAAAA5gAAAA0AAAAAAAAAAAAAAIABAAAAAG1hbmlmZXN0Lmpzb25QSwUGAAAAAAEAAQA7AAAAEQEAAAAA"
    )!

    private static func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw PluginError("FAIL: \(description)") }
        print("PASS \(description)")
    }

    private static func rejects(_ description: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch is PluginError {
            print("PASS \(description)")
            return
        }
        throw PluginError("FAIL: \(description)")
    }

    static func main() async throws {
        let listing = PluginListing(manifest: manifest, path: "packages/room-binding-1.1.0.zip", sha256: checksum)
        let manifestData = try PluginRepository.parsePackage(deflatedZIP)
        try check(manifestData == manifest, "opens the published deflated plugin")
        try check(try PluginRepository.parsePackage(storedZIP) == manifest, "opens a stored ZIP")
        try check(try PluginRepository.verifyDownload(listing, data: deflatedZIP) == manifest,
                  "published plugin SHA-256 and metadata match Android")

        var broken = storedZIP
        broken[50] ^= 1
        try rejects("rejects damaged ZIP data") { _ = try PluginRepository.parsePackage(broken) }
        var nested = storedZIP
        nested[30] = 0x2f
        try rejects("rejects a manifest outside the ZIP root") { _ = try PluginRepository.parsePackage(nested) }
        var duplicate = storedZIP
        duplicate[duplicate.count - 12] = 2
        try rejects("rejects multi-entry packages") { _ = try PluginRepository.parsePackage(duplicate) }
        try rejects("rejects oversized package data") {
            _ = try PluginRepository.parsePackage(Data(repeating: 0, count: PluginRepository.contentLimit + 1))
        }
        try rejects("rejects mismatched download checksum") {
            _ = try PluginRepository.verifyDownload(listing, data: storedZIP)
        }
        let altered = PluginManifest(id: manifest.id, name: "不同名称", author: manifest.author,
                                     version: manifest.version, description: manifest.description)
        try rejects("rejects mismatched catalog name even with a valid checksum") {
            let wrongListing = PluginListing(manifest: altered, path: listing.path, sha256: listing.sha256)
            _ = try PluginRepository.verifyDownload(wrongListing, data: deflatedZIP)
        }

        let plain = PluginRepository.manifestData(manifest)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linyu-plugin-\(UUID()).json")
        try plain.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await PluginRepository.readFile(url)
        try check(imported == manifest, "imports a plain local JSON manifest")

        var entry = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
        entry["path"] = listing.path
        entry["sha256"] = checksum
        func catalog(_ items: [[String: Any]], version: Any = 1) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["formatVersion": version, "plugins": items])
        }
        try check(try PluginRepository.parseCatalog(catalog([entry, ["id": "future-plugin"]])) == [listing],
                  "recognizes current Android catalog and skips unsupported plugins")
        try rejects("rejects a catalog path outside the supported package directory") {
            var invalid = entry
            invalid["path"] = "../room-binding-1.1.0.zip"
            _ = try PluginRepository.parseCatalog(catalog([invalid]))
        }
        try rejects("rejects boolean instead of catalog format version") {
            _ = try PluginRepository.parseCatalog(catalog([entry], version: true))
        }
        try rejects("rejects duplicate catalog IDs") {
            _ = try PluginRepository.parseCatalog(catalog([entry, entry]))
        }
        let numeric = PluginManifest(id: manifest.id, name: manifest.name, author: manifest.author,
                                     version: "1.10.0", description: manifest.description)
        try check(PluginRepository.isUpdate(manifest, numeric) && !PluginRepository.isUpdate(numeric, manifest),
                  "compares semantic plugin versions")

        let suite = "linyu-plugin-regression-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        RoomBindingPlugin.setRoom("ignored", defaults: defaults)
        try check(RoomBindingPlugin.installed(in: defaults) == nil &&
                  RoomBindingPlugin.effectiveRoom(in: defaults).isEmpty,
                  "fresh installs have no room filter until the plugin is installed")
        defaults.set("已有寝室", forKey: "boundRoom")
        defaults.set("之前使用过的设备", forKey: "lastDeviceName")
        try check(RoomBindingPlugin.installed(in: defaults)?.version == "1.0.0" &&
                  RoomBindingPlugin.effectiveRoom(in: defaults) == "已有寝室",
                  "migration preserves a pre-existing room binding")
        try check(RoomBindingPlugin.install(manifest, defaults: defaults) &&
                  !RoomBindingPlugin.install(manifest, defaults: defaults) &&
                  RoomBindingPlugin.effectiveRoom(in: defaults) == "已有寝室",
                  "updating keeps the binding and rejects same-version replacement")
        let firstRoom = PluginManifest(id: manifest.id, name: manifest.name, author: manifest.author,
                                       version: "1.0.0", description: manifest.description, versionEpoch: 1)
        try check(PluginRepository.isUpdate(manifest, firstRoom) && !PluginRepository.isUpdate(firstRoom, manifest) &&
                  InstalledPlugins.install(firstRoom, defaults: defaults) &&
                  RoomBindingPlugin.installed(in: defaults) == firstRoom &&
                  RoomBindingPlugin.effectiveRoom(in: defaults) == "已有寝室",
                  "updates room binding preview to v1.0.0 and keeps its room")
        try check(RoomBindingPlugin.uninstall(defaults: defaults) &&
                  RoomBindingPlugin.installed(in: defaults) == nil &&
                  RoomBindingPlugin.effectiveRoom(in: defaults).isEmpty &&
                  defaults.string(forKey: "lastDeviceName") == "之前使用过的设备",
                  "uninstall clears room settings while preserving device history")

        let bundledFile = URL(fileURLWithPath: "LinYu/linyu_bundled_plugins.json")
        let bundled = try PluginRepository.parseCatalog(Data(contentsOf: bundledFile))
        try check(Set(bundled.map(\.id)) == Set([
            InstalledPlugins.nearbyID, InstalledPlugins.consumptionTrendID, InstalledPlugins.keepScreenOnID,
            InstalledPlugins.backgroundID, InstalledPlugins.runtimeLogID
        ]), "ships all five default plugins and keeps room binding optional")
        let trend = bundled.first { $0.id == InstalledPlugins.consumptionTrendID }!.manifest
        try check(trend.author == "XiaoLoad" && trend.authorGithubID == 63766325,
                  "ships the author and stable GitHub account ID")
        try check(bundled.allSatisfy {
            $0.manifest.version == "1.0.0" && $0.manifest.versionEpoch == 1
                && ($0.manifest.details?.count ?? 0) > $0.manifest.description.count
        }, "ships v1.0.0 with separate brief and detailed descriptions")
        let legacyTrend = Data("""
            {"id":"consumption-trend","name":"消费趋势","author":"LinYu","version":"1.0.0",
             "description":"查看趋势","formatVersion":1,"capabilities":["bill.consumption-trend"],
             "credit":"XiaoLoad","creditGithubId":63766325}
            """.utf8)
        let preview = try PluginRepository.parsePackage(legacyTrend)
        try check(preview.author == trend.author && preview.authorGithubID == trend.authorGithubID &&
                  preview.versionEpoch == 0 && PluginRepository.isUpdate(preview, trend),
                  "migrates stored author metadata and updates the preview to the first release")
        try check(!InstalledPlugins.install(trend, defaults: defaults, bundled: bundled),
                  "the bundled plugin is already installed")
        try check(InstalledPlugins.uninstall(trend.id, defaults: defaults, bundled: bundled) &&
                  !InstalledPlugins.uninstall(trend.id, defaults: defaults, bundled: bundled),
                  "uninstall remains disabled despite the bundled catalog")
        try check(InstalledPlugins.install(trend, defaults: defaults, bundled: bundled) &&
                  !InstalledPlugins.install(trend, defaults: defaults, bundled: bundled),
                  "the default plugin can be reinstalled offline")

        // ── 清单 v2：版本门控 + 权限声明 + 双源（与 Android 端对齐）──
        let pinnedVersion = PluginRepository.appVersionOverride
        PluginRepository.appVersionOverride = "3.1.2"
        defer { PluginRepository.appVersionOverride = pinnedVersion }

        try check(manifest.apiVersion == 1 && manifest.permissions.isEmpty && manifest.minAppVersion == nil,
                  "v1 manifest keeps working with defaults")

        func entry(_ extra: [String: Any]) throws -> [String: Any] {
            var base = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
            base["path"] = listing.path
            base["sha256"] = checksum
            for (key, value) in extra { base[key] = value }
            return base
        }
        let plainEntry = try entry([:])
        func count(_ extra: [String: Any]) throws -> Int {
            try PluginRepository.parseCatalog(catalog([try entry(extra)])).count
        }

        try check(try count(["apiVersion": 2]) == 1, "apiVersion 2 is accepted")
        try check(try count(["apiVersion": 3]) == 0, "apiVersion above client support is skipped")
        try check(try count(["minAppVersion": "1.0.0"]) == 1, "minAppVersion below current app is accepted")
        try check(try count(["minAppVersion": "99.0.0"]) == 0, "minAppVersion above current app is skipped")
        try check(try PluginRepository.parseCatalog(
                      catalog([try entry(["permissions": ["wallet.balance.read", "bill.list.read"]])]))
                      .first?.manifest.permissions == ["wallet.balance.read", "bill.list.read"],
                  "known permissions are parsed and exposed to the UI")
        try check(try count(["permissions": ["filesystem.write"]]) == 0,
                  "unknown permission is rejected (fail closed)")
        try check(try PluginRepository.parseCatalog(
                      catalog([try entry(["apiVersion": 3]), plainEntry])).count == 1,
                  "one unsupported plugin does not break the rest of the catalog")

        let v2 = PluginManifest(id: "room-binding", name: manifest.name, author: manifest.author,
                                version: manifest.version, description: manifest.description,
                                apiVersion: 2, minAppVersion: "3.1.2", permissions: ["device.room-filter"])
        let v2Data = PluginRepository.manifestData(v2)
        try check(v2Data != nil && (try PluginRepository.parsePackage(v2Data!)) == v2,
                  "v2 fields survive serialization round trip")
        try check(PluginRepository.compareVersions([3, 1, 2], [3, 1, 3]) < 0 &&
                  PluginRepository.compareVersions([3, 2, 0], [3, 1, 9]) > 0 &&
                  PluginRepository.compareVersions([3, 1, 2], [3, 1, 2]) == 0,
                  "version comparison is segment wise")
        try check(PluginRepository.repositorySources.count == 2 &&
                  PluginRepository.repositorySources[0].hasPrefix("https://raw.giteeusercontent.com/") &&
                  PluginRepository.repositorySources[1].hasPrefix("https://raw.githubusercontent.com/"),
                  "plugin sources are Gitee first and GitHub as fallback")
    }
}
