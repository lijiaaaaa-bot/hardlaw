import Foundation

// MARK: - String Extensions

/// Shared string helpers used across HardlawKit and HardlawApp.
/// Kept in one place so number extraction and similar utilities are not
/// re-implemented per file.
public extension String {

    /// All decimal numbers (e.g. "7550", "93059.85") found in the string,
    /// in order of appearance. Matches `\d+\.?\d*`.
    var numbers: [String] {
        let pattern = try! NSRegularExpression(pattern: #"\d+\.?\d*"#)
        let range = NSRange(startIndex..., in: self)
        return pattern.matches(in: self, range: range).compactMap {
            Range($0.range, in: self).map { String(self[$0]) }
        }
    }
}
