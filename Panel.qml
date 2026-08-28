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
    var d = t.due.substring(0, 10)
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
    var d = due.substring(0, 10)
    if (d < root.todayStr) return "Overdue"
    if (d === root.todayStr) return "Today"
    var tomorrow = new Date()
    tomorrow.setDate(tomorrow.getDate() + 1)
    if (d === isoDate(tomorrow)) return "Tomorrow"
    return d
  }

  function isOverdue(due) {
    if (!due || due === "") return false
    return due.substring(0, 10) < root.todayStr
  }

  function isDueToday(due) {
    if (!due || due === "") return false
    return due.substring(0, 10) === root.todayStr
  }

  // API Process triggers
  function checkStatus() {
    statusProc.running = true
  }

  function fetchLists() {
    if (!root.authenticated) return
    listListsProc.running = true
  }

  function fetchTasks() {
    if (!root.authenticated || root.activeListId === "" || listTasksProc.running) return
    root.scanning = true
    listTasksProc.command = [
      root.helper, "list-tasks",
      "--list-id", root.activeListId
    ]
    if (root.prefShowCompleted) {
      listTasksProc.command.push("--show-completed")
    }
    listTasksProc.running = true
  }

  function quickAddTask(title) {
    var clean = String(title || "").trim()
    if (clean === "" || !root.authenticated || root.activeListId === "") return
    createTaskProc.command = [
      root.helper, "create-task",
      "--list-id", root.activeListId,
      "--title", clean
    ]
    createTaskProc.running = true
  }

  function toggleTaskComplete(task) {
    if (!task || !task.id || !root.authenticated) return
    var updated = Object.assign({}, root.optimisticallyCompleted)
    if (task.status === "needsAction") {
      updated[task.id] = true
      root.optimisticallyCompleted = updated
      completeTaskProc.command = [
        root.helper, "complete-task",
        "--list-id", root.activeListId,
        "--task-id", task.id
      ]
      completeTaskProc.running = true
    } else {
      delete updated[task.id]
      root.optimisticallyCompleted = updated
      uncompleteTaskProc.command = [
        root.helper, "uncomplete-task",
        "--list-id", root.activeListId,
        "--task-id", task.id
      ]
      uncompleteTaskProc.running = true
    }
  }

  function deleteTask(task) {
    if (!task || !task.id || !root.authenticated) return
    deleteTaskProc.command = [
      root.helper, "delete-task",
      "--list-id", root.activeListId,
      "--task-id", task.id
    ]
    deleteTaskProc.running = true
  }

  function startAuthFlow(clientId, clientSecret) {
    root.authPending = true
    root.statusError = ""
    authProc.command = [
      root.helper, "auth",
      "--client-id", String(clientId || "").trim(),
      "--client-secret", String(clientSecret || "").trim()
    ]
    authProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      checkStatus()
      if (root.authenticated) {
        fetchTasks()
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

  // Process Handlers
  Process {
    id: statusProc
    command: [root.helper, "status"]
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
    command: [root.helper, "list-lists"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(String(text || "[]"))
          if (Array.isArray(arr) && arr.length > 0) {
            root.taskLists = arr
            // Select preferred list or first list
            var target = null
            for (var i = 0; i < arr.length; i++) {
              if (arr[i].title.toLowerCase() === root.prefListName.toLowerCase() || arr[i].id === root.prefListName) {
                target = arr[i]
                break
              }
            }
            if (!target) target = arr[0]
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.scanning = false
        try {
          var items = JSON.parse(String(text || "[]"))
          if (Array.isArray(items)) {
            root.tasks = items
            root.optimisticallyCompleted = ({})
          }
        } catch (e) {
          console.warn("list-tasks parse error", e)
        }
      }
    }
  }

  Process {
    id: createTaskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchTasks()
    }
  }

  Process {
    id: completeTaskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchTasks()
    }
  }

  Process {
    id: uncompleteTaskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchTasks()
    }
  }

  Process {
    id: deleteTaskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchTasks()
    }
  }

  Process {
    id: authProc
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
            root.statusError = err.error || text
          } catch(e) {
            root.statusError = text
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
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  text: root.summary
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
            radius: Style.radius(8)
            border.color: root.borderCol
            border.width: 1

            Column {
              id: settingsCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              Text {
                text: root.authenticated ? "Google Account Connected" : "Connect Google Tasks"
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
                    radius: Style.radius(4)
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
                    radius: Style.radius(4)
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
                      radius: Style.radius(13)
                      border.color: root.borderCol

                      Text {
                        id: listLabel
                        anchors.centerIn: parent
                        text: modelData.title
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
            radius: Style.radius(6)
            border.color: addField.activeFocus ? root.accent : root.borderCol
            border.width: 1

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(6)

              Text {
                text: root.glyphAdd
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              TextField {
                id: addField
                Layout.fillWidth: true
                placeholderText: "Add a task or reminder… (Enter to save)"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                background: null
                onAccepted: {
                  root.quickAddTask(text)
                  text = ""
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
                radius: Style.radius(6)
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
                      text: modelData.status === "completed" || root.optimisticallyCompleted[modelData.id] ? root.glyphChecked : root.glyphUnchecked
                      color: modelData.status === "completed" || root.optimisticallyCompleted[modelData.id] ? root.accent : root.dim
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
                      text: modelData.title
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.WordWrap
                      font.strikeout: modelData.status === "completed" || root.optimisticallyCompleted[modelData.id]
                    }

                    Text {
                      visible: modelData.notes && modelData.notes.trim() !== ""
                      Layout.fillWidth: true
                      text: modelData.notes
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      maximumLineCount: 2
                    }
                  }

                  // Due Badge
                  Rectangle {
                    visible: modelData.due && modelData.due !== ""
                    implicitWidth: dueText.implicitWidth + Style.space(10)
                    implicitHeight: Style.space(20)
                    radius: Style.radius(10)
                    color: root.isOverdue(modelData.due) ? root.urgent : (root.isDueToday(modelData.due) ? root.accent : root.subtleBg)

                    Text {
                      id: dueText
                      anchors.centerIn: parent
                      text: root.formatDue(modelData.due)
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
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "Type above to add a new task or reminder."
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
