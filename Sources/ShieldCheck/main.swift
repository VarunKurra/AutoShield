import Foundation
import ShieldCore

// Shield's test suite and rehearsal harness.
//
// Run with Tools/check.sh. It exercises the detection core the way the app
// does — same normaliser, same rules, same hold policy — and fails loudly.
// The context tier is switched off here so the suite is offline, deterministic
// and free.

var failures = 0
var checks = 0
var group = ""

func section(_ name: String) {
    group = name
    print("\n\u{001B}[1m\(name)\u{001B}[0m")
}

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() {
        print("  \u{001B}[32m✓\u{001B}[0m \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  \u{001B}[31m✗\u{001B}[0m \(name)\(d.isEmpty ? "" : "  — \(d)")")
    }
}

let rules = Tier0Rules()
let tier1 = Tier1Classifier()

func score(_ s: String, _ ctx: [String] = []) -> Verdict {
    rules.evaluate(s, context: ctx).verdict
}

func holds(_ s: String, _ level: Sensitivity = .balanced, _ ctx: [String] = []) -> Bool {
    HoldPolicy.shouldHold(score(s, ctx), sensitivity: level)
}

// MARK: - Normalisation

section("Normalisation and evasion")

do {
    let n = Normalizer.normalize("K.Y.S")
    check("dotted letters collapse", n.squashed.contains("kys"), n.squashed)
    check("and the rules tier sees them", holds("k.y.s"))

    let leet = Normalizer.normalize("y0u ar3 p4th3t1c")
    check("leetspeak resolves", leet.plain.contains("you are pathetic"), leet.plain)

    let stretched = Normalizer.normalize("you are such a loooooser")
    check("stretched letters collapse", stretched.hasWord("loser"), stretched.deStretched)
    check("but ordinary doubles are left alone",
          !Normalizer.normalize("please pass the class").hasWord("ass"))

    let spaced = Normalizer.normalize("k y s")
    check("spaced letters collapse", spaced.squashed.contains("kys"), spaced.squashed)

    let cyrillic = Normalizer.normalize("y\u{043E}u are tr\u{0430}sh")
    check("cyrillic lookalikes fold", cyrillic.plain.contains("you are trash"), cyrillic.plain)

    let zw = Normalizer.normalize("k\u{200B}y\u{200B}s")
    check("zero-width characters are stripped", zw.contains("kys"), zw.squashed)

    let digits = Normalizer.normalize("i have 4 tickets for room 101")
    check("standalone digits survive", digits.plain.contains("4 tickets"), digits.plain)

    let n2 = Normalizer.normalize("please pass the class")
    check("word matching does not fire inside other words", !n2.hasWord("ass"), n2.plain)
}

// MARK: - Tier 0

section("Rules tier")

check("explicit insult is held", holds("you are a worthless pathetic loser"))
check("lethal directive is held", holds("kys"))
check("evaded lethal directive is held", holds("k.y.s you p4th3t1c l0oooser"))
check("slur is held", holds("shut up you retard"))
check("veiled threat is held", holds("i know where you live, be careful"))
check("aimed profanity is held", holds("fuck you"))

check("ordinary chat passes", !holds("hey are we still on for saturday"))
check("blunt disagreement passes", !holds("i really don't agree with this at all, the second half is the only part that works"))
check("venting passes", !holds("today was such a mess and i am so done with this week"))
check("criticism of a thing passes", !holds("this design is stupid and unreadable"))
check("quoting cruelty passes", !holds("they called me a loser in front of everyone"))
check("refusing cruelty passes", !holds("you should never say that to a person"))

do {
    let r = rules.evaluate("wow congrats, you actually finished something for once")
    check("implicit sarcasm raises ambiguity rather than score",
          r.ambiguity >= 0.42, String(format: "ambiguity %.2f", r.ambiguity))
    check("implicit sarcasm is not decisive at tier 0",
          r.verdict.score < 0.85, String(format: "score %.2f", r.verdict.score))
}

