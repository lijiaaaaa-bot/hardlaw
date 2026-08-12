import XCTest
import zlib
@testable import HardlawKit
@testable import HardlawApp

/// 批量导入 + AI 自动填表 全流程测试
/// 使用郭又义真实案件素材（ txt 格式，模拟 OCR 输出）
@MainActor
final class BatchImportTests: XCTestCase {

    // MARK: - ZipReader

    func testZipReaderExtractsChineseFilenames() throws {
        // 最小 zip：一个 stored 条目，中文 UTF-8 文件名（无 UTF-8 flag bit，
        // 验证 decodeFilename 的 UTF-8 优先路径）。
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destDir) }

        let testContent = "测试内容：劳动合同 甲方：河南达海 乙方：郭又义"
        let testData = testContent.data(using: .utf8)!
        let zipURL = destDir.appendingPathComponent("test.zip")
        let zipData = makeSingleEntryZip(
            filename: "证据1、劳动合同.txt",
            payload: testData, method: 0, original: testData
        )

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try zipData.write(to: zipURL)

        let extracted = try ZipReader.extractAll(from: zipURL, to: destDir)
        XCTAssertEqual(extracted.count, 1)
        XCTAssertTrue(extracted[0].lastPathComponent.contains("劳动合同"))
        let content = try String(contentsOf: extracted[0], encoding: .utf8)
        XCTAssertEqual(content, testContent)
    }

    func testZipReaderRejectsPathTraversal() throws {
        // 构建含 "../" 条目的 zip，验证解析器在 CD 阶段拦截路径穿越。
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-traversal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destDir) }

        let testContent = "bad".data(using: .utf8)!
        let zipData = makeSingleEntryZip(
            filename: "../evil.txt",
            payload: testContent, method: 0, original: testContent
        )
        let zipURL = destDir.appendingPathComponent("evil.zip")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try zipData.write(to: zipURL)

        XCTAssertThrowsError(try ZipReader.extractAll(from: zipURL, to: destDir)) { error in
            guard case ZipError.pathTraversal(let name) = error else {
                XCTFail("Expected pathTraversal error, got \(error)")
                return
            }
            XCTAssertTrue(name.contains(".."))
        }
    }

    // MARK: - DocumentClassifier

    func testDocumentClassifierWithGuoCaseFiles() {
        // 劳动合同
        let contractCategory = DocumentClassifier.classify(
            fileName: "证据3、劳动合同.pdf",
            ocrText: "劳动合同\n甲方：河南达海建设工程有限公司\n乙方：郭又义\n月工资：7550元"
        )
        XCTAssertEqual(contractCategory, .laborContract)

        // 银行流水
        let bankCategory = DocumentClassifier.classify(
            fileName: "证据5、银行工资表流水.pdf",
            ocrText: "银行交易明细\n2025年1月 工资 7550元\n付款方：冉林夕"
        )
        XCTAssertEqual(bankCategory, .bankStatement)

        // 社保参保证明
        let insuranceCategory = DocumentClassifier.classify(
            fileName: "证据1、参保证明.pdf",
            ocrText: "河南省社会保险个人参保证明\n参保人：郭又义\n参保单位：河南达海建设工程有限公司"
        )
        XCTAssertEqual(insuranceCategory, .socialInsurance)

        // 被迫解除通知书
        let terminationCategory = DocumentClassifier.classify(
            fileName: "被迫解除劳动关系通知书.pdf",
            ocrText: "被迫解除劳动关系通知书\n依据《劳动合同法》第38条\n于2026年5月8日解除"
        )
        XCTAssertEqual(terminationCategory, .terminationNotice)

        // Garbage file → nil
        let unknownCategory = DocumentClassifier.classify(
            fileName: "unknown_file.mp4",
            ocrText: "binary content"
        )
        XCTAssertNil(unknownCategory)
    }

    // MARK: - AutoFillParser

    func testAutoFillParserFencedJSON() {
        let raw = """
        ```
        json
        {"classification":"书面劳动合同","proof_content":"甲方：河南达海，乙方：郭又义，月工资：7550元","proof_purpose":"证明劳动关系","numbers_cited":["7550元"]}
        ```
        """
        let result = AutoFillParser.parseDocument(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.classification, "书面劳动合同")
        XCTAssertTrue(result?.proofContent.contains("7550") ?? false)
        XCTAssertEqual(result?.numbersCited ?? [], ["7550元"])
    }

    func testAutoFillParserBareJSON() {
        let raw = "some text {\"case_name\":\"拖欠工资\",\"applicant\":\"郭又义\",\"respondent\":\"河南达海\",\"claims\":[\"支付拖欠工资\"]} trailing"
        let result = AutoFillParser.parseMetadata(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.caseName, "拖欠工资")
        XCTAssertEqual(result?.applicant, "郭又义")
        XCTAssertEqual(result?.respondent, "河南达海")
        XCTAssertEqual(result?.claims, ["支付拖欠工资"])
    }

    func testAutoFillParserRejectsGarbage() {
        XCTAssertNil(AutoFillParser.parseDocument("garbage"))
        XCTAssertNil(AutoFillParser.parseMetadata("not json at all"))
    }

    // MARK: - AutoFillRuleEngine

    func testRuleEngineDocumentFill() async throws {
        let engine = AutoFillRuleEngine()
        let prompt = AutoFillPrompt.documentPrompt(
            name: "银行工资流水.pdf",
            candidates: ["工资银行流水", "书面劳动合同"],
            ocrText: "银行交易明细\n2025-01-15 工资 7550元\n付款方：冉林夕\n收款方：郭又义"
        )
        let raw = try await engine.judge(prompt)
        let result = AutoFillParser.parseDocument(raw)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.proofContent.contains("7550") ?? false,
                      "Proof content should cite verbatim number from source")
    }

    func testRuleEngineMetadataExtraction() async throws {
        let engine = AutoFillRuleEngine()
        let prompt = AutoFillPrompt.metadataPrompt(documents: [
            (name: "劳动仲裁申请书.pdf",
             text: "申请人：郭又义\n被申请人：河南达海建设工程有限公司\n案由：拖欠工资、被迫解除劳动合同\n仲裁请求：\n1、支付拖欠工资93059.85元\n2、支付经济补偿金45300元")
        ])
        let raw = try await engine.judge(prompt)
        let result = AutoFillParser.parseMetadata(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.applicant, "郭又义")
        XCTAssertEqual(result?.respondent, "河南达海建设工程有限公司")
        XCTAssertTrue(result?.claims.contains(where: { $0.contains("93059.85") }) ?? false)
    }

    // MARK: - AutoFillPipeline (deterministic path)

    func testAutoFillPipelineFillsEvidenceCatalog() async {
        let cf = CaseFile(caseName: "测试案件", applicant: "", respondent: "")
        cf.evidenceItems.append(EvidenceItem(
            number: 1, name: "劳动合同.pdf",
            sourceOCRText: "劳动合同 甲方：河南达海 乙方：郭又义 月工资：7550元"))
        cf.evidenceItems.append(EvidenceItem(
            number: 2, name: "银行流水.pdf",
            sourceOCRText: "银行交易明细 2025年1月 工资 7550元 付款方：冉林夕"))

        let engine = AutoFillRuleEngine()
        let outcomes = await AutoFillPipeline.fillEvidence(
            cf.evidenceItems,
            llm: engine,
            evidenceVersion: cf.evidenceVersion
        )

        let filled = outcomes.filter { $0.status == .filled }
        XCTAssertEqual(filled.count, 2, "Both items should be filled")

        // Check first item filled
        let item1 = cf.evidenceItems[0]
        XCTAssertFalse(item1.proofContentState.displayValue?.isEmpty ?? true,
                       "Item 1 should have proof content filled")
        XCTAssertTrue(item1.proofContentState.displayValue?.contains("7550") ?? false,
                      "Proof content should contain source number")

        // Check group was set
        XCTAssertEqual(item1.group, EvidenceCategory.laborContract.rawValue)
        XCTAssertEqual(cf.evidenceItems[1].group, EvidenceCategory.bankStatement.rawValue)
    }

    func testPipelineRejectsHallucinatedNumbers() async {
        // Use a simple mock that returns a number NOT in the source
        let hallucinatingLLM = MockHallucinatingLLM()
        let cf = CaseFile(caseName: "test", applicant: "", respondent: "")
        cf.evidenceItems.append(EvidenceItem(
            number: 1, name: "合同.pdf",
            sourceOCRText: "月工资 7550元"))

        let outcomes = await AutoFillPipeline.fillEvidence(
            cf.evidenceItems,
            llm: hallucinatingLLM,
            evidenceVersion: 1
        )

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].status, .rejectedUnverifiable,
                       "Hallucinated numbers (99999) not in source must be rejected")
    }

    func testPipelineSkipsEmptyOCR() async {
        let engine = AutoFillRuleEngine()
        let cf = CaseFile(caseName: "test", applicant: "", respondent: "")
        cf.evidenceItems.append(EvidenceItem(
            number: 1, name: "合同.pdf",
            sourceOCRText: "")) // Empty OCR

        let outcomes = await AutoFillPipeline.fillEvidence(
            cf.evidenceItems,
            llm: engine,
            evidenceVersion: 1
        )

        // No candidates with non-empty OCR → no outcomes
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: - ImportPackage

    func testImportPackageEnumerateDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guo-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "证据1、参保证明.pdf content".write(to: dir.appendingPathComponent("证据1、参保证明.pdf"), atomically: true, encoding: .utf8)
        try "证据3、劳动合同.pdf content".write(to: dir.appendingPathComponent("证据3、劳动合同.pdf"), atomically: true, encoding: .utf8)
        try "证据5、银行工资表流水.pdf content".write(to: dir.appendingPathComponent("证据5、银行工资表流水.pdf"), atomically: true, encoding: .utf8)
        try "视频.mp4 content".write(to: dir.appendingPathComponent("视频.mp4"), atomically: true, encoding: .utf8)

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        let (files, skipped) = try ImportPackage.expand(dir, scratchDir: scratchDir)

        XCTAssertEqual(files.count, 3, "3 supported files")
        XCTAssertEqual(skipped.count, 1, "1 mp4 skipped")
        // Should be sorted
        XCTAssertTrue(files[0].lastPathComponent.contains("证据1"))
        XCTAssertTrue(files[1].lastPathComponent.contains("证据3"))
        XCTAssertTrue(files[2].lastPathComponent.contains("证据5"))
    }

    // MARK: - ZipReader (deflate entries)

    func testZipReaderExtractsDeflateEntry() throws {
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-deflate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destDir) }

        let testContent = "被迫解除劳动关系通知书\n依据《劳动合同法》第38条：未及时足额支付劳动报酬\n于2026年5月8日解除劳动合同"
        let original = testContent.data(using: .utf8)!
        let deflated = zipDeflateRaw(original)

        let zipData = makeSingleEntryZip(filename: "被迫解除通知书.txt", payload: deflated, method: 8, original: original)
        let zipURL = destDir.appendingPathComponent("deflate.zip")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try zipData.write(to: zipURL)

        let extracted = try ZipReader.extractAll(from: zipURL, to: destDir)
        XCTAssertEqual(extracted.count, 1)
        XCTAssertTrue(extracted[0].lastPathComponent.contains("被迫解除通知书"))
        let content = try String(contentsOf: extracted[0], encoding: .utf8)
        XCTAssertEqual(content, testContent, "Deflate 条目应被正确解压还原")
    }

    func testZipReaderInflateRejectsBombEntry() throws {
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-bomb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destDir) }

        // 小 payload 声称 300MB 解压大小：解压前按容量上限直接拒绝（200MB cap），
        // 无需实际分配大内存。
        let deflated = zipDeflateRaw(Data(repeating: 0x41, count: 1024))
        let zipData = makeSingleEntryZip(
            filename: "bomb.txt", payload: deflated, method: 8,
            original: Data(repeating: 0x41, count: 1024),
            uncompressedSize: 300 * 1024 * 1024
        )
        let zipURL = destDir.appendingPathComponent("bomb.zip")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try zipData.write(to: zipURL)

        XCTAssertThrowsError(try ZipReader.extractAll(from: zipURL, to: destDir)) { error in
            guard case ZipError.entryTooLarge = error else {
                XCTFail("Expected entryTooLarge, got \(error)")
                return
            }
        }
    }

    /// 截断 / 垃圾输入不得崩溃：合法 zip 的任意前缀截断、中间挖洞、随机字节，
    /// `extractAll` 必须抛错或成功，绝不能 fatal crash。
    /// 修复前：EOCD / CD 读取处 `DataReader.readUInt16/32` 用 `loadUnaligned`，
    /// 越界触发 `UnsafeRawBufferPointer.load out of bounds` 进程崩溃。
    func testZipReaderTruncatedOrGarbageInputDoesNotCrash() throws {
        let testContent = "测试内容：劳动合同 甲方：河南达海 乙方：郭又义"
        let original = testContent.data(using: .utf8)!
        let zipData = makeSingleEntryZip(
            filename: "证据1、劳动合同.txt",
            payload: original, method: 0, original: original
        )
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-robust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        // 1) 前缀截断：从 EOCD 一路砍进 CD 区、local header 与 payload。
        //    修复前 cut=5 起 EOCD 读取即越界崩溃。
        for cut in 1...80 where cut < zipData.count {
            runExtractSafely(zipData.prefix(zipData.count - cut), into: scratchRoot,
                             label: "prefix cut=\(cut)")
        }

        // 2) 中间挖洞：删掉中段一片字节，模拟损坏的 CD 区。
        for drop in [4, 6, 10, 20] {
            var mutated = zipData
            if mutated.count > drop * 2 {
                let mid = mutated.count / 2
                mutated.removeSubrange(mid..<(mid + drop))
            }
            runExtractSafely(mutated, into: scratchRoot, label: "middle drop=\(drop)")
        }

        // 3) 随机垃圾：各长度字节，越界读取都不该致命。
        for len in [0, 1, 4, 8, 22, 46, 128, 256, 1024] {
            var garbage = Data()
            for _ in 0..<len {
                garbage.append(UInt8.random(in: .min ... .max))
            }
            runExtractSafely(garbage, into: scratchRoot, label: "garbage len=\(len)")
        }
    }

    // MARK: - DocumentClassifier termination disambiguation

    /// 中性文件名 + 被迫解除标记（第38条/被迫）→ 保持 .terminationNotice，不被“解除通知”拉成单方解除。
    func testClassifierDisambiguatesForcedTermination() {
        let cat = DocumentClassifier.classify(
            fileName: "解除劳动关系通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第38条，未及时足额支付劳动报酬\n本人被迫提出解除"
        )
        XCTAssertEqual(cat, .terminationNotice)
    }

    /// 同样的文件名，但内容为用人单位以“严重违纪/第39条/辞退”解除 → 二次消歧翻转为单方解除。
    func testClassifierDisambiguatesEmployerDismissal() {
        let cat = DocumentClassifier.classify(
            fileName: "解除劳动关系通知书.pdf",
            ocrText: "解除劳动关系通知书\n因严重违反公司规章制度\n依据《劳动合同法》第39条，予以辞退"
        )
        XCTAssertEqual(cat, .dismissalNotice)
    }

    /// 无被迫/辞退标记的中性解除通知：不强制翻转，按打分自然落入单方解除。
    func testClassifierDisambiguationLeavesNeutralTermination() {
        let cat = DocumentClassifier.classify(
            fileName: "解除通知.pdf",
            ocrText: "解除通知\n兹通知双方劳动关系于2026年5月8日解除"
        )
        XCTAssertEqual(cat, .dismissalNotice)
    }

    /// classifyTopN 应把消歧后的正确类别提到首位，让 AI 提示优先看到它。
    func testClassifierTopNPromotesCorrectedTerminationToTop() {
        let top = DocumentClassifier.classifyTopN(
            fileName: "解除劳动关系通知书.pdf",
            ocrText: "解除劳动关系通知书\n依据《劳动合同法》第38条，未足额支付劳动报酬\n本人被迫提出解除",
            n: 3
        )
        XCTAssertEqual(top.first, .terminationNotice)
    }

    // MARK: - FieldState.merge 四规则

    /// Rule 1：人工已覆写 → 永不被 AI 覆盖，返回 flagForReview。
    func testFieldStateMergeRule1HumanOverrideNeverOverwritten() {
        var fs = FieldState(machineValue: "AI初稿")
        fs.override(with: "人工修改")
        let action = fs.merge(newMachineValue: "新AI值", directlyAffected: true, evidenceVersion: 2)
        XCTAssertEqual(action, .flagForReview("AI 根据新证据更新了建议，你的修改已保留"))
        XCTAssertEqual(fs.status, .humanOverridden)
        XCTAssertEqual(fs.humanOverride, "人工修改", "人工修改必须保留")
        XCTAssertEqual(fs.machineValue, "新AI值", "机器建议仍可更新")
        XCTAssertEqual(fs.displayValue, "人工修改", "显示值始终优先人工覆写")
    }

    /// Rule 2：已确认 + 受影响 → 降级为 machineDraft 并要求重新确认。
    func testFieldStateMergeRule2ConfirmedAffectedPromptsReconfirmation() {
        var fs = FieldState(machineValue: "旧AI值")
        fs.confirm()
        let action = fs.merge(newMachineValue: "新AI值", directlyAffected: true, evidenceVersion: 2)
        XCTAssertEqual(action, .promptForReconfirmation("AI 建议已更新，请重新确认"))
        XCTAssertEqual(fs.status, .machineDraft, "受影响的已确认值应降级")
        XCTAssertEqual(fs.machineValue, "新AI值")
    }

    /// Rule 3：已确认 + 不受影响 → 保持确认状态，返回 noop。
    func testFieldStateMergeRule3ConfirmedNotAffectedNoop() {
        var fs = FieldState(machineValue: "旧AI值")
        fs.confirm()
        let action = fs.merge(newMachineValue: "无关新值", directlyAffected: false, evidenceVersion: 2)
        XCTAssertEqual(action, .noop)
        XCTAssertEqual(fs.status, .humanConfirmed, "未受影响时保持已确认")
    }

    /// Rule 4：machineDraft / pending → 自由更新为 .applied。
    func testFieldStateMergeRule4MachineDraftOrPendingApplied() {
        var fs = FieldState(machineValue: nil) // pending
        let action = fs.merge(newMachineValue: "AI值", directlyAffected: true, evidenceVersion: 1)
        XCTAssertEqual(action, .applied)
        XCTAssertEqual(fs.status, .machineDraft)
        XCTAssertEqual(fs.basedOnEvidenceVersion, 1)
        XCTAssertFalse(fs.stale)
    }

    // MARK: - FailSafeLLM 降级

    func testFailSafeLLMKeepsPrimaryWhenItSucceeds() async throws {
        let fsllm = FailSafeLLM(primary: StubLLM(output: "primary-output"), fallback: StubLLM(output: "fallback"))
        let result = try await fsllm.judge("test prompt")
        XCTAssertEqual(result, "primary-output")
        let count = await fsllm.fallbackCount
        XCTAssertEqual(count, 0, "主后端成功时不应降级")
    }

    func testFailSafeLLMFallsBackWhenPrimaryThrows() async throws {
        let fsllm = FailSafeLLM(primary: ThrowingLLM(), fallback: StubLLM(output: "fallback-output"))
        let result = try await fsllm.judge("test prompt")
        XCTAssertEqual(result, "fallback-output", "主后端抛错时应透明回退")
        let count = await fsllm.fallbackCount
        XCTAssertEqual(count, 1, "降级次数应累计")
    }

    func testFailSafeLLMPropagatesFallbackFailure() async {
        let fsllm = FailSafeLLM(primary: ThrowingLLM(), fallback: ThrowingLLM())
        do {
            _ = try await fsllm.judge("test prompt")
            XCTFail("主后端和回退后端都失败时应抛出错误")
        } catch {
            let count = await fsllm.fallbackCount
            XCTAssertEqual(count, 1)
        }
    }
}

