import Foundation

/// Everything the rule tier learned about a draft. The cascade reads more of
/// this than the `Verdict` alone carries, because the interesting decision is
/// not "is this bad" but "do I know enough to stop here".
public struct RuleReport: Sendable {
    public var verdict: Verdict
    /// 0...1. High means the surface looks innocent but the shape does not,
    /// which is precisely when the context tier earns its cost.
    public var ambiguity: Double
    /// True when nothing in the text suggests a person is being addressed at all.
    public var trivial: Bool
    public var hits: [String]
    /// True when the text addresses someone: a second-person word, or an
    /// insult used as a vocative. The on-device model is only trusted to
    /// raise a score when this is set.
    public var addressed: Bool = false
}

/// Tier 0: patterns over the canonical form of a draft.
///
/// Every match is on whole words. The old matcher squashed the whole draft
/// into one string and looked for "kys" or "fyou" anywhere in it, which is how
/// "pinky swear" became a death threat and "proud of you" became "f you".
/// Nothing here reaches across a word boundary except runs of single letters
/// ("k y s"), which `Normalizer.joinSingles` has already glued.
public struct Tier0Rules: Analyzer {
    public let tier: Tier = .rules

    public init() {}

    public func analyze(_ text: String, context: [String]) async -> Verdict {
        evaluate(text, context: context).verdict
    }

    // MARK: Patterns

    private struct Rule: @unchecked Sendable {
        let name: String
        let score: Double
        let categories: [Category]
        let regex: NSRegularExpression
        /// Discard the match when the words just before it are the writer
        /// talking about themselves: "i could just die" is not "just die".
        let notAfterFirstPerson: Bool
    }

    private static let you = "(?:you|u|ya|yall|ye|thou|yu)"
    private static let youAre = "(?:youre|you are|u are|you r|u r|ur|your|ya are|yall are|you re|u re)"
    private static let yourself = "(?:yourself|urself|yaself|yoself|your self|ur self|yourselves|uself)"
    private static let target = "(?:you|u|ya|yall|yo|ur|your)"
    private static let me = "(?:i|im|ill|imma|ima|ia|i will|i am|i m|id|we|well|we will|were)"

    private static func rule(_ name: String, _ score: Double, _ cats: [Category],
                             _ pattern: String, notAfterFirstPerson: Bool = false) -> Rule {
        let p = pattern
            .replacingOccurrences(of: "{Y}", with: you)
            .replacingOccurrences(of: "{YR}", with: youAre)
            .replacingOccurrences(of: "{YS}", with: yourself)
            .replacingOccurrences(of: "{T}", with: target)
            .replacingOccurrences(of: "{ME}", with: me)
        // Canonical text is single-spaced and padded, so a space on each side
        // is a whole-word boundary.
        let re = try! NSRegularExpression(pattern: "(?<= )(?:\(p))(?= )")
        return Rule(name: name, score: score, categories: cats, regex: re,
                    notAfterFirstPerson: notAfterFirstPerson)
    }

    /// Telling someone to die, and wishing it on them.
    private static let lethal: [Rule] = [
        rule("kill yourself", 0.97, [.harassment, .threat],
             "(?:go |just |pls |please |plz |should |gonna |go and |)(?:kill|hang|shoot|off|neck|unalive|end|stab|drown|delete|rope) {YS}"),
        rule("kys", 0.97, [.harassment, .threat], "kys|kill ys|k y s"),
        rule("go die", 0.95, [.harassment, .threat],
             "(?:go|just|pls|please|plz|hope you|hope u|i hope you|i hope u|wish you would|why dont you|why dont u|you should|u should|you need to|u need to|you deserve to|u deserve to|you gotta|go and|you can go) (?:die|rot|drop dead|starve|choke|disappear forever)",
             notAfterFirstPerson: true),
        rule("just disappear", 0.74, [.harassment],
             "(?:why dont you|why dont u|why not|you should|u should|you need to|u need to|pls|please|go|can you|can u) (?:just |)(?:disappear|vanish|stop existing|leave this earth|leave the planet|go away forever)",
             notAfterFirstPerson: true),
        rule("die in a fire", 0.95, [.harassment, .threat],
             "die in a (?:fire|hole|ditch|car crash|gutter)|drop dead|go play in traffic|go jump (?:off|in front of|out of)|jump off (?:a|the) (?:bridge|cliff|building|roof)|(?:drink|eat|chug) bleach|slit (?:your|ur) (?:wrists|throat)",
             notAfterFirstPerson: true),
        rule("hope you die", 0.95, [.harassment, .threat],
             "(?:hope|wish|pray|praying) (?:that )?(?:you|u|ur|your|ya|youd|ud|you would|u would) (?:would |could |just |)(?:die|dies|get cancer|gets cancer|get aids|get hit|get raped|burn|rot|suffer|choke|starve|never wake up|drown|crash|get shot|get killed|get run over|kill|catch cancer|get stabbed)"),
        rule("nobody would miss you", 0.95, [.harassment],
             "(?:nobody|no one|noone|no body) (?:would|will|is gonna|is going to|gonna) (?:even |ever |really |honestly |)(?:care|miss|notice|cry|mourn|be sad)(?: about)?(?: you| u)?(?: if| when| once) (?:you|u|ur|youre) (?:die|died|dead|disappear|disappeared|were gone|was gone|left|kill|killed|gone)|(?:nobody|no one|noone) (?:would|will) (?:miss|mourn) (?:you|u)"),
        rule("happier if you were gone", 0.92, [.harassment],
             "(?:everyone|everybody|the world|we|people|life|this school|the group|this class) (?:would be|will be|d be|is|would honestly be|would literally be) (?:better|happier|so much better|way better|so much happier|better off)(?: off)? (?:if|when|once) (?:you|u) (?:were|was|are|is|werent|died|left|disappeared|were dead|didnt exist|were never born|killed|just died|just left|were gone|was gone)"),
        rule("better without you", 0.93, [.harassment],
             "(?:world|everyone|everybody|we|this world|the world|earth|society|your family|ur family) (?:would be|will be|is|d be|would be so much|would be way) (?:better|happier) (?:off )?without (?:you|u)"),
        rule("you should die", 0.96, [.harassment, .threat],
             "{Y} (?:should|shouldve|should have|deserve to|need to|gotta|ought to|better|might as well) (?:just |go )?(?:die|be dead|not exist|not be alive|never have been born|stop breathing|kill {YS}|end it|end {YS}|disappear forever)"),
        rule("should have been aborted", 0.93, [.harassment],
             "(?:should have|shouldve|should of|shoulda) (?:been )?aborted (?:you|u)|(?:you|u) (?:should have|shouldve|should of|shoulda) (?:been|gotten) aborted|(?:wish|wished) (?:you|u) (?:were|was|would be|had been) (?:dead|never born|aborted|gone)"),
        rule("do the world a favor", 0.94, [.harassment],
             "(?:do|doing) (?:us|everyone|everybody|the world|society|all of us) a (?:favor|favour) and (?:die|kill|leave|disappear|jump|end|off)"),
        rule("dont deserve to live", 0.94, [.harassment],
             "{Y} (?:dont|do not|dont even|do not even) deserve to (?:live|be alive|exist|breathe)|unalive {YS}|(?:go |just |you should |u should )commit (?:suicide|die|toaster bath|sewer slide|self delete)"),
    ]

