# Hardlaw Law Usage Scenarios -- Comprehensive Verification Report

Generated 2026-08-07 from actual Python search runs.

## 1. What the Hardlaw App Does

The iOS app (`ios/HardlawApp/`) is an **on-device labor dispute evidence verification workbench**. Its core workflow:

1. **Intake**: User creates a new labor dispute case (type of dispute, applicant/respondent, claims)
2. **Evidence Import**: Import evidence files (PDFs, images) which are OCR-processed on-device
3. **Catalog Generation**: AI (RuleBasedLLM on-device) drafts evidence catalog entries (proof content/proof purpose)
4. **Verification**: Reflection pattern -- every cited number is checked against the OCR source text, hallucinated numbers trigger automatic retry, unverifiable items flagged for human review
5. **Gap Detection**: Compares evidence against labor law statutes (employment relationship, wage arrears, mixed employment, severance calculation) to find missing evidence
6. **Export**: 7-column evidence directory exportable to Excel

All processing is local -- "证据不离开设备" (evidence never leaves the device).

The app targets **labor dispute arbitration preparation** (劳动争议仲裁). The legal knowledge database (`HardlawKit/Sources/LegalKnowledge/`) provides the searchable law reference that the LawAgent uses to validate claims against statutes.

### Module Architecture

| Module | Purpose |
|--------|---------|
| `HardlawKit/Sources/LegalKnowledge/` | Core law search: LawStore (keyword/IDF), LawIndex (FAISS + CoreML embeddings), bundled JSON+vector data |
| `HardlawKit/Sources/Court/` | Court reasoning engine that applies statutes to case data |
| `HardlawKit/Sources/Statute/` | Labor law statutes: employment relationship, wage arrears, mixed employment, severance, forced termination, burden of proof |
| `HardlawKit/Sources/LLM/` | RuleBasedLLM for deterministic on-device legal reasoning; MLXLLM for Apple Silicon models |
| `HardlawKit/Sources/Evidence/` | Evidence validation rules and reference checking |
| `HardlawKit/Sources/Procedure/` | Gap detection procedure definition |
| `HardlawKit/Sources/Verdict/` | Court hearing results and confidence scoring |
| `HardlawKit/Sources/Vision/` | PaddleOCR for Chinese text recognition |

## 2. Complete Law Catalog: 165 Documents / 11,327 Chunks

| Category | Count | Key Laws |
|----------|-------|----------|
| **行政法** (Administrative) | 56 | 治安管理处罚法, 道路交通安全法, 食品安全法, 个人信息保护法, 行政处罚法, 行政许可法, 土地管理法, 网络安全法, 药品管理法, 传染病防治法 |
| **宪法相关法** (Constitution-related) | 20 | 立法法, 国家安全法, 反恐怖主义法, 反有组织犯罪法, 国家赔偿法, 法院/检察院组织法 |
| **经济法** (Economic) | 17 | 个人所得税法, 企业所得税法, 反不正当竞争法, 产品质量法, 审计法, 旅游法, 民用航空法 |
| **民法商法** (Civil/Commercial) | 16 | 公司法, 证券法, 企业破产法, 消费者权益保护法, 商标法, 著作权法, 专利法, 电子商务法 |
| **刑法** (Criminal) | 12 | 刑法 (505 arts) + 11 amendments (1 chunk each) |
| **社会法** (Social) | 10 | 劳动法, 劳动合同法, 工会法, 未成年人保护法, 女职工劳动保护特别规定, 职工带薪年休假条例 |
| **民法典** (Civil Code) | 8 | 总则/物权编/合同编/人格权编/婚姻家庭编/继承编/侵权责任编/附则 (1,260 chunks total) |
| **司法解释** (Judicial Interpretations) | 7 | 民事诉讼法解释 (552 arts), 劳动争议解释(一), 工伤保险规定 |
| **宪法** (Constitution) | 6 | 宪法 (143 arts) + 5 amendments |
| **规定** (Regulations) | 6 | 工资支付暂行规定, 最低工资规定, 网络消费纠纷规定, 算法推荐管理规定, 人脸识别规定 |
| **办法** (Measures) | 3 | 企业职工带薪年休假实施办法, 全国年节及纪念日放假办法 |
| **其他** (Other) | 2 | 民事诉讼法, 劳动仲裁攻略 |
| **案例** (Cases) | 2 | 劳动人事争议典型案例, 指导性案例第42批 |

