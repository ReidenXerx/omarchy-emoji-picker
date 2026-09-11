#!/usr/bin/python3
"""python3 tests/helper_test.py -- the emoji-picker helper against real symlinks, oversized
input, hostile KLIPY replies and a stand-in clipboard process.

Never touches the network, the keyring, the clipboard, the desktop or the real state
files: every path constant points into a scratch directory under $XDG_RUNTIME_DIR, and
safe.run / safe.spawn / safe.http_request / notify fail the test unless a test replaces
them with a fake."""
import contextlib
import http.client
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
sys.path.insert(0, str(BIN))
import plugin_safety as safe  # noqa: E402


def load_helper():
    loader = importlib.machinery.SourceFileLoader("emoji_picker_helper", str(BIN / "emoji-picker"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


H = load_helper()
KEY = "TESTKEY_not-a-real-key"


def ok(stdout=b"", code=0, timed_out=False):
    return safe.Result(code, stdout, b"", timed_out, False)


@contextlib.contextmanager
def stdin_bytes(data):
    with mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(data), encoding="utf-8")):
        yield


def quiet():
    stack = contextlib.ExitStack()
    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
    return stack


def forbidden(name):
    def fn(*args, **kwargs):
        raise AssertionError(f"unexpected {name}{args!r}")
    return fn


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="emoji-picker-test-", dir=safe.runtime_dir()))
        os.chmod(self.root, 0o700)
        state = self.root / "state" / "omarchy"
        self.patch(H, "STATE_DIR", state)
        self.patch(H, "STATE_FILE", state / "emoji-picker.json")
        self.patch(H, "CUSTOMER_ID_FILE", state / "emoji-picker-id")
        self.patch(H, "RUNTIME_DIR", self.root / "run" / "omarchy-emoji-picker")
        self.notes = []
        self.patch(H, "notify", lambda summary, body="": self.notes.append(summary))
        for name in ("run", "spawn", "http_request"):
            self.patch(safe, name, forbidden(f"safe.{name}"))
        self.patch(safe, "die_with_parent", lambda *a: None)
        self.addCleanup(shutil.rmtree, self.root, True)

    def patch(self, target, name, value):
        p = mock.patch.object(target, name, value)
        p.start()
        self.addCleanup(p.stop)

    def victim(self, text="keep"):
        path = self.root / "victim"
        path.write_text(text)
        return path


# ------------------------------------------------------------------ state

