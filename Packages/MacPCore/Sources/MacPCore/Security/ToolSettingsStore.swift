import Foundation

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

/// Persists per-tool enable/disable flags, approval policies, global Shield Mode,
/// and "always allow" permission grants in `UserDefaults`.
public final class ToolSettingsStore: @unchecked Sendable {
    public static let defaultSuiteName = "com.macp.bridge.preferences"

    private let defaults: UserDefaults
    private let lock = NSLock()
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
