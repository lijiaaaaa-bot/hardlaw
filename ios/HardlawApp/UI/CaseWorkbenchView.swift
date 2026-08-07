import SwiftUI
import CoreGraphics
import ImageIO
import PDFKit
import HardlawKit

// MARK: - 案件看板（单一滚动视图，替代 TabView）

struct CaseWorkbenchView: View {
    @Bindable var caseFile: CaseFile
    @Environment(\.dismiss) private var dismiss
    @State private var showEvidenceEditor = false
    @State private var editingItem: EvidenceItem?
    @State private var commandText = ""
    @State private var isProcessing = false
    @State private var expandedNeedsYou = false
    @State private var statusMessage: String?
    @State private var showFileImporter = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CaseHeader(caseFile: caseFile)

                if !activeItems.isEmpty {
                    NeedsYouSection(
                        items: activeItems,
                        expanded: $expandedNeedsYou,
                        onTap: handleNeedsYouTap
                    )
                }

                ClaimsSection(caseFile: caseFile)

                EvidenceSection(
                    caseFile: caseFile,
                    onAdd: { addNewEvidence() },
                    onEdit: { item in editingItem = item; showEvidenceEditor = true }
                )

                ActivitySection(caseFile: caseFile)

                // Spacer so command bar clears content
                Color.clear.frame(height: 80)
            }
        }
        .navigationTitle(caseFile.caseName.isEmpty ? "未命名案件" : caseFile.caseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { addNewEvidence() } label: {
                        Label("添加证据", systemImage: "plus.rectangle")
                    }
                    if let url = ExcelExport.exportCatalog(caseFile) {
                        ShareLink(item: url) {
                            Label("导出目录", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            CommandBar(text: $commandText, isProcessing: $isProcessing,
                       placeholder: nextAction, onSubmit: handleCommand,
                       onImport: { showFileImporter = true })
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image, .plainText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                var importedItems: [EvidenceItem] = []
                for url in urls {
                    let item = EvidenceItem(number: caseFile.evidenceItems.count + 1,
                                            name: url.lastPathComponent)
                    caseFile.evidenceItems.append(item)
                    importedItems.append(item)
                }
                statusMessage = "已导入 \(urls.count) 个文件，正在OCR识别…"
                isProcessing = true
                Task {
                    var failed = 0
                    for (url, item) in zip(urls, importedItems) {
                        let ocrText = await Self.recognizeText(from: url)
                        item.sourceOCRText = ocrText
                        if ocrText.isEmpty { failed += 1 }
                    }
                    statusMessage = failed == 0
                        ? "已完成 \(urls.count) 个文件的识别"
                        : "\(urls.count - failed) 个文件识别成功，\(failed) 个未识别"
                    try? PersistenceController.shared.save(caseFile)
                    isProcessing = false
                }
            }
        }
        .sheet(isPresented: $showEvidenceEditor) {
            if let item = editingItem {
                EvidenceEditorView(item: item)
            }
        }
        .onAppear { verifySnippets() }
    }

    // MARK: - Derived state

    var nextAction: String {
        if caseFile.evidenceItems.isEmpty { return "描述案情，或点 + 添加第一份证据" }
        let stale = caseFile.evidenceItems.filter { $0.proofContentState.stale }.count
        if stale > 0 { return "\(stale) 项待更新 — 输入「全面复核」" }
        let unverified = caseFile.evidenceItems.filter { $0.proofContentState.status == .machineDraft }.count
        if unverified > 0 { return "\(unverified) 项待核实确认" }
        return "输入指令 · 或点 + 添加证据"
    }

    var activeItems: [NeedsYouItem] {
        var items: [NeedsYouItem] = []
        for item in caseFile.evidenceItems where item.proofContentState.needsAttention {
            items.append(NeedsYouItem(kind: .needsReview,
                title: "证据\(item.number) 待核实", detail: item.name,
                action: { editingItem = item; showEvidenceEditor = true }))
        }
        for gap in caseFile.gaps where !gap.isResolved {
            items.append(NeedsYouItem(kind: .gap, title: gap.description,
                detail: gap.suggestedRemedy, action: { /* TODO: focus gap */ }))
        }
        return items
    }

    // MARK: - Actions

    func addNewEvidence() {
        let item = EvidenceItem(number: caseFile.evidenceItems.count + 1)
        caseFile.evidenceItems.append(item)
        editingItem = item
        showEvidenceEditor = true
    }

    func handleNeedsYouTap(_ item: NeedsYouItem) { item.action() }

    func handleCommand(_ text: String) {
        let intent = IntentParser.parse(text, stage: caseFile.stage)
        guard intent.isParsed else {
            statusMessage = "试试：补充银行流水 / 生成目录 / 检查工资 / 全面复核"
            return
        }
        isProcessing = true
        Task {
            if let result = await executeIntent(intent) {
                applyVerdicts(result)
                statusMessage = summary(from: result)
            }
            try? PersistenceController.shared.save(caseFile)
            isProcessing = false
            let msg = statusMessage
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if statusMessage == msg { statusMessage = nil }
            }
        }
    }

    func executeIntent(_ intent: ParsedIntent) async -> CaseResult? {
        switch intent.kind {
        case .generateCatalog:
            let count = caseFile.evidenceItems.count
            guard count > 0, let proc = try? CourtProcedures.catalogGeneration(itemCount: count) else { return nil }
            statusMessage = "生成 \(count) 项目录…"
            return await runCourt(proc, statutes: StatuteBook())
        case .fullReview:
            let count = caseFile.evidenceItems.count
            guard count > 0, let proc = try? CourtProcedures.fullReview(itemCount: count) else { return nil }
            statusMessage = "全面复核中…"
            return await runCourt(proc, statutes: StatuteBook())
        case .detectGaps:
            guard let proc = try? CourtProcedures.gapDetection() else { return nil }
            statusMessage = "检测证据缺口…"
            return await runCourt(proc, statutes: LaborLawStatutes.gapDetectionBook)
        case .checkConsistency:
            guard let proc = try? CourtProcedures.salaryConsistency() else { return nil }
            statusMessage = "工资一致性检查…"
            return await runCourt(proc, statutes: StatuteBook())
        case .verifyCitations:
            verifySnippets()
            statusMessage = "引用验证完成"
            return nil
        default:
            let r = IntentHandler.handle(intent, caseFile: caseFile)
            statusMessage = r.message
            return nil
        }
    }

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
        // LegalKnowledge citations as prompt context
        let store = LawStore()
        try? store.load(from: .main)
        if store.chunkCount > 0 {
            let query = caseFile.claims.map(\.content).joined(separator: " ")
            let results = await LawIndex(store: store).search(query, k: 5)
            let cites = results.map { "\($0.chunk.lawID)第\($0.chunk.articleNum)条" }
            caseData["legal_citations"] = .string(cites.joined(separator: "; "))
        }
        let llm: any LLMBackend = RuleBasedLLM(rules: RuleBasedLLM.defaultRules())
        let court = Court(statutes: statutes, procedure: procedure, llm: llm)
        return await court.hear(caseData: caseData)
    }

    func applyVerdicts(_ result: CaseResult) {
        for (i, verdict) in result.verdicts.enumerated() {
            guard i < caseFile.evidenceItems.count else { break }
            let item = caseFile.evidenceItems[i]
            if !verdict.reasoning.isEmpty {
                _ = item.proofContentState.merge(newMachineValue: verdict.reasoning, directlyAffected: false, evidenceVersion: 0)
            }
            for f in verdict.findings where !f.isEmpty { item.proofContentState.stale = true }
        }
        for v in result.verdicts {
            for f in v.findings where !f.isEmpty {
                caseFile.gaps.append(GapItem(severity: f.kind == "gap" ? .high : .medium, description: f.detail, suggestedRemedy: v.reasoning, relatedClaim: f.location))
            }
        }
    }

    func summary(from result: CaseResult) -> String {
        let g = result.verdicts.flatMap(\.findings).filter { !$0.isEmpty }.count
        return "\(result.verdicts.count) 项已处理\(g > 0 ? "，发现 \(g) 个问题" : "")"
    }

    func verifySnippets() {
        var validator = EvidenceValidator()
        for item in caseFile.evidenceItems where !item.sourceOCRText.isEmpty {
            validator.addSource("evidence_\(item.number)", item.sourceOCRText)
        }
        for item in caseFile.evidenceItems {
            guard !item.sourceOCRText.isEmpty else { continue }
            let numbers = extractKeyNumbers(from: item.proofContentState.displayValue ?? "")
            var allMatch = true
            for num in numbers {
                if !item.sourceOCRText.contains(num) { allMatch = false; break }
            }
            if !allMatch { item.proofContentState.stale = true }
        }
    }

    func extractKeyNumbers(from text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\d+\.?\d*"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - File import → OCR

    /// OCR an imported file (image, PDF, or plain text) into searchable text.
    /// Runs on the global executor so Vision work stays off the main thread.
    private static func recognizeText(from url: URL) async -> String {
        guard url.startAccessingSecurityScopedResource() else { return "" }
        defer { url.stopAccessingSecurityScopedResource() }

        // Plain text files need no OCR
        let ext = url.pathExtension.lowercased()
        if ["txt", "text", "md", "csv"].contains(ext) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        // Render image/PDF pages to CGImage, then run Vision OCR.
        // recognizeTextChinese preprocesses each rendered page (grayscale,
        // contrast stretch, deskew, binarization) before OCR so low-quality
        // scans and handwritten Chinese annotations are recovered.
        let collector = VisionEvidenceCollector()
        var pages: [String] = []
        for image in renderImages(from: url) {
            if let result = try? await collector.recognizeTextChinese(in: image) {
                pages.append(result.fullText)
            }
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Render an image file or the pages of a PDF as CGImages.
    /// Caller must hold the security-scoped resource access.
    private static func renderImages(from url: URL) -> [CGImage] {
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

// MARK: - NeedsYouItem

struct NeedsYouItem: Identifiable {
    let id = UUID()
    enum Kind { case gap, needsReview, conflict }
    var kind: Kind
    var title: String
    var detail: String
    var action: () -> Void
}

// MARK: - Case Header

struct CaseHeader: View {
    @Bindable var caseFile: CaseFile

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(caseFile.caseName.isEmpty ? "未命名案件" : caseFile.caseName)
                    .font(.title3).fontWeight(.bold)
                Spacer()
                StageChip(stage: caseFile.stage)
            }

            HStack {
                Label(caseFile.applicant, systemImage: "person.fill")
                Text("v.")
                Label(caseFile.respondent, systemImage: "building.2.fill")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.top, 4)
        }
        .padding(.horizontal).padding(.top, 8)
    }

}

struct StageChip: View {
    let stage: CaseStage
    var body: some View {
        Text(stage.rawValue)
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
    }
    var color: Color {
        switch stage {
        case .drafting: return .gray; case .evidenceCollection: return .blue
        case .catalogReview: return .orange; case .gapResolution: return .red
        case .readyToFile: return .green
        }
    }
}

// MARK: - NeedsYou Section

struct NeedsYouSection: View {
    let items: [NeedsYouItem]
    @Binding var expanded: Bool

    let onTap: (NeedsYouItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("待办 · \(items.count) 项").font(.subheadline).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
                .padding(.horizontal).padding(.vertical, 10)
                .background(.orange.opacity(0.06))
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        Button { onTap(item) } label: {
                            NeedsYouRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal).padding(.bottom, 8)
                .background(.orange.opacity(0.03))
            }
        }
    }
}

