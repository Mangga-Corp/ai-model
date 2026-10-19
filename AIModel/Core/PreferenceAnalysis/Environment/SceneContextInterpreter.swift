import Foundation
import CoreGraphics

// MARK: - Names

nonisolated extension SceneContextCategory {
    var displayName: String {
        switch self {
        case .indoorInterior: return "Indoor interior"
        case .cafeOrRestaurant: return "Café or restaurant"
        case .urbanStreet: return "Urban street"
        case .architecturalEnvironment: return "Architectural environment"
        case .parkOrGarden: return "Park or garden"
        case .naturalEnvironment: return "Natural environment"
        case .beachOrWaterfront: return "Beach or waterfront"
        case .studioOrPlainBackground: return "Studio or plain background"
        case .mixedEnvironment: return "Mixed environment"
        case .unknown: return "Unknown"
        }
    }
}

nonisolated extension SceneSetting {
    var displayName: String {
        switch self {
        case .indoor: return "Indoor"
        case .outdoor: return "Outdoor"
        case .undetermined: return "Undetermined"
        }
    }
}

nonisolated extension EnvironmentCharacter {
    var displayName: String {
        switch self {
        case .built: return "Mostly built"
        case .natural: return "Mostly natural"
        case .mixed: return "Built and natural"
        case .undetermined: return "Undetermined"
        }
    }
}

nonisolated extension ElementGroup {
    var displayName: String {
        switch self {
        case .person: return "People"
        case .sky: return "Sky"
        case .water: return "Water"
        case .landform: return "Mountains and rock"
        case .vegetation: return "Trees and grass"
        case .naturalGround: return "Sand, snow or bare ground"
        case .pavedSurface: return "Roads and paving"
        case .architecture: return "Buildings and structures"
        case .wall: return "Walls"
        case .opening: return "Doors and windows"
        case .interiorSurface: return "Ceiling and floor"
        case .furniture: return "Furniture"
        case .furnishing: return "Furnishings and fittings"
        case .foodAndDrink: return "Food and tableware"
        case .vehicle: return "Vehicles"
        case .streetFixture: return "Street fixtures"
        case .animal: return "Animals"
        case .carriedItem: return "Carried items"
        case .other: return "Other objects"
        }
    }
}

// MARK: - Interpreter

