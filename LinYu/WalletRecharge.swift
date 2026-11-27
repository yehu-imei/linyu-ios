import Foundation

struct WalletRechargeInfo {
    enum AppPay: Equatable {
        case supported
        case unsupported
        case unknown
    }

    struct Denomination {
        let id: Int64
        let amount: String
        let gift: String?
    }

    let appPay: AppPay
    let message: String?
    let denominations: [Denomination]

    init(mode: WalletRechargeMode?, packages: [WalletRechargePackage]?) {
        appPay = mode?.appPay ?? .unknown
        message = appPay == .unsupported ? mode?.noSaveMessage : nil
        var seen: Set<Int64> = []
        denominations = (packages ?? []).compactMap(\.denomination).filter { seen.insert($0.id).inserted }
    }
}

struct WalletRechargeMode: Decodable {
    private let payWay: [RechargeDecimal]?
    let noSaveMessage: String?

    private enum CodingKeys: String, CodingKey { case payWay, noSaveMessage }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        payWay = try? values.decode([RechargeDecimal].self, forKey: .payWay)
        noSaveMessage = try? values.decode(String.self, forKey: .noSaveMessage)
    }

    var appPay: WalletRechargeInfo.AppPay {
        guard let payWay else { return .unknown }
        let codes = payWay.compactMap(\.wholeNumber)
        guard codes.count == payWay.count, codes.allSatisfy({ $0 >= 0 }) else { return .unknown }
        return codes.contains(2) ? .supported : .unsupported
    }
}

struct WalletRechargePackage: Decodable {
    private let typeId: RechargeDecimal?
    private let amount: RechargeDecimal?
    private let givenMoney: RechargeDecimal?

    private enum CodingKeys: String, CodingKey { case typeId, amount, givenMoney }

    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        typeId = try? values?.decode(RechargeDecimal.self, forKey: .typeId)
        amount = try? values?.decode(RechargeDecimal.self, forKey: .amount)
        givenMoney = try? values?.decode(RechargeDecimal.self, forKey: .givenMoney)
    }

    var denomination: WalletRechargeInfo.Denomination? {
        guard let id = typeId?.wholeNumber, id >= 0, let amount = amount?.displayed else { return nil }
        return .init(id: id, amount: amount, gift: givenMoney?.displayed)
    }
}

private struct RechargeDecimal: Decodable {
    let value: Decimal?

    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if let text = try? values.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.count <= 32 && trimmed.range(of: #"^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
                ? Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) : nil
        } else {
            value = try? values.decode(Decimal.self)
        }
    }

    var wholeNumber: Int64? {
        guard let value, !value.isNaN, value >= Decimal(Int64.min), value <= Decimal(Int64.max) else { return nil }
        let integer = NSDecimalNumber(decimal: value).int64Value
        return Decimal(integer) == value ? integer : nil
    }

    var displayed: String? {
        guard let value, !value.isNaN, value > .zero, value <= 10_000 else { return nil }
        var original = value
        var centsPrecision = Decimal.zero
        NSDecimalRound(&centsPrecision, &original, 2, .plain)
        guard centsPrecision == value else { return nil }
        return MoneyFormat.format(NSDecimalNumber(decimal: value).doubleValue)
    }
}

enum WalletRechargeService {
    static func load(generation: UUID) async -> WalletRechargeInfo? {
        await SessionWork.$generation.withValue(generation) {
            guard SessionWork.isCurrent(generation) else { return nil }
            let mode = await fetch(WalletRechargeMode.self, path: "/settlement/recharge/pay/mode")
            guard SessionWork.isCurrent(generation) else { return nil }
            let packages = mode?.appPay == .supported
                ? await fetch([WalletRechargePackage].self, path: "/settlement/recharge/package/list") : nil
            guard SessionWork.isCurrent(generation) else { return nil }
            return WalletRechargeInfo(mode: mode, packages: packages)
        }
    }

    private static func fetch<T: Decodable>(_ type: T.Type, path: String) async -> T? {
        guard let bytes = try? await ApiClient.get(path),
              let response = try? ApiClient.decodeShell(type, from: bytes, path: path),
              response.success, response.errorCode == 0 else { return nil }
        return response.data
    }
}