do {
    let ctx = ["dev: nobody asked", "sam: nobody asked", "jordan: nobody asked lol"]
    let solo = score("nobody asked")
    let pile = score("nobody asked", ctx)
    check("a pile-on scores above the same line said once",
          pile.score > solo.score, String(format: "%.2f vs %.2f", pile.score, solo.score))
    check("a pile-on is named as one", pile.categories.contains(.pileOn))
}

// MARK: - The invariant that matters most

section("Send Shield never holds someone's own pain")

let selfDirected = [
    "i hate myself so much right now, i'm worthless and i want to die",
    "i don't know, i've been feeling like everyone would be better off without me lately",
    "i want to kill myself",
    "i'm such a worthless piece of garbage and i can't do this anymore",
    "nobody would miss me if i disappeared",
    "i feel like a burden on everyone and i'm so tired",
    "i've been hurting myself again",
]

for text in selfDirected {
    let v = score(text)
    for level in Sensitivity.allCases {
        check("never held at \(level.title): \"\(text.prefix(36))…\"",
              !HoldPolicy.shouldHold(v, sensitivity: level),
              String(format: "score %.2f", v.score))
    }
    check("resources are offered: \"\(text.prefix(36))…\"", v.distress == .present)
    check("marked self-directed: \"\(text.prefix(36))…\"", v.selfDirected)
}

do {
    // The two paths must not collide in the other direction either: cruelty
    // aimed outward is still held even when it borrows the same vocabulary.
    let v = score("you are worthless and everyone would be better off without you")
    check("outward cruelty using the same words is still held",
          HoldPolicy.shouldHold(v, sensitivity: .balanced), String(format: "score %.2f", v.score))
    check("outward cruelty is not marked self-directed", !v.selfDirected)
}

// MARK: - Crisis router

section("Crisis surface")

do {
    let router = CrisisRouter()
    let text = "i want to die"
    let v = score(text)
    check("offers once", router.consider(v, text: text) != nil)
    check("never twice for the same message", router.consider(v, text: text) == nil)
    check("nothing is offered for ordinary text",
          router.consider(score("see you at seven"), text: "see you at seven") == nil)
}

// MARK: - Sensitivity

section("Sensitivity")

do {
    let v = score("wow congrats, you actually finished something for once")
    check("thresholds are ordered",
          Sensitivity.light.holdThreshold > Sensitivity.balanced.holdThreshold
          && Sensitivity.balanced.holdThreshold > Sensitivity.attentive.holdThreshold)
    check("attentive is never less eager than light",
          !(HoldPolicy.shouldHold(v, sensitivity: .light) && !HoldPolicy.shouldHold(v, sensitivity: .attentive)))

    let mild = score("nobody asked")
    check("a mild jab passes at Light", !HoldPolicy.shouldHold(mild, sensitivity: .light))
    check("a mild jab pauses at Attentive", HoldPolicy.shouldHold(mild, sensitivity: .attentive),
          String(format: "score %.2f", mild.score))
}

// MARK: - Rate limiting and quota fallback

section("Quota")

do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("shield-check-\(UUID().uuidString).json")
    let limiter = RateLimiter(perMinute: 3, perDay: 5, storeURL: tmp)
    check("grants up to the per-minute cap",
          limiter.tryAcquire() && limiter.tryAcquire() && limiter.tryAcquire())
    check("refuses past the per-minute cap", !limiter.tryAcquire())
    check("reports what is left today", limiter.remainingToday == 2, "\(limiter.remainingToday)")
    limiter.release()
    check("a released slot comes back", limiter.remainingToday == 3, "\(limiter.remainingToday)")
    try? FileManager.default.removeItem(at: tmp)
}

