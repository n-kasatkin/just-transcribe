import AVFoundation
import ServiceManagement

/// Microphone permission as dictation needs it.
public enum MicrophoneAccess: Sendable, Equatable {
    case granted
    /// Never asked; asking is allowed only after the user starts a dictation or presses Allow.
    case notDetermined
    /// Denied or restricted; only System Settings can change it.
    case denied

    public init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }
}

/// The app's Login Item as the Settings toggle shows it.
public enum LoginItemState: Sendable, Equatable {
    case enabled
    /// Registered, but the user must allow it in System Settings → General → Login Items.
    case requiresApproval
    case disabled

    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound: self = .disabled
        @unknown default: self = .disabled
        }
    }

    /// A pending approval still counts as on: turning it off unregisters it.
    public var isOn: Bool { self != .disabled }
}

/// System Settings panes the app links to.
public enum PrivacyPane: Sendable, CaseIterable {
    case microphone
    case accessibility

    public var url: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}
