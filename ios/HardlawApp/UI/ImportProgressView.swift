import SwiftUI

/// Displays batch import progress: phase text + determinate progress bar.
/// Used inline (e.g. inside the case workbench scroll view) to show the
/// import pipeline's current stage and per-file progress.
struct ImportProgressView: View {
    let phase: String
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(phase)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(done)/\(total)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(done), total: Double(total))
                .tint(.blue)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}

#Preview {
    ImportProgressView(phase: "正在 OCR 识别…", done: 5, total: 12)
        .padding()
}
