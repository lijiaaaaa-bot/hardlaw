# Hardlaw — 劳动/民事法律证据链 iOS 工作台

面向法律工作者的 **iOS 本地化案件工作台**：离线中文法律检索、批量导入、AI 证据自动填充与 fail-closed 判定，全程设备端处理，案卷材料不上传。

## 核心特性

- 📚 **离线法律检索** — 165 部法规、11,724 条法条 chunk；关键词 + BGE-small-zh-v1.5（512 维）语义混合检索
- ⚖️ **fail-closed 判定** — `Court` 状态机 + 劳动法证据规则引擎 + 端侧 MLXLLM，规则不满足默认拒绝
- 🔍 **反幻觉校验** — AI 引用必须逐字命中案卷原文（substring check），杜绝伪造证据引用
- 📦 **批量导入** — 文件夹 / zip 导入（防路径穿越、zip bomb），导入可取消
- ✍️ **AI 自动填充** — OCR 证据逐项填表，数值取自原文（source-grounding 门控），人工覆盖优先
- 🖼️ **双 OCR 引擎** — Vision 框架 + PaddleOCR 静态库
- 🧪 **真实案卷验证** — 郭又义劳动争议案 40+ 份真实材料端到端测试，对照律师结论

## 技术栈

| 层 | 技术 |
|---|---|
| 语言/并发 | Swift 6，strict concurrency，actor 隔离 |
| 检索 | NLTokenizer 关键词 + FAISS 风格向量（CoreML 512 维 query） |
| LLM | RuleBasedLLM（<1ms）→ FailSafeLLM 降级 → MLXLLM（端侧，约 1.9GB） |
| OCR | Vision + PaddleOCR（C++ 静态库） |
| 工程 | XcodeGen（pbxproj 生成），3 targets，186 个 XCTest |

## 快速开始

```bash
brew install xcodegen
cd ios && xcodegen generate
xcodebuild test -project Hardlaw.xcodeproj -scheme HardlawKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## 文档

`README.md`（总览）· `ios/README.md`（工程细节）· `docs/embedding-provider-plan.md`（语义检索方案）· `expert-review-report.html`（专家评审）

## License

MIT
