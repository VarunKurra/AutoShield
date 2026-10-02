#!/usr/bin/env python3
"""Fine-tunes Tier 1: a transformer that recognises cruelty aimed at a person.

Base model: unitary/toxic-bert, a BERT-base already trained on the Jigsaw
toxic-comment corpus. Off the shelf it flags *toxicity*, which includes plain
swearing ("fuck yeah we won"), so it disagreed with Shield's job. Here it is
re-taught a narrower question: is this message attacking, threatening or
demeaning someone?

Training data, built here and never written into the repo:
  - Jigsaw comments labelled insult / threat / identity_hate / severe_toxic
    are harmful; clean comments, and swearing that attacks no one, are not
  - group-chat lines generated from parts below, so the model hears how
    people actually talk, in both directions

Usage:  .venv-model/bin/python Tools/finetune_tier1.py
Writes: build/tier1-transformer/  (Hugging Face checkpoint)
"""
import csv, os, random, re, sys, time

import torch
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSequenceClassification, AutoTokenizer

random.seed(11)
torch.manual_seed(11)
# Gentle by default: this machine has 8 GB and someone is using it.
torch.set_num_threads(int(os.environ.get("THREADS", "2")))

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "build", "tier1-transformer")
BASE = "unitary/toxic-bert"
MAX_LEN = 64

# --------------------------------------------------------------------------
# Jigsaw

def jigsaw():
    path = os.path.join(ROOT, "data", "jigsaw_train.csv")
    pos, neg, swear = [], [], []
    for r in csv.DictReader(open(path, encoding="utf-8")):
        t = " ".join(r["comment_text"].split())
        if not (8 <= len(t) <= 280):
            continue
        aimed = any(r[k] == "1" for k in ("insult", "threat", "identity_hate", "severe_toxic"))
        if aimed:
            pos.append(t)
        elif r["toxic"] == "0" and r["obscene"] == "0":
            neg.append(t)
        elif r["obscene"] == "1" and r["insult"] == "0":
            swear.append(t)
    random.shuffle(neg); random.shuffle(swear)
    return pos, neg[:14000] + swear[:1500]

# --------------------------------------------------------------------------
# Chat, generated from parts

YOU = ["you're", "ur", "you are", "u r", "youre", "you", "u are", "ya", "you're literally", "you're honestly"]
INSULT_N = ["idiot", "loser", "moron", "freak", "creep", "clown", "joke", "waste of space", "failure",
            "bitch", "slut", "whore", "pig", "cow", "retard", "nobody", "embarrassment", "disgrace",
            "piece of shit", "dumbass", "parasite", "weirdo", "fatass", "rat", "loser with no friends"]
INSULT_A = ["stupid", "ugly", "fat", "worthless", "pathetic", "disgusting", "useless", "dumb", "hideous",
            "annoying", "braindead", "gross", "irrelevant", "unlovable", "talentless", "repulsive"]
FILL = ["", "so ", "such a ", "a ", "an absolute ", "a fucking ", "the most ", "really ", "genuinely "]
TAIL = ["", " lol", " lmao", " fr", " ngl", " tbh", " honestly", " bro", "!", ".", " 💀", " and everyone knows it",
        " no cap", " seriously", " smh"]

HARM_FRAMES = [
    "{you} {fill}{n}{tail}", "{you} {fill}{a}{tail}", "{you} {a} {n}{tail}", "what a {n}{tail}",
    "such a {n}{tail}", "shut up you {a} {n}{tail}", "nobody likes you, {n}{tail}", "go away {n}{tail}",
    "everyone thinks {you} {fill}{n}{tail}", "i hope you {death}{tail}", "you should {death}{tail}",
    "no one would care if you {gone}{tail}", "the world would be better if you {gone}{tail}",
    "i'm going to {hurt} you{tail}", "i will {hurt} you after school{tail}", "watch your back{tail}",
    "{you} so {a} nobody will ever love you{tail}", "why are you even alive{tail}",
    "you don't deserve friends{tail}", "nobody wants you here{tail}", "get out of the group chat {n}{tail}",
    "your {fam} must be ashamed of you{tail}", "your {fam} should have aborted you{tail}",
    "kys{tail}", "kill yourself{tail}", "go die{tail}", "imagine being this {a}{tail}",
    "you look like a {animal}{tail}", "you smell like {trash}{tail}", "nobody will come to your {event}{tail}",
    "{you} a mistake{tail}", "you will never be {good}{tail}", "everyone is laughing at you{tail}",
    "stop talking you {a} {n}{tail}", "you're so {a} it's sad{tail}", "delete yourself{tail}",
    "go back to your country{tail}", "you people are all {n}s{tail}", "i'll make your life hell{tail}",
]
DEATH = ["die", "get hit by a car", "get cancer", "rot", "choke", "disappear forever", "kill yourself",
         "drop dead", "never wake up", "jump off a bridge"]
