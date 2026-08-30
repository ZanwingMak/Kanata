import SwiftUI

@main
struct KanataApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(settings)
                .preferredColorScheme(.dark)
        }
    }
}
