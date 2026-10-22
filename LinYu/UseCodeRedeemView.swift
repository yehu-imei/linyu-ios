import SwiftUI

private struct GeneratedUseCode: Decodable {
    let useCode: String?
    let remainTimes: Int?
}

struct UseCodeRedeemView: View {
    @EnvironmentObject private var store: AppDataStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidate = ""
    @State private var expires = Date.distantPast
    @State private var remainTimes: Int?
    @State private var busy = false
    @State private var errorText: String?
    @State private var checking = true
    @State private var eligibilityLoaded = false
    @State private var retryToken = 0
    private var unavailable: Bool { store.useCode?.resetAvailability == 0 }

    var body: some View {
        NavigationStack {
            Form {
                if checking {
                    ProgressView("加载中...")
                } else if !eligibilityLoaded {
                    Text("获取失败，请重试")
                    Button("重试") { retryToken += 1 }
                } else if unavailable {
                    Text(store.useCode?.resetAvailabilityWarMark ?? "1天只能领取一次使用码")
                    Button("知道了") { dismiss() }
                } else {
                    if let current = store.useCode?.useCode { LabeledContent("当前使用码", value: current) }
                    LabeledContent("领取后替换为", value: candidate.isEmpty ? "—" : candidate)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(expires.timeIntervalSince(context.date)))
                        if !candidate.isEmpty {
                            Text(seconds == 0 ? "已超时，请重新换一个" : String(format: "请在 %d:%02d 内领取", seconds / 60, seconds % 60))
                        }
                        Button(busy ? "领取中…" : "确定领取") { Task { await redeem() } }
                            .disabled(busy || candidate.isEmpty || seconds == 0)
                    }
                    if let remainTimes { Text("今日还能换 \(remainTimes) 次") }
                    Button(busy ? "换码中" : (candidate.isEmpty ? "获取" : "换一个")) {
                        Task { await generate() }
                    }.disabled(busy || remainTimes == 0)
                    if let errorText { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle(eligibilityLoaded && unavailable ? "无法领取" : (store.useCode?.useCode?.isEmpty == false ? "重新领取使用码" : "领取使用码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
        }
        .interactiveDismissDisabled(busy)
        .task(id: retryToken) { await prepare() }
    }

    private func prepare() async {
        checking = true
        eligibilityLoaded = await store.loadUseCode(force: true)
        checking = false
        guard eligibilityLoaded, !unavailable, !Task.isCancelled else { return }
        await generate()
    }

    private func generate() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let raw = try await ApiClient.post("/account/useCode/new/generate", form: [:], tag: "generateUseCode")
            let result = try ApiClient.decode(GeneratedUseCode.self, from: raw, path: "generateUseCode")
            guard let code = result.data?.useCode, !code.isEmpty else {
                errorText = "获取失败，请重试"; return
            }
            candidate = code
            remainTimes = result.data?.remainTimes
            expires = Date().addingTimeInterval(180)
        } catch { errorText = error.localizedDescription }
    }

    private func redeem() async {
        guard !busy, !candidate.isEmpty, expires > Date() else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let raw = try await ApiClient.post("/account/useCode/new/set", form: ["useCode": candidate], tag: "setUseCode")
            _ = try ApiClient.decode(EmptyData.self, from: raw, path: "setUseCode")
            store.acceptUseCode(candidate)
            await store.loadUseCode(force: true)
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}