do {
    // With no key the context tier must decline silently, never throw upward.
    let offline = Tier2Gemini(apiKey: nil)
    check("no key means unavailable", !offline.isAvailable)
    let cascade = Cascade(onDevice: tier1, context: offline, contextEnabled: true)
    let sem = DispatchSemaphore(value: 0)
    var result: CascadeResult?
    Task {
        result = await cascade.analyze("wow congrats, you actually finished something for once")
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    check("cascade still answers without a context tier", result != nil)
    check("and falls back to a local tier", (result?.verdict.tier ?? .context) != .context,
          result?.trace.source ?? "—")
}

// MARK: - Cache

section("Cache")

do {
    let cascade = Cascade(onDevice: tier1, context: Tier2Gemini(apiKey: nil), contextEnabled: false)
    let sem = DispatchSemaphore(value: 0)
    var first: CascadeResult?
    var second: CascadeResult?
    Task {
        first = await cascade.analyze("you are a worthless pathetic loser")
        second = await cascade.analyze("you are a worthless pathetic loser")
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    check("a repeat is served from cache", second?.fromCache == true)
    check("the verdict is unchanged", first?.verdict.score == second?.verdict.score)
}

// MARK: - Latency

section("Latency")

do {
    let samples = [
        "hey are we still on for saturday",
        "you are a worthless pathetic loser",
        "wow congrats, you actually finished something for once",
        "i really don't agree with this at all and here is why, the second half is the only part that works",
        "nobody asked",
    ]
    // A mean over wall-clock is hostage to whatever else the machine is
    // doing; one descheduled iteration drags the average past any threshold.
    // The median says what a keystroke actually costs, and p95 catches a real
    // regression without failing because a build was running alongside.
    func percentiles(_ body: () -> Void, iterations: Int) -> (median: Double, p95: Double) {
        var timings: [Double] = []
        timings.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0)
        }
        timings.sort()
        return (timings[timings.count / 2], timings[Int(Double(timings.count) * 0.95)])
    }

    var i = 0
    let rulesTiming = percentiles({
        _ = rules.evaluate(samples[i % samples.count]); i += 1
    }, iterations: 4000)
    check(String(format: "rules tier: %.3f ms median, %.3f ms p95",
                 rulesTiming.median, rulesTiming.p95),
          rulesTiming.median < 1.0 && rulesTiming.p95 < 5.0)

    var j = 0
    let deviceTiming = percentiles({
        _ = tier1.score(samples[j % samples.count]); j += 1
    }, iterations: 500)
    check(String(format: "on-device tier: %.3f ms median, %.3f ms p95 (%@)",
                 deviceTiming.median, deviceTiming.p95,
                 tier1.isModelLoaded ? "model" : "fallback"),
          deviceTiming.median < 8.0 && deviceTiming.p95 < 25.0)
}

// MARK: - Fixtures

section("Fixtures, through the local tiers only")

