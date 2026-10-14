import SwiftUI

/// Page 2: Photo Analysis View
/// Displays progress while the analysis pipeline runs.
/// Calls onComplete when analysis finishes with the resulting profile.
struct PhotoAnalysisView: View {

    @StateObject private var viewModel = PhotoAnalysisViewModel()
    let selectedPhotos: [ReferencePhoto]
    let onComplete: (PhotographicPreferenceProfile) -> Void

    var body: some View {
        VStack(spacing: 32) {
            if viewModel.isAnalyzing {
                ProgressView(value: viewModel.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)

                VStack(spacing: 8) {
                    Text(viewModel.statusText)
                        .font(.title3)
                        .fontWeight(.medium)

                    if !viewModel.currentPhotoName.isEmpty {
                        Text(viewModel.currentPhotoName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("\(Int(viewModel.progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                Button("Cancel", role: .cancel) {
                    viewModel.cancelAnalysis()
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            } else if viewModel.profile != nil {
                // Analysis complete — trigger callback
                Color.clear
                    .onAppear {
                        if let profile = viewModel.profile {
                            onComplete(profile)
                        }
                    }
            } else {
                // Error state
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("Try Again") {
                        viewModel.startAnalysis(photos: selectedPhotos)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.startAnalysis(photos: selectedPhotos)
        }
    }
}

#Preview {
    PhotoAnalysisView(
        selectedPhotos: [],
        onComplete: { _ in }
    )
}
