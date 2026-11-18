import Foundation

/// 已登录会话内，服务端确认关联的项目账户。不携带或持久化登录凭证。
struct ProjectAuthContext: Equatable {
    let projectId: String
    let accountId: String
    let owner: String
    let generation: UUID

    static func owner(userId: String, projectId: String, accountId: String) -> String {
        "\(userId):\(projectId):\(accountId)"
    }
}

struct ProjectAccount: Decodable {
    let userId: Int?
    let projectId: Int?
    let accountId: Int?
}

enum ProjectAuthPolicy {
    static func accounts(_ projects: [ProjectAccount], userId: String,
                         defaultContext: ProjectAuthContext) -> [String: String] {
        let valid = projects.filter { row in
            (row.userId == nil || row.userId == 0 || row.userId.map(String.init) == userId)
                && (row.projectId ?? 0) > 0 && (row.accountId ?? 0) > 0
        }
        let grouped = Dictionary(grouping: valid, by: \.projectId)
        var result: [String: String] = [:]
        for (project, rows) in grouped {
            guard let project else { continue }
            let accountIDs = Set(rows.compactMap(\.accountId))
            if accountIDs.count == 1, let account = accountIDs.first {
                result[String(project)] = String(account)
            }
        }
        result[defaultContext.projectId] = defaultContext.accountId
        return result
    }
}
