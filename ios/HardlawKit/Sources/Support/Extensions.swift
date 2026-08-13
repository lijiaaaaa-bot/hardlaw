import Foundation

// MARK: - String Extensions

/// Shared string helpers used across HardlawKit and HardlawApp.
/// Kept in one place so number extraction and similar utilities are not
/// re-implemented per file.
public extension String {

    /// Regex compiled once instead of per call — `numbers` is hot in
    /// verifySnippets and evidence cross-checks.
    private static let numbersRegex = try! NSRegularExpression(pattern: #"\d+\.?\d*"#)

    /// All decimal numbers (e.g. "7550", "93059.85") found in the string,
    /// in order of appearance. Matches `\d+\.?\d*`.
    var numbers: [String] {
        let range = NSRange(startIndex..., in: self)
        return Self.numbersRegex.matches(in: self, range: range).compactMap {
            Range($0.range, in: self).map { String(self[$0]) }
        }
    }
}
