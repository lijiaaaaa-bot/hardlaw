"""
legal_knowledge — 本地法律知识图谱

A standalone module for storing and searching Chinese legal statutes,
judicial interpretations, and related documents entirely on-device.

Design follows intent-lab's file-based approach:
- Markdown files as source of truth (data/laws/)
- FAISS IndexFlatIP for semantic search
- RRF (Reciprocal Rank Fusion) for keyword + semantic hybrid retrieval
- No SQLite dependency for knowledge storage

Usage::

    from hardlaw.legal_knowledge import LawStore, LawIndex

    store = LawStore()
    index = LawIndex(store)

    # Semantic search
    results = index.search("劳动合同解除条件", k=10)

    # Get full law text
    law = store.get("劳动法")

    # Get specific article
    article = store.get_article("民法典", 464)

    # LLM-enhanced search (requires openai package + API key)
    from hardlaw.legal_knowledge import LLMRanker

    ranker = LLMRanker(store, index)
    result = await ranker.search_with_llm("老板把我开了还不给钱")
    print(result.answer)
"""

from hardlaw.legal_knowledge.law_store import LawStore, LawDocument, LawChunk
from hardlaw.legal_knowledge.law_index import LawIndex
from hardlaw.legal_knowledge.llm_ranker import LLMRanker, LLMSearchResult, create_ranker

__all__ = [
    "LawStore",
    "LawDocument",
    "LawChunk",
    "LawIndex",
    "LLMRanker",
    "LLMSearchResult",
    "create_ranker",
]
