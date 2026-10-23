import AppKit

public struct SavedCombinationState: Codable {
    public var id: String
    public var name: String
    public var savedAt: Date
    public var path1: String
    public var itemPath1: String?
    public var path2: String
    public var itemPath2: String?
    public var rot1: Double
    public var flipH1: Bool
    public var flipV1: Bool
    public var rot2: Double
    public var flipH2: Bool
    public var flipV2: Bool
    public var combiningMode: String
    public var mergeLeftPercent: Double
    public var mergeRightPercent: Double
    public var alphaGradientPercent: Double
    public var fgOffset1Percent: Double
    public var fgOffset2Percent: Double
    public var showBackground1: Bool
    public var showBackground2: Bool
    public var fg1OnTop: Bool
    public var fgPos1X: Double?
    public var fgPos1Y: Double?
    public var fgScale1: Double?
    public var fgRot1: Double?
    public var fgPos2X: Double?
    public var fgPos2Y: Double?
    public var fgScale2: Double?
    public var fgRot2: Double?

    public init(
        id: String = UUID().uuidString,
        name: String,
        savedAt: Date = Date(),
        path1: String,
        itemPath1: String? = nil,
        path2: String,
        itemPath2: String? = nil,
        rot1: Double = 0,
        flipH1: Bool = false,
        flipV1: Bool = false,
        rot2: Double = 0,
        flipH2: Bool = false,
        flipV2: Bool = false,
        combiningMode: String = "split",
        mergeLeftPercent: Double = 50,
        mergeRightPercent: Double = 50,
        alphaGradientPercent: Double = 20,
        fgOffset1Percent: Double = 50,
        fgOffset2Percent: Double = 50,
        showBackground1: Bool = true,
        showBackground2: Bool = true,
        fg1OnTop: Bool = true,
        fgPos1X: Double? = nil,
        fgPos1Y: Double? = nil,
        fgScale1: Double? = nil,
        fgRot1: Double? = nil,
        fgPos2X: Double? = nil,
        fgPos2Y: Double? = nil,
        fgScale2: Double? = nil,
        fgRot2: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.path1 = path1
        self.itemPath1 = itemPath1
        self.path2 = path2
        self.itemPath2 = itemPath2
        self.rot1 = rot1
        self.flipH1 = flipH1
        self.flipV1 = flipV1
        self.rot2 = rot2
        self.flipH2 = flipH2
        self.flipV2 = flipV2
        self.combiningMode = combiningMode
        self.mergeLeftPercent = mergeLeftPercent
        self.mergeRightPercent = mergeRightPercent
        self.alphaGradientPercent = alphaGradientPercent
        self.fgOffset1Percent = fgOffset1Percent
        self.fgOffset2Percent = fgOffset2Percent
        self.showBackground1 = showBackground1
        self.showBackground2 = showBackground2
        self.fg1OnTop = fg1OnTop
        self.fgPos1X = fgPos1X
        self.fgPos1Y = fgPos1Y
        self.fgScale1 = fgScale1
        self.fgRot1 = fgRot1
        self.fgPos2X = fgPos2X
        self.fgPos2Y = fgPos2Y
        self.fgScale2 = fgScale2
        self.fgRot2 = fgRot2
    }
}

public class CombinationStateManager {
    private static let key = "FastViewSavedCombinationStates"

    public static func getAllSavedStates() -> [SavedCombinationState] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedCombinationState].self, from: data)) ?? []
    }

    public static func saveState(_ state: SavedCombinationState) {
        var states = getAllSavedStates()
        if let idx = states.firstIndex(where: { $0.id == state.id || $0.name == state.name }) {
            states[idx] = state
        } else {
            states.append(state)
        }
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func deleteState(id: String) {
        var states = getAllSavedStates()
        states.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
