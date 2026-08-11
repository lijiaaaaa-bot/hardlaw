#!/usr/bin/env python3
"""
MLX Judge Benchmark — 对比多个 MLX 模型在劳动仲裁法律判断上的质量。

用法: python3 scripts/bench_judge.py [--models qwen2.5-0.5b,qwen2.5-3b] [--mode judgment|catalog|all]

产出:
  - 每个模型的通过率、延迟、关键数字命中率
  - bench_results.json（可对比）
  - bench_report.md（人类可读）
"""
from __future__ import annotations

import json, time, sys, os, re
from dataclasses import dataclass, field
from typing import Optional

# ── 数字归一化 ──

def normalize_number(n: str) -> str:
    """Strip commas, spaces, and common Chinese unit suffixes for matching."""
    n = n.strip().replace(",", "").replace("，", "").replace(" ", "")
    # Convert 万/亿 units to raw numbers for comparison
    if n.endswith("万"):
        try:
            return str(int(float(n[:-1]) * 10000))
        except ValueError:
            return n
    if n.endswith("亿"):
        try:
            return str(int(float(n[:-1]) * 100000000))
        except ValueError:
            return n
    # Strip 元 suffix
    if n.endswith("元"):
        n = n[:-1]
    return n

def numbers_match(expected: str, raw_output: str) -> bool:
    """Check if an expected number appears in the raw output, with normalization."""
    norm_expected = normalize_number(expected)
    norm_raw = normalize_number(raw_output)
    # Direct substring match after normalization
    if norm_expected in norm_raw:
        return True
    # Also try the original expected string (for non-numeric tokens like "0028")
    if expected in raw_output:
        return True
    return False

def count_number_hits(expected_numbers: list[str], raw_output: str) -> int:
    """Count how many expected numbers are found in the raw output."""
    return sum(1 for n in expected_numbers if numbers_match(n, raw_output))


# ── 测试用例 ──

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
    # ── 扩展用例：数字计算型（验证模型不只是复读，而是理解）──
    {
        "name": "经济补偿金计算",
        "evidence": """月工资：7550元 工作年限：5年10个月（2020年7月1日至2026年5月8日）
依据《劳动合同法》第47条：每满一年支付一个月工资，六个月以上不满一年按一年计算，不满六个月支付半个月工资""",
        "expected_numbers": ["7550", "6", "45300"],
        "expected_finding": "经济补偿金计算",
        "prompt_type": "judgment",
    },
    {
        "name": "欠薪总额求和",
        "evidence": """郭又义欠薪明细：
2023年12月：7550元
2024年1月：7550元
2024年2月：7550元
2024年3月：7550元
2024年4月：7550元
合计：37750元""",
        "expected_numbers": ["7550", "37750"],
        "expected_finding": "欠薪总额确认",
        "prompt_type": "judgment",
    },
    {
        "name": "时效判断",
        "evidence": """劳动关系终止日期：2026年5月8日
当前日期：2026年8月11日
依据《劳动争议调解仲裁法》第27条：劳动关系终止的，应在终止之日起一年内提出""",
        "expected_numbers": ["2026", "5", "8", "1"],
        "expected_finding": "时效未届满",
        "prompt_type": "judgment",
    },
    {
        "name": "双倍工资区间",
        "evidence": """入职日期：2025年1月15日
签订书面劳动合同日期：2025年8月1日
月工资：8000元
依据《劳动合同法》第82条：用工满一个月起至满一年前一日，未签书面合同应支付双倍工资""",
        "expected_numbers": ["8000", "5.5", "44000"],
        "expected_finding": "双倍工资计算",
        "prompt_type": "judgment",
    },
]

# ── 目录生成用例（CATALOG_PROMPT）──

