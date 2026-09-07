import SwiftUI

@main
struct KanataApp: App {
    @State private var settings = AppSettings()
    @State private var cloudSync = CloudSyncStore.shared

    /// 注册用户导入字体，保证直接进入播放器时也能恢复上次字体。
    init() {
        DanmakuFontRegistry.registerStoredFonts()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(settings)
                .environment(cloudSync)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(settings.accentTheme.accent)
                .task { cloudSync.configure(settings: settings) }
                .alert(
                    "使用提示",
                    isPresented: Binding(
                        get: { settings.shouldShowFreeAppNotice },
                        set: { if !$0 { settings.markFreeAppNoticeShown() } }
                    )
                ) {
                    Button("知道了") { settings.markFreeAppNoticeShown() }
                } message: {
                    Text("当前应用完全免费，如有问题请在设置中前往本项目开源地址")
                }
        }
    }
}