    /// Threats of violence and veiled threats.
    private static let threats: [Rule] = [
        rule("i will hurt you", 0.92, [.threat],
             "{ME} (?:going to |gonna |gon |finna |about to |boutta |bout to |will |gna |)(?:fucking |literally |actually |)(?:kill|murder|stab|shoot|beat|punch|slap|choke|strangle|rape|hurt|smack|bash|break|knock out|jump|sock|stomp|drown|burn) {T}"),
        rule("beat you up", 0.9, [.threat],
             "(?:beat|kick|knock|slap|punch) (?:the (?:shit|crap|hell|fuck|living daylights|life) )?out of (?:you|u|ya|yall)|(?:beat|beating) (?:you|u|ya|yo|ur|your) (?:up|ass|butt|face)"),
        rule("violence", 0.95, [.threat],
             "shoot up (?:the|your|ur|this|our) (?:school|house|class|work)|bomb (?:the|your|ur|this) (?:school|house)|bring a gun to"),
        rule("i know where you live", 0.86, [.threat],
             "(?:watch|better watch) (?:your|ur) back|i know where (?:you|u) (?:live|go|sleep|work|stay|go to school)|i know (?:your|ur) address|sleep with one eye open|hunt (?:you|u) down|i will find (?:you|u)|ill find (?:you|u)|im gonna find (?:you|u)|something (?:might|could|will|is gonna|is going to) happen to (?:you|u|your|ur)"),
        rule("you're dead", 0.76, [.threat],
             "{YR} (?:so |)dead(?! (?:to|weight|serious|tired|wrong|on|last|meat|ass|set|center|end|ahead|right|inside|asleep))|(?:youll|you will|u will|ull|you gonna|u gonna|youre gonna|ur gonna|you are going to) (?:regret|pay for) (?:this|that|it|saying)|(?:coming|come) for (?:you|u)|messed with the wrong (?:person|guy|girl|one|kid)|you better hope|you better watch"),
        rule("sexual threat", 0.88, [.threat, .harassment],
             "{ME} (?:going to |gonna |will |wanna |want to |)rape {T}|(?:leak|post|send everyone|show everyone|share) (?:your|ur) (?:nudes|pics|photos|pictures)"),
        rule("veiled", 0.56, [.threat],
             "(?:it would be|itd be|would be) a shame if|accidents happen|(?:be|better be) careful what (?:you|u) (?:say|post|do)|i would be careful if i were (?:you|u)|id be careful if i were (?:you|u)"),
        rule("kill you", 0.6, [.threat],
             "(?:kill|murder|stab|shoot|strangle) (?:you|u|ya)(?! know)"),
        rule("destroy you", 0.5, [.threat],
             "{ME} (?:going to |gonna |will |)(?:destroy|end|ruin|wreck|bury|smoke|cook) (?:you|u)"),
    ]

