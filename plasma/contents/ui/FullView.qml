import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "../code/EmojiModel.js" as Model

// The picker: search across all three sets at once (English, Ukrainian and Russian names), tabs, group chips,
// the grid, and skin tones. Keys: arrows move, Enter types, Shift+Enter copies, Tab changes tab, Ctrl+←/→ jumps a
// group, Alt+0..5 picks a skin tone, Delete forgets a recent pick.
PlasmaExtras.Representation {
  id: view

  required property var picker

  Layout.preferredWidth: Kirigami.Units.gridUnit * 30
  Layout.preferredHeight: Kirigami.Units.gridUnit * 30
  Layout.minimumWidth: Kirigami.Units.gridUnit * 22
  Layout.minimumHeight: Kirigami.Units.gridUnit * 20

  readonly property var p: view.picker
  readonly property var tabs: [{ id: "emoji", label: "Emoji" }, { id: "symbols", label: "Symbols" },
                               { id: "kaomoji", label: "Kaomoji" }, { id: "gif", label: "GIFs" }]
  readonly property var tones: ["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"]
  readonly property color faint: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.65)

  property string tab: "emoji"
  property string query: ""
  property var results: []
  property int recentCount: 0
  property var starts: ({})
  property var counts: ({})
  property int selected: 0

  readonly property int columns: view.tab === "kaomoji" || view.tab === "gif" ? 3 : 10
  readonly property var selectedItem: view.results.length > 0 ? view.results[Model.clamp(view.selected, view.results.length)] : null
  readonly property bool selectedIsRecent: view.selected < view.recentCount && view.query.trim() === ""
  readonly property int currentGroup: view.selected < view.recentCount ? -1 : (view.selectedItem ? view.selectedItem.g : 0)

  readonly property var chips: {
    if (view.tab === "gif" || view.query.trim() !== "") return []
    var out = []
    if (view.recentCount > 0) out.push({ g: -1, label: view.tab === "kaomoji" ? "Recent" : "🕘", title: "Recent" })
    var gs = view.p.groupsByKind[view.tab] || []
    for (var i = 0; i < gs.length; i++)
      out.push({ g: i, label: view.tab === "kaomoji" ? gs[i].name : gs[i].icon, title: gs[i].name })
    return out
  }

  // ---------------------------------------------------------------- opening

  Connections {
    target: view.p
    function onExpandedChanged() { if (view.p.expanded) view.opened() }
    function onGifItemsChanged() { if (view.tab === "gif") view.rebuild(view.p.gifPage > 1) }
  }
  Component.onCompleted: view.opened()

  function opened() {
    view.tab = view.tabIndex(view.p.lastTab) >= 0 ? view.p.lastTab : "emoji"
    search.text = ""
    view.query = ""
    view.rebuild(false)
    if (view.tab === "gif") view.maybeFetchGifs()
    Qt.callLater(function () { search.forceActiveFocus() })
  }

  function tabIndex(id) {
    for (var i = 0; i < view.tabs.length; i++) if (view.tabs[i].id === id) return i
    return -1
  }

  // ---------------------------------------------------------------- results

  function recentFor(kind, now) {
    var all = Model.recentItems(view.p.recents, view.p.byKey, now, 200)
    var limit = kind === "emoji" ? 20 : (kind === "symbols" ? 10 : 6)
    var out = []
    for (var i = 0; i < all.length && out.length < limit; i++)
      if (all[i].kind === kind) out.push(all[i])
    return out
  }

  function rebuild(keepSelection) {
    var now = Date.now()
    var q = view.query.trim()
    var nextCounts = {}
    var out = []
    var recentN = 0
    if (q !== "") {
      for (var i = 0; i < view.p.localKinds.length; i++) {
        var kind = view.p.localKinds[i]
        var found = Model.search(view.p.sets[kind], q, 500, view.p.recents, now)
        nextCounts[kind] = found.length
        if (kind === view.tab) out = found
      }
    } else if (view.tab !== "gif") {
      var rec = view.recentFor(view.tab, now)
      recentN = rec.length
      out = rec.concat(view.p.sets[view.tab])
    }
    if (view.tab === "gif") {
      var gifRecent = q === "" ? view.recentFor("gif", now) : []
      recentN = gifRecent.length
      out = gifRecent.concat(view.p.gifQuery === q ? view.p.gifItems : [])
    }
    var nextStarts = {}
    if (recentN > 0) nextStarts[-1] = 0
    for (var j = recentN; j < out.length; j++)
      if (nextStarts[out[j].g] === undefined) nextStarts[out[j].g] = j
    view.counts = nextCounts
    view.recentCount = recentN
    view.starts = nextStarts
    view.results = out
    view.selected = keepSelection ? Model.clamp(view.selected, out.length) : 0
    Qt.callLater(function () { if (view.results.length > 0) grid.positionViewAtIndex(view.selected, GridView.Contain) })
  }

  onQueryChanged: {
    view.rebuild(false)
    if (view.tab === "gif") {
      gifDebounce.restart()
    } else if (view.query.trim() !== "" && (view.counts[view.tab] || 0) === 0) {
      // Nothing here but something in another set: go where the matches are.
      for (var i = 0; i < view.p.localKinds.length; i++)
        if ((view.counts[view.p.localKinds[i]] || 0) > 0) { view.setTab(view.p.localKinds[i]); break }
    }
  }

  function setTab(id) {
    if (view.tab === id || view.tabIndex(id) < 0) return
    view.tab = id
    view.rebuild(false)
    if (id === "gif") view.maybeFetchGifs()
  }

  function cycleTab(delta) {
    var n = view.tabs.length
    view.setTab(view.tabs[(view.tabIndex(view.tab) + delta + n) % n].id)
  }

  Timer { id: gifDebounce; interval: 380; onTriggered: view.p.fetchGifs(view.query, 1) }

  function maybeFetchGifs() {
    var q = view.query.trim()
    if (view.p.gifQuery !== q || view.p.gifError !== "" || view.p.gifItems.length === 0) view.p.fetchGifs(q, 1)
  }

  function maybeLoadMore() {
    if (view.tab === "gif" && view.p.gifHasNext && !view.p.gifLoading && view.p.gifItems.length > 0)
      view.p.fetchGifs(view.query, view.p.gifPage + 1)
  }

  // ---------------------------------------------------------------- moving and choosing

  function moveTo(index) {
    if (view.results.length === 0) return
    view.selected = Model.clamp(index, view.results.length)
    grid.positionViewAtIndex(view.selected, GridView.Contain)
    if (view.selected >= view.results.length - view.columns) view.maybeLoadMore()
  }

  function visibleRows() { return Math.max(1, Math.floor(grid.height / Math.max(1, grid.cellHeight))) }

  function jumpToGroup(g) {
    var index = view.starts[g]
    if (index === undefined) return
    view.selected = index
    grid.positionViewAtIndex(index, GridView.Beginning)
  }

  function jumpGroup(delta) {
    var list = view.chips
    if (list.length === 0) return
    var at = 0
    for (var i = 0; i < list.length; i++) if (list[i].g === view.currentGroup) { at = i; break }
    view.jumpToGroup(list[Math.max(0, Math.min(list.length - 1, at + delta))].g)
  }

  function choose(index, mode) {
    var item = view.results[index]
    if (item) view.p.activate(item, mode, view.tab)
  }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var k = event.key
    var count = view.results.length
    var handled = true
    if (k === Qt.Key_Escape) { if (search.text !== "") search.text = ""; else view.p.expanded = false }
    else if (k === Qt.Key_Tab && !ctrl) view.cycleTab(1)
    else if (k === Qt.Key_Backtab) view.cycleTab(-1)
    else if (k === Qt.Key_Left && (ctrl || search.text === "")) { if (ctrl) view.jumpGroup(-1); else view.moveTo(Model.move(view.selected, -1, count)) }
    else if (k === Qt.Key_Right && (ctrl || search.text === "")) { if (ctrl) view.jumpGroup(1); else view.moveTo(Model.move(view.selected, 1, count)) }
    else if (k === Qt.Key_Up) view.moveTo(Model.moveRow(view.selected, -1, view.columns, count))
    else if (k === Qt.Key_Down) view.moveTo(Model.moveRow(view.selected, 1, view.columns, count))
    else if (k === Qt.Key_PageUp) view.moveTo(Model.moveRow(view.selected, -view.visibleRows(), view.columns, count))
    else if (k === Qt.Key_PageDown) view.moveTo(Model.moveRow(view.selected, view.visibleRows(), view.columns, count))
    else if (k === Qt.Key_Return || k === Qt.Key_Enter) view.choose(view.selected, shift ? "copy" : "type")
    else if (k === Qt.Key_Delete && view.selectedIsRecent) { view.p.forget(view.selectedItem.key); view.rebuild(true) }
    else if (alt && k >= Qt.Key_0 && k <= Qt.Key_5) view.p.setTone(k - Qt.Key_0)
    else if (ctrl && k >= Qt.Key_1 && k <= Qt.Key_4) view.setTab(view.tabs[k - Qt.Key_1].id)
    else if (ctrl && k === Qt.Key_K) view.p.setupKey()
    else handled = false
    if (handled) event.accepted = true
  }

  // ---------------------------------------------------------------- the panel

  header: PlasmaExtras.PlasmoidHeading {
    ColumnLayout {
      anchors.fill: parent
      spacing: Kirigami.Units.smallSpacing
      RowLayout {
        Layout.fillWidth: true
        PlasmaExtras.SearchField {
          id: search
          Layout.fillWidth: true
          placeholderText: view.tab === "gif" ? "Search KLIPY" : view.tab === "symbols" ? "Search symbols…"
                         : view.tab === "kaomoji" ? "Search kaomoji…" : "Search emoji…"
          maximumLength: 100
          focus: true
          onTextChanged: view.query = text
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (event) { view.handleKey(event) }
        }
        PlasmaComponents.BusyIndicator {
          implicitWidth: Kirigami.Units.iconSizes.small
          implicitHeight: implicitWidth
          visible: view.tab === "gif" && view.p.gifLoading
          running: visible
        }
      }
      PlasmaComponents.TabBar {
        Layout.fillWidth: true
        currentIndex: view.tabIndex(view.tab)
        Repeater {
          model: view.tabs
          delegate: PlasmaComponents.TabButton {
            required property var modelData
            text: modelData.label + (view.query.trim() !== "" && modelData.id !== "gif" && view.counts[modelData.id] ? " " + view.counts[modelData.id] : "")
            onClicked: { view.setTab(modelData.id); search.forceActiveFocus() }
          }
        }
      }
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: Kirigami.Units.smallSpacing

    // Group chips: one click to a group.
    ListView {
      Layout.fillWidth: true
      Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
      visible: view.chips.length > 0
      orientation: ListView.Horizontal
      clip: true
      spacing: 2
      model: view.chips
      delegate: PlasmaComponents.ToolButton {
        required property var modelData
        text: modelData.label
        checkable: true
        checked: view.currentGroup === modelData.g
        onClicked: { view.jumpToGroup(modelData.g); search.forceActiveFocus() }
        PlasmaComponents.ToolTip.text: modelData.title
        PlasmaComponents.ToolTip.visible: hovered
      }
    }

    GridView {
      id: grid
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: view.results
      cellWidth: Math.floor(width / view.columns)
      cellHeight: view.tab === "gif" ? cellWidth * 0.75 : view.tab === "kaomoji" ? Kirigami.Units.gridUnit * 2.4 : cellWidth
      boundsBehavior: Flickable.StopAtBounds
      QQC2.ScrollBar.vertical: PlasmaComponents.ScrollBar {}
      onAtYEndChanged: if (atYEnd) view.maybeLoadMore()

      delegate: Item {
        id: cell
        required property var modelData
        required property int index
        width: grid.cellWidth
        height: grid.cellHeight

        Rectangle {
          anchors.fill: parent
          anchors.margins: 2
          radius: Kirigami.Units.cornerRadius
          color: cell.index === view.selected ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.35)
               : hover.hovered ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.15) : "transparent"
        }

        PlasmaComponents.Label {
          anchors.fill: parent
          anchors.margins: 3
          visible: cell.modelData.kind !== "gif"
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
          text: Model.textFor(cell.modelData, view.p.tone)
          font.pixelSize: cell.modelData.kind === "kaomoji" ? Kirigami.Units.gridUnit * 0.8 : Math.round(grid.cellWidth * 0.55)
        }

        AnimatedImage {
          anchors.fill: parent
          anchors.margins: 4
          visible: cell.modelData.kind === "gif"
          source: cell.modelData.kind === "gif" && /^https:\/\//.test(cell.modelData.preview) ? cell.modelData.preview : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          playing: visible && (hover.hovered || cell.index === view.selected)
        }

        HoverHandler { id: hover }
        TapHandler {
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onTapped: function (point, button) {
            view.selected = cell.index
            view.choose(cell.index, button === Qt.RightButton ? "copy" : "type")
          }
        }
      }
    }

    // GIF trouble: what went wrong and, when it is the key, how to give one.
    RowLayout {
      Layout.fillWidth: true
      visible: view.tab === "gif" && view.p.gifError !== ""
      PlasmaComponents.Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: Model.gifErrorText(view.p.gifError)
      }
      PlasmaComponents.Button {
        visible: view.p.gifError === "no-key" || view.p.gifError === "bad-key"
        icon.name: "dialog-password"
        text: "Give a key"
        onClicked: view.p.setupKey()
      }
    }

    Kirigami.Separator { Layout.fillWidth: true }

    RowLayout {
      Layout.fillWidth: true
      PlasmaComponents.Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: view.faint
        text: view.selectedItem ? (view.selectedItem.names.length ? view.selectedItem.names[0] : view.selectedItem.title || "")
                                  + (view.selectedIsRecent ? " · Delete forgets it" : "")
                                : (view.query.trim() !== "" ? "Nothing matches" : "")
      }
      Repeater {
        model: view.tab === "emoji" ? view.tones : []
        delegate: PlasmaComponents.ToolButton {
          required property string modelData
          required property int index
          text: modelData
          checkable: true
          checked: view.p.tone === index
          onClicked: { view.p.setTone(index); search.forceActiveFocus() }
          PlasmaComponents.ToolTip.text: index === 0 ? "No skin tone (Alt+0)" : "Skin tone " + index + " (Alt+" + index + ")"
          PlasmaComponents.ToolTip.visible: hovered
        }
      }
    }
    PlasmaComponents.Label {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: view.faint
      font.pointSize: Math.max(7, Math.round(search.font.pointSize * 0.85))
      text: view.tab === "gif" ? "Enter types the GIF's link · Shift+Enter or right click copies it · GIFs by KLIPY"
                               : "Enter types it into the app you were using · Shift+Enter or right click copies it"
    }
  }
}
