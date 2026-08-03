"""Verdict — structured judgment output from LLM.

Every LLM judgment must conform to a fixed schema. Parse failures
have defined fallback behavior:

  1. Try JSON verdict file    → structured Verdict
  2. Try terminal token        → "Refuted" / "Not Refuted"
  3. Default to reject         → fail-closed

This mirrors Grok Build's three-tier output contract:
  goal_verifier_prompt.md:155-202
  goal_classifier.rs:1601-1662 (read_skeptic_verdict)
"""

from dataclasses import dataclass, field
from enum import Enum
import json
import re
import hashlib


class Confidence(Enum):
    """Confidence level of the judge's verdict.

    Mirrors Grok Build's SkepticConfidence enum (goal_classifier.rs:752).
    Used for routing: high-confidence refutes can short-circuit.
    """

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"
    UNKNOWN = "unknown"

    @classmethod
    def parse(cls, s: str) -> "Confidence":
        """Parse from string with fallback to UNKNOWN.

        Matches Grok Build's SkepticConfidence::parse() behavior.
        """
        match s.strip().lower():
            case "high":
                return cls.HIGH
            case "medium":
                return cls.MEDIUM
            case "low":
                return cls.LOW
            case _:
                return cls.UNKNOWN


@dataclass
class Finding:
    """A single gap or violation found by the LLM judge.

    Mirrors Grok Build's Finding struct (goal_classifier.rs:824):
      kind, location, detail — the implementer-facing gap list.

    Attributes:
        kind: "bug" | "gap" | "todo" — what kind of issue.
        location: "path:line" or description of where.
        detail: One-line concrete description.
    """

    kind: str = ""
    location: str = ""
    detail: str = ""

    def is_empty(self) -> bool:
        return not self.kind.strip() and not self.location.strip() and not self.detail.strip()


# Known blocking classifications (from Grok Build goal_verifier_prompt.md:150-153)
# "none": ordinary model-fixable gap
# "contradiction": objective/plan internally conflicts → needs user
# "unverifiable": evidence impossible in this environment → needs user
BLOCKING_NONE = "none"
BLOCKING_CONTRADICTION = "contradiction"
BLOCKING_UNVERIFIABLE = "unverifiable"

# Terminal tokens (from Grok Build goal_verifier_prompt.md:191-198)
TERMINAL_REFUTED = "Refuted"
TERMINAL_NOT_REFUTED = "Not Refuted"


@dataclass
class Verdict:
    """Structured judgment output from an LLM judge.

    Core fields mirror Grok Build's SkepticVerdict (goal_classifier.rs:846).

    Attributes:
        finding: The conclusion — violation type name or "none".
        refuted: True if the work is rejected, False if it passes.
        confidence: How confident the judge is.
        blocking: Whether this blocks further progress.
        evidence_refs: Citations grounding the judgment in evidence.
        findings: Structured list of gaps/violations found.
        reasoning: Human-readable explanation.
    """

    finding: str = ""
    refuted: bool = True  # Default to reject (fail-closed)
    confidence: Confidence = Confidence.MEDIUM
    blocking: bool = False
    blocking_kind: str = BLOCKING_NONE
    evidence_refs: list = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)
    reasoning: str = ""
    details_md: str = ""
    fallback_note: str | None = None

    def is_decisive(self) -> bool:
        """A high-confidence refute that is NOT blocking is decisive —
        it can short-circuit without running remaining judges."""
        return self.refuted and self.confidence == Confidence.HIGH and not self.blocking

    def to_dict(self) -> dict:
        """Serialize to a plain dict."""
        return {
            "finding": self.finding,
            "refuted": self.refuted,
            "confidence": self.confidence.value,
            "blocking": self.blocking,
            "blocking_kind": self.blocking_kind,
            "evidence_refs": [
                r.to_dict() if hasattr(r, "to_dict") else r
                for r in self.evidence_refs
            ],
            "findings": [
                {"kind": f.kind, "location": f.location, "detail": f.detail}
                for f in self.findings
            ],
            "reasoning": self.reasoning,
        }


