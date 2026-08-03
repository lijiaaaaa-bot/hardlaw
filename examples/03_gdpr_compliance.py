"""
03 — GDPR Compliance Audit: multi-step sequential judgment.

Models a GDPR compliance review agent with multiple statutes:
  1. Check consent mechanism (must exist, must be specific)
  2. Check retention policy (must have defined period)
  3. Each step has its own fix-retry loop

This demonstrates:
  - Multiple statutes applied at different judgment points
  - CODE steps for requesting fixes between judgments
  - Anti-ratchet: prior gaps are replayed in each round

Run:
    python examples/03_gdpr_compliance.py
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import asyncio
from hardlaw import (
    Statute,
    ViolationType,
    EscalationRule,
    Procedure,
    Step,
    StepKind,
    CaseContext,
    MockLLM,
    Court,
)


# ── Statutes ──────────────────────────────────────────────────

consent_statute = Statute(
    name="gdpr_consent",
    description="Data processing must have valid consent or legal basis (GDPR Art. 6-7).",
    required_evidence=["privacy_policy", "consent_mechanism"],
    threshold={"confidence_min": "high"},
    violations=[
        ViolationType("missing_consent", "critical", "No consent mechanism found"),
        ViolationType("vague_purpose", "high", "Purpose statement too vague for GDPR"),
        ViolationType("no_opt_out", "high", "No mechanism to withdraw consent"),
        ViolationType("bundled_consent", "medium", "Consent bundled with unrelated terms"),
    ],
    escalation=EscalationRule(max_violations=3, action="block"),
    default_to_reject=True,
)

retention_statute = Statute(
    name="gdpr_retention",
    description="Data must have defined retention period (GDPR Art. 5(1)(e)).",
    required_evidence=["retention_policy"],
    threshold={"confidence_min": "medium"},
    violations=[
        ViolationType("indefinite_retention", "critical", "No retention limit specified"),
        ViolationType("excessive_retention", "high", "Retention period exceeds necessity"),
        ViolationType("no_deletion_policy", "high", "No procedure for data deletion"),
    ],
    escalation=EscalationRule(max_violations=2, action="block"),
    default_to_reject=True,
)


# ── CODE step handlers ────────────────────────────────────────

def fix_consent_request(ctx: CaseContext) -> CaseContext:
    """Simulate requesting a consent fix from the data controller."""
    ctx.metadata["consent_fix_requested"] = True
    ctx.data["consent_mechanism"] = "UPDATED: Explicit opt-in checkbox, unbundled from ToS."
    return ctx

def fix_retention_request(ctx: CaseContext) -> CaseContext:
    """Simulate requesting a retention fix."""
    ctx.metadata["retention_fix_requested"] = True
    ctx.data["retention_policy"] = "UPDATED: Data retained for 24 months, then anonymized."
    return ctx

def issue_certificate(ctx: CaseContext) -> CaseContext:
    ctx.metadata["action"] = "certified"
    return ctx

def report_violation(ctx: CaseContext) -> CaseContext:
    ctx.metadata["action"] = "reported_to_dpa"
    return ctx


# ── Procedure ─────────────────────────────────────────────────

gdpr_procedure = Procedure(
    name="gdpr_compliance_audit",
    initial_step="check_consent",
    steps=[
        Step(
            name="check_consent",
            kind=StepKind.JUDGMENT,
            statutes=["gdpr_consent"],
            transitions={
                "not_refuted": "check_retention",
                "refuted": "fix_consent",
                "blocked": "rejected",
            },
        ),
        Step(
            name="fix_consent",
            kind=StepKind.CODE,
            handler=fix_consent_request,
            transitions={"done": "check_consent"},
        ),
        Step(
            name="check_retention",
            kind=StepKind.JUDGMENT,
            statutes=["gdpr_retention"],
            transitions={
                "not_refuted": "approved",
                "refuted": "fix_retention",
                "blocked": "rejected",
            },
        ),
        Step(
            name="fix_retention",
            kind=StepKind.CODE,
            handler=fix_retention_request,
            transitions={"done": "check_retention"},
        ),
        Step(name="approved", kind=StepKind.CODE, handler=issue_certificate),
        Step(name="rejected", kind=StepKind.CODE, handler=report_violation),
    ],
    max_rounds=10,
)


# ── Mock responses ────────────────────────────────────────────

def consent_refuted():
    """Consent check fails — vague purpose."""
    return (
        '{"finding": "vague_purpose", "refuted": true, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": ['
        '{"source": "privacy_policy", "location": "section 2", "snippet": "We process your data to improve our services", "kind": "text"},'
        '{"source": "consent_mechanism", "location": "N/A", "snippet": "Checkbox bundled with Terms of Service acceptance", "kind": "text"}'
        '],'
        '"reasoning": "Purpose statement is too vague — does not meet GDPR Art. 5(1)(b) specificity.",'
        '"findings": [{"kind": "gap", "location": "privacy_policy:section 2", "detail": "Purpose \'improve our services\' is not specific enough for consent"}]}'
    )

def consent_passed():
    """Consent check passes after fix."""
    return (
        '{"finding": "none", "refuted": false, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": ['
        '{"source": "consent_mechanism", "location": "N/A", "snippet": "Explicit opt-in checkbox, unbundled from ToS", "kind": "text"},'
        '{"source": "privacy_policy", "location": "section 2", "snippet": "We process your data to improve our services", "kind": "text"}'
        '],'
        '"reasoning": "Consent mechanism is explicit, specific, and unbundled — meets GDPR Art. 7.",'
        '"findings": []}'
    )

def retention_refuted():
    """Retention check fails — no limit."""
    return (
        '{"finding": "indefinite_retention", "refuted": true, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": [{"source": "retention_policy", "location": "section 5", "snippet": "Data will be kept for as long as necessary", "kind": "text"}],'
        '"reasoning": "No specific retention period defined — violates GDPR Art. 5(1)(e).",'
        '"findings": [{"kind": "gap", "location": "retention_policy:section 5", "detail": "Retention period is indefinite — no specific time limit"}]}'
    )

def retention_passed():
    """Retention check passes after fix."""
    return (
        '{"finding": "none", "refuted": false, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": [{"source": "retention_policy", "location": "section 5", "snippet": "Data retained for 24 months, then anonymized", "kind": "text"}],'
        '"reasoning": "Clear retention period with defined anonymization procedure — meets GDPR Art. 5(1)(e).",'
        '"findings": []}'
    )


async def main():
    print("=" * 60)
    print("GDPR Compliance Audit — hardlaw example")
    print("=" * 60)

    responses = [
        consent_refuted(),     # Round 1: consent fails
        consent_passed(),      # Round 2: consent fixed
        retention_refuted(),   # Round 3: retention fails
        retention_passed(),    # Round 4: retention fixed
    ]

    court = Court(
        statutes=[consent_statute, retention_statute],
        procedure=gdpr_procedure,
        llm=MockLLM(responses=responses),
    )

    case = {
        "objective": "Audit GDPR compliance for data processing activities.",
        "privacy_policy": "We process your data to improve our services. ...",
        "consent_mechanism": "Checkbox bundled with Terms of Service acceptance.",
        "retention_policy": "Data will be kept for as long as necessary.",
    }

    result = await court.hear(case)

    print(f"\nCase ID: {result.case_id}")
    print(f"Rounds: {result.round_count}")
    print(f"Disposition: {result.final_disposition}")
    print(f"\nSteps visited: {len(result.verdicts)} judgment rounds across the procedure")

    print(f"\nVerdicts ({len(result.verdicts)}):")
    for i, v in enumerate(result.verdicts):
        emoji = "❌" if v.refuted else "✅"
        print(f"  Round {i+1}: {emoji} {v.finding} ({v.confidence.value})")
        if v.findings:
            for f in v.findings:
                print(f"    - [{f.kind}] {f.location}: {f.detail}")
        if v.fallback_note:
            print(f"    ⚠️  Fallback: {v.fallback_note}")

    print(f"\nFinal: {result.final_disposition} — {result.reason}")
    print("\n✅ Example complete.")


if __name__ == "__main__":
    asyncio.run(main())
