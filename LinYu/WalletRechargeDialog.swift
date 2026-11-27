import SwiftUI

struct WalletRechargeDialog: View {
    @Environment(\.appColors) private var colors
    let generation: UUID
    let onOpenOfficial: () -> Void
    let onDismiss: () -> Void

    @State private var info: WalletRechargeInfo?
    @State private var attempt = 0

    var body: some View {
        DialogScrim(onTapOutside: onDismiss) {
            AlertCard(title: "支付宝充值", titleAlign: .leading, contentSpacing: 12, actionSpacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    if let info {
                        paymentStatus(info)
                        if !info.denominations.isEmpty {
                            Text("官方充值档位")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(colors.textPrimary)
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(info.denominations, id: \.id) { item in
                                        HStack {
                                            Text("¥\(item.amount)")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(colors.textPrimary)
                                            Spacer()
                                            if let gift = item.gift {
                                                Text("赠 ¥\(gift)")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(colors.textSecondary)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 32)
                                        .background(colors.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .frame(height: min(CGFloat(info.denominations.count) * 36 - 4, 140))
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().tint(colors.accent)
                            Text("正在查询充值方式…")
                                .font(.system(size: 14))
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                    Text("小程序能否充值，以官方页面为准")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } actions: {
                DialogTextButton(title: "关闭", color: colors.textSecondary, action: onDismiss)
                DialogFilledButton(title: "打开官方小程序", color: colors.accent, action: onOpenOfficial)
            }
        }
        .task(id: attempt) {
            info = nil
            if let loaded = await WalletRechargeService.load(generation: generation) {
                guard SessionWork.isCurrent(generation) else { return }
                info = loaded
            }
        }
    }

    @ViewBuilder
    private func paymentStatus(_ info: WalletRechargeInfo) -> some View {
        Group {
            switch info.appPay {
            case .supported:
                Text("当前项目支持支付宝 App 支付，请通过官方渠道充值")
            case .unsupported:
                Text("当前项目暂不支持支付宝 App 支付")
                if let message = info.message {
                    let display = LoginFeedback.chineseMessage(String(message.prefix(160)), fallback: "")
                    if !display.isEmpty { Text(display).lineLimit(3) }
                }
            case .unknown:
                HStack {
                    Text("暂未获取充值方式")
                    Spacer()
                    Button("重试") { attempt += 1 }
                        .foregroundStyle(colors.accent)
                        .buttonStyle(InstantButtonStyle())
                }
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(colors.textSecondary)
    }
}
