#!/usr/bin/python3 -I
"""plasma-type -- put text into the app in front, on KDE Plasma.

  plasma-type [--terminal | --auto] [--keep-clipboard] < text
  plasma-type --copy-only < text          only put it on the clipboard
  plasma-type --which                     print the window in front's class and desktop file

--auto asks KWin which window is in front (through a one-line KWin script, as kdotool does) and uses
Ctrl+Shift+V when it is a terminal.

Plasma's compositor offers no virtual keyboard to ordinary programs (wtype cannot work there), so this does what
a person would: the text goes onto the clipboard (through Klipper), the paste keystroke is sent through the
desktop's RemoteDesktop portal -- Ctrl+Shift+V for a terminal, Ctrl+V for everything else -- and the clipboard
you had is put back a moment later unless --keep-clipboard is given.

The first time, Plasma asks whether this may control the keyboard; the answer is remembered with the portal's
restore token, kept in $XDG_STATE_HOME/plasma-type/token (0600), so it does not ask again.

Text comes on stdin only, never in arguments, and at most 64 KB of it.
"""
from __future__ import annotations

import json
import os
import secrets
import stat
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

TEXT_MAX = 64 * 1024
PORTAL = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
RD = "org.freedesktop.portal.RemoteDesktop"
KEYBOARD = 1
PERSIST_UNTIL_REVOKED = 2
# evdev key codes
CTRL, SHIFT, KEY_V = 29, 42, 47
RESTORE_AFTER = 0.8
TIMEOUT = 60            # seconds to wait for a portal answer, the first-time question included


# Window classes and desktop files of terminals, matched as substrings, lowered: they paste with Ctrl+Shift+V,
# because Ctrl+V is a control character to the program inside them.
TERMINALS = ("konsole", "yakuake", "foot", "kitty", "alacritty", "wezterm", "ghostty", "warp", "gnome-terminal",
             "org.gnome.console", "ptyxis", "xterm", "urxvt", "terminator", "tilix", "blackbox", "st-256color")
WHICH_IFACE = "app.duduphudu.PlasmaType"
WHICH_XML = f"""<node><interface name="{WHICH_IFACE}"><method name="Front">
  <arg type="s" name="cls" direction="in"/><arg type="s" name="desktop" direction="in"/>
</method></interface></node>"""


class Failed(Exception):
    pass


def front_window(bus: Gio.DBusConnection) -> tuple[str, str]:
    """The class and desktop file of the window in front, from KWin, or ("", "") when it cannot be told.

    KWin has no D-Bus call for this, so a one-line script is loaded that calls back into this process."""
    answer: dict = {}
    loop = GLib.MainLoop()

    def on_call(conn, sender, path, iface, method, params, invocation):
        cls, desktop = params.unpack()
        answer["cls"], answer["desktop"] = str(cls)[:128], str(desktop)[:128]
        invocation.return_value(None)
        loop.quit()

    node = Gio.DBusNodeInfo.new_for_xml(WHICH_XML)
    reg = bus.register_object("/app/duduphudu/PlasmaType", node.interfaces[0], on_call, None, None)
    name = "plasmatype_" + secrets.token_hex(6)
    script = os.path.join(state_dir(), f".{name}.js")
    try:
        fd = os.open(script, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            os.write(fd, ("var w = workspace.activeWindow;\n"
                          f"callDBus({json.dumps(bus.get_unique_name())}, \"/app/duduphudu/PlasmaType\", "
                          f"\"{WHICH_IFACE}\", \"Front\", w ? String(w.resourceClass) : \"\", "
                          "w ? String(w.desktopFileName) : \"\");\n").encode())
        finally:
            os.close(fd)
        reply = bus.call_sync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript",
                              GLib.Variant("(ss)", (script, name)), GLib.VariantType("(i)"),
                              Gio.DBusCallFlags.NONE, 3000, None)
        number = reply.unpack()[0]
        try:
            bus.call_sync("org.kde.KWin", f"/Scripting/Script{number}", "org.kde.kwin.Script", "run", None, None,
                          Gio.DBusCallFlags.NONE, 3000, None)
            GLib.timeout_add(2000, loop.quit)
            loop.run()
        finally:
            bus.call_sync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript",
                          GLib.Variant("(s)", (name,)), None, Gio.DBusCallFlags.NONE, 3000, None)
    except GLib.Error:
        pass
    finally:
        bus.unregister_object(reg)
        try:
            os.unlink(script)
        except OSError:
            pass
    return answer.get("cls", ""), answer.get("desktop", "")


def is_terminal(cls: str, desktop: str) -> bool:
    seen = f"{cls} {desktop}".lower()
    return any(name in seen for name in TERMINALS)


def state_dir() -> str:
    base = os.environ.get("XDG_STATE_HOME", "")
    if not base.startswith("/"):
        base = os.path.join(os.path.expanduser("~"), ".local", "state")
    path = os.path.join(base, "plasma-type")
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Failed(f"{path} is not a private directory of ours")
    return path


