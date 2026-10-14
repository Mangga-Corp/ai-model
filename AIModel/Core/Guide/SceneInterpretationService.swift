import Foundation
import CoreGraphics

#if canImport(FoundationModels)
import FoundationModels
#endif

/// High-level scene interpretation of a single sampled camera frame.
///
/// This is SEMANTIC understanding only — which kinds of things are in the scene
/// and which matter. It deliberately carries NO coordinates or geometry: the
/// task forbids using a language model as the source of precise object
/// boundaries, and this framework is not a geometry engine. All measurement
/// stays with Vision + the composition evaluator.
struct SceneInterpretation: Equatable {
    /// Free-text scene description, e.g. "a person standing before a tall
    /// building". Display-only; never parsed for numbers.
    let description: String

    /// Environmental element categories the model believes are present, e.g.
    /// ["building", "sky"]. Used only to decide whether environmental context is
    /// worth mentioning — never for geometry.
    let environmentalElements: [String]

    /// Which element the model considers the main subject of interest.
    let primarySubjectHint: String

    /// True when this came from the on-device model. False for the fallback, so
    /// the UI can be honest about provenance.
    let isModelDerived: Bool

    static let unavailable = SceneInterpretation(
        description: "",
        environmentalElements: [],
        primarySubjectHint: "",
        isModelDerived: false
    )
}

/// Interprets sampled camera frames with Apple's on-device Foundation Models.
///
/// DESIGN CONSTRAINTS (from the task):
/// - High-level scene interpretation only. NOT a source of coordinates or
///   geometry — Vision owns all measurement.
/// - Runs on SAMPLED frames, never every frame. The caller controls cadence.
/// - Availability-gated with a functional fallback: when the model is
///   unavailable (ineligible device, Apple Intelligence off, model still
///   downloading), `interpret` returns `.unavailable` and the existing
///   vision-only guidance continues untouched.
///
/// The whole implementation is compiled only when the framework exists
/// (`canImport`), and every entry point is guarded by a runtime availability
/// check, so the app never crashes or blocks on an unsupported device.
final class SceneInterpretationService {

    // MARK: - Availability

    /// Why the on-device model is unavailable, when it is. Surfaced so the UI
    /// can explain the fallback rather than silently degrading.
    enum AvailabilityStatus: Equatable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        /// The human-readable reason when unavailable, or nil when available.
        var message: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Checks the on-device model's availability without running inference.
    static func availability() -> AvailabilityStatus {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            // `SystemLanguageModel.Availability` has exactly two cases:
            // `.available` and `.unavailable(reason)`. The specific causes live
            // on `UnavailableReason`, so the switch is on that nested enum.
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reason: Self.message(for: reason))
            }
        } else {
            return .unavailable(reason: "Requires iOS 27 or later.")
        }
        #else
        return .unavailable(reason: "Foundation Models is not available in this build.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 27.0, *)
    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned on in Settings to enable scene understanding."
        case .modelNotReady:
            return "The on-device model is still preparing. Scene understanding will start shortly."
        @unknown default:
            return "The on-device model is unavailable."
        }
    }
    #endif

    // MARK: - Interpretation

    /// Interprets one sampled frame. Returns `.unavailable` on any failure, so a
    /// semantic hiccup never disturbs the existing camera guidance.
    ///
    /// - Parameter cgImage: A downsampled frame. The image spends from the
    ///   model's token budget, so callers should pass a small image, not the
    ///   full-resolution capture.
    func interpret(cgImage: CGImage) async -> SceneInterpretation {
        guard Self.availability().isAvailable else { return .unavailable }

        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else { return .unavailable }

        do {
            let session = LanguageModelSession()

            // One prompt, structured output. The image is attached as an
            // attachment; the instructions keep the model to description and
            // categories, explicitly NOT coordinates.
            // `PromptBuilder` accepts `PromptRepresentable` components, so a
            // `String` and an `Attachment` compose directly. The image
            // initializer is UNLABELED (`init(_ cgImage:orientation:)`).
            let prompt = Prompt {
                "Describe this photo for composition coaching. Identify the main subject and any environmental elements such as buildings, sky, or landscape. Do not estimate positions or sizes."
                Attachment(cgImage)
            }

            let response = try await session.respond(
                to: prompt,
                generating: SceneReading.self
            )

            let reading = response.content
            return SceneInterpretation(
                description: reading.description,
                environmentalElements: reading.environmentalElements,
                primarySubjectHint: reading.primarySubject,
                isModelDerived: true
            )
        } catch {
            // Any failure degrades to unavailable — the vision-only path is
            // unaffected by design.
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }
}

#if canImport(FoundationModels)
/// Structured output schema for scene interpretation.
///
/// `@Generable` constrains the model to these fields and types, so the result
/// is parsed reliably instead of scraping prose. Contains only strings and a
/// string array — deliberately no numeric geometry.
@available(iOS 27.0, *)
@Generable
struct SceneReading {
    @Guide(description: "One sentence describing the scene.")
    var description: String

    @Guide(description: "Environmental element categories present, e.g. building, sky, trees. Lowercase single words.")
    var environmentalElements: [String]

    @Guide(description: "The main subject of the photograph, e.g. person, group of people.")
    var primarySubject: String
}
#endif
