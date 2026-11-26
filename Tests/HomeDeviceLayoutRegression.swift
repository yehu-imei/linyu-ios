import Foundation

enum HomeDeviceLayoutRegression {
    static func run(check: (Bool, String) -> Void) {
        func favorite(sn: String? = "A1", mac: String? = "AA:BB:CC:DD:EE:01", project: Int?,
                      drinking: Bool = true) -> HomeFavoriteDevice? {
            HomeFavoriteDevice(snCode: sn, macAddress: mac, projectId: project, defaultProjectId: 3717,
                               isDrinkingWater: drinking, name: "饮水设备", emoji: "🚰")
        }
        guard let pending = favorite(project: nil), let primary = favorite(project: 3745),
              let otherProject = favorite(project: 3746), let wrongMAC = favorite(mac: "AABBCCDDEE99", project: 3745),
              let implicitDefault = favorite(project: nil, drinking: false) else {
            check(false, "常用设备测试样本可创建")
            return
        }

        check(favorite(sn: nil, project: 3745) == nil && favorite(mac: "", project: 3745) == nil, "收藏要求 SN 与 MAC")
        check(pending.projectId == nil && implicitDefault.projectId == 3717, "饮水收藏允许项目待确认，旧热水器兼容默认项目")
        check(pending.accepts(primary, explicitProjectId: 3745) &&
              !pending.accepts(wrongMAC, explicitProjectId: 3745) &&
              !pending.accepts(implicitDefault, explicitProjectId: nil), "待确认收藏仅凭一致台账的明确项目号启用")
        check(!primary.accepts(otherProject, explicitProjectId: 3746), "相同 SN 的其他项目不能替换收藏")

        var layout = HomeDeviceLayout()
        layout.toggleFavorite(pending)
        layout.confirmFavorite(pending, with: primary, explicitProjectId: 3745)
        layout.toggleFavorite(otherProject)
        layout.moveFavorite(otherProject.id, by: -1)
        check(layout.favorites == [otherProject, primary], "收藏更新项目号并按项目区分、排序")
        layout.toggleSection(.nearby)
        layout.moveSection(.nearby, by: -1)
        layout.moveSection(.lastUsed, by: -1)
        check(layout.hidden == [.nearby] && layout.sections == [.lastUsed, .nearby, .favorites],
              "隐藏与排序独立、首项不能越界上移")
        layout.moveSection(.favorites, by: -1, excluding: [.nearby])
        check(layout.sections == [.favorites, .nearby, .lastUsed] && layout.hidden == [.nearby],
              "附近设备插件卸载后，可见区块能重排且保留插件位置")

        let suite = "LinYu.HomeDeviceLayoutRegression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "测试可创建独立偏好存储")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        HomeDeviceLayoutStore.save(layout, owner: "1:3717:10", defaults: defaults)
        check(HomeDeviceLayoutStore.read(owner: "1:3717:10", defaults: defaults) == layout,
              "重开可恢复首页顺序、隐藏状态与收藏")
        check(HomeDeviceLayoutStore.read(owner: "2:3717:20", defaults: defaults) == HomeDeviceLayout() &&
              HomeDeviceLayoutStore.read(owner: "", defaults: defaults) == HomeDeviceLayout(),
              "不同账户及退出登录不会读取原账号收藏")
    }
}
