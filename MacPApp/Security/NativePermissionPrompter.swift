import AppKit
import Foundation
import MacPCore

/// Presents a native macOS `NSAlert` consent dialog whenever an AI client invokes
/// a sensitive or critical macOS tool.
/// - Displays a scrollable monospace preview when arguments contain scripts or long payloads.
/// - Restores focus to the previously active app after dismissal so tools like `macos_capture_screen`
///   capture the user's real active window instead of MacP.
struct NativePermissionPrompter: PermissionPrompter {
    func requestPermission(for request: ToolPermissionRequest) async -> ToolPermissionDecision {
        await MainActor.run {
            let previousApp = NSWorkspace.shared.frontmostApplication
            let selfPID = ProcessInfo.processInfo.processIdentifier

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

            let detail = request.argumentsDetail
            let needsAccessoryPreview = detail.contains("\n") || detail.count > 120

            if needsAccessoryPreview {
                alert.informativeText = """
                \(request.reason)

                Client IA : \(request.clientName)
                Outil : \(request.toolName)
                """
                alert.accessoryView = makeScriptPreviewView(text: detail)
            } else {
                alert.informativeText = """
                \(request.reason)

                Client IA : \(request.clientName)
                Outil : \(request.toolName)
                Paramètres : \(detail)
                """
            }

            let decision: ToolPermissionDecision
            if isStrict {
                // Critical / Always-Ask tools never allow permanent caching from the prompt.
                let allowOnce = alert.addButton(withTitle: "Autoriser cette fois")
                allowOnce.keyEquivalent = "\r"

                let deny = alert.addButton(withTitle: "Refuser")
                deny.keyEquivalent = "\u{1b}"

                decision = alert.runModal() == .alertFirstButtonReturn ? .allowOnce : .deny
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
                    decision = .allowOnce
                case .alertSecondButtonReturn:
                    decision = .allowFor15Minutes
                case .alertThirdButtonReturn:
                    decision = .allowAlways
                default:
                    decision = .deny
                }
            }

            // Gently restore focus to the previous app so subsequent window captures target it cleanly.
            if let previousApp, previousApp.processIdentifier != selfPID {
                previousApp.activate()
            }

            return decision
        }
    }

    @MainActor
    private func makeScriptPreviewView(text: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 364, height: 120))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }
}
