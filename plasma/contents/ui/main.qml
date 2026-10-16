import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import "../code/EmojiModel.js" as Model
import "../code/EmojiData.js" as Data

// The emoji picker for Plasma: emoji, symbols, kaomoji and GIFs, typed into the app you were using.
//
// Plasma's compositor gives ordinary programs no virtual keyboard, so a pick is typed the way a person would:
// plasma-type puts it on the clipboard through Klipper, presses paste through the desktop's RemoteDesktop portal
// (Plasma asks once whether that is allowed), and puts your clipboard back. GIFs are typed as their link.
PlasmoidItem {
  id: root

  readonly property string code: decodeURIComponent(String(Qt.resolvedUrl("../code")).replace("file://", ""))
  // Optional variables only when set: an empty one is not the same as none (an empty bus address breaks D-Bus).
  readonly property string envPrefix: "/usr/bin/env -i HOME=\"$HOME\" PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONIOENCODING=utf-8"
    + " XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\" ${XDG_STATE_HOME:+XDG_STATE_HOME=\"$XDG_STATE_HOME\"}"
    + " ${DBUS_SESSION_BUS_ADDRESS:+DBUS_SESSION_BUS_ADDRESS=\"$DBUS_SESSION_BUS_ADDRESS\"} "

  function quote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
  function helper(name) { return root.envPrefix + "/usr/bin/python3 -I " + root.quote(root.code + "/bin/" + name) }

  P5Support.DataSource {
    id: runner
    engine: "executable"
    property var onDone: ({})
    onNewData: function (source, data) {
      disconnectSource(source)
      var cb = runner.onDone[source]
      delete runner.onDone[source]
      if (cb) cb(Number(data["exit code"]), String(data["stdout"] || ""), String(data["stderr"] || ""))
    }
  }

  function run(command, done) {
    var key = command + " # " + Date.now() + Math.random()
    runner.onDone[key] = done || null
    runner.connectSource(key)
  }

  // ---------------------------------------------------------------- the data

  readonly property var localKinds: ["emoji", "symbols", "kaomoji"]
  readonly property var sets: ({ emoji: Model.prepare(Data.EMOJI, "emoji"), symbols: Model.prepare(Data.SYMBOLS, "symbols"),
                                 kaomoji: Model.prepare(Data.KAOMOJI, "kaomoji") })
  readonly property var groupsByKind: ({ emoji: Model.groups(Data.EMOJI), symbols: Model.groups(Data.SYMBOLS),
                                         kaomoji: Model.groups(Data.KAOMOJI) })
  readonly property var byKey: {
    var map = {}
    for (var k = 0; k < root.localKinds.length; k++) {
      var items = root.sets[root.localKinds[k]]
      for (var i = 0; i < items.length; i++) map[items[i].key] = items[i]
    }
    return map
  }

  // ---------------------------------------------------------------- what you use

  property int tone: 0
  property var recents: ({})
  property string lastTab: "emoji"

  function loadState() {
    var parsed = null
    try { parsed = Plasmoid.configuration.state ? JSON.parse(Plasmoid.configuration.state) : null } catch (e) { parsed = null }
    var s = Model.normalizeState(parsed)
    root.tone = s.tone
    root.recents = s.recents
    root.lastTab = s.tab
  }

  function saveState() {
    Plasmoid.configuration.state = JSON.stringify({ version: 1, tab: root.lastTab, tone: root.tone, recents: root.recents })
  }

  Component.onCompleted: root.loadState()

  function setTone(t) { root.tone = t; root.saveState() }

  function forget(key) { root.recents = Model.forget(root.recents, key); root.saveState() }

  // ---------------------------------------------------------------- GIFs

  property var gifItems: []
  property string gifQuery: ""
  property bool gifLoading: false
  property string gifError: ""
  property bool gifHasNext: false
  property int gifPage: 0
  property int gifAsk: 0

  function fetchGifs(query, page) {
    var q = String(query || "").trim().slice(0, 100)
    var ask = ++root.gifAsk
    root.gifLoading = true
    var cmd = "/usr/bin/timeout -k 2 30 " + root.helper("emoji-picker") + " gif "
              + (q !== "" ? "search " + root.quote(q) + " " + page : "trending " + page)
    root.run(cmd, function (code, out) {
      if (ask !== root.gifAsk) return               // a newer search took over
      root.gifLoading = false
      var r = Model.parseGifReply(out)
      if (r.error !== "") {
        root.gifError = r.error
        if (r.page <= 1) root.gifItems = []
      } else {
        root.gifError = ""
        root.gifHasNext = r.hasNext
        root.gifPage = r.page
        root.gifItems = r.page <= 1 ? r.items : Model.appendGifs(root.gifItems, r.items)
      }
      root.gifQuery = r.q !== null ? r.q : q
    })
  }

  // The key is asked for in a terminal, never through a field here, so it is never in a command line.
  function setupKey() {
    root.expanded = false
    var cmd = root.helper("emoji-picker") + " gif key set"
    var term = "if [ -x /usr/bin/konsole ]; then /usr/bin/systemd-run --user --collect --quiet -- /usr/bin/konsole --hold -e /usr/bin/bash -c " + root.quote(cmd)
             + "; else /usr/bin/systemd-run --user --collect --quiet -- /usr/bin/xdg-terminal-exec /usr/bin/bash -c " + root.quote(cmd + "; read -r -p 'Press Enter to close'")
             + "; fi >/dev/null 2>&1"
    root.run(term, null)
  }

  // ---------------------------------------------------------------- typing it

  property string trouble: ""

  // mode: "type", "copy", or for a GIF "link" (typed) and "copy" (its link on the clipboard).
  function activate(item, mode, tab) {
    if (!item) return
    root.recents = Model.recordUse(root.recents, item.key, Date.now(), item.kind === "gif" ? { gif: Model.gifCard(item) } : null)
    root.lastTab = tab
    root.saveState()
    var text = item.kind === "gif" ? item.url : Model.textFor(item, root.tone)
    root.expanded = false
    if (mode === "copy") {
      root.run("/usr/bin/printf '%s' " + root.quote(text) + " | " + root.helper("plasma-type") + " --copy-only", root.report)
      return
    }
    // Typed once the popup has gone and the app you were using has the keyboard again.
    root.pending = { text: text }
    typeLater.restart()
  }

  property var pending: null
  Timer {
    id: typeLater
    interval: 250
    onTriggered: {
      var p = root.pending
      root.pending = null
      if (!p) return
      // --auto: KWin is asked which window has the keyboard now, so a terminal gets Ctrl+Shift+V.
      root.run("/usr/bin/printf '%s' " + root.quote(p.text) + " | /usr/bin/timeout -k 2 90 " + root.helper("plasma-type")
               + " --auto", root.report)
    }
  }

  function report(code, out, err) {
    root.trouble = code === 0 ? "" : (err.trim().replace(/^plasma-type: /, "").slice(0, 200) || "Could not type it.")
    if (code !== 0)
      root.run("/usr/bin/notify-send --app-name='Emoji picker' --icon=face-smile -- 'Emoji picker' " + root.quote(root.trouble), null)
  }

  Plasmoid.icon: "face-smile"
  toolTipMainText: "Emoji picker"
  toolTipSubText: "Emoji, symbols, kaomoji and GIFs, typed into the app you were using"

  preferredRepresentation: compactRepresentation
  fullRepresentation: FullView { picker: root }
}
