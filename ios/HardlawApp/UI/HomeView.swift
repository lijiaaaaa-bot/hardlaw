import SwiftUI

/// Main home screen with mode picker and backend selector.
public struct HomeView: View {
    @State private var viewModel = CourtViewModel()
    @State private var showLiveModeration = false
    @State private var showAudit = false
    @State private var inputText = ""

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)

                        Text("Hardlaw")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("On-Device AI Compliance Court")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // Backend selector
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Judge Backend", systemImage: "brain.head.profile")
                            .font(.headline)
                        Picker("Backend", selection: $viewModel.selectedBackend) {
                            ForEach(CourtViewModel.Backend.allCases, id: \.self) { backend in
                                Text(backend.rawValue).tag(backend)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal)

                    // Mode cards
                    VStack(spacing: 16) {
                        // Live Moderation
                        Button {
                            showLiveModeration = true
                        } label: {
                            ModeCard(
                                icon: "waveform.circle.fill",
                                title: "Live Moderation",
                                subtitle: "Real-time rule-based scanning",
                                color: .green,
                                description: "Camera feed analyzed frame-by-frame with deterministic regex rules. Instant results, no network."
                            )
                        }
                        .buttonStyle(.plain)

                        // Text Audit
                        NavigationLink {
                            AuditResultView(viewModel: viewModel, mode: .text(""))
                        } label: {
                            ModeCard(
                                icon: "doc.text.magnifyingglass",
                                title: "Text Audit",
                                subtitle: "Full Court procedure",
                                color: .blue,
                                description: "Submit text for complete judicial review. Evidence collection, judgment, and verdict."
                            )
                        }
                        .buttonStyle(.plain)

                        // Photo Audit
                        NavigationLink {
                            AuditResultView(viewModel: viewModel, mode: .photoPicker)
                        } label: {
                            ModeCard(
                                icon: "camera.viewfinder",
                                title: "Photo Audit",
                                subtitle: "OCR + Court procedure",
                                color: .orange,
                                description: "Capture or select a photo. Vision extracts text as evidence, then the Court judges it."
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)

                    // Statute summary
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Active Statutes", systemImage: "list.clipboard.fill")
                            .font(.headline)
                        ForEach(ContentModerationStatutes.all, id: \.name) { statute in
                            HStack {
                                Text(statute.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(statute.blocking ? "Blocking" : "Non-blocking")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showLiveModeration) {
                LiveModerationView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Mode Card

struct ModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(color)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
