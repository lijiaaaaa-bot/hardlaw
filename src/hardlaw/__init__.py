"""
hardlaw — Framework for encoding enforceable hard constraints on LLM agents.

Inspired by Grok Build's Reflection architecture, hardlaw separates:
  - ⚙️ Hard-coded "procedural law": state machines, thresholds, schemas, routing
  - 🔮 LLM "judges": semantic judgment within those hard constraints

The legal analogy:
  Statute  = the law on the books (what constitutes a violation)
  Procedure = courtroom procedure (what steps must be followed, in what order)
  Evidence  = rules of evidence (what counts as valid proof)
  Verdict   = the judgment (structured output, machine-parseable)
  Court     = the runtime that enforces ALL of the above
"""

from hardlaw.statute import Statute, ViolationType, EscalationRule, StatuteBook
from hardlaw.procedure import Step, StepKind, Procedure, CaseContext, StallDetector
from hardlaw.evidence import EvidenceRef, EvidenceRule, EvidencePacket, EvidenceValidator
from hardlaw.verdict import Verdict, Finding, Confidence, VerdictParser
from hardlaw.court import Court, CaseResult
from hardlaw.llm import LLMBackend, MockLLM, OpenAI, Ollama

__all__ = [
    # statute
    "Statute",
    "ViolationType",
    "EscalationRule",
    "StatuteBook",
    # procedure
    "Step",
    "StepKind",
    "Procedure",
    "CaseContext",
    "StallDetector",
    # evidence
    "EvidenceRef",
    "EvidenceRule",
    "EvidencePacket",
    "EvidenceValidator",
    # verdict
    "Verdict",
    "Finding",
    "Confidence",
    "VerdictParser",
    # court
    "Court",
    "CaseResult",
    # llm
    "LLMBackend",
    "MockLLM",
    "OpenAI",
    "Ollama",
]
