import SwiftUI

@main
struct DissolveApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            WritingPad()
                .environmentObject(settings)
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 960, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 360)
        }
    }
}
