import SwiftUI

private struct AccountFormHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AccountFormScroll: ViewModifier {
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: AccountFormHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        // 测量只限制表单内容的最大高度。卡片、标题和按钮在首帧就可见。
        .frame(maxHeight: contentHeight)
        .onPreferenceChange(AccountFormHeightKey.self) { height in
            if height > 0 { contentHeight = height }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - 修改密码

/// 修改密码 —— 对照 Android `UserScreen.ChangePasswordDialog`。
///
/// 两条路（Android 注释原话）：
/// - **知道当前密码**：`/user/password/update`，要 `oldPassword`
/// - **不知道 / 从没设过**：`/user/password/forget`，只用手机验证码，**不要旧密码**
///
/// 第二条不能省：短信验证码注册的账号根本没有密码可填，
/// 少了它「修改密码」对这些人就是个死按钮。
struct ChangePasswordDialog: View {
    @Environment(\.appColors) private var colors
    let currentPhone: String
    let onDismiss: () -> Void
    var onSuccess: () -> Void = {}

    /// false = 知道当前密码；true = 走短信验证码
    @State private var smsMode = false
    @State private var oldPwd = ""
    @State private var newPwd = ""
    @State private var confirmPwd = ""
    @State private var code = ""
    @State private var codeDelivered = false
    @State private var generation = Session.shared.requestGeneration
    @State private var codeRequest: Task<Void, Never>?
    @State private var sending = false
    @State private var countdown = 0
    @State private var submitting = false
    @State private var errorText: String?

    init(currentPhone: String, onSuccess: @escaping () -> Void = {}, onDismiss: @escaping () -> Void) {
        self.currentPhone = currentPhone
        self.onSuccess = onSuccess
        self.onDismiss = onDismiss
    }

    private var canSubmit: Bool {
        if smsMode {
            return codeDelivered && !code.isEmpty && !newPwd.isEmpty && !confirmPwd.isEmpty
        }
        return !oldPwd.isEmpty && !newPwd.isEmpty && !confirmPwd.isEmpty
    }

    var body: some View {
        DialogScrim(onTapOutside: { if !submitting { onDismiss() } }) {
            AlertCard(title: "修改密码", titleAlign: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    if smsMode {
                        AccountOutlinedField(title: "已绑定手机号", text: .constant(currentPhone),
                                             keyboard: .numberPad)
                            .disabled(true)

                        HStack(alignment: .bottom, spacing: 10) {
                            AccountOutlinedField(title: "验证码", text: $code,
                                                 keyboard: .numberPad, contentType: .oneTimeCode)
                            Button {
                                codeRequest = Task { await sendCode() }
                            } label: {
                                Text(countdown > 0 ? "\(countdown)s" : "发送")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(width: 86, height: AccountOutlinedField.outlineHeight)
                                    .background(canSendCode ? colors.accent : colors.accent.opacity(0.45))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(InstantButtonStyle())
                            .disabled(!canSendCode)
                        }
                    } else {
                        AccountOutlinedField(title: "当前密码", text: $oldPwd,
                                             contentType: .password, secured: true)
                    }

                    AccountOutlinedField(title: "新密码", text: $newPwd,
                                         contentType: .newPassword, secured: true)
                    AccountOutlinedField(title: "确认新密码", text: $confirmPwd,
                                         contentType: .newPassword, secured: true)

                    Button {
                        smsMode.toggle()
                        errorText = nil
                    } label: {
                        Text(smsMode ? "直接修改密码" : "短信验证修改密码")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.accent)
                    }
                    .buttonStyle(InstantButtonStyle())
                    .disabled(submitting)

                    if newPwd != confirmPwd, !confirmPwd.isEmpty {
                        Text("两次输入的新密码不一致")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.danger)
                    }

                    if let e = errorText {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.danger)
                    }
                }
                .modifier(AccountFormScroll())
                .disabled(submitting)
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent) {
                    if !submitting { onDismiss() }
                }
                DialogTextButton(
                    title: submitting ? "提交中…" : "确定",
                    color: colors.accent
                ) {
                    Task { await submit() }
                }
                .disabled(!canSubmit || submitting)
            }
        }
        .interactiveDismissDisabled(submitting)
        .onDisappear { codeRequest?.cancel() }
    }

    private var canSendCode: Bool { !sending && countdown == 0 && currentPhone.count == 11 }

    private func sendCode() async {
        guard canSendCode, SessionWork.isCurrent(generation), Session.shared.telephone == currentPhone else { return }
        sending = true
        errorText = nil
        codeDelivered = false
        code = ""
        defer { sending = false }
        do {
            try await SessionWork.$generation.withValue(generation) {
                try await AuthService.sendSmsCode(phone: currentPhone, typeId: 2)
            }
            guard SessionWork.isCurrent(generation), Session.shared.telephone == currentPhone else { return }
            codeDelivered = true
            countdown = 60
            while countdown > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        } catch {
            guard SessionWork.isCurrent(generation) else { return }
            errorText = LoginFeedback.message(error)
        }
    }

    private func submit() async {
        guard canSubmit, !submitting, SessionWork.isCurrent(generation),
              Session.shared.telephone == currentPhone else { return }
        guard newPwd == confirmPwd else { errorText = "两次输入的新密码不一致"; return }
        submitting = true
        errorText = nil
        defer { submitting = false }
        do {
            // 密码用和登录同一套加密：MD5 取后 10 位大写
            let enc = AuthService.encryptPassword(newPwd)
            let path = smsMode ? "/user/password/forget" : "/user/password/update"
            let form = smsMode
                ? ["password": enc, "code": code]
                : ["oldPassword": AuthService.encryptPassword(oldPwd), "password": enc]
            let tag = smsMode ? "forgetPassword" : "updatePassword"
            let raw = try await SessionWork.$generation.withValue(generation) {
                try await ApiClient.post(path, form: form, tag: tag)
            }
            guard SessionWork.isCurrent(generation) else { return }
            _ = try ApiClient.decode(EmptyData.self, from: raw, path: "changePassword")
            SavedCredential.clear(for: currentPhone)
            onSuccess()
            onDismiss()
        } catch {
            guard SessionWork.isCurrent(generation) else { return }
            errorText = LoginFeedback.message(error)
        }
    }
}

