import Foundation

/// 按账号和项目月份保存成功的响应，失败时可各自回读。
enum BillHistoryCache {
    private static func key(_ owner: String) -> String { "billCache_" + owner }
    static func read(owner: String, defaults: UserDefaults = .standard) -> [BillDTO]? {
        guard !owner.isEmpty, let data = defaults.data(forKey: key(owner)) else { return nil }
        return try? JSONDecoder().decode([BillDTO].self, from: data)
    }
    static func save(_ bills: [BillDTO], owner: String, defaults: UserDefaults = .standard) {
        guard !owner.isEmpty, let data = try? JSONEncoder().encode(bills) else { return }
        defaults.set(data, forKey: key(owner))
    }

    static func monthOwner(_ project: ProjectAuthContext, month: String) -> String {
        "\(project.owner)/\(project.projectId)/\(project.accountId)/\(month)"
    }

    static func newestFirst(_ bills: [BillDTO], mergeProjects: Bool = true) -> [BillDTO] {
        var seenOrderNumbers = Set<String>()
        var seenRows = Set<String>()
        return bills.filter { bill in
            if let no = bill.orderNo, !no.isEmpty, no != "0" {
                let scope = mergeProjects ? "" : "\(bill.sourceProjectId ?? ""):\(bill.sourceAccountId ?? ""):"
                return seenOrderNumbers.insert(scope + "\(no):\(bill.consumeDate ?? "")").inserted
            }
            return seenRows.insert(bill.id).inserted
        }.sorted { ($0.consumeDate ?? "") > ($1.consumeDate ?? "") }
    }
}
