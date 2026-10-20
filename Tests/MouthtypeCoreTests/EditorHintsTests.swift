import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct EditorHintsTests {
    // MARK: Identifier splitting

    @Test func splitsCamelPascalSnakeAndKebab() {
        #expect(EditorHints.spokenWords("viewDidLoad") == ["view", "did", "load"])
        #expect(EditorHints.spokenWords("AppDelegate") == ["app", "delegate"])
        #expect(EditorHints.spokenWords("URLSession") == ["url", "session"])
        #expect(EditorHints.spokenWords("max_retry_count") == ["max", "retry", "count"])
        #expect(EditorHints.spokenWords("my-component-name") == ["my", "component", "name"])
        #expect(EditorHints.spokenWords("MAX_RETRY") == ["max", "retry"])
        #expect(EditorHints.spokenWords("base64Encode") == ["base64", "encode"])
    }

    @Test func findsLowercaseStartIdentifiersInCursorText() {
        let before = "let session = fetchUserProfile(id)\nviewDidLoad() { render_frame() }"
        let found = EditorHints.identifiers(before: before, after: " then applyTheme")
        #expect(found.contains("fetchUserProfile"))
        #expect(found.contains("viewDidLoad"))
        #expect(found.contains("render_frame"))
        #expect(found.contains("applyTheme"))
        #expect(!found.contains("session"))
        #expect(!found.contains("let"))
    }

    @Test func cursorIdentifiersComeNearestFirst() {
        let found = EditorHints.identifiers(before: "farAway(); midWay(); nearBy", after: "afterOne")
        #expect(found == ["nearBy", "midWay", "farAway", "afterOne"])
    }

    @Test func hyphenatedProseIsNotKebabCase() {
        let found = EditorHints.identifiers(before: "a well-known state-of-the-art thing, but user-profile-card works", after: nil)
        #expect(!found.contains("well-known"))
        #expect(!found.contains("state-of-the-art"))
    }

    @Test func compoundsGetSpokenAliases() throws {
        let term = try #require(EditorHints.term("FluidVocabularyRescorer"))
        #expect(term.text == "FluidVocabularyRescorer")
        #expect(term.aliases == ["fluid vocabulary rescorer"])
        let snake = try #require(EditorHints.term("render_frame_buffer"))
        #expect(snake.aliases == ["render frame buffer"])
    }

    // MARK: Everyday-word filter

    @Test func dropsShortAndEverydayWords() {
        for word in ["value", "item", "user", "data", "name", "the", "id", "map", "Value", "ITEM"] {
            #expect(EditorHints.term(word) == nil, "\(word) should be dropped")
        }
        #expect(EditorHints.term("abc") == nil)
        #expect(EditorHints.term("a_b") == nil)
        #expect(EditorHints.term("1234") == nil)
        #expect(EditorHints.term("Mouthtype") != nil)
    }

    @Test func compoundsOfEverydayWordsAreNotTerms() {
        for name in ["getUser", "setValue", "itemList", "isOpen", "get_user_list", "getUserItemList"] {
            #expect(EditorHints.term(name) == nil, "\(name) should be rejected")
        }
        #expect(EditorHints.term("getUserRescorer")?.aliases == ["get user rescorer"])
    }

    @Test func rejectsNonNameShapes() {
        #expect(EditorHints.term("has space") == nil)
        #expect(EditorHints.term("a.b.c.d") == nil)
        #expect(EditorHints.term(String(repeating: "a", count: 65)) == nil)
    }

    // MARK: Ranking and cap

    @Test func ranksCursorThenTitleThenFiles() {
        let terms = EditorHints.terms(cursor: ["cursorOne", "cursorTwo"], title: ["TitleZephyr", "projectQuill"], files: ["fileStemOne"])
        #expect(terms.map(\.text) == ["cursorOne", "cursorTwo", "TitleZephyr", "projectQuill", "fileStemOne"])
    }

    @Test func dedupesCaseInsensitivelyKeepingTheHigherRank() {
        let terms = EditorHints.terms(cursor: ["AppDelegate"], title: ["appdelegate", "Other_quill"], files: ["APPDELEGATE"])
        #expect(terms.map(\.text) == ["AppDelegate", "Other_quill"])
    }

    @Test func capsAtFortyAndLeavesRoomForTitleAndFiles() {
        let cursor = (0..<60).map { "cursorName\($0)Value" }
        let files = (0..<60).map { "fileStem\($0)Thing" }
        let terms = EditorHints.terms(cursor: cursor, title: ["TitleZephyr"], files: files)
        #expect(terms.count == EditorHints.maxTerms)
        #expect(terms.prefix(EditorHints.maxCursorTerms).allSatisfy { $0.text.hasPrefix("cursorName") })
        #expect(terms.contains { $0.text == "TitleZephyr" })
        #expect(terms.last?.text.hasPrefix("fileStem") == true)
    }

    @Test func shallowPathsRankFirst() {
        let names = EditorHints.nameCandidates(fromPaths: ["a/b/c/Deep.swift", "Top.swift", "a/Mid.swift"])
        #expect(names == ["Top", "Mid", "Deep"])
    }

    @Test func fileNameCandidatesDropTheExtension() {
        #expect(EditorHints.candidates(fromFileName: "AppDelegate.swift") == ["AppDelegate"])
        #expect(EditorHints.candidates(fromFileName: "Sources/App/user.service.spec.ts") == ["user", "service", "spec"])
        #expect(EditorHints.candidates(fromFileName: "Dockerfile") == ["Dockerfile"])
    }

    // MARK: Title parsing

    @Test func parsesVSCodeTitles() {
        #expect(EditorHints.parseTitle("DictationPipeline.swift - mouthtype - Visual Studio Code", style: .vscode)
            == .init(file: "DictationPipeline.swift", project: "mouthtype"))
        #expect(EditorHints.parseTitle("\u{25CF} index.ts \u{2014} my-app \u{2014} Visual Studio Code", style: .vscode)
            == .init(file: "index.ts", project: "my-app"))
        #expect(EditorHints.parseTitle("main.py - api (Workspace) - Visual Studio Code", style: .vscode)
            == .init(file: "main.py", project: "api"))
        #expect(EditorHints.parseTitle("[Extension Development Host] ext.ts - plugin - Visual Studio Code", style: .vscode)
            == .init(file: "ext.ts", project: "plugin"))
        #expect(EditorHints.parseTitle("README.md - Visual Studio Code", style: .vscode) == .init(file: "README.md"))
        #expect(EditorHints.parseTitle("mouthtype - Visual Studio Code", style: .vscode) == .init(project: "mouthtype"))
        #expect(EditorHints.parseTitle("Visual Studio Code", style: .vscode) == .init())
    }

    @Test func parsesCursorTitles() {
        #expect(EditorHints.parseTitle("route.tsx - storefront - Cursor", style: .vscode)
            == .init(file: "route.tsx", project: "storefront"))
        #expect(EditorHints.parseTitle("route.tsx \u{2014} storefront \u{2014} Cursor", style: .vscode)
            == .init(file: "route.tsx", project: "storefront"))
    }

    @Test func parsesXcodeTitles() {
        #expect(EditorHints.parseTitle("Mouthtype \u{2014} AppDelegate.swift", style: .xcode)
            == .init(file: "AppDelegate.swift", project: "Mouthtype"))
        #expect(EditorHints.parseTitle("Mouthtype \u{2014} AppDelegate.swift \u{2014} Edited", style: .xcode)
            == .init(file: "AppDelegate.swift", project: "Mouthtype"))
        #expect(EditorHints.parseTitle("Mouthtype \u{2014} Build Succeeded", style: .xcode) == .init(project: "Mouthtype"))
        #expect(EditorHints.parseTitle("Mouthtype", style: .xcode) == .init(project: "Mouthtype"))
        #expect(EditorHints.parseTitle("", style: .xcode) == .init())
    }

    // MARK: Deadline

    @Test func gatherReadsTheCursorUnderTheDeadlineAndOffTheCallersThread() async {
        let input = EditorHints.Input(
            windowTitle: "AppDelegate.swift - mouthtype - Visual Studio Code", titleStyle: .vscode,
            readCursor: { _ in
                InsertionContext(before: Thread.isMainThread ? "" : "applyTheme(", after: nil)
            }
        )
        let terms = await EditorHints.gather(input, deadline: .seconds(2))
        #expect(terms.map(\.text) == ["applyTheme", "AppDelegate", "mouthtype"])
    }

    @Test func gatherGivesUpOnAStuckCursorReadAtTheDeadline() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let input = EditorHints.Input(
            windowTitle: "AppDelegate.swift - mouthtype - Visual Studio Code", titleStyle: .vscode,
            readCursor: { _ in gate.wait(); return InsertionContext(before: "applyTheme(", after: nil) }
        )
        let clock = ContinuousClock()
        let start = clock.now
        let terms = await EditorHints.gather(input, deadline: .milliseconds(100))
        #expect(clock.now - start < .seconds(1))
        #expect(terms.map(\.text) == ["AppDelegate", "mouthtype"])
    }

    @Test func gatherUsesTitleAndCursorWhenFilesAreTooSlow() async {
        let input = EditorHints.Input(
            cursorBefore: "applyTheme()", windowTitle: "AppDelegate.swift - mouthtype - Visual Studio Code", titleStyle: .vscode,
            files: {
                try? await Task.sleep(for: .seconds(5))
                return ["Slow/NeverArrives.swift"]
            }
        )
        let clock = ContinuousClock()
        let start = clock.now
        let terms = await EditorHints.gather(input, deadline: .milliseconds(100))
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(1))
        #expect(terms.map(\.text) == ["applyTheme", "AppDelegate", "mouthtype"])
    }

    @Test func gatherAddsFilesThatAnswerInTime() async {
        let input = EditorHints.Input(
            cursorBefore: nil, windowTitle: "mouthtype - Visual Studio Code", titleStyle: .vscode,
            files: { ["Sources/Deep/FileNameStem.swift", "Top.swift"] }
        )
        let terms = await EditorHints.gather(input, deadline: .seconds(2))
        #expect(terms.map(\.text) == ["mouthtype", "FileNameStem"])
    }

    @Test func gatherWithNothingGivesNothing() async {
        #expect(await EditorHints.gather(.init()).isEmpty)
    }
}
