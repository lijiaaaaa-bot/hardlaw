# Hardlaw — iOS App

On-device AI Compliance Court for iOS 17.0+.
All processing is local: Vision framework evidence collection + pluggable LLM judgment,
enforced by a hard-coded rule engine that defaults to reject (fail-closed).

## Architecture

```
Camera/Photo → VisionEvidenceCollector (ANE-accelerated OCR + face/rectangle detection)
             → EvidenceBundle (refs + source material)
             → Court.hear(caseData) → Procedure state machine
             → LLM judge (RuleBasedLLM / MockLLM / future MLXLLM)
             → VerdictParser (3-tier: JSON → terminal token → default-to-reject)
             → EvidenceValidator (snippet substring check — anti-hallucination)
             → CaseResult (approved/rejected/blocked/stalled)
```

The Python hardlaw framework's legal analogy is preserved:

| Module | Swift | Role |
|---|---|---|
| Statute | `Statute`, `StatuteBook` | The law: what's prohibited, what evidence is required |
| Procedure | `Procedure`, `Step`, `StepKind` | State machine: CODE (deterministic) vs JUDGMENT (LLM) |
| Evidence | `EvidenceRef`, `EvidenceRule`, `EvidenceValidator` | Rules of evidence: citation requirements, source verification |
| Verdict | `Verdict`, `VerdictParser`, `Fingerprint` | Structured judgment, 3-tier fail-closed parsing, SHA-256 stall detection |
| Court | `Court` (actor) | Runtime enforcing all constraints |

JSON wire format is byte-identical to Python — statutes can round-trip between languages.

## Requirements

- macOS with Xcode 16.0+
- iOS 17.0+ (simulator or device)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Quick Start

```bash
# 1. Generate Xcode project
xcodegen generate

# 2. Build & run on simulator
xcodebuild build -project Hardlaw.xcodeproj -scheme HardlawApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# 3. Run tests
xcodebuild test -project Hardlaw.xcodeproj -scheme HardlawKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Project Structure

```
ios/
├── project.yml                    # XcodeGen manifest (3 targets)
├── HardlawKit/                    # Framework: core engine + Vision
│   ├── Sources/
│   │   ├── Statute/               # Statute, ViolationType, StatuteBook
│   │   ├── Procedure/             # Procedure, Step, CaseContext, StallDetector
│   │   ├── Evidence/              # EvidenceRef, EvidenceRule, EvidenceValidator
│   │   ├── Verdict/               # Verdict, VerdictParser, Fingerprint (CryptoKit)
│   │   ├── Court/                 # actor Court, CaseResult
│   │   ├── LLM/                   # LLMBackend protocol, MockLLM, RuleBasedLLM
│   │   └── Support/               # JSONValue
│   ├── Vision/                    # VisionEvidenceCollector
│   └── Tests/                     # 99 XCTest unit tests (1:1 Python port)
├── HardlawApp/                    # SwiftUI App
│   ├── HardlawApp.swift           # @main entry point
│   ├── CourtViewModel.swift       # @Observable MVVM state machine
│   ├── Camera/                    # AVCaptureSession + preview
│   ├── UI/                        # Home, LiveModeration, AuditResult, CaseResult
│   └── Statutes/                  # ContentModerationStatutes (port of ./examples/02)
└── Models/                        # (gitignored) MLX model files
```

## Backend Options

| Backend | Description | Latency | Requirements |
|---|---|---|---|
| **RuleBasedLLM** | Deterministic regex detection (profanity, PII, emails, phones, credit cards) | <1ms | None |
| **MockLLM** | Scripted responses for testing | <1ms | None |
| **MLXLLM** | On-device LLM (future) | 30-90s | mlx-swift, 4GB+ RAM |

## App Modes

### Live Moderation
- Camera feed with real-time OCR
- RuleBasedLLM scans each frame (<1ms)
- Findings overlay on camera preview
- All processing on-device, zero network

### Text Audit
- Paste or type content
- Full Court procedure: prescan → verify → severity → verdict
- Detailed case result with evidence refs and findings

### Photo Audit
- Pick from library or capture
- Vision OCR extracts text as evidence
- Evidence registered in source material (anti-hallucination guarantee)
- Full Court procedure with selected backend

## Key Design Decisions

1. **Fail-closed everywhere**: Verdict.refuted defaults to true, parse failures reject, missing evidence blocks
2. **Evidence = substring of source**: Cited snippets must exist verbatim in registered source material
3. **JSON key parity with Python**: `required_evidence`, `default_to_reject` etc. — statutes round-trip between languages
4. **actor Court**: Swift concurrency serializes hearings automatically
5. **Swift 6 strict concurrency**: All model types are Sendable value types

## Roadmap

- [ ] MLXLLM integration (mlx-swift + Qwen2.5-0.5B-Instruct 4-bit)
- [ ] Add VNDetectHumanBodyPoseRequest for pose evidence
- [ ] Add VNDetectFaceLandmarksRequest for facial expression evidence
- [ ] User-definable statutes via JSON import
- [ ] Case history persistence (SwiftData)
- [ ] Widget for quick audit
- [ ] Apple Intelligence LLM backend (when API available)

## License

MIT (same as parent hardlaw project)
