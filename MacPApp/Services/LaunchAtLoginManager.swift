import Foundation
import ServiceManagement

/// Manages native macOS Launch at Login via Apple's `SMAppService.mainApp`.
enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Activé au démarrage de session"
        case .requiresApproval:
            return "Validation requise dans Réglages Système > Ouverture"
        case .notRegistered, .notFound:
            return "Désactivé"
        @unknown default:
            return "Inconnu"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
