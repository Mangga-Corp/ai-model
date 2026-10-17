import SwiftUI

/// Route for a single photo's result.
struct PhotoDetailRoute: Hashable {
    let photoID: UUID
}

/// Individual photo: the real image with evidence overlays, the four
/// characteristics, and expandable technical details. Reads cached results
/// only, so opening or expanding anything never triggers inference.
struct PhotoResultDetailView: View {
    @ObservedObject var session: AnalysisSession
    let photoID: UUID

    @State private var selectedLayers: Set<EvidenceLayer> = []
    @State private var didSeedLayers = false
    @State private var showModelOutput = false

    var body: some View {
        Group {
            if let photo = session.result(for: photoID) {
                content(photo)
            } else {
                ContentUnavailableView("Result unavailable", systemImage: "photo.badge.exclamationmark",
                                       description: Text("This photo's analysis is not available."))
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ photo: PhotoResult) -> some View {
        let artifacts = session.artifactStore.artifacts(for: photo.id)
        let image = session.imageStore.image(for: photo.id)
        let available = EvidenceLayer.available(for: photo, artifacts: artifacts)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image {
                    VStack(alignment: .leading, spacing: 10) {
                        EvidenceImageView(image: image, photo: photo, artifacts: artifacts, layers: selectedLayers)
                        if available.isEmpty {
                            Label("No overlays: no measurement from this photo can be drawn.", systemImage: "eye.slash")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            EvidenceLayerPicker(available: available, selection: $selectedLayers)
                        }
                    }
                } else {
                    ResultCard {
                        Label("The original photo could not be loaded, so there is nothing to display.", systemImage: "photo.badge.exclamationmark")
                            .font(.subheadline)
                    }
                }

                if !photo.errors.isEmpty { problemsCard(photo) }

                ForEach(CharacteristicKind.allCases) { kind in
                    CharacteristicCard(kind: kind, photo: photo)
                }

                ResultCard {
                    DisclosureGroup(isExpanded: $showModelOutput) {
                        ModelOutputSection(photo: photo).padding(.top, 8)
                    } label: {
                        Label("Model output details", systemImage: "cpu").font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Photo \(photo.selectionOrder + 1)")
        .onAppear {
            if !didSeedLayers {
                selectedLayers = EvidenceLayer.defaultSelection(from: available)
                didSeedLayers = true
            }
        }
    }

    private func problemsCard(_ photo: PhotoResult) -> some View {
        ResultCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Some analysis steps did not complete", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                ForEach(photo.errors, id: \.self) { error in
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                Text("Measurements that did not depend on these steps are unaffected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
