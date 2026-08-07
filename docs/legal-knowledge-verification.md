# LegalKnowledge iOS Module - Integration Verification Report

**Date:** 2026-08-07
**Verification type:** Read-only analysis and testing -- no source code modified

## 1. Module Structure

| File | Purpose | Status |
|------|---------|--------|
| `LawChunk.swift` | Data model with Codable conformance | OK |
| `LawStore.swift` | File-based repository + keyword search | OK |
| `LawIndex.swift` | Hybrid search (keyword + optional semantic) | **BUG** |
| `EmbeddingProvider.swift` | Protocol for semantic embedding | OK |
| `LegalKnowledgeTests.swift` | Test suite (9 test cases) | See findings |
| `project.yml` | XcodeGen target config | See findings |

## 2. Data Integrity Results

### 2.1 Exported Files

All 4 export files are present and structurally valid:

| File | Size | Records | Status |
|------|------|---------|--------|
| `laws_chunks.json` | 6.8 MB | 11,327 chunks | OK |
| `laws_vocab.json` | 628 KB | 14,329 tokens | OK |
| `laws_vectors.bin` | 16.3 MB | 11,157 x 384 float32 | OK |
| `laws_ids.json` | 437 KB | 11,157 IDs | OK |

### 2.2 Field Mapping

`LawChunk.CodingKeys` correctly maps to JSON keys:
- `id`, `lawID` ("law_id"), `lawTitle` ("law_title"), `category`, `articleNum` ("article_num"), `heading`, `text`

All 11,327 chunks have all required fields present. No chunks have empty or extremely short text (min: 12 chars, avg: 119 chars).

### 2.3 Vector Integrity

- 11,157 vectors x 384 dimensions (matches MiniLM-L12-v2 output)
- All vectors are L2-normalized (norm = 1.000000)
- No NaN or Inf values found
- Binary header format matches `LawIndex.loadVectors()` expectations (uint32 nVecs, uint32 dim)
- Vector file size exactly matches expected: `8 + 11157 * 384 * 4 = 17,137,160 bytes`

### 2.4 IDF Vocabulary

- 14,329 vocabulary entries with `df` (document frequency) and `idf` (inverse document frequency)
- IDF formula appears to use approximately `N/(df + smoothing)` rather than standard log-IDF, but is self-consistent
- Top IDF tokens are rare terms (df=1), bottom IDF tokens are common terms (df=10,485 for "中华人民共和国")
- IDF range: 0.10 - 7,551.0
- The Swift code does a direct lookup (no recomputation), so values are used as-is. This is correct.

### 2.5 Data Distribution

| Category | Chunk Count |
|----------|-------------|
| 行政法 | 3,954 |
| 民法商法 | 1,547 |
| 民法典 | 1,260 |
| 经济法 | 1,016 |
| 宪法相关法 | 959 |
| 司法解释 | 721 |
| 社会法 | 665 |
| 刑法 | 516 |
| 其他 | 285 |
| 宪法 | 200 |
| 规定 | 164 |
| 办法 | 38 |
| 案例 | 2 |

165 unique laws across 13 categories. Largest laws: 民诉法解释 (552 chunks), 合同编 (526), 刑法 (505).

## 3. Critical Bugs Found

### BUG 1 (CRITICAL): Duplicate chunk IDs cause runtime crash in `LawIndex.search()`

**Severity:** App will crash on first search

**Root cause:** 42 Criminal Law (刑法) articles have duplicate chunk IDs. These are amendment articles (之一, 之二, etc.) where the `article_num` field in the JSON does not include the amendment suffix.

Example:
- `刑法/第一百二十条` appears 7 times (for 第一百二十条, 第一百二十条之一, ..., 第一百二十条之六)
- All 7 entries have `article_num: "第一百二十条"` (suffix stripped)
- The text field correctly shows "第一百二十条之五 ..." but article_num is truncated

