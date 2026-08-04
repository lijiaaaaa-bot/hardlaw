import SwiftUI
import HardlawKit
import PhotosUI

/// 案件工作台 — 证据目录 + Gap 报告 + 导出
struct CaseWorkbenchView: View {
    @Bindable var caseFile: CaseFile
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    @State private var showEvidenceEditor = false
    @State private var editingItem: EvidenceItem?
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: 证据目录
            EvidenceListView(caseFile: caseFile, onAddEvidence: {
                let newItem = EvidenceItem(number: caseFile.evidenceItems.count + 1)
                caseFile.evidenceItems.append(newItem)
                editingItem = newItem
                showEvidenceEditor = true
            }, onEdit: { item in
                editingItem = item
                showEvidenceEditor = true
            })
            .tabItem { Label("证据目录", systemImage: "list.clipboard") }
            .tag(0)

            // Tab 2: Gap 报告
            GapReportView(caseFile: caseFile)
                .tabItem { Label("待核实 (\(caseFile.gaps.count))", systemImage: "exclamationmark.triangle") }
                .tag(1)

            // Tab 3: 导出
            ExportView(caseFile: caseFile)
                .tabItem { Label("导出", systemImage: "square.and.arrow.up") }
                .tag(2)
        }
        .navigationTitle(caseFile.caseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    // 阶段指示器
                    Text("步骤 \(caseFile.stage.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showEvidenceEditor) {
            if let item = editingItem {
                EvidenceEditorView(item: item)
            }
        }
        .onAppear {
            runAutoVerification()
        }
    }

    /// 自动运行验证
    private func runAutoVerification() {
        // 验证每条证据的 proofContent 是否与 OCR 文字一致
        var validator = EvidenceValidator()
        for item in caseFile.evidenceItems {
            if !item.sourceOCRText.isEmpty {
                validator.addSource("evidence_\(item.number)", item.sourceOCRText)
            }
        }

        for item in caseFile.evidenceItems {
            guard !item.sourceOCRText.isEmpty else { continue }

            // 检查证明内容中的关键数字是否存在于源文件
            let keyNumbers = extractKeyNumbers(from: item.proofContent)
            var allVerified = true
            for num in keyNumbers {
                if !item.sourceOCRText.contains(num) {
                    allVerified = false
                    break
                }
            }

            item.verificationStatus = allVerified ? .verified : .inconsistent
        }

        // 自动检测常见缺口
        detectCommonGaps()
    }

    /// 检测常见证据缺口
    private func detectCommonGaps() {
        caseFile.gaps = []

        // 检查必要证据类型
        let evidenceNames = Set(caseFile.evidenceItems.map { $0.name })
        let criticalTypes = [
            "劳动合同": "证明劳动关系和工资标准",
            "银行流水": "证明实际工资发放和欠薪事实",
            "参保证明": "证明劳动关系存续期间"
        ]

        for (typeName, purpose) in criticalTypes {
            if !evidenceNames.contains(where: { $0.contains(typeName) }) {
                caseFile.gaps.append(GapItem(
                    severity: .high,
                    description: "缺少\(typeName)",
                    suggestedRemedy: "建议补充\(typeName)（\(purpose)）",
                    relatedClaim: "全部请求"
                ))
            }
        }

        // 检查原件比例
        let originalCount = caseFile.evidenceItems.filter { $0.isOriginal }.count
        if Double(originalCount) / Double(max(caseFile.evidenceItems.count, 1)) < 0.5 {
            caseFile.gaps.append(GapItem(
                severity: .medium,
                description: "原件比例偏低（\(originalCount)/\(caseFile.evidenceItems.count)），开庭时可能被要求提供原件核对",
                suggestedRemedy: "尽量补充原件，复印件需与原件核对一致"
            ))
        }

        // 检查薪资一致性
        let salaryItems = caseFile.evidenceItems.filter {
            $0.name.contains("工资") || $0.proofContent.contains("工资") || $0.proofContent.contains("元")
        }
        if salaryItems.count >= 2 {
            let salaryNumbers = salaryItems.flatMap { extractKeyNumbers(from: $0.proofContent) }
            let uniqueSalaries = Set(salaryNumbers)
            if uniqueSalaries.count > 1 {
                caseFile.gaps.append(GapItem(
                    severity: .medium,
                    description: "多份证据显示的工资金额不完全一致：\(uniqueSalaries.sorted().joined(separator: "、"))",
                    suggestedRemedy: "社保缴费基数不等于实际工资（社平60%-300%为正常范围）。确认以工资表和银行流水为准。",
                    relatedClaim: "欠薪相关请求"
                ))
            }
        }
    }

    private func extractKeyNumbers(from text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\d+\.?\d*"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - 证据目录列表

struct EvidenceListView: View {
    @Bindable var caseFile: CaseFile
    let onAddEvidence: () -> Void
    let onEdit: (EvidenceItem) -> Void

    var body: some View {
        List {
            // 概览
            Section {
                HStack {
                    StatBadge(label: "证据总数", value: "\(caseFile.evidenceItems.count)")
                    StatBadge(label: "原件", value: "\(caseFile.evidenceItems.filter(\.isOriginal).count)")
                    StatBadge(label: "已核实", value: "\(caseFile.evidenceItems.filter { $0.verificationStatus == .verified }.count)")
                }
            }

            // 按组别分组显示
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(caseFile.evidenceItems.filter { $0.group == group }) { item in
                        EvidenceRow(item: item, onEdit: { onEdit(item) })
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddEvidence) {
                    Image(systemName: "plus")
                }
            }
        }
    }

    var groups: [String] {
        let all = Set(caseFile.evidenceItems.map(\.group)).filter { !$0.isEmpty }
        return all.isEmpty ? ["未分组"] : Array(all).sorted()
    }
}

