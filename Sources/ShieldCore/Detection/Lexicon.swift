import Foundation

/// The rule tier's vocabulary. Grouped by what the language *does*, not by
/// how rude it looks, because the two come apart constantly.
public enum Lexicon {

    // MARK: Second-person address

    /// Aiming matters more than vocabulary. "This is stupid" and "you are stupid"
    /// share a word and nothing else.
    public static let secondPerson = [
        "you", "u", "ur", "yours", "youre", "your", "ya", "yall", "yourself",
        "urself", "uve", "youve", "youll", "ud",
    ]

    public static let firstPerson = [
        "i", "im", "ive", "id", "ill", "me", "my", "myself", "mine",
    ]

    // MARK: Weighted phrase groups

    /// Telling someone to die or disappear. The highest-signal thing a
    /// keyword tier can catch, and it is worth catching alone.
    public static let lethalDirectives: [String] = [
        "kill yourself", "kill your self", "kys", "khs", "go kill yourself",
        "go die", "just die", "you should die", "hope you die", "wish you were dead",
        "hang yourself", "drink bleach", "slit your wrists", "end yourself",
        "end it all already", "do the world a favor", "nobody would miss you",
        "no one would miss you", "everyone would be better off without you",
        "everyone would be happier without you", "the world would be better without you",
        "off yourself", "neck yourself", "unalive yourself",
    ]

    public static let slurWords: [String] = [
        "retard", "retarded", "retards", "tard", "fag", "fags", "faggot", "faggots",
        "fagot", "dyke", "dykes", "tranny", "trannies", "nigger", "niggers", "nigga",
        "niggas", "chink", "chinks", "spic", "spics", "kike", "kikes", "wetback",
        "wetbacks", "gook", "gooks", "raghead", "towelhead", "mongoloid", "libtard",
        "beaner", "beaners", "paki", "pakis", "sandnigger", "zipperhead", "shemale",
        "spaz", "cripple",
    ]

    /// Slurs common enough in casual, in-group use that they are held only
    /// when pointed at someone.
    public static let softSlurs: Set<String> = ["nigga", "niggas", "spaz", "cripple"]

    /// Nouns that name a person as something lesser. Only scored when aimed.
    public static let insultNouns: [String] = [
        "idiot", "idiots", "moron", "morons", "imbecile", "retard", "loser", "losers",
        "bitch", "bitches", "slut", "sluts", "whore", "whores", "hoe", "hoes", "thot",
        "cunt", "twat", "prick", "dick", "dickhead", "asshole", "assholes", "arsehole",
        "bastard", "motherfucker", "fucker", "wanker", "douche", "douchebag", "jackass",
        "dumbass", "fatass", "dipshit", "shithead", "scumbag", "scum", "trash", "garbage",
        "pig", "cow", "whale", "freak", "creep", "weirdo", "failure", "parasite",
        "vermin", "subhuman", "clown", "joke", "nobody", "coward", "pussy", "incel",
        "bum", "maggot", "cockroach", "rat", "snake", "disgrace", "embarrassment",
        "disappointment", "mistake", "nerd", "dork", "dweeb", "virgin", "simp",
        "psycho", "lunatic", "degenerate", "pathetic", "worthless", "pos", "skank",
        "tramp", "slag", "neckbeard", "manlet", "troll", "goblin", "gremlin", "ogre",
        "hag", "witch", "brat", "crackhead", "junkie", "peasant", "leech", "waste",
        "plague", "cancer", "abomination", "monster", "animal", "ape", "monkey", "dog",
        "dummy", "dork", "dumbo", "doofus", "buffoon", "nitwit", "halfwit", "dimwit", "numbskull",
        "airhead", "bonehead", "knucklehead", "scrub", "noob", "npc", "sheep", "worm", "stain",
    ]

    /// Insult nouns that only ever name a person, never a thing.
    public static let personInsults: Set<String> = [
        "idiot", "moron", "imbecile", "retard", "loser", "bitch", "slut", "whore", "hoe", "thot",
        "cunt", "twat", "prick", "dickhead", "asshole", "bastard", "motherfucker", "fucker",
        "wanker", "douche", "douchebag", "jackass", "dumbass", "fatass", "dipshit", "shithead",
        "scumbag", "freak", "creep", "weirdo", "coward", "pussy", "incel", "maggot", "simp",
        "psycho", "skank", "tramp", "slag", "neckbeard", "manlet", "hag", "crackhead", "loser",
        "losers", "idiots", "morons", "bitches", "sluts", "whores", "hoes", "nerd", "dork",
    ]

