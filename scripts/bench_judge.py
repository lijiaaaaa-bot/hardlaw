#!/usr/bin/env python3
"""
MLX Judge Benchmark — 对比多个 MLX 模型在劳动仲裁法律判断上的质量。

用法: python3 scripts/bench_judge.py [--models qwen2.5-0.5b,qwen2.5-1.5b]

产出:
  - 每个模型的通过率、延迟、关键数字命中率
  - bench_results.json（可对比）
  - bench_report.md（人类可读）
"""
from __future__ import annotations

import json, time, sys, os
from dataclasses import dataclass, field
from typing import Optional

# ── 测试用例（从 hardlaw iOS 郭又义案提取的真实证据）──

TEST_CASES = [
    {
        "name": "劳动关系确认",
        "evidence": """河南省社会保险个人参保证明
参保人：郭又义 参保单位：河南达海建设工程有限公司
参保起始：2020年7月1日 缴费基数：7450元

劳动合同 甲方：河南达海建设工程有限公司 乙方：郭又义
合同期限：2025年7月1日至2028年6月30日 工作岗位：预算员""",
        "expected_numbers": ["7450", "2020", "2025", "2028"],
        "expected_finding": "劳动关系成立",
        "prompt_type": "judgment",
    },
    {
        "name": "工资标准核实",
        "evidence": """达海建筑工资表（2025年1月）姓名：郭又义 基本工资：7000元
工龄津贴：150元 外地津贴：400元 应发工资合计：7550元
制表人：冉林夕（五建集团财务）财务总监：马瑞平""",
        "expected_numbers": ["7000", "150", "400", "7550"],
        "expected_finding": "工资标准确认",
        "prompt_type": "judgment",
    },
    {
        "name": "欠薪事实确认",
        "evidence": """行政处罚事先告知书 中原人社监察罚先告字【2026】第0028号
河南达海建设工程有限公司拖欠4名劳动者工资合计341293.73元
其中：郭又义 93059.85元

未发放工资统计表 郭又义未发放金额合计：93059.85元""",
        "expected_numbers": ["341293.73", "93059.85", "0028"],
        "expected_finding": "欠薪证据确凿",
        "prompt_type": "judgment",
    },
    {
        "name": "混同用工判定",
        "evidence": """达海公司工商登记：股东河南五建建设集团有限公司 持股51%
注册地址：郑州市中原区建设西路100号（与五建集团相同）
工资表由五建集团财务冉林夕制表 达海印章由五建集团党政办管理""",
        "expected_numbers": ["51"],
        "expected_finding": "混同用工成立",
        "prompt_type": "judgment",
    },
]

JUDGMENT_PROMPT = """
你是劳动法律师助理。根据以下证据和硬约束，做出判定。

## 证据
{evidence}

## 要求
1. 判定该证据支持什么法律结论
2. 引用证据中的关键数字（必须与原文逐字一致）
3. 输出 JSON：
{{
  "finding": "<结论名称>",
  "refuted": true/false,
  "confidence": "high"|"medium"|"low",
  "cited_numbers": ["原文中的数字"],
  "reasoning": "<判定理由>"
}}

只返回 JSON，不要其他文字。
"""

CATALOG_PROMPT = """
你是一个劳动仲裁案件审查助手。根据以下证据内容，为证据目录撰写"证明内容"。

## 证据名称
{name}

## 原始证据文字
{evidence}

## 要求
1. 证明内容应客观描述该证据显示了什么事实
2. 引用的金额、日期、姓名必须与原文逐字一致
3. 输出 JSON：
{{
  "proof_content": "<证明内容>",
  "numbers_cited": ["原文中的数字"]
}}
"""

@dataclass
class ModelConfig:
    id: str
    display_name: str

MODELS = [
    ModelConfig("mlx-community/Qwen2.5-0.5B-Instruct-4bit", "Qwen2.5-0.5B"),
    ModelConfig("mlx-community/Qwen2.5-1.5B-Instruct-4bit", "Qwen2.5-1.5B"),
    ModelConfig("mlx-community/Qwen2.5-3B-Instruct-4bit", "Qwen2.5-3B"),
    ModelConfig("mlx-community/Qwen2.5-7B-Instruct-4bit", "Qwen2.5-7B"),
]

