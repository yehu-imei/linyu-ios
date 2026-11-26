import Foundation

/// 「我的」页里可编辑的卡片类型（声明顺序即默认顺序）
enum UserCardType: String, CaseIterable {
    case account
    case useCode
    case notify
    case trend
    case keepScreenOn
    case background
    case boundRoom
    case update
    case about
    case log
    case featureManagement

    var title: String {
        switch self {
        case .account: return "账号信息"
        case .useCode: return "使用码"
        case .notify: return "通知"
        case .trend: return "消费趋势"
        case .keepScreenOn: return "屏幕常亮"
        case .background: return "背景装扮"
        case .boundRoom: return "绑定寝室"
        case .update: return "软件更新"
        case .about: return "关于项目"
        case .log: return "运行日志"
        case .featureManagement: return "功能管理"
        }
    }
}

/// 卡片分页策略 —— 逐条对照 Android 的 `UserCardLayoutPolicy`
enum UserCardLayout {
    struct Pages: Equatable {
        var profile: [UserCardType]
        var settings: [UserCardType]
        var features: [UserCardType]
    }

    enum Destination: Equatable {
        case profile
        case settings
        case features
    }

    static let profileDefaults: [UserCardType] = [.account, .useCode, .boundRoom]
    static let settingsDefaults: [UserCardType] = [.featureManagement, .about, .update]
    static let featureDefaults: [UserCardType] = [.notify, .trend, .keepScreenOn, .background, .log]

    /// 功能管理布局未保存时，保留旧设置卡片的相对顺序并归入功能管理。
    /// 空字符串表示用户已把功能全部移出，恢复时继续使用空分组。
    static func restorePages(profileSaved: String, settingsSaved: String, featuresSaved: String? = nil) -> Pages {
        let group = UserCardType.featureManagement
        var profile = unique(parse(profileSaved).filter { $0 != group })
        let previousSettings = parse(settingsSaved).filter { !profile.contains($0) }
        let features: [UserCardType]
        if let featuresSaved {
            features = unique(parse(featuresSaved).filter { featureDefaults.contains($0) && !profile.contains($0) })
        } else {
            var previousFeatures = previousSettings.filter { featureDefaults.contains($0) }
            if let background = previousFeatures.firstIndex(of: .background), !previousFeatures.contains(.keepScreenOn) {
                previousFeatures.insert(.keepScreenOn, at: background)
            }
            features = unique(previousFeatures + featureDefaults).filter { !profile.contains($0) }
        }
        var settings = unique(previousSettings.compactMap { card in
            if !features.contains(card) { return card }
            return featuresSaved == nil ? group : nil
        })
        var assigned = Set(profile + settings + features)
        profile += profileDefaults.filter { assigned.insert($0).inserted }
        settings += settingsDefaults.filter { assigned.insert($0).inserted }
        settings += featureDefaults.filter { assigned.insert($0).inserted }
        return Pages(profile: profile, settings: settings, features: features)
    }

    static func move(_ type: UserCardType, to destination: Destination, in pages: Pages) -> Pages {
        guard type != .featureManagement else { return pages }
        if destination == .features, !featureDefaults.contains(type) { return pages }

        var result = Pages(
            profile: pages.profile.filter { $0 != type },
            settings: pages.settings.filter { $0 != type },
            features: pages.features.filter { $0 != type }
        )
        switch destination {
        case .profile: result.profile.append(type)
        case .settings: result.settings.append(type)
        case .features: result.features.append(type)
        }
        return result
    }

    static func loadPages(defaults: UserDefaults = .standard) -> Pages {
        if let saved = defaults.dictionary(forKey: "userCardPages") as? [String: String] {
            return restorePages(profileSaved: saved["profile"] ?? "", settingsSaved: saved["settings"] ?? "",
                                featuresSaved: saved["features"])
        }
        return restorePages(profileSaved: defaults.string(forKey: "userProfileCardOrder") ?? "",
                            settingsSaved: defaults.string(forKey: "userSettingsCardOrder") ?? "")
    }

    static func savePages(_ pages: Pages, defaults: UserDefaults = .standard) {
        defaults.set([
            "profile": serialize(pages.profile),
            "settings": serialize(pages.settings),
            "features": serialize(pages.features)
        ], forKey: "userCardPages")
    }

    static func serialize(_ list: [UserCardType]) -> String {
        list.map(\.rawValue).joined(separator: ",")
    }

    private static func parse(_ saved: String) -> [UserCardType] {
        saved.split(separator: ",").compactMap {
            UserCardType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func unique(_ list: [UserCardType]) -> [UserCardType] {
        var seen = Set<UserCardType>()
        return list.filter { seen.insert($0).inserted }
    }

    static func saveHidden(_ set: Set<String>, key: String) {
        UserDefaults.standard.set(set.joined(separator: ","), forKey: key)
    }

    static func loadHidden(_ key: String) -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func swap(_ first: UserCardType, with second: UserCardType, in list: [UserCardType]) -> [UserCardType] {
        guard let firstIndex = list.firstIndex(of: first), let secondIndex = list.firstIndex(of: second),
              firstIndex != secondIndex else { return list }
        var result = list
        result.swapAt(firstIndex, secondIndex)
        return result
    }
}
