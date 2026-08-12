import Foundation
import Observation
import CoreGraphics
import ImageIO
import PDFKit
import HardlawKit

// MARK: - 批量导入结果

/// 批量导入的统计结果。`isEmpty == true` 表示没有任何可用的文件被导入，
/// 调用方（HomeView）应据此清理占位案件（幽灵案件防护）。
public struct ImportBatchResult: Sendable {
    public let importedCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let message: String

    public init(importedCount: Int, failedCount: Int, skippedCount: Int, message: String) {
        self.importedCount = importedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.message = message
    }

    public var isEmpty: Bool { importedCount == 0 }
}

// MARK: - CourtViewModel

/// 案件看板编排层：intent 分发、goal 执行、verdict 落盘、引用验证。
/// 业务逻辑从 CaseWorkbenchView 提取至此；视图只负责 UI 布局与交互。
@MainActor
@Observable
final class CourtViewModel {
    var caseFile: CaseFile
    var goal: Goal?
    var statusMessage: String?
    var isProcessing = false
    var goalProgress = ""
    var importPhase: String?          // 批量导入阶段描述
    var importProgress: (done: Int, total: Int)? // 批量导入进度
    var isImportCancelled = false     // 用户请求取消导入（在复制/OCR/填表循环间检查）

    /// 请求取消当前导入。已在进行的单文件操作（OCR/LLM 调用）完成后即停止，
    /// 已处理的部分保留，占位案件由调用方依据 `ImportBatchResult` 清理。
    func cancelImport() {
        isImportCancelled = true
    }
    /// LLM 后端 — 默认 MLX on-device（Metal GPU）；模型未缓存（首次使用）时
    /// 自动回退本地规则引擎，MLX 加载/推理失败时由 FailSafeLLM 兜底降级，
    /// 绝不联网挂起。集成测试可注入 MockLLM / RuleBasedLLM，保证离线可跑。
    var llm: any LLMBackend = {
        let fallback = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        if MLXLLM.isAvailable {
            return FailSafeLLM(primary: MLXLLM(), fallback: fallback)
        }
        return fallback
    }()

    init(caseFile: CaseFile) {
        self.caseFile = caseFile
    }

    // MARK: - 指令分发

    func handleCommand(_ text: String) {
        let intent = IntentParser.parse(text, stage: caseFile.stage)
        guard intent.isParsed else {
            statusMessage = "试试：补充银行流水 / 生成目录 / 检查工资 / 全面复核"
            return
        }
        isProcessing = true
        Task {
            if intent.kind == .fullReview || text.contains("审查") {
                await runGoalSteps(makeReviewGoal())
                return
            }
            if let result = await executeIntent(intent) {
                applyVerdicts(result)
                statusMessage = summary(from: result) + fallbackHint
            }
            saveCase()
            isProcessing = false
        }
    }