### All 165 Laws by Category

<details>
<summary>Click to expand full listing</summary>

**行政法** (56): 个人信息保护法, 义务教育法, 人口与计划生育法, 人民武装警察法, 人民警察法, 人民防空法, 传染病防治法, 保守国家秘密法, 公共图书馆法, 公共文化服务保障法, 公务员法, 公证法, 兵役法, 军事设施保护法, 出境入境管理法, 医师法, 反间谍法, 国家情报法, 国家通用语言文字法, 土地管理法, 城市房地产管理法, 密码法, 广告法, 户口登记条例, 护照法, 放射性污染防治法, 教师法, 教育法, 数据安全法, 枪支管理法, 核安全法, 档案法, 水污染防治法, 治安管理处罚法, 法律援助法, 测绘法, 海关法, 消防法, 献血法, 环境噪声污染防治法, 生物安全法, 电影产业促进法, 疫苗管理法, 社区矫正法, 禁毒法, 突发事件应对法, 网络安全法, 药品管理法, 行政处罚法, 行政复议法, 行政强制法, 行政许可法, 道路交通安全法, 防震减灾法, 食品安全法, 高等教育法

**宪法相关法** (20): 人民法院组织法, 选举法, 公职人员政务处分法, 军人地位和权益保障法, 反分裂国家法, 反外国制裁法, 反恐怖主义法, 反有组织犯罪法, 国家安全法, 国家赔偿法, 国徽法, 国旗法, 国歌法, 国籍法, 国防法, 城市居民委员会组织法, 居民身份证法, 村民委员会组织法, 立法法, 集会游行示威法

**经济法** (17): 个人所得税法, 产品质量法, 企业所得税法, 会计法, 农产品质量安全法, 出口管制法, 动物防疫法, 印花税法, 反不正当竞争法, 反食品浪费法, 契税法, 审计法, 旅游法, 标准化法, 民用航空法, 车辆购置税法, 进出口商品检验法

**民法商法** (16): 专利法, 个人独资企业法, 企业破产法, 公司法, 农村土地承包法, 农民专业合作社法, 合伙企业法, 商业银行法, 商标法, 消费者权益保护法, 涉外民事关系法律适用法, 电子商务法, 电子签名法, 票据法, 著作权法, 证券法

**刑法** (12): 刑法 + 9 amendments + 刑（十） + 刑（十一）

**社会法** (10): 劳动保障监察条例, 劳动合同法, 劳动法, 女职工劳动保护特别规定, 家庭教育促进法, 工会法, 未成年人保护法, 职工带薪年休假条例, 退役军人保障法, 预防未成年人犯罪法

**民法典** (8): 人格权编, 侵权责任编, 合同编, 婚姻家庭编, 总则, 物权编, 继承编, 附则

**司法解释** (7): 人民法院在线诉讼规则, 最高人民法院关于审理劳动争议案件适用法律问题的解释（一）, 工伤保险行政案件规定, 拒不支付劳动报酬刑事案件解释, 民诉法审判监督程序解释, 民诉法执行程序解释, 民诉法解释

**宪法** (6): 宪法 + 5 amendments

**规定** (6): 互联网信息服务算法推荐管理规定, 人脸识别技术规定, 娱乐场所管理条例, 工资支付暂行规定, 最低工资规定, 网络消费纠纷规定

**办法** (3): 企业职工带薪年休假实施办法, 全国年节及纪念日放假办法, 国家机关 & 事业单位工时实施办法

**其他** (2): 劳动仲裁和劳动诉讼的攻略, 民事诉讼法

**案例** (2): 劳动人事争议典型案例, 最高人民法院第42批指导性案例

</details>

## 3. Usage Scenario Query Results

Each query was run through the Python `LawIndex.search(query, k=5)` with hybrid RRF keyword + semantic search. Scores are RRF fused scores (lower = better for keywords; semantic contributes modestly).

