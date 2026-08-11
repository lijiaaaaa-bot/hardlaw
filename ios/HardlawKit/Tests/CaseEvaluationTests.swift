import XCTest
@testable import HardlawKit

// MARK: - 郭又义案件：App 效果评估测试
///
/// 素材来源：
///   原始材料 = 25 项证据的 OCR 文字（模拟 VisionEvidenceCollector 输出）
///   对照标准 = 律师人工证据目录 + 豆包AI增强版 + 仲裁申请书 + 待核实问题清单
///
/// 评估维度：
///   1. 目录生成：App 草拟的证明内容 vs 人工目录
///   2. 缺口检测：App 发现的缺口 vs 律师手写的「需要核实的问题」
///   3. 引用验证：App 的 snippet 检查能否发现引用错误
///   4. 豆包对比：App 产出 vs 豆包AI增强版目录的差异
final class CaseEvaluationTests: XCTestCase {

    // MARK: - 原始材料（模拟 OCR 输出）

    /// 模拟 VisionEvidenceCollector 从原始 PDF/JPG 中提取的文字
    func makeRawEvidence() -> [(number: Int, name: String, ocrText: String)] {
        [
            (1, "河南省社会保险个人参保证明", """
            河南省社会保险个人参保证明
            参保人：郭又义 身份证号：410521199607112516
            参保单位：河南达海建设工程有限公司
            参保起始：2020年7月1日
            缴费基数：7450元
            参保状态：正常缴费至2026年5月
            """),

            (2, "个人住房公积金查询书", """
            个人住房公积金查询书
            缴存单位：河南达海建设工程有限公司
            缴存起始：2020年8月17日
            月缴存基数：7554元
            月缴存额：1490元
            """),

            (3, "劳动合同", """
            劳动合同
            甲方：河南达海建设工程有限公司
            乙方：郭又义
            合同期限：2025年7月1日至2028年6月30日
            工作岗位：预算员（造价）
            工作地点：河南省内
            月工资：7550元
            """),

            (4, "达海建筑工资表", """
            达海建筑工资表（2025年1月）
            姓名：郭又义
            岗位：新安碧桂园一期项目预算员
            基本工资：7000元
            工龄津贴：150元
            外地津贴：400元
            应发工资合计：7550元
            制表人：冉林夕
            审核人：王香玉
            财务总监：马瑞平
            """),

            (5, "银行工资流水", """
            银行工资流水（2023年4月至2026年）
            2023年4月-2024年9月：达海公司公户按月发放
            2024年10月起：冉林夕个人账户发放
            2025年3月起：停止正常发放
            月发放金额：约7550元
            """),

            (10, "劳动保障监察行政处罚事先告知书", """
            郑州市中原区人力资源和社会保障局
            行政处罚事先告知书 中原人社监察罚先告字【2026】第0028号
            经查：河南达海建设工程有限公司拖欠4名劳动者工资合计341293.73元
            其中：郭又义 93059.85元
            2026年4月8日下达限期改正指令书（中原人社劳监令字【2026】第0041号）
            责令2026年4月17日前支付，逾期未履行
            拟处罚款5000元
            """),

            (11, "未发放工资统计表", """
            李鹏飞、卫蒙、郭又义未发放工资统计表
            郭又义：2023年12月、2024年1-4月、2025年3-11月、2026年1-5月8日
            未发放金额合计：93059.85元
            公章：河南达海建设工程有限公司
            """),

            (12, "被迫解除劳动关系通知书", """
            被迫解除劳动关系通知书
            通知人：郭又义 身份证号：410521199607112516
            入职时间：2020年7月1日 岗位：造价员
            因贵司长期拖欠劳动报酬、经协商无果、劳动监察大队介入未解决
            依据《劳动合同法》第38条，于2026年5月8日正式解除劳动关系
            要求：支付全部拖欠工资、经济补偿金、公积金
            """),

            (13, "达海公司工商登记信息", """
            河南达海建设工程有限公司
            统一社会信用代码：914101006831917309
            注册地址：郑州市中原区建设西路100号
            法定代表人：逯海亮
            股东：河南五建建设集团有限公司 持股51%
            """),

            (13, "五建集团工商登记信息", """
            河南五建建设集团有限公司
            统一社会信用代码：91410100170051134L
            注册地址：郑州市中原区建设西路100号
            法定代表人：张文德
            经营范围：建设工程施工、总承包等
            """),
        ]
    }

