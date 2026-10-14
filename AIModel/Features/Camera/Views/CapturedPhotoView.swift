import SwiftUI
import UIKit
import Photos

// MARK: - Captured Photo Preview

/// Full-screen review of the photo just taken, with Retake and Save actions.
///
/// Retake discards the photo and returns to the live viewfinder. Save writes it
/// to the system photo library and then returns — the user has committed to the
/// shot, so there is nothing left to review.
struct CapturedPhotoView: View {

    let image: UIImage?
    /// Non-nil when the library write was refused. Surfaced rather than
    /// failing silently, so the user knows why nothing happened.
    let saveError: String?
    let onRetake: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Title
                Text("Photo Captured")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                // The photo, filling all space between the title and the actions.
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        // Should not happen — the sheet only opens with an image.
                        Text("Photo unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Save error, if the library write was refused.
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                // Actions
                HStack(spacing: 60) {
                    Button {
                        onRetake()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2)
                            Text("Retake")
                                .font(.caption)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 56)
                        .contentShape(Rectangle())
                    }

                    Button {
                        onSave()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.title2)
                            Text("Save")
                                .font(.caption)
                        }
                        .foregroundStyle(.green)
                        .frame(width: 72, height: 56)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.bottom, 36)
                .padding(.top, 12)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .interactiveDismissDisabled()
    }
}
