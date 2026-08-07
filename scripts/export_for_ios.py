#!/usr/bin/env python3
"""
export_for_ios.py — Export legal knowledge data for iOS HardlawKit.

Reads the LawStore + FAISS index, then writes:
  1. laws_chunks.json  — All chunk metadata (titles, article numbers, text)
  2. laws_vectors.bin  — Pre-computed embedding vectors (float32, row-major)
  3. laws_vocab.json   — IDF vocabulary for keyword search scoring

The iOS app bundles these files and uses them for offline hybrid search
without any Python or FAISS dependency.
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

import numpy as np

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from hardlaw.legal_knowledge import LawStore, LawIndex


def export_chunks(store: LawStore, out_dir: Path) -> int:
    """Write chunk metadata as JSON."""
    chunks = []
    for c in store.all_chunks():
        chunks.append({
            "id": c.chunk_id,
            "law_id": c.law_id,
            "law_title": c.law_title,
            "category": c.category,
            "article_num": c.article_num,
            "heading": c.heading,
            "text": c.text,
        })

    path = out_dir / "laws_chunks.json"
    path.write_text(
        json.dumps(chunks, ensure_ascii=False, indent=None),
        encoding="utf-8",
    )
    print(f"  laws_chunks.json: {len(chunks)} chunks ({path.stat().st_size / 1024:.0f} KB)")
    return len(chunks)


def export_vectors(index: LawIndex, store: LawStore, out_dir: Path) -> tuple[int, int]:
    """Write FAISS vectors as raw float32 binary.

    Format: N rows × D cols, float32 little-endian, row-major.
    Also writes the ID mapping.
    """
    import faiss

    index.ensure_fresh()

    faiss_index = index._index  # faiss.IndexFlatIP
    if faiss_index is None:
        print("  WARNING: No FAISS index loaded, skipping vectors")
        return 0, 0

    n = faiss_index.ntotal
    d = faiss_index.d

    # Extract all vectors from FAISS
    vectors = np.zeros((n, d), dtype=np.float32)
    faiss_index.reconstruct_n(0, n, vectors)

    # Write binary
    bin_path = out_dir / "laws_vectors.bin"
    with open(bin_path, "wb") as f:
        # Header: n_vectors (uint32), dim (uint32)
        f.write(struct.pack("<II", n, d))
        # Vectors: float32 array, row-major
        f.write(vectors.tobytes())

    size_kb = bin_path.stat().st_size / 1024
    print(f"  laws_vectors.bin: {n}×{d} float32 ({size_kb:.0f} KB)")

    # Write ID mapping
    ids_path = out_dir / "laws_ids.json"
    ids_path.write_text(
        json.dumps(index._chunk_ids, ensure_ascii=False),
        encoding="utf-8",
    )

    return n, d


def export_vocab(store: LawStore, out_dir: Path) -> int:
    """Pre-compute IDF vocabulary for keyword search.

    The iOS app uses this to score keyword matches without
    needing to tokenize all chunks at runtime (IDF weights
    are pre-computed from the full corpus).
    """
    from hardlaw.legal_knowledge.law_store import _tokenize, _get_tokens, _clear_token_cache
    _clear_token_cache()

    chunks = store.all_chunks()
    n_docs = len(chunks)

    # Collect all unique tokens and their document frequencies
    doc_freq: dict[str, int] = {}
    for i, chunk in enumerate(chunks):
        tokens = set(_get_tokens(chunk))
        for t in tokens:
            doc_freq[t] = doc_freq.get(t, 0) + 1
        if (i + 1) % 2000 == 0:
            print(f"    scanning tokens: {i+1}/{n_docs}...", flush=True)

    # Compute IDF: log((N - df + 0.5) / (df + 0.5))
    vocab: dict[str, dict[str, float]] = {}
    for token, df in doc_freq.items():
        idf = max(0.1, (n_docs - df + 0.5) / (df + 0.5))
        vocab[token] = {"df": df, "idf": idf}

    path = out_dir / "laws_vocab.json"
    path.write_text(
        json.dumps(vocab, ensure_ascii=False, indent=None),
        encoding="utf-8",
    )
    print(f"  laws_vocab.json: {len(vocab)} tokens ({path.stat().st_size / 1024:.0f} KB)")
    return len(vocab)


def main() -> None:
    out_dir = Path(__file__).resolve().parents[1] / "ios" / "HardlawKit" / "Resources" / "LegalKnowledge"
    out_dir.mkdir(parents=True, exist_ok=True)

    print("Loading LawStore...")
    store = LawStore()
    print(f"  {store.law_count} laws, {store.chunk_count} chunks")

    print("\nLoading LawIndex...")
    index = LawIndex(store)
    index.ensure_fresh()
    print(f"  {index.size} vectors")

    print("\nExporting chunks...")
    export_chunks(store, out_dir)

    print("\nExporting vectors...")
    export_vectors(index, store, out_dir)

    print("\nBuilding vocabulary...")
    export_vocab(store, out_dir)

    print(f"\nDone! Files in {out_dir}/")


if __name__ == "__main__":
    main()
