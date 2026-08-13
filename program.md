# Goal-Driven — 修复三个"最后一公里"

## Goal

PaddleOCR 接线 + MLX 回退链 + 端到端验收。让 7 个芯片能力全部闭环。

## Criteria for success

1. 模拟器构建成功（136 测试通过，零回归）
2. PaddleOCR 有 Swift 调用方：设备优先 Paddle、模拟器/失败回退 Vision
3. MLXLLM 加载失败 → 自动降级 RuleBasedLLM，不阻塞 App
4. 一条端到端测试：27 份 PDF 文本→OCR→目录草拟→缺口检测→全部通过

## Subagents

### Subagent 1 (OCR 决策器)
- 创建 `ios/HardlawApp/Services/OCRRouter.swift`：`OCRRouter.recognize(cgImage) -> [String]`
- 逻辑：设备 → PaddleOCR；模拟器/失败 → Vision
- 更新 `CourtViewModel.recognizeText(from:)` 使用 OCRRouter
- 约束：零 CS、不破坏现有测试

### Subagent 2 (LLM 回退链)
- 修改 `CourtViewModel.runCourt()`：try? MLXLLM，失败→RuleBasedLLM
- MLXLLM 增加 `isAvailable` 静态属性判断模型是否已缓存
- 未缓存时自动降级，首次使用提示用户连接 WiFi
- 约束：不破坏 MockLLM 测试

### Subagent 3 (端到端验收)
- 创建 `ios/HardlawKit/Tests/EndToEndTests.swift`
- 使用 GuoYouyiCaseTests 的证据文本（10 份 OCR 文字）
- 走完整流程：OCR→Court→applyVerdicts→导出 CSV
- 断言：目录生成成功、缺口检测产出、CSV 文件有效
- 目标：至少 1 条测试验证 27 份证据规模
