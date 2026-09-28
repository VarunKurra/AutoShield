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
