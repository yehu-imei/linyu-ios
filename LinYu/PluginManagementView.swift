import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct PluginCardPositions: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

@MainActor
struct PluginManagementView: View {
    @Environment(\.appColors) private var colors

    let installed: [PluginManifest]
    let backgroundPluginInstalled: Bool
    let onInstall: (PluginManifest) -> Bool
    let onUninstall: (String) -> Bool
    let onMove: (String, String) -> Void
    let onDismiss: () -> Void
    let onMessage: (String) -> Void

    private static let listSpace = "installedPluginList"

    private enum Panel {
        case details(PluginManifest)
        case delete(String)
    }

    private struct CardDrag {
        let id: String
        let offset: CGFloat
    }

    @State private var showingMarket = false
    @State private var importingFile = false
    @State private var catalog = PluginRepository.bundledCatalog
    @State private var catalogFailed = false
    @State private var creditRefresh = 0
    @State private var githubLogins: [Int64: String] = [:]
    @State private var panel: Panel?
    @State private var request: Task<Void, Never>?
    @State private var cardPositions: [String: CGFloat] = [:]
    @GestureState private var drag: CardDrag?

    private var busy: Bool { request != nil }
    private var canReorder: Bool { installed.count > 1 && !busy }
    private func availableUpdate(for plugin: PluginManifest) -> PluginListing? {
        catalog.first { PluginRepository.isUpdate(plugin, $0.manifest) }
    }

