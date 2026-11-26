import Foundation

/// 账单 / 钱包 / 学籍信息 —— 对照 Android 的 `MainViewModel.loadBills/loadWallet/loadAccountInfo`。
enum BillService {

    /// 拉**最近 3 个月**的账单并合并。
    ///
    /// 为什么要 3 个月：账单列表接口一个月一拉，只拉当月的话
    /// 月初打开 App 会看到空列表（像是「没消费过」），而消费趋势里 7 天视图也会缺数据。
    /// Android 那边同样拉 3 个月（`for (i in 0..2)`）。
    static func loadHistory() async -> [BillDTO] {
        let generation = SessionWork.generation ?? Session.shared.requestGeneration
        // 结算兜底保留已成功取得的月份，不因其它月份失败丢弃有效订单。
        var all: [BillDTO] = []
        for month in recentMonths() {
            guard SessionWork.isCurrent(generation) else { return [] }
            if let list = try? await loadMonth(month) { all.append(contentsOf: list) }
        }
        guard SessionWork.isCurrent(generation) else { return [] }
        return all
    }

    struct History {
        var bills: [BillDTO] = []
        var defaultBills: [BillDTO] = []
        var fresh: [BillDTO] = []
        var hasDefault = false
        var hadFailure = false
    }

    @MainActor static func loadMergedHistory(legacyDefault: [BillDTO]?) async throws -> History {
        let defaultProject = try ProjectAuthRepository.defaultContext()
        let projects = try await ProjectAuthRepository.projectAccounts()
        let months = recentMonths()
        var history = History()
        for project in projects {
            let isDefault = project.projectId == defaultProject.projectId && project.accountId == defaultProject.accountId
            let responses = await withTaskGroup(of: (String, [BillDTO]?).self) { group in
                for month in months {
                    group.addTask { (month, try? await loadMonth(month, project: project)) }
                }
                var results: [String: [BillDTO]] = [:]
                for await (month, bills) in group { results[month] = bills }
                return results
            }
            guard SessionWork.isCurrent(defaultProject.generation) else { throw CancellationError() }
            if isDefault, responses.isEmpty, let legacyDefault {
                history.bills += legacyDefault
                history.defaultBills = legacyDefault
                history.hasDefault = true
                history.hadFailure = true
                continue
            }
            for month in months {
                let owner = BillHistoryCache.monthOwner(project, month: month)
                let rows: [BillDTO]?
                if let fetched = responses[month] {
                    rows = fetched
                    history.fresh += fetched
                    BillHistoryCache.save(fetched, owner: owner)
                } else {
                    history.hadFailure = true
                    rows = BillHistoryCache.read(owner: owner) ?? (
                        isDefault ? legacyDefault?.filter { $0.consumeDate?.hasPrefix(month) == true } : nil
                    )
                }
                if let rows {
                    history.bills += rows
                    if isDefault {
                        history.hasDefault = true
                        history.defaultBills += rows
                    }
                }
            }
        }
        history.bills = BillHistoryCache.newestFirst(history.bills)
        history.defaultBills = BillHistoryCache.newestFirst(history.defaultBills)
        history.fresh = BillHistoryCache.newestFirst(history.fresh, mergeProjects: false)
        return history
    }

    /// 拉最近 3 个月账单；**任一月请求失败就返回 nil**
    ///
    /// 和 `loadHistory()` 的区别：后者把失败仍当空表合并，适合帛页面兜底、不适合对账。
    /// 对账拿到的必须是完整账单，否则「没匹配到」可能只是因为那一个月没拉到，
    /// 于是把一条明明已经结算的记录当成「仍然待对账」一直留着。
    static func loadHistoryOrNil() async -> [BillDTO]? {
        let generation = SessionWork.generation ?? Session.shared.requestGeneration
        var all: [BillDTO] = []
        for month in recentMonths() {
            guard SessionWork.isCurrent(generation) else { return nil }
            do {
                all.append(contentsOf: try await loadMonth(month))
            } catch {
                AppLog.shared.w("账单月份 \(month) 拉取失败：\(error.localizedDescription)")
                return nil
            }
        }
        guard SessionWork.isCurrent(generation) else { return nil }
        return all
    }

    private static func recentMonths() -> [String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM"

        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")

        let now = Date()
        return (0 ..< 3).map { i in
            let date = cal.date(byAdding: .month, value: -i, to: now) ?? now
            return fmt.string(from: date)
        }
    }

