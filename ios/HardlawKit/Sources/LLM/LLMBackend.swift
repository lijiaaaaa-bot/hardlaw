import Foundation

// MARK: - LLMBackend

/// Protocol for pluggable LLM judge backends.
/// Mirrors Python `hardlaw.llm.LLMBackend` Protocol.
///
/// ## Available Backends
///
/// | Backend | Description | Latency | Requirements |
/// |---------|-------------|---------|--------------|
/// | ``RuleBasedLLM`` | Deterministic rule engine | <1ms | None |
/// | ``FailSafeLLM`` | Primary backend, fallback on error | primary-dependent | primary + fallback |
///
/// ## Creating a New Backend
///
/// Conform to this protocol with an `actor` for thread safety. The `judge(_:)`
/// method receives a full judgment prompt (including case data, statutes, prior
/// gaps, and the output contract) and must return raw text that
/// `VerdictParser.parse()` can handle — a JSON verdict object followed by a
/// terminal token ("Refuted" or "Not Refuted").
///
/// Errors thrown from `judge(_:)` are caught by `Court.invokeJudge(ctx:step:)`
/// and result in a fail-closed verdict (`refuted: true, blocking: true`).
public protocol LLMBackend: Sendable {
    /// Submit a judgment prompt and receive raw LLM output.
    /// The only async point in the entire hardlaw pipeline.
    func judge(_ prompt: String) async throws -> String
}

// MARK: - FailSafeLLM

/// Fallback wrapper: tries a primary backend and transparently re-routes to a
/// fallback backend when the primary throws (e.g. an MLX model that fails to
/// load or run). Keeps `judge(_:)` from propagating errors, so the Court
/// pipeline always receives a verdict — while `fallbackCount` lets callers
/// surface a user-facing notice that degradation happened.
public actor FailSafeLLM: LLMBackend {
    private let primary: any LLMBackend
    private let fallback: any LLMBackend

    /// Number of `judge` calls that fell back to `fallback` (0 while the
    /// primary backend succeeds).
    public private(set) var fallbackCount: Int = 0

    public init(primary: any LLMBackend, fallback: any LLMBackend) {
        self.primary = primary
        self.fallback = fallback
    }

    public func judge(_ prompt: String) async throws -> String {
        do {
            return try await primary.judge(prompt)
        } catch {
            fallbackCount += 1
            print("[FailSafeLLM] Primary backend failed (\(error.localizedDescription)); using fallback.")
            return try await fallback.judge(prompt)
        }
    }
}


