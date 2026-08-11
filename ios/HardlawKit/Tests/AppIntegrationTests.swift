import XCTest
@testable import HardlawKit
@testable import HardlawApp

// MARK: - App 层集成测试

/// 覆盖主路径：创建案件 → 添加证据 → goal 执行 → 结果验证。
/// 全部使用内存 mock 数据（OCR 文本直接写入），不依赖真实文件。
@MainActor
final class AppIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// 构造一个带仲裁请求的空案件。
    private func makeCase() -> CaseFile {
        let cf = CaseFile(caseName: "郭又义劳动争议案", applicant: "郭又义",
                          respondent: "河南达海建设工程有限公司")
        cf.claims.append(ClaimItem(claimNumber: 1, content: "支付拖欠工资 93059.85 元"))
        return cf
    }

    // MARK: - 1. 创建案件 → 添加证据 → 验证证据数与阶段

    func testCreateCaseAddEvidence() {
        let cf = makeCase()
        XCTAssertEqual(cf.evidenceItems.count, 0)
        XCTAssertEqual(cf.stage, .drafting, "空案件应处于起草阶段")

        cf.evidenceItems.append(EvidenceItem(
            group: "劳动关系", number: 1, name: "劳动合同",
            proofContent: "合同期限：2025年7月1日至2028年6月30日，月工资：7550元",
            sourceOCRText: "劳动合同 甲方：河南达海 乙方：郭又义 月工资：7550元"))
        cf.evidenceItems.append(EvidenceItem(
            group: "欠薪", number: 2, name: "银行工资流水",
            proofContent: "月发放金额：约7550元",
            sourceOCRText: "2024年10月起：冉林夕个人账户发放 月发放金额：约7550元"))

        XCTAssertEqual(cf.evidenceItems.count, 2, "添加 2 份证据后计数应为 2")
        XCTAssertEqual(cf.evidenceItems[0].proofContent, "合同期限：2025年7月1日至2028年6月30日，月工资：7550元")
        XCTAssertEqual(cf.evidenceItems[1].sourceOCRText, "2024年10月起：冉林夕个人账户发放 月发放金额：约7550元")
        // 证据齐备、无缺口、未人工确认 → 目录审查阶段
        XCTAssertEqual(cf.stage, .catalogReview, "证据齐备后应进入目录审查阶段")
    }

    // MARK: - 2. Goal 构造：makeReviewGoal 产出非空步骤

    func testMakeReviewGoalProducesNonEmptySteps() {
        let cf = makeCase()
        cf.evidenceItems.append(EvidenceItem(number: 1, name: "劳动合同",
                                             proofContent: "月工资：7550元"))
        cf.evidenceItems.append(EvidenceItem(number: 2, name: "达海建筑工资表",
                                             proofContent: "应发工资合计：7550元"))
        let vm = CourtViewModel(caseFile: cf)

        let goal = vm.makeReviewGoal()

        XCTAssertFalse(goal.steps.isEmpty, "审查 goal 应包含至少一个步骤")
        // 证据均有证明内容 → 不插入目录生成步骤；两条工资证据 → 追加一致性检查
        XCTAssertEqual(goal.steps.map(\.kind), [.verifyCitations, .detectGaps, .checkConsistency])
        XCTAssertEqual(goal.steps[0].name, "验证引用出处")
    }

    // MARK: - 3. Goal 执行：runGoal 按序执行全部步骤且不崩溃

    func testRunGoalExecutesAllSteps() async {
        let cf = makeCase()
        cf.evidenceItems.append(EvidenceItem(
            number: 1, name: "劳动合同",
            proofContent: "合同期限：2025年7月1日至2028年6月30日，月工资：7550元",
            sourceOCRText: "劳动合同 甲方：河南达海建设工程有限公司 乙方：郭又义 月工资：7550元"))
        let vm = CourtViewModel(caseFile: cf)

        let goal = vm.makeReviewGoal()
        XCTAssertFalse(goal.steps.isEmpty)
        await vm.runGoalSteps(goal)

        XCTAssertEqual(vm.goal?.status, .done, "全部步骤完成后 goal 应为 done")
        for step in vm.goal?.steps ?? [] {
            XCTAssertTrue(step.status == .done || step.status == .failed,
                          "步骤「\(step.name)」应有终态，实际 \(step.status.rawValue)")
        }
        XCTAssertFalse(vm.isProcessing, "goal 执行完毕应复位处理中状态")
        XCTAssertEqual(vm.goal?.progress, 1.0, "全部步骤到达终态后进度应为 100%")
    }

    // MARK: - 4. Verdict 落盘：applyVerdicts 不重复追加 gap

    func testApplyVerdictsDoesNotDuplicateGaps() {
        let cf = makeCase()
        let vm = CourtViewModel(caseFile: cf)
        let findings = [Finding(kind: "gap", location: "content:1", detail: "缺少劳动合同")]
        let verdict = Verdict(finding: "missing_contract", refuted: true, confidence: .high,
                              blocking: false, findings: findings,
                              reasoning: "缺少劳动合同，无法确认劳动关系")
        let result = CaseResult(caseId: "t", verdicts: [verdict, verdict, verdict],
                                finalDisposition: .rejected, reason: "r", roundCount: 1)

        // 同一结果内出现 3 次相同 gap → 只追加 1 个
        vm.applyVerdicts(result)
        XCTAssertEqual(cf.gaps.count, 1, "同一结果内的相同 gap 不应重复追加")
        XCTAssertEqual(cf.gaps[0].description, "缺少劳动合同")

        // 再次应用相同结果 → 仍然不重复
        vm.applyVerdicts(result)
        XCTAssertEqual(cf.gaps.count, 1, "重复应用相同结果不应追加重复 gap")
    }

    // MARK: - 5. verifyCitations goal 步骤正常完成（非红叉）

    func testVerifyCitationsGoalStepCompletes() async {
        let cf = makeCase()
        cf.evidenceItems.append(EvidenceItem(
            number: 1, name: "劳动合同",
            proofContent: "合同期限：2025年7月1日至2028年6月30日，月工资：7550元",
            sourceOCRText: "合同期限：2025年7月1日至2028年6月30日 月工资：7550元"))
        let vm = CourtViewModel(caseFile: cf)
        let goal = Goal(description: "验证引用", steps: [
            GoalStep(name: "验证引用出处", detail: "逐字核对原文", kind: .verifyCitations)
        ])

        await vm.runGoalSteps(goal)

        XCTAssertEqual(vm.goal?.steps.first?.status, .done,
                       "verifyCitations 步骤应正常完成，而非失败")
        XCTAssertEqual(vm.goal?.status, .done)
        XCTAssertFalse(vm.goal?.steps.first?.resultSummary.isEmpty ?? true,
                       "完成的步骤应带有结果摘要")
    }

    // MARK: - 6. 经济补偿金计算正确性（5年10个月 → 6 个月工资）

    func testSeveranceCalculationCorrectness() {
        let cf = CaseFile(caseName: "经济补偿金计算")
        cf.evidenceItems.append(EvidenceItem(
            number: 1, name: "劳动合同",
            sourceOCRText: "月工资 7550 元，工作 5.8 年"))

        let intent = IntentParser.parse("算经济补偿", stage: cf.stage)
        XCTAssertEqual(intent.kind, .computeSeverance)
        let result = IntentHandler.handle(intent, caseFile: cf)

        XCTAssertTrue(result.success, "应能完成经济补偿金计算：\(result.message)")
        XCTAssertTrue(result.message.contains("× 6 个月"),
                      "5年10个月应按 6 个月工资计算：\(result.message)")
        XCTAssertTrue(result.message.contains("= 45300 元"),
                      "7550 × 6 = 45300：\(result.message)")
    }

    // MARK: - 7. 证据齐备 → RuleBasedLLM 模板推理不得产生假缺口

    func testCompleteEvidenceProducesNoFalseGaps() async {
        // 社保 + 合同 + 公积金 证据齐备：OCR 原文包含全部关键词
        let cf = makeCase()
        cf.evidenceItems.append(EvidenceItem(
            number: 1, name: "劳动合同",
            proofContent: "合同期限：2025年7月1日至2028年6月30日，月工资：7550元",
            sourceOCRText: "劳动合同 甲方：河南达海建设工程有限公司 乙方：郭又义 月工资：7550元"))
        cf.evidenceItems.append(EvidenceItem(
            number: 2, name: "社会保险参保证明",
            proofContent: "参保单位：河南达海建设工程有限公司，参保起始：2020年7月1日",
            sourceOCRText: "河南省社会保险个人参保证明 参保人：郭又义 参保单位：河南达海建设工程有限公司 参保起始：2020年7月1日"))
        cf.evidenceItems.append(EvidenceItem(
            number: 3, name: "住房公积金缴存证明",
            proofContent: "缴存单位：河南达海建设工程有限公司",
            sourceOCRText: "个人住房公积金查询书 缴存单位：河南达海建设工程有限公司"))

        let vm = CourtViewModel(caseFile: cf)
        let goal = vm.makeReviewGoal()
        XCTAssertFalse(goal.steps.isEmpty, "审查 goal 应包含至少一个步骤")

        await vm.runGoalSteps(goal)

        XCTAssertEqual(vm.goal?.status, .done, "goal 应正常完成")
        // 证据齐备时 regex 命中只是"关键词存在"，不是"证据缺失"——
        // 模板推理（Rule-based detection）不得落成缺口（Bug 1 回归）
        XCTAssertTrue(cf.gaps.isEmpty,
                      "证据齐备时不应产生假缺口，实际产生：\(cf.gaps.map { "\($0.description)@\($0.relatedClaim)" })")
    }
}
