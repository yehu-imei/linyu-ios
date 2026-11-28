import CoreFoundation
import Foundation

/// 「这一单花了多少钱」的查询与回退 —— 逐条对照 Android 的 `data/SettlementEngine.kt`。
///
/// ## 三态，不能只用 `Double?`
///
/// | 状态 | 含义 | 界面 |
/// |---|---|---|
/// | `.found(x)` | 拿到了大于 0 的金额 | 「本次消费 ¥x」 |
/// | `.knownZero` | 接口明确说 `consumeMoney` 就是 0 | 还要再确认，见下 |
/// | `.unknown` | 没拿到（网络失败 / 还没结算 / 结构不认识） | 「结算中」 |
///
/// 「字段不存在」和「字段就是 0」是**两件不同的事**：前者是「还不知道，继续等」，
/// 后者是「确实没花钱，可以收工」。用一个 `nil` 合并掉的话，
/// 开完水马上停的单子会一直停在「结算中」。
enum SettlementEngine {

    // MARK: - 对外

    /// 查出本次消费金额。
    ///
    /// - Returns: 金额（元）。`0.0` = 确实没花钱；`nil` = **还没查出来**（和 0 不是一回事）
    @MainActor static func settleAmount(_ order: PendingSettlement, project: ProjectAuthContext) async -> Double? {
        let generation = SessionWork.generation ?? Session.shared.requestGeneration
        guard project.generation == generation, SessionWork.isCurrent(generation),
              order.projectId == project.projectId, order.accountId == project.accountId,
              order.authOwner == project.owner else { return nil }
        let orderNo = order.orderNo
        let snCode = order.snCode
        func complete(_ amount: Double) -> Double {
            Prefs.recordConsume(snCode, amount: amount, atMs: order.consumptionTime)
            PendingSettlementStore.clear(order)
            return amount
        }
        var sawDefiniteZero = false

        if !orderNo.isEmpty {
            // ① 快速探测：命中正数立刻收工。
            //    实测（Android 27 次调用）第 1 轮就是终值，不能让有消费的单子干等。
            probe: for attempt in 0 ..< probeRounds {
                guard SessionWork.isCurrent(generation) else { return nil }
                let result = await queryConsumeResult(orderNo: orderNo, snCode: snCode, project: project)
                guard SessionWork.isCurrent(generation) else { return nil }
                switch result {
                case let .found(v):
                    AppLog.shared.i("结算命中（consumeOrder/result，第 \(attempt + 1) 轮）：¥\(MoneyFormat.format(v))")
                    return complete(v)
                case .knownZero:
                    sawDefiniteZero = true
                    // 字段在、值是 0 —— 交给下面的零确认，别急着下结论
                    // （⚠️ 这里必须是 `break probe`：Swift 的裸 `break` 只跳出 switch）
                    break probe
                case .unknown:
                    break
                }
                if attempt < probeRounds - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(confirmDelayMs) * 1_000_000)
                }
            }

