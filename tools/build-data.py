#!/usr/bin/python3
"""Build the picker's data files from upstream sources.

  tools/build-data.py <source-dir>

<source-dir> must hold the downloaded upstream files (see THIRD_PARTY_NOTICES.md for
where each comes from):

  emoji-test.txt                     Unicode emoji list, groups, skin-tone variants
  cldr-annotations-{en,uk,ru}.json   CLDR names and keywords
  cldr-derived-{en,uk,ru}.json       CLDR names for flags, keycaps, ZWJ sequences
  emoticons.json                     kaomoji (w33ble/emoticon-data)

Writes data/emoji.json, data/symbols.json and data/kaomoji.json. The output is
committed, so users never run this; it exists so the data can be regenerated and
audited rather than trusted.
"""
import json
import pathlib
import re
import sys
import unicodedata

LOCALES = ("en", "uk", "ru")
PLUGIN_DIR = pathlib.Path(__file__).resolve().parent.parent
OUT = PLUGIN_DIR / "data"

VS16 = "️"
TONES = range(0x1F3FB, 0x1F400)

GROUP_ICONS = {
    "Smileys & Emotion": "😀",
    "People & Body": "👋",
    "Animals & Nature": "🐻",
    "Food & Drink": "🍔",
    "Travel & Places": "✈️",
    "Activities": "⚽",
    "Objects": "💡",
    "Symbols": "💟",
    "Flags": "🏁",
}

# Symbol tabs: (name, glyph, the ones people actually reach for, code point ranges).
# Order is display order. The common characters are listed first in their tab; the
# rest follow in code point order, each in the first tab whose range holds it.
SYMBOL_TABS = [
    ("Arrows", "→", "→←↑↓↔↕⇒⇐⇑⇓⇔↩↪↻↺➜⟶⟵",
     [(0x2190, 0x21FF), (0x27F0, 0x27FF), (0x2900, 0x297F), (0x2B00, 0x2B11)]),
    ("Math", "∑", "±×÷≠≈≡≤≥∞√∑∏∫∂∆∇∈∉∩∪⊂⊃∀∃¬∧∨∝∴°²³¹",
     [(0x00B1, 0x00B1), (0x00D7, 0x00D7), (0x00F7, 0x00F7), (0x2200, 0x22FF),
      (0x2070, 0x209F), (0x00B2, 0x00B3), (0x00B9, 0x00B9)]),
    ("Fractions & numbers", "½", "½⅓⅔¼¾⅕⅛⅜⅝⅞ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ①②③④⑤",
     [(0x00BC, 0x00BE), (0x2150, 0x218F), (0x2460, 0x24FF)]),
    ("Currency", "€", "€$£¥₴₽₿¢₹₩₺₪₫",
     [(0x0024, 0x0024), (0x00A2, 0x00A5), (0x20A0, 0x20CF)]),
    ("Technical", "⌘", "⌘⌥⌃⇧⇪⇥⎋⏎↵⌫⌦⏏⎇⌚⌛⏻⏼⏽",
     [(0x2300, 0x23FF)]),
    ("Punctuation", "…", "…—–•·§¶©®™℠№«»„“”‘’‚′″‰†‡¿¡℃℉",
     [(0x00A1, 0x00A1), (0x00A7, 0x00A7), (0x00A9, 0x00A9), (0x00AB, 0x00AB),
      (0x00AE, 0x00AE), (0x00B0, 0x00B0), (0x00B5, 0x00B7), (0x00BB, 0x00BB),
      (0x00BF, 0x00BF), (0x2010, 0x205E), (0x2100, 0x214F)]),
    ("Shapes & marks", "★", "★☆✓✔✗✘✦✧❖●○◉■□▪▫▲△▼▽◆◇♠♣♥♦♤♧♡♢☐☑☒✱✳❄☀☁☂☼☾♪♫",
     [(0x25A0, 0x25FF), (0x2600, 0x26FF), (0x2700, 0x27BF), (0x2B12, 0x2BFF)]),
    ("Greek", "π", "αβγδεζηθλμπρστφχψωΑΒΓΔΘΛΠΣΦΨΩ",
     [(0x0391, 0x03A9), (0x03B1, 0x03C9)]),
]

# Kaomoji tabs: the most used tags get their own tab, everything else lands in "More".
KAOMOJI_TABS = 12
KAOMOJI_TAB_NAMES = {"embarassed": "Embarrassed"}

