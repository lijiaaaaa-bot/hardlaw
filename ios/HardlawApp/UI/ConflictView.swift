import SwiftUI

// MARK: - 证据冲突对照

/// 证据冲突对照 — 并排（iPhone 上纵向堆叠）对比两份相互矛盾的证据。
/// 左侧为原结论，右侧为新证据；底部提供「以此为准」与「暂不处理」三个选择。
struct ConflictView: View {
    let leftSource: String; let leftValue: String
    let rightSource: String; let rightValue: String
    let onChooseLeft: () -> Void
    let onChooseRight: () -> Void
    let onDefer: () -> Void
    @Environment(\.dismiss) var dismiss

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// iPhone（紧凑宽度）纵向堆叠，宽屏（iPad / 横屏）左右并排
    private var isStacked: Bool { horizontalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    conflictBanner

                    if isStacked {
                        VStack(spacing: 12) {
                            columnCard(side: .left)
                            Divider()
                            columnCard(side: .right)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            columnCard(side: .left)
                            Divider()
                            columnCard(side: .right)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("证据冲突")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
    }

    // MARK: - 冲突提示

    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.shield.fill")
                .foregroundStyle(.orange)
            Text("检测到两处相互矛盾的结论，请确认以哪一版为准")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 对照列

    private enum Side { case left, right }

    private func columnCard(side: Side) -> some View {
        let isLeft = side == .left
        let title = isLeft ? "原结论" : "新证据"
        let source = isLeft ? leftSource : rightSource
        let value = isLeft ? leftValue : rightValue

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: isLeft ? "doc.text" : "sparkles")
                    .font(.caption)
                    .foregroundStyle(isLeft ? Color.gray : Color.blue)
                Text(title).font(.headline)
                Spacer()
                if !source.isEmpty {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // 冲突值 — 橙色底强调
            Text(value)
                .font(.subheadline).fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - 底部操作

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                onChooseLeft()
                dismiss()
            } label: {
                Text("以此为准").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.gray)

            Button {
                onDefer()
                dismiss()
            } label: {
                Text("暂不处理").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                onChooseRight()
                dismiss()
            } label: {
                Text("以此为准").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
