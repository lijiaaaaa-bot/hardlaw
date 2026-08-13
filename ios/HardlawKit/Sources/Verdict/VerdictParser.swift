import Foundation

// MARK: - VerdictParser

/// Parses LLM judge output into a structured Verdict.
/// Three-tier fallback: JSON → terminal token → default-to-reject.
/// NEVER throws — mirrors Python exception-free design.
public enum VerdictParser {

    // MARK: - Terminal tokens

    static let terminalRefuted = "Refuted"
    static let terminalNotRefuted = "Not Refuted"

    // MARK: - Public API

    /// Parse raw LLM output into a Verdict. Never throws.
    /// Three-tier fallback identical to Python `VerdictParser.parse`.
    public static func parse(_ raw: String) -> Verdict {
        // Tier 1: Try to extract JSON
        if let jsonStr = extractJSON(from: raw),
           let data = jsonStr.data(using: .utf8) {
            do {
                let verdict = try JSONDecoder().decode(Verdict.self, from: data)
                return verdict
            } catch {
                // JSON parsing failed, fall through to tier 2
            }
        }

        // Tier 2: Terminal token
        if let verdict = parseTerminalToken(raw) {
            return verdict
        }

        // Tier 3: Default to reject
        return Verdict(
            finding: "parse_failure",
            refuted: true,
            confidence: .unknown,
            blocking: true,
            blockingKind: BlockingKind.contradiction,
            reasoning: "",
            fallbackNote: "verdict JSON missing AND terminal token unrecognised"
        )
    }

    // MARK: - JSON Extraction

    /// Extract JSON from LLM output. Tries markdown code fences first, then bare braces.
    /// Mirrors Python `VerdictParser._extract_json`.
    static func extractJSON(from raw: String) -> String? {
        // 1. Try markdown code fences: ```json ... ```
        let fencePattern = #"```(?:json)?\s*(\{.*?\})\s*```"#
        if let match = try? NSRegularExpression(pattern: fencePattern, options: [.dotMatchesLineSeparators])
            .firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let range = Range(match.range(at: 1), in: raw) {
            return String(raw[range])
        }

        // 2. Greedy bare `{...}` fallback — find first `{` and last `}`
        if let openBrace = raw.firstIndex(of: "{"),
           let closeBrace = raw.lastIndex(of: "}"),
           openBrace < closeBrace {
            let jsonCandidate = String(raw[openBrace...closeBrace])
            // Basic sanity: must contain enough structure
            if jsonCandidate.contains(#""finding""#) || jsonCandidate.contains(#""refuted""#) {
                return jsonCandidate
            }
        }

        return nil
    }

    // MARK: - Terminal Token Parser

    /// Parse "Refuted" or "Not Refuted" terminal tokens.
    /// Mirrors Python `VerdictParser._parse_terminal_token`.
    static func parseTerminalToken(_ raw: String) -> Verdict? {
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            // Skip code fence lines
            if line.hasPrefix("```") { continue }
            // Remove trailing backticks and punctuation
            var cleaned = line
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))

            if cleaned == terminalRefuted {
                return Verdict(
                    finding: "none",
                    refuted: true,
                    confidence: .unknown,
                    fallbackNote: "verdict JSON missing/malformed; used terminal token"
                )
            } else if cleaned == terminalNotRefuted {
                return Verdict(
                    finding: "unknown",
                    refuted: false,
                    confidence: .unknown,
                    fallbackNote: "verdict JSON missing/malformed; used terminal token"
                )
            }
        }
        return nil
    }
}
