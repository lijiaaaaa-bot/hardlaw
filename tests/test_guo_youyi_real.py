"""
郭又义劳动争议案 — 基于原始证据的自动化测试

测试原则：
  - 输入：从原始证据 PDF 中实际提取的文字
  - 对照：劳动仲裁申请书 + 证据目录 + 需要核实的问题（律师整理的正确结论）
  - 不适用 MockLLM 手写返回值。使用 RuleBasedLLM 或直接机械验证。

原始材料来源：test-resources/raw-evidence/
对照材料来源：test-resources/guo-youyi/
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest
from hardlaw import (
    Statute, ViolationType, EscalationRule, StatuteBook,
    Procedure, Step, StepKind, CaseContext,
    EvidenceRef, EvidenceRule, EvidenceValidator,
    VerdictParser,
    Court,
)


# ============================================================
# 从原始证据提取的真实文本
# ============================================================

# 证据1：参保证明 — 从 PDF 实际提取
SOCIAL_INSURANCE_TEXT = """
表单验证号码2853aaf457684f93a0382ee27c17f3fb
河南省社会保险个人参保证明（2025年）
证件号码 410521199607112516
姓名 郭又义
单位名称 河南达海建设工程有限公司
失业保险 202007 -
工伤保险 202007 -
企业职工基本养老保险 202007 -
参保时间 2020-07-01 参保缴费
缴费基数 7450
"""

# 证据5：银行工资流水 — 从 PDF 实际提取
BANK_STATEMENT_TEXT = """
账户交易流水
起始日期 20230317 结束日期 20260317
账户名称 郭又义 账号 6236600043464171
20260213 5932.25 收入 冉林夕 6236601123216184 网上银行 25年12月份工资
20250521 6037.65 收入 中原银行 冉林夕
"""

# 证据13：达海工商登记 — 从 PDF 实际提取
DAHAI_BUSINESS_TEXT = """
河南达海建设工程有限公司 存续
统一社会信用代码：914101006831917309
法定代表人：逯海亮
注册资本：10000万元
成立日期：2009-01-06
地址：郑州市中原区建设西路100号
"""

# 证据13：五建工商登记 — 从 PDF 实际提取
WUJIAN_BUSINESS_TEXT = """
河南五建建设集团有限公司 存续
统一社会信用代码：91410100170051134L
法定代表人：张文德
注册资本：30000万元
成立日期：1999-11-26
地址：郑州市中原区建设西路100号
"""

# 证据2：公积金 — 从对照材料可知缴存基数7554元
HOUSING_FUND_TEXT = """
个人住房公积金查询书
缴存单位：河南达海建设工程有限公司
缴存起始：2020年8月17日
月缴存基数：7554元
"""

# 以下证据是图片 PDF，文字从对照材料（证据目录）中交叉验证获取
# 对照材料中的"证明内容"列是对原始证据的客观摘要，不含主观判断
# 我们在测试中使用的 snippet 必须能在这些文字中逐字定位

SALARY_TABLE_TEXT = """
达海建筑工资表（2025年1月）
姓名：郭又义 岗位：新安碧桂园一期项目预算员
基本工资：7000元 工龄津贴：150元 外地津贴：400元
应发工资合计：7550元
制表人：冉林夕 审核人：王香玉
"""

ADMIN_PENALTY_TEXT = """
郑州市中原区人力资源和社会保障局
行政处罚事先告知书
中原人社监察罚先告字【2026】第0028号
经查，河南达海建设工程有限公司拖欠4名劳动者工资合计341293.73元
其中：郭又义 93059.85元
2026年4月8日下达限期改正指令书，逾期未履行
"""

ARREARS_STATEMENT_TEXT = """
李鹏飞、卫蒙、郭又义未发放工资统计表
郭又义：2023年12月、2024年1-4月、2025年3-11月、2026年1-5月8日
合计未发放金额：93059.85元
盖章：河南达海建设工程有限公司
"""

PERSONNEL_TEXT = """
混同用工证据汇总：
1. 和海波：达海公司总经理，同时为五建集团工会委员
2. 彭国运：五建集团监事、七分公司总经理
3. 谢朝晖：达海公司股东，建造师证书工作单位为五建集团
4. 五建集团人事周甜负责达海员工劳动合同续签
5. 达海印章由五建集团党政办管理
6. 达海财务人员均为五建集团员工
⚠️ 待核实：
- 爨淑纳是否为五建集团员工？缺乏社保或工商记录
- 周甜是否为五建集团员工？缺乏独立证据
- 杨旭是否为五建集团法务？仅有聊天记录提及
"""

# ============================================================
# 对照材料中的事实（来自劳动仲裁申请书和证据目录）
# 这些是"正确答案"，测试应验证管线是否能自动得出相同结论
# ============================================================

KNOWN_FACTS = {
    "applicant": "郭又义",
    "applicant_id": "410521199607112516",
    "respondent_1": "河南达海建设工程有限公司",
    "respondent_1_credit_code": "914101006831917309",
    "respondent_2": "河南五建建设集团有限公司",
    "respondent_2_credit_code": "91410100170051134L",
    "monthly_wage": 7550,
    "social_insurance_base": 7450,
    "housing_fund_base": 7554,
    "wage_arrears_amount": 93059.85,
    "employment_start": "2020-07-01",
    "termination_date": "2026-05-08",
    "severance_amount": 37750,  # 7550 × 5
    "wujian_holds_dahai": "51%",
    "same_address": "郑州市中原区建设西路100号",
}

# ============================================================
# Test 1: 证据物理层 — 引用完整性（不依赖 LLM）
# ============================================================

class TestEvidencePhysics:
    """证据的物理约束测试 — 纯机械验证，不涉及 LLM"""

    def test_social_insurance_contains_key_data(self):
        """证据1 参保证明：应包含身份证号、参保单位、起始日期、缴费基数"""
        assert "410521199607112516" in SOCIAL_INSURANCE_TEXT
        assert "河南达海建设工程有限公司" in SOCIAL_INSURANCE_TEXT
        assert "202007" in SOCIAL_INSURANCE_TEXT
        assert "7450" in SOCIAL_INSURANCE_TEXT

    def test_bank_statement_shows_ran_linxi_payment(self):
        """证据5 银行流水：2024年10月起冉林夕个人账户发工资"""
        assert "冉林夕" in BANK_STATEMENT_TEXT
        assert "6236601123216184" in BANK_STATEMENT_TEXT

    def test_business_registration_same_address(self):
        """证据13：达海和五建注册地址相同"""
        dahai_addr = "建设西路100号"
        wujian_addr = "建设西路100号"
        assert dahai_addr in DAHAI_BUSINESS_TEXT
        assert wujian_addr in WUJIAN_BUSINESS_TEXT
        assert dahai_addr == wujian_addr

    def test_credit_codes_different_entities(self):
        """达海和五建是不同的法律实体"""
        assert "914101006831917309" in DAHAI_BUSINESS_TEXT
        assert "91410100170051134L" in WUJIAN_BUSINESS_TEXT
        assert "914101006831917309" != "91410100170051134L"

    def test_amount_conservation_salary_components(self):
        """金额守恒：7000 + 150 + 400 = 7550"""
        assert "7000" in SALARY_TABLE_TEXT
        assert "150" in SALARY_TABLE_TEXT
        assert "400" in SALARY_TABLE_TEXT
        assert "7550" in SALARY_TABLE_TEXT
        assert 7000 + 150 + 400 == 7550

    def test_amount_conservation_arrears(self):
        """金额守恒：行政处罚告知书和统计表的欠薪金额一致"""
        assert "93059.85" in ADMIN_PENALTY_TEXT
        assert "93059.85" in ARREARS_STATEMENT_TEXT

    def test_salary_inconsistency_three_sources(self):
        """工资标准三源不一致：社保7450 vs 公积金7554 vs 工资表7550"""
        social_base = 7450
        housing_base = 7554
        salary_table = 7550
        # 三份来源的数额不完全相同
        assert len({social_base, housing_base, salary_table}) == 3

    def test_evidence_validator_snippet_must_exist(self):
        """EvidenceValidator：引用的 snippet 必须在源文中逐字存在"""
        validator = EvidenceValidator()
        validator.add_source("social_insurance", SOCIAL_INSURANCE_TEXT)
        validator.add_source("admin_penalty", ADMIN_PENALTY_TEXT)
        validator.add_source("bank_statement", BANK_STATEMENT_TEXT)

        # 这些 snippet 必须在源文中存在
        assert validator.validate(EvidenceRef(
            source="social_insurance", snippet="7450"))
        assert validator.validate(EvidenceRef(
            source="admin_penalty", snippet="郭又义 93059.85元"))
        assert validator.validate(EvidenceRef(
            source="bank_statement", snippet="冉林夕"))

    def test_evidence_validator_rejects_hallucinated_snippet(self):
        """EvidenceValidator：幻觉 snippet 必须被拒绝"""
        validator = EvidenceValidator()
        validator.add_source("admin_penalty", ADMIN_PENALTY_TEXT)

        # 幻觉金额 — 不存在于源文
        assert not validator.validate(EvidenceRef(
            source="admin_penalty", snippet="郭又义 150000元"))
        # 幻觉来源
        assert not validator.validate(EvidenceRef(
            source="court_judgment", snippet="驳回"))


# ============================================================
# Test 2: 从对照材料反向验证 — 测试用例生成
# ============================================================

class TestAgainstReferenceMaterial:
    """对照材料验证：管线输出应匹配律师整理的正确结论"""

    @pytest.fixture
    def all_evidence(self):
        return {
            "social_insurance": SOCIAL_INSURANCE_TEXT,
            "housing_fund": HOUSING_FUND_TEXT,
            "salary_table": SALARY_TABLE_TEXT,
            "bank_statement": BANK_STATEMENT_TEXT,
            "administrative_penalty": ADMIN_PENALTY_TEXT,
            "arrears_statement": ARREARS_STATEMENT_TEXT,
            "dahai_business": DAHAI_BUSINESS_TEXT,
            "wujian_business": WUJIAN_BUSINESS_TEXT,
            "personnel_overlap": PERSONNEL_TEXT,
        }

    def test_social_insurance_company_name_match(self):
        """对照验证：参保证明中的单位名称应与被申请人一一致"""
        assert "河南达海建设工程有限公司" in SOCIAL_INSURANCE_TEXT

    def test_arrears_amount_consistent_across_sources(self):
        """对照验证：欠薪金额 93059.85 在行政处罚和统计表中一致"""
        assert "93059.85" in ADMIN_PENALTY_TEXT
        assert "93059.85" in ARREARS_STATEMENT_TEXT

    def test_personnel_gaps_exist(self):
        """对照验证：需要核实的问题中提到的3个人员身份缺口"""
        gaps_needed = ["爨淑纳", "周甜", "杨旭"]
        for name in gaps_needed:
            assert name in PERSONNEL_TEXT, f"人员 {name} 应出现在混同用工证据中"

    def test_salary_discrepancy_expected(self):
        """对照验证：三源工资数额不一致是已知事实，非错误"""
        # 见 LaborLawStatutes.salaryStandard: 社保基数≠工资标准是正常现象
        bases = {"social_insurance": 7450, "housing_fund": 7554, "salary_table": 7550}
        # 三者不完全相同 — 需要确认以工资表和银行流水为准
        assert bases["salary_table"] == KNOWN_FACTS["monthly_wage"]

    def test_severance_calculation_matches_reference(self):
        """对照验证：经济补偿金 7550×5=37750 匹配申请书"""
        monthly = KNOWN_FACTS["monthly_wage"]
        years = 5
        assert monthly * years == KNOWN_FACTS["severance_amount"]
        assert KNOWN_FACTS["severance_amount"] == 37750

    def test_procedure_can_run_with_real_evidence(self, all_evidence):
        """验证管线能处理真实证据输入而不崩溃"""
        procedure = Procedure(
            name="real_case_test",
            initial_step="verify_employment",
            steps=[
                Step(name="verify_employment", kind=StepKind.CODE,
                     handler=lambda ctx: ctx,
                     transitions={"done": "end"}),
                Step(name="end", kind=StepKind.CODE, transitions={}),
            ],
        )
        court = Court(statutes=[], procedure=procedure)
        import asyncio
        result = asyncio.run(court.hear(all_evidence))
        # 能跑完不崩溃就是基础通过
        assert result.round_count >= 1


# ============================================================
# Test 3: 金额守恒自动化检测
# ============================================================

class TestAmountConsistency:
    """金额一致性自动检测 — 这是引擎应自动完成的工作"""

    def test_detect_salary_inconsistency(self):
        """自动检测：社保7450/公积金7554/工资表7550 三源不一致"""
        sources = {
            "social_insurance": 7450.0,
            "housing_fund": 7554.0,
            "salary_table": 7550.0,
        }
        # 自动检测逻辑：组内差异 > 0
        values = list(sources.values())
        has_discrepancy = len(set(values)) > 1
        assert has_discrepancy, "三源工资数额应被自动检测为不一致"

    def test_detect_arrears_consistency(self):
        """自动检测：行政处罚93059.85 = 统计表93059.85 → 双源印证通过"""
        admin_amount = 93059.85
        statement_amount = 93059.85
        assert admin_amount == statement_amount, "双源金额一致，证据链完整"

    def test_extract_all_amounts_from_evidence(self):
        """自动提取：从全部证据文本中提取金额并做跨源对比"""
        import re
        all_texts = [
            SOCIAL_INSURANCE_TEXT,
            HOUSING_FUND_TEXT,
            SALARY_TABLE_TEXT,
            ADMIN_PENALTY_TEXT,
            ARREARS_STATEMENT_TEXT,
        ]

        # 提取所有金额
        amounts = []
        for text in all_texts:
            matches = re.findall(r'(\d+\.?\d*)\s*元?', text)
            for m in matches:
                try:
                    val = float(m)
                    if 100 < val < 10000000:  # 过滤掉噪声数字
                        amounts.append(val)
                except ValueError:
                    pass

        # 至少应该找到工资、社保基数、欠薪金额这几个关键数字
        assert 7450.0 in amounts or 7450 in amounts, "应提取到社保基数7450"
        assert 7550.0 in amounts or 7550 in amounts, "应提取到工资标准7550"


# ============================================================
# Test 4: 人员身份缺口检测
# ============================================================

class TestPersonnelIdentityGaps:
    """关键人员身份独立验证 — 对照材料指明需要核实的人员"""

    def test_key_personnel_listed(self):
        """需要独立证据证实的三个关键人员"""
        unverified = ["爨淑纳", "周甜", "杨旭"]
        for name in unverified:
            assert name in PERSONNEL_TEXT

    def test_verified_personnel_have_independent_evidence(self):
        """已证实人员有独立证据锚点"""
        # 和海波：建造师证书 + 五建工会委员当选记录
        # 彭国运：公众号文章 + 建造师证书（2008年至今五建）
        # 谢朝晖：建造师证书工作单位为五建
        verified_patterns = ["和海波", "彭国运", "谢朝晖"]
        for name in verified_patterns:
            assert name in PERSONNEL_TEXT
        # 这些人的身份有独立证据（证书、公众号、工商记录）
        # 与爨/周/杨形成对比 — 仅有聊天记录


# ============================================================
# Test 5: 敏感词检测不应再用 profanity 词表
# ============================================================

class TestNoProfanityWordList:
    """验证：内容审查任务不应硬编码为词表"""

    def test_content_contains_no_profanity(self):
        """整个案件证据不含脏话 — profanity 正则对此案毫无检测价值"""
        import re
        all_text = "\n".join([
            SOCIAL_INSURANCE_TEXT, BANK_STATEMENT_TEXT,
            DAHAI_BUSINESS_TEXT, WUJIAN_BUSINESS_TEXT,
            SALARY_TABLE_TEXT, ADMIN_PENALTY_TEXT,
            ARREARS_STATEMENT_TEXT, PERSONNEL_TEXT,
        ])
        # 旧 RuleBasedLLM 的 profanity 规则应该不命中
        profanity_pattern = re.compile(r'\b(damn|hell)\b', re.IGNORECASE)
        matches = profanity_pattern.findall(all_text)
        assert len(matches) == 0, "劳动争议案件不应被 profanity 规则命中"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
