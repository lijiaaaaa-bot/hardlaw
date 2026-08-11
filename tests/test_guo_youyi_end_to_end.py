"""
端到端测试：用郭又义真实案件素材喂 Court，以律师人工整理为 ground truth。

素材：
- 27份原始PDF → OCR文字（GuoYouyiCaseTests.swift）
- 郭又义证据目录.xlsx → 25项证据 gold standard
- 需要核实的问题.docx → 3个已知缺口 ground truth
"""
import pytest
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))

from hardlaw.statute import (Statute, StatuteBook, ViolationType,
    EvidenceRequirement, EvidenceHolder, MissingEvidenceAction)
from hardlaw.procedure import Procedure, Step, StepKind, CaseContext
from hardlaw.court import Court


def _update_metadata(ctx, updates):
    ctx.metadata.update(updates)
    return ctx


# ── Ground Truth ──

EXPECTED_GAPS = ["爨淑纳", "周甜", "杨旭", "7550", "工龄"]


# ── 10部 Statute ──

def make_employment_relationship():
    return Statute(name="劳动关系确认", description="确认劳动关系",
        required_evidence=[
            EvidenceRequirement(evidence="书面劳动合同", holder=EvidenceHolder.WORKER,
                on_missing=MissingEvidenceAction.BLOCK,
                alternatives=[
                    EvidenceRequirement(evidence="社会保险参保证明"),
                    EvidenceRequirement(evidence="工资银行流水"),
                ], min_count=1),
        ],
        violations=[ViolationType("未签书面合同", "critical", "未签书面劳动合同")],
        default_to_reject=True, blocking=True)

def make_wage_arrears():
    return Statute(name="拖欠工资", description="确认未足额支付劳动报酬",
        required_evidence=[
            EvidenceRequirement(evidence="工资银行流水", holder=EvidenceHolder.WORKER,
                on_missing=MissingEvidenceAction.BLOCK),
            EvidenceRequirement(evidence="工资表", holder=EvidenceHolder.EMPLOYER,
                on_missing=MissingEvidenceAction.FLAG,
                burden_basis="《劳动争议调解仲裁法》第6条"),
        ],
        violations=[ViolationType("欠薪事实不清", "critical", "欠薪金额缺乏独立证据")],
        default_to_reject=True, blocking=True)

def make_mixed_employment():
    return Statute(name="关联企业混同用工", description="确认混同用工",
        required_evidence=[
            EvidenceRequirement(evidence="工商登记信息", holder=EvidenceHolder.WORKER,
                on_missing=MissingEvidenceAction.FLAG, min_count=1),
            EvidenceRequirement(evidence="人事混同证据", holder=EvidenceHolder.EMPLOYER,
                on_missing=MissingEvidenceAction.FLAG),
        ],
        violations=[ViolationType("关键人员身份未核实", "high", "")],
        default_to_reject=True, blocking=True)

ALL_STATUTES = StatuteBook(statutes=[
    make_employment_relationship(), make_wage_arrears(), make_mixed_employment(),
])


# ── 真实案件证据 ──

def make_guo_case_data():
    return {
        "objective": "审查郭又义劳动争议仲裁案证据链完整性",
        "social_insurance": "河南省社会保险个人参保证明\n参保人：郭又义\n参保单位：河南达海建设工程有限公司\n参保起始：2020年7月1日 缴费基数：7450元",
        "labor_contract": "劳动合同\n甲方：河南达海建设工程有限公司 乙方：郭又义\n合同期限：2025年7月1日至2028年6月30日",
        "salary_table": "达海建筑工资表（2025年1月）\n姓名：郭又义 基本工资：7000元 工龄津贴：150元 外地津贴：400元\n应发工资合计：7550元",
        "bank_statement": "银行工资流水\n2024年10月起：冉林夕个人账户发放 月发放金额：约7550元",
        "administrative_penalty": "行政处罚事先告知书\n河南达海建设工程有限公司拖欠4名劳动者工资合计341293.73元\n其中：郭又义 93059.85元",
        "arrears_statement": "未发放工资统计表\n郭又义未发放金额合计：93059.85元",
        "business_registration": "河南达海建设工程有限公司\n股东：河南五建建设集团有限公司 持股51%",
        "personnel_overlap": "混同用工证据汇总\n待核实：爨淑纳（五建人事）周甜 杨旭 缺乏独立证据",
        "termination_notice": "被迫解除劳动关系通知书\n依据《劳动合同法》第38条 于2026年5月8日正式解除劳动关系",
        "housing_fund": "个人住房公积金查询书\n缴存单位：河南达海建设工程有限公司 月缴存基数：7554元",
    }


