import Foundation

// Runs the production AppDataStore and BillService with a deterministic HTTP boundary.
@main
struct DataStoreRegression {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures.append(name) }
        }

        let cacheKey = "billCache_test-school:test-account"
        func clearCache() {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: cacheKey)
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("billCache_test-user:test-school:test-account/") {
                defaults.removeObject(forKey: key)
            }
        }
        clearCache()
        defer { clearCache() }
        ApiClient.failBills = true
        let retryStore = AppDataStore()
        await retryStore.loadIfNeeded()
        check(!retryStore.loaded, "failed requests are not cached as an empty success")
        ApiClient.failBills = false
        await retryStore.loadIfNeeded()
        check(retryStore.loaded && retryStore.bills.count == 3, "initial failure can retry on next visit")
        ApiClient.failBills = true
        await retryStore.reload()
        check(retryStore.bills.count == 3, "refresh failure preserves previously loaded bills")

        ApiClient.failBills = false
        ApiClient.delay = 30_000_000
        let switchingStore = AppDataStore()
        let page = Task { await switchingStore.loadIfNeeded() }
        while ApiClient.activeRequests == 0 { await Task.yield() }
        page.cancel()
        await page.value
        check(switchingStore.loaded && switchingStore.bills.count == 3,
              "leaving a tab does not cancel shared bill loading")

        ApiClient.delay = 0
        ApiClient.emptyBills = true
        let emptyStore = AppDataStore()
        await emptyStore.loadIfNeeded()
        check(emptyStore.loaded && emptyStore.bills.isEmpty, "successful empty response remains a valid empty state")
        ApiClient.emptyBills = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        ApiClient.failingMonth = formatter.string(from: Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: Date())!)
        let partial = await BillService.loadHistory()
        check(partial.count == 2, "settlement fallback preserves successful months on partial failure")
        let partialStore = AppDataStore()
        await partialStore.loadIfNeeded()
        check(partialStore.billsError != nil && partialStore.bills.count == 2,
              "partial bill response combines successful months with cache for the failed month")
        ApiClient.failingMonth = nil

        Session.shared.requestGeneration = UUID()
        ApiClient.getResponses["/user/project/list"] = #"{"success":true,"data":[{"projectId":902,"accountId":102},{"projectId":903,"accountId":103,"userId":222}]}"#
        ApiClient.billResponsesByProject["902"] = #"{"success":true,"data":[{"consumeBillDTO":{"orderId":"shared","deviceDescription":"温水机-A号","dealDate":"2026-11-10T12:00:00","consumeMoney":"0","thirdTradeMoney":"0.123"}},{"rechargeBillDTO":{"orderId":"add"},"consumeBillDTO":{"orderId":"add","consumeDate":"2026-11-10 12:00:01","consumeMoney":"1.0"}}]}"#
        ApiClient.billQueries = []
        let mergedStore = AppDataStore()
        await mergedStore.loadIfNeeded()
        let foreign = mergedStore.bills.filter { $0.sourceProjectId == "902" }
        check(mergedStore.bills.count == 4 && foreign.count == 1 && foreign.first?.yuan == 0.123 &&
            foreign.first?.isDrinkingWaterBill == true && foreign.first?.consumeDate == "2026-11-10 12:00:00",
            "合并其他已授权项目的饮水账单，排除充值并补齐金额和时间")
        check(mergedStore.balanceBills.count == 3 && mergedStore.balanceBills.allSatisfy(mergedStore.isDefaultBill),
              "余额估算只使用默认项目的完整账单")
        check(ApiClient.billQueries.filter { $0.project == "902" && $0.account == "102" && $0.type == "0" }.count == 3 &&
            ApiClient.billQueries.filter { $0.project == "test-school" && $0.account == "test-account" && $0.type == "2" }.count == 3 &&
            ApiClient.billQueries.count == 6, "默认和授权项目分别使用项目账户和查询类型")
        ApiClient.getResponses = [:]
        ApiClient.billResponsesByProject = [:]
        Session.shared.requestGeneration = UUID()

        Prefs.campusBalance = "2.31"
        ApiClient.getResponses["/settlement/campus/userInfo"] = #"{"success":false,"errorCode":500,"errorMessage":"暂不可用"}"#
        await BillService.refreshBalances()
        check(Prefs.campusBalance == "2.31", "一卡通暂时查询失败保留旧余额")
        ApiClient.getResponses["/settlement/campus/userInfo"] = #"{"success":false,"errorCode":12,"errorMessage":"无效支付配置"}"#
        await BillService.refreshBalances()
        check(Prefs.campusBalance.isEmpty, "确认无一卡通支付配置时清除旧余额")
        Prefs.campusBalance = "2.31"
        ApiClient.getResponses["/settlement/campus/userInfo"] = #"{"success":true,"data":{"signStatus":0,"amount":"2.31"}}"#
        await BillService.refreshBalances()
        check(Prefs.campusBalance.isEmpty, "一卡通未签约响应清除过期余额")
        ApiClient.getResponses = [:]

        SettlementRegression.run(check: check)
        CoreLogicRegression.run(check: check)
        MoneyDisplayRegression.run(check: check)
        await DeviceControlRegression.run(check: check)
        await ParityBatchRegression.run(check: check)
        await DeviceAddressRegression.run(check: check)
        await SessionIsolationRegression.run(check: check)
        await ParityFinishRegression.run(check: check)
        await SharedStoreSessionRegression.run(check: check)
        UserCardLayoutRegression.run(check: check)
        HomeDeviceLayoutRegression.run(check: check)
        BleCallbackRegression.run(check: check)
        BleReplyBufferRegression.run(check: check)
        await BleSettlementRegression.run(check: check)
        await NotificationFeedbackRegression.run(check: check)
        await WalletRechargeRegression.run(check: check)

        if !failures.isEmpty { fatalError("Regression failures: \(failures.joined(separator: ", "))") }
    }
}
