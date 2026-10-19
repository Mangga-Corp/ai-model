import Foundation

// MARK: - Groups

/// Photography-relevant grouping of DETR classes. Extending the taxonomy means
/// adding a case here and entries in `SegmentationTaxonomy.groupTable`; nothing
/// else in the analysis needs to change.
nonisolated enum ElementGroup: String, Sendable, CaseIterable, Hashable {
    case person
    case sky
    case water
    case landform
    case vegetation
    case naturalGround
    case pavedSurface
    case architecture
    case wall
    case opening
    case interiorSurface
    case furniture
    case furnishing
    case foodAndDrink
    case vehicle
    case streetFixture
    case animal
    case carriedItem
    case other

    /// Part of the surroundings. People and the things they carry or wear
    /// (tie, bag, skis) belong to the subject, not to the environment.
    var isEnvironmental: Bool { self != .person && self != .carriedItem }

    /// Surface classes of these groups are analysed as ONE region ("Trees and
    /// grass") because splitting tree from grass fragments what a viewer sees as
    /// one mass. Object-like groups stay one region per class.
    var mergesSurfaceClasses: Bool {
        switch self {
        case .sky, .water, .landform, .vegetation, .naturalGround, .pavedSurface, .architecture, .opening, .wall:
            return true
        default:
            return false
        }
    }

    /// Man-made outdoor-or-indoor structure used for the built / natural balance.
    var isBuilt: Bool {
        switch self {
        case .architecture, .wall, .opening, .pavedSurface, .vehicle, .streetFixture: return true
        default: return false
        }
    }

    var isNatural: Bool {
        switch self {
        case .water, .landform, .vegetation, .naturalGround: return true
        default: return false
        }
    }
}

/// Whether the model labels a countable object class ("things") or a surface /
/// region class ("stuff"). Either way DETR is SEMANTIC: all pixels of one class
/// are one region, never separate instances.
nonisolated enum RegionKind: String, Sendable, Hashable {
    case surface
    case object
}

// MARK: - Families

/// One analysable unit of the segmentation.
///
/// Several DETR classes can share a unit. "wall (brick)" and "wall (other)" are
/// both `wall`, and for surface groups such as vegetation, tree, grass and
/// flower are merged into one unit ("Trees and grass"), because the finer split
/// is not meaningful for composition. `memberKeys` keeps the classes inside, and
/// each region lists the exact DETR labels it absorbed.
nonisolated struct SemanticFamily: Sendable, Hashable, Identifiable {
    let key: String
    let displayName: String
    let group: ElementGroup
    let kind: RegionKind
    /// Class-level family keys merged into this unit (just `key` for single classes).
    let memberKeys: [String]
    var id: String { key }
}

nonisolated enum SegmentationTaxonomy {

    /// "wall (brick)" -> "wall", "sky (other)" -> "sky". The model's placeholder
    /// entries ("--") and empty labels are unsupported and return nil.
    static func familyKey(forLabel raw: String) -> String? {
        var s = raw.lowercased()
        if let open = s.firstIndex(of: "(") { s = String(s[..<open]) }
        s = s.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.allSatisfy({ $0 == "-" }) { return nil }
        return s
    }

    /// The single-class unit for a label ("wall (brick)" -> wall).
    static func family(forLabel raw: String) -> SemanticFamily? {
        guard let key = familyKey(forLabel: raw) else { return nil }
        return SemanticFamily(
            key: key,
            displayName: displayNames[key] ?? (key.prefix(1).uppercased() + key.dropFirst()),
            group: groupTable[key] ?? .other,
            kind: ObjectLabel.isObject(key) ? .object : .surface,
            memberKeys: [key])
    }

    /// The analysis unit a label belongs to: its group for merging surface
    /// groups, otherwise its own class.
    static func unit(forLabel raw: String) -> SemanticFamily? {
        guard let single = family(forLabel: raw) else { return nil }
        guard single.kind == .surface, single.group.mergesSurfaceClasses, single.group != .wall, single.group != .sky else {
            return single
        }
        return SemanticFamily(key: single.group.rawValue, displayName: single.group.displayName,
                              group: single.group, kind: .surface, memberKeys: [single.key])
    }

    /// The DETR label table mapped to analysis units. Unsupported labels map to -1.
    struct Mapping {
        let families: [SemanticFamily]
        /// Per DETR class index: index into `families`, or -1.
        let familyOfClass: [Int]
        /// Index of the `person` unit, when the label table has one.
        let personFamily: Int?

        init(labels: [String]) {
            var byKey: [String: SemanticFamily] = [:]
            var members: [String: Set<String>] = [:]
            var perClass: [String?] = []
            for label in labels {
                guard let unit = SegmentationTaxonomy.unit(forLabel: label) else { perClass.append(nil); continue }
                perClass.append(unit.key)
                byKey[unit.key] = unit
                members[unit.key, default: []].formUnion(unit.memberKeys)
            }
            let units = byKey.values.map { unit in
                SemanticFamily(key: unit.key, displayName: unit.displayName, group: unit.group, kind: unit.kind,
                               memberKeys: (members[unit.key] ?? []).sorted())
            }.sorted { $0.key < $1.key }
            let index = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($1.key, $0) })
            families = units
            familyOfClass = perClass.map { $0.flatMap { index[$0] } ?? -1 }
            personFamily = index["person"]
        }
    }

    // MARK: Tables

    private static let displayNames: [String: String] = [
        "tv": "TV", "playingfield": "Sports field", "hair drier": "Hair dryer", "cell phone": "Phone",
        "potted plant": "Potted plant", "dining table": "Dining table", "fire hydrant": "Fire hydrant",
        "traffic light": "Traffic light", "stop sign": "Stop sign", "parking meter": "Parking meter",
    ]

    static let groupTable: [String: ElementGroup] = {
        var table: [String: ElementGroup] = [:]
        func add(_ group: ElementGroup, _ keys: [String]) { keys.forEach { table[$0] = group } }
        add(.person, ["person"])
        add(.sky, ["sky"])
        add(.water, ["sea", "river", "water"])
        add(.landform, ["mountain", "rock"])
        add(.vegetation, ["tree", "grass", "flower"])
        add(.naturalGround, ["sand", "snow", "dirt", "gravel", "playingfield"])
        add(.pavedSurface, ["road", "pavement", "railroad", "platform"])
        add(.architecture, ["building", "house", "roof", "bridge", "tent", "stairs", "fence"])
        add(.wall, ["wall"])
        add(.opening, ["door", "window"])
        add(.interiorSurface, ["ceiling", "floor"])
        add(.furniture, ["chair", "couch", "bed", "dining table", "table", "cabinet", "shelf", "counter"])
        add(.furnishing, ["rug", "pillow", "blanket", "curtain", "towel", "mirror", "light", "vase", "clock",
                          "book", "potted plant", "tv", "laptop", "mouse", "remote", "keyboard", "microwave",
                          "oven", "toaster", "sink", "refrigerator", "toilet", "teddy bear", "hair drier",
                          "toothbrush", "scissors", "cell phone"])
        add(.foodAndDrink, ["bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
                            "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
                            "food", "fruit"])
        add(.vehicle, ["bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat"])
        add(.streetFixture, ["traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "banner"])
        add(.animal, ["bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe"])
        add(.carriedItem, ["backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
                           "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard",
                           "tennis racket"])
        add(.other, ["cardboard", "net", "paper"])
        return table
    }()
}
