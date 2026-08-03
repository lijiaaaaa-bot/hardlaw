"""Statute definitions — the "law on the books."

A Statute is a named hard rule that defines:
  - What constitutes a violation
  - What evidence is required
  - What happens on repeated violations
  - Default judgment posture (default-to-reject)
"""

from dataclasses import dataclass, field
from typing import Any, Literal


@dataclass
class ViolationType:
    """A kind of violation that can be found by an LLM judge.

    Attributes:
        name: Short identifier, e.g. "hate_speech", "missing_consent".
        severity: How serious the violation is.
        description: Human-readable definition for the judge.
    """

    name: str
    severity: Literal["critical", "high", "medium", "low"]
    description: str = ""


@dataclass
class EscalationRule:
    """What happens on repeated violations.

    Attributes:
        max_violations: Escalate after N violations of the same type.
        action: What action to take on escalation.
        escalate_to: Name of escalated statute, if escalation changes the rule set.
    """

    max_violations: int = 3
    action: Literal["block", "flag", "notify", "pause"] = "block"
    escalate_to: str | None = None


@dataclass
class Statute:
    """A named hard rule encoding enforceable constraints on LLM agents.

    A Statute is data, not code — it can be serialized to JSON/YAML so that
    non-programmers can define the rules.

    Attributes:
        name: Unique identifier, e.g. "hate_speech", "gdpr_consent".
        description: Human-readable explanation of what this statute governs.
        threshold: Multi-dimensional thresholds, e.g. {"confidence_min": "medium"}.
        required_evidence: Evidence fields that MUST be cited in any verdict.
        violations: Kinds of violations this statute covers.
        escalation: What happens on repeated violations.
        default_to_reject: When the judge is uncertain, default to rejecting.
            Mirrors Grok Build's "Default to refuted: true if uncertain".
        blocking: If True, a violation blocks the action entirely (no retry).
    """

    name: str
    description: str = ""
    threshold: dict[str, Any] = field(default_factory=dict)
    required_evidence: list[str] = field(default_factory=list)
    violations: list[ViolationType] = field(default_factory=list)
    escalation: EscalationRule = field(default_factory=EscalationRule)
    default_to_reject: bool = True
    blocking: bool = True

    def to_dict(self) -> dict[str, Any]:
        """Serialize to a plain dict (JSON-compatible)."""
        return {
            "name": self.name,
            "description": self.description,
            "threshold": self.threshold,
            "required_evidence": self.required_evidence,
            "violations": [
                {"name": v.name, "severity": v.severity, "description": v.description}
                for v in self.violations
            ],
            "escalation": {
                "max_violations": self.escalation.max_violations,
                "action": self.escalation.action,
                "escalate_to": self.escalation.escalate_to,
            },
            "default_to_reject": self.default_to_reject,
            "blocking": self.blocking,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Statute":
        """Deserialize from a plain dict."""
        violations = [
            ViolationType(
                name=v["name"],
                severity=v["severity"],
                description=v.get("description", ""),
            )
            for v in data.get("violations", [])
        ]
        esc_data = data.get("escalation", {})
        escalation = EscalationRule(
            max_violations=esc_data.get("max_violations", 3),
            action=esc_data.get("action", "block"),
            escalate_to=esc_data.get("escalate_to"),
        )
        return cls(
            name=data["name"],
            description=data.get("description", ""),
            threshold=data.get("threshold", {}),
            required_evidence=data.get("required_evidence", []),
            violations=violations,
            escalation=escalation,
            default_to_reject=data.get("default_to_reject", True),
            blocking=data.get("blocking", True),
        )


class StatuteBook:
    """A collection of statutes — the "legal code" for a domain.

    Provides lookup, validation, and serialization for multiple statutes.
    """

    def __init__(self, statutes: list[Statute] | None = None):
        self._statutes: dict[str, Statute] = {}
        if statutes:
            for s in statutes:
                self.add(s)

    def add(self, statute: Statute) -> None:
        """Add a statute to the book. Replaces if name already exists."""
        self._statutes[statute.name] = statute

    def get(self, name: str) -> Statute | None:
        """Look up a statute by name."""
        return self._statutes.get(name)

    def get_all(self, names: list[str]) -> list[Statute]:
        """Look up multiple statutes. Silently skips unknown names."""
        return [s for s in (self._statutes.get(n) for n in names) if s is not None]

    def list_names(self) -> list[str]:
        """Return all statute names."""
        return list(self._statutes.keys())

    def __len__(self) -> int:
        return len(self._statutes)

    def __contains__(self, name: str) -> bool:
        return name in self._statutes

    def to_dict(self) -> dict[str, Any]:
        """Serialize all statutes."""
        return {"statutes": [s.to_dict() for s in self._statutes.values()]}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "StatuteBook":
        """Deserialize a statute book."""
        statutes = [Statute.from_dict(s) for s in data.get("statutes", [])]
        return cls(statutes)
