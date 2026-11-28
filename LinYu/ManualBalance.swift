import Foundation

struct ManualBalance {
    let amount: Double
    let enteredAt: Double

    static func read(owner: String, defaults: UserDefaults = .standard) -> ManualBalance? {
        guard let key = key(owner), let raw = defaults.dictionary(forKey: key),
              let amount = raw["amount"] as? Double, amount.isFinite,
              let enteredAt = raw["enteredAt"] as? Double, enteredAt.isFinite, enteredAt > 0 else { return nil }
        return ManualBalance(amount: amount, enteredAt: enteredAt)
    }

    static func save(_ value: String, enteredAt: Double, owner: String, defaults: UserDefaults = .standard) -> Bool {
        guard let key = key(owner) else { return false }
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            guard let amount = Double(input), amount.isFinite, enteredAt.isFinite, enteredAt > 0 else { return false }
            defaults.set(["amount": amount, "enteredAt": enteredAt], forKey: key)
        }
        defaults.removeObject(forKey: "manualBalance")
        defaults.removeObject(forKey: "manualBalanceTime")
        return true
    }

    private static func key(_ owner: String) -> String? {
        let parts = owner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0 != "0" }) else { return nil }
        return "manualBalance.v2.\(owner)"
    }
}
