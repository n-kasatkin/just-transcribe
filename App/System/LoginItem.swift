import JustTranscribeKit
import Observation
import ServiceManagement

/// Start at login through `SMAppService.mainApp`. Nothing registers until the user flips the toggle.
@Observable
final class LoginItem {
    private(set) var state = LoginItemState(SMAppService.mainApp.status)
    /// Why the last change failed, shown under the toggle.
    private(set) var errorMessage: String?

    func refresh() {
        state = LoginItemState(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
