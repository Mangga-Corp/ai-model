import SwiftUI

/// The analysis step of the app flow: shows live progress while the pipeline
/// runs, then the results. Starting is idempotent per selection, so returning
/// to this screen reuses the existing results and never repeats inference.
struct AnalysisFlowView: View {
    @ObservedObject var session: AnalysisSession
    let photos: [ReferencePhoto]
    let onOpenCamera: () -> Void
    let onExit: () -> Void

    var body: some View {
        Group {
            switch session.phase {
            case .idle, .running:
                AnalysisProgressPanel(session: session) {
                    session.cancel()
                    onExit()
                }
            case .completed:
                ResultsOverviewView(session: session, onOpenCamera: onOpenCamera)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.phase == .completed ? "Analysis Results" : "Analyzing Photos")
        .navigationBarTitleDisplayMode(.inline)
        .task { session.start(photos: photos) }
    }
}

// MARK: - Progress

struct AnalysisProgressPanel: View {
    @ObservedObject var session: AnalysisSession
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ResultCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Analyzing your reference photos").font(.headline)
                        ProgressView(value: session.progress)
                        Text("\(session.finishedCount) of \(session.totalCount) photos analyzed")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        Text("Each photo is measured on this device. Progress advances only when a photo is actually finished.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                ResultCard {
                    VStack(spacing: 12) {
                        ForEach(Array(session.photoOrder.enumerated()), id: \.element) { index, id in
                            HStack {
                                Text("Photo \(index + 1)").font(.subheadline)
                                Spacer()
                                stateView(session.photoStates[id] ?? .queued)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func stateView(_ state: PhotoRunState) -> some View {
        switch state {
        case .queued:
            Label("Waiting", systemImage: "clock").font(.footnote).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Analyzing").font(.footnote) }
        case .finished(let status):
            switch status {
            case .complete: Label("Done", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            case .partial: Label("Done, partial", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.orange)
            case .failed: Label("Could not analyze", systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red)
            }
        }
    }
}
