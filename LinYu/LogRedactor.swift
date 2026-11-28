import Foundation

enum LogRedactor {
    private static let sensitiveKeys = [
        "loginCode", "password", "oldPassword", "useCode", "code", "smsCode",
        "signature", "token", "sign", "secret", "randomNumber", "random", "telephone", "telPhone",
        "newTelephone", "userId", "accountId", "name", "realName", "studentName",
        "idCardNumber", "studentNumber", "cardNumber", "Authorization",
    ].joined(separator: "|")

    static func mask(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?<!\d)(1[3-9]\d)\d{4}(\d{4})(?!\d)"#,
            with: "$1****$2", options: .regularExpression)
        let json = #"(?i)("(?:\#(sensitiveKeys))"\s*:\s*)(?:"(?:\\.|[^"\\])*(?:"|$)|[^,}\s\]]+)"#
        out = out.replacingOccurrences(of: json, with: "$1\"***\"", options: .regularExpression)
        let form = #"(?i)(?<![\p{L}\p{N}_])((?:\#(sensitiveKeys))=)[^&\r\n{}]+"#
        out = out.replacingOccurrences(of: form, with: "$1***", options: .regularExpression)
        return out
    }

    /// 旧日志的正文可能只剩半个 JSON 或包含无字段名的载荷。导出保留主记录，
    /// 跳过正文续行，并去掉曾直接放在主记录里的原始结算响应。
    static func exportLines(_ history: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let record = #"^\[(?:\d{2}-\d{2} )?\d{2}:\d{2}:\d{2}\.\d{3}\] \[[IWE]\] "#
        let legacyPayload = #"结算原始响应|收帧非法（CRC/格式）：|0x2[12] [^\r\n]*：(?:[0-9A-Fa-f]{2}(?: |$))"#
        return history.split(whereSeparator: \.isNewline).filter {
            $0.range(of: record, options: .regularExpression) != nil &&
                $0.range(of: legacyPayload, options: .regularExpression) == nil
        }.suffix(limit).map { mask(String($0)) }
    }
}