# Kaomoji carry English tags only. The common ones get Ukrainian and Russian words too,
# so the same query works on every tab.
KAOMOJI_TAG_WORDS = {
    "happy": "щасливий радість радий счастливый радость рад",
    "love": "кохання любов серце любовь сердце",
    "dance": "танець танцює танец танцует",
    "table": "стіл перевернути стол перевернуть",
    "flip": "перевернути перевернуть",
    "cry": "плач плаче сльози плач плачет слёзы слезы",
    "wave": "привіт помахати привет помахать",
    "sad": "сумний сум грустный грусть печаль",
    "angry": "злий злість гнів злой злость гнев",
    "music": "музика пісня музыка песня",
    "excited": "захват схвильований восторг взволнованный",
    "kiss": "поцілунок цілую поцелуй целую",
    "sleep": "сон спати сплю спать",
    "confused": "розгублений спантеличений растерянный смущённый",
    "animal": "тварина животное",
    "cat": "кіт кішка кот кошка",
    "dog": "собака пес",
    "bear": "ведмідь медведь",
    "hug": "обійми обіймати объятия обнять",
    "shrug": "знизати плечима пожать плечами",
    "hide": "сховатися ховатися спрятаться прятаться",
    "surprised": "здивований подив удивлённый удивление",
    "shock": "шок",
    "run": "бігти біг бежать бег",
    "fight": "бійка битися драка драться",
    "wink": "підморгнути подмигнуть",
    "embarrassed": "зніяковілий соромно смущённый стыдно",
    "laugh": "сміх сміятися смех смеяться",
    "smile": "усмішка посмішка улыбка",
    "bye": "бувай до побачення пока до свидания",
    "hello": "привіт вітаю привет здравствуй",
    "sorry": "вибач пробач прости извини",
    "thanks": "дякую спасибо",
    "yes": "так да",
    "no": "ні нет",
    "food": "їжа еда",
    "eat": "їсти їсть есть ест",
    "tired": "втомлений втома уставший усталость",
    "worried": "стурбований тривога обеспокоенный тревога",
    "bored": "нудьга нудно скука скучно",
    "evil": "злий зло злодій злой зло злодей",
    "cool": "круто крутий круто крутой",
    "sunglasses": "окуляри сонцезахисні очки солнечные",
    "flower": "квітка цветок",
    "magic": "магія чари магия волшебство",
    "sparkle": "блиск іскри блеск искры",
    "star": "зірка звезда",
    "rabbit": "кролик заєць кролик заяц",
    "pig": "свиня свинья",
    "fish": "риба рыба",
    "bird": "птах птиця птица",
    "monkey": "мавпа обезьяна",
    "point": "вказати показать",
    "tableflip": "стіл перевернути стол перевернуть",
    "unflip": "повернути стіл вернуть стол",
    "punch": "удар кулак",
    "gun": "пістолет пистолет",
    "sword": "меч",
    "salute": "салют віддати честь отдать честь",
    "nervous": "нервовий нервный",
    "whatever": "байдуже всё равно",
    "blush": "рум'янець червоніти румянец краснеть",
    "drool": "слина слюна",
    "money": "гроші деньги",
    "writing": "писати пишу писать пишу",
    "strong": "сильний сильный",
    "sick": "хворий больной",
    "dead": "мертвий мёртвый мертвый",
    "cheer": "підбадьорити ура подбодрить ура",
    "friends": "друзі друзья",
    "sing": "співати петь",
    "sweat": "піт пот",
    "lenny": "ленні ленни",
    "disapproval": "несхвалення неодобрение",
}


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def cps(s):
    return [ord(c) for c in s]


def no_vs(s):
    return s.replace(VS16, "")


def clean(words):
    """Lowercased, de-duplicated search words, order kept."""
    seen, out = set(), []
    for w in words:
        w = str(w).strip().lower()
        if w and w not in seen:
            seen.add(w)
            out.append(w)
    return out


class Names:
    """CLDR names/keywords for one locale, direct annotations over derived ones."""

    def __init__(self, src, loc):
        base = load_json(src / f"cldr-annotations-{loc}.json")["annotations"]["annotations"]
        derived = load_json(src / f"cldr-derived-{loc}.json")["annotationsDerived"]["annotations"]
        self.table = {**derived, **base}

    def get(self, ch):
        return self.table.get(ch) or self.table.get(no_vs(ch))

    def name(self, ch):
        v = self.get(ch)
        return (v.get("tts") or [""])[0] if v else ""

    def keywords(self, ch):
        v = self.get(ch)
        return list(v.get("default") or []) if v else []


def parse_emoji_test(path):
    """Yield (group, subgroup, emoji, english_name) for fully-qualified entries."""
    group = subgroup = None
    line_re = re.compile(r"^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*(\S+)\s+E\d+\.\d+\s+(.*)$")
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
        elif line.startswith("# subgroup:"):
            subgroup = line.split(":", 1)[1].strip()
        else:
            m = line_re.match(line)
            if m and group != "Component":
                yield group, subgroup, m.group(2), m.group(3)


