"""Procedure — the state machine that governs agent workflows.

A Procedure defines the steps an agent MUST follow, in what order,
and what transitions are allowed. Steps are of two kinds:

  - CodeStep: deterministic Python function, LLM cannot skip/modify.
  - JudgmentStep: calls LLM for semantic judgment, but input/output
    is constrained by statute schemas and evidence rules.

The state machine is PURE and SYNCHRONOUS — no async I/O.
This matches Grok Build's GoalTracker pattern (goal_tracker.rs:1-5):
"a pure state machine (no async I/O) modeled after PlanModeTracker."

Stall detection is built in: when the same gap fingerprint appears
on consecutive judgment rounds, the procedure escalates.
"""

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Any, Callable


class StepKind(Enum):
    """What kind of step this is.

    CODE: deterministic Python function — LLM has no say.
    JUDGMENT: LLM call point — structured input, structured output.
    """

    CODE = auto()
    JUDGMENT = auto()


@dataclass
class Step:
    """One step in the state machine.

    Attributes:
        name: Unique step identifier within the procedure.
        kind: CODE or JUDGMENT.
        handler: For CODE steps, the function to call.
        statutes: For JUDGMENT steps, which statute names apply.
        transitions: Map of verdict outcome → next step name.
            Common keys: "done" (code step), "refuted", "not_refuted", "blocked".
    """

    name: str
    kind: StepKind
    handler: Callable[["CaseContext"], "CaseContext"] | None = None
    statutes: list[str] | None = None
    transitions: dict[str, str] = field(default_factory=dict)

    def next_step(self, outcome: str) -> str | None:
        """Get the next step name for a given outcome.

        Returns None if no transition defined (terminal step).
        """
        return self.transitions.get(outcome)


@dataclass
class CaseContext:
    """Mutable context that accumulates state through a procedure.

    Mirrors Grok Build's GoalOrchestration struct (goal_tracker.rs:427):
    accumulates round counts, gap fingerprints, and findings.

    Attributes:
        case_id: Unique identifier for this case.
        data: Arbitrary case data (the "case file").
        findings: All verdicts/findings accumulated so far.
        step_history: Ordered list of step names visited.
        gap_fingerprints: SHA-256 hashes of gap findings, for stall detection.
        round_count: Total rounds executed.
        metadata: Arbitrary metadata set by steps.
    """

    case_id: str
    data: dict[str, Any] = field(default_factory=dict)
    findings: list[Any] = field(default_factory=list)  # list[Verdict]
    step_history: list[str] = field(default_factory=list)
    gap_fingerprints: list[str] = field(default_factory=list)
    round_count: int = 0
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class StallDetector:
    """Detect when the same gap fingerprint appears N consecutive times.

    Mirrors Grok Build's record_classifier_stall (goal_tracker.rs:1213-1228):
    identical fingerprint → increment count; different → reset to 1.
    Threshold at GOAL_CLASSIFIER_STALL_THRESHOLD (=2) trips the stall.

    Attributes:
        threshold: Number of consecutive identical fingerprints to trip.
        last_fingerprint: The most recent fingerprint seen.
        count: Consecutive occurrences of `last_fingerprint`.
    """

    threshold: int = 2
    last_fingerprint: str | None = None
    count: int = 0

    def check(self, fingerprint: str) -> bool:
        """Check if this fingerprint triggers a stall.

        Returns True if the same fingerprint has been seen `threshold`
        consecutive times.
        """
        if not fingerprint:
            return False

        if fingerprint == self.last_fingerprint:
            self.count += 1
        else:
            self.last_fingerprint = fingerprint
            self.count = 1

        return self.count >= self.threshold

    def reset(self) -> None:
        """Reset the stall detector state."""
        self.last_fingerprint = None
        self.count = 0


class Procedure:
    """A state machine for multi-step agent workflows.

    The Procedure is the "courtroom procedure" — it defines:
      - What steps must be followed
      - In what order
      - What transitions are allowed

    The LLM CANNOT change the flow. Transitions are deterministic code.

    Attributes:
        name: Human-readable name for this procedure.
        steps: Ordered list of steps.
        initial_step: Name of the step to start at.
        max_rounds: Hard cap on total rounds (runaway backstop).
        stall_threshold: Consecutive identical fingerprints to trigger stall.
    """

    def __init__(
        self,
        name: str,
        steps: list[Step],
        initial_step: str | None = None,
        max_rounds: int = 10,
        stall_threshold: int = 2,
    ):
        self.name = name
        self.steps = steps
        self._step_map: dict[str, Step] = {s.name: s for s in steps}
        self.initial_step = initial_step or (steps[0].name if steps else "")
        self.max_rounds = max_rounds
        self.stall_threshold = stall_threshold

        # Validate: initial_step must exist
        if self.initial_step not in self._step_map:
            raise ValueError(
                f"initial_step '{self.initial_step}' not found in steps"
            )

    def get_step(self, name: str) -> Step:
        """Get a step by name. Raises KeyError if not found."""
        return self._step_map[name]

    def transition(self, current: str, outcome: str) -> str:
        """Compute the next step based on a verdict outcome.

        This is DETERMINISTIC — no LLM involvement.

        Args:
            current: Current step name.
            outcome: Verdict outcome string ("done", "refuted", "not_refuted", "blocked").

        Returns:
            Next step name, or `current` if no transition defined (terminal).
        """
        step = self._step_map[current]
        return step.transitions.get(outcome, current)

    def is_terminal(self, step_name: str) -> bool:
        """Check if a step is terminal (has no transitions)."""
        step = self._step_map.get(step_name)
        return step is not None and not step.transitions

    def step_names(self) -> list[str]:
        """Return all step names in order."""
        return [s.name for s in self.steps]

    def to_dict(self) -> dict[str, Any]:
        """Serialize procedure structure (not handlers)."""
        return {
            "name": self.name,
            "initial_step": self.initial_step,
            "max_rounds": self.max_rounds,
            "stall_threshold": self.stall_threshold,
            "steps": [
                {
                    "name": s.name,
                    "kind": s.kind.name,
                    "statutes": s.statutes,
                    "transitions": s.transitions,
                }
                for s in self.steps
            ],
        }
