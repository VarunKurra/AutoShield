<div align="center">

<img src="Design/AutoShield-logo.png" width="112" alt="AutoShield">

# AutoShield

**Catches a cruel message before it sends, and covers one sent to you.
Everywhere on your Mac, in every app, without those apps cooperating.**

macOS 15 · Swift 6.1 · no third-party packages

</div>

---

A macOS app that catches cruel messages before they send — in every application
on the machine. Not in its own chat window. Discord, Instagram in Chrome,
Messages, Gmail, Slack, any text field on the system.

This is a local prototype. No App Store, no notarization, no distribution.

```
Tools/build.sh          build Shield.app
Tools/train.sh          fetch the corpus and train the Tier 1 model
Tools/check.sh          run the test suite
Tools/check.sh --context  also replay the fixtures through Gemini
open Shield.app
open Shield.app --args --monitor    open straight into the instrument panel
```

## What it does

**Outgoing.** Shield reads what you are writing, from the focused field
through the Accessibility API, or from your keystrokes in apps that draw their
own text and expose nothing (Google Docs, canvas editors, games). It keeps a
verdict warm as you type and stops cruel text two ways:

- **While typing**, in any app: once the offending word is finished, the
  keyboard pauses and a non-activating panel appears beside the caret. Nothing
  more can be typed onto the message until you choose.
- **On Return**: a system-wide `CGEventTap` swallows Return on a draft over the
  threshold, every time, so the message does not send.

The panel has three ways out, each one keystroke:

- `return` rewrites it with Gemini (and sends it, if Return is what triggered
  the pause), keeping your point and your voice and dropping the cruelty
- `⌘⌫` removes the offending sentences
- `esc` puts you back in the field to fix it yourself

There is no "send it anyway" button, because one sitting next to the others
turns the pause into a dare. Escape is not a pass either: the same words are
held again if you press Return on them. Nothing is ever sent that you have not
seen: if the rewrite fails or quota is gone, the panel says so and your
original text is untouched.

**Incoming.** Frosted glass floated over a cruel message that was sent *to*
you, tracked to its rect and peeled away only if you ask. It works in any app:
a background scan reads the visible text of the frontmost window continuously,
judges each run of text alone and joined with its neighbours (so a message
split by a link or bold text is still read whole), and moves covers with the
text as you scroll.

An honest limit: macOS gives no way to intercept another app's rendering, so
text exists on screen for the moment between paint and cover. Shield closes
that gap as far as a native app can (a continuous off-main-thread sweep, a
synchronous local score, no network on the hot path) but it cannot make it
zero. Only code running inside the app itself could.

**Crisis surface.** When language turns toward self-harm, Shield shows 988 and
the Crisis Text Line beside the draft. It offers and never acts: nothing is
sent, reported or escalated, nothing is blocked, and a message about your own
pain is never held.

**Severity.** Every caught message is scored and coloured on a warm ramp:
amber (Sharp), orange (Harsh), red (Cruel). The word sits next to the colour,
so the meaning never depends on seeing hue.

**Shield Monitor.** Which tier resolved each draft, its latency, the context
tier's rationale when it fired, live tier distribution, remaining daily quota,
and a rehearsal tab that replays the fixtures through the real pipeline.

## The cascade

One interface, three tiers, swappable without touching UI code:

```swift
func analyze(_ text: String, context: [String]) async -> Verdict
```

| Tier | What | Cost | Typical latency |
|------|------|------|-----------------|
| 0 | Whole-word patterns over normalised text, with evasion handling | free, local | < 1 ms |
| 1 | Fine-tuned BERT transformer on the Neural Engine (Core ML) | free, local | ~2 ms |
| 2 | Gemini with the surrounding conversation | free tier, network | 400–2000 ms |

**Tier 0** decides almost everything. Text is normalised first: leetspeak,
unicode lookalikes, zero-width characters, stretched letters ("looooser"),
masked words ("f*ck", "n****r") and spelled-out letters ("k y s") all fold
back onto plain words. Matching is strictly on whole words, so "if you" never
reads as "f you" and "pinky swear" never reads as "kys". Insults are scored by
who they land on: "you're a loser" is aimed, "my code is garbage" is not,
"i'm such an idiot" is the writer, and "you're not stupid" is negated. Explicit
patterns cover death wishes, threats, harassment, exclusion and slurs; friendly
markers ("jk", "love you", a heart) soften an insult but never a threat.

**Swearing and explicit language** are judged by the word, not by aim, because
Shield is meant for school and family machines:

| | Light | Balanced | Attentive |
|---|---|---|---|
| Explicit or sexual language | held | held | held |
| Swearing (f-word, s-word, "bitch"…) | held | held | held |
| Mild swearing ("damn", "hell", "crap", "ass") | passes | held | held |

Acronyms count exactly as the words they stand for ("wtf", "stfu", "ffs",
"lmfao" are the f-word; "wth" is "hell"; "lmao" is "ass"). Quoting, a "jk",
or the context tier can never talk a banned word down. Someone describing
their own pain is the one exception: it is never held, only offered resources.