class State(Sandbox):
    def write(self, blob, args=()):
        with stdin_bytes(blob), quiet():
            return H.cmd_state_write(list(args))

    def test_reads_document_from_stdin(self):
        doc = {"version": 1, "tab": "gif", "tone": 2, "recents": {"emoji:😀": {"c": 1.5, "t": 5}}}
        self.assertEqual(self.write(json.dumps(doc, ensure_ascii=False).encode()), 0)
        self.assertEqual(json.loads(H.STATE_FILE.read_text()), doc)
        self.assertEqual(H.STATE_FILE.stat().st_mode & 0o777, 0o600)
        self.assertEqual(os.listdir(H.STATE_DIR), ["emoji-picker.json"], "no temporary file left behind")

    def test_refuses_document_on_argv(self):
        self.assertEqual(self.write(b"", ['{"tone": 1}']), 2)
        self.assertFalse(H.STATE_FILE.exists())

    def test_rejects_bad_documents(self):
        for blob in (b"[1, 2]", b"{nope", b"\xff\xfe", b"[" * 100000,
                     b'{"a": "' + b"x" * H.STATE_MAX + b'"}',
                     json.dumps({"a": [[[[[[[[[[1]]]]]]]]]]}).encode()):
            self.assertEqual(self.write(blob), 2, blob[:20])
        self.assertFalse(H.STATE_FILE.exists())

    def test_refuses_symlinked_state_file(self):
        victim = self.victim()
        H.STATE_DIR.mkdir(parents=True)
        H.STATE_FILE.symlink_to(victim)
        self.assertEqual(self.write(b'{"tone": 1}'), 1)
        self.assertEqual(victim.read_text(), "keep")
        self.assertTrue(H.STATE_FILE.is_symlink())

    def test_refuses_symlinked_state_dir(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        H.STATE_DIR.parent.mkdir(parents=True)
        H.STATE_DIR.symlink_to(elsewhere)
        self.assertEqual(self.write(b'{"tone": 1}'), 1)
        self.assertEqual(os.listdir(elsewhere), [])

    def test_forget_recents_keeps_the_rest(self):
        H.STATE_DIR.mkdir(parents=True)
        H.STATE_FILE.write_text(json.dumps({"tone": 3, "tab": "symbols", "recents": {"emoji:x": {"c": 1, "t": 1}}}))
        with quiet():
            self.assertEqual(H.cmd_forget_recents([]), 0)
        self.assertEqual(json.loads(H.STATE_FILE.read_text()), {"tone": 3, "tab": "symbols", "recents": {}})
        self.assertEqual(self.notes, ["Recent picks forgotten"])

    def test_forget_recents_survives_garbage_and_refuses_symlinks(self):
        H.STATE_DIR.mkdir(parents=True)
        H.STATE_FILE.write_text("[" * 50000)
        with quiet():
            self.assertEqual(H.cmd_forget_recents([]), 0)
        self.assertEqual(json.loads(H.STATE_FILE.read_text()), {"recents": {}})
        H.STATE_FILE.unlink()
        victim = self.victim('{"recents": {"a": 1}}')
        H.STATE_FILE.symlink_to(victim)
        with quiet():
            self.assertEqual(H.cmd_forget_recents([]), 1)
        self.assertEqual(victim.read_text(), '{"recents": {"a": 1}}')


class CustomerId(Sandbox):
    def test_created_private_and_stable(self):
        first = H.customer_id()
        self.assertRegex(first, H.CUSTOMER_ID_RE)
        self.assertEqual(H.CUSTOMER_ID_FILE.stat().st_mode & 0o777, 0o600)
        self.assertEqual(H.customer_id(), first)

    def test_garbage_replaced(self):
        H.STATE_DIR.mkdir(parents=True)
        H.CUSTOMER_ID_FILE.write_text("not an id")
        value = H.customer_id()
        self.assertRegex(value, H.CUSTOMER_ID_RE)
        self.assertEqual(H.CUSTOMER_ID_FILE.read_text().strip(), value)

    def test_unsafe_file_left_alone(self):
        H.STATE_DIR.mkdir(parents=True)
        victim = self.victim()
        H.CUSTOMER_ID_FILE.symlink_to(victim)
        with quiet():
            a, b = H.customer_id(), H.customer_id()
        self.assertRegex(a, H.CUSTOMER_ID_RE)
        self.assertNotEqual(a, b, "a throwaway id per request, nothing persisted")
        self.assertEqual(victim.read_text(), "keep")
        H.CUSTOMER_ID_FILE.unlink()
        H.CUSTOMER_ID_FILE.write_bytes(b"0" * (H.ID_MAX + 1))
        with quiet():
            H.customer_id()
        self.assertEqual(H.CUSTOMER_ID_FILE.read_bytes(), b"0" * (H.ID_MAX + 1))


# ------------------------------------------------------------------ KLIPY

class Klipy(Sandbox):
    def reply(self, *result, raises=None):
        calls = []

        def fake(url, **kwargs):
            calls.append((url, kwargs))
            if raises:
                raise raises
            return result

        self.patch(safe, "http_request", fake)
        return calls

    def test_success_is_capped_and_goes_to_klipy(self):
        calls = self.reply(200, b'{"result": true, "data": {"data": []}}')
        self.assertEqual(H.klipy_request(KEY, "gifs/search", {"q": "cat"}), {"result": True, "data": {"data": []}})
        url, kwargs = calls[0]
        self.assertTrue(url.startswith(f"https://api.klipy.com/api/v1/{KEY}/gifs/search?"))
        self.assertEqual(kwargs["max_bytes"], 2 * 1024 * 1024)
        self.assertLessEqual(kwargs["timeout"], 12)

    def test_error_statuses(self):
        cases = [((404, b'{"result":false,"errors":{"message":["The provided API key is invalid."]}}'), "bad-key"),
                 ((401, b""), "bad-key"), ((429, b""), "rate-limited"), ((500, b"oops"), "http-500")]
        for result, code in cases:
            self.reply(*result)
            self.assertEqual(H.klipy_request(KEY, "gifs/trending"), {"error": code})

    def test_transport_failures(self):
        for exc, code in ((safe.TooLarge("big"), "bad-reply"), (OSError("down"), "offline"),
                          (http.client.IncompleteRead(b""), "offline"), (safe.UnsafeError("x"), "offline")):
            self.reply(raises=exc)
            self.assertEqual(H.klipy_request(KEY, "gifs/trending"), {"error": code})

    def test_hostile_bodies(self):
        for body in (b"<html>", b"[1]", b"\xff", b"[" * 5000 + b"]" * 5000, b'"' + b"x" * 300000 + b'"'):
            self.reply(200, body)
            self.assertEqual(H.klipy_request(KEY, "gifs/trending"), {"error": "bad-reply"}, body[:10])

    def test_malformed_key_never_sent(self):
        self.assertEqual(H.klipy_request("../../x?y", "gifs/trending"), {"error": "bad-key"})


def gif_item(slug="cat-1", host="static.klipy.com", kind="gif", sizes=None, title="Cat"):
    sizes = sizes or {}
    return {
        "slug": slug, "title": title, "type": kind,
        "file": {s: {k: {"url": f"https://{host}/{slug}/{s}.{k}", "width": 200, "height": 150,
                         "size": sizes.get(s, 1000)} for k in ("gif", "webp")}
                 for s in ("hd", "md", "sm", "xs")},
    }


class Results(unittest.TestCase):
    def test_filters_ads_foreign_hosts_and_bad_slugs(self):
        reply = {"result": True, "data": {"has_next": True, "data": [
            gif_item(), gif_item(slug="ad-1", kind="ad"), gif_item(slug="evil", host="evil.example"),
            gif_item(slug="bad/slug"), "junk", {"slug": "nofile"}, gif_item(slug="lookalike", host="klipy.com.evil.example"),
        ]}}
        out = H.normalize_results(reply)
        self.assertEqual([i["id"] for i in out["items"]], ["cat-1"])
        self.assertTrue(out["hasNext"])
        item = out["items"][0]
        self.assertTrue(item["preview"].endswith("/sm.webp"))
        self.assertTrue(item["url"].endswith("/hd.gif"))
        self.assertEqual((item["w"], item["h"], item["title"]), (200, 150, "Cat"))

    def test_oversized_full_gif_falls_back(self):
        out = H.normalize_results({"data": {"data": [gif_item(sizes={"hd": H.MAX_GIF_BYTES + 1})]}})
        self.assertTrue(out["items"][0]["url"].endswith("/md.gif"))

    def test_garbage_shapes(self):
        for reply in ([], "x", {"data": "x"}, {"data": {"data": {"a": 1}}}, {"data": {"data": [None, 1, []]}}):
            self.assertEqual(H.normalize_results(reply), {"items": [], "hasNext": False})
        self.assertEqual(H.normalize_results({"result": False}), {"error": "bad-reply"})
        self.assertEqual(H.normalize_results({"error": "offline"}), {"error": "offline"})
        weird = gif_item(title=["x"])
        weird["file"]["sm"]["webp"]["width"] = True
        weird["file"]["sm"]["webp"]["height"] = "999999"
        item = H.normalize_results({"data": {"data": [weird]}})["items"][0]
        self.assertEqual((item["w"], item["h"], item["title"]), (1, 1, ""))

    def test_item_count_capped(self):
        many = [gif_item(slug=f"g{i}") for i in range(300)]
        self.assertEqual(len(H.normalize_results({"data": {"data": many}})["items"]), H.MAX_ITEMS)

    def test_trusted_media_url(self):
        good = ["https://klipy.com/a.gif", "https://static.klipy.com/a/b.gif?x=1"]
        bad = ["http://static.klipy.com/a.gif", "https://klipy.com.evil.example/a.gif", "https://evilklipy.com/a",
               "https://klipy.com@evil.example/a", "https://user@static.klipy.com/a", "ftp://klipy.com/a",
               "https://static.klipy.com/a b", "https://static.klipy.com/\n", "https://[::1/", "",
               "https://static.klipy.com/" + "a" * 3000, None]
        for url in good:
            self.assertTrue(H.trusted_media_url(url), url)
        for url in bad:
            self.assertFalse(H.trusted_media_url(url), url)

    def test_file_names_and_pages(self):
        self.assertEqual(H.gif_file_name("a/b..c"), "a_b__c.gif")
        self.assertEqual(H.gif_file_name(""), "gif.gif")
        long_name = H.gif_file_name("x" * 200)
        self.assertEqual(len(long_name), 84)
        for slug in ("a/b..c", "", "x" * 200, "ünï~cødé"):
            self.assertRegex(H.gif_file_name(slug), H.GIF_NAME_RE)
        self.assertEqual([H.page_arg(v) for v in ("3", "99999", "-1", "0", "abc", "", None)], [3, 1, 1, 1, 1, 1, 1])


class Listing(Sandbox):
    def test_no_key(self):
        self.patch(H, "read_key", lambda: None)
        self.assertEqual(H.gif_listing("search", "cat", 2), {"error": "no-key", "q": "cat", "page": 2})

    def test_search_prints_echoed_results(self):
        self.patch(H, "read_key", lambda: KEY)
        calls = []

        def fake(url, **kwargs):
            calls.append(url)
            return 200, json.dumps({"result": True, "data": {"data": [gif_item()], "has_next": False}}).encode()

        self.patch(safe, "http_request", fake)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(H.cmd_gif(["search", "  cat  ", "2"]), 0)
        printed = json.loads(out.getvalue())
        self.assertEqual((printed["q"], printed["page"], len(printed["items"])), ("cat", 2, 1))
        self.assertIn("customer_id=", calls[0])
        self.assertRegex(H.CUSTOMER_ID_FILE.read_text().strip(), H.CUSTOMER_ID_RE)

    def test_deadline_reports_offline(self):
        self.patch(H, "read_key", lambda: KEY)

        def slow(url, **kwargs):
            time.sleep(5)

        self.patch(safe, "http_request", slow)
        self.patch(H, "SEARCH_DEADLINE", 1)
        start = time.monotonic()
        self.assertEqual(H.gif_listing("trending", "", 1)["error"], "offline")
        self.assertLess(time.monotonic() - start, 3)


# ------------------------------------------------------------------ keyring

class Keyring(Sandbox):
    def setUp(self):
        super().setUp()
        self.patch(safe, "has_tool", lambda name: True)
        self.calls = []

    def fake_run(self, answers):
        def run(argv, **kwargs):
            self.calls.append((list(argv), kwargs))
            return answers(argv)
        self.patch(safe, "run", run)

    def test_lookup_is_bounded_and_validated(self):
        self.fake_run(lambda argv: ok(KEY.encode() + b"\n"))
        self.assertEqual(H.read_key(), KEY)
        argv, kwargs = self.calls[0]
        self.assertEqual(argv[:2], ["secret-tool", "lookup"])
        self.assertEqual((kwargs["timeout"], kwargs["max_output"]), (5, 4096))
        for answer in (ok(b"not a key!"), ok(KEY.encode(), code=1), ok(KEY.encode(), timed_out=True), ok(b"")):
            self.fake_run(lambda argv, a=answer: a)
            self.assertIsNone(H.read_key())

    def test_set_sends_key_on_stdin_only(self):
        def answers(argv):
            return ok(KEY.encode() + b"\n") if argv[0] == "zenity" else ok()
        self.fake_run(answers)
        self.patch(H, "klipy_request", lambda *a, **k: {"result": True})
        with stdin_bytes(b""), quiet():
            self.assertEqual(H.cmd_key(["set"]), 0)
        zenity, store = self.calls
        self.assertEqual(zenity[1]["timeout"], 300)
        self.assertEqual(store[0][:2], ["secret-tool", "store"])
        self.assertEqual(store[1]["input"], KEY)
        for argv, _ in self.calls:
            self.assertFalse(any(KEY in str(a) for a in argv), argv)

    def test_rejected_or_malformed_key_not_stored(self):
        self.fake_run(lambda argv: ok(KEY.encode()) if argv[0] == "zenity" else ok())
        self.patch(H, "klipy_request", lambda *a, **k: {"error": "bad-key"})
        with stdin_bytes(b""), quiet():
            self.assertEqual(H.cmd_key(["set"]), 1)
        self.assertEqual([c[0][0] for c in self.calls], ["zenity"])
        self.calls.clear()
        self.fake_run(lambda argv: ok(b"short") if argv[0] == "zenity" else ok())
        self.patch(H, "klipy_request", forbidden("klipy_request"))
        with stdin_bytes(b""), quiet():
            self.assertEqual(H.cmd_key(["set"]), 1)


# ------------------------------------------------------------------ GIF files

class GifFiles(Sandbox):
    def fake_download(self, *result, raises=None):
        calls = []

        def fake(url, **kwargs):
            calls.append((url, kwargs))
            if raises:
                raise raises
            return result

        self.patch(safe, "http_request", fake)
        return calls

    def age(self, path, seconds):
        t = time.time() - seconds
        os.utime(path, (t, t), follow_symlinks=False)

    def test_download_private_file(self):
        calls = self.fake_download(200, b"GIF89a" + b"x" * 10)
        path = H.download("cat-1", "https://static.klipy.com/cat.gif")
        self.assertEqual(path, H.RUNTIME_DIR / "cat-1.gif")
        self.assertEqual(path.read_bytes(), b"GIF89a" + b"x" * 10)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(H.RUNTIME_DIR.stat().st_mode & 0o777, 0o700)
        self.assertEqual(calls[0][1]["max_bytes"], 12 * 1024 * 1024)
        self.assertEqual(os.listdir(H.RUNTIME_DIR), ["cat-1.gif"])

    def test_download_failures(self):
        for result, raises in (((200, b"<html>"), None), ((404, b"GIF89a"), None), ((), safe.TooLarge("big")),
                               ((), OSError("down")), ((), http.client.IncompleteRead(b""))):
            self.fake_download(*result, raises=raises)
            with quiet():
                self.assertIsNone(H.download("cat-1", "https://static.klipy.com/cat.gif"))
        self.assertFalse((H.RUNTIME_DIR / "cat-1.gif").exists())

    def test_download_refuses_symlinks(self):
        self.fake_download(200, b"GIF89a")
        victim = self.victim()
        safe.ensure_dir(H.RUNTIME_DIR)
        (H.RUNTIME_DIR / "cat-1.gif").symlink_to(victim)
        with quiet():
            self.assertIsNone(H.download("cat-1", "https://static.klipy.com/cat.gif"))
        self.assertEqual(victim.read_text(), "keep")
        (H.RUNTIME_DIR / "cat-1.gif").unlink()
        H.RUNTIME_DIR.rmdir()
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        H.RUNTIME_DIR.symlink_to(elsewhere)
        with quiet():
            self.assertIsNone(H.download("cat-1", "https://static.klipy.com/cat.gif"))
        self.assertEqual(os.listdir(elsewhere), [])

    def test_sweep_removes_only_old_picker_gifs(self):
        safe.ensure_dir(H.RUNTIME_DIR)
        victim = self.victim()
        d = H.RUNTIME_DIR
        (d / "old.gif").write_bytes(b"GIF89a")
        (d / "new.gif").write_bytes(b"GIF89a")
        (d / "notes.txt").write_text("x")
        (d / "dir.gif").mkdir()
        (d / "link.gif").symlink_to(victim)
        (d / "bad name.gif").write_text("x")
        for name in ("old.gif", "notes.txt", "dir.gif", "link.gif", "bad name.gif"):
            self.age(d / name, H.GIF_FILE_TTL_SEC + 60)
        H.sweep_old_files()
        self.assertEqual(sorted(os.listdir(d)), ["bad name.gif", "dir.gif", "link.gif", "new.gif", "notes.txt"])
        self.assertEqual(victim.read_text(), "keep")

    def test_forget_file(self):
        safe.ensure_dir(H.RUNTIME_DIR)
        old, fresh = H.RUNTIME_DIR / "old.gif", H.RUNTIME_DIR / "fresh.gif"
        old.write_bytes(b"GIF89a")
        fresh.write_bytes(b"GIF89a")
        self.age(old, H.GIF_FILE_TTL_SEC + 1)
        self.assertTrue(H.forget_file("old.gif"))
        self.assertFalse(H.forget_file("fresh.gif"), "re-pasted within the TTL: its own timer removes it")
        self.assertTrue(fresh.exists())
        (H.RUNTIME_DIR / "link.gif").symlink_to(self.victim())
        self.age(H.RUNTIME_DIR / "link.gif", H.GIF_FILE_TTL_SEC + 1)
        self.assertFalse(H.forget_file("link.gif"))
        for name in ("../victim", "x.txt", ".x.gif", ""):
            with self.assertRaises(safe.UnsafeError):
                H.forget_file(name)

    def test_gif_forget_command(self):
        with mock.patch.object(H.time, "sleep", forbidden("sleep")), quiet():
            self.assertEqual(H.cmd_gif(["forget", "../../victim"]), 2)
            self.assertEqual(H.cmd_gif(["forget"]), 2)
        safe.ensure_dir(H.RUNTIME_DIR)
        path = H.RUNTIME_DIR / "cat-1.gif"
        path.write_bytes(b"GIF89a")
        slept = []
        with mock.patch.object(H.time, "sleep", slept.append):
            self.age(path, H.GIF_FILE_TTL_SEC)
            self.assertEqual(H.cmd_gif(["forget", "cat-1.gif"]), 0)
        self.assertEqual(slept, [H.GIF_FILE_TTL_SEC])
        self.assertFalse(path.exists())

    def test_forget_later_spawns_helper_without_shell(self):
        calls = []
        self.patch(safe, "spawn", lambda argv, **kw: calls.append((argv, kw)))
        H.forget_later("cat-1.gif")
        self.assertEqual(calls, [(["/usr/bin/python3", str(BIN / "emoji-picker"), "gif", "forget", "cat-1.gif"],
                                  {"timeout": H.GIF_FILE_TTL_SEC + 30})])


class GifSend(Sandbox):
    def setUp(self):
        super().setUp()
        self.pasted, self.forgotten, self.shared = [], [], []
        self.patch(H, "paste", lambda payload, mime, hold_sec=0.2: self.pasted.append((payload, mime)) or 0)
        self.patch(H, "forget_later", self.forgotten.append)
        self.patch(H, "report_share", self.shared.append)

    def test_insert_pastes_file_uri(self):
        self.patch(H, "download", lambda slug, url: H.RUNTIME_DIR / "cat-1.gif")
        self.assertEqual(H.cmd_gif(["insert", "cat-1", "https://static.klipy.com/cat.gif"]), 0)
        self.assertEqual(self.pasted, [((H.RUNTIME_DIR / "cat-1.gif").as_uri() + "\r\n", "text/uri-list")])
        self.assertEqual((self.forgotten, self.shared), (["cat-1.gif"], ["cat-1"]))

    def test_failed_download_types_link(self):
        self.patch(H, "download", lambda slug, url: None)
        self.assertEqual(H.cmd_gif(["insert", "cat-1", "https://static.klipy.com/cat.gif"]), 0)
        self.assertEqual(self.pasted, [("https://static.klipy.com/cat.gif", "text/plain;charset=utf-8")])
        self.assertEqual(self.forgotten, [])
        self.assertEqual(len(self.notes), 1)

    def test_link(self):
        self.patch(H, "download", forbidden("download"))
        self.assertEqual(H.cmd_gif(["link", "cat-1", "https://static.klipy.com/cat.gif"]), 0)
        self.assertEqual(self.pasted, [("https://static.klipy.com/cat.gif", "text/plain;charset=utf-8")])

    def test_refuses_untrusted_input(self):
        self.patch(H, "download", forbidden("download"))
        with quiet():
            self.assertEqual(H.cmd_gif(["insert", "cat-1", "https://evil.example/cat.gif"]), 1)
            self.assertEqual(H.cmd_gif(["insert", "../x", "https://static.klipy.com/cat.gif"]), 1)
            self.assertEqual(H.cmd_gif(["link", "cat-1", "file:///etc/passwd"]), 1)
        self.assertEqual((self.pasted, self.shared), ([], []))


# ------------------------------------------------------------------ typing

COPIER = """
import os, sys, time
data = sys.stdin.buffer.read()
with open(sys.argv[1] + ".part", "wb") as f:
    f.write(b"\\n".join([str(os.getpid()).encode(), os.environ.get("PATH", "").encode(), sys.argv[2].encode(), data]))
os.rename(sys.argv[1] + ".part", sys.argv[1])
time.sleep(30)
"""


class Paste(Sandbox):
    def setUp(self):
        super().setUp()
        self.out = self.root / "copier-out"
        self.typed = []

    def stand_in(self, argv=None):
        self.patch(H, "copier_argv", lambda mime: argv or ["/usr/bin/python3", "-c", COPIER, str(self.out), mime])

    def fake_wtype(self, result):
        def run(argv, **kwargs):
            deadline = time.monotonic() + 5
            while not self.out.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.typed.append((list(argv), kwargs))
            return result
        self.patch(safe, "run", run)

    def test_payload_on_stdin_and_copier_reaped(self):
        self.stand_in()
        self.fake_wtype(ok())
        start = time.monotonic()
        with quiet():
            self.assertEqual(H.paste("héllo 👋", "text/plain;charset=utf-8", hold_sec=0), 0)
        self.assertLess(time.monotonic() - start, 5)
        pid, path, mime, data = self.out.read_bytes().split(b"\n", 3)
        self.assertEqual((path, mime, data.decode()), (b"/usr/bin", b"text/plain;charset=utf-8", "héllo 👋"))
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid), 0)
        self.assertEqual(self.typed[0][0], ["wtype", "-M", "shift", "-k", "Insert", "-m", "shift"])
        self.assertLessEqual(self.typed[0][1]["timeout"], 5)

    def test_wtype_failure_still_withdraws_clipboard(self):
        self.stand_in()
        self.fake_wtype(ok(code=1))
        with quiet():
            self.assertEqual(H.paste("x", "text/plain", hold_sec=0), 1)
        pid = int(self.out.read_bytes().split(b"\n", 1)[0])
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_copier_that_dies_skips_typing(self):
        self.stand_in(["/usr/bin/true"])
        self.patch(safe, "run", forbidden("wtype"))
        with quiet():
            self.assertEqual(H.paste("x", "text/plain", hold_sec=0), 1)