@dataclass
class TestResult:
    model: str
    test_name: str
    passed: bool
    numbers_hit: int
    numbers_total: int
    latency_seconds: float
    raw_output: str = ""
    error: Optional[str] = None

@dataclass
class ModelReport:
    model: str
    results: list[TestResult] = field(default_factory=list)

    @property
    def pass_rate(self) -> float:
        return sum(1 for r in self.results if r.passed) / max(len(self.results), 1)

    @property
    def avg_numbers_hit_rate(self) -> float:
        total_hit = sum(r.numbers_hit for r in self.results)
        total_num = sum(r.numbers_total for r in self.results)
        return total_hit / max(total_num, 1)

    @property
    def avg_latency(self) -> float:
        return sum(r.latency_seconds for r in self.results) / max(len(self.results), 1)


def run_judgment_test(model_id: str, test: dict) -> TestResult:
    """Run a single judgment test and measure quality."""
    import mlx_lm

    model, tokenizer = mlx_lm.load(model_id)
    prompt = JUDGMENT_PROMPT.format(evidence=test["evidence"])
    input_ids = tokenizer.apply_chat_template([{"role":"user","content":prompt}], add_generation_prompt=True)

    start = time.time()
    try:
        raw = mlx_lm.generate(model, tokenizer, prompt=input_ids, max_tokens=300, verbose=False)
    except Exception as e:
        return TestResult(model=model_id, test_name=test["name"],
                         passed=False, numbers_hit=0, numbers_total=len(test["expected_numbers"]),
                         latency_seconds=time.time()-start, error=str(e))
    latency = time.time() - start

    # Score: check if expected numbers appear in output
    numbers_hit = sum(1 for n in test["expected_numbers"] if n in raw)
    passed = numbers_hit >= len(test["expected_numbers"]) * 0.5  # 50% threshold

    return TestResult(
        model=model_id, test_name=test["name"],
        passed=passed, numbers_hit=numbers_hit,
        numbers_total=len(test["expected_numbers"]),
        latency_seconds=latency, raw_output=raw[:500]
    )


def main():
    # Parse model selection
    if "--models" in sys.argv:
        selected = sys.argv[sys.argv.index("--models") + 1].split(",")
        models = [m for m in MODELS if any(s.lower() in m.id.lower() for s in selected)]
    else:
        models = MODELS[:2]  # Default: smallest two

    print(f"Benchmarking {len(models)} models on {len(TEST_CASES)} test cases...\n")

    reports: dict[str, ModelReport] = {}
    for mc in models:
        print(f"── {mc.display_name} ──")
        report = ModelReport(model=mc.display_name)
        for test in TEST_CASES:
            print(f"  {test['name']}...", end=" ", flush=True)
            result = run_judgment_test(mc.id, test)
            report.results.append(result)
            status = "✅" if result.passed else f"❌ ({result.numbers_hit}/{result.numbers_total})"
            print(f"{status} {result.latency_seconds:.1f}s")
        reports[mc.display_name] = report
        print()

    # Comparison table
    print("═" * 60)
    print(f"{'Model':<16} {'Pass':>6} {'Nums':>6} {'Avg Lat':>8}")
    print("─" * 60)
    for name, r in reports.items():
        print(f"{name:<16} {r.pass_rate:>5.0%} {r.avg_numbers_hit_rate:>5.0%} {r.avg_latency:>7.1f}s")
    print("═" * 60)

    # Save results
    results_data = {
        name: {
            "pass_rate": r.pass_rate,
            "numbers_hit_rate": r.avg_numbers_hit_rate,
            "avg_latency": r.avg_latency,
            "tests": [{"name": t.test_name, "passed": t.passed,
                       "numbers": f"{t.numbers_hit}/{t.numbers_total}",
                       "latency": t.latency_seconds,
                       "error": t.error} for t in r.results]
        } for name, r in reports.items()
    }
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_results.json")
    with open(out_path, "w") as f:
        json.dump(results_data, f, indent=2, ensure_ascii=False)
    print(f"\nResults saved to scripts/bench_results.json")


if __name__ == "__main__":
    main()
