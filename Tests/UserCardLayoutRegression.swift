import Foundation

enum UserCardLayoutRegression {
    static func run(check: (Bool, String) -> Void) {
        let defaults = UserCardLayout.restorePages(profileSaved: "", settingsSaved: "")
        check(defaults.profile == [.account, .useCode, .boundRoom], "我的页面默认顺序包含绑定寝室的位置")
        check(defaults.settings == [.featureManagement, .background, .log, .about, .update], "设置独立显示背景与日志")
        check(defaults.features == [.notify, .trend, .keepScreenOn], "开关管理只包含通知、消费趋势与屏幕常亮")
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
        check(previous.settings == [.background, .about, .featureManagement, .update] &&
              previous.features == [.notify, .trend, .keepScreenOn], "旧设置只归组开关卡片，背景保留原位置")
        let previousGroup = UserCardLayout.restorePages(profileSaved: "account,useCode,boundRoom", settingsSaved: "about,featureManagement,update",
                                                        featuresSaved: "keepScreenOn,log,trend,background,notify")
        check(previousGroup.settings == [.about, .featureManagement, .log, .background, .update] &&
              previousGroup.features == [.keepScreenOn, .trend, .notify], "旧组内背景和日志按相对顺序移到设置")
        let previousPlacement = UserCardLayout.restorePages(profileSaved: "account,log,useCode", settingsSaved: "background,about,featureManagement,update",
                                                            featuresSaved: "log,background,notify,trend,keepScreenOn")
        check(previousPlacement.profile.prefix(3) == [.account, .log, .useCode] &&
              previousPlacement.settings == [.background, .about, .featureManagement, .update], "迁移保留背景与日志在其他页面上的已有位置")

        let removed = UserCardLayout.move(.trend, to: .settings, in: defaults)
        check(!removed.features.contains(.trend) && removed.settings.last == .trend, "从开关管理移出到设置")
        let added = UserCardLayout.move(.trend, to: .features, in: removed)
        check(!added.settings.contains(.trend) && added.features.last == .trend, "移入开关管理时仅保留一份卡片")
        check(UserCardLayout.move(.featureManagement, to: .profile, in: defaults) == defaults &&
              UserCardLayout.move(.account, to: .features, in: defaults) == defaults &&
              UserCardLayout.move(.background, to: .features, in: defaults) == defaults &&
              UserCardLayout.move(.log, to: .features, in: defaults) == defaults, "卡片只能移动到支持的位置")

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
              "开关管理移空后重启不会把卡片归回组内")
    }
}
