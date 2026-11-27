import SwiftUI

@main
struct LinYuApp: App {
    init() {
        AppLog.shared.i("App 启动")
        // 插件仓库自己的日志也进 AppLog（文件里不直接依赖 AppLog，便于单测编译）
        PluginRepository.log = { AppLog.shared.i($0) }
        AppNotifications.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if #available(iOS 17.0, *), CommandLine.arguments.contains("--widget-preview") {
                WidgetPreviewScreen()
            } else {
                RootView().onOpenURL { WidgetBridge.shared.receive($0) }
            }
            #else
            RootView().onOpenURL { WidgetBridge.shared.receive($0) }
            #endif
        }
    }
}
