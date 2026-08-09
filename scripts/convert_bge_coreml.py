#!/usr/bin/env python3
"""将 BGE-small-zh-v1.5 转为 CoreML 格式，在 iPhone ANE 上跑语义搜索。
运行: python3 scripts/convert_bge_coreml.py
"""
import coremltools as ct
from transformers import AutoTokenizer, AutoModel
import torch, os

model_name = "BAAI/bge-small-zh-v1.5"
out_dir = "ios/HardlawKit/Vision/CoreMLModels"

print(f"下载 {model_name}...")
tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModel.from_pretrained(model_name)
model.eval()

class BGEWrapper(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, input_ids, attention_mask):
        out = self.m(input_ids=input_ids, attention_mask=attention_mask)
        cls = out.last_hidden_state[:, 0, :]
        return cls / cls.norm(dim=1, keepdim=True)

traced = torch.jit.trace(BGEWrapper(model),
    (torch.randint(0, 1000, (1, 512)), torch.ones(1, 512, dtype=torch.long)))

os.makedirs(out_dir, exist_ok=True)
mlmodel = ct.convert(traced,
    inputs=[ct.TensorType(shape=(1, 512), name="input_ids"),
            ct.TensorType(shape=(1, 512), name="attention_mask")],
    outputs=[ct.TensorType(name="sentence_embedding")],
    minimum_deployment_target=ct.target.iOS17)
path = os.path.join(out_dir, "BGE-small-zh.mlpackage")
mlmodel.save(path)

# 同时保存 vocab.txt
tokenizer.save_pretrained(out_dir)
vocab_path = os.path.join(out_dir, "vocab.txt")
print(f"✅ CoreML 模型: {path}")
print(f"✅ 词表: {vocab_path}")
