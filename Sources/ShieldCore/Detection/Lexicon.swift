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
        "retard", "retarded", "tard", "fag", "faggot", "fagot", "dyke", "tranny",
        "nigger", "nigga", "chink", "spic", "kike", "wetback", "gook", "coon",
        "raghead", "towelhead", "gyp", "mongoloid", "libtard", "beaner",
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

    public static let profanityWords: [String] = [
        "fuck", "fucking", "fucker", "motherfucker", "shit", "shitty", "bullshit",
        "bitch", "bitches", "asshole", "arsehole", "dickhead", "cunt", "twat",
        "prick", "wanker", "bastard", "slut", "whore", "hoe", "douchebag",
        "jackass", "dumbass", "dipshit", "piss", "pissed",
    ]

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
        "you werent invited", "not part of this", "this isn't for you",
        "this isnt for you", "stay out of it", "go away", "leave the chat",
        "nobody was talking to you", "no one was talking to you",
        "literally nobody", "nobody:", "not your group", "you don't belong",
        "you dont belong", "everyone agrees", "we were all saying",
        "we all talked about it", "we all think", "everyone is talking about you",
        "everyones talking about you", "the whole group", "everyone but you",
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
        "lmao", "lmfao", "imagine being", "imagine thinking", "couldn't be me",
        "couldnt be me", "the audacity", "who does she think", "who does he think",
        "who do you think you are", "embarrassing", "second hand embarrassment",
        "secondhand embarrassment", "cringe compilation", "touch grass",
        "ratio", "l + ratio", "found the", "cry about it", "cope",
        "seethe", "mald", "skill issue", "womp womp", "get a life",
        "delete your account", "delete this", "log off", "nobody:",
        "this you?", "we're all laughing", "were all laughing",
        "everyone saw", "screenshotted", "screenshotting this",
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
        "com.apple.finder",
        "com.apple.ActivityMonitor",
        "com.apple.Console",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
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
