import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// Sprint board for an Azure DevOps team.
//
// One window with four views: "setup" (organization, project, token),
// "teams" (pick the team), "board" (the sprint's stories with their tasks as
// a keyboard list) and "detail" (view and edit one work item). All Azure
// DevOps traffic goes through devops.py, which answers every call with one
// JSON object; the board shows its cached copy first and refreshes behind it.
//
// Board keys: type to filter, Up/Down move, Right/Left expand or collapse a
// story, Enter opens, Tab switches All / Mine, Ctrl+H hides closed sprints
// and items, Ctrl+Left/Right changes
// sprint, Ctrl+T team, Ctrl+R refresh, Ctrl+O open in the browser, Ctrl+,
// connection settings, Escape clears the filter. Super+W closes the window.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool closingFromHost: false
  readonly property string windowTitle: "DevOps Board"
  property string view: "loading"
  property var status: null
  property var board: null
  property bool boardLoading: false
  property string boardError: ""
  property string iterationId: ""
  property bool mineOnly: false
  property bool hideClosed: false
  property bool showBacklog: false
  property int hiddenCount: 0
  property string filterText: ""
  property var expanded: ({})
  property int selectedIndex: 0
  property var stats: ({ tasks: 0, done: 0, doing: 0, blocked: 0, remaining: 0, points: 0, pointsDone: 0 })

  property var teams: []
  property string teamFilter: ""
  property int teamIndex: 0
  property bool teamsLoading: false
  property string teamsError: ""

  property int openItemId: 0

  property int boardSeq: 0

  readonly property string pluginId: (manifest && manifest.id) || "funcoder.devops-board"
  readonly property string helper: {
    var url = String(Qt.resolvedUrl("devops.py"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : url
  }

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color urgent: Color.urgent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.lg
  property int rowHeight: Math.max(Style.space(32), Style.font.body + Style.spacing.controlPaddingY * 2 + Style.space(8))

  // Layout breakpoints for the window width.
  readonly property bool compact: card.width < Style.space(900)
  readonly property bool narrow: card.width < Style.space(620)

  readonly property var me: (board && board.user) || (status && status.user) || null

  // State colours come from the current Omarchy theme's named colours.
  property var themeColors: ({})
  readonly property color colorBlocked: themeColor(["red", "color1"], Color.urgent)
  readonly property color colorActive: themeColor(["blue", "color4"], Color.accent)
  readonly property color colorReview: themeColor(["yellow", "color3"], "#e0af68")
  readonly property color colorDone: themeColor(["green", "color2"], "#9ece6a")

  // Nerd Font glyphs.
  readonly property string glyphBoard: "\uF0AE"
  readonly property string glyphEpic: "\uF073"
  readonly property string glyphFeature: "\uF0E8"
  readonly property string glyphStory: "\uF02D"
  readonly property string glyphBug: "\uF188"
  readonly property string glyphTodo: "\uF10C"
  readonly property string glyphDoing: "\uF042"
  readonly property string glyphDone: "\uF058"
  readonly property string glyphOpen: "\uF078"
  readonly property string glyphClosed: "\uF054"
  readonly property string glyphLeft: "\uF053"
  readonly property string glyphRight: "\uF054"
  readonly property string glyphTeam: "\uF0C0"
  readonly property string glyphSync: "\uF021"
  readonly property string glyphBlocked: "\uF05E"

  // ---- helper processes -------------------------------------------------------

  Component {
    id: jobComponent

    Process {
      id: job
      property string payload: ""
      property var callback: null
      property bool done: false
      stdinEnabled: payload !== ""
      onStarted: if (payload !== "") write(payload + "\n")
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: job.finish(text)
      }
      function finish(raw) {
        if (done) return
        done = true
        var data
        try {
          data = JSON.parse(String(raw || "").trim() || "{}")
        } catch (e) {
          data = { error: "The helper returned something unreadable" }
        }
        if (data && data.error)
          console.warn(root.pluginId + ": " + command.slice(1).join(" ") + ": " + data.error)
        var cb = callback
        callback = null
        try { if (cb) cb(data) } catch (e) { console.warn(root.pluginId + ": callback failed", e) }
        Qt.callLater(function() { job.destroy() })
      }
    }
  }

  // Runs devops.py with args; payload (an object) goes to stdin as one JSON line.
  function run(args, payload, callback) {
    var job = jobComponent.createObject(root, {
      command: [helper].concat(args),
      payload: payload ? JSON.stringify(payload) : ""
    })
    job.callback = callback
    job.running = true
  }

  // ---- open / close -----------------------------------------------------------------

  function open(payloadJson) {
    if (opened) {
      raise()
      return
    }
    opened = true
    themeFile.reload()
    filterText = ""
    if (view === "detail" || view === "teams") view = board ? "board" : "loading"
    if (!status || !status.connected) loadStatus()
    else refreshBoard()
    focusKeys()
  }

  // Host-initiated close (`shell hide`): the shell already knows.
  function close() {
    closingFromHost = true
    opened = false
    closingFromHost = false
  }

  // User-initiated close; tells the shell so `toggle` stays in step.
  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else opened = false
  }

  // Summoned while already open (maybe on another workspace): bring it here.
  function raise() {
    Quickshell.execDetached(["bash", "-c",
      "a=$(hyprctl clients -j | jq -r --arg t \"$1\" 'first(.[] | select(.title == $t) | .address) // empty'); "
      + "[ -n \"$a\" ] && hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$a\\\" })\"",
      "raise", windowTitle])
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  function focusKeys() {
    Qt.callLater(function() {
      if (view === "detail") detail.focusDefault()
      else if (view === "setup") setup.focusDefault()
      else keyCatcher.forceActiveFocus()
    })
  }

  function openInBrowser(url) {
    if (!url) return
    Quickshell.execDetached(["xdg-open", url])
  }

  // ---- connection -------------------------------------------------------------------

  function loadStatus() {
    if (view !== "board" && view !== "detail") view = "loading"
    run(["status"], null, function(data) {
      status = data
      hideClosed = data.hideClosed === true
      showBacklog = data.showBacklog === true
      if (data.error) {
        boardError = data.error
        view = "setup"
      } else if (!data.connected) {
        view = "setup"
      } else if (!data.team) {
        showTeams()
      } else {
        if (view !== "detail") view = "board"
        loadCachedBoard()
        refreshBoard()
      }
      focusKeys()
    })
  }

  function connected(data) {
    status = { connected: true, org: data.org, project: data.project, team: data.team, user: data.user }
    board = null
    iterationId = ""
    expanded = ({})
    if (data.teams && data.teams.length > 0) teams = data.teams
    if (!data.team) {
      showTeams(true)
    } else {
      view = "board"
      refreshBoard()
      focusKeys()
    }
  }

  function showSetup() {
    view = "setup"
    focusKeys()
  }

  // Team picker; loaded = true reuses the list connect just returned.
  function showTeams(loaded) {
    view = "teams"
    teamFilter = ""
    teamIndex = 0
    teamsError = ""
    focusKeys()
    if (loaded === true && teams.length > 0) return
    teamsLoading = true
    run(["teams"], null, function(data) {
      teamsLoading = false
      if (data.error) {
        teamsError = data.error
        return
      }
      teams = data.teams || []
      var current = board ? board.team : (status ? status.team : null)
      var list = filteredTeams()
      for (var i = 0; i < list.length; i++) if (current && list[i].id === current.id) teamIndex = i
    })
  }

  function filteredTeams() {
    var needle = teamFilter.toLowerCase()
    return teams.filter(function(t) {
      return needle === "" || t.name.toLowerCase().indexOf(needle) !== -1
        || String(t.project || "").toLowerCase().indexOf(needle) !== -1
    })
  }

  function pickTeam(team) {
    if (!team) return
    teamsLoading = true
    run(["set-team", team.id], null, function(data) {
      teamsLoading = false
      if (data.error) {
        teamsError = data.error
        return
      }
      if (status) status = Object.assign({}, status, { team: team, project: data.project || team.project || "" })
      board = null
      iterationId = ""
      expanded = ({})
      selectedIndex = 0
      view = "board"
      rebuild()
      loadCachedBoard()
      refreshBoard()
      focusKeys()
    })
  }

  // ---- board -----------------------------------------------------------------------

  function boardArgs() {
    var args = ["board"]
    if (showBacklog) args.push("--backlog")
    else if (iterationId) args.push("--iteration", iterationId)
    return args
  }

  function loadCachedBoard() {
    var seq = boardSeq
    run(boardArgs().concat(["--cached"]), null, function(data) {
      if (seq !== boardSeq || board || data.error || data.cacheMiss) return
      applyBoard(data)
    })
  }

  function refreshBoard() {
    var seq = ++boardSeq
    boardLoading = true
    run(boardArgs(), null, function(data) {
      if (seq !== boardSeq) return
      boardLoading = false
      if (data.error) {
        boardError = data.error
        if (/Choose a team/.test(data.error)) showTeams()
        else if (/Not connected|No token|Token rejected/.test(data.error) && !board) showSetup()
        return
      }
      boardError = ""
      applyBoard(data)
    })
  }

  function applyBoard(data) {
    board = data
    var s = { tasks: 0, done: 0, doing: 0, blocked: 0, remaining: 0, points: 0, pointsDone: 0 }
    var rows = data.rows || []
    var nextExpanded = Object.assign({}, expanded)
    // Walk the whole tree so stats reflect everything: Epics > Features >
    // Stories/Bugs > Tasks. "tasks" counts the leaves; "points" rolls up any
    // node that has points, including Features and parent items.
    function visit(node) {
      var kids = node.children || node.tasks || []
      if (node.type === "Task") {
        s.tasks++
        if (node.category === "done") s.done++
        else {
          if (node.category === "doing") s.doing++
          if (stateKind(node.state, node.category) === "blocked") s.blocked++
          s.remaining += Number(node.remaining) || 0
        }
      } else if (node.points) {
        s.points += node.points
        if (node.category === "done") s.pointsDone += node.points
      }
      var openLeaf = false
      for (var i = 0; i < kids.length; i++) {
        visit(kids[i])
        if (kids[i].type === "Task" && kids[i].category !== "done") openLeaf = true
      }
      if (kids.length > 0 && nextExpanded[node.id] === undefined) {
        nextExpanded[node.id] = openLeaf || (node.type !== "Task")
      }
    }
    for (var i = 0; i < rows.length; i++) visit(rows[i])
    s.remaining = Math.round(s.remaining * 10) / 10
    stats = s
    expanded = nextExpanded
    rebuild()
  }

  function changeSprint(delta) {
    if (showBacklog) {
      // Switching sprints turns backlog mode off and lands on the chosen sprint.
      showBacklog = false
      refreshBoard()
      return
    }
    if (!board || !board.iterations || board.iterations.length === 0) return
    var its = sprintChoices()
    var idx = -1
    for (var i = 0; i < its.length; i++) if (its[i].id === board.iteration.id) idx = i
    var next = Math.max(0, Math.min(its.length - 1, idx + delta))
    if (next === idx) return
    iterationId = its[next].id
    board = Object.assign({}, board, { iteration: its[next], rows: [] })
    stats = { tasks: 0, done: 0, doing: 0, blocked: 0, remaining: 0, points: 0, pointsDone: 0 }
    selectedIndex = 0
    rebuild()
    var seq = boardSeq
    run(["board", "--cached", "--iteration", iterationId], null, function(data) {
      if (seq === boardSeq - 1 && !data.error && !data.cacheMiss && board.rows.length === 0) applyBoard(data)
    })
    refreshBoard()
  }

  // Sprints the arrows step through; closed (past) ones drop out while hidden,
  // except the one being looked at.
  function sprintChoices() {
    if (!board || !board.iterations) return []
    return board.iterations.filter(function(it) {
      return !hideClosed || it.timeFrame !== "past" || it.id === board.iteration.id
    })
  }

  function setHideClosed(value) {
    hideClosed = value
    run(["pref", "hideClosed", value ? "on" : "off"], null, null)
    if (value && board && board.iteration && board.iteration.timeFrame === "past") {
      // Back to the current sprint.
      iterationId = ""
      board = Object.assign({}, board, { rows: [] })
      refreshBoard()
    }
    selectedIndex = 0
    rebuild()
    list.positionViewAtBeginning()
  }

  function setShowBacklog(value) {
    if (showBacklog === value) return
    showBacklog = value
    run(["pref", "showBacklog", value ? "on" : "off"], null, null)
    iterationId = ""
    board = null
    stats = { tasks: 0, done: 0, doing: 0, blocked: 0, remaining: 0, points: 0, pointsDone: 0 }
    selectedIndex = 0
    loadCachedBoard()
    refreshBoard()
  }

  function isMine(email) {
    return !!(me && me.email && email && email.toLowerCase() === me.email.toLowerCase())
  }

  function matches(item, needle) {
    if (needle === "") return true
    return String(item.title).toLowerCase().indexOf(needle) !== -1
      || String(item.id).indexOf(needle) !== -1
      || String(item.assignedTo || "").toLowerCase().indexOf(needle) !== -1
      || String(item.state || "").toLowerCase().indexOf(needle) === 0
      || (item.tags || []).join(" ").toLowerCase().indexOf(needle) !== -1
  }

  function initials(name) {
    var parts = String(name || "").replace(/\(.*\)/, "").trim().split(/\s+/).filter(function(p) { return p.length > 0 })
    if (parts.length === 0) return ""
    if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
    return (parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase()
  }

  function rowFor(item, level, extra) {
    var r = {
      kind: item.type === "Task" ? "task" : "node",
      itemId: Number(item.id) || 0,
      type: String(item.type || ""),
      level: level,
      title: String(item.title || ""),
      state: String(item.state || ""),
      category: String(item.category || ""),
      assignedTo: String(item.assignedTo || ""),
      mine: isMine(item.assignedEmail),
      points: item.points === null || item.points === undefined ? -1 : Number(item.points),
      remaining: item.remaining === null || item.remaining === undefined ? -1 : Number(item.remaining),
      tags: (item.tags || []).join("  "),
      taskTotal: 0,
      taskDone: 0,
      taskDoing: 0,
      hasChildren: false,
      isExpanded: false,
      lastChild: false,
      outside: item.inSprint === false
    }
    for (var k in extra) r[k] = extra[k]
    return r
  }

  function rebuild() {
    var keep = selectedIndex >= 0 && selectedIndex < rowsModel.count ? rowsModel.get(selectedIndex) : null
    var keepKey = keep ? keep.kind + ":" + keep.itemId : ""
    rowsModel.clear()
    if (!board) return
    var needle = filterText.toLowerCase().trim()
    var roots = board.rows || []
    var restore = -1
    var hidden = 0

    // Counters over the whole subtree, used both for the visible progress bar
    // on a parent row and for the "hide closed" rule. A node is "open" if any
    // descendant Task isn't done.
    function leafCounts(node) {
      var kids = (node.children && node.children.length > 0) ? node.children
        : (node.tasks && node.tasks.length > 0) ? node.tasks
        : []
      var total = 0, done = 0, doing = 0, leafOpen = false, hasTasks = false
      for (var i = 0; i < kids.length; i++) {
        var k = kids[i]
        if (k.type === "Task") {
          hasTasks = true
          total++
          if (k.category === "done") done++
          else {
            leafOpen = true
            if (k.category === "doing") doing++
          }
        } else {
          var sub = leafCounts(k)
          total += sub.total
          done += sub.done
          doing += sub.doing
          if (sub.leafOpen) leafOpen = true
          if (sub.hasTasks) hasTasks = true
        }
      }
      return { total: total, done: done, doing: doing, leafOpen: leafOpen, hasTasks: hasTasks }
    }

    function passesFilter(node) {
      if (needle === "" && !mineOnly) return true
      if (matches(node, needle)) return true
      var kids = (node.children && node.children.length > 0) ? node.children
        : (node.tasks && node.tasks.length > 0) ? node.tasks
        : []
      for (var i = 0; i < kids.length; i++) if (passesFilter(kids[i])) return true
      return false
    }

    function mineMatch(node) {
      if (!mineOnly) return true
      if (isMine(node.assignedEmail)) return true
      var kids = (node.children && node.children.length > 0) ? node.children
        : (node.tasks && node.tasks.length > 0) ? node.tasks
        : []
      for (var i = 0; i < kids.length; i++) if (mineMatch(kids[i])) return true
      return false
    }

    function appendNode(node, level) {
      var counts = leafCounts(node)
      var kids = (node.children && node.children.length > 0) ? node.children
        : (node.tasks && node.tasks.length > 0) ? node.tasks
        : []
      var openExpanded = needle !== "" || mineOnly || expanded[node.id] === true
      var isOpen = openExpanded && (kids.length > 0)

      var row = rowFor(node, level, {
        taskTotal: counts.total,
        taskDone: counts.done,
        taskDoing: counts.doing,
        hasChildren: kids.length > 0,
        isExpanded: isOpen
      })
      if (row.kind + ":" + row.itemId === keepKey) restore = rowsModel.count
      rowsModel.append(row)

      if (!isOpen) return
      var visible = []
      for (var i = 0; i < kids.length; i++) {
        var k = kids[i]
        if (k.type === "Task") {
          if (hideClosed && k.category === "done") {
            hidden++
            continue
          }
          visible.push(k)
        } else {
          if (hideClosed && k.category === "done" && !(leafCounts(k).leafOpen)) {
            hidden++
            continue
          }
          if (!passesFilter(k)) continue
          if (!mineMatch(k)) continue
          visible.push(k)
        }
      }
      for (var j = 0; j < visible.length; j++) {
        var child = visible[j]
        if (child.type === "Task") {
          var trow = rowFor(child, level + 1, { lastChild: j === visible.length - 1 })
          if (trow.kind + ":" + trow.itemId === keepKey) restore = rowsModel.count
          rowsModel.append(trow)
        } else {
          appendNode(child, level + 1)
        }
      }
    }

    for (var r = 0; r < roots.length; r++) {
      var root = roots[r]
      if (!passesFilter(root)) continue
      if (!mineMatch(root)) continue
      if (hideClosed && root.category === "done" && !(leafCounts(root).leafOpen)
          && root.id !== 0 && root.type !== "Task") {
        hidden++
        continue
      }
      appendNode(root, 0)
    }

    hiddenCount = hidden
    if (restore >= 0) selectedIndex = restore
    selectedIndex = Math.max(0, Math.min(rowsModel.count - 1, selectedIndex))
  }

  function setFilter(text) {
    filterText = text
    selectedIndex = 0
    rebuild()
    list.positionViewAtBeginning()
  }

  function moveSelection(delta) {
    if (rowsModel.count === 0) return
    selectedIndex = Math.max(0, Math.min(rowsModel.count - 1, selectedIndex + delta))
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function storyIndexFor(index) {
    for (var i = index; i >= 0; i--) if (rowsModel.get(i).kind === "node") return i
    return -1
  }

  function setExpanded(index, open) {
    if (index < 0 || index >= rowsModel.count) return
    var row = rowsModel.get(index)
    if (row.kind === "task") {
      if (open) return
      index = storyIndexFor(index)
      row = rowsModel.get(index)
    }
    if (!row.hasChildren || filterText !== "" || mineOnly) {
      selectedIndex = index
      return
    }
    var next = Object.assign({}, expanded)
    next[row.itemId] = open
    expanded = next
    selectedIndex = index
    rebuild()
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function toggleExpanded(index) {
    var row = rowsModel.get(index)
    if (row) setExpanded(index, !row.isExpanded)
  }

  function setMineOnly(value) {
    mineOnly = value
    selectedIndex = 0
    rebuild()
    list.positionViewAtBeginning()
  }

  function selectedRow() {
    return selectedIndex >= 0 && selectedIndex < rowsModel.count ? rowsModel.get(selectedIndex) : null
  }

  function workItemUrl(id) {
    if (!board || !id) return ""
    return board.org + "/" + encodeURIComponent(board.project) + "/_workitems/edit/" + id
  }

  function openItem(id) {
    if (!id) return
    openItemId = id
    view = "detail"
    detail.load(id)
  }

  function closeDetail() {
    view = board ? "board" : "loading"
    focusKeys()
  }

  // A saved item changes the board immediately; the full refresh follows.
  function itemSaved(item) {
    if (!board || !item) return
    var roots = board.rows || []
    var hit = false
    function patch(node) {
      if (node.id === item.id) {
        node.title = item.title
        node.state = item.state
        node.category = item.category
        node.assignedTo = item.assignedTo ? item.assignedTo.name : ""
        node.assignedEmail = item.assignedTo ? item.assignedTo.email : ""
        node.points = item.points
        node.remaining = item.remaining
        hit = true
        return
      }
      var kids = node.children || node.tasks || []
      for (var i = 0; i < kids.length; i++) patch(kids[i])
    }
    for (var r = 0; r < roots.length; r++) patch(roots[r])
    if (hit) applyBoard(board)
    refreshBoard()
  }

  // ---- text helpers ----------------------------------------------------------------

  readonly property var monthNames: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  function parseDay(iso) {
    if (!iso) return null
    var m = String(iso).match(/^(\d{4})-(\d{2})-(\d{2})/)
    return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null
  }

  function shortDate(iso) {
    var d = parseDay(iso)
    return d ? d.getDate() + " " + monthNames[d.getMonth()] : ""
  }

  function workingDays(from, to) {
    var n = 0
    var d = new Date(from.getTime())
    while (d <= to) {
      var day = d.getDay()
      if (day !== 0 && day !== 6) n++
      d.setDate(d.getDate() + 1)
    }
    return n
  }

  function sprintProgress() {
    if (!board || !board.iteration) return { text: "", fraction: 0 }
    var start = parseDay(board.iteration.start)
    var finish = parseDay(board.iteration.finish)
    if (!start || !finish) return { text: "No dates", fraction: 0 }
    var today = new Date()
    today = new Date(today.getFullYear(), today.getMonth(), today.getDate())
    var total = Math.max(1, workingDays(start, finish))
    if (today < start) {
      var until = Math.round((start - today) / 86400000)
      return { text: "Starts in " + until + (until === 1 ? " day" : " days"), fraction: 0 }
    }
    if (today > finish) {
      var ago = Math.round((today - finish) / 86400000)
      return { text: "Ended " + ago + (ago === 1 ? " day ago" : " days ago"), fraction: 1 }
    }
    var day = Math.max(1, workingDays(start, today))
    return { text: "Day " + Math.min(day, total) + " of " + total + " · " + (total - Math.min(day, total)) + " left", fraction: day / total }
  }

  function number(n) {
    return Math.round(n * 10) / 10
  }

  function statsText() {
    if (!board) return ""
    var parts = []
    parts.push(stats.done + " of " + stats.tasks + (stats.tasks === 1 ? " task" : " tasks") + " done")
    if (stats.doing > 0) parts.push(stats.doing + " in progress")
    if (stats.blocked > 0) parts.push(stats.blocked + " blocked")
    if (stats.remaining > 0) parts.push(number(stats.remaining) + "h left")
    if (stats.points > 0) parts.push(number(stats.pointsDone) + " of " + number(stats.points) + " points")
    if (hideClosed && hiddenCount > 0) parts.push(hiddenCount + " closed hidden")
    return parts.join("  ·  ")
  }

  function themeColor(keys, fallback) {
    for (var i = 0; i < keys.length; i++) if (themeColors[keys[i]]) return themeColors[keys[i]]
    return fallback
  }

  function loadThemeColors(raw) {
    var out = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) out[m[1]] = m[2]
    }
    themeColors = out
  }

  // "blocked", "review", "done", "active" or "todo". Blocked and review are
  // read from the state name, since processes file them under In Progress.
  function stateKind(state, category) {
    var name = String(state || "").toLowerCase()
    if (category === "done") return "done"
    if (/block|hold|imped|wait|stuck|paused/.test(name)) return "blocked"
    if (/review|test|qa|verif|resolved|ready|approval/.test(name) && category !== "todo") return "review"
    if (category === "doing") return "active"
    return "todo"
  }

  function stateColor(state, category, neutral) {
    var kind = stateKind(state, category)
    if (kind === "blocked") return colorBlocked
    if (kind === "review") return colorReview
    if (kind === "active") return colorActive
    if (kind === "done") return colorDone
    return neutral !== undefined ? neutral : dim
  }

  function stateGlyph(category, state) {
    if (category === "done") return glyphDone
    if (stateKind(state, category) === "blocked") return glyphBlocked
    return category === "doing" ? glyphDoing : glyphTodo
  }

  function updatedText() {
    if (boardLoading) return "Syncing…"
    if (!board || !board.fetchedAt) return ""
    var d = new Date(board.fetchedAt)
    if (isNaN(d.getTime())) return ""
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    return "Updated " + pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  function emptyText() {
    if (!board) return boardError !== "" ? boardError : (showBacklog ? "Loading the backlog…" : "Loading the sprint…")
    if (filterText !== "") return "Nothing matches “" + filterText + "”"
    if (mineOnly) return "Nothing assigned to you in " + (showBacklog ? "the team backlog" : board.iteration.name)
    if (boardLoading) return "Loading " + (showBacklog ? "the backlog" : board.iteration.name) + "…"
    if (hideClosed && hiddenCount > 0) return "Everything is closed  ·  Ctrl+H shows it"
    return showBacklog ? "No active items in the team backlog"
      : "Nothing planned for " + board.iteration.name
  }

  ListModel { id: rowsModel }

  FileView {
    id: themeFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadThemeColors(text())
    onFileChanged: reload()
  }

  IpcHandler {
    target: root.pluginId

    function toggle(): void { root.shell ? root.shell.toggle(root.pluginId, "{}") : root.toggle() }
    function close(): void { root.dismiss() }
    function refresh(): void { root.refreshBoard() }
    function item(id: int): void {
      if (!root.opened) root.shell ? root.shell.summon(root.pluginId, "{}") : root.open("{}")
      else root.raise()
      root.openItem(id)
    }
  }

  // Keep the cached board fresh while the card is open.
  Timer {
    interval: 120000
    running: root.opened && root.view === "board"
    repeat: true
    onTriggered: if (!root.boardLoading) root.refreshBoard()
  }

  // ---- window --------------------------------------------------------------------------

  // A normal Hyprland window: it tiles, moves between workspaces and closes
  // with the usual window keys.
  FloatingWindow {
    id: panel
    title: root.windowTitle
    visible: root.opened
    color: root.background
    implicitWidth: Style.space(1180)
    implicitHeight: Style.space(820)
    minimumSize: Qt.size(Style.space(720), Style.space(480))

    onVisibleChanged: {
      if (visible || !root.opened) return
      // Closed by the window manager (Super+W).
      root.opened = false
      if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    Item {
      id: card
      anchors.fill: parent
      anchors.margins: root.contentMargin

      Item {
        id: content
        anchors.fill: parent

        // ---------- loading ----------
        Text {
          anchors.centerIn: parent
          visible: root.view === "loading"
          textFormat: Text.PlainText
          text: root.boardError !== "" ? root.boardError : "Connecting to Azure DevOps…"
          color: root.boardError !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        // ---------- setup ----------
        Connection {
          id: setup
          anchors.fill: parent
          visible: root.view === "setup"
          app: root
        }

        // ---------- detail ----------
        ItemDetail {
          id: detail
          anchors.fill: parent
          visible: root.view === "detail"
          app: root
        }

        // ---------- board + team picker ----------
        Item {
          id: keyCatcher
          anchors.fill: parent
          visible: root.view === "board" || root.view === "teams"
          focus: visible

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (root.view === "teams") handleTeamKey(event)
            else handleBoardKey(event)
          }

          function printable(event) {
            var ctrl = (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) !== 0
            return !ctrl && event.text && event.text.length === 1
              && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
          }

          function handleTeamKey(event) {
            var list = root.filteredTeams()
            if (event.key === Qt.Key_Escape) {
              if (root.teamFilter !== "") root.teamFilter = ""
              else if (root.board || (root.status && root.status.team)) { root.view = "board"; root.focusKeys() }
              else root.showSetup()
            } else if (Util.editsFilter(event, root.teamFilter)) {
              root.teamFilter = Util.editedFilter(event, root.teamFilter)
              root.teamIndex = 0
            } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && event.modifiers & Qt.ControlModifier)) {
              root.teamIndex = Math.min(list.length - 1, root.teamIndex + 1)
              teamList.positionViewAtIndex(root.teamIndex, ListView.Contain)
            } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && event.modifiers & Qt.ControlModifier)) {
              root.teamIndex = Math.max(0, root.teamIndex - 1)
              teamList.positionViewAtIndex(root.teamIndex, ListView.Contain)
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (list.length > 0) root.pickTeam(list[Math.max(0, Math.min(list.length - 1, root.teamIndex))])
            } else if (event.key === Qt.Key_Comma && event.modifiers & Qt.ControlModifier) {
              root.showSetup()
            } else if (printable(event)) {
              root.teamFilter += event.text
              root.teamIndex = 0
            } else {
              return
            }
            event.accepted = true
          }

          function handleBoardKey(event) {
            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
            var row = root.selectedRow()
            if (event.key === Qt.Key_Escape) {
              if (root.filterText !== "") root.setFilter("")
            } else if (ctrl && event.key === Qt.Key_R) {
              root.refreshBoard()
            } else if (ctrl && event.key === Qt.Key_T) {
              root.showTeams()
            } else if (ctrl && event.key === Qt.Key_H) {
              root.setHideClosed(!root.hideClosed)
            } else if (ctrl && event.key === Qt.Key_B) {
              root.setShowBacklog(!root.showBacklog)
            } else if (ctrl && event.key === Qt.Key_Comma) {
              root.showSetup()
            } else if (ctrl && event.key === Qt.Key_O) {
              if (row) root.openInBrowser(root.workItemUrl(row.itemId))
            } else if (ctrl && (event.key === Qt.Key_Left || event.key === Qt.Key_BracketLeft)) {
              root.changeSprint(-1)
            } else if (ctrl && (event.key === Qt.Key_Right || event.key === Qt.Key_BracketRight)) {
              root.changeSprint(1)
            } else if (Util.editsFilter(event, root.filterText)) {
              root.setFilter(Util.editedFilter(event, root.filterText))
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              root.setMineOnly(!root.mineOnly)
            } else if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) {
              root.moveSelection(1)
            } else if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) {
              root.moveSelection(-1)
            } else if (event.key === Qt.Key_PageDown) {
              root.moveSelection(Math.max(1, Math.floor(list.height / root.rowHeight) - 1))
            } else if (event.key === Qt.Key_PageUp) {
              root.moveSelection(-Math.max(1, Math.floor(list.height / root.rowHeight) - 1))
            } else if (event.key === Qt.Key_Home) {
              root.moveSelection(-rowsModel.count)
            } else if (event.key === Qt.Key_End) {
              root.moveSelection(rowsModel.count)
            } else if (event.key === Qt.Key_Right) {
              root.setExpanded(root.selectedIndex, true)
            } else if (event.key === Qt.Key_Left) {
              root.setExpanded(root.selectedIndex, false)
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (row && row.itemId > 0) root.openItem(row.itemId)
            } else if (printable(event)) {
              root.setFilter(root.filterText + event.text)
            } else {
              return
            }
            event.accepted = true
          }

          Column {
            id: layout
            anchors.fill: parent
            spacing: root.contentSpacing

            // ---------- header ----------
            Item {
              id: header
              width: parent.width
              height: root.compact
                ? Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight) + (sprintNav.visible ? Style.spacing.lg + sprintNav.implicitHeight : 0)
                : Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, sprintNav.implicitHeight)

              Text {
                id: heroIcon
                anchors.left: parent.left
                anchors.verticalCenter: heroLabels.verticalCenter
                textFormat: Text.PlainText
                text: root.view === "teams" ? root.glyphTeam : root.glyphBoard
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }

              Column {
                id: heroLabels
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(14)
                anchors.right: root.compact ? parent.right : sprintNav.left
                anchors.rightMargin: root.compact ? 0 : root.contentSpacing
                anchors.verticalCenter: root.compact ? undefined : parent.verticalCenter
                anchors.top: root.compact ? parent.top : undefined
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.view === "teams"
                    ? "Choose your team"
                    : (root.showBacklog && root.board ? "Team backlog"
                      : (root.board ? root.board.team.name
                      : (root.status && root.status.team ? root.status.team.name : "Sprint board")))
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: {
                    if (root.view === "teams") {
                      var first = !(root.status && root.status.team)
                      var org = root.status && root.status.org ? root.status.org.replace(/^https?:\/\//, "") : ""
                      return ((first ? "Step 2 of 2  ·  " : "") + org + "  ·  " + root.teams.length + (root.teams.length === 1 ? " team" : " teams")).toUpperCase()
                    }
                    if (!root.board) return (root.status ? root.status.project : "").toUpperCase()
                    var parts = [root.board.project]
                    if (root.showBacklog) {
                      parts.push("FULL TEAM BACKLOG")
                    } else {
                      var it = root.board.iteration
                      if (it.start && it.finish) parts.push(root.shortDate(it.start) + " – " + root.shortDate(it.finish))
                      var p = root.sprintProgress().text
                      if (p) parts.push(p)
                    }
                    return parts.join("  ·  ").toUpperCase()
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                  elide: Text.ElideRight
                }
              }

              Row {
                id: sprintNav
                anchors.right: parent.right
                anchors.verticalCenter: root.compact ? undefined : parent.verticalCenter
                anchors.bottom: root.compact ? parent.bottom : undefined
                spacing: Style.spacing.sm
                visible: root.view === "board" && root.board !== null

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.glyphLeft
                  tooltipText: "Previous sprint  (Ctrl+←)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.changeSprint(-1)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(Math.max(Style.space(110), implicitWidth), root.narrow ? card.width * 0.26 : root.compact ? card.width * 0.4 : Style.space(320))
                  elide: Text.ElideRight
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: {
                    if (!root.board) return ""
                    if (root.showBacklog) return "Backlog"
                    return root.board.iteration.name
                      + (root.board.iteration.timeFrame === "current" ? "" : root.board.iteration.timeFrame === "past" ? "  (past)" : "  (next)")
                  }
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.glyphRight
                  tooltipText: "Next sprint  (Ctrl+→)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.changeSprint(1)
                }

                Item { width: Style.spacing.lg; height: 1 }

                Repeater {
                  model: ["All", "Mine"]

                  Rectangle {
                    required property int index
                    required property string modelData
                    readonly property bool active: (index === 1) === root.mineOnly

                    anchors.verticalCenter: parent.verticalCenter
                    width: tabLabel.implicitWidth + Style.spacing.controlPaddingX * 2
                    height: tabLabel.implicitHeight + Style.spacing.controlPaddingY * 2
                    radius: root.cornerRadius
                    color: active ? root.selectedBackground : "transparent"

                    Text {
                      id: tabLabel
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: parent.modelData
                      color: parent.active ? root.selectedText : root.foreground
                      opacity: parent.active ? 1 : 0.7
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setMineOnly(parent.index === 1)
                    }
                  }
                }

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.hideClosed ? "\uF070" : "\uF06E"
                  text: root.narrow ? "" : "Closed"
                  fontSize: Style.font.body
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  selected: root.hideClosed
                  tooltipText: root.hideClosed ? "Show closed sprints and items  (Ctrl+H)" : "Hide closed sprints and items  (Ctrl+H)"
                  onClicked: root.setHideClosed(!root.hideClosed)
                }

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "\uF03A"
                  text: root.narrow ? "" : "Backlog"
                  fontSize: Style.font.body
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  selected: root.showBacklog
                  tooltipText: root.showBacklog
                    ? "Back to the current sprint  (Ctrl+B)"
                    : "Show the full team backlog: every Epic, Feature, Story and Task in the project, not just what's in this sprint  (Ctrl+B)"
                  onClicked: root.setShowBacklog(!root.showBacklog)
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.glyphSync
                  tooltipText: "Refresh  (Ctrl+R)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.refreshBoard()
                }
              }
            }

            // ---------- sprint progress ----------
            Column {
              id: progress
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.view === "board" && root.board !== null && root.stats.tasks > 0 && !root.showBacklog

              Item {
                width: parent.width
                height: Style.space(6)

                Rectangle {
                  id: track
                  anchors.fill: parent
                  radius: height / 2
                  color: Util.alpha(root.foreground, 0.12)
                }

                Rectangle {
                  anchors.left: track.left
                  height: track.height
                  radius: track.radius
                  color: root.colorActive
                  width: root.stats.tasks > 0 ? track.width * (root.stats.done + root.stats.doing) / root.stats.tasks : 0
                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }

                Rectangle {
                  anchors.left: track.left
                  height: track.height
                  radius: track.radius
                  color: root.colorDone
                  width: root.stats.tasks > 0 ? Math.max(root.stats.done > 0 ? track.height : 0, track.width * root.stats.done / root.stats.tasks) : 0
                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }

                // Where the sprint calendar is today.
                Rectangle {
                  readonly property real fraction: root.sprintProgress().fraction
                  visible: fraction > 0 && fraction < 1
                  x: Math.round(track.width * fraction) - width / 2
                  anchors.verticalCenter: track.verticalCenter
                  width: Math.max(2, Style.space(2))
                  height: track.height + Style.space(8)
                  color: root.selectedText
                }
              }

              Item {
                width: parent.width
                height: statsLine.implicitHeight

                Text {
                  id: statsLine
                  anchors.left: parent.left
                  anchors.right: updatedLine.left
                  anchors.rightMargin: root.contentSpacing
                  textFormat: Text.PlainText
                  text: root.statsText()
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  id: updatedLine
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: root.boardError !== "" && root.board ? root.boardError : root.updatedText()
                  color: root.boardError !== "" && root.board ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: Math.min(implicitWidth, parent.width * 0.5)
                  elide: Text.ElideRight
                }
              }
            }

            // ---------- filter ----------
            Text {
              id: filterLine
              width: parent.width
              textFormat: Text.PlainText
              text: root.view === "teams"
                ? (root.teamFilter || "Type to find a team or project…")
                : (root.filterText || "Type to filter by title, id, person, state or tag…")
              color: root.foreground
              opacity: (root.view === "teams" ? root.teamFilter : root.filterText) ? 1 : 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              elide: Text.ElideRight
            }

            Rectangle {
              id: rule
              width: parent.width
              height: Math.max(1, Style.space(1))
              color: root.border
              opacity: 0.35
            }

            // ---------- rows ----------
            Item {
              width: parent.width
              height: parent.height - header.height - (progress.visible ? progress.height + root.contentSpacing : 0)
                - filterLine.height - rule.height - footer.height - root.contentSpacing * 4

              ListView {
                id: list
                anchors.fill: parent
                visible: root.view === "board"
                model: rowsModel
                clip: true
                spacing: Style.spacing.xxs
                boundsBehavior: Flickable.StopAtBounds
                delegate: BoardRow {}
              }

              Text {
                anchors.centerIn: parent
                width: parent.width
                visible: root.view === "board" && rowsModel.count === 0
                textFormat: Text.PlainText
                text: root.emptyText()
                color: root.boardError !== "" && !root.board ? root.urgent : root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
              }

              ListView {
                id: teamList
                anchors.fill: parent
                visible: root.view === "teams"
                model: root.view === "teams" ? root.filteredTeams() : []
                clip: true
                spacing: Style.spacing.xxs
                boundsBehavior: Flickable.StopAtBounds

                delegate: CursorSurface {
                  required property var modelData
                  required property int index
                  readonly property bool isCurrent: root.board ? root.board.team.id === modelData.id
                    : (root.status && root.status.team ? root.status.team.id === modelData.id : false)

                  width: teamList.width
                  height: root.rowHeight
                  hasCursor: index === root.teamIndex
                  current: isCurrent
                  foreground: root.foreground

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.right: teamProject.left
                    anchors.rightMargin: Style.spacing.xl
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: parent.modelData.name + (parent.isCurrent ? "   ·  current" : "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    id: teamProject
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, teamList.width * 0.4)
                    textFormat: Text.PlainText
                    text: parent.modelData.project || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.teamIndex = parent.index
                    onClicked: root.pickTeam(parent.modelData)
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                width: parent.width
                visible: root.view === "teams" && teamList.count === 0
                textFormat: Text.PlainText
                text: root.teamsLoading ? "Loading teams…" : (root.teamsError || "No team matches “" + root.teamFilter + "”")
                color: root.teamsError ? root.urgent : root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
              }
            }

            Text {
              id: footer
              width: parent.width
              textFormat: Text.PlainText
              text: root.view === "teams"
                ? "Type to filter  ·  ↑↓ select  ·  Enter choose  ·  Ctrl+, connection  ·  Esc back"
                : "↑↓ move  ·  →← expand  ·  Enter open  ·  Tab all/mine  ·  Ctrl+H hide closed  ·  Ctrl+B backlog  ·  Ctrl+←→ sprint  ·  Ctrl+T team  ·  Ctrl+O browser  ·  Ctrl+, connection  ·  Esc clear filter"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideLeft
            }
          }
        }
      }
    }
  }

  // One node or task in the hierarchy. Nodes carry a chevron, a roll-up
  // progress bar, and (for Stories/Bugs) their points; tasks are indented
  // and show remaining hours.
  component BoardRow: CursorSurface {
    id: row

    required property int index
    required property string kind
    required property int itemId
    required property string type
    required property int level
    required property string title
    required property string state
    required property string category
    required property string assignedTo
    required property bool mine
    required property real points
    required property real remaining
    required property string tags
    required property int taskTotal
    required property int taskDone
    required property int taskDoing
    required property bool hasChildren
    required property bool isExpanded
    required property bool outside

    readonly property bool isTask: kind === "task"
    readonly property bool isNode: kind === "node"
    readonly property bool isEpic: type === "Epic"
    readonly property bool isFeature: type === "Feature"
    readonly property bool isStory: type === "User Story" || type === "Bug"
    readonly property bool isDone: category === "done"
    readonly property int indent: isTask ? level * Style.space(22) : (level * Style.space(22))

    width: list.width
    height: root.rowHeight
    hasCursor: index === root.selectedIndex
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: root.selectedIndex = row.index
      onClicked: if (row.itemId > 0) root.openItem(row.itemId)
    }

    // Chevron (nodes that have children).
    Text {
      id: chevron
      visible: row.isNode && row.hasChildren
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.md + row.indent
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: row.isExpanded ? root.glyphOpen : root.glyphClosed
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleExpanded(row.index)
      }
    }

    // Tree line joining non-root rows to their parent.
    Rectangle {
      visible: row.level > 0
      x: Style.spacing.md + Style.space(7) + (row.level - 1) * Style.space(22)
      width: Math.max(1, Style.space(1))
      height: row.height + Style.spacing.xxs
      y: -Style.spacing.xxs
      color: Util.alpha(root.foreground, 0.18)
    }

    Text {
      id: glyph
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.md + Style.space(22) + row.indent
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: {
        if (row.itemId === 0) return root.glyphClosed
        if (row.isEpic) return root.glyphEpic
        if (row.isFeature) return root.glyphFeature
        if (row.isTask) return root.stateGlyph(row.category, row.state)
        if (row.type === "Bug") return root.glyphBug
        return root.glyphStory
      }
      color: row.itemId === 0 ? root.dim : root.stateColor(row.state, row.category, root.foreground)
      opacity: row.isDone ? 0.5 : 1
      font.family: root.fontFamily
      font.pixelSize: row.isEpic ? Style.font.heading
        : row.isFeature || row.isStory ? Style.font.title
        : Style.font.body
    }

    Text {
      id: idLabel
      anchors.left: glyph.right
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.narrow
      width: root.narrow ? 0 : Style.space(46)
      textFormat: Text.PlainText
      text: row.itemId > 0 ? String(row.itemId) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      anchors.left: idLabel.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: meta.left
      anchors.rightMargin: root.contentSpacing
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.lg
      clip: true

      Text {
        id: titleLabel
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, parent.width - (tagLabel.visible ? Math.min(tagLabel.implicitWidth, parent.width * 0.3) + parent.spacing : 0))
        textFormat: Text.PlainText
        text: row.title
        color: root.foreground
        opacity: row.isDone ? 0.5 : 1
        font.family: root.fontFamily
        font.pixelSize: row.isEpic ? Style.font.title
          : row.isFeature || row.isStory ? Style.font.subtitle
          : Style.font.body
        font.bold: row.isEpic || row.isFeature || row.isStory
        font.strikeout: false
        elide: Text.ElideRight
      }

      Text {
        id: tagLabel
        visible: !root.compact && (row.tags !== "" || row.outside)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, parent.width * 0.3)
        textFormat: Text.PlainText
        text: (row.outside ? "other sprint  " : "") + row.tags
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: meta
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xl

      // Roll-up progress bar for any node with descendant tasks.
      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: root.compact ? Style.space(40) : Style.space(96)
        height: countLabel.implicitHeight

        Item {
          visible: !root.compact && row.isNode && row.taskTotal > 0
          anchors.left: parent.left
          anchors.right: countLabel.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(4)

          Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(root.foreground, 0.12)
          }
          Rectangle {
            height: parent.height
            radius: height / 2
            color: root.colorActive
            width: row.taskTotal > 0 ? parent.width * (row.taskDone + row.taskDoing) / row.taskTotal : 0
          }
          Rectangle {
            height: parent.height
            radius: height / 2
            color: root.colorDone
            width: row.taskTotal > 0 ? parent.width * row.taskDone / row.taskTotal : 0
          }
        }

        Text {
          id: countLabel
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: row.isTask
            ? (row.remaining > 0 ? root.number(row.remaining) + "h" : "")
            : (row.taskTotal > 0 ? row.taskDone + "/" + row.taskTotal : "")
          color: row.isTask ? root.dim : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.narrow && row.isStory
        width: Style.space(44)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: row.isStory && row.points >= 0 ? root.number(row.points) + " pt" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.narrow
        width: root.compact ? Style.space(62) : Style.space(84)
        textFormat: Text.PlainText
        text: row.state
        color: root.stateColor(row.state, row.category)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.stateKind(row.state, row.category) !== "todo" && !row.isDone
        elide: Text.ElideRight
      }

      // Assignee initials; yours are filled.
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(26)
        height: width
        radius: width / 2
        color: row.mine ? root.selectedText : "transparent"
        border.width: row.assignedTo !== "" && !row.mine ? Math.max(1, Style.space(1)) : 0
        border.color: Util.alpha(root.foreground, 0.35)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: row.assignedTo !== "" ? root.initials(row.assignedTo) : "·"
          color: row.mine ? root.background : root.foreground
          opacity: row.assignedTo !== "" ? 1 : 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        MouseArea {
          id: avatarHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: avatarHover.containsMouse && row.assignedTo !== ""
          text: row.assignedTo
        }
      }
    }
  }
}