    /// Abuse that needs no insult word.
    private static let harassment: [Rule] = [
        rule("go fuck yourself", 0.9, [.insult, .harassment],
             "go (?:fuck|fk|screw) {YS}|gfy|fuck (?:you|u|ya|yall) (?:and|bitch|loser|idiot|retard|cunt|asshole)"),
        rule("fuck you", 0.82, [.insult],
             "(?:fuck|fk|screw|f) (?:you|u|ya|yall|yo|off|your|ur|yourself|urself)(?! know)"),
        rule("go to hell", 0.78, [.insult],
             "(?:go|burn|rot|die) (?:to|in) hell"),
        rule("shut the fuck up", 0.72, [.insult],
             "stfu|shut (?:the fuck|the hell|tf|ur|your|yo|the fk) (?:up|mouth)|shut up (?:bitch|loser|idiot|retard|slut|whore|hoe|you|u|stupid|fatass|cunt)"),
        rule("crude", 0.72, [.insult],
             "suck my (?:dick|cock|balls|ass)|eat (?:shit|a dick|my ass|a bag of)|kiss my ass|piss off|bite me|get (?:the fuck|tf|the hell) out"),
        rule("i hate you", 0.78, [.harassment],
             "(?:i|we|everyone|everybody|literally everyone|all of us|the whole class|the whole school|they all|people|they) (?:really |honestly |literally |fucking |all |)(?:hate|hates|despise|despises|cant stand|cannot stand) {Y}"),
        rule("nobody likes you", 0.82, [.harassment, .exclusion],
             "(?:nobody|no one|noone|no body|not a single person|not one person) (?:here |even |actually |really |)(?:likes|loves|wants|cares about|cares abt|needs|wanted|liked|will ever love|will ever like|would ever date|would ever love|could ever love|will ever want|gives a (?:shit|fuck|damn|crap) about|is ever going to love|is gonna love|wants to be friends with|will ever date|would date|would want|would love) {Y}"),
        rule("nobody sits with you", 0.78, [.harassment, .exclusion],
             "(?:nobody|no one|noone|no body) (?:wants to |ever |even |will |would |actually |)(?:sits|sit|talks|talk|hangs out|hang out|plays|play|eats|eat|texts|text|calls|call|invites|invite|stands|stand|walks|walk|chooses|picks|pick) (?:with |to |around |next to |near |)(?:you|u|ya)"),
        rule("die alone", 0.8, [.harassment],
             "(?:you|u|ur|youre|youll|ull|ya)(?: are| re| r| will| ll|)(?: gonna| going to| gon| finna|) die (?:alone|lonely|a virgin|unloved|sad|young|soon|in a ditch)"),
        rule("you make me sick", 0.76, [.insult],
             "(?:your|ur|yo) (?:face|voice|body|existence|presence|laugh|smell|personality|whole existence|looks|breath|teeth) (?:makes|make|is making) me (?:sick|want to puke|wanna puke|want to throw up|wanna throw up|want to vomit|wanna vomit|cringe|nauseous|want to die|wanna die)|{Y} (?:make|makes) me (?:sick|want to puke|wanna puke|throw up|want to vomit|wanna vomit)"),
        rule("the reason", 0.72, [.harassment],
             "{YR} (?:the |)(?:reason|problem) (?:why |that |)(?:your|ur) (?:parents|mom|dad|family|mother|father) (?:got divorced|split|fight|left|hate|are|is|dont|never)|{YR} (?:the |)reason (?:why |that |)(?:everyone|nobody|no one|people|we all|the group) (?:left|leaves|hates|hate|is sad|cant stand|quit)"),
        rule("make your life hell", 0.85, [.threat, .harassment],
             "{ME} (?:going to |gonna |will |gon |about to |)(?:make|making) (?:your|ur) (?:life|year|days) (?:a living hell|hell|miserable|a nightmare|so hard|worse)|{ME} (?:going to |gonna |will |gon |)(?:make|making) (?:you|u) (?:regret|suffer|cry|pay|bleed)"),
        rule("you belong in a zoo", 0.8, [.harassment],
             "{Y} (?:belong|belongs|should be|need to be|ought to be) (?:in|at|on) (?:a |the |)(?:zoo|cage|dumpster|trash|garbage|landfill|sewer|gutter|mental hospital|asylum|psych ward|circus|kennel|barn|pigpen|grave|ground)"),
        rule("no wonder they left", 0.78, [.harassment],
             "no wonder (?:your|ur|yo) (?:dad|mom|mum|parents|father|mother|family|boyfriend|girlfriend|bf|gf|friends|ex|husband|wife) (?:left|leaves|hates|hate|cheated|dumped|abandoned|doesnt love|dont love|never loved|gave up|ran away)|no wonder (?:nobody|no one|noone) (?:likes|loves|wants|talks to|sits with|texts) (?:you|u)"),
        rule("nobody will date you", 0.8, [.harassment],
             "(?:nobody|no one|noone|no body|no guy|no girl|no man|no woman)(?: is| will| would| could)? ever (?:want to |wanna |going to |gonna |)(?:date|love|like|marry|kiss|be with|touch|want|choose|pick) {Y}"),
        rule("deserve to suffer", 0.82, [.harassment],
             "{Y} (?:deserve|deserves|deserved) (?:to suffer|to be hurt|to be alone|to be bullied|to be miserable|to rot|to be hated|everything bad|to be sad|to be in pain|to cry|nothing good|to be beaten|to get hurt)"),
        rule("imagine being this ugly", 0.68, [.insult, .sarcasm],
             "imagine (?:being|looking|having|acting) (?:this|that|so|as|such a|such an|a|an|like) (?:\\w+ )?(?:\(Lexicon.insultAdjectives.joined(separator: "|"))|\(Lexicon.insultNouns.joined(separator: "|")))"),
        rule("you're the worst", 0.5, [.insult],
             "{YR} (?:literally |honestly |actually |genuinely |)(?:the worst|the absolute worst|a nightmare)"),
        rule("you will never", 0.76, [.harassment],
             "{Y}(?: will| ll|ll| are going to| re going to| gonna| re gonna| are gonna)? never (?:amount|be loved|be anything|be good enough|be enough|find anyone|be happy|have friends|matter|be pretty|be wanted|make it|succeed|be liked|be like)"),
        rule("waste of space", 0.88, [.insult, .harassment],
             "(?:waste|wastes) of (?:space|air|oxygen|life|skin|sperm|a person|a human|breath|time and space)"),
        rule("you suck", 0.66, [.insult],
             "{Y} (?:suck|sucks|stink|stinks)(?! at)|{Y} (?:suck|sucks) at (?:life|everything|being)"),
        rule("you look like", 0.78, [.insult],
             "{Y} (?:look|looks|smell|smells|sound|sounds|act|acts|walk|talk|dress) like (?:a |an |the |)(?:fucking |)(?:pig|cow|whale|monkey|ape|dog|rat|troll|goblin|clown|freak|homeless|crackhead|tranny|hooker|prostitute|whore|slut|retard|potato|beached whale|hippo|bitch|zombie|corpse|skeleton|shit|trash|garbage|gorilla|horse|walrus|man|thumb|foot|toe|virgin|loser|pedo|pedophile|creep|rapist|terrorist|alien|gremlin|ogre|witch|hag)"),
        rule("go back to your country", 0.88, [.harassment],
             "go back to (?:your|ur|where) (?:own )?(?:country|you came from|people|homeland|hole|cave)"),
        rule("your parents", 0.82, [.harassment],
             "(?:your|ur|yo) (?:parents|mom|mum|mother|dad|father|family|mama) (?:must be|are|r|is|should be|were|was|have to be|gotta be) (?:so |)(?:ashamed|embarrassed|disappointed|disgusted)|(?:your|ur|yo) (?:parents|mom|mum|mother|dad|father|family) (?:hate|hates|regret|regrets|never wanted|didnt want|dont want|doesnt want|dont love|doesnt love|never loved|should have aborted|shouldve aborted) (?:you|u|having you)"),
        rule("you are nothing", 0.68, [.harassment],
             "{YR} (?:nothing|nothing to me|dead to me|a mistake|a burden|a waste|unwanted|unloved|replaceable|forgettable)|{Y} (?:mean|matter) nothing|{Y} (?:dont|do not|will never|never|dont even) matter"),
        rule("everyone laughs at you", 0.8, [.harassment],
             "(?:everyone|everybody|the whole (?:school|class|group|team|grade)|we all|all of us) (?:is |are |)(?:laughing|laughs|laughed|making fun|talking shit|talks shit) (?:at|of|about) (?:you|u)"),
        rule("no friends", 0.74, [.harassment, .exclusion],
             "{Y} (?:have|got|has) no (?:friends|life)|no wonder (?:you|u) (?:have|got) no (?:friends|life)|{Y} (?:will always be|are|r|re) (?:alone|a loner)"),
        rule("sexual harassment", 0.74, [.harassment],
             "(?:send|show) (?:me |)(?:your |ur |)(?:nudes|tits|boobs|dick pic|body pics)"),
        rule("ugly af", 0.78, [.insult],
             "(?:ugly|fat|dumb|stupid|gross|retarded|disgusting|nasty|annoying) (?:as fuck|af|asf|as hell)"),
        rule("get a life", 0.48, [.sarcasm],
             "get a life|touch grass|delete your account|cry about it|cope harder|skill issue|womp womp|nobody cares|no one cares"),
        rule("shut up", 0.38, [.insult],
             "shut up"),
    ]

