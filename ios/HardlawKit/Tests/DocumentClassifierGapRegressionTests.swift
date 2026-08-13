import XCTest
@testable import HardlawKit

/// DocumentClassifier 已修复 gap 的回归测试。
///
/// 每个方法对应 `docs/DocumentClassifier-gaps.md` 中的一个 gap id，
/// 用真实分类器输入固化修复行为，防止规则回退。
final class DocumentClassifierGapRegressionTests: XCTestCase {

    // MARK: - G1 文件名权重(chatRecord「微信」×3 → ×1)

    /// G1a: 纯日期 OCR 不应因文件名含「微信」被误判为 chatRecord。
    func testG1aWeChatImageFilenameWithDateIsNotChatRecord() {
        let category = DocumentClassifier.classify(
            fileName: "微信图片_20260511142513.jpg",
            ocrText: "2026/05/11 14:25"
        )
        XCTAssertNotEqual(category, .chatRecord, "G1a: 纯日期不应被「微信」文件名误判为聊天记录")
    }

    /// G1b: 纯数字 OCR 不应因文件名含「微信」被误判为 chatRecord。
    func testG1bWeChatImageFilenameWithNumbersIsNotChatRecord() {
        let category = DocumentClassifier.classify(
            fileName: "微信图片_20260511142513.jpg",
            ocrText: "7554\n7450"
        )
        XCTAssertNotEqual(category, .chatRecord, "G1b: 纯数字不应被「微信」文件名误判为聊天记录")
    }

    /// G1c: 同一「微信图片」文件名 + 工资表内容，应识别为 salaryTable。
    func testG1cWeChatImageFilenameWithWageTableContentIsSalaryTable() {
        let category = DocumentClassifier.classify(
            fileName: "微信图片_20260511142513.jpg",
            ocrText: "姓名 郭又义 应发 7554 实发 7450"
        )
        XCTAssertEqual(category, .salaryTable, "G1c: 工资表内容应压过「微信」文件名信号")
    }

    /// G1d: 文件名同时含「微信」与「聊天记录」时仍应为 chatRecord。
    func testG1dWeChatChatRecordFilenameIsChatRecord() {
        let category = DocumentClassifier.classify(
            fileName: "微信聊天记录.pdf",
            ocrText: "申请人：好的 明天见 王经理：可以"
        )
        XCTAssertEqual(category, .chatRecord, "G1d: 强聊天文件名应保留 chatRecord")
    }

    // MARK: - G2 解除/行政处罚消歧

    /// G2a: 第39条辞退 → dismissalNotice。
    func testG2aUnilateralDismissalIsDismissalNotice() {
        let category = DocumentClassifier.classify(
            fileName: "解除通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第39条 严重违反规章制度 予以辞退"
        )
        XCTAssertEqual(category, .dismissalNotice, "G2a: 第39条辞退应识别为单方解除")
    }

    /// G2b: 第38条被迫解除 → terminationNotice。
    func testG2bForcedTerminationIsTerminationNotice() {
        let category = DocumentClassifier.classify(
            fileName: "解除通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第38条 未足额支付劳动报酬"
        )
        XCTAssertEqual(category, .terminationNotice, "G2b: 第38条被迫解除应识别为被迫解除通知书")
    }

    /// G2c: 责令改正决定书 → administrativeDecision。
    func testG2cOrderToCorrectIsAdministrativeDecision() {
        let category = DocumentClassifier.classify(
            fileName: "劳动保障监察责令改正决定书.pdf",
            ocrText: "劳动保障监察责令改正决定书\n责令限期支付拖欠工资"
        )
        XCTAssertEqual(category, .administrativeDecision, "G2c: 责令改正决定书应识别为行政责令决定")
    }

    /// G2d: 行政处罚决定书 → penaltyNotice。
    func testG2dAdministrativePenaltyIsPenaltyNotice() {
        let category = DocumentClassifier.classify(
            fileName: "行政处罚决定书.pdf",
            ocrText: "行政处罚决定书\n依据《劳动保障监察条例》处以罚款"
        )
        XCTAssertEqual(category, .penaltyNotice, "G2d: 行政处罚决定书应识别为行政处罚文书")
    }

