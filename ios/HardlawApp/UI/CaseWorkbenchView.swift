import SwiftUI
import HardlawKit

// MARK: - 案件看板（单一滚动视图，替代 TabView）
// 业务编排见 CourtViewModel.swift；分区与编辑器视图见 CaseSectionsView.swift；
// 审查目标进度条见 GoalProgressView.swift。

struct CaseWorkbenchView: View {
    @Bindable var caseFile: CaseFile
    @State private var viewModel: CourtViewModel
    @State private var showEvidenceEditor = false
    @State private var editingItem: EvidenceItem?
    @State private var commandText = ""
    @State private var expandedNeedsYou = false
    @State private var showFileImporter = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    init(caseFile: CaseFile) {
        self.caseFile = caseFile
        _viewModel = State(initialValue: CourtViewModel(caseFile: caseFile))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CaseHeader(caseFile: caseFile)

                if let statusMessage = viewModel.statusMessage {
                    StatusBanner(text: statusMessage) { viewModel.statusMessage = nil }
                }

                if let goal = viewModel.goal {
                    GoalProgressView(goal: goal)
                }

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
                    Button { exportCatalog() } label: {
                        Label("导出目录", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            CommandBar(text: $commandText, isProcessing: $viewModel.isProcessing,
                       placeholder: nextAction, onSubmit: handleCommand,
                       onImport: { showFileImporter = true })
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image, .plainText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { viewModel.importFiles(urls) }
        }
        .sheet(isPresented: $showEvidenceEditor) {
            if let item = editingItem { EvidenceEditorView(item: item) }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareLink(item: url) {
                    Label("分享导出的证据目录", systemImage: "square.and.arrow.up")
                }
                .padding(24)
                .presentationDetents([.medium])
            }
        }
        .onAppear { viewModel.verifySnippets() }
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

    func handleCommand(_ text: String) { viewModel.handleCommand(text) }
    func handleNeedsYouTap(_ item: NeedsYouItem) { item.action() }

    func addNewEvidence() {
        let item = EvidenceItem(number: caseFile.evidenceItems.count + 1)
        caseFile.evidenceItems.append(item)
        caseFile.evidenceVersion += 1 // 新证据入卷 — 版本递增
        editingItem = item
        showEvidenceEditor = true
    }

    /// 导出证据目录 CSV；失败时给出用户可见反馈。
    func exportCatalog() {
        if let url = viewModel.exportCatalogURL() {
            shareURL = url
            showShareSheet = true
        } else {
            viewModel.statusMessage = "导出失败：无法生成目录文件，请重试"
        }
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

// MARK: - 共享组件

/// 状态提示条：展示 statusMessage（操作结果 / 错误反馈），可手动关闭。
struct StatusBanner: View {
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        let isError = text.contains("失败") || text.contains("错误")
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? .red : .blue)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((isError ? Color.red : Color.blue).opacity(0.08))
    }
}

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
