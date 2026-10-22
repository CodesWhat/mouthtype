import Foundation

/// Per-stage switches. Every stage is on by default.
public struct TextPipelineOptions: Sendable, Equatable {
    public var fillers: Bool
    public var spokenCommands: Bool
    /// "slash research" becomes "/research". Runs only when the input's `codingTarget` is true, and before spoken
    /// commands so it sees "dash", "hyphen" and "underscore" as words.
    public var slashCommands: Bool
    /// "At two, actually three" becomes "at three". Runs after spoken commands, so it sees number words.
    public var selfCorrection: Bool
    /// Lists the speaker counts ("first, second", "one, two") become numbered lists. Runs right after spoken commands.
    public var countedLists: Bool
    public var notation: Bool
    public var numbers: Bool
    public var dictionary: Bool
    public var snippets: Bool
    public var blend: Bool
    public var whitespace: Bool
    /// Swearing is removed when the tone is Formal. Other tones leave it as spoken.
    public var profanity: Bool
    /// The tone pass. `.formal` changes nothing here (see `profanity` for what Formal does remove).
    public var style: StyleOptions

    public init(
        fillers: Bool = true,
        spokenCommands: Bool = true,
        slashCommands: Bool = true,
        selfCorrection: Bool = true,
        countedLists: Bool = true,
        notation: Bool = true,
        numbers: Bool = true,
        dictionary: Bool = true,
        snippets: Bool = true,
        blend: Bool = true,
        whitespace: Bool = true,
        profanity: Bool = true,
        style: StyleOptions = .formal
    ) {
        self.fillers = fillers
        self.spokenCommands = spokenCommands
        self.slashCommands = slashCommands
        self.selfCorrection = selfCorrection
        self.countedLists = countedLists
        self.notation = notation
        self.numbers = numbers
        self.dictionary = dictionary
        self.snippets = snippets
        self.blend = blend
        self.whitespace = whitespace
        self.profanity = profanity
        self.style = style
    }

    public static let all = TextPipelineOptions()
    public static let none = TextPipelineOptions(
        fillers: false, spokenCommands: false, slashCommands: false, selfCorrection: false, countedLists: false, notation: false,
        numbers: false, dictionary: false,
        snippets: false, blend: false, whitespace: false, profanity: false
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
    /// Phrases the profanity stage must not cut into, on top of the dictionary and snippets given here. For rules a
    /// caller holds back from this run (joined spellings waiting for the model, snippet triggers expanded later).
    public var protectedPhrases: [String]
    /// Words the profanity stage leaves alone and whose case a removal keeps, on top of the dictionary and snippets
    /// given here (written spellings and snippet text of rules this run does not apply).
    public var protectedWords: [String]
    /// True when the text is going into a terminal, code editor or agent app. Gates the slash command stage.
    public var codingTarget: Bool

    public init(
        text: String,
        dictionary: [DictionaryRule] = [],
        snippets: [Snippet] = [],
        context: InsertionContext? = nil,
        now: Date = Date(),
        clipboard: String? = nil,
        options: TextPipelineOptions = .all,
        protectedPhrases: [String] = [],
        protectedWords: [String] = [],
        codingTarget: Bool = false
    ) {
        self.text = text
        self.dictionary = dictionary
        self.snippets = snippets
        self.context = context
        self.now = now
        self.clipboard = clipboard
        self.options = options
        self.protectedPhrases = protectedPhrases
        self.protectedWords = protectedWords
        self.codingTarget = codingTarget
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
/// Stages run in this fixed order: fillers, slash commands (coding targets only), spoken commands, self-corrections, counted lists, notation, numbers, dictionary, snippets, profanity (Formal only), blend, style, whitespace.
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
        if options.slashCommands, input.codingTarget {
            let phrases =
                input.protectedPhrases
                + (options.dictionary ? input.dictionary.flatMap { [$0.heard, $0.written] } : [])
                + (options.snippets ? input.snippets.flatMap { [$0.trigger, $0.expansion] } : [])
            run(SlashCommands.stageName) { SlashCommands(protectedPhrases: phrases).apply($0) }
        }
        if options.spokenCommands {
            run(SpokenCommands.stageName) { SpokenCommands().apply($0) }
        }
        if options.selfCorrection {
            run(SelfCorrection.stageName) { SelfCorrection().apply($0) }
        }
        if options.countedLists {
            run(CountedLists.stageName) { CountedLists().apply($0) }
        }
        if options.notation {
            let phrases =
                (options.dictionary ? input.dictionary.flatMap { [$0.heard, $0.written] } : [])
                + (options.snippets ? input.snippets.flatMap { [$0.trigger, $0.expansion] } : [])
            let nearby = CleanupPrompt.nearbySpellings(CleanupContext(before: input.context?.before, after: input.context?.after))
            run(TechnicalNotation.stageName) { TechnicalNotation(protectedPhrases: phrases + nearby).apply($0) }
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
        if options.profanity, options.style == .formal {
            var protected = StyleStage.words(of: input.protectedWords)
            if options.dictionary { protected.formUnion(StyleStage.words(of: input.dictionary.map(\.written))) }
            if options.snippets { protected.formUnion(StyleStage.words(of: input.snippets.map(\.expansion))) }
            var phrases = input.protectedPhrases
            if options.dictionary { phrases += input.dictionary.flatMap { [$0.heard, $0.written] } }
            if options.snippets { phrases += input.snippets.flatMap { [$0.trigger, $0.expansion] } }
            let stage = ProfanityRemover(protectedWords: protected, protectedPhrases: phrases)
            run(ProfanityRemover.stageName) { stage.apply($0) }
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
