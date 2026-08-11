import Foundation

// MARK: - Persistence Controller

/// File-based persistence using Codable JSON.
/// Saves each case as a separate .json file in the app's documents directory.
public final class PersistenceController: @unchecked Sendable {
    public static let shared = PersistenceController()

    private let fileManager = FileManager.default

    /// 存储目录（Documents/Cases）。目录创建失败时抛出，由调用方展示给用户。
    private func storageDirectory() throws -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Cases", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.directoryCreationFailed(error)
        }
        return dir
    }

    // MARK: - Save

    @MainActor
    public func save(_ caseFile: CaseFile) throws {
        let dto = CaseFileDTO(from: caseFile)
        let data = try JSONEncoder().encode(dto)
        let url = try storageDirectory().appendingPathComponent("\(caseFile.id.uuidString).json")
        try data.write(to: url)
    }

    // MARK: - Load

    @MainActor
    public func loadAll() throws -> [CaseFile] {
        let urls = try fileManager.contentsOfDirectory(
            at: try storageDirectory(), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        return try urls.compactMap { url in
            let data = try Data(contentsOf: url)
            let dto = try JSONDecoder().decode(CaseFileDTO.self, from: data)
            return dto.toCaseFile()
        }
    }

    @MainActor
    public func load(id: UUID) throws -> CaseFile? {
        let url = try storageDirectory().appendingPathComponent("\(id.uuidString).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let dto = try JSONDecoder().decode(CaseFileDTO.self, from: data)
        return dto.toCaseFile()
    }

    // MARK: - Delete

    @MainActor
    public func delete(id: UUID) throws {
        let url = try storageDirectory().appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func deleteAll() throws {
        let urls = try fileManager.contentsOfDirectory(at: try storageDirectory(), includingPropertiesForKeys: nil)
        for url in urls { try fileManager.removeItem(at: url) }
    }
}

// MARK: - 错误类型

/// 持久化错误。实现 LocalizedError，向用户展示中文可读描述。
enum PersistenceError: Error, LocalizedError {
    case directoryCreationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let underlying):
            return "无法创建存储目录：\(underlying.localizedDescription)"
        }
    }
}

// MARK: - Data Transfer Object (Codable mirror of CaseFile)

/// Serializable snapshot of CaseFile. Handles FieldState encoding/decoding.
struct CaseFileDTO: Codable {
    var id: UUID
    var caseName: String
    var applicant: String
    var respondent: String
    var createdAt: Date
    var claims: [ClaimDTO]
    var evidenceItems: [EvidenceDTO]
    var gaps: [GapDTO]
    var evidenceVersion: Int
    init(from caseFile: CaseFile) {
        self.id = caseFile.id
        self.caseName = caseFile.caseName
        self.applicant = caseFile.applicant
        self.respondent = caseFile.respondent
        self.createdAt = caseFile.createdAt
        self.claims = caseFile.claims.map(ClaimDTO.init)
        self.evidenceItems = caseFile.evidenceItems.map(EvidenceDTO.init)
        self.gaps = caseFile.gaps.map(GapDTO.init)
        self.evidenceVersion = caseFile.evidenceVersion
    }

    // Old saved files have no evidenceVersion — default to 0.
    enum CodingKeys: String, CodingKey {
        case id, caseName, applicant, respondent, createdAt
        case claims, evidenceItems, gaps, evidenceVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        caseName = try c.decode(String.self, forKey: .caseName)
        applicant = try c.decode(String.self, forKey: .applicant)
        respondent = try c.decode(String.self, forKey: .respondent)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        claims = try c.decode([ClaimDTO].self, forKey: .claims)
        evidenceItems = try c.decode([EvidenceDTO].self, forKey: .evidenceItems)
        gaps = try c.decode([GapDTO].self, forKey: .gaps)
        evidenceVersion = try c.decodeIfPresent(Int.self, forKey: .evidenceVersion) ?? 0
    }

    func toCaseFile() -> CaseFile {
        let cf = CaseFile(
            caseName: caseName,
            applicant: applicant,
            respondent: respondent,
            claims: [],
            evidenceItems: []
        )
        cf.id = id
        cf.createdAt = createdAt
        cf.claims = claims.map { $0.toClaimItem() }
        cf.evidenceItems = evidenceItems.map { $0.toEvidenceItem() }
        cf.gaps = gaps.map { $0.toGapItem() }
        cf.evidenceVersion = evidenceVersion
        return cf
    }
}

struct ClaimDTO: Codable {
    var id: UUID; var claimNumber: Int; var content: String; var legalBasis: String
    init(from c: ClaimItem) { id = c.id; claimNumber = c.claimNumber; content = c.content; legalBasis = c.legalBasis }
    func toClaimItem() -> ClaimItem { let c = ClaimItem(claimNumber: claimNumber, content: content, legalBasis: legalBasis); c.id = id; return c }
}

struct EvidenceDTO: Codable {
    var id: UUID; var group: String; var number: Int; var name: String
    var isOriginal: Bool; var pageCount: Int
    var proofContentState: FieldStateDTO; var proofPurposeState: FieldStateDTO
    var sourceOCRText: String; var humanReviewed: Bool
    init(from e: EvidenceItem) {
        id = e.id; group = e.group; number = e.number; name = e.name
        isOriginal = e.isOriginal; pageCount = e.pageCount
        proofContentState = FieldStateDTO(from: e.proofContentState)
        proofPurposeState = FieldStateDTO(from: e.proofPurposeState)
        sourceOCRText = e.sourceOCRText; humanReviewed = e.humanReviewed
    }
    func toEvidenceItem() -> EvidenceItem {
        let e = EvidenceItem(group: group, number: number, name: name,
                             isOriginal: isOriginal, pageCount: pageCount,
                             sourceOCRText: sourceOCRText)
        e.id = id; e.proofContentState = proofContentState.toFieldState()
        e.proofPurposeState = proofPurposeState.toFieldState(); e.humanReviewed = humanReviewed
        return e
    }
}

struct FieldStateDTO: Codable {
    var machineValue: String?; var humanOverride: String?; var confirmedValue: String?
    var lastVerifiedAt: Date?; var status: String; var basedOnEvidenceVersion: Int; var stale: Bool
    init(from fs: FieldState) {
        machineValue = fs.machineValue; humanOverride = fs.humanOverride
        confirmedValue = fs.confirmedValue; lastVerifiedAt = fs.lastVerifiedAt
        status = fs.status.rawValue; basedOnEvidenceVersion = fs.basedOnEvidenceVersion; stale = fs.stale
    }
    func toFieldState() -> FieldState {
        var fs = FieldState(machineValue: machineValue)
        fs.humanOverride = humanOverride; fs.confirmedValue = confirmedValue
        fs.lastVerifiedAt = lastVerifiedAt
        fs.status = FieldStatus(rawValue: status) ?? .pending
        fs.basedOnEvidenceVersion = basedOnEvidenceVersion; fs.stale = stale
        return fs
    }
}

struct GapDTO: Codable {
    var id: UUID; var severity: String; var description: String
    var suggestedRemedy: String; var relatedClaim: String; var isResolved: Bool
    init(from g: GapItem) { id = g.id; severity = g.severity.rawValue; description = g.description; suggestedRemedy = g.suggestedRemedy; relatedClaim = g.relatedClaim; isResolved = g.isResolved }
    func toGapItem() -> GapItem { let g = GapItem(severity: GapSeverity(rawValue: severity) ?? .medium, description: description, suggestedRemedy: suggestedRemedy, relatedClaim: relatedClaim, isResolved: isResolved); g.id = id; return g }
}