/// Feature C: infers the broad kind of place from what the segmentation sees.
///
/// OBSERVATION and INTERPRETATION stay apart. Observation is how much of the
/// visible surroundings each group of regions covers (`SceneCue`). The
/// interpretation reads those shares through explicit rules and reports why.
///
/// STEPS
///  1. Setting. Outdoor cues (sky, water, mountains, trees, paving, building
///     exteriors, vehicles) and indoor cues (ceiling, floor, furniture,
///     furnishings) each add a fixed weight. Indoor or outdoor needs weight >= 3
///     and at least twice the other side, otherwise the setting is undetermined.
///     Walls, doors and windows count for neither side.
///  2. Specific categories each have a gate of required segmentation evidence
///     (for example "park" needs substantial vegetation, little built structure
///     AND a park cue such as a bench, flowers, lawn or a path). A gate that
///     fails produces no candidate, so object presence alone proves nothing: a
///     tree and a building do not make a park.
///  3. A candidate must reach strength 0.50 to be primary. A child category
///     (park, beach, café, urban street) replaces its broader parent
///     (natural, indoor, architectural) only when its own gate also passed.
///     Two unrelated candidates within 0.10 of each other are reported as a
///     mixed environment, never as a coin-flip winner.
///  4. FastViT labels add 0.15 (0.30 for café) to a candidate that already
///     passed its gate, and are the only way a café can become primary. They
///     cannot create a category.
///  5. Quality: segmentation only is capped at moderate; high needs the
///     classifier to agree as well. Little visible surroundings, many
///     unsupported labels or ambiguity each lower it.
nonisolated enum SceneContextInterpreter {

    static let minimumEnvironmentFraction = ObjectSegmentationResult.minimumInterpretableSurroundings
    static let primaryThreshold = 0.50
    static let secondaryThreshold = 0.30
    static let ambiguityGap = 0.10
    static let hintBoost = 0.15
    static let cafeHintBoost = 0.30
    static let settingMinimumWeight = 3
    static let settingDominance = 2.0

    private struct Draft {
        var category: SceneContextCategory
        var strength: Double
        var reasons: [String]
        var corroborated: Bool
    }

    private static let childToParent: [SceneContextCategory: SceneContextCategory] = [
        .parkOrGarden: .naturalEnvironment,
        .beachOrWaterfront: .naturalEnvironment,
        .cafeOrRestaurant: .indoorInterior,
        .urbanStreet: .architecturalEnvironment,
    ]

    static let method = "Scene category is inferred from which kinds of region are visible and how much of the surroundings they cover. The segmentation model recognises surfaces and objects, not places, so this is an inference rather than a measurement."

    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private static func empty(_ assessment: Assessment, cues: [SceneCue] = []) -> SceneContextResult {
        SceneContextResult(primary: .unknown, primaryStrength: 0, secondary: [], setting: .undetermined,
                           settingReasons: [], character: .undetermined, builtShare: nil, observedCues: cues,
                           classifierHints: [], isAmbiguous: false, assessment: assessment)
    }

    static func interpret(_ segmentation: ObjectSegmentationResult,
                          classifier: EvidenceOutcome<[ScoredLabel]>) -> SceneContextResult {

        guard segmentation.availability.hasValidOutput else {
            return empty(.unavailable(
                "The scene could not be assessed because segmentation is unavailable. The image classifier alone is not used to name a place.",
                limitations: [method]))
        }

        // Only the surroundings count: not the person, not what they carry or wear.
        let regions = segmentation.environmentalRegions
        let setAside = segmentation.setAsideRegions.filter { $0.family.group.isEnvironmental }
        let env = segmentation.environmentFraction

        var groupArea: [ElementGroup: Double] = [:]
        for r in regions { groupArea[r.family.group, default: 0] += r.areaFraction }
        func g(_ group: ElementGroup) -> Double { groupArea[group] ?? 0 }

        // Class-level areas. Regions merge classes ("Trees and grass"), so single
        // classes are read from the labels each region absorbed.
        let classAreas: [String: Double] = regions.flatMap(\.rawLabels).reduce(into: [:]) { acc, label in
            if let key = SegmentationTaxonomy.familyKey(forLabel: label.label) { acc[key, default: 0] += label.areaFraction }
        }
        func a(_ keys: [String]) -> Double { keys.reduce(0) { $0 + (classAreas[$1] ?? 0) } }
        func has(_ key: String) -> Bool { (classAreas[key] ?? 0) > 0 }
        func share(_ area: Double) -> Double { env > 0 ? area / env : 0 }

        // Observed cues (facts).
        let cues: [SceneCue] = ElementGroup.allCases
            .filter { $0 != .person && g($0) >= 0.02 }
            .map { SceneCue(group: $0, label: $0.displayName, areaFraction: g($0), environmentShare: share(g($0))) }
            .sorted { $0.areaFraction != $1.areaFraction ? $0.areaFraction > $1.areaFraction : $0.label < $1.label }

        // INTERPRETATION ELIGIBILITY. If too little of the frame is interpretable surroundings (or
        // too little of the image carries supported labels), the cues are shown as observations but
        // no place is named.
        if case .limited(let why) = segmentation.interpretation {
            return empty(.insufficient(
                "The scene is not assessed because \(why).",
                limitations: [method]), cues: cues)
        }

        // Classifier hints.
        var hints: [SceneHint] = []
        if let labels = classifier.value {
            for l in labels where l.score >= SceneHintTable.minimumScore {
                if let category = SceneHintTable.category(forLabel: l.label) {
                    hints.append(SceneHint(label: SceneHintTable.shortName(l.label), score: l.score, supports: category, used: false))
                }
            }
        }
        var usedHints = Set<String>()
        func boost(_ category: SceneContextCategory, _ amount: Double) -> (amount: Double, note: String)? {
            guard let best = hints.filter({ $0.supports == category }).max(by: { $0.score < $1.score }) else { return nil }
            usedHints.insert(best.label)
            return (amount, "the image classifier also reports \"\(best.label)\" (\(pct(best.score)))")
        }

        // 1. Setting.
        let sky = g(.sky), water = g(.water), landform = g(.landform), vegetation = g(.vegetation)
        let sand = a(["sand"]), paved = g(.pavedSurface)
        let ground = g(.naturalGround)
        let exteriorArchitecture = a(["building", "house", "roof", "bridge", "tent"])
        let walls = g(.wall)
        let vehicles = g(.vehicle)
        // A bench says nothing about streets (parks have them), so it is not a street fixture here.
        let fixtures = a(["traffic light", "fire hydrant", "stop sign", "parking meter"])
        let ceiling = a(["ceiling"]), floor = a(["floor"]), furniture = g(.furniture), furnishing = g(.furnishing)

        // Weights: a modest amount of a cue counts less than a large one (>= 25%).
        var outdoorCues: [(weight: Int, text: String)] = []
        func outdoor(_ area: Double, small: Double, _ text: String, base: Int = 2) {
            guard area >= small else { return }
            outdoorCues.append((area >= 0.25 ? 3 : base, "\(text) (\(pct(area)))"))
        }
        outdoor(sky, small: 0.05, "sky is visible", base: 3)
        outdoor(water, small: 0.05, "water is visible")
        outdoor(landform, small: 0.05, "mountains or rock are visible")
        outdoor(vegetation, small: 0.08, "trees or grass are visible")
        outdoor(ground, small: 0.04, "sand, snow or bare ground is visible")
        outdoor(paved, small: 0.04, "roads or paving are visible")
        outdoor(exteriorArchitecture, small: 0.08, "building exteriors are visible")
        if vehicles >= 0.01 || fixtures >= 0.005 { outdoorCues.append((1, "vehicles or street fixtures are visible")) }

        var indoorCues: [(weight: Int, text: String)] = []
        func indoor(_ ok: Bool, _ weight: Int, _ text: String) { if ok { indoorCues.append((weight, text)) } }
        indoor(ceiling >= 0.03, 3, "a ceiling is visible (\(pct(ceiling)))")
        indoor(floor >= 0.12, 3, "a large floor is visible (\(pct(floor)))")
        indoor(floor >= 0.05 && floor < 0.12, 2, "a floor is visible (\(pct(floor)))")
        indoor(furniture >= 0.04, 3, "furniture is visible (\(pct(furniture)))")
        indoor(furnishing >= 0.03, 1, "furnishings are visible (\(pct(furnishing)))")

        let outdoorScore = outdoorCues.reduce(0) { $0 + $1.weight }
        let indoorScore = indoorCues.reduce(0) { $0 + $1.weight }

        let setting: SceneSetting
        var settingReasons: [String]
        if indoorScore >= settingMinimumWeight && Double(indoorScore) >= settingDominance * Double(outdoorScore) {
            setting = .indoor; settingReasons = indoorCues.map(\.text)
        } else if outdoorScore >= settingMinimumWeight && Double(outdoorScore) >= settingDominance * Double(indoorScore) {
            setting = .outdoor; settingReasons = outdoorCues.map(\.text)
        } else {
            setting = .undetermined
            settingReasons = (indoorScore > 0 && outdoorScore > 0)
                ? ["both indoor and outdoor cues are present (\(indoorScore) vs \(outdoorScore)), so the setting is not decided"]
                : ["too few indoor or outdoor cues are visible to decide"]
        }

        // Character (built vs natural).
        let builtArea = ElementGroup.allCases.filter(\.isBuilt).reduce(0) { $0 + g($1) }
        let naturalArea = ElementGroup.allCases.filter(\.isNatural).reduce(0) { $0 + g($1) }
        var builtShare: Double?
        var character = EnvironmentCharacter.undetermined
        if builtArea + naturalArea >= 0.05 {
            let b = builtArea / (builtArea + naturalArea)
            builtShare = b
            character = b >= 0.70 ? .built : (b <= 0.30 ? .natural : .mixed)
        }
        let builtEnv = share(builtArea), naturalEnv = share(naturalArea)

        // 2. Candidates (each gate needs segmentation evidence).
        var drafts: [Draft] = []
        func finish(_ category: SceneContextCategory, _ base: Double, _ reasons: [String], hint: Double = hintBoost, cap: Double = 0.90) {
            var strength = base
            var notes = reasons
            var corroborated = false
            if let b = boost(category, hint) { strength += b.amount; notes.append(b.note); corroborated = true }
            drafts.append(Draft(category: category, strength: min(cap, strength), reasons: notes, corroborated: corroborated))
        }

        // Beach or waterfront.
        if setting == .outdoor, water >= 0.10 || (sand >= 0.06 && water >= 0.03) {
            var s = 0.55
            var why = ["water covers \(pct(water)) of the image"]
            if water >= 0.20 { s += 0.15 }
            if sand >= 0.06 && water >= 0.03 { s += 0.15; why.append("sand lies beside the water (\(pct(sand)))") }
            finish(.beachOrWaterfront, s, why)
        }

        // Park or garden: vegetation, little built structure, and a park cue.
        var parkCues: [String] = []
        if has("bench") { parkCues.append("a bench is visible") }
        if a(["flower"]) >= 0.01 { parkCues.append("flowers are visible") }
        if a(["grass"]) >= 0.10 { parkCues.append("open grass covers \(pct(a(["grass"])))") }
        if a(["dirt", "gravel"]) >= 0.02 { parkCues.append("a path of gravel or bare ground is visible") }
        if has("playingfield") { parkCues.append("a sports field is visible") }
        if setting == .outdoor, vegetation >= 0.12, share(vegetation) >= 0.30, builtEnv <= 0.25, !parkCues.isEmpty {
            finish(.parkOrGarden, 0.40 + 0.15 * Double(parkCues.count),
                   ["trees or grass fill \(pct(share(vegetation))) of the surroundings, built structures only \(pct(builtEnv))"] + parkCues,
                   cap: 0.85)
        }

        // Natural environment.
        let naturalGroups = [ElementGroup.vegetation, .water, .landform, .naturalGround].filter { g($0) >= 0.05 }.count
        if setting == .outdoor, naturalArea >= 0.20, share(naturalArea) >= 0.50, builtEnv <= 0.25 {
            finish(.naturalEnvironment, 0.55 + (naturalGroups >= 2 ? 0.10 : 0),
                   ["natural elements fill \(pct(share(naturalArea))) of the surroundings, built structures only \(pct(builtEnv))"])
        }

        // Urban street: paving is required. Bicycles, boats and a lone wall do not make a street.
        let streetVehicles = a(["car", "bus", "truck", "motorcycle"])
        let hasTraffic = streetVehicles >= 0.01 || fixtures >= 0.005
        let streetPaved = paved >= 0.04
        // Outdoors, plain walls are part of the built surroundings (courtyards, facades, fences).
        let outdoorStructures = exteriorArchitecture + walls
        let streetBuildings = share(outdoorStructures) >= 0.15
        if setting == .outdoor, streetPaved, share(outdoorStructures) >= 0.10 || hasTraffic {
            var why = ["roads or paving cover \(pct(paved))"]
            if streetBuildings { why.append("buildings and walls fill \(pct(share(outdoorStructures))) of the surroundings") }
            if hasTraffic { why.append("cars or street fixtures are present") }
            finish(.urbanStreet, 0.40 + 0.15 * Double(why.count), why)
        }

        // Architectural environment.
        let architectureArea = outdoorStructures + a(["stairs", "fence"])
        if setting == .outdoor, share(architectureArea) >= 0.30 {
            finish(.architecturalEnvironment, 0.50 + (share(architectureArea) >= 0.50 ? 0.10 : 0),
                   ["buildings, walls and structures fill \(pct(share(architectureArea))) of the surroundings"],
                   cap: 0.85)
        }

        // Café or restaurant: only primary when the classifier agrees.
        if setting == .indoor, (has("dining table") || has("table")), has("chair") {
            let service = g(.foodAndDrink) > 0
            var why = ["tables and chairs are visible" + (service ? " with food or tableware" : "")]
            why.append("this fits a café or restaurant, but nothing here separates it from a home dining area")
            finish(.cafeOrRestaurant, 0.30 + (service ? 0.05 : 0), why, hint: cafeHintBoost)
        }

        // Indoor interior.
        if setting == .indoor {
            finish(.indoorInterior, min(0.80, 0.40 + 0.05 * Double(indoorScore)), settingReasons, cap: 0.85)
        }

        // Studio or plain background: one plain region and nothing else of note.
        if let top = regions.first, ["wall", "curtain", "paper", "banner"].contains(top.family.key),
           share(top.areaFraction) >= 0.70,
           regions.dropFirst().allSatisfy({ share($0.areaFraction) <= 0.10 }),
           ceiling == 0, floor == 0, furniture == 0, sky == 0, vegetation == 0 {
            drafts.append(Draft(
                category: .studioOrPlainBackground, strength: 0.50,
                reasons: ["one plain \(top.family.displayName.lowercased()) fills \(pct(share(top.areaFraction))) of the surroundings and little else is visible",
                          "a plain wall and a studio backdrop look the same to the segmentation model"],
                corroborated: false))
        }

        // Mixed built and natural surroundings.
        if setting == .outdoor, builtEnv > 0.25, naturalEnv >= 0.25 {
            drafts.append(Draft(
                category: .mixedEnvironment, strength: 0.50,
                reasons: ["built structures (\(pct(builtEnv))) and natural elements (\(pct(naturalEnv))) both make up a large part of the surroundings"],
                corroborated: false))
        }

        // 3. Resolve.
        let order = SceneContextCategory.allCases
        func ordered(_ list: [Draft]) -> [Draft] {
            list.sorted {
                if $0.strength != $1.strength { return $0.strength > $1.strength }
                return (order.firstIndex(of: $0.category) ?? 0) < (order.firstIndex(of: $1.category) ?? 0)
            }
        }

        var eligible = drafts.filter { $0.strength >= primaryThreshold }
        let presentCategories = Set(eligible.map(\.category))
        eligible.removeAll { draft in
            childToParent.contains { child, parent in parent == draft.category && presentCategories.contains(child) }
        }
        if presentCategories.contains(.mixedEnvironment), !presentCategories.contains(.urbanStreet) {
            eligible.removeAll { $0.category == .architecturalEnvironment }
        }
        eligible = ordered(eligible)

        var primary: SceneContextCategory = .unknown
        var primaryStrength = 0.0
        var primaryReasons: [String] = []
        var corroborated = false
        var ambiguous = false
        var secondaryPool = drafts

        if let first = eligible.first {
            if eligible.count >= 2, first.category != .mixedEnvironment,
               eligible[1].category != .mixedEnvironment,
               first.strength - eligible[1].strength < ambiguityGap {
                ambiguous = true
                primary = .mixedEnvironment
                primaryStrength = eligible[1].strength
                primaryReasons = ["\(first.category.displayName) and \(eligible[1].category.displayName) are about equally supported, so a broader mixed environment is reported"]
                secondaryPool = [first, eligible[1]]
            } else {
                primary = first.category
                primaryStrength = first.strength
                primaryReasons = first.reasons
                corroborated = first.corroborated
                secondaryPool.removeAll { $0.category == first.category }
            }
        }

        let secondary = ordered(secondaryPool.filter { $0.strength >= secondaryThreshold && $0.category != primary })
            .prefix(2)
            .map { SceneCandidate(category: $0.category, strength: $0.strength, reasons: $0.reasons,
                                  corroboratedByClassifier: $0.corroborated) }

        // 4. Quality and explanation.
        var quality: EvidenceQuality = .none
        if primary != .unknown {
            if ambiguous { quality = .low }
            else if primaryStrength >= 0.80 && corroborated { quality = .high }
            else if primaryStrength >= 0.65 { quality = .moderate }
            else { quality = .low }
            if env < 0.30 { quality = quality.lowered() }
            if segmentation.unsupportedFraction > 0.25 { quality = quality.lowered() }
            if !setAside.isEmpty { quality = quality.lowered() }
        }

        var limitations = [method,
                           "The image classifier (FastViT, ImageNet labels) names objects, not places. It can only corroborate a category the segmentation already supports."]
        if env < 0.30 { limitations.append("Only \(pct(env)) of the frame shows the surroundings, so cues are sparse.") }
        if segmentation.unsupportedFraction > 0.25 { limitations.append("Many pixels have labels outside the supported set.") }
        if !setAside.isEmpty {
            limitations.append("Set aside as unreliable and not used: " + setAside.map(\.family.displayName).joined(separator: ", ")
                               + ". Their area is unknown, not an empty background.")
        }
        if classifier.value == nil, let problem = classifier.problem {
            limitations.append("The image classifier did not run (\(problem)); no corroboration was available.")
        }

        let finalHints = hints.map { SceneHint(label: $0.label, score: $0.score, supports: $0.supports, used: usedHints.contains($0.label)) }

        var evidence: [EvidenceReference] = cues.prefix(5).map {
            EvidenceReference(source: .detrSegmentation, origin: .derivedMeasurement, role: .supporting, label: $0.label,
                              value: "\(pct($0.areaFraction)) of the image, \(pct($0.environmentShare)) of the surroundings")
        }
        evidence += finalHints.map {
            EvidenceReference(source: .fastViT, origin: .rawModelOutput, role: $0.used ? .supporting : .contextual,
                              label: "Classifier label", value: "\($0.label) \(pct($0.score)), points toward \($0.supports.displayName)\($0.used ? "" : " (not used: no segmentation support)")")
        }
        evidence.append(EvidenceReference(
            source: nil, origin: .interpretation, role: .primary, label: "Setting",
            value: "\(setting.displayName): " + settingReasons.joined(separator: "; ")))
        evidence.append(EvidenceReference(
            source: nil, origin: .interpretation, role: .primary, label: "Scene category",
            value: primary == .unknown ? "Unknown"
                : String(format: "%@ (strength %.2f)", primary.displayName, primaryStrength)))

        if primary == .unknown {
            let secondaryText = secondary.isEmpty ? "" : " Weak hints: " + secondary.map(\.category.displayName).joined(separator: ", ") + "."
            return SceneContextResult(
                primary: .unknown, primaryStrength: 0, secondary: Array(secondary), setting: setting,
                settingReasons: settingReasons, character: character, builtShare: builtShare, observedCues: cues,
                classifierHints: finalHints, isAmbiguous: false,
                assessment: .insufficient(
                    "The visible surroundings do not point clearly to a kind of place, so no scene category is reported. Setting: \(setting.displayName.lowercased()).\(secondaryText)",
                    evidence: evidence, limitations: limitations))
        }

        var explanation = "\(primary.displayName): " + primaryReasons.prefix(3).joined(separator: "; ") + "."
        if !secondary.isEmpty && !ambiguous {
            explanation += " Also consistent with: " + secondary.map(\.category.displayName).joined(separator: ", ") + "."
        }
        if !corroborated && primary != .mixedEnvironment {
            explanation += " Only the segmentation supports this, so it is a moderate-at-best inference."
        }
        return SceneContextResult(
            primary: primary, primaryStrength: primaryStrength, secondary: Array(secondary), setting: setting,
            settingReasons: settingReasons, character: character, builtShare: builtShare, observedCues: cues,
            classifierHints: finalHints, isAmbiguous: ambiguous,
            assessment: Assessment(status: .determined, quality: quality, explanation: explanation,
                                   evidence: evidence, limitations: limitations))
    }
}
