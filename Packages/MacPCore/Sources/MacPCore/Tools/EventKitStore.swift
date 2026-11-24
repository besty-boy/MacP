import EventKit
import Foundation

/// Shared, long-lived `EKEventStore` container recommended by Apple's EventKit guidelines.
/// Reusing one store avoids repeated XPC connection setup/teardown to `calendard` and `remindd` on every tool call.
final class SharedEventKitStore: @unchecked Sendable {
    static let shared = SharedEventKitStore()

    let eventStore: EKEventStore

    private init() {
        self.eventStore = EKEventStore()
    }

    enum AccessResult: Sendable {
        case granted
        case denied(String)
    }

    func ensureFullAccess(for entityType: EKEntityType) async -> AccessResult {
        let label = (entityType == .event) ? "Calendriers" : "Rappels"
        let status = EKEventStore.authorizationStatus(for: entityType)
        switch status {
        case .fullAccess:
            return .granted
        case .notDetermined:
            do {
                let granted: Bool
                if entityType == .event {
                    granted = try await eventStore.requestFullAccessToEvents()
                } else {
                    granted = try await eventStore.requestFullAccessToReminders()
                }
                return granted
                    ? .granted
                    : .denied("Accès aux \(label) macOS refusé par l'utilisateur.")
            } catch {
                return .denied("Erreur lors de la demande d'accès aux \(label) : \(error.localizedDescription)")
            }
        case .writeOnly:
            return .denied("Accès complet requis dans Réglages Système > Confidentialité et sécurité > \(label).")
        case .denied, .restricted:
            return .denied("Accès aux \(label) refusé ou restreint. Autorisez MacP dans Réglages Système > Confidentialité et sécurité > \(label).")
        @unknown default:
            return .denied("Statut d'autorisation EventKit (\(label)) inconnu.")
        }
    }
}
