import SwiftUI
import UniformTypeIdentifiers

// MARK: - 首页：案件入口

public struct HomeView: View {
    @State private var showNewCase = false
    @State private var showFolderImporter = false
    @State private var cases: [CaseFile] = []
    @State private var selectedCase: CaseFile?
    @State private var statusMessage: String?
    @State private var isImporting = false
    /// 当前进行中的导入任务（持有进度/阶段/取消状态）。仅导入期间非 nil。
    @State private var importVM: CourtViewModel?

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TrustBanner()

                if let statusMessage {
                    StatusBanner(text: statusMessage) { self.statusMessage = nil }
                }

                if cases.isEmpty {
                    EmptyCaseView(onNewCase: { showNewCase = true }, onImport: { showFolderImporter = true })
                } else {
                    CaseListView(cases: cases, onSelect: { selectedCase = $0 },
                                 onNewCase: { showNewCase = true },
                                 onImport: { showFolderImporter = true })
                }
            }
            .navigationTitle("证据链核查")
            .navigationBarTitleDisplayMode(.large)
            .overlay {
                if isImporting {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.5)
                        Text(importVM?.importPhase ?? "正在导入案件材料…")
                            .font(.headline)
                        if let progress = importVM?.importProgress, progress.total > 0 {
                            ProgressView(value: Double(progress.done), total: Double(progress.total))
                                .tint(.blue)
                                .frame(width: 220)
                            Text("\(progress.done)/\(progress.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("OCR 识别 + AI 自动填表")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            importVM?.cancelImport()
                        } label: {
                            Text("取消").font(.subheadline)
                        }
                    }
                    .padding(32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showNewCase) {
                CaseIntakeView { newCase in
                    cases.append(newCase)
                    do {
                        try PersistenceController.shared.save(newCase)
                    } catch {
                        statusMessage = "保存失败：\(error.localizedDescription)"
                    }
                    selectedCase = newCase
                    showNewCase = false
                }
            }
            .fileImporter(isPresented: $showFolderImporter,
                          allowedContentTypes: [.folder, .pdf, .image, .plainText, UTType(filenameExtension: "zip") ?? .archive],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    // Security-scoped access 必须在文件选择器回调内获取，
                    // 且作用域要存活到异步导入真正读完文件为止（见 importFolder 的 Task）。
                    let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                    guard scoped.count == urls.count else {
                        statusMessage = "无法访问所选文件（权限不足）"
                        return
                    }
                    importFolder(urls, scoped: scoped)
                }
            }
            .navigationDestination(item: $selectedCase) { caseFile in
                CaseWorkbenchView(caseFile: caseFile)
                    .onDisappear {
                        do {
                            try PersistenceController.shared.save(caseFile)
                        } catch {
                            statusMessage = "保存失败：\(error.localizedDescription)"
                        }
                    }
            }
        }
        .onAppear {
            do {
                cases = try PersistenceController.shared.loadAll()
            } catch {
                statusMessage = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    /// 从文件夹/压缩包新建案件：展开 → 复制 → OCR → AI 填表 → 提取元数据。
    /// `scoped` 为已获取 security-scoped access 的 URL，作用域在异步导入
    /// 完全结束（Task 末尾）时才释放，避免任务内读取文件时权限已失效。
    private func importFolder(_ urls: [URL], scoped: [URL]) {
        isImporting = true
        let newCase = CaseFile(caseName: "新导入案件", applicant: "", respondent: "")
        let vm = CourtViewModel(caseFile: newCase)
        importVM = vm

        Task {
            defer {
                for url in scoped { url.stopAccessingSecurityScopedResource() }
            }

            let result = await vm.importBatch(urls, fromDirectory: true)

            // 幽灵案件清理：没有任何文件被导入时不进入看板，
            // 删除占位案件（JSON + 可能已复制进沙盒的证据目录）。
            guard !result.isEmpty else {
                try? PersistenceController.shared.delete(id: newCase.id)
                try? EvidenceFileStore.removeCaseEvidence(caseID: newCase.id)
                cases.removeAll { $0.id == newCase.id }
                statusMessage = result.message
                isImporting = false
                importVM = nil
                return
            }

            // 案名兜底：AI 未提取到时使用文件夹/压缩包名（而非其父目录名）。
            if newCase.caseName.isEmpty || newCase.caseName == "新导入案件" {
                newCase.caseName = derivedCaseName(from: urls)
            }
            if newCase.claims.isEmpty {
                newCase.claims = [ClaimItem(claimNumber: 1, content: "待确认仲裁请求")]
            }
            try? PersistenceController.shared.save(newCase)

            statusMessage = result.message
            isImporting = false
            importVM = nil
            selectedCase = newCase
        }
    }

    /// 案名兜底：单文件夹 → 文件夹名；单压缩包 → 去扩展名的文件名；
    /// 多个散文件 → 其所在目录名。
    private func derivedCaseName(from urls: [URL]) -> String {
        guard let first = urls.first else { return "导入案件" }
        if urls.count == 1 {
            if first.hasDirectoryPath {
                return first.lastPathComponent
            }
            if first.pathExtension.lowercased() == "zip" {
                let stem = (first.lastPathComponent as NSString).deletingPathExtension
                return stem.isEmpty ? "导入案件" : stem
            }
        }
        let parent = first.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "导入案件" : parent
    }
}

// MARK: - 空状态

struct EmptyCaseView: View {
    let onNewCase: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 60)

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.blue.opacity(0.6))

            Text("劳动争议证据链核查")
                .font(.title2.bold())

            Text("拍照导入仲裁材料，AI 自动生成\n证据目录并检测证明链缺口")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button(action: onImport) {
                    Label("导入文件夹或压缩包", systemImage: "folder.badge.plus")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onNewCase) {
                    Label("手动创建案件", systemImage: "square.and.pencil")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer().frame(height: 60)

            VStack(alignment: .leading, spacing: 8) {
                CapabilityRow(icon: "camera.viewfinder", text: "拍照或导入 PDF 证据，OCR 自动识别")
                CapabilityRow(icon: "list.clipboard", text: "AI 自动生成证据目录（证明内容+证明目的）")
                CapabilityRow(icon: "sparkle.magnifyingglass", text: "自动发现证据缺口并给出补证建议")
            }
            .padding(.bottom, 40)
        }
        .padding()
    }
}

struct CapabilityRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - 案件列表

struct CaseListView: View {
    let cases: [CaseFile]
    let onSelect: (CaseFile) -> Void
    let onNewCase: () -> Void
    let onImport: () -> Void

    var body: some View {
        List {
            Section("案件列表") {
                ForEach(cases) { caseFile in
                    Button { onSelect(caseFile) } label: {
                        CaseRow(caseFile: caseFile)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) {
                    Image(systemName: "folder.badge.plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewCase) {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

struct CaseRow: View {
    let caseFile: CaseFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(caseFile.caseName.isEmpty ? "未命名案件" : caseFile.caseName)
                    .font(.headline)
                Spacer()
                Text(caseFile.stage.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(stageColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(stageColor)
            }
            HStack {
                Text("申请人: \(caseFile.applicant)")
                Text("被申请人: \(caseFile.respondent)")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    var stageColor: Color {
        switch caseFile.stage {
        case .drafting: return .gray
        case .evidenceCollection: return .blue
        case .catalogReview: return .orange
        case .gapResolution: return .red
        case .readyToFile: return .green
        }
    }
}
