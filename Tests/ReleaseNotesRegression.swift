import Foundation

@main struct ReleaseNotesRegression {
    static func main() throws {
        var failures = 0
        func check(_ result: Bool, _ message: String) {
            print("\(result ? "PASS" : "FAIL"): \(message)")
            if !result { failures += 1 }
        }
        let doc = try String(contentsOfFile: "docs/APP_CHANGELOG.md", encoding: .utf8)
        let notes = UserReleaseNotes.parse(doc)
        check(notes.count == 14 && notes.first?.version == "v3.1.0" && notes.last?.version == "v1.0", "完整读取全部已发布历史版本，不受 Release 十条限制")
        check(!notes.contains { $0.version == "v3.1.1" }, "待发布版本不进入应用日志或更新判断")
        check(notes.allSatisfy { !$0.items.isEmpty && $0.items.count <= 5 && $0.items.allSatisfy { $0.count <= 50 } }, "每版最多五条简短用户文案")
        check(!notes.flatMap(\.items).contains { $0.contains("后台用水监控") || $0.contains("单格开关") }, "iOS 不展示 Android 专属能力")
        let android = UserReleaseNotes.parse(doc, platform: "Android")
        check(android.count == 14 && android.flatMap(\.items).contains { $0.contains("后台用水监控") }, "Android 日志保留平台专属能力")
        check(!android.flatMap(\.items).contains { $0.contains("通知、扫码权限") }, "Android 不混入 iOS 适配记录")
        let sample = "<!-- linyu-release-notes:1 -->\n## v3.2.0 | 2026-11-05\n- 改善体验\n- 兼容新设备\n- [iOS] 精简提示\n## v3.3.0 | 待发布\n- 未发布\n"
        check(UserReleaseNotes.parse(sample).first?.items.count == 3, "普通优化与兼容条目完整保留，不靠新增修复关键词")
        check(UserReleaseNotes.parse("<html>error</html>").isEmpty, "远程错误页面不能覆盖离线日志")
        check(UserReleaseNotes.merge(preferred: [], fallback: notes) == notes, "失败刷新保留离线日志")
        check(UserReleaseNotes.merge(preferred: UserReleaseNotes.parse(sample), fallback: notes).count == 15, "新增远程版本不丢失旧版本")
        let crlf = doc.replacingOccurrences(of: "\n", with: "\r\n")
        check(UserReleaseNotes.parse(crlf) == notes, "Windows 换行不影响日志读取")
        let legacy = UserReleaseNote(version: "v3.1.0", date: "2026-09-30", items: ["支持 Android 8.0。 ", "消费 0.025 元。", "区分“结算中”。金额准确。"])
        check(legacy.text == "• 支持 Android 8.0\n• 消费 0.025 元\n• 区分“结算中”。金额准确", "旧缓存只去条目末尾句号，保留内部标点和小数点")
        check(notes.flatMap(\.items).allSatisfy { !$0.hasSuffix("。") }, "内置用户日志条目不带结尾句号")
        if failures > 0 { fatalError("\(failures) release note checks failed") }
    }
}
