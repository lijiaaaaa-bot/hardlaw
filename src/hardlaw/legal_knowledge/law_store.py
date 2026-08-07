"""
law_store.py — File-based legal document repository.

Parses Markdown law files from data/laws/ into structured LawDocument
and LawChunk objects. No SQLite — follows intent-lab's approach of
Markdown-as-source-of-truth + in-memory structured access.

Law files are organized as::

    data/laws/
      ├── 宪法/
      │   └── 宪法.md
      ├── 民法典/
      │   ├── 总则.md
      │   ├── 物权编.md
      │   ├── 合同编.md
      │   └── ...
      ├── 刑法/
      │   ├── 刑法.md
      │   └── 刑法修正案*.md
      ├── 社会法/
      │   ├── 劳动法.md
      │   ├── 劳动合同法.md
      │   └── ...
      ├── 司法解释/
      │   └── ...
      └── ...

Each Markdown file structure::

    # Law Title
    <metadata lines — enactment date, amendments>
    <!-- INFO END -->
    ## Chapter Title
    ### Section Title (optional)
    第X条 Article text...
    ...
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ── Data Model ──────────────────────────────────────────────────────────


@dataclass
class LawChunk:
    """A single indexed chunk — typically one article (一条)."""

    chunk_id: str          # e.g. "劳动法/第3条"
    law_id: str            # e.g. "劳动法"
    law_title: str         # e.g. "中华人民共和国劳动法"
    category: str          # e.g. "社会法"
    article_num: str       # e.g. "第三条" or "" for preamble
    heading: str           # Chapter/section heading this chunk belongs to
    text: str              # The full text of this chunk
    search_text: str       # Combined text for indexing (heading + article + text)


@dataclass
class LawDocument:
    """Full law document metadata and content."""

    law_id: str            # Unique identifier (filename without .md)
    title: str             # Full Chinese title
    category: str          # Top-level category directory
    subcategory: str       # Subcategory directory (if any)
    path: Path             # Filesystem path
    enactment: str         # Enactment/amendment info from header
    full_text: str         # Complete Markdown content
    chunks: list[LawChunk] = field(default_factory=list)
    article_count: int = 0


# ── LawStore ─────────────────────────────────────────────────────────────


class LawStore:
    """File-based repository of Chinese legal documents.

    Scans data/laws/ on init, parses all Markdown files into structured
    LawDocument + LawChunk objects. All data lives in memory — the
    Markdown files are the source of truth.

    Parameters
    ----------
    data_dir:
        Path to the laws directory. Defaults to the bundled data/laws/
        relative to the hardlaw package root.
    """

    def __init__(self, data_dir: str | Path | None = None) -> None:
        if data_dir is None:
            data_dir = Path(__file__).resolve().parents[3] / "data" / "laws"
        self.data_dir = Path(data_dir)
        self._documents: dict[str, LawDocument] = {}
        self._chunks: list[LawChunk] = []
        self._by_category: dict[str, list[str]] = {}  # category -> [law_id, ...]
        self._load_all()

    # ── Public API ──────────────────────────────────────────────────────

    @property
    def law_count(self) -> int:
        """Total number of law documents loaded."""
        return len(self._documents)

    @property
    def chunk_count(self) -> int:
        """Total number of searchable chunks (articles)."""
        return len(self._chunks)

    @property
    def categories(self) -> list[str]:
        """All top-level categories."""
        return sorted(self._by_category.keys())

    def get(self, law_id: str) -> LawDocument | None:
        """Get a law document by its ID (filename without .md)."""
        return self._documents.get(law_id)

    def get_article(self, law_id: str, article_num: int | str) -> LawChunk | None:
        """Get a specific article by number."""
        doc = self._documents.get(law_id)
        if doc is None:
            return None
        article_str = f"第{article_num}条"
        for chunk in doc.chunks:
            if chunk.article_num == article_str:
                return chunk
        return None

    def list_laws(self, category: str | None = None) -> list[dict[str, Any]]:
        """List all laws, optionally filtered by category.

        Returns a list of {law_id, title, category, article_count} dicts.
        """
        result: list[dict[str, Any]] = []
        for doc in self._documents.values():
            if category and doc.category != category:
                continue
            result.append({
                "law_id": doc.law_id,
                "title": doc.title,
                "category": doc.category,
                "article_count": doc.article_count,
                "enactment": doc.enactment[:120] if doc.enactment else "",
            })
        result.sort(key=lambda d: d["title"])
        return result

    def search_keyword(
        self, query: str, limit: int = 20
    ) -> list[tuple[LawChunk, float]]:
        """Keyword search using jieba tokenization with TF-IDF-like scoring.

        Segments the query into Chinese words, expands with synonyms, then
        scores each chunk by token overlap weighted by inverse document
        frequency (IDF).

        Synonym expansion handles vocabulary mismatch between natural
        language queries and actual law text (e.g., "经济补偿金" in queries
        vs "经济补偿" in the law).
        """
        if not query.strip():
            return []

        query_tokens = _tokenize(query.strip())
        if not query_tokens:
            return []

        # Expand with synonyms for better recall
        query_tokens = _expand_query(query_tokens)

        # Compute IDF weights for query tokens
        n_docs = len(self._chunks)
        query_weights: dict[str, float] = {}
        for token in query_tokens:
            # Count docs containing this token
            df = sum(1 for c in self._chunks if token in _get_tokens(c))
            # Smooth IDF: (N - df + 0.5) / (df + 0.5)
            idf_val = max(0.1, (n_docs - df + 0.5) / (df + 0.5))
            query_weights[token] = idf_val

        scored: list[tuple[LawChunk, float]] = []
        for chunk in self._chunks:
            chunk_tokens = _get_tokens(chunk)
            # Weighted token overlap score
            score = sum(
                query_weights[t] * min(chunk_tokens.count(t), 3)
                for t in query_tokens
            )
            if score > 0:
                # Normalize by document token count to avoid long-doc bias
                norm_score = score / (1 + len(chunk_tokens) ** 0.5)
                # Apply category boost (down-weight guides/cases)
                boost = self._CATEGORY_BOOST.get(chunk.category, 0.8)
                norm_score *= boost
                scored.append((chunk, norm_score))

        scored.sort(key=lambda x: x[1], reverse=True)
        return scored[: max(limit, 100)]

    # ── Category weights for relevance boosting ───────────────────────

    #: Chunks in "reference" categories are down-weighted because they're
    #: guides, case collections, or administrative documents rather than
    #: primary legislation. Without this, long-form guides dominate keyword
    #: search results due to high token overlap.
    _CATEGORY_BOOST: dict[str, float] = {
        # Core legislation — highest priority
        "民法典": 1.0, "刑法": 1.0, "社会法": 1.0,
        "经济法": 1.0, "宪法": 1.0, "宪法相关法": 1.0,
        # Secondary legislation
        "民法商法": 0.9, "行政法": 0.85,
        # Judicial interpretations — long documents with dense terminology;
        # down-weighted to prevent them from crowding out the primary laws
        # they interpret. Users searching for "经济补偿金" should see
        # 劳动合同法 before the judicial interpretation.
        "司法解释": 0.4,
        # Administrative regulations and methods
        "规定": 0.5, "办法": 0.5,
        # Reference materials — heavily down-weighted
        "案例": 0.2, "其他": 0.15,
    }

    def all_chunks(self) -> list[LawChunk]:
        """Return all chunks (for index building)."""
        return list(self._chunks)

    # ── Loading ─────────────────────────────────────────────────────────

    def _load_all(self) -> None:
        """Scan data_dir and parse all .md files."""
        if not self.data_dir.is_dir():
            raise FileNotFoundError(
                f"Law data directory not found: {self.data_dir}\n"
                "Clone LawRefBook or copy law Markdown files to data/laws/"
            )

        for md_path in sorted(self.data_dir.rglob("*.md")):
            try:
                doc = self._parse_file(md_path)
                self._documents[doc.law_id] = doc
                self._chunks.extend(doc.chunks)
                self._by_category.setdefault(doc.category, []).append(doc.law_id)
            except Exception:
                # Skip malformed files silently — a single bad file
                # shouldn't break the entire law store.
                continue

    def _parse_file(self, path: Path) -> LawDocument:
        """Parse a single Markdown law file into a LawDocument."""
        text = path.read_text(encoding="utf-8")

        # Determine category from path relative to data_dir
        rel = path.relative_to(self.data_dir)
        parts = rel.parts
        category = parts[0] if len(parts) > 1 else "其他"
        subcategory = parts[1] if len(parts) > 2 else ""

        # Split header from body at <!-- INFO END -->
        header, _, body = text.partition("<!-- INFO END -->")
        header = header.strip()
        body = body.strip()

        # Extract title from first H1
        title_match = re.match(r"^#\s+(.+)$", header, re.MULTILINE)
        title = title_match.group(1).strip() if title_match else path.stem

        # Extract enactment info (lines between title and INFO END)
        enactment_lines: list[str] = []
        for line in header.split("\n")[1:]:
            line = line.strip()
            if line and not line.startswith("#") and not line.startswith("<!--"):
                enactment_lines.append(line)
        enactment = "；".join(enactment_lines) if enactment_lines else ""

        # Law ID: filename without extension
        law_id = path.stem

        # Parse articles into chunks
        chunks = _chunk_body(
            law_id=law_id,
            law_title=title,
            category=category,
            body=body,
        )

        return LawDocument(
            law_id=law_id,
            title=title,
            category=category,
            subcategory=subcategory,
            path=path,
            enactment=enactment,
            full_text=text,
            chunks=chunks,
            article_count=len(chunks),
        )


# ── Chunking ─────────────────────────────────────────────────────────────


# Matches articles like "第一条", "第四百六十三条", "第 1 条"
# Also captures "之X" suffixes: "第一百二十条之一", "第三十七条之二"
_ARTICLE_RE = re.compile(
    r"^(第[零一二三四五六七八九十百千万\d]+\s*条(?:之[零一二三四五六七八九十\d]+)?)\s*(.*)",
    re.MULTILINE,
)

# Chapter/section headings
_HEADING_RE = re.compile(r"^(#{2,4})\s+(.+)$", re.MULTILINE)

# Amendment instruction patterns for 刑法修正案 chunking.
# Matches lines like:
#   将刑法第十七条修改为：...
#   在刑法第一百三十三条之一后增加一条，作为第一百三十三条之二：...
#   将刑法第一百三十四条第二款修改为：...
_AMENDMENT_RE = re.compile(
    r"(?:将|在)刑法"
    r"(?P<full_article>第[零一二三四五六七八九十百千万\d]+条(?:之[零一二三四五六七八九十\d]+)?)"
    r"(?:第(?P<paragraph>[零一二三四五六七八九十\d]+)款)?"
    r"(?:修改为|后增加一条，作为\s*(?P<new_article>第[零一二三四五六七八九十百千万\d]+条(?:之[零一二三四五六七八九十\d]+)?)"
    r"|中增加一款作为[^，]*，将该条修改为)"
    r"[：:]\s*",
)


def _chunk_body(
    law_id: str,
    law_title: str,
    category: str,
    body: str,
) -> list[LawChunk]:
    """Split a law body into article-level chunks.

    Handles two formats:
    1. Standard legislation — articles start with "第X条" at line beginning.
    2. Criminal law amendments (刑法修正案) — instructional format:
       "将刑法第X条修改为：", "在刑法第X条后增加一条，作为第Y条："
    """
    chunks: list[LawChunk] = []

    # Detect amendment format: body contains amendment instruction patterns.
    # Don't check just the first line — some amendments have preface paragraphs
    # before the actual instructions (e.g., "为了惩治...对刑法作如下修改").
    if category == "刑法" and _AMENDMENT_RE.search(body):
        return _chunk_amendment(law_id, law_title, category, body)

    # Standard chunking: articles start with "第X条" at line beginning
    # Track current heading context
    current_heading = ""

    # Find all headings and article starts
    lines = body.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()

        # Track heading context
        heading_match = _HEADING_RE.match(line)
        if heading_match:
            current_heading = heading_match.group(2).strip()
            i += 1
            continue

        # Check for article start
        article_match = _ARTICLE_RE.match(line)
        if article_match:
            article_num = article_match.group(1)
            first_line_text = article_match.group(2)

            # Collect all lines until next article or heading
            chunk_lines = [line]
            j = i + 1
            while j < len(lines):
                next_line = lines[j].strip()
                if _ARTICLE_RE.match(next_line) or _HEADING_RE.match(next_line):
                    break
                if next_line:
                    chunk_lines.append(lines[j])
                j += 1

            full_text = "\n".join(chunk_lines).strip()

            # Build search text: context + article content
            search_parts = [law_title]
            if current_heading:
                search_parts.append(current_heading)
            search_parts.append(full_text)
            search_text = " ".join(search_parts)

            chunk = LawChunk(
                chunk_id=f"{law_id}/{article_num}",
                law_id=law_id,
                law_title=law_title,
                category=category,
                article_num=article_num,
                heading=current_heading,
                text=full_text,
                search_text=search_text,
            )
            chunks.append(chunk)
            i = j
        else:
            i += 1

    # If no articles found (e.g. preamble-only docs), create one chunk
    if not chunks and body.strip():
        chunks.append(LawChunk(
            chunk_id=f"{law_id}/full",
            law_id=law_id,
            law_title=law_title,
            category=category,
            article_num="",
            heading="",
            text=body.strip(),
            search_text=f"{law_title} {body.strip()}",
        ))

    return chunks


def _chunk_amendment(
    law_id: str,
    law_title: str,
    category: str,
    body: str,
) -> list[LawChunk]:
    """Split a 刑法修正案 body into per-instruction chunks.

    Each amendment instruction ("将刑法第X条修改为" / "在刑法第X条后增加一条")
    becomes its own searchable chunk with the affected article number.

    This replaces the previous behavior where entire amendments were 1 chunk,
    making their substantive content invisible to search.
    """
    chunks: list[LawChunk] = []

    # Find all amendment instruction positions
    instructions: list[tuple[int, int, str, str]] = []
    # (start_pos, end_pos, article_num, instruction_type)

    for m in _AMENDMENT_RE.finditer(body):
        start = m.start()
        end = m.end()

        # Determine article number
        new_article = m.group("new_article")
        if new_article:
            # "在刑法第X条后增加一条，作为第Y条" → use new article number Y
            article_num = new_article
        else:
            # "将刑法第X条修改为" → use full article number
            article_num = m.group("full_article")
            paragraph = m.group("paragraph")
            if paragraph:
                article_num = f"{article_num}第{paragraph}款"

        full_instruction = body[m.start():m.end()]
        instructions.append((start, end, article_num, full_instruction))

    if not instructions:
        # Fallback: no amendment instructions found, create single chunk
        if body.strip():
            chunks.append(LawChunk(
                chunk_id=f"{law_id}/full",
                law_id=law_id,
                law_title=law_title,
                category=category,
                article_num="",
                heading="",
                text=body.strip(),
                search_text=f"{law_title} {body.strip()}",
            ))
        return chunks

    # Extract text for each instruction
    for idx, (start, end, article_num, instruction) in enumerate(instructions):
        # Determine where this instruction's content ends
        if idx + 1 < len(instructions):
            next_start = instructions[idx + 1][0]
        else:
            next_start = len(body)

        # Content is: instruction header + text until next instruction
        content = body[start:next_start].strip()

        # Build search text
        search_text = f"{law_title} 刑法 {article_num} {content}"

        # Chunk ID: law_id/article_num with amendment suffix
        # e.g. "刑法修正案（十一）/第一百三十三条之二"
        chunk_id = f"{law_id}/{article_num}"

        chunks.append(LawChunk(
            chunk_id=chunk_id,
            law_id=law_id,
            law_title=law_title,
            category=category,
            article_num=article_num,
            heading="",
            text=content,
            search_text=search_text,
        ))

    return chunks


# ── Chinese Tokenization ─────────────────────────────────────────────────

#: Lazy-loaded jieba tokenizer
_JIEBA_LOADED = False

#: Stop words filtered during tokenization (set in _ensure_jieba)
_STOP_WORDS: set[str] = set()


def _ensure_jieba() -> None:
    """Load jieba and add legal-domain vocabulary."""
    global _JIEBA_LOADED
    if _JIEBA_LOADED:
        return
    import jieba

    # Common legal terms that jieba might not segment correctly.
    # Order matters: longer compounds must be added BEFORE shorter ones,
    # otherwise jieba will split on the shorter match first.
    legal_terms = [
        # ── Long compounds FIRST (≥5 chars) ──────────────────────
        "解除劳动合同", "终止劳动合同", "变更劳动合同",
        "订立劳动合同", "履行劳动合同", "违法解除劳动合同",
        "无固定期限劳动合同", "固定期限劳动合同",
        "未签订劳动合同", "未订立劳动合同", "未签劳动合同",
        "二倍工资", "双倍工资", "支付二倍的工资",
        "支付加班费", "带薪年休假",
        # ── Medium compounds (3-4 chars) ────────────────────────
        "未签订", "未订立", "未签", "未支付", "未缴纳",
        "未参加", "未安排", "未提供", "未履行", "未依法",
        "不予", "不得", "不能", "不会", "不应", "不许",
        "加班费", "双倍工资", "二倍工资", "经济补偿金",
        "经济补偿", "赔偿金", "违约金", "补偿金",
        "劳动合同", "集体合同", "固定期限", "无固定期限",
        "试用期", "最低工资", "劳动争议", "社会保险",
        "劳动报酬", "工作时间", "休息休假", "职业培训",
        "安全卫生", "女职工", "未成年工", "工伤认定",
        "加班工资", "病假工资", "劳务派遣",
        "拖欠工资", "克扣工资", "违法解除", "违法终止",
        "被迫解除", "协商一致", "书面形式", "口头形式",
        "实际履行", "视为订立", "视为续订",
        "无效合同", "可撤销", "效力待定", "善意取得",
        "无权处分", "表见代理", "情势变更", "显失公平",
        "乘人之危", "重大误解", "意思表示", "法律行为",
        "合同无效", "合同解除", "合同终止", "合同变更",
        "合同欺诈", "合同诈骗", "违约责任", "侵权责任",
        "个人信息", "隐私权", "数据安全", "商业秘密",
        "竞业限制", "不当得利", "不可抗力", "格式条款",
        "连带责任", "诉讼时效", "举证责任", "仲裁裁决",
        "行政复议", "行政诉讼",
        "用人单位", "劳动者", "劳动行政部门",
        "产品责任", "医疗事故", "交通事故", "工伤事故",
        "职业病", "安全生产", "环境保护", "消费者权益",
        "股权转让", "注册资本",
        "自首", "立功", "累犯", "缓刑", "假释", "减刑",
        # ── Colloquial → legal compound terms ──────────────────
        "高空抛物",     # Prevent "高空" + "抛物" split; map to 民法典/刑法 provisions
        "危险驾驶罪",   # Colloquial name for 刑法第133条之一
        "被辞退",       # Worker-perspective term
        "租房合同",     # Map to 租赁合同
        "借钱不还",     # Map to 民间借贷
        "借钱",         # Map to 借款
        "双倍",         # Prevent splitting "双倍工资"
        "年假",         # Map to 年休假
        "醉驾",         # Map to 醉酒驾驶
        # ── Short terms (2 chars) ───────────────────────────────
        "产假", "哺乳", "赔偿", "补偿",
    ]

    # Words that carry no legal meaning but are common in natural
    # language queries about the law. Filtered out during tokenization.
    global _STOP_WORDS
    _STOP_WORDS = {
        "怎么办", "怎样", "如何", "是否", "什么", "多少",
        "哪些", "哪个", "哪种", "怎么", "多久", "多长",
        "能不能", "可以吗", "行不行", "对不对",
        "导致", "造成", "致使", "引起", "产生", "形成",
        "根据", "按照", "依照", "关于", "对于", "有关",
        "及其", "以及", "或者", "并且", "因为", "所以",
        "的", "是", "在", "和", "与", "或", "之", "等",
        "后果", "责任", "权利", "义务",  # Generic legal nouns — pollute search results
    }
    for term in legal_terms:
        jieba.add_word(term)

    _JIEBA_LOADED = True


def _tokenize(text: str) -> list[str]:
    """Segment Chinese text into meaningful words using jieba.

    Returns a list of tokens, filtered to remove stop words and
    single-character noise tokens.
    """
    if not text.strip():
        return []

    _ensure_jieba()
    import jieba

    # Cut the text and filter
    tokens = jieba.lcut(text)
    result = []
    for t in tokens:
        t = t.strip()
        # Skip single-char tokens (except digits)
        if len(t) < 2 and not t.isdigit():
            continue
        # Skip stop words
        if t in _STOP_WORDS:
            continue
        result.append(t)
    return result


#: Per-chunk token cache for fast keyword scoring
_token_cache: dict[str, list[str]] = {}


def _get_tokens(chunk: "LawChunk") -> list[str]:
    """Return cached tokens for a chunk, computing them once."""
    if chunk.chunk_id not in _token_cache:
        _token_cache[chunk.chunk_id] = _tokenize(chunk.search_text)
    return _token_cache[chunk.chunk_id]


def _clear_token_cache() -> None:
    """Clear the token cache (e.g., after reindexing)."""
    _token_cache.clear()


# ── Query Expansion ──────────────────────────────────────────────────────

#: Synonym pairs for query expansion. When the query contains a term
#: from the left side, the right-side terms are added to the search.
#: This handles vocabulary mismatch between natural language queries
#: and actual law text wording.
_QUERY_SYNONYMS: dict[str, list[str]] = {
    # ── Labor law ──
    "经济补偿金": ["经济补偿"],
    "双倍工资": ["二倍工资", "二倍的工资"],
    "拖欠工资": ["克扣工资", "无故拖欠", "未支付工资", "劳动报酬"],
    "补偿金": ["经济补偿", "赔偿金"],
    "竞业限制": ["竞业禁止"],
    "无固定期限": ["无固定期限劳动合同"],
    "固定期限": ["固定期限劳动合同"],
    "未签订": ["未订立", "未签", "未与"],
    "未签劳动合同": ["未订立书面劳动合同", "未与劳动者订立", "双倍工资", "二倍工资", "支付二倍的工资"],
    "没签合同": ["未订立书面劳动合同", "双倍工资", "二倍工资"],
    "违法解除": ["违法解除劳动合同", "违法终止"],
    "合同无效": ["无效合同", "合同不生效"],
    "合同欺诈": ["欺诈手段", "欺诈行为", "欺诈", "可撤销", "违背真实意思"],
    "个人信息": ["个人数据", "个人信息保护"],
    "加班费": ["加班工资", "延长工作时间", "加班"],
    "产假": ["生育", "孕期", "哺乳期"],
    "被辞退": ["解除劳动合同", "违法解除", "经济补偿", "赔偿金"],
    "辞退": ["解除劳动合同", "违法解除"],
    "辞职": ["解除劳动合同", "劳动者解除"],
    "裁员": ["经济性裁员", "裁减人员"],
    # ── Civil / daily life ──
    "高空抛物": ["抛掷物品", "抛掷", "建筑物中抛掷"],
    "租房": ["租赁", "租赁合同", "承租", "出租"],
    "租房合同": ["租赁合同", "承租", "出租"],
    "合同到期": ["租赁期限届满", "租赁期满", "合同期限届满", "期限届满"],
    "借钱": ["借款", "民间借贷", "返还借款"],
    "借钱不还": ["借款", "民间借贷", "返还借款"],
    "交通事故": ["机动车", "道路交通", "侵权"],
    # ── Criminal ──
    "危险驾驶": ["醉酒驾驶", "追逐竞驶", "违规运输危险化学品", "机动车"],
    "危险驾驶罪": ["醉酒驾驶", "追逐竞驶", "违规运输危险化学品"],
    "醉驾": ["醉酒驾驶", "危险驾驶"],
    "盗窃": ["盗窃罪", "盗窃公私财物"],
    # ── General ──
    "试用期": ["试用期间"],
    "工伤": ["工伤保险", "因工受伤", "因工负伤"],
    "最低工资": ["最低工资标准", "当地最低工资"],
    "年休假": ["带薪年休假", "年假"],
    "年假": ["带薪年休假", "年休假"],
}


def _expand_query(tokens: list[str]) -> list[str]:
    """Add synonym tokens to improve recall.

    Returns the original tokens plus any synonym expansions found.
    """
    expanded = list(tokens)
    for token in tokens:
        synonyms = _QUERY_SYNONYMS.get(token)
        if synonyms:
            for syn in synonyms:
                if syn not in expanded:
                    expanded.append(syn)
    return expanded
