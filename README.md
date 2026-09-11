# Emoji picker

An [Omarchy](https://omarchy.org) overlay for **emoji, symbols, kaomoji and GIFs**. Whatever
you pick is typed straight into the app you were using.

Search matches **English, Ukrainian and Russian** names at once, so `heart`, `серце` and
`сердце` all find ❤️. The picker also remembers what you use and keeps your skin tone.

![overlay](https://img.shields.io/badge/omarchy-overlay-blue)

## Install

```bash
omarchy plugin add https://github.com/ReidenXerx/omarchy-emoji-picker.git --enable
```

Bind it to a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + PERIOD", "Emoji picker", "omarchy-shell shell toggle reidenxerx.emoji-picker '{}'")

-- or take over the built-in picker's key:
hl.unbind("SUPER + CTRL + E")
o.bind("SUPER + CTRL + E", "Emoji picker", "omarchy-shell shell toggle reidenxerx.emoji-picker '{}'")
```

To add its entries to the Omarchy menu as well:

```bash
~/.config/omarchy/plugins/reidenxerx.emoji-picker/bin/emoji-picker-menu-install
```

It needs `wl-copy` and `wtype` (both in Omarchy's default set). GIF search also needs
`secret-tool`, which comes with gnome-keyring.

## Use

| key | does |
|---|---|
| type | search the current tab |
| `←` `→` `↑` `↓`, `PgUp` `PgDn` | move |
| `Enter` | type the selection into the app underneath |
| `Shift` + `Enter` | copy it instead |
| `Tab`, `Shift` + `Tab`, `Ctrl` + `1`–`4` | switch between Emoji, Symbols, Kaomoji and GIFs |
| `Ctrl` + `←` `→` | jump between groups (smileys, animals, arrows…) |
| `Alt` + `0`–`5` | skin tone: default, then light to dark |
| `Del` | forget a recent pick |
| `Esc` | clear the search, then close |
| click, right-click | type, copy |

Each tab opens with what you used most recently. The ranking favours what you pick
often, and a burst of use fades over a few weeks instead of sticking forever.

When a search finds nothing on the current tab but something on another, the picker
switches there. The tab labels show how many matches each one has.

### Typing, not just copying

The picker types the way Omarchy's own emoji picker does. The text goes on the
clipboard **marked sensitive**, so clipboard history skips it; `Shift+Insert` pastes it,
and the clipboard is released straight after. Unlike simulated key presses, this delivers
flags, skin tones, joined sequences like 👩🏽‍💻 and kaomoji exactly, whatever keyboard
layout is active.

Symbols that also exist as emoji (☺, ✈, ❤) are sent with a text presentation selector,
so they arrive as a plain glyph instead of turning into a colour emoji.

## GIFs

GIF search is powered by [KLIPY](https://klipy.com). Tenor closed its API to new apps in
2026, and KLIPY is the free replacement built by Tenor's founders. It needs a **free API
key of your own**:

1. Sign up at [partner.klipy.com](https://partner.klipy.com) and create a key under
   **API Keys**.
2. Press `Ctrl` + `K` in the picker, or run `bin/emoji-picker gif key set`, and paste it.

The key is stored in your **keyring** (libsecret), checked against KLIPY before it is
saved, and only ever sent to KLIPY. It is never written to a file, shown, or passed on a
command line. A test key allows 100 searches an hour; request production access in the
KLIPY panel if that is not enough.

`Enter` pastes a GIF **as a file**, the way a file manager copies one. Chat apps
(Telegram, Discord, browsers) then attach the actual animation. `Alt` + `Enter` types the
GIF's link instead, which also embeds in most chats.

KLIPY's terms do not allow keeping their files. A pasted GIF lives in
`$XDG_RUNTIME_DIR/omarchy-emoji-picker/` (RAM, cleared on logout) and is deleted after ten
minutes. Recent GIFs are remembered by link only.

KLIPY asks for a stable per-user id. The picker generates a random one per install
(`~/.local/state/omarchy/emoji-picker-id`); nothing about you is sent.

## Where things live

| file | holds |
|---|---|
| `~/.local/state/omarchy/emoji-picker.json` | recent picks, skin tone, last tab |
| `~/.local/state/omarchy/emoji-picker-id` | the random KLIPY user id |
| keyring, `service=omarchy-emoji-picker` | the KLIPY API key |

## From the command line

```bash
emoji-picker open                  # show the picker
emoji-picker insert "¯\_(ツ)_/¯"   # type text into the focused app
emoji-picker copy "→"              # just copy it
emoji-picker forget-recents
emoji-picker gif key set | clear | status
emoji-picker gif search "cat" | jq '.items[0]'
```

## Menu entries

A plugin cannot register menu routes itself, because Omarchy builds its menu from its
own file plus one user file. Opt in with:

```bash
bin/emoji-picker-menu-install          # add them
bin/emoji-picker-menu-install remove   # take them out
bin/emoji-picker-menu-install print    # just show the snippet
```

This adds *Open the picker*, *Search GIFs*, *Set / Remove the GIF search key* and
*Forget recent picks*. The installer writes only between its own marker comments in
`~/.config/omarchy/extensions/omarchy-menu.jsonc` and leaves the rest of that file
untouched. It is safe to re-run, and it rolls back rather than leaving the file
unparseable, because a malformed menu file silently disables **every** user entry.

## Data

`data/` is generated by `tools/build-data.py` from Unicode's `emoji-test.txt` (Emoji
16.0), the CLDR annotations for en/uk/ru, and
[emoticon-data](https://github.com/w33ble/emoticon-data) for kaomoji. Sources, revisions
and licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

```bash
node tests/model-test.js    # search, ranking, recents, GIF parsing
```

## Remove

```bash
bin/emoji-picker-menu-install remove
bin/emoji-picker gif key clear
omarchy plugin remove reidenxerx.emoji-picker
rm -f ~/.local/state/omarchy/emoji-picker.json ~/.local/state/omarchy/emoji-picker-id
```

Also remove any key binding you added. The plugin owns no daemon, and the GIF files it
pastes are deleted on their own.

## License

MIT for the code. The data keeps its own licenses, listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