    // MARK: - G3 社保 vs 公积金

    /// G3a: 参保证明 → socialInsurance。
    func testG3aSocialInsuranceCertificateIsSocialInsurance() {
        let category = DocumentClassifier.classify(
            fileName: "参保证明.pdf",
            ocrText: "河南省社会保险个人参保证明\n参保人：郭又义\n缴费基数 5000"
        )
        XCTAssertEqual(category, .socialInsurance, "G3a: 参保证明应识别为社保证据")
    }

    /// G3b: 住房公积金查询书 → housingFund。
    func testG3bHousingFundQueryIsHousingFund() {
        let category = DocumentClassifier.classify(
            fileName: "个人住房公积金查询书.pdf",
            ocrText: "个人住房公积金查询书\n缴存额 1490\n缴存单位 达海公司"
        )
        XCTAssertEqual(category, .housingFund, "G3b: 住房公积金查询书应识别为公积金证据")
    }

    // MARK: - G4 全角数字(OCR 常见全角)

    /// G4a: 全角「第３８条」+ 文件名「被迫解除」→ terminationNotice。
    func testG4aFullWidth38ForcedTerminationIsTerminationNotice() {
        let category = DocumentClassifier.classify(
            fileName: "被迫解除劳动关系通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第３８条 未足额支付劳动报酬"
        )
        XCTAssertEqual(category, .terminationNotice, "G4a: 全角第38条 + 被迫解除应识别为被迫解除通知书")
    }

    /// G4b: 全角「第３９条」+ 文件名「辞退」→ dismissalNotice。
    func testG4bFullWidth39DismissalIsDismissalNotice() {
        let category = DocumentClassifier.classify(
            fileName: "辞退通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第３９条 严重违反规章制度"
        )
        XCTAssertEqual(category, .dismissalNotice, "G4b: 全角第39条 + 辞退应识别为单方解除")
    }

    /// G4c: 纯全角条文号(无 marker 词)——条文号是唯一定类信号。
    /// 修复前依赖平局先到者胜的偶然正确;归一化后确定性成立。
    func testG4cFullWidth38PureArticleIsTerminationNotice() {
        let category = DocumentClassifier.classify(
            fileName: "解除通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第３８条"
        )
        XCTAssertEqual(category, .terminationNotice, "G4c: 纯全角第38条应识别为被迫解除通知书")
    }

    /// G4d: 纯全角「第３９条」→ dismissalNotice(无 marker 词)。
    func testG4dFullWidth39PureArticleIsDismissalNotice() {
        let category = DocumentClassifier.classify(
            fileName: "解除通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第３９条"
        )
        XCTAssertEqual(category, .dismissalNotice, "G4d: 纯全角第39条应识别为单方解除")
    }

    // MARK: - G5-G10 关键词缺口(对齐豆包基准, top-3 命中语义)

    /// G5: 建造师证书查询 → top-3 含 workHistory。
    func testG5BuilderCertificateQueryContainsWorkHistoryInTopN() {
        let top = DocumentClassifier.classifyTopN(
            fileName: "证据18、谢朝晖建造师证书查询结果.pdf",
            ocrText: "建造师证书查询结果\n姓名 谢朝晖 专业 建筑工程",
            n: 3
        )
        let names = top.map { $0.rawValue }.joined(separator: " / ")
        XCTAssertTrue(top.contains(.workHistory), "G5: 建造师证书查询应命中 workHistory，实际 top-3: \(names)")
    }

    /// G6: 聘任证明 → top-3 含 workHistory。
    func testG6AppointmentCertificateContainsWorkHistoryInTopN() {
        let top = DocumentClassifier.classifyTopN(
            fileName: "聘任证明.pdf",
            ocrText: "聘任证明\n兹聘任郭又义为预算员",
            n: 3
        )
        let names = top.map { $0.rawValue }.joined(separator: " / ")
        XCTAssertTrue(top.contains(.workHistory), "G6: 聘任证明应命中 workHistory，实际 top-3: \(names)")
    }

