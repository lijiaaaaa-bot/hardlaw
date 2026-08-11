"""Court — the runtime orchestrator that enforces hard constraints.

The Court is where everything comes together:
  - Loads statutes (the law) and procedure (the process)
  - At each JUDGMENT step: builds evidence packet, calls LLM,
    enforces verdict schema, validates evidence
  - At each CODE step: runs the deterministic handler
  - Detects stalls and escalates
  - Routes between steps based on verdict outcomes

The Court enforces that:
  - LLM cannot skip steps or change the flow
  - Every judgment is structured and evidence-backed
  - Parse failures default to reject (fail-closed)
  - Repeated identical gaps trigger escalation
"""

from dataclasses import dataclass, field
import logging

from hardlaw.statute import Statute, StatuteBook
from hardlaw.procedure import Procedure, Step, StepKind, CaseContext, StallDetector
from hardlaw.evidence import EvidenceRule, EvidencePacket, EvidenceValidator, EvidenceRef
from hardlaw.verdict import (
    Verdict,
    Finding,
    VerdictParser,
    compute_fingerprint,
    BLOCKING_CONTRADICTION,
)

logger = logging.getLogger(__name__)


@dataclass
class CaseResult:
    """The final outcome of a case heard by the Court.

    Attributes:
        case_id: The case identifier.
        verdicts: All verdicts collected during the procedure.
        final_disposition: "approved", "rejected", "blocked", "stalled", "max_rounds".
        reason: Human-readable summary of the outcome.
        round_count: Total rounds executed.
    """

    case_id: str
    verdicts: list[Verdict] = field(default_factory=list)
    final_disposition: str = ""
    reason: str = ""
    round_count: int = 0