    // MARK: Insult aim

    private static let insultSet = Set(Lexicon.insultNouns).union(Lexicon.insultAdjectives)
    private static let secondSet: Set<String> = ["you", "u", "ya", "yall", "youre", "ur", "thou",
                                                 "yourself", "urself", "ye", "yu", "youve", "youll"]
    private static let firstSet: Set<String> = ["i", "im", "me", "myself", "ive", "id", "ill", "my", "mine"]
    // "this" and "that" are deliberately absent: "this is a stupid idea"
    // is about an idea.
    private static let thirdSet: Set<String> = ["he", "she", "they", "him", "her", "them", "hes", "shes",
                                                "theyre", "his", "kid", "girl", "guy", "dude", "boy",
                                                "teacher", "bitch", "chick"]
    private static let familySet: Set<String> = ["mom", "mum", "mother", "dad", "father", "sister",
                                                 "brother", "parents", "family", "girlfriend", "boyfriend",
                                                 "gf", "bf", "wife", "husband", "mama", "momma", "sis", "bro"]
    /// Words that cannot be the noun in "your stupid ___".
    static let functionWords: Set<String> = [
        "and", "lol", "lmao", "lmfao", "af", "asf", "bro", "dude", "fr", "tbh", "ngl", "you", "u", "its",
        "it", "is", "was", "so", "too", "honestly", "but", "to", "like", "ok", "okay", "i", "im", "that",
        "thats", "when", "if", "because", "cuz", "bc", "haha", "omg", "smh", "for", "as", "at", "in",
        "on", "of", "or", "with", "then", "now", "already", "again", "lowkey", "highkey", "fax", "frfr",
        "lil", "though", "tho", "anyway", "seriously", "literally", "bruh", "man", "girl", "sis",
    ]
    /// Signs a mild jab is a joke shared rather than a jab thrown.
    static let warmMarkers: [String] = [" love it ", " love you ", " love u ", " i love ", " haha ", " hahaha ",
                                        " jk ", " just kidding ", " ily ", " bestie ", " lol i ", " right lol "]
    private static let bodySet: Set<String> = ["face", "body", "voice", "nose", "teeth", "skin", "smile",
                                               "laugh", "existence", "personality", "forehead", "head",
                                               "eyes", "hair", "breath", "legs", "arms", "fit", "outfit"]
    private static let negationSet: Set<String> = ["not", "never", "arent", "isnt", "aint", "no", "dont",
                                                   "wasnt", "werent", "nor", "hardly", "neither"]
    /// Words that can sit between a subject and the insult it carries.
    private static let fillerSet: Set<String> = [
        "are", "r", "re", "is", "be", "was", "were", "so", "such", "a", "an", "the", "one", "really",
        "literally", "actually", "just", "fucking", "fuckin", "freaking", "frickin", "damn", "absolute",
        "complete", "total", "little", "lil", "big", "massive", "being", "like", "kinda", "kind", "of",
        "very", "too", "most", "biggest", "always", "still", "ass", "piece", "bit", "straight",
        "genuinely", "honestly", "truly", "seriously", "deadass", "lowkey", "highkey", "af", "sound",
        "sounds", "look", "looks", "act", "acting", "seem", "seems", "smell", "smells", "nothing", "but",
        "what", "how", "as", "ever", "effing", "bloody", "useless", "worthless", "fat", "ugly",
        "stupid", "dumb", "pathetic", "disgusting", "lazy", "fake", "dirty", "filthy", "sorry",
        "sad", "sick", "gross", "pure", "utter", "certified", "bonafide", "low", "life", "lowlife",
        "u", "mega", "super", "gigantic", "huge", "giant", "brainless", "retarded", "annoying",
        "ugliest", "dumbest", "stupidest", "fattest", "worst", "dirtiest", "nastiest", "bitchass",
        "becoming", "turning", "into", "called", "named", "are", "now", "again", "officially", "also",
    ]
    private static let exclamativeSet: Set<String> = ["what", "such", "how", "ur", "absolute", "total"]