struct StatBadge: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).fontWeight(.bold)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct EvidenceRow: View {
    let item: EvidenceItem
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("编号 \(item.number)")
                        .font(.caption).foregroundStyle(.blue)
                    Spacer()
                    VerificationBadge(status: item.verificationStatus)
                }
                Text(item.name)
                    .font(.subheadline).fontWeight(.medium)
                if !item.proofContent.isEmpty {
                    Text(item.proofContent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !item.proofPurpose.isEmpty {
                    Text("证明目的：\(item.proofPurpose)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Label(item.isOriginal ? "原件" : "复印件", systemImage: item.isOriginal ? "doc.fill" : "doc")
                    Label("\(item.pageCount)页", systemImage: "text.page")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

struct VerificationBadge: View {
    let status: VerificationStatus
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(status.rawValue)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
    var icon: String {
        switch status {
        case .unverified: return "circle"
        case .verified: return "checkmark.circle.fill"
        case .inconsistent: return "exclamationmark.triangle.fill"
        case .needsReview: return "eye"
        }
    }
    var color: Color {
        switch status {
        case .unverified: return .gray
        case .verified: return .green
        case .inconsistent: return .orange
        case .needsReview: return .blue
        }
    }
}

// MARK: - 证据编辑

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

                Section("证明内容（AI 可辅助生成）") {
                    TextEditor(text: $item.proofContent)
                        .frame(minHeight: 100)
                        .font(.callout)
                }

                Section("证明目的") {
                    TextEditor(text: $item.proofPurpose)
                        .frame(minHeight: 80)
                        .font(.callout)
                }

                Section("源文件 OCR 文字") {
                    if item.sourceOCRText.isEmpty {
                        Text("尚未导入源文件。点击下方按钮拍照或选择图片导入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.sourceOCRText)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(10)
                    }
                    // TODO: PhotosPicker integration for OCR
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

// MARK: - Gap 报告

struct GapReportView: View {
    @Bindable var caseFile: CaseFile

    var body: some View {
        List {
            if caseFile.gaps.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 40)).foregroundStyle(.green)
                        Text("暂未发现证据缺口")
                            .font(.headline)
                        Text("添加更多证据后，系统将自动检测不一致和缺失项")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                }
            } else {
                ForEach(caseFile.gaps) { gap in
                    GapRow(gap: gap)
                        .swipeActions(edge: .trailing) {
                            Button { gap.isResolved = true } label: {
                                Label("已解决", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                }
            }
        }
    }
}

struct GapRow: View {
    @Bindable var gap: GapItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                GapSeverityBadge(severity: gap.severity)
                Spacer()
                if gap.isResolved {
                    Text("已解决").font(.caption).foregroundStyle(.green)
                }
            }
            Text(gap.description).font(.subheadline)
            if !gap.suggestedRemedy.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("补证建议：").font(.caption).fontWeight(.medium).foregroundStyle(.blue)
                    Text(gap.suggestedRemedy).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !gap.relatedClaim.isEmpty {
                Text("关联请求：\(gap.relatedClaim)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .opacity(gap.isResolved ? 0.5 : 1)
    }
}

struct GapSeverityBadge: View {
    let severity: GapSeverity
    var body: some View {
        Text(severity.rawValue)
            .font(.caption2).fontWeight(.bold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    var color: Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .gray
        }
    }
}

// MARK: - 导出

struct ExportView: View {
    let caseFile: CaseFile

    var body: some View {
        List {
            Section("证据目录导出") {
                ExportButton(title: "导出为 Excel 表格", icon: "tablecells", description: "七列证据目录，可直接提交仲裁委")
                ExportButton(title: "导出证据目录 + 待核实清单", icon: "doc.richtext", description: "包含所有证据项、验证状态和补证建议")
            }
            Section("案件摘要") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("案由：\(caseFile.caseName)").font(.callout)
                    Text("申请人：\(caseFile.applicant)").font(.callout)
                    Text("被申请人：\(caseFile.respondent)").font(.callout)
                    Text("仲裁请求：\(caseFile.claims.count) 项").font(.callout)
                    Text("证据：\(caseFile.evidenceItems.count) 项，\(caseFile.gaps.count) 个待核实问题").font(.callout)
                }
            }
        }
        .navigationTitle("导出")
    }
}

struct ExportButton: View {
    let title: String; let icon: String; let description: String
    var body: some View {
        Button {} label: {
            HStack {
                Image(systemName: icon).font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text(title).font(.callout)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
