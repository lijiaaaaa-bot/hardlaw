import Foundation
import Observation
import CoreGraphics
import HardlawKit

/// View model for the Hardlaw app. Owns the Court instance and drives the UI state machine.
@MainActor
@Observable
public final class CourtViewModel {

    /// Current phase of the audit flow.
    public enum Phase: Equatable, Sendable {
        case idle
        case capturing
        case collecting
        case deliberating
        case decided(CaseResult)
    }

    /// Backend selection.
    public enum Backend: String, CaseIterable, Sendable {
        case ruleBased = "Rule-Based"
        case mockPass = "Mock (Pass)"
        case mockRefute = "Mock (Refute)"
    }

    // MARK: - State

    public var phase: Phase = .idle
    public var selectedBackend: Backend = .ruleBased
    public var liveFindings: [Finding] = []
    public var isCameraRunning: Bool = false
    public var lastFrameText: String = ""
    public var statusMessage: String = "Ready"

    // MARK: - Private

    private var court: Court?
    private var evidenceCollector = VisionEvidenceCollector()

    public init() {}

    // MARK: - Court Setup

    /// Build a Court with the selected backend.
    private func makeCourt() -> Court {
        let statutes: [Statute] = ContentModerationStatutes.all
        let procedure = try! ContentModerationStatutes.makeAuditProcedure()

        let llm: (any LLMBackend)?
        switch selectedBackend {
        case .ruleBased:
            llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        case .mockPass:
            let mock = MockLLM(responses: [])
            llm = mock
        case .mockRefute:
            let refuteResponse = """
            {
                "finding": "profanity",
                "refuted": true,
                "confidence": "high",
                "blocking": "none",
                "evidence_refs": [],
                "reasoning": "Mock: profanity detected",
                "findings": [{"kind": "gap", "location": "content:1", "detail": "Mock finding"}]
            }
            """
            let mock = MockLLM(responses: [refuteResponse])
            llm = mock
        }

        return Court(statutes: statutes, procedure: procedure, llm: llm)
    }

    // MARK: - Live Scan (Rule-Based, frame-by-frame)

    /// Run a quick rule-based scan on a text string (no full Court procedure).
    public func scanText(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            liveFindings = []
            return
        }

        let llm = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let prompt = """
        ## CASE DATA
        ### content
        \(text)
        ### objective
        Scan for policy violations
        """

        do {
            let raw = try await llm.judge(prompt)
            let verdict = VerdictParser.parse(raw)
            liveFindings = verdict.findings
            lastFrameText = text
        } catch {
            liveFindings = []
        }
    }

    // MARK: - Audit (Full Court Procedure)

    /// Run a full Court audit on a text string.
    public func auditText(_ text: String) async {
        phase = .deliberating
        statusMessage = "Court in session..."

        let court = makeCourt()
        let result = await court.hear(caseData: [
            "content": .string(text),
            "objective": .string("Audit content for policy compliance"),
        ])

        phase = .decided(result)
        statusMessage = result.finalDisposition.rawValue.capitalized
    }

    /// Run a full Court audit from a CGImage (using Vision evidence collection).
    public func auditImage(_ cgImage: CGImage) async {
        phase = .collecting
        statusMessage = "Collecting evidence..."

        do {
            let bundle = try await evidenceCollector.collectEvidence(from: cgImage)

            // Convert evidence bundle to case data
            var caseData: [String: JSONValue] = [
                "objective": .string("Audit camera frame for policy compliance"),
            ]
            for (key, value) in bundle.sourceMaterial {
                caseData[key] = .string(value)
            }

            phase = .deliberating
            statusMessage = "Court in session..."

            let court = makeCourt()
            // Register all source materials
            for (key, value) in bundle.sourceMaterial {
                // EvidenceValidator.addSource is called inside Court.hear()
                _ = key
                _ = value
            }
            let result = await court.hear(caseData: caseData)

            phase = .decided(result)
            statusMessage = result.finalDisposition.rawValue.capitalized
        } catch {
            phase = .idle
            statusMessage = "Evidence error: \(error.localizedDescription)"
        }
    }

    /// Reset to idle.
    public func reset() {
        phase = .idle
        liveFindings = []
        lastFrameText = ""
        statusMessage = "Ready"
    }
}