// MARK: - Mock helpers

private func zipCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if (crc & 1) != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
    }
    return (~crc)
}

/// Returns a hallucinated number not in any source text.
private final class MockHallucinatingLLM: LLMBackend, @unchecked Sendable {
    func judge(_ prompt: String) async throws -> String {
        return """
        {"classification":"书面劳动合同","proof_content":"月工资 99999元","proof_purpose":"证明劳动关系","numbers_cited":["99999元"]}
        """
    }
}

/// Compress data with raw deflate (no zlib header/trailer) via the same zlib
/// `deflateInit2_(-MAX_WBITS)` convention that `ZipReader.inflateData` uses
/// (`inflateInit2_(-MAX_WBITS)`), so the round trip is a genuine zlib deflate.
private func zipDeflateRaw(_ data: Data) -> Data {
    var stream = z_stream()
    stream.zalloc = nil
    stream.zfree = nil
    stream.opaque = nil

    let windowBits = -MAX_WBITS  // raw deflate, no zlib/gzip wrapper
    let initRet = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                windowBits, 8, Z_DEFAULT_STRATEGY,
                                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initRet == Z_OK else { return data }  // fallback: store uncompressed
    defer { deflateEnd(&stream) }

    let chunkSize = 64 * 1024
    var output = Data()
    var src = data
    let srcCount = src.count
    var done = false

    src.withUnsafeMutableBytes { (srcRaw: UnsafeMutableRawBufferPointer) in
        stream.next_in = srcRaw.bindMemory(to: Bytef.self).baseAddress
        stream.avail_in = uInt(srcCount)

        while !done {
            var chunk = [Bytef](repeating: 0, count: chunkSize)
            stream.next_out = chunk.withUnsafeMutableBytes { $0.bindMemory(to: Bytef.self).baseAddress }
            stream.avail_out = uInt(chunkSize)

            let flush = (stream.avail_in == 0) ? Z_FINISH : Z_NO_FLUSH
            let ret = deflate(&stream, flush)
            if ret == Z_STREAM_END {
                done = true
            } else if ret != Z_OK {
                break
            }

            let produced = chunkSize - Int(stream.avail_out)
            output.append(chunk, count: produced)
        }
    }
    return output
}

