import Foundation

enum WalletRechargeRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        let mode = "/settlement/recharge/pay/mode"
        let packages = "/settlement/recharge/package/list"
        let generation = Session.shared.requestGeneration
        let oldResponses = ApiClient.getResponses
        let oldPaths = ApiClient.getPaths
        let oldOnGet = ApiClient.onGet
        let postPaths = ApiClient.postPaths
        defer {
            Session.shared.requestGeneration = generation
            ApiClient.getResponses = oldResponses
            ApiClient.getPaths = oldPaths
            ApiClient.onGet = oldOnGet
        }

        ApiClient.onGet = nil
        ApiClient.getPaths = []
        let supportedMode = #"{"success":true,"errorCode":0,"data":{"payWay":["2",26]}}"#
        ApiClient.getResponses[mode] = supportedMode
        ApiClient.getResponses[packages] = #"{"success":true,"errorCode":0,"data":[{"typeId":"1","amount":"10.50","givenMoney":2},{"typeId":2,"amount":0.01},{"typeId":"2","amount":4},{"typeId":3,"amount":"0.015"},{"typeId":4,"amount":10000.01},{"typeId":5,"amount":"10元"},null]}"#
        let supported = await WalletRechargeService.load(generation: generation)
        check(supported?.appPay == .supported && ApiClient.getPaths == [mode, packages], "充值渠道接受数字和字符串，只在支持时查询档位")
        check(supported?.denominations.map(\.id) == [1, 2] &&
              supported?.denominations.map(\.amount) == ["10.50", "0.01"] &&
              supported?.denominations.first?.gift == "2.00",
              "官方充值档位按分展示并过滤超范围、非法金额或重复编号")

        ApiClient.getPaths = []
        ApiClient.getResponses[mode] = #"{"success":true,"errorCode":0,"data":{"payWay":["26"],"noSaveMessage":"请充值校园卡"}}"#
        let unsupported = await WalletRechargeService.load(generation: generation)
        check(unsupported?.appPay == .unsupported && unsupported?.message == "请充值校园卡" && ApiClient.getPaths == [mode], "不支持支付宝 App 支付时显示官方原因")

        ApiClient.getPaths = []
        ApiClient.getResponses[mode] = #"{"success":true,"errorCode":9,"data":{"payWay":[2]}}"#
        let failed = await WalletRechargeService.load(generation: generation)
        check(failed?.appPay == .unknown && ApiClient.getPaths == [mode], "非零业务错误不能显示支持")

        ApiClient.getPaths = []
        ApiClient.getResponses[mode] = #"{"success":true,"errorCode":0,"data":{"payWay":[2,"invalid"]}}"#
        let malformed = await WalletRechargeService.load(generation: generation)
        check(malformed?.appPay == .unknown && ApiClient.getPaths == [mode], "错误渠道类型显示状态未知")

        ApiClient.getPaths = []
        ApiClient.getResponses[mode] = #"{"success":true,"errorCode":0,"data":{"payWay":[2,-1]}}"#
        let negativeCode = await WalletRechargeService.load(generation: generation)
        check(negativeCode?.appPay == .unknown && ApiClient.getPaths == [mode], "负数渠道编号显示状态未知")

        ApiClient.getPaths = []
        let stale = await WalletRechargeService.load(generation: UUID())
        check(stale == nil && ApiClient.getPaths.isEmpty, "旧会话不再发起充值查询")

        ApiClient.getResponses[mode] = supportedMode
        for changeDuring in [mode, packages] {
            Session.shared.requestGeneration = generation
            ApiClient.getPaths = []
            ApiClient.onGet = { path in
                if path == changeDuring { Session.shared.requestGeneration = UUID() }
            }
            let result = await WalletRechargeService.load(generation: generation)
            let expectedPaths = changeDuring == mode ? [mode] : [mode, packages]
            check(result == nil && ApiClient.getPaths == expectedPaths, "忽略切换账号后返回的充值查询结果")
        }

        check(ApiClient.postPaths == postPaths, "充值查询全程只执行 GET")
    }
}