    var body: some View {
        ZStack {
            colors.background
                .ignoresSafeArea()
                .onTapGesture {}
                .accessibilityHidden(true)
            AppBackground(scope: .home, backgroundPluginInstalled: backgroundPluginInstalled)
            VStack(spacing: 0) {
                header
                if busy {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(colors.accent)
                        .padding(.horizontal, PageLayout.horizontalInset)
                }
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        if showingMarket {
                            marketContent
                        } else if installed.isEmpty {
                            emptyMessage("暂无已安装的插件")
                        } else {
                            ForEach(installed) { plugin in
                                installedCard(plugin)
                            }
                        }
                    }
                    .padding(.horizontal, PageLayout.horizontalInset)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }
                .coordinateSpace(name: Self.listSpace)
                .scrollDisabled(drag != nil)
                .onPreferenceChange(PluginCardPositions.self) { cardPositions = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(panel == nil)
            .accessibilityHidden(panel != nil)

            panelContent
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard value.startLocation.x < 24, value.translation.width > 80,
                      abs(value.translation.height) < 50 else { return }
                back()
            }
        )
        .accessibilityAction(.escape) { back() }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.zip, .json]) { result in
            switch result {
            case let .success(url):
                install(success: "安装成功", failure: "无法安装此文件，请选择兼容的插件包") {
                    try await PluginRepository.readFile(url)
                }
            case let .failure(error):
                let cocoaError = error as NSError
                if cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError {
                    onMessage("无法读取插件文件")
                }
            }
        }
        .task(id: creditRefresh) {
            let manifests = installed + catalog.map(\.manifest)
            let logins = await PluginRepository.fetchGithubLogins(manifests)
            guard !Task.isCancelled else { return }
            githubLogins.merge(logins) { _, refreshed in refreshed }
        }
        .onChange(of: Set(installed.compactMap(\.creditGithubID))) { _ in creditRefresh += 1 }
        .onDisappear { request?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                headerIcon("chevron.left")
            }
            .buttonStyle(InstantButtonStyle())
            .accessibilityLabel(showingMarket ? "返回插件管理" : "返回设置")

            Text(showingMarket ? "插件仓库" : "插件管理")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if !showingMarket {
                Button {
                    checkCatalog(reportUpdates: true)
                } label: {
                    headerIcon("arrow.clockwise")
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("检查插件更新")
                .disabled(busy)

                Menu {
                    Button {
                        showingMarket = true
                        checkCatalog(reportUpdates: false)
                    } label: {
                        Label("浏览插件仓库", systemImage: "cart")
                    }
                    Button {
                        importingFile = true
                    } label: {
                        Label("选择文件安装", systemImage: "doc.badge.plus")
                    }
                } label: {
                    headerIcon("plus")
                }
                .accessibilityLabel("添加插件")
                .disabled(busy)
            }
        }
        .frame(height: PageLayout.titleHeight)
        .frame(height: PageLayout.headerHeight, alignment: .top)
        .padding(.horizontal, PageLayout.horizontalInset)
        .padding(.top, 20)
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(colors.textPrimary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func installedCard(_ plugin: PluginManifest) -> some View {
        let update = availableUpdate(for: plugin)
        return HStack(spacing: 0) {
            Button {
                panel = .details(plugin)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    name(plugin)
                    HStack(spacing: 8) {
                        Text("版本 \(plugin.version)")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary)
                        if update != nil {
                            Text("可更新")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(colors.warning)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(colors.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    guard let update else { return }
                    download(update, updating: true)
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .disabled(update == nil)
                Button(role: .destructive) {
                    panel = .delete(plugin.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(plugin.name)操作")
            .disabled(busy)

            reorderHandle(plugin)
        }
        .padding(.trailing, 4)
        .linyuCard(colors)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PluginCardPositions.self, value: [
                    plugin.id: geometry.frame(in: .named(Self.listSpace)).midY
                ])
            }
        }
        .offset(y: drag?.id == plugin.id ? drag?.offset ?? 0 : 0)
        .zIndex(drag?.id == plugin.id ? 1 : 0)
    }

    private func reorderHandle(_ plugin: PluginManifest) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colors.textSecondary.opacity(canReorder ? 1 : 0.35))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
                    .updating($drag) { value, drag, _ in
                        drag = CardDrag(id: plugin.id, offset: value.translation.height)
                    }
                    .onEnded { value in
                        let target = cardPositions.min { left, right in
                            let y = value.location.y
                            let leftCenter = left.key == plugin.id ? value.startLocation.y : left.value
                            let rightCenter = right.key == plugin.id ? value.startLocation.y : right.value
                            return abs(leftCenter - y) < abs(rightCenter - y)
                        }
                        if let target { onMove(plugin.id, target.key) }
                    },
                including: canReorder ? .all : .none
            )
            .accessibilityLabel("拖动排序")
            .accessibilityAdjustableAction { direction in
                guard let index = installed.firstIndex(where: { $0.id == plugin.id }) else { return }
                switch direction {
                case .increment:
                    if index < installed.count - 1 { onMove(plugin.id, installed[index + 1].id) }
                case .decrement:
                    if index > 0 { onMove(plugin.id, installed[index - 1].id) }
                @unknown default:
                    break
                }
            }
            .accessibilityHidden(!canReorder)
    }

    @ViewBuilder private var marketContent: some View {
        if catalogFailed {
            if catalog.isEmpty {
                emptyMessage("无法读取插件目录")
                retryCatalogButton
            } else {
                HStack {
                    Text("暂时无法访问在线插件仓库")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                    Spacer(minLength: 6)
                    retryCatalogButton
                }
            }
        } else if catalog.isEmpty, !busy {
            emptyMessage("暂无可用插件")
        }
        ForEach(catalog) { listing in
            marketCard(listing)
        }
    }

    private var retryCatalogButton: some View {
        Button("重试") { checkCatalog(reportUpdates: false) }
            .buttonStyle(InstantButtonStyle())
            .foregroundStyle(colors.accent)
            .frame(minHeight: 44)
    }

    private func marketCard(_ listing: PluginListing) -> some View {
        let plugin = listing.manifest
        let current = installed.first { $0.id == plugin.id }
        let canUpdate = current.map { PluginRepository.isUpdate($0, plugin) } ?? false
        return HStack(spacing: 10) {
            Button {
                panel = .details(plugin)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    name(plugin)
                    attribution(plugin, size: 12)
                    Text(plugin.description)
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if current == nil || canUpdate {
                Button(canUpdate ? "更新" : "安装") {
                    download(listing, updating: canUpdate)
                }
                .buttonStyle(AccentButtonStyle(colors: colors, radius: 12, height: 36))
                .disabled(busy)
                .opacity(busy ? 0.55 : 1)
            } else {
                Text("已安装")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .padding(15)
        .linyuCard(colors)
    }

    private func name(_ plugin: PluginManifest) -> some View {
        Text(plugin.name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colors.textPrimary)
            .lineLimit(1)
    }

    private func attribution(_ plugin: PluginManifest, size: CGFloat) -> some View {
        let suggestion = plugin.creditGithubID.flatMap { githubLogins[$0] }.map { "@\($0)" } ?? plugin.credit
        return VStack(alignment: .leading, spacing: 4) {
            Text("作者 \(plugin.author) · 版本 \(plugin.version)")
            if let suggestion {
                Text("功能建议 \(suggestion)")
            }
        }
        .font(.system(size: size))
        .foregroundStyle(colors.textSecondary)
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(colors.textSecondary)
            .padding(.top, 44)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var panelContent: some View {
        if let panel {
            switch panel {
            case let .details(plugin):
                DialogScrim(onTapOutside: { self.panel = nil }) {
                    AlertCard(title: plugin.name, titleAlign: .leading,
                              contentSpacing: 10, actionSpacing: 0, cardPadding: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            attribution(plugin, size: 13)
                            Text(plugin.description)
                                .font(.system(size: 15))
                                .foregroundStyle(colors.textPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } actions: {
                        EmptyView()
                    }
                }
            case let .delete(id):
                ConfirmDialogView(
                    title: "删除插件",
                    message: "确定删除这个插件？",
                    confirmTitle: "删除",
                    destructive: true,
                    onConfirm: {
                        self.panel = nil
                        onMessage(onUninstall(id) ? "已删除" : "删除失败，请重试")
                    },
                    onDismiss: { self.panel = nil }
                )
            }
        }
    }

    private func back() {
        if panel != nil {
            panel = nil
        } else if showingMarket {
            showingMarket = false
        } else {
            onDismiss()
        }
    }

    private func checkCatalog(reportUpdates: Bool) {
        guard !busy else { return }
        catalogFailed = false
        request = Task {
            defer { request = nil }
            do {
                let entries = try await PluginRepository.fetchCatalog()
                try Task.checkCancellation()
                catalog = entries
                creditRefresh += 1
                if reportUpdates {
                    let updateCount = installed.filter { plugin in
                        entries.contains { PluginRepository.isUpdate(plugin, $0.manifest) }
                    }.count
                    if installed.isEmpty {
                        onMessage("暂无已安装的插件")
                    } else if updateCount == 0 {
                        onMessage("插件均为最新版本")
                    } else {
                        onMessage("有 \(updateCount) 个插件可更新")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                catalogFailed = true
                if reportUpdates { onMessage("检查更新失败，请重试") }
            }
        }
    }

    private func download(_ listing: PluginListing, updating: Bool) {
        install(
            success: updating ? "更新成功" : "安装成功",
            failure: updating ? "更新失败，请检查网络后重试" : "下载失败，请检查网络后重试"
        ) {
            try await PluginRepository.download(listing)
        }
    }

    private func install(success: String, failure: String, load: @escaping () async throws -> PluginManifest) {
        guard !busy else { return }
        request = Task {
            defer { request = nil }
            do {
                let manifest = try await load()
                try Task.checkCancellation()
                if onInstall(manifest) {
                    showingMarket = false
                    onMessage(success)
                } else {
                    onMessage("安装失败，请检查插件版本")
                }
            } catch {
                if !Task.isCancelled {
                    onMessage((error as? LocalizedError)?.errorDescription ?? failure)
                }
            }
        }
    }
}
