import CoreBluetooth
import SwiftUI

/// 主界面 —— 逐条对照 Android 的 `MainScreen.kt`。
///
/// 结构（自上而下）：
/// ```
/// 淋浴 / Hualala             [编辑] [扫码] [刷新]
/// 使用中的设备 / 上次使用设备
/// 常用设备
/// 附近设备                          一卡通余额 ¥55.46
/// 🏠 已筛选：3层-320  取消筛选
/// ● 扫描中...                ●强 ●中 ●弱
/// [设备卡片…]
/// ```
struct MainScreenView: View {
    @ObservedObject private var widgets = WidgetBridge.shared
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors
    @Environment(\.isDarkMode) private var isDark

    /// 扫描器由 MainTabView 持有：首页要展示列表，「我的 → 绑定寝室」也要读附近设备，
    /// 两个页面必须共用同一份扫描结果（各建一个会重复扫描、结果还不一致）
    @ObservedObject var scanner: BLEScanner
    /// 账单/余额缓存，同样由容器持有
    @ObservedObject var store: AppDataStore
    /// 由 MainTabView 注入，用水页也在那一层切换
    @ObservedObject var flow: ShowerFlow
    let onResumeOrder: () -> Void

    /// snCode → 台账
    @State private var resolved: [String: DeviceInfo] = [:]
    @State private var resolving: Set<String> = []
    @State private var detailDevice: DeviceInfo?
    @State private var deviceDetailTask: Task<Void, Never>?
    @State private var showQr = false
    @State private var editing = false
    @State private var homeLayout = HomeDeviceLayout()
    @State private var layoutOwner = ""

    /// 寝室筛选条件（ViewModel 的等价物：改完要立刻刷新列表）
    @AppStorage("boundRoom") private var boundRoom = ""
    /// 下拉刷新中
    @State private var refreshing = false

    // MARK: - 派生

    /// 能解析出 snCode 的设备（解析不出来的不是这批水表）
    private var scanned: [DiscoveredPeripheral] {
        scanner.devices.filter { device in
            guard let sn = device.parsedSnCode else { return false }
            return store.deviceInfos[sn] != nil
        }
    }

    /// 按寝室筛选后的列表
    private var filtered: [DiscoveredPeripheral] {
        guard !boundRoom.isEmpty else { return scanned }
        return scanned.filter { d in
            let sn = d.parsedSnCode ?? ""
            let name = store.deviceInfos[sn]?.deviceName ?? d.name
            return DeviceInfo.inSameRoom(boundKey: boundRoom, deviceName: name)
        }
    }

    /// 余额：真实余额优先（一卡通 > 钱包），否则本地估算
    private var displayBalance: Double? {
        if BalanceEstimator.hasRealBalance { return BalanceEstimator.realBalance }
        return store.balanceBillsLoaded ? BalanceEstimator.estimate(store.balanceBills) : nil
    }

    private var balanceText: String {
        guard let b = displayBalance else { return "\(BalanceEstimator.title) ¥ —" }
        return "\(BalanceEstimator.title) \(BalanceEstimator.format(b))"
    }

    private var homeOwner: String {
        guard session.isLoggedIn, !session.userId.isEmpty, !session.projectId.isEmpty, !session.accountId.isEmpty else { return "" }
        return "\(session.userId):\(session.projectId):\(session.accountId)"
    }

