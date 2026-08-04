import SwiftUI
import PhotosUI
import HardlawKit

/// View for submitting content and showing audit results.
public struct AuditResultView: View {
    @Bindable var viewModel: CourtViewModel

    /// Audit mode.
    public enum AuditMode: Sendable {
        case text(String)
        case photoPicker
    }

    let mode: AuditMode

    @State private var textInput: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var auditTask: Task<Void, Never>?
    @State private var showCamera = false

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Input section
                switch mode {
                case .text:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content to Audit")
                            .font(.headline)
                        TextEditor(text: $textInput)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary, lineWidth: 1)
                            )
                        Button {
                            auditTask = Task {
                                await viewModel.auditText(textInput)
                            }
                        } label: {
                            Label("Submit to Court", systemImage: "gavel")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)

                case .photoPicker:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Photo Audit")
                            .font(.headline)

                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("Select Photo", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .onChange(of: selectedPhotoItem) { _, newItem in
                            guard let item = newItem else { return }
                            auditTask = Task {
                                await auditPhoto(item)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                // Phase indicator
                if viewModel.phase != .idle {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text(viewModel.statusMessage)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }

                // Results
                switch viewModel.phase {
                case .decided(let result):
                    CaseResultView(result: result)
                default:
                    EmptyView()
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(modeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            viewModel.reset()
        }
    }

    var modeTitle: String {
        switch mode {
        case .text: return "Text Audit"
        case .photoPicker: return "Photo Audit"
        }
    }

    func auditPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            viewModel.statusMessage = "Failed to load photo"
            return
        }
        await viewModel.auditImage(cgImage)
    }
}

// MARK: - Case Result View

public struct CaseResultView: View {
    let result: CaseResult

    public var body: some View {
        VStack(spacing: 16) {
            // Disposition badge
            DispositionBadge(disposition: result.finalDisposition)

            // Summary
            VStack(spacing: 8) {
                Text("Case \(result.caseId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.reason)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Text("\(result.roundCount) round(s), \(result.verdicts.count) verdict(s)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Verdicts
            if !result.verdicts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Verdicts")
                        .font(.headline)

                    ForEach(Array(result.verdicts.enumerated()), id: \.offset) { index, verdict in
                        VerdictRow(index: index, verdict: verdict)
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

// MARK: - Disposition Badge

struct DispositionBadge: View {
    let disposition: CaseResult.Disposition

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(disposition.rawValue.capitalized)
                .font(.title2)
                .fontWeight(.bold)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(color.opacity(0.15), in: Capsule())
    }

    var icon: String {
        switch disposition {
        case .approved: return "checkmark.seal.fill"
        case .rejected: return "xmark.seal.fill"
        case .blocked: return "hand.raised.fill"
        case .stalled: return "exclamationmark.triangle.fill"
        case .maxRounds: return "clock.badge.exclamationmark.fill"
        case .terminalStep: return "flag.fill"
        }
    }

    var color: Color {
        switch disposition {
        case .approved: return .green
        case .rejected: return .red
        case .blocked: return .red
        case .stalled: return .orange
        case .maxRounds: return .orange
        case .terminalStep: return .blue
        }
    }
}

// MARK: - Verdict Row

struct VerdictRow: View {
    let index: Int
    let verdict: Verdict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Round \(index + 1)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                VerdictBadge(refuted: verdict.refuted, blocking: verdict.blocking)
                ConfidenceBadge(confidence: verdict.confidence)
            }

            if !verdict.finding.isEmpty && verdict.finding != "none" {
                Text("Finding: \(verdict.finding)")
                    .font(.subheadline)
            }
            if !verdict.reasoning.isEmpty {
                Text(verdict.reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Evidence refs
            if !verdict.evidenceRefs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evidence:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(verdict.evidenceRefs.enumerated()), id: \.offset) { _, ref in
                        Text("[\(ref.source):\(ref.location)] \(ref.snippet)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // Findings
            if !verdict.findings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gaps:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(verdict.findings.enumerated()), id: \.offset) { _, f in
                        HStack(spacing: 4) {
                            Text("[\(f.kind)]")
                                .font(.caption2)
                                .fontWeight(.semibold)
                            Text("\(f.location): \(f.detail)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let note = verdict.fallbackNote {
                Text("Note: \(note)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Small Badges

struct VerdictBadge: View {
    let refuted: Bool
    let blocking: Bool

    var body: some View {
        Text(blocking ? "BLOCKED" : (refuted ? "REFUTED" : "PASS"))
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(labelColor.opacity(0.15), in: Capsule())
            .foregroundStyle(labelColor)
    }

    var labelColor: Color {
        blocking ? .red : (refuted ? .orange : .green)
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Text(confidence.rawValue.uppercased())
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}
