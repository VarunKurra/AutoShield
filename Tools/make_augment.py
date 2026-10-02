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

# --- Everyday chat ---------------------------------------------------------
#
# The public corpora are tweets and Wikipedia talk pages. Neither sounds like
# a group chat, so without this the model learns that "you" plus anything
# informal is an attack. These teach it what friends actually say.

ok_chat = [
    "i'm so proud of you", "you're killing it bro", "you are the best friend ever",
    "damn you look good today", "what do you think about the essay",
    "you're crazy good at this", "thank you so much for your help",
    "can you send me the notes from today", "are you coming to the party tonight",
    "let me know if you want to come", "you did amazing on that test",
    "you're literally the funniest person i know", "i miss you so much",
    "did you finish the homework yet", "you're so talented honestly",
    "omg you look so cute in that pic", "that's sick dude", "she is a beast at basketball",
    "fuck yeah we won the game", "holy shit that's amazing", "this homework is killing me",
    "i could kill for a burger right now", "i'm dying lmao that's hilarious",
    "bro that was insane", "you're a legend", "you're a genius", "you absolute legend",
    "dude you're so lucky", "you deserve it so much", "you got this", "good luck tomorrow you'll do great",
    "happy birthday hope you have the best day", "call me when you get home",
    "what time are you free", "you want to play later", "can you help me with math",
    "you're right my bad", "sorry i was late", "i love you guys", "love you bestie",
    "you're so sweet", "that's so nice of you", "you're the goat", "you're actually so smart",
    "wanna hang out this weekend", "you have to watch this video", "where are you",
    "you were so good in the play", "your drawing is so good", "your hair looks great",
    "this song slaps", "that game was fire", "lmao you're wild", "you're so funny",
    "damn that's crazy", "shit i forgot my charger", "fuck i missed the bus",
    "this traffic is ass", "my code is garbage lol", "this bug is so stupid",
    "that movie was trash honestly", "the weather is disgusting today", "i'm so tired",
    "ugh mondays", "i hate mondays", "math is the worst", "my phone is dying",
    "we should get food", "you down for pizza", "i'm proud of how far you've come",
    "you inspire me", "you're doing great sweetie", "i'm here if you need me",
    "you can do it", "just text me", "send me the link", "did you see that",
    "you're up early", "you good?", "you okay?", "how are you doing",
    "i think you're wrong about this but ok", "i disagree with you on that",
    "that's not how it works though", "you forgot to add the file",
    "you have a typo in the second line", "can you fix the slides",
    "you missed the meeting", "you owe me five bucks lol", "you're so extra lol",
    "you're such a nerd for that lol", "stop you're making me blush",
    "shut up that's so cool", "no way you did that", "are you kidding me that's awesome",
    "that's lowkey hilarious", "lmao i'm dead", "that killed me", "you killed it",
    "you smashed that presentation", "you crushed it", "go off queen",
    "slay", "you ate that", "periodt", "no cap you were amazing", "bet see you there",
]

harmful_chat = [
    "you're so ugly no one will ever love you", "you are a fat ugly pig",
    "shut up you stupid bitch", "kill yourself", "nobody likes you just leave",
    "you're a waste of space", "go jump off a bridge", "everyone hates you",
    "you're a fucking idiot", "you should just disappear forever",
    "i hope you get cancer", "ur so dumb its embarrassing",
    "you will never amount to anything", "you're pathetic and worthless",
    "stfu loser", "i'm going to beat the shit out of you", "you're a disgusting whore",
    "nobody would care if you died", "your mom should have aborted you",
    "you're retarded", "go back to your country", "you look like a pig",
    "you're a dumb fuck", "die in a fire", "i will kill you", "kys loser",
    "you are so annoying nobody wants you here", "stupid ass bitch",
    "you're such a failure your parents must be ashamed", "shut the fuck up",
    "you're an ugly piece of shit", "fuck you", "go to hell", "i hate you", "you suck",
    "you're worthless", "no one wants you around", "you're a joke",
    "everyone is laughing at you", "you have no friends", "go cry about it loser",
    "you're so stupid it hurts", "you're a freak", "you're disgusting",
    "you're a loser and everyone knows it", "you smell like trash",
    "you're the reason everyone left", "nobody invited you", "you're not welcome here",
    "get out of the group chat", "we all hate you", "you're so fat",
    "you're ugly as hell", "you're a slut", "you're a creep", "you're such a loser",
    "nobody cares about you", "no one will miss you", "the world would be better without you",
    "you should kill yourself", "go die", "just die already", "i hope you die",
    "watch your back", "i know where you live", "you're dead after school",
    "i'll make your life hell", "you'll regret this", "i'm going to find you",
    "imagine being that ugly", "you're a waste of oxygen", "you're so pathetic",
    "what a loser", "such an idiot", "you're braindead", "you absolute moron",
    "you dumbass", "idiot", "loser", "moron", "fatass", "you're trash",
]

def expand_plain(lines, label, tails_for):
    out = []
    for line in lines:
        for tail in tails_for:
            s = " ".join(f"{line} {tail}".split())
            out.append({"text": s, "label": label})
    return out

chat_tails = ["", "lol", "lmao", "fr", "tbh", "honestly", "!", "bro", "dude", "ngl"]

rows = (expand(harmful_templates, "harmful") + expand(ok_templates, "ok")
        + expand_plain(ok_chat, "ok", chat_tails)
        + expand_plain(harmful_chat, "harmful", chat_tails))
random.shuffle(rows)

path = os.path.join(os.path.dirname(__file__), "..",
                    "Sources", "ShieldCore", "Resources", "train-augment.json")
with open(path, "w") as f:
    json.dump({"rows": rows}, f, indent=1)
print(len(rows), "augmentation rows ->", os.path.relpath(path))
print("harmful:", sum(1 for r in rows if r["label"] == "harmful"),
      " ok:", sum(1 for r in rows if r["label"] == "ok"))