class TextCommands(Sandbox):
    def test_insert_reads_stdin(self):
        pasted = []
        self.patch(H, "paste", lambda payload, mime, hold_sec=0.2: pasted.append(payload) or 0)
        for blob, expected in (("¯\\_(ツ)_/¯".encode(), "¯\\_(ツ)_/¯"), (b"x\n", "x"), (b"a\n\n", "a\n")):
            with stdin_bytes(blob):
                self.assertEqual(H.cmd_insert([]), 0)
            self.assertEqual(pasted[-1], expected)
        with quiet():
            for blob in (b"", b"\n", b"x" * (H.TEXT_MAX + 1), b"\xff"):
                with stdin_bytes(blob):
                    self.assertEqual(H.cmd_insert([]), 2, blob[:10])

    def test_copy_uses_bounded_spawn_with_stdin(self):
        calls = []

        class Done:
            def wait(self, timeout=None):
                return 0

        self.patch(safe, "spawn", lambda argv, **kw: calls.append((argv, kw)) or Done())
        with stdin_bytes("→".encode()):
            self.assertEqual(H.cmd_copy([]), 0)
        argv, kw = calls[0]
        self.assertEqual(argv, ["wl-copy", "--type", "text/plain;charset=utf-8"])
        self.assertEqual(kw["input"], "→")
        self.assertLessEqual(kw["timeout"], 10)

    def test_state_write_and_unknown_commands_via_main(self):
        with quiet():
            self.assertEqual(H.main(["emoji-picker", "nope"]), 2)
            self.assertEqual(H.main(["emoji-picker", "gif", "bogus"]), 2)