    /// Adjectives that degrade a person when pointed at one.
    public static let insultAdjectives: [String] = [
        "stupid", "dumb", "ugly", "fat", "worthless", "pathetic", "disgusting",
        "repulsive", "revolting", "useless", "hideous", "gross", "annoying",
        "insufferable", "unlovable", "brainless", "braindead", "retarded", "ignorant",
        "talentless", "clueless", "trashy", "ratchet", "irrelevant", "unwanted",
        "obese", "fugly", "nasty", "smelly", "dense", "idiotic", "moronic", "lame",
        "cringe", "cringey", "weird", "creepy", "worthless", "unbearable", "toxic",
        "fake", "spineless", "gutless", "hopeless", "unwanted", "unlikeable",
        "unlikable", "boring", "slow", "ugly", "ghetto", "skanky", "slutty",
        "dumbass", "fatass", "dirty", "filthy", "vile", "despicable", "deformed",
        "dumbest", "stupidest", "ugliest", "fattest", "grossest", "weirdest", "lamest",
        "nastiest", "dirtiest", "creepiest",
    ]

    /// Insults mild enough that they mean little alone. They still count when
    /// they arrive with something stronger, or at Attentive.
    public static let mildInsults: Set<String> = [
        "lame", "cringe", "cringey", "weird", "boring", "slow", "nerd", "dork", "dweeb",
        "fake", "toxic", "dense", "annoying", "clueless", "ignorant", "virgin", "simp",
        "troll", "goblin", "gremlin", "brat", "dirty", "joke", "clown", "dog",
        "animal", "monster", "snake", "rat", "nobody", "mistake", "hopeless", "witch",
        "peasant", "psycho", "creepy", "gross", "nasty", "smelly", "irrelevant",
        "weirdest", "lamest", "dummy", "dumbo", "doofus", "scrub", "noob", "npc", "sheep",
    ]

    /// Direct degradation of a person.
    public static let degradingWords: [String] = [
        "worthless", "pathetic", "disgusting", "repulsive", "revolting",
        "useless", "subhuman", "vermin", "parasite", "leech", "freak",
        "hideous", "grotesque", "trash", "garbage", "scum", "filth",
        "waste", "loser", "failure", "nobody", "creep", "weirdo",
        "idiot", "moron", "imbecile", "stupid", "dumb", "brainless",
        "clown", "joke", "embarrassment", "disgrace", "cringe", "ugly",
        "fat", "gross", "annoying", "insufferable", "unlovable", "unwanted",
    ]

    /// Swearing that is blocked at every sensitivity. Acronyms count exactly
    /// like the words they stand for: "wtf" is the f-word.
    public static let strongProfanity: [String] = [
        "fuck", "fucks", "fucking", "fucked", "fucker", "fuckers", "fuckin", "fuckboy", "fuckface",
        "motherfucker", "motherfuckers", "motherfucking", "shit", "shits", "shitty", "shitting",
        "bullshit", "horseshit", "shithead", "shitface", "bitch", "bitches", "bitchy", "bitching",
        "bitchass", "asshole", "assholes", "arsehole", "cunt", "cunts", "twat", "prick", "dick",
        "dicks", "dickhead", "cock", "cocks", "cocksucker", "pussy", "pussies", "wanker", "bastard",
        "bastards", "slut", "sluts", "whore", "whores", "hoe", "hoes", "douche", "douchebag",
        "jackass", "dumbass", "fatass", "dipshit", "bollocks", "twats", "skank",
        // Acronyms, as the words they stand for.
        "wtf", "wtaf", "stfu", "gtfo", "ffs", "fml", "lmfao", "lmfaoo", "idgaf", "idfk",
        "omfg", "af", "asf", "tf", "mf", "mfer", "mfs", "gfy", "smd", "pos", "bs", "stfd", "dafuq",
        "fk", "fck",
    ]

    /// Mild swearing: allowed at Light, blocked at Balanced and Attentive.
    public static let mildProfanity: [String] = [
        "damn", "damned", "dammit", "damnit", "goddamn", "goddammit", "goddamnit", "hell", "crap",
        "crappy", "craps", "ass", "arse", "asses", "badass", "smartass", "kickass", "piss", "pissed",
        "pissy", "pissing", "wth", "lmao", "lmaoo", "lmaooo",
    ]