**Crash location:** `LawIndex.swift:161-163`
```swift
let chunkMap = Dictionary(
    uniqueKeysWithValues: store.chunks.map { ($0.id, $0) }
)
```
`Dictionary(uniqueKeysWithValues:)` traps on duplicate keys at runtime.

**Impact:**
- `LawIndex.search()` always crashes (chunkMap is built before any search logic)
- `LawStore.searchKeyword()` works fine (does not build chunkMap)
- All 4 test cases in `LawIndexTests` would crash
- Crashes even in keyword-only mode (no embedding provider needed)

**Root cause in data generation:** `law_store.py:303-304`
```python
_ARTICLE_RE = re.compile(
    r"^(第[零一二三四五六七八九十百千万\d]+\s*条)\s*(.*)",
    re.MULTILINE,
)
```
The regex captures only the base article number and does not include the "之X" amendment suffix.

**Affected: 42 chunk IDs** (all in 刑法), creating 53 duplicate entries:
- 刑法/第一百二十条: 7 duplicates (之一 through 之六)
- 刑法/第一百三十三条: 3 duplicates (之一, 之二)
- And 40 more with 2 duplicates each

### BUG 2 (MODERATE): Missing vocabulary terms for common legal queries

The following compound terms are NOT in the vocabulary despite being common search queries:

| Term | Reason |
|------|--------|
| `双倍工资` | Law text uses "二倍的工资" instead |
| `未签劳动合同` | Law text uses "未订立书面劳动合同" |
| `医疗期` | Not tokenized as compound |
| `生育津贴` | Not tokenized as compound |
| `失业保险` | Not tokenized as compound |
| `住房公积金` | Not tokenized as compound |

This causes keyword mismatch for user queries vs legal text formulations (synonym problem).

### BUG 3 (MINOR): 170 chunks without vectors

170 chunks (from categories including 司法解释, 社会法, 办法, 规定) have no corresponding vectors. This is likely by design (certain categories excluded from embedding), but should be documented.

## 4. Search Quality Assessment

Keyword search was tested using a Python simulation that replicates the exact Swift `LawStore.searchKeyword()` scoring logic (IDF lookup, TF clipping at 3.0, document length normalization, category boosting).

| Query | Top Result | Quality |
|-------|-----------|---------|
| 加班费怎么计算 | 司法解释(一)第42条 -- overtime burden of proof | GOOD |
| 试用期最长多久 | 劳动法第21条 -- "试用期最长不得超过六个月" | EXCELLENT |
| 未签劳动合同的双倍工资 | 民诉法解释第507条 -- wrong context (双倍 matching) | POOR |
| 用人单位单方解除劳动合同需要什么条件 | 劳动合同法第43条 -- correct | GOOD |
| 女职工产假多少天 | 女职工劳动保护特别规定第7条 -- "98天产假" | EXCELLENT |
| 经济补偿金的标准 | 司法解释(一)第53条 -- mentions term but not the standard | FAIR |
| 工伤认定需要什么条件 | 工伤保险司法解释第9条 -- relevant | GOOD |
| 最低工资标准 | 劳动法第48条 -- "最低工资保障制度" | EXCELLENT |
| 年休假天数 | 职工带薪年休假条例 -- all relevant results | EXCELLENT |
| 拖欠工资怎么办 | 劳动仲裁攻略 -- only 1 result, not about wage arrears | POOR |

**Score: 6/10 good or excellent, 2/10 fair, 2/10 poor**

Key quality issues:
1. "未签劳动合同的双倍工资" -- "双倍" matches civil code articles about double damages; the correct article (劳动合同法第82条, which uses "二倍") ranks 4th
2. "拖欠工资怎么办" -- only 1 result returned; "拖欠工资" token has df=1 and idf=7551 (very high), but only matches a guide document about overtime pay, not wage arrears
3. "经济补偿金的标准" -- top results mention the term but don't state the formula (N+1 standard)

## 5. Test Assertion Analysis