    /// 默认项目保留原查询类型，其他授权项目读取设备消费记录。
    static func loadMonth(_ month: String, project: ProjectAuthContext? = nil, requestType: String? = nil) async throws -> [BillDTO] {
        let kind = requestType ?? (project.map { $0.projectId != Session.shared.projectId } == true ? "0" : "2")
        let data = try await ApiClient.get(
            "/order/query/account/bill/list",
            query: ["month": month, "billRequestType": kind],
            project: project,
            tag: "bills"
        )
        let resp = try ApiClient.decode([BillItem].self, from: data, path: "billList")
        guard let rows = resp.data else { throw ApiError.transport("账单数据暂不可用") }
        return rows.compactMap { row in
            guard var bill = row.consumeBillDTO,
                  let date = [bill.consumeDate, bill.dealDate, bill.createTime]
                    .compactMap({ $0 }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            bill.consumeDate = date.replacingOccurrences(of: "T", with: " ")
            if bill.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                bill.description = bill.deviceDescription
            }
            if bill.yuan == nil || bill.yuan == 0,
               let third = bill.thirdTradeMoney.flatMap(Double.init), third.isFinite, third > 0 {
                bill.consumeMoney = bill.thirdTradeMoney
            }
            bill.sourceProjectId = project?.projectId
            bill.sourceAccountId = project?.accountId
            return bill
        }
    }

    @MainActor static func loadPendingHistory(_ pending: [PendingSettlement]) async -> [BillDTO] {
        guard let defaultProject = try? ProjectAuthRepository.defaultContext() else { return [] }
        var windows: [String: Set<String>] = [:]
        var scopes: [String: ProjectAuthContext] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM"
        for item in pending {
            guard item.authOwner == nil || item.authOwner == defaultProject.owner else { continue }
            let project: ProjectAuthContext
            if let projectId = item.projectId, let accountId = item.accountId {
                guard let resolved = try? await ProjectAuthRepository.context(projectId: projectId, accountId: accountId)
                else { continue }
                project = resolved
            } else if item.projectId == nil, item.accountId == nil {
                project = defaultProject
            } else { continue }
            let key = "\(project.projectId):\(project.accountId)"
            scopes[key] = project
            for time in [item.startedAt, item.createdAt] where time > 0 {
                windows[key, default: []].insert(dateFormatter.string(from: Date(timeIntervalSince1970: Double(time) / 1000)))
            }
        }
        var result: [BillDTO] = []
        for (key, months) in windows {
            guard SessionWork.isCurrent(defaultProject.generation), let project = scopes[key] else { return [] }
            for month in months.sorted() {
                if let rows = try? await loadMonth(month, project: project) { result += rows }
            }
        }
        guard SessionWork.isCurrent(defaultProject.generation) else { return [] }
        return BillHistoryCache.newestFirst(result, mergeProjects: false)
    }

    /// 在最近的账单里找某一单（结算的兜底路径）
    static func findBill(orderNo: String, snCode: String) async -> BillDTO? {
        let all = await loadHistory()
        if !orderNo.isEmpty, let hit = all.first(where: { $0.orderNo == orderNo }) {
            return hit
        }
        if !snCode.isEmpty, let hit = all.first(where: { $0.deviceSnCode == snCode }) {
            return hit
        }
        return nil
    }

    // MARK: - 钱包 / 一卡通

    /// GET + 解码，失败返回 nil（这些接口失败都不该打断页面）
    private static func fetch<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [String: String] = [:],
        tag: String
    ) async -> APIResponse<T>? {
        do {
            let data = try await ApiClient.get(path, query: query, tag: tag)
            let resp = try ApiClient.decode(type, from: data, path: path)
            return resp.success ? resp : nil
        } catch {
            AppLog.shared.w("\(path) 请求/解析失败：\(error.localizedDescription)")
            return nil
        }
    }

    static func loadWallet() async -> WalletData? {
        await fetch(WalletData.self, path: "/account/wallet", tag: "wallet")?.data
    }

    static func loadCampusInfo() async -> CampusUserInfo? {
        await fetch(CampusUserInfo.self, path: "/settlement/campus/userInfo", tag: "campus")?.data
    }

    enum CampusBalanceUpdate: Equatable { case keep, clear, set(Double) }

    static func campusBalanceUpdate(_ response: APIResponse<CampusUserInfo>) -> CampusBalanceUpdate {
        guard response.success else {
            return response.errorCode == 12 && response.displayMessage?.trimmingCharacters(in: .whitespacesAndNewlines) == "无效支付配置"
                ? .clear : .keep
        }
        guard let info = response.data, info.signStatus != 0, let amount = info.yuan, amount.isFinite else {
            return .clear
        }
        return .set(amount)
    }

    static func loadAccountInfo() async -> AccountInfo? {
        await fetch(AccountInfo.self, path: "/account/info", tag: "accountInfo")?.data
    }

    static func loadProjectInfo() async -> ProjectInfo? {
        await fetch(ProjectInfo.self, path: "/project/info/triple", tag: "projectInfo")?.data
    }

    static func loadBindCardInfo() async -> AccountInfo? {
        await fetch(AccountInfo.self, path: "/account/card/getBindCardInfo", tag: "bindCardInfo")?.data
    }

    // MARK: - 未支付账单 / 手动代扣

    /// 未支付账单列表（残留账单）
    ///
    /// 就是俗称的「残留账单」—— 12 点后结束用水、或者一卡通余额不足的时候，
    /// 服务端结算没扣成，账单留在待扣状态。返回**扁平结构**（不套 consumeBillDTO）。
    ///
    /// ⚠️ 失败返回 nil，**不是空数组**：调用方要靠这个区别决定「保持原样」还是「真的没有」。
    static func loadUnpaid() async -> [UnpaidBill]? {
        do {
            let data = try await ApiClient.post(
                "/order/weixinScorePay/unPay/queryBill",
                form: [:],
                tag: "unpaid"
            )
            let resp = try ApiClient.decodeShell([UnpaidBill].self, from: data, path: "unpaid")
            guard resp.success else {
                AppLog.shared.w("未支付账单查询失败：\(resp.displayMessage ?? "")\(resp.errorCode.map { "（\($0)）" } ?? "")")
                return nil
            }
            return resp.data ?? []
        } catch {
            AppLog.shared.w("未支付账单查询异常：\(error.localizedDescription)")
            return nil
        }
    }

    /// 把两个余额来源刷进 Prefs（界面读 Prefs，所以刷完要手动触发刷新）
    @MainActor static func refreshBalances() async {
        let generation = SessionWork.generation ?? Session.shared.requestGeneration
        guard SessionWork.isCurrent(generation) else { return }
        if let data = try? await ApiClient.get("/settlement/campus/userInfo", tag: "campus"),
           let response = try? ApiClient.decodeShell(CampusUserInfo.self, from: data, path: "campus") {
            guard SessionWork.isCurrent(generation) else { return }
            switch campusBalanceUpdate(response) {
            case .keep: break
            case .clear: Prefs.campusBalance = ""
            case let .set(amount): Prefs.campusBalance = String(amount)
            }
        }
        guard SessionWork.isCurrent(generation) else { return }
        if let w = await loadWallet() {
            guard SessionWork.isCurrent(generation) else { return }
            // Android refreshWallet：money 已是元，accountRealMoney 为厘，不能混用。
            let v = w.moneyYuan
            Prefs.walletBalance = v.map { String($0) } ?? ""
            AppLog.shared.i("钱包余额：\(v.map { String($0) } ?? "空")")
        }
    }
}