GONE = ["died", "disappeared", "were gone", "vanished", "never came back", "killed yourself"]
HURT = ["kill", "beat", "punch", "stab", "hurt", "smash", "jump", "end"]
FAM = ["parents", "mom", "dad", "family"]
ANIMAL = ["pig", "cow", "whale", "rat", "monkey", "goblin", "thumb", "potato"]
TRASH = ["trash", "garbage", "shit", "a dumpster", "rotten eggs"]
EVENT = ["funeral", "birthday", "party", "wedding"]
GOOD = ["good enough", "loved", "anything", "pretty", "happy", "wanted"]

OK_FRAMES = [
    "{you} {fill}{praise}{tail}", "{you} killing it{tail}", "you killed it{tail}", "you ate that{tail}",
    "{swear} yeah we won{tail}", "holy {swear2} that's amazing{tail}", "this {thing} is so {a}{tail}",
    "my {thing} is {a2} lol", "i'm such an {n2} today{tail}", "i feel so {a3} today{tail}",
    "i'm {identity} and proud{tail}", "as a {identity} person i love this{tail}", "happy {holiday}{tail}",
    "my {identity} friend is the best{tail}", "you're so bad at this game lmao", "ez{tail}", "gg{tail}",
    "rematch? you got lucky{tail}", "i'm gonna destroy you in {game} tonight{tail}",
    "bro you got cooked{tail}", "skill issue lol", "you're cracked at {game}{tail}",
    "can you send me the {thing}{tail}", "what do you think about the {thing}{tail}",
    "are you coming {when}{tail}", "did you finish the {thing}{tail}", "you have to try this {food}{tail}",
    "thank you so much{tail}", "i'm so proud of you{tail}", "love you{tail}", "miss you{tail}",
    "you're not {a} at all{tail}", "nobody thinks you're {a}, stop{tail}", "they called me a {n2} and it hurt",
    "don't call people {a}, that's mean", "the villain is so {evil}{tail}", "that {thing} was trash{tail}",
    "i hate {thing}s{tail}", "this {thing} is killing me{tail}", "i'm dying lmao{tail}", "i'm dead 💀",
    "shut up that's so cool{tail}", "no way you did that{tail}", "you're crazy good{tail}",
    "{swear2} i forgot my {thing}{tail}", "what the hell happened to the {thing}{tail}",
    "you look tired, get some sleep{tail}", "you smell nice{tail}", "you're the {praise_n}{tail}",
    "nobody is home right now{tail}", "no one asked me to the dance{tail}", "go to bed it's late{tail}",
]
PRAISE = ["amazing", "talented", "funny", "smart", "cute", "sweet", "kind", "cool", "a legend", "a genius",
          "the best", "so good at this", "gorgeous", "underrated", "goated"]
PRAISE_N = ["goat", "best", "sweetest", "funniest", "realest"]
SWEAR = ["fuck", "hell", "fuckin", "damn"]
SWEAR2 = ["shit", "fuck", "crap", "damn"]
THING = ["homework", "essay", "printer", "bug", "wifi", "test", "movie", "game", "traffic", "class",
         "weather", "code", "song", "level", "lecture", "charger", "ref", "boss fight"]
A2 = ["garbage", "trash", "a mess", "broken", "so bad", "stupid"]
A3 = ["stupid", "ugly", "fat", "dumb", "useless", "gross"]
N2 = ["idiot", "loser", "mess", "clown", "dork", "nerd"]
IDENTITY = ["gay", "black", "muslim", "jewish", "trans", "mexican", "asian", "autistic", "disabled",
            "lesbian", "bi", "indian", "chinese", "latina", "nonbinary", "deaf"]
HOLIDAY = ["eid", "pride", "diwali", "hanukkah", "lunar new year", "christmas"]
GAME = ["fortnite", "mario kart", "valorant", "smash", "chess", "2k", "minecraft"]
WHEN = ["tonight", "to the party", "saturday", "later", "to practice"]
FOOD = ["ramen", "pizza", "boba", "tacos", "cake"]
EVIL = ["evil", "creepy", "terrifying", "ruthless"]


