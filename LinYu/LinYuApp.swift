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
            if CommandLine.arguments.contains("--account-dialog-preview") {
                AccountDialogPreview()
            } else if #available(iOS 17.0, *), CommandLine.arguments.contains("--widget-preview") {
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

#if DEBUG
private struct AccountDialogPreview: View {
    private let startsInSMS = CommandLine.arguments.contains("--preview-password-sms")

    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .overlay {
                if startsInSMS || CommandLine.arguments.contains("--preview-password") {
                    ChangePasswordDialog(currentPhone: "13800000000", startsInSMS: startsInSMS) {}
                } else {
                    ChangePhoneDialog(currentPhone: "13800000000", onDismiss: {})
                }
            }
    }
}
#endif
