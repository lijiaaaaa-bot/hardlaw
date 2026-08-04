import SwiftUI
import HardlawKit

/// Live camera feed with real-time rule-based findings overlay.
public struct LiveModerationView: View {
    @Bindable var viewModel: CourtViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var cameraService = CameraService()
    @State private var scanTask: Task<Void, Never>?
    @State private var frameCount = 0

    public var body: some View {
        ZStack {
            // Camera preview
            if viewModel.isCameraRunning {
                CameraPreviewView(session: cameraService.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                VStack {
                    ProgressView()
                    Text("Starting camera...")
                        .foregroundStyle(.white)
                }
            }

            // Overlay
            VStack {
                // Top bar
                HStack {
                    Button {
                        stopCamera()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }

                    Spacer()

                    VStack(alignment: .trailing) {
                        Text("Live Scan")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("\(viewModel.liveFindings.count) findings")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding()
                .background(.black.opacity(0.4))

                Spacer()

                // Findings panel
                if !viewModel.liveFindings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Findings", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(viewModel.liveFindings.enumerated()), id: \.offset) { _, finding in
                                    FindingChip(finding: finding)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }

                // Last scanned text
                if !viewModel.lastFrameText.isEmpty {
                    Text(viewModel.lastFrameText.prefix(100) + (viewModel.lastFrameText.count > 100 ? "..." : ""))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .padding(.horizontal)
                        .padding(.bottom, 40)
                }
            }
        }
        .task {
            await startCamera()
        }
        .onDisappear {
            stopCamera()
        }
    }

    private func startCamera() async {
        await cameraService.start()
        viewModel.isCameraRunning = true

        // Throttled frame scanning: once per second
        cameraService.onFrame = { cgImage in
            frameCount += 1
            // Scan every 30th frame (~1/sec at 30fps)
            guard frameCount % 30 == 0 else { return }

            scanTask?.cancel()
            scanTask = Task {
                let collector = VisionEvidenceCollector()
                if let ocrResult = try? await collector.recognizeText(in: cgImage),
                   !ocrResult.fullText.isEmpty {
                    await viewModel.scanText(ocrResult.fullText)
                }
            }
        }
    }

    private func stopCamera() {
        scanTask?.cancel()
        cameraService.stop()
        viewModel.isCameraRunning = false
    }
}

// MARK: - Finding Chip

struct FindingChip: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(finding.kind.uppercased())
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(kindColor.opacity(0.2), in: Capsule())
            Text(finding.detail)
                .font(.caption)
                .lineLimit(1)
            Text(finding.location)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    var kindColor: Color {
        switch finding.kind {
        case "bug": return .red
        case "gap": return .orange
        case "todo": return .blue
        default: return .gray
        }
    }
}
