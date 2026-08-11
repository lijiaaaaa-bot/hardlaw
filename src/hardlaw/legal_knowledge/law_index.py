"""
law_index.py — FAISS semantic search index for legal documents.

Follows intent-lab's vector_index.py pattern exactly:
- Lazy-loaded embedding model (paraphrase-multilingual-MiniLM-L12-v2)
- FAISS IndexFlatIP for cosine similarity via normalized vectors
- File-based persistence (saved alongside law data)
- RRF (Reciprocal Rank Fusion) for hybrid keyword + semantic search

Usage::

    from hardlaw.legal_knowledge import LawStore, LawIndex

    store = LawStore()
    index = LawIndex(store)

    # Build or load index
    index.ensure_fresh()

    # Hybrid search
    results = index.search("劳动合同解除需要什么条件", k=10)
    for chunk, score in results:
        print(f"[{chunk.law_title}] {chunk.article_num}: {chunk.text[:100]}")
"""

from __future__ import annotations

import json
import logging
import os
import threading
from pathlib import Path
from typing import Any

import numpy as np

from hardlaw.legal_knowledge.law_store import LawChunk, LawStore

logger = logging.getLogger(__name__)

# ── Embedding Model (singleton, lazy-loaded) ────────────────────────────

_MODEL_NAME = "BAAI/bge-small-zh-v1.5"
_MODEL: Any = None
_MODEL_LOCK = threading.Lock()


def _get_model() -> Any:
    """Return the cached sentence-transformers model.

    Tries the official HuggingFace endpoint first; falls back to
    HF_ENDPOINT env var. Uses INTENT_LAB_EMBEDDING_MODEL if set
    (shared with intent-lab for consistency).
    """
    global _MODEL
    if _MODEL is not None:
        return _MODEL
    with _MODEL_LOCK:
        if _MODEL is not None:
            return _MODEL

        override = os.environ.get("INTENT_LAB_EMBEDDING_MODEL", "").strip()
        model_name = override or _MODEL_NAME
        local_only = os.environ.get("HF_HUB_OFFLINE", "0") == "1"

        from sentence_transformers import SentenceTransformer

        load_kwargs: dict[str, Any] = {"device": "cpu"}
        if local_only:
            load_kwargs["local_files_only"] = True

        # On Apple Silicon, CPU with AMX is ~2x faster than MPS for
        # small embedding models (overhead outweighs GPU acceleration).
        _MODEL = SentenceTransformer(model_name, **load_kwargs)
        logger.info("Loaded embedding model: %s (device=cpu)", model_name)
        return _MODEL


def _prewarm_model() -> None:
    """Eagerly load the embedding model to avoid segfaults.

    Must be called BEFORE any jieba tokenization happens, otherwise
    a C-extension conflict between jieba and PyTorch can cause a
    segmentation fault on macOS.
    """
    _get_model()


def _embed(texts: list[str]) -> np.ndarray:
    """Encode a batch of texts into normalized 512-dim vectors."""
    if not texts:
        return np.empty((0, 512), dtype=np.float32)
    model = _get_model()
    embeddings: np.ndarray = model.encode(
        texts,
        batch_size=128,
        show_progress_bar=False,
        normalize_embeddings=True,
    )
    return embeddings.astype(np.float32)


# ── LawIndex ─────────────────────────────────────────────────────────────


