import Foundation

// MARK: - FieldState

/// AI-human merge state for a single value field.
/// Every AI-fillable field carries provenance and adjudication status.
public enum FieldStatus: String, Codable, Sendable {
    case pending           // AI never produced a value
    case machineDraft      // AI wrote it; human hasn't touched it
    case humanConfirmed    // human explicitly approved (the trust ceremony)
    case humanOverridden   // human replaced the AI value
}

public struct FieldState: Codable, Sendable, Equatable {
    public var machineValue: String?       // AI suggestion (freely updatable)
    public var humanOverride: String?      // human text (nil = never edited)
    public var confirmedValue: String?     // snapshot at confirmation time (diff baseline)
    public var lastVerifiedAt: Date?
    public var status: FieldStatus
    public var basedOnEvidenceVersion: Int
    public var stale: Bool

    public init(machineValue: String? = nil) {
        self.machineValue = machineValue
        self.humanOverride = nil
        self.confirmedValue = nil
        self.lastVerifiedAt = nil
        self.status = machineValue != nil ? .machineDraft : .pending
        self.basedOnEvidenceVersion = 0
        self.stale = false
    }

    /// The authoritative displayed value: human override wins, then machine draft.
    public var displayValue: String? {
        humanOverride ?? machineValue
    }

    /// Whether the value needs human attention.
    public var needsAttention: Bool {
        stale || (status == .machineDraft && machineValue != nil)
    }

    // MARK: - Merge

    /// Apply a new machine value. Returns the action the UI should take.
    public enum MergeAction: Sendable, Equatable {
        case noop
        case applied                          // freely updated
        case flagForReview(String)            // human owns it, show advisory
        case promptForReconfirmation(String)  // confirmed but affected, show diff
    }

    public mutating func merge(
        newMachineValue: String?,
        directlyAffected: Bool,
        evidenceVersion: Int
    ) -> MergeAction {
        machineValue = newMachineValue
        lastVerifiedAt = .now
        basedOnEvidenceVersion = evidenceVersion
        stale = false

        // Rule 1: Human override — NEVER overwrite
        if humanOverride != nil {
            status = .humanOverridden
            return .flagForReview("AI 根据新证据更新了建议，你的修改已保留")
        }
        // Rule 2: Human confirmed + directly affected → downgrade, show diff
        if status == .humanConfirmed, directlyAffected {
            status = .machineDraft
            return .promptForReconfirmation("AI 建议已更新，请重新确认")
        }
        // Rule 3: Human confirmed + not affected → keep
        if status == .humanConfirmed {
            return .noop
        }
        // Rule 4: machineDraft or pending → free update
        status = newMachineValue != nil ? .machineDraft : .pending
        return .applied
    }

    /// Human confirms the current value.
    public mutating func confirm() {
        confirmedValue = displayValue
        status = .humanConfirmed
        lastVerifiedAt = .now
    }

    /// Human edits the value.
    public mutating func override(with text: String) {
        humanOverride = text
        status = .humanOverridden
        lastVerifiedAt = .now
    }
}

// MARK: - EvidenceRecord

/// A single piece of evidence in the case store.
public struct EvidenceRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public var fileName: String
    public var sourceKey: String          // "ev_AB12" — key for EvidenceValidator
    public var ocrText: String?           // Vision OCR output
    public var entityIndex: EntityIndex   // extracted numbers, names, dates
    public var sha256: String
    public var evidenceVersion: Int
    public var ocrState: OCRState
    public var importedAt: Date

    public init(fileName: String, sha256: String = "") {
        self.id = UUID()
        self.fileName = fileName
        self.sourceKey = "ev_\(id.uuidString.prefix(4))"
        self.sha256 = sha256
        self.entityIndex = EntityIndex()
        self.evidenceVersion = 0
        self.ocrState = .pending
        self.importedAt = .now
    }
}

public enum OCRState: String, Codable, Sendable {
    case pending, running, done, failed
}

/// Extracted entities for fast deterministic cross-checking.
public struct EntityIndex: Codable, Sendable, Equatable {
    public var amounts: [String]      // "7550元", "93059.85"
    public var dates: [String]        // "2020年7月1日"
    public var idNumbers: [String]    // "410521199607112516"
    public var names: [String]        // "郭又义", "河南达海"
    public var categories: [String]   // "工资", "社保", "合同"

    public init() {
        amounts = []; dates = []; idNumbers = []; names = []; categories = []
    }

    public var isEmpty: Bool {
        amounts.isEmpty && dates.isEmpty && names.isEmpty
    }
}

// MARK: - Provenance

/// Tracks which evidence records an AI artifact depends on.
public struct Provenance: Codable, Sendable {
    public var dependsOn: Set<UUID>       // evidence record IDs
    public var domainKey: String          // "claim:wageArrears", "catalog:12"
    public var evidenceVersionAtRun: Int
    public var startCounter: Int          // artifact counter when task started

    public init(dependsOn: Set<UUID> = [], domainKey: String = "",
                evidenceVersionAtRun: Int = 0, startCounter: Int = 0) {
        self.dependsOn = dependsOn
        self.domainKey = domainKey
        self.evidenceVersionAtRun = evidenceVersionAtRun
        self.startCounter = startCounter
    }
}

// REMOVED: ConflictItem moved to CaseFile.swift alongside GapSeverity for Codable compatibility
