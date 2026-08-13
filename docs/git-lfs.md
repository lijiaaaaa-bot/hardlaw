# Git LFS 策略

## 现状

仓库内已入库的大二进制（>5MB，截至 2026-08-13）：

| 文件 | 大小 |
|---|---|
| `ios/HardlawApp/PaddleOCR/lib/libpaddle_api_light_bundled.a` | 49 MB |
| `ios/HardlawApp/LegalKnowledge/laws_vectors.bin` | 24 MB |
| `ios/HardlawApp/PaddleOCR/models/inference.pdiparams` | 10.7 MB |
| `ios/HardlawApp/LegalKnowledge/laws_chunks.json` | 7 MB |

这些 blob 已存在于 git 对象库中，`.gitattributes` 不会自动转换它们。

## 策略

- `.gitattributes` 已将 `*.a` / `*.bin` / `*.pdiparams` / `*.pdmodel` / `*.mp4` 声明为 LFS 跟踪。
  **今后新添加的此类文件**（以及 `git add --renormalize .` 后重新暂存的文件）会以 LFS 指针存储。
- **例外：`.mlpackage` 内部永不走 LFS**（`**/*.mlpackage/** !filter !diff !merge`）。
  Xcode 的 `coremlcompiler` 编译 `.mlpackage → .mlmodelc` 需要真实权重文件，
  权重一旦是指针会导致编译失败（曾发生过，见提交 43f9a3f）。
- 历史大文件**不做 `git lfs migrate` 重写**：迁移会重写已推送提交（`80a1d15` 之前的远端历史），
  导致本地与 `origin` 分叉，后续 push 必须 force，风险不可逆。

## 若需要瘦身历史（可选，破坏性）

```bash
# 1. 在干净工作树、无其他协作者的分支上执行
git lfs migrate import --above=10MB --include-ref=feature/hardlaw-ios
# 2. 这将重写该分支全部历史，推送时需 force
git push --force origin feature/hardlaw-ios
```

执行前请确认：所有已推送远端副本可丢弃、无他人基于旧历史工作。

## 参考

- 大文件定期复查：`git ls-files | while read f; do [ -f "$f" ] && s=$(stat -f%z "$f") && [ "$s" -gt 5242880 ] && echo "$s $f"; done | sort -rn`
