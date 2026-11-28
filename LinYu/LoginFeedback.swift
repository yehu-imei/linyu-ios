import Foundation

enum LoginFeedback {
    static func isSessionExpiredMessage(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "登陆", with: "登录")
        if ["未登录", "请先登录", "请重新登录", "登录已失效", "登录失效", "登录已过期", "登录过期",
            "在别处登录", "在其他地方登录", "在其他设备登录", "在其它设备登录", "在另一台设备登录",
            "sign in again", "log in again", "login required", "not logged in"].contains(where: text.contains) {
            return true
        }
        if ["蓝牙会话", "设备会话", "device session", "bluetooth session"].contains(where: text.contains) {
            return false
        }
        let identifiesSession = ["登录状态", "登录会话", "登录凭证", "登录信息", "令牌", "会话", "token",
                                 "logincode", "session"].contains(where: text.contains)
        return identifiesSession && ["失效", "过期", "无效", "不存在", "认证失败", "校验失败", "invalid",
                                    "expired", "revoked"].contains(where: text.contains)
    }

    static func message(_ error: Error, fallback: String = "网络连接失败，请检查网络") -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "连接超时，请重试"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "网络连接失败，请检查网络"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "安全连接失败，请重试"
            case .cancelled: return "操作已取消"
            default: return "网络连接失败，请检查网络"
            }
        }
        let value = error.localizedDescription
        let lower = value.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") { return "连接超时，请重试" }
        if ["offline", "internet connection", "resolve host", "network is unreachable", "connect to", "connection was lost"].contains(where: lower.contains) {
            return "网络连接失败，请检查网络"
        }
        return chineseMessage(value, fallback: fallback)
    }

    static func smsSendMessage(_ error: Error) -> String {
        let fallback = "验证码发送失败，请重试"
        let reason = message(error, fallback: fallback)
        // 发码接口不携带登录凭证，不能用它的错误文案判断会话已失效。
        if isSessionExpiredMessage(reason) || reason == "请求失败" || reason == "请求失败，请稍后重试" {
            return fallback
        }
        return reason
    }

    /// 仅用于错误展示，不改变原始响应和业务判断；排除中英混合的异常详情。
    static func chineseMessage(_ value: String, fallback: String = "请求失败，请稍后重试") -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "1天只能领取一次使用码" { return "每天只能领取一次使用码" }
        let lower = text.lowercased()
        if ["timeout", "timed out"].contains(where: lower.contains) { return "连接超时，请重试" }
        if ["unable to resolve host", "no address associated", "network is unreachable",
            "offline", "internet connection", "failed to connect", "connection was lost"].contains(where: lower.contains) {
            return "网络连接失败，请检查网络"
        }
        let hasChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasLatin = text.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        return hasChinese && !hasLatin && text.count <= 120 && !text.contains("\n") && !text.contains("\r") ? text : fallback
    }
}
