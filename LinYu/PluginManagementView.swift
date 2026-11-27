import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    private static let cardHeight: CGFloat = 66
    private static let cardSpacing: CGFloat = 10
    private static let cardStride = cardHeight + cardSpacing

    private enum Page {
        case management
        case repository

        var title: String {
            switch self {
            case .management: return "插件管理"
            case .repository: return "插件仓库"
            }
        }
    }

    private struct CardDrag {
        let pluginID: String
        let sourceIndex: Int
        let targetIndex: Int
        let offset: CGFloat
    }

    @State private var page = Page.management
    @State private var importingFile = false
    @State private var catalog = PluginRepository.bundledCatalog
    @State private var catalogFailed = false
    @State private var authorRefresh = 0
    @State private var githubLogins: [Int64: String] = [:]
    @State private var selection: Set<String>?
    @State private var detailPlugin: PluginManifest?
    @State private var pendingDeletion: [String]?
    @State private var request: Task<Void, Never>?
    @GestureState private var drag: CardDrag? = nil

    private var busy: Bool { request != nil }
    private var selecting: Bool { selection != nil }
    private var canReorder: Bool { installed.count > 1 && !busy && !selecting }
    private var showingDialog: Bool { detailPlugin != nil || pendingDeletion != nil }
    private var activeDrag: CardDrag? {
        guard let drag, installed.indices.contains(drag.sourceIndex),
              installed[drag.sourceIndex].id == drag.pluginID else { return nil }
        return drag
    }
    private var selectedPlugins: [PluginManifest] {
        installed.filter { selection?.contains($0.id) == true }
    }
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
            // 标题栏放进各自的 ScrollView 里（和其它页面一致），
            // 这样下拉时标题会跟着内容一起滚上去，而不是钉在顶部。
            pageContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!showingDialog)
            .accessibilityHidden(showingDialog)

            if let detailPlugin { pluginDetails(detailPlugin) }
            deleteConfirmation
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
        .task(id: authorRefresh) {
            let manifests = installed + catalog.map(\.manifest)
            let logins = await PluginRepository.fetchGithubLogins(manifests)
            guard !Task.isCancelled else { return }
            githubLogins.merge(logins) { _, refreshed in refreshed }
        }
        .onChange(of: Set(installed.compactMap(\.authorGithubID))) { _ in authorRefresh += 1 }
        .onDisappear { request?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                headerIcon(selecting ? "xmark" : "chevron.left")
            }
            .buttonStyle(InstantButtonStyle())
            .accessibilityLabel(selecting ? "退出选择" : "返回")

            Text(selection.map { "已选择 \($0.count) 个" } ?? page.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            toolbarActions
        }
        .frame(height: PageLayout.titleHeight)
        .frame(height: PageLayout.headerHeight, alignment: .top)
        .padding(.horizontal, PageLayout.horizontalInset)
        .padding(.top, PageLayout.topInset)
    }

    @ViewBuilder private var toolbarActions: some View {
        switch page {
        case .management:
            if selecting {
                Button(action: updateSelection) {
                    updateIcon
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("更新所选插件")
                .disabled(busy || selectedPlugins.isEmpty)

                Button {
                    pendingDeletion = selectedPlugins.map(\.id)
                } label: {
                    headerIcon("trash")
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("删除所选插件")
                .disabled(busy || selectedPlugins.isEmpty)
            } else {
                Button {
                    checkCatalog(reportUpdates: true)
                } label: {
                    updateIcon
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel("检查插件更新")
                .disabled(busy)

                Menu {
                    Button {
                        navigate(to: .repository)
                        checkCatalog(reportUpdates: false)
                    } label: {
                        Label("浏览插件仓库", image: "PluginGitHubIcon")
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
        case .repository:
            Button {
                checkCatalog(reportUpdates: false, reportRefresh: true)
            } label: {
                headerIcon("arrow.clockwise")
            }
            .buttonStyle(InstantButtonStyle())
            .accessibilityLabel("刷新插件仓库")
            .disabled(busy)
        }
    }

    private var updateIcon: some View {
        Image("PluginUpdateIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
            .foregroundStyle(colors.textPrimary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(colors.textPrimary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .management:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    if busy {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(colors.accent)
                            .padding(.horizontal, PageLayout.horizontalInset)
                    }
                }
                .padding(.bottom, 4)

                VStack(spacing: Self.cardSpacing) {
                    if installed.isEmpty {
                        emptyMessage("暂无已安装的插件")
                    } else {
                        ForEach(Array(installed.enumerated()), id: \.element.id) { index, plugin in
                            installedCard(plugin, index: index)
                        }
                    }
                }
                .padding(.horizontal, PageLayout.horizontalInset)
                .padding(.vertical, 16)
            }
            .coordinateSpace(name: Self.listSpace)
            .scrollDisabled(activeDrag != nil)
            .id("installed-plugin-list")
        case .repository:
            ScrollView(showsIndicators: false) {
                header
                if busy {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(colors.accent)
                        .padding(.horizontal, PageLayout.horizontalInset)
                }
                VStack(spacing: 10) { repositoryContent }
                    .padding(.horizontal, PageLayout.horizontalInset)
                    .padding(.vertical, 16)
            }
            .id("repository-plugin-list")
        }
    }

    private func installedCard(_ plugin: PluginManifest, index: Int) -> some View {
        let update = availableUpdate(for: plugin)
        let isSelected = selection?.contains(plugin.id) == true
        let drag = activeDrag
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                name(plugin)
                HStack(spacing: 4) {
                    Text("v\(plugin.version)")
                        .foregroundStyle(colors.textSecondary)
                    if update != nil {
                        Text("（可更新）")
                            .foregroundStyle(colors.danger)
                    }
                }
                .font(.system(size: 13))
                .lineLimit(1)
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.cardHeight)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.45)
                    .exclusively(before: TapGesture())
                    .onEnded { value in
                        switch value {
                        case .first: selectByLongPress(plugin.id)
                        case .second: tapInstalled(plugin)
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { tapInstalled(plugin) }
            .accessibilityAction(named: Text("选择插件")) { selectByLongPress(plugin.id) }

            if selecting {
                Button {
                    toggleSelection(plugin.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundStyle(isSelected ? colors.accent : colors.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InstantButtonStyle())
                .accessibilityLabel(isSelected ? "取消选择\(plugin.name)" : "选择\(plugin.name)")
                .disabled(busy)
            } else {
                installedMenu(plugin, update: update)
                reorderHandle(plugin, index: index)
            }
        }
        .padding(.trailing, 4)
        .linyuCard(colors)
        .offset(y: cardDragOffset(at: index, drag: drag))
        .animation(drag != nil && drag?.sourceIndex != index ? .easeOut(duration: 0.16) : nil,
                   value: drag?.targetIndex)
        .zIndex(drag?.sourceIndex == index ? 1 : 0)
    }

    private func installedMenu(_ plugin: PluginManifest, update: PluginListing?) -> some View {
        Menu {
            Button {
                guard let update else { return }
                download(update, updating: true)
            } label: {
                Label("更新", image: "PluginUpdateIcon")
            }
            .disabled(update == nil)
            Button(role: .destructive) {
                pendingDeletion = [plugin.id]
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
    }

    private func reorderHandle(_ plugin: PluginManifest, index: Int) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colors.textSecondary.opacity(canReorder ? 1 : 0.35))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
                    .updating($drag) { value, drag, _ in
                        let offset = value.translation.height
                        drag = CardDrag(pluginID: plugin.id, sourceIndex: index,
                                        targetIndex: destinationIndex(from: index, offset: offset), offset: offset)
                    }
                    .onEnded { value in
                        let targetIndex = destinationIndex(from: index, offset: value.translation.height)
                        if targetIndex != index { onMove(plugin.id, installed[targetIndex].id) }
                    },
                including: canReorder ? .all : .none
            )
            .accessibilityLabel("拖动排序")
            .accessibilityAdjustableAction { direction in
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

    private func destinationIndex(from index: Int, offset: CGFloat) -> Int {
        let slots = Int((offset / Self.cardStride).rounded())
        return min(max(0, index + slots), installed.count - 1)
    }

    private func cardDragOffset(at index: Int, drag: CardDrag?) -> CGFloat {
        guard let drag else { return 0 }
        if index == drag.sourceIndex { return drag.offset }
        if drag.sourceIndex < index, index <= drag.targetIndex { return -Self.cardStride }
        if drag.targetIndex <= index, index < drag.sourceIndex { return Self.cardStride }
        return 0
    }

    @ViewBuilder private var repositoryContent: some View {
        let publishedIDs = Set(catalog.map(\.id))
        let installedOnly = installed.filter { !publishedIDs.contains($0.id) }
        let isEmpty = catalog.isEmpty && installedOnly.isEmpty
        if catalogFailed {
            if isEmpty {
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
        } else if isEmpty, !busy {
            emptyMessage("暂无可用插件")
        }
        ForEach(catalog) { listing in
            repositoryCard(listing.manifest, listing: listing)
        }
        ForEach(installedOnly) { plugin in
            repositoryCard(plugin, listing: nil)
        }
    }

    private var retryCatalogButton: some View {
        Button("重试") { checkCatalog(reportUpdates: false) }
            .buttonStyle(InstantButtonStyle())
            .foregroundStyle(colors.accent)
            .frame(minHeight: 44)
    }

    private func repositoryCard(_ plugin: PluginManifest, listing: PluginListing?) -> some View {
        let current = installed.first { $0.id == plugin.id }
        let canUpdate = current.map { PluginRepository.isUpdate($0, plugin) } ?? false
        return HStack(spacing: 10) {
            Button {
                detailPlugin = plugin
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    name(plugin)
                    Text("作者 \(authorName(plugin)) · v\(plugin.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                    Text(plugin.description)
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let listing, current == nil || canUpdate {
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
                    .frame(minWidth: 55)
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

    private func authorName(_ plugin: PluginManifest) -> String {
        plugin.authorGithubID.flatMap { githubLogins[$0] }.map { "@\($0)" } ?? plugin.author
    }

    private func pluginDetails(_ plugin: PluginManifest) -> some View {
        let description = plugin.details
            ?? catalog.first(where: { $0.id == plugin.id })?.manifest.details
            ?? plugin.description
        let detailText = Text(description)
            .font(.system(size: 15))
            .foregroundStyle(colors.textPrimary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return DialogScrim(onTapOutside: { detailPlugin = nil }) {
            AlertCard(title: plugin.name, titleAlign: .leading,
                      contentSpacing: 10, actionSpacing: 0, cardPadding: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("作者 \(authorName(plugin)) · v\(plugin.version)")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                    if !plugin.permissions.isEmpty {
                        // v2：把插件声明访问的数据/动作直接摆给用户看（知情权，不是装饰）
                        Text("权限：" + plugin.permissions.map(PluginRepository.permissionLabel).joined(separator: "、"))
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PluginDetailDescriptionLayout {
                        detailText.hidden().accessibilityHidden(true)
                        ViewThatFits(in: .vertical) {
                            detailText
                            ScrollView { detailText }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } actions: {
                EmptyView()
            }
        }
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(colors.textSecondary)
            .padding(.top, 44)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var deleteConfirmation: some View {
        if let ids = pendingDeletion {
            ConfirmDialogView(
                title: "删除插件",
                message: ids.count == 1 ? "确定删除这个插件？" : "确定删除所选插件？",
                confirmTitle: "删除",
                destructive: true,
                compact: true,
                onConfirm: { deletePlugins(ids) },
                onDismiss: { pendingDeletion = nil }
            )
        }
    }

    private func tapInstalled(_ plugin: PluginManifest) {
        if selecting {
            toggleSelection(plugin.id)
        } else {
            detailPlugin = plugin
        }
    }

    private func selectByLongPress(_ id: String) {
        guard !busy else { return }
        if selection == nil { selection = [id] }
    }

    private func toggleSelection(_ id: String) {
        guard !busy, var selection else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        self.selection = selection
    }

    private func deletePlugins(_ ids: [String]) {
        pendingDeletion = nil
        let removed = ids.filter { onUninstall($0) }
        selection?.subtract(removed)
        if selection?.isEmpty == true { selection = nil }
        if removed.isEmpty {
            onMessage("删除失败，请重试")
        } else if ids.count == 1 {
            onMessage("已删除")
        } else if removed.count == ids.count {
            onMessage("已删除 \(removed.count) 个插件")
        } else {
            onMessage("已删除 \(removed.count) 个，\(ids.count - removed.count) 个失败")
        }
    }

    private func navigate(to page: Page) {
        pendingDeletion = nil
        detailPlugin = nil
        selection = nil
        self.page = page
    }

    private func back() {
        if detailPlugin != nil {
            detailPlugin = nil
        } else if pendingDeletion != nil {
            pendingDeletion = nil
        } else if selecting {
            selection = nil
        } else {
            switch page {
            case .management: onDismiss()
            case .repository: navigate(to: .management)
            }
        }
    }

    private func loadCatalog() async throws {
        let entries = try await PluginRepository.fetchCatalog()
        try Task.checkCancellation()
        catalog = entries
        catalogFailed = false
        authorRefresh += 1
    }

    private func checkCatalog(reportUpdates: Bool, reportRefresh: Bool = false) {
        guard !busy else { return }
        catalogFailed = false
        request = Task {
            defer { request = nil }
            do {
                try await loadCatalog()
                if reportUpdates {
                    let updateCount = installed.filter { availableUpdate(for: $0) != nil }.count
                    if installed.isEmpty {
                        onMessage("暂无已安装的插件")
                    } else if updateCount == 0 {
                        onMessage("插件均为最新版本")
                    } else {
                        onMessage("有 \(updateCount) 个插件可更新")
                    }
                } else if reportRefresh {
                    onMessage("插件仓库已刷新")
                }
            } catch {
                guard !Task.isCancelled else { return }
                catalogFailed = true
                if reportUpdates { onMessage("检查更新失败，请重试") }
                if reportRefresh { onMessage("刷新失败，请重试") }
            }
        }
    }

    private func updateSelection() {
        let plugins = selectedPlugins
        guard !busy, !plugins.isEmpty else { return }
        request = Task {
            defer { request = nil }
            do {
                try await loadCatalog()
            } catch {
                guard !Task.isCancelled else { return }
                catalogFailed = true
            }

            let updates = plugins.compactMap { availableUpdate(for: $0) }
            guard !updates.isEmpty else {
                onMessage(catalogFailed ? "检查更新失败，请重试" : "所选插件均为最新版本")
                return
            }

            var failedIDs: Set<String> = []
            for listing in updates {
                do {
                    let manifest = try await PluginRepository.download(listing)
                    try Task.checkCancellation()
                    if !onInstall(manifest) { failedIDs.insert(listing.id) }
                } catch {
                    guard !Task.isCancelled else { return }
                    failedIDs.insert(listing.id)
                }
            }

            let updated = updates.count - failedIDs.count
            if updated == 0 {
                onMessage("更新失败，请重试")
            } else {
                if selecting { selection = failedIDs.isEmpty ? nil : failedIDs }
                if failedIDs.isEmpty {
                    onMessage("已更新 \(updated) 个插件")
                } else {
                    onMessage("已更新 \(updated) 个，\(failedIDs.count) 个失败")
                }
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

private struct PluginDetailDescriptionLayout: Layout {
    private let maxHeight: CGFloat = 280

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        // Measure only the text's natural height. The fallback scroll view may claim all the space.
        let textSize = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let height = min(textSize.height, maxHeight, proposal.height ?? maxHeight)
        return CGSize(width: width ?? textSize.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