    private var lastFavorite: HomeFavoriteDevice? {
        let matches = homeLayout.favorites.filter {
            $0.matchesIdentity(sn: Prefs.lastDeviceSnCode, mac: Prefs.lastDeviceMac)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private var displayedSections: [HomeDeviceSection] {
        if editing { return homeLayout.sections }
        return homeLayout.sections.filter { section in
            !homeLayout.hidden.contains(section) && (section != .lastUsed ||
                (flow.restoredOrders.isEmpty && !Prefs.lastDeviceSnCode.isEmpty))
        }
    }

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    // ⚠️ 顶部留白和账单页 / 我的页一致（都是 20），
                    // 否则三个 tab 的标题不在同一高度
                    header

                    // 使用中的设备（**可以有多台**，对照 Android `activeOrders.forEach`）
                    if !flow.restoredOrders.isEmpty {
                        sectionTitle("使用中的设备")
                        ForEach(flow.restoredOrders, id: \.snCode) { record in
                            restoredOrderCard(
                                record,
                                isCurrent: flow.activeOrder?.snCode == record.snCode
                            )
                        }
                    }
                    ForEach(displayedSections) { section in
                        let isVisible = !homeLayout.hidden.contains(section)
                        Section {
                            homeSectionContent(section, opacity: isVisible ? 1 : 0.45)
                        } header: {
                            homeSectionHeader(section, isVisible: isVisible)
                        }
                    }

                    Color.clear.frame(height: 100)   // 给悬浮导航栏留位置
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            // ⚠️ 裁剪：不加的话滚动时内容会画到状态栏/导航栏区域上，
            // 表现为「文字盖住状态栏」。Android 那边是 statusBarsPadding() 保证的，
            // iOS 靠「内容留在安全区内 + 这里裁掉溢出」等价实现。
            .clipped()
            .refreshable {
                await refreshAll()
                if flow.restoredOrders.isEmpty { scanner.start() }
            }
        }
        .fullScreenCover(isPresented: $showQr) {
            QrScanView { sn in
                showQr = false
                if !sn.isEmpty { Task { await bindBySn(sn) } }
            } onCancel: {
                showQr = false
            }
        }
        .task {
            // 关键：让扫描器把连接事件转发给业务会话（iOS 只能有一个 central）
            scanner.activeSession = flow.ble
            // ⚠️ 首次进页面才拉账单；之后切回来直接复用容器里的缓存
            await store.loadIfNeeded()
            guard !Task.isCancelled else { return }
            // ⚠️ 只在**还没有扫到设备**时才启动扫描。
            // 之前每次切回首页都重新 start()，而 start() 会清空列表，
            // 于是设备先闪回广播名（KLCXKJ-Water）再变回房间名。
            // Android 那边是下拉刷新才重新扫描。
            if scanner.devices.isEmpty && flow.restoredOrders.isEmpty { scanner.start() }
            for device in scanner.devices {
                if let sn = device.parsedSnCode { await resolveDevice(sn) }
            }
        }
        .onChange(of: scanner.devices) { list in
            for d in list {
                guard let sn = d.parsedSnCode else { continue }
                guard store.deviceInfos[sn] == nil, !resolving.contains(sn) else { continue }
                resolving.insert(sn)
                Task { await resolveDevice(sn) }
            }
        }
        .task(id: homeOwner) {
            let owner = homeOwner
            homeLayout = HomeDeviceLayoutStore.read(owner: owner)
            layoutOwner = owner
        }
        .onChange(of: homeOwner) { _ in
            editing = false
            detailDevice = nil
            deviceDetailTask?.cancel()
        }
        .onDisappear {
            scanner.stop()
            deviceDetailTask?.cancel()
        }
        // 弹窗全部走**居中卡片**（Material3 AlertDialog 的样子），
        // 不用 .sheet —— 那会从底部升上来，和 Android 完全不一样
        .overlay { dialogLayer }
        .task { openWidgetDevice() }
        .onChange(of: widgets.pendingDeviceSN) { _ in openWidgetDevice() }
    }

    // MARK: - 弹窗层

