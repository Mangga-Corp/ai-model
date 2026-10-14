import Foundation
import Vision
import CoreGraphics
import simd

/// Protocol defining the leading-lines analysis interface.
protocol LeadingLinesAnalyzing {
    func analyzeLeadingLines(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> LeadingLinesResult
}

/// LeadingLinesService — detects straight structural lines (architecture, roads,
/// fences, shorelines) that create depth and guide the viewer's eye.
///
/// METHOD (documented, deterministic):
/// 1. Run `DetectContoursRequest` (iOS 18+ Swift API) to get edge contours.
/// 2. Walk the top-level contours and their children.
/// 3. For each contour, simplify with `polygonApproximation(epsilon:)`
///    (Ramer–Douglas–Peucker) to extract straight segments.
/// 4. Filter to significant segments (long enough to be intentional).
/// 5. Compute the dominant angle and how strongly lines cluster around it.
///
/// HONESTY ABOUT LIMITS (surfaced in limitations, never hidden):
/// - True vanishing-point detection requires converging-line intersection
///   analysis. We report the dominant angle and cluster strength, which is
///   the measurable signal, rather than claiming a detected vanishing point.
/// - Curved contours (people, trees) produce noisy segments; the epsilon
///   filter and minimum-length threshold suppress most of these.
/// - PRD Rule 4: no contours detected is reported as "unavailable", NOT as
///   evidence that the photograph contains no leading lines.
final class LeadingLinesService: LeadingLinesAnalyzing {

    /// Contour simplification tolerance. Higher = fewer, straighter segments.
    private let polygonEpsilon: Float = 0.02

    /// Minimum segment length (relative to frame diagonal) to be "significant".
    private let minimumSegmentLength: Double = 0.18

    /// Minimum number of significant segments before we report a dominant angle.
    private let minimumLineCount = 2

    /// Angular window (degrees) for counting a line as "diagonal".
    private let diagonalLow: Double = 25
    private let diagonalHigh: Double = 65

    func analyzeLeadingLines(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> LeadingLinesResult {
        var request = DetectContoursRequest()
        request.contrastAdjustment = 1.5
        request.contrastPivot = nil

        do {
            let observation: ContoursObservation = try await request.perform(on: cgImage, orientation: orientation)

            var allLines: [DetectedLine] = []
            let frameDiagonal = sqrt(2.0)  // normalized space is 0-1 on both axes

            // Walk top-level contours and their children recursively
            for contour in observation.topLevelContours {
                extractLines(from: contour, frameDiagonal: frameDiagonal, into: &allLines)
                for child in contour.childContours {
                    extractLines(from: child, frameDiagonal: frameDiagonal, into: &allLines)
                }
            }

            // Filter to significant lines
            let significant = allLines.filter { $0.length >= minimumSegmentLength }

            guard significant.count >= minimumLineCount else {
                return LeadingLinesResult(
                    lines: significant,
                    lineCount: significant.count,
                    dominantAngle: nil,
                    convergenceStrength: nil,
                    hasDiagonalDominance: false,
                    isAvailable: false
                )
            }

            // Compute dominant angle: circular mean of line orientations
            let dominantAngle = computeDominantAngle(lines: significant)

            // Compute convergence strength: fraction of lines within ±15° of dominant
            let convergenceStrength = computeConvergenceStrength(lines: significant, dominantAngle: dominantAngle)

            // Diagonal dominance: majority of significant lines are diagonal
            let diagonalCount = significant.filter { line in
                let a = line.angle
                return (a >= diagonalLow && a <= diagonalHigh) ||
                       (a >= (180 - diagonalHigh) && a <= (180 - diagonalLow))
            }.count
            let hasDiagonalDominance = Double(diagonalCount) / Double(significant.count) > 0.5

            return LeadingLinesResult(
                lines: significant,
                lineCount: significant.count,
                dominantAngle: dominantAngle,
                convergenceStrength: convergenceStrength,
                hasDiagonalDominance: hasDiagonalDominance,
                isAvailable: true
            )
        } catch {
            return LeadingLinesResult(
                lines: [], lineCount: 0, dominantAngle: nil,
                convergenceStrength: nil, hasDiagonalDominance: false,
                isAvailable: false
            )
        }
    }

    // MARK: - Private

    /// Extracts straight segments from a contour via polygon approximation.
    private func extractLines(from contour: ContoursObservation.Contour, frameDiagonal: Double, into lines: inout [DetectedLine]) {
        do {
            let simplified = try contour.polygonApproximation(epsilon: polygonEpsilon)
            let points = simplified.normalizedPoints  // [simd_float2], Vision coords (y up)

            guard points.count >= 2 else { return }

            for i in 0..<(points.count - 1) {
                let p1 = points[i]
                let p2 = points[i + 1]

                // Convert to UIKit coords (y down) for consistency with the rest of the app
                let start = CGPoint(x: CGFloat(p1.x), y: 1.0 - CGFloat(p1.y))
                let end = CGPoint(x: CGFloat(p2.x), y: 1.0 - CGFloat(p2.y))

                let dx = Double(p2.x - p1.x)
                let dy = Double(p2.y - p1.y)
                let length = sqrt(dx * dx + dy * dy) / frameDiagonal

                // Line orientation angle: 0-180 degrees (undirected)
                var angle = atan2(abs(dy), abs(dx)) * 180 / .pi

                // Normalize: we want orientation in [0, 180)
                if angle >= 180 { angle -= 180 }

                lines.append(DetectedLine(
                    start: start,
                    end: end,
                    length: length,
                    angle: angle
                ))
            }
        } catch {
            // polygonApproximation can throw for degenerate contours; skip silently
            return
        }
    }

    /// Computes the circular mean angle of line orientations (0-180°).
    private func computeDominantAngle(lines: [DetectedLine]) -> Double {
        // Weight by length so longer lines count more
        var sumSin: Double = 0
        var sumCos: Double = 0
        var totalWeight: Double = 0

        for line in lines {
            // Double the angle so 0° and 180° map to the same orientation
            let radians = line.angle * 2 * .pi / 180
            let weight = line.length
            sumSin += sin(radians) * weight
            sumCos += cos(radians) * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return 0 }

        let meanRadians = atan2(sumSin, sumCos)
        var meanAngle = meanRadians * 180 / .pi / 2  // halve back to 0-180

        if meanAngle < 0 { meanAngle += 180 }
        if meanAngle >= 180 { meanAngle -= 180 }

        return meanAngle
    }

    /// Fraction of lines within ±15° of the dominant angle.
    private func computeConvergenceStrength(lines: [DetectedLine], dominantAngle: Double) -> Double {
        guard !lines.isEmpty else { return 0 }

        let window = 15.0
        var matching = 0
        for line in lines {
            var diff = abs(line.angle - dominantAngle)
            if diff > 90 { diff = 180 - diff }  // account for undirected lines
            if diff <= window { matching += 1 }
        }

        return Double(matching) / Double(lines.count)
    }
}
