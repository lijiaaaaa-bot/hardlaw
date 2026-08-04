import SwiftUI

// MARK: - 首页：案件入口

public struct HomeView: View {
    @State private var showNewCase = false
    @State private var cases: [CaseFile] = []
    @State private var selectedCase: CaseFile?

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 信任声明
                TrustBanner()

                if cases.isEmpty {
                    EmptyCaseView(onNewCase: { showNewCase = true })
                } else {
                    CaseListView(cases: cases, onSelect: { selectedCase = $0 }, onNewCase: { showNewCase = true })
                }
            }
            .navigationTitle("证据链核查")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showNewCase) {
                CaseIntakeView { newCase in
                    cases.append(newCase)
                    selectedCase = newCase
                    showNewCase = false
                }
            }
            .sheet(item: $selectedCase) { caseFile in
                CaseWorkbenchView(caseFile: caseFile)
            }
        }
    }
}

// MARK: - 信任声明

struct TrustBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("所有分析在手机本地完成，证据不离开设备。引用内容必须与原文逐字一致。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.green.opacity(0.06))
    }
}

// MARK: - 空状态

struct EmptyCaseView: View {
    let onNewCase: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.blue.opacity(0.6))

            VStack(spacing: 8) {
                Text("证据链核查工作台")
                    .font(.title2).fontWeight(.bold)
                Text("新建劳动争议案件，自动生成证据目录、\n检测证据缺口、验证引用一致性")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onNewCase) {
                Label("新建案件", systemImage: "plus.rectangle.fill")
                    .font(.headline)
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()

            // 能力展示
            VStack(spacing: 12) {
                CapabilityRow(icon: "text.viewfinder", text: "拍照或导入证据，OCR 提取文字")
                CapabilityRow(icon: "list.clipboard", text: "自动生成七列证据目录，可逐条编辑")
                CapabilityRow(icon: "exclamationmark.shield", text: "逐字验证引用内容是否真实存在于源文件")
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
            Button(action: onNewCase) {
                Image(systemName: "plus")
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
