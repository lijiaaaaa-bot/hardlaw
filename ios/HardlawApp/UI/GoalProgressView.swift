import SwiftUI
import HardlawKit

// MARK: - Goal Progress View

/// 审查目标进度条：显示 goal 描述、整体进度与每个步骤的状态。
struct GoalProgressView: View {
    let goal: Goal

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: goal.isComplete ? "checkmark.circle.fill" : "circle.grid.cross.fill")
                    .foregroundStyle(goal.isComplete ? .green : .blue)
                Text(goal.description).font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text("\(Int(goal.progress * 100))%").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 10)

            ProgressView(value: goal.progress)
                .padding(.horizontal).padding(.bottom, 4)

            ForEach(goal.steps) { step in
                HStack(spacing: 10) {
                    Image(systemName: step.status == .done ? "checkmark.circle.fill" :
                           step.status == .running ? "circle.dotted" :
                           step.status == .failed ? "xmark.circle.fill" : "circle")
                        .foregroundStyle(step.status == .done ? .green :
                                         step.status == .running ? .blue :
                                         step.status == .failed ? .red : .gray)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.name).font(.caption).fontWeight(.medium)
                        Text(step.status == .done ? step.resultSummary : step.detail)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 4)
            }
            Divider().padding(.top, 4)
        }
        .background(.blue.opacity(0.04))
    }
}
