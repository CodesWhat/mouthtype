import Testing
@testable import MouthtypeCore

@Suite struct WhitespaceNormalizerTests {
    static let cases: [TextCase] = [
        TextCase("hello   world", "hello world"),
        TextCase("  hello world  ", "hello world"),
        TextCase("hello , world", "hello, world"),
        TextCase("hello ; world : yes", "hello; world: yes"),
        TextCase("really ? yes ! ok .", "really? yes! ok."),
        TextCase("see ( the notes ) now", "see (the notes) now"),
        TextCase("wait …", "wait…"),
        TextCase("a\tb", "a b"),
        TextCase("a\u{00A0}b", "a b"),
        TextCase("line one \nline two", "line one\nline two"),
        TextCase("line one\n   line two", "line one\nline two"),
        TextCase("para\n\nnext", "para\n\nnext"),
        TextCase("trailing\n", "trailing\n"),
        TextCase("a  \n  \n  b", "a\n\nb"),
        TextCase("Hi\r\nthere", "Hi\r\nthere"),
        TextCase("", ""),
        TextCase("   ", ""),
        TextCase("...", "..."),
        TextCase("12 : 30", "12: 30"),
        TextCase("open .gitignore now", "open .gitignore now"),
        TextCase("it is .5 more", "it is .5 more"),
        TextCase("smile :) ok", "smile :) ok"),
        TextCase("wink ;) ok", "wink ;) ok"),
        TextCase("你好  世界 ,好", "你好 世界,好"),
        TextCase("😀  party  😀", "😀 party 😀"),
        TextCase("e\u{301}  cole", "e\u{301} cole"),
    ]

    @Test(arguments: cases)
    func normalizes(_ c: TextCase) {
        #expect(WhitespaceNormalizer().apply(c.input) == c.expected)
    }

    @Test(arguments: cases)
    func isIdempotent(_ c: TextCase) {
        let once = WhitespaceNormalizer().apply(c.input)
        #expect(WhitespaceNormalizer().apply(once) == once)
    }
}
