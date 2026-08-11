#!/usr/bin/env python3
"""
convert_bge_to_coreml.py — Convert BAAI/bge-small-zh-v1.5 to CoreML for iOS.

Outputs:
  ios/HardlawApp/bge-small-zh-v1.5.mlpackage/  — CoreML model (must be added
      as an explicit resource in project.yml so Xcode compiles it to
      .mlmodelc; folder references do NOT compile CoreML models)
  ios/HardlawApp/LegalKnowledge/vocab.txt      — BERT vocab (folder reference;
      CoreMLEmbeddingProvider finds it next to the laws_* files in
      Bundle.main)
  ios/HardlawApp/LegalKnowledge/tokenizer_config.json

Prerequisites:
  pip install coremltools sentence-transformers torch

Key gotchas handled:
  1. Mean pooling (NOT just CLS token) — traces through the full pooling layer
  2. RangeDim — variable-length input support (1..512 tokens)
  3. vocab.txt — copied directly from HF repo for exact match
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from sentence_transformers import SentenceTransformer

MODEL_ID = "BAAI/bge-small-zh-v1.5"
MAX_SEQ_LEN = 512
OUTPUT_DIM = 512

PROJECT_ROOT = Path(__file__).resolve().parents[1]
# The kit no longer keeps its own LegalKnowledge duplicate — the app bundle
# is the single source of truth. Bundle.main resolves these folders at
# runtime on both device and simulator.
APP_DIR = PROJECT_ROOT / "ios" / "HardlawApp"
COREML_OUTPUT = APP_DIR / "bge-small-zh-v1.5.mlpackage"
TOKENIZER_OUTPUT = APP_DIR / "LegalKnowledge"


def main() -> None:
    print(f"Loading {MODEL_ID} ...")
    st_model = SentenceTransformer(MODEL_ID, device="cpu")

    # ── Extract transformer + pooling modules ──────────────────────────────
    # bge-small-zh-v1.5 architecture:
    #   SentenceTransformer(
    #     (0): Transformer({'max_seq_length': 512, ...})  — BERT encoder
    #     (1): Pooling({'pooling_mode_mean_last_tokens': True, ...})
    #     (2): Normalize()
    #   )
    modules = list(st_model.modules())
    print(f"  Found {len(modules)} modules")

    # Find the transformer module (index 0) and pooling module (index 1)
    transformer = st_model._first_module()
    pooling = None
    for module in st_model.modules():
        class_name = type(module).__name__
        if "Pooling" in class_name:
            pooling = module
            break

    if pooling is None:
        raise RuntimeError(
            "Could not find Pooling module. Expected bge-small-zh-v1.5 "
            "to have a Pooling layer."
        )

    # ── Trace through pooling (critical: mean pooling, NOT CLS) ────────────
    class EmbeddingWrapper(nn.Module):
        """Wrapper that runs transformer → mean pooling → sentence embedding.

        This is critical: bge-small-zh-v1.5 uses mean pooling over ALL token
        embeddings (weighted by attention mask), NOT just the [CLS] token.
        Using last_hidden_state[:, 0, :] would produce WRONG embeddings.
        """

        def __init__(self, transformer, pooling):
            super().__init__()
            self.transformer = transformer
            self.pooling = pooling

        def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor):
            # Run BERT transformer
            output = self.transformer.forward({
                "input_ids": input_ids,
                "attention_mask": attention_mask,
            })

            # Apply mean pooling with attention mask
            # This averages all non-padding token embeddings
            features = self.pooling.forward({
                "token_embeddings": output["token_embeddings"],
                "attention_mask": attention_mask,
            })

            # Return the sentence embedding (after pooling, before normalize)
            return features["sentence_embedding"]

    wrapped = EmbeddingWrapper(transformer, pooling)
    wrapped.eval()

    # Trace with variable-length dummy input
    # Use length=8 to demonstrate RangeDim works; model pads to MAX_SEQ_LEN
    dummy_ids = torch.zeros((1, MAX_SEQ_LEN), dtype=torch.long)
    dummy_mask = torch.zeros((1, MAX_SEQ_LEN), dtype=torch.long)
    # Set first 8 tokens as "real"
    dummy_ids[0, :8] = 101  # [CLS]
    dummy_mask[0, :8] = 1

    print("  Tracing model ...")
    traced = torch.jit.trace(wrapped, (dummy_ids, dummy_mask))

    # Verify output shape
    with torch.no_grad():
        test_out = traced(dummy_ids, dummy_mask)
    print(f"  Traced output shape: {test_out.shape} (expected [1, {OUTPUT_DIM}])")
    assert test_out.shape == (1, OUTPUT_DIM), f"Unexpected output shape: {test_out.shape}"

    # ── Convert to CoreML ───────────────────────────────────────────────────
    print("  Converting to CoreML ...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="input_ids",
                shape=(1, ct.RangeDim(1, MAX_SEQ_LEN)),
                dtype=np.int32,
            ),
            ct.TensorType(
                name="attention_mask",
                shape=(1, ct.RangeDim(1, MAX_SEQ_LEN)),
                dtype=np.int32,
            ),
        ],
        outputs=[
            ct.TensorType(name="sentence_embedding", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",  # Modern CoreML format with better ANE support
    )

    # Add metadata
    mlmodel.short_description = (
        "BGE-small-zh-v1.5 — Chinese sentence embedding model for legal text search. "
        "512-dim output. Mean pooling over BERT token embeddings."
    )
    mlmodel.version = "1.5"
    mlmodel.author = "BAAI (Beijing Academy of Artificial Intelligence)"
    mlmodel.license = "MIT"

    # Save CoreML model
    COREML_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if COREML_OUTPUT.exists():
        shutil.rmtree(COREML_OUTPUT)
    mlmodel.save(str(COREML_OUTPUT))
    print(f"  Saved: {COREML_OUTPUT}")

    # ── Copy tokenizer files ────────────────────────────────────────────────
    TOKENIZER_OUTPUT.mkdir(parents=True, exist_ok=True)

    # Get the tokenizer path from the sentence-transformers model
    model_dir = Path(st_model._model_card_vars.get("__path__", ""))
    if not model_dir:
        # Fall back to HF cache
        from transformers import AutoTokenizer
        tok = AutoTokenizer.from_pretrained(MODEL_ID)
        model_dir = Path(tok.name_or_path)
        if not model_dir.exists():
            # Resolve from HF cache
            import huggingface_hub
            model_dir = Path(huggingface_hub.snapshot_download(MODEL_ID))

    # vocab.txt — must match training vocabulary EXACTLY
    vocab_src = model_dir / "vocab.txt"
    if vocab_src.exists():
        shutil.copy2(vocab_src, TOKENIZER_OUTPUT / "vocab.txt")
        print(f"  Copied: vocab.txt ({vocab_src.stat().st_size} bytes)")
    else:
        raise RuntimeError(f"vocab.txt not found at {vocab_src}")

    # tokenizer_config.json
    config_src = model_dir / "tokenizer_config.json"
    if config_src.exists():
        # Read and validate it's a BERT/WordPiece tokenizer
        config = json.loads(config_src.read_text(encoding="utf-8"))
        if config.get("tokenizer_class") != "BertTokenizer":
            print(f"  WARNING: tokenizer_class={config.get('tokenizer_class')}, expected BertTokenizer")
        shutil.copy2(config_src, TOKENIZER_OUTPUT / "tokenizer_config.json")
        print(f"  Copied: tokenizer_config.json ({config_src.stat().st_size} bytes)")
    else:
        # Some HF repos have tokenizer.json instead; that works too
        tokenizer_json = model_dir / "tokenizer.json"
        if tokenizer_json.exists():
            shutil.copy2(tokenizer_json, TOKENIZER_OUTPUT / "tokenizer.json")
            print(f"  Copied: tokenizer.json ({tokenizer_json.stat().st_size} bytes)")
        else:
            raise RuntimeError(f"No tokenizer config found at {model_dir}")

    print(f"\nDone! CoreML model saved to {COREML_OUTPUT}")
    print(f"Tokenizer files saved to {TOKENIZER_OUTPUT}/")


if __name__ == "__main__":
    main()
