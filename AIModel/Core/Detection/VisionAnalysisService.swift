import Foundation
import Vision
import CoreGraphics
import UIKit

/// Protocol defining the vision analysis service interface.
protocol VisionAnalyzing {
    func analyze(cgImage: CGImage, orientation: CGImagePropertyOrientation, photoID: UUID) async throws -> PhotoAnalysis
}

/// VisionAnalysisService — implements Stage B: Per-Image Visual Analysis.
///
/// Orchestrates multiple analysis passes:
/// 1. Subject detection (DetectHumanRectanglesRequest)
/// 2. Horizon detection (DetectHorizonRequest)
/// 3. Scene classification (ClassifyImageRequest)
/// 4. Saliency analysis (GenerateAttentionBasedSaliencyImageRequest)
/// 5. Head pose (DetectFaceRectanglesRequest)
/// 6. Body pose (DetectHumanBodyPoseRequest)
/// 7. Aesthetic scoring (CalculateImageAestheticsScoresRequest)
/// 8. Lighting & color (CoreImageAnalysisService — vDSP/Accelerate)
/// 9. Lighting direction (LightingDirectionService — Sobel gradient)
/// 10. Leading lines (LeadingLinesService — DetectContoursRequest)
final class VisionAnalysisService: VisionAnalyzing {

    // MARK: - Dependencies

    private let saliencyService = SaliencyAnalysisService()
    private let poseService = PoseAnalysisService()
    private let coreImageService = CoreImageAnalysisService()
    private let lightingDirectionService = LightingDirectionService()
    private let leadingLinesService = LeadingLinesService()
    private let symmetryService = SymmetryAnalysisService()
    private let goldenRatioService = GoldenRatioAnalysisService()

    // MARK: - Public API