def fill(frame):
    parts = dict(you=random.choice(YOU), fill=random.choice(FILL), n=random.choice(INSULT_N),
                 a=random.choice(INSULT_A), tail=random.choice(TAIL), death=random.choice(DEATH),
                 gone=random.choice(GONE), hurt=random.choice(HURT), fam=random.choice(FAM),
                 animal=random.choice(ANIMAL), trash=random.choice(TRASH), event=random.choice(EVENT),
                 good=random.choice(GOOD), praise=random.choice(PRAISE), praise_n=random.choice(PRAISE_N),
                 swear=random.choice(SWEAR), swear2=random.choice(SWEAR2), thing=random.choice(THING),
                 a2=random.choice(A2), a3=random.choice(A3), n2=random.choice(N2),
                 identity=random.choice(IDENTITY), holiday=random.choice(HOLIDAY), game=random.choice(GAME),
                 when=random.choice(WHEN), food=random.choice(FOOD), evil=random.choice(EVIL))
    s = frame.format(**parts)
    s = re.sub(r"\s+", " ", s).strip()
    # "you're a idiot" -> "you're an idiot"
    s = re.sub(r"\ba ([aeiou])", r"an \1", s)
    return s


def chat():
    harm = {fill(random.choice(HARM_FRAMES)) for _ in range(9000)}
    ok = {fill(random.choice(OK_FRAMES)) for _ in range(9000)}
    return list(harm), list(ok)


def curated():
    import json
    path = os.path.join(ROOT, "Sources", "ShieldCore", "Resources", "train-augment.json")
    rows = json.load(open(path))["rows"]
    return ([r["text"] for r in rows if r["label"] == "harmful"],
            [r["text"] for r in rows if r["label"] == "ok"])

# --------------------------------------------------------------------------

class Rows(Dataset):
    def __init__(self, items, tok):
        self.items, self.tok = items, tok
    def __len__(self):
        return len(self.items)
    def __getitem__(self, i):
        return self.items[i]


def main():
    jp, jn = jigsaw()
    cp, cn = chat()
    up, un = curated()
    print(f"jigsaw  {len(jp)} harmful {len(jn)} ok")
    print(f"chat    {len(cp)} harmful {len(cn)} ok")
    print(f"curated {len(up)} harmful {len(un)} ok")
    items = [(t, 1) for t in jp + cp + up] + [(t, 0) for t in jn + cn + un]
    random.shuffle(items)
    cut = int(len(items) * 0.95)
    train, val = items[:cut], items[cut:]

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    tok = AutoTokenizer.from_pretrained(BASE)
    # A fresh two-way head on top of the toxicity encoder.
    model = AutoModelForSequenceClassification.from_pretrained(
        BASE, num_labels=2, problem_type="single_label_classification",
        id2label={0: "ok", 1: "harmful"}, label2id={"ok": 0, "harmful": 1},
        ignore_mismatched_sizes=True).to(device)

    def collate(batch):
        enc = tok([b[0] for b in batch], padding=True, truncation=True, max_length=MAX_LEN, return_tensors="pt")
        enc["labels"] = torch.tensor([b[1] for b in batch])
        return enc

    dl = DataLoader(Rows(train, tok), batch_size=int(os.environ.get("BATCH", "16")), shuffle=True,
                    collate_fn=collate)
    epochs = int(os.environ.get("EPOCHS", "2"))
    steps = epochs * len(dl)
    opt = torch.optim.AdamW(model.parameters(), lr=3e-5, weight_decay=0.01)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-5, total_steps=steps, pct_start=0.06,
                                                anneal_strategy="linear")
    print(f"training on {len(train)} rows, {steps} steps, device={device}")
    model.train()
    t0, step = time.time(), 0
    for ep in range(epochs):
        for batch in dl:
            batch = {k: v.to(device) for k, v in batch.items()}
            loss = model(**batch).loss
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); sched.step(); opt.zero_grad()
            step += 1
            if step % 100 == 0:
                if device == "mps":
                    torch.mps.empty_cache()
                print(f"  step {step}/{steps} loss {loss.item():.3f} {time.time() - t0:.0f}s", flush=True)

    model.eval()
    correct = 0
    with torch.no_grad():
        for i in range(0, len(val), 64):
            b = collate(val[i:i + 64])
            labels = b.pop("labels")
            pred = model(**{k: v.to(device) for k, v in b.items()}).logits.argmax(-1).cpu()
            correct += (pred == labels).sum().item()
    print(f"held-out accuracy {correct / len(val) * 100:.1f}% on {len(val)} rows")

    os.makedirs(OUT, exist_ok=True)
    model.to("cpu").save_pretrained(OUT)
    tok.save_pretrained(OUT)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