// MARK: - 消费趋势统计

/// 逐条对照 Android 的 `data/SpendingAnalytics.kt`
enum SpendingAnalytics {

    enum Range: String, CaseIterable {
        case last7 = "LAST_7_DAYS"
        case thisMonth = "THIS_MONTH"

        var label: String { self == .last7 ? "7天" : "本月" }
    }

    struct DailySpend: Identifiable {
        let date: Date
        let amount: Double
        let count: Int
        var id: Date { date }
    }

    struct Summary {
        var points: [DailySpend] = []
        var total: Double = 0
        var count: Int = 0
        var average: Double = 0
    }

    static func summarize(bills: [BillDTO], range: Range, today: Date = Date()) -> Summary {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")

        let start: Date = {
            switch range {
            case .last7:
                return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: today)) ?? today
            case .thisMonth:
                let comps = cal.dateComponents([.year, .month], from: today)
                return cal.date(from: comps) ?? today
            }
        }()

        // 按天聚合
        var byDay: [Date: (sum: Double, count: Int)] = [:]
        for b in bills {
            let ms = BalanceEstimator.billTimeMs(b.consumeDate ?? "")
            guard ms > 0 else { continue }
            let date = cal.startOfDay(for: Date(timeIntervalSince1970: ms / 1000))
            guard date >= start, date <= cal.startOfDay(for: today) else { continue }
            guard let amount = b.yuan, amount.isFinite, amount >= 0 else { continue }
            var cur = byDay[date] ?? (0, 0)
            cur.sum += amount
            cur.count += 1
            byDay[date] = cur
        }

        // 补全每一天（没消费的那天是 0，不是「不存在」——折线要连起来）
        var points: [DailySpend] = []
        var cursor = start
        let end = cal.startOfDay(for: today)
        while cursor <= end {
            let v = byDay[cursor] ?? (0, 0)
            points.append(DailySpend(date: cursor, amount: v.sum, count: v.count))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let total = points.reduce(0) { $0 + $1.amount }
        let count = points.reduce(0) { $0 + $1.count }
        return Summary(
            points: points,
            total: total,
            count: count,
            average: count == 0 ? 0 : total / Double(count)
        )
    }
}

/// 图表坐标策略 —— 对照 Android 的 `TrendDisplayPolicy`
enum TrendDisplayPolicy {

    static func plotX(index: Int, size: Int, width: CGFloat, horizontalInset: CGFloat) -> CGFloat {
        if size <= 1 { return width / 2 }
        let inset = min(max(horizontalInset, 0), width / 2)
        return inset + CGFloat(index) / CGFloat(size - 1) * (width - inset * 2)
    }

    /// 横轴最多 5 个标签
    static func axisIndices(size: Int, maxLabels: Int = 5) -> [Int] {
        if size <= 0 || maxLabels <= 0 { return [] }
        if maxLabels == 1 { return [0] }
        if size <= maxLabels { return Array(Set([0, size / 2, size - 1])).sorted() }
        let step = Double(size - 1) / Double(maxLabels - 1)
        var out: [Int] = []
        for i in 0 ..< maxLabels {
            let v = Int(Double(i) * step)
            if !out.contains(v) { out.append(v) }
        }
        return out
    }
}