class VerdictParser:
    """Parse LLM output into a structured Verdict.

    Three-tier fallback (from Grok Build goal_classifier.rs:1601-1662):
      1. Try JSON verdict → parse into Verdict
      2. Try terminal token → "Refuted"/"Not Refuted"
      3. Default to reject → fail-closed
    """

    @staticmethod
    def parse(raw: str) -> Verdict:
        """Parse LLM response into a Verdict.

        Never raises — always returns a Verdict, defaulting to reject.
        """
        # Tier 1: Try JSON
        json_body = VerdictParser._extract_json(raw)
        if json_body:
            try:
                data = json.loads(json_body)
                return VerdictParser._from_dict(data)
            except (json.JSONDecodeError, KeyError, TypeError):
                pass

        # Tier 2: Try terminal token
        token_result = VerdictParser._parse_terminal_token(raw)
        if token_result is not None:
            return Verdict(
                finding="none" if not token_result else "unknown",
                refuted=token_result,
                confidence=Confidence.UNKNOWN,
                fallback_note="verdict JSON missing/malformed; used terminal token",
            )

        # Tier 3: Default to reject
        return Verdict(
            finding="parse_failure",
            refuted=True,
            blocking=True,
            confidence=Confidence.UNKNOWN,
            fallback_note="verdict JSON missing AND terminal token unrecognised",
        )

    @staticmethod
    def _extract_json(raw: str) -> str | None:
        """Extract a JSON object from LLM response.

        Handles markdown code fences and bare JSON objects.
        """
        # Try markdown code block first
        match = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', raw, re.DOTALL)
        if match:
            return match.group(1)
        # Try bare JSON object (greedy — finds outermost braces)
        match = re.search(r'\{.*\}', raw, re.DOTALL)
        if match:
            return match.group(0)
        return None

    @staticmethod
    def _parse_terminal_token(raw: str) -> bool | None:
        """Parse Grok Build-style terminal token.

        Must be exactly "Refuted" or "Not Refuted" on its own line.
        Tolerates code fences and trailing punctuation.

        From goal_classifier.rs:378-393 parse_skeptic_terminal_response.
        """
        lines = [
            line.strip()
            for line in raw.splitlines()
            if line.strip() and not line.strip().startswith("```")
        ]
        # Clean: trim backticks, trailing punctuation
        cleaned = [
            l.strip("`").rstrip(".!").strip()
            for l in lines
            if l.strip()
        ]
        for line in cleaned:
            if line == TERMINAL_REFUTED:
                return True
            if line == TERMINAL_NOT_REFUTED:
                return False
        return None

    @staticmethod
    def _from_dict(data: dict) -> Verdict:
        """Build Verdict from parsed JSON dict with defaults."""
        evidence_refs = []
        for r in data.get("evidence_refs", []):
            from hardlaw.evidence import EvidenceRef

            evidence_refs.append(
                EvidenceRef(
                    source=r.get("source", ""),
                    location=r.get("location", ""),
                    snippet=r.get("snippet", ""),
                    kind=r.get("kind", "text"),
                )
            )

        findings = []
        for f in data.get("findings", []):
            finding = Finding(
                kind=f.get("kind", ""),
                location=f.get("location", ""),
                detail=f.get("detail", ""),
            )
            if not finding.is_empty():
                findings.append(finding)

        blocking_kind = data.get("blocking", BLOCKING_NONE)
        if blocking_kind not in (BLOCKING_NONE, BLOCKING_CONTRADICTION, BLOCKING_UNVERIFIABLE):
            blocking_kind = BLOCKING_NONE

        return Verdict(
            finding=data.get("finding", ""),
            refuted=data.get("refuted", True),
            confidence=Confidence.parse(data.get("confidence", "medium")),
            blocking=blocking_kind != BLOCKING_NONE,
            blocking_kind=blocking_kind,
            evidence_refs=evidence_refs,
            findings=findings,
            reasoning=data.get("reasoning", ""),
            details_md=data.get("details_md", ""),
        )


def compute_fingerprint(findings: list[Finding]) -> str:
    """Compute a stable gap fingerprint for stall detection.

    Mirrors Grok Build's gap_fingerprint:
      SHA-256 of sorted kind:location:detail strings, first 16 hex chars.

    From goal_classifier.rs gap_fingerprint function.
    """
    if not findings:
        return ""
    tokens = sorted(
        f"{f.kind}:{f.location}:{f.detail}"
        for f in findings
        if not f.is_empty()
    )
    if not tokens:
        return ""
    return hashlib.sha256("|".join(tokens).encode()).hexdigest()[:16]
