import Foundation

struct UserReleaseNote: Equatable, Identifiable {
    var version: String
    var date: String
    var items: [String]
    var id: String { version }
    var text: String { items.map { "• " + $0 }.joined(separator: "\n") }
}

/// 专用用户日志格式。只识别版本、日期及显式平台标签，不按“新增/修复”等关键词截取。
enum UserReleaseNotes {
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/yehu-imei/linyu/master/docs/APP_CHANGELOG.md")!
    static func parse(_ source: String, platform: String = "iOS") -> [UserReleaseNote] {
        guard source.utf8.count <= 131_072, source.contains("<!-- linyu-release-notes:1 -->") else { return [] }
        var result: [UserReleaseNote] = []
        var current: UserReleaseNote?
        func flush() {
            if let item = current, !item.items.isEmpty, !result.contains(where: { $0.version == item.version }) { result.append(item) }
            current = nil
        }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                let fields = line.dropFirst(3).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == 2,
                      fields[0].range(of: #"^v[0-9]+(?:\.[0-9]+){1,2}$"#, options: .regularExpression) != nil,
                      fields[1].range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { continue }
                current = UserReleaseNote(version: fields[0], date: fields[1], items: [])
            } else if current != nil, line.hasPrefix("- ") {
                var item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                for tag in ["Android", "iOS"] where item.hasPrefix("[\(tag)] ") {
                    item = tag == platform ? String(item.dropFirst(tag.count + 3)) : ""
                    break
                }
                if !item.isEmpty { current?.items.append(item) }
            }
        }
        flush()
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
    static func merge(preferred: [UserReleaseNote], fallback: [UserReleaseNote]) -> [UserReleaseNote] {
        var versions = Dictionary(fallback.map { ($0.version, $0) }, uniquingKeysWith: { first, _ in first })
        for item in preferred { versions[item.version] = item }
        return versions.values.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
    static var bundled: [UserReleaseNote] {
        guard let url = Bundle.main.url(forResource: "APP_CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }
}
