# DocumentClassifier Gap 回归测试规范

本文档定义 DocumentClassifier 已修复 gap 的回归测试要求。
请将每个 gap 固化为 `ios/HardlawKit/Tests/DocumentClassifierGapRegressionTests.swift`
中的一个独立 XCTest test 方法，方法名必须包含 gap id（如 `testG1a...`）。

## 已修复 gap 清单

### G1 文件名权重(chatRecord「微信」×3 → ×1)
- G1a: `classify(fileName: "微信图片_20260511142513.jpg", ocrText: "2026/05/11 14:25")` 不得为 `.chatRecord`(现为 nil)
- G1b: `classify(fileName: "微信图片_20260511142513.jpg", ocrText: "7554\n7450")` 不得为 `.chatRecord`(现为 nil)
- G1c: `classify(fileName: "微信图片_20260511142513.jpg", ocrText: "姓名 郭又义 应发 7554 实发 7450")` == `.salaryTable`
- G1d: `classify(fileName: "微信聊天记录.pdf", ocrText: "申请人：好的 明天见 王经理：可以")` == `.chatRecord`

### G2 解除/行政处罚消歧
- G2a: `classify(fileName: "解除通知书.pdf", ocrText: "解除劳动关系通知书\n依据《劳动合同法》第39条 严重违反规章制度 予以辞退")` == `.dismissalNotice`
- G2b: `classify(fileName: "解除通知书.pdf", ocrText: "解除劳动关系通知书\n依据《劳动合同法》第38条 未足额支付劳动报酬")` == `.terminationNotice`
- G2c: `classify(fileName: "劳动保障监察责令改正决定书.pdf", ocrText: "劳动保障监察责令改正决定书\n责令限期支付拖欠工资")` == `.administrativeDecision`
- G2d: `classify(fileName: "行政处罚决定书.pdf", ocrText: "行政处罚决定书\n依据《劳动保障监察条例》处以罚款")` == `.penaltyNotice`

### G3 社保 vs 公积金
- G3a: `classify(fileName: "参保证明.pdf", ocrText: "河南省社会保险个人参保证明\n参保人：郭又义\n缴费基数 5000")` == `.socialInsurance`
- G3b: `classify(fileName: "个人住房公积金查询书.pdf", ocrText: "个人住房公积金查询书\n缴存额 1490\n缴存单位 达海公司")` == `.housingFund`

### G4 全角数字(OCR 常见全角)
- G4a: `classify(fileName: "被迫解除劳动关系通知书.pdf", ocrText: "解除劳动关系通知书\n依据《劳动合同法》第３８条 未足额支付劳动报酬")` == `.terminationNotice`
- G4b: `classify(fileName: "辞退通知书.pdf", ocrText: "解除劳动关系通知书\n依据《劳动合同法》第３９条 严重违反规章制度")` == `.dismissalNotice`

### G5-G10 关键词缺口(对齐豆包基准,用 classifyTopN top-3 命中语义)
- G5: `classifyTopN(fileName: "证据18、谢朝晖建造师证书查询结果.pdf", ocrText: "建造师证书查询结果\n姓名 谢朝晖 专业 建筑工程", n: 3)` 含 `.workHistory`
- G6: `classifyTopN(fileName: "聘任证明.pdf", ocrText: "聘任证明\n兹聘任郭又义为预算员", n: 3)` 含 `.workHistory`
- G7: `classifyTopN(fileName: "证据23、达海项目发票.pdf", ocrText: "河南增值税发票\n价税合计 50000", n: 3)` 含 `.financialOverlap`
- G8: `classifyTopN(fileName: "证据15、彭国运证书、五建集团公众号文章.pdf", ocrText: "五建集团公众号文章\n员工风采", n: 3)` 含 `.other`
- G9: `classifyTopN(fileName: "证据16、会议纪要.pdf", ocrText: "会议纪要\n参会人员", n: 3)` 含 `.other`
- G10: `classifyTopN(fileName: "证据17、补充协议、付款单据.pdf", ocrText: "补充协议\n付款单据", n: 3)` 含 `.other`

### R1-R4 基础回归
- R1: `classify(fileName: "证据3、劳动合同.pdf", ocrText: "劳动合同\n甲方：河南达海建设工程有限公司\n乙方：郭又义\n月工资：7550元")` == `.laborContract`
- R2: `classify(fileName: "证据5、银行工资表流水.pdf", ocrText: "银行交易明细\n2025年1月 工资 7550元\n付款方：冉林夕")` == `.bankStatement`
- R3: `classify(fileName: "unknown_file.mp4", ocrText: "binary content")` == nil
- R4: `classify(fileName: "证据12、EMS交寄单（郭又义）.pdf", ocrText: "EMS 交寄单\n邮件号码 EX123456789\n寄件人 郭又义")` == `.emsReceipt`

## 文件要求
- 文件路径:`ios/HardlawKit/Tests/DocumentClassifierGapRegressionTests.swift`
- import: `import XCTest` + `@testable import HardlawKit`
- 每个 gap 一个独立 test 方法,方法名含 id
- 注释标明 gap id,便于验证器匹配