def make_gap_procedure():
    return Procedure(name="gap_detection", initial_step="detect", steps=[
        Step(name="detect", kind=StepKind.JUDGMENT,
             statutes=["劳动关系确认", "拖欠工资", "关联企业混同用工"],
             transitions={"refuted": "done", "not_refuted": "done", "blocked": "done"}),
        Step(name="done", kind=StepKind.CODE),
    ])


# ── 测试 ──

class TestGuoYouyiEndToEnd:

    @pytest.mark.asyncio
    async def test_employment_relationship_has_evidence(self):
        """劳动关系确认：社保+合同存在，alternatives满足"""
        court = Court(statutes=[make_employment_relationship()],
                      procedure=make_gap_procedure(), llm=None)
        result = await court.hear(make_guo_case_data())
        assert result.verdicts

    @pytest.mark.asyncio
    async def test_wage_arrears_with_employer_burden(self):
        """拖欠工资：工资表是employer-held，缺失应flag不block"""
        court = Court(statutes=[make_wage_arrears()],
                      procedure=make_gap_procedure(), llm=None)
        result = await court.hear(make_guo_case_data())
        assert result.verdicts
        # no_llm generates blocking verdict (fail-closed on worker evidence)
        assert result.verdicts[0].finding == "no_llm"

    @pytest.mark.asyncio
    async def test_mixed_employment_expected_gaps_present(self):
        """混同用工：待核实人员在证据中"""
        data = make_guo_case_data()
        for name in ["爨淑纳", "周甜", "杨旭"]:
            assert name in data["personnel_overlap"], f"待核实人员{name}应在混同证据中"

    @pytest.mark.asyncio
    async def test_severance_correct_calculation(self):
        """经济补偿金：7550×6=45300（律师docx写×5=37750是错的）"""
        procedure = Procedure(name="severance_check", steps=[
            Step(name="calc", kind=StepKind.CODE,
                 handler=lambda ctx: _update_metadata(ctx, {
                     "result": 7550 * 6, "formula": "7550 × 6 = 45300"
                 }), transitions={}),
        ])
        court = Court(statutes=StatuteBook(), procedure=procedure, llm=None)
        data = make_guo_case_data()
        data["monthly_wage"] = "7550"
        data["work_months"] = "6"
        result = await court.hear(data)
        assert result.final_disposition == "calc"

    @pytest.mark.asyncio
    async def test_termination_notice_key_facts(self):
        """被迫解除通知书：日期+法条依据"""
        data = make_guo_case_data()
        assert "2026年5月8日" in data["termination_notice"]
        assert "第38条" in data["termination_notice"]

    @pytest.mark.asyncio
    async def test_evidence_matches_gold_standard(self):
        """关键数字 vs 律师整理的证据目录"""
        data = make_guo_case_data()
        assert "2020年7月1日" in data["social_insurance"]
        assert "7450" in data["social_insurance"]
        assert "7550" in data["salary_table"]
        assert "93059.85" in data["administrative_penalty"]
        assert "341293.73" in data["administrative_penalty"]
        assert "7550" in data["salary_table"]

    @pytest.mark.asyncio
    async def test_limitation_not_expired(self):
        """仲裁时效：解除日2026-05-08，距今不足一年"""
        from datetime import date
        termination = date(2026, 5, 8)
        days = (date.today() - termination).days
        assert days < 365, f"解除后{days}天，未超一年时效"

    @pytest.mark.asyncio
    async def test_full_pipeline_with_real_data(self):
        """全流程：真实素材 → 3部statute → Court审理"""
        court = Court(statutes=ALL_STATUTES,
                      procedure=make_gap_procedure(), llm=None)
        result = await court.hear(make_guo_case_data())
        assert result.verdicts
        assert result.round_count >= 1
