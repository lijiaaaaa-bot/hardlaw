#!/usr/bin/env python3
"""eval_llm_ranker.py — Evaluate LLM-enhanced search vs baseline.

Loads the full law store, runs test queries through both:
1. Baseline keyword + semantic (LawIndex.search)
2. LLM-enhanced pipeline (LLMRanker.search_with_llm) — if API key available

Outputs a comparison table with top-1 accuracy, top-3 recall, and notes.

Usage::

    # Dry-run (baseline only, no LLM):
    python scripts/eval_llm_ranker.py

    # With real LLM (requires API key):
    HARDLAW_LLM_API_KEY=sk-xxx python scripts/eval_llm_ranker.py --llm

    # With custom base URL / model:
    python scripts/eval_llm_ranker.py --llm \\
        --base-url https://api.example.com/v1 \\
        --model custom-model
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Ensure the package is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))


# ── Test Queries ────────────────────────────────────────────────────────────
# Format: (colloquial_query, expected_law_title, legal_terms, category)

@dataclass
class TestQuery:
    query: str
    expected_law: str  # law title keyword to check in top results
    description: str


TEST_QUERIES: list[TestQuery] = [
    TestQuery("老板把我开了还不给钱", "劳动合同法", "违法解除劳动合同支付工资"),
    TestQuery("在工地干活摔伤了怎么办", "工伤保险条例", "工伤认定工伤待遇"),
    TestQuery("试用期被辞退有赔偿吗", "劳动合同法", "试用期解除劳动合同经济补偿金"),
    TestQuery("加班不给加班费合法吗", "劳动法", "加班工资支付标准"),
    TestQuery("公司不给交社保怎么维权", "社会保险法", "用人单位缴纳社会保险费"),
    TestQuery("农民工工资被拖欠找谁要", "保障农民工工资支付条例", "拖欠农民工工资"),
    TestQuery("被公司裁员能拿多少补偿", "劳动合同法", "经济补偿金计算标准"),
    TestQuery("产假期间工资怎么发", "劳动法", "女职工产假待遇"),
    TestQuery("上下班路上受伤算工伤吗", "工伤保险条例", "上下班途中事故工伤认定"),
    TestQuery("公司单方面降薪可以拒绝吗", "劳动合同法", "变更劳动合同"),
    TestQuery("病假工资怎么算", "劳动法", "病假工资医疗期"),
    TestQuery("签了竞业限制不给补偿怎么办", "劳动合同法", "竞业限制经济补偿"),
    TestQuery("工伤认定需要什么材料", "工伤保险条例", "工伤认定申请材料"),
    TestQuery("没签劳动合同怎么证明劳动关系", "劳动合同法", "事实劳动关系认定"),
    TestQuery("退休后能领多少养老金", "社会保险法", "基本养老保险待遇计算"),
]


# ── Evaluation Logic ────────────────────────────────────────────────────────


def check_top1(law_title: str, expected: str) -> bool:
    """Check if the expected law name appears in the result title."""
    return expected.lower() in law_title.lower()


def check_in_top_n(
    results: list[tuple[Any, float]], expected: str, n: int = 3
) -> bool:
    """Check if the expected law appears in the top-N results."""
    for chunk, _ in results[:n]:
        if expected.lower() in chunk.law_title.lower():
            return True
    return False


def evaluate_baseline(store: Any, index: Any, queries: list[TestQuery]) -> dict:
    """Run baseline search and compute accuracy metrics."""
    top1_correct = 0
    top3_correct = 0
    results_detail: list[dict] = []

    for q in queries:
        # Use hybrid search (keyword + semantic)
        try:
            hybrid_results = index.search(q.query, k=5)
        except Exception:
            # Fallback to keyword-only if semantic fails
            hybrid_results = store.search_keyword(q.query, limit=5)

        top1_ok = hybrid_results and check_top1(
            hybrid_results[0][0].law_title, q.expected_law
        )
        top3_ok = check_in_top_n(hybrid_results, q.expected_law, 3)

        if top1_ok:
            top1_correct += 1
        if top3_ok:
            top3_correct += 1

        top_chunks = [
            (c.law_title, c.article_num, s)
            for c, s in hybrid_results[:5]
        ]
        results_detail.append({
            "query": q.query,
            "expected": q.expected_law,
            "top1_ok": top1_ok,
            "top3_ok": top3_ok,
            "top_results": top_chunks,
        })

    n = len(queries)
    return {
        "top1_accuracy": top1_correct / n if n > 0 else 0,
        "top3_recall": top3_correct / n if n > 0 else 0,
        "top1_correct": top1_correct,
        "top3_correct": top3_correct,
        "total": n,
        "details": results_detail,
    }


async def evaluate_llm(
    ranker: Any, queries: list[TestQuery]
) -> dict | None:
    """Run LLM-enhanced search and compute accuracy metrics."""
    top1_correct = 0
    top3_correct = 0
    results_detail: list[dict] = []
    errors = 0

    for q in queries:
        try:
            result = await ranker.search_with_llm(q.query, top_k=5)
        except Exception as e:
            errors += 1
            results_detail.append({
                "query": q.query,
                "expected": q.expected_law,
                "top1_ok": False,
                "top3_ok": False,
                "error": str(e),
            })
            continue

        top1_ok = result.top_chunks and check_top1(
            result.top_chunks[0][0].law_title, q.expected_law
        )
        top3_ok = check_in_top_n(result.top_chunks, q.expected_law, 3)

        if top1_ok:
            top1_correct += 1
        if top3_ok:
            top3_correct += 1

        top_chunks = [
            (c.law_title, c.article_num, s)
            for c, s in result.top_chunks[:5]
        ]
        results_detail.append({
            "query": q.query,
            "expected": q.expected_law,
            "rewritten": result.rewritten_query,
            "top1_ok": top1_ok,
            "top3_ok": top3_ok,
            "top_results": top_chunks,
        })

    n = len(queries)
    return {
        "top1_accuracy": top1_correct / n if n > 0 else 0,
        "top3_recall": top3_correct / n if n > 0 else 0,
        "top1_correct": top1_correct,
        "top3_correct": top3_correct,
        "total": n,
        "errors": errors,
        "details": results_detail,
    }


# ── Output ──────────────────────────────────────────────────────────────────


def print_results(
    baseline: dict, llm: dict | None, queries: list[TestQuery]
) -> None:
    """Print evaluation results in a readable table."""
    print("\n" + "=" * 80)
    print("  法律检索评估结果")
    print("=" * 80)

    # Query-level detail table
    print(f"\n{'查询':<28s} {'预期法律':<20s} {'基准Top1':^8s} {'LLM Top1':^8s}")
    print("-" * 80)

    for i, q in enumerate(queries):
        b_detail = baseline["details"][i]
        l_detail = llm["details"][i] if llm else None

        b_mark = "✓" if b_detail["top1_ok"] else "✗"
        if l_detail:
            l_mark = "✓" if l_detail["top1_ok"] else "✗"
            if l_detail.get("error"):
                l_mark = "⚠"
        else:
            l_mark = "—"

        query_abbrev = q.query[:24] + ("" if len(q.query) <= 24 else "…")
        print(f"{query_abbrev:<28s} {q.expected_law:<20s} {b_mark:^8s} {l_mark:^8s}")

    # Summary
    print("-" * 80)
    print(f"{'总计':<28s} {'':<20s} "
          f"{baseline['top1_correct']}/{baseline['total']:^8} ", end="")
    if llm:
        print(f"{llm['top1_correct']}/{llm['total']:^8}")
    else:
        print("—")

    # Detailed metrics
    print(f"\n{'指标':<20s} {'基准':>15s}", end="")
    if llm:
        print(f"  {'LLM增强':>15s}  {'提升':>8s}")
    else:
        print()
    print("-" * 40 if not llm else "-" * 65)

    print(f"{'Top-1 准确率':<20s} {baseline['top1_accuracy']:>14.1%}", end="")
    if llm:
        delta = llm['top1_accuracy'] - baseline['top1_accuracy']
        print(f"  {llm['top1_accuracy']:>14.1%}  {delta:>+7.1%}")
    else:
        print()

    print(f"{'Top-3 召回率':<20s} {baseline['top3_recall']:>14.1%}", end="")
    if llm:
        delta = llm['top3_recall'] - baseline['top3_recall']
        print(f"  {llm['top3_recall']:>14.1%}  {delta:>+7.1%}")
    else:
        print()

    # Show failed queries
    failed_baseline = [
        d for d in baseline["details"] if not d["top1_ok"]
    ]
    if failed_baseline:
        print(f"\n## 基准 Top-1 失败 ({len(failed_baseline)} 条)")
        for d in failed_baseline:
            print(f"  查询: {d['query']}")
            print(f"  预期: {d['expected']}")
            top_titles = [t[0] for t in d["top_results"][:3]]
            print(f"  实际: {top_titles}")
            print()

    if llm:
        failed_llm = [
            d for d in llm["details"] if not d["top1_ok"]
        ]
        if failed_llm:
            print(f"\n## LLM Top-1 失败 ({len(failed_llm)} 条)")
            for d in failed_llm:
                print(f"  查询: {d['query']}")
                print(f"  改写: {d.get('rewritten', 'N/A')}")
                print(f"  预期: {d['expected']}")
                top_titles = [t[0] for t in d.get("top_results", [])[:3]]
                print(f"  实际: {top_titles}")
                if d.get("error"):
                    print(f"  错误: {d['error']}")
                print()


# ── Main ────────────────────────────────────────────────────────────────────


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Evaluate LLM-enhanced legal search vs baseline"
    )
    parser.add_argument(
        "--llm", action="store_true",
        help="Run LLM-enhanced pipeline (requires API key)"
    )
    parser.add_argument(
        "--base-url", default=None,
        help="LLM API base URL"
    )
    parser.add_argument(
        "--model", default=None,
        help="LLM model name"
    )
    parser.add_argument(
        "--data-dir", default=None,
        help="Path to data/laws directory"
    )
    args = parser.parse_args()

    # ── Load law store ───────────────────────────────────────────────────
    project_root = Path(__file__).resolve().parent.parent
    data_dir = args.data_dir or str(project_root / "data" / "laws")

    print(f"加载法律库: {data_dir}")

    from hardlaw.legal_knowledge.law_store import LawStore

    t0 = time.time()
    store = LawStore(data_dir)
    print(f"  LawStore: {store.law_count} 部法律, "
          f"{len(store.all_chunks())} 条 ({(time.time() - t0):.1f}s)")

    # ── Load law index ───────────────────────────────────────────────────
    index = None
    try:
        from hardlaw.legal_knowledge.law_index import LawIndex

        t0 = time.time()
        index = LawIndex(store)
        index.ensure_fresh()
        print(f"  LawIndex: {index.size} 向量 ({(time.time() - t0):.1f}s)")
    except Exception as e:
        print(f"  LawIndex: 不可用 ({e})")

    # ── Benchmark baseline ───────────────────────────────────────────────
    print(f"\n运行基准测试 ({len(TEST_QUERIES)} 条查询)...")
    baseline = evaluate_baseline(store, index, TEST_QUERIES)
    print(f"  Top-1: {baseline['top1_accuracy']:.1%}  "
          f"Top-3: {baseline['top3_recall']:.1%}")

    # ── Benchmark LLM (if enabled) ───────────────────────────────────────
    llm_result = None
    if args.llm:
        from hardlaw.legal_knowledge.llm_ranker import LLMRanker

        ranker = LLMRanker(
            store, index,
            base_url=args.base_url,
            model=args.model,
        )
        print(f"\n运行 LLM 增强测试 ({len(TEST_QUERIES)} 条查询)...")
        print(f"  模型: {ranker._model}")
        print(f"  终端: {ranker._base_url}")

        llm_result = await evaluate_llm(ranker, TEST_QUERIES)
        if llm_result:
            print(f"  Top-1: {llm_result['top1_accuracy']:.1%}  "
                  f"Top-3: {llm_result['top3_recall']:.1%}  "
                  f"错误: {llm_result.get('errors', 0)}")

    # ── Print results ────────────────────────────────────────────────────
    print_results(baseline, llm_result, TEST_QUERIES)

    if not args.llm:
        print("\n💡 提示: 设置 API key 并添加 --llm 以运行 LLM 增强测试:")
        print("   HARDLAW_LLM_API_KEY=sk-xxx python scripts/eval_llm_ranker.py --llm")


if __name__ == "__main__":
    asyncio.run(main())