def build_emoji(src, names):
    groups, items, by_key = [], [], {}
    pending_tones = []

    for group, subgroup, e, en_name in parse_emoji_test(src / "emoji-test.txt"):
        tones_in = [c for c in cps(e) if c in TONES]
        if tones_in:
            pending_tones.append((e, tones_in))
            continue
        if not groups or groups[-1]["name"] != group:
            groups.append({"name": group, "icon": GROUP_ICONS.get(group, e)})
        localized = [names[loc].name(e) or (en_name if loc == "en" else "") for loc in LOCALES]
        words = clean(localized + sum((names[loc].keywords(e) for loc in LOCALES), [])
                      + [en_name, subgroup.replace("-", " ")])
        item = {"e": e, "g": len(groups) - 1, "n": localized, "k": " ".join(words)}
        items.append(item)
        by_key[no_vs(e)] = item

    # Only variants whose modifiers are all the same tone fit a five-swatch picker;
    # mixed pairs (e.g. two people with different tones) are skipped.
    for e, tones_in in pending_tones:
        if len(set(tones_in)) != 1:
            continue
        base = no_vs("".join(c for c in e if ord(c) not in TONES))
        item = by_key.get(base)
        if item is None:
            continue
        item.setdefault("t", [None] * 5)[tones_in[0] - 0x1F3FB] = e

    for item in items:
        if "t" in item and None in item["t"]:
            del item["t"]
    return {"groups": groups, "items": items}


def build_symbols(names, emoji_keys):
    tabs = [{"name": n, "icon": icon} for n, icon, _, _ in SYMBOL_TABS]
    per_tab = [[] for _ in SYMBOL_TABS]
    seen = set()

    def tab_of(cp):
        for i, (_, _, _, ranges) in enumerate(SYMBOL_TABS):
            if any(lo <= cp <= hi for lo, hi in ranges):
                return i
        return None

    def add(ch, t):
        if ch in seen:
            return
        uname = unicodedata.name(ch, "")
        if not uname or unicodedata.category(ch) in ("Mn", "Me", "Cc", "Cf", "Zs", "Co", "Cn"):
            return
        seen.add(ch)
        localized = [names[loc].name(ch) or (uname.lower() if loc == "en" else "") for loc in LOCALES]
        words = clean(localized + sum((names[loc].keywords(ch) for loc in LOCALES), []) + [uname])
        item = {"e": ch, "g": t, "n": localized, "k": " ".join(words)}
        if ch in emoji_keys:
            item["x"] = 1  # also an emoji: insert as text presentation
        per_tab[t].append(item)

    for t, (_, _, common, _) in enumerate(SYMBOL_TABS):
        for ch in common:
            add(ch, t)
    for cp in range(0x20, 0x2C00):
        t = tab_of(cp)
        if t is not None:
            add(chr(cp), t)
    return {"groups": tabs, "items": [it for tab in per_tab for it in tab]}


def build_kaomoji(src):
    raw = load_json(src / "emoticons.json")["emoticons"]
    counts = {}
    for k in raw:
        for tag in k.get("tags") or []:
            counts[tag] = counts.get(tag, 0) + 1
    tabs = [t for t, _ in sorted(counts.items(), key=lambda kv: -kv[1])[:KAOMOJI_TABS]]
    groups = [{"name": KAOMOJI_TAB_NAMES.get(t, t.capitalize()), "icon": ""} for t in tabs]
    groups.append({"name": "More", "icon": ""})

    items, seen = [], set()
    for k in raw:
        s = (k.get("string") or "").strip()
        if not s or s in seen:
            continue
        seen.add(s)
        tags = [t.strip().lower() for t in (k.get("tags") or []) if t and t.strip()]
        g = next((tabs.index(t) for t in tags if t in tabs), len(tabs))
        # Tags can be phrases ("table flip"): translate the phrase and each of its words.
        parts = tags + [w for t in tags for w in re.split(r"[\s_-]+", t)]
        words = clean(parts + [KAOMOJI_TAG_WORDS.get(p, "") for p in parts])
        items.append({"e": s, "g": g, "n": [", ".join(tags), "", ""], "k": " ".join(words)})
    items.sort(key=lambda it: it["g"])
    for i, g in enumerate(groups):
        g["icon"] = next((it["e"] for it in items if it["g"] == i), "")
    return {"groups": groups, "items": items}


def write(name, data):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"{path.relative_to(PLUGIN_DIR)}: {len(data['items'])} items in {len(data['groups'])} groups, "
          f"{path.stat().st_size // 1024} KiB")


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src = pathlib.Path(argv[1])
    names = {loc: Names(src, loc) for loc in LOCALES}
    emoji = build_emoji(src, names)
    keys = {no_vs(it["e"]) for it in emoji["items"]} | {it["e"] for it in emoji["items"]}
    write("emoji.json", emoji)
    write("symbols.json", build_symbols(names, keys))
    write("kaomoji.json", build_kaomoji(src))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