    /// Sexual and explicit language. Blocked at every sensitivity.
    public static let explicitWords: [String] = [
        "porn", "porno", "pornhub", "xvideos", "xxx", "nsfw", "onlyfans", "hentai", "milf", "nudes",
        "blowjob", "blowjobs", "handjob", "rimjob", "cum", "cumming", "cumshot", "dildo",
        "horny", "boobs", "boob", "tits", "titties", "titty", "orgasm", "masturbate", "masturbating",
        "masturbation", "fap", "fapping", "anal", "sext", "sexting", "boner", "deepthroat", "gangbang",
        "threesome", "clit", "sexy", "dtf", "smd", "cock", "pussy", "thot", "jizz", "stripper",
    ]

    /// Explicit phrases made of ordinary words.
    public static let explicitPhrases: [String] = [
        "have sex", "had sex", "having sex", "sex with", "send nudes", "send me nudes", "nude pics",
        "naked pics", "naked pictures", "jerk off", "jerking off", "jack off", "suck my", "eat me out",
        "sit on my face", "down to fuck", "blow me", "go down on", "bend over for",
        "show me your body", "take your clothes off", "sex tape", "ride me",
    ]

    /// Every swear word, for the rules that need to know whether a word is
    /// one at all.
    public static let profanityWords: [String] = strongProfanity + mildProfanity

    /// Language that threatens without naming a weapon.
    public static let threatPhrases: [String] = [
        "watch your back", "you're dead", "youre dead", "your dead", "you are dead",
        "i know where you live", "i know where you go", "i know your address",
        "you'll regret", "youll regret", "you will regret", "make you regret",
        "be careful what you", "i'd be careful if i were you", "id be careful if i were you",
        "something might happen", "accidents happen", "sleep with one eye open",
        "it would be a shame if", "hope nothing happens to", "you better hope",
        "i'm coming for you", "im coming for you", "find you", "hunt you down",
        "beat your ass", "beat you up", "messed with the wrong",
    ]

    /// Relational aggression: the cruelty that leaves no word behind.
    public static let exclusionPhrases: [String] = [
        "nobody asked", "no one asked", "nobody cares", "no one cares",
        "nobody likes you", "no one likes you", "nobody wants you",
        "no one wants you here", "nobody invited you", "no one invited you",
        "why are you even here", "why are you still here", "who invited",
        "we don't want you", "we dont want you", "you weren't invited",
        "you werent invited", "this isn't for you",
        "this isnt for you", "leave the chat", "leave the group", "leave the server",
        "nobody was talking to you", "no one was talking to you",
        "not your group", "you don't belong", "you dont belong",
        "everyone is talking about you", "everyones talking about you", "everyone but you",
        "nobody wants you here", "no one wants you here", "get out of the chat",
        "we don't like you", "we dont like you", "you have no friends", "you got no friends",
    ]

    /// Praise shaped like a knife.
    public static let backhandedPhrases: [String] = [
        "for someone like you", "for a girl", "for a guy", "for someone your",
        "brave of you", "bold of you", "good for you for trying",
        "at least you tried", "you tried your best", "no offense but",
        "not to be mean but", "i'm just being honest", "im just being honest",
        "just saying", "don't take this the wrong way", "dont take this the wrong way",
        "i mean this in the nicest way", "with all due respect",
        "i guess that's one way", "i guess thats one way",
        "that's certainly a choice", "thats certainly a choice",
        "bless your heart", "you do you i guess", "interesting choice",
        "it's cute that you", "its cute that you", "cute that you think",
        "sweet that you think", "adorable that you think",
        "if you like that sort of thing", "some people find that",
        "must be nice to not care", "i could never pull that off",
        "you're so confident", "youre so confident",
    ]

    /// Pile-on and mockery markers, which matter most alongside repetition.
    public static let mockeryPhrases: [String] = [
        "imagine being", "imagine thinking", "couldn't be me",
        "couldnt be me", "the audacity", "who does she think", "who does he think",
        "who do you think you are", "second hand embarrassment",
        "secondhand embarrassment", "cringe compilation", "touch grass",
        "l ratio", "cry about it", "cope harder", "cope and seethe",
        "seethe", "mald", "skill issue", "womp womp", "get a life",
        "delete your account",
        "we're all laughing", "were all laughing", "everyone is laughing at",
        "screenshotting this", "the whole school saw", "everyone saw what you",
    ]

