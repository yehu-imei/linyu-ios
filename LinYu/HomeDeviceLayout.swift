import Foundation

enum HomeDeviceSection: String, Codable, CaseIterable, Identifiable {
    case lastUsed, favorites, nearby

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastUsed: return "上次使用设备"
        case .favorites: return "常用设备"
        case .nearby: return "附近设备"
        }
    }
}

/// 台账有项目号时用「项目 + SN」区分设备。缺项目的收藏仍能保留，使用前需核对台账。
struct HomeFavoriteDevice: Codable, Equatable, Identifiable {
    let snCode: String
    let macAddress: String
    let projectId: Int?
    let name: String
    let emoji: String

    init?(snCode: String?, macAddress: String?, projectId: Int?, defaultProjectId: Int?,
          isDrinkingWater: Bool, name: String, emoji: String) {
        guard let sn = snCode?.trimmingCharacters(in: .whitespacesAndNewlines), !sn.isEmpty,
              let mac = macAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !mac.isEmpty
        else { return nil }
        self.snCode = sn
        self.macAddress = mac
        if let projectId, projectId > 0 {
            self.projectId = projectId
        } else if !isDrinkingWater, let defaultProjectId, defaultProjectId > 0 {
            self.projectId = defaultProjectId
        } else {
            self.projectId = nil
        }
        self.name = name
        self.emoji = emoji
    }

    var id: String {
        if let projectId { return "\(projectId):\(snCode)" }
        return "pending:\(snCode):\(addressKey)"
    }

    private var addressKey: String { DeviceAddress.normalize(macAddress) ?? macAddress.uppercased() }

    func matchesIdentity(sn: String, mac: String) -> Bool {
        snCode == sn && addressKey == (DeviceAddress.normalize(mac) ?? mac.uppercased())
    }

    func matches(_ other: Self) -> Bool {
        if projectId != nil, other.projectId != nil { return id == other.id }
        return matchesIdentity(sn: other.snCode, mac: other.macAddress)
    }

    func accepts(_ fresh: Self, explicitProjectId: Int?) -> Bool {
        guard matches(fresh) else { return false }
        if let projectId { return fresh.projectId == projectId }
        return explicitProjectId.map { $0 > 0 && $0 == fresh.projectId } ?? false
    }
}

struct HomeDeviceLayout: Codable, Equatable {
    var favorites: [HomeFavoriteDevice] = []
    var hidden: Set<HomeDeviceSection> = []
    private var order: [HomeDeviceSection] = HomeDeviceSection.allCases

    var sections: [HomeDeviceSection] {
        var seen = Set<HomeDeviceSection>()
        return (order + HomeDeviceSection.allCases).filter { seen.insert($0).inserted }
    }

    mutating func toggleSection(_ section: HomeDeviceSection) {
        if hidden.remove(section) == nil { hidden.insert(section) }
    }

    mutating func moveSection(_ section: HomeDeviceSection, by offset: Int) {
        var ordered = sections
        guard let index = ordered.firstIndex(of: section), Self.move(&ordered, from: index, by: offset)
        else { return }
        order = ordered
    }

    func favorite(matching candidate: HomeFavoriteDevice) -> HomeFavoriteDevice? {
        if let exact = favorites.first(where: { $0.id == candidate.id }) { return exact }
        let matches = favorites.filter { $0.matches(candidate) }
        return matches.count == 1 ? matches[0] : nil
    }

    mutating func toggleFavorite(_ candidate: HomeFavoriteDevice) {
        if let existing = favorite(matching: candidate) { removeFavorite(existing.id) }
        else { favorites.append(candidate) }
    }

    mutating func removeFavorite(_ id: String) {
        favorites.removeAll { $0.id == id }
    }

    mutating func moveFavorite(_ id: String, by offset: Int) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        _ = Self.move(&favorites, from: index, by: offset)
    }

    mutating func confirmFavorite(_ saved: HomeFavoriteDevice, with fresh: HomeFavoriteDevice, explicitProjectId: Int?) {
        guard saved.projectId == nil, saved.accepts(fresh, explicitProjectId: explicitProjectId),
              let index = favorites.firstIndex(where: { $0.id == saved.id }) else { return }
        favorites[index] = fresh
        var seen = Set<String>()
        favorites = favorites.filter { seen.insert($0.id).inserted }
    }

    private static func move<T>(_ items: inout [T], from index: Int, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1, items.indices.contains(index + offset) else { return false }
        items.swapAt(index, index + offset)
        return true
    }
}

/// 每个账户有自己的首页设置，换号不会读到另一个账户的设备。
enum HomeDeviceLayoutStore {
    static func read(owner: String, defaults: UserDefaults = .standard) -> HomeDeviceLayout {
        guard !owner.isEmpty, let data = defaults.data(forKey: key(owner)),
              let layout = try? JSONDecoder().decode(HomeDeviceLayout.self, from: data) else {
            return HomeDeviceLayout()
        }
        return layout
    }

    static func save(_ layout: HomeDeviceLayout, owner: String, defaults: UserDefaults = .standard) {
        guard !owner.isEmpty, let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: key(owner))
    }

    private static func key(_ owner: String) -> String { "homeDeviceLayout.\(owner)" }
}