class Court:
    """The hard-law enforcement runtime.

    Court = statute_book + procedure + llm + evidence_validator + stall_detector.

    Usage:
        court = Court(statutes, procedure, llm)
        result = await court.hear({"content": "...", "author": "..."})
    """

    def __init__(
        self,
        statutes: StatuteBook | list[Statute] | None = None,
        procedure: Procedure | None = None,
        llm=None,
        max_rounds: int = 10,
        stall_threshold: int = 2,
    ):
        # Normalize statutes
        if isinstance(statutes, list):
            self.statute_book = StatuteBook(statutes)
        elif isinstance(statutes, StatuteBook):
            self.statute_book = statutes
        else:
            self.statute_book = StatuteBook()

        self.procedure = procedure
        self.llm = llm
        # Use procedure's max_rounds if the caller didn't override from the default
        if max_rounds == 10 and procedure is not None and procedure.max_rounds != 10:
            self.max_rounds = procedure.max_rounds
        else:
            self.max_rounds = max_rounds
        # Use procedure's stall_threshold if the caller didn't override from the default
        if stall_threshold == 2 and procedure is not None and procedure.stall_threshold != 2:
            self.stall_threshold = procedure.stall_threshold
        else:
            self.stall_threshold = stall_threshold
        self.evidence_validator = EvidenceValidator()
        self.stall_detector = StallDetector(threshold=self.stall_threshold)

    async def hear(self, case_data: dict | None = None) -> CaseResult:
        """Hear a case through the full procedure.

        This is the main entry point. It runs the procedure state machine:
          CODE step → execute handler → transition
          JUDGMENT step → build prompt → call LLM → parse verdict →
                          validate evidence → stall check → transition

        Args:
            case_data: The case to judge (arbitrary dict).

        Returns:
            CaseResult with all verdicts and final disposition.
        """
        if self.procedure is None:
            return CaseResult(
                case_id="no-procedure",
                final_disposition="rejected",
                reason="No procedure defined",
            )

        import uuid

        case_id = uuid.uuid4().hex[:12]
        ctx = CaseContext(case_id=case_id, data=case_data or {})

        # Register case data as evidence sources
        for key, value in (case_data or {}).items():
            if isinstance(value, str):
                self.evidence_validator.add_source(key, value)

        current_step = self.procedure.initial_step
        verdicts: list[Verdict] = []

        for _ in range(self.max_rounds):
            ctx.round_count += 1
            step = self.procedure.get_step(current_step)
            ctx.step_history.append(current_step)

            if step.kind == StepKind.CODE:
                # --- Deterministic code execution ---
                if step.handler:
                    ctx = step.handler(ctx)
                    # Refresh evidence sources — handlers may have modified case data
                    for key, value in ctx.data.items():
                        if isinstance(value, str):
                            self.evidence_validator.add_source(key, value)

                if step.next_step("done") is None:
                    # Terminal CODE step
                    return CaseResult(
                        case_id=case_id,
                        verdicts=verdicts,
                        final_disposition=current_step,
                        reason=f"Procedure ended at terminal step '{current_step}'",
                        round_count=ctx.round_count,
                    )
                current_step = self.procedure.transition(current_step, "done")
                continue

            elif step.kind == StepKind.JUDGMENT:
                # --- LLM judgment point ---
                verdict = await self._invoke_judge(ctx, step)
                verdicts.append(verdict)
                ctx.findings.append(verdict)

                # Stall detection
                fp = compute_fingerprint(verdict.findings)
                if fp:
                    stalled = self.stall_detector.check(fp)
                    ctx.gap_fingerprints.append(fp)
                    if stalled:
                        logger.warning(
                            f"Stall detected at step '{current_step}' "
                            f"(fingerprint {fp}, count={self.stall_detector.count})"
                        )
                        return CaseResult(
                            case_id=case_id,
                            verdicts=verdicts,
                            final_disposition="stalled",
                            reason=f"Same gap fingerprint appeared {self.stall_detector.count} consecutive times",
                            round_count=ctx.round_count,
                        )

                # Route based on verdict
                if verdict.blocking:
                    route = "blocked"
                elif verdict.refuted:
                    route = "refuted"
                else:
                    route = "not_refuted"

                # Check if this step has a defined transition for this route.
                # Use next_step() (returns None if absent) rather than comparing
                # transition() == current_step (which confuses loops with terminals).
                if step.next_step(route) is None:
                    # No transition — verdict is final
                    disposition = (
                        "approved" if not verdict.refuted
                        else "blocked" if verdict.blocking
                        else "rejected"
                    )
                    return CaseResult(
                        case_id=case_id,
                        verdicts=verdicts,
                        final_disposition=disposition,
                        reason=verdict.reasoning,
                        round_count=ctx.round_count,
                    )
                current_step = self.procedure.transition(current_step, route)
                continue

        # Max rounds exceeded
        return CaseResult(
            case_id=case_id,
            verdicts=verdicts,
            final_disposition="max_rounds",
            reason=f"Procedure did not converge within {self.max_rounds} rounds",
            round_count=ctx.round_count,
        )

    async def _invoke_judge(self, ctx: CaseContext, step: Step) -> Verdict:
        """Invoke LLM at a judgment point, enforcing all hard constraints.

        1. Build evidence packet + judgment prompt
        2. Call LLM
        3. Parse verdict (with fallback → default to reject)
        4. Validate evidence (insufficient → force reject)
        """
        # Get applicable statutes
        statute_list = self.statute_book.get_all(step.statutes or [])

        # Build the judgment prompt
        prompt = self._build_judgment_prompt(ctx, statute_list, step)

        # Call LLM
        if self.llm is None:
            return Verdict(
                finding="no_llm",
                refuted=True,
                blocking=True,
                reasoning="No LLM backend configured",
            )

        try:
            raw = await self.llm.judge(prompt)
        except Exception as e:
            logger.error(f"LLM judge failed: {e}")
            return Verdict(
                finding="llm_error",
                refuted=True,
                blocking=True,
                blocking_kind=BLOCKING_CONTRADICTION,
                fallback_note=f"LLM call failed: {e}",
            )

        # Parse verdict (never raises)
        verdict = VerdictParser.parse(raw)

        # Enforce evidence rules
        for statute in statute_list:
            if statute.required_evidence:
                rule = EvidenceRule(
                    required_sources=statute.required_evidence,
                    min_citations=1,
                )
                passed, reason = rule.validate(verdict.evidence_refs)
                if not passed:
                    logger.warning(
                        f"Evidence rule violated for statute '{statute.name}': {reason}"
                    )
                    verdict.refuted = True
                    verdict.blocking = True
                    verdict.fallback_note = (
                        f"Evidence insufficient: {reason}"
                    )
                    break

        # Validate cited evidence actually exists
        if verdict.evidence_refs:
            all_valid, failures = self.evidence_validator.validate_all(
                verdict.evidence_refs
            )
            if not all_valid:
                logger.warning(f"Evidence validation failures: {failures}")
                # Force reject on unverifiable evidence — fail-closed invariant.
                # An LLM citing evidence that doesn't exist in the source material
                # is a hallucination and must never result in a passing verdict.
                verdict.refuted = True

        return verdict

    def _build_judgment_prompt(
        self,
        ctx: CaseContext,
        statutes: list[Statute],
        step: Step,
    ) -> str:
        """Build the judgment prompt for the LLM judge.

        Formats an evidence packet modeled after Grok Build's verifier prompt
        structure: OBJECTIVE, EVIDENCE, RULES, OUTPUT CONTRACT.
        """
        import json as json_mod

        lines = [
            "You are an adversarial judge applying hard constraints to agent output.",
            "",
            "## OBJECTIVE",
            ctx.data.get("objective", "(no objective specified)"),
            "",
            "## CASE DATA",
        ]

        # Include case data (excluding very large fields)
        for key, value in ctx.data.items():
            value_str = str(value)
            if len(value_str) > 2000:
                value_str = value_str[:2000] + "\n... (truncated)"
            lines.append(f"### {key}")
            lines.append(value_str)
            lines.append("")

        # Applicable statutes
        if statutes:
            lines.append("## APPLICABLE STATUTES")
            for s in statutes:
                lines.append(f"### {s.name}: {s.description}")
                lines.append(f"Required evidence: {', '.join(s.required_evidence)}")
                if s.violations:
                    lines.append("Violations to check:")
                    for v in s.violations:
                        lines.append(
                            f"  - {v.name} ({v.severity}): {v.description}"
                        )
                lines.append(f"Default to reject: {s.default_to_reject}")
                lines.append("")

        # Prior gaps
        prior_gaps = [
            f
            for verdict in ctx.findings
            for f in verdict.findings
            if not f.is_empty()
        ]
        if prior_gaps:
            lines.append("## PRIOR GAPS (from previous rounds)")
            for g in prior_gaps:
                lines.append(f"- [{g.kind}] {g.location}: {g.detail}")
            lines.append("")

        # Decision rules
        lines.extend([
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
            '  "finding": "<violation type name or \'none\'>",',
            '  "refuted": true|false,',
            '  "confidence": "high"|"medium"|"low",',
            '  "blocking": "none"|"contradiction"|"unverifiable",',
            '  "evidence_refs": [{"source": "...", "location": "...", "snippet": "...", "kind": "text"}],',
            '  "reasoning": "<explanation>",',
            '  "findings": [{"kind": "bug|gap|todo", "location": "path:line", "detail": "..."}]',
            "}",
            "",
            "Your terminal response must be EXACTLY one of:",
            "Refuted",
            "Not Refuted",
        ])

        return "\n".join(lines)
