import SwiftUI

/// 无淡出、缩放或系统按压背景；用于箭头、模式切换和卡片编辑。
struct InstantButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentTransition(.identity)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

struct EditModeButton: View {
    @Environment(\.appColors) private var colors
    let isEditing: Bool
    var circleBackground = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isEditing {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(colors.accent)
                } else {
                    VectorIconView(icon: DeviceIcons.editSquare, size: 20, tint: colors.textPrimary, viewport: 32)
                }
            }
            .frame(width: 40, height: 40)
            .background {
                if circleBackground { Circle().fill(colors.card) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InstantButtonStyle())
        .accessibilityLabel(isEditing ? "完成编辑" : "编辑")
    }
}

enum PageLayout {
    static let titleHeight: CGFloat = 40
    static let headerHeight: CGFloat = 60
    static let horizontalInset: CGFloat = 20
    static let topInset: CGFloat = 20
}

// MARK: - 尾部优先省略

/// 单行文本，**尾部优先省略**（保留结尾）。
///
/// 为什么需要：设备名有辨识度的部分在**结尾**（房号 `320洗手台`），
/// MAC 的厂商前缀是固定的、区别也在末尾。普通 `Text` 放不下时会折行，
/// 把卡片撑变形——Android 注释里专门写了这个坑（系统字体调大更明显）。
struct TailEllipsisText: View {
    let text: String
    var fontSize: CGFloat = 15
    var weight: Font.Weight = .regular
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            // 保留结尾、省略开头
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 图例点

/// 信号强度图例：`● 强`
struct LegendDot: View {
    let color: Color
    let label: String
    let textColor: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(textColor)
        }
    }
}

// MARK: - 设备图标

/// 设备图标块：彩色圆角底 + 图标
///
/// 花洒 / 牙刷用项目自己的矢量图标（`DeviceIcons`），其余（饮水机）仍画 emoji——
/// 和 Android 的 `DeviceGlyph` 完全一致：那张映射表只覆盖这两个，
/// 数据层继续用 emoji 字符串，老数据零迁移。
///
/// ⚠️ 图标固定用**白色**：它压在设备类型色的圆底上（洗手台橙、饮水机绿、其余蓝），
/// 单色图标跟底色同色就糊了。
struct DeviceGlyph: View {
    let emoji: String
    var boxSize: CGFloat = 48
    var cornerRadius: CGFloat = 14
    var emojiSize: CGFloat = 22
    var iconSize: CGFloat = 26
    let background: Color

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(background)
            .frame(width: boxSize, height: boxSize)
            .overlay {
                if let icon = DeviceIcons.icon(for: emoji) {
                    VectorIconView(icon: icon, size: iconSize, tint: .white)
                } else {
                    Text(emoji)
                        .font(.system(size: emojiSize))
                }
            }
    }

    /// 上次使用和常用设备按设备类型使用固定底色。
    static func background(for emoji: String, defaultColor: Color = Color(hex: 0x2563EB)) -> Color {
        switch emoji {
        case "🪥": return Color(hex: 0xFFCC80)
        case "❄️", "♨️", "🚰": return Color(hex: 0x10B981)
        default: return defaultColor
        }
    }
}

// MARK: - Toast

/// 与 Android 一致，使用当前主题的单行提示卡片。
struct LinYuToast: View {
    @Environment(\.appColors) private var colors
    let message: String

    private var displayMessage: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last == "。" || last == "." || last == "．",
              trimmed.dropLast().last != last else { return trimmed }
        return String(trimmed.dropLast())
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let text = displayMessage
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.head)
                .frame(minHeight: 23)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(colors.solidSurface, in: shape)
                .overlay(shape.strokeBorder(colors.border, lineWidth: 0.8))
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
                .padding(.horizontal, 24)
                .frame(maxWidth: 420, alignment: .center)
        }
    }
}


// MARK: - 按钮样式

/// 强调色实心按钮（圆角 16，对照 Android 的 `RoundedCornerShape(16.dp)`）
struct AccentButtonStyle: ButtonStyle {
    let colors: AppColorSet
    var radius: CGFloat = 16
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(colors.accent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 卡片按压反馈：轻微缩小到 0.97（对照 Android 的 DeviceCard）
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - 无底色图标

/// 只画图标 / emoji，**不带底色**。
///
/// 用水页那个 72pt 的大图标就是这种：它直接压在渐变背景上。
/// 首页卡片里的 `DeviceGlyph` 有彩色圆底（为了和卡片背景拉开层次），
/// 两者不能混用——用水页套个圆底会变成一个突兀的色块。
struct PlainGlyph: View {
    let emoji: String
    var size: CGFloat
    var tint: Color = .white

    var body: some View {
        if let icon = DeviceIcons.icon(for: emoji) {
            VectorIconView(icon: icon, size: size, tint: tint)
        } else {
            Text(emoji)
                .font(.system(size: size))
        }
    }
}

