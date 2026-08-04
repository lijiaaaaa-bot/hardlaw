import Foundation

// MARK: - CaseStore

/// Single-writer actor owning all mutable case state.
/// Every AI result and human edit flows through the apply gate.
public actor CaseStore {

    // MARK: - Stored state

    public private(set) var evidenceRecords: [UUID: EvidenceRecord] = [:]
    public private(set) var conflicts: [ConflictItem] = []
    public private(set) var evidenceVersion: Int = 0
    public private(set) var commandLog: [Command] = []
    private var undoStack: [Command] = []
    private var artifactCounters: [UUID: Int] = [:]   // artifact ID → mutation counter

    // MARK: - Evidence

    public func appendEvidence(_ record: EvidenceRecord) {
        evidenceRecords[record.id] = record
        evidenceVersion += 1
        log(.evidenceAdd)
    }

    public func evidence(hash: String) -> EvidenceRecord? {
        evidenceRecords.values.first { $0.sha256 == hash }
    }

    public func evidence(id: UUID) -> EvidenceRecord? {
        evidenceRecords[id]
    }

    public func allEvidence() -> [EvidenceRecord] {
        Array(evidenceRecords.values)
    }

    // MARK: - Counters

    public func counter(for artifactID: UUID) -> Int {
        artifactCounters[artifactID] ?? 0
    }

    public func bump(_ artifactID: UUID) {
        artifactCounters[artifactID] = (artifactCounters[artifactID] ?? 0) + 1
    }

    // MARK: - Apply gate

    /// Returns nil if the result's context is stale and should be rejected.
    public func validateContext(evidenceVersionAtRun: Int,
                                observedCounters: [UUID: Int]) -> Bool {
        guard evidenceVersionAtRun == evidenceVersion else { return false }
        for (id, counter) in observedCounters {
            if (artifactCounters[id] ?? 0) != counter { return false }
        }
        return true
    }

    // MARK: - Conflicts

    public func addConflict(_ conflict: ConflictItem) {
        conflicts.append(conflict)
    }

    public func resolveConflict(_ id: UUID, status: ConflictStatus) {
        if let idx = conflicts.firstIndex(where: { $0.id == id }) {
            conflicts[idx].status = status
        }
    }

    // MARK: - Command log

    private func log(_ type: CommandType) {
        let cmd = Command(
            type: type,
            caseID: UUID(), // placeholder — set from CaseFile
            timestamp: .now
        )
        commandLog.append(cmd)
        undoStack.append(cmd)
    }
}

// MARK: - Command

public enum CommandType: String, Codable, Sendable {
    case aiDraft, humanEdit, evidenceAdd, evidenceRemove
    case gapResolve, conflictResolve, batchAnalysis, humanConfirm
}

public struct Command: Codable, Identifiable, Sendable {
    public let id: UUID
    public let type: CommandType
    public let caseID: UUID
    public let timestamp: Date
    public var derivedFrom: [UUID] = []

    public init(type: CommandType, caseID: UUID, timestamp: Date = .now) {
        self.id = UUID()
        self.type = type
        self.caseID = caseID
        self.timestamp = timestamp
    }
}
