import Foundation

// MARK: - LLMBackend

/// Protocol for pluggable LLM judge backends.
/// Mirrors Python `hardlaw.llm.LLMBackend` Protocol.
///
/// ## Available Backends
///
/// | Backend | Description | Latency | Requirements |
/// |---------|-------------|---------|--------------|
/// | ``MockLLM`` | Scripted responses for testing | <1ms | None |
/// | ``RuleBasedLLM`` | Deterministic rule engine | <1ms | None |
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

// MARK: - MockLLM

/// Scripted LLM backend for testing.
/// Consumes scripted responses in order, then repeats the last/default pass response.
/// Mirrors Python `hardlaw.llm.MockLLM`.
public actor MockLLM: LLMBackend {
    /// Scripted responses consumed in order.
    private var responses: [String]
    /// Default pass response used when script is exhausted.
    private let defaultPassResponse: String
    /// Number of calls made.
    public private(set) var callCount: Int = 0
    /// Full prompt history for assertions.
    public private(set) var history: [String] = []

    public init(responses: [String] = []) {
        self.responses = responses
        self.defaultPassResponse = """
        {
            "finding": "none",
            "refuted": false,
            "confidence": "high",
            "blocking": "none",
            "evidence_refs": [],
            "reasoning": "No violations found (mock)",
            "findings": []
        }
        Refuted
        Not Refuted
        """
    }

    /// Get the next response (scripted or default).
    public func judge(_ prompt: String) async throws -> String {
        callCount += 1
        history.append(prompt)
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        return defaultPassResponse
    }
}