CATALOG_TEST_CASES = [
    {
        "name": "工资表",
        "evidence": """达海建筑工资表（2025年1月）姓名：郭又义 基本工资：7000元
工龄津贴：150元 外地津贴：400元 应发工资合计：7550元""",
        "expected_numbers": ["7550"],
        "expected_keywords": ["工资", "郭又义"],
    },
    {
        "name": "参保证明",
        "evidence": """河南省社会保险个人参保证明
参保人：郭又义 参保单位：河南达海建设工程有限公司
参保起始：2020年7月1日 缴费基数：7450元""",
        "expected_numbers": ["7450", "2020"],
        "expected_keywords": ["社保", "达海"],
    },
    {
        "name": "银行流水",
        "evidence": """银行工资流水（2023年4月至2026年）
2023年4月-2024年9月：达海公司公户发放
2024年10月起：冉林夕个人账户发放
月发放金额：约7550元""",
        "expected_numbers": ["7550"],
        "expected_keywords": ["银行", "流水", "发放"],
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
    ModelConfig("mlx-community/Qwen3-4B-Instruct-2507-4bit", "Qwen3-4B"),
    ModelConfig("mlx-community/Qwen3.5-35B-A3B-4bit", "Qwen3.5-35B-MoE"),
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


def run_judgment_test(model_id: str, test: dict, model_cache: dict | None = None) -> TestResult:
    """Run a single judgment test and measure quality."""
    import mlx_lm

    if model_cache is not None and model_id in model_cache:
        model, tokenizer = model_cache[model_id]
    else:
        model, tokenizer = mlx_lm.load(model_id)
        if model_cache is not None:
            model_cache[model_id] = (model, tokenizer)
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

    # Score: normalized number matching (handles 万/元/逗号 variants)
    numbers_hit = count_number_hits(test["expected_numbers"], raw)
    passed = numbers_hit >= len(test["expected_numbers"]) * 0.5  # 50% threshold

    return TestResult(
        model=model_id, test_name=test["name"],
        passed=passed, numbers_hit=numbers_hit,
        numbers_total=len(test["expected_numbers"]),
        latency_seconds=latency, raw_output=raw
    )


def run_catalog_test(model_id: str, test: dict, model_cache: dict | None = None) -> TestResult:
    """Run a catalog generation test (proof content drafting)."""
    import mlx_lm

    if model_cache is not None and model_id in model_cache:
        model, tokenizer = model_cache[model_id]
    else:
        model, tokenizer = mlx_lm.load(model_id)
        if model_cache is not None:
            model_cache[model_id] = (model, tokenizer)
    prompt = CATALOG_PROMPT.format(name=test["name"], evidence=test["evidence"])
    input_ids = tokenizer.apply_chat_template([{"role":"user","content":prompt}], add_generation_prompt=True)

    start = time.time()
    try:
        raw = mlx_lm.generate(model, tokenizer, prompt=input_ids, max_tokens=200, verbose=False)
    except Exception as e:
        return TestResult(model=model_id, test_name=f"catalog:{test['name']}",
                         passed=False, numbers_hit=0, numbers_total=len(test["expected_numbers"]),
                         latency_seconds=time.time()-start, error=str(e))
    latency = time.time() - start

    numbers_hit = count_number_hits(test["expected_numbers"], raw)
    # Catalog: also check for expected keywords
    kw_hit = sum(1 for kw in test.get("expected_keywords", []) if kw in raw)
    passed = numbers_hit >= len(test["expected_numbers"]) * 0.5

    return TestResult(
        model=model_id, test_name=f"catalog:{test['name']}",
        passed=passed, numbers_hit=numbers_hit,
        numbers_total=len(test["expected_numbers"]),
        latency_seconds=latency, raw_output=raw
    )


def main():
    # Parse arguments
    if "--models" in sys.argv:
        idx = sys.argv.index("--models")
        selected = sys.argv[idx + 1].split(",")
        models = [m for m in MODELS if any(s.lower() in m.id.lower() for s in selected)]
    else:
        models = MODELS[:2]  # Default: smallest two

    mode = "all"
    if "--mode" in sys.argv:
        mode = sys.argv[sys.argv.index("--mode") + 1]  # "judgment", "catalog", "all"

    run_judgment = mode in ("judgment", "all")
    run_catalog = mode in ("catalog", "all")

    total_cases = 0
    if run_judgment: total_cases += len(TEST_CASES)
    if run_catalog: total_cases += len(CATALOG_TEST_CASES)
    print(f"Benchmarking {len(models)} models on {total_cases} test cases (judgment={run_judgment}, catalog={run_catalog})...\n")

    reports: dict[str, ModelReport] = {}
    for mc in models:
        print(f"── {mc.display_name} ──")
        report = ModelReport(model=mc.display_name)
        model_cache: dict = {}  # Cache loaded model across tests

        if run_judgment:
            for test in TEST_CASES:
                print(f"  {test['name']}...", end=" ", flush=True)
                result = run_judgment_test(mc.id, test, model_cache)
                report.results.append(result)
                status = "✅" if result.passed else f"❌ ({result.numbers_hit}/{result.numbers_total})"
                print(f"{status} {result.latency_seconds:.1f}s")

        if run_catalog:
            for test in CATALOG_TEST_CASES:
                print(f"  catalog:{test['name']}...", end=" ", flush=True)
                result = run_catalog_test(mc.id, test, model_cache)
                report.results.append(result)
                status = "✅" if result.passed else f"❌ ({result.numbers_hit}/{result.numbers_total})"
                print(f"{status} {result.latency_seconds:.1f}s")

        reports[mc.display_name] = report
        print()

    # Comparison table
    print("═" * 70)
    print(f"{'Model':<18} {'Pass':>6} {'Nums':>7} {'Avg Lat':>8}")
    print("─" * 70)
    for name, r in reports.items():
        print(f"{name:<18} {r.pass_rate:>5.0%} {r.avg_numbers_hit_rate:>6.0%} {r.avg_latency:>7.1f}s")
    print("═" * 70)

    # Save results (including raw_output for debugging)
    results_data = {
        name: {
            "pass_rate": r.pass_rate,
            "numbers_hit_rate": r.avg_numbers_hit_rate,
            "avg_latency": r.avg_latency,
            "tests": [{"name": t.test_name, "passed": t.passed,
                       "numbers": f"{t.numbers_hit}/{t.numbers_total}",
                       "latency": t.latency_seconds,
                       "raw_output": t.raw_output[:1000] if not t.error else None,
                       "error": t.error} for t in r.results]
        } for name, r in reports.items()
    }
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_results.json")
    with open(out_path, "w") as f:
        json.dump(results_data, f, indent=2, ensure_ascii=False)
    print(f"\nResults saved to scripts/bench_results.json")


if __name__ == "__main__":
    main()
