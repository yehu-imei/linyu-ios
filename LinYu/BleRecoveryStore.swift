import Foundation

/// Android BleShowerController.Session 的恢复字段；不持久化凭证或费率包。
struct BleRecoveryRecord: Codable {
    let owner: String
    let snCode: String
    let orderNo: String
    let startedAt: Int64
    let protocolType: String
    let randomNumber: String
    let consumeDate: String
    var awaitingOpenConfirmation: Bool? = nil
    var projectId: String? = nil
    var accountId: String? = nil
    var authOwner: String? = nil

    func canConfirmOpen(project: ProjectAuthContext, serverOrderNo: String?) -> Bool {
        awaitingOpenConfirmation == true && projectId == project.projectId &&
            accountId == project.accountId && authOwner == project.owner &&
            !orderNo.isEmpty && serverOrderNo == orderNo
    }
}
enum BleRecoveryStore {
    static let key = "bleSessionJson"
    private static func all(_ defaults: UserDefaults) -> [BleRecoveryRecord] {
        decode(defaults.string(forKey: key))
    }
    private static func decode(_ text: String?) -> [BleRecoveryRecord] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([BleRecoveryRecord].self, from: data)) ?? []
    }
    static func read(owner: String, snCode: String, orderNo: String, startedAt: Int64,
                     defaults: UserDefaults = .standard) -> BleRecoveryRecord? {
        guard !owner.isEmpty, startedAt > 0 else { return nil }
        return all(defaults).first {
            $0.awaitingOpenConfirmation != true && $0.owner == owner && $0.snCode == snCode && $0.startedAt == startedAt &&
                ($0.orderNo == orderNo || $0.orderNo.isEmpty || orderNo.isEmpty)
        }
    }
    static func candidate(owner: String, authOwner: String, snCode: String,
                          defaults: UserDefaults = .standard) -> BleRecoveryRecord? {
        all(defaults).first {
            $0.owner == owner && $0.authOwner == authOwner && $0.snCode == snCode &&
                $0.awaitingOpenConfirmation == true
        }
    }
    static func archiveUnconfirmed(owner: String, authOwner: String, defaults: UserDefaults) -> String? {
        let pending = all(defaults).filter {
            $0.awaitingOpenConfirmation == true && $0.owner == owner && $0.authOwner == authOwner
        }
        return pending.isEmpty ? nil : encode(pending)
    }
    static func excludeUnconfirmed(from text: String?) -> String? {
        let confirmed = decode(text).filter { $0.awaitingOpenConfirmation != true }
        return confirmed.isEmpty ? nil : encode(confirmed)
    }
    static func restoreUnconfirmed(_ archived: String?, owner: String, authOwner: String,
                                   defaults: UserDefaults) {
        let current = all(defaults)
        let pending = decode(archived).filter { record in
            record.awaitingOpenConfirmation == true && record.owner == owner && record.authOwner == authOwner &&
                !current.contains { $0.owner == owner && $0.snCode == record.snCode }
        }
        if !pending.isEmpty { write(current + pending, defaults) }
    }
    static func save(_ value: BleRecoveryRecord, defaults: UserDefaults = .standard) {
        var values = all(defaults).filter { $0.owner == value.owner && $0.snCode != value.snCode }
        values.append(value)
        write(values, defaults)
    }
    static func remove(snCode: String, defaults: UserDefaults = .standard) {
        write(all(defaults).filter { $0.snCode != snCode }, defaults)
    }
    private static func write(_ values: [BleRecoveryRecord], _ defaults: UserDefaults) {
        guard let text = encode(values) else { return }
        defaults.set(text, forKey: key)
    }
    private static func encode(_ values: [BleRecoveryRecord]) -> String? {
        guard let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
