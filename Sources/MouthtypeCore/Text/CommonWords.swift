import Foundation

/// Everyday English words that are safe to lowercase at the start of a sentence: function words, auxiliaries,
/// common verbs, adverbs and nouns. Proper nouns, month and day names, and words that double as names ("will",
/// "mark", "grace", "bill") are deliberately absent, so a leading name keeps its capital.
enum CommonWords {
    static let set: Set<String> = Set(raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    private static let raw = """
        the a an this that these those my your his her its our their me him us them i you he she it we they who whom \
        whose which what where when why how and but or so if because although though while since unless until before \
        after as than then else also too very just only even still already again always never often sometimes maybe \
        perhaps probably actually basically really quite rather almost both either neither each every any some many \
        much more most less least few several all none one two three four five six seven eight nine ten first second \
        third last next other another such same different new old good great bad better best worse little big small \
        long short high low early late right wrong sure ok okay yes no not nope yeah yep hi hello hey oh ah well now \
        here there today tomorrow yesterday tonight soon later anyway however therefore instead meanwhile finally \
        otherwise besides thanks thank please sorry welcome congrats is are was were be been being am do does did done \
        doing have has had having can could shall should would might must need needs needed want wants wanted like \
        likes liked love loved hate think thinks thought know knows knew known see sees saw seen look looks looked \
        make makes made get gets got go goes going went gone come comes came take takes took give gives gave say says \
        said tell tells told ask asks asked call calls called try tries tried use uses used work works worked find \
        finds found feel feels felt keep keeps kept let lets put set run runs ran move moves moved start starts started \
        stop stops stopped turn turns turned open opens opened close closes closed read reads write writes wrote send \
        sends sent ship ships shipped build builds built check checks checked fix fixes fixed add adds added remove \
        removes removed change changes changed update updates updated create creates created show shows showed help \
        helps helped bring brings brought buy buys bought pay pays paid meet meets met talk talks talked wait waits \
        waited follow follows leave leaves left remember forget forgot learn learns plan plans planned book books \
        booked schedule scheduled share shares shared save saves saved test tests tested review reviews reviewed \
        thing things way ways time times day days week weeks month months year years people person man woman time work \
        life world place home house office team project problem question questions idea ideas point part number \
        number case issue issues list item items email message note notes file files page word words line lines \
        thing something anything everything nothing someone anyone everyone nobody somebody somewhere anywhere \
        everywhere nowhere for of to in on at by with from into onto over under about above below between through \
        during without within across against along around behind beside beyond near off out up down back away \
        together apart per via versus let's it's that's there's here's what's who's how's where's don't doesn't didn't \
        can't couldn't won't wouldn't shouldn't isn't aren't wasn't weren't haven't hasn't hadn't we're you're they're \
        he's she's we'll you'll they'll we've you've they've we'd you'd they'd clear restart reset install uninstall \
        deploy merge push pull commit delete copy paste click press type enter select choose pick drop grab pack \
        call email text print scan sign log login upload download install connect disconnect refresh reload rename \
        schedule cancel confirm approve submit finish complete continue resume pause skip repeat explain describe \
        consider remember mention suggest recommend expect hope wish wonder guess mean means meant happen happens \
        happened seem seems become becomes became begin begins began end ends ended walk drive visit watch listen \
        sit stand eat drink sleep wake cook clean wash pick cut fill hold carry throw catch lose win miss
        """
}
