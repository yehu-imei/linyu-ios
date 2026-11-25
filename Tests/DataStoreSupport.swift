import Foundation

enum ApiError: Error { case transport(String); case unauthorized(status: Int); case business(Int, String) }
final class Session {
    static let shared = Session()
    var isLoggedIn = true
    var requestGeneration = UUID()
    var projectId = "test-school"
    var accountId = "test-account"
    var loginCode = "test-only"
    var userId = "test-user"
}
enum Prefs {
    static var campusBalance = ""
    static var walletBalance = ""
    static var lastDeviceSnCode = ""
    static var lastDeviceMac = ""
    static var recordedConsume: [String: Double] = [:]
    static func recordConsume(_ snCode: String, amount: Double, atMs: Double = Date().timeIntervalSince1970 * 1000) {
        recordedConsume[snCode] = amount
    }
}
enum BalanceEstimator {
    static func billTimeMs(_ value: String) -> Double {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (formatter.date(from: value)?.timeIntervalSince1970 ?? 0) * 1000
    }
}
extension DeviceInfo { static func formatDeviceName(_ value: String) -> String { value } }
final class AppLog {
    static let shared = AppLog()
    func i(_ text: String) {}
    func i(_ text: String, _ detail: String?) {}
    func w(_ text: String) {}
    func w(_ text: String, _ detail: String?) {}
    func e(_ text: String) {}
    func e(_ text: String, _ detail: String?) {}
}
enum ApiClient {
    static var getResponses: [String: String] = [:]
    static var getPaths: [String] = []
    static var deviceQueries: [String] = []
    static var deviceResponses: [String: String] = [:]
    static var failBills = false
    static var emptyBills = false
    static var failingMonth: String?
    static var billQueries: [(project: String?, account: String?, type: String?)] = []
    static var billResponsesByProject: [String: String] = [:]
    static var delay: UInt64 = 0
    static var activeRequests = 0
    static var postPaths: [String] = []
    static var postResponse = "{\"success\":true,\"data\":null}"
    static var postResponses: [String: String] = [:]
    static var postProjects: [ProjectAuthContext?] = []
    static var failPost = false
    static var onPost: (() -> Void)?
    static var onGet: ((String) -> Void)?
    @MainActor static func get(
        _ path: String, query: [String: String] = [:], project: ProjectAuthContext? = nil, tag: String? = nil
    ) async throws -> Data {
        activeRequests += 1
        defer { activeRequests -= 1 }
        try Task.checkCancellation()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        getPaths.append(path)
        onGet?(path)
        if path == "/device/info/mac" {
            let address = query["macAddress"] ?? ""
            deviceQueries.append(address)
            if let response = deviceResponses[address] { return Data(response.utf8) }
        }
        if let response = getResponses[path] { return Data(response.utf8) }
        if path.contains("bill/list") {
            billQueries.append((project?.projectId, project?.accountId, query["billRequestType"]))
            if failBills { throw URLError(.notConnectedToInternet) }
            let month = query["month"] ?? ""
            if month == failingMonth { throw URLError(.notConnectedToInternet) }
            if let project, let response = billResponsesByProject[project.projectId] {
                return Data(response.utf8)
            }
            let data: String = emptyBills ? "[]" : """
                [{"consumeBillDTO":{"orderId":"\(month)","consumeDate":"\(month)-10 12:00:00","consumeMoney":"2.00"}}]
                """
            return Data("{\"success\":true,\"data\":\(data)}".utf8)
        }
        return Data("{\"success\":true,\"data\":null}".utf8)
    }
    static func post(_ path: String, form: [String: String], project: ProjectAuthContext? = nil,
                     tag: String? = nil) async throws -> Data {
        postPaths.append(path)
        postProjects.append(project)
        onPost?()
        if failPost { throw URLError(.notConnectedToInternet) }
        return Data((postResponses[path] ?? postResponse).utf8)
    }
    static func postJSON(_ path: String, body: [String: Any], tag: String? = nil) async throws -> Data {
        try await post(path, form: [:], tag: tag)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> APIResponse<T> {
        let response = try decodeShell(type, from: data, path: path)
        guard response.success else {
            throw ApiError.business(response.errorCode ?? -1, response.errorMessage ?? response.msg ?? "请求失败")
        }
        return response
    }
    static func decodeShell<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> APIResponse<T> {
        try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }
}
