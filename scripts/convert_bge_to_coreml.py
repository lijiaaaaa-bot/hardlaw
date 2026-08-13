"""Convert BAAI/bge-small-zh-v1.5 to CoreML for iOS embedding.

Usage:
    python3 scripts/convert_bge_to_coreml.py

Outputs:
    ios/HardlawApp/bge-small-zh-v1.5.mlpackage   (Xcode compiles to .mlmodelc at build time)
    ios/HardlawApp/LegalKnowledge/vocab.txt      (BERT vocab read by CoreMLEmbeddingProvider)

See docs/embedding-provider-plan.md for the full plan and design rationale.
"""
from pathlib import Path

import coremltools as ct
import torch
import torch.nn as nn
from sentence_transformers import SentenceTransformer

MODEL_ID = "BAAI/bge-small-zh-v1.5"
ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = ROOT / "ios" / "HardlawApp" / "bge-small-zh-v1.5.mlpackage"
VOCAB_TARGET = ROOT / "ios" / "HardlawApp" / "LegalKnowledge" / "vocab.txt"
MAX_SEQ_LEN = 512


class EmbeddingWrapper(nn.Module):
    """Transformer + mean pooling + L2 normalize → sentence_embedding."""

    def __init__(self, transformer, pooling, normalize):
        super().__init__()
        self.transformer = transformer
        self.pooling = pooling
        self.normalize = normalize

    def forward(self, input_ids, attention_mask):
        outputs = self.transformer.forward({
            "input_ids": input_ids,
            "attention_mask": attention_mask,
        })
        features = self.pooling.forward({
            "token_embeddings": outputs["token_embeddings"],
            "attention_mask": attention_mask,
        })
        if self.normalize is not None:
            features = self.normalize.forward(features)
        return features["sentence_embedding"]


def verify_model() -> None:
    """Load the converted model and predict a real embedding; assert 512-dim."""
    import numpy as np

    from coremltools.models import MLModel

    loaded = MLModel(str(OUTPUT_PATH))
    pred = loaded.predict({
        "input_ids": np.zeros((1, MAX_SEQ_LEN), dtype=np.int32),
        "attention_mask": np.zeros((1, MAX_SEQ_LEN), dtype=np.float32),
    })
    emb = np.asarray(pred["sentence_embedding"])
    print(f"[convert] predicted embedding shape: {emb.shape}")
    assert emb.shape[-1] == 512, "expected 512-dim output"
    print("[convert] OK — model output is 512-dimensional")


def main() -> None:
    # Force CPU: torch 2.0.x on macOS defaults to MPS, which breaks
    # torch.jit.trace for this model ("Placeholder storage has not been
    # allocated on MPS device").
    torch.set_default_device("cpu")

    # Idempotent: if both artifacts already exist, verify only.
    if OUTPUT_PATH.exists() and VOCAB_TARGET.exists():
        print("[convert] outputs already exist — verifying")
        verify_model()
        return

    print(f"[convert] loading {MODEL_ID} (first run downloads ~130MB)...")
    st_model = SentenceTransformer(MODEL_ID, device="cpu")

    # bge-small-zh-v1.5 = BERT encoder + mean pooling + L2 normalize.
    # Module order: [0] Transformer, [1] Pooling, [2] Normalize.
    transformer = st_model[0]  # Transformer module
    pooling = st_model[1]      # Pooling module (mean pooling with attention mask)
    normalize = st_model[2] if len(st_model) > 2 else None  # L2 normalize (BGE)

    wrapped = EmbeddingWrapper(transformer, pooling, normalize)
    wrapped.eval()

    dummy_ids = torch.zeros((1, MAX_SEQ_LEN), dtype=torch.long)
    dummy_mask = torch.zeros((1, MAX_SEQ_LEN), dtype=torch.long)
    traced = torch.jit.trace(wrapped, (dummy_ids, dummy_mask))

    print("[convert] converting to CoreML (FLOAT16, iOS17 target)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, ct.RangeDim(1, MAX_SEQ_LEN))),
            ct.TensorType(name="attention_mask", shape=(1, ct.RangeDim(1, MAX_SEQ_LEN))),
        ],
        outputs=[
            ct.TensorType(name="sentence_embedding"),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "BGE-small-zh-v1.5 embedding model for Chinese legal text"
    mlmodel.version = "1.5"
    mlmodel.save(OUTPUT_PATH)
    print(f"[convert] saved {OUTPUT_PATH}")

    # Export the BERT vocab next to the other LegalKnowledge resources.
    # Swift CoreMLEmbeddingProvider maps line index → token id, so lines must
    # be written in strictly ascending id order (no blank lines).
    vocab = st_model.tokenizer.get_vocab()  # {token: id}
    if vocab:
        VOCAB_TARGET.parent.mkdir(parents=True, exist_ok=True)
        with open(VOCAB_TARGET, "w", encoding="utf-8") as f:
            for token, _ in sorted(vocab.items(), key=lambda kv: kv[1]):
                f.write(token + "\n")
        print(f"[convert] wrote vocab ({len(vocab)} entries) -> {VOCAB_TARGET}")
    else:
        raise SystemExit("[convert] tokenizer has no vocabulary")

    verify_model()


if __name__ == "__main__":
    main()
