import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "cjkaufman.google-tasks"
  ipcTarget: "cjkaufman.google-tasks"

  // Glyphs (Nerd Font / Material Design Symbols)
  readonly property string glyphBar: String.fromCodePoint(0xF0133)        // Tasks check icon
  readonly property string glyphUnchecked: String.fromCodePoint(0xF0131)  // Square unchecked
  readonly property string glyphChecked: String.fromCodePoint(0xF0132)    // Square checked
  readonly property string glyphAdd: String.fromCodePoint(0xF0415)        // Plus icon
  readonly property string glyphRefresh: String.fromCodePoint(0xF0450)    // Refresh icon
  readonly property string glyphCog: String.fromCodePoint(0xF0493)        // Settings gear
  readonly property string glyphKey: String.fromCodePoint(0xF0306)        // Key / Auth
  readonly property string glyphTrash: String.fromCodePoint(0xF01E0)      // Trash can
  readonly property string glyphCalendar: String.fromCodePoint(0xF00ED)   // Calendar

  readonly property string helper: Qt.resolvedUrl("bin/tasks-helper").toString().replace("file://", "")

  // Theme styling
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color subtleBg: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.07)
  readonly property color cardBg: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.04)
  readonly property color borderCol: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Plugin settings
  readonly property string prefListName: String(setting("targetListName", "My Tasks"))
  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 120)))
  readonly property bool prefShowCompleted: Boolean(setting("showCompleted", false))
  readonly property string countMode: String(setting("countMode", "all"))

  // State
  property bool authenticated: false
  property bool isConfigured: false
  property bool authPending: false
  property bool scanning: false
  property bool settingsOpen: false
  property string statusError: ""

  property var taskLists: []
  property string activeListId: ""
  property string activeListTitle: "My Tasks"

  property var tasks: []
  property var optimisticallyCompleted: ({})
  property bool showCompletedOverride: root.prefShowCompleted
  property string expandedTaskId: ""
  property var subtaskParent: null
  property var reminders: ({})

  readonly property string todayStr: isoDate(new Date())

  readonly property var openTasks: (tasks || []).filter(function (t) {
    return t.status === "needsAction" && !optimisticallyCompleted[t.id]
  })

  function isTaskCompleted(t) {
    return Boolean(t && (t.status === "completed" || root.optimisticallyCompleted[t.id]))
  }

  // Flattens the parent/child task graph into a display order: each task
  // immediately followed by its subtasks, indented one level. Google Tasks
  // itself only supports one level of nesting, so depth is not recursed
  // beyond that in the UI (see the "add subtask" button below, which only
  // appears on depth-0 rows).
  //
  // A completed task is dropped when `showCompleted` is off UNLESS it still
  // has a visible (incomplete) child -- otherwise completing a parent would
  // orphan an open subtask out of the list entirely.
  function buildDisplayList(list, showCompleted) {
    var byId = ({})
    var order = []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t || !t.id) continue
      byId[t.id] = { data: t, children: [] }
      order.push(t.id)
    }
    var roots = []
    for (var j = 0; j < order.length; j++) {
      var node = byId[order[j]]
      var parentId = node.data.parent
      if (parentId && byId[parentId]) byId[parentId].children.push(node)
      else roots.push(node)
    }
    function flatten(nodes, depth) {
      var out = []
      for (var k = 0; k < nodes.length; k++) {
        var n = nodes[k]
        var childOut = flatten(n.children, depth + 1)
        var completedNow = root.isTaskCompleted(n.data)
        var include = showCompleted || !completedNow || childOut.length > 0
        if (include) {
          var row = Object.assign({}, n.data, {
            depth: depth,
            hasChildren: n.children.length > 0,
            completedNow: completedNow
          })
          out.push(row)
          out = out.concat(childOut)
        }
      }
      return out
    }
    return flatten(roots, 0)
  }

  readonly property var displayTasks: root.buildDisplayList(root.tasks || [], root.showCompletedOverride)

  readonly property var dueTasks: openTasks.filter(function (t) {
    if (!t.due || t.due === "") return false
    var d = String(t.due).substring(0, 10)
    return d <= root.todayStr
  })

  readonly property int badgeCount: countMode === "none" ? 0 : (countMode === "due" ? dueTasks.length : openTasks.length)

  readonly property string summary: {
    if (!root.authenticated) return "Google Tasks: Sign in required"
    if (root.scanning && tasks.length === 0) return "Syncing Google Tasks…"
    if (openTasks.length === 0) return activeListTitle + ": All caught up!"
    var str = openTasks.length + (openTasks.length === 1 ? " task" : " tasks")
    return dueTasks.length > 0 ? activeListTitle + " (" + str + " · " + dueTasks.length + " due)" : activeListTitle + " (" + str + ")"
  }

  function isoDate(d) {
    return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2)
  }

  function formatDue(due) {
    if (!due || due === "") return ""
    var d = String(due).substring(0, 10)
    if (d < root.todayStr) return "Overdue"
    if (d === root.todayStr) return "Today"
    var tomorrow = new Date()
    tomorrow.setDate(tomorrow.getDate() + 1)
    if (d === isoDate(tomorrow)) return "Tomorrow"
    return d
  }

  function isOverdue(due) {
    if (!due || due === "") return false
    return String(due).substring(0, 10) < root.todayStr
  }

  function isDueToday(due) {
    if (!due || due === "") return false
    return String(due).substring(0, 10) === root.todayStr
  }

  function dueDateOnly(due) {
    return due ? String(due).substring(0, 10) : ""
  }

  readonly property var datePattern: /^\d{4}-\d{2}-\d{2}$/
  readonly property var dateTimePattern: /^(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})$/

  function isValidDate(s) {
    return root.datePattern.test(String(s || ""))
  }

  // Accepts "YYYY-MM-DD HH:MM" (local time) and returns epoch seconds, or
  // -1 if the string doesn't parse. Used for local reminder scheduling only
  // -- never sent to Google.
  function parseReminderInput(s) {
    var m = root.dateTimePattern.exec(String(s || "").trim())
    if (!m) return -1
    var d = new Date(Number(m[1].substring(0, 4)), Number(m[1].substring(5, 7)) - 1, Number(m[1].substring(8, 10)), Number(m[2]), Number(m[3]), 0, 0)
    var epoch = d.getTime() / 1000
    return isFinite(epoch) ? epoch : -1
  }

  function formatReminderEpoch(epoch) {
    if (!epoch) return ""
    var d = new Date(epoch * 1000)
    var pad = function (n) { return ("0" + n).slice(-2) }
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + " " + pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  // API Process triggers using stdin bounded IPC
  function checkStatus() {
    statusProc.inputPayload = JSON.stringify({ action: "status" })
    statusProc.running = true
  }

  function fetchLists() {
    if (!root.authenticated) return
    listListsProc.running = false
    listListsProc.inputPayload = JSON.stringify({ action: "list-lists" })
    listListsProc.running = true
  }

  function fetchTasks() {
    if (!root.authenticated || root.activeListId === "") return
    root.scanning = true
    listTasksProc.running = false
    listTasksProc.inputPayload = JSON.stringify({
      action: "list-tasks",
      list_id: root.activeListId,
      show_completed: root.showCompletedOverride
    })
    listTasksProc.running = true
  }

  function fetchReminders() {
    if (!root.authenticated) return
    listRemindersProc.running = false
    listRemindersProc.inputPayload = JSON.stringify({ action: "list-reminders" })
    listRemindersProc.running = true
  }

  function pollReminders() {
    if (!root.authenticated) return
    pollRemindersProc.running = false
    pollRemindersProc.inputPayload = JSON.stringify({ action: "poll-reminders" })
    pollRemindersProc.running = true
  }

  // `dueDate` is an optional "YYYY-MM-DD" string. `parentId` set means this
  // is a subtask of that task (Google Tasks supports exactly one level).
  function quickAddTask(title, dueDate, parentId) {
    var clean = String(title || "").trim()
    if (clean === "" || !root.authenticated) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    root.statusError = ""
    var due = String(dueDate || "").trim()
    var parent = String(parentId || "").trim()
    // Optimistic UI addition
    var tempTask = {
      id: "temp_" + Date.now(),
      title: clean,
      notes: "",
      status: "needsAction",
      due: due ? due + "T00:00:00.000Z" : "",
      parent: parent
    }
    root.tasks = [tempTask].concat(root.tasks || [])
    var payload = {
      action: "create-task",
      list_id: targetList,
      title: clean
    }
    if (due) payload.due = due + "T00:00:00.000Z"
    if (parent) payload.parent_id = parent
    createTaskProc.running = false
    createTaskProc.inputPayload = JSON.stringify(payload)
    createTaskProc.running = true
    root.subtaskParent = null
  }

  // `fields` may include title, notes, due (each optional; due: "" clears it).
  function updateTask(task, fields) {
    if (!task || !task.id || !root.authenticated) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    var payload = {
      action: "update-task",
      list_id: targetList,
      task_id: task.id
    }
    if (fields.title !== undefined) payload.title = fields.title
    if (fields.notes !== undefined) payload.notes = fields.notes
    if (fields.due !== undefined) payload.due = fields.due
    // Optimistic local patch so the row reflects the edit immediately.
    root.tasks = (root.tasks || []).map(function (t) {
      if (t.id !== task.id) return t
      return Object.assign({}, t, fields)
    })
    updateTaskProc.running = false
    updateTaskProc.inputPayload = JSON.stringify(payload)
    updateTaskProc.running = true
  }

  function setReminder(task, epochSeconds) {
    if (!task || !task.id || !root.authenticated) return
    setReminderProc.inputPayload = JSON.stringify({
      action: "set-reminder",
      task_id: task.id,
      remind_at_epoch: epochSeconds,
      title: task.title,
      list_id: root.activeListId || "@default"
    })
    setReminderProc.running = true
    var next = Object.assign({}, root.reminders)
    next[task.id] = { remind_at_epoch: epochSeconds, fired: false }
    root.reminders = next
  }

  function clearReminder(task) {
    if (!task || !task.id) return
    clearReminderProc.inputPayload = JSON.stringify({ action: "clear-reminder", task_id: task.id })
    clearReminderProc.running = true
    var next = Object.assign({}, root.reminders)
    delete next[task.id]
    root.reminders = next
  }

  function toggleTaskComplete(task) {
    if (!task || !task.id || !root.authenticated) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    var updated = Object.assign({}, root.optimisticallyCompleted)
    if (task.status === "needsAction") {
      updated[task.id] = true
      root.optimisticallyCompleted = updated
      completeTaskProc.inputPayload = JSON.stringify({
        action: "complete-task",
        list_id: targetList,
        task_id: task.id
      })
      completeTaskProc.running = true
    } else {
      delete updated[task.id]
      root.optimisticallyCompleted = updated
      uncompleteTaskProc.inputPayload = JSON.stringify({
        action: "uncomplete-task",
        list_id: targetList,
        task_id: task.id
      })
      uncompleteTaskProc.running = true
    }
  }

  function deleteTask(task) {
    if (!task || !task.id || !root.authenticated || deleteTaskProc.running) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    // Optimistically remove from local tasks array
    root.tasks = (root.tasks || []).filter(function(t) { return t.id !== task.id })
    deleteTaskProc.inputPayload = JSON.stringify({
      action: "delete-task",
      list_id: targetList,
      task_id: task.id
    })
    deleteTaskProc.running = true
  }

  function startAuthFlow(clientId, clientSecret) {
    root.authPending = true
    root.statusError = ""
    authProc.inputPayload = JSON.stringify({
      action: "auth",
      client_id: String(clientId || "").trim(),
      client_secret: String(clientSecret || "").trim()
    })
    authProc.running = true
  }

  function logout() {
    logoutProc.inputPayload = JSON.stringify({ action: "logout" })
    logoutProc.running = true
  }

  Component.onCompleted: {
    root.checkStatus()
  }

  onOpenedChanged: {
    if (opened) {
      checkStatus()
      if (root.authenticated) {
        root.fetchLists()
      }
    }
  }

  // Periodic Refresh
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.authenticated) {
        root.fetchLists()
      } else {
        checkStatus()
      }
    }
  }

  // Local reminder check. Runs regardless of whether the panel is open --
  // this component is mounted for the lifetime of the bar -- since a
  // reminder has to fire whether or not you're looking at the popup. The
  // helper process itself fires the desktop notification; this just has to
  // invoke it periodically.
  Timer {
    interval: 20000
    running: root.authenticated
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollReminders()
  }

  // Process Handlers (All pass sensitive and private content over stdin)
  Process {
    id: statusProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(String(text || "{}"))
          root.authenticated = res.authenticated === true
          root.isConfigured = res.configured === true
          if (res.client_id && clientIdInput && clientIdInput.text === "") {
            clientIdInput.text = res.client_id
          }
          if (res.client_secret && clientSecretInput && clientSecretInput.text === "") {
            clientSecretInput.text = res.client_secret
          }
          if (root.authenticated && root.taskLists.length === 0) {
            root.fetchLists()
          }
        } catch (e) {
          console.warn("tasks-helper status parse error", e)
        }
      }
    }
  }

  Process {
    id: listListsProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(String(text || "[]"))
          if (Array.isArray(arr) && arr.length > 0) {
            root.taskLists = arr.slice(0, 25)
            var target = null
            for (var i = 0; i < root.taskLists.length; i++) {
              if (root.taskLists[i].id === root.activeListId) {
                target = root.taskLists[i]
                break
              }
            }
            if (!target && root.prefListName) {
              for (var j = 0; j < root.taskLists.length; j++) {
                if (root.taskLists[j].title.toLowerCase() === root.prefListName.toLowerCase() || root.taskLists[j].id === root.prefListName) {
                  target = root.taskLists[j]
                  break
                }
              }
            }
            if (!target) target = root.taskLists[0]
            root.activeListId = target.id
            root.activeListTitle = target.title
            root.statusError = ""
            root.fetchTasks()
          }
        } catch (e) {
          console.warn("list-lists parse error", e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("listListsProc error:", text)
          try {
            var err = JSON.parse(text)
            var errMsg = String(err.error || text)
            if (errMsg.indexOf("Token refresh failed") !== -1 || errMsg.indexOf("invalid_grant") !== -1 || errMsg.indexOf("Not authenticated") !== -1) {
              root.authenticated = false
            }
            root.statusError = errMsg.substring(0, 250)
          } catch (e) {
            if (text.indexOf("Token refresh failed") !== -1 || text.indexOf("invalid_grant") !== -1 || text.indexOf("Not authenticated") !== -1) {
              root.authenticated = false
            }
            root.statusError = String(text).substring(0, 250)
          }
        }
      }
    }
  }

  Process {
    id: listTasksProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.scanning = false
        try {
          var items = JSON.parse(String(text || "[]"))
          if (Array.isArray(items)) {
            root.tasks = items.slice(0, 100)
            root.optimisticallyCompleted = ({})
            root.fetchReminders()
          }
        } catch (e) {
          console.warn("list-tasks parse error", e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.scanning = false
        if (text && text.trim() !== "") {
          console.warn("listTasksProc error:", text)
          try {
            var err = JSON.parse(text)
            var errMsg = String(err.error || text)
            if (errMsg.indexOf("Token refresh failed") !== -1 || errMsg.indexOf("invalid_grant") !== -1 || errMsg.indexOf("Not authenticated") !== -1) {
              root.authenticated = false
            }
            if (errMsg.indexOf("404") !== -1 || errMsg.indexOf("not found") !== -1 || errMsg.indexOf("notFound") !== -1) {
              root.activeListId = ""
              root.fetchLists()
              return
            }
            root.statusError = errMsg.substring(0, 250)
          } catch (e) {
            if (text.indexOf("Token refresh failed") !== -1 || text.indexOf("invalid_grant") !== -1 || text.indexOf("Not authenticated") !== -1) {
              root.authenticated = false
            }
            if (text.indexOf("404") !== -1 || text.indexOf("not found") !== -1 || text.indexOf("notFound") !== -1) {
              root.activeListId = ""
              root.fetchLists()
              return
            }
            root.statusError = String(text).substring(0, 250)
          }
        }
      }
    }
  }

  Process {
    id: createTaskProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    onExited: root.fetchTasks()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("createTaskProc error:", text)
          try {
            var err = JSON.parse(text)
            root.statusError = String(err.error || text).substring(0, 250)
          } catch (e) {
            root.statusError = String(text).substring(0, 250)
          }
        }
      }
    }
  }

  Process {
    id: completeTaskProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    onExited: root.fetchTasks()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("completeTaskProc error:", text)
        }
      }
    }
  }

  Process {
    id: uncompleteTaskProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    onExited: root.fetchTasks()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("uncompleteTaskProc error:", text)
        }
      }
    }
  }

  Process {
    id: deleteTaskProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    onExited: root.fetchTasks()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("deleteTaskProc error:", text)
        }
      }
    }
  }

  Process {
    id: updateTaskProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    onExited: root.fetchTasks()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("updateTaskProc error:", text)
          try {
            var err = JSON.parse(text)
            root.statusError = String(err.error || text).substring(0, 250)
          } catch (e) {
            root.statusError = String(text).substring(0, 250)
          }
        }
      }
    }
  }

  Process {
    id: setReminderProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") console.warn("setReminderProc error:", text)
      }
    }
  }

  Process {
    id: clearReminderProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") console.warn("clearReminderProc error:", text)
      }
    }
  }

  Process {
    id: listRemindersProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(String(text || "{}"))
          if (res && typeof res === "object") root.reminders = res
        } catch (e) {
          console.warn("list-reminders parse error", e)
        }
      }
    }
  }

  Process {
    id: pollRemindersProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    onExited: root.fetchReminders()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") console.warn("pollRemindersProc error:", text)
      }
    }
  }

  Process {
    id: authProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.authPending = false
        root.checkStatus()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          root.authPending = false
          try {
            var err = JSON.parse(text)
            root.statusError = String(err.error || text).substring(0, 250)
          } catch(e) {
            root.statusError = String(text).substring(0, 250)
          }
        }
      }
    }
  }

  Process {
    id: logoutProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.authenticated = false
        root.tasks = []
        root.taskLists = []
        root.activeListId = ""
        root.checkStatus()
      }
    }
  }

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  // Top Bar Icon
  WidgetButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: root.badgeCount > 0 ? (root.glyphBar + " " + root.badgeCount) : root.glyphBar
    dimmed: !root.authenticated || root.badgeCount === 0
    tooltipText: root.summary
    onPressed: function (btn) {
      if (btn === Qt.RightButton) {
        root.fetchTasks()
      } else {
        root.toggle()
      }
    }
  }

  // Dropdown Popup Panel
  KeyboardPanel {
    id: panel
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: addField
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(mainCol.implicitHeight + Style.space(24), Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus || clientIdInput.activeFocus || clientSecretInput.activeFocus || dueField.activeFocus || root.expandedTaskId !== ""
      onCloseRequested: root.close()
      onTabRequested: function (dir) { root.switchPanel(dir) }
      onTextKey: function (k) {
        if (k === "a" || k === "A") addField.forceActiveFocus()
        else if (k === "r" || k === "R") root.fetchTasks()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: mainCol
          width: flick.width
          spacing: Style.space(12)

          // Header
          Item {
            width: parent.width
            implicitHeight: Math.max(headerLabels.implicitHeight, headerActions.implicitHeight)

            Row {
              id: headerLabels
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                text: root.glyphBar
                textFormat: Text.PlainText
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: root.activeListTitle
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  text: root.summary
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                visible: root.authenticated
                iconText: root.glyphChecked
                tooltipText: root.showCompletedOverride ? "Hide completed tasks" : "Show completed tasks"
                foreground: root.showCompletedOverride ? root.accent : root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.showCompletedOverride = !root.showCompletedOverride
                  root.fetchTasks()
                }
              }

              PanelActionButton {
                iconText: root.glyphRefresh
                tooltipText: "Sync Google Tasks"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.statusError = ""
                  if (root.authenticated) root.fetchLists()
                  else root.checkStatus()
                }
              }

              PanelActionButton {
                iconText: root.glyphCog
                tooltipText: root.settingsOpen ? "Close Settings" : "OAuth & Account Settings"
                foreground: root.settingsOpen ? root.accent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.settingsOpen = !root.settingsOpen
              }
            }
          }

          // Settings / OAuth Auth Section
          Rectangle {
            id: settingsBox
            visible: root.settingsOpen || !root.authenticated
            width: parent.width
            implicitHeight: settingsCol.implicitHeight + Style.space(20)
            color: root.subtleBg
            radius: 8
            border.color: root.borderCol
            border.width: 1

            Column {
              id: settingsCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: root.authenticated ? "Google Account Connected" : "Connect Google Tasks"
                  textFormat: Text.PlainText
                  color: root.authenticated ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Button {
                  visible: root.authenticated
                  text: "Sign Out"
                  onClicked: root.logout()
                }
              }

              Text {
                visible: !root.authenticated
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.isConfigured ? "Credentials configured. Click below to sign in with your Google account." : "Provide your Google Cloud Desktop Client credentials to sign in. See README for 2-minute setup guide."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Column {
                visible: !root.authenticated
                width: parent.width
                spacing: Style.space(6)

                TextField {
                  id: clientIdInput
                  width: parent.width
                  placeholderText: "Google Client ID (.apps.googleusercontent.com)"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  background: Rectangle {
                    color: root.cardBg
                    border.color: root.borderCol
                    radius: 4
                  }
                }

                TextField {
                  id: clientSecretInput
                  width: parent.width
                  placeholderText: "Google Client Secret"
                  echoMode: TextInput.Password
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  background: Rectangle {
                    color: root.cardBg
                    border.color: root.borderCol
                    radius: 4
                  }
                }

                Button {
                  width: parent.width
                  text: root.authPending ? "Waiting for Browser Login…" : "Sign In with Google"
                  enabled: !root.authPending
                  onClicked: root.startAuthFlow(clientIdInput.text, clientSecretInput.text)
                }
              }

              Text {
                visible: root.statusError !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.statusError
                textFormat: Text.PlainText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // List selector if authenticated
              Column {
                visible: root.authenticated && root.taskLists.length > 1
                width: parent.width
                spacing: Style.space(4)

                Text {
                  text: "Switch Task List:"
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: root.taskLists
                    delegate: Rectangle {
                      implicitWidth: listLabel.implicitWidth + Style.space(16)
                      implicitHeight: Style.space(26)
                      color: root.activeListId === modelData.id ? root.accent : root.cardBg
                      radius: 13
                      border.color: root.borderCol

                      Text {
                        id: listLabel
                        anchors.centerIn: parent
                        text: String(modelData.title || "")
                        textFormat: Text.PlainText
                        color: root.activeListId === modelData.id ? "#ffffff" : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.activeListId = modelData.id
                          root.activeListTitle = modelData.title
                          root.fetchTasks()
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // Quick Add Box
          Column {
            visible: root.authenticated
            width: parent.width
            spacing: Style.space(6)

            // Subtask-mode banner. Shown after clicking "+" on a top-level
            // task; the next quick-add creates a subtask of it instead.
            Rectangle {
              visible: root.subtaskParent !== null
              width: parent.width
              implicitHeight: Style.space(26)
              color: root.subtleBg
              radius: 6

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: "Adding subtask to “" + (root.subtaskParent ? String(root.subtaskParent.title) : "") + "”"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  implicitWidth: Style.space(18)
                  implicitHeight: Style.space(18)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.subtaskParent = null
                  Text {
                    anchors.centerIn: parent
                    text: "✕"
                    textFormat: Text.PlainText
                    color: root.dim
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Rectangle {
              id: quickAddBox
              width: parent.width
              implicitHeight: Style.space(38)
              color: root.cardBg
              radius: 6
              border.color: addField.activeFocus ? root.accent : root.borderCol
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(6)

                MouseArea {
                  implicitWidth: Style.space(24)
                  implicitHeight: Style.space(24)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: quickAddBox.submit()

                  Text {
                    anchors.centerIn: parent
                    text: root.glyphAdd
                    textFormat: Text.PlainText
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                TextField {
                  id: addField
                  Layout.fillWidth: true
                  placeholderText: root.subtaskParent ? "Subtask title… (Enter to save)" : "Add a task or reminder… (Enter to save)"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  background: null
                  selectByMouse: true
                  onAccepted: quickAddBox.submit()
                  Keys.onReturnPressed: function(event) { quickAddBox.submit(); event.accepted = true }
                  Keys.onEnterPressed: function(event) { quickAddBox.submit(); event.accepted = true }
                }

                PanelActionButton {
                  visible: root.subtaskParent === null
                  iconText: root.glyphCalendar
                  tooltipText: dueField.visible ? "Remove due date" : "Set a due date"
                  foreground: dueField.visible ? root.accent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    dueField.visible = !dueField.visible
                    if (!dueField.visible) dueField.text = ""
                  }
                }
              }

              function submit() {
                if (addField.text.trim() === "") return
                if (dueField.visible && dueField.text.trim() !== "" && !root.isValidDate(dueField.text)) {
                  root.statusError = "Due date must be YYYY-MM-DD"
                  return
                }
                root.quickAddTask(addField.text, dueField.visible ? dueField.text : "", root.subtaskParent ? root.subtaskParent.id : "")
                addField.text = ""
                dueField.text = ""
                dueField.visible = false
              }
            }

            TextField {
              id: dueField
              visible: false
              width: parent.width
              placeholderText: "Due date: YYYY-MM-DD (e.g. " + root.todayStr + ")"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              background: Rectangle {
                color: root.cardBg
                border.color: root.borderCol
                radius: 4
              }
              onAccepted: quickAddBox.submit()
            }
          }

          // Tasks List
          Column {
            visible: root.authenticated
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.displayTasks
              delegate: Rectangle {
                id: taskCard
                width: parent.width
                implicitHeight: cardColumn.implicitHeight + Style.space(14)
                color: root.cardBg
                radius: 6
                border.color: root.borderCol
                border.width: 1

                readonly property bool isCompleted: Boolean(modelData && (modelData.status === "completed" || root.optimisticallyCompleted[modelData.id]))
                readonly property bool isExpanded: Boolean(modelData) && root.expandedTaskId === modelData.id
                readonly property var reminderInfo: (modelData && root.reminders[modelData.id]) ? root.reminders[modelData.id] : null

                Column {
                  id: cardColumn
                  x: Style.space(8)
                  y: Style.space(7)
                  width: parent.width - Style.space(16)
                  spacing: Style.space(8)

                  RowLayout {
                    id: cardContent
                    width: parent.width
                    spacing: Style.space(10)

                    // Subtask indent
                    Item {
                      implicitWidth: (modelData.depth || 0) * Style.space(18)
                      implicitHeight: 1
                    }

                    // Checkbox
                    MouseArea {
                      Layout.alignment: Qt.AlignVCenter
                      implicitWidth: Style.space(24)
                      implicitHeight: Style.space(24)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleTaskComplete(modelData)

                      Text {
                        anchors.centerIn: parent
                        text: taskCard.isCompleted ? root.glyphChecked : root.glyphUnchecked
                        textFormat: Text.PlainText
                        color: taskCard.isCompleted ? root.accent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }

                    // Title & Notes -- click to expand the editor
                    MouseArea {
                      Layout.fillWidth: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.expandedTaskId = taskCard.isExpanded ? "" : modelData.id

                      ColumnLayout {
                        width: parent.width
                        spacing: Style.space(2)

                        RowLayout {
                          Layout.fillWidth: true
                          spacing: Style.space(6)

                          Text {
                            Layout.fillWidth: true
                            text: String((modelData && modelData.title) || "")
                            textFormat: Text.PlainText
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            wrapMode: Text.WordWrap
                            font.strikeout: taskCard.isCompleted
                          }

                          Text {
                            visible: taskCard.reminderInfo !== null && !taskCard.reminderInfo.fired
                            text: "⏰"
                            textFormat: Text.PlainText
                            font.pixelSize: Style.font.caption
                          }
                        }

                        Text {
                          visible: Boolean(modelData && modelData.notes && String(modelData.notes).trim() !== "")
                          Layout.fillWidth: true
                          text: String((modelData && modelData.notes) || "")
                          textFormat: Text.PlainText
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                          maximumLineCount: 2
                        }
                      }
                    }

                    // Due Badge
                    Rectangle {
                      visible: Boolean(modelData && modelData.due && String(modelData.due) !== "")
                      implicitWidth: dueText.implicitWidth + Style.space(10)
                      implicitHeight: Style.space(20)
                      radius: 10
                      color: root.isOverdue(modelData ? modelData.due : "") ? root.urgent : (root.isDueToday(modelData ? modelData.due : "") ? root.accent : root.subtleBg)

                      Text {
                        id: dueText
                        anchors.centerIn: parent
                        text: root.formatDue(modelData.due)
                        textFormat: Text.PlainText
                        color: (root.isOverdue(modelData.due) || root.isDueToday(modelData.due)) ? "#ffffff" : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    // Add subtask -- Google Tasks only supports one level of
                    // nesting, so this only appears on top-level tasks.
                    MouseArea {
                      visible: (modelData.depth || 0) === 0
                      Layout.alignment: Qt.AlignVCenter
                      implicitWidth: Style.space(20)
                      implicitHeight: Style.space(20)
                      cursorShape: Qt.PointingHandCursor
                      opacity: 0.6
                      onClicked: {
                        root.subtaskParent = modelData
                        addField.forceActiveFocus()
                      }

                      Text {
                        anchors.centerIn: parent
                        text: root.glyphAdd
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    // Delete action
                    MouseArea {
                      Layout.alignment: Qt.AlignVCenter
                      implicitWidth: Style.space(20)
                      implicitHeight: Style.space(20)
                      cursorShape: Qt.PointingHandCursor
                      opacity: 0.6
                      onClicked: root.deleteTask(modelData)

                      Text {
                        anchors.centerIn: parent
                        text: root.glyphTrash
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  // Expanded editor: title, notes, due date, and a local
                  // reminder time. Google's API has no field for the
                  // reminder, so it's stored and fired locally (see
                  // set-reminder/poll-reminders in bin/tasks-helper).
                  Rectangle {
                    id: detailBox
                    visible: taskCard.isExpanded
                    width: parent.width
                    implicitHeight: visible ? detailCol.implicitHeight + Style.space(20) : 0
                    color: root.subtleBg
                    radius: 6
                    border.color: root.borderCol
                    border.width: 1

                    property string rowError: ""

                    Column {
                      id: detailCol
                      anchors.fill: parent
                      anchors.margins: Style.space(10)
                      spacing: Style.space(6)

                      TextField {
                        id: titleField
                        width: parent.width
                        text: modelData ? String(modelData.title || "") : ""
                        placeholderText: "Title"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        background: Rectangle { color: root.cardBg; border.color: root.borderCol; radius: 4 }
                      }

                      TextField {
                        id: notesField
                        width: parent.width
                        text: modelData ? String(modelData.notes || "") : ""
                        placeholderText: "Notes"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        background: Rectangle { color: root.cardBg; border.color: root.borderCol; radius: 4 }
                      }

                      TextField {
                        id: dueEditField
                        width: parent.width
                        text: modelData ? root.dueDateOnly(modelData.due) : ""
                        placeholderText: "Due date: YYYY-MM-DD (blank to clear)"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        background: Rectangle { color: root.cardBg; border.color: root.borderCol; radius: 4 }
                      }

                      RowLayout {
                        width: parent.width
                        spacing: Style.space(6)

                        Button {
                          text: "Save"
                          onClicked: {
                            var due = dueEditField.text.trim()
                            if (due !== "" && !root.isValidDate(due)) {
                              detailBox.rowError = "Due date must be YYYY-MM-DD"
                              return
                            }
                            if (titleField.text.trim() === "") {
                              detailBox.rowError = "Title cannot be empty"
                              return
                            }
                            detailBox.rowError = ""
                            root.updateTask(modelData, {
                              title: titleField.text.trim(),
                              notes: notesField.text,
                              due: due !== "" ? due + "T00:00:00.000Z" : ""
                            })
                            root.expandedTaskId = ""
                          }
                        }

                        Button {
                          text: "Close"
                          onClicked: root.expandedTaskId = ""
                        }
                      }

                      Rectangle {
                        width: parent.width
                        implicitHeight: 1
                        color: root.borderCol
                      }

                      Text {
                        text: "Local reminder (not synced to Google — fires as a desktop notification while Omarchy is running)"
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        width: parent.width
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        visible: taskCard.reminderInfo !== null
                        text: taskCard.reminderInfo ? (taskCard.reminderInfo.fired ? "Last reminder: " + root.formatReminderEpoch(taskCard.reminderInfo.remind_at_epoch) + " (fired)" : "Reminder set: " + root.formatReminderEpoch(taskCard.reminderInfo.remind_at_epoch)) : ""
                        textFormat: Text.PlainText
                        color: root.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      RowLayout {
                        width: parent.width
                        spacing: Style.space(6)

                        TextField {
                          id: reminderField
                          Layout.fillWidth: true
                          placeholderText: "YYYY-MM-DD HH:MM"
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          background: Rectangle { color: root.cardBg; border.color: root.borderCol; radius: 4 }
                        }

                        Button {
                          text: "Set"
                          onClicked: {
                            var epoch = root.parseReminderInput(reminderField.text)
                            if (epoch < 0) {
                              detailBox.rowError = "Reminder must be YYYY-MM-DD HH:MM"
                              return
                            }
                            detailBox.rowError = ""
                            root.setReminder(modelData, epoch)
                            reminderField.text = ""
                          }
                        }

                        Button {
                          text: "Clear"
                          visible: taskCard.reminderInfo !== null
                          onClicked: root.clearReminder(modelData)
                        }
                      }

                      Text {
                        visible: detailBox.rowError !== ""
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: detailBox.rowError
                        textFormat: Text.PlainText
                        color: root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }

            // Empty state
            Item {
              visible: root.openTasks.length === 0 && !root.scanning
              width: parent.width
              implicitHeight: Style.space(60)

              Column {
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "🎉 All tasks completed!"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "Type above to add a new task or reminder."
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }
}