**Tier 1** is `unitary/toxic-bert` (BERT-base) fine-tuned by
`Tools/finetune_tier1.py` on one question, "does this attack someone?", then
converted by `Tools/convert_tier1.py` to an 8-bit Core ML model (110 MB) with a
Swift WordPiece tokenizer verified token-for-token against Hugging Face's. It
catches cruelty no rule names ("you're a stain on this school"), but on its
own it cannot tell teasing between friends from the real thing, so it never
holds a message by itself: what only the transformer flags goes to tier 2,
and Return waits up to 2.5 s for the answer. Without tier 2 (offline, no key),
the transformer holds on its own at Attentive only.

**Tier 2** reads the conversation. It is reached when the transformer flags
something the rules missed, when the local tiers are unsure, or when the text
has the shape of veiled cruelty (polite threats, freeze-outs, coded in-jokes).

Verdicts are computed continuously while typing and cached by content hash.
The event tap reads one atomic flag; if Return arrives before the watcher has
scored the latest keystrokes, the tap scores them itself, locally, rather than
let the message go on a stale verdict.

### Training tier 1

```bash
python3 -m venv --system-site-packages .venv-model
.venv-model/bin/pip install coremltools          # torch and transformers too
curl -sL -o data/jigsaw_train.csv \
  https://huggingface.co/datasets/thesofakillers/jigsaw-toxic-comment-classification-challenge/resolve/main/train.csv
taskpolicy -b .venv-model/bin/python Tools/finetune_tier1.py   # ~1.5 h on an M3, at background priority
.venv-model/bin/python Tools/convert_tier1.py                  # Core ML + parity file
Tools/build.sh && Tools/check.sh
```

Training data: Jigsaw comments labelled insult, threat, identity hate or
severe toxicity are harmful; clean comments and swearing that attacks no one
are not (swearing is handled by the word lists, not the model). Generated
group-chat lines add how people actually talk in both directions. The older
bag-of-words model (`Tools/train.sh`) remains as a fallback when the
transformer is not bundled.

## Setup

Two permissions, granted by hand in System Settings. The app's first-launch
screen explains both and shows their state live.

- **Accessibility** — read the focused text field in other apps.
- **Input Monitoring** — see Return before the app underneath does, and read
  keystrokes in apps whose text Accessibility cannot see. Typed text is kept
  in memory only (the last few hundred characters of the frontmost app), never
  written to disk, and dropped on app switch or after two idle minutes.

After granting either one, quit Shield and open it again; macOS only hands a
new permission to a fresh launch.

### The Gemini key

Never committed. Shield reads it from the environment or a local file:

```bash
export GEMINI_API_KEY=...
# or
mkdir -p ~/.config/shield && cat > ~/.config/shield/config.json <<'EOF'
{
  "geminiAPIKey": "...",
  "model": "gemini-3.1-flash-lite",
  "supabaseURL": "https://<project>.supabase.co",
  "supabaseAnonKey": "sb_publishable_..."
}
EOF
chmod 600 ~/.config/shield/config.json
```

Without a key Shield runs local-only and says so in the monitor. The model name
lives in one constant, `GeminiConfig.defaultModel`.

## Supabase

Off by default. When switched on in Settings, Shield upserts one row per
install per day containing counts and nothing else: caught, rewritten,
dropped, sent anyway, covered, per-tier totals, and the sensitivity in force.
No message text, no rewrites, no app names, no account.

Schema, policies and setup are in [`supabase/`](supabase/). Row level security
assumes the publishable key is public: anon may insert and update recent rows
and cannot read anything back.

## What leaves this Mac

Tiers 0 and 1 run entirely locally. Tier 2 sends the draft and the surrounding
conversation to Google's Gemini API — the only thing that ever leaves the
machine — and Settings turns it off for local-only operation. Counts are kept
on disk for the monitor; message text never is. Shield reports to nobody: no
parent view, no school view, no server, no account.

## Build notes

Built with `swiftc` directly rather than SwiftPM. The Command Line Tools on
this machine ship a stale duplicate `SwiftBridging` module map and a
`PackageDescription` older than the driver, which breaks every framework import
and every manifest link. `Tools/fix-toolchain.sh` mirrors the toolchain's
include tree into `.toolchain/`, drops the duplicate there and points `swiftc`
at the mirror with `-resource-dir`. No system files are touched, and the script
is a no-op on a healthy install.

Swift 6.1 toolchain, language mode 5. No third-party packages: AppKit and
Core Animation cover the two hero animations, and hand-written `AXUIElement`
calls are smaller than a wrapper would be.

Type is Source Serif 4 for anything that speaks and Geist for anything that
labels, with GeistMono in the Monitor only. Both are bundled.

### Chrome and Electron

Blink-based apps build no accessibility tree until a client asks for one, which
makes every web text field invisible. Shield sets `AXManualAccessibility` on
each app once, the same thing a screen reader does. Without it, Discord,
Instagram and Gmail are simply not there.

### Debugging

`SHIELD_DEBUG=1 ./Shield.app/Contents/MacOS/Shield` writes the catch path to
`/tmp/shield-debug.log`: focus changes, holds, panel geometry, dismissals,
rewrites and stats syncs. Running it from a terminal that already has
Accessibility and Input Monitoring is also the quickest way to test without
re-granting permissions.

The app is signed ad-hoc with a stable identifier so permission grants survive
rebuilds where macOS allows it. If a rebuild makes Shield stop catching,
remove it from both System Settings lists and add it back.