    func analyze(cgImage: CGImage, orientation: CGImagePropertyOrientation, photoID: UUID) async throws -> PhotoAnalysis {
        var subjectPosition: CGPoint?
        var subjectSize: Double?
        var subjectBoundingBox: NormalizedRect?
        var subjectConfidence: Float?
        var bodyExtent: BodyExtent?
        var halfBodyPosition: CGPoint?
        var negativeSpaceDistribution: NegativeSpaceDistribution?

        var horizonAngle: Double?
        var horizonVerticalPosition: Double?

        var sceneClassifications: [String: Double] = [:]

        var saliencyCentroid: CGPoint?
        var saliencyBoundingBox: NormalizedRect?
        var saliencyIntensity: Double?
        var ruleOfThirdsAlignment: RuleOfThirds?

        var headRoll: Double?
        var headYaw: Double?
        var headPitch: Double?
        var faceBoundingBox: NormalizedRect?
        var faceConfidence: Float?

        var bodyPoseJointCount: Int?
        var bodyOrientation: Double?
        var bodySymmetry: Double?
        var dominantJointsGroup: String?

        var meanBrightness: Double?
        var brightnessStdDev: Double?
        var meanSaturation: Double?
        var aestheticScore: Double?
        var captureQuality: String?

        var lightDirection: LightDirection?
        var lightDirectionConfidence: Double?
        var shadowDirection: LightDirection?

        var leadingLinesResult: LeadingLinesResult?
        var symmetryResult: SymmetryResult?
        var goldenRatioResult: GoldenRatioResult?

        var dominantColors: [DominantColor]?
        var colorHarmony: ColorHarmony?
        var colorTemperature: Double?

        var unavailableCharacteristics: Set<Characteristic> = []
        var errorMessage: String?

        // --- Run Vision requests in parallel where possible ---
        async let subjectResult = detectSubject(cgImage: cgImage, orientation: orientation)
        async let horizonResult = detectHorizon(cgImage: cgImage, orientation: orientation)
        async let classificationResult = classifyScene(cgImage: cgImage, orientation: orientation)
        async let saliencyResult = saliencyService.analyzeSaliency(cgImage: cgImage, orientation: orientation)
        async let headPoseResult = poseService.analyzeHeadPose(cgImage: cgImage, orientation: orientation)
        async let bodyPoseResult = poseService.analyzeBodyPose(cgImage: cgImage, orientation: orientation)
        async let aestheticResult = detectAestheticScore(cgImage: cgImage, orientation: orientation)
        async let leadingLinesResultValue = leadingLinesService.analyzeLeadingLines(cgImage: cgImage, orientation: orientation)

        // --- Subject ---
        if let detection = await subjectResult {
            subjectBoundingBox = detection.boundingBox
            subjectSize = detection.area
            subjectConfidence = Float(detection.confidence)
            bodyExtent = detection.bodyExtent

            let centerX = detection.boundingBox.origin.x + detection.boundingBox.width / 2
            let centerY = 1.0 - (detection.boundingBox.origin.y + detection.boundingBox.height / 2)
            subjectPosition = CGPoint(x: centerX, y: centerY)
            negativeSpaceDistribution = computeNegativeSpace(for: subjectPosition!, boundingBox: subjectBoundingBox)

            // Half-body position: centre of the upper-body box, same y-flip
            // convention as subjectPosition so both live in the same space.
            if let upperBox = detection.upperBodyBox {
                let halfX = upperBox.origin.x + upperBox.width / 2
                let halfY = 1.0 - (upperBox.origin.y + upperBox.height / 2)
                halfBodyPosition = CGPoint(x: halfX, y: halfY)
            }
        } else {
            unavailableCharacteristics.insert(.subjectPlacement)
            unavailableCharacteristics.insert(.subjectSize)
            unavailableCharacteristics.insert(.negativeSpace)
        }


        // --- Horizon ---
        if let horizon = await horizonResult {
            horizonAngle = horizon.angleDegrees
            horizonVerticalPosition = horizon.verticalPosition
        } else {
            unavailableCharacteristics.insert(.horizonAlignment)
        }

        // --- Scene ---
        let classifications = await classificationResult
        if !classifications.isEmpty {
            sceneClassifications = classifications
        } else {
            unavailableCharacteristics.insert(.sceneSemiotics)
        }

        // --- Saliency ---
        let saliency = await saliencyResult
        if saliency.isAvailable {
            saliencyCentroid = saliency.centroid
            saliencyBoundingBox = saliency.boundingBox
            saliencyIntensity = saliency.intensity
        } else {
            unavailableCharacteristics.insert(.saliency)
        }

        // --- Head Pose ---
        let headPose = await headPoseResult
        if headPose.isAvailable {
            headRoll = headPose.roll
            headYaw = headPose.yaw
            headPitch = headPose.pitch
            faceBoundingBox = headPose.boundingBox
            faceConfidence = headPose.confidence
        } else {
            unavailableCharacteristics.insert(.headAngle)
        }

        // --- Body Pose ---
        let bodyPose = await bodyPoseResult
        if bodyPose.isAvailable {
            bodyPoseJointCount = bodyPose.jointCount
            bodyOrientation = bodyPose.orientation
            bodySymmetry = bodyPose.symmetry
            dominantJointsGroup = bodyPose.dominantGroup
        } else {
            unavailableCharacteristics.insert(.bodyOrientation)
            unavailableCharacteristics.insert(.bodySymmetry)
        }

        // --- Aesthetic Score ---
        if let aesthetic = await aestheticResult {
            aestheticScore = aesthetic
            captureQuality = aesthetic > 0.3 ? "good" : (aesthetic > -0.1 ? "fair" : "poor")
        } else {
            unavailableCharacteristics.insert(.aestheticQuality)
        }

        // --- Lighting Direction (Sobel gradient) ---
        let lightResult = lightingDirectionService.analyzeLightDirection(cgImage: cgImage)
        lightDirection = lightResult.direction
        lightDirectionConfidence = lightResult.confidence
        shadowDirection = lightResult.shadowDirection
        if lightResult.direction == nil || lightResult.confidence < 0.20 {
            unavailableCharacteristics.insert(.lightDirection)
        }

        // --- Leading Lines (contours) ---
        let linesResult = await leadingLinesResultValue
        leadingLinesResult = linesResult
        if !linesResult.isAvailable {
            unavailableCharacteristics.insert(.leadingLines)
        }

        // --- Symmetry (luminance mirror correlation) ---
        symmetryResult = symmetryService.analyzeSymmetry(cgImage: cgImage)
        if !(symmetryResult?.isSymmetric ?? false) {
            unavailableCharacteristics.insert(.symmetry)
        }

        // --- Golden Ratio (derived from the subject position already measured) ---
        goldenRatioResult = goldenRatioService.analyzeGoldenRatio(subjectPosition: subjectPosition)
        if subjectPosition == nil || !(goldenRatioResult?.isAtGoldenPoint ?? false) {
            unavailableCharacteristics.insert(.goldenRatio)
        }

        // --- Lighting & Color (Core Image) ---
        let lighting = coreImageService.analyzeLighting(cgImage: cgImage)
        meanBrightness = lighting.meanBrightness
        brightnessStdDev = lighting.brightnessStdDev
        meanSaturation = lighting.meanSaturation

        if meanBrightness == nil {
            unavailableCharacteristics.insert(.brightness)
            unavailableCharacteristics.insert(.contrast)
        }
        if meanSaturation == nil {
            unavailableCharacteristics.insert(.saturation)
        }

        let colorResult = coreImageService.analyzeColors(cgImage: cgImage)
        dominantColors = colorResult.dominantColors
        colorHarmony = colorResult.harmony
        colorTemperature = colorResult.colorTemperature

        if dominantColors?.isEmpty ?? true {
            unavailableCharacteristics.insert(.colorHarmony)
        }
        if colorTemperature == nil {
            unavailableCharacteristics.insert(.colorTemperature)
        }

        // --- Rule of Thirds ---
        if let pos = subjectPosition {
            ruleOfThirdsAlignment = classifyRuleOfThirds(position: pos)
        } else {
            unavailableCharacteristics.insert(.ruleOfThirds)
        }

        // --- Visual Balance (from saliency centroid vs image center) ---
        if saliencyCentroid == nil {
            unavailableCharacteristics.insert(.visualBalance)
        }

        // --- Determine status ---
        //
        // A missing SUBJECT is disqualifying. Subject placement is the axis the
        // entire preference profile is organised around — position, size,
        // negative space, golden ratio and rule-of-thirds all derive from it.
        // A photo with no subject would contribute lighting and color data to a
        // profile whose central claim is about where subjects sit, so it is
        // marked failed and excluded from aggregation rather than counted as a
        // partial success.
        //
        // Other missing characteristics (horizon, head pose) still yield
        // `.partial` — they are per-photo gaps, not structural ones.
        let totalCharacteristics = Characteristic.allCases.count
        let availableCount = totalCharacteristics - unavailableCharacteristics.count

        let status: AnalysisStatus
        if subjectPosition == nil {
            status = .failed
        } else if availableCount == totalCharacteristics {
            status = .success
        } else if availableCount > 0 {
            status = .partial
        } else {
            status = .failed
        }

        if status == .failed {
            errorMessage = subjectPosition == nil
                ? "No subject detected in this photo."
                : "No characteristics could be detected in this image."
        }

        let aspectRatio = Double(cgImage.width) / Double(cgImage.height)

        return PhotoAnalysis(
            id: UUID(),
            referencePhotoID: photoID,
            subjectPosition: subjectPosition,
            subjectSize: subjectSize,
            subjectBoundingBox: subjectBoundingBox,
            subjectConfidence: subjectConfidence,
            halfBodyPosition: halfBodyPosition,
            bodyExtent: bodyExtent,
            negativeSpaceDistribution: negativeSpaceDistribution,
            saliencyCentroid: saliencyCentroid,
            saliencyBoundingBox: saliencyBoundingBox,
            saliencyIntensity: saliencyIntensity,
            ruleOfThirdsAlignment: ruleOfThirdsAlignment,
            horizonAngle: horizonAngle,
            horizonVerticalPosition: horizonVerticalPosition,
            headRoll: headRoll,
            headYaw: headYaw,
            headPitch: headPitch,
            faceBoundingBox: faceBoundingBox,
            faceConfidence: faceConfidence,
            bodyPoseJointCount: bodyPoseJointCount,
            bodyOrientation: bodyOrientation,
            bodySymmetry: bodySymmetry,
            dominantJointsGroup: dominantJointsGroup,
            meanBrightness: meanBrightness,
            brightnessStdDev: brightnessStdDev,
            meanSaturation: meanSaturation,
            aestheticScore: aestheticScore,
            captureQuality: captureQuality,
            lightDirection: lightDirection,
            lightDirectionConfidence: lightDirectionConfidence,
            shadowDirection: shadowDirection,
            leadingLines: leadingLinesResult,
            symmetry: symmetryResult,
            goldenRatio: goldenRatioResult,
            dominantColors: dominantColors,
            colorHarmony: colorHarmony,
            colorTemperature: colorTemperature,
            sceneClassifications: sceneClassifications,
            imageDimensions: CGSize(width: cgImage.width, height: cgImage.height),
            orientation: orientation,
            aspectRatio: aspectRatio,
            status: status,
            errorMessage: errorMessage,
            unavailableCharacteristics: unavailableCharacteristics
        )
    }

