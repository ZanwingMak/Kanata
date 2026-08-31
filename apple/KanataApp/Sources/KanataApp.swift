import SwiftUI

@main
struct KanataApp: App {
    @State private var settings = AppSettings()

    /// 注册用户导入字体，保证直接进入播放器时也能恢复上次字体。
    init() {
        DanmakuFontRegistry.registerStoredFonts()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(settings)
                .preferredColorScheme(.dark)
        }
    }
}
