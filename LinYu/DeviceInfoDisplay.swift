import SwiftUI

/// 设备模型的**显示与筛选**逻辑 —— 逐条对照 Android 的 `model/DeviceModels.kt`。
///
/// 这些不是"格式化工具"，而是踩过坑的判据，注释里的历史不能丢：
/// - `isDrinkingWater` 必须是**正向判据**（只认饮水机独有词）
/// - `roomKey` 必须从**原始设备名**取，不能从 `displayName` 取
/// - `roomKey` 必须**幂等**
extension DeviceInfo {

    // MARK: 展示名

    /// 去掉「热水表-」「洗手台54-」这类前缀，把 `-` 换成空格。
    var displayName: String {
        // 优先用原名，缺失时退回 snCode
        let name = deviceName ?? deviceDesc ?? snCode ?? "未知设备"
        let formatted = Self.formatDeviceName(name)
        return formatted.isEmpty ? name : formatted
    }

    /// 仅位置（与 displayName 相同，语义上给"使用页副标题"用）
    var locationOnly: String { displayName }

    static func formatDeviceName(_ name: String) -> String {
        var s = name
        // 1. 先处理「热水器 / 热水表 / 热水变」——否则下面的规则会先吃掉"热水"
        s = s.replacingOccurrences(of: "^热水[器表变][- ]*", with: "", options: .regularExpression)
        // 2. 饮水机前缀
        s = s.replacingOccurrences(of: "^直饮[- ]*(开水|冷水|热水|温水)[- ]*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^(开水|冷水|温水)[- ]*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^(平衡|直饮水?机?)[- ]*", with: "", options: .regularExpression)
        // 3. 洗手台前缀
        s = s.replacingOccurrences(of: "^洗手台\\d*[- ]*", with: "", options: .regularExpression)
        // 4. 尾部水类型
        s = s.replacingOccurrences(of: "[- ](直饮)?(开水|冷水|热水|温水)$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "-\\d+层-", with: "-", options: .regularExpression)
        s = s.replacingOccurrences(of: "洗手台$", with: "房", options: .regularExpression)
        s = s.replacingOccurrences(of: "-", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 类型判定

    /// 同 Android：小类名称明确时优先，未知温度保留未确认状态。
    var waterTemperature: String? {
        func classify(_ text: String) -> String? {
            if text.contains("温水") { return "温水" }
            if text.contains("冷水") || text.contains("凉水") { return "冷水" }
            if text.contains("热水") || text.contains("开水") { return "热水" }
            return nil
        }
        return classify(smallTypeName ?? "") ?? classify(deviceName ?? "")
    }

    var isWashbasin: Bool {
        (deviceName ?? "").hasPrefix("洗手台")
    }

    /// 类型名：饮水机 / 洗手台 / 热水器
    var typeName: String {
        if isDrinkingWater { return "饮水机" }
        if isWashbasin { return "洗手台" }
        return "热水器"
    }

    /// 类型 emoji：♨️ / ❄️ / 🪥 / 🚿
    var typeEmoji: String {
        if isDrinkingWater {
            switch waterTemperature {
            case "热水": return "♨️"
            case "冷水": return "❄️"
            default: return "🚰"
            }
        }
        if isWashbasin { return "🪥" }
        return "🚿"
    }

    /// 类型说明（小组件副标题、账单标签用）
    var typeLabel: String {
        if isDrinkingWater { return waterTemperature.map { "直饮水机 · \($0)" } ?? "直饮水机" }
        if isWashbasin { return "洗手台热水器" }
        return "卫生间热水器"
    }

    var typeColor: Color {
        if isDrinkingWater { return Color(hex: 0x10B981) }
        if isWashbasin { return Color(hex: 0xFFCC80) }
        return Color(hex: 0x2563EB)
    }

    /// 用水状态文案
    var statusText: String {
        if isDrinkingWater { return waterTemperature.map { "正在接\($0)" } ?? "正在接水" }
        if isWashbasin { return "正在洗漱中" }
        return "正在沐浴中"
    }

    // MARK: 寝室筛选

    private static let roomPrefixPattern =
        "^(热水[器表变]|洗手台\\d*|直饮(?:开水|冷水|热水|温水)|开水机?|冷水|温水|平衡|直饮水?机?)[- ]*"

    private static let roomSuffixPattern =
        "[- ]*(?:热水器|热水表|洗手台|卫生间|洗漱台|浴室|淋浴间|淋浴|饮水机|直饮水|开水机|开水器|水龙头|水房)$"

    /// 「寝室关键词」——判断两台设备在不在同一间，就比这个。
    ///
    /// | 设备名 | 关键词 |
    /// |---|---|
    /// | `热水表-龙川北苑-3号楼南-3层-320房` | `龙川北苑-3号楼南-3层-320` |
    /// | `洗手台54-龙川北苑-3号楼南-3层-320洗手台` | `龙川北苑-3号楼南-3层-320` |
    ///
    /// ⚠️ 三条不能动的规矩：
    /// 1. **从原始设备名取**，不能从 `displayName` 取（后者会把 `洗手台` 改写成 `房`）
    /// 2. 什么都不补、什么都不改（曾"剥完只剩数字就补房字"，导致筛选落空）
    /// 3. 必须幂等（绑定值就是键，筛选时会再走一次）
    static func roomKey(_ name: String) -> String? {
        var s = name.replacingOccurrences(of: roomPrefixPattern, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: roomSuffixPattern, with: "", options: .regularExpression)
        if s.hasSuffix("房") { s.removeLast() }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " 　-_"))
        s = s.replacingOccurrences(of: "[-_\\s　]+", with: "-", options: .regularExpression)
        s = s.lowercased()
        return s.isEmpty ? nil : s
    }

    /// 寝室筛选的**唯一判据**（首页、快照、小组件都走这一个）
    static func inSameRoom(boundKey: String, deviceName: String) -> Bool {
        let bound = boundKey.trimmingCharacters(in: .whitespaces)
        if bound.isEmpty { return true }
        guard let key = roomKey(bound) else { return true }
        guard let device = roomKey(deviceName) else { return true }
        return device == key || device.hasSuffix("-\(key)")
    }
}