    /// Softeners and quoting that flip meaning. Used to pull scores down.
    public static let negators: [String] = [
        "don't say", "dont say", "never say", "would never say", "wouldn't say",
        "wouldnt say", "stop saying", "shouldn't call", "shouldnt call",
        "don't call anyone", "dont call anyone", "is not okay to say",
        "isn't okay", "isnt okay", "please don't", "please dont",
        "that's not", "thats not", "they called me", "he called me",
        "she called me", "they said i was", "someone told me i was",
        "i was called", "was called a", "the word", "quote",
    ]

    /// Self-reference for the distress path. Kept separate on purpose.
    public static let selfHarmPhrases: [String] = [
        "kill myself", "killing myself", "end my life", "ending my life",
        "end it all", "take my own life", "want to die", "wanna die",
        "wish i was dead", "wish i were dead", "better off dead",
        "better off without me", "not want to be here anymore",
        "don't want to be here anymore", "dont want to be here anymore",
        "don't want to be alive", "dont want to be alive",
        "hurt myself", "hurting myself", "cut myself", "cutting myself",
        "self harm", "selfharm", "overdose", "od on my",
        "nobody would miss me", "no one would miss me", "nobody would care if i",
        "no one would care if i", "nobody would notice if i", "if i disappeared",
        "want to disappear", "wanna disappear",
        "no reason to keep going", "no point in going on", "can't go on",
        "cant go on", "can't do this anymore", "cant do this anymore",
        "give up on everything", "nobody would notice if i", "disappear forever",
        "goodbye everyone", "this is my last", "won't be around much longer",
        "wont be around much longer", "sui cide", "suicidal", "suicide",
        "kms", "unalive myself", "ending things tonight",
    ]

    /// Softer distress, enough to offer resources but not to name a crisis.
    public static let distressPhrases: [String] = [
        "i hate myself", "i hate my life", "i'm worthless", "im worthless",
        "i'm a burden", "im a burden", "like a burden", "a burden on everyone",
        "a burden to everyone", "burden on everyone", "everyone hates me", "nobody loves me",
        "nobody cares about me", "no one cares about me", "i'm so alone",
        "im so alone", "i can't take it anymore", "i cant take it anymore",
        "i'm done with everything", "im done with everything",
        "what's the point anymore", "whats the point anymore",
        "i'm drowning", "im drowning", "i'm falling apart", "im falling apart",
        "nothing matters anymore", "i feel empty", "i'm numb", "im numb",
    ]

    /// Apps where a keystroke tap has no business running.
    public static let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.loginwindow",
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.sinesignal.Bitwarden",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",
    ]
}

// MARK: - Prepared forms
//
// The rules tier runs on every keystroke, so the lists above are turned into
// sets and pre-squashed phrase sets exactly once, at first use.

public extension Lexicon {
    static let secondPersonSet = Set(secondPerson)
    static let firstPersonSet = Set(firstPerson)
    static let slurSet = Set(slurWords)
    static let degradingSet = Set(degradingWords)
    static let profanitySet = Set(profanityWords)
    static let strongProfanitySet = Set(strongProfanity)
    static let mildProfanitySet = Set(mildProfanity)
    static let explicitSet = Set(explicitWords)
    static let explicitPhraseSet = PhraseSet(explicitPhrases, evasive: true)

    /// Evasion handling costs an extra scan, so it is spent only where people
    /// actually bother to evade.
    static let lethal = PhraseSet(lethalDirectives, evasive: true)
    static let threats = PhraseSet(threatPhrases)
    static let aimedProfanity = PhraseSet(
        ["fuck you", "fuck off", "screw you", "f you", "fuk you"], evasive: true)
    static let exclusion = PhraseSet(exclusionPhrases)
    static let backhanded = PhraseSet(backhandedPhrases)
    static let mockery = PhraseSet(mockeryPhrases)
    static let negatorSet = PhraseSet(negators)
    static let selfHarm = PhraseSet(selfHarmPhrases, evasive: true)
    static let distress = PhraseSet(distressPhrases)
}
