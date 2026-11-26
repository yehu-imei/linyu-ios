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
        try check(trend.credit == "XiaoLoad" && trend.creditGithubID == 63766325 && trend.author == "LinYu",
                  "keeps suggestion attribution separate from authorship")
        try check(!InstalledPlugins.install(trend, defaults: defaults, bundled: bundled),
                  "the bundled plugin is already installed")
        try check(InstalledPlugins.uninstall(trend.id, defaults: defaults, bundled: bundled) &&
                  !InstalledPlugins.uninstall(trend.id, defaults: defaults, bundled: bundled),
                  "uninstall remains disabled despite the bundled catalog")
        try check(InstalledPlugins.install(trend, defaults: defaults, bundled: bundled) &&
                  !InstalledPlugins.install(trend, defaults: defaults, bundled: bundled),
                  "the default plugin can be reinstalled offline")
    }
}
