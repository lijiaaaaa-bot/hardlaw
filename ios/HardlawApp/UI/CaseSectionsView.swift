import SwiftUI
import HardlawKit

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

// MARK: - Evidence Editor

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
