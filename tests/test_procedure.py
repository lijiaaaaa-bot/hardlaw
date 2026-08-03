"""Tests for procedure.py — State machine, steps, stall detection."""

import pytest
from hardlaw.procedure import (
    Step,
    StepKind,
    Procedure,
    CaseContext,
    StallDetector,
)


class TestStep:
    def test_code_step(self):
        step = Step(
            name="validate",
            kind=StepKind.CODE,
            transitions={"done": "next_step"},
        )
        assert step.name == "validate"
        assert step.kind == StepKind.CODE
        assert step.next_step("done") == "next_step"
        assert step.next_step("unknown") is None

    def test_judgment_step(self):
        step = Step(
            name="review",
            kind=StepKind.JUDGMENT,
            statutes=["hate_speech"],
            transitions={
                "refuted": "fix",
                "not_refuted": "approved",
                "blocked": "rejected",
            },
        )
        assert step.kind == StepKind.JUDGMENT
        assert step.statutes == ["hate_speech"]
        assert step.next_step("refuted") == "fix"
        assert step.next_step("not_refuted") == "approved"

    def test_terminal_step(self):
        step = Step(name="done", kind=StepKind.CODE)
        assert step.transitions == {}
        assert step.next_step("anything") is None


class TestCaseContext:
    def test_create(self):
        ctx = CaseContext(case_id="test-1")
        assert ctx.case_id == "test-1"
        assert ctx.round_count == 0
        assert ctx.findings == []
        assert ctx.gap_fingerprints == []

    def test_data_access(self):
        ctx = CaseContext(case_id="test", data={"key": "value"})
        assert ctx.data["key"] == "value"

    def test_metadata(self):
        ctx = CaseContext(case_id="test")
        ctx.metadata["flag"] = True
        assert ctx.metadata["flag"] is True


class TestStallDetector:
    def test_initial_state(self):
        sd = StallDetector(threshold=2)
        assert sd.count == 0
        assert sd.last_fingerprint is None

    def test_no_stall_on_first(self):
        sd = StallDetector(threshold=2)
        assert sd.check("fp-a") is False
        assert sd.count == 1
        assert sd.last_fingerprint == "fp-a"

    def test_stall_on_second_same(self):
        sd = StallDetector(threshold=2)
        sd.check("fp-a")
        assert sd.check("fp-a") is True
        assert sd.count == 2

    def test_no_stall_on_different(self):
        sd = StallDetector(threshold=2)
        sd.check("fp-a")
        assert sd.check("fp-b") is False
        assert sd.count == 1
        assert sd.last_fingerprint == "fp-b"

    def test_custom_threshold(self):
        sd = StallDetector(threshold=3)
        sd.check("fp-a")
        sd.check("fp-a")
        assert sd.check("fp-a") is True
        assert sd.count == 3

    def test_empty_fingerprint(self):
        sd = StallDetector(threshold=2)
        assert sd.check("") is False
        assert sd.count == 0

    def test_reset(self):
        sd = StallDetector(threshold=2)
        sd.check("fp-a")
        sd.check("fp-a")
        sd.reset()
        assert sd.count == 0
        assert sd.last_fingerprint is None
        # After reset, same fingerprint is fresh
        assert sd.check("fp-a") is False
        assert sd.count == 1

    def test_pattern_change_resets(self):
        """fp-a, fp-a (stall), fp-b (reset), fp-b (stall again)."""
        sd = StallDetector(threshold=2)
        sd.check("fp-a")
        assert sd.check("fp-a") is True  # stall on fp-a
        assert sd.check("fp-b") is False  # different, reset to 1
        assert sd.check("fp-b") is True  # stall on fp-b
        assert sd.count == 2


class TestProcedure:
    def test_create(self):
        steps = [
            Step(name="start", kind=StepKind.CODE, transitions={"done": "end"}),
            Step(name="end", kind=StepKind.CODE),
        ]
        proc = Procedure(name="test", steps=steps, initial_step="start")
        assert proc.name == "test"
        assert proc.initial_step == "start"
        assert proc.get_step("start").name == "start"

    def test_initial_step_defaults_to_first(self):
        steps = [
            Step(name="first", kind=StepKind.CODE),
            Step(name="second", kind=StepKind.CODE),
        ]
        proc = Procedure(name="test", steps=steps)
        assert proc.initial_step == "first"

    def test_invalid_initial_step(self):
        steps = [Step(name="only", kind=StepKind.CODE)]
        with pytest.raises(ValueError, match="initial_step"):
            Procedure(name="test", steps=steps, initial_step="nonexistent")

    def test_transition(self):
        steps = [
            Step(name="review", kind=StepKind.JUDGMENT,
                 transitions={"refuted": "fix", "not_refuted": "done"}),
            Step(name="fix", kind=StepKind.CODE, transitions={"done": "review"}),
            Step(name="done", kind=StepKind.CODE),
        ]
        proc = Procedure(name="test", steps=steps)

        assert proc.transition("review", "refuted") == "fix"
        assert proc.transition("review", "not_refuted") == "done"
        # Terminal step returns itself
        assert proc.transition("done", "anything") == "done"

    def test_is_terminal(self):
        steps = [
            Step(name="start", kind=StepKind.CODE, transitions={"done": "end"}),
            Step(name="end", kind=StepKind.CODE),
        ]
        proc = Procedure(name="test", steps=steps)
        assert proc.is_terminal("end") is True
        assert proc.is_terminal("start") is False

    def test_step_names(self):
        steps = [
            Step(name="a", kind=StepKind.CODE),
            Step(name="b", kind=StepKind.JUDGMENT),
            Step(name="c", kind=StepKind.CODE),
        ]
        proc = Procedure(name="test", steps=steps)
        assert proc.step_names() == ["a", "b", "c"]

    def test_get_step_missing(self):
        proc = Procedure(name="test", steps=[Step(name="only", kind=StepKind.CODE)])
        with pytest.raises(KeyError):
            proc.get_step("nonexistent")

    def test_default_values(self):
        steps = [Step(name="start", kind=StepKind.CODE)]
        proc = Procedure(name="test", steps=steps)
        assert proc.max_rounds == 10
        assert proc.stall_threshold == 2

    def test_to_dict(self):
        steps = [
            Step(name="review", kind=StepKind.JUDGMENT,
                 statutes=["statute_a"],
                 transitions={"refuted": "end"}),
            Step(name="end", kind=StepKind.CODE),
        ]
        proc = Procedure(name="audit", steps=steps, max_rounds=5)
        d = proc.to_dict()
        assert d["name"] == "audit"
        assert d["max_rounds"] == 5
        assert len(d["steps"]) == 2
        assert d["steps"][0]["statutes"] == ["statute_a"]
        assert d["steps"][0]["transitions"] == {"refuted": "end"}
