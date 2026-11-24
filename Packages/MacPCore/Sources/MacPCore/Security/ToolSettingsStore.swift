import Foundation
import os

/// Per-tool user-configurable approval policy.
public enum ToolPermissionPolicy: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Execute without prompting (recommended for read-only telemetry).
    case automatic
    /// Prompt on first use; allows remembering "Always Allow" or 15-minute window.
    case askOnce
    /// Prompt on EVERY call; never persists "Always Allow".
    case alwaysAsk

    public var id: String { rawValue }

    public var frenchLabel: String {
        switch self {
        case .automatic: return "Automatique"
        case .askOnce: return "Demander 1x"
        case .alwaysAsk: return "Toujours demander"
        }
    }
}

/// Curated tool activation presets to balance capabilities and LLM context-window token cost.
public enum ToolPreset: String, Sendable, CaseIterable, Identifiable {
    /// Minimal 5-tool footprint (~65% fewer schema tokens sent per LLM turn).
    case eco
    /// Daily productivity tools (Calendar, Reminders, Clipboard, Spotlight, Shortcuts, Stats).
    case productivity
    /// All 17 native macOS tools enabled.
    case full

    public var id: String { rawValue }

    public var frenchTitle: String {
        switch self {
        case .eco: return "Éco"
        case .productivity: return "Productivité"
        case .full: return "Complet"
        }
    }

    public var frenchHelp: String {
        switch self {
        case .eco: return "5 outils essentiels — empreinte minimale en tokens LLM"
        case .productivity: return "Outils Productivité Apple + Stats Système (sans Vision/AppleScript)"
        case .full: return "Active les 17 outils macOS natifs"
        }
    }

    public func isToolIncluded(_ toolName: String, category: ToolCategory) -> Bool {
        switch self {
        case .eco:
            return Self.ecoToolNames.contains(toolName)
        case .productivity:
            return category == .productivity || toolName == "macos_system_stats"
        case .full:
            return true
        }
    }

    private static let ecoToolNames: Set<String> = [
        "macos_system_stats",
        "macos_list_running_apps",
        "macos_read_clipboard",
        "macos_write_clipboard",
        "macos_spotlight_search"
    ]
}

/// Persists per-tool enable/disable flags, approval policies, global Shield Mode,
/// and "always allow" permission grants in `UserDefaults`.
public final class ToolSettingsStore: @unchecked Sendable {
    public static let defaultSuiteName = "com.macp.bridge.preferences"

    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock()
    private let enabledPrefix = "tool.enabled."
    private let alwaysAllowedPrefix = "tool.alwaysAllowed."
    private let policyPrefix = "tool.policy."
    private let shieldModeKey = "global.shieldModeActive"

    public init(suiteName: String? = ToolSettingsStore.defaultSuiteName) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
    }

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
    }

    /// Global panic switch ("Mode Bouclier") that immediately blocks all AI tool/resource execution.
    public var isShieldModeActive: Bool {
        get {
            lock.withLock { defaults.bool(forKey: shieldModeKey) }
        }
        set {
            lock.withLock { defaults.set(newValue, forKey: shieldModeKey) }
        }
    }

    /// Returns whether a tool is enabled. Defaults to `true` when never configured.
    public func isToolEnabled(_ toolName: String) -> Bool {
        lock.withLock {
            let key = enabledPrefix + toolName
            guard defaults.object(forKey: key) != nil else {
                return true
            }
            return defaults.bool(forKey: key)
        }
    }

    public func setToolEnabled(_ toolName: String, enabled: Bool) {
        lock.withLock {
            defaults.set(enabled, forKey: enabledPrefix + toolName)
        }
    }

    public func setToolsEnabled(_ updates: [String: Bool]) {
        lock.withLock {
            for (name, enabled) in updates {
                defaults.set(enabled, forKey: enabledPrefix + name)
            }
        }
    }

    /// Applies a token-economy preset across all provided tools in one atomic lock pass.
    public func applyPreset(_ preset: ToolPreset, to tools: [MCPToolMetadata]) {
        lock.withLock {
            for tool in tools {
                let enabled = preset.isToolIncluded(tool.name, category: tool.category)
                defaults.set(enabled, forKey: enabledPrefix + tool.name)
            }
        }
    }

    /// Returns the effective permission policy for a tool, falling back to its recommended default.
    public func permissionPolicy(
        for toolName: String,
        defaultPolicy: ToolPermissionPolicy
    ) -> ToolPermissionPolicy {
        lock.withLock {
            guard let raw = defaults.string(forKey: policyPrefix + toolName),
                  let parsed = ToolPermissionPolicy(rawValue: raw) else {
                return defaultPolicy
            }
            return parsed
        }
    }

    public func setPermissionPolicy(_ toolName: String, policy: ToolPermissionPolicy) {
        lock.withLock {
            defaults.set(policy.rawValue, forKey: policyPrefix + toolName)
            if policy == .alwaysAsk {
                defaults.set(false, forKey: alwaysAllowedPrefix + toolName)
            }
        }
    }

    /// Returns whether the user previously chose "Always Allow" for a tool.
    public func isAlwaysAllowed(_ toolName: String) -> Bool {
        lock.withLock {
            defaults.bool(forKey: alwaysAllowedPrefix + toolName)
        }
    }

    public func setAlwaysAllowed(_ toolName: String, allowed: Bool) {
        lock.withLock {
            defaults.set(allowed, forKey: alwaysAllowedPrefix + toolName)
        }
    }

    /// Revokes all persisted "Always Allow" grants so future calls prompt again.
    public func revokeAllPermissions(for toolNames: [String]) {
        lock.withLock {
            for name in toolNames {
                defaults.removeObject(forKey: alwaysAllowedPrefix + name)
            }
        }
    }
}
