import SwiftUI
import UIKit
import Photos

// MARK: - Captured Photo Preview

/// Full-screen review of the photo just taken, with Retake and Save actions.
///
/// AI enhance is always applied. The screen opens on the original photo; once
/// the enhanced version is ready, a line sweeps from right to left and the
/// enhanced photo is revealed behind it. After the reveal, a compare button
/// appears inside the photo: holding it shows the original, releasing it goes
/// back to the enhanced photo. The photo can be pinched or double-tapped to zoom,
/// and the zoom is kept while comparing.
///
/// Retake discards the photo and returns to the live viewfinder. Save writes the
/// enhanced photo to the system photo library and then returns — the user has
/// committed to the shot, so there is nothing left to review.
struct CapturedPhotoView: View {

    let originalImage: UIImage?
    /// Nil while enhancing, or if the enhance failed.
    let enhancedImage: UIImage?
    let isEnhancing: Bool
    /// Non-nil when the library write was refused. Surfaced rather than
    /// failing silently, so the user knows why nothing happened.
    let saveError: String?
    let onRetake: () -> Void
    let onSave: () -> Void

    /// 0 = original fully visible, 1 = enhanced fully revealed.
    @State private var revealProgress: CGFloat = 0
    /// True once the sweep has finished; the compare button appears then.
    @State private var isRevealFinished = false
    /// True while the compare button is held down.
    @State private var isHoldingOriginal = false

    /// Pause on the original before the sweep starts, so the user registers
    /// what was captured before it changes.
    private let revealDelay: Duration = .milliseconds(400)
    private let revealDuration: Double = 1.4

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
                photoArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

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
                    // Saving mid-enhance would quietly write the original.
                    .disabled(isEnhancing)
                    .opacity(isEnhancing ? 0.4 : 1)
                }
                .padding(.bottom, 36)
                .padding(.top, 12)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .interactiveDismissDisabled()
        .task(id: enhancedImage != nil) {
            await revealEnhancedIfReady()
        }
    }

    // MARK: - Photo

    @ViewBuilder
    private var photoArea: some View {
        if let originalImage {
            GeometryReader { proxy in
                let imageRect = Self.fittedRect(for: originalImage.size, in: proxy.size)

                ZStack(alignment: .topLeading) {
                    ZoomablePhoto {
                        comparisonPhoto(original: originalImage)
                    }

                    // Placed against the photo's own rect, not the container,
                    // so the controls sit inside the picture and not in the
                    // black letterbox around it.
                    photoOverlays
                        .frame(width: imageRect.width, height: imageRect.height)
                        .offset(x: imageRect.minX, y: imageRect.minY)
                }
            }
        } else {
            // Should not happen — the sheet only opens with an image.
            Text("Photo unavailable")
                .foregroundStyle(.secondary)
        }
    }

    /// The original with the enhanced photo laid exactly on top, revealed from
    /// the right edge as `revealProgress` grows, plus the sweep line on the
    /// reveal edge. Both images have identical dimensions, so they line up.
    private func comparisonPhoto(original: UIImage) -> some View {
        Image(uiImage: original)
            .resizable()
            .scaledToFit()
            .overlay {
                if let enhancedImage {
                    Image(uiImage: enhancedImage)
                        .resizable()
                        .scaledToFit()
                        .mask(alignment: .trailing) {
                            GeometryReader { proxy in
                                Rectangle()
                                    .frame(width: proxy.size.width * revealProgress)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .opacity(isHoldingOriginal ? 0 : 1)
                }
            }
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    sweepLine
                        .frame(height: proxy.size.height)
                        .offset(x: proxy.size.width * (1 - revealProgress) - 1.5)
                }
                .opacity(enhancedImage != nil && !isRevealFinished ? 1 : 0)
                .allowsHitTesting(false)
            }
    }

    private var sweepLine: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 3)
            .shadow(color: .white.opacity(0.9), radius: 6)
            .shadow(color: .yellow.opacity(0.6), radius: 14)
    }

    /// Everything drawn inside the photo's rect, on top of it.
    private var photoOverlays: some View {
        ZStack {
            if isEnhancing {
                enhancingIndicator
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if isHoldingOriginal {
                badge("Original")
            } else if !isEnhancing && enhancedImage == nil {
                badge("Enhance unavailable")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isRevealFinished {
                holdToCompareButton
                    .padding(12)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    // MARK: - Compare button

    /// Shows the original while held; releasing returns to the enhanced photo.
    private var holdToCompareButton: some View {
        HStack(spacing: 6) {
            Image(systemName: isHoldingOriginal ? "eye.fill" : "eye")
            Text("Hold")
                .font(.caption.weight(.semibold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isHoldingOriginal ? Color.black : Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHoldingOriginal ? Color.white : Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
        .scaleEffect(isHoldingOriginal ? 0.94 : 1)
        .animation(.easeOut(duration: 0.12), value: isHoldingOriginal)
        .contentShape(Capsule())
        // Infinite duration: the "long press" never completes, so only the
        // pressing state matters — down shows the original, up restores.
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60,
                            perform: {},
                            onPressingChanged: { isHoldingOriginal = $0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to see the original photo")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Reveal

    /// Runs the sweep once the enhanced photo exists. Re-run by `.task(id:)`
    /// when the enhanced photo arrives; does nothing if it never does.
    private func revealEnhancedIfReady() async {
        guard enhancedImage != nil, !isRevealFinished else { return }
        try? await Task.sleep(for: revealDelay)
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: revealDuration)) {
            revealProgress = 1
        } completion: {
            withAnimation(.spring(duration: 0.35)) {
                isRevealFinished = true
            }
        }
    }

    // MARK: - Overlays

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(12)
            .allowsHitTesting(false)
    }

    private var enhancingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.white)
            Text("Enhancing…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .allowsHitTesting(false)
    }

    /// The rect an aspect-fit image of `imageSize` occupies, centred in `bounds`.
    private static func fittedRect(for imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Zoomable photo

/// Content that can be pinched to zoom (up to 5×), dragged while zoomed, and
/// double-tapped to toggle between fit and 2.5×.
///
/// Zoom state lives here, around both photo versions, so comparing keeps the
/// same region in view.
private struct ZoomablePhoto<Content: View>: View {

    @ViewBuilder let content: Content

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(magnify.simultaneously(with: pan))
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2.5
                        baseScale = 2.5
                    }
                }
            }
            .accessibilityHint("Pinch or double-tap to zoom")
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), maxScale)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 {
                    withAnimation(.easeInOut(duration: 0.2)) { reset() }
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
