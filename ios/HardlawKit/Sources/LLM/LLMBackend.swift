import Foundation

// MARK: - LLMBackend

/// Protocol for pluggable LLM judge backends.
/// Mirrors Python `hardlaw.llm.LLMBackend` Protocol.
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

// MARK: - LLMError

public enum LLMError: Error, Sendable {
    case noBackendConfigured
    case modelLoadFailed(String)
    case inferenceError(String)
}
