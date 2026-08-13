import Foundation

/// Expands a folder or zip into a flat list of supported files.
/// Folders are enumerated recursively; zip archives are extracted to a scratch directory.
/// Unsupported file types (mp4, docx, xlsx, etc.) are reported in `skipped`.
public enum ImportPackage {

    /// File extensions we can OCR.
    public static let supportedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "heic", "tiff", "txt", "md", "csv",
    ]

    /// Unsupported-but-common extensions to explicitly skip and report.
    public static let unsupportedExtensions: Set<String> = [
        "mp4", "mov", "avi", "docx", "doc", "xlsx", "xls", "pptx", "ppt",
        "zip", "rar", "7z", "dmg",
    ]

    // MARK: - Public API

    /// Expand a folder or zip URL into a sorted list of supported file URLs.
    ///
    /// - Parameters:
    ///   - sourceURL: The folder or zip archive to expand.
    ///   - scratchDir: Temporary directory for zip extraction output.
    /// - Returns: `(files: supported files sorted by name, skipped: unsupported files)`.
    public static func expand(
        _ sourceURL: URL,
        scratchDir: URL
    ) throws -> (files: [URL], skipped: [URL]) {
        let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let isZip = sourceURL.pathExtension.lowercased() == "zip"

        let allFiles: [URL]
        if isDirectory {
            allFiles = enumerateDirectory(sourceURL)
        } else if isZip {
            allFiles = try expandZip(sourceURL, to: scratchDir)
        } else {
            // Single file
            allFiles = [sourceURL]
        }

        // Partition by supported extension
        var supported: [URL] = []
        var skipped: [URL] = []
        for url in allFiles {
            let ext = url.pathExtension.lowercased()
            if ext.isEmpty || supportedExtensions.contains(ext) {
                supported.append(url)
            } else {
                skipped.append(url)
            }
        }

        // Sort preserving numeric prefixes (证据1 → 证据2 → … → 证据25)
        supported.sort { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        skipped.sort { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        return (supported, skipped)
    }

    // MARK: - Internals

    private static func enumerateDirectory(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            // Skip hidden files and .DS_Store
            guard !name.hasPrefix(".") else { continue }
            files.append(url)
        }
        return files
    }

    private static func expandZip(_ zipURL: URL, to scratchDir: URL) throws -> [URL] {
        let fm = FileManager.default
        // Clean scratch dir if it exists
        try? fm.removeItem(at: scratchDir)
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let extracted = try ZipReader.extractAll(from: zipURL, to: scratchDir)
        return extracted
    }
}
