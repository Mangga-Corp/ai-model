import Foundation
import CoreGraphics
import Accelerate

/// Protocol defining the image-symmetry analysis interface.
protocol SymmetryAnalyzing {
    func analyzeSymmetry(cgImage: CGImage) -> SymmetryResult
}

/// SymmetryAnalysisService — measures mirror symmetry of the luminance
/// distribution across the frame.
///
/// METHOD (documented, deterministic, honest about limits):
/// 1. Build a 64×64 luminance grid via the shared vImage builder.
/// 2. Bilateral: compare the left half against the mirrored right half.
/// 3. Vertical: compare the top half against the mirrored bottom half.
/// 4. Score each with normalized cross-correlation (NCC):
///
///        NCC = dot(a, mirror(b)) / (‖a‖ × ‖mirror(b)‖)
///
///    1.0 = perfect mirror, ~0 = no relationship.
///
/// WHAT IT MEASURES — and what it does not:
/// This is a measurement of the *light and tone distribution*, not semantic
/// symmetry. A perfectly symmetric building with a person standing off to one
/// side scores lower than it "should", because the person breaks the luminance
/// mirror. That is an honest limitation, not a bug.
///
/// Distinguish from `PhotoAnalysis.bodySymmetry`, which measures whether a
/// detected person's shoulder midpoint aligns with their hip midpoint —
/// a body-pose property, unrelated to this image-level measurement.
final class SymmetryAnalysisService: SymmetryAnalyzing {

    /// Grid size for the luminance plane (shared with lighting analysis).
    private let gridSize = LuminanceGridBuilder.defaultGridSize

    /// NCC above which a frame is reported as symmetric.
    /// 0.75 is deliberately strict: an off-center subject typically drags
    /// the score well below it, so a pass implies genuine mirroring.
    private let symmetryThreshold = 0.75

    func analyzeSymmetry(cgImage: CGImage) -> SymmetryResult {
        guard let grid = LuminanceGridBuilder.build(from: cgImage, gridSize: gridSize) else {
            return SymmetryResult(
                bilateral: 0, vertical: 0, dominant: 0,
                dominantAxis: .none, isSymmetric: false
            )
        }

        let bilateral = Self.normalizedCrossCorrelation(
            grid: grid,
            axis: .horizontal
        )
        let vertical = Self.normalizedCrossCorrelation(
            grid: grid,
            axis: .vertical
        )
        let dominant = max(bilateral, vertical)
        let axis: SymmetryAxis
        if dominant < symmetryThreshold {
            axis = .none
        } else if bilateral >= vertical {
            axis = .bilateral
        } else {
            axis = .vertical
        }

        return SymmetryResult(
            bilateral: bilateral,
            vertical: vertical,
            dominant: dominant,
            dominantAxis: axis,
            isSymmetric: dominant >= symmetryThreshold
        )
    }

    // MARK: - Correlation

    /// Mirror axis for the correlation.
    private enum MirrorAxis {
        case horizontal  // left vs right
        case vertical    // top vs bottom
    }

    /// Computes normalized cross-correlation of the grid against its own mirror.
    private static func normalizedCrossCorrelation(grid: [Float], axis: MirrorAxis) -> Double {
        let n = LuminanceGridBuilder.defaultGridSize
        let half = n / 2

        // Extract one half and the mirrored other half into flat arrays.
        var halfA = [Float](repeating: 0, count: half * n)
        var halfB = [Float](repeating: 0, count: half * n)

        if axis == .horizontal {
            // Left half vs mirrored right half, row by row.
            for y in 0..<n {
                for x in 0..<half {
                    let index = y * half + x
                    halfA[index] = grid[y * n + x]
                    // Mirror: rightmost column maps to the leftmost.
                    halfB[index] = grid[y * n + (n - 1 - x)]
                }
            }
        } else {
            // Top half vs mirrored bottom half.
            for y in 0..<half {
                for x in 0..<n {
                    let index = y * n + x
                    halfA[index] = grid[y * n + x]
                    halfB[index] = grid[(n - 1 - y) * n + x]
                }
            }
        }

        let count = vDSP_Length(halfA.count)

        // NCC = dot(a,b) / (‖a‖ × ‖b‖)
        var dot: Float = 0
        vDSP_dotpr(halfA, 1, halfB, 1, &dot, count)

        var sumSqA: Float = 0
        vDSP_svesq(halfA, 1, &sumSqA, count)

        var sumSqB: Float = 0
        vDSP_svesq(halfB, 1, &sumSqB, count)

        let normA = sqrt(sumSqA)
        let normB = sqrt(sumSqB)
        let denominator = normA * normB

        guard denominator > 0.0001 else { return 0 }

        // Clamp to 0...1 — floating-point error can push a perfect mirror
        // marginally above 1.
        return Double(min(max(dot / denominator, 0), 1))
    }
}
