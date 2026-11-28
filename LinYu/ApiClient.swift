import Foundation

/// HTTP 层的错误
enum ApiError: LocalizedError {
    /// 业务错误（success=false），带服务端 errorCode
    case business(code: Int, message: String)
    /// 网络/解码层面
    case transport(String)
    /// 未登录
    case notLoggedIn
    /// HTTP 401 / 403 —— 会话已失效（被挤号或凭证过期）
    case unauthorized(status: Int)
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .business(_, let msg): return LoginFeedback.chineseMessage(msg)
        case .transport(let msg): return LoginFeedback.chineseMessage(msg, fallback: "网络连接失败，请检查网络")
        case .notLoggedIn: return "未登录"
        case .unauthorized: return "登录已失效，请重新登录"
        case .http: return "服务暂不可用，请稍后重试"
        }
    }
}

/// HTTP 客户端。对照 Android 的 `NetworkModule` + Retrofit 接口。
///
/// ## 三处容易写错的约定
///
/// 1. **POST 全是 form-urlencoded**（除了手动代扣那个接口，本项目不用）
/// 2. **GET 要把 auth 拼进 query**，而且 `telPhone` 也要带
/// 3. **所有请求都要带 `Config-Project` / `Config-Keys` 头** ——
///    Android 端缺了这两个头时，蓝牙结算（upload）直接报 226「加密校验失败」
struct ApiClient {

    static let baseURL = "https://v3-api.china-qzxy.cn"

    private static let configKeys =
        "module_list,advertise_type,question_list,service_phone_list," +
        "banner_list_app,activity_list_app,aliCard_popup_config"

    static var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // MARK: - 请求

