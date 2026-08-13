#!/usr/bin/env python3
"""bench_judge.py — 法律裁决 LLM 基准(3 组指标)。

指标:
  1. 法条引用准确率 (law_citation): 给定法律问题,LLM 回答是否引用正确法条
  2. 数字蕴含准确率 (numeric_entailment): 回答中的数字是否能在给定证据中回溯
  3. 分类准确率 (classification): 文档分类与确定性 DocumentClassifier 的一致性

用法:
  python3 bench_judge.py --backend deepseek-pro      # 云端
  python3 bench_judge.py --backend mlx-3b            # 本地(需 mlx_lm.server 在 8099)

输出 JSON 报告:每组 pass/total/rate + 失败样本。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1]

# ── 评测集 ──────────────────────────────────────────────────────────────

# 1. 法条引用: (问题, 期望法条关键词)
LAW_CITATION_CASES = [
    ("用人单位拖欠工资超过一个月,劳动者可依据哪条法律主张权利?",
     ["劳动法", "劳动合同法", "工资支付暂行规定"]),
    ("劳动者被迫解除劳动合同的依据是什么?",
     ["劳动合同法", "38", "第三十八条"]),
    ("违法解除劳动合同的赔偿金标准(2N)依据?",
     ["劳动合同法", "87", "第八十七条"]),
    ("经济补偿金每满一年支付几个月的计算依据?",
     ["劳动合同法", "47", "第四十七条"]),
    ("劳动争议申请仲裁的时效期间是多久?",
     ["劳动争议调解仲裁法", "27", "第二十七条", "一年"]),
    ("未休年休假的工资报酬标准?",
     ["职工带薪年休假条例", "5", "300%"]),
    ("加班费工作日延长工作时间的支付比例?",
     ["劳动法", "44", "第四十四条", "150%"]),
    ("未签书面劳动合同超过一个月不满一年,双倍工资依据?",
     ["劳动合同法", "82", "第八十二条"]),
    # ── 扩充:互斥法条/边界(可自动判定) ──
    ("经济补偿金(N)与违法解除赔偿金(2N)能否同时主张?",
     ["87", "第八十七条", "不能兼得", "不能同时"]),
    ("违法解除赔偿金与代通知金(N+1)能否同时主张?",
     ["87", "第八十七条", "40", "第四十条", "不能兼得", "不能同时"]),
    ("未签合同满一年后,双倍工资最多支持几个月?",
     ["82", "第八十二条", "11", "十一个月"]),
    ("工作日加班、休息日加班、法定节假日加班的支付比例分别是什么?",
     ["150%", "200%", "300%", "44", "第四十四条"]),
    ("累计工作满10年不满20年的职工,年休假几天?",
     ["10", "十天", "年休假"]),
    ("休息日安排工作又不能安排补休的,支付不低于工资的多少?",
     ["200%", "44", "第四十四条"]),
    ("高收入劳动者经济补偿金年限封顶多少年?",
     ["47", "第四十七条", "12", "十二年"]),
]

# 2. 数字蕴含: (证据文本, 回答应包含的数字集合)
NUMERIC_CASES = [
    ("劳动合同载明:月工资7550元,2025年1月起欠薪。",
     {"7550"}),
    ("工资表:应发合计7550.00元,基本工资7000元,工龄津贴150元。",
     {"7550", "7000", "150"}),
    ("被迫解除通知书:经济赔偿金90600元,2020年7月1日入职。",
     {"90600"}),
    # ── 扩充:数字陷阱(可自动判定) ──
    # 社保缴费基数是社平 60%-300%,不等于实际工资
    ("社保参保证明:缴费基数5000元。劳动合同约定月工资8000元。",
     {"5000", "8000"}),
    # 公积金缴存额 vs 工资(豆包基准曾错:7554 vs 1490)
    ("个人住房公积金查询书:月缴存额1490元。工资表:月工资7550元。",
     {"1490", "7550"}),
    # 金额含小数与千分位
    ("银行流水:2025年1月实发工资7,550.00元,个税扣除355.00元。",
     {"7550", "355"}),
    # 经济补偿计算:2年4个月→2.5个月
    ("劳动合同:月工资8000元,工作2年4个月,违法解除。",
     {"2.5"}),
    # 高薪封顶:社平3倍+12年
    ("月工资50000元,工作20年,当地社平工资10000元,违法解除赔偿金?",
     {"360000", "30000"}),
]

# 3. 分类: (文件名, OCR 内容, 期望类别)
CLASSIFY_CASES = [
    ("证据3、劳动合同.pdf", "劳动合同 甲方：河南达海 乙方：郭又义 月工资：7550元", "书面劳动合同"),
    ("证据1、参保证明.pdf", "河南省社会保险个人参保证明 参保人：郭又义", "参保证明"),
    ("微信图片_20260511.jpg", "应发工资 7550 实发 7450", "工资表"),
    ("证据12、EMS交寄单.pdf", "EMS 邮件号码 EX123 寄件人 郭又义", "EMS邮寄凭证"),
    ("被迫解除劳动关系通知书.pdf", "依据《劳动合同法》第38条 被迫解除", "被迫解除通知书"),
    ("证据23、达海项目发票.pdf", "河南增值税发票 价税合计 50000", "财务混同证据"),
    # ── 扩充:对抗分类(易误判边界) ──
    # 被迫解除 vs 辞退:文件名相似,靠内容区分
    ("解除通知书.pdf", "依据《劳动合同法》第38条 未足额支付劳动报酬 被迫解除", "被迫解除通知书"),
    ("辞退通知书.pdf", "依据《劳动合同法》第39条 严重违反规章制度 予以辞退", "解除通知书"),
    # 混同用工:人事混同 vs 财务混同
    ("情况说明.pdf", "郭又义同时任职于达海和五建两公司 人员交叉", "人事混同证据"),
    ("发票及付款凭证.pdf", "五建集团为达海公司垫付工程款 资金混同", "财务混同证据"),
    # 年休假 vs 普通请假
    ("请假审批单.pdf", "年休假申请 2025年8月 5天 审批通过", "年休假申请/审批记录"),
    ("请假单.pdf", "事假申请 2025年3月 2天", "年休假申请/审批记录"),  # 事假≠年休假,应判其他
    # 公积金 vs 社保(易混)
    ("住房公积金查询书.pdf", "个人住房公积金 月缴存额 1490", "住房公积金"),
    # 聊天记录 vs 工资表(微信图片陷阱回归)
    ("微信图片_20260511142513.jpg", "2026/05/11 14:25", "其他证据"),  # 弱内容,不应判聊天记录
    # 未发工资统计表 vs 工资表
    ("未发放工资统计表.pdf", "2025年3月 拖欠工资 30000元 未发放", "未发工资统计表"),
]


def normalize(text: str) -> str:
    """全角→半角 + 空白归一(与 iOS 端一致)。"""
    out = []
    for ch in text:
        code = ord(ch)
        if 0xFF01 <= code <= 0xFF5E:
            out.append(chr(code - 0xFEE0))
        elif code == 0x3000:
            out.append(" ")
        else:
            out.append(ch)
    return re.sub(r"\s+", " ", "".join(out))


# ── 后端 ────────────────────────────────────────────────────────────────

BACKENDS = {
    "deepseek-pro": ("https://api.deepseek.com/v1", "deepseek-v4-pro"),
    "deepseek-flash": ("https://api.deepseek.com/v1", "deepseek-v4-flash"),
    "mlx-3b": ("http://127.0.0.1:8099/v1", "mlx-community/Qwen2.5-3B-Instruct-4bit"),
    "mlx-05b": ("http://127.0.0.1:8099/v1", "mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
}


def resolve_key() -> str:
    env = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if env:
        return env
    try:
        s = json.loads(Path.home().joinpath(".claude", "settings.json").read_text())
        return s.get("env", {}).get("ANTHROPIC_AUTH_TOKEN", "")
    except Exception:
        return ""


def chat(backend: str, prompt: str, max_tokens: int = 512, retries: int = 2) -> str:
    base, model = BACKENDS[backend]
    key = resolve_key()
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
    }
    last_err = ""
    for attempt in range(retries + 1):
        try:
            r = httpx.post(f"{base}/chat/completions", json=payload,
                           headers=headers, timeout=60)
            r.raise_for_status()
            content = r.json()["choices"][0]["message"]["content"]
            if content and content.strip():
                return content
            last_err = "empty response"
        except Exception as e:
            last_err = str(e)
        if attempt < retries:
            time.sleep(1.5 * (attempt + 1))
    return f"__ERROR__: {last_err}"


# ── 评测执行 ────────────────────────────────────────────────────────────

def bench_law_citation(backend: str) -> dict:
    hits = 0
    failures = []
    for q, expected in LAW_CITATION_CASES:
        resp = chat(backend, f"请用一句话回答,并引用具体法条(法律名称+条号):\n{q}")
        norm = normalize(resp)
        hit = any(k in norm for k in expected)
        if hit:
            hits += 1
        else:
            failures.append({"q": q, "resp": resp[:200], "expected": expected})
    return {"total": len(LAW_CITATION_CASES), "pass": hits,
            "failures": failures}


def bench_numeric(backend: str) -> dict:
    hits = 0
    failures = []
    for evidence, expected_nums in NUMERIC_CASES:
        prompt = (f"证据: {evidence}\n"
                  f"请提取证据中的关键数字并说明其含义(回答中必须包含这些数字)。")
        resp = chat(backend, prompt)
        norm = normalize(resp)
        found = [n for n in expected_nums if n in norm]
        if len(found) == len(expected_nums):
            hits += 1
        else:
            failures.append({"evidence": evidence, "resp": resp[:200],
                             "missing": list(expected_nums - set(found))})
    return {"total": len(NUMERIC_CASES), "pass": hits,
            "failures": failures}


def bench_classify(backend: str) -> dict:
    hits = 0
    failures = []
    for fname, ocr, expected in CLASSIFY_CASES:
        prompt = (f"文档分类。文件名: {fname}\nOCR 内容: {ocr}\n"
                  f"从以下类别中选择最匹配的一个(只输出类别名,不要解释):\n"
                  f"书面劳动合同、工资银行流水、工资表、参保证明、工商登记信息、"
                  f"人事混同证据、财务混同证据、被迫解除通知书、EMS邮寄凭证、"
                  f"解除通知书、加班记录/打卡记录、工龄/工作年限证明、年休假申请/审批记录、"
                  f"月工资标准、入职日期、劳动关系终止日期、劳动行政部门责令限期支付决定、"
                  f"住房公积金、行政处罚文书、未发工资统计表、聊天记录、其他证据")
        resp = chat(backend, prompt).strip()
        if expected in resp:
            hits += 1
        else:
            failures.append({"file": fname, "resp": resp[:100], "expected": expected})
    return {"total": len(CLASSIFY_CASES), "pass": hits,
            "failures": failures}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="deepseek-pro", choices=list(BACKENDS))
    ap.add_argument("--out", default="bench_report.json")
    args = ap.parse_args()

    print(f"[bench_judge] backend={args.backend} started={time.strftime('%H:%M:%S')}")
    results = {
        "backend": args.backend,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "law_citation": bench_law_citation(args.backend),
        "numeric_entailment": bench_numeric(args.backend),
        "classification": bench_classify(args.backend),
    }

    # 汇总
    print("\n=== bench 结果 ===")
    overall = []
    for key, label in [("law_citation", "法条引用"), ("numeric_entailment", "数字蕴含"),
                       ("classification", "分类")]:
        r = results[key]
        rate = r["pass"] / r["total"] if r["total"] else 0
        overall.append(rate)
        print(f"  {label}: {r['pass']}/{r['total']} = {rate:.2%}")
        for f in r["failures"][:3]:
            print(f"    ✗ {f}")
    avg = sum(overall) / len(overall) if overall else 0
    results["overall_rate"] = avg
    print(f"  平均: {avg:.2%}")

    Path(args.out).write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f"\n报告已写入 {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
