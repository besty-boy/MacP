import MacPCore
import SwiftUI

/// Top header displaying MacP branding, live connection status pill, and quick Shield Mode panic switch.
struct StatusHeaderView: View {
    let snapshot: BridgeSnapshot
    let isShieldActive: Bool
    let onToggleShield: (Bool) -> Void

    private var statusColor: Color {
        if isShieldActive { return .orange }
        return snapshot.isClientConnected ? .green : .red
    }

    private var statusLabel: String {
        if isShieldActive { return "Bouclier" }
        if snapshot.isClientConnected {
            let count = snapshot.connectedClients.count
            return count == 1 ? "Connecté" : "\(count) clients"
        }
        return snapshot.isListening ? "En attente" : "Hors ligne"
    }

    private var subtitleText: String {
        if isShieldActive {
            return "Accès IA mis en pause"
        }
        if let firstClient = snapshot.connectedClients.first {
            let extra = snapshot.connectedClients.count - 1
            return extra > 0 ? "\(firstClient.displayLabel) +\(extra)" : firstClient.displayLabel
        }
        return "Pont MCP macOS natif • \(MacPVersion.short)"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isShieldActive
                                ? [Color.orange.opacity(0.28), Color.red.opacity(0.16)]
                                : [Color.accentColor.opacity(0.26), Color.cyan.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(
                    systemName: isShieldActive
                        ? "shield.slash.fill"
                        : "point.3.filled.connected.trianglepath.dotted"
                )
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isShieldActive ? Color.orange : Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("MacP")
                    .font(.system(.headline, design: .default, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitleText)
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Live status pill
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 4)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(statusColor.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(statusColor.opacity(0.28), lineWidth: 0.75))

            // Quick Shield Mode panic button
            Button {
                onToggleShield(!isShieldActive)
            } label: {
                Image(systemName: isShieldActive ? "shield.slash.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isShieldActive ? .white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        isShieldActive ? Color.orange : Color.primary.opacity(0.06),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help(
                isShieldActive
                    ? "Désactiver le Mode Bouclier et réautoriser les requêtes IA"
                    : "Activer le Mode Bouclier (bloquer immédiatement toutes les actions IA)"
            )
        }
    }
}