### Scenario A: Worker/Labor Rights Lookup

| Query | Quality | Top Hit | Notes |
|-------|---------|---------|-------|
| 加班费怎么计算 | **Good** | 劳动争议解释(一) Art 42 (burden of proof for overtime) | Art 31 of 劳动合同法 at #2 (overtime pay obligation); Art 85 at #3 (penalties). Broadly correct but starts with procedural rule rather than substantive right. |
| 被辞退能拿多少钱 | **Poor** | 公务员法 Art 90 (civil servant termination) | Query "辞退" maps strongly to civil servant discipline. Should surface 劳动合同法 Art 46-47 (severance pay). Worker context not inferred. |
| 试用期被辞退有没有补偿 | **Fair** | 公务员法 Art 90 (civil servant) | 劳动合同法 Art 83 at #2 (probation violation); 劳动法 Art 21 at #4 (6-month max). Missing the key intersection: Art 39 (at-fault termination during probation = no severance). |
| 工伤怎么认定 | **Fair** | 工伤保险规定 Art 8 (third-party injury) | Strong judicial interpretation but missing the substantive 工伤保险条例 criteria for what constitutes a work injury. 劳动法 Art 70 at #2 is too general. |
| 年休假怎么安排 | **Excellent** | 职工带薪年休假条例 Art 3 (5/10/15 day scale) | Perfect. All top 5 results from the same regulation with exact answers. |
| 最低工资标准是多少 | **Good** | 劳动法 Art 48 (minimum wage system) | Direct hit. Art 48 states standard is set by province. Follow-up results correctly show enforcement provisions. |
| 女职工产假多少天 | **Excellent** | 女职工劳动保护特别规定 Art 7 (98 days) | Exact answer at #1. Follow-up includes Art 8 (maternity allowance details) and 劳动法 Art 62 (90+ day minimum). |
| 未签劳动合同有什么后果 | **Poor** | 劳动法 Art 24 (contract termination by agreement) | Completely missed 劳动合同法 Art 82 (double wage for no written contract). Top results are generic contract provisions. This is a critical failure for the app's target domain. |
| 经济补偿金怎么算 | **Fair** | 劳动争议解释(一) Art 53 (remedy amounts) | 劳动合同法 Art 47 (severance formula) only at #4. Correct article exists but ranked too low. |
| 竞业限制期限多久 | **Good** | 劳动争议解释(一) Art 39 (termination of NCC) | 劳动合同法 Art 23/24 at #3/#4 directly address NCC scope, duration, and compensation. |

**Scenario A score**: 5/10 good/excellent, 3/10 fair, 2/10 poor. Labo

r law queries work best when the query terms exactly match legal terminology. Natural language like "被辞退能拿多少钱" fails because "辞退" in the corpus primarily means civil servant termination.

### Scenario B: Legal Professional Reference (Article Lookup)

The `LawStore.get_article(law_id, article_num)` API works correctly when given the right law ID (filename without `.md`) and Chinese numeral article numbers:

```
store.get_article("劳动合同法", "四十七")
→ "第四十七条 经济补偿按劳动者在本单位工作的年限，每满一年支付一个月工资..."

store.get_article("刑法", "二百六十四")
→ "第二百六十四条 盗窃公私财物，数额较大的...处三年以下有期徒刑..."

store.get_article("道路交通安全法", "九十一")
→ "第九十一条 饮酒后驾驶机动车...醉酒驾驶机动车...吊销机动车驾驶证..."
```

**Caveat**: The API requires Chinese numerals (e.g., "四十七" not "47"). The iOS app's `LawStore.article(lawID:, articleNum:)` likely has the same constraint. A convenience method accepting Arabic numerals with automatic conversion would improve usability.

### Scenario C: HR/Employer Compliance

Same queries as Scenario A, since the labor law corpus covers both worker-side and employer-side inquiries. The neutral queries (年休假, 最低工资, 产假) work equally well for either role.

**Additional note for HR use**: The app's current focus is labor dispute evidence preparation (worker vs employer), not proactive compliance checking. An HR compliance module would need different UI flows and different search patterns.

