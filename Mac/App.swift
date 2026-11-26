import SwiftUI
import AppKit


@main struct BuddiHexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = RotatorModel.shared
    var body: some Scene {
        WindowGroup("BuddiHex Rotator") {
            MainView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 940, minHeight: 730)
        }
        .defaultSize(width: 1040, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Rotator") {
                Button("STOP") { model.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!model.connected)
                Button("Refresh bearing") { model.refresh() }.keyboardShortcut("r", modifiers: .command).disabled(!model.connected)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        RotatorModel.shared.connectOnLaunchIfEnabled()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { RotatorModel.shared.disconnect() }
}

