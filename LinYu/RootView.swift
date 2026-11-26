import SwiftUI

/// 根视图：注入主题色 + 按登录态切页。
///
/// 主题色用 `Environment` 往下传，任何子视图读 `@Environment(\.appColors)` 即可，
/// 不用每个页面都接一个 `@EnvironmentObject`。
struct RootView: View {
    @ObservedObject private var session = Session.shared
    @AppStorage("linyu.darkMode") private var isDark = false
    /// 圆形揭示主题切换（对照 Android CircularRevealTheme）
    @StateObject private var reveal = ThemeReveal()

    private var colors: AppColorSet { isDark ? .dark : .light }

    var body: some View {
        ZStack {
            if session.isLoggedIn {
                MainTabView()
                    .id(session.requestGeneration)
                    .environmentObject(session)
            } else {
                LoginView()
                    .environmentObject(session)
            }
        }
        // 弹窗挂在稳定的根容器，清理失效登录并切换页面时仍能显示。
        .alert(
            "登录已失效",
            isPresented: Binding(
                get: { session.kickedReason != nil },
                set: { if !$0 { _ = session.consumeKickReason() } }
            )
        ) {
            Button("重新登录") { _ = session.consumeKickReason() }
        } message: {
            Text("账户已在别处登录，请重新登陆。")
                .multilineTextAlignment(.center)
        }
        // 遮罩盖在**所有内容之上**（包括弹窗），否则过渡时会看到底层先变色
        .overlay {
            if let animation = reveal.animation {
                ThemeRevealOverlay(animation: animation, progress: reveal.progress)
            }
        }
        .environmentObject(reveal)
        .environment(\.appColors, colors)
        .environment(\.isDarkMode, isDark)
        .preferredColorScheme(isDark ? .dark : .light)
        .scrollIndicators(.hidden)
        .tint(colors.accent)
    }
}
