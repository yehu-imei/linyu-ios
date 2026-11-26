import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PluginManagementView: View {
    @Environment(\.appColors) private var colors

    let installed: PluginManifest?
    let onInstall: (PluginManifest) -> Bool
    let onUninstall: () -> Bool
    let onDismiss: () -> Void
    let onMessage: (String) -> Void

    private enum Panel {
        case details(PluginManifest)
        case delete(PluginManifest)
    }

    @State private var showingMarket = false
    @State private var importingFile = false
    @State private var catalog: [PluginListing]?
    @State private var catalogFailed = false
    @State private var panel: Panel?
    @State private var request: Task<Void, Never>?

    private var busy: Bool { request != nil }
    private var availableUpdate: PluginListing? {
        guard let installed else { return nil }
        return catalog?.first { PluginRepository.isUpdate(installed, $0.manifest) }
    }

    var body: some View {
        ZStack {
            colors.background
                .ignoresSafeArea()
                .onTapGesture {}
                .accessibilityHidden(true)
            AppBackground(scope: .home)
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
                        } else if let installed {
                            installedCard(installed)
                        } else {
                            emptyMessage("暂无已安装的插件")
                        }
                    }
                    .padding(.horizontal, PageLayout.horizontalInset)
                    .padding(.vertical, 12)
                }
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
        .onDisappear { request?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                headerIcon("chevron.left")
            }
            .buttonStyle(InstantButtonStyle())
            .accessibilityLabel(showingMarket ? "返回插件管理" : "返回设置")

            Text(showingMarket ? "插件市场" : "插件管理")
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
                        Label("去插件市场", systemImage: "cart")
                    }
                    Button {
                        importingFile = true
                    } label: {
                        Label("从文件安装", systemImage: "doc.badge.plus")
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
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(colors.textPrimary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func installedCard(_ plugin: PluginManifest) -> some View {
        HStack(spacing: 0) {
            Button {
                panel = .details(plugin)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    name(plugin)
                    HStack(spacing: 8) {
                        Text("版本 \(plugin.version)")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary)
                        if availableUpdate != nil {
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
                    guard let availableUpdate else { return }
                    download(availableUpdate, updating: true)
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .disabled(availableUpdate == nil)
                Button(role: .destructive) {
                    panel = .delete(plugin)
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

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(colors.textSecondary.opacity(0.35))
                .frame(width: 40, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.trailing, 4)
        .linyuCard(colors)
    }

    @ViewBuilder private var marketContent: some View {
        if let catalog {
            if catalog.isEmpty {
                emptyMessage("暂无可用插件")
            } else {
                ForEach(catalog, id: \.manifest.id) { listing in
                    marketCard(listing)
                }
            }
        } else if catalogFailed {
            emptyMessage("无法读取插件目录")
            Button("重试") { checkCatalog(reportUpdates: false) }
                .buttonStyle(InstantButtonStyle())
                .foregroundStyle(colors.accent)
                .frame(minHeight: 44)
        }
    }

    private func marketCard(_ listing: PluginListing) -> some View {
        let plugin = listing.manifest
        let isInstalled = installed?.id == plugin.id
        let canUpdate = installed.map { PluginRepository.isUpdate($0, plugin) } ?? false
        return HStack(spacing: 10) {
            Button {
                panel = .details(plugin)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    name(plugin)
                    Text("作者 \(plugin.author) · 版本 \(plugin.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                    Text(plugin.description)
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isInstalled || canUpdate {
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
                            Text("作者 \(plugin.author) · 版本 \(plugin.version)")
                                .font(.system(size: 13))
                                .foregroundStyle(colors.textSecondary)
                            Text(plugin.description)
                                .font(.system(size: 15))
                                .foregroundStyle(colors.textPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } actions: {
                        EmptyView()
                    }
                }
            case let .delete(plugin):
                ConfirmDialogView(
                    title: "删除\(plugin.name)？",
                    message: "将清除当前绑定，首页和桌面小组件恢复显示附近设备。",
                    confirmTitle: "删除",
                    destructive: true,
                    onConfirm: {
                        self.panel = nil
                        onMessage(onUninstall() ? "已删除" : "删除失败，请重试")
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
                if reportUpdates {
                    if installed == nil {
                        onMessage("暂无已安装的插件")
                    } else {
                        onMessage(availableUpdate == nil ? "插件均为最新版本" : "有 1 个插件可更新")
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
