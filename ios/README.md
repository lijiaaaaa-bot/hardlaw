# Hardlaw — iOS App

On-device legal evidence workbench for iOS 17.0+.
All processing is local: OCR evidence collection + offline law search + AI auto-fill,
enforced by a fail-closed rule engine that defaults to reject.

## Architecture

```
Case folder/zip → ZipReader/ImportPackage (batch import, cancelable)
               → PaddleOCR / VisionEvidenceCollector (OCR evidence)
               → DocumentClassifier (evidence type classification)
               → AutoFillPipeline → AutoFillRuleEngine (source-grounded field fill)
               → Court.hear(caseData) → Procedure state machine
               → LLM judge (RuleBasedLLM / FailSafeLLM / MLXLLM)
               → EvidenceValidator (snippet substring check — anti-hallucination)
               → CaseResult (approved/rejected/blocked/stalled)
LawStore/LawIndex → offline keyword + semantic (BGE-512) retrieval for citation
```

## Module Map

| Module | Swift | Role |
|---|---|---|
| Statute | `Statute`, `StatuteBook`, `LaborLawStatutes` | The law: violations, required evidence |
| LegalKnowledge | `LawStore`, `LawIndex`, `CoreMLEmbeddingProvider` | Offline Chinese law retrieval (11,724 chunks, 512-dim BGE vectors) |
| Procedure | `Procedure`, `Step`, `StallDetector` | State machine: CODE (deterministic) vs JUDGMENT (LLM) |
| Evidence | `EvidenceRef`, `EvidenceRule`, `EvidenceValidator`, `DocumentClassifier` | Rules of evidence: citation requirements, source verification |
| Verdict | `Verdict`, `VerdictParser`, `Fingerprint` | Structured judgment, 3-tier fail-closed parsing, SHA-256 stall detection |
| Court | `Court` (actor), `CourtProcedures`, `Goal` | Runtime enforcing all constraints |
| AutoFill | `AutoFillParser`, `AutoFillPrompt`, `AutoFillRuleEngine` | AI field auto-fill with source-grounding gate |
| Archive | `ImportPackage`, `ZipReader` | Batch folder/zip import, zip-bomb & path-traversal protection |
| LLM | `LLMBackend`, `FailSafeLLM`, `RuleBasedLLM`, `MLXLLM` | Pluggable judgment backends with transparent fallback |

## Requirements

- macOS with Xcode 16.0+
- iOS 17.0+ (simulator or device)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (Swift Package, for on-device LLM)
  - 4 GB+ device RAM required for MLX backends
  - ~1.9 GB storage for the default 3B model (auto-downloaded on first use)

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
├── HardlawKit/                    # Framework: core engine
│   ├── Sources/
│   │   ├── Archive/               # ImportPackage, ZipReader
│   │   ├── AutoFill/              # AutoFillParser, AutoFillPrompt, AutoFillRuleEngine
│   │   ├── Court/                 # actor Court, CaseResult, CourtProcedures, Goal
│   │   ├── Evidence/              # EvidenceRef, EvidenceRule, EvidenceValidator, DocumentClassifier
│   │   ├── LegalKnowledge/        # LawStore, LawIndex, CoreMLEmbeddingProvider
│   │   ├── LLM/                   # LLMBackend, FailSafeLLM, RuleBasedLLM, MLXLLM
│   │   ├── Procedure/             # Procedure, Step, StallDetector
│   │   ├── Statute/               # Statute, StatuteBook, LaborLawStatutes
│   │   ├── Support/               # JSONValue
│   │   └── Verdict/               # Verdict, VerdictParser, Fingerprint
│   ├── Vision/                    # VisionEvidenceCollector
│   └── Tests/                     # 186 XCTest cases (incl. Guo Youyi E2E)
├── HardlawApp/                    # SwiftUI App
│   ├── HardlawApp.swift           # @main entry point
│   ├── CourtViewModel.swift       # @Observable MVVM state machine
│   ├── Services/                  # AutoFillPipeline, OCRRouter, PaddleOCREngine(.mm), EvidenceFileStore, ExcelExport
│   ├── PaddleOCR/                 # bundled static lib + inference models + ppocr_keys.txt
│   ├── LegalKnowledge/            # laws_chunks/ids/vocab/vectors.bin (512-dim, single source of truth)
│   ├── State/                     # IntentParser, PersistenceController
│   └── UI/                        # Home, CaseWorkbench, CaseSections, GoalProgress, ImportProgress
└── Models/                        # (gitignored) MLX model files
```

## Backend Options

| Backend | Description | Latency | Requirements |
|---|---|---|---|
| **RuleBasedLLM** | Deterministic labor-law evidence-gap rules (劳动关系/工资标准/欠薪/混同用工/解除程序) | <1ms | None |
| **FailSafeLLM** | Wraps a primary backend; on failure falls back to RuleBasedLLM and logs the cause | — | None |
| **MLXLLM** | On-device LLM via mlx-swift-lm (default 3B model) | 30-90s | mlx-swift-lm, 4GB+ RAM |

## App Workflows

### Case Workbench
- Batch import case folders / zips (cancelable, orphan-case cleanup)
- Evidence classification → AI auto-fill with source-grounding gate (numbers must hit OCR text verbatim)
- Manual overrides always win; version stamps prevent stale AI writes
- Goal tracking (`Goal`), sectioned case view, Excel export

### Legal Search
- Offline hybrid retrieval: `NLTokenizer` keyword + BGE-small-zh-v1.5 512-dim semantic vectors
- Fail-closed degradation: no vectors/model → keyword-only; dimension mismatch → warning (no silent breakage)

### Evidence & Verdict
- OCR evidence registered in source material (anti-hallucination guarantee)
- Full Court procedure with selected backend; `Fingerprint` SHA-256 stall detection

## Key Design Decisions

1. **Fail-closed everywhere**: `Verdict.refuted` defaults to true, parse failures reject, missing evidence blocks
2. **Evidence = substring of source**: Cited snippets must exist verbatim in registered source material
3. **actor isolation**: `Court`, `FailSafeLLM`, `MLXLLM`, `AutoFillRuleEngine` never block the main thread
4. **Swift 6 strict concurrency**: All model types are Sendable value types

## Roadmap

- [x] MLXLLM integration (mlx-swift-lm)
- [x] PaddleOCR integration
- [x] Batch import + AI auto-fill (source-grounding gate)
- [x] Offline legal search with 512-dim BGE vectors
- [x] Guo Youyi end-to-end test vs lawyer ground truth
- [x] Bundle CoreML semantic model (`bge-small-zh-v1.5.mlpackage` + `vocab.txt`, via `scripts/convert_bge_to_coreml.py`)
- [x] GitHub Actions CI (xcodegen + xcodebuild test)
- [ ] User-definable statutes via JSON import
- [ ] Case history persistence (SwiftData)
- [ ] Apple Intelligence LLM backend (when API available)

## License

MIT — see root [LICENSE](../LICENSE).
