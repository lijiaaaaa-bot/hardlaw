import Foundation

// MARK: - RuleBasedLLM

/// Deterministic LLM backend using regex rules — no model needed.
/// Produces Verdict-shaped JSON that exercises the full VerdictParser pipeline.
public actor RuleBasedLLM: LLMBackend {

    /// A single regex-based detection rule.
    public struct Rule: Sendable {
        public let violationName: String
        public let regex: NSRegularExpression
        public let severity: String

        public init(violationName: String, pattern: String, severity: String = "high") throws {
            self.violationName = violationName
            self.regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.severity = severity
        }
    }

    private let rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    /// Default rules: common banned content patterns.
    public static func defaultRules() -> [Rule] {
        [
            // Profanity detection (example patterns)
            try! Rule(violationName: "profanity", pattern: #"\b(damn|hell)\b"#, severity: "low"),
            // PII: credit card numbers
            try! Rule(violationName: "pii_leak", pattern: #"\b(?:\d[ -]?){13,16}\b"#, severity: "critical"),
            // PII: email addresses
            try! Rule(violationName: "pii_leak", pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, severity: "high"),
            // PII: phone numbers (loose)
            try! Rule(violationName: "pii_leak", pattern: #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#, severity: "medium"),
        ]
    }

    /// Judge content by applying all rules.
    /// Returns JSON string conforming to the Court's OUTPUT CONTRACT.
    public func judge(_ prompt: String) async throws -> String {
        // Extract case data from the markdown prompt
        // Look for the content section between "## CASE DATA" and next "##"
        let content = extractContentField(from: prompt, field: "content")
            ?? extractContentField(from: prompt, field: "ocr_frame")
            ?? prompt

        var findings: [[String: String]] = []
        var evidenceRefs: [[String: Any]] = []
        var violationNames: Set<String> = []

        for rule in rules {
            let range = NSRange(content.startIndex..., in: content)
            let matches = rule.regex.matches(in: content, options: [], range: range)
            for match in matches {
                guard let matchRange = Range(match.range, in: content) else { continue }
                let matchedText = String(content[matchRange])

                // Create finding
                findings.append([
                    "kind": "gap",
                    "location": "content:\(match.range.location)",
                    "detail": "\(rule.violationName): '\(matchedText)'",
                ])

                // Create evidence ref (snippet from actual content = always verifiable)
                evidenceRefs.append([
                    "source": "content",
                    "location": "offset:\(match.range.location)",
                    "snippet": matchedText,
                    "kind": "text",
                ])

                violationNames.insert(rule.violationName)
            }
        }

        // Build verdict JSON
        let refuted = !findings.isEmpty
        let finding = violationNames.joined(separator: ",").isEmpty ? "none" : violationNames.joined(separator: ",")

        let json: [String: Any] = [
            "finding": finding,
            "refuted": refuted,
            "confidence": refuted ? "high" : "high",
            "blocking": refuted ? "none" : "none",
            "evidence_refs": evidenceRefs,
            "reasoning": refuted
                ? "Rule-based detection found \(findings.count) violation(s)"
                : "No rule violations detected",
            "findings": findings,
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"

        // Append terminal tokens
        return """
        \(jsonStr)

        \(refuted ? "Refuted" : "Not Refuted")
        """
    }

    /// Extract a field value from the markdown prompt's case data section.
    private func extractContentField(from prompt: String, field: String) -> String? {
        let pattern = "### \(field)\\n([\\s\\S]*?)(?=\\n###|\\n##|\\Z)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let range = Range(match.range(at: 1), in: prompt) else {
            return nil
        }
        return String(prompt[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - CapabilityDetector

/// Detects device capabilities for LLM backends.
public enum CapabilityDetector {

    /// Check if on-device MLX LLM can run on this device.
    /// Requires iOS 17.0+ and sufficient memory.
    public static func canRunMLXLLM() -> Bool {
        // Memory check: need at least 4 GB for 0.5B model
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let minMemory: UInt64 = 3 * 1024 * 1024 * 1024 // 3 GB (conservative)
        return physicalMemory > minMemory
    }

    /// Get the recommended backend based on device capabilities.
    public static func recommendedBackend() -> RecommendedBackend {
        if canRunMLXLLM() {
            return .mlxLLM
        }
        return .ruleBased
    }
}

public enum RecommendedBackend: String, Sendable {
    case ruleBased = "Rule-Based"
    case mlxLLM = "On-Device MLX"
    case appleIntelligence = "Apple Intelligence"
}
