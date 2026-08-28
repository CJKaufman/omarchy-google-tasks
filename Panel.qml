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

  readonly property string todayStr: isoDate(new Date())

  readonly property var openTasks: (tasks || []).filter(function (t) {
    return t.status === "needsAction" && !optimisticallyCompleted[t.id]
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

  // API Process triggers using stdin bounded IPC
  function checkStatus() {
    statusProc.inputPayload = JSON.stringify({ action: "status" })
    statusProc.running = true
  }

  function fetchLists() {
    if (!root.authenticated || listListsProc.running) return
    listListsProc.inputPayload = JSON.stringify({ action: "list-lists" })
    listListsProc.running = true
  }

  function fetchTasks() {
    if (!root.authenticated || root.activeListId === "") return
    root.scanning = true
    listTasksProc.inputPayload = JSON.stringify({
      action: "list-tasks",
      list_id: root.activeListId,
      show_completed: root.prefShowCompleted
    })
    if (!listTasksProc.running) {
      listTasksProc.running = true
    }
  }

  function quickAddTask(title) {
    var clean = String(title || "").trim()
    if (clean === "" || !root.authenticated) return
    var targetList = root.activeListId || (root.taskLists && root.taskLists.length > 0 ? root.taskLists[0].id : "@default")
    root.statusError = ""
    // Optimistic UI addition
    var tempTask = {
      id: "temp_" + Date.now(),
      title: clean,
      notes: "",
      status: "needsAction",
      due: ""
    }
    root.tasks = [tempTask].concat(root.tasks || [])
    createTaskProc.running = false
    createTaskProc.inputPayload = JSON.stringify({
      action: "create-task",
      list_id: targetList,
      title: clean
    })
    createTaskProc.running = true
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

  Component.onCompleted: {
    root.checkStatus()
  }

  onOpenedChanged: {
    if (opened) {
      checkStatus()
      if (root.authenticated) {
        if (root.taskLists.length === 0) root.fetchLists()
        else root.fetchTasks()
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
      if (root.authenticated && root.activeListId !== "") {
        fetchTasks()
      } else {
        checkStatus()
      }
    }
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
              if (root.taskLists[i].title.toLowerCase() === root.prefListName.toLowerCase() || root.taskLists[i].id === root.prefListName) {
                target = root.taskLists[i]
                break
              }
            }
            if (!target) target = root.taskLists[0]
            root.activeListId = target.id
            root.activeListTitle = target.title
            root.fetchTasks()
          }
        } catch (e) {
          console.warn("list-lists parse error", e)
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
            root.tasks = items.slice(0, 50)
            root.optimisticallyCompleted = ({})
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
            root.statusError = String(err.error || text).substring(0, 250)
          } catch (e) {
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
      blocked: addField.activeFocus || clientIdInput.activeFocus || clientSecretInput.activeFocus
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
                  if (root.authenticated) root.fetchTasks()
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

              Text {
                text: root.authenticated ? "Google Account Connected" : "Connect Google Tasks"
                textFormat: Text.PlainText
                color: root.authenticated ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                visible: !root.authenticated
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Provide your Google Cloud Desktop Client credentials to sign in. See README for 2-minute setup guide."
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
                placeholderText: "Add a task or reminder… (Enter to save)"
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

          // Tasks List
          Column {
            visible: root.authenticated
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.openTasks
              delegate: Rectangle {
                id: taskCard
                width: parent.width
                implicitHeight: cardContent.implicitHeight + Style.space(14)
                color: root.cardBg
                radius: 6
                border.color: root.borderCol
                border.width: 1

                RowLayout {
                  id: cardContent
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(10)

                  // Checkbox
                  MouseArea {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Style.space(24)
                    implicitHeight: Style.space(24)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleTaskComplete(modelData)

                    Text {
                      anchors.centerIn: parent
                      text: (modelData && modelData.status === "completed") || Boolean(root.optimisticallyCompleted && root.optimisticallyCompleted[modelData.id]) ? root.glyphChecked : root.glyphUnchecked
                      textFormat: Text.PlainText
                      color: (modelData && modelData.status === "completed") || Boolean(root.optimisticallyCompleted && root.optimisticallyCompleted[modelData.id]) ? root.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }

                  // Title & Notes
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    Text {
                      Layout.fillWidth: true
                      text: String((modelData && modelData.title) || "")
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.WordWrap
                      font.strikeout: (modelData && modelData.status === "completed") || Boolean(root.optimisticallyCompleted && root.optimisticallyCompleted[modelData.id])
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
