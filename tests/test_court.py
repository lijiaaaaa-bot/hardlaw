"""Tests for court.py — Runtime orchestrator integration tests."""

import pytest
import asyncio
from hardlaw.statute import Statute, ViolationType, EscalationRule
from hardlaw.procedure import Procedure, Step, StepKind, CaseContext
from hardlaw.llm import MockLLM
from hardlaw.court import Court, CaseResult
from hardlaw.verdict import VerdictParser


# ── Fixtures ──────────────────────────────────────────────────

@pytest.fixture
def simple_statute():
    return Statute(
        name="test_statute",
        description="A test statute",
        required_evidence=["content"],
        violations=[
            ViolationType("violation", "high", "A violation"),
        ],
        default_to_reject=True,
    )


@pytest.fixture
def simple_procedure():
    return Procedure(
        name="simple_test",
        initial_step="review",
        steps=[
            Step(
                name="review",
                kind=StepKind.JUDGMENT,
                statutes=["test_statute"],
                transitions={
                    "not_refuted": "approved",
                    "refuted": "review",  # loop
                    "blocked": "rejected",
                },
            ),
            Step(name="approved", kind=StepKind.CODE),
            Step(name="rejected", kind=StepKind.CODE),
        ],
        max_rounds=5,
    )


# ── Tests ─────────────────────────────────────────────────────

class TestCourtBasic:
    async def test_approved_case(self, simple_statute, simple_procedure):
        """A clean case passes on first round."""
        court = Court(
            statutes=[simple_statute],
            procedure=simple_procedure,
            llm=MockLLM(responses=[
                '{"finding": "none", "refuted": false, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "N/A", "snippet": "clean content", "kind": "text"}], "findings": [], "reasoning": "All good."}',
            ]),
        )
        result = await court.hear({"content": "clean content"})
        # Round count: 1 (JUDGMENT) + 1 (CODE terminal) = 2
        assert result.final_disposition == "approved"
        assert result.round_count == 2
        assert len(result.verdicts) == 1
        assert result.verdicts[0].refuted is False

    async def test_refuted_then_approved(self, simple_statute, simple_procedure):
        """First round fails, second round passes (fix loop)."""
        responses = [
            # Round 1: violation found
            '{"finding": "violation", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "p1", "snippet": "bad stuff", "kind": "text"}], "findings": [{"kind": "gap", "location": "content:p1", "detail": "Found bad stuff"}], "reasoning": "Violation detected."}',
            # Round 2: fixed
            '{"finding": "none", "refuted": false, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "p1", "snippet": "fixed content", "kind": "text"}], "findings": [], "reasoning": "Fixed."}',
        ]
        court = Court(
            statutes=[simple_statute],
            procedure=simple_procedure,
            llm=MockLLM(responses=responses),
        )
        # Round count: 1 (JUDGMENT refuted) + 1 (JUDGMENT not_refuted) + 1 (CODE terminal) = 3
        # Content must contain all snippets cited by LLM for evidence validation to pass
        result = await court.hear({"content": "bad stuff. Then fixed content."})
        assert result.final_disposition == "approved"
        assert result.round_count == 3
        assert len(result.verdicts) == 2

    async def test_blocked_case(self, simple_statute, simple_procedure):
        """A blocking violation stops the procedure."""
        court = Court(
            statutes=[simple_statute],
            procedure=simple_procedure,
            llm=MockLLM(responses=[
                '{"finding": "violation", "refuted": true, "confidence": "high", "blocking": "contradiction", "evidence_refs": [{"source": "content", "location": "p1", "snippet": "bad", "kind": "text"}], "findings": [{"kind": "gap", "location": "content:p1", "detail": "Critical"}], "reasoning": "Blocking violation."}',
            ]),
        )
        result = await court.hear({"content": "bad content"})
        assert result.final_disposition == "rejected"

    async def test_no_llm_configured(self, simple_statute, simple_procedure):
        """Without an LLM backend, returns a no_llm verdict."""
        court = Court(
            statutes=[simple_statute],
            procedure=simple_procedure,
            llm=None,
        )
        result = await court.hear({"content": "test"})
        assert result.verdicts[0].finding == "no_llm"
        assert result.verdicts[0].refuted is True

    async def test_no_procedure(self):
        """Without a procedure, returns rejected immediately."""
        court = Court(llm=MockLLM())
        result = await court.hear({"content": "test"})
        assert result.final_disposition == "rejected"
        assert "No procedure" in result.reason


