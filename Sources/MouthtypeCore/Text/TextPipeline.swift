import Foundation

/// Per-stage switches. Every stage is on by default.
public struct TextPipelineOptions: Sendable, Equatable {
    public var fillers: Bool
    public var spokenCommands: Bool
    /// Lists the speaker counts ("first, second", "one, two") become numbered lists. Runs right after spoken commands.
    public var countedLists: Bool
    public var numbers: Bool
    public var dictionary: Bool
    public var snippets: Bool
    public var blend: Bool
    public var whitespace: Bool
    /// The tone pass. `.formal` changes nothing.
    public var style: StyleOptions

    public init(
        fillers: Bool = true,
        spokenCommands: Bool = true,
        countedLists: Bool = true,
        numbers: Bool = true,
        dictionary: Bool = true,
        snippets: Bool = true,
        blend: Bool = true,
        whitespace: Bool = true,
        style: StyleOptions = .formal
    ) {
        self.fillers = fillers
        self.spokenCommands = spokenCommands
        self.countedLists = countedLists
        self.numbers = numbers
        self.dictionary = dictionary
        self.snippets = snippets
        self.blend = blend
        self.whitespace = whitespace
        self.style = style
    }

    public static let all = TextPipelineOptions()
    public static let none = TextPipelineOptions(
        fillers: false, spokenCommands: false, countedLists: false, numbers: false, dictionary: false,
        snippets: false, blend: false, whitespace: false
    )

    var anyEnabled: Bool { self != .none }
}

public struct TextPipelineInput: Sendable {
    public var text: String
    public var dictionary: [DictionaryRule]
    public var snippets: [Snippet]
    public var context: InsertionContext?
    public var now: Date
    public var clipboard: String?
    public var options: TextPipelineOptions

    public init(
        text: String,
        dictionary: [DictionaryRule] = [],
        snippets: [Snippet] = [],
        context: InsertionContext? = nil,
        now: Date = Date(),
        clipboard: String? = nil,
        options: TextPipelineOptions = .all
    ) {
        self.text = text
        self.dictionary = dictionary
        self.snippets = snippets
        self.context = context
        self.now = now
        self.clipboard = clipboard
        self.options = options
    }
}

public struct TextPipelineResult: Sendable, Equatable {
    public var text: String
    /// Every logged change, in the order the stages ran. Reuses the store's `EditOp`.
    public var edits: [EditOp]
    /// Wall time per stage in milliseconds, keyed by the stage name used in `EditOp.stage`
    /// (plus `whitespace`). Disabled stages are absent.
    public var stageMillis: [String: Double]
    /// Diagnostics that are not edits, e.g. a snippet used `{clipboard}` with nothing on the clipboard.
    public var notes: [String]

    public init(text: String, edits: [EditOp] = [], stageMillis: [String: Double] = [:], notes: [String] = []) {
        self.text = text
        self.edits = edits
        self.stageMillis = stageMillis
        self.notes = notes
    }
}

/// The deterministic cleanup pass: no model, a few milliseconds, every change logged.
///
/// Stages run in this fixed order: fillers, spoken commands, counted lists, numbers, dictionary, snippets, blend, style, whitespace.
/// Style edits are logged under the `blend` stage name, the store's vocabulary has no separate one.
/// Each is its own small type and takes the previous stage's output; the edit `position` is a Character offset
/// into the text as it entered that stage.
public struct TextPipeline: Sendable {
    public static let whitespaceStageName = "whitespace"
    public static let styleStageName = "style"

    private let numberFormatter: any NumberFormatting
    private let dateFormatter: SnippetExpander.DateFormatter

    public init(
        numberFormatter: any NumberFormatting = SpokenNumberFormatter(),
        dateFormatter: @escaping SnippetExpander.DateFormatter = SnippetExpander.defaultDateFormatter
    ) {
        self.numberFormatter = numberFormatter
        self.dateFormatter = dateFormatter
    }

    public func run(_ input: TextPipelineInput) -> TextPipelineResult {
        runTraced(input).result
    }

    /// One stage's input and output, for tests that replay the edit log.
    struct StageTrace: Equatable {
        var stage: String
        var input: String
        var output: String
        var edits: [EditOp]
    }

    func runTraced(_ input: TextPipelineInput) -> (result: TextPipelineResult, trace: [StageTrace]) {
        let options = input.options
        guard options.anyEnabled else { return (TextPipelineResult(text: input.text), []) }
        guard !input.text.allSatisfy(\.isWhitespace) else { return (TextPipelineResult(text: ""), []) }

        var text = input.text
        var edits: [EditOp] = []
        var millis: [String: Double] = [:]
        var notes: [String] = []
        var trace: [StageTrace] = []
        let clock = ContinuousClock()

        func run(_ name: String, _ body: (String) -> StageResult) {
            let start = clock.now
            let before = text
            let out = body(text)
            let d = clock.now - start
            // Counted lists log under the spoken command stage, so their time adds to it.
            millis[name, default: 0] += Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            text = out.text
            edits += out.edits
            notes += out.notes
            trace.append(StageTrace(stage: name, input: before, output: out.text, edits: out.edits))
        }

        if options.fillers {
            run(FillerRemover.stageName) { FillerRemover().apply($0) }
        }
        if options.spokenCommands {
            run(SpokenCommands.stageName) { SpokenCommands().apply($0) }
        }
        if options.countedLists {
            run(CountedLists.stageName) { CountedLists().apply($0) }
        }
        if options.numbers {
            let formatter = numberFormatter
            run("number format") { current in
                let chars = Array(current)
                return SpanRewriter.apply(formatter.spans(in: current), to: chars, stage: "number format")
            }
        }
        if options.dictionary, !input.dictionary.isEmpty {
            run(DictionaryReplacer.stageName) { DictionaryReplacer(rules: input.dictionary).apply($0) }
        }
        if options.snippets, !input.snippets.isEmpty {
            let expander = SnippetExpander(
                snippets: input.snippets, now: input.now, clipboard: input.clipboard, dateFormatter: dateFormatter
            )
            run(SnippetExpander.stageName) { expander.apply($0) }
        }
        if options.blend {
            var protected = Set<String>()
            if options.dictionary { protected.formUnion(BlendStage.firstWords(of: input.dictionary.map(\.written))) }
            if options.snippets { protected.formUnion(BlendStage.firstWords(of: input.snippets.map(\.expansion))) }
            let stage = BlendStage(context: input.context, protectedWords: protected)
            run(BlendStage.stageName) { stage.apply($0) }
        }
        if options.style != .formal {
            var protected = Set<String>()
            if options.dictionary { protected.formUnion(StyleStage.words(of: input.dictionary.map(\.written))) }
            if options.snippets { protected.formUnion(StyleStage.words(of: input.snippets.map(\.expansion))) }
            let stage = StyleStage(options: options.style, protectedWords: protected)
            run(Self.styleStageName) { stage.apply($0) }
        }
        if options.whitespace {
            run(Self.whitespaceStageName) { StageResult(text: WhitespaceNormalizer().apply($0)) }
        }

        let result = TextPipelineResult(text: text, edits: edits, stageMillis: millis, notes: notes)
        return (result, trace)
    }
}
