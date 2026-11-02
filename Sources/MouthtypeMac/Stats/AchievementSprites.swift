import Foundation

/// The 12x12 face sprite of each trophy, in the mouth-icon style: black outline, flat fills, cream face. The grids are the
/// approved ones from the design mock, one character per pixel (`.` is clear).
enum AchievementSprites {
    static let size = 12

    static let palette: [Character: UInt32] = [
        "k": 0x1D1D1F, "r": 0xD6453D, "R": 0xA82E2A, "w": 0xFFFFFF, "o": 0xF19A4B, "y": 0xF2C94C, "g": 0xA6CD52, "G": 0x4A6A12,
        "b": 0x4C8BD6, "B": 0x2D5C9E, "s": 0x9A9CA3, "S": 0x5C5C61, "t": 0xF08A9B, "n": 0x8A5A32, "p": 0xF7C9C2, "c": 0xECE6D2,
    ]

    /// The face of a hidden trophy that is not earned yet.
    static let hiddenID = "?"

    /// Centres short rows, pads missing rows at the bottom, and always returns 12 rows of 12.
    static func normalized(_ rows: [String]) -> [String] {
        var out = rows.map { row -> String in
            guard row.count < size else { return row }
            let left = (size - row.count) / 2
            return String(repeating: ".", count: left) + row + String(repeating: ".", count: size - row.count - left)
        }
        while out.count < size { out.append(String(repeating: ".", count: size)) }
        return out
    }

    static func rows(for id: String) -> [String]? { grids[id] }

    private static let mouth = [
        "............", "...kkkkkk...", ".kkrrrrrrkk.", "krrrrrrrrrrk", "krkkkkkkkkrk", "kkwwwwwwwwkk", "kkkkkkkkkkkk", "krkkkkkkkkrk",
        "krrrrrrrrrrk", ".kkrrrrrrkk.", "...kkkkkk...",
    ]