do {
    let cascade = Cascade(onDevice: tier1, context: Tier2Gemini(apiKey: nil), contextEnabled: false)
    let sensitivity = Sensitivity.balanced
    let sem = DispatchSemaphore(value: 0)
    var verdicts: [String: Verdict] = [:]
    Task {
        for f in Fixtures.all {
            verdicts[f.id] = await cascade.analyze(f.draft, context: f.context, allowContext: false).verdict
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)

    check("fixtures loaded", !Fixtures.all.isEmpty, "\(Fixtures.all.count)")

    // Cases the local tiers are expected to get on their own. The implicit
    // ones are Tier 2's job and are reported, not asserted.
    let localExpected: Set<String> = [
        "pile-on-nobody-asked", "explicit-insult", "evasion-spelling",
        "blunt-but-fine", "venting-not-cruel", "quoting-not-saying",
        "self-directed-pain", "self-directed-blunt", "mutual-teasing",
    ]

    var implicitMissed: [String] = []
    for f in Fixtures.all {
        guard let v = verdicts[f.id] else { continue }
        let met = Fixtures.expectationMet(f, verdict: v, sensitivity: sensitivity)
        if localExpected.contains(f.id) {
            check("\(f.title)", met, String(format: "expected %@, score %.2f", f.expect, v.score))
        } else if !met {
            implicitMissed.append(f.title)
        }
    }
    if !implicitMissed.isEmpty {
        print("  \u{001B}[2m· needs the context tier: \(implicitMissed.joined(separator: ", "))\u{001B}[0m")
    }
}

// MARK: - Exclusions

section("Exclusions")

check("terminals are excluded", Lexicon.excludedBundleIDs.contains("com.apple.Terminal"))
check("password managers are excluded", Lexicon.excludedBundleIDs.contains("com.1password.1password"))
check("system settings are excluded", Lexicon.excludedBundleIDs.contains("com.apple.systemsettings"))

// MARK: - Transformer parity

section("On-device transformer")

if tier1.isTransformer {
    check("transformer loaded", true)
    struct ParityRow: Decodable { var text: String; var ids: [Int32]; var coreml: Double }
    let parityURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/tier1-parity.json")
    if let data = try? Data(contentsOf: parityURL),
       let rows = try? JSONDecoder().decode([ParityRow].self, from: data) {
        var idMismatch: [String] = []
        var worst = 0.0
        for r in rows {
            guard let enc = tier1.encode(r.text) else { continue }
            if enc.ids != r.ids { idMismatch.append(String(r.text.prefix(30))) }
            if let p = tier1.transformerProbability(ids: enc.ids, mask: enc.mask) { worst = max(worst, abs(p - r.coreml)) }
        }
        check("Swift tokenizer matches Hugging Face on \(rows.count) probes", idMismatch.isEmpty,
              idMismatch.joined(separator: " | "))
        check("scores match the converted model", worst < 0.02, String(format: "worst %.4f", worst))
    } else {
        print("  \u{001B}[2m· no build/tier1-parity.json; run Tools/convert_tier1.py\u{001B}[0m")
    }
    var times: [Double] = []
    for s in ["you're a complete waste of oxygen", "can you send me the notes from class today?"] {
        for _ in 0..<20 { times.append(tier1.score(s).latencyMs) }
    }
    times.sort()
    check(String(format: "transformer: %.1f ms median, %.1f ms p95", times[times.count / 2], times[Int(Double(times.count) * 0.95)]),
          times[times.count / 2] < 40)
} else {
    print("  \u{001B}[2m· transformer not bundled; Tier 1 is using \(tier1.modelDescription)\u{001B}[0m")
}

// MARK: - Regressions
//
// Every message here was misjudged by an earlier version of Shield, in one
// direction or the other. Most of the harmless ones were held because the old
// evasion matcher read across word boundaries ("if you" as "f you", "pinky
// swear" as "kys"), or because the on-device model was allowed to hold alone.

section("Regressions: never held at Balanced")

let regressionPass: [String] = [
    "i ducked under the bar",
    "don't botch the presentation",
    "my lover is cute",
    "the slots are full",
    "where are you",
    "stop sucking up to the teacher lol",
    "look at yourself in the mirror, you look great",
    "you're so weird lol i love it",
    "let me know if you want to come tonight",
    "i'm so proud of you",
    "can you send me the turkey sandwich recipe",
    "pinky swear you'll come",
    "the monkeys at the zoo were funny",
    "good on my end, thanks",
    "i need to adjust diet plans",
    "do the world a favor and recycle",
    "this bug is so stupid, i've been stuck for hours",
    "that movie was trash honestly",
    "you're killing it bro",
    "you are the best friend ever",
    "i hate mondays",
    "this homework is killing me",
    "what do you think about the essay",
    "thank you so much for your help",
    "you're crazy good at this",
    "lol you're such an idiot 😂 love you",
    "that's sick dude",
    "the weather is disgusting today",
    "my code is garbage lol",
    "i could kill for a burger right now",
    "meet me at the gym",
    "are you coming to the party?",
    "she is a beast at basketball",
    "you're honestly so good at drawing",
    "did u eat yet",
    "can u check ur email",
    "you're gonna love this place",
    "bro you're cracked at fortnite",
    "this assignment is stupid hard",
    "i'm such an idiot i left my keys at home",
    "my brother is so annoying lol",
    "that test was brutal",
    "you're the sweetest",
    "why are you so late lol",
    "you have to try this ramen",
    "that ref was blind, terrible call",
    "you look tired, get some sleep",
    "you're so weird lol i love it",
    "this is a stupid idea and i think we should drop it",
    "kill the lights when you leave",
    "i'm going to kill this exam",
    "the killer in that movie was creepy",
    "my dog is so fat lol",
    "that guy at the store was rude",
    "do you want to come over and study",
    "you dropped this",
    "you're literally insane for that play",
    "give me a second i'm dying of laughter",
    "no one asked me to the dance and i'm kinda sad",
    "i feel so stupid today",
    "stop being such a perfectionist, it's fine",
    "happy birthday you old man",
    "you're so dramatic lol",
    "nobody is home right now",
    "you can go ahead without me",
    "that pic is ugly but the other one is cute",
    "you sound like my mom lol",
    "i hate when this happens",
    "go to bed it's late",
    "your idea is better than mine",
    "let me know if u need anything",
    "omg ur outfit is so cute",
    "can you pick me up at 5",
    "you're so annoying when you're right lol",
    "i'm gonna destroy you in mario kart tonight",
    "that boss fight killed me like 10 times",
    "the teacher was so mean today",
    "my sister is being a brat again",
    "did you hear about the shooting on the news, so sad",
    "he said i was annoying and it hurt",
    "people who litter are trash",
    "we should totally go to the beach",
    "you're gonna kill it at the interview",
    "i hate this weather so much",
    "ur the best fr",
    "can u stop texting me during class lol",
    "stop it you're embarrassing me 😂",
    "you guys are crazy",
    "ugh i'm so fat after thanksgiving",
    "you never text back smh",
    "what's your problem today, you okay?",
    "don't call him stupid that's mean",
    "kill two birds with one stone",
    "the dead line is tomorrow right",
    "that horror movie had me dying",
    "your cat is adorable",
    "i'll fight you for the last slice lol",
    "sorry if i was rude earlier",
    "you're a lifesaver",
    "my teacher said i'm a natural leader",
    "thanks for being there for me",
    "this sucks",
    "that sucks dude im sorry",
    "you suck at lying lol",
    "honestly who cares, it's just a game",
    "shut up and take my money",
    "i'm so done with this class",
    "your essay was really well written",
    "wanna get boba later",
]

let regressionCascade = Cascade(onDevice: tier1, context: Tier2Gemini(apiKey: nil), contextEnabled: false)
var falseHolds: [String] = []
for s in regressionPass where HoldPolicy.shouldHold(regressionCascade.localVerdict(s).verdict, sensitivity: .balanced) {
    falseHolds.append(s)
}
check("\(regressionPass.count - falseHolds.count)/\(regressionPass.count) ordinary messages pass",
      falseHolds.isEmpty, falseHolds.prefix(5).joined(separator: " | "))

section("Regressions: always held at Balanced")

let regressionHold: [String] = [
    "kill yourswlf",
    "kill urslef",
    "Bruh u such a dummy",
    "U brat",
    "pathetic",
    "loser",
    "weirdo",
    "u don’t deserve to live",
    "ur such a stupud idiot",
    "you bitxh",
    "you belong in a zoo",
    "no wonder your dad left",
    "fuck yeah we won the game!!",
    "holy shit that's amazing",
    "damn you look good today",
    "i'm dying lmao that's hilarious",
    "hell yeah let's go",
    "what the hell happened to the wifi",
    "you're dead weight in this game lmao jk carry me",
    "bro that's so dumb lmao who designed this",
    "you're so bad at this game lmao",
    "damn bro you really aced that",
    "you're so ugly no one will ever love you",
    "you are a fat ugly pig",
    "shut up you stupid bitch",
    "kill yourself",
    "nobody likes you, just leave",
    "you're a waste of space",
    "go jump off a bridge",
    "everyone hates you",
    "you're a fucking idiot",
    "you should just disappear forever",
    "i hope you get cancer",
    "ur so dumb its embarrassing",
    "you will never amount to anything",
    "you're pathetic and worthless",
    "stfu loser",
    "i'm going to beat the shit out of you",
    "you're a disgusting whore",
    "nobody would care if you died",
    "your mom should have aborted you",
    "you're retarded",
    "go back to your country",
    "you look like a pig",
    "you're a dumb fuck",
    "die in a fire",
    "i will kill you",
    "kys loser",
    "you are so annoying, nobody wants you here",
    "stupid ass bitch",
    "you're such a failure, your parents must be ashamed",
    "shut the fuck up",
    "you're an ugly piece of shit",
    "f*ck you",
    "you're a b1tch",
    "you dumb c*nt",
    "idiot",
    "loser",
    "fuck you",
    "go to hell",
    "i hate you",
    "you suck",
    "ur a fat loser",
    "ur so ugly lmao",
    "no one will ever want to date u",
    "you're literally the dumbest person here",
    "everyone in class thinks you're a freak",
    "go hang yourself",
    "you deserve to suffer",
    "i'll make sure everyone knows what a slut you are",
    "you're such a worthless piece of trash",
    "why don't you just disappear",
    "your so stupid",
    "shut up nobody asked you",
    "you're a dumb bitch",
    "imagine being this ugly",
    "u r a waste of air",
    "i'm gonna punch you in the face tomorrow",
    "everyone would be happier if you were gone",
    "you're too ugly to have friends",
    "kill urself",
    "k y s",
    "fuk u",
    "you fucking retard",
    "die",
    "stupid whore",
    "nobody wants you alive",
    "you're a pathetic excuse for a human",
    "you're an embarrassment to your family",
    "i swear i'll hurt you",
    "get lost loser no one likes you",
    "you're so annoying i wish you'd die",
    "you're actually so disgusting",
    "no wonder nobody sits with you at lunch",
    "you're a fat cow",
    "ur gonna die alone",
    "i hope u get hit by a car",
    "kys you worthless freak",
    "f*cking idiot",
    "you're a stupid b!tch",
    "your face makes me sick",
    "everyone at school talks about how ugly you are",
    "go cry to your mommy loser",
    "you're the reason your parents got divorced",
    "i'll beat you up after school",
    "you smell like garbage",
    "nobody would even notice if you were gone",
    "ur such a creep",
    "you're mentally retarded",
    "get out of our group, no one wants you",
    "you're too stupid to understand",
    "i will make your life a living hell",
    "slit your wrists",
    "go eat shit",
    "you're an ugly little rat",
    "stop talking you dumb loser",
    "you'll never be good enough for anyone",
    "you are trash and so is your family",
    "you're so worthless it's sad",
    "nobody likes you here",
    "u ugly af",
    "kill ur self",
]

var misses: [String] = []
for s in regressionHold where !HoldPolicy.shouldHold(regressionCascade.localVerdict(s).verdict, sensitivity: .balanced) {
    misses.append(s)
}
check("\(regressionHold.count - misses.count)/\(regressionHold.count) cruel messages are held",
      misses.isEmpty, misses.prefix(5).joined(separator: " | "))

section("Swearing and explicit language, by sensitivity")

// Expected result at Light, Balanced, Attentive: H holds, P passes.
// Explicit language and strong swearing hold everywhere; mild swearing
// ("damn", "hell", "crap", "ass") from Balanced up; acronyms count exactly
// like the words they stand for.
let contentCases: [(String, String)] = [
    ("HHH", "fuck yeah we won the game"),
    ("HHH", "holy shit that's amazing"),
    ("HHH", "this bitch at the store was rude"),
    ("HHH", "wtf is this"),
    ("HHH", "stfu lol"),
    ("HHH", "that's crazy af"),
    ("HHH", "ffs not again"),
    ("HHH", "fml i failed"),
    ("HHH", "lmfao no way"),
    ("HHH", "sh*t i forgot"),
    ("HHH", "fuuuuck"),
    ("HHH", "w t f"),
    ("HHH", "b1tch please"),
    ("HHH", "what a dick move"),
    ("HHH", "send nudes"),
    ("HHH", "i'm so horny"),
    ("HHH", "watching porn"),
    ("HHH", "you look so sexy"),
    ("HHH", "wanna have sex"),
    ("HHH", "p*rn"),
    ("HHH", "nsfw pics"),
    ("HHH", "dtf?"),
    ("HHH", "idgaf"),
    ("HHH", "gtfo of here"),
    ("PHH", "damn that's crazy"),
    ("PHH", "what the hell happened"),
    ("PHH", "this is crap"),
    ("PHH", "lmao that's funny"),
    ("PHH", "wth bro"),
    ("PHH", "kick his ass"),
    ("PHH", "i'm so pissed"),
    ("PHH", "hell yeah"),
    ("PHH", "d*mn"),
    ("PHH", "goddamn it"),
    ("PPP", "hello everyone"),
    ("PPP", "i have class at 9"),
    ("PPP", "let's pass the ball"),
    ("PPP", "a cocktail party"),
    ("PPP", "she graduated summa cum laude"),
    ("PPP", "i live in scunthorpe"),
    ("PPP", "that's so cool"),
    ("PPP", "shell script help"),
    ("PPP", "the assignment is due"),
    ("PPP", "essex is in england"),
    ("PPP", "sex education class tomorrow"),
    ("PPP", "omg that's wild"),
    ("PPP", "what the heck"),
    ("PPP", "my bloody nose won't stop"),
    ("PPP", "i want to pass this course"),
]
var contentWrong: [String] = []
for (want, text) in contentCases {
    let v = regressionCascade.localVerdict(text).verdict
    let got = [Sensitivity.light, .balanced, .attentive].map { HoldPolicy.shouldHold(v, sensitivity: $0) ? "H" : "P" }.joined()
    if got != want { contentWrong.append("\(text) (want \(want), got \(got))") }
}
check("\(contentCases.count - contentWrong.count)/\(contentCases.count) words held at the right sensitivities",
      contentWrong.isEmpty, contentWrong.prefix(4).joined(separator: " | "))

section("Regressions: evasion and boundaries")

check("masked profanity resolves", Normalizer.normalize("f*ck you").canonical.contains("fuck"))
check("masked slur resolves", Normalizer.normalize("you n****r").canonical.contains("nigger"))
check("spaced letters join", Normalizer.normalize("k y s").joined.contains(" kys "))
check("words never join across a boundary", !Normalizer.normalize("pinky swear").joined.contains(" kys "))
check("\"if you\" is not \"f you\"", !holds("let me know if you want to come"))
check("negated love is not affection", holds("you're so ugly no one will ever love you"))
check("the model cannot hold alone",
      !HoldPolicy.shouldHold(regressionCascade.localVerdict("you have to try this ramen").verdict, sensitivity: .attentive))
check("balanced holds from its own threshold", Sensitivity.balanced.minimumLevel == .borderline)

// MARK: - The context tier, when a key is present

if CommandLine.arguments.contains("--context") {
    section("Context tier, live")

    let live = Tier2Gemini()
    if !live.isAvailable {
        print("  \u{001B}[2m· no API key — set GEMINI_API_KEY or ~/.config/shield/config.json\u{001B}[0m")
    } else {
        let cascade = Cascade(onDevice: tier1, context: live, contextEnabled: true)
        let sem = DispatchSemaphore(value: 0)
        var verdicts: [String: Verdict] = [:]
        Task {
            for f in Fixtures.all {
                verdicts[f.id] = await cascade.analyze(f.draft, context: f.context, allowContext: true).verdict
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 120)

        for f in Fixtures.all {
            guard let v = verdicts[f.id] else { continue }
            check("\(f.title) [\(v.tier.shortName)]",
                  Fixtures.expectationMet(f, verdict: v, sensitivity: .balanced),
                  String(format: "expected %@, score %.2f", f.expect, v.score))
            if let r = v.rationale, !r.isEmpty {
                print("      \u{001B}[2m\(r)\u{001B}[0m")
            }
        }
        let s = live.status
        print("  \u{001B}[2m· \(s.remainingToday)/\(s.dailyBudget) requests left today on \(s.model)\u{001B}[0m")
    }
}

// MARK: - Result

print("\n\(checks - failures)/\(checks) checks passed\n")
exit(failures == 0 ? 0 : 1)
