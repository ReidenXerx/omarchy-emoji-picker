import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "EmojiModel.js" as Model

// Full-screen overlay in the style of Omarchy's own emoji picker: a card over a scrim,
// search on top, a grid below, and whatever is picked typed into the app that had focus.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false

  // Helpers always run under the system interpreter, never through PATH or a shebang.
  readonly property string python: "/usr/bin/python3"
  readonly property string helper: localPath("bin/emoji-picker")
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy/emoji-picker.json"

  function localPath(rel) {
    return decodeURIComponent(String(Qt.resolvedUrl(rel)).replace("file://", ""))
  }

  // ---------------------------------------------------------------- theme

  // The [menu] surface tokens, like the built-in picker, so themes style both alike.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  readonly property int cardWidth: Math.min(Style.space(600), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(580), panel.height - Style.gapsOut * 2)
  readonly property int searchHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
  readonly property int tabsHeight: Style.space(28)
  readonly property int chipsHeight: Style.space(32)
  readonly property int footerHeight: Style.space(54)

  // ---------------------------------------------------------------- state

  readonly property var tabs: [
    { id: "emoji", label: "Emoji" },
    { id: "symbols", label: "Symbols" },
    { id: "kaomoji", label: "Kaomoji" },
    { id: "gif", label: "GIFs" }
  ]
  readonly property var localKinds: ["emoji", "symbols", "kaomoji"]
  readonly property var tones: ["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"]

  property string tab: "emoji"
  property string lastTab: "emoji"
  property int tone: 0
  property var recents: ({})

  property var sets: ({ emoji: [], symbols: [], kaomoji: [] })
  property var groupsByKind: ({ emoji: [], symbols: [], kaomoji: [] })
  property var byKey: ({})

  property string query: ""
  property var results: []
  property int recentCount: 0
  property var starts: ({})
  property var counts: ({})
  property int selected: 0

  property var gifItems: []
  property string gifQuery: ""
  property bool gifLoading: false
  property string gifError: ""
  property bool gifHasNext: false
  property int gifPage: 0

  readonly property int columns: tab === "kaomoji" || tab === "gif" ? 3 : 10
  readonly property var selectedItem: results.length > 0 ? results[Model.clamp(selected, results.length)] : null
  readonly property bool selectedIsRecent: selected < recentCount && query.trim() === ""
  readonly property int currentGroup: selected < recentCount ? -1 : (selectedItem ? selectedItem.g : 0)

  readonly property var chips: {
    if (tab === "gif" || query.trim() !== "") return []
    var out = []
    if (recentCount > 0) out.push({ g: -1, label: tab === "kaomoji" ? "Recent" : "🕘", title: "Recent" })
    var gs = groupsByKind[tab] || []
    for (var i = 0; i < gs.length; i++)
      out.push({ g: i, label: tab === "kaomoji" ? gs[i].name : gs[i].icon, title: gs[i].name })
    return out
  }

  // ---------------------------------------------------------------- shell contract

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    root.opened = true
    root.tab = tabIndex(String(payload.tab || "")) >= 0 ? String(payload.tab) : root.lastTab
    search.text = ""
    root.query = ""
    rebuild(false)
    if (root.tab === "gif") maybeFetchGifs()
    Qt.callLater(function() { search.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    gifDebounce.stop()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "reidenxerx.emoji-picker")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---------------------------------------------------------------- data

  function loadSet(kind, raw) {
    var data = null
    try { data = JSON.parse(raw) } catch (e) { data = null }
    var nextSets = Object.assign({}, root.sets)
    nextSets[kind] = Model.prepare(data, kind)
    root.sets = nextSets
    var nextGroups = Object.assign({}, root.groupsByKind)
    nextGroups[kind] = Model.groups(data)
    root.groupsByKind = nextGroups

    var map = {}
    for (var k = 0; k < root.localKinds.length; k++) {
      var items = root.sets[root.localKinds[k]]
      for (var i = 0; i < items.length; i++) map[items[i].key] = items[i]
    }
    root.byKey = map
    if (root.opened) rebuild(true)
  }

  function applyState(raw) {
    var parsed = null
    try { parsed = raw ? JSON.parse(raw) : null } catch (e) { parsed = null }
    var s = Model.normalizeState(parsed)
    root.tone = s.tone
    root.recents = s.recents
    root.lastTab = s.tab
    if (root.opened) rebuild(true)
  }

  // Helpers that take a payload (text to type, the state document) get it over stdin,
  // never argv. One Process per call, so a paste still finishes when another starts;
  // each one destroys itself once its child has exited.
  Component {
    id: helperCall

    Process {
      id: call
      property string input: ""
      property var done: null

      stdinEnabled: true
      onStarted: {
        write(call.input)
        call.input = ""
        stdinEnabled = false
      }
      onExited: {
        var callback = call.done
        call.done = null
        if (typeof callback === "function") callback()
        call.destroy()
      }
    }
  }

  function runHelper(args, input, done) {
    var proc = helperCall.createObject(root, {
      command: [root.python, root.helper].concat(args),
      input: String(input || ""),
      done: done || null
    })
    if (!proc) {
      if (typeof done === "function") done()
      return
    }
    proc.running = true
  }

  // One state write at a time, newest snapshot last, so an older document can never
  // land after a newer one. The watchdog frees the queue if a writer never reports back.
  property bool stateWriting: false
  property bool stateQueued: false
  property int stateGeneration: 0

  function saveState() {
    root.stateQueued = true
    if (!root.stateWriting) flushState()
  }

  function flushState() {
    var generation = ++root.stateGeneration
    root.stateQueued = false
    root.stateWriting = true
    stateWatchdog.restart()
    runHelper(["state-write"], JSON.stringify({
      version: 1, tab: root.lastTab, tone: root.tone, recents: root.recents
    }), function() {
      if (generation !== root.stateGeneration) return
      stateWatchdog.stop()
      root.stateWriting = false
      if (root.stateQueued) Qt.callLater(root.flushState)
    })
  }

  Timer {
    id: stateWatchdog
    interval: 10000
    onTriggered: {
      root.stateWriting = false
      if (root.stateQueued) root.flushState()
    }
  }

  // A cell that appears under a still pointer (after typing, a tab switch, a scroll)
  // gets a synthetic hover; this lets only real pointer movement change the selection.
  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView { path: root.localPath("data/emoji.json"); onLoaded: root.loadSet("emoji", text()) }
  FileView { path: root.localPath("data/symbols.json"); onLoaded: root.loadSet("symbols", text()) }
  FileView { path: root.localPath("data/kaomoji.json"); onLoaded: root.loadSet("kaomoji", text()) }

  FileView {
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: root.applyState("")
  }

  // ---------------------------------------------------------------- results

  function tabIndex(id) {
    for (var i = 0; i < root.tabs.length; i++) if (root.tabs[i].id === id) return i
    return -1
  }

  function recentFor(kind, now) {
    var all = Model.recentItems(root.recents, root.byKey, now, 200)
    var limit = kind === "emoji" ? 20 : (kind === "symbols" ? 10 : 6)
    var out = []
    for (var i = 0; i < all.length && out.length < limit; i++)
      if (all[i].kind === kind) out.push(all[i])
    return out
  }

  function rebuild(keepSelection) {
    var now = Date.now()
    var q = root.query.trim()
    var nextCounts = {}
    var out = []
    var recentN = 0

    if (q !== "") {
      for (var i = 0; i < root.localKinds.length; i++) {
        var kind = root.localKinds[i]
        var found = Model.search(root.sets[kind], q, 500, root.recents, now)
        nextCounts[kind] = found.length
        if (kind === root.tab) out = found
      }
    } else if (root.tab !== "gif") {
      var rec = recentFor(root.tab, now)
      recentN = rec.length
      out = rec.concat(root.sets[root.tab])
    }
    if (root.tab === "gif") {
      var gifRecent = q === "" ? recentFor("gif", now) : []
      recentN = gifRecent.length
      out = gifRecent.concat(root.gifQuery === q ? root.gifItems : [])
    }

    var nextStarts = {}
    if (recentN > 0) nextStarts[-1] = 0
    for (var j = recentN; j < out.length; j++)
      if (nextStarts[out[j].g] === undefined) nextStarts[out[j].g] = j

    root.counts = nextCounts
    root.recentCount = recentN
    root.starts = nextStarts
    root.results = out
    root.selected = keepSelection ? Model.clamp(root.selected, out.length) : 0
    pointerGate.reset()
    Qt.callLater(function() {
      if (root.results.length > 0) grid.positionViewAtIndex(root.selected, GridView.Contain)
    })
  }

  onQueryChanged: {
    if (!root.opened) return
    rebuild(false)
    if (root.tab === "gif") {
      gifDebounce.restart()
    } else if (root.query.trim() !== "" && (root.counts[root.tab] || 0) === 0) {
      // Nothing here but something elsewhere: go where the matches are.
      for (var i = 0; i < root.localKinds.length; i++) {
        if ((root.counts[root.localKinds[i]] || 0) > 0) { setTab(root.localKinds[i]); break }
      }
    }
  }

  function setTab(id) {
    if (root.tab === id || tabIndex(id) < 0) return
    root.tab = id
    rebuild(false)
    if (id === "gif") maybeFetchGifs()
  }

  function cycleTab(delta) {
    var n = root.tabs.length
    setTab(root.tabs[(tabIndex(root.tab) + delta + n) % n].id)
  }

  // ---------------------------------------------------------------- GIFs

  Timer {
    id: gifDebounce
    interval: 380
    onTriggered: root.fetchGifs(1)
  }

  Process {
    id: gifProcess
    stdout: StdioCollector { onStreamFinished: root.gifReply(text) }
  }

  // The helper gives up on KLIPY after 30 s by itself; this is the backstop in case it
  // hangs anyway. It polls only while a request is loading.
  readonly property int gifWatchdogMs: 45000
  property real gifStartedAt: 0
  property bool gifTimedOut: false

  Timer {
    id: gifWatchdog
    interval: 5000
    repeat: true
    running: root.gifLoading
    onTriggered: {
      if (Date.now() - root.gifStartedAt < root.gifWatchdogMs) return
      root.gifLoading = false
      if (!gifProcess.running) return
      root.gifTimedOut = true
      gifProcess.signal(15)
      root.gifError = "offline"
      if (root.tab === "gif") root.rebuild(true)
    }
  }

  function maybeFetchGifs() {
    var q = root.query.trim()
    if (root.gifQuery !== q || root.gifError !== "" || root.gifItems.length === 0) fetchGifs(1)
  }

  function fetchGifs(page) {
    var q = root.query.trim()
    root.gifLoading = true
    root.gifTimedOut = false
    root.gifStartedAt = Date.now()
    gifProcess.exec(q !== ""
      ? [root.python, root.helper, "gif", "search", q, String(page)]
      : [root.python, root.helper, "gif", "trending", String(page)])
  }

  function gifReply(raw) {
    var r = Model.parseGifReply(raw)
    // The watchdog stopped this request and has already said so.
    if (r.q === null && root.gifTimedOut) { root.gifTimedOut = false; return }
    // A reply to a search the user has already typed past.
    if (r.q !== null && r.q !== root.query.trim()) return
    root.gifLoading = false
    if (r.error !== "") {
      root.gifError = r.error
      if (r.page <= 1) root.gifItems = []
    } else {
      root.gifError = ""
      root.gifHasNext = r.hasNext
      root.gifPage = r.page
      root.gifItems = r.page <= 1 ? r.items : Model.appendGifs(root.gifItems, r.items)
    }
    root.gifQuery = r.q !== null ? r.q : root.query.trim()
    if (root.tab === "gif") rebuild(r.page > 1)
  }

  function maybeLoadMore() {
    if (root.tab === "gif" && root.gifHasNext && !root.gifLoading && root.gifItems.length > 0)
      fetchGifs(root.gifPage + 1)
  }

  function setupKey() {
    root.dismiss()
    Quickshell.execDetached([root.python, root.helper, "gif", "key", "set"])
  }

  // ---------------------------------------------------------------- actions

  // mode: "type" into the focused app, "copy" to the clipboard, or "link" (GIFs: type the
  // link instead of pasting the file).
  function activate(index, mode) {
    var item = root.results[index]
    if (!item) return
    root.recents = Model.recordUse(root.recents, item.key, Date.now(),
      item.kind === "gif" ? { gif: Model.gifCard(item) } : null)
    root.lastTab = root.tab
    saveState()

    // Close first: the overlay holds keyboard focus, and the paste has to reach the app
    // underneath it.
    root.dismiss()
    if (item.kind === "gif" && mode !== "copy") {
      // Only an id and a klipy.com link, both validated by the helper. Detached, so a
      // slow download survives the shell reloading.
      Quickshell.execDetached([root.python, root.helper, "gif", mode === "link" ? "link" : "insert", item.id, item.url])
    } else {
      // The text itself goes over stdin.
      runHelper([mode === "copy" ? "copy" : "insert"], item.kind === "gif" ? item.url : Model.textFor(item, root.tone))
    }
  }

  function setTone(t) {
    root.tone = t
    saveState()
  }

  function forgetSelected() {
    if (!root.selectedIsRecent || !root.selectedItem) return
    root.recents = Model.forget(root.recents, root.selectedItem.key)
    saveState()
    rebuild(true)
  }

  function moveTo(index) {
    if (root.results.length === 0) return
    root.selected = Model.clamp(index, root.results.length)
    pointerGate.reset()
    grid.positionViewAtIndex(root.selected, GridView.Contain)
    if (root.selected >= root.results.length - root.columns) maybeLoadMore()
  }

  function visibleRows() {
    return Math.max(1, Math.floor(grid.height / Math.max(1, grid.cellHeight)))
  }

  function jumpToGroup(g) {
    var index = root.starts[g]
    if (index === undefined) return
    root.selected = index
    pointerGate.reset()
    grid.positionViewAtIndex(index, GridView.Beginning)
  }

  function jumpGroup(delta) {
    var list = root.chips
    if (list.length === 0) return
    var at = 0
    for (var i = 0; i < list.length; i++) if (list[i].g === root.currentGroup) { at = i; break }
    jumpToGroup(list[Math.max(0, Math.min(list.length - 1, at + delta))].g)
  }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var k = event.key
    var count = root.results.length
    var handled = true

    if (k === Qt.Key_Escape) { if (search.text !== "") search.text = ""; else root.dismiss() }
    else if (k === Qt.Key_Tab && !ctrl) cycleTab(1)
    else if (k === Qt.Key_Backtab) cycleTab(-1)
    else if (k === Qt.Key_Left) { if (ctrl) jumpGroup(-1); else moveTo(Model.move(root.selected, -1, count)) }
    else if (k === Qt.Key_Right) { if (ctrl) jumpGroup(1); else moveTo(Model.move(root.selected, 1, count)) }
    else if (k === Qt.Key_Up) moveTo(Model.moveRow(root.selected, -1, root.columns, count))
    else if (k === Qt.Key_Down) moveTo(Model.moveRow(root.selected, 1, root.columns, count))
    else if (k === Qt.Key_PageUp) moveTo(Model.moveRow(root.selected, -visibleRows(), root.columns, count))
    else if (k === Qt.Key_PageDown) moveTo(Model.moveRow(root.selected, visibleRows(), root.columns, count))
    else if (k === Qt.Key_Home && ctrl) moveTo(0)
    else if (k === Qt.Key_End && ctrl) moveTo(count - 1)
    else if (k === Qt.Key_Return || k === Qt.Key_Enter) activate(root.selected, shift ? "copy" : (alt ? "link" : "type"))
    else if (k === Qt.Key_Delete && root.selectedIsRecent) forgetSelected()
    else if (alt && k >= Qt.Key_0 && k <= Qt.Key_5) setTone(k - Qt.Key_0)
    else if (ctrl && k >= Qt.Key_1 && k <= Qt.Key_4) setTab(root.tabs[k - Qt.Key_1].id)
    else if (ctrl && k === Qt.Key_K) setupKey()
    else handled = false

    if (handled) event.accepted = true
  }

  // ---------------------------------------------------------------- ui

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-emoji-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: search.forceActiveFocus() }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // ------------------------------------------------ search
        Item {
          width: parent.width
          height: root.searchHeight

          TextInput {
            id: search
            anchors.left: parent.left
            anchors.right: spinner.left
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            selectionColor: Util.alpha(root.selectedText, 0.35)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            maximumLength: 100
            clip: true
            focus: true
            onTextChanged: root.query = text
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { root.handleKey(event) }

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: search.text === ""
              textFormat: Text.PlainText
              text: root.tab === "gif" ? "Search KLIPY"
                : (root.tab === "symbols" ? "Search symbols…" : (root.tab === "kaomoji" ? "Search kaomoji…" : "Search emoji…"))
              color: root.foreground
              opacity: 0.58
              font: search.font
              elide: Text.ElideRight
            }
          }

          Text {
            id: spinner
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: root.tab === "gif" && root.gifLoading ? implicitWidth : 0
            visible: width > 0
            textFormat: Text.PlainText
            text: "…"
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }
        }

        // ------------------------------------------------ tabs
        Item {
          width: parent.width
          height: root.tabsHeight

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxxl

            Repeater {
              model: root.tabs

              delegate: Item {
                id: tabItem
                required property var modelData
                required property int index
                readonly property bool active: root.tab === modelData.id
                readonly property string countText: root.query.trim() !== "" && modelData.id !== "gif"
                  ? " " + (root.counts[modelData.id] || 0) : ""

                width: tabLabel.implicitWidth
                height: root.tabsHeight

                Text {
                  id: tabLabel
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: tabItem.modelData.label + tabItem.countText
                  color: tabItem.active ? root.selectedText : root.foreground
                  opacity: tabItem.active ? 1 : 0.62
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Math.max(1, Style.space(2))
                  radius: height / 2
                  color: root.selectedText
                  visible: tabItem.active
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.setTab(tabItem.modelData.id); search.forceActiveFocus() }
                }
              }
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Tab ⇄"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ------------------------------------------------ group chips
        ListView {
          id: chipList
          width: parent.width
          height: root.chips.length > 0 ? root.chipsHeight : 0
          visible: height > 0
          orientation: ListView.Horizontal
          spacing: Style.spacing.sm
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.chips

          delegate: Rectangle {
            id: chip
            required property var modelData
            required property int index
            readonly property bool active: modelData.g === root.currentGroup

            width: chipLabel.implicitWidth + Style.spacing.lg * 2
            height: root.chipsHeight
            radius: root.cornerRadius
            color: active ? root.selectedBackground : "transparent"

            Text {
              id: chipLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: chip.modelData.label
              color: chip.active ? root.selectedText : root.foreground
              opacity: chip.active ? 1 : 0.75
              font.family: root.fontFamily
              font.pixelSize: root.tab === "kaomoji" ? Style.font.body : Style.font.title
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.jumpToGroup(chip.modelData.g); search.forceActiveFocus() }
            }
          }

          Connections {
            target: root
            function onCurrentGroupChanged() {
              for (var i = 0; i < root.chips.length; i++)
                if (root.chips[i].g === root.currentGroup) { chipList.positionViewAtIndex(i, ListView.Contain); break }
            }
          }
        }

        // ------------------------------------------------ grid
        Item {
          id: gridArea
          width: parent.width
          height: content.height - root.searchHeight - root.tabsHeight - chipList.height - root.footerHeight
            - content.spacing * (chipList.visible ? 4 : 3)

          GridView {
            id: grid
            anchors.fill: parent
            model: root.results
            clip: true
            cellWidth: Math.floor(width / root.columns)
            cellHeight: root.tab === "kaomoji" ? Style.space(46)
              : (root.tab === "gif" ? Math.round(cellWidth * 0.75) : cellWidth)
            cacheBuffer: cellHeight * 3
            boundsBehavior: Flickable.StopAtBounds
            onAtYEndChanged: if (atYEnd) root.maybeLoadMore()

            delegate: Item {
              id: cell
              required property var modelData
              required property int index
              readonly property bool hasCursor: index === root.selected
              readonly property bool isGif: modelData.kind === "gif"

              width: grid.cellWidth
              height: grid.cellHeight

              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.spacing.xxs
                radius: root.cornerRadius
                color: cell.hasCursor ? root.selectedBackground : (cell.isGif ? Util.alpha(root.foreground, 0.05) : "transparent")
              }

              Text {
                visible: !cell.isGif
                anchors.fill: parent
                anchors.margins: Style.spacing.sm
                textFormat: Text.PlainText
                text: Model.textFor(cell.modelData, root.tone)
                color: cell.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: cell.modelData.kind === "kaomoji" ? Style.font.title : Style.font.display
                fontSizeMode: cell.modelData.kind === "kaomoji" ? Text.HorizontalFit : Text.FixedSize
                minimumPixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
              }

              Loader {
                active: cell.isGif
                anchors.fill: parent
                anchors.margins: Style.spacing.xs
                sourceComponent: AnimatedImage {
                  source: cell.modelData.preview
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  smooth: true
                  playing: root.opened && status === AnimatedImage.Ready
                }
              }

              Rectangle {
                visible: cell.isGif && cell.hasCursor
                anchors.fill: parent
                anchors.margins: Style.spacing.xxs
                radius: root.cornerRadius
                color: "transparent"
                border.width: Math.max(1, Style.space(2))
                border.color: root.selectedText
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) {
                  if (pointerGate.moved(cell, mouse)) root.selected = cell.index
                }
                onClicked: function(mouse) {
                  root.selected = cell.index
                  root.activate(cell.index, mouse.button === Qt.RightButton ? "copy"
                    : (mouse.button === Qt.MiddleButton ? "link" : "type"))
                }
              }
            }
          }

          // Empty and status states.
          Column {
            anchors.centerIn: parent
            width: parent.width - Style.spacing.panelPadding * 2
            spacing: Style.spacing.lg
            visible: root.results.length === 0 || (root.tab === "gif" && root.gifError !== "")

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.tab === "gif" ? "󰵸" : "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: {
                if (root.tab === "gif") {
                  if (root.gifError !== "") return Model.gifErrorText(root.gifError)
                  if (root.gifLoading) return "Searching KLIPY…"
                  return root.query.trim() !== "" ? "No GIFs for “" + root.query.trim() + "”" : "Type to search GIFs"
                }
                if (root.query.trim() !== "") return "No matches for “" + root.query.trim() + "”"
                return "Loading…"
              }
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              visible: root.tab === "gif" && (root.gifError === "no-key" || root.gifError === "bad-key")
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Get a free key at partner.klipy.com → API Keys, then press Ctrl+K to add it. It is kept in your keyring."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.tab === "gif" && (root.gifError === "no-key" || root.gifError === "bad-key")
              text: "Add API key"
              onClicked: root.setupKey()
            }
          }
        }

        // ------------------------------------------------ footer
        Item {
          width: parent.width
          height: root.footerHeight

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Style.normalBorderWidth
            color: Util.alpha(root.border, 0.28)
          }

          Text {
            id: bigPreview
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: Style.spacing.xs
            width: root.selectedItem && root.selectedItem.kind !== "gif" && root.selectedItem.kind !== "kaomoji"
              ? Style.space(40) : 0
            visible: width > 0
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.selectedItem ? Model.textFor(root.selectedItem, root.tone) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          Column {
            anchors.left: bigPreview.right
            anchors.leftMargin: bigPreview.visible ? Style.spacing.lg : 0
            anchors.right: sideControls.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: Style.spacing.xs
            spacing: Style.spacing.xxs

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: {
                var it = root.selectedItem
                if (!it) return ""
                if (it.kind === "gif") return it.title || "GIF"
                var seen = {}, out = []
                for (var i = 0; i < it.names.length; i++) {
                  var n = it.names[i]
                  if (n && !seen[n.toLowerCase()]) { seen[n.toLowerCase()] = true; out.push(n) }
                }
                return out.join("  ·  ")
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Item {
              width: parent.width
              height: hintText.implicitHeight

              Text {
                id: hintText
                anchors.left: parent.left
                anchors.right: klipyMark.left
                anchors.rightMargin: klipyMark.visible ? Style.spacing.lg : 0
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: (root.tab === "gif" ? "Enter paste · Alt+Enter link · Shift+Enter copy link"
                  : (root.tab === "emoji" ? "Enter type · Shift+Enter copy · Alt+0–5 tone"
                  : "Enter type · Shift+Enter copy · Ctrl+←→ groups"))
                  + (root.selectedIsRecent ? " · Del forget" : "")
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // KLIPY's attribution guidelines ask for this wherever its results show.
              Text {
                id: klipyMark
                anchors.right: parent.right
                visible: root.tab === "gif"
                width: visible ? implicitWidth : 0
                textFormat: Text.PlainText
                text: "Powered by KLIPY"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Item {
            id: sideControls
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: Style.spacing.xs
            width: root.tab === "emoji" ? toneRow.width : 0
            height: parent.height - Style.spacing.lg

            Row {
              id: toneRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.tab === "emoji"
              spacing: Style.spacing.xxs

              Repeater {
                model: root.tones

                delegate: Rectangle {
                  id: swatch
                  required property var modelData
                  required property int index
                  width: Style.space(28)
                  height: Style.space(28)
                  radius: root.cornerRadius
                  color: root.tone === index ? root.selectedBackground : "transparent"
                  border.width: root.tone === index ? Math.max(1, Style.space(1)) : 0
                  border.color: root.selectedText

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: swatch.modelData
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.setTone(swatch.index); search.forceActiveFocus() }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
