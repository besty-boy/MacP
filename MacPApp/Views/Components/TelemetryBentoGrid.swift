import MacPCore
import SwiftUI

/// Live 2x2 Bento Grid showing real-time CPU, RAM, Battery/Disk telemetry and MCP Bridge summary.
struct TelemetryBentoGrid: View {
    let stats: SystemStatsTool.SystemStatsPayload?
    let snapshot: BridgeSnapshot
    let activeToolsCount: Int
    let totalToolsCount: Int
    let resourcesCount: Int
    let promptsCount: Int

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            // Card 1: Live CPU Ring
            BentoCard(cornerRadius: 16, padding: 12) {
                HStack(spacing: 10) {
                    let cpuPct = stats?.cpu.usagePercent ?? 0
                    TelemetryRingView(
                        progress: cpuPct / 100.0,
                        color: cpuPct > 80 ? .red : (cpuPct > 55 ? .orange : .cyan),
                        centerText: stats?.cpu.usagePercent.map { "\(Int($0.rounded()))%" } ?? "—"
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CPU")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(stats.map { "\($0.cpu.logicalCores) cœurs" } ?? "Mesure...")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let load1 = stats?.cpu.loadAverage1m {
                            Text(String(format: "Charge %.2f", load1))
                                .font(.system(.caption2))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // Card 2: Live Memory Ring
            BentoCard(cornerRadius: 16, padding: 12) {
                HStack(spacing: 10) {
                    let memPct = stats?.memory.usagePercent ?? 0
                    TelemetryRingView(
                        progress: memPct / 100.0,
                        color: memPct > 85 ? .red : (memPct > 65 ? .orange : .indigo),
                        centerText: stats.map { "\(Int($0.memory.usagePercent.rounded()))%" } ?? "—"
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mémoire")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let mem = stats?.memory {
                            Text(String(format: "%.1f / %.0f Go", mem.usedGB, mem.totalGB))
                                .font(.system(.subheadline, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Text(String(format: "%.1f Go libre", mem.freeGB))
                                .font(.system(.caption2))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Mesure...")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // Card 3: Battery (MacBook) or SSD Storage (Desktop Mac)
            BentoCard(cornerRadius: 16, padding: 12) {
                if let battery = stats?.battery, battery.hasBattery, let pct = battery.percentage {
                    HStack(spacing: 10) {
                        TelemetryRingView(
                            progress: Double(pct) / 100.0,
                            color: pct < 20 ? .red : (battery.isCharging == true ? .green : .mint),
                            centerText: "\(pct)%"
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Batterie", systemImage: battery.isCharging == true ? "bolt.fill" : "battery.100")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(battery.isCharging == true ? "En charge" : battery.powerSource)
                                .font(.system(.subheadline, weight: .semibold))
                                .lineLimit(1)
                            if let mins = battery.timeRemainingMinutes {
                                Text("\(mins / 60)h\(String(format: "%02d", mins % 60)) restant")
                                    .font(.system(.caption2))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 10) {
                        let diskPct = stats?.disk?.usagePercent ?? 0
                        TelemetryRingView(
                            progress: diskPct / 100.0,
                            color: diskPct > 88 ? .orange : .teal,
                            centerText: stats?.disk.map { "\(Int($0.usagePercent.rounded()))%" } ?? "—"
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stockage")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
                            if let disk = stats?.disk {
                                Text(String(format: "%.0f Go libres", disk.availableGB))
                                    .font(.system(.subheadline, weight: .semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                Text(String(format: "sur %.0f Go", disk.totalGB))
                                    .font(.system(.caption2))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("Secteur AC")
                                    .font(.system(.subheadline, weight: .semibold))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            // Card 4: MCP Capabilities Summary
            BentoCard(cornerRadius: 16, padding: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Pont MCP", systemImage: "cpu")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(activeToolsCount)/\(totalToolsCount)")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }

                    Text("\(snapshot.connectedClients.count) client\(snapshot.connectedClients.count > 1 ? "s" : "") actif\(snapshot.connectedClients.count > 1 ? "s" : "")")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(resourcesCount) ressources • \(promptsCount) prompts")
                        .font(.system(.caption2))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
