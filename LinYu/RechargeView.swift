import SwiftUI

@MainActor
struct RechargeView: View {
    let onBack: () -> Void

    @Environment(\.appColors) private var colors
    @Environment(\.openURL) private var openURL
    @AppStorage("walletBalance") private var walletBalance = ""
    @State private var generation = Session.shared.requestGeneration
    @State private var info: WalletRechargeInfo?
    @State private var lookupAttempt = 0
    @State private var balanceRefresh: UUID?
    @State private var balanceError: String?
    @State private var openingOfficial = false
    @State private var openError: String?
    @State private var isVisible = false

    var body: some View {
        ZStack {
            colors.solidSurface.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    balanceCard
                    paymentOptions
                    officialEntry
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: lookupAttempt) {
            let expectedGeneration = generation
            info = nil
            let loaded = await WalletRechargeService.load(generation: expectedGeneration)
            guard SessionWork.isCurrent(expectedGeneration) else { return }
            info = loaded
        }
        .task(id: balanceRefresh) {
            guard balanceRefresh != nil else { return }
            await refreshBalance()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(InstantButtonStyle())
            .accessibilityLabel("返回")

            Text("账户充值")
                .font(.title3.bold())
                .foregroundStyle(colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("趣智校园余额")
                        .font(.subheadline)
                        .foregroundStyle(colors.textSecondary)
                    Text(MoneyFormat.withSymbol(Double(walletBalance)))
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(colors.textPrimary)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                Button {
                    balanceError = nil
                    balanceRefresh = UUID()
                } label: {
                    if balanceRefresh != nil {
                        ProgressView()
                            .tint(colors.accent)
                            .frame(minWidth: 60, minHeight: 44)
                            .accessibilityLabel("正在刷新余额")
                    } else {
                        Text("刷新余额")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colors.accent)
                            .frame(minHeight: 44)
                    }
                }
                .buttonStyle(InstantButtonStyle())
                .disabled(balanceRefresh != nil)
            }
            if let balanceError {
                Text(balanceError)
                    .font(.footnote)
                    .foregroundStyle(colors.danger)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .linyuCard(colors)
    }

    private var paymentOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("充值方式")
                .font(.headline)
                .foregroundStyle(colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            if let info {
                paymentStatus(info)
                if !info.denominations.isEmpty {
                    denominations(info.denominations)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(colors.accent)
                    Text("正在查询充值方式…")
                }
                .font(.subheadline)
                .foregroundStyle(colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func paymentStatus(_ info: WalletRechargeInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch info.appPay {
            case .supported:
                Text("当前项目支持支付宝 App 支付，请前往官方渠道充值")
                if info.denominations.isEmpty {
                    retryRow("暂未获取官方充值档位")
                }
            case .unsupported:
                Text("当前项目暂不支持支付宝 App 支付")
                if let message = info.message {
                    let display = LoginFeedback.chineseMessage(String(message.prefix(160)), fallback: "")
                    if !display.isEmpty { Text(display) }
                }
            case .unknown:
                retryRow("暂未获取充值方式")
            }
        }
        .font(.subheadline)
        .foregroundStyle(colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .linyuCard(colors, radius: 16)
    }

    private func retryRow(_ message: String) -> some View {
        HStack {
            Text(message)
            Spacer(minLength: 8)
            Button("重试") {
                info = nil
                lookupAttempt += 1
            }
            .foregroundStyle(colors.accent)
            .buttonStyle(InstantButtonStyle())
        }
    }

    private func denominations(_ items: [WalletRechargeInfo.Denomination]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("官方充值档位")
                .font(.headline)
                .foregroundStyle(colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                ForEach(items, id: \.id) { item in
                    VStack(spacing: 4) {
                        Text("¥\(item.amount)")
                            .font(.title3.bold())
                            .foregroundStyle(colors.textPrimary)
                            .monospacedDigit()
                        if let gift = item.gift {
                            Text("赠 ¥\(gift)")
                                .font(.footnote)
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .padding(.horizontal, 6)
                    .linyuCard(colors, radius: 16)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var officialEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: openOfficial) {
                HStack(spacing: 8) {
                    if openingOfficial {
                        ProgressView().tint(colors.onAccent)
                    } else {
                        Image(systemName: "arrow.up.right.square")
                            .accessibilityHidden(true)
                    }
                    Text("打开支付宝官方小程序")
                }
                .font(.headline)
                .foregroundStyle(colors.onAccent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 12)
                .background(colors.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(InstantButtonStyle())
            .disabled(openingOfficial)

            Text("在官方小程序选择金额，充值方式和档位以官方页面为准")
                .font(.footnote)
                .foregroundStyle(colors.textSecondary)
            if let openError {
                Text(openError)
                    .font(.footnote)
                    .foregroundStyle(colors.danger)
            }
        }
    }

    private func refreshBalance() async {
        let expectedGeneration = generation
        guard SessionWork.isCurrent(expectedGeneration) else { return }
        let wallet = await SessionWork.$generation.withValue(expectedGeneration) {
            await BillService.loadWallet()
        }
        guard SessionWork.isCurrent(expectedGeneration) else { return }
        balanceRefresh = nil
        guard let balance = wallet?.moneyYuan, balance.isFinite else {
            balanceError = "未能刷新余额，请重试"
            return
        }
        walletBalance = String(balance)
    }

    private func openOfficial() {
        let expectedGeneration = generation
        guard SessionWork.isCurrent(expectedGeneration), !openingOfficial,
              let url = URL(string: "alipays://platformapi/startapp?appId=2018090661238647&page=pages%2Frecharge%2Frecharge") else { return }
        openingOfficial = true
        openError = nil
        openURL(url) { accepted in
            Task { @MainActor in
                guard isVisible, SessionWork.isCurrent(expectedGeneration) else { return }
                openingOfficial = false
                if !accepted { openError = "无法打开小程序，请在支付宝搜索「趣智校园」" }
            }
        }
    }
}
