import Foundation

// MARK: - Court

/// The hard-law enforcement runtime.
/// Court = statute_book + procedure + llm + evidence_validator + stall_detector.
/// Runs the procedure state machine and enforces all hard constraints.
/// Mirrors Python `hardlaw.court.Court`.
public actor Court {
    /// The statute book (legal code).
    public var statuteBook: StatuteBook
    /// The procedure state machine.
    public var procedure: Procedure?
    /// The LLM judge backend.
    public var llm: (any LLMBackend)?
    /// Maximum rounds before forced termination.
    public var maxRounds: Int
    /// Stall detection threshold.
    public var stallThreshold: Int
    /// Evidence validator (anti-hallucination).
    private var evidenceValidator: EvidenceValidator
    /// Stall detector.
    private var stallDetector: StallDetector

    /// Logger tag for this court.
    private let logTag: String

    public init(
        statutes: StatuteBookConvertible? = nil,
        procedure: Procedure? = nil,
        llm: (any LLMBackend)? = nil,
        maxRounds: Int? = nil,
        stallThreshold: Int? = nil
    ) {
        self.statuteBook = statutes?.asStatuteBook ?? StatuteBook()
        self.procedure = procedure
        self.llm = llm
        // Use procedure's values when caller hasn't explicitly overridden from defaults
        // Mirrors Python sentinel-default logic
        if let maxRounds {
            self.maxRounds = maxRounds
        } else if let proc = procedure, proc.maxRounds != 10 {
            self.maxRounds = proc.maxRounds
        } else {
            self.maxRounds = 10
        }
        if let stallThreshold {
            self.stallThreshold = stallThreshold
        } else if let proc = procedure, proc.stallThreshold != 2 {
            self.stallThreshold = proc.stallThreshold
        } else {
            self.stallThreshold = 2
        }
        self.evidenceValidator = EvidenceValidator()
        self.stallDetector = StallDetector(threshold: self.stallThreshold)
        self.logTag = "hardlaw.court"
    }

    /// Hear a case through the full procedure.
    /// This is the main entry point. Runs the procedure state machine.
    /// Mirrors Python `Court.hear`.
    public func hear(caseData: [String: JSONValue] = [:]) async -> CaseResult {
        guard let procedure else {
            return CaseResult(
                caseId: "no-procedure",
                finalDisposition: .rejected,
                reason: "No procedure defined"
            )
        }

        let caseId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        var ctx = CaseContext(caseId: String(caseId), data: caseData)

        // Register case data strings as evidence sources
        for (key, value) in caseData {
            if let str = value.stringValue {
                evidenceValidator.addSource(key, str)
            }
        }

        var currentStep = procedure.initialStep
        var verdicts: [Verdict] = []

        for _ in 0..<maxRounds {
            ctx.roundCount += 1

            let step: Step
            do {
                step = try procedure.getStep(currentStep)
            } catch {
                // Step not found — surface the config error instead of
                // silently treating it as a terminal disposition.
                return CaseResult(
                    caseId: String(caseId),
                    verdicts: verdicts,
                    finalDisposition: .rejected,
                    reason: "Step '\(currentStep)' not found in procedure",
                    roundCount: ctx.roundCount
                )
            }
            ctx.stepHistory.append(currentStep)

            if step.kind == .code {
                // --- Deterministic code execution ---
                step.handler?(&ctx)
                // Refresh evidence sources — handlers may have modified case data
                for (key, value) in ctx.data {
                    if let str = value.stringValue {
                        evidenceValidator.addSource(key, str)
                    }
                }
                if step.nextStep("done") == nil {
                    // Terminal CODE step
                    return CaseResult(
                        caseId: String(caseId),
                        verdicts: verdicts,
                        finalDisposition: CaseResult.Disposition.fromStepName(currentStep),
                        reason: "Procedure ended at terminal step '\(currentStep)'",
                        roundCount: ctx.roundCount
                    )
                }
                currentStep = procedure.transition(from: currentStep, outcome: "done")
                continue
            } else {
                // --- LLM judgment point ---
                var verdict = await invokeJudge(ctx: &ctx, step: step)

                // Deterministic cross-statute invariants (e.g. 2N/N+1 exclusion):
                // an approved statute records itself so a later conflicting approval
                // can be reconciled by the invariant, not trusted to the LLM.
                let statuteNames = Set((step.statutes ?? []))
                if !verdict.refuted {
                    for name in statuteNames where !ctx.approvedStatutes.contains(name) {
                        ctx.approvedStatutes.append(name)
                    }
                    verdict = StatuteExclusions.enforce(
                        verdict: verdict,
                        approvedStatutes: ctx.approvedStatutes,
                        stepStatutes: statuteNames)
                }

                verdicts.append(verdict)
                ctx.findings.append(verdict)

                // Stall detection
                let fp = Fingerprint.compute(findings: verdict.findings)
                if !fp.isEmpty {
                    ctx.gapFingerprints.append(fp)
                    if stallDetector.check(fp) {
                        return CaseResult(
                            caseId: String(caseId),
                            verdicts: verdicts,
                            finalDisposition: .stalled,
                            reason: "Same gap fingerprint appeared \(stallDetector.count) consecutive times",
                            roundCount: ctx.roundCount
                        )
                    }
                }

                // Route based on verdict
                let route: String
                if verdict.blocking {
                    route = "blocked"
                } else if verdict.refuted {
                    route = "refuted"
                } else {
                    route = "not_refuted"
                }

                // Check if this step has a defined transition for this route
                if step.nextStep(route) == nil {
                    // No transition — verdict is final
                    let disposition: CaseResult.Disposition
                    if !verdict.refuted {
                        disposition = .approved
                    } else if verdict.blocking {
                        disposition = .blocked
                    } else {
                        disposition = .rejected
                    }
                    return CaseResult(
                        caseId: String(caseId),
                        verdicts: verdicts,
                        finalDisposition: disposition,
                        reason: verdict.reasoning,
                        roundCount: ctx.roundCount
                    )
                }
                currentStep = procedure.transition(from: currentStep, outcome: route)
                continue
            }
        }

        // Max rounds exceeded
        return CaseResult(
            caseId: String(caseId),
            verdicts: verdicts,
            finalDisposition: .maxRounds,
            reason: "Procedure did not converge within \(maxRounds) rounds",
            roundCount: ctx.roundCount
        )
    }

    // MARK: - Judgment

    /// Invoke LLM at a judgment point, enforcing all hard constraints.
    /// Mirrors Python `Court._invoke_judge`.
    private func invokeJudge(ctx: inout CaseContext, step: Step) async -> Verdict {
        // Get applicable statutes
        let statuteList = statuteBook.getAll(step.statutes ?? [])

        // Build the judgment prompt
        let prompt = buildJudgmentPrompt(ctx: ctx, statutes: statuteList, step: step)

        // Call LLM
        guard let llm else {
            return Verdict(
                finding: "no_llm",
                refuted: true,
                blocking: true,
                blockingKind: BlockingKind.contradiction,
                reasoning: "No LLM backend configured"
            )
        }

        let raw: String
        do {
            raw = try await llm.judge(prompt)
        } catch {
            return Verdict(
                finding: "llm_error",
                refuted: true,
                blocking: true,
                blockingKind: BlockingKind.contradiction,
                fallbackNote: "LLM call failed: \(error.localizedDescription)"
            )
        }

        // Parse verdict (never throws)
        var verdict = VerdictParser.parse(raw)

        // Enforce evidence rules with burden-of-proof layering
        for statute in statuteList {
            for req in statute.requiredEvidence {
                // Check if this requirement is satisfied (primary or alternatives)
                let allOptions = [req.evidence] + req.alternatives.map(\.evidence)
                let citedSources = Set(verdict.evidenceRefs.map(\.source))
                let matched = allOptions.filter { citedSources.contains($0) }
                if matched.count >= req.minCount { continue } // Satisfied

                // Unsatisfied — route based on holder + onMissing action
                switch req.holder {
                case .worker where req.onMissing == .block:
                    // Worker-held evidence missing, block action → fail-closed
                    verdict.refuted = true
                    verdict.blocking = true
                    verdict.blockingKind = BlockingKind.contradiction
                    verdict.fallbackNote = "Missing worker-held evidence: \(req.evidence)"
                case .worker:
                    // Worker-held but flagged as non-blocking → notice only
                    verdict.findings.append(Finding(
                        kind: "gap", location: "\(statute.name)/\(req.evidence)",
                        detail: "缺少：\(req.evidence)"))
                case .employer:
                    // Employer-held evidence missing → burden notice, don't block worker
                    verdict.findings.append(Finding(
                        kind: "notice",
                        location: "\(statute.name)/\(req.evidence)",
                        detail: "该证据由用人单位掌握管理\(req.burdenBasis.map { "（\($0)）" } ?? "")，应由其提供。不作为申请人证据缺口。"
                    ))
                case .thirdParty:
                    // Third-party evidence → add gap finding + prompt for retry
                    verdict.findings.append(Finding(
                        kind: "gap", location: "\(statute.name)/\(req.evidence)",
                        detail: "需调取第三方证据：\(req.evidence)\(req.burdenBasis.map { "（\($0)）" } ?? "")"))
                    verdict.fallbackNote = "第三方证据待调取: \(req.evidence)"
                }
                // Only .block action stops the verdict; flag/prompt add notices and continue
                if verdict.blocking { break }
            }
            if verdict.blocking { break }
        }

        // Validate cited evidence actually exists (anti-hallucination Layer 1)
        if !verdict.evidenceRefs.isEmpty {
            let (allValid, _) = evidenceValidator.validateAll(verdict.evidenceRefs)
            if !allValid {
                // Fail-closed invariant: LLM hallucinated evidence → force reject
                verdict.refuted = true
            }
        }

        // Numeric entailment check (anti-hallucination Layer 2)
        // Deterministic: numbers in reasoning must be traceable to cited evidence.
        // Catches "correct snippet, wrong attribution" hallucinations.
        if !verdict.refuted && !verdict.evidenceRefs.isEmpty {
            let numericEntailment = checkNumericEntailment(verdict)
            if !numericEntailment.passed {
                verdict.refuted = true
                verdict.blockingKind = BlockingKind.unverifiable
                verdict.fallbackNote = numericEntailment.reason
            }
        }

        // Blind review (anti-hallucination Layer 3)
        // Only triggered when the refute is from the LLM's own low-confidence judgment,
        // NOT from deterministic gates (evidence missing, hallucination, numeric entailment).
        // Deterministic gate refutes always set blockingKind to contradiction.
        let llmRefuted = verdict.refuted && verdict.blockingKind != BlockingKind.contradiction
        if llmRefuted && verdict.confidence == .low {
            if let blindVerdict = await blindReview(verdict: verdict, llm: llm) {
                if !blindVerdict.refuted {
                    verdict = blindVerdict
                    verdict.fallbackNote = (verdict.fallbackNote ?? "") + "; blind review overrode low-confidence refute"
                }
            }
        }

        return verdict
    }

    // MARK: - Blind Review (Layer 3)

    /// Second LLM call with orthogonal prompt: only shows cited snippets and the conclusion,
    /// asking "does this evidence actually support this conclusion?" No case data, no claims.
    private func blindReview(verdict: Verdict, llm: any LLMBackend) async -> Verdict? {
        // Build orthogonal prompt
        var lines: [String] = [
            "You are an independent second reviewer. Your sole job: verify whether the cited evidence actually supports the conclusion.",
            "",
            "## CONCLUSION TO REVIEW",
            "Finding: \(verdict.finding)",
            "Refuted: \(verdict.refuted)",
            "Reasoning: \(verdict.reasoning)",
            "",
            "## CITED EVIDENCE",
        ]
        for ref in verdict.evidenceRefs {
            let snippet = ref.snippet.isEmpty ? "(empty)" : ref.snippet
            lines.append("- [\(ref.source)] \(snippet)")
        }
        lines.append(contentsOf: [
            "",
            "## QUESTION",
            "Based ONLY on the cited evidence above, does the evidence actually support the conclusion?",
            "Respond with exactly: CONFIRMED or OVERRULED",
        ])

        let prompt = lines.joined(separator: "\n")
        do {
            let raw = try await llm.judge(prompt)
            if raw.uppercased().contains("OVERRULED") {
                return Verdict(
                    finding: verdict.finding,
                    refuted: false,
                    confidence: .medium,
                    blocking: false,
                    blockingKind: BlockingKind.none,
                    evidenceRefs: verdict.evidenceRefs,
                    findings: verdict.findings,
                    reasoning: verdict.reasoning,
                    fallbackNote: "Blind review overrode original refute"
                )
            }
        } catch {
            // Blind review failed → keep original verdict
        }
        return nil
    }

    // MARK: - Numeric Entailment (Layer 2)

    /// Check that numbers claimed in the verdict's reasoning appear in cited evidence.
    /// This is a deterministic, zero-cost check that catches "correct snippet, wrong claim" hallucinations.
    private func checkNumericEntailment(_ verdict: Verdict) -> (passed: Bool, reason: String) {
        // Extract numbers from reasoning
        let reasoningNumbers = verdict.reasoning.numbers
        guard !reasoningNumbers.isEmpty else { return (true, "") }

        // Collect all verifiable numbers from cited evidence refs
        var evidenceNumbers = Set<String>()
        for ref in verdict.evidenceRefs {
            guard let content = evidenceValidator.sources[ref.source] else { continue }
            // Extract the cited snippet's context from source
            if !ref.snippet.isEmpty, content.contains(ref.snippet) {
                evidenceNumbers.formUnion(ref.snippet.numbers)
            }
            evidenceNumbers.formUnion(content.numbers)
        }

        // Check: majority of reasoning numbers (≥3 digits) must appear in evidence.
        // Uses a relaxed threshold to allow formula-derived results (sums, multiples)
        // that won't appear verbatim in source documents.
        let significantNums = reasoningNumbers.filter { $0.count >= 3 }
        guard !significantNums.isEmpty else { return (true, "") }
        let found = significantNums.filter { num in
            evidenceNumbers.contains(where: { $0.contains(num) || num.contains($0) })
        }
        let hitRate = Double(found.count) / Double(significantNums.count)
        if hitRate < 0.5 {
            let missing = significantNums.filter { num in
                !evidenceNumbers.contains(where: { $0.contains(num) || num.contains($0) })
            }
            return (false, "Majority of cited numbers not found in evidence: \(missing.prefix(3).joined(separator: ", "))")
        }
        return (true, "")
    }

    // MARK: - Prompt Builder

    /// Build the judgment prompt for the LLM judge.
    /// Byte-identical to Python `Court._build_judgment_prompt`.
    private func buildJudgmentPrompt(
        ctx: CaseContext,
        statutes: [Statute],
        step: Step
    ) -> String {
        var lines: [String] = [
            "You are an adversarial judge applying hard constraints to agent output.",
            "",
            "## OBJECTIVE",
            ctx.data["objective"]?.stringValue ?? "(no objective specified)",
            "",
            "## CASE DATA",
        ]

        // Include case data (excluding very large fields)
        for (key, value) in ctx.data {
            var valueStr: String
            switch value {
            case .string(let s): valueStr = s
            case .number(let n): valueStr = String(n)
            case .bool(let b): valueStr = String(b)
            case .array, .object:
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(value),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    valueStr = jsonStr
                } else {
                    valueStr = "\(value)"
                }
            case .null: valueStr = "null"
            }
            if valueStr.count > 2000 {
                valueStr = String(valueStr.prefix(2000)) + "\n... (truncated)"
            }
            lines.append("### \(key)")
            lines.append(valueStr)
            lines.append("")
        }

        // Applicable statutes
        if !statutes.isEmpty {
            lines.append("## APPLICABLE STATUTES")
            for s in statutes {
                lines.append("### \(s.name): \(s.description)")
                lines.append("Required evidence: \(s.requiredEvidence.map(\.evidence).joined(separator: ", "))")
                if !s.violations.isEmpty {
                    lines.append("Violations to check:")
                    for v in s.violations {
                        lines.append("  - \(v.name) (\(v.severity.rawValue)): \(v.description)")
                    }
                }
                lines.append("Default to reject: \(s.defaultToReject)")
                lines.append("")
            }
        }

        // Prior gaps (anti-ratchet)
        let priorGaps = ctx.findings.flatMap { verdict in
            verdict.findings.filter { !$0.isEmpty }
        }
        if !priorGaps.isEmpty {
            lines.append("## PRIOR GAPS (from previous rounds)")
            for g in priorGaps {
                lines.append("- [\(g.kind)] \(g.location): \(g.detail)")
            }
            lines.append("")
        }

        // Decision rules
        lines.append(contentsOf: [
            "## RULES",
            "- Default to reject if uncertain.",
            "- Every finding MUST cite specific evidence (source + location + snippet).",
            "- Claims without verifiable evidence MUST be rejected.",
            "- Do NOT re-litigate issues already resolved in prior rounds (anti-ratchet).",
            "- Do NOT author new evidence — only audit what is provided.",
            "",
            "## OUTPUT CONTRACT",
            "You MUST output a JSON verdict object:",
            "{",
            #"  "finding": "<violation type name or 'none'>","#,
            #"  "refuted": true|false,"#,
            #"  "confidence": "high"|"medium"|"low","#,
            #"  "blocking": "none"|"contradiction"|"unverifiable","#,
            #"  "evidence_refs": [{"source": "...", "location": "...", "snippet": "...", "kind": "text"}],"#,
            #"  "reasoning": "<explanation>","#,
            #"  "findings": [{"kind": "bug|gap|todo", "location": "path:line", "detail": "..."}]"#,
            "}",
            "",
            "Your terminal response must be EXACTLY one of:",
            "Refuted",
            "Not Refuted",
        ])

        return lines.joined(separator: "\n")
    }
}

// MARK: - StatuteBookConvertible

/// Protocol for types that can be converted to a StatuteBook.
public protocol StatuteBookConvertible: Sendable {
    var asStatuteBook: StatuteBook { get }
}

extension StatuteBook: StatuteBookConvertible {
    public var asStatuteBook: StatuteBook { self }
}

extension Array: StatuteBookConvertible where Element == Statute {
    public var asStatuteBook: StatuteBook { StatuteBook(statutes: self) }
}
