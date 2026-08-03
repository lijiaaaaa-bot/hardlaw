"""
02 — Content Moderation: hate speech detection with evidence grounding.

Models a content moderation agent where:
  - Statute defines what constitutes hate speech
  - Procedure: review → classify severity → route (approve/warn/block)
  - Evidence: LLM must cite the exact offending text snippet
  - Stall detection: same violation twice → escalate to block

Run:
    python examples/02_content_moderation.py
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

hate_speech_statute = Statute(
    name="hate_speech",
    description="Content must not contain hate speech targeting protected groups.",
    threshold={"confidence_min": "medium"},
    required_evidence=["content"],
    violations=[
        ViolationType("slur", "critical", "Use of recognized slurs"),
        ViolationType("dehumanization", "high", "Dehumanizing language"),
        ViolationType("incitement", "critical", "Incitement to violence"),
        ViolationType("stereotyping", "medium", "Harmful stereotyping"),
    ],
    escalation=EscalationRule(max_violations=2, action="block"),
    default_to_reject=True,
    blocking=True,
)


# ── CODE step handlers ────────────────────────────────────────

def approve_content(ctx: CaseContext) -> CaseContext:
    ctx.metadata["action"] = "approved"
    return ctx

def warn_author(ctx: CaseContext) -> CaseContext:
    ctx.metadata["action"] = "warned"
    return ctx

def block_content(ctx: CaseContext) -> CaseContext:
    ctx.metadata["action"] = "blocked"
    return ctx


# ── Procedure ─────────────────────────────────────────────────

moderation_procedure = Procedure(
    name="content_moderation",
    initial_step="review_content",
    steps=[
        Step(
            name="review_content",
            kind=StepKind.JUDGMENT,
            statutes=["hate_speech"],
            transitions={
                "not_refuted": "approved",
                "refuted": "classify_severity",
                "blocked": "blocked",
            },
        ),
        Step(
            name="classify_severity",
            kind=StepKind.JUDGMENT,
            statutes=["hate_speech"],
            transitions={
                "not_refuted": "warned",      # Low severity → warn
                "refuted": "blocked",          # High severity → block
                "blocked": "blocked",
            },
        ),
        Step(name="approved", kind=StepKind.CODE, handler=approve_content),
        Step(name="warned", kind=StepKind.CODE, handler=warn_author),
        Step(name="blocked", kind=StepKind.CODE, handler=block_content),
    ],
    max_rounds=5,
    stall_threshold=2,
)


# ── Mock scenarios ────────────────────────────────────────────

def make_clean_response():
    return (
        '{"finding": "none", "refuted": false, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": [{"source": "content", "location": "full text", "snippet": "I think we should improve our community standards.", "kind": "text"}],'
        '"reasoning": "Content is respectful, no violation found.",'
        '"findings": []}'
    )

def make_violation_response():
    return (
        '{"finding": "dehumanization", "refuted": true, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": [{"source": "content", "location": "paragraph 2", "snippet": "they are like animals", "kind": "text"}],'
        '"reasoning": "Paragraph 2 uses dehumanizing comparison against a protected group.",'
        '"findings": [{"kind": "gap", "location": "content:paragraph 2", "detail": "Dehumanizing language: compares group to animals"}]}'
    )

def make_severity_high_response():
    return (
        '{"finding": "incitement", "refuted": true, "confidence": "high",'
        '"blocking": true, "blocking_kind": "none",'
        '"evidence_refs": [{"source": "content", "location": "paragraph 2", "snippet": "we must take action against them", "kind": "text"}],'
        '"reasoning": "Content incites action against a protected group — high severity.",'
        '"findings": [{"kind": "gap", "location": "content:paragraph 2", "detail": "Incitement language detected"}]}'
    )

def make_severity_low_response():
    return (
        '{"finding": "stereotyping", "refuted": false, "confidence": "medium",'
        '"blocking": false,'
        '"evidence_refs": [{"source": "content", "location": "paragraph 1", "snippet": "they tend to be good at math", "kind": "text"}],'
        '"reasoning": "Mild stereotype — warrants a warning but not a block.",'
        '"findings": [{"kind": "gap", "location": "content:paragraph 1", "detail": "Stereotyping language"}]}'
    )


async def run_scenario(name: str, case: dict, responses: list[str]):
    print(f"\n{'─' * 60}")
    print(f"Scenario: {name}")
    print(f"Content: {case['content'][:80]}...")
    print(f"{'─' * 60}")

    court = Court(
        statutes=[hate_speech_statute],
        procedure=moderation_procedure,
        llm=MockLLM(responses=responses),
    )

    result = await court.hear(case)

    print(f"  Rounds: {result.round_count}")
    print(f"  Disposition: {result.final_disposition}")
    print(f"  Action: {result.final_disposition}")
    for i, v in enumerate(result.verdicts):
        emoji = "❌" if v.refuted else "✅"
        print(f"    Verdict {i+1}: {emoji} {v.finding} ({v.confidence.value})")
    print(f"  Reason: {result.reason[:120]}")


async def main():
    print("=" * 60)
    print("Content Moderation — hardlaw example")
    print("=" * 60)

    # Scenario 1: Clean content
    await run_scenario(
        "Clean content passes",
        {"content": "I think we should improve our community standards. Let's work together.", "author": "user_a"},
        [make_clean_response()],
    )

    # Scenario 2: Violation → high severity → block
    await run_scenario(
        "Violation → high severity → block",
        {
            "content": "Some people say things. But they are like animals and we must take action against them.",
            "author": "user_b",
        },
        [
            '{"finding": "dehumanization", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "p2", "snippet": "they are like animals", "kind": "text"}], "reasoning": "Dehumanizing comparison.", "findings": [{"kind": "gap", "location": "content:p2", "detail": "Dehumanizing language"}]}',
            '{"finding": "incitement", "refuted": true, "confidence": "high", "blocking": true, "blocking_kind": "none", "evidence_refs": [{"source": "content", "location": "p2", "snippet": "we must take action against them", "kind": "text"}], "reasoning": "Incites action against a protected group.", "findings": [{"kind": "gap", "location": "content:p2", "detail": "Incitement detected"}]}',
        ],
    )

    # Scenario 3: Violation → low severity → warn
    await run_scenario(
        "Violation → low severity → warn",
        {
            "content": "In my experience, they tend to be good at math. Just an observation.",
            "author": "user_c",
        },
        [
            '{"finding": "dehumanization", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "p1", "snippet": "they tend to be good at math", "kind": "text"}], "reasoning": "Harmful stereotype about a protected group.", "findings": [{"kind": "gap", "location": "content:p1", "detail": "Stereotyping language"}]}',
            '{"finding": "stereotyping", "refuted": false, "confidence": "medium", "blocking": false, "blocking_kind": "none", "evidence_refs": [{"source": "content", "location": "p1", "snippet": "they tend to be good at math", "kind": "text"}], "reasoning": "Mild stereotype — warrants a warning not a block.", "findings": [{"kind": "gap", "location": "content:p1", "detail": "Stereotyping classified as low severity"}]}',
        ],
    )

    print(f"\n✅ All scenarios complete.")


if __name__ == "__main__":
    asyncio.run(main())
