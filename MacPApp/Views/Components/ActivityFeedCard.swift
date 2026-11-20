import MacPCore
import SwiftUI

/// Minimalist visual log of the last 5 processed MCP requests inside the Bento Dashboard.
struct ActivityFeedCard: View {
    let entries: [AuditEntry]
    let onOpenFullLog: () -> Void

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        BentoCard(cornerRadius: 16, padding: 13) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Dernières requêtes", systemImage: "waveform.path.ecg")
                        .font(.system(.subheadline, design: .default, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Button(action: onOpenFullLog) {
                        HStack(spacing: 3) {
                            Text("Inspecteur")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.system(.caption, design: .default, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                if entries.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                        Text("Aucune action IA enregistrée pour le moment.")
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                } else {
                    VStack(spacing: 5) {
                        ForEach(entries.prefix(5)) { entry in
                            Button(action: onOpenFullLog) {
                                ActivityRow(entry: entry, timeFormatter: Self.timeFormatter)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let entry: AuditEntry
    let timeFormatter: RelativeDateTimeFormatter

    private var iconName: String {
        switch entry.outcome {
        case .success: return "checkmark.circle.fill"
        case .denied: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch entry.outcome {
        case .success: return .green
        case .denied: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.toolName ?? entry.method)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(entry.clientName) • \(entry.method)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(entry.durationMs) ms")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(timeFormatter.localizedString(for: entry.timestamp, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
