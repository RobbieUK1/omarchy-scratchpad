import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// ScratchPad — a bar widget that drops down into an always-focused notepad.
//
// The panel, the injection plumbing and the store handling are lifted from the
// SuperClip bar widget (robbie.superclip): the same WidgetButton /
// PanelController / KeyboardPanel trio, the same focus-aware paste command, the
// same omarchy-clipboard-paste-{text,file} --copy-only calls, the same FileView
// store, the same floating hover preview for images, and the same
// SearchBox / ClearAllButton / ListScrollIndicator components.
//
// What is new here is the editor that sits permanently at the top of the drop
// down, plus the clipboard *reader* (SuperClip only ever wrote to the
// clipboard) so you can paste text and images into the pad itself.
Item {
  id: root

  property var bar: null
  property string moduleName: ""
  property var moduleSettings: ({})

  // Notes currently in the pad. Text notes carry `text`; image notes carry
  // `path` + `mime` and live under the scratchpad media dir.
  property var notes: []
  property string filter: ""
  property int hoverIndex: -1
  property int editingIndex: -1
  property string draftText: ""
  property string statusText: ""

  // Floating image preview state (see the hoverPreview comment at the bottom).
  property string hoverPreviewPath: ""
  property var hoverPreviewItem: null
  property int scrollEpoch: 0

  // Transient confirmation line, e.g. "Saved" / "Pasted image".
  property int statusEpoch: 0
  function flash(message) {
    root.statusText = message
    root.statusEpoch++
  }

  readonly property var filteredNotes: {
    var q = root.filter.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.notes.length; i++) {
      var n = root.notes[i]
      if (!q) { out.push(n); continue }
      var hay = String(n.label || "") + " " + String(n.text || "") + " " + String(n.mime || "")
      if (hay.toLowerCase().indexOf(q) >= 0) out.push(n)
    }
    return out
  }

  function noteOriginalIndex(i) {
    var n = root.filteredNotes[i]
    return root.notes.indexOf(n)
  }

  readonly property string dataPath: Quickshell.env("HOME") + "/.config/omarchy/scratchpad.json"
  readonly property string mediaDir: Quickshell.env("HOME") + "/.local/state/omarchy/scratchpad"
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property bool opened: panelController.open
  readonly property int panelContentWidth: Style.space(400)

  // Fixed chrome heights, kept together so contentHeightFor() and the anchors
  // below can never drift apart.
  readonly property int headerH: Style.space(32)
  readonly property int sepH: 1
  readonly property int toolbarH: Style.space(32)
  readonly property int searchRowH: Style.space(36)

  // The draft box is the only part of the panel that changes size. It starts
  // compact and grows to fit whatever is in it, up to a cap; past the cap the
  // TextEdit scrolls internally instead of the card growing forever. Because
  // it is a plain property rather than a binding, it can carry a Behavior and
  // ease into place instead of snapping on every keystroke.
  readonly property int editorPad: Style.space(8) * 2
  readonly property int editorMinH: Style.space(56)
  readonly property int editorMaxH: Style.space(190)
  property int editorH: Style.space(56)

  Behavior on editorH {
    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
  }

  // Re-measure the draft. Driven from onTextChanged and from the width change
  // that re-wraps the text, because a wrapped document's height depends on its
  // width — contentHeight is a document measurement, so it does not depend on
  // the editor's own height and this cannot feed back into itself.
  function syncEditorHeight() {
    var wanted = Math.ceil(draftEdit.contentHeight) + root.editorPad + Style.space(2)
    root.editorH = Math.max(root.editorMinH, Math.min(root.editorMaxH, wanted))
  }

  // The list yields room to the draft as it grows, so a long note never pushes
  // the card off the screen: whatever the editor takes above its resting
  // height comes straight back out of the list. listCap is how tall the list
  // may be when the draft is empty, and maxListHeight is that budget after the
  // editor has taken its share.
  readonly property int listCap: Style.space(180)
  readonly property int listFloor: Style.space(72)
  readonly property int maxListHeight: Math.max(
    listFloor,
    listCap - Math.max(0, root.editorH - root.editorMinH))

  // ------------------------------------------------------------------ text --

  // Single-line preview, whitespace collapsed. Same rule SuperClip uses for
  // its history and SuperClip rows.
  function preview(text) {
    var t = String(text || "").replace(/\s+/g, " ")
    if (t.length > 90) t = t.substring(0, 90) + "…"
    return t
  }

  function basename(path) {
    var parts = String(path || "").split("/")
    return parts[parts.length - 1] || ""
  }

  function ago(ms) {
    var d = Date.now() - Number(ms || 0)
    if (!(d >= 0)) return ""
    var mins = Math.floor(d / 60000)
    if (mins < 1) return "now"
    if (mins < 60) return mins + "m"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + "h"
    var days = Math.floor(hours / 24)
    if (days < 7) return days + "d"
    var date = new Date(Number(ms))
    return (date.getMonth() + 1) + "/" + date.getDate()
  }

  function mimeExtension(mime) {
    var m = String(mime || "").toLowerCase()
    if (m.indexOf("png") >= 0) return "png"
    if (m.indexOf("jpeg") >= 0 || m.indexOf("jpg") >= 0) return "jpg"
    if (m.indexOf("webp") >= 0) return "webp"
    if (m.indexOf("gif") >= 0) return "gif"
    if (m.indexOf("bmp") >= 0) return "bmp"
    if (m.indexOf("svg") >= 0) return "svg"
    if (m.indexOf("tiff") >= 0) return "tif"
    if (m.indexOf("avif") >= 0) return "avif"
    return "bin"
  }

  // Image mimes we are willing to read off the clipboard, best first. Browsers
  // and image viewers usually advertise image/png; some offer bmp and jpeg too.
  function pickImageMime(types) {
    var order = ["image/png", "image/jpeg", "image/webp", "image/bmp", "image/gif",
      "image/tiff", "image/avif", "image/x-icon"]
    for (var i = 0; i < order.length; i++) {
      if (types.indexOf(order[i]) >= 0) return order[i]
    }
    for (var j = 0; j < types.length; j++) {
      if (String(types[j]).indexOf("image/") === 0) return types[j]
    }
    return ""
  }

  function hasTextMime(types) {
    for (var i = 0; i < types.length; i++) {
      if (String(types[i]).indexOf("text/") === 0) return true
    }
    return false
  }

  // ----------------------------------------------------------------- store --

  function save() {
    dataFile.setText(JSON.stringify(root.notes, null, 2) + "\n")
  }

  function newId() {
    return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8)
  }

  function addTextNote(label, text) {
    var list = root.notes.slice()
    list.unshift({
      id: root.newId(),
      label: label,
      type: "text",
      text: text,
      createdAt: Date.now()
    })
    root.notes = list
    root.save()
  }

  function addImageNote(path, mime) {
    var list = root.notes.slice()
    list.unshift({
      id: root.newId(),
      label: root.basename(path),
      type: "image",
      mime: mime,
      path: path,
      createdAt: Date.now()
    })
    root.notes = list
    root.save()
  }

  // Only ever unlink files we wrote into the pad's own media dir, so a note
  // that points at a clipboard image the user owns never deletes their file.
  function removeMedia(path) {
    if (!path || String(path).indexOf(root.mediaDir) !== 0) return
    Util.execDetached("rm -f " + Util.shellQuote(path))
  }

  function updateNote(index, label, text) {
    var list = root.notes.slice()
    var prev = list[index] || {}
    if (prev.type === "image") {
      list[index] = {
        id: prev.id,
        label: label,
        type: "image",
        mime: prev.mime,
        path: prev.path,
        createdAt: prev.createdAt
      }
    } else {
      list[index] = {
        id: prev.id,
        label: label,
        type: "text",
        text: text,
        createdAt: prev.createdAt
      }
    }
    root.notes = list
    root.save()
  }

  function deleteNote(index) {
    var entry = root.notes[index]
    if (!entry) return
    if (entry.type === "image") root.removeMedia(entry.path)
    var list = root.notes.slice()
    list.splice(index, 1)
    root.notes = list
    root.save()
  }

  function clearNotes() {
    for (var i = 0; i < root.notes.length; i++) {
      if (root.notes[i] && root.notes[i].type === "image") root.removeMedia(root.notes[i].path)
    }
    root.notes = []
    root.save()
  }

  // -------------------------------------------------------------- injection --

  // Focus-aware paste: terminals want Shift+Insert, everything else Ctrl+V.
  // Verbatim from SuperClip.
  function universalPasteCommand() {
    return "sleep 0.4"
      + " && if jq -e 'any(.tags[]?; startswith(\"terminal\"))' <(hyprctl activewindow -j) >/dev/null 2>&1; then M=SHIFT; K=Insert; else M=CTRL; K=V; fi"
      + " && hyprctl dispatch \"hl.dsp.send_key_state({ mods = \\\"$M\\\", key = \\\"$K\\\", state = \\\"down\\\" })\""
      + " && sleep 0.05"
      + " && hyprctl dispatch \"hl.dsp.send_key_state({ mods = \\\"$M\\\", key = \\\"$K\\\", state = \\\"up\\\" })\""
  }

  // Copy the note to the clipboard, drop focus back to whatever window the user
  // came from, then fire the paste key there. Same two-step SuperClip uses.
  function injectNote(i) {
    var entry = root.notes[i]
    if (!entry) return
    root.close()
    var script
    if (entry.type === "image") {
      script = Util.shellQuote(root.omarchyPath + "/bin/omarchy-clipboard-paste-file")
        + " --copy-only " + Util.shellQuote(entry.mime || "image/png") + " " + Util.shellQuote(entry.path)
    } else {
      script = Util.shellQuote(root.omarchyPath + "/bin/omarchy-clipboard-paste-text")
        + " --copy-only " + Util.shellQuote(entry.text || "")
    }
    Util.execDetached(script + " && " + root.universalPasteCommand())
  }

  // Copy without stealing focus — handy when the target is somewhere you are
  // about to click yourself.
  function copyNote(i) {
    var entry = root.notes[i]
    if (!entry) return
    if (entry.type === "image") {
      Util.execDetached(Util.shellQuote(root.omarchyPath + "/bin/omarchy-clipboard-paste-file")
        + " --copy-only " + Util.shellQuote(entry.mime || "image/png") + " " + Util.shellQuote(entry.path))
      root.flash("Image copied")
    } else {
      Util.execDetached(Util.shellQuote(root.omarchyPath + "/bin/omarchy-clipboard-paste-text")
        + " --copy-only " + Util.shellQuote(entry.text || ""))
      root.flash("Copied")
    }
  }

  // ------------------------------------------------------------- clipboard --

  // Ctrl+V in the draft. Text goes into the editor at the cursor; an image is
  // written to the media dir and added as a note straight away, since Qt's
  // QML clipboard API cannot put an image into a TextEdit.
  //
  // When the clipboard offers both (e.g. "Copy image" from a web page carries
  // an HTML fallback) text wins; the Paste image button forces the image path.
  function pasteFromClipboard(forceImage) {
    if (clipboardTypesProc.running) return
    pendingImagePaste = !!forceImage
    clipboardTypesProc.command = ["bash", "-c", "wl-paste --list-types 2>/dev/null", "bash"]
    clipboardTypesProc.running = true
  }

  property bool pendingImagePaste: false

  function onClipboardTypes(raw) {
    var types = String(raw || "").split("\n")
    var clean = []
    for (var i = 0; i < types.length; i++) {
      var t = types[i].trim()
      if (t) clean.push(t)
    }
    if (clean.length === 0) {
      root.flash("Clipboard is empty")
      return
    }
    var imageMime = root.pickImageMime(clean)
    if (imageMime && (root.pendingImagePaste || !root.hasTextMime(clean))) {
      root.readClipboardImage(imageMime)
      return
    }
    if (!root.hasTextMime(clean)) {
      root.flash("No text or image on the clipboard")
      return
    }
    clipboardTextProc.running = true
  }

  function onClipboardText(raw) {
    var text = String(raw || "").replace(/\n$/, "")
    if (!text) {
      root.flash("Clipboard is empty")
      return
    }
    // `insert()` splits on \n itself, so keep the newlines intact.
    draftEdit.insert(draftEdit.cursorPosition, text)
    draftEdit.forceActiveFocus()
    root.flash("Pasted " + text.length + " chars")
  }

  function readClipboardImage(mime) {
    var ext = root.mimeExtension(mime)
    var name = Date.now() + "-" + root.newId().slice(-4) + "." + ext
    var target = root.mediaDir + "/" + name
    clipboardImageProc.target = target
    clipboardImageProc.mime = mime
    clipboardImageProc.command = ["bash", "-c",
      "mkdir -p \"$1\" && wl-paste --type \"$2\" > \"$3\" 2>/dev/null; [[ -s \"$3\" ]] && echo OK || echo FAIL",
      "bash", root.mediaDir, mime, target]
    clipboardImageProc.running = true
  }

  function onClipboardImage(raw) {
    var target = clipboardImageProc.target
    var mime = clipboardImageProc.mime
    if (String(raw || "").indexOf("OK") < 0) {
      if (target) Util.execDetached("rm -f " + Util.shellQuote(target))
      root.flash("Could not read the image")
      return
    }
    root.addImageNote(target, mime)
    root.flash("Image added")
  }

  // ------------------------------------------------------------------ draft --

  function saveDraft() {
    var text = root.draftText.trim()
    if (!text) {
      root.flash("Nothing to save")
      return
    }
    // Title = first meaningful line, so notes are scannable in the list.
    var lines = text.split("\n")
    var label = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line) { label = line; break }
    }
    label = root.preview(label)
    if (root.editingIndex >= 0) {
      root.updateNote(root.editingIndex, label, text)
      root.flash("Updated")
    } else {
      root.addTextNote(label, text)
      root.flash("Saved")
    }
    root.resetDraft()
  }

  function resetDraft() {
    root.editingIndex = -1
    root.draftText = ""
    root.syncEditorHeight()
  }

  function editNote(index) {
    var entry = root.notes[index]
    if (!entry) return
    root.editingIndex = index
    root.draftText = entry.type === "image" ? "" : String(entry.text || "")
    draftEdit.forceActiveFocus()
    draftEdit.cursorPosition = draftEdit.text.length
    // The text binding has landed by now, so this settles on the loaded note's
    // real height rather than animating up from the collapsed minimum.
    Qt.callLater(root.syncEditorHeight)
  }

  function open() { panelController.show() }
  function close() { panelController.hide() }
  function toggle() { root.opened ? close() : open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  // ---------------------------------------------------------------- heights --

  function listContentHeight() {
    var h = 0
    for (var i = 0; i < root.filteredNotes.length; i++) {
      var n = root.filteredNotes[i]
      h += (n && n.type === "image" ? Style.space(88) : Style.space(48))
    }
    h += Math.max(0, root.filteredNotes.length - 1) * Style.space(4)
    return h
  }

  function contentHeightFor() {
    var h = root.headerH          // header
    h += root.sepH               // separator
    h += root.editorH            // draft box
    h += Style.space(8)          // editor / toolbar gap
    h += root.toolbarH           // paste-image / save row
    h += Style.space(12)
    h += root.sepH               // separator
    h += root.searchRowH         // search + clear all
    h += Style.space(10)
    h += Math.min(root.listContentHeight(), root.maxListHeight)
    h += Style.space(8)
    return h
  }

  onOpenedChanged: {
    if (!root.opened) {
      root.filter = ""
      searchField.clearSearch()
      root.hoverIndex = -1
      root.hoverPreviewPath = ""
      root.hoverPreviewItem = null
    } else {
      root.resetDraft()
      root.ensureMediaDir()
      // Layout of the notepad is only meaningful once the card has its final
      // width, so measure after the panel has opened rather than before.
      Qt.callLater(root.syncEditorHeight)
    }
  }

  function ensureMediaDir() {
    Util.execDetached("mkdir -p " + Util.shellQuote(root.mediaDir))
  }

  // --------------------------------------------------------------- processes --

  Process {
    id: clipboardTypesProc
    stdout: StdioCollector {
      id: clipboardTypesOut
      waitForEnd: true
    }
    onExited: root.onClipboardTypes(String(clipboardTypesOut.text || ""))
  }

  Process {
    id: clipboardTextProc
    stdout: StdioCollector {
      id: clipboardTextOut
      waitForEnd: true
    }
    onExited: root.onClipboardText(String(clipboardTextOut.text || ""))
  }

  Process {
    id: clipboardImageProc
    property string target: ""
    property string mime: ""
    stdout: StdioCollector {
      id: clipboardImageOut
      waitForEnd: true
    }
    onExited: root.onClipboardImage(String(clipboardImageOut.text || ""))
  }

  // Status line fades out on its own so a flash never lingers.
  Timer {
    id: statusTimer
    interval: 1800
    onTriggered: root.statusText = ""
  }
  onStatusEpochChanged: if (root.statusText) statusTimer.restart()

  // ----------------------------------------------------------------- store --

  FileView {
    id: dataFile
    path: root.dataPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var raw = text() || "[]"
      try {
        var parsed = JSON.parse(raw)
        root.notes = Array.isArray(parsed) ? parsed : []
      } catch (e) { root.notes = [] }
    }
    onLoadFailed: { root.notes = [] }
    onFileChanged: { reload() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf02d"
    tooltipText: "ScratchPad"
    onPressed: function(b) {
      if (b === Qt.LeftButton || b === Qt.MiddleButton) root.toggle()
    }
  }

  PanelController {
    id: panelController
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: draftEdit
    contentWidth: panel.fittedContentWidth(root.panelContentWidth)
    // No hard pixel cap of our own: fittedContentHeight already clamps to the
    // space actually available under the bar, and contentHeightFor() now sizes
    // itself from the draft and the list rather than from a fixed budget.
    contentHeight: panel.fittedContentHeight(root.contentHeightFor())

    Item {
      id: panelContent
      anchors.fill: parent

      ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: root.headerH
          spacing: Style.space(8)

          Text {
            text: "\uf02d"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            verticalAlignment: Text.AlignVCenter
          }

          Text {
            text: "ScratchPad"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            verticalAlignment: Text.AlignVCenter
          }

          Text {
            text: root.notes.length > 0 ? root.notes.length : ""
            color: Util.alpha(Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }

          Item { Layout.fillWidth: true }

          Text {
            text: root.statusText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: root.sepH
          color: Util.alpha(Color.popups.text, 0.15)
        }

        // Draft editor — always present, always focused on open.
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: root.editorH
          Layout.topMargin: Style.space(4)
          clip: true

          Rectangle {
            anchors.fill: parent
            radius: Style.space(6)
            color: draftEdit.activeFocus ? Util.alpha(Color.accent, 0.08) : Util.alpha(Color.popups.text, 0.04)
            border.width: 1
            border.color: draftEdit.activeFocus ? Util.alpha(Color.accent, 0.5) : Util.alpha(Color.popups.text, 0.15)

            Text {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              visible: draftEdit.text === ""
              text: root.editingIndex >= 0
                ? "Edit your note…  (Ctrl+Enter to save)"
                : "Type a thought, a snippet, a command…  (Ctrl+Enter to save)"
              color: Util.alpha(Color.popups.text, 0.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              verticalAlignment: Text.AlignTop
              wrapMode: Text.Wrap
              maximumLineCount: 3
              elide: Text.ElideRight
            }

            TextEdit {
              id: draftEdit
              anchors.fill: parent
              anchors.margins: Style.space(8)
              color: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: TextEdit.Wrap
              selectByMouse: true
              clip: true
              text: root.draftText
              onTextChanged: {
                root.draftText = text
                root.syncEditorHeight()
              }

              // A wrapped document re-flows on width change, so the height that
              // fits it changes too. Cheaper to trust the new width than to
              // re-measure on every keystroke from here.
              onWidthChanged: root.syncEditorHeight()

              // Keys handlers run before TextEdit's own handling and the event
              // arrives already accepted, so every unhandled key has to be
              // explicitly released back to the editor's default behaviour
              // (typing, selection, undo).
              Keys.onPressed: function(event) {
                var handled = false
                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                var shift = (event.modifiers & Qt.ShiftModifier) !== 0

                if (ctrl && event.key === Qt.Key_Return) {
                  root.saveDraft()
                  handled = true
                } else if (ctrl && event.key === Qt.Key_Escape) {
                  root.resetDraft()
                  handled = true
                } else if (ctrl && event.key === Qt.Key_F) {
                  searchField.focusSearch()
                  handled = true
                } else if (ctrl && event.key === Qt.Key_V) {
                  // Qt cannot paste an image into a TextEdit, so both paths
                  // are routed through wl-paste. Ctrl+Shift+V forces the image.
                  root.pasteFromClipboard(shift)
                  handled = true
                } else if (event.key === Qt.Key_Escape) {
                  if (root.draftText.length > 0) root.resetDraft()
                  else root.close()
                  handled = true
                }
                event.accepted = handled
              }
            }
          }
        }

        // Editor toolbar
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: root.toolbarH
          Layout.topMargin: Style.space(8)
          Layout.bottomMargin: Style.space(12)
          spacing: Style.space(8)

          Rectangle {
            Layout.preferredWidth: Style.space(132)
            Layout.fillHeight: true
            radius: Style.space(6)
            color: pasteImgArea.containsMouse ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.popups.text, 0.06)
            border.width: 1
            border.color: Util.alpha(Color.popups.text, 0.2)

            Text {
              anchors.centerIn: parent
              text: "\uf03e  Paste image"
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            PanelToolTip {
              visible: pasteImgArea.containsMouse
              text: "Copy an image anywhere, then click (or press Ctrl+Shift+V)"
            }

            MouseArea {
              id: pasteImgArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pasteFromClipboard(true)
            }
          }

          Rectangle {
            Layout.preferredWidth: Style.space(76)
            Layout.fillHeight: true
            radius: Style.space(6)
            color: Util.alpha(Color.popups.text, 0.06)
            border.width: 1
            border.color: Util.alpha(Color.popups.text, 0.2)

            Text {
              anchors.centerIn: parent
              text: root.editingIndex >= 0 ? "Cancel" : "Clear"
              color: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: clearDraftArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.resetDraft()
            }
          }

          Item { Layout.fillWidth: true }

          Rectangle {
            Layout.preferredWidth: Style.space(104)
            Layout.fillHeight: true
            radius: Style.space(6)
            color: saveDraftArea.containsMouse ? Qt.darker(Color.accent, 1.1) : Color.accent

            Text {
              anchors.centerIn: parent
              text: root.editingIndex >= 0 ? "Update" : "Save"
              color: "#ffffff"
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            PanelToolTip {
              visible: saveDraftArea.containsMouse
              text: "Ctrl+Enter"
            }

            MouseArea {
              id: saveDraftArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.saveDraft()
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: root.sepH
          color: Util.alpha(Color.popups.text, 0.15)
        }

        // Search + clear all
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: root.searchRowH
          Layout.topMargin: Style.space(8)

          SearchBox {
            id: searchField
            width: parent.width - Style.space(122)
            placeholder: "Search notes"
            onSearchChanged: root.filter = value
          }

          ClearAllButton {
            enabled: root.notes.length > 0
            onClicked: root.clearNotes()
          }
        }

        // Note list
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: Math.min(root.listContentHeight(), root.maxListHeight)
          Layout.topMargin: Style.space(2)
          clip: true

          Flickable {
            id: listScroll
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: listColumn.height
            boundsBehavior: Flickable.StopAtBounds
            onContentYChanged: root.scrollEpoch++

            Column {
              id: listColumn
              width: parent.width
              topPadding: Style.space(2)
              spacing: Style.space(4)

              Repeater {
                model: root.filteredNotes

                Item {
                  required property var modelData
                  required property int index
                  width: listColumn.width
                  height: modelData.type === "image" ? Style.space(88) : Style.space(48)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(6)
                    color: root.hoverIndex === index
                      ? Util.alpha(Color.accent, 0.2)
                      : Util.alpha(Color.popups.text, 0.06)
                  }

                  // Thumbnail for image notes, same tile size SuperClip's
                  // Images / Screenshots grids use.
                  Image {
                    visible: modelData.type === "image"
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(4)
                    width: Style.space(80)
                    height: Style.space(80)
                    source: modelData.type === "image" ? Util.fileUrl(modelData.path) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    sourceSize.width: Style.space(160)
                    sourceSize.height: Style.space(160)
                    clip: true
                  }

                  RowLayout {
                    visible: modelData.type !== "image"
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: noteIcons.width + Style.space(12)
                    spacing: Style.space(6)

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 1

                      Text {
                        Layout.fillWidth: true
                        text: modelData.label || "Untitled"
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: Color.popups.text
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }

                      Text {
                        Layout.fillWidth: true
                        text: root.preview(modelData.text)
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: Util.alpha(Color.popups.text, 0.5)
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  // Image notes: filename + type + age.
                  RowLayout {
                    visible: modelData.type === "image"
                    anchors.left: parent.left
                    anchors.right: noteIcons.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(92)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(6)

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 1

                      Text {
                        Layout.fillWidth: true
                        text: modelData.label || "Image"
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: Color.popups.text
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }

                      Text {
                        Layout.fillWidth: true
                        text: (modelData.mime || "image") + " · " + root.ago(modelData.createdAt)
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        color: Util.alpha(Color.popups.text, 0.5)
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  // Hover tracking only — shows the large preview, never
                  // steals clicks. Same split SuperClip uses in its grids.
                  MouseArea {
                    anchors.fill: parent
                    z: 50
                    hoverEnabled: true
                    enabled: modelData.type === "image"
                    acceptedButtons: Qt.NoButton
                    cursorShape: Qt.PointingHandCursor
                    onEntered: { root.hoverPreviewPath = modelData.path; root.hoverPreviewItem = parent }
                    onExited: { root.hoverPreviewPath = ""; root.hoverPreviewItem = null }
                  }

                  // Row click = inject into the active window.
                  MouseArea {
                    id: noteRowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.hoverIndex = index
                    onClicked: root.injectNote(root.noteOriginalIndex(index))
                  }

                  // Copy / edit / delete sit above the row so their clicks win.
                  Item {
                    id: noteIcons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: Style.space(4)
                    width: Style.space(26) * 3 + Style.space(8) * 2
                    height: Style.space(26)
                    z: 60

                    Text {
                      x: Style.space(0)
                      width: Style.space(26)
                      height: Style.space(26)
                      text: "\uf0c5"
                      color: copyNoteArea.containsMouse ? Color.accent : Util.alpha(Color.popups.text, 0.45)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Math.round(Style.font.body)
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter

                      PanelToolTip {
                        visible: copyNoteArea.containsMouse
                        text: "Copy only"
                      }

                      MouseArea {
                        id: copyNoteArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.hoverIndex = index
                        onClicked: root.copyNote(root.noteOriginalIndex(index))
                      }
                    }

                    Text {
                      x: Style.space(26) + Style.space(8)
                      width: Style.space(26)
                      height: Style.space(26)
                      visible: modelData.type !== "image"
                      text: "\uf044"
                      color: Util.alpha(Color.popups.text, 0.5)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Math.round(Style.font.body)
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter

                      PanelToolTip {
                        visible: modelData.type !== "image" && editNoteArea.containsMouse
                        text: "Edit in the box above"
                      }

                      MouseArea {
                        id: editNoteArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.hoverIndex = index
                        onClicked: root.editNote(root.noteOriginalIndex(index))
                      }
                    }

                    Text {
                      x: Style.space(26) * 2 + Style.space(8) * 2
                      width: Style.space(26)
                      height: Style.space(26)
                      text: "\uf1f8"
                      color: deleteNoteArea.containsMouse ? Color.urgent : Util.alpha(Color.popups.text, 0.5)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Math.round(Style.font.body)
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter

                      PanelToolTip {
                        visible: deleteNoteArea.containsMouse
                        text: "Delete"
                      }

                      MouseArea {
                        id: deleteNoteArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.hoverIndex = index
                        onClicked: root.deleteNote(root.noteOriginalIndex(index))
                      }
                    }
                  }
                }
              }

              Text {
                width: listColumn.width
                visible: root.filteredNotes.length === 0
                text: root.notes.length === 0
                  ? "Empty pad — type above and hit Ctrl+Enter"
                  : "No matches"
                color: Util.alpha(Color.popups.text, 0.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(24)
                bottomPadding: Style.space(24)
              }
            }
          }

          ListScrollIndicator {
            flick: listScroll
          }
        }
      }
    }

    // Hover preview for image notes. The card is only ~400px wide, so placing
    // a large preview beside a thumbnail inside the pane would cover the other
    // rows' icons. Instead it floats in the desktop space to the LEFT of the
    // card (a bar-pinned panel sits at the screen edge, which leaves room),
    // vertically aligned with the hovered thumbnail. The full-screen layer
    // surface is not clipped, so it renders beyond the card. On scroll
    // (root.scrollEpoch bumps in the Flickable's onContentYChanged) the
    // thumbnail re-maps so the preview keeps tracking its row. If the card is
    // pinned to the screen's left edge, the preview flips to the right of it.
    readonly property point hoverOrigin: {
      root.scrollEpoch  // re-map when the thumbnail moves under the cursor
      if (!root.hoverPreviewItem || !panelContent) return Qt.point(0, 0)
      return panelContent.mapFromItem(root.hoverPreviewItem, 0, 0)
    }

    Rectangle {
      id: hoverPreview
      x: panel.cardOrigin.x >= width + Style.space(8) ? -width - Style.space(8) : panel.contentWidth + Style.space(8)
      y: {
        var itemH = root.hoverPreviewItem ? root.hoverPreviewItem.height : 0
        var cy = panel.hoverOrigin.y - (height - itemH) / 2
        var minY = Style.space(6) - panel.cardOrigin.y
        var maxY = panel.screenH - panel.cardOrigin.y - height - Style.space(6)
        return Math.max(minY, Math.min(maxY, cy))
      }
      width: Math.min(Style.space(280), parent.width - Style.space(16))
      height: Math.min(Style.space(280), parent.height - Style.space(16))
      radius: Style.space(6)
      z: 100
      visible: root.hoverPreviewPath !== ""
      color: "transparent"
      clip: true

      Image {
        anchors.fill: parent
        anchors.margins: Style.space(2)
        source: root.hoverPreviewPath ? Util.fileUrl(root.hoverPreviewPath) : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        sourceSize.width: Math.max(Style.space(280), Math.round(width * 2))
        sourceSize.height: Math.max(Style.space(280), Math.round(height * 2))
      }
    }
  }

  // ---------------------------------------------------------------- pieces --

  component ListScrollIndicator: Rectangle {
    id: scrollBar
    required property Flickable flick
    visible: scrollBar.flick.visible && scrollBar.flick.contentHeight > scrollBar.flick.height
    width: Style.space(3)
    radius: width / 2
    color: Util.alpha(Color.popups.text, 0.3)
    anchors.right: scrollBar.flick.right
    anchors.rightMargin: Style.space(4)
    height: Math.max(Style.space(20), scrollBar.flick.height * scrollBar.flick.height / Math.max(1, scrollBar.flick.contentHeight))
    y: scrollBar.flick.y + (scrollBar.flick.height - height) * scrollBar.flick.contentY / Math.max(1, scrollBar.flick.contentHeight - scrollBar.flick.height)
  }

  component SearchBox: Rectangle {
    id: searchBox
    signal searchChanged(string value)
    property string placeholder: ""
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: Style.space(0)
    height: Style.space(28)

    // Reachable from outside the component: the draft editor's Ctrl+F and the
    // close handler both need to drive the inner TextInput.
    function focusSearch() {
      searchInput.forceActiveFocus()
      searchInput.selectAll()
    }

    function clearSearch() {
      searchInput.text = ""
    }

    radius: Style.space(6)
    color: searchInput.activeFocus ? Util.alpha(Color.accent, 0.12) : Util.alpha(Color.popups.text, 0.06)
    border.width: 1
    border.color: searchInput.activeFocus ? Util.alpha(Color.accent, 0.6) : Util.alpha(Color.popups.text, 0.15)

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "\uf002"
      color: Util.alpha(Color.popups.text, 0.5)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.fill: parent
      anchors.leftMargin: Style.space(26)
      anchors.rightMargin: Style.space(8)
      text: searchInput.text ? "" : searchBox.placeholder
      color: Util.alpha(Color.popups.text, 0.35)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }

    TextInput {
      id: searchInput
      anchors.fill: parent
      anchors.leftMargin: Style.space(26)
      anchors.rightMargin: Style.space(8)
      color: Color.popups.text
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      verticalAlignment: TextInput.AlignVCenter
      clip: true
      selectByMouse: true
      onTextChanged: searchBox.searchChanged(text)
    }
  }

  component ClearAllButton: Rectangle {
    id: clearBtn
    signal clicked()
    anchors.right: parent.right
    anchors.top: parent.top
    width: Style.space(104)
    height: Style.space(28)
    radius: Style.space(6)
    color: enabled
      ? (clearBtnArea.containsMouse ? Util.alpha(Color.urgent, 0.25) : Util.alpha(Color.urgent, 0.08))
      : Util.alpha(Color.popups.text, 0.04)
    border.width: 1
    border.color: enabled
      ? (clearBtnArea.containsMouse ? Color.urgent : Util.alpha(Color.urgent, 0.4))
      : Util.alpha(Color.popups.text, 0.1)

    Text {
      anchors.centerIn: parent
      text: "\uf1f8  Clear All"
      color: clearBtn.enabled ? Color.urgent : Util.alpha(Color.popups.text, 0.3)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      id: clearBtnArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: clearBtn.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: clearBtn.clicked()
    }
  }

  // KeyboardPanel ships no IpcHandler of its own, but every built-in panel
  // exposes one under its plugin id. Matching that means the ScratchPad can be
  // driven from a keybind or the CLI the same way any other panel can:
  //   qs ipc call robbie.scratchpad toggle
  IpcHandler {
    target: "robbie.scratchpad"

    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }

    // Focus the draft and start a new note. Not named `new`, which is a
    // reserved word in the JS dialect QML parses.
    function compose() {
      root.open()
      Qt.callLater(function() {
        root.resetDraft()
        draftEdit.forceActiveFocus()
      })
    }

  }
}
