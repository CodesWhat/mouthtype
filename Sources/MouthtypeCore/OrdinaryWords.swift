import Foundation

/// Whether a heard form is everyday English. A saved spelling whose heard form is an ordinary word rewrites that
/// word everywhere it's said, and as a boost alias it pulls recognition toward the written name for that word.
/// The list is bundled and dependency-free, favouring common words so it doesn't nag about rare ones.
public enum OrdinaryWords {
    /// True when every word of `heard` is ordinary. Blank text is not ordinary.
    public static func isOrdinary(_ heard: String) -> Bool {
        let parts = heard.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty, parts.allSatisfy(isPlainWord) else { return false }
        return parts.map(normalise).allSatisfy(isOrdinaryWord)
    }

    /// Plain-language warning for a rule, or nil when the heard form is safe. Boost-only rules (heard equals
    /// written) and joined spellings like "mouth type" to "Mouthtype" don't replace a word on its own, so they pass.
    public static func warning(for rule: DictionaryRule) -> String? {
        warning(heard: rule.heard, written: rule.written)
    }

    public static func warning(heard: String, written: String) -> String? {
        let heard = heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty, isOrdinary(heard) else { return nil }
        let rule = DictionaryRule(heard: heard, written: written)
        guard !rule.allowsSpellingHints else { return nil }
        let noun = heard.contains(" ") ? "an everyday English phrase" : "an everyday English word"
        return "\u{2018}\(heard)\u{2019} is \(noun), so every \u{2018}\(heard)\u{2019} you say becomes \(written)."
    }

    /// True when the rule's heard form should not act as a boost alias.
    /// A starred rule keeps its alias: starring means the user insists on it.
    static func suppressesAlias(_ rule: DictionaryRule) -> Bool {
        !rule.starred && warning(for: rule) != nil
    }

    /// Only letters and apostrophes. Digits or symbols (S3, C++, win32, node.js) mark an identifier, never plain speech.
    private static func isPlainWord(_ raw: Substring) -> Bool {
        raw.unicodeScalars.allSatisfy(isWordScalar)
    }

