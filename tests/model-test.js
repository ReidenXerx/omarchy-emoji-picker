#!/usr/bin/env node
// node tests/model-test.js — runs EmojiModel.js against the real data files.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const root = path.resolve(__dirname, "..")
const source = fs.readFileSync(path.join(root, "EmojiModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.runInNewContext(source + "\nthis.M = { fold, prepare, groups, tokens, search, score, frecency, inGroup, groupStarts, withTone, textFor, normalizeState, recordUse, recentItems, forget, gifItem, gifCard, parseGifReply, appendGifs, gifErrorText, clamp, move, moveRow, HALF_LIFE_MS, MAX_RECENTS }", M)
// Values made inside the vm context have that context's Array/Object prototypes, which
// deepStrictEqual treats as different. Compare plain copies instead.
const plain = v => JSON.parse(JSON.stringify(v))
const _deep = assert.deepStrictEqual
assert.deepStrictEqual = (a, b, msg) => _deep(plain(a), plain(b), msg)

const E = M.M

const load = name => JSON.parse(fs.readFileSync(path.join(root, "data", name), "utf8"))
const emoji = E.prepare(load("emoji.json"), "emoji")
const symbols = E.prepare(load("symbols.json"), "symbols")
const kaomoji = E.prepare(load("kaomoji.json"), "kaomoji")
const NOW = Date.UTC(2026, 8, 11)

let passed = 0
const failures = []
function test(name, fn) {
  try { fn(); passed++ } catch (e) { failures.push(name + "\n    " + e.message) }
}
const top = (items, q, n = 5) => E.search(items, q, n, null, NOW).map(i => i.e)

test("data loads", () => {
  assert.ok(emoji.length > 1800, "emoji " + emoji.length)
  assert.ok(symbols.length > 1500, "symbols " + symbols.length)
  assert.ok(kaomoji.length > 1500, "kaomoji " + kaomoji.length)
})

test("empty query keeps data order", () => {
  assert.deepStrictEqual(top(emoji, "", 3), emoji.slice(0, 3).map(i => i.e))
})

test("english name prefix", () => assert.ok(top(emoji, "grinning").includes("😀")))
test("ukrainian name", () => assert.ok(top(emoji, "серце", 20).includes("❤️")))
test("russian name", () => assert.ok(top(emoji, "сердце", 20).includes("❤️")))
test("russian ё folds to е", () => assert.ok(top(emoji, "слезы", 10).includes("😂")))
test("flag by country, uk", () => assert.strictEqual(top(emoji, "україна", 1)[0], "🇺🇦"))
test("flag by country, en", () => assert.ok(top(emoji, "ukraine", 3).includes("🇺🇦")))
test("zwj sequence is findable", () => assert.ok(top(emoji, "technologist", 10).includes("👩‍💻")))
test("multi-word query needs every word", () => {
  const r = E.search(emoji, "red heart", 50, null, NOW)
  assert.ok(r.length > 0 && r.every(i => i.hay.includes("red") && i.hay.includes("heart")))
  assert.strictEqual(r[0].e, "❤️")
})
test("exact name wins over prefix", () => assert.strictEqual(top(emoji, "cat", 1)[0], "🐈"))
test("no match gives nothing", () => assert.deepStrictEqual(top(emoji, "zzqqxx"), []))
test("single letter does not substring-match", () => {
  assert.ok(E.search(emoji, "q", 5000, null, NOW).every(i => /(^|[\s,:;|(«"'\-])q/.test(i.folded.join(" ") + " " + i.hay)))
})

test("symbol by english name", () => assert.ok(top(symbols, "check mark", 5).includes("✓")))
test("symbol by ukrainian name", () => assert.ok(top(symbols, "стрілка праворуч", 5).includes("→")))
test("currency euro in russian", () => assert.ok(top(symbols, "евро", 3).includes("€")))
test("hryvnia sign", () => assert.ok(top(symbols, "hryvnia", 3).includes("₴")))
test("command key", () => assert.ok(top(symbols, "place of interest", 3).includes("⌘")))
test("symbol tabs start with the common ones", () => {
  assert.strictEqual(E.inGroup(symbols, 0)[0].e, "→")
  assert.strictEqual(E.inGroup(symbols, 4)[0].e, "⌘")
})
test("symbol that is also emoji gets VS15", () => {
  const it = symbols.find(i => i.x)
  assert.ok(it, "no flagged symbol")
  assert.strictEqual(E.textFor(it, 0), it.e + "︎")
})

test("kaomoji english tag", () => assert.ok(E.search(kaomoji, "table flip", 5, null, NOW).length === 5))
test("kaomoji ukrainian tag", () => assert.ok(E.search(kaomoji, "кіт", 5, null, NOW).length > 0))
test("kaomoji russian tag", () => assert.ok(E.search(kaomoji, "грусть", 5, null, NOW).length > 0))

test("skin tone applies", () => {
  const wave = emoji.find(i => i.e === "👋")
  assert.strictEqual(E.textFor(wave, 0), "👋")
  assert.strictEqual(E.textFor(wave, 3), "👋🏽")
})
test("tone ignored where unsupported", () => {
  const ua = emoji.find(i => i.e === "🇺🇦")
  assert.strictEqual(E.textFor(ua, 4), "🇺🇦")
})

test("recordUse counts and stamps", () => {
  let r = E.recordUse({}, "emoji:😂", NOW)
  r = E.recordUse(r, "emoji:😂", NOW)
  assert.strictEqual(r["emoji:😂"].c, 2)
  assert.strictEqual(r["emoji:😂"].t, NOW)
})
test("recordUse does not mutate its input", () => {
  const before = { "emoji:😀": { c: 1, t: NOW } }
  E.recordUse(before, "emoji:😂", NOW)
  assert.deepStrictEqual(Object.keys(before), ["emoji:😀"])
})
test("old use decays by half-life", () => {
  const f = E.frecency({ c: 4, t: NOW - E.HALF_LIFE_MS }, NOW)
  assert.ok(Math.abs(f - 2) < 1e-9, String(f))
})
test("recents are capped", () => {
  let r = {}
  for (let i = 0; i < E.MAX_RECENTS + 20; i++) r = E.recordUse(r, "k:" + i, NOW + i)
  assert.strictEqual(Object.keys(r).length, E.MAX_RECENTS)
  assert.ok(r["k:" + (E.MAX_RECENTS + 19)], "newest kept")
})
test("recentItems orders by frecency and resolves", () => {
  const byKey = {}
  for (const it of emoji) byKey[it.key] = it
  let r = E.recordUse({}, "emoji:😀", NOW - 1000)
  r = E.recordUse(r, "emoji:😂", NOW)
  r = E.recordUse(r, "emoji:😂", NOW)
  r = E.recordUse(r, "emoji:gone", NOW)
  assert.deepStrictEqual(E.recentItems(r, byKey, NOW, 10).map(i => i.e), ["😂", "😀"])
})
test("recent GIFs come back from their stored card", () => {
  const card = { id: "abc", title: "cat", preview: "https://x/p.webp", url: "https://x/f.gif", w: 200, h: 100 }
  const r = E.recordUse({}, "gif:abc", NOW, { gif: card })
  const items = E.recentItems(r, {}, NOW, 10)
  assert.strictEqual(items[0].kind, "gif")
  assert.deepStrictEqual(E.gifCard(items[0]), card)
})
test("recents boost but never beat a better match", () => {
  const r = E.recordUse({}, "emoji:😿", NOW)
  const first = E.search(emoji, "cat", 1, r, NOW)[0].e
  assert.strictEqual(first, "🐈")
})
test("forget removes one", () => {
  const r = E.forget({ a: { c: 1, t: 1 }, b: { c: 1, t: 1 } }, "a")
  assert.deepStrictEqual(Object.keys(r), ["b"])
})

test("normalizeState rejects junk", () => {
  assert.deepStrictEqual(E.normalizeState(null), { tone: 0, tab: "emoji", recents: {} })
  const s = E.normalizeState({ tone: 9, tab: "nope", recents: { a: { c: 1, t: 5 }, b: { c: "x" }, c: null } })
  assert.strictEqual(s.tone, 0)
  assert.strictEqual(s.tab, "emoji")
  assert.deepStrictEqual(Object.keys(s.recents), ["a"])
})
test("normalizeState keeps a valid tone, tab and gif cards", () => {
  const s = E.normalizeState({ tone: 2, tab: "gif", recents: { "gif:1": { c: 1, t: 5, gif: { id: "1" } } } })
  assert.strictEqual(s.tone, 2)
  assert.strictEqual(s.tab, "gif")
  assert.strictEqual(s.recents["gif:1"].gif.id, "1")
})

test("parseGifReply keeps only complete items and echoes the request", () => {
  const raw = JSON.stringify({ q: "cat", page: 2, items: [
    { id: "a", title: "hi", preview: "p", url: "u", w: 10, h: 5 },
    { id: "b", preview: "p" },
  ], hasNext: true })
  const r = E.parseGifReply(raw)
  assert.strictEqual(r.error, "")
  assert.strictEqual(r.items.length, 1)
  assert.strictEqual(r.hasNext, true)
  assert.strictEqual(r.q, "cat")
  assert.strictEqual(r.page, 2)
})
test("parseGifReply surfaces errors", () => {
  const nokey = E.parseGifReply('{"error":"no-key","q":"","page":1}')
  assert.strictEqual(nokey.error, "no-key")
  assert.strictEqual(nokey.q, "")
  const junk = E.parseGifReply("not json")
  assert.strictEqual(junk.error, "bad-reply")
  assert.strictEqual(junk.q, null)
  assert.ok(E.gifErrorText("no-key").includes("KLIPY"))
  assert.ok(E.gifErrorText("weird").includes("weird"))
})
test("appendGifs skips repeats", () => {
  const a = [E.gifItem({ id: "1" }), E.gifItem({ id: "2" })]
  const b = [E.gifItem({ id: "2" }), E.gifItem({ id: "3" })]
  assert.deepStrictEqual(E.appendGifs(a, b).map(g => g.id), ["1", "2", "3"])
})

test("grid movement clamps", () => {
  assert.strictEqual(E.move(0, -1, 10), 0)
  assert.strictEqual(E.move(9, 1, 10), 9)
  assert.strictEqual(E.moveRow(3, 1, 8, 10), 9)
  assert.strictEqual(E.moveRow(3, -1, 8, 10), 0)
  assert.strictEqual(E.clamp(5, 0), 0)
})
test("groupStarts finds each group's first index", () => {
  const starts = E.groupStarts(emoji)
  assert.strictEqual(starts[0], 0)
  assert.strictEqual(emoji[starts[8]].g, 8)
})

console.log(`${passed} passed, ${failures.length} failed`)
for (const f of failures) console.log("  FAIL " + f)
process.exit(failures.length ? 1 : 0)