            // ② 零确认：拿到过 0 就多观察几轮再认。
            //
            // 直答接口在结算完成前 `consumeMoney` 就是 0，和服务端真算出 0 元**长得一模一样**。
            // 只问一两轮的话，服务端稍慢一点就每一轮都落在「还没算完」的窗口里，
            // 于是把「还没算完」当成「没花钱」。
            //
            // 代价是零消费的单子多等几秒；这个交换划算 ——
            // **「明明花了钱却被告知无消费」比多等几秒严重得多**。
            if sawDefiniteZero {
                for attempt in 0 ..< zeroConfirmRounds {
                    try? await Task.sleep(nanoseconds: UInt64(zeroConfirmDelayMs) * 1_000_000)
                    guard SessionWork.isCurrent(generation) else { return nil }
                    let zeroProbe = await queryConsumeResult(orderNo: orderNo, snCode: snCode, project: project)
                    guard SessionWork.isCurrent(generation) else { return nil }
                    if case let .found(v) = zeroProbe {
                        AppLog.shared.i("结算命中（零确认第 \(attempt + 1) 轮）：¥\(MoneyFormat.format(v))")
                        return complete(v)
                    }
                }
            }
            AppLog.shared.w("consumeOrder/result 没给金额（见过明确的 0：\(sawDefiniteZero)），回退到账单列表")
        }

        // ③ 回退：拉账单列表自己匹配
        guard SessionWork.isCurrent(generation) else { return nil }
        let probe = await settleFromBillList(order, project: project)
        guard SessionWork.isCurrent(generation) else { return nil }

        // 账单列表也没查到金额时，要靠**两种不同的信息**下结论：
        //
        // | 直答接口 | 账单列表里有没有这一单 | 结论 |
        // |---|---|---|
        // | 说 0 | **有**（金额还没填） | 未结算完 → nil（「结算中」） |
        // | 说 0 | **从来没有** | 真零消费 → 0.0（「无消费」） |
        // | 说不清 | 有没有都行 | 未知 → nil |
        //
        // 第二行是关键：真零消费的单子账单列表里压根不会有这一条（开完水马上停，
        // 一笔账都不产生）。所以「账单里出现过」本身就是**有消费**的证据，
        // 不能因为金额还是 0 就判成没花钱 —— 这正是「有消费却显示无消费」的来源。
        let resolved = probe.resolvedAmount(directZero: sawDefiniteZero)
        if probe.sawBill && probe.amount == nil {
            AppLog.shared.w("结算：账单已出现但金额未填，按「未结算完」处理（不判无消费）")
        }

        // 关阀时已登记。只确认正消费后才清这笔记录，避免并发复核后重建旧记录。
        if let resolved, resolved > 0 { return complete(resolved) }
        return resolved
    }

    // MARK: - 主路径：直接问这一单结了多少钱

    /// `/order/consumeOrder/result/query`
    ///
    /// ⚠️ 这里故意走**原始 JSON 串**而不是 `Decodable` 模型：
    /// 不同学校的字段名/类型不一样（`consumeMoney` 有数字也有字符串），
    /// 声明成固定模型会一解码就失败，然后整条主路径静默失效。
    /// Android 端也是同样的理由（`consumeOrderResultRaw`）。
    private static func queryConsumeResult(orderNo: String, snCode: String, project: ProjectAuthContext) async -> MoneyProbe {
        do {
            let data = try await ApiClient.post(
                "/order/consumeOrder/result/query",
                form: ["snCode": snCode, "orderNo": orderNo],
                project: project,
                tag: "consumeResult"
            )
            return probeMoney(String(data: data, encoding: .utf8) ?? "")
        } catch {
            return .unknown
        }
    }

    /// 从响应 JSON 里挖出消费金额并**换算成元**。
    ///
    /// 1. 先认已知字段名（数字/字符串两种都收）
    /// 2. 认不出来就在 `data` 里按名字找像金额的数值字段
    ///
    /// ⚠️ 第 2 步必须**排除余额类字段**（`balance` / `account` / `wallet` / `pre` / `give` /
    /// `remain`）。拿钱包余额当消费金额是这里最危险的错法：金额会大得离谱，
    /// 而且看着还挺像个正常数字，不会有人发现不对。
    ///
    /// ⚠️ 单位是**厘**，必须过一遍 `toYuan`。
    /// ⚠️ 故意做成 internal：回归检查要直接喂各种学校的响应形状给它
    static func probeMoney(_ raw: String) -> MoneyProbe {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        if (root["success"] as? Bool) == false { return .unknown }

        // 金额可能在 data 里，也可能直接铺在顶层，两处都看
        var scopes: [[String: Any]] = []
        if let d = root["data"] as? [String: Any] { scopes.append(d) }
        scopes.append(root)

        // ① 已知字段名。字段**在**就采信，哪怕值是 0
        for scope in scopes {
            for key in ["consumeMoney", "consumeMoneyStr", "money", "consumeAmount"] {
                guard let el = scope[key], !(el is NSNull) else { continue }
                guard let rawValue = numberValue(el), rawValue.isFinite, rawValue >= 0 else { continue }
                let v = toYuan(rawValue)
                if v > 0 {
                    AppLog.shared.i("结算：`\(key)` 原始值 \(rawValue) → ¥\(v)（按 1000 厘/元 换算）")
                    return .found(v)
                }
                return .knownZero
            }
        }

        // ② 兜底：按名字找像金额的数值字段。
        // ⚠️ 这里**只认正数** —— 字段名是猜的，猜出来的 0 不敢当「确实没花钱」用，
        // 宁可算 unknown 让它走账单列表那条路复核一遍。
        for scope in scopes {
            for (key, el) in scope {
                let k = key.lowercased()
                guard k.range(of: amountKeyHint, options: .regularExpression) != nil,
                      k.range(of: amountKeyExclude, options: .regularExpression) == nil,
                      let rawValue = numberValue(el), rawValue.isFinite
                else { continue }
                let v = toYuan(rawValue)
                if v > 0 {
                    AppLog.shared.w("结算：通过备用金额字段确认 ¥\(v)")
                    return .found(v)
                }
            }
        }

        if (root["success"] as? Bool) == true, root["data"] is NSNull || root["data"] == nil {
            AppLog.shared.i("结算：接口返回成功但 data 为空，这单可能还没结算")
        }
        return .unknown
    }

    private static func numberValue(_ el: Any) -> Double? {
        if let n = el as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = el as? String { return Double(s) }
        return nil
    }

    // MARK: - 回退路径：账单列表

    struct BillProbe {
        var amount: Double?
        var sawBill = false
        var lookupFailed = false

        mutating func observe(_ match: BillDTO?, succeeded: Bool) {
            if !succeeded {
                lookupFailed = true
            } else if let match {
                sawBill = true
                if let yuan = match.yuan, yuan > 0 { amount = yuan }
            }
        }

        func resolvedAmount(directZero: Bool) -> Double? {
            amount ?? (directZero && !sawBill && !lookupFailed ? 0 : nil)
        }
    }

    @MainActor private static func settleFromBillList(
        _ order: PendingSettlement,
        project: ProjectAuthContext
    ) async -> BillProbe {
        let ended = Date(timeIntervalSince1970: Double(order.createdAt) / 1000)
        let orderNo = order.orderNo
        let startTimeMs = order.startedAt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        let endMonth = formatter.string(from: ended)
        let startMonth = startTimeMs > 0
            ? formatter.string(from: Date(timeIntervalSince1970: Double(startTimeMs) / 1000)) : endMonth
        let months = startMonth == endMonth ? [endMonth] : [startMonth, endMonth]
        let windowStart = startTimeMs > 0 ? startTimeMs - SettlementReconciler.timeSlackMs : 0
        let windowEnd = Int64(ended.timeIntervalSince1970 * 1000)

        var probe = BillProbe()
        for attempt in 0 ..< billListRounds {
            var bills: [BillDTO] = []
            var succeeded = true
            for month in months {
                guard SessionWork.isCurrent(project.generation) else { return probe }
                if let rows = try? await BillService.loadMonth(month, project: project) {
                    bills += rows
                } else {
                    succeeded = false
                    probe.observe(nil, succeeded: false)
                }
            }
            guard SessionWork.isCurrent(project.generation) else { return probe }
            let matched = SettlementReconciler.match(BillHistoryCache.newestFirst(bills),
                orderNo: orderNo, deviceName: order.deviceName, from: windowStart, until: windowEnd)
            // 部分失败时仍保留见过的占位账单。只有精确单号能在此情况下确认正消费。
            if !succeeded && orderNo.isEmpty {
                if matched != nil { probe.sawBill = true }
            } else {
                probe.observe(matched, succeeded: true)
            }
            if let amount = probe.amount {
                AppLog.shared.i("结算命中（账单列表，第 \(attempt + 1) 轮）：¥\(MoneyFormat.format(amount))")
                return probe
            }
            if attempt < billListRounds - 1 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        }
        return probe
    }

    // MARK: - 常量（与 Android 完全一致）

    /// 主路径问几轮。实测第 1 轮就是最终值，两轮足够（第二轮只在拿到 0 时用）
    private static let probeRounds = 2
    private static let confirmDelayMs = 1000

    /// 拿到 0 之后的额外确认轮数。
    ///
    /// ⚠️ 别再往上加。曾经加到 6 轮（7.2 秒）是治错了病：
    /// 误判的根因是**判据**（账单出现过 ⇒ 有消费），不是等得不够长。
    private static let zeroConfirmRounds = 2
    private static let zeroConfirmDelayMs = 1200

    /// 回退路径问几轮。⚠️ **不能是 1**：账单会先以占位 `"0.0"` 出现，
    /// 只问一轮就会把「刚出现还没填金额」误判成无消费。
    private static let billListRounds = 3

    private static let amountKeyHint = "(consume|money|amount|fee|cost|pay|charge|price)"
    private static let amountKeyExclude =
        "(balance|remain|surplus|account|wallet|pre|give|given|total|sum|count|id|no\\b|time|date|status|state)"

    /// 厘 → 元。`/order/consumeOrder/result/query` 的单位是**厘**（1 元 = 1000 厘），
    /// 而账单列表里同名字段是**元**。忘了换算不是报错，而是静默错 1000 倍。
    private static func toYuan(_ raw: Double) -> Double { raw / 1000.0 }
}

/// 三态探询结果
enum MoneyProbe {
    case found(Double)
    case knownZero
    case unknown
}
