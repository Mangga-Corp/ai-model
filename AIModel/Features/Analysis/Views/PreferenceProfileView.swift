import SwiftUI

/// Page 3: Photography Preference Profile View
/// Displays the aggregated analysis results with traceable evidence.
struct PreferenceProfileView: View {

    @StateObject private var viewModel: PreferenceProfileViewModel
    let onBack: () -> Void
    /// Opens the camera screen. Offered here rather than on the selection page
    /// so the camera follows analysis instead of competing with it.
    let onOpenCamera: () -> Void

    init(profile: PhotographicPreferenceProfile, onBack: @escaping () -> Void, onOpenCamera: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: PreferenceProfileViewModel(profile: profile))
        self.onBack = onBack
        self.onOpenCamera = onOpenCamera
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Summary
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Photography Profile")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text(viewModel.profile.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text("\(viewModel.profile.successfullyAnalyzedCount) of \(viewModel.profile.photoCount) photos analyzed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Core characteristics — one unified card.
                //
                // Replaces the previous one-card-per-insight list. All six core
                // traits read together in a single summary, each with its
                // measured value and evidence badge.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Photographic Characteristics")
                        .font(.headline)

                    CharacteristicsSummaryCard(insights: viewModel.profile.insights)
                }

                // Analyzed photos with detected overlays
                if !viewModel.profile.analyzedPhotoPairs.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your Analyzed Photos")
                            .font(.headline)

                        Text("Overlays show what was actually detected in each photo. Tap to toggle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(viewModel.profile.analyzedPhotoPairs, id: \.photo.id) { pair in
                            AnalyzedPhotoCard(photo: pair.photo, analysis: pair.analysis)
                        }
                    }
                }

                // Inconsistencies (if any)
                if !viewModel.profile.mixedPatterns.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mixed Patterns")
                            .font(.headline)

                        ForEach(viewModel.profile.mixedPatterns, id: \.characteristic) { pattern in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.orange)

                                Text(pattern.description)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Limitations
                if !viewModel.profile.limitations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Limitations")
                            .font(.headline)

                        ForEach(viewModel.profile.limitations, id: \.self) { limitation in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.tertiary)

                                Text(limitation)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // Actions
                VStack(spacing: 12) {
                    // Opens the live camera. Placed on the result page because
                    // it makes sense after seeing what your preferences are —
                    // the camera is a tool for applying them.
                    Button {
                        onOpenCamera()
                    } label: {
                        Label("Camera Guide", systemImage: "camera.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Select New Photos") {
                        onBack()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

            }
            .padding()
        }
        .navigationTitle("Your Photography Profile")
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview {
    PreferenceProfileView(
        profile: PhotographicPreferenceProfile(
            id: UUID(),
            photoCount: 5,
            successfullyAnalyzedCount: 5,
            subjectPositionDistribution: PositionDistribution(meanX: 0.3, meanY: 0.5, stdDevX: 0.1, stdDevY: 0.1, isConsistent: true),
            halfBodyPositionDistribution: PositionDistribution(meanX: 0.3, meanY: 0.42, stdDevX: 0.1, stdDevY: 0.1, isConsistent: true),
            subjectSizeDistribution: SizeDistribution(meanArea: 0.1, minArea: 0.05, maxArea: 0.2, stdDev: 0.05, isConsistent: true),
            horizonAngleDistribution: AngleDistribution(meanAngle: 0.5, stdDev: 2.0, sampleCount: 5),
            brightnessDistribution: ValueDistribution(mean: 0.55, stdDev: 0.08, min: 0.4, max: 0.7, sampleCount: 5, isConsistent: true),
            saturationDistribution: ValueDistribution(mean: 0.45, stdDev: 0.1, min: 0.3, max: 0.6, sampleCount: 5, isConsistent: true),
            colorTemperatureDistribution: ValueDistribution(mean: 0.2, stdDev: 0.05, min: 0.1, max: 0.3, sampleCount: 5, isConsistent: true),
            headYawDistribution: ValueDistribution(mean: -10, stdDev: 5, min: -20, max: 0, sampleCount: 3, isConsistent: true),
            headRollDistribution: nil,
            bodyOrientationDistribution: ValueDistribution(mean: 5, stdDev: 3, min: 0, max: 10, sampleCount: 4, isConsistent: true),
            bodySymmetryDistribution: nil,
            saliencyIntensityDistribution: nil,
            aestheticScoreDistribution: ValueDistribution(mean: 0.4, stdDev: 0.1, min: 0.2, max: 0.6, sampleCount: 5, isConsistent: true),
            leadingLinesLineCountDistribution: ValueDistribution(mean: 3.2, stdDev: 1.1, min: 2, max: 5, sampleCount: 4, isConsistent: true),
            leadingLinesAngleDistribution: ValueDistribution(mean: 42, stdDev: 8, min: 30, max: 55, sampleCount: 4, isConsistent: true),
            leadingLinesConvergenceDistribution: ValueDistribution(mean: 0.7, stdDev: 0.1, min: 0.5, max: 0.9, sampleCount: 4, isConsistent: true),
            diagonalDominanceRatio: 0.75,
            ruleOfThirdsPatterns: [.middleLeft: 3, .center: 2],
            sceneCategories: ["landscape": 3, "portrait": 2],
            negativeSpacePatterns: [.balanced: 2, .rightHeavy: 3],
            colorHarmonyPatterns: [.analogous: 3, .warm: 2],
            dominantColorPalette: [
                DominantColor(red: 0.6, green: 0.4, blue: 0.2, proportion: 0.3),
                DominantColor(red: 0.2, green: 0.3, blue: 0.5, proportion: 0.25),
                DominantColor(red: 0.8, green: 0.7, blue: 0.6, proportion: 0.2)
            ],
            lightDirectionPatterns: [.topLeft: 3, .right: 2],
            symmetryDistribution: ValueDistribution(mean: 0.82, stdDev: 0.05, min: 0.75, max: 0.9, sampleCount: 4, isConsistent: true),
            bilateralDistribution: ValueDistribution(mean: 0.85, stdDev: 0.04, min: 0.8, max: 0.92, sampleCount: 4, isConsistent: true),
            symmetryRatio: 0.8,
            symmetryAxisPatterns: [.bilateral: 3, .vertical: 1],
            goldenRatioDistribution: ValueDistribution(mean: 0.6, stdDev: 0.15, min: 0.4, max: 0.8, sampleCount: 5, isConsistent: false),
            goldenRatioHitRatio: 0.6,
            summary: "Subjects are consistently placed on the left side with small framing. Your photographs tend toward bright, well-exposed frames with warm color temperatures.",
            insights: [
                PreferenceInsight(
                    id: UUID(),
                    title: "Subject Placement",
                    description: "Subjects are consistently placed in the left side of your photographs.",
                    category: .composition,
                    supportingPhotoIDs: [],
                    supportingMeasurements: [:],
                    evidenceStrength: .strong,
                    interpretationStatus: .observation
                )
            ],
            analyses: [],
            photos: [],
            mixedPatterns: [],
            limitations: ["Simulator may not support all features."],
            generatedAt: Date()
        ),
        onBack: { },

    )
}
