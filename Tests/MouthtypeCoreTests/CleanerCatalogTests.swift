import Testing
@testable import MouthtypeCore

@Suite struct CleanerCatalogTests {
    @Test func cleanupStrengthDoesNotAuthorizeRephrasing() {
        let light = CleanupPrompt.system(for: CleanupContext(level: .light))
        let medium = CleanupPrompt.system(for: CleanupContext(level: .medium))
        #expect(light == medium)
        #expect(medium.contains("Do not paraphrase"))
    }

    @Test func emptyFieldContextDoesNotChangeThePrompt() {
        let empty = CleanupContext(before: "", after: " \t\n")
        #expect(CleanupPrompt.system(for: empty) == CleanupPrompt.systemPrompt)
        #expect(CleanupPrompt.reference(empty).isEmpty)
        #expect(CleanupPrompt.user("check the CPU", context: empty) == CleanupPrompt.user("check the CPU"))
    }

    @Test func nearbyTextStaysSeparateFromInstructionsAndDictation() {
        let context = CleanupContext(before: "Recipient: Mary\n")
        #expect(!CleanupPrompt.system(for: context).contains("Recipient: Mary"))
        let user = CleanupPrompt.user("send this to merry", context: context)
        #expect(user.contains("\"Mary\""))
        #expect(!user.contains("Recipient"))
        #expect(user.hasSuffix("<transcript>\nsend this to merry\n</transcript>"))
    }

    @Test func nearbyReferenceContainsOnlyPossibleSpellings() {
        let context = CleanupContext(before: "Recipient: Mary Jensen\nProject: Drydock\nLatest update:\nThe build is ready.\n", after: " Ask John.")
        let reference = CleanupPrompt.reference(context)
        for name in ["Mary", "Jensen", "Drydock", "John"] {
            #expect(reference.contains("\"\(name)\""))
        }
        for text in ["Recipient", "Project", "Latest", "The", "Ask", "build is ready", "before", "after"] {
            #expect(!reference.contains(text))
        }
        #expect(CleanupPrompt.reference(CleanupContext(before: "the build is ready")).isEmpty)
        #expect(CleanupPrompt.system(for: context).contains("optional spelling hints"))
    }

    @Test func nearbySpellingsAreBoundedDeduplicatedAndKeepUnicode() {
        let names = (0..<40).map { "Name\($0)" }.joined(separator: " ")
        let reference = CleanupPrompt.reference(CleanupContext(before: "Zoë Zoë Élodie \(names)", after: "Zoë"))
        #expect(reference.components(separatedBy: "Zoë").count == 2)
        #expect(reference.contains("Élodie"))
        #expect(reference.contains("Name21"))
        #expect(!reference.contains("Name22"))
        #expect(!CleanupPrompt.reference(CleanupContext(before: "May Mark Merry")).isEmpty)
    }
    @Test func smartCleanupUsesTheMeasuredQualityModel() {
        let model = CleanerCatalog.makeSmartCleanup()
        #expect(model.id == "gemma-4-e4b-it-4bit")
        #expect(!model.usesNativeControls)
        #expect(model.spec.downloadSizeMB >= 4000)
        #expect(CleanerCatalog.mlxSpec(id: "superwhisper-s1-mini") != nil)
    }
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
