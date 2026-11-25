import Foundation

/// 主动挤号检测 —— 逐条对照 Android `MainViewModel.startKickWatch`。
///
/// ## 为什么需要它
///
/// 服务端允许同一账号在别处登录，旧会话的 `loginCode` 会被作废。之后任何请求都会
/// 返回「登录失效」，但用户可能**正在使用页**上 —— 他只看到结算失败、账单拉不出来，
/// 不知道发生了什么，会以为是网络问题反复点。
///
/// 这里每 25 秒问一次 `/account/wallet`：
/// - 成功：**顺手把钱包余额刷新了**（这条心跳反正要跑，不加请求量，
///   却让余额在洗完澡后自动跟上，不用等用户下拉刷新）
/// - 失败：ApiClient 统一处理会话失效，和刷新或操作设备共用同一个弹窗。
///
/// ⚠️ 生命周期跟随主界面（`MainTabView`）：退到登录页就该停，别在后台空转。
@MainActor
final class KickWatch: ObservableObject {

    /// Android 的 `kickWatchIntervalMs` 是 25 秒，保持一致
    static let intervalSec: UInt64 = 25

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        AppLog.shared.i("挤号检测启动（每 \(Self.intervalSec)s）")
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.intervalSec * 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        // 已经登出了（正常退出或被挤）就不用再问了
        guard Session.shared.isLoggedIn, Session.shared.kickedReason == nil else { return }

        let generation = Session.shared.requestGeneration
        let wallet = await BillService.loadWallet()
        guard SessionWork.isCurrent(generation), let value = wallet?.moneyYuan else { return }
        Prefs.walletBalance = String(value)
    }
}