struct NeedsYouRow: View {
    let item: NeedsYouItem
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .conflict ? "xmark.shield.fill" :
                  item.kind == .gap ? "exclamationmark.triangle" : "eye")
                .font(.caption).foregroundStyle(item.kind == .conflict ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.quaternary)
        }
        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Claims Section

struct ClaimsSection: View {
    @Bindable var caseFile: CaseFile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "仲裁请求", count: caseFile.claims.count,
                          icon: "list.number")
            if caseFile.claims.isEmpty {
                Text("暂无请求 — 输入指令让 AI 草拟").font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal)
            } else {
                ForEach(caseFile.claims) { claim in
                    ClaimCard(claim: claim)
                        .padding(.horizontal)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct ClaimCard: View {
    let claim: ClaimItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("请求 \(claim.claimNumber)").font(.caption).foregroundStyle(.blue)
                Spacer()
            }
            Text(claim.content).font(.subheadline)
            if !claim.legalBasis.isEmpty {
                Text(claim.legalBasis).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Evidence Section

struct EvidenceSection: View {
    @Bindable var caseFile: CaseFile
    let onAdd: () -> Void
    let onEdit: (EvidenceItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "证据目录", count: caseFile.evidenceItems.count,
                              icon: "list.clipboard")
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
            }
            .padding(.horizontal)

            if caseFile.evidenceItems.isEmpty {
                Text("点击 + 添加证据，或拖入文件").font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal)
            }

            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group).font(.caption).fontWeight(.medium)
                        .foregroundStyle(.secondary).padding(.horizontal)
                    ForEach(caseFile.evidenceItems.filter { $0.group == group }) { item in
                        Button { onEdit(item) } label: {
                            EvidenceCard(item: item)
                        }
                        .buttonStyle(.plain).padding(.horizontal)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    var groups: [String] {
        let all = Set(caseFile.evidenceItems.map(\.group)).filter { !$0.isEmpty }
        return all.isEmpty ? ["未分组"] : Array(all).sorted()
    }
}

struct EvidenceCard: View {
    let item: EvidenceItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("编号 \(item.number)").font(.caption).foregroundStyle(.blue)
                Spacer()
                EvidenceStatusChip(item: item)
            }
            Text(item.name).font(.subheadline).fontWeight(.medium)
            if let content = item.proofContentState.displayValue, !content.isEmpty {
                Text(content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Label(item.isOriginal ? "原件" : "复印件",
                      systemImage: item.isOriginal ? "doc.fill" : "doc")
                Label("\(item.pageCount)页", systemImage: "text.page")
                if !item.sourceOCRText.isEmpty {
                    Label("有源文件", systemImage: "text.viewfinder")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EvidenceStatusChip: View {
    let item: EvidenceItem
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text(label).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
    }
    var icon: String {
        if item.humanReviewed { return "checkmark.shield.fill" }
        if item.proofContentState.stale { return "exclamationmark.triangle.fill" }
        if item.proofContentState.status == .machineDraft { return "circle.dotted" }
        return "circle"
    }
    var label: String {
        if item.humanReviewed { return "已确认" }
        if item.proofContentState.stale { return "待更新" }
        if item.proofContentState.status == .machineDraft { return "AI草稿" }
        return "待核实"
    }
    var color: Color {
        if item.humanReviewed { return .green }
        if item.proofContentState.stale { return .orange }
        if item.proofContentState.status == .machineDraft { return .blue }
        return .gray
    }
}

// MARK: - Activity Section

struct ActivitySection: View {
    let caseFile: CaseFile
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "最近动态", count: nil, icon: "clock.arrow.circlepath")
                .padding(.horizontal)
            Text(activitySummary)
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    var activitySummary: String {
        let total = caseFile.evidenceItems.count
        let reviewed = caseFile.evidenceItems.filter(\.humanReviewed).count
        if total == 0 { return "尚无活动" }
        return "\(total) 项证据 · \(reviewed) 项已确认"
    }
}

// MARK: - Shared components

struct SectionHeader: View {
    let title: String
    let count: Int?
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.blue)
            Text(title).font(.headline)
            if let count {
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

// MARK: - Command Bar

struct CommandBar: View {
    @Binding var text: String
    @Binding var isProcessing: Bool
    let placeholder: String
    let onSubmit: (String) -> Void
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onImport) {
                Image(systemName: "doc.badge.plus").font(.title3)
            }

            HStack {
                if isProcessing {
                    ProgressView().scaleEffect(0.7).padding(.leading, 4)
                }
                TextField(placeholder, text: $text)
                    .font(.callout)
                    .onSubmit {
                        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        onSubmit(text)
                        text = ""
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())

            Button {
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                onSubmit(text)
                text = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title3)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Evidence Editor (unchanged from v2)

struct EvidenceEditorView: View {
    @Bindable var item: EvidenceItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("组别", text: $item.group)
                    TextField("证据名称", text: $item.name)
                    Stepper("编号: \(item.number)", value: $item.number, in: 1...99)
                    Toggle("原件", isOn: $item.isOriginal)
                    Stepper("页码: \(item.pageCount)", value: $item.pageCount, in: 1...999)
                }

                Section("证明内容") {
                    TextEditor(text: Binding(
                        get: { item.proofContentState.displayValue ?? "" },
                        set: { item.proofContentState.override(with: $0) }
                    ))
                    .frame(minHeight: 100).font(.callout)
                    if item.proofContentState.status == .machineDraft {
                        Label("AI 草稿，请核实后确认", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.blue)
                    }
                    if item.humanReviewed {
                        Label("已逐项核对确认", systemImage: "checkmark.shield.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                Section("证明目的") {
                    TextEditor(text: Binding(
                        get: { item.proofPurposeState.displayValue ?? "" },
                        set: { item.proofPurposeState.override(with: $0) }
                    ))
                    .frame(minHeight: 80).font(.callout)
                }

                Section("源文件 OCR") {
                    if item.sourceOCRText.isEmpty {
                        Text("尚未导入源文件").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(item.sourceOCRText).font(.caption).foregroundStyle(.secondary).lineLimit(10)
                    }
                }

                Section {
                    Button {
                        item.humanReviewed = true
                        item.proofContentState.confirm()
                        item.proofPurposeState.confirm()
                        dismiss()
                    } label: {
                        Label("我已逐项核对，确认与原件一致", systemImage: "checkmark.shield.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(item.proofContentState.displayValue?.isEmpty != false)
                }
            }
            .navigationTitle("编辑证据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Share Sheet (replaced by native ShareLink in the toolbar menu)