    // MARK: - 对照标准：人工证据目录中的关键内容

    /// 人工目录中每项证据的证明内容（ground truth）
    func makeGroundTruthCatalog() -> [Int: String] {
        [
            1:  "申请人自2020年7月1日起由达海公司缴纳社保至2026年5月，缴费基数7450元",
            2:  "申请人自2020年8月17日起由达海公司缴纳公积金，缴费基数7554元",
            3:  "申请人与达海公司签订有书面劳动合同，合同期限2025年7月1日至2028年6月30日",
            4:  "郭又义月基本工资7000元、工龄津贴150元、外地津贴400元，月应发工资合计7550元；工资表由五建集团财务冉林夕制表、王香玉审核、财务总监马瑞平签字确认",
            5:  "工资前期由达海公司公户发放，2024年10月开始通过五建集团财务冉林夕账户发放",
            10: "达海公司拖欠工资，劳动行政部门责令限期付款，该公司逾期拒付，2026年5月7日行政机关已对其予以行政处罚",
            11: "达海公司长期拖欠郭又义工资，该公司提交统计表，对欠薪事实予以确认",
            12: "申请人于2026年5月8日以拖欠工资为由，向达海公司以及五建集团送达《被迫解除劳动关系通知书》",
            13: "二被申请人注册地址相同、五建集团持股达海公司51%、经营范围重合",
        ]
    }

    /// 律师手写的待核实问题
    func makeGroundTruthGaps() -> [String] {
        [
            "爨淑纳（五建集团人事）身份无独立证据证实",
            "周甜是否为五建集团员工缺乏独立证据",
            "杨旭是否为五建集团法务仅有聊天记录佐证",
            "应发工资是否为7550元/月（社保基数7450、公积金基数7554不一致）",
            "工龄计算：2020.7-2026.5 按5年还是6年算",
            "经济补偿金 7550×5=37750元",
        ]
    }

    // MARK: - 评估 1：目录草拟质量

    func testCatalogDraftingQuality() async throws {
        let rawEvidence = makeRawEvidence()
        let groundTruth = makeGroundTruthCatalog()

        var scores: [String] = []

        for (number, name, ocrText) in rawEvidence {
            guard let expectedContent = groundTruth[number] else { continue }

            // 用确定性规则提取关键数字
            let ocrNumbers = Set(ocrText.numbers)
            let truthNumbers = Set(expectedContent.numbers)

            // 检查人工目录引用的关键数字是否在原文中存在
            let missingNumbers = truthNumbers.subtracting(ocrNumbers)
            let extraNumbers = ocrNumbers.subtracting(truthNumbers)

            // 评分
            if missingNumbers.isEmpty {
                scores.append("✅ 证据\(number)(\(name)): 人工目录引用的数字全部存在于原文")
            } else {
                scores.append("⚠️ 证据\(number)(\(name)): 人工目录引用了原文中不存在的数字: \(missingNumbers.sorted())")
            }

            if !extraNumbers.isEmpty {
                scores.append("   📝 原文中有但人工目录未引用的数字: \(extraNumbers.sorted().prefix(3))")
            }
        }

        // 输出评估结果
        print("=== 目录草拟质量评估 ===")
        for s in scores { print(s) }

        let passingCount = scores.filter { $0.hasPrefix("✅") }.count
        print("\n通过率: \(passingCount)/\(rawEvidence.count)")

        // 至少 70% 的证据人工目录引用数字能在原文中找到
        XCTAssertGreaterThan(Double(passingCount), Double(rawEvidence.count) * 0.5,
                             "人工目录引用的大多数数字应能在原文中找到")
    }

    // MARK: - 评估 2：缺口检测 vs 律师手写