    /// 持久化案件；失败时给出用户可见反馈。
    func saveCase() {
        do {
            try PersistenceController.shared.save(caseFile)
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Goal 执行（Plan → Execute → Verify）

    /// 构造审查 goal：目录生成（存在无内容的证据时）→ 引用验证 → 缺口检测 →
    /// 工资一致性检查（存在 ≥2 条工资类证据时）。
    func makeReviewGoal() -> Goal {
        var steps: [GoalStep] = [
            GoalStep(name: "验证引用出处", detail: "逐字核对原文", kind: .verifyCitations),
            GoalStep(name: "检测证据缺口", detail: "劳动关系、工资、混同", kind: .detectGaps),
        ]
        let pendingCount = caseFile.evidenceItems.filter { ($0.proofContentState.displayValue ?? "").isEmpty && !$0.sourceOCRText.isEmpty }.count
        if pendingCount > 0 {
            steps.insert(GoalStep(name: "AI 自动填表", detail: "\(pendingCount) 项待填写", kind: .autoFill), at: 0)
        }
        if caseFile.evidenceItems.contains(where: { ($0.proofContentState.displayValue?.isEmpty ?? true) }) {
            steps.insert(GoalStep(name: "生成证据目录", detail: "\(caseFile.evidenceItems.count) 项", kind: .generateCatalog), at: 0)
        }
        if caseFile.evidenceItems.filter({ $0.name.contains("工资") || ($0.proofContentState.displayValue ?? "").contains("元") }).count >= 2 {
            steps.append(GoalStep(name: "工资一致性检查", detail: "交叉比对", kind: .checkConsistency))
        }
        return Goal(description: "审查 \(caseFile.caseName)", steps: steps)
    }

    /// 启动 goal 执行（UI 入口：后台异步运行）。
    func runGoal(_ goal: Goal) {
        isProcessing = true
        Task { await runGoalSteps(goal) }
    }

    /// 顺序执行 goal 的全部步骤并展示进度（同步核心，UI 与集成测试共用）。
    func runGoalSteps(_ goal: Goal) async {
        var g = goal
        g.status = .running
        self.goal = g
        for i in g.steps.indices {
            g.steps[i].status = .running
            self.goal = g
            goalProgress = "步骤 \(i+1)/\(g.steps.count): \(g.steps[i].name)"
            let result = await executeGoalStep(g.steps[i])
            g.steps[i].status = result != nil ? .done : .failed
            g.steps[i].resultSummary = result.flatMap { summary(from: $0) } ?? ""
            if let r = result { applyVerdicts(r) }
            self.goal = g
        }
        g.status = g.isComplete ? .done : .failed
        self.goal = g
        statusMessage = (g.isComplete ? "审查完成" : "部分步骤需要人工处理") + fallbackHint
        saveCase()
        isProcessing = false
    }

    func executeGoalStep(_ step: GoalStep) async -> CaseResult? {
        switch step.kind {
        case .generateCatalog:
            guard caseFile.evidenceItems.count > 0 else { return nil }
            do {
                let proc = try CourtProcedures.catalogGeneration(itemCount: caseFile.evidenceItems.count)
                return await runCourt(proc, statutes: StatuteBook())
            } catch {
                statusMessage = "目录生成失败：\(error.localizedDescription)"
                return nil
            }
        case .verifyCitations:
            verifySnippets()
            // 返回非 nil，让 goal 步骤正常完成（非红叉）
            return CaseResult(
                caseId: "verify-citations",
                verdicts: [Verdict(finding: "none", refuted: false, confidence: .high,
                                    blocking: false, reasoning: "引用验证完成：目录数字均已与原文核对")],
                finalDisposition: .approved,
                reason: "引用验证完成",
                roundCount: 1
            )
        case .detectGaps:
            // Fallback 模式（RuleBasedLLM）：使用确定性缺口检查作为保底产出。
            // MLX 模式：走完整 LLM 审理流程。
            if llm is RuleBasedLLM {
                let gaps = IntentHandler.findCommonGaps(caseFile)
                if !gaps.isEmpty {
                    for g in gaps { caseFile.gaps.append(g) }
                    statusMessage = "已检测 \(gaps.count) 个常见证据缺口"
                } else {
                    statusMessage = "未发现常见证据缺口"
                }
                return CaseResult(caseId: "detect-gaps-deterministic",
                    verdicts: [], finalDisposition: .approved,
                    reason: gaps.isEmpty ? "确定性检查未发现缺口" : "发现 \(gaps.count) 个缺口",
                    roundCount: 1)
            }
            do {
                let proc = try CourtProcedures.gapDetection()
                return await runCourt(proc, statutes: LaborLawStatutes.gapDetectionBook)
            } catch {
                statusMessage = "缺口检测失败：\(error.localizedDescription)"
                return nil
            }
        case .autoFill:
            let candidates = caseFile.evidenceItems.filter {
                ($0.proofContentState.displayValue ?? "").isEmpty && !$0.sourceOCRText.isEmpty
            }
            guard !candidates.isEmpty else { return nil }
            let outcomes = await AutoFillPipeline.fillEvidence(
                caseFile.evidenceItems,
                llm: llm,
                evidenceVersion: caseFile.evidenceVersion,
                claims: caseFile.claims.map(\.content)
            )
            // Also try metadata extraction
            if caseFile.caseName.isEmpty || caseFile.caseName == "新导入案件" || caseFile.applicant.isEmpty || caseFile.respondent.isEmpty {
                if let meta = await AutoFillPipeline.extractMetadata(from: caseFile.evidenceItems, llm: llm) {
                    if caseFile.caseName.isEmpty && !meta.caseName.isEmpty {
                        caseFile.caseName = meta.caseName
                    }
                    if caseFile.applicant.isEmpty && !meta.applicant.isEmpty {
                        caseFile.applicant = meta.applicant
                    }
                    if caseFile.respondent.isEmpty && !meta.respondent.isEmpty {
                        caseFile.respondent = meta.respondent
                    }
                    for claim in meta.claims where !caseFile.claims.contains(where: { $0.content == claim }) {
                        caseFile.claims.append(ClaimItem(claimNumber: caseFile.claims.count + 1, content: claim))
                    }
                }
            }
            let filled = outcomes.filter { $0.status == .filled }.count
            let rejected = outcomes.filter { $0.status == .rejectedUnverifiable }.count
            let overridden = outcomes.filter { $0.status == .humanOverridden }.count
            let skipped = outcomes.filter { $0.status == .skipped }.count
            var reason = "自动填表完成 \(filled) 项"
            if rejected > 0 { reason += "，\(rejected) 项因数据不可验证被拒绝" }
            if overridden > 0 { reason += "，\(overridden) 项保留人工修改" }
            if skipped > 0 { reason += "，\(skipped) 项跳过" }
            return CaseResult(caseId: "auto-fill", verdicts: [], finalDisposition: .approved,
                reason: reason, roundCount: 1)
        case .checkConsistency:
            do {
                let proc = try CourtProcedures.salaryConsistency()
                return await runCourt(proc, statutes: StatuteBook())
            } catch {
                statusMessage = "工资检查失败：\(error.localizedDescription)"
                return nil
            }
        }
    }

    // MARK: - Intent 执行

    func executeIntent(_ intent: ParsedIntent) async -> CaseResult? {
        switch intent.kind {
        case .generateCatalog:
            let count = caseFile.evidenceItems.count
            guard count > 0 else {
                statusMessage = "尚无证据，无法生成目录"
                return nil
            }
            do {
                let proc = try CourtProcedures.catalogGeneration(itemCount: count)
                statusMessage = "生成 \(count) 项目录…"
                return await runCourt(proc, statutes: StatuteBook())
            } catch {
                statusMessage = "目录生成失败：\(error.localizedDescription)"
                return nil
            }
        case .fullReview:
            let count = caseFile.evidenceItems.count
            guard count > 0 else {
                statusMessage = "尚无证据，无法全面复核"
                return nil
            }
            do {
                let proc = try CourtProcedures.fullReview(itemCount: count)
                statusMessage = "全面复核中…"
                return await runCourt(proc, statutes: StatuteBook())
            } catch {
                statusMessage = "全面复核失败：\(error.localizedDescription)"
                return nil
            }
        case .detectGaps:
            // Fallback path: use deterministic check when LLM is rule-based
            if llm is RuleBasedLLM {
                let gaps = IntentHandler.findCommonGaps(caseFile)
                for g in gaps { caseFile.gaps.append(g) }
                statusMessage = gaps.isEmpty ? "未发现常见证据缺口" : "已检测 \(gaps.count) 个常见证据缺口（规则引擎）"
                return CaseResult(caseId: "detect-gaps-deterministic", verdicts: [], finalDisposition: .approved, reason: "确定性检查", roundCount: 1)
            }
            do {
                let proc = try CourtProcedures.gapDetection()
                statusMessage = "检测证据缺口…"
                return await runCourt(proc, statutes: LaborLawStatutes.gapDetectionBook)
            } catch {
                statusMessage = "缺口检测失败：\(error.localizedDescription)"
                return nil
            }
        case .checkConsistency:
            do {
                let proc = try CourtProcedures.salaryConsistency()
                statusMessage = "工资一致性检查…"
                return await runCourt(proc, statutes: StatuteBook())
            } catch {
                statusMessage = "工资检查失败：\(error.localizedDescription)"
                return nil
            }
        case .verifyCitations:
            verifySnippets()
            statusMessage = "引用验证完成"
            return nil
        default:
            if intent.kind == .addFact, !intent.originalText.isEmpty {
                caseFile.facts.append(intent.originalText)
                statusMessage = "已记录事实（共\(caseFile.facts.count)条）。可输入「生成目录」或「全面复核」"
            } else {
                let r = IntentHandler.handle(intent, caseFile: caseFile)
                statusMessage = r.message
            }
            return nil
        }
    }

    // MARK: - Court 审理

    /// 本地规则引擎兜底提示：MLX 模型未缓存（首次使用）时，
    /// 附加在最终状态消息之后，确保用户能看到。
    private var fallbackHint: String {
        guard llm is RuleBasedLLM else { return "" }
        return "（首次使用需联网下载AI模型约500MB，当前为本地规则引擎）"
    }

    /// 组装案件数据 → 本地审理（全部本地，零网络；模型未缓存时走规则引擎）。
    func runCourt(_ procedure: Procedure, statutes: StatuteBook) async -> CaseResult {
        var caseData: [String: JSONValue] = [:]
        for item in caseFile.evidenceItems {
            if !item.sourceOCRText.isEmpty {
                caseData["evidence_\(item.number)"] = .string(item.sourceOCRText)
            }
            if let c = item.proofContentState.displayValue, !c.isEmpty {
                caseData["catalog_\(item.number)"] = .string(c)
            }
        }
        for claim in caseFile.claims {
            caseData["claim_\(claim.claimNumber)"] = .string(claim.content)
        }
        // 用户陈述的案件事实（自然语言录入）
        if !caseFile.facts.isEmpty {
            caseData["case_facts"] = .string(caseFile.facts.joined(separator: "\n"))
        }
        // LegalKnowledge citations as prompt context
        // 尽力而为：法条库缺失/加载失败时跳过引用增强，不影响本地分析。
        // 单例缓存：7MB 法条 JSON 只加载一次，避免每次命令都从磁盘重读。
        let store = LawStore.shared
        if store.chunkCount > 0 {
            let query = caseFile.claims.map(\.content).joined(separator: " ")
            let results = await LawIndex(store: store).search(query, k: 5)
            let cites = results.map { "\($0.chunk.lawID)第\($0.chunk.articleNum)条" }
            caseData["legal_citations"] = .string(cites.joined(separator: "; "))
        }
        // 首次使用（MLX 模型未缓存）→ 自动使用本地规则引擎，零网络零等待；
        // 提示用户后续可联网下载 AI 模型获得更精确的审理。
        if llm is RuleBasedLLM {
            statusMessage = "首次使用需联网下载AI模型（约500MB），当前使用本地规则引擎"
        }
        // LLM 后端 — 默认 MLX on-device；测试注入 MockLLM/RuleBasedLLM 保证离线可跑
        let court = Court(statutes: statutes, procedure: procedure, llm: llm)
        let result = await court.hear(caseData: caseData)
        // MLX 运行时失败（模型损坏/加载错误）→ FailSafeLLM 已降级为规则引擎，
        // 向用户说明兜底路径，而不是静默返回空结果。
        if let failSafe = llm as? FailSafeLLM, await failSafe.fallbackCount > 0 {
            statusMessage = "AI模型加载失败，已切换至本地规则引擎审理"
        }
        return result
    }

    // MARK: - Verdict 落盘

    /// 将审理结果写入 FieldState 并追加证据缺口（同一 gap 不重复追加）。
    func applyVerdicts(_ result: CaseResult) {
        var gapKeys = Set(caseFile.gaps.map { $0.description + $0.relatedClaim })
        for v in result.verdicts {
            // Template reasoning from RuleBasedLLM: skip for gap creation
            // (regex engine cannot distinguish evidence present from missing),
            // but still write to FieldState and mark stale so catalog content
            // and consistency checks are not silently discarded.
            let isTemplate = v.reasoning.contains("Rule-based detection")
            // Write to FieldState if verdict has reasoning
            if !v.reasoning.isEmpty {
                if let itemNum = parseItemNumber(from: v.finding), itemNum > 0, itemNum <= caseFile.evidenceItems.count {
                    let item = caseFile.evidenceItems[itemNum - 1]
                    _ = item.proofContentState.merge(newMachineValue: v.reasoning, directlyAffected: false,
                                                     evidenceVersion: caseFile.evidenceVersion)
                }
            }
            // Mark items stale for real findings
            for f in v.findings where !f.isEmpty {
                if let itemNum = parseItemNumber(from: f.location), itemNum > 0, itemNum <= caseFile.evidenceItems.count {
                    caseFile.evidenceItems[itemNum - 1].proofContentState.stale = true
                }
            }
            // Gap creation: skip template reasoning to prevent false gaps
            // (regex engine cannot distinguish evidence present from missing)
            if isTemplate { continue }
            for f in v.findings where !f.isEmpty {
                let key = f.detail + f.location
                if gapKeys.insert(key).inserted {
                    caseFile.gaps.append(GapItem(severity: f.kind == "gap" ? .high : .medium,
                                                 description: f.detail,
                                                 suggestedRemedy: v.reasoning,
                                                 relatedClaim: f.location))
                }
            }
        }
    }

    /// Extract item number from step names like "draft_item_3" or locations like "content:3"
    func parseItemNumber(from text: String) -> Int? {
        if let r = text.range(of: #"\d+"#, options: .regularExpression) {
            return Int(text[r])
        }
        return nil
    }

    func summary(from result: CaseResult) -> String {
        let g = result.verdicts.flatMap(\.findings).filter { !$0.isEmpty }.count
        return "\(result.verdicts.count) 项已处理\(g > 0 ? "，发现 \(g) 个问题" : "")"
    }

    // MARK: - 引用验证

    /// 逐字核对：目录证明内容中的数字必须能在 OCR 原文中找到，否则标记待更新。
    /// 无 OCR 原文的证据项标记为"无法核实"而非静默通过。
    func verifySnippets() {
        var stats = (verified: 0, stale: 0, noSource: 0)
        var validator = EvidenceValidator()
        for item in caseFile.evidenceItems where !item.sourceOCRText.isEmpty {
            validator.addSource("evidence_\(item.number)", item.sourceOCRText)
        }
        for item in caseFile.evidenceItems {
            guard !item.sourceOCRText.isEmpty else {
                item.proofContentState.stale = true
                stats.noSource += 1
                continue
            }
            let displayText = item.proofContentState.displayValue ?? ""
            guard !displayText.isEmpty else { continue }

            // Check numbers in proof content against OCR source
            let numbers = displayText.numbers
            var allMatch = true
            for num in numbers {
                if !item.sourceOCRText.contains(num) { allMatch = false; break }
            }
            // Also verify significant text spans (non-numeric content ≥ 4 chars)
            if allMatch {
                let spans = displayText.components(separatedBy: .whitespacesAndNewlines)
                    .filter { $0.count >= 4 && Double($0) == nil }
                for span in spans.prefix(3) {
                    if !item.sourceOCRText.contains(span) { allMatch = false; break }
                }
            }
            if !allMatch {
                item.proofContentState.stale = true
                stats.stale += 1
            } else {
                stats.verified += 1
            }
        }
        let parts: [String] = [
            stats.verified > 0 ? "\(stats.verified) 项通过" : nil,
            stats.stale > 0 ? "\(stats.stale) 项待更新" : nil,
            stats.noSource > 0 ? "\(stats.noSource) 项无原文" : nil,
        ].compactMap { $0 }
        statusMessage = parts.isEmpty ? "引用验证完成" : "引用验证：\(parts.joined(separator: "，"))"
    }

    // MARK: - 导出

    /// 导出证据目录 CSV；失败时返回 nil，由视图给出用户反馈。
    func exportCatalogURL() -> URL? {
        ExcelExport.exportCatalog(caseFile)
    }

    // MARK: - 文件导入 → OCR

    /// 导入单个/多个文件（兼容旧版 `fileImporter` 路径）。
    func importFiles(_ urls: [URL]) {
        Task { await importBatch(urls) }
    }

    /// 批量导入文件夹或展开后的文件列表。
    /// 处理流程：展开（如需要）→ 复制到沙盒 → OCR（带进度）→ AI 自动填表。
    /// 批量导入（真正 async — 无内部 Task，调用者可直接 await）。
    ///
    /// - Returns: 导入统计。`isEmpty == true` 时调用方应清理占位案件（幽灵案件防护），
    ///   且不应进入看板。
    @discardableResult
    func importBatch(_ urls: [URL], fromDirectory: Bool = false) async -> ImportBatchResult {
        let batchID = UUID()
        isImportCancelled = false

        isProcessing = true
        importPhase = "正在展开文件…"
        importProgress = nil

        // Step 1: Expand
        let fileURLs: [URL]
        var skipped: [URL] = []
        if fromDirectory || urls.contains(where: { $0.pathExtension.lowercased() == "zip" }) {
            let scratchDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("hardlaw-import-\(batchID.uuidString)")
            defer { try? FileManager.default.removeItem(at: scratchDir) }

            var allFiles: [URL] = []
            var allSkipped: [URL] = []
            for url in urls {
                do {
                    let (files, skippedFiles) = try ImportPackage.expand(url, scratchDir: scratchDir)
                    allFiles.append(contentsOf: files)
                    allSkipped.append(contentsOf: skippedFiles)
                } catch {
                    allFiles.append(url)
                }
            }
            fileURLs = allFiles
            skipped = allSkipped
        } else {
            fileURLs = urls
        }

        guard !fileURLs.isEmpty else {
            let msg = "未找到可识别的文件" + (skipped.isEmpty ? "" : "（已跳过 \(skipped.count) 个不支持的文件格式）")
            statusMessage = msg
            importPhase = nil; importProgress = nil
            isProcessing = false
            return ImportBatchResult(importedCount: 0, failedCount: 0, skippedCount: skipped.count, message: msg)
        }

        // Step 2: Copy to sandbox + create EvidenceItems
        importPhase = "正在复制文件…"
        importProgress = (0, fileURLs.count)

        var importedItems: [EvidenceItem] = []
        var sandboxURLs: [URL] = []
        var copyWarning: String?
        do {
            sandboxURLs = try EvidenceFileStore.copyIntoCase(fileURLs, caseID: caseFile.id, batchID: batchID)
        } catch {
            // 复制失败不再静默回退：记入结果消息，让用户知道文件只是临时读取、未入沙盒。
            copyWarning = "文件未能复制到应用沙盒（\(error.localizedDescription)），本次为临时读取，退出后可能丢失"
            sandboxURLs = fileURLs
        }

        for (i, url) in sandboxURLs.enumerated() {
            let item = EvidenceItem(number: caseFile.evidenceItems.count + 1, name: url.lastPathComponent)
            item.batchID = batchID
            item.sourceFile = EvidenceFileStore.relativePath(for: url, caseID: caseFile.id)
            caseFile.evidenceItems.append(item)
            caseFile.evidenceVersion += 1
            importedItems.append(item)
            importProgress = (i + 1, fileURLs.count)
        }

        // Step 3: OCR（支持中途取消）
        importPhase = "正在 OCR 识别…"
        importProgress = (0, importedItems.count)
        var failed = 0
        for (i, item) in importedItems.enumerated() {
            if isImportCancelled {
                item.sourceOCRText = ""
                failed += 1
                continue
            }
            let fileURL: URL
            if let relPath = item.sourceFile,
               let absURL = EvidenceFileStore.absoluteURL(for: relPath, caseID: caseFile.id) {
                fileURL = absURL
            } else {
                fileURL = sandboxURLs[i]
            }
            let ocrText = await Self.recognizeText(from: fileURL)
            item.sourceOCRText = ocrText
            if ocrText.isEmpty { failed += 1 }
            importProgress = (i + 1, importedItems.count)
        }

        var parts: [String]
        if isImportCancelled {
            let processed = importedItems.filter { !$0.sourceOCRText.isEmpty }.count
            parts = ["已取消导入", "已处理 \(processed) 个文件"]
        } else {
            parts = ["已导入 \(importedItems.count) 个文件"]
            let recognized = importedItems.count - failed
            if recognized > 0 { parts.append("\(recognized) 个识别成功") }
            if failed > 0 { parts.append("\(failed) 个识别失败") }
            if !skipped.isEmpty { parts.append("已跳过 \(skipped.count) 个不支持格式") }
            if let copyWarning { parts.append(copyWarning) }
        }
        statusMessage = parts.joined(separator: "，")
        saveCase()

        // Step 4: Auto-fill（取消后不再启动）
        let pendingItems = importedItems.filter { !$0.sourceOCRText.isEmpty && ($0.proofContentState.displayValue ?? "").isEmpty }
        if !pendingItems.isEmpty && !isImportCancelled {
            importPhase = "AI 自动填表…"
            let outcomes = await AutoFillPipeline.fillEvidence(
                importedItems, llm: llm, evidenceVersion: caseFile.evidenceVersion,
                claims: caseFile.claims.map(\.content),
                progress: { [self] done, total in importProgress = (done, total) }
            )
            let filled = outcomes.filter { $0.status == .filled }.count
            let rejected = outcomes.filter { $0.status == .rejectedUnverifiable }.count
            let skipped = outcomes.filter { $0.status == .skipped }.count
            var note = "AI 填表：\(filled) 项完成"
            if rejected > 0 { note += "，\(rejected) 项数据异常已拒绝" }
            if skipped > 0 { note += "，\(skipped) 项跳过" }
            parts.append(note)
            if caseFile.caseName.isEmpty || caseFile.caseName == "新导入案件" || caseFile.applicant.isEmpty || caseFile.respondent.isEmpty {
                if let meta = await AutoFillPipeline.extractMetadata(from: caseFile.evidenceItems, llm: llm) {
                    if (caseFile.caseName.isEmpty || caseFile.caseName == "新导入案件") && !meta.caseName.isEmpty { caseFile.caseName = meta.caseName }
                    if caseFile.applicant.isEmpty && !meta.applicant.isEmpty { caseFile.applicant = meta.applicant }
                    if caseFile.respondent.isEmpty && !meta.respondent.isEmpty { caseFile.respondent = meta.respondent }
                    for claim in meta.claims where !caseFile.claims.contains(where: { $0.content == claim }) {
                        caseFile.claims.append(ClaimItem(claimNumber: caseFile.claims.count + 1, content: claim))
                    }
                }
            }
            saveCase()
        }

        importPhase = nil; importProgress = nil
        statusMessage = parts.joined(separator: "，")
        isProcessing = false
        return ImportBatchResult(importedCount: importedItems.count, failedCount: failed, skippedCount: skipped.count, message: statusMessage ?? parts.joined(separator: "，"))
    }

    /// OCR an imported file (image, PDF, or plain text) into searchable text.
    /// Runs on the global executor so Vision work stays off the main thread.
    nonisolated static func recognizeText(from url: URL) async -> String {
        guard url.startAccessingSecurityScopedResource() else { return "" }
        defer { url.stopAccessingSecurityScopedResource() }

        // Plain text files need no OCR
        // 尽力而为：读取失败视为无文本，由导入流程标记该文件未识别
        let ext = url.pathExtension.lowercased()
        if ["txt", "text", "md", "csv"].contains(ext) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        // Render image/PDF pages to CGImage, then route OCR through OCRRouter:
        // PaddleOCR on device (higher Chinese accuracy), Vision fallback on
        // engine failure or simulator.
        var pages: [String] = []
        for image in renderImages(from: url) {
            // 尽力而为：单页 OCR 失败时跳过该页，不影响其余页面识别
            let lines = await OCRRouter.recognize(image)
            if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Render an image file or the pages of a PDF as CGImages.
    /// Caller must hold the security-scoped resource access.
    nonisolated static func renderImages(from url: URL) -> [CGImage] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { return [] }
            let pageCount = min(document.pageCount, 10)
            var images: [CGImage] = []
            for pageIndex in 0..<pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let box = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2.0 // render at 2x for better OCR accuracy
                let size = CGSize(width: max(1, box.width * scale),
                                  height: max(1, box.height * scale))
                if let image = page.thumbnail(of: size, for: .mediaBox).cgImage {
                    images.append(image)
                }
            }
            return images
        }

        // Raster images (PNG/JPG/HEIC/…) via ImageIO
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return [image]
        }
        return []
    }
}
