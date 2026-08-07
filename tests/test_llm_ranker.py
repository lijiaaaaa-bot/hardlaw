"""Tests for llm_ranker.py — LLM-enhanced search module.

Pure-logic tests (no API key needed):
    - Config/env-var handling
    - Static methods (format_chunks, parse_rerank_response)
    - Error paths (no API key, empty candidates)
    - Dataclass defaults

Integration tests (require API key):
    - Query rewriting, reranking, answer generation, full pipeline
    - Set HARDLAW_LLM_API_KEY to enable.
"""

from __future__ import annotations

import json
import os
import sys
from unittest.mock import MagicMock, AsyncMock

import pytest

# Prevent law_index eager import from crashing when torch is broken.
# This is NOT a fallback — it's test-infra to allow import on CI machines
# that lack torch. The production import path has no such guard.
if "sentence_transformers" not in sys.modules:
    sys.modules["sentence_transformers"] = MagicMock()
if "torch" not in sys.modules:
    sys.modules["torch"] = MagicMock()

from hardlaw.legal_knowledge.law_store import LawChunk  # noqa: E402
from hardlaw.legal_knowledge.llm_ranker import (  # noqa: E402
    LLMRanker,
    LLMSearchResult,
)


# ── Helpers ─────────────────────────────────────────────────────────────────


def _make_chunk(
    chunk_id: str = "劳动法/第3条",
    law_id: str = "劳动法",
    law_title: str = "中华人民共和国劳动法",
    category: str = "社会法",
    article_num: str = "第三条",
    heading: str = "第一章 总则",
    text: str = "劳动者享有平等就业和选择职业的权利、取得劳动报酬的权利、休息休假的权利。",
) -> LawChunk:
    return LawChunk(
        chunk_id=chunk_id,
        law_id=law_id,
        law_title=law_title,
        category=category,
        article_num=article_num,
        heading=heading,
        text=text,
        search_text=f"{heading} {article_num} {text}",
    )


def _make_chunks(count: int = 5, prefix: str = "劳动法") -> list[LawChunk]:
    return [
        _make_chunk(
            chunk_id=f"{prefix}/第{i}条",
            law_id=prefix,
            law_title=f"中华人民共和国{prefix}",
            article_num=f"第{i}条",
            text=f"第{i}条规定的内容文本。",
        )
        for i in range(1, count + 1)
    ]


class MockLawStore:
    """Minimal store stub for tests that don't touch search_keyword."""

    def search_keyword(self, query: str, limit: int = 20):
        chunks = _make_chunks(3)
        return [(c, 0.8) for c in chunks]


def _can_run_llm() -> bool:
    """Integration tests need: API key + openai package installed."""
    has_key = bool(os.getenv("HARDLAW_LLM_API_KEY") or os.getenv("OPENAI_API_KEY"))
    try:
        import openai  # noqa: F401
        return has_key
    except ImportError:
        return False


def _make_ranker(**kwargs) -> LLMRanker:
    key = os.getenv("HARDLAW_LLM_API_KEY") or os.getenv("OPENAI_API_KEY") or "test-key"
    return LLMRanker(MockLawStore(), api_key=key, **kwargs)  # type: ignore[arg-type]


# ── Pure-logic tests (no API calls) ────────────────────────────────────────