    /// G7: 项目发票 → top-3 含 financialOverlap。
    func testG7ProjectInvoiceContainsFinancialOverlapInTopN() {
        let top = DocumentClassifier.classifyTopN(
            fileName: "证据23、达海项目发票.pdf",
            ocrText: "河南增值税发票\n价税合计 50000",
            n: 3
        )
        let names = top.map { $0.rawValue }.joined(separator: " / ")
        XCTAssertTrue(top.contains(.financialOverlap), "G7: 发票应命中 financialOverlap，实际 top-3: \(names)")
    }

    /// G8: 证书/公众号文章 → top-3 含 other。
    func testG8CertificateAndArticleContainsOtherInTopN() {
        let top = DocumentClassifier.classifyTopN(
            fileName: "证据15、彭国运证书、五建集团公众号文章.pdf",
            ocrText: "五建集团公众号文章\n员工风采",
            n: 3
        )
        let names = top.map { $0.rawValue }.joined(separator: " / ")
        XCTAssertTrue(top.contains(.other), "G8: 证书/公众号文章应命中 other，实际 top-3: \(names)")
    }

    /// G9: 会议纪要 → top-3 含 other。
    func testG9MeetingMinutesContainsOtherInTopN() {
        let top = DocumentClassifier.classifyTopN(
            fileName: "证据16、会议纪要.pdf",
            ocrText: "会议纪要\n参会人员",
            n: 3
        )
        let names = top.map { $0.rawValue }.joined(separator: " / ")
        XCTAssertTrue(top.contains(.other), "G9: 会议纪要应命中 other，实际 top-3: \(names)")
    }

    /// G10: 补充协议/付款单据 → top-3 含 other。
    func testG10SupplementalAgreementAndPaymentVoucherContainsOtherInTopN() {
        let top = DocumentClassifier.classifyTopN(
            fileName: "证据17、补充协议、付款单据.pdf",
            ocrText: "补充协议\n付款单据",
            n: 3
        )
        let names = top.map { $0.rawValue }.joined(separator: " / ")
        XCTAssertTrue(top.contains(.other), "G10: 补充协议/付款单据应命中 other，实际 top-3: \(names)")
    }

    // MARK: - R1-R4 基础回归

    /// R1: 劳动合同 → laborContract。
    func testR1LaborContractIsLaborContract() {
        let category = DocumentClassifier.classify(
            fileName: "证据3、劳动合同.pdf",
            ocrText: "劳动合同\n甲方：河南达海建设工程有限公司\n乙方：郭又义\n月工资：7550元"
        )
        XCTAssertEqual(category, .laborContract, "R1: 劳动合同应识别为书面劳动合同")
    }

    /// R2: 银行工资流水 → bankStatement。
    func testR2BankSalaryStatementIsBankStatement() {
        let category = DocumentClassifier.classify(
            fileName: "证据5、银行工资表流水.pdf",
            ocrText: "银行交易明细\n2025年1月 工资 7550元\n付款方：冉林夕"
        )
        XCTAssertEqual(category, .bankStatement, "R2: 银行工资流水应识别为银行流水")
    }

    /// R3: 无信号文件 → nil。
    func testR3UnknownFileIsNil() {
        let category = DocumentClassifier.classify(
            fileName: "unknown_file.mp4",
            ocrText: "binary content"
        )
        XCTAssertNil(category, "R3: 无任何信号的文件应返回 nil")
    }

    /// R4: EMS 交寄单 → emsReceipt。
    func testR4EMSReceiptIsEMSReceipt() {
        let category = DocumentClassifier.classify(
            fileName: "证据12、EMS交寄单（郭又义）.pdf",
            ocrText: "EMS 交寄单\n邮件号码 EX123456789\n寄件人 郭又义"
        )
        XCTAssertEqual(category, .emsReceipt, "R4: EMS 交寄单应识别为邮寄凭证")
    }
}