    /// Letters and apostrophes. ASCII is decided by range; CharacterSet is only consulted for other scripts.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x27, 0x2019: return true
        case 0..<0x80: return false
        default: return CharacterSet.letters.contains(scalar)
        }
    }

    private static func normalise(_ raw: Substring) -> String {
        raw.lowercased().unicodeScalars
            .filter(isWordScalar)
            .map { $0 == "\u{2019}" ? "'" : Character($0) }
            .reduce(into: "") { $0.append($1) }
    }

    private static func isOrdinaryWord(_ word: String) -> Bool {
        words.contains(word)
    }

    private static let words: Set<String> = Set(list.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let list = """
        the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was were been being has had did does done am
        said says made makes got gets went goes gone came comes took takes taken saw seen knew known thought thinks told tells found finds gave given put puts set sets let lets kept keeps began begun begins left leaves felt feels brought brings held holds wrote written writes ran runs stood stands heard hears met meets paid pays sat sits spoke spoken speaks lost loses fell falls fall sent sends built builds spent spends cut cuts won wins win winning lose losing
        here where why while those much many more very still such each both few every own same another too off down through under again never always often sometimes already yet ever once between during before until since against without within along around among across behind beyond near far away upon toward towards inside outside above below
        yes yeah okay ok hello hi hey please thanks thank sorry maybe sure right left really actually probably definitely basically anyway though although however whether either neither nor rather quite almost enough less least next last later soon today tomorrow yesterday tonight morning afternoon evening night week month years days weeks months hour hours minute minutes second seconds moment
        man woman men women child children boy girl kid kids baby mother father mom dad brother sister son daughter wife husband friend friends family person place home house room door window floor wall table chair bed car cars road street city town country world state area part parts point number numbers group company business money job jobs school class student teacher book books paper word words name names thing things life lives hand hands head eye eyes face body heart mind water food fire air light dark sun moon star sky tree river sea land ground earth rain snow wind weather
        big small little large long short high low old young early late great best better worse worst bad nice happy sad angry hard easy simple clear free full empty open closed ready sure true false real different important possible able available whole certain special main major public private local national human strong weak fast slow quick hot cold warm cool red blue green black white yellow brown pink orange gold silver
        ask asks asked call calls called try tries tried need needs needed feel become becomes became leave seem seems seemed turn turns turned start starts started show shows showed shown hear play plays played move moves moved live lives lived believe bring happen happens happened write provide sit stand lose pay meet include includes continue continues learn learns change changes changed lead leads led understand watch follow follows stop stops stopped create creates created speak read reads allow allows add adds added spend grow grows grew open walk walks walked offer remember remembers love loves loved consider appear buy buys bought wait waits waited serve die dies died send expect build stay stays fall reach reaches remain suggest raise pass passes sell sells sold require report decide decides pull pulls
        run running going coming doing making taking getting having being looking working thinking saying seeing wanting using trying asking needing feeling leaving calling talking talk talks talked telling meeting playing eating eat eats ate drink drinks driving drive drives drove sleep sleeps sleeping slept cook cooks cooking clean cleans cleaned wash washes washed sing sings sang song songs dance dances danced jump jumps jumped catch catches caught throw throws threw hit hits kick kicks push pushes fix fixes fixed break breaks broke broken check checks checked test tests tested save saves saved share shares shared send sent
        can't won't don't doesn't didn't isn't aren't wasn't weren't haven't hasn't hadn't wouldn't couldn't shouldn't i'm i've i'll i'd you're you've you'll you'd he's she's it's we're we've we'll they're they've they'll that's there's what's who's let's
        should must might may shall cannot can't
        something anything nothing everything someone anyone everyone nobody somebody anybody everybody somewhere anywhere nowhere everywhere
        idea ideas question questions answer answers problem problems reason reasons result results story stories fact facts case cases issue issues program system systems government law power matter side kind kinds sort type types form forms level order rule rules lot lots bit piece pieces space story research information data game games team music movie film picture photo video voice sound sounds news email message messages phone phones computer computers screen page pages site website app apps file files folder text line lines list lists code
        one two three four five six seven eight nine ten eleven twelve twenty thirty forty fifty hundred thousand million first second third zero half double
        monday tuesday wednesday thursday friday saturday sunday january february march april may june july august september october november december
        will bill mark jack ray rob pat joy grace hope faith art rose lily violet daisy ivy amber summer autumn winter spring dawn eve gene frank chase drew grant miles hunter
        hover hovers cat cats dog dogs bird birds fish horse horses cow pig animal animals
        casino bank card cards price cost costs pay tax buy shop store market sale deal trade
        ahead along apart aside away downtown upstairs downstairs
        able accept account across act action activity add address agree air alone amount animal apply area arm arrive art attack attention available avoid bar base beautiful beat beyond bill bit blood board boat bottom box brain bring camera care carry catch cause center century chance character charge choice choose church color common community compare complete condition contain control copy correct couple court cover cross crowd culture current customer danger date deep degree develop difference difficult direction discuss doctor dollar draw dream dress drop dry due during edge effect effort end energy enjoy enter entire environment event exactly example exist experience explain express extra fact fair fear field fight figure fill final finally finger finish flow fly focus force forget forward front future garden general girl glass goal ground guess guy hair half hang hate health heavy help history hole hospital hotel idea image imagine interest involve island join kill kitchen knowledge language laugh lay lie lift limit listen literally machine mean measure member mention middle mile mouth movement nature nearly neck notice object office officer onto opportunity option outside paint pair park particular party past pattern perfect perhaps period pick plan plant plate pool popular position pressure pretty prevent process produce product project proper protect prove quality quiet race raise range rate reach record reduce refer region relate remove repeat represent respond rest return rich ride ring rise risk rock role roll round safe scene science season seat section seem sense serious service several shape sheet shoot shot shoulder sign similar single sir size skin slightly smile soft soldier somewhat sort source speed spirit sport spot spread square staff stage standard step stick stock stone store strange stuff subject success suddenly suffer summer supply support surface surprise sweet swim system tell term thin thus tie tired title tone tool top total touch track train travel trip trouble truck trust truth twice unit usually value various view visit wait wake war wear wide wish wonder worry wrong yard
        """
}
