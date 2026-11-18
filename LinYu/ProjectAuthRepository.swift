import Foundation

@MainActor enum ProjectAuthRepository {
    private static var currentGeneration: UUID?
    private static var projectMap: [String: String] = [:]
    private static var devices: [String: DeviceInfo] = [:]
    private static var lastAttempt: Date?
    private static var refreshTask: Task<[ProjectAccount]?, Error>?

    static func isCurrent(_ context: ProjectAuthContext) -> Bool {
        SessionWork.isCurrent(context.generation)
    }

    static func defaultContext() throws -> ProjectAuthContext {
        let session = Session.shared
        let generation = session.requestGeneration
        guard SessionWork.isCurrent(generation),
              SessionWork.generation == nil || SessionWork.generation == generation,
              session.isLoggedIn, !session.projectId.isEmpty, !session.accountId.isEmpty else {
            throw CancellationError()
        }
        if currentGeneration != generation {
            refreshTask?.cancel()
            refreshTask = nil
            projectMap.removeAll()
            devices.removeAll()
            lastAttempt = nil
            currentGeneration = generation
        }
        let owner = ProjectAuthContext.owner(userId: session.userId, projectId: session.projectId,
                                             accountId: session.accountId)
        return ProjectAuthContext(projectId: session.projectId, accountId: session.accountId,
                                  owner: owner, generation: generation)
    }

    static func projectAccounts() async throws -> [ProjectAuthContext] {
        let current = try defaultContext()
        if refreshTask == nil,
           lastAttempt.map({ Date().timeIntervalSince($0) >= 15 }) ?? true {
            lastAttempt = Date()
            refreshTask = Task {
                let data = try await ApiClient.get("/user/project/list", project: current, tag: "projectAccounts")
                let response = try ApiClient.decodeShell([ProjectAccount].self, from: data, path: "projectAccounts")
                guard response.success else { throw ApiError.transport("项目账户暂未更新") }
                return response.data
            }
        }
        if let task = refreshTask {
            do {
                let projects = try await task.value
                guard isCurrent(current) else { throw CancellationError() }
                if let projects {
                    projectMap = ProjectAuthPolicy.accounts(projects, userId: Session.shared.userId,
                                                            defaultContext: current)
                }
            } catch is CancellationError {
                if currentGeneration == current.generation { refreshTask = nil }
                throw CancellationError()
            } catch {
                guard isCurrent(current) else { throw CancellationError() }
                AppLog.shared.w("项目账户暂未更新")
            }
            if currentGeneration == current.generation { refreshTask = nil }
        }
        return [current] + projectMap.keys.sorted().compactMap { project in
            guard project != current.projectId, let account = projectMap[project] else { return nil }
            return ProjectAuthContext(projectId: project, accountId: account, owner: current.owner,
                                      generation: current.generation)
        }
    }

    static func context(projectId: String, accountId: String? = nil) async throws -> ProjectAuthContext {
        let current = try defaultContext()
        if projectId == current.projectId && (accountId == nil || accountId == current.accountId) {
            return current
        }
        if let verified = projectMap[projectId], accountId == nil || accountId == verified {
            return ProjectAuthContext(projectId: projectId, accountId: verified, owner: current.owner,
                                      generation: current.generation)
        }
        let accounts = try await projectAccounts()
        guard let found = accounts.first(where: {
            $0.projectId == projectId && (accountId == nil || $0.accountId == accountId)
        }) else {
            throw ApiError.transport("未找到该设备的项目账户，请先在官方 App 确认")
        }
        return found
    }

    static func remember(_ device: DeviceInfo, generation: UUID) {
        guard SessionWork.isCurrent(generation), (try? defaultContext()) != nil,
              let sn = device.snCode, !sn.isEmpty else { return }
        devices[sn] = device
    }

    static func context(snCode: String, device: DeviceInfo? = nil) async throws -> ProjectAuthContext {
        let current = try defaultContext()
        let record = ActiveOrderStore.find(snCode)
        if let owner = record?.authOwner, owner != current.owner {
            throw ApiError.transport("此订单属于其他账户，请切回原账户")
        }
        if let device {
            guard device.snCode == snCode else { throw ApiError.transport("设备信息已变化，请刷新") }
            remember(device, generation: current.generation)
        }
        var info = device ?? devices[snCode]
        if info == nil, record?.projectId == nil {
            let lookup = record?.deviceMac.isEmpty == false ? record?.deviceMac :
                (Prefs.lastDeviceSnCode == snCode ? Prefs.lastDeviceMac : DeviceAddress.normalize(snCode))
            if let lookup, !lookup.isEmpty,
               let found = try await DeviceLookup.load(lookup), found.snCode == snCode {
                info = found
            }
        }
        guard isCurrent(current) else { throw CancellationError() }
        let explicit = info?.projectId.flatMap { $0 > 0 ? String($0) : nil }
        if let explicit, let recorded = record?.projectId, explicit != recorded {
            throw ApiError.transport("设备所属项目已变化，请在官方 App 核对订单")
        }
        guard let project = explicit ?? record?.projectId ??
            (info?.isDrinkingWater == false ? current.projectId : nil) else {
            throw ApiError.transport("设备项目信息不完整，请刷新设备后重试")
        }
        return try await context(projectId: project, accountId: record?.projectAccountId)
    }
}
