# hardlaw

> 📜 Hard-coded law for LLM agents — enforced, not advised.

**hardlaw** encodes enforceable constraints on AI agents, modeled after a legal system:
**Statute** (hard rules) + **Procedure** (state machine) + **Evidence** (citation rules) + **Verdict** (structured output).

Inspired by the [Grok Build](https://github.com/xai-org/grok-build) Reflection architecture's separation of hard-coded state machines from LLM semantic judgment.

```python
from hardlaw import Statute, Procedure, Step, StepKind, Court, MockLLM

statute = Statute(
    name="honesty_check",
    required_evidence=["source_text"],
    violations=[ViolationType("fabrication", "critical")],
)

procedure = Procedure("simple_check", steps=[
    Step("review", kind=StepKind.JUDGMENT, statutes=["honesty_check"],
         transitions={"not_refuted": "approved", "refuted": "review"}),
    Step("approved", kind=StepKind.CODE),
])

court = Court(statutes=[statute], procedure=procedure, llm=MockLLM(...))
result = await court.hear({"source_text": "...", "agent_output": "..."})
# → CaseResult with verdicts, disposition, and round count
```

## Core Concepts

| Component | Analogy | Role |
|-----------|---------|------|
| **Statute** | Law | Hard constraint — what constitutes a violation, what evidence is required |
| **Procedure** | Court procedure | State machine — what steps must be followed, what transitions are allowed |
| **Evidence** | Evidence rules | Citation rules — every claim must cite `source:location:snippet` |
| **Verdict** | Judgment | Structured output schema — JSON + terminal token + fail-closed fallback |
| **Court** | Court | Runtime — orchestrates the full loop with evidence validation and stall detection |

### Statute
```python
Statute(
    name="gdpr_consent",
    description="Data processing must have valid consent (GDPR Art. 6-7)",
    required_evidence=["privacy_policy", "consent_mechanism"],
    violations=[ViolationType("vague_purpose", "high")],
    escalation=EscalationRule(max_violations=3, action="block"),
    default_to_reject=True,      # fail-closed: reject on uncertainty
)
```

### Procedure
```python
Procedure("content_moderation", steps=[
    Step("review", kind=StepKind.JUDGMENT, statutes=["hate_speech"],
         transitions={"not_refuted": "approved", "refuted": "classify"}),
    Step("classify", kind=StepKind.JUDGMENT, statutes=["hate_speech"],
         transitions={"not_refuted": "warned", "refuted": "blocked"}),
    Step("approved", kind=StepKind.CODE, handler=approve_handler),
    Step("warned", kind=StepKind.CODE, handler=warn_handler),
    Step("blocked", kind=StepKind.CODE, handler=block_handler),
])
```

### Verdict (structured LLM output)
```json
{
  "finding": "fabrication",
  "refuted": true,
  "confidence": "high",
  "blocking": "none",
  "evidence_refs": [{"source": "doc.txt", "location": "line:42", "snippet": "...", "kind": "text"}],
  "findings": [{"kind": "bug", "location": "output:1", "detail": "Fabricated claim"}],
  "reasoning": "Source says X, agent claimed Y."
}
```

## Key Design Decisions

1. **Law is data, not code** — Statutes/Procedures are JSON-serializable, non-programmers can write them
2. **LLM judges, code enforces** — Procedure transitions are deterministic code; LLM cannot change the flow
3. **Evidence is verifiable** — Every citation (`source:location:snippet`) can be automatically validated
4. **Fail-closed** — Parse failure → reject. Never linger in uncertainty.
5. **Stall detection** — Same gap fingerprint × N consecutive rounds → escalation (mirrors Grok Build's `NoProgressPaused`)

## Architecture

```
Case enters
  │
  ▼
Court.hear(case)
  │
  ├─ CODE step → execute handler → transition("done")
  │
  └─ JUDGMENT step
       ├─ Build evidence packet + prompt
       ├─ Call LLM.judge(prompt) → raw text
       ├─ VerdictParser.parse(raw)
       │    ├─ Try JSON → ✅
       │    ├─ Try terminal token ("Refuted"/"Not Refuted") → ⚠️
       │    └─ Default to reject → ❌ (fail-closed)
       ├─ Validate evidence (must cite required sources)
       ├─ Verify snippets exist in source material
       ├─ StallDetector.check(fingerprint) → stall? escalate
       └─ Route by verdict outcome
```

## Quick Start

```bash
pip install -e ".[dev]"
python examples/01_hello_world.py
python examples/02_content_moderation.py
python examples/03_gdpr_compliance.py
pytest tests/
```

## Examples

| Example | What it demonstrates |
|---------|---------------------|
| `01_hello_world.py` | Minimal: one statute, one-step procedure, 2-round reflection loop |
| `02_content_moderation.py` | Multi-step: review → classify severity → route to approve/warn/block |
| `03_gdpr_compliance.py` | Sequential audit: two statutes applied at different judgment points with fix-retry loops |

## Future Exploration

- Multi-judge parallel panel (mirrors Grok Build's skeptic `futures::future::join_all`)
- Strategist mode: automated root-cause analysis on stall
- Statute version management + conflict detection
- MCP integration: Court as an MCP server

## License

MIT
