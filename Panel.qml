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
  readonly property string glyphEdit: String.fromCodePoint(0xF03EB)       // Pencil edit
  readonly property string glyphChevronDown: String.fromCodePoint(0xF0140) // Chevron down
  readonly property string glyphChevronRight: String.fromCodePoint(0xF0142) // Chevron right

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
  property var subtaskParent: null
  property var reminders: ({})

  // Enhancement state
  property bool completedCollapsed: true
  property string editingTaskId: ""
  property string editTitleText: ""
  property string editNotesText: ""
  property string editDueText: ""
  property string quickAddDue: ""
  property bool creatingList: false
  property string newListName: ""
  property var notifiedTaskIds: ({})

  readonly property string todayStr: isoDate(new Date())

  function isTaskCompleted(t) {
    return Boolean(t && (t.status === "completed" || root.optimisticallyCompleted[t.id]))
  }

  // Flattens the parent/child task graph into a display order: each task
  // immediately followed by its subtasks, indented one level. Google Tasks
  // itself only supports one level of nesting.
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

  readonly property var displayTasks: root.buildDisplayList(root.tasks || [], false)

  readonly property var openTasks: (tasks || []).filter(function (t) {
    return t.status === "needsAction" && !optimisticallyCompleted[t.id]
  })

  readonly property var completedTasks: (tasks || []).filter(function (t) {
    return t.status === "completed" || Boolean(optimisticallyCompleted[t.id])
  })

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

  readonly property var dateTimePattern: /^(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})$/

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

  function parseQuickAdd(rawText) {
    var text = String(rawText || "").trim()
    var due = ""
    var dayMap = {
      "today": 0,
      "tomorrow": 1,
      "tmrw": 1,
      "sun": 0, "sunday": 0,
      "mon": 1, "monday": 1,
      "tue": 2, "tuesday": 2,
      "wed": 3, "wednesday": 3,
      "thu": 4, "thursday": 4,
      "fri": 5, "friday": 5,
      "sat": 6, "saturday": 6
    }
    var match = text.match(/@([a-zA-Z0-9-]+)/)
    if (match) {
      var tag = match[1].toLowerCase()
      var targetDate = null
      if (tag === "today") {
        targetDate = new Date()
      } else if (tag === "tomorrow" || tag === "tmrw") {
        targetDate = new Date()
        targetDate.setDate(targetDate.getDate() + 1)
      } else if (dayMap[tag] !== undefined) {
        var wantedDay = dayMap[tag]
        targetDate = new Date()
        var currentDay = targetDate.getDay()
        var diff = wantedDay - currentDay
        if (diff <= 0) diff += 7
        targetDate.setDate(targetDate.getDate() + diff)
      } else if (/^\d{4}-\d{2}-\d{2}$/.test(tag)) {
        due = tag + "T00:00:00.000Z"
      }
      if (targetDate) {
        due = isoDate(targetDate) + "T00:00:00.000Z"
      }
      if (due !== "") {
        text = text.replace(match[0], "").trim()
      }
    }
    return { title: text, due: due }
  }

  function checkDueNotifications() {
    if (!root.authenticated || !root.openTasks || root.openTasks.length === 0) return
    var overdueCount = 0
    var dueTodayCount = 0
    var sampleTitle = ""
    var updatedNotified = Object.assign({}, root.notifiedTaskIds)
    var newlyDue = false

    for (var i = 0; i < root.openTasks.length; i++) {
      var t = root.openTasks[i]
      if (!t.due) continue
      var d = String(t.due).substring(0, 10)
      if (d < root.todayStr) {
        overdueCount++
        if (!updatedNotified[t.id]) {
          updatedNotified[t.id] = true
          newlyDue = true
          if (!sampleTitle) sampleTitle = t.title
        }
      } else if (d === root.todayStr) {
        dueTodayCount++
        if (!updatedNotified[t.id]) {
          updatedNotified[t.id] = true
          newlyDue = true
          if (!sampleTitle) sampleTitle = t.title
        }
      }
    }

    root.notifiedTaskIds = updatedNotified
    if (newlyDue && (overdueCount > 0 || dueTodayCount > 0)) {
      var headline = overdueCount > 0 ? "Google Tasks: Overdue Reminders" : "Google Tasks: Due Today"
      var desc = sampleTitle
      var total = overdueCount + dueTodayCount
      if (total > 1) {
        desc += " (and " + (total - 1) + " more)"
      }
      notifyProc.command = [
        "omarchy-notification-send",
        "-u", overdueCount > 0 ? "critical" : "normal",
        "-g", root.glyphCalendar,
        headline,
        desc
      ]
      notifyProc.running = true
    }
  }

  // API Process triggers using stdin bounded IPC
  function checkStatus() {
    statusProc.inputPayload = JSON.stringify({ action: "status" })
    statusProc.running = true
  }

  function loadCachedData() {
    getCacheProc.inputPayload = JSON.stringify({ action: "get-cache" })
    getCacheProc.running = true
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
      show_completed: true
    })
    listTasksProc.running = true
  }

  function quickAddTask(rawTitle) {
    var parsed = parseQuickAdd(rawTitle)
    var clean = parsed.title
    var dueTimestamp = parsed.due || root.quickAddDue
    if (clean === "" || !root.authenticated) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    var parentId = root.subtaskParent ? root.subtaskParent.id : ""
    root.statusError = ""
    root.quickAddDue = ""

    // Optimistic UI addition
    var tempTask = {
      id: "temp_" + Date.now(),
      title: clean,
      notes: "",
      status: "needsAction",
      due: dueTimestamp,
      parent: parentId
    }
    root.tasks = [tempTask].concat(root.tasks || [])
    createTaskProc.running = false
    var payload = {
      action: "create-task",
      list_id: targetList,
      title: clean
    }
    if (dueTimestamp) payload.due = dueTimestamp
    if (parentId) payload.parent_id = parentId
    createTaskProc.inputPayload = JSON.stringify(payload)
    createTaskProc.running = true
    root.subtaskParent = null
  }

  function startEditingTask(task) {
    if (!task) return
    root.editingTaskId = task.id
    root.editTitleText = String(task.title || "")
    root.editNotesText = String(task.notes || "")
    root.editDueText = task.due ? String(task.due).substring(0, 10) : ""
  }

  function cancelEditingTask() {
    root.editingTaskId = ""
    root.editTitleText = ""
    root.editNotesText = ""
    root.editDueText = ""
  }

  function saveEditingTask(taskId) {
    if (!taskId || !root.authenticated) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    var cleanTitle = root.editTitleText.trim()
    if (cleanTitle === "") return
    var cleanNotes = root.editNotesText.trim()
    var dueTimestamp = ""
    if (root.editDueText.trim() !== "") {
      var d = root.editDueText.trim()
      dueTimestamp = d.indexOf("T") !== -1 ? d : d + "T00:00:00.000Z"
    }

    // Optimistic update
    root.tasks = (root.tasks || []).map(function(t) {
      if (t.id === taskId) {
        var copy = Object.assign({}, t)
        copy.title = cleanTitle
        copy.notes = cleanNotes
        copy.due = dueTimestamp
        return copy
      }
      return t
    })

    root.editingTaskId = ""
    updateTaskProc.running = false
    updateTaskProc.inputPayload = JSON.stringify({
      action: "update-task",
      list_id: targetList,
      task_id: taskId,
      title: cleanTitle,
      notes: cleanNotes,
      due: dueTimestamp
    })
    updateTaskProc.running = true
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

  function clearCompleted() {
    if (!root.authenticated || root.activeListId === "" || clearCompletedProc.running) return
    root.tasks = (root.tasks || []).filter(function(t) {
      return t.status !== "completed" && !root.optimisticallyCompleted[t.id]
    })
    root.optimisticallyCompleted = ({})
    clearCompletedProc.inputPayload = JSON.stringify({
      action: "clear-completed",
      list_id: root.activeListId
    })
    clearCompletedProc.running = true
  }

  function createTaskList(title) {
    var clean = String(title || "").trim()
    if (clean === "" || !root.authenticated || createListProc.running) return
    createListProc.inputPayload = JSON.stringify({
      action: "create-list",
      title: clean
    })
    createListProc.running = true
    root.creatingList = false
    root.newListName = ""
  }

  function deleteActiveList() {
    if (!root.authenticated || !root.activeListId || root.activeListId === "@default" || deleteListProc.running) return
    var idToDelete = root.activeListId
    root.taskLists = (root.taskLists || []).filter(function(l) { return l.id !== idToDelete })
    if (root.taskLists.length > 0) {
      root.activeListId = root.taskLists[0].id
      root.activeListTitle = root.taskLists[0].title
      root.fetchTasks()
    } else {
      root.activeListId = ""
      root.activeListTitle = "My Tasks"
      root.tasks = []
    }
    deleteListProc.inputPayload = JSON.stringify({
      action: "delete-list",
      list_id: idToDelete
    })
    deleteListProc.running = true
  }

  function deleteTask(task) {
    if (!task || !task.id || !root.authenticated || deleteTaskProc.running) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    // Optimistically remove from local tasks array
    root.tasks = (root.tasks || []).filter(function(t) { return t.id !== task.id })
    if (root.reminders && root.reminders[task.id]) {
      var nextRem = Object.assign({}, root.reminders)
      delete nextRem[task.id]
      root.reminders = nextRem
    }
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
    root.loadCachedData()
  }

  onOpenedChanged: {
    if (opened) {
      checkStatus()
      if (root.tasks.length === 0) {
        root.loadCachedData()
      }
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

  // Local reminder check. Runs every 20s while authenticated.
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
            root.checkDueNotifications()
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
    id: getCacheProc
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
          var cache = JSON.parse(String(text || "{}"))
          if (cache && typeof cache === "object") {
            if (Array.isArray(cache.lists) && cache.lists.length > 0 && root.taskLists.length === 0) {
              root.taskLists = cache.lists
              if (!root.activeListId) {
                root.activeListId = cache.lists[0].id
                root.activeListTitle = cache.lists[0].title
              }
            }
            if (cache.tasks_by_list && root.activeListId && cache.tasks_by_list[root.activeListId] && root.tasks.length === 0) {
              root.tasks = cache.tasks_by_list[root.activeListId]
            }
          }
        } catch (e) {
          console.warn("getCacheProc parse error", e)
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
    id: clearCompletedProc
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
          console.warn("clearCompletedProc error:", text)
        }
      }
    }
  }

  Process {
    id: createListProc
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
          if (res && res.id) {
            root.activeListId = res.id
            root.activeListTitle = res.title || "New List"
            root.fetchLists()
          }
        } catch (e) {
          console.warn("createListProc parse error", e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("createListProc error:", text)
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
    id: deleteListProc
    command: [root.helper]
    stdinEnabled: true
    property string inputPayload: ""
    onStarted: {
      if (inputPayload) write(inputPayload + "\n")
    }
    onExited: root.fetchLists()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.warn("deleteListProc error:", text)
        }
      }
    }
  }

  Process {
    id: notifyProc
    command: ["omarchy-notification-send"]
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
      blocked: addField.activeFocus || clientIdInput.activeFocus || clientSecretInput.activeFocus || root.editingTaskId !== ""
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
                visible: root.authenticated && root.taskLists.length > 0
                width: parent.width
                spacing: Style.space(6)

                RowLayout {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    Layout.fillWidth: true
                    text: "Task Lists:"
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  // Delete active list button (if not @default and not only list)
                  Rectangle {
                    visible: root.taskLists.length > 1 && root.activeListId !== "@default"
                    implicitWidth: deleteListLabel.implicitWidth + Style.space(12)
                    implicitHeight: Style.space(22)
                    radius: 4
                    color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.15)
                    border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.3)

                    Text {
                      id: deleteListLabel
                      anchors.centerIn: parent
                      text: "Delete List"
                      textFormat: Text.PlainText
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.deleteActiveList()
                    }
                  }
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

                  // + New List Button
                  Rectangle {
                    visible: !root.creatingList
                    implicitWidth: addListText.implicitWidth + Style.space(14)
                    implicitHeight: Style.space(26)
                    color: root.cardBg
                    radius: 13
                    border.color: root.accent
                    border.width: 1

                    Text {
                      id: addListText
                      anchors.centerIn: parent
                      text: "+ New List"
                      textFormat: Text.PlainText
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.creatingList = true
                        root.newListName = ""
                      }
                    }
                  }
                }

                // Inline List Creator
                RowLayout {
                  visible: root.creatingList
                  width: parent.width
                  spacing: Style.space(6)

                  TextField {
                    id: newListNameField
                    Layout.fillWidth: true
                    placeholderText: "New list name…"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    background: Rectangle {
                      color: root.cardBg
                      border.color: root.accent
                      radius: 4
                    }
                    onAccepted: {
                      root.createTaskList(text)
                      text = ""
                    }
                    Keys.onReturnPressed: function(event) {
                      root.createTaskList(text)
                      text = ""
                      event.accepted = true
                    }
                  }

                  Button {
                    text: "Create"
                    onClicked: {
                      root.createTaskList(newListNameField.text)
                      newListNameField.text = ""
                    }
                  }

                  Button {
                    text: "Cancel"
                    onClicked: {
                      root.creatingList = false
                      newListNameField.text = ""
                    }
                  }
                }
              }
            }
          }

          // Subtask banner
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

          // Quick Add Box
          Rectangle {
            visible: root.authenticated
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
                onClicked: {
                  root.quickAddTask(addField.text)
                  addField.text = ""
                }

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
                placeholderText: root.subtaskParent ? "Subtask title… (Enter to save)" : "Add task or reminder… (@today, @fri) (Enter)"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                background: null
                selectByMouse: true
                onAccepted: {
                  root.quickAddTask(text)
                  text = ""
                }
                Keys.onReturnPressed: function(event) {
                  root.quickAddTask(text)
                  text = ""
                  event.accepted = true
                }
                Keys.onEnterPressed: function(event) {
                  root.quickAddTask(text)
                  text = ""
                  event.accepted = true
                }
              }
            }
          }

          // Quick-Add Date Chips
          Row {
            visible: root.authenticated
            spacing: Style.space(6)

            Rectangle {
              property string targetDue: root.todayStr + "T00:00:00.000Z"
              implicitWidth: todayChipText.implicitWidth + Style.space(12)
              implicitHeight: Style.space(22)
              radius: 11
              color: root.quickAddDue === targetDue ? root.accent : root.cardBg
              border.color: root.borderCol

              Text {
                id: todayChipText
                anchors.centerIn: parent
                text: "Today"
                textFormat: Text.PlainText
                color: root.quickAddDue === parent.targetDue ? "#ffffff" : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.quickAddDue = (root.quickAddDue === parent.targetDue) ? "" : parent.targetDue
                }
              }
            }

            Rectangle {
              property string targetDue: {
                var tmrw = new Date()
                tmrw.setDate(tmrw.getDate() + 1)
                return root.isoDate(tmrw) + "T00:00:00.000Z"
              }
              implicitWidth: tmrwChipText.implicitWidth + Style.space(12)
              implicitHeight: Style.space(22)
              radius: 11
              color: root.quickAddDue === targetDue ? root.accent : root.cardBg
              border.color: root.borderCol

              Text {
                id: tmrwChipText
                anchors.centerIn: parent
                text: "Tomorrow"
                textFormat: Text.PlainText
                color: root.quickAddDue === parent.targetDue ? "#ffffff" : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.quickAddDue = (root.quickAddDue === parent.targetDue) ? "" : parent.targetDue
                }
              }
            }

            Rectangle {
              property string targetDue: {
                var nextMon = new Date()
                var currentDay = nextMon.getDay()
                var diff = 1 - currentDay
                if (diff <= 0) diff += 7
                nextMon.setDate(nextMon.getDate() + diff)
                return root.isoDate(nextMon) + "T00:00:00.000Z"
              }
              implicitWidth: monChipText.implicitWidth + Style.space(12)
              implicitHeight: Style.space(22)
              radius: 11
              color: root.quickAddDue === targetDue ? root.accent : root.cardBg
              border.color: root.borderCol

              Text {
                id: monChipText
                anchors.centerIn: parent
                text: "Next Mon"
                textFormat: Text.PlainText
                color: root.quickAddDue === parent.targetDue ? "#ffffff" : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.quickAddDue = (root.quickAddDue === parent.targetDue) ? "" : parent.targetDue
                }
              }
            }

            Rectangle {
              visible: root.quickAddDue !== ""
              implicitWidth: clearChipText.implicitWidth + Style.space(12)
              implicitHeight: Style.space(22)
              radius: 11
              color: root.cardBg
              border.color: root.borderCol

              Text {
                id: clearChipText
                anchors.centerIn: parent
                text: "✕ Clear Due"
                textFormat: Text.PlainText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.quickAddDue = ""
              }
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
                border.color: root.editingTaskId === modelData.id ? root.accent : root.borderCol
                border.width: 1

                readonly property bool isCompleted: root.isTaskCompleted(modelData)
                readonly property var reminderInfo: (modelData && root.reminders[modelData.id]) ? root.reminders[modelData.id] : null

                // Background click-catcher for click-to-edit placed as sibling of cardColumn
                MouseArea {
                  x: cardColumn.x
                  y: cardColumn.y
                  width: cardContent.width
                  height: cardContent.height
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.editingTaskId === modelData.id) root.cancelEditingTask()
                    else root.startEditingTask(modelData)
                  }
                }

                Column {
                  id: cardColumn
                  x: Style.space(8)
                  y: Style.space(7)
                  width: parent.width - Style.space(16)
                  spacing: Style.space(8)

                  Item {
                    id: cardContent
                    width: parent.width
                    implicitHeight: Math.max(Style.space(24), titleCol.implicitHeight)

                    // Checkbox
                    MouseArea {
                      id: checkbox
                      anchors.left: parent.left
                      anchors.leftMargin: (modelData.depth || 0) * Style.space(18)
                      anchors.verticalCenter: titleCol.verticalCenter
                      width: Style.space(24)
                      height: Style.space(24)
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

                    Row {
                      id: rightIcons
                      anchors.right: parent.right
                      anchors.verticalCenter: titleCol.verticalCenter
                      spacing: Style.space(6)

                      // Due Badge
                      Rectangle {
                        visible: Boolean(modelData && modelData.due && String(modelData.due) !== "")
                        width: dueText.implicitWidth + Style.space(10)
                        height: Style.space(20)
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

                      // Add subtask (Google Tasks supports 1-level limit)
                      MouseArea {
                        visible: (modelData.depth || 0) === 0
                        width: Style.space(20)
                        height: Style.space(20)
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

                      // Edit action
                      MouseArea {
                        width: Style.space(20)
                        height: Style.space(20)
                        cursorShape: Qt.PointingHandCursor
                        opacity: 0.6
                        onClicked: {
                          if (root.editingTaskId === modelData.id) root.cancelEditingTask()
                          else root.startEditingTask(modelData)
                        }

                        Text {
                          anchors.centerIn: parent
                          text: root.glyphEdit
                          textFormat: Text.PlainText
                          color: root.editingTaskId === modelData.id ? root.accent : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      // Delete action
                      MouseArea {
                        width: Style.space(20)
                        height: Style.space(20)
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

                    Column {
                      id: titleCol
                      anchors.left: checkbox.right
                      anchors.leftMargin: Style.space(10)
                      anchors.right: rightIcons.left
                      anchors.rightMargin: Style.space(10)
                      anchors.top: parent.top
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        text: String((modelData && modelData.title) || "") + (taskCard.reminderInfo !== null && !taskCard.reminderInfo.fired ? "  ⏰" : "")
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        wrapMode: Text.WordWrap
                        font.strikeout: taskCard.isCompleted
                      }

                      Text {
                        visible: Boolean(modelData && modelData.notes && String(modelData.notes).trim() !== "")
                        width: parent.width
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

                  // Inline Edit Box
                  Column {
                    visible: root.editingTaskId === modelData.id
                    width: parent.width
                    spacing: Style.space(6)

                    TextField {
                      width: parent.width
                      text: root.editTitleText
                      placeholderText: "Task title…"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      background: Rectangle {
                        color: root.subtleBg
                        border.color: root.borderCol
                        radius: 4
                      }
                      onTextChanged: root.editTitleText = text
                    }

                    TextField {
                      width: parent.width
                      text: root.editNotesText
                      placeholderText: "Notes or description…"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      background: Rectangle {
                        color: root.subtleBg
                        border.color: root.borderCol
                        radius: 4
                      }
                      onTextChanged: root.editNotesText = text
                    }

                    TextField {
                      width: parent.width
                      text: root.editDueText
                      placeholderText: "Due date (YYYY-MM-DD)…"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      background: Rectangle {
                        color: root.subtleBg
                        border.color: root.borderCol
                        radius: 4
                      }
                      onTextChanged: root.editDueText = text
                    }

                    Row {
                      spacing: Style.space(8)

                      Button {
                        text: "Save"
                        onClicked: root.saveEditingTask(modelData.id)
                      }

                      Button {
                        text: "Cancel"
                        onClicked: root.cancelEditingTask()
                      }
                    }

                    Rectangle {
                      width: parent.width
                      implicitHeight: 1
                      color: root.borderCol
                    }

                    Text {
                      text: "Local reminder (fires desktop notification while Omarchy is running)"
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
                        background: Rectangle {
                          color: root.subtleBg
                          border.color: root.borderCol
                          radius: 4
                        }
                      }

                      Button {
                        text: "Set"
                        onClicked: {
                          var epoch = root.parseReminderInput(reminderField.text)
                          if (epoch < 0) {
                            root.statusError = "Reminder must be YYYY-MM-DD HH:MM"
                            return
                          }
                          root.statusError = ""
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
                  }
                }
              }
            }

            // Empty state for open tasks
            Item {
              visible: root.displayTasks.length === 0 && !root.scanning
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

            // Collapsible Completed Tasks Accordion
            Column {
              visible: root.completedTasks.length > 0
              width: parent.width
              spacing: Style.space(6)

              Rectangle {
                width: parent.width
                implicitHeight: Style.space(32)
                color: root.subtleBg
                radius: 6

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  MouseArea {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.completedCollapsed = !root.completedCollapsed

                    RowLayout {
                      anchors.fill: parent
                      spacing: Style.space(6)

                      Text {
                        text: root.completedCollapsed ? root.glyphChevronRight : root.glyphChevronDown
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        text: "Completed (" + root.completedTasks.length + ")"
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }

                  // Clear completed button
                  Rectangle {
                    implicitWidth: clearLabel.implicitWidth + Style.space(12)
                    implicitHeight: Style.space(20)
                    radius: 4
                    color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)

                    Text {
                      id: clearLabel
                      anchors.centerIn: parent
                      text: "Clear All"
                      textFormat: Text.PlainText
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.clearCompleted()
                    }
                  }
                }
              }

              // Completed Items List
              Column {
                visible: !root.completedCollapsed
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: root.completedTasks
                  delegate: Rectangle {
                    width: parent.width
                    implicitHeight: completedCardRow.implicitHeight + Style.space(10)
                    color: root.cardBg
                    radius: 6
                    border.color: root.borderCol
                    opacity: 0.75

                    RowLayout {
                      id: completedCardRow
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      spacing: Style.space(8)

                      // Checkbox uncomplete
                      MouseArea {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Style.space(22)
                        implicitHeight: Style.space(22)
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleTaskComplete(modelData)

                        Text {
                          anchors.centerIn: parent
                          text: root.glyphChecked
                          textFormat: Text.PlainText
                          color: root.accent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }
                      }

                      Text {
                        Layout.fillWidth: true
                        text: String((modelData && modelData.title) || "")
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.strikeout: true
                        wrapMode: Text.WordWrap
                      }

                      // Delete action
                      MouseArea {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Style.space(20)
                        implicitHeight: Style.space(20)
                        cursorShape: Qt.PointingHandCursor
                        opacity: 0.5
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
