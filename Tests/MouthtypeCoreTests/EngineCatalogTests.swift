import Testing
@testable import MouthtypeCore

@Suite struct EngineCatalogTests {
    @Test func unknownIDThrowsWithValidIDs() {
        do {
            _ = try EngineCatalog.make(id: "nope")
            Issue.record("expected make(id:) to throw")
        } catch let error as EngineCatalogError {
            #expect(error == .unknownEngine(id: "nope", validIDs: EngineCatalog.ids))
            let message = error.errorDescription ?? ""
            for id in EngineCatalog.ids {
                #expect(message.contains(id))
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func everyListedIDConstructs() throws {
        #expect(!EngineCatalog.ids.isEmpty)
        for entry in EngineCatalog.entries {
            let engine = try EngineCatalog.make(id: entry.id)
            #expect(engine.id == entry.id)
            #expect(engine.displayName == entry.displayName)
        }
    }

    @Test func idsAreUnique() {
        #expect(Set(EngineCatalog.ids).count == EngineCatalog.ids.count)
    }

    @Test func transcribeBeforePrepareThrows() async throws {
        let engine = try EngineCatalog.make(id: EngineCatalog.ids[0])
        await #expect(throws: EngineError.self) {
            _ = try await engine.transcribe(samples: [0, 0, 0])
        }
    }
}
