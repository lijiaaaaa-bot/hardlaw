"""
llm_ranker.py — LLM-powered query enhancement, reranking, and answer generation.

Integrates cloud LLM (OpenAI-compatible API) with the local LawStore/LawIndex
to provide:

1. **Query rewriting** — colloquial → legal terminology
2. **Reranking** — LLM pointwise scoring of candidate chunks
3. **Answer generation** — RAG-style answer with law citations

Provider-agnostic: works with any OpenAI-compatible API (DeepSeek, Qwen, GPT,
Claude via proxy, etc.). Configure via environment variables or constructor.

Usage::

    from hardlaw.legal_knowledge import LawStore, LawIndex, LLMRanker

    store = LawStore("data/laws")
    index = LawIndex(store)
    ranker = LLMRanker(store, index)

    import asyncio
    result = asyncio.run(ranker.search_with_llm("老板把我开了还不给钱"))
    print(result.answer)
    for chunk, score in result.top_chunks:
        print(f"  [{chunk.law_title}] {chunk.article_num}: {score:.1f}")

Environment variables::

    HARDLAW_LLM_API_KEY   — API key (default: $OPENAI_API_KEY)
    HARDLAW_LLM_BASE_URL  — API base URL (default: https://api.deepseek.com/v1)
    HARDLAW_LLM_MODEL     — Model name (default: deepseek-chat)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from hardlaw.legal_knowledge.law_store import LawChunk, LawStore
    from hardlaw.legal_knowledge.law_index import LawIndex

logger = logging.getLogger(__name__)


# ── Data Model ──────────────────────────────────────────────────────────────


@dataclass
class LLMSearchResult:
    """Complete result from an LLM-enhanced search.

    Attributes
    ----------
    rewritten_query:
        The query after LLM rewriting into legal terminology.
    answer:
        LLM-generated answer with law citations (markdown format).
    top_chunks:
        Reranked top-k chunks with LLM scores.
    raw_kw_results:
        Original keyword search results before reranking (for debugging).
    """

    rewritten_query: str
    answer: str
    top_chunks: list[tuple["LawChunk", float]]
    raw_kw_results: list[tuple["LawChunk", float]] = field(default_factory=list)


# ── Prompt Templates ────────────────────────────────────────────────────────


_SYSTEM_PROMPT = """你是一位精通中国法律的专业法律助手。你的职责是：
1. 将用户的口语化问题转换为精确的法律术语查询
2. 对检索到的法律条文进行相关性评分
3. 基于法律条文生成准确、带出处的法律解答

你需要熟悉中国的法律体系，包括《民法典》《刑法》《劳动法》《劳动合同法》
《社会保险法》《工伤保险条例》等法律法规。

重要原则：
- 精确引用法条出处（法律名称 + 第几条）
- 区分"应当"（强制性规定）、"可以"（授权性规定）、"不得"（禁止性规定）
- 如果法条信息不足以回答，明确指出
- 不编造法律条文，不确定时说明不确定"""


_QUERY_REWRITE_PROMPT = """请将以下用户的口语化问题改写为精确的法律检索查询。

要求：
1. 将口语转换为法律术语（如"被开除"→"解除劳动合同"、"不给钱"→"拖欠工资"）
2. 保留用户的核心诉求和法律关系
3. 只输出改写后的查询文本，不要有任何解释或标点

## 示例

用户：老板把我开了还不给钱
改写：用人单位违法解除劳动合同拖欠工资经济补偿金

用户：在工地干活摔伤了怎么办
改写：工伤认定工伤待遇劳动关系确认

用户：试用期被辞退有赔偿吗
改写：试用期解除劳动合同经济补偿金

用户：{query}
改写："""


_RERANK_PROMPT = """请对以下候选法律条文进行相关性评分。

用户查询：{query}

候选法条：
{chunks_text}

请为每条法条给出0-10分的相关性评分和一句话理由。
10分=完全直接相关，0分=完全无关。

输出JSON数组格式：
```json
[
  {{"chunk_id": "法律名/第X条", "score": 8, "reason": "该条款直接规定了..."}},
  ...
]
```

只输出JSON数组，不要有其他内容。"""


_ANSWER_PROMPT = """请基于以下法律条文回答用户的问题。

用户问题：{query}

相关法律条文：
{chunks_text}

