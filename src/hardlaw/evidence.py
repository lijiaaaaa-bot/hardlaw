"""Evidence rules — what counts as valid proof.

Inspired by Grok Build's evidence packet format and the rule:
"Cite concrete evidence per assertion (path:line, captured transcript, diff hunk).
FINAL_RESPONSE prose is NOT evidence."

Key principles:
  - Every claim must cite specific, verifiable evidence.
  - Evidence without source/location/snippet is rejected.
  - The harness validates evidence BEFORE accepting a verdict.
"""

from dataclasses import dataclass, field


@dataclass
class EvidenceRef:
    """A citation grounding a claim in verifiable evidence.

    Mirrors Grok Build's pattern of requiring path:line citations.

    Attributes:
        source: File path, data source, or artifact name.
        location: Precise location within the source ("line:42", "section 3.2").
        snippet: Verifiable quote or excerpt from the source.
        kind: Type of evidence ("text", "diff", "test_output", "screenshot").
    """

    source: str
    location: str = ""
    snippet: str = ""
    kind: str = "text"

    def is_empty(self) -> bool:
        """An evidence ref with no snippet is not verifiable."""
        return not self.snippet.strip()

    def to_dict(self) -> dict[str, str]:
        return {
            "source": self.source,
            "location": self.location,
            "snippet": self.snippet,
            "kind": self.kind,
        }


@dataclass
class EvidenceRule:
    """Rules for what constitutes valid evidence.

    Enforced by code, not by LLM — the harness rejects any verdict
    whose evidence does not satisfy these rules.

    Attributes:
        required_sources: Sources that MUST be cited (e.g., "source_text").
        min_citations: Minimum number of evidence refs required.
        must_be_verifiable: If True, every ref must have a non-empty snippet.
        max_claim_without_evidence: Claims without evidence beyond this are rejected.
    """

    required_sources: list[str] = field(default_factory=list)
    min_citations: int = 1
    must_be_verifiable: bool = True
    max_claim_without_evidence: int = 0

    def validate(self, refs: list[EvidenceRef]) -> tuple[bool, str]:
        """Check that evidence meets the rules.

        Returns:
            (passed, reason) — reason is empty on success.
        """
        if not refs and self.min_citations > 0:
            return False, "no evidence refs provided"

        cited_sources = {r.source for r in refs}

        for required in self.required_sources:
            if required not in cited_sources:
                return False, f"required source '{required}' not cited"

        if len(refs) < self.min_citations:
            return False, f"only {len(refs)} citations, need at least {self.min_citations}"

        if self.must_be_verifiable:
            for ref in refs:
                if ref.is_empty():
                    return False, f"evidence from '{ref.source}' has empty snippet"

        return True, ""


@dataclass
class EvidencePacket:
    """A bundle of evidence assembled for LLM review.

    Mirrors Grok Build's evidence packet format:
      OBJECTIVE, CHANGED_FILES, PLAN_CHANGES, FINAL_RESPONSE, PRIOR_GAPS

    Attributes:
        objective: What the agent was asked to do.
        artifacts: Named pieces of evidence (files, outputs, diffs).
        prior_gaps: Gaps found in previous rounds (for anti-ratchet).
    """

    objective: str
    artifacts: dict[str, str] = field(default_factory=dict)
    prior_gaps: list[str] = field(default_factory=list)

    def to_prompt_section(self) -> str:
        """Render the evidence packet as a prompt section for the LLM judge."""
        lines = [
            "## OBJECTIVE",
            self.objective,
            "",
            "## EVIDENCE",
        ]
        for name, content in self.artifacts.items():
            lines.append(f"\n### {name}")
            lines.append(content)

        if self.prior_gaps:
            lines.append("\n## PRIOR GAPS (from previous rounds)")
            for gap in self.prior_gaps:
                lines.append(f"- {gap}")

        return "\n".join(lines)


@dataclass
class EvidenceValidator:
    """Validates that LLM-cited evidence actually exists in the source material.

    This is the enforcement arm: it checks that the LLM's cited snippets
    appear in the actual evidence, preventing hallucinated citations.
    """

    def __init__(self, source_material: dict[str, str] | None = None):
        """
        Args:
            source_material: Map of source name to full content.
        """
        self.source_material = source_material or {}

    def add_source(self, name: str, content: str) -> None:
        """Register a source for validation."""
        self.source_material[name] = content

    def validate(self, ref: EvidenceRef) -> bool:
        """Check that a cited snippet actually exists in the source material.

        Returns True if the snippet can be verified.
        """
        content = self.source_material.get(ref.source)
        if content is None:
            # Source not registered — can't verify
            return False
        if not ref.snippet.strip():
            return False
        # Check snippet appears in source
        return ref.snippet.strip() in content

    def validate_all(self, refs: list[EvidenceRef]) -> tuple[bool, list[str]]:
        """Validate all evidence refs. Returns (all_valid, failures)."""
        failures = []
        for ref in refs:
            if not self.validate(ref):
                failures.append(
                    f"Unverifiable: '{ref.snippet[:60]}...' not found in '{ref.source}'"
                )
        return len(failures) == 0, failures
