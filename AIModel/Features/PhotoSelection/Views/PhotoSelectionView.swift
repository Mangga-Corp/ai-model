import SwiftUI
import PhotosUI

/// Page 1: Photo Selection View
/// Minimalist, high-contrast interface for selecting reference photographs.
struct PhotoSelectionView: View {

    @StateObject private var viewModel = PhotoSelectionViewModel()
    let onAnalyze: ([ReferencePhoto]) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header — describes whichever mode is active.
                VStack(spacing: 8) {
                    Text("Your Favorite Photos")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Select 3–5 photos you love. We'll look for patterns in your photography.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding(.top, 8)

                analysisSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .navigationTitle("Photo Selection")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $viewModel.isShowingPicker) {
                PhotoPickerViewControllerWrapper(selectionLimit: viewModel.remainingSelectionCount) { results in
                    viewModel.handlePickerResults(results)
                }
            }
            .alert("Error", isPresented: Binding<Bool>(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.errorMessage = nil }
            )) {
                Button("OK") { }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
        }
    }

    // MARK: - Analysis Section

    private var analysisSection: some View {
        VStack(spacing: 28) {
            selectionArea

            loadingOrStatus

            actionButtons
        }
    }

    // MARK: - Selection Area

    private var selectionArea: some View {
        Group {
            if viewModel.selectedPhotos.isEmpty {
                    // Empty state: Interactive upload card
                    Button {
                        viewModel.selectPhotos()
                    } label: {
                        VStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(width: 72, height: 72)

                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 32, weight: .medium))
                                    .foregroundStyle(.primary)
                            }

                            VStack(spacing: 4) {
                                Text("Choose from Library")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text("Photos representing your best work")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                        .padding(.horizontal, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select photos from your library")
                } else {
                    // Selected photos preview strip
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Selected Photos")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            Spacer()

                            Text("\(viewModel.selectedPhotos.count)/\(viewModel.maxSelectionCount)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(viewModel.selectedPhotos) { photo in
                                    ThumbnailView(photo: photo) {
                                        viewModel.removePhoto(photo)
                                    }
                                }

                                if viewModel.remainingSelectionCount > 0 {
                                    AddMoreThumbnailButton {
                                        viewModel.selectPhotos()
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

        }
    }



    // MARK: - Loading or Status

    private var loadingOrStatus: some View {
        Group {
            if viewModel.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Loading photos...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(viewModel.selectionCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Primary Select / Add button
            Button {
                viewModel.selectPhotos()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.selectedPhotos.isEmpty ? "plus.circle.fill" : "plus")
                    Text(viewModel.selectedPhotos.isEmpty ? "Choose from Library" : "Add More")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.remainingSelectionCount == 0 || viewModel.isLoading)

            // Analyze button
            Button {
                onAnalyze(viewModel.selectedPhotos)
            } label: {
                HStack {
                    Text(viewModel.selectedPhotos.isEmpty ? "Analyze Photos" : "Analyze \(viewModel.selectedPhotos.count) Photos")
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canAnalyze)

            // Advisory note for small selections — does not block analysis.
            if let note = viewModel.smallSampleNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Clear All button
            if !viewModel.selectedPhotos.isEmpty {
                Button(role: .destructive) {
                    viewModel.clearAll()
                } label: {
                    Text("Clear Selection")
                        .font(.subheadline)
                }
                .disabled(viewModel.isLoading)
                .padding(.top, 4)
            }
        }
        .padding(.top, 8)
    }
}


/// Thumbnail view for a selected photo with remove button
struct ThumbnailView: View {
    let photo: ReferencePhoto
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = photo.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 88, height: 88)
                    .overlay(
                        ProgressView()
                    )
            }

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.7))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove photo")
        }
    }
}

/// "Add More" button styled like a thumbnail
struct AddMoreThumbnailButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Add")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 88)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add more photos")
    }
}

// MARK: - PHPicker Integration

/// Wraps PHPickerViewController for use in SwiftUI with configurable selection limit.
struct PhotoPickerViewControllerWrapper: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPick: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selection = .ordered
        configuration.selectionLimit = selectionLimit
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void

        init(onPick: @escaping ([PHPickerResult]) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results)
        }
    }
}

#Preview {
    NavigationStack {
        PhotoSelectionView(onAnalyze: { _ in })
    }
}