// MARK: - 更换手机号

/// 更换手机号 —— 对照 Android `UserScreen.ChangePhoneDialog`。
struct ChangePhoneDialog: View {
    @Environment(\.appColors) private var colors
    let currentPhone: String
    let onDismiss: () -> Void
    var onSuccess: () -> Void = {}

    @State private var newPhone = ""
    @State private var code = ""
    @State private var codeRecipient: String?
    @State private var generation = Session.shared.requestGeneration
    @State private var codeRequest: Task<Void, Never>?
    @State private var sending = false
    @State private var countdown = 0
    @State private var submitting = false
    @State private var errorText: String?

    private var canSubmit: Bool {
        newPhone.count == 11 && codeRecipient == newPhone && !code.isEmpty && !submitting
    }

    var body: some View {
        DialogScrim(onTapOutside: { if !submitting { onDismiss() } }) {
            AlertCard(title: "更换手机号", titleAlign: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    // ⚠️ 验证码发到**新**手机号（typeId = 5），不是当前绑定的那个。
                    // 抓包实测：`telephone=新号&typeId=5`，旧号只作为认证参数出现。
                    // 发到旧号用户根本收不到，会一直提示验证码错误。
                    Text("当前手机号：\(currentPhone)")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)

                    AccountOutlinedField(title: "新手机号",
                                         text: Binding(get: { newPhone }, set: updateNewPhone),
                                         keyboard: .numberPad, contentType: .telephoneNumber)

                    HStack(alignment: .bottom, spacing: 10) {
                        AccountOutlinedField(title: "验证码", text: $code,
                                             keyboard: .numberPad, contentType: .oneTimeCode)
                        Button {
                            codeRequest = Task { await sendCode() }
                        } label: {
                            Text(countdown > 0 ? "\(countdown)s" : "发送")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(width: 86, height: AccountOutlinedField.outlineHeight)
                                .background(canSend ? colors.accent : colors.accent.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(InstantButtonStyle())
                        .disabled(!canSend)
                    }

                    if let e = errorText {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.danger)
                    }
                }
                .modifier(AccountFormScroll())
                .disabled(submitting)
            } actions: {
                DialogTextButton(title: "取消", color: colors.accent) {
                    if !submitting { onDismiss() }
                }
                DialogTextButton(
                    title: submitting ? "提交中…" : "确定",
                    color: colors.accent
                ) {
                    Task { await submit() }
                }
                .disabled(!canSubmit)
            }
        }
        .interactiveDismissDisabled(submitting)
        .onDisappear { codeRequest?.cancel() }
    }

    private var canSend: Bool { !sending && countdown == 0 && newPhone.count == 11 }

    private func updateNewPhone(_ value: String) {
        guard newPhone != value else { return }
        newPhone = value
        code = ""
        codeRecipient = nil
        errorText = nil
    }

    private func sendCode() async {
        guard canSend, SessionWork.isCurrent(generation) else { return }
        let recipient = newPhone
        sending = true
        errorText = nil
        code = ""
        codeRecipient = nil
        defer { sending = false }
        do {
            try await SessionWork.$generation.withValue(generation) {
                try await AuthService.sendSmsCode(phone: recipient, typeId: 5)
            }
            guard SessionWork.isCurrent(generation) else { return }
            if newPhone == recipient { codeRecipient = recipient }
            countdown = 60
            while countdown > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        } catch {
            guard SessionWork.isCurrent(generation), newPhone == recipient else { return }
            errorText = LoginFeedback.message(error)
        }
    }

    private func submit() async {
        guard canSubmit, SessionWork.isCurrent(generation),
              Session.shared.telephone == currentPhone else { return }
        let recipient = newPhone
        let previousPhone = Session.shared.telephone
        submitting = true
        errorText = nil
        defer { submitting = false }
        do {
            let form = ["newTelephone": recipient, "code": code]
            let raw = try await SessionWork.$generation.withValue(generation) {
                try await ApiClient.post("/user/phone/update", form: form, tag: "updatePhone")
            }
            guard SessionWork.isCurrent(generation) else { return }
            _ = try ApiClient.decode(EmptyData.self, from: raw, path: "updatePhone")
            SavedCredential.clear(for: previousPhone)
            // 认证参数里的 telephone 也得跟着换，否则后续请求还在用旧号
            Session.shared.updateTelephone(recipient)
            onSuccess()
            onDismiss()
        } catch {
            guard SessionWork.isCurrent(generation) else { return }
            errorText = LoginFeedback.message(error)
        }
    }
}