### Scenario D: General Citizen Legal Knowledge

| Query | Quality | Top Hit | Notes |
|-------|---------|---------|-------|
| 租房合同违约怎么处理 | **Good** | 民法典 Art 584 (breach damages) | Civil Code contract breach provisions at #1-3. Correctly finds general breach remedies but no lease-specific articles (租赁合同 is chapter 14 of the contract book). |
| 借钱不还怎么办 | **Poor** | 民法典 Art 670 (interest deduction) | Very low scores (0.015-0.016). Results are about loan terms rather than debt recovery. Missing legal framework for enforcing debt repayment. |
| 交通事故赔偿标准 | **Fair** | 网络消费纠纷规定 Art 10 (consumer damages) | Irrelevant #1 result. 道路交通安全法 Art 73 at #2 (accident report). Civil Code motor vehicle tort provisions at #3-5. No specific compensation amount table. |

### Scenario E: Criminal Law Lookup

| Query | Quality | Top Hit | Notes |
|-------|---------|---------|-------|
| 盗窃罪量刑标准 | **Poor** | 刑法 Art 63 (mitigation rules) | Shows general sentencing framework (Art 61-64) but NOT the specific theft article (Art 264). The specific article IS in the database but ranked below general provisions. This is an IDF weighting issue -- "量刑" matches general sentencing provisions more strongly than specific crimes. |
| 正当防卫怎么认定 | **Good** | 刑法 Art 20 (self-defense) | Correct article at #2, with Civil Code Art 181 at #1. Both are relevant. |
| 醉酒驾车怎么处罚 | **Fair** | 道路交通安全法 Art 19 (licensing) | The key article (Art 91, drunk driving penalties) is at #3. The criminal law dangerous driving article (Art 133之一) did not appear in top 5, which is a gap since drunk driving is criminalized. |
| 网络诈骗怎么判刑 | **Poor** | 反恐怖主义法 Art 70 (terrorism judicial cooperation) | No specific fraud article surfaced. Top results are about "判刑" (sentencing) in general. The actual fraud provisions (Art 266: fraud; Art 287: computer crime) are not retrieved. |

### Gap Analysis: What's NOT Covered

| Query | Result | Assessment |
|-------|--------|------------|
| 网购退货怎么维权 | **Covered** | 消费者权益保护法 Art 24/25 directly address 7-day no-reason returns for online purchases. Good results. |
| 结婚离婚 | **Covered** | 民法典 婚姻家庭编 (Art 1046-1051 for marriage, divorce provisions elsewhere in the book). Marriage conditions are well-retrieved. |
| 征地补偿标准是多少 | **Covered** | 土地管理法 Art 46-48 with detailed compensation requirements. Excellent results. |
| 网络诈骗怎么判刑 | **Not well covered** | No specialized cyber fraud law. No cybersecurity-specific criminal provisions surfaced. The 网络安全法 exists but doesn't contain criminal sentencing. |
| 个人隐私被泄露怎么办 | **Not well covered** | 个人信息保护法 exists but search surfaces government secrecy provisions instead of individual privacy rights. The query "泄露" matches government/official confidentiality clauses more strongly than personal data protection rights. |

## 4. Data Quality Issues Found

### Issue 1: 刑法修正案 All Have 1 Chunk Each (Complete Data Loss)

All 11 criminal law amendment files are parsed as a single chunk each:

| File | Expected Behavior | Actual |
|------|------------------|--------|
| 刑法修正案11.md | ~40+ individual amendment articles | 1 chunk with entire file content |

**Root cause**: The amendment files use "将刑法第一百九十一条修改为" format, not "第X条" format. The chunker's `_ARTICLE_RE` regex only matches `第...条` patterns. When no articles are found, the fallback creates one chunk with the entire body text.

**Impact**: Amendments are not searchable at the individual article level. A query about a specific amendment change will match the entire file, with poor relevance. 40+ criminal law changes from Amendment 11 alone are effectively invisible to search.

### Issue 2: 案例 Files Are 1 Chunk Each

