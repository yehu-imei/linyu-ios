import Foundation

enum WalletRechargeRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        let mode = "/settlement/recharge/pay/mode"
        let packages = "/settlement/recharge/package/list"
        let oldResponses = ApiClient.getResponses
        let oldPaths = ApiClient.getPaths
        defer {
            ApiClient.getResponses = oldResponses
            ApiClient.getPaths = oldPaths
        }

        let generation = Session.shared.requestGeneration
        ApiClient.getPaths = []
        ApiClient.getResponses[mode] = #"{"success":true,"errorCode":0,"data":{"payWay":["2",26]}}"#
        ApiClient.getResponses[packages] = #"{"success":true,"errorCode":0,"data":[{"typeId":"1","amount":"10.50","givenMoney":2},{"typeId":2,"amount":0.01},{"typeId":2,"amount":4},{"typeId":3,"amount":"0.015"},{"typeId":4,"amount":10000.01},{"typeId":5,"amount":"10元"},null]}"#
        let supported = await WalletRechargeService.load(generation: generation)
        check(supported?.appPay == .supported && ApiClient.getPaths == [mode, packages], "充值渠道接受数字和字符串，只在支持时查询档位")
        check(supported?.denominations.map(\.amount) == ["10.50", "0.01"] && supported?.denominations.first?.gift == "2.00", "官方充值档位按分展示并过滤超范围、小于分或重复的档位")

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
        let stale = await WalletRechargeService.load(generation: UUID())
        check(stale == nil && ApiClient.getPaths.isEmpty, "旧会话不再发起充值查询")
    }
}
