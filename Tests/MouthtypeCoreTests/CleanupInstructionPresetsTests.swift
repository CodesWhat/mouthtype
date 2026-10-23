import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct CleanupInstructionPresetsTests {
    @Test func theShippedPresetsAreThese() {
        #expect(CleanupInstructionPresets.all.map(\.id) == ["slack", "keep-my-wording", "code-comments"])
        #expect(CleanupInstructionPresets.all.map(\.title) == ["Slack", "Keep my wording", "Code comments"])
    }

    @Test func everyPresetFitsTheCapAndSurvivesNormalizing() {
        for preset in CleanupInstructionPresets.all {
            #expect(!preset.text.isEmpty)
            #expect(preset.text.count <= CleanupInstructions.maxLength, "\(preset.id)")
            #expect(CleanupInstructions.normalize(preset.text) == preset.text, "\(preset.id) changes when normalized")
        }
    }

    @Test func idsAndTitlesAreUnique() {
        let all = CleanupInstructionPresets.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.title)).count == all.count)
    }

    /// The eval fixture carries the presets' exact text, so a reworded preset can't ship without a re-run.
    @Test func theEvalFixtureUsesTheShippedText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/instruction-preset-cases.json"))
        let cases = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for preset in CleanupInstructionPresets.all {
            let own = cases.filter { ($0["id"] as? String)?.hasPrefix(preset.id + "-") == true }
            #expect(own.count >= 10, "\(preset.id) has \(own.count) takes")
            #expect(own.allSatisfy { $0["instructions"] as? String == preset.text }, "\(preset.id)")
        }
    }
}
