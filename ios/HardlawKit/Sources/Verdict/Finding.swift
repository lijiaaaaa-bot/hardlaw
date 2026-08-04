import Foundation

// MARK: - Finding

/// A specific finding (gap, bug, todo) within a verdict.
/// Mirrors Python `hardlaw.verdict.Finding`.
public struct Finding: Codable, Equatable, Sendable {
    /// Kind of finding: "bug", "gap", "todo".
    public var kind: String
    /// Location in the form "path:line".
    public var location: String
    /// Human-readable detail.
    public var detail: String

    public init(kind: String = "", location: String = "", detail: String = "") {
        self.kind = kind
        self.location = location
        self.detail = detail
    }

    /// Returns true if all three fields are blank.
    /// Mirrors Python `Finding.is_empty`.
    public var isEmpty: Bool {
        kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Fingerprint

/// SHA-256 fingerprint of gap findings for stall detection.
/// Mirrors Python `hardlaw.verdict.compute_fingerprint`.
public enum Fingerprint {
    /// Compute a stable SHA-256 fingerprint (first 16 hex chars) from a list of findings.
    /// Empty/non-gap findings are excluded. Tokens are `"kind:location:detail"`, sorted,
    /// joined with `"|"`, then hashed.
    /// Mirrors Python `compute_fingerprint(findings)`.
    public static func compute(findings: [Finding]) -> String {
        let nonEmpty = findings.filter { !$0.isEmpty }
        if nonEmpty.isEmpty { return "" }

        let tokens = nonEmpty.map { "\($0.kind):\($0.location):\($0.detail)" }.sorted()
        let joined = tokens.joined(separator: "|")
        guard let data = joined.data(using: .utf8) else { return "" }

        let hash = Data(SHA256.hash(data: data))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// CryptoKit re-export
import CryptoKit
