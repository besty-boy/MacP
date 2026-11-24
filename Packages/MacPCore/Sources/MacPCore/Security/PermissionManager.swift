import Foundation

/// Risk / sensitivity tier of an MCP tool.
public enum ToolSensitivity: String, Sendable, Codable {
    /// Read-only, non-personal telemetry (e.g. CPU/RAM/battery, running app names).
    case standard
    /// Accesses user data or triggers system actions; defaults to prompt on first use.
    case sensitive
    /// High-privilege capability (Screen capture, AppleScript/JXA); defaults to ALWAYS prompt.
    case critical

    public var defaultPolicy: ToolPermissionPolicy {
        switch self {
        case .standard: return .automatic
        case .sensitive: return .askOnce
        case .critical: return .alwaysAsk
        }
    }
}

/// Request metadata shown to the user when asking for consent.
public struct ToolPermissionRequest: Sendable, Equatable {
    public let toolName: String
    public let toolDisplayName: String
    public let sensitivity: ToolSensitivity
    public let policy: ToolPermissionPolicy
    public let reason: String
    public let clientName: String
    public let argumentsSummary: String
    public let argumentsDetail: String

    public init(
        toolName: String,
        toolDisplayName: String,
        sensitivity: ToolSensitivity = .sensitive,
        policy: ToolPermissionPolicy = .askOnce,
        reason: String,
        clientName: String,
        argumentsSummary: String,
        argumentsDetail: String? = nil
    ) {
        self.toolName = toolName
        self.toolDisplayName = toolDisplayName
        self.sensitivity = sensitivity
        self.policy = policy
        self.reason = reason
        self.clientName = clientName
        self.argumentsSummary = argumentsSummary
        self.argumentsDetail = argumentsDetail ?? argumentsSummary
    }
}

/// User decision from a native macOS permission dialog.
public enum ToolPermissionDecision: String, Sendable, Equatable {
    case allowOnce
    case allowFor15Minutes
    case allowAlways
    case deny
}

/// Abstraction for prompting the user (implemented via `NSAlert` in the macOS app, or mocked in tests).
public protocol PermissionPrompter: Sendable {
    func requestPermission(for request: ToolPermissionRequest) async -> ToolPermissionDecision
}

/// Non-interactive prompter useful for headless/CLI fallback or tests.
public struct StaticPermissionPrompter: PermissionPrompter {
    private let decision: ToolPermissionDecision

    public init(decision: ToolPermissionDecision) {
        self.decision = decision
    }

    public func requestPermission(for request: ToolPermissionRequest) async -> ToolPermissionDecision {
        decision
    }
}

/// Coordinates permission checks, persisted grants, timed 15-minute leases, and strictly serialized user prompts.
/// Uses an explicit FIFO async lock to prevent Swift actor reentrancy from stacking concurrent `NSAlert` dialogs.
public actor PermissionManager {
    public static let temporaryGrantDuration: TimeInterval = 15 * 60

    private let settings: ToolSettingsStore
    private let prompter: any PermissionPrompter
    private var temporaryGrants: [String: Date] = [:]

    // Explicit prompt serialization across `await prompter.requestPermission(...)` suspension points.
    private var isPrompting = false
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []

    public init(settings: ToolSettingsStore, prompter: any PermissionPrompter) {
        self.settings = settings
        self.prompter = prompter
    }

    /// Ensures the caller is allowed to execute the tool.
    /// Strictly serializes interactive consent prompts and re-evaluates newly granted leases/always-allow flags.
    public func authorize(
        toolName: String,
        toolDisplayName: String,
        sensitivity: ToolSensitivity,
        reason: String,
        clientName: String,
        argumentsSummary: String,
        argumentsDetail: String? = nil
    ) async -> Bool {
        if let immediate = checkCachedGrant(toolName: toolName, sensitivity: sensitivity) {
            return immediate
        }

        await acquirePromptTurn()
        defer { releasePromptTurn() }

        // If the MCP request was cancelled while waiting for a prior prompt, deny without showing a stale dialog.
        if Task.isCancelled {
            return false
        }

        // Re-check after acquiring the prompt turn: an earlier queued call may have granted 15m or Always Allow.
        if let cached = checkCachedGrant(toolName: toolName, sensitivity: sensitivity) {
            return cached
        }

        let policy = settings.permissionPolicy(
            for: toolName,
            defaultPolicy: sensitivity.defaultPolicy
        )

        let request = ToolPermissionRequest(
            toolName: toolName,
            toolDisplayName: toolDisplayName,
            sensitivity: sensitivity,
            policy: policy,
            reason: reason,
            clientName: clientName,
            argumentsSummary: argumentsSummary,
            argumentsDetail: argumentsDetail ?? argumentsSummary
        )

        let decision = await prompter.requestPermission(for: request)
        switch decision {
        case .allowOnce:
            return true
        case .allowFor15Minutes:
            if policy != .alwaysAsk {
                temporaryGrants[toolName] = Date().addingTimeInterval(Self.temporaryGrantDuration)
            }
            return true
        case .allowAlways:
            if policy != .alwaysAsk {
                settings.setAlwaysAllowed(toolName, allowed: true)
            }
            return true
        case .deny:
            return false
        }
    }

    /// Returns active temporary grant expiration dates (filtering expired entries).
    public func activeTemporaryGrants(now: Date = Date()) -> [String: Date] {
        temporaryGrants = temporaryGrants.filter { $0.value > now }
        return temporaryGrants
    }

    public func revokeTemporaryGrant(toolName: String) {
        temporaryGrants.removeValue(forKey: toolName)
    }

    public func revokeAlwaysAllowed(toolName: String) {
        settings.setAlwaysAllowed(toolName, allowed: false)
        temporaryGrants.removeValue(forKey: toolName)
    }

    public func revokeAllGrants(for toolNames: [String]) {
        settings.revokeAllPermissions(for: toolNames)
        temporaryGrants.removeAll()
    }

    // MARK: - Helpers

    private func checkCachedGrant(toolName: String, sensitivity: ToolSensitivity) -> Bool? {
        let policy = settings.permissionPolicy(
            for: toolName,
            defaultPolicy: sensitivity.defaultPolicy
        )

        switch policy {
        case .automatic:
            return true
        case .askOnce:
            if settings.isAlwaysAllowed(toolName) {
                return true
            }
            if let expiry = temporaryGrants[toolName], expiry > Date() {
                return true
            } else {
                temporaryGrants.removeValue(forKey: toolName)
                return nil
            }
        case .alwaysAsk:
            return nil
        }
    }

    private func acquirePromptTurn() async {
        if !isPrompting {
            isPrompting = true
            return
        }
        await withCheckedContinuation { continuation in
            promptWaiters.append(continuation)
        }
    }

    private func releasePromptTurn() {
        if !promptWaiters.isEmpty {
            let next = promptWaiters.removeFirst()
            next.resume()
        } else {
            isPrompting = false
        }
    }
}
