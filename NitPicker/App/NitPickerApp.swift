import AppKit
import SwiftUI

@main
struct NitPickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var player = PlayerModel()

    var body: some Scene {
        Window("Nit Picker", id: "main") {
            PlayerWindowView()
                .environment(player)
                .onOpenURL { url in if PlayerModel.canOpen(url) { player.open(url) } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    player.saveResumePosition()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 540)
        .commands { AppCommands(player: player) }

        Settings {
            SettingsView()
                .environment(player)
        }
    }
}
