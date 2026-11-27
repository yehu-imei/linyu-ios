import Foundation

enum DeviceControlRegression {
    @MainActor static func run(check: (Bool, String) -> Void) async {
        check(!ShowerChannel.ble.usesAppAutoClose && ShowerChannel.cloud.usesAppAutoClose,
              "App 自动关停只适用于云端设备")
        check(AutoCloseDeadline.remainingSeconds(deadlineMs: 6_000, nowMs: 5_999) == 1 &&
              !AutoCloseDeadline.isDue(deadlineMs: 6_000, nowMs: 5_999),
              "距截止还剩不足一秒时继续显示倒计时，不提前关阀")
        check(AutoCloseDeadline.isDue(deadlineMs: 6_000, nowMs: 6_000) &&
              AutoCloseDeadline.remainingSeconds(deadlineMs: 6_000, nowMs: 6_000) == 0,
              "云端订单到真实截止时间才满足关阀条件")
        check(!AutoCloseDeadline.isDue(deadlineMs: 0, nowMs: 6_000),
              "没有保存截止时间时不触发自动关阀")
        let a = ActiveOrderRecord(snCode: "A", orderNo: "order-A", deviceName: "A",
                                  deviceMac: "A", deviceEmoji: "", preDeduct: 0)
        let b = ActiveOrderRecord(snCode: "B", orderNo: "order-B", deviceName: "B",
                                  deviceMac: "B", deviceEmoji: "", preDeduct: 0)
        let target = DeviceNotificationTarget(accountKey: "school:user", snCode: "A",
                                               orderNo: "order-A", startedAt: 100)
        check(target.matches(accountKey: "school:user", record: a, startedAt: 100), "通知可匹配原设备原订单")
        check(!target.matches(accountKey: "school:user", record: b, startedAt: 100), "A 通知不能操作当前显示的 B")
        check(!target.matches(accountKey: "other:user", record: a, startedAt: 100), "换账号后拒绝旧通知")
        check(!target.matches(accountKey: "school:user", record: a, startedAt: 200), "同设备新一轮用水拒绝旧通知")
        check(!target.matches(accountKey: "school:user", record: nil, startedAt: 100), "已结束订单不会因通知重新开阀")
        var changed = a; changed.orderNo = "new-order"
        check(!target.matches(accountKey: "school:user", record: changed, startedAt: 100), "订单号变化拒绝旧通知")
        let pending = DeviceNotificationTarget(accountKey: "school:user", snCode: "A", orderNo: "", startedAt: 100)
        check(pending.matches(accountKey: "school:user", record: a, startedAt: 100), "通知发出后补齐订单号仍能匹配")
        check(DeviceNotificationTarget(userInfo: [:]) == nil, "旧版无设备身份通知不会退回当前设备")
        check(DeviceNotificationTarget(userInfo: target.userInfo) == target, "通知载荷完整往返")
        check(target.isSameSession(as: target), "同一已完成订单的重复投递可识别")
        check(target.isSameSession(as: pending), "补齐订单号后仍识别同笔重复投递")
        check(!target.isSameSession(as: .init(accountKey: "school:user", snCode: "A", orderNo: "new-order", startedAt: 100)), "不同订单号不被完成去重吞掉")
        check(!target.isSameSession(as: .init(accountKey: "school:user", snCode: "A", orderNo: "order-A", startedAt: 200)), "同设备新会话不被完成去重吞掉")
        check(!target.isSameSession(as: .init(accountKey: "other:user", snCode: "A", orderNo: "order-A", startedAt: 100)), "不同账号的通知不能共享完成身份")
        check(target.matchesServerOrder(record: a, orderNo: "order-A", isOwner: true), "通知停止前确认服务器原订单")
        check(!target.matchesServerOrder(record: a, orderNo: "remote-new-order", isOwner: true), "旧通知不能关闭远端重开的订单")
        check(!target.matchesServerOrder(record: a, orderNo: "order-A", isOwner: false), "通知不能关闭他人的订单")
        check(!target.matchesServerOrder(record: a, orderNo: "order-A", isOwner: nil), "通知停止需要明确的所属账户")
        var unknown = a; unknown.orderNo = ""
        check(!pending.matchesServerOrder(record: unknown, orderNo: "unknown", isOwner: true), "没有原订单号时不猜测通知目标")
        check(DeviceNotificationTarget.notificationID(snCode: "A", finished: false) != DeviceNotificationTarget.notificationID(snCode: "B", finished: false), "两台设备通知互不覆盖")
        var gate = DeviceControlGate()
        let first = gate.begin()!
        check(gate.begin() == nil, "已有控制或蓝牙结算时拒绝另一条控制链")
        gate.finish(UUID())
        check(gate.isBusy, "其它任务不能释放控制锁")
        gate.finish(first)
        let second = gate.begin()
        check(second != nil, "结算结束后允许下一台设备操作")
        gate.finish(first)
        check(gate.isBusy, "旧任务结束不能释放新的操作锁")
        gate.finish(second!)

        ApiClient.postPaths = []
        _ = await CloudShower.open(snCode: "A", allowNewOrder: false)
        check(ApiClient.postPaths == ["/order/tcpDevice/query/rateOrder/using"], "恢复空闲设备只查询，不申请新费率")
        ApiClient.postPaths = []; ApiClient.failPost = true
        _ = await CloudShower.open(snCode: "A", allowNewOrder: false)
        check(ApiClient.postPaths == ["/order/tcpDevice/query/rateOrder/using"], "恢复查询断网不会转成开阀")
        ApiClient.failPost = false
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"orderNo":"old-order","isOwner":true}}"#
        if case let .resumed(orderNo, _) = await CloudShower.open(snCode: "A", allowNewOrder: false) {
            check(orderNo == "old-order", "恢复沿用服务器原订单号")
        } else { check(false, "恢复沿用服务器原订单号") }
        if case .failed = await CloudShower.open(snCode: "A", allowNewOrder: false, expectedOrderNo: "different-order") {
            check(true, "恢复时拒绝用另一笔服务器订单覆盖原订单")
        } else { check(false, "恢复时拒绝用另一笔服务器订单覆盖原订单") }
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"orderNo":"other-order","isOwner":false}}"#
        if case .inUseByOthers = await CloudShower.open(snCode: "A", allowNewOrder: false) {
            check(true, "恢复拒绝他人订单")
        } else { check(false, "恢复拒绝他人订单") }
        let usingPath = "/order/tcpDevice/query/rateOrder/using"
        let closePath = "/order/tcpDevice/closeOrder"
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"orderNo":"unknown-owner"}}"#
        ApiClient.postPaths = []
        if case .inUseByOthers = await CloudShower.open(snCode: "A") {
            check(ApiClient.postPaths == [usingPath], "307 未确认订单归属时禁止恢复和申请新费率")
        } else { check(false, "307 未确认订单归属时禁止恢复和申请新费率") }
        ApiClient.postPaths = []
        if case .unconfirmed = await CloudShower.close(snCode: "A", orderNo: "") {
            check(ApiClient.postPaths == [usingPath], "缺少可信订单号时不发送关阀")
        } else { check(false, "缺少可信订单号时不发送关阀") }
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"snCode":"B","orderNo":"other-device","isOwner":true}}"#
        if case .inUseByOthers = await CloudShower.open(snCode: "A", allowNewOrder: false) {
            check(true, "恢复拒绝响应中身份不一致的设备")
        } else { check(false, "恢复拒绝响应中身份不一致的设备") }

        ApiClient.postResponse = #"{"success":true,"data":null}"#
        ApiClient.postPaths = []
        ApiClient.postProjects = []
        let project = ProjectAuthContext(projectId: "89", accountId: "12", owner: "1:88:11",
                                         generation: Session.shared.requestGeneration)
        let own = #"{"success":false,"errorCode":307,"data":{"snCode":"A","orderNo":"order-A","isOwner":true}}"#
        let idle = #"{"success":true,"data":null}"#
        let foreign = #"{"success":false,"errorCode":307,"data":{"orderNo":"","isOwner":false}}"#
        ApiClient.onPost = {
            if ApiClient.postPaths.last == usingPath {
                ApiClient.postResponses[usingPath] = ApiClient.postPaths.contains(closePath) ? idle : own
            }
        }
        if case .closed = await CloudShower.close(snCode: "A", orderNo: "order-A", project: project) {
            check(ApiClient.postPaths == [usingPath, closePath, usingPath], "只关闭预检确认的原订单并复核结果")
            check(ApiClient.postProjects == [project, project, project], "关阀预检、请求和复核均沿用目标项目账户")
        } else { check(false, "关阀受理后确认空闲才返回已关闭") }
        ApiClient.onPost = nil

        ApiClient.postPaths = []
        ApiClient.postResponses[usingPath] = foreign
        if case .replaced(ownedByCurrentAccount: false) = await CloudShower.close(snCode: "A", orderNo: "order-A", project: project) {
            check(ApiClient.postPaths == [usingPath], "设备已由他人使用时结束本地原单，不发送关阀")
        } else { check(false, "他人占用与本地原单状态分开") }

        ApiClient.postPaths = []
        ApiClient.postResponses[usingPath] = own.replacingOccurrences(of: "order-A", with: "replacement")
        if case .replaced(ownedByCurrentAccount: true) = await CloudShower.close(snCode: "A", orderNo: "order-A", project: project) {
            check(ApiClient.postPaths == [usingPath], "同账户另一订单也不能用旧订单动作关闭")
        } else { check(false, "识别同账户的另一订单") }

        ApiClient.postPaths = []
        ApiClient.postResponses[usingPath] = foreign.replacingOccurrences(of: "\"isOwner\":false", with: "\"isOwner\":false,\"snCode\":\"B\"")
        if case .unconfirmed = await CloudShower.close(snCode: "A", orderNo: "order-A", project: project) {
            check(ApiClient.postPaths == [usingPath], "响应明确属于其他设备不能判定原单结束或发出关阀")
        } else { check(false, "忽略他设备的占用响应") }

        ApiClient.postPaths = []
        ApiClient.onPost = {
            if ApiClient.postPaths.last == usingPath {
                ApiClient.postResponses[usingPath] = ApiClient.postPaths.contains(closePath) ? foreign : own
            }
        }
        if case .replaced(ownedByCurrentAccount: false) = await CloudShower.close(snCode: "A", orderNo: "order-A", project: project) {
            check(ApiClient.postPaths == [usingPath, closePath, usingPath], "原单关阀受理后被他人占用只复核，不重发关阀")
        } else { check(false, "关阀复核确认原单已结束但设备仍被占用") }
        ApiClient.onPost = nil

        let stillRunning = #"{"success":false,"errorCode":307,"data":null}"#
        for closeReply in [idle, stillRunning] {
            var statusReads = 0
            ApiClient.postPaths = []
            ApiClient.postResponses[closePath] = closeReply
            ApiClient.onPost = {
                guard ApiClient.postPaths.last == usingPath else { return }
                statusReads += 1
                ApiClient.postResponses[usingPath] = statusReads == 1 ? own : (statusReads < 6 ? stillRunning : idle)
            }
            let result = await CloudShower.close(snCode: "A", orderNo: "order-A", project: project, confirmationPause: {})
            if case .closed = result {
                check(ApiClient.postPaths == [usingPath, closePath] + Array(repeating: usingPath, count: 5),
                      "关阀受理或返回 307 后，延迟到第五次确认空闲也只发送一次关阀")
            } else { check(false, "关阀等待设备延迟回报") }
        }
        ApiClient.onPost = nil
        ApiClient.postResponses.removeValue(forKey: closePath)

        ApiClient.postPaths = []
        ApiClient.postResponses[usingPath] = own
        if case .unconfirmed = await CloudShower.close(snCode: "A", orderNo: "order-A", project: project, confirmationPause: {}) {
            check(ApiClient.postPaths == [usingPath, closePath] + Array(repeating: usingPath, count: 9),
                  "关阀受理但一直占用时只复核，不重复关阀")
        } else { check(false, "关阀受理但一直占用时保持未确认") }
        ApiClient.postResponses.removeValue(forKey: usingPath)

        let accounts = ProjectAuthPolicy.accounts([
            .init(userId: 1, projectId: 88, accountId: 999),
            .init(userId: 1, projectId: 89, accountId: 12),
            .init(userId: 2, projectId: 90, accountId: 13),
            .init(userId: 1, projectId: 91, accountId: -1),
            .init(userId: 1, projectId: 92, accountId: 15),
            .init(userId: 1, projectId: 92, accountId: 16)
        ], userId: "1", defaultContext: .init(
            projectId: "88", accountId: "11", owner: project.owner, generation: project.generation))
        check(accounts == ["88": "11", "89": "12"], "仅接受当前用户明确关联的项目账户")

        ActiveOrderStore.clear()
        ActiveOrderStore.upsert(a)
        ActiveOrderStore.upsert(b)
        ActiveOrderStore.finish("A")
        check(!ActiveOrderStore.isRunning("A") && ActiveOrderStore.isRunning("B"), "结束 A 立即移除 A 并保留 B")
        check(ActiveOrderStore.wasFinished(snCode: "A", orderNo: "order-A"), "已结束订单身份落盘，迟到查询不能恢复")
        check(!ActiveOrderStore.wasFinished(snCode: "A", orderNo: "next-order"), "同设备的新订单不会被旧订单拦截")
        check(!ActiveOrderStore.wasFinished(snCode: "B", orderNo: "order-A"), "结束记录按设备隔离")
        ActiveOrderStore.confirmIdle("A")
        check(ActiveOrderStore.wasFinished(snCode: "A", orderNo: "order-A"), "空闲确认后仍拒绝迟到的已知旧订单")
        var noNumber = b; noNumber.orderNo = ""
        ActiveOrderStore.upsert(noNumber)
        ActiveOrderStore.finish("B")
        check(ActiveOrderStore.wasFinished(snCode: "B", orderNo: "late-number"), "结束时订单号未知先拦截延迟补号")
        ActiveOrderStore.confirmIdle("B")
        check(!ActiveOrderStore.wasFinished(snCode: "B", orderNo: "next-B"), "确认空闲后解除未知订单号拦截")
        ApiClient.postPaths = []
        ApiClient.postResponse = #"{"success":false,"errorCode":307,"data":{"orderNo":"order-A","isOwner":true}}"#
        if case .failed = await CloudShower.open(snCode: "A") {
            check(!ApiClient.postPaths.contains("/order/tcpDevice/downRate/rateOrder"), "关阀后旧订单仍在服务器时不能恢复或重复开阀")
        } else { check(false, "关阀后旧订单仍在服务器时不能恢复或重复开阀") }
        ActiveOrderStore.clear()
        check(!ActiveOrderStore.wasFinished(snCode: "A", orderNo: "order-A"), "退出账号清理结束订单身份")
        ApiClient.postResponse = #"{"success":true,"data":null}"#
        ApiClient.failPost = true
        if case .unconfirmed = await CloudShower.close(snCode: "A", orderNo: "order-A") {
            check(true, "断网关阀不冒充已关闭")
        } else { check(false, "断网关阀不冒充已关闭") }
        ApiClient.failPost = false

        let listPath = "/user/project/list"
        ApiClient.getResponses[listPath] = #"{"success":false,"data":[{"projectId":89,"accountId":12}]}"#
        Session.shared.requestGeneration = UUID()
        let failedAccounts = try? await ProjectAuthRepository.projectAccounts()
        check(failedAccounts?.count == 1, "失败的项目账户响应不能授权跨项目")

        ApiClient.getResponses[listPath] = #"{"success":true,"data":[{"projectId":89,"accountId":12}]}"#
        Session.shared.requestGeneration = UUID()
        let linked = try? await ProjectAuthRepository.context(projectId: "89", accountId: "12")
        check(linked?.projectId == "89" && linked?.accountId == "12", "服务端已关联项目启用目标账户")
        let unlinked = try? await ProjectAuthRepository.context(projectId: "89", accountId: "99")
        check(unlinked == nil, "旧订单记录不能冒用同项目下的其他账户")
        Session.shared.requestGeneration = UUID()
        check(linked.map(ProjectAuthRepository.isCurrent) == false, "重新登录后旧项目快照失效")
        ApiClient.getResponses.removeValue(forKey: listPath)
    }
}