    private enum Aim { case second, family, third, first, vocative, none }

    /// Who an insult at position `i` lands on. Walks back over filler words to
    /// the nearest subject; a negation on the way means it lands on no one.
    private static func aim(of i: Int, in t: [String]) -> Aim {
        var j = i - 1
        var steps = 0
        while j >= 0 && steps < 7 {
            let w = t[j]
            if negationSet.contains(w) { return .none }
            if w == "your" || w == "ur" || w == "yo" {
                // "your stupid phone" is about the phone. "your stupid" with
                // nothing after, or "ur stupid", is "you're stupid".
                if w == "your", j == i - 1 || j == i - 2,
                   Lexicon.insultAdjectives.contains(t[i]),
                   let next = t[safe: i + 1],
                   !insultSet.contains(next), !Lexicon.profanityWords.contains(next),
                   !Tier0Rules.functionWords.contains(next) {
                    return .none
                }
                return .second
            }
            if secondSet.contains(w) { return .second }
            if bodySet.contains(w), let p = t[safe: j - 1], ["your", "ur", "yo"].contains(p) { return .family }
            if familySet.contains(w) {
                if let p = t[safe: j - 1], ["your", "ur", "yo"].contains(p) { return .family }
                return .third
            }
            if firstSet.contains(w) { return .first }
            if thirdSet.contains(w) { return .third }
            if exclamativeSet.contains(w) && (w == "what" || w == "such" || w == "how") {
                // "what a loser", "such an idiot": exclaimed at whoever is
                // being spoken to, unless the writer says otherwise.
                return .vocative
            }
            if !fillerSet.contains(w) && !insultSet.contains(w) && !Lexicon.profanityWords.contains(w) {
                break
            }
            j -= 1
            steps += 1
        }
        // Directly followed by "you": "idiot you are", "loser u".
        if let next = t[safe: i + 1], secondSet.contains(next) { return .second }
        // A person-noun closing the message is said to someone: "nice try
        // loser", "go cry to your mommy loser". Words that also name things
        // ("trash", "garbage", "joke") are left out, so "that movie was
        // garbage" stays about the movie.
        if i == t.count - 1, i >= 1, Lexicon.personInsults.contains(t[i]) { return .vocative }
        return .none
    }

    private struct InsultResult {
        var score = 0.0
        var categories = Set<Category>()
        var hits: [String] = []
        var addressed = false
    }

    private static func scoreInsults(_ n: Normalized) -> InsultResult {
        var r = InsultResult()
        let t = n.canonical
        guard !t.isEmpty else { return r }

        let hasFirst = t.contains(where: { firstSet.contains($0) })
        let hasSecond = t.contains(where: { secondSet.contains($0) || $0 == "your" })
        let hasThird = t.contains(where: { ["he", "she", "him", "her", "hes", "shes", "they", "them"].contains($0) })
        // A message made of nothing but insults and swearing is aimed at the
        // person reading it: "loser", "stfu loser", "stupid ass bitch".
        let fillerOK: Set<String> = ["ass", "af", "asf", "lol", "lmao", "bro", "dude", "stfu", "shut", "up",
                                     "you", "u", "a", "an", "such", "what", "fr", "ngl", "tbh", "omg",
                                     "ur", "so", "the", "go", "away", "lmfao", "haha", "ok", "okay",
                                     "just", "really", "fucking", "fuckin", "big", "little", "lil", "dumb"]
        let insultOnly = t.count <= 6 && t.allSatisfy {
            insultSet.contains($0) || Lexicon.profanityWords.contains($0) || fillerOK.contains($0)
                || Lexicon.slurWords.contains($0)
        }

        var strong: [String] = []
        var mild: [String] = []
        var third: [String] = []
        for (i, w) in t.enumerated() where insultSet.contains(w) {
            var a = aim(of: i, in: t)
            if a == .vocative {
                a = hasFirst && !hasSecond ? .first : (hasThird && !hasSecond ? .third : .second)
            }
            if a == .none && insultOnly && !hasFirst { a = .second }
            let isMild = Lexicon.mildInsults.contains(w)
            switch a {
            case .second, .family, .vocative:
                if isMild { mild.append(w) } else { strong.append(w) }
                if a == .family { r.hits.append("family:\(w)") }
            case .third:
                third.append(w)
            case .first, .none:
                r.hits.append("unaimed:\(w)")
            }
        }

        if !strong.isEmpty {
            let extra = Double(min(strong.count + mild.count - 1, 2)) * 0.06
            r.score = min(0.80 + extra, 0.92)
            r.categories.insert(.insult)
            r.addressed = true
            r.hits += strong.map { "insult:\($0)" } + mild.map { "insult-mild:\($0)" }
        } else if !mild.isEmpty {
            // A mild insult said straight at someone ("u brat", "bruh u such a
            // dummy") holds from Balanced up. Laughing it off ("you're so
            // weird lol i love it") keeps it under the line.
            let warm = Tier0Rules.warmMarkers.contains { n.text.contains($0) }
                || ["😂", "🤣", "😭", "❤", "🥰"].contains { n.plain.contains($0) }
            let base = warm ? 0.50 : 0.63
            r.score = min(base + Double(min(mild.count - 1, 2)) * 0.06, warm ? 0.6 : 0.72)
            r.categories.insert(.insult)
            r.addressed = true
            r.hits += mild.map { "insult-mild:\($0)" }
        }
        if !third.isEmpty {
            let strongThird = third.contains { !Lexicon.mildInsults.contains($0) }
            r.score = max(r.score, strongThird ? 0.64 : 0.40)
            r.categories.insert(.insult)
            r.hits += third.map { "third:\($0)" }
        }
        if r.score == 0, r.hits.contains(where: { $0.hasPrefix("unaimed:") }) {
            r.score = 0.15
        }
        if insultOnly && !hasFirst { r.addressed = true }
        return r
    }