要求：
1. 直接回答用户的问题，引用具体的法律条文
2. 每条引用必须注明法律名称和条款号，格式：[《法律名》第X条]
3. 如果涉及金额计算，说明计算公式
4. 区分"应当/必须"（强制）、"可以"（权利）、"不得"（禁止）
5. 如果信息不足以回答，明确指出缺少什么信息
6. 使用markdown格式，层次清晰"""


# ── LLMRanker ───────────────────────────────────────────────────────────────


class LLMRanker:
    """Cloud LLM-enhanced legal search: query rewrite → retrieve → rerank → answer.

    Uses OpenAI-compatible chat/completions API. Defaults to DeepSeek
    (cheap, strong Chinese, API-compatible). Swap via ``base_url`` and
    ``model`` parameters.

    Parameters
    ----------
    law_store:
        LawStore instance for keyword retrieval and chunk access.
    law_index:
        Optional LawIndex for semantic search. If omitted, only keyword
        retrieval is used in ``search_with_llm()``.
    api_key:
        API key. Reads from ``HARDLAW_LLM_API_KEY`` or ``OPENAI_API_KEY``.
    base_url:
        OpenAI-compatible API base URL. Default: DeepSeek.
    model:
        Model name. Default: ``deepseek-chat``.
    max_concurrent:
        Max concurrent LLM calls during parallel reranking.
    """

    def __init__(
        self,
        law_store: "LawStore",
        law_index: "LawIndex | None" = None,
        *,
        api_key: str | None = None,
        base_url: str | None = None,
        model: str | None = None,
        max_concurrent: int = 5,
    ) -> None:
        self._store = law_store
        self._index = law_index

        self._api_key = (
            api_key
            or os.getenv("HARDLAW_LLM_API_KEY")
            or os.getenv("OPENAI_API_KEY")
        )
        self._base_url = (
            base_url
            or os.getenv("HARDLAW_LLM_BASE_URL")
            or "https://api.deepseek.com/v1"
        )
        self._model = (
            model
            or os.getenv("HARDLAW_LLM_MODEL")
            or "deepseek-chat"
        )
        self._max_concurrent = max_concurrent
        self._sem = asyncio.Semaphore(max_concurrent)

    # ── Public API ──────────────────────────────────────────────────────────

    async def rewrite_query(self, query: str) -> str:
        """Rewrite a colloquial query into legal terminology.

        >>> await ranker.rewrite_query("老板把我开了还不给钱")
        "用人单位违法解除劳动合同拖欠工资经济补偿金"
        """
        prompt = _QUERY_REWRITE_PROMPT.format(query=query)
        response = await self._call_llm(prompt, system=None, temperature=0.1)
        # Strip any quotes, trailing punctuation, or explanation
        rewritten = response.strip().strip('"\'。，,.')
        logger.debug("Query rewrite: %r → %r", query, rewritten)
        return rewritten

    async def rerank(
        self,
        query: str,
        candidates: list["LawChunk"],
        top_k: int = 5,
    ) -> list[tuple["LawChunk", float]]:
        """Rerank candidate chunks using LLM pointwise scoring.

        Scores each chunk 0–10, returns top_k sorted by score.
        If there are more than 15 candidates, splits into parallel batches.
        """
        if not candidates:
            return []

        # For small candidate sets, score all at once
        if len(candidates) <= 15:
            return await self._rerank_batch(query, candidates, top_k)

        # For larger sets, split into parallel batches and merge
        batch_size = 15
        batches = [
            candidates[i : i + batch_size]
            for i in range(0, len(candidates), batch_size)
        ]

        tasks = [
            self._rerank_batch(query, batch, len(batch))
            for batch in batches
        ]
        batch_results = await asyncio.gather(*tasks)

        # Merge and sort
        all_scored: list[tuple["LawChunk", float]] = []
        for scored in batch_results:
            all_scored.extend(scored)

        all_scored.sort(key=lambda x: x[1], reverse=True)
        return all_scored[:top_k]

    async def generate_answer(
        self,
        query: str,
        context_chunks: list["LawChunk"],
    ) -> str:
        """Generate a law-cited answer from retrieved chunks.

        Uses RAG pattern: chunks as context, LLM generates cited answer.
        """
        if not context_chunks:
            return "未找到相关法律条文，建议补充更多案情信息或咨询专业律师。"

        chunks_text = self._format_chunks_for_prompt(context_chunks)
        prompt = _ANSWER_PROMPT.format(query=query, chunks_text=chunks_text)
        return await self._call_llm(prompt, system=_SYSTEM_PROMPT, temperature=0.3)

    async def search_with_llm(
        self,
        query: str,
        top_k: int = 5,
        *,
        use_semantic: bool = True,
    ) -> LLMSearchResult:
        """Full LLM-enhanced search pipeline.

        1. Rewrite query into legal terminology
        2. Retrieve candidates (keyword + optional semantic)
        3. LLM reranking
        4. Generate cited answer

        This is the primary entry point for the app.
        """
        # Step 1: Rewrite query
        rewritten = await self.rewrite_query(query)

        # Step 2: Retrieve candidates
        # Search with both original and rewritten query, merge results
        if use_semantic and self._index is not None:
            raw_results = self._index.search(query, k=20)
            rewritten_results = self._index.search(rewritten, k=10)
        else:
            raw_results = self._store.search_keyword(query, limit=20)
            rewritten_results = self._store.search_keyword(rewritten, limit=10)

        # Merge and deduplicate
        seen_ids: set[str] = set()
        candidates: list["LawChunk"] = []
        for chunk, _ in raw_results + rewritten_results:
            if chunk.chunk_id not in seen_ids:
                seen_ids.add(chunk.chunk_id)
                candidates.append(chunk)

        # Step 3: Rerank
        top_chunks = await self.rerank(query, candidates, top_k=top_k)

        # Step 4: Generate answer (extract chunks from (chunk, score) tuples)
        answer_chunks = [c for c, _ in top_chunks[:top_k]]
        answer = await self.generate_answer(query, answer_chunks)

        return LLMSearchResult(
            rewritten_query=rewritten,
            answer=answer,
            top_chunks=top_chunks,
            raw_kw_results=raw_results,
        )

    # ── Internals ───────────────────────────────────────────────────────────

    async def _call_llm(
        self,
        prompt: str,
        *,
        system: str | None = None,
        temperature: float = 0.1,
    ) -> str:
        """Send a prompt to the LLM and return the response text."""
        if not self._api_key:
            raise RuntimeError(
                "No API key configured. Set HARDLAW_LLM_API_KEY or OPENAI_API_KEY."
            )

        import openai

        messages: list[dict[str, str]] = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        async with self._sem:
            client = openai.AsyncOpenAI(
                api_key=self._api_key,
                base_url=self._base_url,
            )
            response = await client.chat.completions.create(
                model=self._model,
                messages=messages,
                temperature=temperature,
            )
            return response.choices[0].message.content or ""

    async def _rerank_batch(
        self,
        query: str,
        candidates: list["LawChunk"],
        top_k: int,
    ) -> list[tuple["LawChunk", float]]:
        """Score a single batch of candidates and return scored results.

        Raises the original exception if the LLM call or response parsing
        fails — no silent fallback. The caller decides how to handle errors.
        """
        chunks_text = self._format_chunks_for_prompt(candidates)
        prompt = _RERANK_PROMPT.format(query=query, chunks_text=chunks_text)

        response = await self._call_llm(prompt, temperature=0.1)
        scores = self._parse_rerank_response(response, candidates)
        scores.sort(key=lambda x: x[1], reverse=True)
        return scores[:top_k]

    @staticmethod
    def _format_chunks_for_prompt(chunks: list["LawChunk"]) -> str:
        """Format chunks as a numbered list for the LLM prompt."""
        lines = []
        for i, chunk in enumerate(chunks, 1):
            # Truncate text to ~300 chars to stay within prompt limits
            text = chunk.text.strip().replace("\n", " ")
            if len(text) > 300:
                text = text[:300] + "…"
            lines.append(
                f"{i}. [{chunk.chunk_id}] "
                f"《{chunk.law_title}》{chunk.article_num}\n"
                f"   {text}"
            )
        return "\n\n".join(lines)

    @staticmethod
    def _parse_rerank_response(
        response: str,
        candidates: list["LawChunk"],
    ) -> list[tuple["LawChunk", float]]:
        """Parse LLM JSON response into (chunk, score) pairs.

        Handles various LLM output quirks: markdown code fences,
        trailing commas, missing fields.
        """
        # Extract JSON from response (handle markdown code fences)
        json_str = response.strip()
        # Remove ```json / ``` wrappers
        json_str = re.sub(r"^```(?:json)?\s*", "", json_str)
        json_str = re.sub(r"\s*```$", "", json_str)
        # Fix trailing commas before ] or }
        json_str = re.sub(r",\s*([}\]])", r"\1", json_str)

        try:
            raw_scores = json.loads(json_str)
        except json.JSONDecodeError:
            # Try to extract a JSON array from anywhere in the response
            match = re.search(r"\[.*\]", response, re.DOTALL)
            if match:
                try:
                    raw_scores = json.loads(match.group())
                except json.JSONDecodeError:
                    raise ValueError(f"Could not parse rerank response: {response[:200]}")
            else:
                raise ValueError(f"No JSON array found in rerank response: {response[:200]}")

        if not isinstance(raw_scores, list):
            raise ValueError(f"Expected JSON array, got {type(raw_scores)}")

        # Build chunk lookup
        chunk_map = {c.chunk_id: c for c in candidates}

        results: list[tuple["LawChunk", float]] = []
        for item in raw_scores:
            if not isinstance(item, dict):
                continue
            chunk_id = item.get("chunk_id", "")
            score = item.get("score", 0)
            reason = item.get("reason", "")

            chunk = chunk_map.get(chunk_id)
            if chunk is not None and isinstance(score, (int, float)):
                results.append((chunk, float(score)))
                logger.debug("  LLM score: %s → %.1f (%s)", chunk_id, score, reason)

        return results


# ── Convenience ─────────────────────────────────────────────────────────────


def create_ranker(
    data_dir: str | None = None,
    *,
    api_key: str | None = None,
    base_url: str | None = None,
    model: str | None = None,
) -> LLMRanker:
    """Create an LLMRanker with defaults from environment variables.

    Convenience function that wires up LawStore → LLMRanker with
    optional LawIndex for semantic search.
    """
    from hardlaw.legal_knowledge.law_store import LawStore
    from hardlaw.legal_knowledge.law_index import LawIndex

    store = LawStore(data_dir)
    index = LawIndex(store)
    index.ensure_fresh()

    return LLMRanker(
        store,
        index,
        api_key=api_key,
        base_url=base_url,
        model=model,
    )
