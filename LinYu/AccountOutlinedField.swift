import SwiftUI

struct AccountOutlinedField: View {
    static let outlineHeight: CGFloat = 56

    @Environment(\.appColors) private var colors
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var localFocus: Bool

    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var secured = false
    var leadingIcon: String?
    var showsClear = false
    var focus: FocusState<Bool>.Binding? = nil

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $localFocus }
    private var focused: Bool { focusBinding.wrappedValue }
    private var floats: Bool { focused || !text.isEmpty }
    private var corner: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    private var prompt: Text {
        Text(floats ? "" : title).foregroundColor(colors.textSecondary)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(colors.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            Group {
                if secured {
                    SecureField(title, text: $text, prompt: prompt)
                } else {
                    TextField(title, text: $text, prompt: prompt)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(colors.textPrimary)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused(focusBinding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if showsClear, !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("清空\(title)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.outlineHeight)
        .overlay {
            corner
                .strokeBorder(focused ? colors.accent : colors.textSecondary.opacity(0.55),
                              lineWidth: focused ? 2 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if floats {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(focused ? colors.accent : colors.textSecondary)
                    .padding(.horizontal, 4)
                    .background(colors.solidSurface)
                    .offset(x: 10, y: -7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if isEnabled, !focused { focusBinding.wrappedValue = true }
        })
        .padding(.top, 8)
    }
}