    // MARK: Softeners

    /// Reporting or refusing cruelty is not committing it.
    private static let reporting: [NSRegularExpression] = [
        "(?:they|he|she|someone|somebody|people|kids|everyone|this kid|this girl|this guy|my \\w+) (?:called|call|calls|keep calling|kept calling|was calling|were calling|keeps calling) (?:me|us|him|her|them|my)",
        "(?:dont|do not|never|stop|shouldnt|should not|please dont|wouldnt|would never|we shouldnt|cant believe they|cant believe he|cant believe she|why would you|why did you) (?:call|calling|say|saying|tell|telling|use|using|write|writing|post|posting) (?:people|anyone|someone|others|him|her|them|kids|me|that|the word|words like|stuff like|things like|it)",
        "the (?:word|term|phrase|f word|n word|r word|slur)",
        "(?:isnt|is not|its not|not|never|aint) (?:ok|okay|cool|acceptable|alright|funny) to (?:say|call|tell|write)",
        "(?:i was|i got|got|been|was being|were) called",
        "(?:he|she|they|someone|somebody) (?:said|told me|texted|wrote|posted|messaged) (?:that )?(?:i|im|my)",
    ].map { try! NSRegularExpression(pattern: "(?<= )(?:\($0))(?= )") }

    /// Affection that turns an insult into a joke between friends. Never
    /// softens a threat, a slur, or a death wish.

    // Sarcasm and minimisation markers. Individually meaningless, jointly loud.
    private static let sarcasmMarkers = PhraseSet([
        "actually", "for once", "finally", "wow", "oh wow", "congrats",
        "congratulations", "sure jan", "okay then", "ok then", "cool story",
        "must be nice", "good luck with that", "how original", "groundbreaking",
        "riveting", "fascinating", "shocking", "who would have guessed",
        "what a surprise", "never would have guessed", "of course you",
        "typical", "classic", "as always", "every time",
    ])

    /// The shapes of cruelty that uses no flagged words: veiled threats,
    /// freeze-outs, in-jokes at someone's expense. Not enough to hold on, but
    /// enough to ask the context tier, which reads the conversation.
    private static let veiledMarkers = PhraseSet([
        "hate for", "would be a shame", "come up", "you know how these things go",
        "you know how it is", "you know what i mean", "you know what happens", "same energy",
        "everyone remember", "remember what happened", "already talked about", "the other chat",
        "keep it there", "without you", "not invited", "just saying", "no offense",
        "with all due respect", "interesting choice", "if i were you", "last time",
        "watch yourself", "we'll see", "careful", "as always", "of course", "your call",
        "while everyone", "in front of everyone", "everyone knows", "we all know",
        "not to be mean", "i'm just saying", "just being honest", "bless your heart",
        "good for you", "must be nice", "who invited", "we decided", "the rest of us",
    ])

    private static let evaluativeSet: Set<String> = [
        "try", "tried", "trying", "attempt", "effort", "finally", "manage",
        "managed", "actually", "surprisingly", "somehow",
    ]

    /// Backhanded phrases that are barbed on their own. The rest are only
    /// shape, and are left to the context tier.
    private static let pointedBackhanded = PhraseSet([
        "for someone like you", "good for you for trying", "brave of you", "bold of you",
        "bless your heart", "it's cute that you", "its cute that you", "cute that you think",
        "sweet that you think", "adorable that you think", "must be nice to not care",
        "that's certainly a choice", "thats certainly a choice", "for someone who just started",
        "for someone your size", "for someone your age", "i could never be that confident",
        "you're so brave for", "youre so brave for",
    ])

    // MARK: Evaluate