| File | Chunks | Content |
|------|--------|---------|
| 劳动人事争议典型案例 | 1 | Entire case collection as one chunk |
| 最高人民法院第42批指导性案例 | 1 | Entire batch as one chunk |

**Root cause**: Case files use a non-standard format without 第X条 markers.

**Impact**: Case precedent is not searchable by individual case. A query about a specific type of labor dispute can't surface relevant precedent.

### Issue 3: Law IDs Are Filename-Stripped

The law_id used in code is the filename without `.md`, which means:
- "劳动合同法" not "中华人民共和国劳动合同法"
- "刑法" not "中华人民共和国刑法"
- "广告法" not "中华人民共和国广告法"

The `get_article()` API requires these shortened IDs. This is consistent but not documented -- a developer calling `store.get("中华人民共和国劳动合同法")` will get `None`.

### Issue 4: Article Numbers Require Chinese Numerals

`store.get_article("劳动合同法", "四十七")` works, `store.get_article("劳动合同法", 47)` does not. The API accepts `int | str` but when given an int like `47`, it builds "第47条" while the actual data stores "第四十七条".

**Fix**: Add a Chinese numeral converter in the `get_article` method.

### Issue 5: Category Boost May Hide Relevant Content

The category boost configuration down-weights "案例" to 0.25 of normal. This means precedent cases from the Supreme People's Court -- which are directly relevant to legal argument -- are 4x less likely to appear in search results. For a legal professional reference tool, precedent should arguably be weighted higher, not lower.

### Issue 6: 民法典 Split Into 8 Files

The Civil Code is split into 8 separate files (总则, 物权编, 合同编, etc.). All 8 documents share the same title "中华人民共和国民法典". When a user searches for "民法典" related topics, the results correctly show different books but the identical title makes it hard to distinguish which book a result comes from.

## 5. Important Laws NOT in the Database

| Missing Law | Importance | Why It Matters |
|-------------|-----------|----------------|
| **社会保险法** | Critical for labor | Social insurance (pension, medical, unemployment, work injury, maternity) is a core labor right. Currently only has fragmented coverage via 劳动法 and 工伤保险规定. |
| **妇女权益保障法** | High | Gender discrimination, workplace harassment, equal employment rights. |
| **残疾人保障法** | Medium | Disability employment quotas, workplace accommodation. |
| **老年人权益保障法** | Medium | Age discrimination, elderly care obligations. |
| **反家庭暴力法** | Medium | Domestic violence protection orders intersect with labor (leave, workplace safety). |
| **保障农民工工资支付条例** | High for labor | Directly relevant to the app's core wage dispute domain. Has specific rules about wage deposit accounts and payment guarantees. |
| **住房公积金管理条例** | Medium for labor | Housing fund is a mandatory benefit; disputes about non-payment are common in labor arbitration. |

## 6. Search Quality Scorecard

### By Query Type

| Query Type | Score | Notes |
|-----------|-------|-------|
| **Exact terminology match** (e.g., "年休假", "产假", "最低工资") | Excellent | Terms that appear verbatim in law titles/article text return accurate, focused results. |
| **Legal concept queries** (e.g., "竞业限制", "加班费", "正当防卫") | Good | Legal terms are well-handled by jieba tokenization and synonym expansion. |
| **Natural language questions** (e.g., "被辞退能拿多少钱", "借钱不还怎么办") | Poor | The search has no query understanding. "怎么办", "多少" etc. are stop-word filtered, but the remaining query doesn't capture intent well. |
| **Combined concepts** (e.g., "试用期被辞退补偿") | Fair | Each concept is matched separately but the intersection is not modeled. |
| **Specific article lookup** (law + article number) | Excellent | `get_article()` API works correctly (with Chinese numerals). |
| **Criminal sentencing queries** (e.g., "盗窃罪量刑", "网络诈骗判刑") | Poor | "量刑" matches general sentencing provisions (Art 61-64) more strongly than specific crime articles. IDF weights favor general principles. |

### By Law Category