class TestLLMRankerInit:
    def test_defaults_from_env(self, monkeypatch):
        monkeypatch.setenv("HARDLAW_LLM_API_KEY", "env-key")
        monkeypatch.setenv("HARDLAW_LLM_BASE_URL", "https://llm.example.com/v1")
        monkeypatch.setenv("HARDLAW_LLM_MODEL", "custom-model")

        r = LLMRanker(MockLawStore())  # type: ignore[arg-type]
        assert r._api_key == "env-key"
        assert r._base_url == "https://llm.example.com/v1"
        assert r._model == "custom-model"

    def test_explicit_overrides_env(self, monkeypatch):
        monkeypatch.setenv("HARDLAW_LLM_API_KEY", "env-key")
        r = LLMRanker(MockLawStore(), api_key="explicit-key")  # type: ignore[arg-type]
        assert r._api_key == "explicit-key"

    def test_openai_api_key_fallback(self, monkeypatch):
        monkeypatch.delenv("HARDLAW_LLM_API_KEY", raising=False)
        monkeypatch.setenv("OPENAI_API_KEY", "openai-key")
        r = LLMRanker(MockLawStore())  # type: ignore[arg-type]
        assert r._api_key == "openai-key"

    def test_no_api_key(self, monkeypatch):
        monkeypatch.delenv("HARDLAW_LLM_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        r = LLMRanker(MockLawStore())  # type: ignore[arg-type]
        assert r._api_key is None


class TestRerankEmpty:
    """rerank() with empty candidates returns immediately — no LLM call."""

    @pytest.mark.asyncio
    async def test_empty_candidates(self):
        r = _make_ranker()
        results = await r.rerank("test", [], top_k=5)
        assert results == []


class TestGenerateAnswer:
    @pytest.mark.asyncio
    async def test_empty_context(self):
        """generate_answer with no chunks returns a guidance message."""
        r = _make_ranker()
        result = await r.generate_answer("test", [])
        assert "未找到" in result
        assert "专业律师" in result


class TestCallLLM:
    @pytest.mark.asyncio
    async def test_no_api_key_raises(self, monkeypatch):
        monkeypatch.delenv("HARDLAW_LLM_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        r = LLMRanker(MockLawStore())  # type: ignore[arg-type]
        with pytest.raises(RuntimeError, match="No API key"):
            await r._call_llm("test")


class TestFormatChunksForPrompt:
    def test_formats_chunks_numbered(self):
        chunks = _make_chunks(3)
        result = LLMRanker._format_chunks_for_prompt(chunks)
        assert "1. [劳动法/第1条]" in result
        assert "2. [劳动法/第2条]" in result
        assert "3. [劳动法/第3条]" in result

    def test_truncates_long_text(self):
        chunk = _make_chunk(text="A" * 500)
        result = LLMRanker._format_chunks_for_prompt([chunk])
        assert "…" in result
        assert len(result.split("\n")[-1].strip()) <= 304


class TestParseRerankResponse:
    def test_parses_valid_json(self):
        candidates = _make_chunks(3)
        response = json.dumps([
            {"chunk_id": "劳动法/第1条", "score": 9, "reason": "好"},
            {"chunk_id": "劳动法/第2条", "score": 5, "reason": "一般"},
        ])
        results = LLMRanker._parse_rerank_response(response, candidates)
        assert len(results) == 2
        assert results[0][1] == 9.0

    def test_strips_markdown_code_fence(self):
        candidates = _make_chunks(3)
        response = '```json\n[{"chunk_id": "劳动法/第1条", "score": 8}]\n```'
        results = LLMRanker._parse_rerank_response(response, candidates)
        assert len(results) == 1
        assert results[0][1] == 8.0

    def test_fixes_trailing_commas(self):
        candidates = _make_chunks(3)
        response = '[{"chunk_id": "劳动法/第1条", "score": 7, "reason": "ok"},]'
        results = LLMRanker._parse_rerank_response(response, candidates)
        assert len(results) == 1

    def test_extracts_json_from_noisy_response(self):
        candidates = _make_chunks(3)
        response = '好的，以下是评分结果：\n[{"chunk_id": "劳动法/第1条", "score": 6}]\n评分完毕。'
        results = LLMRanker._parse_rerank_response(response, candidates)
        assert len(results) == 1

    def test_raises_on_unparseable(self):
        candidates = _make_chunks(3)
        with pytest.raises(ValueError):
            LLMRanker._parse_rerank_response("no json here at all", candidates)


class TestLLMSearchResult:
    def test_defaults(self):
        chunk = _make_chunk()
        result = LLMSearchResult(
            rewritten_query="rewritten",
            answer="answer",
            top_chunks=[(chunk, 9.0)],
        )
        assert result.raw_kw_results == []
        assert result.rewritten_query == "rewritten"
        assert result.answer == "answer"
        assert len(result.top_chunks) == 1

    def test_with_raw_results(self):
        chunk = _make_chunk()
        result = LLMSearchResult(
            rewritten_query="q",
            answer="a",
            top_chunks=[(chunk, 8.0)],
            raw_kw_results=[(chunk, 0.7)],
        )
        assert len(result.raw_kw_results) == 1


# ── Integration tests (require API key) ─────────────────────────────────────

_NEEDS_KEY = pytest.mark.skipif(not _can_run_llm(), reason="HARDLAW_LLM_API_KEY not set or openai not installed")


class TestRewriteQueryIntegration:
    @pytest.mark.asyncio
    @_NEEDS_KEY
    async def test_rewrite_converts_colloquial_to_legal(self):
        """Real LLM: colloquial query → legal terminology."""
        r = _make_ranker()
        result = await r.rewrite_query("老板把我开了还不给钱")
        # Should contain legal terms, not colloquial phrasing
        assert len(result) > 5
        # The rewritten query should NOT be identical to the input
        assert result != "老板把我开了还不给钱"

    @pytest.mark.asyncio
    @_NEEDS_KEY
    async def test_rewrite_handles_employment_dispute(self):
        r = _make_ranker()
        result = await r.rewrite_query("试用期被辞退有赔偿吗")
        assert len(result) > 0
        # Should contain legal terms around termination/compensation
        legal_keywords = ["解除", "合同", "试用", "经济补偿", "赔偿"]
        assert any(kw in result for kw in legal_keywords)


class TestRerankIntegration:
    @pytest.mark.asyncio
    @_NEEDS_KEY
    async def test_rerank_scores_directly_relevant_highest(self):
        """Real LLM: directly relevant chunks score highest."""
        r = _make_ranker()
        chunks = [
            _make_chunk(
                chunk_id="劳动合同法/第47条",
                law_title="中华人民共和国劳动合同法",
                text="经济补偿按劳动者在本单位工作的年限，每满一年支付一个月工资的标准向劳动者支付。",
            ),
            _make_chunk(
                chunk_id="劳动法/第3条",
                law_title="中华人民共和国劳动法",
                text="劳动者享有平等就业和选择职业的权利。",
            ),
            _make_chunk(
                chunk_id="刑法/第232条",
                law_title="中华人民共和国刑法",
                text="故意杀人的，处死刑、无期徒刑或者十年以上有期徒刑。",
            ),
        ]

        results = await r.rerank("被公司裁员能拿多少补偿", chunks, top_k=3)
        assert len(results) >= 1
        # 劳动合同法第47条 is the most directly relevant
        assert results[0][0].chunk_id == "劳动合同法/第47条"

    @pytest.mark.asyncio
    @_NEEDS_KEY
    async def test_rerank_large_batch(self):
        """Real LLM: batches > 15 candidates correctly."""
        r = _make_ranker()
        chunks = []
        for i in range(1, 21):
            chunks.append(_make_chunk(
                chunk_id=f"劳动法/第{i}条",
                law_title="中华人民共和国劳动法",
                text=f"劳动法第{i}条的内容。",
            ))

        results = await r.rerank("加班不给加班费", chunks, top_k=5)
        assert len(results) == 5
        assert all(isinstance(s, float) for _, s in results)


class TestGenerateAnswerIntegration:
    @pytest.mark.asyncio
    @_NEEDS_KEY
    async def test_generates_cited_answer(self):
        """Real LLM: answer includes law citations."""
        r = _make_ranker()
        chunks = [
            _make_chunk(
                chunk_id="劳动合同法/第47条",
                law_title="中华人民共和国劳动合同法",
                text="经济补偿按劳动者在本单位工作的年限，每满一年支付一个月工资的标准向劳动者支付。六个月以上不满一年的，按一年计算；不满六个月的，向劳动者支付半个月工资的经济补偿。",
            ),
        ]

        answer = await r.generate_answer("被裁员怎么算补偿", chunks)
        assert "劳动合同法" in answer
        assert "第47条" in answer
        assert len(answer) > 50


class TestSearchWithLLMIntegration:
    @pytest.mark.asyncio
    @_NEEDS_KEY
    async def test_full_pipeline(self):
        """Real LLM: complete search pipeline returns LLMSearchResult."""
        r = _make_ranker()
        result = await r.search_with_llm("被公司裁员能拿多少补偿", top_k=3, use_semantic=False)

        assert isinstance(result, LLMSearchResult)
        assert len(result.rewritten_query) > 0
        assert len(result.answer) > 0
        assert len(result.top_chunks) >= 1
