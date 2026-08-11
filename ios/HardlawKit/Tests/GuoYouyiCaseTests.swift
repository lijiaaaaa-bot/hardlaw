import XCTest
@testable import HardlawKit

/// 郭又义劳动争议仲裁案 — 真实案件证据数据 + 确定性验证测试。
///
/// 不再使用 MockLLM。所有测试使用 RuleBasedLLM 或 nil LLM，
/// 验证的是硬约束引擎的正确性，而非模拟 AI 行为。
final class GuoYouyiCaseTests: XCTestCase {

    // MARK: - 真实案件证据数据

    /// 模拟 VisionEvidenceCollector 从原始 PDF/JPG 中提取的文字
    func makeCaseEvidence() -> [String: JSONValue] {
        [
            "objective": .string("审查郭又义劳动争议仲裁案证据链完整性，识别需要补充的证据"),
            "social_insurance": .string("""
            河南省社会保险个人参保证明
            参保人：郭又义 身份证号：410521199607112516
            参保单位：河南达海建设工程有限公司
            参保起始：2020年7月1日
            缴费基数：7450元
            参保状态：正常缴费
            """),
            "labor_contract": .string("""
            劳动合同
            甲方：河南达海建设工程有限公司
            乙方：郭又义
            合同期限：2025年7月1日至2028年6月30日
            工作岗位：预算员（造价）
            """),
            "salary_table": .string("""
            达海建筑工资表（2025年1月）
            姓名：郭又义
            基本工资：7000元 工龄津贴：150元 外地津贴：400元
            应发工资合计：7550元
            制表人：冉林夕（五建集团财务） 财务总监：马瑞平
            """),
            "bank_statement": .string("""
            银行工资流水（2023年4月至2026年）
            2023年4月-2024年9月：达海公司公户发放
            2024年10月起：冉林夕个人账户发放
            月发放金额：约7550元
            """),
            "administrative_penalty": .string("""
            郑州市中原区人力资源和社会保障局
            行政处罚事先告知书 中原人社监察罚先告字【2026】第0028号
            经查：河南达海建设工程有限公司拖欠4名劳动者工资合计341293.73元
            其中：郭又义 93059.85元
            """),
            "arrears_statement": .string("""
            未发放工资统计表
            郭又义：2023年12月、2024年1-4月、2025年3-11月、2026年1-5月8日
            合计未发放金额：93059.85元 盖章：河南达海建设工程有限公司
            """),
            "business_registration": .string("""
            河南达海建设工程有限公司 统一社会信用代码：914101006831917309
            注册地址：郑州市中原区建设西路100号
            股东：河南五建建设集团有限公司 持股51%
            """),
            "personnel_overlap": .string("""
            混同用工证据汇总：和海波为达海总经理同时为五建工会委员
            彭国运为五建监事同时负责达海项目管理
            达海印章由五建集团党政办管理
            ⚠️ 待核实：爨淑纳（五建人事）周甜 杨旭 缺乏独立证据
            """),
            "termination_notice": .string("""
            被迫解除劳动关系通知书
            通知人：郭又义 因贵司长期拖欠劳动报酬
            依据《劳动合同法》第38条 于2026年5月8日正式解除劳动关系
            """),
            "housing_fund": .string("""
            个人住房公积金查询书
            缴存单位：河南达海建设工程有限公司
            月缴存基数：7554元
            """),
        ]
    }

    // MARK: - CODE 步测试（纯确定性，无 LLM）

    /// 测试经济补偿金 CODE 步计算
    func testSeveranceCalculationCODE() async throws {
        let procedure = try Procedure(
            name: "severance_check",
            steps: [
                Step(name: "calculate", kind: .code,
                     handler: { ctx in
                         // 郭又义案：参保 2020-07-01 至解除 2026-05-08 = 5年10个月
                         // 依《劳动合同法》第47条：六个月以上不满一年按一年 → 6个月
                         let monthly = 7550
                         let years = 6
                         ctx.metadata["result"] = JSONValue.number(Double(monthly * years))
                         ctx.metadata["formula"] = JSONValue.string("\(monthly) × \(years)")
                     },
                     transitions: [:]),
            ]
        )
        let court = Court(statutes: [], procedure: procedure, llm: nil)
        let result = await court.hear(caseData: [
            "monthly_wage": .string("7550"),
            "work_years": .string("5"),
        ])
        XCTAssertEqual(result.finalDisposition, .terminalStep)
        XCTAssertEqual(result.roundCount, 1)
        // NOTE: 金额验证见 SeveranceCalculationTests（经济补偿金计算测试）
        // 本测试验证 CODE 步正常执行，非金额计算正确性
    }

    // MARK: - 证据验证测试（纯确定性）

    /// 测试 EvidenceValidator 子串检查 — 真实 snippet 通过，幻觉 snippet 被拒
    func testEvidenceSnippetVerification() async throws {
        var validator = EvidenceValidator()
        validator.addSource("labor_contract", "合同期限：2025年7月1日至2028年6月30日")
        validator.addSource("administrative_penalty", "郭又义 93059.85元")

        // Valid: exact snippet exists
        XCTAssertTrue(validator.validate(EvidenceRef(source: "administrative_penalty", snippet: "郭又义 93059.85元")))
        // Invalid: LLM hallucinated a different amount
        XCTAssertFalse(validator.validate(EvidenceRef(source: "administrative_penalty", snippet: "欠薪总额 150000 元")))
        // Invalid: source not registered
        XCTAssertFalse(validator.validate(EvidenceRef(source: "court_judgment", snippet: "驳回")))
    }
}
