import Foundation

enum UserCardLayoutRegression {
    static func run(check: (Bool, String) -> Void) {
        let defaults = UserCardLayout.restorePages(profileSaved: "", settingsSaved: "")
        check(defaults.profile == [.account, .useCode, .boundRoom], "我的页面默认顺序包含绑定寝室的位置")
        check(defaults.settings == [.featureManagement, .about, .update], "设置默认使用功能管理分组")
        check(defaults.features == [.notify, .trend, .keepScreenOn, .background, .log], "功能管理默认顺序与安卓一致")
        let moved = UserCardLayout.move(.account, to: .settings, in: defaults)
        check(moved.profile == [.useCode, .boundRoom] && moved.settings.last == .account, "移到设置放在末尾")
        let restored = UserCardLayout.restorePages(profileSaved: UserCardLayout.serialize(moved.profile),
                                                   settingsSaved: UserCardLayout.serialize(moved.settings),
                                                   featuresSaved: UserCardLayout.serialize(moved.features))
        check(restored == moved, "重启恢复保留卡片归属和顺序")
        let back = UserCardLayout.move(.account, to: .profile, in: moved)
        check(back.profile == [.useCode, .boundRoom, .account] && !back.settings.contains(.account), "移回我的追加且不重复")
        let broken = UserCardLayout.restorePages(profileSaved: " account,account,unknown,log ", settingsSaved: "log,notify,notify")
        let all = broken.profile + broken.settings + broken.features
        check(all.count == UserCardType.allCases.count && Set(all).count == all.count, "重复未知及跨页冲突恢复后每卡恰好一份")
        check(broken.profile.prefix(2) == [.account, .log] && !broken.features.contains(.log), "旧版已移到我的卡片留在原页")
        let previous = UserCardLayout.restorePages(profileSaved: "account,log,useCode", settingsSaved: "background,about,notify,trend")
        check(previous.settings == [.featureManagement, .about, .update] &&
              previous.features == [.keepScreenOn, .background, .notify, .trend], "旧设置归组时保留顺序，常亮置于背景之前")

        let removed = UserCardLayout.move(.trend, to: .settings, in: defaults)
        check(!removed.features.contains(.trend) && removed.settings.last == .trend, "从功能管理移出到设置")
        let added = UserCardLayout.move(.trend, to: .features, in: removed)
        check(!added.settings.contains(.trend) && added.features.last == .trend, "移入功能管理时仅保留一份卡片")
        check(UserCardLayout.move(.featureManagement, to: .profile, in: defaults) == defaults &&
              UserCardLayout.move(.account, to: .features, in: defaults) == defaults, "卡片只能移动到支持的位置")

        let pluginSlot: [UserCardType] = [.account, .boundRoom, .useCode]
        check(UserCardLayout.swap(.account, with: .useCode, in: pluginSlot) == [.useCode, .boundRoom, .account],
              "插件未安装时调整相邻可见卡片，保留插件槽位")
        check(UserCardLayout.swap(.account, with: .trend, in: pluginSlot) == pluginSlot, "失效位置不会重排卡片")

        let key = "LinYu.UserCardLayoutRegression.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: key) else {
            check(false, "建立卡片布局测试数据")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: key) }
        testDefaults.set("account,log,useCode", forKey: "userProfileCardOrder")
        testDefaults.set("background,about,notify,trend", forKey: "userSettingsCardOrder")
        check(UserCardLayout.loadPages(defaults: testDefaults) == previous, "升级读取已有卡片设置")
        let emptyGroup = defaults.features.reduce(defaults) { UserCardLayout.move($1, to: .settings, in: $0) }
        UserCardLayout.savePages(emptyGroup, defaults: testDefaults)
        check(emptyGroup.features.isEmpty && UserCardLayout.loadPages(defaults: testDefaults) == emptyGroup,
              "功能管理移空后重启不会把卡片归回组内")
    }
}
