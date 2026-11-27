import SwiftUI

/// 「我的账号」与「设置」共用主界面的编辑状态。开关管理支持组内排序和移入移出。
struct UserScreenView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.appColors) private var colors
    @EnvironmentObject private var store: AppDataStore
    @EnvironmentObject private var presentation: UserPresentation
    /// 主题切换的圆形揭示
    @EnvironmentObject private var reveal: ThemeReveal

    @ObservedObject var flow: ShowerFlow
    @ObservedObject var scanner: BLEScanner
    /// 进设置页时底部导航栏要消失（Android 也是这么做的）
    @Binding var settingsVisible: Bool
    @Binding var editMode: Bool
    let roomPluginInstalled: Bool
    let trendPluginInstalled: Bool
    let keepScreenOnPluginInstalled: Bool
    let backgroundPluginInstalled: Bool
    let runtimeLogPluginInstalled: Bool
    let onOpenPluginManagement: () -> Void

    @AppStorage("linyu.darkMode") private var isDark = false

    @State private var showSettings = false
    @State private var featuresExpanded = true
    /// 主题按钮在屏幕坐标里的位置（揭示动画的原点）
    @State private var themeAnchor: CGRect = .zero

    @State private var pages: UserCardLayout.Pages
    @State private var profileHidden: Set<String> = UserCardLayout.loadHidden("userProfileHiddenCards")
    @State private var settingsHidden: Set<String> = UserCardLayout.loadHidden("userSettingsHiddenCards")

    init(flow: ShowerFlow, scanner: BLEScanner, settingsVisible: Binding<Bool>, editMode: Binding<Bool>,
         roomPluginInstalled: Bool, trendPluginInstalled: Bool, keepScreenOnPluginInstalled: Bool,
         backgroundPluginInstalled: Bool, runtimeLogPluginInstalled: Bool,
         onOpenPluginManagement: @escaping () -> Void) {
        self.flow = flow
        self.scanner = scanner
        _settingsVisible = settingsVisible
        _editMode = editMode
        self.roomPluginInstalled = roomPluginInstalled
        self.trendPluginInstalled = trendPluginInstalled
        self.keepScreenOnPluginInstalled = keepScreenOnPluginInstalled
        self.backgroundPluginInstalled = backgroundPluginInstalled
        self.runtimeLogPluginInstalled = runtimeLogPluginInstalled
        self.onOpenPluginManagement = onOpenPluginManagement
        _pages = State(initialValue: UserCardLayout.loadPages())
    }

    private var versionText: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "?"
        return "Hualala v\(v) · 哗啦啦啦啦让我去淋浴~"
    }

    var body: some View {
        ZStack {
            // 整屏页面（背景装扮 / 运行日志）由 MainTabView 渲染 —— 它们必须盖住
            // 底部导航和整个屏幕（对照 Android 的全屏 Dialog），放在这里会被页面范围限制。
            if showSettings {
                settingsPage
            } else {
                profilePage
            }
        }
        .onAppear { settingsVisible = showSettings || presentation.page != nil }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onChange(of: showSettings) { v in settingsVisible = v || presentation.page != nil }
        .onChange(of: presentation.page) { page in settingsVisible = showSettings || page != nil }
        .onDisappear { settingsVisible = false }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard presentation.dialog == nil, value.startLocation.x < 24,
                      value.translation.width > 80, abs(value.translation.height) < 50 else { return }
                if presentation.page != nil { presentation.page = nil; return }
                guard showSettings else { return }
                showSettings = false
            }
        )
    }

    // MARK: - 我的

    @ViewBuilder
    private var profilePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(showBack: false)

                cardList(
                    order: $pages.profile,
                    hidden: $profileHidden,
                    hiddenKey: "userProfileHiddenCards",
                    moveIcon: "arrow.right",
                    moveHint: "移到设置页面",
                    onMove: { moveAcrossPages($0, to: .settings) }
                ) { type in
                    // 插件管理被移到「我的」页时也要渲染，否则是空白卡
                    if type == .pluginManagement { pluginManagementEntry }
                    else { card(type) }
                }

                Color.clear.frame(height: 100)
            }
            .padding(.horizontal, PageLayout.horizontalInset)
            .padding(.vertical, PageLayout.topInset)
        }
        .clipped()
    }

    // MARK: - 设置

    @ViewBuilder
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(showBack: true)

                cardList(
                    order: $pages.settings,
                    hidden: $settingsHidden,
                    hiddenKey: "userSettingsHiddenCards",
                    moveIcon: "arrow.left",
                    moveHint: "移到我的页面",
                    onMove: { moveAcrossPages($0, to: .profile) },
                    onMoveIntoFeatures: { moveCard($0, to: .features) }
                ) { type in
                    if type == .pluginManagement { pluginManagementEntry }
                    else if type == .featureManagement { featureManagementCard }
                    else { card(type) }
                }

                // 对照 Android `UserScreen.kt:409`：点击只是把事件往上抛，
                // 真正的确认弹窗在容器层（MainActivity）——iOS 这边同理放在本页 overlay
                Button {
                    presentation.dialog = .logout
                } label: {
                    Text("退出登录")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(colors.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .contentShape(Rectangle())
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(colors.danger.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(InstantButtonStyle())
                .padding(.top, 8)

                Text(versionText)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.top, 8)

                Color.clear.frame(height: 100)
            }
            .padding(.horizontal, PageLayout.horizontalInset)
            .padding(.vertical, PageLayout.topInset)
        }
        .clipped()
    }

    private func header(showBack: Bool) -> some View {
        HStack(alignment: .center) {
            if showBack {
                Button {
                    showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("返回我的账号")
            }

            Text(showBack ? "设置" : "我的账号")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(colors.textPrimary)

            Spacer()

            EditModeButton(isEditing: editMode) {
                editMode.toggle()
            }

            if !showBack {
                Button {
                    toggleTheme()
                } label: {
                    Text(isDark ? "🌙" : "☀️")
                        .font(.system(size: 20))
                        .frame(width: 40, height: 40)
                        // 记录按钮在**屏幕坐标**里的位置：揭示动画要以它为中心扩散
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ThemeAnchorKey.self,
                                    value: g.frame(in: .global)
                                )
                            }
                        )
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel(isDark ? "切换浅色模式" : "切换深色模式")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("打开设置")
            }
        }
        .frame(height: PageLayout.titleHeight)
        .frame(height: PageLayout.headerHeight, alignment: .top)
        .padding(.bottom, 16)
        .onPreferenceChange(ThemeAnchorKey.self) { themeAnchor = $0 }
    }

    /// 切主题：有按钮位置就走圆形揭示，拿不到就退化成直接切（绝不因为动画失败而不切）
    private func toggleTheme() {
        let screen = UIScreen.main.bounds.size
        guard themeAnchor != .zero else {
            isDark.toggle()
            return
        }
        // ⚠️ coverColor 必须是**切换前**的底色：遮罩填的就是它
        reveal.toggle(
            anchor: themeAnchor,
            coverColor: colors.background,
            screen: screen
        ) {
            isDark.toggle()
        }
    }

    // MARK: - 卡片列表

    private func visibleCards(in order: [UserCardType], hidden: Set<String>) -> [UserCardType] {
        order.filter { card in
            guard editMode || !hidden.contains(card.rawValue) else { return false }
            switch card {
            case .boundRoom: return roomPluginInstalled
            case .trend: return trendPluginInstalled
            case .keepScreenOn: return keepScreenOnPluginInstalled
            case .background: return backgroundPluginInstalled
            case .log: return runtimeLogPluginInstalled
            default: return true
            }
        }
    }

    @ViewBuilder
    private func cardList<Content: View>(
        order: Binding<[UserCardType]>,
        hidden: Binding<Set<String>>,
        hiddenKey: String,
        moveIcon: String,
        moveHint: String,
        onMove: @escaping (UserCardType) -> Void,
        onMoveIntoFeatures: ((UserCardType) -> Void)? = nil,
        spacing: CGFloat = 16,
        @ViewBuilder content: @escaping (UserCardType) -> Content
    ) -> some View {
        let visible = visibleCards(in: order.wrappedValue, hidden: hidden.wrappedValue)

        ForEach(Array(visible.enumerated()), id: \.element) { index, type in
            VStack(alignment: .leading, spacing: 4) {
                if editMode {
                    HStack(spacing: 0) {
                        Text(hidden.wrappedValue.contains(type.rawValue) ? "\(type.title)（已隐藏）" : type.title)
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary.opacity(
                                hidden.wrappedValue.contains(type.rawValue) ? 0.6 : 1
                            ))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if type != .featureManagement {
                            editIcon(moveIcon, moveHint, colors.accent) {
                                onMove(type)
                            }
                        }
                        if let onMoveIntoFeatures, UserCardLayout.featureDefaults.contains(type) {
                            editIcon("plus", "移入开关管理", colors.accent) {
                                onMoveIntoFeatures(type)
                            }
                        }
                        editIcon("chevron.up", "上移", index > 0 ? colors.accent : colors.textSecondary.opacity(0.3), enabled: index > 0) {
                            guard index > 0 else { return }
                            order.wrappedValue = UserCardLayout.swap(type, with: visible[index - 1], in: order.wrappedValue)
                            UserCardLayout.savePages(pages)
                        }
                        editIcon("chevron.down", "下移",
                                 index < visible.count - 1 ? colors.accent : colors.textSecondary.opacity(0.3),
                                 enabled: index < visible.count - 1) {
                            guard index + 1 < visible.count else { return }
                            order.wrappedValue = UserCardLayout.swap(type, with: visible[index + 1], in: order.wrappedValue)
                            UserCardLayout.savePages(pages)
                        }
                        let isHidden = hidden.wrappedValue.contains(type.rawValue)
                        editIcon(
                            isHidden ? "eye" : "eye.slash",
                            isHidden ? "显示" : "隐藏",
                            isHidden ? colors.success : colors.textSecondary
                        ) {
                            var s = hidden.wrappedValue
                            if isHidden { s.remove(type.rawValue) } else { s.insert(type.rawValue) }
                            hidden.wrappedValue = s
                            UserCardLayout.saveHidden(s, key: hiddenKey)
                        }
                    }
                }

                content(type)
                    .opacity(editMode && hidden.wrappedValue.contains(type.rawValue) ? 0.45 : 1)
            }
            .padding(.bottom, spacing)

        }
    }

    private var featureManagementCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                featuresExpanded.toggle()
            } label: {
                HStack {
                    Text(UserCardType.featureManagement.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Spacer()
                    if !editMode {
                        Image(systemName: featuresExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.textSecondary)
                    }
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(InstantButtonStyle())
            .disabled(editMode)
            .accessibilityValue(featuresExpanded || editMode ? "已展开" : "已折叠")

            if featuresExpanded || editMode {
                if visibleCards(in: pages.features, hidden: settingsHidden).isEmpty && !editMode {
                    Text("暂无显示的功能")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                        .padding(8)
                }
                cardList(order: $pages.features, hidden: $settingsHidden,
                         hiddenKey: "userSettingsHiddenCards", moveIcon: "arrow.right",
                         moveHint: "移出开关管理", onMove: { moveCard($0, to: .settings) },
                         spacing: 8) { type in
                    card(type)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .linyuCard(colors)
    }

    private var pluginManagementEntry: some View {
        Button(action: onOpenPluginManagement) {
            BaseCard {
                HStack {
                    Text("插件管理")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.accent)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(InstantButtonStyle())
        .padding(.bottom, 16)
    }

    private func editIcon(
        _ symbol: String,
        _ hint: String,
        _ color: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(InstantButtonStyle())
        .accessibilityLabel(hint)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func card(_ type: UserCardType) -> some View {
        switch type {
        case .account: AccountCardView()
        case .useCode: UseCodeCardView()
        case .notify: NotifyCardView()
        case .trend: TrendToggleCardView()
        case .keepScreenOn: KeepScreenOnCardView()
        case .background: BackgroundCardView()
        case .boundRoom: BoundRoomCardView(scanner: scanner, store: store)
        case .update: SoftwareUpdateCard()
        case .about: AboutCardView()
        case .log: LogCardView { presentation.page = .log }
        case .featureManagement: EmptyView()
        case .pluginManagement: EmptyView()
        }
    }

    // MARK: - 跨页移动

    private func moveCard(_ type: UserCardType, to destination: UserCardLayout.Destination) {
        pages = UserCardLayout.move(type, to: destination, in: pages)
        UserCardLayout.savePages(pages)
    }

    private func moveAcrossPages(_ type: UserCardType, to destination: UserCardLayout.Destination) {
        moveCard(type, to: destination)
        profileHidden.remove(type.rawValue)
        settingsHidden.remove(type.rawValue)
        UserCardLayout.saveHidden(profileHidden, key: "userProfileHiddenCards")
        UserCardLayout.saveHidden(settingsHidden, key: "userSettingsHiddenCards")
    }
}
