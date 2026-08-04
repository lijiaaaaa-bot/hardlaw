import Foundation

// MARK: - Confidence

/// Confidence level for a judgment.
/// Mirrors Python `hardlaw.verdict.Confidence` (str-valued enum).
public enum Confidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low, unknown

    /// Parse case-insensitive string, falling back to `.unknown`.
    /// Mirrors Python `Confidence.parse`.
    public static func parse(_ s: String) -> Confidence {
        Confidence(rawValue: s.lowercased()) ?? .unknown
    }
}
