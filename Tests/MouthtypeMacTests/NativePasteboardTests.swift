import AppKit
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct NativePasteboardTests {
    private final class NoKeyboardEvents: PasteEventPosting {
        var posts = 0
        func postPaste(keyCode: CGKeyCode, targetPID: pid_t?) -> Bool { posts += 1; return true }
    }

    private func seed(_ board: NSPasteboard) throws {
        let rich = NSPasteboardItem()
        rich.setString("Clipboard formatting stays mine.", forType: .string)
        rich.setData(Data("{\\rtf1\\ansi\\b Clipboard formatting stays mine.\\b0}".utf8), forType: .rtf)
        rich.setData(Data("<b>Clipboard formatting stays mine.</b>".utf8), forType: .html)
        let second = NSPasteboardItem()
        second.setData(Data([0, 1, 255, 0, 42]), forType: .init("app.mouthtype.qa-bytes"))
        try #require(board.writeObjects([rich, second]))
    }

    @Test func richItemsSurviveARealPromiseReadAndScheduledRestoration() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try seed(board)
        let access = SystemPasteboard(board)
        let original = access.snapshot()
        let poster = NoKeyboardEvents()
        var scheduled: [@MainActor () -> Void] = []
        let session = PasteboardSession(pasteboard: access, poster: poster, schedule: { _, work in scheduled.append(work) })

        #expect(session.paste("First take", keyCode: 9, targetPID: nil))
        #expect(board.string(forType: .string) == "First take")
        #expect(session.readCount == 1)
        await Task.yield()
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        #expect(!session.isRestorePending)
        #expect(access.snapshot() == original)
        #expect(original.items.count == 2)
        let formats = Set(original.items[0].map(\.type))
        #expect(
            formats.isSuperset(of: [
                NSPasteboard.PasteboardType.string.rawValue,
                NSPasteboard.PasteboardType.rtf.rawValue, NSPasteboard.PasteboardType.html.rawValue,
            ]))
        #expect(poster.posts == 1)
    }

    @Test func aNewNativeCopyWinsOverPendingAndShutdownRestores() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try seed(board)
        let access = SystemPasteboard(board)
        var scheduled: [@MainActor () -> Void] = []
        let session = PasteboardSession(pasteboard: access, poster: NoKeyboardEvents(), schedule: { _, work in scheduled.append(work) })
        #expect(session.paste("Pending take", keyCode: 9, targetPID: nil))
        board.clearContents()
        try #require(board.setString("A newer copy", forType: .string))
        session.restoreForTermination()
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        #expect(board.string(forType: .string) == "A newer copy")
        #expect(!session.isRestorePending)
    }
}
