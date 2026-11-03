import Foundation

@main struct WidgetRegression {
    static func main() throws {
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL"): \(name)")
            if !passed { failures += 1 }
        }
        var snapshot = WidgetSnapshot()
        check(snapshot.emptyTitle == "未登录", "无账户且没有同步错误才显示未登录")
        snapshot.message = "小组件无法同步，请检查安装权限"
        check(snapshot.emptyTitle == "等待同步", "共享权限错误不误报退出登录")
        snapshot.message = nil
        snapshot.owner = "school:account"
        snapshot.lastDevice = "A"
        snapshot.devices = [WidgetDevice(id: "A", name: "320房", detail: "热水器", emoji: "🚿"),
                            WidgetDevice(id: "B", name: "321房", detail: "热水器", emoji: "🚿", running: true, orderNo: "orderB", startedAt: 123, selectable: false)]
        let start = WidgetCommand(url: WidgetCommand.url(.start, snapshot: snapshot, device: snapshot.devices[0]))!
        check(start.matches(snapshot), "组件开阀按钮保留目标身份")
        let stop = WidgetCommand(url: WidgetCommand.url(.stop, snapshot: snapshot, device: snapshot.devices[1]))!
        check(stop.matches(snapshot), "寝室筛选不隐藏正在使用设备的停止入口")
        check(snapshot.selected("B")?.running == true, "筛选外进行中的订单仍可展示")
        snapshot.devices[1].running = false
        check(snapshot.selected("B") == nil && !stop.matches(snapshot), "筛选外空闲设备不能被展示或停止")
        snapshot.devices[1].running = true
        snapshot.devices[1].orderNo = "newOrder"
        check(!stop.matches(snapshot), "旧组件不能关闭同设备新订单")
        snapshot.devices[0].running = true
        check(!start.matches(snapshot), "旧开阀按钮不能操作已运行的设备")
        snapshot.devices[0].running = false
        snapshot.devices[0].selectable = false
        check(!start.matches(snapshot), "寝室筛选也校验实际开阀入口")
        snapshot.devices[0].selectable = true
        snapshot.owner = "school:another"
        check(!start.matches(snapshot), "换账号后拒绝旧组件动作")
        snapshot.owner = "school:account"
        snapshot.token = UUID().uuidString
        check(!start.matches(snapshot), "随机身份变化后拒绝旧按钮")
        check(WidgetCommand(url: URL(string: "linyu-widget://start?sn=A")!) == nil, "外部不完整链接不触发水控")
        check(WidgetCommand(url: URL(string: "https://start")!) == nil, "非组件链接拒绝执行")
        let encoded = try JSONEncoder().encode(snapshot)
        check(try JSONDecoder().decode(WidgetSnapshot.self, from: encoded) == snapshot, "快照序列化完整保留设备与订单")
        let before = snapshot.controlIdentity
        snapshot.balance = "¥ 5.00"
        snapshot.devices[0].rssi = -65
        check(before == snapshot.controlIdentity, "余额和信号刷新不使控制身份失效")
        snapshot.devices[0].startedAt = 456
        check(before != snapshot.controlIdentity, "新会话时间使旧控制身份失效")
        check(snapshot.selected("")?.id == "A", "默认选中上次设备")
        let detail = WidgetCommand(url: WidgetCommand.url(.billDetail, snapshot: snapshot, device: nil, billID: "bill/123 中文"))!
        check(detail.kind == .billDetail && detail.billID == "bill/123 中文", "具体账单点击保留完整账单身份")
        let deviceLink = WidgetCommand(url: WidgetCommand.url(.device, snapshot: snapshot, device: snapshot.devices[0]))!
        check(deviceLink.kind == .device && deviceLink.sn == "A", "附近设备点击进入对应设备详情")
        check(WidgetCommand(url: WidgetCommand.url(.refreshNearby, snapshot: snapshot, device: nil))?.kind == .refreshNearby, "刷新与普通附近导航使用不同动作")
        check(WidgetCommand(url: URL(string: "linyu-widget://start?owner=x&owner=y&sn=A&order=&start=0")!) == nil, "拒绝重复参数绕过身份校验")
        let device = WidgetDevice(id: "water", name: "320房", detail: "洗手台热水器", emoji: "🪥")
        let wrong = WidgetBill(name: "320房", emoji: "🚿", time: "2026-11-03", money: "-¥1.84", detail: "卫生间热水器", amount: 1.84)
        var right = wrong; right.detail = device.detail; right.amount = 0.5
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [wrong]) == 0, "同房不同设备类型不能串用消费")
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [wrong, right]) == 0.5, "已有账单补齐对应设备消费")
        check(WidgetDisplayPolicy.lastConsume(cached: 0.8, device: device, bills: [right]) == 0.8, "较旧账单不覆盖已记录的设备消费")
        right.deviceSN = "other"
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [right]) == 0, "明确不同序列号时不按相同名字猜测")
        right.deviceSN = "water"; right.name = "旧设备名"
        check(WidgetDisplayPolicy.lastConsume(cached: 0, device: device, bills: [right]) == 0.5, "序列号精确匹配允许名称改变")
        let oldBill = Data(#"{"name":"320房","emoji":"🚿","time":"2026-11-03","money":"-¥1.84"}"#.utf8)
        check(try JSONDecoder().decode(WidgetBill.self, from: oldBill).id == nil, "升级兼容旧版组件账单缓存")
        let group = "group.com.hualala.linyu"
        let profile = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["com.apple.security.application-groups": [group + ".TEAM", "group.unrelated"]]], format: .xml, options: 0)
        check(WidgetGroupPolicy.candidates(profile: profile, original: group) == [group + ".TEAM"], "使用本应用签名后的组名且不读取无关应用组")
        check(WidgetGroupPolicy.candidates(profile: nil, original: group) == [group], "模拟器及无描述文件时使用原组名")
        check(WidgetGroupPolicy.candidates(profile: Data("broken".utf8), original: group) == [group], "损坏描述文件不崩溃")
        let now = Date()
        check(WidgetDisplayPolicy.syncedAgo(now, now: now) == "刚刚", "组件刚同步文案中文")
        check(WidgetDisplayPolicy.syncedAgo(now.addingTimeInterval(-120), now: now) == "2 分钟前", "组件分钟文案不受英文系统影响")
        check(WidgetDisplayPolicy.syncedAgo(now.addingTimeInterval(-7200), now: now) == "2 小时前", "组件小时文案中文")
        if failures > 0 { fatalError("\(failures) widget checks failed") }
    }
}