    // MARK: - Vision Requests

    private func detectSubject(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> SubjectDetection? {
        // Run BOTH detection modes so body extent can be CLASSIFIED rather than
        // assumed. The full-body box is what the rest of the pipeline uses; the
        // upper-body box exists only to compare against it. This costs one extra
        // Vision pass per photo, which is the price of an honest full/half
        // measurement instead of a guess.
        async let fullResult = detectLargestPerson(cgImage: cgImage, orientation: orientation, upperBodyOnly: false)
        async let upperResult = detectLargestPerson(cgImage: cgImage, orientation: orientation, upperBodyOnly: true)

        guard let full = await fullResult else { return nil }
        let upper = await upperResult

        let bodyExtent = Self.classifyBodyExtent(fullBox: full.box, upperBox: upper?.box)

        return SubjectDetection(
            boundingBox: full.box,
            area: full.area,
            confidence: full.confidence,
            bodyExtent: bodyExtent,
            upperBodyBox: upper?.box
        )
    }

    /// Runs person detection in one mode and returns the largest person's box.
    private func detectLargestPerson(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        upperBodyOnly: Bool
    ) async -> (box: NormalizedRect, area: Double, confidence: Double)? {
        var request = DetectHumanRectanglesRequest()
        request.upperBodyOnly = upperBodyOnly

        do {
            let results: [HumanObservation] = try await request.perform(on: cgImage, orientation: orientation)
            guard let largest = results.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
                return nil
            }
            let box = largest.boundingBox
            let area = Double(box.width * box.height)
            return (box, area, Double(largest.confidence))
        } catch {
            return nil
        }
    }

