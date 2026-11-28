import Foundation

enum NotificationKind: String {
    case inUse, finished, autoClosed, closeProblem, openFailed, occupied
    var destination: Int { self == .finished || self == .autoClosed ? 1 : 0 }
}

enum NotificationPolicy {
    static func removeLegacyPreferences(defaults: UserDefaults = .standard) {
        for key in ["notifyInUse", "notifyFinished", "notifyAutoClose", "notifyAlert"] {
            defaults.removeObject(forKey: key)
        }
    }
}