| Test | Expected | Data Supports? |
|------|----------|---------------|
| `loadFromBundle` | chunkCount > 10,000 | YES (11,327) |
| `keywordSearchLaborLaw` | Results with 加班费 or 延长工作时间 | YES (18 chunks) |
| `keywordSearchProbation` | Top result has 试用期 | YES (22 chunks) |
| `keywordSearchMaternityLeave` | Top result has 产假/女职工 | YES (36 chunks) |
| `chunkLookupByLaw` | 劳动法 >= 100 chunks | YES (107) |
| `loadVectors` | vectorCount > 10,000 | YES (11,157) |
| `keywordOnlySearch` | 劳动合同法第82条 found | LIKELY (1 chunk) |
| `unliteralDismissalSearch` | 劳动合同法/劳动法 in results | LIKELY |
| `chineseWordSegmentation` | 劳动合同 in tokens | Depends on NLTokenizer |
| `stopWordFiltering` | 怎么办 filtered, 拖欠工资 preserved | Depends on NLTokenizer |

Note: Tests in `LawIndexTests` will crash due to Bug #1 (duplicate IDs) before assertions are reached.

## 6. Project Configuration

`ios/project.yml`:
- Target `HardlawKit` includes `HardlawKit/Sources/LegalKnowledge` in sources -- **CORRECT**
- Resources include `HardlawKit/Resources/LegalKnowledge` as folder reference -- **CORRECT**
- `GENERATE_INFOPLIST_FILE: true` -- **CORRECT**
- Swift 6.0 with strict concurrency -- **CORRECT** (all types use `Sendable`)
- Deployment target iOS 17.0 -- appropriate for NLTokenizer
- Dependencies include `mlx-libraries` (for future CoreML/MLX embedding) -- **CORRECT**
- Tests target `HardlawKitTests` includes `HardlawKit/Tests` -- **CORRECT**
- Test host set to `HardlawApp` -- may need adjustment based on app structure

## 7. Recommendations

### Must Fix Before Ship

1. **Fix duplicate chunk IDs (Bug #1):** Modify `_ARTICLE_RE` in `law_store.py` to capture "之X" suffixes in article numbers:
   ```
   r"^(第[零一二三四五六七八九十百千万\d]+\s*条(?:之[一二三四五六七八九十\d]+)?)\s*(.*)"
   ```
   Re-run `export_for_ios.py` after the fix.

   Alternatively, as a defensive measure in the Swift code, change `LawIndex.swift:161-162` to handle duplicates:
   ```swift
   let chunkMap = Dictionary(
       store.chunks.map { ($0.id, $0) },
       uniquingKeysWith: { first, _ in first }
   )
   ```
   But fixing the data generation is the correct long-term solution.

2. **Add missing compound vocabulary terms (Bug #2):** Add `双倍工资`, `未签劳动合同`, `医疗期`, `生育津贴`, `失业保险`, `住房公积金` as known terms, either via synonym mapping or by adjusting the tokenizer's compound detection.

### Should Fix

3. **Add synonym mapping:** Map user query terms to legal text equivalents:
   - 双倍工资 -> 二倍的工资
   - 未签劳动合同 -> 未订立书面劳动合同
   - 辞退 -> 解除劳动合同

4. **Document the 170 chunks without vectors** so developers understand the limitation.

### Nice to Have

5. **Add more test queries** covering edge cases: wage arrears, discrimination, workplace injury procedures.
6. **Add performance benchmarks** for keyword search on device (expected <50ms for 11K chunks).
7. **Consider query expansion** for the keyword search to improve recall on poor-performing queries.

## 8. Readiness Assessment

**Keyword-only search (LawStore directly): READY** -- the data loads correctly, keyword scoring works, and results are reasonable for 8/10 test queries.

**Hybrid search (LawIndex): NOT READY** -- the duplicate ID bug (Bug #1) causes a guaranteed crash on any call to `LawIndex.search()`. This must be fixed before any integration testing.

**Overall: NOT READY for app integration** due to the critical crash bug. After fixing Bug #1, the module is suitable for initial testing with keyword-only search. Semantic search quality will depend on the chosen EmbeddingProvider implementation (not yet available on iOS).
