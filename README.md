# Hardlaw — 劳动/民事法律证据链 iOS 工作台

**Hardlaw** 是一个面向法律工作者的 iOS 本地化工作台：离线中文法律检索、案件证据批量导入、AI 证据自动填充与 fail-closed 判定。所有处理都在设备端完成，不上传案卷材料。

> iOS 17.0+，Swift 6 严格并发，`HardlawKit`（framework 核心引擎）+ `HardlawApp`（SwiftUI 应用）双 target。

## 核心能力

| 能力 | 说明 |
|---|---|
| 📚 离线法律检索 | 11,724 条法条 chunk（劳动法/民法典/司法解释等 165 部法规），`NLTokenizer` 关键词 + FAISS 风格向量混合检索（BGE-small-zh-v1.5 512 维，CoreML 语义 query） |
| ⚖️ fail-closed 判定 | `Court`（actor）状态机 + `RuleBasedLLM` 劳动法证据规则引擎 + `MLXLLM` 端侧大模型 + `FailSafeLLM` 透明降级；规则不满足默认拒绝（refuted） |
| 🔍 反幻觉证据校验 | `EvidenceValidator` 子串校验：AI 引用的证据片段必须逐字存在于已登记案卷材料中，杜绝伪造引用 |
| 📦 批量导入 | 文件夹 / zip 批量导入案卷，`ZipReader` 防路径穿越与 zip bomb，导入可取消 |
| ✍️ AI 自动填充 | OCR 证据 → `AutoFillRuleEngine` 逐项填充案件字段，数值必须命中 OCR 原文（source-grounding 门控），人工覆盖永不被 AI 覆盖 |
| 🖼️ 证据收集 | Vision 框架 + PaddleOCR（静态库）双 OCR 引擎，图片/PDF/视频证据入库 |
| 🧪 真实案卷验证 | 郭又义劳动争议案真实材料端到端测试（`test-resources/guo-youyi/`，与律师人工结论对比） |

## 架构

```
ios/
├── project.yml                    # XcodeGen 清单（3 targets）
├── HardlawKit/                    # framework：核心引擎
│   └── Sources/
│       ├── Archive/               # ImportPackage, ZipReader（批量导入）
│       ├── AutoFill/              # AutoFillParser/Prompt/RuleEngine（AI 自动填充）
│       ├── Court/                 # actor Court, CaseResult, CourtProcedures, Goal
│       ├── Evidence/              # EvidenceRef, EvidenceRule, EvidenceValidator, DocumentClassifier
│       ├── LegalKnowledge/        # LawStore, LawIndex, CoreMLEmbeddingProvider（离线检索）
│       ├── LLM/                   # LLMBackend, FailSafeLLM, RuleBasedLLM, MLXLLM
│       ├── Procedure/             # Procedure 状态机, StallDetector
│       ├── Statute/               # Statute, StatuteBook, LaborLawStatutes
│       ├── Support/               # JSONValue 等
│       └── Verdict/               # Verdict, VerdictParser, Fingerprint
│   └── Tests/                     # 186 个 XCTest 用例（含郭又义端到端）
├── HardlawApp/                    # SwiftUI 应用
│   ├── CourtViewModel.swift       # @Observable MVVM 状态机
│   ├── Services/                  # AutoFillPipeline, OCRRouter, PaddleOCREngine(.mm), EvidenceFileStore
│   ├── PaddleOCR/                 # 静态库 + 模型（inference.pdiparams/pdmodel, ppocr_keys.txt）
│   ├── LegalKnowledge/            # laws_chunks/ids/vocab/vectors（512 维，运行时唯一数据源）
│   └── UI/                        # Home, CaseWorkbench, CaseSections, GoalProgress 等
└── Models/                        # (gitignored) MLX 模型文件
```

关键设计：

1. **fail-closed 无处不在**：`Verdict.refuted` 默认为 true，解析失败即拒绝，证据缺失即阻塞
2. **证据 = 原文子串**：引用片段必须逐字存在于登记案卷；`Fingerprint`（CryptoKit SHA-256）做停滞检测
3. **actor 隔离**：`Court` / `FailSafeLLM` / `MLXLLM` / `AutoFillRuleEngine` 均为 actor，推理不阻塞主线程
4. **Swift 6 strict concurrency**：模型类型均为 Sendable 值类型

## 快速开始

```bash
# 1. 生成 Xcode 工程（pbxproj 由 XcodeGen 托管）
brew install xcodegen
cd ios && xcodegen generate

# 2. 构建并运行
xcodebuild build -project Hardlaw.xcodeproj -scheme HardlawApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# 3. 运行测试
xcodebuild test -project Hardlaw.xcodeproj -scheme HardlawKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## LLM 后端

| 后端 | 说明 | 延迟 |
|---|---|---|
| `RuleBasedLLM` | 劳动法证据缺口规则引擎（劳动关系/工资标准/欠薪/混同用工/解除程序等关键词规则） | <1ms |
| `FailSafeLLM` | 主后端失败自动降级到规则引擎，记录降级原因 | — |
| `MLXLLM` | 端侧大模型（mlx-swift-lm），默认 3B 模型约 1.9GB，首次使用自动下载 | 30-90s |

## 测试

`ios/HardlawKit/Tests/` 14 个文件、186 个用例：

- **郭又义劳动争议案端到端**：真实案卷材料（40+ PDF/JPG/MP4）驱动的完整流程，证据文字硬编码保证确定性可复现，与律师人工结论对比
- **DocumentClassifierGapRegressionTests**：按 gap id 精确断言分类类别
- **LegalKnowledgeTests**：关键词/语义检索、向量加载、维度一致性
- **BatchImportTests**：截断/垃圾输入不崩溃等健壮性回归

## 文档

- [`ios/README.md`](ios/README.md) — iOS 工程细节与后端选项
- [`docs/embedding-provider-plan.md`](docs/embedding-provider-plan.md) — CoreML embedding 方案（BGE-small-zh-v1.5）
- [`docs/legal-knowledge-verification.md`](docs/legal-knowledge-verification.md) — 法律检索模块验证记录
- [`docs/DocumentClassifier-gaps.md`](docs/DocumentClassifier-gaps.md) — 证据分类器 gap 分析
- [`expert-review-report.html`](expert-review-report.html) — 第三方专家评审报告（7.4/10）
- [`program.md`](program.md) — 近期任务书

## 路线图

- [x] Python 原型 → iOS Swift-only 迁移
- [x] 离线法律检索（关键词 + BGE 512 维语义向量）
- [x] 批量导入 + AI 自动填充（source-grounding 门控）
- [x] PaddleOCR 集成
- [x] 郭又义真实案卷端到端验证
- [x] CoreML 语义模型打包（`bge-small-zh-v1.5.mlpackage` + vocab.txt，转换脚本 `scripts/convert_bge_to_coreml.py`）
- [x] GitHub Actions CI（xcodegen + xcodebuild test）
- [ ] 用户自定义法条/规则导入
- [ ] SwiftData 案件历史持久化

## License

MIT — 见 [LICENSE](LICENSE)。
