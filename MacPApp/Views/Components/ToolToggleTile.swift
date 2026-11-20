import MacPCore
import SwiftUI

/// Rich Bento row controlling an individual MCP tool's toggle, approval policy, and active permission grant.
struct ToolToggleTile: View {
    let tool: MCPToolMetadata
    let isEnabled: Bool
    let policy: ToolPermissionPolicy
    let isAlwaysAllowed: Bool
    let leaseMinutesRemaining: Int?
    let onToggle: (Bool) -> Void
    let onPolicyChange: (ToolPermissionPolicy) -> Void
    let onRevokePermission: () -> Void

    private var iconTint: Color {
        guard isEnabled else { return .secondary }
        switch tool.category {
        case .productivity: return .blue
        case .workspace: return .teal
        case .vision: return .purple
        case .automation: return .orange
        }
    }

    var body: some View {
        BentoCard(cornerRadius: 14, padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(iconTint.opacity(isEnabled ? 0.16 : 0.08))
                            .frame(width: 30, height: 30)
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(iconTint)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(tool.displayName)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(isEnabled ? .primary : .secondary)
                                .lineLimit(1)
                            if tool.sensitivity == .critical {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                    .help("Outil critique : confirmation recommandée à chaque appel")
                            }
                        }
                        Text(tool.shortSubtitle)
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isEnabled },
                            set: { onToggle($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                // Governance & Permission Bar
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let mins = leaseMinutesRemaining {
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                                .font(.system(size: 9))
                            Text("\(mins)m")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(.blue)
                        .onTapGesture(perform: onRevokePermission)
                        .help("Autorisation temporaire active — cliquer pour révoquer")
                    } else if isAlwaysAllowed && policy == .askOnce {
                        Button(action: onRevokePermission) {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 9))
                                Text("Autorisé")
                                    .font(.system(size: 9.5, weight: .medium))
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14), in: Capsule())
                            .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Cliquer pour révoquer « Toujours autoriser »")
                    }

                    Menu {
                        ForEach(ToolPermissionPolicy.allCases) { option in
                            Button {
                                onPolicyChange(option)
                            } label: {
                                HStack {
                                    Text(option.frenchLabel)
                                    if option == policy {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: policyIcon)
                                .font(.system(size: 9))
                            Text(policy.frenchLabel)
                                .font(.system(size: 9.5, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7.5))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(policyColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(policyColor)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .opacity(isEnabled ? 1.0 : 0.68)
        }
    }

    private var policyIcon: String {
        switch policy {
        case .automatic: return "checkmark.shield"
        case .askOnce: return "lock.shield"
        case .alwaysAsk: return "hand.raised.fill"
        }
    }

    private var policyColor: Color {
        switch policy {
        case .automatic: return .secondary
        case .askOnce: return .orange
        case .alwaysAsk: return .red
        }
    }
}
