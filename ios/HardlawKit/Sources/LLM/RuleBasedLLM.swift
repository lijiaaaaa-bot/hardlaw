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

    /// Default labor-law domain rules for Chinese employment dispute cases.
    /// Each rule detects evidence-bearing keywords and reports a 'gap' finding
    /// when the corresponding evidence is missing from the case content.
    public static func defaultRules() -> [Rule] {
        [
            // 劳动关系成立：劳动合同 / 社保 / 公积金 / 参保
            try! Rule(violationName: "劳动关系成立", pattern: #"劳动合同|社保|公积金|参保"#, severity: "medium"),
            // 工资标准：工资表 / 应发工资 / 月工资 / 基本工资
            try! Rule(violationName: "工资标准", pattern: #"工资表|应发工资|月工资|基本工资"#, severity: "medium"),
            // 欠薪证据：拖欠 / 欠薪 / 未发放 / 行政处罚
            try! Rule(violationName: "欠薪证据", pattern: #"拖欠|欠薪|未发放|行政处罚"#, severity: "high"),
            // 混同用工：五建集团公章/财务/人事、持股比例
            try! Rule(violationName: "混同用工", pattern: #"五建集团.*公章|五建集团.*财务|五建集团.*人事|持股.*%"#, severity: "high"),
            // 解除程序：被迫解除 / 解除劳动关系 / EMS
            try! Rule(violationName: "解除程序", pattern: #"被迫解除|解除劳动关系|EMS"#, severity: "high"),
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
                    "severity": rule.severity,
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



