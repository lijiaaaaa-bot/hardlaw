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

    /// Placeholder rules — replace with domain-specific rules for your use case.
    public static func defaultRules() -> [Rule] {
        [
            // Example: detect numbers mentioned as monetary amounts
            try! Rule(violationName: "amount_mismatch", pattern: #"\d+\.?\d*\s*元"#, severity: "low"),
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
            "confidence": "high",
            "blocking": "none",
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



