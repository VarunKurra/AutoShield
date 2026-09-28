#!/usr/bin/env python3
"""Builds the curated half of Tier 1's training data.

The public toxicity corpus the trainer downloads is profanity-heavy: it teaches
a model to spot swearing, which Tier 0 already does for free. What it cannot
teach is the cruelty that uses no flagged words, or the difference between
aiming at someone and describing your own pain.

So we hand-write that half. Templates give coverage without pretending to be a
bigger dataset than it is.
"""
import json, itertools, os, random

random.seed(7)

harmful_templates = [
    # exclusion
    "nobody asked {tail}",
    "no one asked for your opinion {tail}",
    "literally nobody was talking to you {tail}",
    "why are you even in this chat {tail}",
    "we already decided this without you {tail}",
    "the group chat is fine without you {tail}",
    "you were not invited and you know it {tail}",
    "everyone talked about it already, you just were not there {tail}",
    "this is a conversation for people who actually matter {tail}",
    "stay in your lane, nobody here wants you {tail}",
    # backhanded
    "this is really good for someone like you {tail}",
    "brave of you to post that {tail}",
    "that is certainly a choice {tail}",
    "good for you for trying at least {tail}",
    "i could never be that confident about something like that {tail}",
    "it is cute that you think that matters {tail}",
    "no offense but you are not built for this {tail}",
    "i am just being honest, you are not as good as you think {tail}",
    "sweet that you thought anyone would care {tail}",
    "must be nice to not notice how that comes across {tail}",
    # sarcasm as a weapon
    "wow you actually finished something for once {tail}",
    "congrats on doing the bare minimum {tail}",
    "shocking, you got it wrong again {tail}",
    "of course you would say that, typical {tail}",
    "how original, never heard that before {tail}",
    "groundbreaking contribution as always {tail}",
    "every single time with you, without fail {tail}",
    # veiled threats
    "i would be careful what you say next {tail}",
    "it would be a shame if people found out about last year {tail}",
    "you might want to think about who you are talking to {tail}",
    "i hope nothing happens to that account of yours {tail}",
    "accidents happen to people who talk too much {tail}",
    "i know exactly where you go after school {tail}",
    # mockery / pile-on
    "imagine thinking anyone here likes you {tail}",
    "we are all laughing at you right now {tail}",
    "screenshotted, the whole group is seeing this {tail}",
    "delete your account honestly {tail}",
    "second hand embarrassment reading that {tail}",
    "cry about it, nobody cares {tail}",
    # direct
    "you are the single most pathetic person i have ever met {tail}",
    "everyone thinks you are a joke and they are right {tail}",
    "you make everything worse just by being there {tail}",
    "no one would notice if you disappeared tomorrow {tail}",
    "you are genuinely worthless and everyone can see it {tail}",
    "you ruin every single thing you touch {tail}",
]

ok_templates = [
    # blunt disagreement about ideas
    "i really do not agree with this at all {tail}",
    "i think this approach is wrong and here is why {tail}",
    "that argument does not hold up, the numbers say otherwise {tail}",
    "this whole plan seems like a bad idea to me {tail}",
    "i hate this design, it makes the page unreadable {tail}",
    "that movie was terrible and i am not changing my mind {tail}",
    "the second half is the only part that works {tail}",
    "strong disagree, but i see where you are coming from {tail}",
    # venting without a target
    "today was such a mess, everything broke at once {tail}",
    "i am so done with this week honestly {tail}",
    "this stupid printer has eaten three pages already {tail}",
    "traffic was awful and i missed the whole first half {tail}",
    "i am furious about how this was handled {tail}",
    # warmth and ordinary chat
    "hey are we still on for saturday {tail}",
    "thank you so much for covering for me today {tail}",
    "that looks great, honestly nice work {tail}",
    "let me know when you get there {tail}",
    "i will send the file over in a minute {tail}",
    "congratulations, that is genuinely amazing news {tail}",
    "do you want to grab food after {tail}",
    "sorry i missed your message, long day {tail}",
    # mutual teasing
    "you play like my grandmother and i will prove it {tail}",
    "ok you owe me a rematch, i carried you all night {tail}",
    "terrible take but i love you anyway {tail}",
    # reporting cruelty rather than committing it
    "they called me a loser in front of everyone {tail}",
    "someone told her nobody asked and she left the chat {tail}",
    "you should never say that to a person {tail}",
    "that is not okay to say to someone, please stop {tail}",
    # the writer's own pain — these must never read as outward harm
    "i hate myself so much right now {tail}",
    "i feel like everyone would be better off without me {tail}",
    "i am worthless and i cannot shake it {tail}",
    "i do not want to be here anymore {tail}",
    "i have been so alone lately and it is getting worse {tail}",
    "i am falling apart and i do not know who to tell {tail}",
    "what is even the point anymore {tail}",
    "i am a burden on everyone around me {tail}",
    "i want to disappear for a while {tail}",
    "nothing matters and i am so tired {tail}",
]

tails = ["", "lol", "honestly", "fr", "tbh", "…", "!", ".", "i guess", "anyway",
         "just saying", "seriously", "ok", "🙂", "whatever"]

def expand(templates, label):
    out = []
    for t in templates:
        for tail in tails:
            s = t.format(tail=tail).strip()
            s = " ".join(s.split())
            out.append({"text": s, "label": label})
    return out

rows = expand(harmful_templates, "harmful") + expand(ok_templates, "ok")
random.shuffle(rows)

path = os.path.join(os.path.dirname(__file__), "..",
                    "Sources", "ShieldCore", "Resources", "train-augment.json")
with open(path, "w") as f:
    json.dump({"rows": rows}, f, indent=1)
print(len(rows), "augmentation rows ->", os.path.relpath(path))
print("harmful:", sum(1 for r in rows if r["label"] == "harmful"),
      " ok:", sum(1 for r in rows if r["label"] == "ok"))
