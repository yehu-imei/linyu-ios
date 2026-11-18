import SwiftUI

/// 主题按钮在**全屏坐标系**里的位置。主题切换的圆形揭示要以它为中心扩散。
struct ThemeAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 圆形揭示（Circular Reveal）主题切换 —— 逐条对照 Android 的
/// `ui/theme/CircularRevealTheme.kt`。
///
/// ## 做法
///
/// 1. **立刻**切主题（内容与配色一起换）
/// 2. 在上面盖一层「旧主题的底色」，并把**圆形区域挖空**（`destinationOut`）
/// 3. 让圆从点击点扩散到能盖满全屏 → 视觉上新主题从点击处铺开
///
/// ## 为什么不是"先动画再切"
///
/// 那样会在动画结束时闪一下（内容在动画末尾整块换色）。Android 那边也是同一个结论：
/// 内容只渲染一次、主题在**起点**切换，过渡完全由遮罩负责。
///
/// 时序参数照抄 Android：650ms、`CubicBezier(0.4, 0, 0.2, 1)`。
@MainActor
final class ThemeReveal: ObservableObject {

    struct Animation: Equatable {
        let origin: CGPoint
        /// 旧主题的底色 —— 遮罩要填的就是它
        let coverColor: Color
        let startRadius: CGFloat
        let maxRadius: CGFloat
    }

    /// 非 nil 时遮罩在场
    @Published private(set) var animation: Animation?
    /// 0 → 1 的扩散进度。用 `scaleEffect` 驱动，才能被 SwiftUI 真正插值
    @Published private(set) var progress: CGFloat = 0

    static let duration: Double = 0.65

    /// 切主题并播放揭示动画。
    ///
    /// - Parameters:
    ///   - anchor: 按钮范围（全屏坐标）
    ///   - coverColor: **旧**主题背景色
    ///   - screen: 屏幕尺寸（用来算盖满全屏所需的半径）
    ///   - apply: 真正执行主题切换
    func toggle(
        anchor: CGRect,
        coverColor: Color,
        screen: CGSize,
        apply: () -> Void
    ) {
        // 动画进行中忽略重复点击：否则遮罩会被中途替换，看着像闪屏
        guard animation == nil else { return }

        let width = max(screen.width, 1)
        let height = max(screen.height, 1)
        let origin = CGPoint(x: anchor.midX, y: anchor.midY)
        let startRadius = hypot(anchor.width, anchor.height) / 2
        // 半径取到「最远的那个角」，保证结束时一定盖满
        let dx = max(origin.x, width - origin.x)
        let dy = max(origin.y, height - origin.y)
        let maxRadius = max(startRadius, hypot(dx, dy))

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            apply()
            animation = Animation(origin: origin, coverColor: coverColor, startRadius: startRadius, maxRadius: maxRadius)
            progress = 0
        }

        // 第一帧先露出主题按钮，让更新后的太阳或月亮立刻可见。
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: Self.duration)) {
                self.progress = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
                self.animation = nil
                self.progress = 0
            }
        }
    }
}

/// 遮罩本体：旧底色 + 中间挖掉的圆
struct ThemeRevealOverlay: View {
    let animation: ThemeReveal.Animation
    let progress: CGFloat

    var body: some View {
        let diameter = animation.maxRadius * 2
        let initialScale = animation.startRadius / animation.maxRadius
        ZStack {
            animation.coverColor
            Circle()
                .frame(width: diameter, height: diameter)
                .scaleEffect(initialScale + (1 - initialScale) * progress)
                .position(x: animation.origin.x, y: animation.origin.y)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
