import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// One work item, editable in place. The left column holds the fields that
// change (title, state, assignee, estimate, tags, description, acceptance
// criteria); the right column shows the parent, child tasks and discussion.
// Nothing is sent until Ctrl+S, and only the fields that changed are sent,
// guarded by the revision the item was loaded at.
Item {
  id: root

  property var app: null

  property var item: null
  property bool loading: false
  property string errorText: ""
  property bool saving: false
  property string noticeText: ""
  property bool posting: false
  property var history: []
  property int loadSeq: 0

  // Draft values.
  property string draftTitle: ""
  property string draftState: ""
  property string draftAssignee: ""
  property string draftPoints: ""
  property string draftRemaining: ""
  property string draftPriority: ""
  property string draftTags: ""
  property string draftBody: ""
  property string draftAcceptance: ""
  property string draftComment: ""

  // "", "back", "reload" or "open:<id>" while the discard dialog is up.
  property string pendingAction: ""

  readonly property var changes: {
    var c = {}
    if (!item) return c
    if (draftTitle.trim() !== item.title) c.title = draftTitle.trim()
    if (draftState !== item.state) c.state = draftState
    if (draftAssignee !== (item.assignedTo ? item.assignedTo.email : "")) c.assignedTo = draftAssignee
    if (item.pointsField && draftPoints.trim() !== numberText(item.points)) c.points = draftPoints.trim()
    if (item.hasRemaining && draftRemaining.trim() !== numberText(item.remaining)) c.remaining = draftRemaining.trim()
    if (item.hasPriority && draftPriority.trim() !== numberText(item.priority)) c.priority = draftPriority.trim()
    if (normalizeTags(draftTags) !== normalizeTags(item.tags)) c.tags = draftTags
    if (!item.bodyRich && draftBody.trim() !== item.body.trim()) c.body = draftBody
    if (item.hasAcceptance && !item.acceptanceRich && draftAcceptance.trim() !== item.acceptance.trim()) c.acceptance = draftAcceptance
    return c
  }
  readonly property int changeCount: Object.keys(changes).length
  readonly property bool dirty: changeCount > 0

  function numberText(n) {
    return n === null || n === undefined ? "" : String(n)
  }

  function normalizeTags(value) {
    return String(value || "").split(/[;,]/).map(function(t) { return t.trim() })
      .filter(function(t) { return t.length > 0 }).sort().join(";")
  }

  function focusDefault() {
    root.forceActiveFocus()
  }

  // ---- loading and saving ---------------------------------------------------------

  function load(id, keepHistory) {
    if (!keepHistory) history = []
    var seq = ++loadSeq
    loading = true
    errorText = ""
    noticeText = ""
    item = null
    draftComment = ""
    commentEditor.setText("")
    focusDefault()
    app.run(["item", String(id)], null, function(data) {
      if (seq !== loadSeq) return
      loading = false
      if (data.error) {
        errorText = data.error
        return
      }
      setItem(data)
    })
  }

  function setItem(data) {
    item = data
    draftTitle = data.title
    titleField.text = data.title
    draftState = data.state
    stateDropdown.value = data.state
    draftAssignee = data.assignedTo ? data.assignedTo.email : ""
    assigneeDropdown.value = draftAssignee
    draftPoints = numberText(data.points)
    estimateField.text = data.pointsField ? draftPoints : numberText(data.remaining)
    draftRemaining = numberText(data.remaining)
    draftPriority = numberText(data.priority)
    priorityField.text = draftPriority
    draftTags = data.tags
    tagsField.text = data.tags
    draftBody = data.body
    bodyEditor.setText(data.body)
    draftAcceptance = data.acceptance
    acceptanceEditor.setText(data.acceptance)
  }

  function save() {
    if (!item || saving || !dirty) return
    saving = true
    errorText = ""
    noticeText = ""
    var id = item.id
    app.run(["update", String(id)], { rev: item.rev, changes: changes }, function(data) {
      saving = false
      if (data.error) {
        errorText = data.error
        return
      }
      if (!item || item.id !== id) return
      setItem(data.item)
      noticeText = "Saved"
      noticeTimer.restart()
      app.itemSaved(data.item)
    })
  }

  function postComment() {
    var text = draftComment.trim()
    if (!item || posting || text === "") return
    posting = true
    var id = item.id
    app.run(["comment", String(id)], { text: text }, function(data) {
      posting = false
      if (data.error) {
        errorText = data.error
        return
      }
      if (!item || item.id !== id) return
      item = Object.assign({}, item, { comments: data.item.comments, rev: data.item.rev })
      draftComment = ""
      commentEditor.setText("")
      noticeText = "Comment added"
      noticeTimer.restart()
    })
  }

  // Leaving with unsaved edits asks first.
  function guard(action) {
    if (dirty) {
      pendingAction = action
      confirm.selectedIndex = 1
      root.forceActiveFocus()
      return
    }
    perform(action)
  }

  function perform(action) {
    if (action === "back") {
      if (history.length > 0) {
        var prev = history[history.length - 1]
        history = history.slice(0, -1)
        load(prev, true)
      } else {
        app.closeDetail()
      }
    } else if (action === "reload") {
      if (item) load(item.id, true)
    } else if (action.indexOf("open:") === 0) {
      if (item) history = history.concat([item.id])
      load(Number(action.slice(5)), true)
    }
  }

  // ---- text helpers -------------------------------------------------------------------

  function when(iso) {
    if (!iso) return ""
    var d = new Date(iso)
    if (isNaN(d.getTime())) return ""
    var mins = Math.round((Date.now() - d.getTime()) / 60000)
    if (mins < 1) return "just now"
    if (mins < 60) return mins + "m ago"
    if (mins < 60 * 24) return Math.round(mins / 60) + "h ago"
    if (mins < 60 * 24 * 7) return Math.round(mins / 1440) + "d ago"
    return d.getDate() + " " + app.monthNames[d.getMonth()] + (d.getFullYear() !== new Date().getFullYear() ? " " + d.getFullYear() : "")
  }

  function stateOptions() {
    if (!item) return []
    var out = item.states.map(function(s) { return { value: s.name, label: s.name } })
    if (!item.states.some(function(s) { return s.name === item.state })) out.unshift({ value: item.state, label: item.state })
    return out
  }

  function assigneeOptions() {
    if (!item) return []
    var out = [{ value: "", label: "Unassigned" }]
    for (var i = 0; i < item.members.length; i++) {
      var m = item.members[i]
      out.push({ value: m.email, label: m.name + (app.isMine(m.email) ? "  (you)" : ""), description: m.email })
    }
    return out
  }

  Timer {
    id: noticeTimer
    interval: 2500
    onTriggered: root.noticeText = ""
  }

  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (confirm.handleKey(event)) {
      event.accepted = true
      return
    }
    if (root.pendingAction !== "") {
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Escape) {
      if (root.activeFocus) root.guard("back")
      else root.forceActiveFocus()
    } else if (ctrl && event.key === Qt.Key_S) {
      root.save()
    } else if (ctrl && event.key === Qt.Key_O) {
      if (root.item) root.app.openInBrowser(root.item.url)
    } else if (ctrl && event.key === Qt.Key_R) {
      root.guard("reload")
    } else if (root.activeFocus && (event.key === Qt.Key_Tab || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      titleField.forceActiveFocus()
    } else {
      return
    }
    event.accepted = true
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: app.contentSpacing

    // ---------- header ----------
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(14)

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: app.glyphLeft
        tooltipText: "Back  (Esc)"
        foreground: app.foreground
        fontFamily: app.fontFamily
        onClicked: root.guard("back")
      }

Text {
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: !root.item ? app.glyphBoard
            : root.item.type === "Epic" ? app.glyphEpic
            : root.item.type === "Feature" ? app.glyphFeature
            : root.item.type === "Bug" ? app.glyphBug
            : root.item.type === "Task" ? app.stateGlyph(root.item.category, root.item.state)
            : app.glyphStory
          color: root.item ? app.stateColor(root.item.state, root.item.category, app.foreground) : app.foreground
          font.family: app.fontFamily
          font.pixelSize: app.compact ? Style.font.iconLarge : Style.font.display
        }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.item
            ? (root.item.type + "  " + root.item.id + "  ·  " + root.item.iterationPath.split("\\").pop()
              + "  ·  " + root.item.areaPath).toUpperCase()
            : (root.loading ? "LOADING " + app.openItemId : "")
          color: app.dim
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          elide: Text.ElideRight
        }

        TextField {
          id: titleField
          Layout.fillWidth: true
          enabled: root.item !== null && !root.saving
          foreground: app.foreground
          font.family: app.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
          placeholderText: root.loading ? "Loading…" : "Title"
          onTextEdited: root.draftTitle = text
          onAccepted: root.save()
          KeyNavigation.tab: stateDropdown
        }
      }

      Text {
        Layout.alignment: Qt.AlignVCenter
        visible: !app.compact
        textFormat: Text.PlainText
        text: root.saving ? "Saving…"
          : root.noticeText !== "" ? root.noticeText
          : root.dirty ? root.changeCount + (root.changeCount === 1 ? " unsaved change" : " unsaved changes")
          : ""
        color: root.dirty && !root.saving ? app.selectedText : app.dim
        font.family: app.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.dirty
      }

      Button {
        Layout.alignment: Qt.AlignVCenter
        iconText: "\uF0C7"
        text: app.compact ? (root.dirty ? String(root.changeCount) : "") : "Save"
        fontSize: Style.font.bodySmall
        foreground: app.foreground
        fontFamily: app.fontFamily
        bordered: true
        enabled: root.dirty && !root.saving
        opacity: enabled ? 1 : 0.45
        tooltipText: "Ctrl+S"
        onClicked: root.save()
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: "\uF08E"
        tooltipText: "Open in Azure DevOps  (Ctrl+O)"
        foreground: app.foreground
        fontFamily: app.fontFamily
        enabled: root.item !== null
        onClicked: app.openInBrowser(root.item.url)
      }
    }

    Text {
      Layout.fillWidth: true
      visible: root.errorText !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: root.errorText
      color: app.urgent
      font.family: app.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.max(1, Style.space(1))
      color: app.border
      opacity: 0.35
    }

    // ---------- body ----------
    // Side by side when there is room; stacked and scrolling in a narrow window.
    Flickable {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.item !== null
      clip: true
      contentWidth: width
      contentHeight: app.compact ? bodyGrid.implicitHeight : height
      interactive: app.compact
      boundsBehavior: Flickable.StopAtBounds

      GridLayout {
        id: bodyGrid
        width: parent.width
        height: app.compact ? implicitHeight : parent.height
        columns: app.compact ? 1 : 3
        columnSpacing: Style.space(18)
        rowSpacing: Style.space(14)

        // Left: editable fields.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 620
          spacing: Style.space(12)

          GridLayout {
            Layout.fillWidth: true
            // Label above each control; two columns in a narrow window.
            flow: GridLayout.TopToBottom
            rows: app.compact ? 4 : 2
            columnSpacing: Style.spacing.xl
            rowSpacing: Style.spacing.labelGap

            FieldLabel { text: "STATE" }
            Dropdown {
              id: stateDropdown
              Layout.fillWidth: true
              Layout.preferredWidth: Style.space(140)
              showLabel: false
              options: root.stateOptions()
              foreground: app.foreground
              fontFamily: app.fontFamily
              enabled: !root.saving
              onChanged: function(v) { root.draftState = v }
            }

            FieldLabel { text: "ASSIGNED TO" }
            SearchableDropdown {
              id: assigneeDropdown
              Layout.fillWidth: true
              Layout.preferredWidth: Style.space(260)
              showLabel: false
              options: root.assigneeOptions()
              placeholderText: "Find a person…"
              foreground: app.foreground
              fontFamily: app.fontFamily
              enabled: !root.saving
              onChanged: function(v) { root.draftAssignee = v }
            }

            FieldLabel { text: root.item && root.item.pointsField ? root.item.pointsLabel.toUpperCase() : "REMAINING (H)" }
            TextField {
              id: estimateField
              Layout.fillWidth: true
              Layout.preferredWidth: Style.space(100)
              foreground: app.foreground
              font.family: app.fontFamily
              enabled: root.item !== null && !root.saving && (root.item.pointsField !== "" || root.item.hasRemaining)
              placeholderText: root.item && (root.item.pointsField !== "" || root.item.hasRemaining) ? "–" : "n/a"
              inputMethodHints: Qt.ImhFormattedNumbersOnly
              onTextEdited: {
                if (root.item && root.item.pointsField) root.draftPoints = text
                else root.draftRemaining = text
              }
              onAccepted: root.save()
            }

            FieldLabel { text: "PRIORITY" }
            TextField {
              id: priorityField
              Layout.fillWidth: true
              Layout.preferredWidth: Style.space(80)
              foreground: app.foreground
              font.family: app.fontFamily
              enabled: root.item !== null && root.item.hasPriority && !root.saving
              placeholderText: root.item && root.item.hasPriority ? "1–4" : "n/a"
              inputMethodHints: Qt.ImhDigitsOnly
              onTextEdited: root.draftPriority = text
              onAccepted: root.save()
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.labelGap

            FieldLabel { text: "TAGS" }

            TextField {
              id: tagsField
              Layout.fillWidth: true
              foreground: app.foreground
              font.family: app.fontFamily
              enabled: root.item !== null && !root.saving
              placeholderText: "Separate tags with ;"
              onTextEdited: root.draftTags = text
              onAccepted: root.save()
            }
          }

          RowLayout {
            Layout.fillWidth: true
            FieldLabel { text: root.item ? root.item.bodyLabel.toUpperCase() : "DESCRIPTION" }
            Item { Layout.fillWidth: true }
            Text {
              textFormat: Text.PlainText
              text: root.item && root.item.bodyRich ? "Has images or tables · edit in the browser" : "**bold**  *italic*  - list  [link](url)"
              color: app.dim
              font.family: app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          NoteEditor {
            id: bodyEditor
            Layout.fillWidth: true
            Layout.fillHeight: !app.compact
            Layout.minimumHeight: Style.space(80)
            Layout.preferredHeight: app.compact ? Style.space(160) : -1
            readOnly: root.item === null || root.item.bodyRich || root.saving
            foreground: app.foreground
            fontFamily: app.fontFamily
            placeholderText: "No " + (root.item ? root.item.bodyLabel.toLowerCase() : "description") + " yet"
            onEdited: root.draftBody = text
          }

          FieldLabel {
            visible: root.item !== null && root.item.hasAcceptance
            text: "ACCEPTANCE CRITERIA" + (root.item && root.item.acceptanceRich ? "  ·  read-only" : "")
          }

          NoteEditor {
            id: acceptanceEditor
            visible: root.item !== null && root.item.hasAcceptance
            Layout.fillWidth: true
            Layout.fillHeight: !app.compact
            Layout.minimumHeight: Style.space(70)
            Layout.preferredHeight: app.compact ? Style.space(120) : -1
            readOnly: root.item === null || root.item.acceptanceRich || root.saving
            foreground: app.foreground
            fontFamily: app.fontFamily
            placeholderText: "No acceptance criteria yet"
            onEdited: root.draftAcceptance = text
          }
        }

        Rectangle {
          visible: !app.compact
          Layout.fillHeight: true
          Layout.preferredWidth: Math.max(1, Style.space(1))
          color: app.border
          opacity: 0.25
        }

        // Right: relations and discussion.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 380
          spacing: Style.space(10)

          FieldLabel {
            visible: root.item !== null && root.item.parent !== null
            text: "PARENT"
          }

          LinkRow {
            visible: root.item !== null && root.item.parent !== null
            Layout.fillWidth: true
            link: root.item && root.item.parent ? root.item.parent : null
          }

          FieldLabel {
            visible: root.item !== null && root.item.children.length > 0
            text: {
              if (!root.item) return ""
              var label = "CHILDREN"
              if (root.item.type === "Epic") label = "FEATURES"
              else if (root.item.type === "Feature") label = "USER STORIES"
              else if (root.item.type === "User Story" || root.item.type === "Bug") label = "TASKS"
              var done = root.item.children.filter(function(c) { return c.category === "done" }).length
              return label + "  ·  " + done + "/" + root.item.children.length + " DONE"
            }
          }

          ListView {
            id: childList
            visible: root.item !== null && root.item.children.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, app.rowHeight * 5)
            clip: true
            spacing: Style.spacing.xxs
            boundsBehavior: Flickable.StopAtBounds
            model: root.item ? root.item.children : []
            delegate: LinkRow {
              required property var modelData
              width: childList.width
              link: modelData
            }
          }

          RowLayout {
            Layout.fillWidth: true
            FieldLabel { text: "DISCUSSION" + (root.item && root.item.comments.length > 0 ? "  ·  " + root.item.comments.length : "") }
            Item { Layout.fillWidth: true }
            Text {
              textFormat: Text.PlainText
              text: root.posting ? "Posting…" : "Ctrl+Enter post"
              color: app.dim
              font.family: app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          NoteEditor {
            id: commentEditor
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(64)
            readOnly: root.item === null || root.posting
            foreground: app.foreground
            fontFamily: app.fontFamily
            placeholderText: "Add a comment…"
            onEdited: root.draftComment = text
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                root.postComment()
                event.accepted = true
              }
            }
          }

          ListView {
            id: commentList
            Layout.fillWidth: true
            Layout.fillHeight: !app.compact
            Layout.preferredHeight: app.compact ? Math.max(Style.space(60), contentHeight) : -1
            interactive: !app.compact
            clip: true
            spacing: Style.space(12)
            boundsBehavior: Flickable.StopAtBounds
            model: root.item ? root.item.comments : []

            delegate: Column {
              required property var modelData
              width: commentList.width
              spacing: Style.spacing.xxs

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: parent.modelData.author + "  ·  " + root.when(parent.modelData.date)
                color: app.isMine(app.me ? app.me.email : "") && app.me && parent.modelData.author === app.me.name ? app.selectedText : app.dim
                font.family: app.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: parent.modelData.text
                color: app.foreground
                font.family: app.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
            }

            Text {
              anchors.centerIn: parent
              visible: commentList.count === 0
              textFormat: Text.PlainText
              text: "No comments yet"
              color: app.dim
              font.family: app.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.item
              ? "Created by " + root.item.createdBy + " " + root.when(root.item.createdDate)
                + "  ·  changed by " + root.item.changedBy + " " + root.when(root.item.changedDate)
              : ""
            color: app.dim
            font.family: app.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.item === null

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.loading ? "Loading work item…" : ""
        color: app.foreground
        opacity: 0.7
        font.family: app.fontFamily
        font.pixelSize: Style.font.title
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: "Tab next field  ·  Ctrl+S save  ·  Ctrl+R reload  ·  Ctrl+O browser  ·  Esc leave field, then back"
      color: app.foreground
      opacity: 0.5
      font.family: app.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
    }
  }

  ConfirmDialog {
    id: confirm
    anchors.fill: parent
    z: 10
    opened: root.pendingAction !== ""
    message: "Discard " + root.changeCount + (root.changeCount === 1 ? " unsaved change?" : " unsaved changes?")
    confirmText: "Discard"
    foreground: app.foreground
    fontFamily: app.fontFamily
    background: Color.popups.background
    onCanceled: root.pendingAction = ""
    onConfirmed: {
      var action = root.pendingAction
      root.pendingAction = ""
      if (root.item) root.setItem(root.item)
      root.perform(action)
    }
  }

  component FieldLabel: Text {
    textFormat: Text.PlainText
    color: app.dim
    font.family: app.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1
    elide: Text.ElideRight
  }

  // A parent or child work item; click opens it.
  component LinkRow: CursorSurface {
    id: linkRow
    property var link: null

    implicitHeight: app.rowHeight
    height: app.rowHeight
    hasCursor: linkMouse.containsMouse
    foreground: app.foreground

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (linkRow.link) root.guard("open:" + linkRow.link.id)
    }

    Text {
      id: linkGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: {
        if (!linkRow.link) return ""
        if (linkRow.link.type === "Epic") return app.glyphEpic
        if (linkRow.link.type === "Feature") return app.glyphFeature
        if (linkRow.link.type === "Bug") return app.glyphBug
        if (linkRow.link.type === "Task") return app.stateGlyph(linkRow.link.category, linkRow.link.state)
        return app.glyphStory
      }
      color: linkRow.link ? app.stateColor(linkRow.link.state, linkRow.link.category, app.foreground) : app.foreground
      opacity: linkRow.link && linkRow.link.category === "done" ? 0.5 : 1
      font.family: app.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.left: linkGlyph.right
      anchors.leftMargin: Style.spacing.lg
      anchors.right: linkMeta.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: linkRow.link ? linkRow.link.id + "  " + linkRow.link.title : ""
      color: app.foreground
      opacity: linkRow.link && linkRow.link.category === "done" ? 0.5 : 1
      font.family: app.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: linkMeta
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: {
        if (!linkRow.link) return ""
        var parts = []
        if (linkRow.link.remaining !== null && linkRow.link.remaining !== undefined && linkRow.link.category !== "done")
          parts.push(linkRow.link.remaining + "h")
        if (linkRow.link.assignedTo) parts.push(app.initials(linkRow.link.assignedTo))
        parts.push(linkRow.link.state)
        return parts.join("  ")
      }
      color: app.dim
      font.family: app.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