    public func evaluate(_ text: String, context: [String] = []) -> RuleReport {
        let started = DispatchTime.now()
        let n = Normalizer.normalize(text)

        guard !n.canonical.isEmpty else {
            return RuleReport(verdict: Verdict(confidence: 1, tier: .rules, latencyMs: elapsed(started)),
                              ambiguity: 0, trivial: true, hits: [])
        }

        // Scores split by kind, because a joke between friends can soften an
        // insult but never a threat.
        var hardScore = 0.0
        var softScore = 0.0
        var categories = Set<Category>()
        var hits: [String] = []
        var confidence = 0.45
        var addressed = false

        let t = n.canonical
        let second = t.contains(where: { Tier0Rules.secondSet.contains($0) || $0 == "your" })
        let first = t.contains(where: { Tier0Rules.firstSet.contains($0) })
        let quoting = Tier0Rules.reporting.contains {
            $0.firstMatch(in: n.text, range: NSRange(n.text.startIndex..., in: n.text)) != nil
        }

        // --- Distress runs first and on its own wire. -------------------------
        let selfHarm = Lexicon.selfHarm.matches(in: n)
        let softDistress = Lexicon.distress.matches(in: n)
        let distressPresent = !selfHarm.isEmpty || !softDistress.isEmpty
        // Distress only counts as the writer's own when they are talking about
        // themselves and not aiming anything at someone else.
        let selfDirected = distressPresent && first && !second

        // --- Pattern rules. ----------------------------------------------------
        // The glued form only differs when the text spells letters out; most
        // of the time there is one form to search, not two.
        let forms = n.joined == n.text ? [n.text] : [n.text, n.joined]
        func run(_ rules: [Rule], hard: Bool) {
            for r in rules {
                for form in forms {
                    let range = NSRange(form.startIndex..., in: form)
                    var matched = false
                    if r.notAfterFirstPerson {
                        for m in r.regex.matches(in: form, range: range)
                        where !Tier0Rules.firstPersonBefore(m.range, in: form) {
                            matched = true
                            break
                        }
                    } else {
                        matched = r.regex.firstMatch(in: form, range: range) != nil
                    }
                    guard matched else { continue }
                    if hard { hardScore = max(hardScore, r.score) } else { softScore = max(softScore, r.score) }
                    categories.formUnion(r.categories)
                    confidence = max(confidence, min(0.97, r.score))
                    hits.append("\(hard ? "rule" : "phrase"):\(r.name)")
                    addressed = true
                    break
                }
            }
        }
        // A bare command at the whole message: "die", "die loser".
        if t.count <= 3, ["die", "rot", "kys"].contains(t[0]) {
            hardScore = max(hardScore, 0.92)
            categories.formUnion([.harassment, .threat])
            hits.append("rule:bare command")
            addressed = true
        }
        run(Tier0Rules.lethal, hard: true)
        run(Tier0Rules.threats, hard: true)
        run(Tier0Rules.harassment, hard: false)

        // --- Slurs. -----------------------------------------------------------
        let joinedTokens = Set(n.joined.split(separator: " ").map(String.init))
        let slurs = Lexicon.slurWords.filter { t.contains($0) || joinedTokens.contains($0) }
        if !slurs.isEmpty {
            let soft = slurs.allSatisfy { Lexicon.softSlurs.contains($0) }
            let s: Double = soft ? (second ? 0.72 : 0.30) : (second ? 0.95 : 0.86)
            hardScore = max(hardScore, s)
            categories.insert(.slur)
            confidence = max(confidence, 0.9)
            hits.append(contentsOf: slurs.map { "slur:\($0)" })
            if second { addressed = true }
        }

        // --- Insults, by who they land on. -------------------------------------
        let insults = Tier0Rules.scoreInsults(n)
        if insults.score > 0 {
            softScore = max(softScore, insults.score)
            categories.formUnion(insults.categories)
            if insults.score >= 0.5 { confidence = max(confidence, 0.8) }
            hits.append(contentsOf: insults.hits)
        }
        addressed = addressed || insults.addressed

        // --- Language that is not allowed, whoever it is aimed at. ------------
        //
        // Shield runs on school and family machines, so swearing and explicit
        // language are blocked by word, not by aim. Explicit language and
        // strong swearing hold at every sensitivity; mild swearing ("damn",
        // "hell", "crap") holds from Balanced up. These scores are kept apart
        // from cruelty, so quoting or a "jk" can never talk them down.
        let content = Tier0Rules.contentScore(n, tokens: joinedTokens)
        if content.score > 0 {
            categories.insert(content.category)
            confidence = max(confidence, 0.95)
            hits.append(contentsOf: content.hits)
        }

        // --- Relational aggression. -------------------------------------------
        // "no one asked me to the dance" is sad, not cruel.
        let exclusion = Lexicon.exclusion.matches(in: n).filter { phrase in
            guard phrase.hasSuffix("asked") else { return true }
            return !n.text.contains(" asked me ") && !n.text.contains(" asked us ")
                && !n.text.contains(" asked him ") && !n.text.contains(" asked her ")
                && !n.text.contains(" asked them ") && !n.text.contains(" asked to ")
                && !n.text.contains(" asked for ") && !n.text.contains(" asked about ")
        }
        if !exclusion.isEmpty {
            let base = 0.55 + 0.08 * Double(min(exclusion.count - 1, 2))
            softScore = max(softScore, min(base + (second ? 0.07 : 0), 0.80))
            categories.insert(.exclusion)
            confidence = max(confidence, 0.6)
            hits.append(contentsOf: exclusion.map { "exclusion:\($0)" })
        }

        let backhanded = Tier0Rules.pointedBackhanded.matches(in: n)
        let backhandedShape = Lexicon.backhanded.matches(in: n)
        if !backhanded.isEmpty {
            softScore = max(softScore, min(0.48 + 0.08 * Double(min(backhanded.count - 1, 2)), 0.64))
            categories.insert(.backhanded)
            hits.append(contentsOf: backhanded.map { "backhanded:\($0)" })
        }

        let mockery = Lexicon.mockery.matches(in: n)
        if !mockery.isEmpty {
            softScore = max(softScore, min(0.36 + 0.08 * Double(min(mockery.count - 1, 3)), 0.6))
            categories.insert(.sarcasm)
            hits.append(contentsOf: mockery.map { "mockery:\($0)" })
        }

        // --- Pile-on: the same jab arriving from several directions. -----------
        if let pile = pileOnBoost(text: n, context: context) {
            softScore = max(softScore, pile)
            categories.insert(.pileOn)
            confidence = max(confidence, 0.70)
            hits.append("pile-on:context")
        }

        // --- Friendly teasing softens insults, never threats. ------------------
        //
        // Only a plain insult can be softened: anything a phrase rule caught
        // ("nobody will ever love you") is not teasing, and "love you" there
        // is part of the cruelty.
        let phraseHit = hits.contains { $0.hasPrefix("phrase:") || $0.hasPrefix("rule:") }
        if softScore >= 0.45, !phraseHit, Tier0Rules.isAffectionate(text: text, n: n) {
            softScore = max(softScore - 0.30, 0.3)
            hits.append("affectionate")
        }

        var score = max(hardScore, softScore)

        // --- Quoting and refusing pull the score back down. --------------------
        if quoting && score > 0 {
            score *= 0.4
            confidence = min(confidence, 0.5)
            hits.append("quoted")
        }
        // Not allowed is not allowed, quoted or not.
        score = max(score, content.score)

        // --- Ambiguity: the reason the context tier exists. --------------------
        var ambiguity = 0.0
        if score < 0.85 {
            let sarcasmCount = Tier0Rules.sarcasmMarkers.count(in: n)
            let evaluativeCount = t.filter { Tier0Rules.evaluativeSet.contains($0) }.count
            if second { ambiguity += 0.22 }
            if sarcasmCount > 0 { ambiguity += min(0.30, 0.16 * Double(sarcasmCount)) }
            if evaluativeCount > 0 { ambiguity += min(0.22, 0.12 * Double(evaluativeCount)) }
            if !backhanded.isEmpty || !backhandedShape.isEmpty { ambiguity += 0.30 }
            if !exclusion.isEmpty { ambiguity += 0.18 }
            if !mockery.isEmpty { ambiguity += 0.18 }
            let veiled = Tier0Rules.veiledMarkers.count(in: n)
            if veiled > 0 { ambiguity += min(0.40, 0.22 * Double(veiled)) }
            if !context.isEmpty { ambiguity += 0.08 }
            if context.count >= 2 { ambiguity += 0.06 }
            if n.plain.hasSuffix("...") || n.plain.contains(" lol") { ambiguity += 0.10 }
            ambiguity = min(ambiguity, 1.0)
        }

        // Trivial means the rules saw nothing at all. An insult word with no
        // clear target ("stop breathing my air, freak") is not trivial: it
        // still goes to the transformer.
        let trivial = score < 0.2 && hits.isEmpty && !second && ambiguity < 0.15 && t.count <= 40 && !addressed

        var verdict = Verdict(
            level: Tier0Rules.level(for: score),
            score: score,
            confidence: confidence,
            tier: .rules,
            latencyMs: elapsed(started),
            rationale: nil,
            categories: categories.sorted { $0.rawValue < $1.rawValue },
            distress: distressPresent ? .present : .none,
            selfDirected: selfDirected
        )

        // Someone describing their own pain is never held. This is enforced
        // again in the cascade and once more in HoldPolicy; three locks, on purpose.
        if selfDirected && categories.isDisjoint(with: [.threat, .slur, .explicit]) {
            verdict.score = min(verdict.score, 0.15)
            verdict.level = .clear
            verdict.confidence = 0.9
            hits.append("self-directed")
        }

        if !selfHarm.isEmpty { hits.append(contentsOf: selfHarm.prefix(2).map { "distress:\($0)" }) }
        else if !softDistress.isEmpty { hits.append(contentsOf: softDistress.prefix(2).map { "distress:\($0)" }) }

        var report = RuleReport(verdict: verdict, ambiguity: ambiguity, trivial: trivial, hits: hits)
        report.addressed = addressed || second
        return report
    }

