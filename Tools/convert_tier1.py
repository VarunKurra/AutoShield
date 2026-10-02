#!/usr/bin/env python3
"""Converts the fine-tuned Tier 1 transformer to Core ML.

Reads   build/tier1-transformer/        (from Tools/finetune_tier1.py)
Writes  build/ShieldTier1T.mlmodelc     compiled model the app loads
        build/ShieldTier1T.vocab.txt    WordPiece vocabulary
        build/tier1-parity.json         token ids and scores the Swift side
                                        is checked against

The model takes input_ids and attention_mask (1 x 64, int32) and returns the
probability that the text attacks someone. Weights are quantised to 8 bits:
a quarter of the float32 size, with scores checked against PyTorch below.
"""
import json, os, shutil, sys

import numpy as np
import torch
import coremltools as ct
import coremltools.optimize.coreml as cto
from transformers import AutoModelForSequenceClassification, AutoTokenizer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC = os.path.join(ROOT, "build", "tier1-transformer")
BUILD = os.path.join(ROOT, "build")
LEN = 64


class Harm(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_ids, attention_mask):
        logits = self.m(input_ids=input_ids, attention_mask=attention_mask)[0]
        return torch.softmax(logits, dim=-1)[:, 1:2]


def main():
    tok = AutoTokenizer.from_pretrained(SRC)
    model = AutoModelForSequenceClassification.from_pretrained(SRC, torchscript=True).eval()
    wrapped = Harm(model).eval()

    ex = tok("example", padding="max_length", max_length=LEN, truncation=True, return_tensors="pt")
    ids, mask = ex["input_ids"].int(), ex["attention_mask"].int()
    traced = torch.jit.trace(wrapped, (ids, mask))

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, LEN), dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=(1, LEN), dtype=np.int32)],
        outputs=[ct.TensorType(name="harm")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric"))
    mlmodel = cto.linear_quantize_weights(mlmodel, config)
    mlmodel.short_description = "AutoShield Tier 1: probability a message attacks someone"

    pkg = os.path.join(BUILD, "ShieldTier1T.mlpackage")
    shutil.rmtree(pkg, ignore_errors=True)
    mlmodel.save(pkg)

    # Compile once here, so the app ships a ready .mlmodelc.
    # The compiled copy lives only as long as the MLModel that made it.
    holder = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
    compiled = holder.get_compiled_model_path()
    dest = os.path.join(BUILD, "ShieldTier1T.mlmodelc")
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(compiled, dest)
    del holder

    shutil.copy(os.path.join(SRC, "vocab.txt"), os.path.join(BUILD, "ShieldTier1T.vocab.txt"))

    # Parity: tokens and scores the Swift side must reproduce.
    probes = [
        "you're a complete waste of oxygen", "I'm so proud of you!!", "Héllo, wörld — naïve café",
        "k.y.s you p4th3t1c l0ser", "ur mom is a hoe 💀💀", "can you send me the notes?",
        "This is unbelievably, ridiculously, absurdly long " * 6, "中文 mixed text", "don't", "",
    ]
    loaded = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.CPU_AND_NE)
    rows, worst = [], 0.0
    for p in probes:
        enc = tok(p, padding="max_length", max_length=LEN, truncation=True, return_tensors="np")
        i32, m32 = enc["input_ids"].astype(np.int32), enc["attention_mask"].astype(np.int32)
        with torch.no_grad():
            ref = float(wrapped(torch.from_numpy(i32), torch.from_numpy(m32))[0, 0])
        got = float(loaded.predict({"input_ids": i32, "attention_mask": m32})["harm"].reshape(-1)[0])
        worst = max(worst, abs(ref - got))
        rows.append({"text": p, "ids": i32[0].tolist(), "torch": ref, "coreml": got})
        print(f"  torch {ref:.3f}  coreml {got:.3f}  {p[:50]}")
    json.dump(rows, open(os.path.join(BUILD, "tier1-parity.json"), "w"), ensure_ascii=False)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(dest) for f in fs) / 1e6
    print(f"largest torch/coreml difference {worst:.4f}; compiled model {size:.0f} MB -> {dest}")
    if worst > 0.05:
        sys.exit("Core ML output drifted from PyTorch; refusing to ship it")


if __name__ == "__main__":
    main()