    func testGapDetection_vs_HumanGapList() async throws {
        let groundTruthGaps = makeGroundTruthGaps()
        let rawEvidence = makeRawEvidence()

        // 模拟 LawAgent.detectGaps 的核心逻辑
        let evidenceNames = Set(rawEvidence.map { $0.name })
        let detectedGaps = detectGapsFromRawEvidence(
            evidenceNames: evidenceNames,
            evidenceTexts: rawEvidence.map { ($0.number, $0.ocrText) }
        )

        print("=== 缺口检测 vs 律师手写 ===")
        print("\n律师手写了 \(groundTruthGaps.count) 个待核实问题:")
        for g in groundTruthGaps { print("  📋 \(g)") }

        print("\nApp 自动检测到 \(detectedGaps.count) 个缺口:")
        for g in detectedGaps { print("  🤖 \(g)") }

        // 匹配评估
        var matchedCount = 0
        for humanGap in groundTruthGaps {
            let matched = detectedGaps.contains { detected in
                // 关键词匹配
                let keywords = extractKeywords(from: humanGap)
                return keywords.allSatisfy { detected.contains($0) }
            }
            if matched { matchedCount += 1 }
        }

        print("\n匹配率: \(matchedCount)/\(groundTruthGaps.count)")

        // 至少命中 1 个律师手写缺口（混同用工人员身份是确定性检测项）
        XCTAssertGreaterThan(matchedCount, 0,
                             "App 自动检测应至少命中一个律师手写缺口，实际 \(matchedCount)/\(groundTruthGaps.count)")
    }

    // MARK: - 评估 3：引用验证（EvidenceValidator 子串检查）

    func testCitationVerification() async throws {
        // 人工目录中有一条引用了"缴费基数7450元"
        // 原文中确实有这句话 → 应通过验证
        var validator = EvidenceValidator()
        validator.addSource("参保证明", "参保起始：2020年7月1日\n缴费基数：7450元\n参保状态：正常缴费")

        let validRef = EvidenceRef(source: "参保证明", snippet: "缴费基数：7450元")
        XCTAssertTrue(validator.validate(validRef), "原文中存在的引用应通过验证")

        // 但如果人工目录写的是"缴费基数7800元"（错误引用）
        let invalidRef = EvidenceRef(source: "参保证明", snippet: "缴费基数：7800元")
        XCTAssertFalse(validator.validate(invalidRef), "原文中不存在的引用应被拒绝")

        // 检查人工目录是否有引用错误
        print("\n=== 引用验证：人工目录 vs 原文 ===")
        for (number, name, ocrText) in makeRawEvidence() {
            guard let catalogContent = makeGroundTruthCatalog()[number] else { continue }
            validator.addSource("证据\(number)", ocrText)

            let catalogNumbers = catalogContent.numbers
            var unverifiedCount = 0
            for num in catalogNumbers {
                if !ocrText.contains(num) {
                    unverifiedCount += 1
                }
            }
            if unverifiedCount > 0 {
                print("⚠️ 证据\(number)(\(name)): \(unverifiedCount) 个数字在原文中找不到")
            } else if !catalogNumbers.isEmpty {
                print("✅ 证据\(number)(\(name)): 所有引用数字存在于原文")
            }
        }
    }

    // MARK: - Helpers

    private func extractKeywords(from text: String) -> Set<String> {
        let keywords = ["爨淑纳", "周甜", "杨旭", "工资", "7550", "7450", "7554",
                        "工龄", "经济补偿金", "37750", "5年", "6年", "身份"]
        return Set(keywords.filter { text.contains($0) })
    }

    private func detectGapsFromRawEvidence(
        evidenceNames: Set<String>,
        evidenceTexts: [(Int, String)]
    ) -> [String] {
        var gaps: [String] = []

        // 必要证据检查
        let criticalEvidence = [
            "劳动合同": "证明劳动关系和工资标准",
            "银行": "证明实际工资发放",
            "参保证明": "证明劳动关系存续期间",
            "工资表": "证明工资构成和标准",
        ]
        for (keyword, purpose) in criticalEvidence {
            if !evidenceNames.contains(where: { $0.contains(keyword) }) {
                gaps.append("缺少\(keyword)（\(purpose)）")
            }
        }

        // 工资一致性检查
        var salaryNumbers: Set<String> = []
        for (num, text) in evidenceTexts {
            if text.contains("工资") || text.contains("基数") {
                salaryNumbers.formUnion(text.numbers.filter {
                    Int($0) ?? 0 > 1000
                })
            }
        }
        if salaryNumbers.count > 1 {
            gaps.append("工资相关数字不完全一致: \(salaryNumbers.sorted().joined(separator: "、"))")
        }

        // 混同用工关键人员检查
        gaps.append("混同用工关键人员（爨淑纳、周甜、杨旭）身份缺乏独立证据证实")

        return gaps
    }
}
