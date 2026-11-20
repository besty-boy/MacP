import AppKit
import Foundation
import MacPCore

/// Presents a native macOS `NSAlert` consent dialog whenever an AI client invokes
/// a sensitive or critical macOS tool.
struct NativePermissionPrompter: PermissionPrompter {
    func requestPermission(for request: ToolPermissionRequest) async -> ToolPermissionDecision {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            let isStrict = (request.policy == .alwaysAsk || request.sensitivity == .critical)
            alert.alertStyle = isStrict ? .warning : .informational

            let symbolName = isStrict ? "exclamationmark.shield.fill" : "shield.lefthalf.filled"
            if let shield = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "Autorisation MacP"
            ) {
                let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
                alert.icon = shield.withSymbolConfiguration(config) ?? shield
            }

            alert.messageText = isStrict
                ? "Action sensible : « \(request.toolDisplayName) »"
                : "Autoriser « \(request.toolDisplayName) » ?"

            let formattedArgs = request.argumentsSummary.count > 260
                ? String(request.argumentsSummary.prefix(257)) + "..."
                : request.argumentsSummary

            alert.informativeText = """
            \(request.reason)

            Client IA : \(request.clientName)
            Outil : \(request.toolName)
            Paramètres : \(formattedArgs)
            """

            if isStrict {
                // Critical / Always-Ask tools never allow permanent caching from the prompt.
                let allowOnce = alert.addButton(withTitle: "Autoriser cette fois")
                allowOnce.keyEquivalent = "\r"

                let deny = alert.addButton(withTitle: "Refuser")
                deny.keyEquivalent = "\u{1b}"

                return alert.runModal() == .alertFirstButtonReturn ? .allowOnce : .deny
            } else {
                let allowOnce = alert.addButton(withTitle: "Autoriser cette fois")
                allowOnce.keyEquivalent = "\r"

                let allow15m = alert.addButton(withTitle: "Autoriser 15 min")
                allow15m.keyEquivalent = ""

                let allowAlways = alert.addButton(withTitle: "Toujours autoriser")
                allowAlways.keyEquivalent = ""

                let deny = alert.addButton(withTitle: "Refuser")
                deny.keyEquivalent = "\u{1b}"

                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    return .allowOnce
                case .alertSecondButtonReturn:
                    return .allowFor15Minutes
                case .alertThirdButtonReturn:
                    return .allowAlways
                default:
                    return .deny
                }
            }
        }
    }
}
