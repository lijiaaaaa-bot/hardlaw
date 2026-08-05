# hardlaw iOS — 能力评估与技术路线

## 当前能力总览

### ✅ 已完成的模块

| 模块 | 能力 | 技术栈 |
|------|------|--------|
| **证据采集** | 相机拍照/相册选取 → OCR 提取文字 | Vision framework (ANE 加速) |
| **中文 OCR 预处理** | 灰度→对比度拉伸→纠偏→二值化 | Core Image 管线 |
| **文档检测** | 矩形/人脸检测，批量 Vision 请求 | VNDetectRectanglesRequest |
| **规则判断** | 正则匹配违反项，生成 Verdict JSON | RuleBasedLLM (<1ms) |
| **Court 引擎** | Statute→Procedure→Evidence→Verdict 全流程 | actor Court (Swift concurrency) |
| **证据校验** | LLM 引用的 snippet 必须出现在 OCR 原文中 | EvidenceValidator.substring |
| **防停滞** | 相同 gap fingerprint 连续出现 → 触发 escalation | SHA-256 + StallDetector |
| **Fail-closed** | 解析失败/证据不足/缺少 LLM → 默认 reject | VerdictParser 三层回退 |
| **Reflection** | draft → verify → reflect 循环 | LawAgent.generateCatalogEntry |
| **人机协同** | machineDraft/humanConfirmed/humanOverridden 状态机 | FieldState |
| **缺口检测** | 依据劳动法 Statute 检查证据完整性 | GapDetectionProcedure |
| **目录生成** | 从 OCR 文本提取事实 → 撰写证明内容/证明目的 | LawAgent + 规则引擎 |
| **意图解析** | 命令栏文本 → 结构化操作 | IntentParser |
| **数据持久化** | Codable 文件存储 | PersistenceController |
| **Excel 导出** | 证据目录导出为 .xlsx | ExcelExport |
| **真实案例评测** | 郭又义劳动争议案 ground truth 对照 | OCRRealEvidenceTests |

### ❌ 待完成

| 优先级 | 模块 | 说明 |
|--------|------|------|
| **P0** | PaddleOCR 模型转化 | 静态库已链接 (47MB)，模型待转 .nb 格式 |
| **P1** | MLXLLM 集成 | Qwen2.5-0.5B 4-bit，替换 RuleBasedLLM |
| **P2** | 多模态 LLM | Qwen2.5-VL，处理手写件/印章/签名 |
| **P3** | 用户自定义 Statute | JSON 导入劳动法规 |
| **P3** | SwiftData 持久化 | 替换当前 Codable 文件存储 |

## iPhone 端侧可行性

### 已验证

- **iOS 17.0+**，所有 API 均为系统原生
- Vision OCR 使用 ANE（Apple Neural Engine），不占 CPU/GPU
- RuleBasedLLM 正则匹配 <1ms，零内存压力
- PaddleOCR Lite 静态库已是 ARM64 编译，可直接运行

### 待验证

- MLXLLM 需要 4GB+ 内存（iPhone 15 Pro 以上，8GB 机型）
- Qwen2.5-0.5B 4-bit 量化后约 400MB，完全在 Jetsam 限制内
- 全量推理预估 30-60s / 次（A17 Pro 以上），可接受

### 结论

**iPhone 15 Pro 以上完全可运行**。iPhone 14/标准版（6GB RAM）也可跑 MLXLLM，但需用更小的模型。

## 安装包大小估算

| 组件 | 大小 | 说明 |
|------|------|------|
| Swift 编译产物 (~7600 行) | ~5-8 MB | 两个 target |
| PaddleOCR 静态库 | 47 MB | ARM64 only，可 thin |
| PaddleOCR 模型 (.nb) | ~15-20 MB | 检测 + 识别，待添加 |
| SwiftUI 资源 | ~1-2 MB | 图标、字体（无大图） |
| MLXLLM 模型 (.gguf) | ~400 MB | Qwen2.5-0.5B Q4_K_M，On-Demand Resources |
| **总计（不含 MLX）** | **~65-80 MB** | App Store 下载大小 |
| **总计（含 MLX）** | **~480 MB** | 模型通过 ODR 按需下载 |

> 模型文件不应打入 IPA，使用 App Store 的 On-Demand Resources 机制按需下载。
> 首次启动时静默下载，用户无感知。

## OCR vs 多模态 LLM：为什么不能二选一

### hardlaw 的证据校验链

```
OCR 文本提取（确定性）→ EvidenceValidator.substring 校验（确定性）
                                    ↑
LLM 判断（概率性）→ 引用 OCR 文本中的 snippet → 校验通过/失败
```

去掉 OCR 后：

```
多模态 LLM 看图片 → 输出 "工资合计7550元"
                    → EvidenceValidator 拿什么验证？
                    → 图片是像素，substring match 不可用
                    → 反幻觉链条断裂
```

### 分工

| | OCR（PaddleOCR） | 多模态 LLM（Qwen2.5-VL） |
|---|---|---|
| **角色** | 法院书记员 | 专家证人 |
| **输出** | 精确文本（可逐字审计） | 语义理解（不可逐字验证） |
| **速度** | <100ms | 30-90s |
| **确定性** | 相同输入 = 相同输出 | 相同输入 ≠ 相同输出 |
| **擅长** | 打印文档、表格、数字 | 手写体、印章真伪、签名比对、版面异常 |
| **在 hardlaw 中的位置** | 证据采集层（上游） | 判断层（Court 内部） |

### 唯一例外：手写体

`证据12_EMS`（手写邮寄单）—— Vision OCR 6 种预处理全部失败。

此时多模态 LLM 可以绕过 OCR 直接理解手写内容。但这种情况下应标注 `confidence: low` 且 `evidenceRefs` 不可做 substring 校验。

## 路线建议

```
Phase 1（本周）: PaddleOCR 模型 .nb 转化 → 替换 Vision OCR
Phase 2（下周）: MLXLLM 文本模型 → 替换 RuleBasedLLM
Phase 3（远期）: Qwen2.5-VL 多模态 → 手写件/印章专项
```

三个阶段互不阻塞，可以独立上线。Phase 1 提升 OCR 准确率，Phase 2 提升判断智能水平，Phase 3 覆盖 OCR 无法处理的视觉场景。
