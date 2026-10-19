import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

// MARK: - Photo Enhancer

/// On-device "AI enhance" for a captured photo.
///
/// Built from Core Image filters steered by Vision, so it needs no extra model
/// download and runs in well under a second on a captured video frame. How
/// strong each step is gets decided per photo: `PhotoStatistics` measures the
/// capture (brightness, contrast, saturation, colour cast, noise, faces) and
/// `EnhanceTuner` turns those measurements into `Settings`.
///
///
///   1. **Auto adjust** — Core Image's own analysis picks exposure, tone curve,
///      vibrance and shadow/highlight corrections for THIS image (the same
///      engine behind Photos' Auto button). This is what evens out a dim,
///      flat indoor shot.
///   2. **Warmth** — a small white-balance shift, so office/LED light reads
///      clean and warm rather than grey-blue.
///   3. **Clarity** — large-radius unsharp mask (local contrast), which gives
///      the "punchy" depth of the reference look without raising global contrast.
///   4. **Skin smoothing** — faces found by Vision get a soft blur blended in
///      through a feathered mask, with the eyes, brows and mouth cut out of the
///      mask so they stay crisp.
///   5. **Sharpen** — fine luminance sharpening for edge detail.
///   6. **Vignette** — a light falloff that pulls the eye to the subject.
///   7. **Strength** — the result is mixed back over the original, so the
///      look stays natural rather than heavily filtered.
///
/// Not included: changing image CONTENT (e.g. opening closed eyes). That needs a
/// generative face model, which this pipeline deliberately does not use — every
/// step here only re-tones pixels that were actually captured.
nonisolated struct PhotoEnhancer: Sendable {

    /// Strengths of each step. The defaults are the original hand-tuned look;
    /// by default `EnhanceTuner` replaces them per photo from its statistics.
    struct Settings: Sendable, Equatable {
        /// Overall strength: how much of the enhanced result is mixed over the
        /// original (0 = original, 1 = full enhance). Auto adjust reacts to
        /// each scene, so some photos come out stronger than others; this one
        /// knob tones the whole look down evenly without retuning each step.
        var strength: Float = 0.7
        /// Extra vibrance on top of auto adjust (0…1).
        var vibrance: Float = 0.2
        /// White-balance shift in kelvin; positive warms the image.
        var warmthKelvin: Float = 350
        /// Local-contrast strength (0…1).
        var clarity: Float = 0.45
        /// Clarity radius as a fraction of the image's short side.
        var clarityRadiusFraction: Float = 0.02
        /// How much smoothed skin replaces the original on faces (0…1).
        var skinSmoothing: Float = 0.55
        /// Luminance sharpening (0…1 is a natural range).
        var sharpness: Float = 0.4
        /// Vignette darkening (0 disables it).
        var vignette: Float = 0.35
    }

    /// Fixed strengths for every photo, or nil (the default) to tune them per
    /// photo from its measured statistics via `EnhanceTuner`.
    var fixedSettings: Settings?

    /// The strengths for the photo being rendered. Set inside `enhance(_:)`.
    private var settings = Settings()

    init(settings: Settings? = nil) {
        self.fixedSettings = settings
    }

    /// One context for every render. Creating a context per call is expensive;
    /// `CIContext` is safe to use from multiple threads.
    private static let context = CIContext()

    /// Returns the enhanced photo, or nil if it could not be rendered.
    ///
    /// Synchronous and CPU/GPU heavy — call it off the main actor.
    func enhance(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let faces = Self.detectFaces(in: cgImage)

        // Measured on the ORIGINAL, before any step runs, so the numbers
        // describe what the camera captured rather than an earlier step's output.
        var renderer = self
        renderer.settings = fixedSettings ?? EnhanceTuner.settings(
            for: PhotoStatistics.measure(input, faces: faces, context: Self.context))
        return renderer.render(input, faces: faces, image: image)
    }

    private func render(_ input: CIImage, faces: [VNFaceObservation], image: UIImage) -> UIImage? {
        let extent = input.extent
        var output = autoAdjusted(input)
        output = warmed(output)
        output = clarified(output, extent: extent)
        output = smoothedSkin(output, faces: faces, extent: extent)
        output = sharpened(output)
        output = vignetted(output, extent: extent)
        output = mixed(original: input, enhanced: output)

        guard let rendered = Self.context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Steps

    private func autoAdjusted(_ image: CIImage) -> CIImage {
        // Red-eye is off: it needs face features and is irrelevant for
        // video-frame captures without flash.
        var output = image
        for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
            filter.setValue(output, forKey: kCIInputImageKey)
            output = filter.outputImage ?? output
        }

        guard settings.vibrance > 0 else { return output }
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = output
        vibrance.amount = settings.vibrance
        return vibrance.outputImage ?? output
    }

    private func warmed(_ image: CIImage) -> CIImage {
        guard settings.warmthKelvin != 0 else { return image }
        // `neutral` is the illuminant the photo is assumed to have been lit by.
        // Declaring it bluer (higher kelvin) than the 6500 K target makes the
        // filter compensate towards yellow, i.e. warmer.
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: CGFloat(6500 + settings.warmthKelvin), y: 0)
        filter.targetNeutral = CIVector(x: 6500, y: 0)
        return filter.outputImage ?? image
    }

    private func clarified(_ image: CIImage, extent: CGRect) -> CIImage {
        guard settings.clarity > 0 else { return image }
        let filter = CIFilter.unsharpMask()
        // Clamped so the blur does not pull transparent pixels in at the edges.
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(min(extent.width, extent.height)) * settings.clarityRadiusFraction
        filter.intensity = settings.clarity
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    private func smoothedSkin(_ image: CIImage, faces: [VNFaceObservation], extent: CGRect) -> CIImage {
        guard settings.skinSmoothing > 0, !faces.isEmpty else { return image }

        var mask = CIImage(color: .black).cropped(to: extent)
        var largestFaceWidth: CGFloat = 0

        for face in faces {
            // Vision's normalised rects share Core Image's bottom-left origin,
            // so they scale straight into image space.
            let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            largestFaceWidth = max(largestFaceWidth, box.width)

            let faceMask = Self.ellipseMask(center: CGPoint(x: box.midX, y: box.midY),
                                            radius: box.width * 0.62,
                                            verticalStretch: 1.25,
                                            level: CGFloat(settings.skinSmoothing),
                                            inverted: false)
            mask = faceMask.applyingFilter("CIMaximumCompositing",
                                           parameters: [kCIInputBackgroundImageKey: mask])

            // Keep the features that carry expression sharp.
            for (center, radius) in Self.featureSpots(of: face, box: box) {
                let hole = Self.ellipseMask(center: center, radius: radius,
                                            verticalStretch: 1, level: 1, inverted: true)
                mask = hole.applyingFilter("CIMinimumCompositing",
                                           parameters: [kCIInputBackgroundImageKey: mask])
            }
        }
        mask = mask.cropped(to: extent)

        // Blur scaled to face size, so a small background face is not smeared
        // and a close-up still gets visibly smoother skin.
        let sigma = max(1.5, largestFaceWidth * 0.012)
        let smooth = image.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(sigma))
            .cropped(to: extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = smooth
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    private func sharpened(_ image: CIImage) -> CIImage {
        guard settings.sharpness > 0 else { return image }
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = settings.sharpness
        filter.radius = 1.5
        return filter.outputImage ?? image
    }

    private func vignetted(_ image: CIImage, extent: CGRect) -> CIImage {
        guard settings.vignette > 0 else { return image }
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = settings.vignette
        filter.radius = 1.6
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    private func mixed(original: CIImage, enhanced: CIImage) -> CIImage {
        guard settings.strength < 1 else { return enhanced }
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = original
        filter.targetImage = enhanced
        filter.time = max(0, settings.strength)
        return filter.outputImage ?? enhanced
    }

    // MARK: - Faces

    /// Faces with landmarks, or an empty list if Vision finds none or fails.
    private static func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return request.results ?? []
    }

    /// Centres and radii (image space) of the eyes, brows and mouth.
    private static func featureSpots(of face: VNFaceObservation, box: CGRect) -> [(CGPoint, CGFloat)] {
        guard let landmarks = face.landmarks else { return [] }
        let regions: [(VNFaceLandmarkRegion2D?, CGFloat)] = [
            (landmarks.leftEye, 0.14), (landmarks.rightEye, 0.14),
            (landmarks.leftEyebrow, 0.13), (landmarks.rightEyebrow, 0.13),
            (landmarks.outerLips, 0.2)
        ]
        return regions.compactMap { region, radiusFraction in
            guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
            // Landmark points are normalised to the face box.
            let meanX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
            let meanY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
            let center = CGPoint(x: box.minX + meanX * box.width,
                                 y: box.minY + meanY * box.height)
            return (center, box.width * radiusFraction)
        }
    }

    /// A feathered elliptical spot: `level` grey inside fading to black
    /// outside, or black inside fading to white when `inverted`.
    private static func ellipseMask(center: CGPoint, radius: CGFloat, verticalStretch: CGFloat,
                                    level: CGFloat, inverted: Bool) -> CIImage {
        let inner = CIColor(red: inverted ? 0 : level, green: inverted ? 0 : level, blue: inverted ? 0 : level)
        let outer = inverted ? CIColor.white : CIColor.black

        let gradient = CIFilter.radialGradient()
        gradient.center = .zero
        gradient.radius0 = Float(radius * 0.55)
        gradient.radius1 = Float(radius)
        gradient.color0 = inner
        gradient.color1 = outer

        // Drawn at the origin so the stretch is about the spot's own centre.
        let transform = CGAffineTransform(scaleX: 1, y: verticalStretch)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return gradient.outputImage?.transformed(by: transform)
            ?? CIImage(color: outer)
    }
}