/// Build a minimal single-entry zip in memory.
/// - Parameters:
///   - filename: entry name (UTF-8, no UTF-8 flag bit)
///   - payload: the entry payload exactly as stored in the archive
///   - method: 0 = stored, 8 = deflated
///   - original: the uncompressed original data (for crc32 + sizes)
///   - uncompressedSize: 声明在压缩包里的解压大小；默认取 `original.count`。
///     用于模拟 zip bomb（小 payload 声称超大解压大小）。
private func makeSingleEntryZip(filename: String, payload: Data, method: UInt16, original: Data, uncompressedSize: Int? = nil) -> Data {
    let filenameBytes = filename.data(using: .utf8)!
    let crc = zipCRC32(original)
    let uncompressed = UInt32(uncompressedSize ?? original.count)

    var zipData = Data()

    // Local file header
    zipData.append(contentsOf: [0x50, 0x4b, 0x03, 0x04]) // signature
    zipData.append(contentsOf: [0x14, 0x00]) // version needed
    zipData.append(contentsOf: [0x00, 0x00]) // flags
    zipData.append(contentsOf: withUnsafeBytes(of: method.littleEndian, Array.init))
    zipData.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // modtime/date
    zipData.append(contentsOf: withUnsafeBytes(of: crc.littleEndian, Array.init))
    zipData.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init)) // compressed size
    zipData.append(contentsOf: withUnsafeBytes(of: uncompressed.littleEndian, Array.init)) // uncompressed size
    zipData.append(contentsOf: withUnsafeBytes(of: UInt16(filenameBytes.count).littleEndian, Array.init))
    zipData.append(contentsOf: [0x00, 0x00]) // extra field length
    zipData.append(filenameBytes)
    zipData.append(payload)

    // Central directory
    let cdOffset = UInt32(zipData.count)
    zipData.append(contentsOf: [0x50, 0x4b, 0x01, 0x02]) // CD signature
    zipData.append(contentsOf: [0x14, 0x00]) // version made by
    zipData.append(contentsOf: [0x14, 0x00]) // version needed
    zipData.append(contentsOf: [0x00, 0x00]) // flags
    zipData.append(contentsOf: withUnsafeBytes(of: method.littleEndian, Array.init))
    zipData.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // modtime/date
    zipData.append(contentsOf: withUnsafeBytes(of: crc.littleEndian, Array.init))
    zipData.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init)) // compressed
    zipData.append(contentsOf: withUnsafeBytes(of: uncompressed.littleEndian, Array.init)) // uncompressed
    zipData.append(contentsOf: withUnsafeBytes(of: UInt16(filenameBytes.count).littleEndian, Array.init))
    zipData.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // extra + comment + disk start
    // 固定头共 46 字节：internal attrs(2) + external attrs(4) + local header offset(4) = 10
    zipData.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    zipData.append(filenameBytes) // CD 条目文件名（必须追加，否则文件名超出文件尾）

    // EOCD
    let cdSize = UInt32(zipData.count) - cdOffset // CD 大小必须在追加 EOCD 前计算
    zipData.append(contentsOf: [0x50, 0x4b, 0x05, 0x06]) // EOCD signature
    zipData.append(contentsOf: [0x00, 0x00]) // disk
    zipData.append(contentsOf: [0x00, 0x00]) // CD disk
    zipData.append(contentsOf: [0x01, 0x00]) // entries on disk
    zipData.append(contentsOf: [0x01, 0x00]) // total entries
    zipData.append(contentsOf: withUnsafeBytes(of: cdSize.littleEndian, Array.init))
    zipData.append(contentsOf: withUnsafeBytes(of: cdOffset.littleEndian, Array.init))
    zipData.append(contentsOf: [0x00, 0x00]) // comment length
    return zipData
}

/// 把 zip 数据写入 scratch 子目录并调用 `extractAll`，吞掉一切错误。
/// 唯一关心的就是不崩溃：一旦 `loadUnaligned` 越界，整个测试进程直接 fatal。
private func runExtractSafely(_ data: Data, into scratchRoot: URL, label: String) {
    let dir = scratchRoot.appendingPathComponent(label.replacingOccurrences(of: " ", with: "_"))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let zipURL = dir.appendingPathComponent("input.zip")
    try? data.write(to: zipURL)
    _ = try? ZipReader.extractAll(from: zipURL, to: dir)
}

/// Always-throwing backend — exercises the FailSafeLLM fallback path.
private struct ThrowingLLM: LLMBackend {
    func judge(_ prompt: String) async throws -> String {
        throw TestBackendError.failed
    }
}

/// Fixed-output backend for deterministic assertions.
private struct StubLLM: LLMBackend {
    let output: String
    func judge(_ prompt: String) async throws -> String { output }
}

private enum TestBackendError: Error {
    case failed
}
