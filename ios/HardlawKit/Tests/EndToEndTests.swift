import XCTest
@testable import HardlawKit
@testable import HardlawApp

// MARK: - 端到端全流程验证

/// 端到端验证测试：用郭又义案件 10 份真实 OCR 证据文本，走完整业务流水线：
///   创建 CaseFile（OCR 文本预置，模拟 Vision/Paddle 输出）
///   → CourtViewModel.makeReviewGoal() 生成审查目标
///   → runGoalSteps() 顺序执行全部步骤（目录生成/引用验证/缺口检测）
///   → 校验 goal 完成、全部步骤落终态、检测到证据缺口
///   → ExcelExport 导出 CSV 并校验文件有效
///
/// LLM 只使用 MockLLM（确定性脚本，复用 GuoYouyiCaseTests 的案件判定），
/// 不加载 MLX 模型、不访问网络，保证完全离线可跑。
@MainActor
final class EndToEndTests: XCTestCase {

    // MARK: - Helpers

    /// 访问 GuoYouyiCaseTests 的真实案件证据数据（OCR 文本）。
    /// 返回按证据目录固定顺序排列的 10 份证据：
    /// (name: 证据类型 key, text: OCR 原文)。
    func makeCaseEvidence() -> [(name: String, text: String)] {
        let source = GuoYouyiCaseTests()
        let raw = source.makeCaseEvidence()
        let order = [
            "social_insurance", "labor_contract", "salary_table", "bank_statement",
            "administrative_penalty", "arrears_statement", "business_registration",
            "personnel_overlap", "termination_notice", "housing_fund",
        ]
        return order.compactMap { key in
            guard let text = raw[key]?.stringValue else { return nil }
            return (name: key, text: text)
        }
    }

    /// 从 GuoYouyiCaseTests 复用案件的 MockLLM 判定脚本。
    /// 顺序与 goal 步骤的 judge 调用严格对应：
    ///   10 × 目录生成（每项证据一条通过响应）
    ///   + 1 × 劳动关系成立（通过）
    ///   + 1 × 工资标准核实（发现不一致 gap）
    ///   + 1 × 混同用工判定（发现 3 个人员身份 gap）
    static func makeMockResponses() -> [String] {
        let source = GuoYouyiCaseTests()
        var responses: [String] = []
        responses.append(contentsOf: Array(repeating: source.makeEmploymentPassResponse(), count: 10))
        responses.append(source.makeEmploymentPassResponse())
        responses.append(source.makeSalaryGapResponse())
        responses.append(source.makeMixedEmploymentGapResponse())
        return responses
    }

    // MARK: - 端到端全流程

    func testEndToEndFullPipeline() async throws {
        // 1. 创建案件档案，预置 10 份真实案件证据（OCR 文本，模拟 Vision/Paddle 输出）
        let cf = CaseFile(caseName: "郭又义劳动争议案", applicant: "郭又义",
                          respondent: "河南达海建设工程有限公司")
        for (name, text) in makeCaseEvidence() {
            let item = EvidenceItem(number: cf.evidenceItems.count + 1,
                                    name: name,
                                    sourceOCRText: text)
            cf.evidenceItems.append(item)
        }
        XCTAssertEqual(cf.evidenceItems.count, 10, "应预置 10 份真实案件证据")
        XCTAssertEqual(cf.evidenceItems.map(\.number), Array(1...10), "证据编号应连续 1-10")
        XCTAssertFalse(cf.evidenceItems.contains { $0.sourceOCRText.isEmpty },
                       "每份证据都应带 OCR 文本")

        cf.claims = [ClaimItem(claimNumber: 1, content: "支付拖欠工资", legalBasis: "《劳动合同法》第85条")]

        // 2. 创建 CourtViewModel，注入 MockLLM（离线、确定性）
        let vm = CourtViewModel(caseFile: cf)
        vm.llm = MockLLM(responses: Self.makeMockResponses())

        // 3. 生成审查 goal 并执行全部步骤
        let goal = vm.makeReviewGoal()
        XCTAssertFalse(goal.steps.isEmpty, "审查 goal 应包含至少一个步骤")
        XCTAssertEqual(goal.status, .pending, "goal 初始应为 pending")

        let start = Date()
        await vm.runGoalSteps(goal)
        let elapsed = Date().timeIntervalSince(start)

        // 4. 校验：goal 完成、全部步骤完成、检测到证据缺口
        XCTAssertEqual(vm.goal?.status, .done, "goal 应完成，实际: \(vm.goal?.status.rawValue ?? "nil")")
        let steps = vm.goal?.steps ?? []
        XCTAssertFalse(steps.isEmpty, "goal 应包含步骤")
        for step in steps {
            XCTAssertEqual(step.status, .done,
                           "步骤「\(step.name)」应完成，实际: \(step.status.rawValue)")
        }
        XCTAssertEqual(vm.goal?.progress, 1.0, "全部步骤落终态后进度应为 100%")

        // 期望缺口：工资标准不一致 1 个 + 混同用工关键人员身份 3 个 = 4 个
        XCTAssertEqual(cf.gaps.count, 4,
                       "应检测到 4 个证据缺口，实际 \(cf.gaps.count) 个：\(cf.gaps.map(\.description))")
        XCTAssertTrue(cf.gaps.contains { $0.description.contains("三份证据工资数额不一致") },
                      "应包含工资标准不一致缺口")
        XCTAssertTrue(cf.gaps.contains { $0.description.contains("爨淑纳") },
                      "应包含关键人员身份未核实缺口")

        // 5. 导出 CSV 并校验文件有效（非空、含表头、含缺口内容）
        let url = try XCTUnwrap(ExcelExport.exportFullReport(cf), "CSV 导出应成功")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 0, "CSV 文件应非空")
        let csv = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(csv.isEmpty, "CSV 内容应非空")
        XCTAssertTrue(csv.contains("组别"), "CSV 应包含证据目录表头")
        XCTAssertTrue(csv.contains("待核实清单"), "CSV 应包含待核实清单章节")
        XCTAssertTrue(csv.contains("三份证据工资数额不一致"),
                      "CSV 应包含检测到的缺口内容")

        // 6. 摘要输出
        print("=== 端到端全流程验证：\(cf.caseName) ===")
        print("证据项: \(cf.evidenceItems.count) 份（OCR 文本预置，模拟 Vision/Paddle 输出）")
        print("Goal 步骤: \(steps.count) 个（\(steps.map(\.name).joined(separator: " / "))）")
        print("Goal 状态: \(vm.goal?.status.rawValue ?? "")")
        print("发现证据缺口: \(cf.gaps.count) 个")
        for gap in cf.gaps {
            print("  - [\(gap.severity.rawValue)] \(gap.description)")
        }
        print("CSV 导出: \(url.lastPathComponent)（\(fileSize) 字节）")
        print("耗时: \(String(format: "%.2f", elapsed)) 秒")
    }
}
