import Foundation

/// Manages imported evidence files in the app sandbox.
/// Files are stored under `Documents/Cases/{caseID}/evidence/{batchID}/{filename}`
/// with `.completeFileProtection` and `.isExcludedFromBackupKey`.
public enum EvidenceFileStore {

    // MARK: - Public API

    /// Copy files into the case sandbox and return destination URLs.
    ///
    /// - Parameters:
    ///   - urls: Source file URLs (from folder enumeration or zip extraction).
    ///   - caseID: The case's UUID.
    ///   - batchID: Batch identifier for this import session.
    /// - Returns: Destination URLs in the sandbox.
    public static func copyIntoCase(
        _ urls: [URL],
        caseID: UUID,
        batchID: UUID
    ) throws -> [URL] {
        let destDir = evidenceDirectory(caseID: caseID, batchID: batchID)
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var copied: [URL] = []
        for url in urls {
            let fileName = url.lastPathComponent
            let destURL = uniqueURL(for: fileName, in: destDir)
            try fm.copyItem(at: url, to: destURL)
            try protectFile(at: destURL)
            copied.append(destURL)
        }
        return copied
    }

    /// Resolve a relative path (from EvidenceItem.sourceFile) to an absolute sandbox URL.
    public static func absoluteURL(for relativePath: String, caseID: UUID) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let fullPath = docs.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fullPath.path) else {
            return nil
        }
        return fullPath
    }

    /// Build a relative path string for persistence.
    public static func relativePath(for absoluteURL: URL, caseID: UUID) -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let docsPath = docs.path
        let filePath = absoluteURL.path
        guard filePath.hasPrefix(docsPath) else { return nil }
        return String(filePath.dropFirst(docsPath.count + 1)) // drop leading "/"
    }

    /// Remove all evidence files for a case.
    public static func removeCaseEvidence(caseID: UUID) throws {
        let dir = baseEvidenceDirectory(caseID: caseID)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - URLs

    private static func evidenceDirectory(caseID: UUID, batchID: UUID) -> URL {
        baseEvidenceDirectory(caseID: caseID)
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
    }

    private static func baseEvidenceDirectory(caseID: UUID) -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable")
        }
        return docs.appendingPathComponent("Cases/\(caseID.uuidString)/evidence", isDirectory: true)
    }

    // MARK: - Helpers

    /// Generate a unique filename by appending a counter if the name exists.
    private static func uniqueURL(for fileName: String, in dir: URL) -> URL {
        let base = fileName
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(base)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    /// Apply security protections to a file.
    private static func protectFile(at url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)

        // Set data protection
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }
}
