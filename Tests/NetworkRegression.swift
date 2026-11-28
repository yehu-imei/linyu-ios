import Foundation
extension DeviceInfo { static func formatDeviceName(_ value: String) -> String { value } }

// 独立编译生产 ApiClient；URLProtocol 拦截全部请求，禁止访问真实账号和水控服务。
final class Session {
    static let shared = Session()
    var requestGeneration = UUID()
    var isLoggedIn = true
    var projectId = "test-school"
    var kickReasons: [String] = []
    var authFields: [String: String] {
        ["loginCode": "test-only", "userId": "test-user", "projectId": projectId, "accountId": "test-account"]
    }
    var authQuery: [String: String] { authFields }
    func save(loginCode: String, userId: String, accountId: String, projectId: String,
              telephone: String, displayName: String?) {}
    @MainActor func kickOut(reason: String?) {
        kickReasons.append(reason ?? "")
        requestGeneration = UUID()
        isLoggedIn = false
    }
}
final class AppLog {
    static let shared = AppLog()
    var lastError = ""
    func i(_ text: String, _ detail: String? = nil) {}
    func w(_ text: String) {}
    func e(_ text: String, _ detail: String? = nil) { lastError = text + (detail ?? "") }
}
final class MockProtocol: URLProtocol {
    static var status = 200
    static var rotateSession = false
    static var failNetwork = false
    static var requests = 0
    static var lastRequest: URLRequest?
    static var lastForm = ""
    static var responseBody = #"{"success":true,"data":null}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastRequest = request
        Self.lastForm = ""
        if let body = request.httpBody {
            Self.lastForm = String(decoding: body, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            Self.lastForm = String(decoding: body, as: UTF8.self)
        }
        if Self.rotateSession { Session.shared.requestGeneration = UUID() }
        if Self.failNetwork {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct NetworkRegression {
    static func main() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        ApiClient.session = URLSession(configuration: config)
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        let methods: [(String, () async throws -> Data)] = [
            ("GET", { try await ApiClient.get("/mock") }),
            ("POST", { try await ApiClient.post("/mock", form: [:]) }),
            ("JSON", { try await ApiClient.postJSON("/mock", body: ["loginCode": "test-only"]) })
        ]
        // 直接测试生产解析器：业务失败必须中断领取，但水控错误码仍可分支处理。
        let rejected = Data(#"{"success":false,"errorCode":307,"errorMessage":"设备正在使用","data":null}"#.utf8)
        do {
            _ = try ApiClient.decode(DeviceInfo.self, from: rejected, path: "regression")
            check(false, "严格解析必须拒绝业务失败")
        } catch ApiError.business(let code, let message) {
            check(code == 307 && message == "设备正在使用", "严格解析保留业务错误码和原文")
        } catch { check(false, "严格解析业务错误类型") }
        do {
            let shell = try ApiClient.decodeShell(DeviceInfo.self, from: rejected, path: "regression")
            check(!shell.success && shell.errorCode == 307, "水控外壳解析不吞掉307分支")
        } catch { check(false, "外壳解析不应因业务失败抛错") }
        do {
            let invalid = Data(#"{"success":"wrong type","data":{"name":"SyntheticPrivateName"}}"#.utf8)
            _ = try ApiClient.decodeShell(AccountInfo.self, from: invalid, path: "accountInfo")
            check(false, "无效个人信息响应应被拒绝")
        } catch {
            check(AppLog.shared.lastError.contains("解析失败 accountInfo") &&
                  !AppLog.shared.lastError.contains("SyntheticPrivateName"), "响应解析失败日志不写原始正文")
        }
        for (name, request) in methods {
            for status in [401, 403] {
                Session.shared.isLoggedIn = true
                let prior = Session.shared.kickReasons.count
                MockProtocol.status = status
                do { _ = try await request(); check(false, "\(name) \(status)") }
                catch ApiError.unauthorized(let actual) { check(actual == status, "\(name)保留HTTP \(status)类型") }
                catch { check(false, "\(name)错误被包装: \(error)") }
                check(Session.shared.kickReasons.count == prior + 1, "\(name)有效主会话收到HTTP \(status)立即退出")
            }
            Session.shared.isLoggedIn = true
            let prior = Session.shared.kickReasons.count
            MockProtocol.status = 500
            do { _ = try await request(); check(false, "\(name)HTTP500") }
            catch ApiError.http(let status) { check(status == 500, "\(name)不把HTTP500成功JSON当业务成功") }
            catch { check(false, "\(name)HTTP500类型") }
            MockProtocol.status = 200
            MockProtocol.rotateSession = true
            do { _ = try await request(); check(false, "\(name)过期响应") }
            catch is CancellationError { check(true, "\(name)拒绝旧会话成功响应") }
            catch { check(false, "\(name)过期错误类型") }
            MockProtocol.failNetwork = true
            do { _ = try await request(); check(false, "\(name)过期网络错误") }
            catch is CancellationError { check(true, "\(name)旧会话网络错误也按取消处理") }
            catch { check(false, "\(name)过期网络错误类型") }
            MockProtocol.rotateSession = false
            do { _ = try await request(); check(false, "\(name)断网") }
            catch ApiError.transport(let message) { check(message == "网络连接失败，请检查网络", "\(name)断网不当作登录失效且提示简短中文") }
            catch { check(false, "\(name)断网错误类型") }
            MockProtocol.failNetwork = false
            check(Session.shared.kickReasons.count == prior, "\(name)网络、HTTP 500 与旧响应不结束会话")
        }
        MockProtocol.responseBody = #"{"success":false,"msg":"Token过期，请重新登录","data":null}"#
        let beforeExpiry = Session.shared.kickReasons.count
        do {
            _ = try await ApiClient.get("/device/info/mac")
            check(false, "设备详情业务响应说明会话过期应中止")
        } catch is CancellationError {
            check(Session.shared.kickReasons.count == beforeExpiry + 1, "设备详情的业务失效触发重新登录")
        } catch { check(false, "业务会话失效应中止旧请求") }
        Session.shared.isLoggedIn = true
        MockProtocol.responseBody = #"{"success":false,"errorCode":401,"data":null}"#
        let beforeWalletExpiry = Session.shared.kickReasons.count
        _ = try? await ApiClient.get("/account/wallet")
        check(Session.shared.kickReasons.count == beforeWalletExpiry + 1, "保留钱包心跳对业务错误码 401 的失效处理")
        Session.shared.isLoggedIn = true
        MockProtocol.responseBody = #"{"success":false,"msg":"Token过期，请重新登录","data":null}"#
        let beforeUnauthenticated = Session.shared.kickReasons.count
        _ = try? await ApiClient.post("/user/login", form: [:], withAuth: false)
        _ = try? await ApiClient.get("/user/verification/code/get")
        check(Session.shared.kickReasons.count == beforeUnauthenticated, "登录和短信验证码响应不结束已有会话")
        MockProtocol.responseBody = #"{"success":false,"errorCode":429,"errorMessage":"发送频繁，请稍后重试","data":null}"#
        do {
            try await AuthService.sendSmsCode(phone: "10000000000")
            check(false, "HTTP 200 的发码拒绝不能视为已发送")
        } catch ApiError.business(let code, _) {
            check(code == 429, "发码失败沿用业务错误码")
        } catch { check(false, "发码拒绝应返回业务错误") }
        MockProtocol.responseBody = #"{"success":true,"data":1}"#
        do {
            try await AuthService.sendSmsCode(phone: "10000000000", typeId: 5)
            check(true, "发码成功兼容非空标记字段")
        } catch { check(false, "发码成功被误判失败") }
        MockProtocol.responseBody = #"{"success":false,"errorMessage":"二维码已失效，请重新扫码","data":null}"#
        let stillLoggedIn = try? await ApiClient.get("/device/info/mac")
        check(stillLoggedIn != nil && Session.shared.kickReasons.count == beforeUnauthenticated,
              "二维码失效等设备业务错误保持原处理")
        MockProtocol.responseBody = #"{"success":true,"data":null}"#
        Session.shared.isLoggedIn = false
        _ = try? await ApiClient.get("/mock")
        check(MockProtocol.lastRequest?.url?.query?.contains("loginCode") != true, "未登录GET不拼空认证字段")
        Session.shared.isLoggedIn = true
        _ = try? await ApiClient.get("/user/verification/code/get")
        check(MockProtocol.lastRequest?.url?.query?.contains("loginCode") != true, "验证码GET不注入认证")
        check(MockProtocol.lastRequest?.value(forHTTPHeaderField: "phoneSystem") == nil, "不额外添加安卓未发送的phoneSystem头")
        let encoded = String(data: ApiClient.encodeForm(["value": "a b+c&d"]), encoding: .utf8)
        check(encoded == "value=a+b%2Bc%26d", "表单空格用加号、真实加号及分隔符正确转义")
        let project = ProjectAuthContext(projectId: "89", accountId: "12", owner:
            ProjectAuthContext.owner(userId: "test-user", projectId: Session.shared.projectId,
                                     accountId: "test-account"), generation: Session.shared.requestGeneration)
        do {
            _ = try await ApiClient.get("/mock", query: ["projectId": "wrong", "accountId": "wrong"], project: project)
            let items = MockProtocol.lastRequest?.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
            } ?? []
            check(items.filter { $0.name == "projectId" }.map(\.value) == ["89"]
                  && items.filter { $0.name == "accountId" }.map(\.value) == ["12"],
                  "跨项目 GET 只使用目标项目和账户参数")
            check(MockProtocol.lastRequest?.value(forHTTPHeaderField: "Config-Project") == "89",
                  "跨项目 GET 报头与参数一致")
            _ = try await ApiClient.post("/mock", form: ["projectId": "wrong", "accountId": "wrong"], project: project)
            let fields = MockProtocol.lastForm.split(separator: "&")
            check(fields.contains("projectId=89") && fields.contains("accountId=12")
                  && MockProtocol.lastRequest?.value(forHTTPHeaderField: "Config-Project") == "89",
                  "跨项目 POST 表单和报头使用同一个目标项目")
        } catch { check(false, "跨项目请求成功构造") }
        check(Session.shared.projectId == "test-school", "跨项目请求保留原登录项目")
        MockProtocol.status = 403
        let beforeDenied = Session.shared.kickReasons.count
        _ = try? await ApiClient.get("/mock", project: project)
        check(Session.shared.kickReasons.count == beforeDenied, "关联项目单独返回 HTTP 403 不结束主会话")
        MockProtocol.status = 401
        MockProtocol.rotateSession = true
        _ = try? await ApiClient.get("/mock")
        check(Session.shared.kickReasons.count == beforeDenied, "旧会话的 HTTP 401 不结束新会话")
        MockProtocol.rotateSession = false
        MockProtocol.status = 200
        let before = MockProtocol.requests
        let expired = Session.shared.requestGeneration
        Session.shared.requestGeneration = UUID()
        do {
            _ = try await ApiClient.get("/mock", project: project)
            check(false, "过期项目凭证不发起请求")
        } catch is CancellationError {
            check(MockProtocol.requests == before, "过期项目凭证不发起请求")
        } catch { check(false, "过期项目凭证不发起请求") }
        let blocked = await SessionWork.$generation.withValue(expired) {
            do { _ = try await ApiClient.post("/mock", form: [:]); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        check(blocked && MockProtocol.requests == before, "旧任务下一轮不能借用新账号凭证发请求")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await ApiClient.get("/mock"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let didCancel = await cancelled.value
        check(didCancel && MockProtocol.requests == before, "取消任务不发起网络请求")
        if failures > 0 { fatalError("网络回归失败 \(failures)") }
    }
}
