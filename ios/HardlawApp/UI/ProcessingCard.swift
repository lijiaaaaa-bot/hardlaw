import SwiftUI

// MARK: - AI 任务进度卡片

/// AI 任务进度卡片 — 显示在证据区上方。
/// 固定四个阶段：OCR → 草拟 → 验证 → 完成；
/// 完成后显示汇总与「撤销」按钮，并在 3 秒后自动折叠。
struct ProcessingCard: View {
    let step: String
    let detail: String
    let fraction: Double
    let isComplete: Bool
    let onUndo: () -> Void

    /// 固定阶段名称
    private static let stageNames = ["OCR", "草拟", "验证", "完成"]

    /// 完成后是否已自动折叠
    @State private var collapsed = false

    /// 折叠计时任务（可取消）
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !collapsed { card }
        }
        .task(id: isComplete) { scheduleCollapseIfNeeded() }
        .onDisappear { collapseTask?.cancel() }
    }

    // MARK: - 卡片主体

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isComplete {
                completionSummary
            } else {
                stepsRow
                progressBar
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.seal.fill" : "sparkles")
                .font(.subheadline)
                .foregroundStyle(isComplete ? Color.green : Color.blue)

            Text(isComplete ? "完成" : (step.isEmpty ? "AI 处理中" : step))
                .font(.subheadline).fontWeight(.semibold)

            Spacer()

            if isComplete {
                Button(action: onUndo) {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
            }
        }
    }

    /// 完成汇总 — 总数由调用方传入的 detail 携带（如「共 12 项证据已处理」）
    private var completionSummary: some View {
        Text(detail.isEmpty ? "处理完成" : detail)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - 阶段进度

    private enum StepState { case done, current, pending }

    /// 当前已完成阶段数（0...4）
    private var doneCount: Int {
        let clamped = min(max(fraction, 0), 1)
        return min(4, Int(ceil(clamped * 4)))
    }

    private func stepState(at index: Int) -> StepState {
        if index < doneCount { return .done }
        if index == doneCount { return .current }
        return .pending
    }

    private var stepsRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.stageNames.enumerated()), id: \.offset) { index, name in
                stepItem(name: name, state: stepState(at: index))
                if index < Self.stageNames.count - 1 {
                    connector(active: stepState(at: index) == .done)
                }
            }
        }
    }

    private func stepItem(name: String, state: StepState) -> some View {
        HStack(spacing: 4) {
            stepIcon(state: state)
            Text(name)
                .font(.caption2)
                .fontWeight(state == .current ? .semibold : .regular)
                .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
        }
    }

    @ViewBuilder
    private func stepIcon(state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 14, height: 14)
        case .current:
            ProgressView()
                .controlSize(.mini)
                .tint(.blue)
                .frame(width: 14, height: 14)
        case .pending:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .frame(width: 14, height: 14)
        }
    }

    /// 阶段之间的连接线
    private func connector(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.green.opacity(0.5) : Color.primary.opacity(0.12))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 进度条

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.blue, .cyan],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }

    // MARK: - 自动折叠

    /// 完成后 3 秒自动折叠；开始新任务时恢复展开。
    private func scheduleCollapseIfNeeded() {
        collapseTask?.cancel()
        guard isComplete else {
            collapsed = false
            return
        }
        collapsed = false
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { collapsed = true }
        }
    }
}
