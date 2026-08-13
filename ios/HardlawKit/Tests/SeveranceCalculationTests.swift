import XCTest
@testable import HardlawApp

// MARK: - 经济补偿金计算（《劳动合同法》第47条）

/// 验证 <6 个月（不满六个月）时补偿 0.5 个月工资：
///   每满一年支付一个月工资；六个月以上不满一年按一年计算；
///   不满六个月支付半个月工资。
/// 覆盖意图解析 → 工资/工龄提取 → 补偿倍数 → 金额的完整链路。
final class SeveranceCalculationTests: XCTestCase {

    /// 构造一个含 OCR 文本的案件，走 IntentParser → IntentHandler 全链路。
    private func computeSeverance(ocrText: String, file: StaticString = #filePath, line: UInt = #line) -> IntentResult {
        let caseFile = CaseFile(caseName: "经济补偿金计算测试")
        caseFile.evidenceItems.append(
            EvidenceItem(number: 1, name: "劳动合同", sourceOCRText: ocrText)
        )
        let intent = IntentParser.parse("算补偿", stage: .drafting)
        XCTAssertEqual(intent.kind, .computeSeverance, "「算补偿」应解析为经济补偿金计算意图", file: file, line: line)
        let result = IntentHandler.handle(intent, caseFile: caseFile)
        XCTAssertTrue(result.success, "缺少任一要素时不应失败：\(result.message)", file: file, line: line)
        return result
    }

    /// 2 年 5 个月（不满六个月）→ 2.5 个月工资
    func testTwoYearsFiveMonths() {
        let result = computeSeverance(ocrText: "月工资 8000 元，工作 2.4 年")
        XCTAssertTrue(result.message.contains("× 2.50 个月"), "应输出 2.5 个月：\(result.message)")
        XCTAssertTrue(result.message.contains("= 20000 元"), "8000 × 2.5 = 20000：\(result.message)")
    }

    /// 5 年 10 个月（六个月以上不满一年按一年）→ 6 个月工资
    func testFiveYearsTenMonths() {
        let result = computeSeverance(ocrText: "月工资 8000 元，工龄 5.8 年")
        XCTAssertTrue(result.message.contains("× 6 个月"), "应输出 6 个月：\(result.message)")
        XCTAssertTrue(result.message.contains("= 48000 元"), "8000 × 6 = 48000：\(result.message)")
    }

    /// 3 年 3 个月（不满六个月）→ 3.5 个月工资
    func testThreeYearsThreeMonths() {
        let result = computeSeverance(ocrText: "月工资 8000 元，工作 3.25 年")
        XCTAssertTrue(result.message.contains("× 3.50 个月"), "应输出 3.5 个月：\(result.message)")
        XCTAssertTrue(result.message.contains("= 28000 元"), "8000 × 3.5 = 28000：\(result.message)")
    }

    /// 不满六个月且不足整年（0 年 4.8 个月）→ 0.5 个月工资
    func testLessThanSixMonths() {
        let result = computeSeverance(ocrText: "月工资 8000 元，工作 0.4 年")
        XCTAssertTrue(result.message.contains("× 0.50 个月"), "应输出 0.5 个月：\(result.message)")
        XCTAssertTrue(result.message.contains("= 4000 元"), "8000 × 0.5 = 4000：\(result.message)")
    }

    /// 回归保护：整年不受影响，满 5 年 → 5 个月工资（不是 5.5）
    func testExactWholeYearsUnaffected() {
        let result = computeSeverance(ocrText: "月工资 8000 元，工作 5 年")
        XCTAssertTrue(result.message.contains("× 5 个月"), "满 5 年应输出 5 个月：\(result.message)")
        XCTAssertTrue(result.message.contains("= 40000 元"), "8000 × 5 = 40000：\(result.message)")
        XCTAssertFalse(result.message.contains("5.5"), "整年不应加上半个月：\(result.message)")
    }
}