| Category | Search Quality | Notes |
|----------|---------------|-------|
| 社会法 (Labor laws) | Good | Core domain. 劳动法, 劳动合同法, and related regulations have good coverage and synonym expansion. |
| 民法典 (Civil Code) | Good | Strong coverage via 8 books. Contract, tort, and property provisions surface well. |
| 刑法 (Criminal Law) | Fair | Core articles exist but 量刑 queries fail. Amendments are single-chunk. |
| 行政法 (Administrative) | Varies | Specific regulations (治安处罚, 交通) work well. General "行政" queries are noisy due to the category's large size. |
| 司法解释 (Judicial Interpretations) | Good | Strong for labor topics but dominate some search results due to high token density. |
| 案例 (Precedent Cases) | Poor | Category boost of 0.25 effectively hides them. |

## 7. Recommendations

### Immediate (fix data quality)

1. **Fix 刑法修正案 chunking**: Parse amendment files with a custom parser that recognizes modification instruction format ("将刑法第X条修改为"). Each amendment instruction should be its own chunk, with the instruction as article text and the original article number as context.

2. **Fix 案例 chunking**: Split case collections into individual case chunks. Each case should be searchable independently.

3. **Add Chinese numeral conversion** to `get_article()`: Accept both `int` (47) and `str` ("四十七"), automatically converting Arabic to Chinese numerals.

4. **Rebalance category boost**: Increase 案例 boost from 0.25 to 0.8 to make precedent cases visible in search results.

### Short-term (improve search)

5. **Add query-specific synonym expansion**: Map common natural language queries to legal terms:
   - "被辞退" -> add "解除劳动合同", "经济补偿"
   - "借钱不还" -> add "借款合同", "债务", "违约责任"
   - "被开除" -> add "解除劳动合同", "违法解除"

6. **Add criminal law synonym expansions**:
   - "量刑" -> add specific crime names
   - "判刑" -> add "处...有期徒刑", "死刑"
   - "网络诈骗" -> add "诈骗", "电信诈骗", "计算机犯罪"

7. **Add law-level boost for specific queries**: When query contains "辞退", boost 劳动合同法 results higher than 公务员法 (which currently dominates "辞退" queries).

### Medium-term (add laws)

8. **Add critical missing labor laws**:
   - 社会保险法 (Social Insurance Law)
   - 保障农民工工资支付条例 (Migrant Worker Wage Payment Regulation)
   - 工伤保险条例 (full version, not just judicial interpretation)

9. **Add social protection laws**:
   - 妇女权益保障法
   - 残疾人保障法
   - 反家庭暴力法
   - 住房公积金管理条例

10. **Add specialized criminal/cyber provisions** (or expand existing criminal law coverage to include computer/network crimes articles).

### Search Architecture

11. **Consider query intent classification**: Add a lightweight intent classifier before search to detect whether a query is about civil, criminal, labor, or administrative law, then boost results from relevant categories.

12. **Improve RRF fusion**: The current configuration (keyword k=10, semantic k=60) heavily weights keyword over semantic search. Since the multilingual MiniLM embedding model has mediocre Chinese performance, this is correct for now, but switching to a Chinese-optimized embedding model (e.g., `BAAI/bge-large-zh-v1.5`) would allow a more even fusion ratio.

## Appendix: Test Methodology

All queries were run through the Python backend:
```python
from hardlaw.legal_knowledge import LawStore, LawIndex
store = LawStore()
index = LawIndex(store)
index.ensure_fresh()
results = index.search(query, k=5)
```

- **Embedding model**: `paraphrase-multilingual-MiniLM-L12-v2` (384-dim)
- **FAISS index**: IndexFlatIP (cosine similarity via normalized vectors)
- **Keyword search**: jieba tokenization + TF-IDF with synonym expansion
- **Fusion**: RRF with keyword k=10, semantic k=60
- **Category boosts**: 民法典/刑法/社会法/经济法/司法解释 = 1.0; 行政法/民法商法 = 0.9; 案例/办法/规定/其他 = 0.25

The iOS app mirrors this same search logic using:
- `NLTokenizer` (Apple's Chinese word segmentation, equivalent to jieba)
- Pre-computed IDF vocabulary from `laws_vocab.json`
- CoreML embeddings or FAISS via `LawIndex.swift`
- Same category boost values
