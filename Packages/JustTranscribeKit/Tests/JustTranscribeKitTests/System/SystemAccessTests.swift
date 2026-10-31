import AVFoundation
import ServiceManagement
import Testing
@testable import JustTranscribeKit

struct SystemAccessTests {
    @Test func microphoneAccess() {
        #expect(MicrophoneAccess(.authorized) == .granted)
        #expect(MicrophoneAccess(.notDetermined) == .notDetermined)
        #expect(MicrophoneAccess(.denied) == .denied)
        #expect(MicrophoneAccess(.restricted) == .denied)
    }

    @Test func loginItemState() {
        #expect(LoginItemState(.enabled) == .enabled)
        #expect(LoginItemState(.requiresApproval) == .requiresApproval)
        #expect(LoginItemState(.notRegistered) == .disabled)
        #expect(LoginItemState(.notFound) == .disabled)
        #expect(LoginItemState.enabled.isOn)
        #expect(LoginItemState.requiresApproval.isOn)
        #expect(!LoginItemState.disabled.isOn)
    }

    @Test func privacyPanesOpenSystemSettings() {
        #expect(PrivacyPane.microphone.url.absoluteString.hasSuffix("?Privacy_Microphone"))
        #expect(PrivacyPane.accessibility.url.absoluteString.hasSuffix("?Privacy_Accessibility"))
        #expect(PrivacyPane.allCases.allSatisfy { $0.url.scheme == "x-apple.systempreferences" })
    }
}
