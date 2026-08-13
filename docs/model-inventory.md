# 模型来源与完整性记录

本文件记录 hardlaw 使用的全部 AI 模型资产的来源、版本与校验 hash,
保证供应链可审计、可复现。

## 语义嵌入模型(CoreML,本机)

| 项 | 值 |
|---|---|
| 模型 | `BAAI/bge-small-zh-v1.5` |
| 用途 | LawIndex 查询侧语义 embedding(query-side) |
| 输出维度 | 512 |
| 转换脚本 | `scripts/convert_bge_to_coreml.py`(coremltools + sentence-transformers) |
| 打包位置 | `ios/HardlawApp/bge-small-zh-v1.5.mlpackage` |
| 词汇表 | `ios/HardlawApp/LegalKnowledge/vocab.txt`(BERT WordPiece,21,128 tokens) |
| 文档向量 | `laws_vectors.bin`(11,724 × 512 float32,由 export 脚本离线条目生成) |

### 校验 hash(SHA-256)

```
model.mlmodel  141bad7e40744b377bc2ed97f10fd9847288520aedf49f9f49d52df30e191961
Manifest.json  f798d795bbd76be80966e9bb5e8e036b1fbe4f65f2decd78d036e6caf6ac0fab
```

> ⚠️ `.mlpackage` 内部权重(`weights/weight.bin`,47MB)体积大,未逐字节记录 hash;
> 复现途径 = 重跑 `convert_bge_to_coreml.py` 并比对上述 model.mlmodel hash。
> LFS 策略:`**/*.mlpackage/**` 排除 LFS(coremlcompiler 需要真实 blob)。

## 端侧 LLM(MLX,运行时下载/缓存)

| 项 | 默认 | 回退 |
|---|---|---|
| HuggingFace ID | `mlx-community/Qwen2.5-3B-Instruct-4bit` | `mlx-community/Qwen2.5-0.5B-Instruct-4bit` |
| pinned revision | `4f83f8f146fdf28b512a06562b671d7af4fab457` | `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3` |
| 位置 | `ios/HardlawKit/Sources/LLM/MLXLLM.swift` | 同左 |

- revision 为 HuggingFace snapshot hash,由 `ModelConfiguration(id:revision:)` 强制 pin;
  未知 modelID 直接 `fatalError`(不静默回退到 `main`)。
- 模型不随仓库分发(体积),首次使用需联网下载至设备 HF cache。

## 更新纪律

1. 换嵌入模型:重跑 `convert_bge_to_coreml.py` → 重导出 `laws_vectors.bin` → 更新本文件 hash。
2. 换 LLM:更新 `MLXLLM.swift` 的 modelID + revision(必须先 bench 验证)→ 更新本表。
