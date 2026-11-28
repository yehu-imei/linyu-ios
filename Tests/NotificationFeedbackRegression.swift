import Foundation

enum NotificationFeedbackRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        let notificationSuite = "linyu.notification-tests." + UUID().uuidString
        if let defaults = UserDefaults(suiteName: notificationSuite) {
            defer { defaults.removePersistentDomain(forName: notificationSuite) }
            let legacy = ["notifyInUse": false, "notifyFinished": false, "notifyAutoClose": false, "notifyAlert": true]
            for (key, value) in legacy { defaults.set(value, forKey: key) }
            defaults.set(false, forKey: "notifyEnabled")
            defaults.set(true, forKey: "trendEnabled")
            NotificationPolicy.removeLegacyPreferences(defaults: defaults)
            check(legacy.keys.allSatisfy { defaults.object(forKey: $0) == nil }, "升级移除旧的通知分类与横幅偏好")
            check(defaults.object(forKey: "notifyEnabled") as? Bool == false &&
                  defaults.object(forKey: "trendEnabled") as? Bool == true, "清理不改通知总开关或其他偏好")
            defaults.set(true, forKey: "notifyEnabled")
            NotificationPolicy.removeLegacyPreferences(defaults: defaults)
            check(defaults.object(forKey: "notifyEnabled") as? Bool == true, "再次启动保留已开启的通知总开关")
        } else {
            check(false, "建立独立通知偏好测试数据")
        }
        check(NotificationKind.finished.destination == 1 && NotificationKind.autoClosed.destination == 1 &&
              NotificationKind.occupied.destination == 0 && NotificationKind.openFailed.destination == 0 &&
              NotificationKind.closeProblem.destination == 0, "结算去账单，设备占用和开关阀失败去首页")
        defer { ApiClient.getResponses = [:]; ApiClient.postResponse = #"{"success":true,"data":null}"# }
        let owner = "quota-test:" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "useCodeQuota_" + owner) }
        let store = AppDataStore(profileOwnerProvider: { owner })
        ApiClient.postResponse = #"{"success":true,"data":{"useCode":"last-candidate","remainTimes":0}}"#
        do {
            let result = try await store.generateUseCode()
            check(result.useCode == "last-candidate" && store.useCodeQuotaExhausted, "第20次候选有效并记住剩余次数为零")
        } catch { check(false, "最后一次生成应成功") }
        ApiClient.postPaths = []
        do { _ = try await store.generateUseCode(); check(false, "额度耗尽不应继续换码") }
        catch { check(ApiClient.postPaths.isEmpty && store.useCodeBlockReason != nil, "额度耗尽在请求前拦截并解释原因") }
        check(AppDataStore(profileOwnerProvider: { owner }).useCodeQuotaExhausted, "同日重新创建缓存仍保留次数耗尽状态")
        check(UseCodeQuotaStore.read(owner: owner + "other") == nil, "不同账号不共用换码额度")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        check(UseCodeQuotaStore.read(owner: owner, now: tomorrow) == nil, "跨日不沿用昨日次数耗尽记录")
        let rejectedOwner = "quota-error:" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "useCodeQuota_" + rejectedOwner) }
        let rejected = AppDataStore(profileOwnerProvider: { rejectedOwner })
        ApiClient.postResponse = #"{"success":false,"errorCode":79,"errorMessage":"使用码生成次数超出日限制次数","data":null}"#
        do { _ = try await rejected.generateUseCode(); check(false, "服务端额度错误不能生成候选") }
        catch { check(rejected.useCodeQuotaExhausted, "错误79也记录当日额度耗尽") }
        check(AppDataStore(profileOwnerProvider: { rejectedOwner }).useCodeBlockReason != nil, "错误79持久化后重新进入仍拦截")
        ApiClient.postPaths = []
        do { _ = try await rejected.generateUseCode(); check(false, "错误79后不再请求换码") }
        catch { check(ApiClient.postPaths.isEmpty, "错误79后的重复点击不调用接口") }
    }
}
