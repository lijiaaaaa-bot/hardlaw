import Foundation

// MARK: - Auto-fill result types

/// Parsed result from a per-document auto-fill LLM response.
public struct AutoFillDocumentResult: Sendable {
    public let classification: String
    public let proofContent: String
    public let proofPurpose: String
    public let numbersCited: [String]

    /// Whether this result is empty (parse failure or empty response).
    public var isEmpty: Bool {
        proofContent.isEmpty && proofPurpose.isEmpty
    }
}

/// Parsed result from a metadata-extraction LLM response.
public struct AutoFillMetadataResult: Sendable {
    public let caseName: String
    public let applicant: String
    public let respondent: String
    public let claims: [String]

    public var isEmpty: Bool {
        caseName.isEmpty && applicant.isEmpty && respondent.isEmpty && claims.isEmpty
    }
}

// MARK: - Parser

/// 3-tier JSON parser for auto-fill LLM responses.
/// Mirrors `VerdictParser`'s fail-closed design — never throws.
public enum AutoFillParser {

    // MARK: - Document parsing

    /// Parse a per-document auto-fill response.
    /// Returns nil when the response is unparseable (fail-closed).
    public static func parseDocument(_ raw: String) -> AutoFillDocumentResult? {
        guard let json = extractJSON(from: raw) else { return nil }

        let classification = json["classification"] as? String ?? ""
        let proofContent = json["proof_content"] as? String ?? ""
        let proofPurpose = json["proof_purpose"] as? String ?? ""
        let numbersCited = json["numbers_cited"] as? [String] ?? []

        // At minimum, we need proof_content to be useful
        guard !proofContent.isEmpty else { return nil }

        return AutoFillDocumentResult(
            classification: classification,
            proofContent: proofContent,
            proofPurpose: proofPurpose,
            numbersCited: numbersCited
        )
    }

    // MARK: - Metadata parsing

    /// Parse a metadata-extraction response.
    public static func parseMetadata(_ raw: String) -> AutoFillMetadataResult? {
        guard let json = extractJSON(from: raw) else { return nil }

        let caseName = json["case_name"] as? String ?? ""
        let applicant = json["applicant"] as? String ?? ""
        let respondent = json["respondent"] as? String ?? ""
        let claims = json["claims"] as? [String] ?? []

        // At minimum, we need case_name or applicant to be useful
        guard !caseName.isEmpty || !applicant.isEmpty else { return nil }

        return AutoFillMetadataResult(
            caseName: caseName.trimmingCharacters(in: .whitespacesAndNewlines),
            applicant: applicant.trimmingCharacters(in: .whitespacesAndNewlines),
            respondent: respondent.trimmingCharacters(in: .whitespacesAndNewlines),
            claims: claims.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
    }

    // MARK: - JSON extraction (3-tier fallback)

    /// 3-tier extraction: code fences → bare JSON → nil.
    /// Never throws — mirrors `VerdictParser._extractJSON`.
    private static func extractJSON(from raw: String) -> [String: Any]? {
        // Tier 1: JSON in markdown code fences
        if let json = tryExtractCodeFence(raw) { return json }

        // Tier 2: bare JSON object anywhere in the text
        if let json = tryExtractBareJSON(raw) { return json }

        // Tier 3: failure
        return nil
    }

    private static func tryExtractCodeFence(_ raw: String) -> [String: Any]? {
        let fencePattern = try! NSRegularExpression(
            pattern: "```(?:json)?\\s*\\n([\\s\\S]*?)\\n```",
            options: []
        )
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = fencePattern.matches(in: raw, options: [], range: nsRange)
        for match in matches {
            if let range = Range(match.range(at: 1), in: raw) {
                let jsonStr = String(raw[range])
                if let dict = parseJSONDict(jsonStr) { return dict }
            }
        }
        return nil
    }

    private static func tryExtractBareJSON(_ raw: String) -> [String: Any]? {
        // Find the first `{` and try to parse from there
        guard let start = raw.firstIndex(of: "{") else { return nil }

        // Try successively shorter substrings (balanced-brace search)
        var depth = 0
        for (offset, ch) in raw[start...].enumerated() {
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let endIndex = raw.index(start, offsetBy: offset + 1)
                    let jsonStr = String(raw[start..<endIndex])
                    if let dict = parseJSONDict(jsonStr) { return dict }
                    break
                }
            }
        }
        return nil
    }

    private static func parseJSONDict(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            return obj as? [String: Any]
        } catch {
            return nil
        }
    }
}