    private static let manyApps: [String] = {
        var grid = Array(repeating: Array(repeating: Character("."), count: size), count: size)
        func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ fill: Character, _ dark: Character) {
            for y in y0...y1 {
                for x in x0...x1 {
                    let edge = x == x0 || x == x1 || y == y0 || y == y1
                    grid[y][x] = edge ? "k" : (y == y0 + 1 ? dark : fill)
                }
            }
        }
        box(0, 0, 6, 6, "b", "B")
        box(3, 3, 8, 8, "g", "G")
        box(6, 6, 11, 11, "o", "n")
        return grid.map { String($0) }
    }()

    private static let grids: [String: [String]] = {
        var raw: [String: [String]] = [:]
        var first = mouth
        first[0] = "y..........y"
        first.append("y..........y")
        raw["first_words"] = first
        raw["hands_free"] = [
            "", "..kkkkkk..", ".kSSSSSSk.", "kS......Sk", "kS......Sk", "kbbk..kbbk", "kbbk..kbbk", "kbbk..kbbk", "kkkk..kkkk", "......kkkk",
            "......kg..",
        ]
        raw["many_apps"] = manyApps
        raw["four_figures"] = [
            "........yyy.", ".........yy.", "kkkkkkkkkkkk", "kwwkwwkwwkwk", "kkkkkkkkkkkk", "kwwkwwkwwkwk", "kkkkkkkkkkkk", "kwwwwwwwwwwk",
            "kkkkkkkkkkkk",
        ]
        raw["five_figures"] = [
            "", ".kkkkkkkkkk.", "kwwwwkkwwwwk", "kwSSwkkwSSwk", "kwwwwkkwwwwk", "kwSSwkkwSSwk", "kwwwwkkwwwwk", "kwSSwkkwSSwk",
            "kwwwwkkwwwwk", ".kkkkkkkkkk.",
        ]
        raw["six_figures"] = [
            ".....yy.....", "....yyyy....", "..kkkkkkkk..", "..krrrrrrk..", "..kkkkkkkk..", ".kkkkkkkkkk.", ".kbbbbbbbbk.", ".kkkkkkkkkk.",
            "kkkkkkkkkkkk", "kggggggggggk", "kkkkkkkkkkkk",
        ]
        raw["hundred_takes"] = [
            "", "kkkkkkkkkkkk", "kwwkkwwkkwwk", "kkkkkkkkkkkk", "", "kkkkkkkkkkkk", "kSSSSSSSSSSk", "kSwwwwwwwwSk", "kSSSSSSSSSSk",
            "kkkkkkkkkkkk",
        ]
        raw["thousand_takes"] = [
            "", "", "kkkkkkkkkkkk", "kcccccccccck", "kckkkcckkkck", "kckwkcckwkck", "kckkkcckkkck", "kcccccccccck", "kcckkkkkkcck",
            "kkkkkkkkkkkk",
        ]
        raw["monologue"] = [
            "", "..kkkkkkkk..", ".kwwwwwwwwk.", "kwwwwwwwwwwk", "kwSSSSSSSSwk", "kwwwwwwwwwwk", "kwSSSSSSwwwk", "kwwwwwwwwwwk",
            ".kwwwwwwwwk.", "..kkkkkwwk..", "......kwk...", ".......k...",
        ]
        raw["three_row"] = ["", ".o...o...o..", "ooo.ooo.ooo.", "kkk.kkk.kkk.", "kyk.kyk.kyk.", "kkk.kkk.kkk.", "", "kkkkkkkkkkk."]
        raw["month"] = [
            ".....k", "....kok", "....kook", "...kooyok", "..kooyyook", "..kooyyyok", ".koooyyyook", ".koooyyyyok", ".kooyywyyok", ".kooyywwyok",
            "..koyyyyok", "...kkkkkk",
        ]
        raw["no_days_off"] = [
            "", "kkkkkkkkkkkk", "krrrrrrrrrrk", "kwwwwwwwwwwk", "kwgwgwgwgwwk", "kwwwwwwwwwwk", "kwgwgwgwwwwk", "kwwwwwwwwwwk",
            "kwwwwwwwwwwk", "kkkkkkkkkkkk",
        ]
        raw["century"] = [
            "y....y....y.", "yy..yyy..yy.", "yyyyyyyyyyyy", "kkkkkkkkkkkk", "....kook....", "...kooook...", "..koooyook..", "..koyyyyok..",
            "..koyywyok..", "..koyywyok..", "...kooyok...", "....kkkk....",
        ]
        raw["fast_talker"] = [
            "", "", "...kkkkkk...", ".kkwwwwwwkk.", "kwwgwwwwrwwk", "kwwwwwwkwwwk", "kgwwwwkkwwrk", "kwwwwkkkwwwk", "kkkkkkkkkkkk",
            "kSSSSSSSSSSk",
        ]
        raw["auctioneer"] = [
            "", ".kkkkkkk....", "knnnnnnnk...", "knnnnnnnkk..", "knnnnnnnknk.", ".kkkkkkkk.nk", ".........nk.", "........nk..", "kkkkkkkkkkkk",
            "knnnnnnnnnnk", "kkkkkkkkkkkk",
        ]
        raw["triple_speed"] = [
            "....kk....", "...kwwk...", "..kwwwwk..", "..kwbbwk..", "..kwbbwk..", "..kwwwwk..", ".krwwwwrk.", ".krkwwkrk.", "..kk.kk...",
            "...koyok...", "....kyk....", ".....k.....",
        ]
        raw["hour_back"] = [
            "", "...kkkkkk...", "..kwwwwwwk..", ".kwwwwkwwwk.", ".kwwwwkwwwk.", "kwwwwwkwwwwk", "kwwwkkkwwwwk", "kwwwwwwwwwwk",
            ".kwwwwwwwwk.", "..kwwwwwwk..", "...kkkkkk...",
        ]
        raw["workday_back"] = [
            "y....y....y.", "..y..y..y...", "", "....kkkk....", "..kkyyyykk..", ".kyyyyyyyyk.", ".kyyyyyyyyk.", "kyyyyyyyyyyk", "kkkkkkkkkkkk",
            "kbbbbbbbbbbk", "kkkkkkkkkkkk",
        ]
        raw["honest_baseline"] = [
            "....kkkk....", ".....kk.....", "...kkkkkk...", ".kkccccccckk", ".kccccrccck.", "kcccccrcccck", "kccccckrrcck", "kcccccccccck",
            ".kcccccccck.", "..kkccccckk.", "....kkkk....",
        ]
        raw["proper_noun"] = [
            "", "kkkkkkkkkkkk", "kwwwwwwwwwwk", "kwwwwkkwwwwk", "kwwwkwwkwwwk", "kwwkwwwwkwwk", "kwwkkkkkkwwk", "kwwkwwwwkwwk", "kwwkwwwwkwwk",
            "kwggggggggwk", "kkkkkkkkkkkk",
        ]
        raw["shortcut"] = [
            "......yyyy..", ".....yyy....", "....yyy.....", "...yyy......", "..yyyyyyy...", ".....yyy....", "....yyy.....", "...yy.......",
            "..yy........", "..y.........",
        ]
        raw["second_draft"] = [
            "........kk..", ".......kttk.", "......kttkk.", ".....kyykk..", "....kyyyk...", "...kyyyk....", "..kyyyk.....", ".kyyyk......",
            ".kpykk......", "kppk........", "kkk.........",
        ]
        raw["editor"] = [
            "..kk....kk..", "..ksk..ksk..", "...ksk.ksk..", "....ksksk...", ".....kSk....", "....ksksk...", "...ksk.ksk..", "..krk...krk.",
            ".krrk...krrk", ".krrk...krrk", "..kk.....kk.",
        ]
        raw["reworded"] = [
            ".......k....", ".......kk...", ".kbbbbbbbk..", ".......kk...", ".......k....", "............", "....k.......",
            "...kk.......", "..kbbbbbbbk.", "...kk.......", "....k.......",
        ]
        raw["tongue_out"] = [
            "", "...kkkkkk...", ".kkrrrrrrkk.", "krrrrrrrrrrk", "kkkkkkkkkkkk", "krrrrrrrrrrk", ".kkrrrrrrkk.", "..kkkttkkk..",
            "....kttttk..", "....kttttk..", ".....kttk...", "......kk....",
        ]
        raw["read_credits"] = [
            "..kkkkkkkk..", ".kccccyccck.", ".kcccyyycck.", ".kccccyccck.", ".kcckkkkcck.", ".kcckkkkcck.", ".kcckkkkcck.",
            ".kcccccccck.", "..kkkkkkkk..",
        ]
        raw["night_owl"] = [
            ".kk......kk.", ".knkkkkkknk.", "knnnnnnnnnnk", "knwwwnnwwwnk", "knwkwnnwkwnk", "knwwwnnwwwnk", "knnnnyynnnnk", "knppppppppnk",
            "knpnpnpnpnnk", ".knnnnnnnnk.", "..yk....ky..",
        ]
        raw["filibuster"] = [
            "....kSk.....", "....kSk.....", "kkkkkkkkkkkk", "knnnnnnnnnnk", "kknnnnnnnnkk", ".knnnnnnnnk.", ".knnwwwwnnk.", ".knnnnnnnnk.",
            ".knnnnnnnnk.", ".knnnnnnnnk.", "kkkkkkkkkkkk",
        ]
        raw["welcome_back"] = ["", "yy........yy", "yoy......yoy", ".yoy....yoy.", "..yoy..yoy..", "...yoyyoy...", "....yooy....", ".....yy....."]
        raw[hiddenID] = [
            "", "...ssssss...", "..ss....ss..", "..ss....ss..", "........ss..", ".......ss...", "......ss....", "......ss....", "", "......ss....",
            "......ss...",
        ]
        return raw.mapValues(normalized)
    }()
}
