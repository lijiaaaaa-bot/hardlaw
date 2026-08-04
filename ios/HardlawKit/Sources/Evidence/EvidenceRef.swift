import Foundation

// MARK: - EvidenceRef

/// A citation of a specific piece of evidence.
/// Mirrors Python `hardlaw.evidence.EvidenceRef`.
public struct EvidenceRef: Codable, Equatable, Sendable {
    /// Which source document / artifact this comes from.
    public var source: String
    /// Where in the source (e.g. "line 5", "x:0.12,y:0.34").
    public var location: String
    /// The exact text snippet from the source.
    public var snippet: String
    /// Kind of evidence (default "text").
    public var kind: String

    public init(source: String, location: String = "", snippet: String = "", kind: String = "text") {
        self.source = source
        self.location = location
        self.snippet = snippet
        self.kind = kind
    }

    /// Returns true if the snippet is blank (trimmed).
    /// Mirrors Python `EvidenceRef.is_empty`.
    public var isEmpty: Bool {
        snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Serialize to plain dict (mirrors Python `to_dict`).
    public func toDict() -> [String: Any] {
        [
            "source": source,
            "location": location,
            "snippet": snippet,
            "kind": kind,
        ]
    }
}