class LawIndex:
    """FAISS-backed semantic search index for legal documents.

    Stores a FAISS IndexFlatIP (inner product → cosine similarity with
    L2-normalized vectors) over LawChunk.search_text. Follows the same
    pattern as intent-lab's VectorIndex: file-based persistence, lazy
    rebuild, RRF hybrid search.

    Parameters
    ----------
    law_store:
        The LawStore instance providing chunks to index.
    index_dir:
        Directory to persist the FAISS index. Defaults to
        data/law_index/ alongside the law data.
    """

    def __init__(
        self,
        law_store: LawStore,
        index_dir: str | Path | None = None,
    ) -> None:
        self._store = law_store
        if index_dir is None:
            index_dir = Path(__file__).resolve().parents[3] / "data" / "law_index"
        self._index_dir = Path(index_dir)
        self._index_dir.mkdir(parents=True, exist_ok=True)

        self._index_path = self._index_dir / "laws.faiss"
        self._ids_path = self._index_dir / "laws.ids.json"

        self._index: Any = None  # faiss.IndexFlatIP
        self._chunk_ids: list[str] = []
        self._generation: int = 0
        self._stale: bool = True

    # ── Public API ──────────────────────────────────────────────────────

    @property
    def generation(self) -> int:
        return self._generation

    @property
    def size(self) -> int:
        return len(self._chunk_ids)

    def mark_stale(self) -> None:
        """Mark the index as needing a rebuild before the next search."""
        self._stale = True

    def ensure_fresh(self) -> None:
        """Rebuild the index if stale or empty.

        Loads from disk if a fresh index exists; otherwise builds from
        the LawStore chunks and persists to disk.
        """
        if not self._stale and self._index is not None and len(self._chunk_ids) > 0:
            return

        if self._load():
            self._stale = False
            return

        self._rebuild()
        self._stale = False

    def search(
        self,
        query: str,
        k: int = 10,
    ) -> list[tuple[LawChunk, float]]:
        """Hybrid search returning top-k (chunk, score) results.

        Uses RRF to merge keyword results from LawStore with semantic
        results from FAISS. Falls back to keyword-only if FAISS is
        unavailable.

        Parameters
        ----------
        query:
            Natural language query in Chinese or English.
        k:
            Number of results to return.

        Returns
        -------
        List of (LawChunk, similarity_score) pairs sorted by relevance.
        """
        if not query.strip():
            return []

        self.ensure_fresh()

        # Build a chunk lookup map
        chunk_map = {c.chunk_id: c for c in self._store.all_chunks()}

        # Keyword results
        kw_results = self._store.search_keyword(query, limit=k * 3)
        kw_ranked = [(r[0].chunk_id, float(idx)) for idx, r in enumerate(kw_results)]

        # Semantic results
        try:
            sem_ranked = self._semantic_search(query, k=k * 3)
        except Exception:
            logger.exception("Semantic search failed, falling back to keyword-only")
            # Return keyword results directly
            return [(r[0], 1.0 / (idx + 1)) for idx, r in enumerate(kw_results[:k])]

        if not sem_ranked:
            return [(r[0], 1.0 / (idx + 1)) for idx, r in enumerate(kw_results[:k])]

        # RRF merge — keyword weighted more heavily (k=10, higher RRF
        # contribution) than semantic (k=60, lower contribution). The
        # multilingual MiniLM embedding model has mediocre Chinese
        # performance; keyword search is more reliable for legal text.
        # Semantic results only influence ranking when they're extremely
        # confident (top-3 positions).
        merged = _rrf_merge(
            [kw_ranked, sem_ranked],
            k_values=[10, 60],
            limit=k,
        )

        # Resolve IDs to chunks
        results: list[tuple[LawChunk, float]] = []
        for chunk_id, score in merged:
            chunk = chunk_map.get(chunk_id)
            if chunk is not None:
                results.append((chunk, score))

        return results

    # ── Internals ───────────────────────────────────────────────────────

    def _semantic_search(
        self, query: str, k: int = 30
    ) -> list[tuple[str, float]]:
        """Run FAISS semantic search. Returns (chunk_id, similarity) pairs."""
        if self._index is None or not self._chunk_ids:
            return []

        vec = _embed([query.strip()])
        k_effective = min(k, len(self._chunk_ids))
        if k_effective == 0:
            return []

        scores, indices = self._index.search(vec, k_effective)
        results: list[tuple[str, float]] = []
        for score, idx in zip(scores[0], indices[0]):
            if idx < 0 or idx >= len(self._chunk_ids):
                continue
            results.append((self._chunk_ids[idx], float(score)))
        return results

    def _rebuild(self) -> None:
        """Build a fresh FAISS index from all chunks in the LawStore."""
        chunks = self._store.all_chunks()
        if not chunks:
            self._index = None
            self._chunk_ids = []
            self._generation = 0
            return

        texts = [c.search_text for c in chunks]
        ids = [c.chunk_id for c in chunks]

        embeddings = _embed(texts)

        import faiss

        dim = embeddings.shape[1]
        index = faiss.IndexFlatIP(dim)
        index.add(embeddings)

        self._index = index
        self._chunk_ids = ids
        self._generation += 1

        # Persist
        faiss.write_index(index, str(self._index_path))
        self._ids_path.write_text(
            json.dumps(self._chunk_ids, ensure_ascii=False),
            encoding="utf-8",
        )

        logger.info(
            "Built law FAISS index: %d vectors (dim=%d), generation %d",
            len(ids), dim, self._generation,
        )

    def _load(self) -> bool:
        """Load a previously-saved index from disk. Returns True on success."""
        if not self._index_path.exists():
            return False
        try:
            import faiss

            self._index = faiss.read_index(str(self._index_path))
            if self._ids_path.exists():
                self._chunk_ids = json.loads(
                    self._ids_path.read_text(encoding="utf-8")
                )
            logger.info(
                "Loaded law FAISS index (%d vectors) from %s",
                self._index.ntotal, self._index_path,
            )
            return True
        except Exception:
            logger.exception("Failed to load law FAISS index")
            self._index = None
            self._chunk_ids = []
            return False


# ── RRF (Reciprocal Rank Fusion) ─────────────────────────────────────────


def _rrf_merge(
    ranked_lists: list[list[tuple[str, float]]],
    k_values: list[int] | None = None,
    *,
    limit: int = 20,
) -> list[tuple[str, float]]:
    """Combine multiple ranked result lists with Reciprocal Rank Fusion.

    Parameters
    ----------
    ranked_lists:
        One list per ranker. Each list is [(id, score), …] in rank order.
    k_values:
        RRF *k* constant per ranker (default 60 for each).
    limit:
        Maximum results to return.

    Returns
    -------
    Merged list of (id, fused_score) sorted descending.
    """
    if not ranked_lists:
        return []

    if k_values is None:
        k_values = [60] * len(ranked_lists)

    scores: dict[str, float] = {}
    for ranker_idx, (results, k) in enumerate(zip(ranked_lists, k_values)):
        for rank, (rid, _score) in enumerate(results):
            rrf = 1.0 / (k + rank + 1)
            if rid not in scores or rrf > scores[rid]:
                scores[rid] = rrf

    merged = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    return merged[:limit]


# ── Eager Initialization ──────────────────────────────────────────────

# Preload the embedding model at import time to avoid a C-extension
# conflict between jieba (loaded by law_store) and PyTorch (loaded by
# sentence-transformers). If jieba loads first, subsequent PyTorch
# operations may segfault on macOS.
_prewarm_model()