class TestCourtStallDetection:
    async def test_stall_detected(self):
        """Same gap twice → stall."""
        statute = Statute(name="test", required_evidence=["content"])
        procedure = Procedure(
            name="stall_test",
            initial_step="review",
            steps=[
                Step(
                    name="review",
                    kind=StepKind.JUDGMENT,
                    statutes=["test"],
                    transitions={"refuted": "review"},
                ),
            ],
            max_rounds=10,
            stall_threshold=2,
        )
        # Same violation twice — identical findings → same fingerprint
        violation_response = (
            '{"finding": "violation", "refuted": true, "confidence": "high", "blocking": "none",'
            '"evidence_refs": [{"source": "content", "location": "line 1", "snippet": "bad", "kind": "text"}],'
            '"findings": [{"kind": "gap", "location": "file:1", "detail": "Same issue every round"}],'
            '"reasoning": "Same violation."}'
        )
        court = Court(
            statutes=[statute],
            procedure=procedure,
            llm=MockLLM(responses=[violation_response, violation_response]),
            stall_threshold=2,
        )
        result = await court.hear({"content": "bad"})
        assert result.final_disposition == "stalled"
        assert "Same gap fingerprint" in result.reason

    async def test_no_stall_with_different_gaps(self):
        """Different gaps each round → no stall."""
        statute = Statute(name="test", required_evidence=["content"])
        procedure = Procedure(
            name="no_stall_test",
            initial_step="review",
            steps=[
                Step(
                    name="review",
                    kind=StepKind.JUDGMENT,
                    statutes=["test"],
                    transitions={"refuted": "review"},
                ),
            ],
            max_rounds=2,
            stall_threshold=2,
        )
        court = Court(
            statutes=[statute],
            procedure=procedure,
            llm=MockLLM(responses=[
                '{"finding": "gap_a", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "line 1", "snippet": "test", "kind": "text"}], "findings": [{"kind": "gap", "location": "file:1", "detail": "Different issue A"}], "reasoning": "Gap A."}',
                '{"finding": "gap_b", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "line 2", "snippet": "test", "kind": "text"}], "findings": [{"kind": "gap", "location": "file:2", "detail": "Different issue B"}], "reasoning": "Gap B."}',
            ]),
            stall_threshold=2,
        )
        result = await court.hear({"content": "test"})
        # Different fingerprints, no stall — should max out
        assert result.final_disposition == "max_rounds"


class TestCourtEvidenceValidation:
    async def test_evidence_insufficient_forces_reject(self):
        """When the LLM doesn't cite the required source, force reject."""
        statute = Statute(
            name="gdpr",
            required_evidence=["privacy_policy", "consent_form"],
            default_to_reject=True,
        )
        procedure = Procedure(
            name="evidence_test",
            initial_step="review",
            steps=[
                Step(
                    name="review",
                    kind=StepKind.JUDGMENT,
                    statutes=["gdpr"],
                    transitions={"not_refuted": "approved", "refuted": "review"},
                ),
                Step(name="approved", kind=StepKind.CODE),
            ],
            max_rounds=3,
        )
        # LLM says it's fine but only cites privacy_policy, not consent_form
        court = Court(
            statutes=[statute],
            procedure=procedure,
            llm=MockLLM(responses=[
                '{"finding": "none", "refuted": false, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "privacy_policy", "location": "s1", "snippet": "ok", "kind": "text"}], "findings": [], "reasoning": "Looks fine."}',
            ]),
        )
        result = await court.hear({
            "objective": "GDPR audit",
            "privacy_policy": "ok content",
            "consent_form": "consent content",
        })
        # Evidence insufficient → forced to refuted
        # Note: missing required source means verdict gets blocked/rejected
        assert len(result.verdicts) > 0
        # The evidence validation forces refuted=True
        assert result.verdicts[0].refuted is True

    async def test_evidence_verifiable_passes(self):
        """When LLM cites the actual snippet from source, it passes."""
        statute = Statute(
            name="simple",
            required_evidence=["content"],
            default_to_reject=True,
        )
        procedure = Procedure(
            name="verify_test",
            initial_step="review",
            steps=[
                Step(
                    name="review",
                    kind=StepKind.JUDGMENT,
                    statutes=["simple"],
                    transitions={"not_refuted": "approved", "refuted": "review"},
                ),
                Step(name="approved", kind=StepKind.CODE),
            ],
            max_rounds=3,
        )
        # The actual content is "the sky is blue"
        # LLM cites a snippet that IS in the content
        court = Court(
            statutes=[statute],
            procedure=procedure,
            llm=MockLLM(responses=[
                '{"finding": "none", "refuted": false, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "text", "snippet": "sky is blue", "kind": "text"}], "findings": [], "reasoning": "Content is accurate."}',
            ]),
        )
        result = await court.hear({"content": "the sky is blue"})
        # Evidence is verifiable AND all required sources cited → passes
        assert result.final_disposition == "approved"


class TestCourtMaxRounds:
    async def test_max_rounds_exceeded(self):
        """When procedure loops too long, it exits with max_rounds."""
        statute = Statute(name="test")
        procedure = Procedure(
            name="loop_test",
            initial_step="review",
            steps=[
                Step(
                    name="review",
                    kind=StepKind.JUDGMENT,
                    statutes=["test"],
                    transitions={"refuted": "review"},  # always loops
                ),
            ],
            max_rounds=2,
        )
        court = Court(
            statutes=[statute],
            procedure=procedure,
            llm=MockLLM(responses=[
                '{"finding": "gap", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "p1", "snippet": "test", "kind": "text"}], "findings": [{"kind": "gap", "location": "f:1", "detail": "never fixed"}], "reasoning": "Still broken."}',
                '{"finding": "gap", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [{"source": "content", "location": "p1", "snippet": "test", "kind": "text"}], "findings": [{"kind": "gap", "location": "f:2", "detail": "different"}], "reasoning": "Still broken differently."}',
            ]),
        )
        result = await court.hear({"content": "test"})
        assert result.final_disposition == "max_rounds"
        assert result.round_count == 2
