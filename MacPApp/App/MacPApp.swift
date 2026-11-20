import AppKit
import SwiftUI

final class MacPAppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep MacP strictly as a Menu Bar utility (no Dock icon).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

/// Native macOS Menu Bar SwiftUI application (launched by `MacPMain` when not in `--stdio` mode).
struct MacPMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MacPAppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        state.start()
        _appState = State(initialValue: state)
    }

    private var menuBarSymbol: String {
        if appState.isShieldModeActive {
            return "shield.slash.fill"
        }
        return appState.snapshot.isClientConnected
            ? "point.3.filled.connected.trianglepath.dotted"
            : "point.3.connected.trianglepath.dotted"
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(appState: appState)
                .onAppear {
                    appState.startLiveTelemetry()
                    appState.refreshClientStatuses()
                    appState.refreshLaunchAtLogin()
                    appDelegate.onTerminate = { [weak appState] in
                        Task { @MainActor in
                            appState?.stop()
                        }
                    }
                }
                .onDisappear {
                    appState.stopLiveTelemetry()
                }
        } label: {
            Label {
                Text("MacP")
            } icon: {
                Image(systemName: menuBarSymbol)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Journal d'audit MacP", id: "audit-log") {
            AuditLogSheetView(appState: appState)
                .frame(minWidth: 740, minHeight: 500)
        }
        .defaultSize(width: 840, height: 560)
        .windowResizability(.contentMinSize)
    }
}
