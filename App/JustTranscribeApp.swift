import AppKit
import SwiftUI

@main
struct JustTranscribeApp: App {
    var body: some Scene {
        MenuBarExtra("just transcribe", systemImage: "waveform") {
            Button("About just transcribe") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Divider()
            Button("Quit just transcribe") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
