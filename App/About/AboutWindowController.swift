import AppKit
import JustTranscribeKit
import SwiftUI

/// The About window, in place of the standard about panel, so it can credit ostt and show the
/// bundled ostt's version.
final class AboutWindowController {
    private let client: OsttSettingsClient
    private let acknowledgements = AcknowledgementsWindowController()
    private var window: NSWindow?

    init(client: OsttSettingsClient) {
        self.client = client
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = AboutView(client: client) { [acknowledgements] in acknowledgements.show() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "About just transcribe"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private struct AboutView: View {
    let client: OsttSettingsClient
    let showAcknowledgements: () -> Void
    @State private var osttVersion = "ostt …"
    @State private var versionLoaded = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("just transcribe")
                    .font(.system(size: 22, weight: .semibold))
                Text(Self.appVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Press a key. Talk. It's typed.")
            VStack(spacing: 4) {
                Text("Based on [ostt](https://github.com/kristoferlund/ostt) by Kristofer Lund · MIT")
                Text(osttVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            VStack(spacing: 4) {
                Text("Copyright © 2026 Nikita Kasatkin · MIT License")
                Link("github.com/n-kasatkin/just-transcribe", destination: Self.repoURL)
            }
            .font(.callout)
            Button("Acknowledgements", action: showAcknowledgements)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 360)
        // The window is reused, so the task reruns on every reopen; the version cannot change.
        .task {
            guard !versionLoaded else { return }
            do {
                osttVersion = "ostt \(try await client.version())"
                versionLoaded = true
            } catch OsttError.helperMissing {
                osttVersion = "ostt is missing from the app"
            } catch {
                osttVersion = "ostt version unavailable"
            }
        }
    }

    private static let repoURL = URL(string: "https://github.com/n-kasatkin/just-transcribe")!

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}