    /// POST **JSON body** —— 本项目唯一用它的就是手动代扣
    /// （`/order/thirdTrade/single/json/pay`）。
    ///
    /// ⚠️ 别照其他接口改成 form-urlencoded：那个接口只收 JSON，
    /// 换成表单会直接报参数错。而且它要的 `phoneSystem` 是 `WeChat`
    /// （照抄官方 H5 抓包），不是 `android`。
    static func postJSON(
        _ path: String,
        body: [String: Any],
        tag: String? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let generation = Session.shared.requestGeneration
        try validateGeneration(generation)
        let usesCurrentSession = Session.shared.isLoggedIn &&
            (body["loginCode"] as? String) == Session.shared.authFields["loginCode"]
        guard let url = URL(string: baseURL + path) else {
            throw ApiError.transport("请求地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            try validateGeneration(generation)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            try await validateResponse(data, status: code, path: path, authenticated: usesCurrentSession,
                                       project: nil, generation: generation, method: "POST(json)", elapsed: ms, tag: tag)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApiError {
            throw error
        } catch {
            try validateGeneration(generation)
            AppLog.shared.e("HTTP FAIL POST(json) \(path): \(LoginFeedback.message(error))")
            throw ApiError.transport(LoginFeedback.message(error))
        }
    }

    /// POST form-urlencoded
    static func post(
        _ path: String,
        form: [String: String],
        withAuth: Bool = true,
        project: ProjectAuthContext? = nil,
        tag: String? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let generation = Session.shared.requestGeneration
        try validateGeneration(generation)
        let usesCurrentSession = withAuth && Session.shared.isLoggedIn
        var fields = form
        if withAuth {
            for (k, v) in try authFields(project: project, generation: generation) { fields[k] = v }
        } else if project != nil {
            throw ApiError.notLoggedIn
        }

        guard let url = URL(string: baseURL + path) else {
            throw ApiError.transport("请求地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                     forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&req, projectId: project?.projectId)
        req.httpBody = encodeForm(fields)

        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            try validateGeneration(generation)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            try await validateResponse(data, status: code, path: path, authenticated: usesCurrentSession,
                                        project: project, generation: generation, method: "POST", elapsed: ms, tag: tag)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApiError {
            throw error
        } catch {
            try validateGeneration(generation)
            AppLog.shared.e("HTTP FAIL POST \(path): \(LoginFeedback.message(error))")
            throw ApiError.transport(LoginFeedback.message(error))
        }
    }

    /// GET（自动拼 auth，但跳过 verification 接口）
    static func get(
        _ path: String,
        query: [String: String] = [:],
        project: ProjectAuthContext? = nil,
        tag: String? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let generation = Session.shared.requestGeneration
        try validateGeneration(generation)
        guard var comps = URLComponents(string: baseURL + path) else {
            throw ApiError.transport("请求地址无效")
        }
        var items = comps.queryItems ?? []
        var fields = query
        let usesCurrentSession = Session.shared.isLoggedIn && !path.contains("verification")
        if usesCurrentSession {
            for (k, v) in try authFields(project: project, generation: generation) { fields[k] = v }
        } else if project != nil {
            throw ApiError.notLoggedIn
        }
        items.removeAll { fields[$0.name] != nil }
        items.append(contentsOf: fields.map { URLQueryItem(name: $0.key, value: $0.value) })
        comps.queryItems = items

        guard let url = comps.url else { throw ApiError.transport("请求地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyCommonHeaders(&req, projectId: project?.projectId)

        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            try validateGeneration(generation)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            try await validateResponse(data, status: code, path: path, authenticated: usesCurrentSession,
                                        project: project, generation: generation, method: "GET", elapsed: ms, tag: tag)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApiError {
            throw error
        } catch {
            try validateGeneration(generation)
            AppLog.shared.e("HTTP FAIL GET \(path): \(LoginFeedback.message(error))")
            throw ApiError.transport(LoginFeedback.message(error))
        }
    }

    // MARK: - 内部

    private struct SessionFailureResponse: Decodable {
        let success: Bool?
        let errorCode: AnyNumber?
        let errorMessage: String?
        let msg: String?

        var expiryReason: String? {
            guard success == false else { return nil }
            return [errorMessage, msg].compactMap { $0 }.first(where: LoginFeedback.isSessionExpiredMessage)
        }
    }

    private static func validateResponse(
        _ data: Data, status: Int, path: String, authenticated: Bool, project: ProjectAuthContext?, generation: UUID,
        method: String, elapsed: Int, tag: String?
    ) async throws {
        let response = try? JSONDecoder().decode(SessionFailureResponse.self, from: data)
        let errorCode = response?.errorCode?.value
        let outcome = errorCode.map { "，业务码 \($0)" } ?? ""
        AppLog.shared.i("HTTP \(status) \(method) \(path) (\(elapsed)ms)\(tag.map { " [\($0)]" } ?? "")\(outcome)")
        let isUnauthorized = status == 401 || status == 403
        let isSuccessStatus = (200..<300).contains(status)
        if authenticated && (isUnauthorized || isSuccessStatus) {
            let isDefaultProject = project.map {
                let fields = Session.shared.authFields
                return $0.projectId == fields["projectId"] && $0.accountId == fields["accountId"]
            } ?? true
            // 保留钱包心跳对 HTTP 200 响应内 401 / 403 的识别。
            let walletSessionRejected = path == "/account/wallet" && response?.success == false &&
                (errorCode == 401 || errorCode == 403)
            // 单个关联项目的 401/403 也可能只是该项目无权限，需有明确的登录失效文案。
            let reason = response?.expiryReason ??
                ((isUnauthorized || walletSessionRejected) && isDefaultProject ? "登录已失效，请重新登录" : nil)
            if let reason {
                let endedCurrentSession = await MainActor.run {
                    guard SessionWork.isCurrent(generation) else { return false }
                    Session.shared.kickOut(reason: reason)
                    return true
                }
                guard endedCurrentSession else { throw CancellationError() }
                if isUnauthorized { throw ApiError.unauthorized(status: status) }
                throw CancellationError()
            }
        }
        try validateGeneration(generation)
        if isUnauthorized { throw ApiError.unauthorized(status: status) }
        guard isSuccessStatus else { throw ApiError.http(status: status) }
    }

    private static func validateGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        if let inherited = SessionWork.generation, inherited != generation { throw CancellationError() }
        guard generation == Session.shared.requestGeneration else { throw CancellationError() }
    }

    private static func authFields(project: ProjectAuthContext?, generation: UUID) throws -> [String: String] {
        var fields = Session.shared.authFields
        if let project {
            let owner = ProjectAuthContext.owner(userId: fields["userId"] ?? "",
                                                 projectId: fields["projectId"] ?? "",
                                                 accountId: fields["accountId"] ?? "")
            guard Session.shared.isLoggedIn, project.generation == generation, project.owner == owner,
                  !project.projectId.isEmpty, !project.accountId.isEmpty else { throw CancellationError() }
            fields["projectId"] = project.projectId
            fields["accountId"] = project.accountId
        }
        try validateGeneration(generation)
        return fields
    }

    private static func applyCommonHeaders(_ req: inout URLRequest, projectId: String? = nil) {
        let pid = projectId ?? Session.shared.projectId
        if !pid.isEmpty && pid != "0" {
            req.setValue(pid, forHTTPHeaderField: "Config-Project")
            req.setValue(configKeys, forHTTPHeaderField: "Config-Keys")
        }
    }

    static func encodeForm(_ fields: [String: String]) -> Data {
        // 用 application/x-www-form-urlencoded 的规则：空格 → +，其余百分号编码
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        allowed.insert(charactersIn: "*")
        let body = fields.map { k, v -> String in
            let ek = (k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k).replacingOccurrences(of: "%20", with: "+")
            let ev = (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v).replacingOccurrences(of: "%20", with: "+")
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    // MARK: - 业务响应

    /// 解析 `{ success, errorCode, errorMessage, data }`，`success == false` 时**抛错**。
    ///
    /// 只适用于「失败就该中断」的接口（登录、改密、领取使用码……）。
    /// 需要看 `errorCode` 的接口一律用 `decodeShell`，否则分支永远是死的（见那里的说明）。
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> APIResponse<T> {
        let resp = try decodeShell(type, from: data, path: path)
        guard resp.success else {
            throw ApiError.business(
                code: resp.errorCode ?? -1,
                message: resp.errorMessage ?? resp.msg ?? "请求失败"
            )
        }
        return resp
    }

    /// 只解外壳、**不因 `success == false` 抛错** —— 对照 Android 的 `SafeApi.parse`。
    ///
    /// ## 为什么必须有这个
    ///
    /// 服务端的业务语义大量藏在 `success=false` 里，而且**全是正常流程**：
    ///
    /// | errorCode | 含义 | 正确反应 |
    /// |---|---|---|
    /// | 306 | 设备不在线（4G 通道下发不到） | 问用户要不要改用蓝牙 |
    /// | 307 | 已有订单 / 已在关闭中 | 恢复订单 / 视为关阀成功 |
    /// | 206 / 209 | 蓝牙上传已受理 | 视为结算成功 |
    ///
    /// 用 `decode` 会把它们统统变成异常，调用方再写 `if errorCode == 306` 就**永远不成立**
    /// ——这正是「蓝牙表开了不阀、用户白等一次网络往返」的根因。
    static func decodeShell<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        path: String
    ) throws -> APIResponse<T> {
        do {
            return try JSONDecoder().decode(APIResponse<T>.self, from: data)
        } catch {
            AppLog.shared.e("解析失败 \(path)（\(data.count)B，\(type(of: error))）")
            throw ApiError.transport("服务响应异常，请重试")
        }
    }
}