def read_token() -> str:
    try:
        fd = os.open(os.path.join(state_dir(), "token"), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return ""
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return ""
        token = os.read(fd, 256).decode("ascii", "replace").strip()
    finally:
        os.close(fd)
    return token if token.replace("-", "").isalnum() else ""


def write_token(token: str) -> None:
    d = state_dir()
    tmp = os.path.join(d, f".token.{secrets.token_hex(6)}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        os.write(fd, token.encode("ascii") + b"\n")
    finally:
        os.close(fd)
    os.replace(tmp, os.path.join(d, "token"))


class Portal:
    """The RemoteDesktop portal's request-and-response dance, synchronously."""

    def __init__(self, bus: Gio.DBusConnection) -> None:
        self.bus = bus
        name = bus.get_unique_name()[1:].replace(".", "_")
        self.sender = name

    def request(self, method: str, fields: list, signature: str) -> dict:
        """Call `method` with `fields` (the last one its options, as Variants) and wait for the Response."""
        token = "pt" + secrets.token_hex(8)
        path = f"/org/freedesktop/portal/desktop/request/{self.sender}/{token}"
        loop = GLib.MainLoop()
        answer: dict = {}

        def on_response(conn, sender, obj, iface, signal, params):
            code, results = params.unpack()
            answer["code"], answer["results"] = code, results
            loop.quit()

        sub = self.bus.signal_subscribe(PORTAL, "org.freedesktop.portal.Request", "Response", path, None,
                                        Gio.DBusSignalFlags.NO_MATCH_RULE, on_response)
        try:
            fields = list(fields)
            fields[-1] = dict(fields[-1], handle_token=GLib.Variant("s", token))
            self.bus.call_sync(PORTAL, PORTAL_PATH, RD, method, GLib.Variant(signature, tuple(fields)),
                               GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, 10000, None)
            GLib.timeout_add_seconds(TIMEOUT, loop.quit)
            loop.run()
        finally:
            self.bus.signal_unsubscribe(sub)
        if answer.get("code") != 0:
            raise Failed("the desktop did not allow keyboard control" if answer.get("code") == 1
                         else f"the portal answered {answer.get('code', 'nothing')} to {method}")
        return answer["results"]

    def start(self) -> str:
        results = self.request("CreateSession", [{"session_handle_token": GLib.Variant("s", "pts" + secrets.token_hex(6))}],
                               "(a{sv})")
        session = results["session_handle"]
        options = {"types": GLib.Variant("u", KEYBOARD), "persist_mode": GLib.Variant("u", PERSIST_UNTIL_REVOKED)}
        token = read_token()
        if token:
            options["restore_token"] = GLib.Variant("s", token)
        self.request("SelectDevices", [session, options], "(oa{sv})")
        started = self.request("Start", [session, "", {}], "(osa{sv})")
        if not int(started.get("devices", 0)) & KEYBOARD:
            raise Failed("the desktop gave no keyboard")
        if started.get("restore_token"):
            write_token(str(started["restore_token"]))
        return session

    def key(self, session: str, code: int, pressed: bool) -> None:
        self.bus.call_sync(PORTAL, PORTAL_PATH, RD, "NotifyKeyboardKeycode",
                           GLib.Variant("(oa{sv}iu)", (session, {}, code, 1 if pressed else 0)),
                           None, Gio.DBusCallFlags.NONE, 5000, None)

    def close(self, session: str) -> None:
        try:
            self.bus.call_sync(PORTAL, session, "org.freedesktop.portal.Session", "Close", None, None,
                               Gio.DBusCallFlags.NONE, 5000, None)
        except GLib.Error:
            pass


def klipper(bus: Gio.DBusConnection, method: str, *args: str) -> str | None:
    try:
        reply = bus.call_sync("org.kde.klipper", "/klipper", "org.kde.klipper.klipper", method,
                              GLib.Variant("(" + "s" * len(args) + ")", args) if args else None,
                              None, Gio.DBusCallFlags.NONE, 3000, None)
    except GLib.Error as problem:
        raise Failed("Klipper, Plasma's clipboard, did not answer") from problem
    return reply.unpack()[0] if reply is not None and reply.n_children() else None


def main(argv: list[str]) -> int:
    terminal = "--terminal" in argv
    keep = "--keep-clipboard" in argv
    copy_only = "--copy-only" in argv
    if any(a not in ("--terminal", "--auto", "--keep-clipboard", "--copy-only", "--which") for a in argv):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    if "--which" in argv:
        try:
            cls, desktop = front_window(Gio.bus_get_sync(Gio.BusType.SESSION, None))
        except (Failed, GLib.Error, OSError) as problem:
            print(f"plasma-type: {problem}", file=sys.stderr)
            return 1
        print(json.dumps({"class": cls, "desktop": desktop, "terminal": is_terminal(cls, desktop)}))
        return 0
    raw = sys.stdin.buffer.read(TEXT_MAX + 1)
    if len(raw) > TEXT_MAX:
        print("plasma-type: more than 64 KB of text", file=sys.stderr)
        return 2
    text = raw.decode("utf-8", "replace")
    if not text:
        return 0
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        if copy_only:
            klipper(bus, "setClipboardContents", text)
            return 0
        before = None if keep else klipper(bus, "getClipboardContents")
        klipper(bus, "setClipboardContents", text)
        if "--auto" in argv:
            terminal = is_terminal(*front_window(bus))
        portal = Portal(bus)
        session = portal.start()
        try:
            chord = [CTRL, SHIFT, KEY_V] if terminal else [CTRL, KEY_V]
            for code in chord:
                portal.key(session, code, True)
            for code in reversed(chord):
                portal.key(session, code, False)
            time.sleep(0.05)
        finally:
            portal.close(session)
        if before is not None:
            # Long enough for the app to have asked for the clipboard; then yours is back.
            time.sleep(RESTORE_AFTER)
            klipper(bus, "setClipboardContents", before)
    except (Failed, GLib.Error, OSError) as problem:
        print(f"plasma-type: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
