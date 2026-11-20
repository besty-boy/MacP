import MacPCore
import SwiftUI

/// Clients & macOS Integration tab: 1-click setup for Antigravity, Claude Desktop, and Cursor
/// plus native Launch at Login (`SMAppService`) and security controls.
struct ClientsSettingsView: View {
    let appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = appState.clientActionBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(banner)
                            .font(.system(.caption))
                            .foregroundStyle(.primary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // 1-Click MCP Clients Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Configuration 1-clic des clients IA")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)

                    ForEach(SupportedMCPClient.allCases) { client in
                        ClientSetupCard(
                            client: client,
                            status: appState.clientStatuses[client] ?? .notConfigured,
                            onInstall: { appState.configureClient(client) },
                            onRemove: { appState.removeClientConfig(client) }
                        )
                    }
                }

                // System & Security Card
                VStack(alignment: .leading, spacing: 8) {
                    Text("Système & Sécurité")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)

                    BentoCard(cornerRadius: 16, padding: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Lancer au démarrage")
                                        .font(.system(.subheadline, weight: .semibold))
                                    Text(appState.launchAtLoginMessage ?? "SMAppService natif")
                                        .font(.system(.caption2))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { appState.launchAtLoginEnabled },
                                        set: { appState.setLaunchAtLogin($0) }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            }

                            Divider()

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Autorisations mémorisées")
                                        .font(.system(.subheadline, weight: .semibold))
                                    Text("\(appState.activeGrantsCount) accès permanent(s) ou temporaire(s)")
                                        .font(.system(.caption2))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Tout révoquer") {
                                    appState.revokeAllPermissions()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(appState.activeGrantsCount == 0)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Socket Unix local (0600)")
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(appState.snapshot.socketPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 330)
    }
}

private struct ClientSetupCard: View {
    let client: SupportedMCPClient
    let status: ClientConfigStatus
    let onInstall: () -> Void
    let onRemove: () -> Void

    private var statusColor: Color {
        switch status {
        case .configured: return .green
        case .outdatedPath: return .orange
        case .notConfigured: return .secondary
        case .error: return .red
        }
    }

    var body: some View {
        BentoCard(cornerRadius: 14, padding: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: client.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor == .secondary ? Color.accentColor : statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(client.displayName)
                            .font(.system(.subheadline, weight: .semibold))
                        Text(status.label)
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(statusColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(statusColor)
                    }
                    Text(client.configFileURL.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path,
                        with: "~"
                    ))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                switch status {
                case .configured:
                    Button("Retirer", action: onRemove)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                case .outdatedPath:
                    Button("Mettre à jour", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                case .notConfigured, .error:
                    Button("Installer", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
            }
        }
    }
}