    @ViewBuilder
    private var dialogLayer: some View {
        if let d = detailDevice {
            DeviceDetailDialogView(
                device: d,
                isActive: isDeviceActive(d),
                // 他人使用中：按钮置灰，避免拿别人的订单去开阀
                isOwner: flow.isOwnerFor(d.snCode ?? ""),
                onDismiss: { detailDevice = nil },
                onConfirm: { confirmOpen(d) },
                isFavorite: favoriteDevice(d).flatMap { homeLayout.favorite(matching: $0) } != nil,
                onFavorite: { toggleFavorite(d) }
            )
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("淋浴")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                    .frame(height: PageLayout.titleHeight)
                Text("Hualala")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                EditModeButton(isEditing: editing, circleBackground: true) {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { editing.toggle() }
                }
                .accessibilityLabel(editing ? "完成编辑" : "编辑首页")
                circleIconButton {
                    showQr = true
                } content: {
                    VectorIconView(icon: DeviceIcons.qrScanner, size: 20, tint: colors.textPrimary)
                }
                .accessibilityLabel("扫码绑定设备")
                circleIconButton {
                    Task {
                        await refreshAll()
                        if flow.activeOrder == nil { scanner.start() }
                    }
                } content: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(colors.textPrimary)
                }
                .disabled(refreshing)
                .accessibilityLabel("刷新附近设备")
            }
        }
        .frame(height: PageLayout.headerHeight, alignment: .top)
    }

    private func circleIconButton<C: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> C
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(colors.card)
                content()
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(PressableCardStyle())
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func homeSectionHeader(_ section: HomeDeviceSection, isVisible: Bool) -> some View {
        let order = homeLayout.sections
        let index = order.firstIndex(of: section) ?? 0
        return HStack(spacing: 0) {
            Text(isVisible ? section.title : "\(section.title)（已隐藏）")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isVisible ? colors.textPrimary : colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if editing {
                moveButtons(index: index, count: order.count) { offset in
                    updateHomeLayout { $0.moveSection(section, by: offset) }
                }
                homeEditButton(isVisible ? "eye.slash" : "eye",
                               title: isVisible ? "隐藏\(section.title)" : "显示\(section.title)",
                               tint: isVisible ? colors.textSecondary : colors.success) {
                    updateHomeLayout { $0.toggleSection(section) }
                }
            } else if section == .nearby {
                Text(balanceText)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func homeSectionContent(_ section: HomeDeviceSection, opacity: Double) -> some View {
        switch section {
        case .lastUsed:
            if Prefs.lastDeviceSnCode.isEmpty {
                Text("暂无使用记录")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(opacity)
            } else {
                lastDeviceCard.opacity(opacity)
            }
        case .favorites:
            if homeLayout.favorites.isEmpty {
                Text("点编辑，从设备列表添加常用设备")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(opacity)
            }
            ForEach(homeLayout.favorites) { favorite in
                favoriteCard(favorite).opacity(opacity)
            }
        case .nearby:
            let devices = editing ? scanned : filtered
            if !editing && !boundRoom.isEmpty { boundRoomRow.opacity(opacity) }
            if scanner.isScanning { scanningRow.opacity(opacity) }
            if devices.isEmpty && !scanner.isScanning { emptyHint.opacity(opacity) }
            ForEach(devices, id: \.id) { device in deviceCard(device).opacity(opacity) }
        }
    }

    @ViewBuilder
    private func moveButtons(index: Int, count: Int, onMove: @escaping (Int) -> Void) -> some View {
        homeEditButton("chevron.up", title: "上移", enabled: index > 0, tint: colors.accent) { onMove(-1) }
        homeEditButton("chevron.down", title: "下移", enabled: index < count - 1, tint: colors.accent) { onMove(1) }
    }

    private func homeEditButton(_ symbol: String, title: String, enabled: Bool = true,
                                tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(enabled ? tint : colors.textSecondary.opacity(0.3))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(InstantButtonStyle())
        .accessibilityLabel(title)
        .disabled(!enabled)
    }

    // MARK: - 使用中的设备

    // MARK: - 上次使用设备

    /// 已落盘、但未进入使用页的订单（App 重启 / 被挤号重登后的恢复入口）。
    ///
    /// ⚠️ 这张卡不能省：没有它，用户重开 App 后**完全不知道水还在流**，
    /// 也找不到关阀入口——只能等账单出来才知道被扣了钱。
    private func restoredOrderCard(_ record: ActiveOrderRecord, isCurrent: Bool = false) -> some View {
        HStack(spacing: 14) {
            DeviceGlyph(
                emoji: record.deviceEmoji.isEmpty ? "🚿" : record.deviceEmoji,
                boxSize: 48,
                cornerRadius: 14,
                emojiSize: 22,
                iconSize: 26,
                background: DeviceGlyph.background(for: record.deviceEmoji, defaultColor: colors.accent)
            )

            VStack(alignment: .leading, spacing: 4) {
                TailEllipsisText(
                    text: record.deviceName.isEmpty ? "热水器" : record.deviceName,
                    fontSize: 15,
                    weight: .semibold,
                    color: colors.textPrimary
                )
                HStack(spacing: 8) {
                    Text("使用中")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colors.activeBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("点击恢复订单")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
            }
            Spacer(minLength: 0)

            Button("恢复") {
                if isCurrent {
                    onResumeOrder()
                } else {
                    Task {
                        await flow.resume(record: record)
                        if flow.activeOrder?.snCode == record.snCode { onResumeOrder() }
                    }
                }
            }
            .buttonStyle(AccentButtonStyle(colors: colors))
        }
        .padding(16)
        .background(colors.activeBg)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(colors.border, lineWidth: 0.8)
        )
    }

    private var lastDeviceCard: some View {
        quickDeviceCard(
            name: Prefs.lastDeviceName.isEmpty ? "热水器" : Prefs.lastDeviceName,
            mac: Prefs.lastDeviceMac,
            emoji: Prefs.lastDeviceEmoji
        ) {
            if editing {
                HomeFavoriteButton(selected: lastFavorite != nil) {
                    if let lastFavorite {
                        updateHomeLayout { $0.removeFavorite(lastFavorite.id) }
                    } else {
                        Task { await addLastFavorite() }
                    }
                }
            } else {
                Button("开始") {
                    Task { await startLastDevice() }
                }
                .buttonStyle(AccentButtonStyle(colors: colors))
            }
        }
    }

    @ViewBuilder
    private func favoriteCard(_ favorite: HomeFavoriteDevice) -> some View {
        if editing {
            quickDeviceCard(name: favorite.name, mac: favorite.macAddress, emoji: favorite.emoji) {
                let index = homeLayout.favorites.firstIndex(of: favorite) ?? 0
                moveButtons(index: index, count: homeLayout.favorites.count) { offset in
                    updateHomeLayout { $0.moveFavorite(favorite.id, by: offset) }
                }
                HomeFavoriteButton(selected: true) {
                    updateHomeLayout { $0.removeFavorite(favorite.id) }
                }
            }
        } else {
            Button {
                openFavorite(favorite)
            } label: {
                quickDeviceCard(name: favorite.name, mac: favorite.macAddress, emoji: favorite.emoji) {
                    navigationChevron
                }
            }
            .buttonStyle(PressableCardStyle())
        }
    }

    private func quickDeviceCard<Actions: View>(name: String, mac: String, emoji: String,
                                                @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 14) {
            DeviceGlyph(
                emoji: emoji,
                boxSize: 48,
                cornerRadius: 14,
                emojiSize: 22,
                iconSize: 26,
                background: DeviceGlyph.background(for: emoji)
            )

            VStack(alignment: .leading, spacing: 4) {
                TailEllipsisText(
                    text: name,
                    fontSize: 15,
                    weight: .semibold,
                    color: colors.textPrimary
                )
                TailEllipsisText(
                    text: "MAC: \(mac)",
                    fontSize: 12,
                    color: colors.textSecondary
                )
            }
            Spacer(minLength: 0)

            actions()
        }
        .padding(16)
        .linyuCard(colors)
    }

    // MARK: - 附近设备

    private var boundRoomRow: some View {
        HStack(spacing: 8) {
            Text("🏠 已筛选：\(DeviceInfo.roomKey(boundRoom) ?? boundRoom)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.accent)
            Button {
                boundRoom = ""
                Prefs.boundRoom = ""
                flow.toast = "已取消寝室筛选"
            } label: {
                Text("取消筛选")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }
            .buttonStyle(InstantButtonStyle())
            Spacer()
        }
    }

    private var scanningRow: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(colors.accent)
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
                Text("扫描中...")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                LegendDot(color: colors.success, label: "强", textColor: colors.textSecondary)
                LegendDot(color: colors.warning, label: "中", textColor: colors.textSecondary)
                LegendDot(color: colors.danger, label: "弱", textColor: colors.textSecondary)
            }
        }
    }

    private var emptyHint: some View {
        Text(boundRoom.isEmpty || editing ? "未发现附近设备" : "未找到寝室内的设备")
            .font(.system(size: 14))
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(32)
    }

    @ViewBuilder
    private func deviceCard(_ d: DiscoveredPeripheral) -> some View {
        let sn = d.parsedSnCode ?? ""
        if editing {
            nearbyCard(d) {
                if let info = store.deviceInfos[sn] {
                    HomeFavoriteButton(selected: favoriteDevice(info).flatMap { homeLayout.favorite(matching: $0) } != nil) {
                        toggleFavorite(info)
                    }
                } else {
                    Color.clear.frame(width: 36, height: 36)
                }
            }
        } else {
            Button { openDetail(sn) } label: {
                nearbyCard(d) { navigationChevron }
            }
            .buttonStyle(PressableCardStyle())
        }
    }

    private var navigationChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(colors.textSecondary)
            .frame(width: 36, height: 36)
    }

    private func nearbyCard<Actions: View>(_ d: DiscoveredPeripheral,
                                            @ViewBuilder actions: () -> Actions) -> some View {
        let sn = d.parsedSnCode ?? ""
        let info = store.deviceInfos[sn]
        let sigColor: Color = d.rssi >= -70 ? colors.success
            : (d.rssi >= -85 ? colors.warning : colors.danger)
        // ⚠️ 文案照搬 Android `NearbyDevice.signalText`：`"信号强度: $rssi dBm"`
        // ——就是这一句，不要自己改成「强/中/弱」之类的说法
        let sigLabel = "信号强度: \(d.rssi) dBm"

        return HStack(spacing: 14) {
            DeviceGlyph(
                emoji: info?.typeEmoji ?? "🚿",
                boxSize: 48,
                cornerRadius: 14,
                emojiSize: 22,
                iconSize: 26,
                background: info.map { $0.typeColor } ?? colors.accent
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(info?.displayName ?? (d.name.isEmpty ? "未命名设备" : d.name))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sigLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(sigColor)
                Text("MAC: \(info?.macAddress ?? sn)")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .linyuCard(colors)
    }

    // MARK: - 数据加载

    private func updateHomeLayout(_ change: (inout HomeDeviceLayout) -> Void) {
        let owner = homeOwner
        guard !owner.isEmpty, layoutOwner == owner else { return }
        var layout = homeLayout
        change(&layout)
        guard layout != homeLayout else { return }
        homeLayout = layout
        HomeDeviceLayoutStore.save(layout, owner: owner)
    }

    private func favoriteDevice(_ device: DeviceInfo) -> HomeFavoriteDevice? {
        HomeFavoriteDevice(snCode: device.snCode, macAddress: device.macAddress, projectId: device.projectId,
                           defaultProjectId: Int(session.projectId), isDrinkingWater: device.isDrinkingWater,
                           name: device.displayName, emoji: device.typeEmoji)
    }

    private func toggleFavorite(_ device: DeviceInfo) {
        guard let favorite = favoriteDevice(device) else {
            flow.toast = "设备信息未确认，暂无法收藏"
            return
        }
        updateHomeLayout { $0.toggleFavorite(favorite) }
    }

    private func addLastFavorite() async {
        let sn = Prefs.lastDeviceSnCode
        let mac = Prefs.lastDeviceMac
        let generation = session.requestGeneration
        guard !sn.isEmpty else { return }
        do {
            let info: DeviceInfo?
            if let cached = store.deviceInfos[sn] {
                info = cached
            } else {
                info = try await DeviceLookup.load(mac.isEmpty ? sn : mac)
            }
            guard SessionWork.isCurrent(generation),
                  Prefs.lastDeviceSnCode == sn, Prefs.lastDeviceMac == mac else { return }
            guard let info, let favorite = favoriteDevice(info), favorite.snCode == sn else {
                flow.toast = "设备信息未确认，暂无法收藏"
                return
            }
            updateHomeLayout {
                if $0.favorite(matching: favorite) == nil { $0.toggleFavorite(favorite) }
            }
        } catch {
            guard SessionWork.isCurrent(generation) else { return }
            flow.toast = "获取设备信息失败，请重试"
        }
    }

    private func openFavorite(_ favorite: HomeFavoriteDevice) {
        deviceDetailTask?.cancel()
        let generation = session.requestGeneration
        deviceDetailTask = Task {
            do {
                let result: DeviceInfo?
                if favorite.projectId != nil, let cached = store.deviceInfos[favorite.snCode],
                   let candidate = favoriteDevice(cached), favorite.matches(candidate),
                   favorite.matchesIdentity(sn: candidate.snCode, mac: candidate.macAddress) {
                    result = cached
                } else {
                    result = try await DeviceLookup.load(favorite.macAddress)
                }
                guard SessionWork.isCurrent(generation), !editing else { return }
                guard let info = result else {
                    flow.toast = "获取设备信息失败，请重试"
                    return
                }
                guard let fresh = favoriteDevice(info), favorite.matches(fresh) else {
                    flow.toast = "设备信息已变化，请重新扫码或刷新附近设备"
                    return
                }
                guard favorite.accepts(fresh, explicitProjectId: info.projectId) else {
                    flow.toast = "设备项目待确认，请稍后重试"
                    return
                }
                updateHomeLayout { $0.confirmFavorite(favorite, with: fresh, explicitProjectId: info.projectId) }
                store.putDeviceInfo(info, sn: fresh.snCode)
                detailDevice = info
                await flow.refreshDeviceStatus(fresh.snCode)
            } catch {
                guard SessionWork.isCurrent(generation) else { return }
                flow.toast = LoginFeedback.message(error, fallback: "获取设备信息失败，请重试")
            }
        }
    }

    private func refreshAll() async {
        refreshing = true
        defer { refreshing = false }

        await store.reload()
        boundRoom = Prefs.boundRoom
    }

    /// 查台账。结果存在 `AppDataStore` 里（跨页面保留），
    /// 所以切走再切回来**不会**再显示一次广播名
    private func resolveDevice(_ sn: String) async {
        defer { resolving.remove(sn) }
        await store.deviceInfo(sn)
        // 台账拿到之后再问一次「这台有没有订单」——对照 Android `fetchInfo`：
        // 用使用码在键盘上开机后，这里能发现「已经有订单」，首页就会出现使用中卡片
        guard let info = store.deviceInfos[sn] else { return }
        scanner.register(info: info, advertisedSN: sn)
        if let ledgerSN = info.snCode { await flow.refreshDeviceStatus(ledgerSN) }
    }

    private func openDetail(_ sn: String) {
        deviceDetailTask?.cancel()
        // Android fetchDeviceInfo：缓存命中立即展示，查询占用不挡住点击反馈。
        if let info = store.deviceInfos[sn] {
            scanner.register(info: info, advertisedSN: sn)
            detailDevice = info
            deviceDetailTask = Task { if let ledgerSN = info.snCode { await flow.refreshDeviceStatus(ledgerSN) } }
            return
        }
        let generation = session.requestGeneration
        deviceDetailTask = Task {
            await store.deviceInfo(sn)
            guard SessionWork.isCurrent(generation) else { return }
            guard let info = store.deviceInfos[sn] else {
                flow.toast = store.deviceLookupMessages[sn] ?? "获取设备信息失败，请稍后重试"
                return
            }
            detailDevice = info
            scanner.register(info: info, advertisedSN: sn)
            if let ledgerSN = info.snCode { await flow.refreshDeviceStatus(ledgerSN) }
        }
    }

    private func openWidgetDevice() {
        guard let sn = widgets.pendingDeviceSN, !sn.isEmpty else { return }
        widgets.pendingDeviceSN = nil
        openDetail(sn)
    }

    /// 这台设备有没有活跃订单。
    ///
    /// ⚠️ 不能只比 `activeOrder`：那只是「使用页当前显示的那一单」，
    /// 同时开着两台时，另一台也是「使用中」，点它应该恢复而不是再开一次。
    private func isDeviceActive(_ device: DeviceInfo) -> Bool {
        let sn = device.snCode ?? ""
        guard !sn.isEmpty else { return false }
        return flow.restoredOrders.contains { $0.snCode == sn } || !flow.isOwnerFor(sn)
    }

    /// 详情弹窗里点了「开始使用」
    private func confirmOpen(_ device: DeviceInfo) {
        detailDevice = nil
        let sn = device.snCode ?? ""
        if let record = flow.restoredOrders.first(where: { $0.snCode == sn }) {
            if let recordProject = record.projectId, let projectId = device.projectId,
               projectId > 0, recordProject != String(projectId) {
                flow.toast = "设备所属项目已变化，请在官方 App 核对订单"
                return
            }
            // 已经在用：当前显示的那一单回使用页，其它单走恢复流程
            if flow.activeOrder?.snCode == sn {
                onResumeOrder()
            } else {
                Task {
                    await flow.resume(record: record)
                    if flow.activeOrder?.snCode == record.snCode { onResumeOrder() }
                }
            }
            return
        }
        let peripheral = scanner.peripheral(forSn: sn)
        let central = scanner.manager

        if device.needsBluetoothControl || Prefs.isBleDevice(sn) {
            guard peripheral != nil else {
                flow.toast = "这台是蓝牙表，需要先扫描到它才能连接"
                return
            }
        }
        Task {
            await flow.open(device: device, peripheral: peripheral, central: central)
            if flow.activeOrder?.snCode == sn { onResumeOrder() }
        }
    }

    /// 「上次使用设备」→ 开始。
    ///
    /// ⚠️ 这里**不需要扫描到设备**：普通 4G 表走云端，服务端推给设备就行。
    /// 只有蓝牙表（服务端标记 or 用户确认过）才必须有连接对象——那种情况才提示去附近设备里选。
    private func startLastDevice() async {
        let sn = Prefs.lastDeviceSnCode
        guard !sn.isEmpty else {
            flow.toast = "没有上次使用的设备"
            return
        }

        let info: DeviceInfo
        if let cached = store.deviceInfos[sn] {
            info = cached
        } else {
            do {
                guard let d = try await DeviceLookup.load(sn) else {
                    flow.toast = "未查询到该设备，请检查设备码"
                    return
                }
                await store.putDeviceInfo(d, sn: sn)
                info = d
            } catch {
                flow.toast = "获取设备信息失败：\(LoginFeedback.message(error))"
                return
            }
        }

        if info.needsBluetoothControl || Prefs.isBleDevice(sn) {
            guard let p = scanner.peripheral(forSn: sn), let central = scanner.manager else {
                flow.toast = "这台是蓝牙表，请从「附近设备」中选它（需要先扫描到）"
                return
            }
            await flow.open(device: info, peripheral: p, central: central)
        } else {
            // 云端通道，不需要连接对象
            await flow.open(device: info, peripheral: nil, central: nil)
        }
        if flow.activeOrder?.snCode == (info.snCode ?? sn) { onResumeOrder() }
    }

    /// 扫码绑定：扫到 snCode 后查台账并直接打开详情
    private func bindBySn(_ sn: String) async {
        deviceDetailTask?.cancel()
        let generation = session.requestGeneration
        await resolveDevice(sn)
        guard SessionWork.isCurrent(generation) else { return }
        guard let info = store.deviceInfos[sn] else {
            flow.toast = store.deviceLookupMessages[sn] ?? "未查询到该设备，请检查设备码"
            return
        }
        detailDevice = info
    }
}
