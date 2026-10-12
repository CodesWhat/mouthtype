import Testing
@testable import MouthtypeCore

@Suite struct CleanerCatalogTests {
    @Test func unknownIDThrowsWithValidIDs() {
        do {
            _ = try CleanerCatalog.make(id: "nope")
            Issue.record("expected make(id:) to throw")
        } catch let error as CleanerCatalogError {
            #expect(error == .unknownCleaner(id: "nope", validIDs: CleanerCatalog.ids))
            let message = error.errorDescription ?? ""
            for id in CleanerCatalog.ids {
                #expect(message.contains(id))
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func everyListedIDConstructs() throws {
        #expect(!CleanerCatalog.ids.isEmpty)
        for entry in CleanerCatalog.entries {
            let cleaner = try CleanerCatalog.make(id: entry.id)
            #expect(cleaner.id == entry.id)
            #expect(cleaner.displayName == entry.displayName)
        }
    }

    @Test func idsAreUnique() {
        #expect(Set(CleanerCatalog.ids).count == CleanerCatalog.ids.count)
    }

    @Test func promptIncludesVocabularyAndApp() {
        let context = CleanupContext(vocabulary: ["Kubernetes", "Helm"], appName: "Slack")
        let prompt = CleanupPrompt.system(for: context)
        #expect(prompt.hasPrefix(CleanupPrompt.systemPrompt))
        #expect(prompt.contains("Kubernetes, Helm"))
        #expect(prompt.contains("Slack"))
        #expect(CleanupPrompt.system(for: CleanupContext()) == CleanupPrompt.systemPrompt)
    }

    @Test func sanitizeStripsEchoedTags() {
        #expect(CleanupPrompt.sanitize("<transcript>\nHello there.\n</transcript>\n") == "Hello there.")
    }
}
