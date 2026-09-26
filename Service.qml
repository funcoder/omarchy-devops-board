import QtQuick
import Quickshell
import Quickshell.Io

// Lists the board in the Omarchy menu's Apps (and the app launcher) by making
// sure its .desktop entry exists each time the shell starts. devops.py only
// rewrites the file when it differs, e.g. after the plugin has moved.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string helper: {
    var url = String(Qt.resolvedUrl("devops.py"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : url
  }

  Process {
    id: launcherProc
    command: [root.helper, "launcher"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data
        try { data = JSON.parse(text.trim() || "{}") } catch (e) { data = { error: "unreadable reply" } }
        if (data.error) console.warn("funcoder.devops-board: launcher: " + data.error)
        else if (data.changed) console.log("funcoder.devops-board: wrote " + data.path)
      }
    }
  }

  Component.onCompleted: launcherProc.running = true
}