    /// Classifies full vs half body by comparing the two detection boxes.
    ///
    /// The upper-body box always fits INSIDE the full-body box. When the subject
    /// is framed as a half body, the full-body detector still returns a tall box
    /// (it extrapolates the body), so the ratio of upper height to full height
    /// is what distinguishes them: near 1.0 means the visible subject is mostly
    /// torso-and-up (half body); well below 1.0 means the full figure extends
    /// below the torso (full body).
    ///
    /// Thresholds are deliberately conservative — a borderline ratio is reported
    /// as `.undetermined` rather than guessed.
    static func classifyBodyExtent(fullBox: NormalizedRect, upperBox: NormalizedRect?) -> BodyExtent {
        guard let upperBox else { return .undetermined }
        guard fullBox.height > 0 else { return .undetermined }

        let ratio = Double(upperBox.height / fullBox.height)

        // Upper box covers most of the full box → the framing is a half body.
        if ratio >= 0.80 {
            return .halfBody
        }
        // Full figure clearly extends well below the torso → full body.
        if ratio <= 0.55 {
            return .fullBody
        }
        return .undetermined
    }

    private func detectHorizon(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> HorizonResult? {
        let request = DetectHorizonRequest()
        do {
            let result: HorizonObservation? = try await request.perform(on: cgImage, orientation: orientation)
            guard let horizon = result else { return nil }
            let angleDegrees = horizon.angle.converted(to: .degrees).value
            let verticalPosition = estimateHorizonVerticalPosition(cgImage: cgImage, observation: horizon)
            return HorizonResult(angleDegrees: angleDegrees, verticalPosition: verticalPosition)
        } catch {
            return nil
        }
    }

    private func classifyScene(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> [String: Double] {
        let request = ClassifyImageRequest()
        do {
            let results: [ClassificationObservation] = try await request.perform(on: cgImage, orientation: orientation)
            return Dictionary(uniqueKeysWithValues: results.map { ($0.identifier, Double($0.confidence)) })
        } catch {
            return [:]
        }
    }

    private func detectAestheticScore(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> Double? {
        let request = CalculateImageAestheticsScoresRequest()
        do {
            let observation: ImageAestheticsScoresObservation = try await request.perform(on: cgImage, orientation: orientation)
            let score = observation.overallScore
            return Double(score)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func estimateHorizonVerticalPosition(cgImage: CGImage, observation: HorizonObservation) -> Double {
        let imageHeight = Double(cgImage.height)
        let transform = observation.transform
        let sampleX = Double(cgImage.width) / 2.0
        let c = Double(transform.c), d = Double(transform.d)
        let ty = Double(transform.ty)

        if abs(d) > 0.0001 {
            let y = -(c * sampleX + ty) / d
            let normalizedY = y / imageHeight
            return max(0.0, min(1.0, normalizedY))
        } else {
            let invertT = transform.inverted()
            let center = CGPoint(x: sampleX, y: imageHeight / 2.0).applying(invertT)
            return max(0.0, min(1.0, center.y / imageHeight))
        }
    }

    private func computeNegativeSpace(for position: CGPoint, boundingBox: NormalizedRect?) -> NegativeSpaceDistribution {
        guard let box = boundingBox else { return .balanced }
        let leftSpace = box.origin.x
        let rightSpace = 1.0 - (box.origin.x + box.width)
        let topSpace = box.origin.y
        let bottomSpace = 1.0 - (box.origin.y + box.height)

        let horizontalDiff = abs(leftSpace - rightSpace)
        let verticalDiff = abs(topSpace - bottomSpace)

        if horizontalDiff > 0.15 && horizontalDiff >= verticalDiff {
            return leftSpace > rightSpace ? .leftHeavy : .rightHeavy
        }
        if verticalDiff > 0.15 {
            return topSpace > bottomSpace ? .topHeavy : .bottomHeavy
        }
        return .balanced
    }

    /// Classifies subject position into a rule-of-thirds grid cell.
    private func classifyRuleOfThirds(position: CGPoint) -> RuleOfThirds {
        let x = position.x
        let y = position.y

        // Thresholds at 1/3 and 2/3
        let horizontal: Int
        if x < 0.33 { horizontal = 0 }       // left
        else if x > 0.67 { horizontal = 2 }  // right
        else { horizontal = 1 }              // center

        let vertical: Int
        if y < 0.33 { vertical = 0 }         // top
        else if y > 0.67 { vertical = 2 }    // bottom
        else { vertical = 1 }                // middle

        switch (vertical, horizontal) {
        case (0, 0): return .topLeft
        case (0, 1): return .topCenter
        case (0, 2): return .topRight
        case (1, 0): return .middleLeft
        case (1, 1): return .center
        case (1, 2): return .middleRight
        case (2, 0): return .bottomLeft
        case (2, 1): return .bottomCenter
        case (2, 2): return .bottomRight
        default: return .center
        }
    }

    // MARK: - Private Types

    private struct SubjectDetection {
        let boundingBox: NormalizedRect
        let area: Double
        let confidence: Double
        /// Full vs half body, classified by comparing both detection modes.
        let bodyExtent: BodyExtent
        /// The upper-body box, retained so its centre can be stored as the
        /// half-body position the guide box uses.
        let upperBodyBox: NormalizedRect?
    }

    private struct HorizonResult {
        let angleDegrees: Double
        let verticalPosition: Double
    }
}
