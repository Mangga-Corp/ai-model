import Foundation

/// Decides which measured regions may support user-facing claims.
///
/// WHY THIS EXISTS. DETR returns one class per pixel and no confidence, so a
/// mask can be perfectly well formed and still carry a wrong label. Structural
/// validity (the map decoded, the region was measured) therefore says nothing
/// about whether the label is believable. Two cases were observed on real
/// photos, and each is handled by one explicit rule:
///
///  R1  IMPLAUSIBLE OBJECT SIZE. An object class (a countable "thing" such as
///      cow, bed, refrigerator) covering at least half the frame. In a portrait
///      that is far more likely a mislabelled surface, clothing or artwork than
///      a real object. Observed: a headscarf labelled "cow" over 52% of a
///      close-up, a painted dress and park labelled "bed" over 63%, and a whole
///      film contact sheet labelled "refrigerator" over 92%. Legitimate large
///      objects seen so far stay below it (a motorcycle rider's motorcycle: 39%).
///      A mislabel smaller than half the frame is NOT caught: see the limits below.
///
///  R2  UNCORROBORATED ROCK. "Rock" that is (nearly) all the natural area of
///      the frame, with no sky, no "mountain" class, and no vegetation, water or
///      open ground beside it. The model also uses "rock" for stone walls,
///      cliffs and bark. Observed: a castle's stone wall labelled rock over 96%.
///      It is the same condition the scene inference already applied to refuse
///      "natural environment"; it now applies once, here, so the ranking and
///      measurements agree with the scene.
///
/// A set-aside region is still listed and measured (so the user sees what the model
/// said), but it is excluded from the ranking, the scene inference, the element
/// measurements and the preference tendencies. Setting a region aside is NOT a
/// claim that the label is wrong, only that it is not trusted enough to be used.
///
/// LIMITS. These rules catch only labels that are implausible on their face. A
/// wrong label of ordinary size (a white wall labelled sky, a shirt labelled wall)
/// is not detectable here and still flows through. The rules change no weights
/// or thresholds elsewhere.
nonisolated enum RegionReliabilityAssessor {

    /// R1: an object class covering at least this share of the image is set aside.
    static let implausibleObjectArea = 0.5
    /// R2: rock must be at least this share of the natural area to be doubted.
    static let rockShareOfNature = 0.9
    /// R2: a "mountain" class at least this large corroborates rock.
    static let mountainCorroboration = 0.03
    /// R2: visible sky at least this large corroborates rock.
    static let skyCorroboration = 0.05
    /// R2 only concerns rock that could pass as the scenery: the same 20% floor the
    /// natural-environment rule uses. A small rock in a street scene is left alone.
    static let sceneryFloor = 0.20

    static func assess(_ regions: [SemanticRegion]) -> [SemanticRegion] {
        var result = regions

        // R1.
        for i in result.indices where result[i].isValid
            && result[i].family.kind == .object
            && result[i].areaFraction >= implausibleObjectArea {
            result[i].reliability = .setAside(String(
                format: "A single object class (%@) covers %.0f%% of the frame. In a portrait that is more likely a mislabelled surface, clothing or artwork than a real object, and the model gives no confidence to tell them apart.",
                result[i].family.displayName.lowercased(), result[i].areaFraction * 100))
        }

        // R2, judged on what is still eligible.
        let eligible = result.filter { $0.isValid && $0.reliability.isEligible && $0.family.group.isEnvironmental }
        func area(_ group: ElementGroup) -> Double { eligible.filter { $0.family.group == group }.reduce(0) { $0 + $1.areaFraction } }
        let landform = area(.landform)
        let naturalArea = landform + area(.vegetation) + area(.water) + area(.naturalGround)
        let mountain = eligible.flatMap(\.rawLabels)
            .filter { SegmentationTaxonomy.familyKey(forLabel: $0.label) == "mountain" }
            .reduce(0) { $0 + $1.areaFraction }
        let sky = area(.sky)

        if landform >= sceneryFloor,
           landform >= rockShareOfNature * naturalArea,
           mountain < mountainCorroboration,
           sky < skyCorroboration {
            for i in result.indices where result[i].isValid && result[i].reliability.isEligible
                && result[i].family.group == .landform {
                result[i].reliability = .setAside(String(
                    format: "'Rock' covers %.0f%% of the frame with no sky, mountain, vegetation, water or open ground to support it as scenery. The model also uses this class for stone walls, cliffs and bark.",
                    result[i].areaFraction * 100))
            }
        }
        return result
    }
}