# ------------------------------------------------------------------ static rules

class Static(unittest.TestCase):
    def source(self, rel):
        return (ROOT / rel).read_text(encoding="utf-8")

    def test_shebangs(self):
        for rel in ("bin/emoji-picker", "bin/emoji-picker-menu-install", "tools/build-data.py"):
            self.assertEqual(self.source(rel).splitlines()[0], "#!/usr/bin/python3", rel)

    def test_helper_has_no_shell_or_path_lookup(self):
        src = self.source("bin/emoji-picker")
        for needle in ("shutil", "shell=True", "os.system", "os.popen", '"sh"', "/usr/bin/env",
                       "urllib.request", ".read_text(", ".write_text(", ".write_bytes(", "json.loads("):
            self.assertNotIn(needle, src, needle)
        self.assertIsNone(re.search(r"(?<![\w.])open\(|os\.open\(", src), "files only through plugin_safety")
        self.assertEqual(src.count("subprocess.Popen("), 1, "only the paste copier, which is killed after use")
        self.assertNotIn("safe._", src)

    def test_qml_runs_helper_under_system_python(self):
        src = self.source("EmojiPicker.qml")
        self.assertIn('readonly property string python: "/usr/bin/python3"', src)
        uses = [m.start() for m in re.finditer(r"root\.helper\b", src)]
        self.assertGreater(len(uses), 3)
        for at in uses:
            self.assertEqual(src[at - 13:at], "root.python, ", src[at - 60:at + 20])
        self.assertNotIn("state-write\", JSON", src)

    def test_menu_actions_use_system_python(self):
        src = self.source("menu.jsonc")
        actions = re.findall(r'"action": "([^"]*@PLUGIN_BIN@[^"]*)"', src)
        self.assertEqual(len(actions), src.count("@PLUGIN_BIN@/"))
        self.assertEqual(len(actions), 3)
        for action in actions:
            self.assertRegex(action, r"^/usr/bin/python3 @PLUGIN_BIN@/emoji-picker (gif key (set|clear)|forget-recents)$")

    def test_vendored_library_matches_master(self):
        master = pathlib.Path(safe.home_dir()) / "Projects/omarchy-plugin-safety/plugin_safety.py"
        if not master.exists():
            self.skipTest("master copy not present")
        self.assertEqual((BIN / "plugin_safety.py").read_bytes(), master.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=1)
