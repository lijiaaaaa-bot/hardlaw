"""
01 — Hello World: the minimal hardlaw example.

Shows the absolute minimum to get a Court running:
  1. Define one Statute
  2. Define a one-step Procedure
  3. Hear a case with a Mock LLM

Run:
    python examples/01_hello_world.py
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
    MockLLM,
    Court,
)


# ── Define a simple statute ──────────────────────────────────

honesty_statute = Statute(
    name="honesty_check",
    description="Agent outputs must not contain fabricated claims.",
    threshold={"confidence_min": "medium"},
    required_evidence=["source_text"],
    violations=[
        ViolationType("fabrication", "critical", "Claimed fact not found in source"),
        ViolationType("exaggeration", "medium", "Claim is stronger than source supports"),
    ],
    escalation=EscalationRule(max_violations=2, action="block"),
    default_to_reject=True,
)

# ── Define a simple procedure ─────────────────────────────────

procedure = Procedure(
    name="simple_honesty_check",
    initial_step="verify",
    steps=[
        Step(
            name="verify",
            kind=StepKind.JUDGMENT,
            statutes=["honesty_check"],
            transitions={
                "not_refuted": "verify",  # Loop until clean (terminal here)
                "refuted": "verify",
                "blocked": "verify",
            },
        ),
    ],
    max_rounds=2,
)

# ── Mock LLM responses ────────────────────────────────────────

# Round 1: finds a fabrication — cites source truth, notes fabrication in reasoning
# Round 2: passes — all claims match source
mock_responses = [
    # Round 1: refuted
    (
        '{"finding": "fabrication", "refuted": true, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": [{"source": "source_text", "location": "paragraph 1", "snippet": "the sky is blue", "kind": "text"}],'
        '"reasoning": "Source says sky is blue, agent claimed green.",'
        '"findings": [{"kind": "bug", "location": "output:1", "detail": "Fabricated color claim"}]}'
    ),
    # Round 2: clean
    (
        '{"finding": "none", "refuted": false, "confidence": "high",'
        '"blocking": "none",'
        '"evidence_refs": [{"source": "source_text", "location": "paragraph 1", "snippet": "the sky is blue", "kind": "text"}],'
        '"reasoning": "All claims match source.",'
        '"findings": []}'
    ),
]


async def main():
    court = Court(
        statutes=[honesty_statute],
        procedure=procedure,
        llm=MockLLM(responses=mock_responses),
    )

    case = {
        "objective": "Verify that the agent output is factually accurate.",
        "source_text": "the sky is blue. water is wet.",
        "agent_output": "the sky is green. water is wet.",
    }

    result = await court.hear(case)

    print("=" * 60)
    print("Hello World — hardlaw minimal example")
    print("=" * 60)
    print(f"\nCase ID: {result.case_id}")
    print(f"Rounds: {result.round_count}")
    print(f"Disposition: {result.final_disposition}")
    print(f"Reason: {result.reason}")

    print(f"\nVerdicts ({len(result.verdicts)}):")
    for i, v in enumerate(result.verdicts):
        emoji = "❌" if v.refuted else "✅"
        print(f"  Round {i+1}: {emoji} {v.finding} ({v.confidence.value})")
        if v.findings:
            for f in v.findings:
                print(f"    - [{f.kind}] {f.location}: {f.detail}")

    print("\n✅ Example complete.")


if __name__ == "__main__":
    asyncio.run(main())