    private static let affectionRegex = try! NSRegularExpression(
        pattern: "(?<= )(love you|love u|luv you|luv u|ily|ilysm|ly|jk|just kidding|jking|kidding|bestie|no hate|all love)(?= )")
    private static let affectionEmoji: [String] = ["❤", "😘", "🥰", "💕", "💖", "<3", "🫶", "😍", "🤍", "💜", "💙"]
    private static let loveNegators: Set<String> = ["no", "nobody", "noone", "one", "ever", "never", "not",
                                                    "would", "could", "will", "wont", "cant", "dont", "doesnt", "can", "nobodys"]

    /// "jk", "love you", a heart: the markers of teasing between friends.
    /// "love you" after a negation ("no one will ever love you") is not one.
    static func isAffectionate(text: String, n: Normalized) -> Bool {
        if affectionEmoji.contains(where: { text.contains($0) }) { return true }
        let s = n.text
        for m in affectionRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            let before = s[s.startIndex..<r.lowerBound].split(separator: " ").suffix(4).map(String.init)
            if before.contains(where: { loveNegators.contains($0) }) { continue }
            return true
        }
        return false
    }

    /// Swearing and explicit language, scored by tier. A word counts in any
    /// disguise the normaliser can see through: "sh*t", "fuuuck", "w t f".
    static func contentScore(_ n: Normalized, tokens joined: Set<String>) -> (score: Double, category: Category, hits: [String]) {
        let words = Set(n.canonical).union(joined)
        var explicit = words.filter { Lexicon.explicitSet.contains($0) }
        // "summa cum laude" is a graduation, not a sex act.
        if explicit.contains("cum"), words.contains("laude") { explicit.remove("cum") }
        let explicitPhrases = Lexicon.explicitPhraseSet.matches(in: n)
        if !explicit.isEmpty || !explicitPhrases.isEmpty {
            return (0.97, .explicit, (explicit.sorted() + explicitPhrases).prefix(3).map { "explicit:\($0)" })
        }
        let strong = words.filter { Lexicon.strongProfanitySet.contains($0) }
        if !strong.isEmpty {
            return (0.86, .profanity, strong.sorted().prefix(3).map { "profanity:\($0)" })
        }
        let mild = words.filter { Lexicon.mildProfanitySet.contains($0) }
        if !mild.isEmpty {
            return (0.66, .profanity, mild.sorted().prefix(3).map { "profanity-mild:\($0)" })
        }
        return (0, .profanity, [])
    }

    /// True when one of the three words before `range` is the writer.
    private static func firstPersonBefore(_ range: NSRange, in s: String) -> Bool {
        guard let r = Range(range, in: s) else { return false }
        let before = s[s.startIndex..<r.lowerBound].split(separator: " ").suffix(3)
        return before.contains { firstSet.contains(String($0)) || $0 == "we" || $0 == "could" }
    }

    /// Three people landing on the same line inside one short window reads very
    /// differently from one person saying it once.
    private func pileOnBoost(text: Normalized, context: [String]) -> Double? {
        guard context.count >= 2 else { return nil }
        let draftTokens = Set(text.tokens.filter { $0.count > 2 })
        guard !draftTokens.isEmpty else { return nil }

        var echoes = 0
        for msg in context.suffix(6) {
            let t = Set(Normalizer.normalize(msg).tokens.filter { $0.count > 2 })
            guard !t.isEmpty else { continue }
            let overlap = Double(draftTokens.intersection(t).count)
            let jaccard = overlap / Double(draftTokens.union(t).count)
            if jaccard >= 0.45 { echoes += 1 }
        }
        guard echoes >= 2 else { return nil }
        return min(0.58 + 0.10 * Double(echoes), 0.82)
    }

    static func level(for score: Double) -> Level {
        if score >= 0.70 { return .harmful }
        if score >= 0.35 { return .borderline }
        return .clear
    }

    private func elapsed(_ t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000.0
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
