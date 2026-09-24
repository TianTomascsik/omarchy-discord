import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import "Model.js" as Model

// Discord's state from the services the shell already runs; README maps signal to service.
Item {
  id: root

  readonly property int pollIntervalMs: 20000
  readonly property int settleIntervalMs: 1500
  readonly property int settleTicks: 4
  readonly property real maxVolume: 1.5

  // ------------------------------------------------------------ settings

  // Panel hands these down from shell.json; "" leaves Discord wherever Hyprland puts it.
  property string workspacePreset: ""
  property bool followWorkspace: false
  // Entries look like { id: "80351110224678912", name: "gm" }.
  property var watchedFriends: []

  // ------------------------------------------------------------ installed

  readonly property var applications: DesktopEntries.applications ? DesktopEntries.applications.values : []
  readonly property bool installed: Model.findEntry(applications) !== null

  // ------------------------------------------------------------ processes

  property bool running: false
  property int processCount: 0
  property real memoryMib: 0
  property int mainPid: 0
  property string lastError: ""

  readonly property bool busy: statusProcess.running

  // ------------------------------------------------------------ windows

  readonly property var toplevels: Hyprland.toplevels ? Hyprland.toplevels.values : []
  readonly property var workspaces: Hyprland.workspaces ? Hyprland.workspaces.values : []
  readonly property var windows: Model.matchWindows(toplevels)
  readonly property bool hasWindow: windows.length > 0
  readonly property var primaryWindow: hasWindow ? windows[0] : null
  readonly property string workspace: Model.workspaceLabel(primaryWindow)

  // Only while Discord has a window; a tray-hidden instance has nothing to flag.
  readonly property bool attention: Model.anyUrgent(windows)

  // Session-scoped: launch() cannot see a running client, and a first click after a restart falls back to APP_IDS order.
  property string lastClientId: ""
  onToplevelsChanged: {
    var id = Model.runningClientId(toplevels)
    if (id !== "") lastClientId = id
  }

  // ------------------------------------------------------------ voice

  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var streamNodes: Model.streamNodes(nodes)
  readonly property var captureNode: Model.findDiscordStream(streamNodes, false)
  readonly property var playbackNode: Model.findDiscordStream(streamNodes, true)

  // The voice engine holds streams only in a call; the bridge names the call outright.
  readonly property bool inVoice: bridge.inVoice || Model.hasVoiceStream(streamNodes)
  readonly property bool hasPlayback: playbackNode !== null

  // Discord's own voice state when configured; every property below falls back to PipeWire.
  Rpc {
    id: bridge
    active: root.running
  }

  readonly property alias rpc: bridge
  readonly property bool voiceKnown: bridge.connected
  readonly property string callChannel: bridge.channel
  readonly property string callGuild: bridge.guild

  // Without the bridge the capture stream is all there is, and Discord drops it while muted.
  readonly property bool hasMicControl: voiceKnown || captureNode !== null
  readonly property bool micMuted: voiceKnown
    ? bridge.mute
    : (captureNode && captureNode.audio ? captureNode.audio.muted : false)
  readonly property bool micLive: hasMicControl && !micMuted
  readonly property real appVolume: playbackNode && playbackNode.audio ? playbackNode.audio.volume : 0
  readonly property bool appMuted: playbackNode && playbackNode.audio ? playbackNode.audio.muted : false

  readonly property string statusText: Model.statusPhrase(root)

  // Binding the nodes is what makes their properties readable at all.
  PwObjectTracker {
    objects: root.streamNodes
  }

  // ------------------------------------------------------------ friends

  // The bridge's friend list, only with the relationships.read scope granted.
  readonly property var friends: bridge.friends
  readonly property bool friendsKnown: bridge.friendsOk
  readonly property string friendsError: bridge.friendsError
  readonly property var watchedRows: Model.watchedRows(friends, watchedFriends)
  readonly property var watchableFriends: Model.watchableFriends(friends, watchedFriends)
  readonly property int watchedOnline: Model.countOnline(watchedRows)

  // The first snapshot after a connect only seeds, so nobody gets a storm of stale arrivals.
  property var lastPresence: ({})
  property bool presenceSeeded: false
  property var lastNotifiedAt: ({})
  readonly property int notifyCooldownMs: 60000

  Connections {
    target: bridge
    function onFriendsChanged() { root.trackPresence() }
    function onReadyChanged() {
      if (bridge.ready) return
      root.presenceSeeded = false
      root.lastPresence = {}
    }
  }

  function trackPresence() {
    if (!bridge.friendsOk) return
    if (!presenceSeeded) {
      lastPresence = Model.presenceMap(bridge.friends)
      presenceSeeded = true
      return
    }
    var arrivals = Model.arrivals(lastPresence, bridge.friends, watchedFriends)
    lastPresence = Model.presenceMap(bridge.friends)
    var now = Date.now()
    for (var i = 0; i < arrivals.length; i++) {
      var friend = arrivals[i]
      if (now - (lastNotifiedAt[friend.id] || 0) < notifyCooldownMs) continue
      lastNotifiedAt[friend.id] = now
      notifyOnline(friend)
    }
  }

  // The shell's own notification server; clicking the toast raises Discord.
  function notifyOnline(friend) {
    Util.execArgv(["omarchy-notification-send", "--app-name", "Discord", "-g", "󰂚", "-u", "normal",
      String(friend.name) + " is online", Model.presenceLabel(friend.status) + " on Discord",
      "--exec", "omarchy-shell", "discord", "raise"])
  }

  // ------------------------------------------------------------ actions

  // Re-reads both tiers in case a dispatch was missed; the bridge ignores this while down.
  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
    bridge.refresh()
  }

  function applyProcesses(raw) {
    var parsed = Model.parseProcesses(raw)
    running = parsed.count > 0
    processCount = parsed.count
    memoryMib = parsed.memoryMib
    mainPid = parsed.mainPid
  }

  // The launcher's own path, so the client lands in app-graphical.slice, not the compositor's.
  function launch() {
    if (!installed) return
    // StartupWMClass is not the desktop file's basename, which is why the key exists at all.
    Util.execArgv(["uwsm-app", "--", "gtk-launch", String(Model.findEntry(applications, lastClientId).id)])
    settle()
  }

  // A Lua-configured Hyprland rejects the legacy dispatcher strings, so the form follows usingLua.
  function dispatch(command) {
    if (command === "") return
    // Hyprland's reply never reaches QML, so the command itself is the only trace in the shell log.
    console.log("omarchy-discord dispatch: " + command)
    Hyprland.dispatch(command)
  }

  function focusWindow(toplevel) {
    var target = toplevel || primaryWindow
    if (!target || !target.address) return
    // Focusing follows the window to its workspace.
    dispatch(Model.focusDispatch(target.address, Hyprland.usingLua))
  }

  // Runs once when Discord's first window appears, whichever launcher opened it.
  function placeWindow(address, currentWorkspace) {
    if (workspacePreset === "" || !address) return
    if (Model.sameWorkspace(currentWorkspace, workspacePreset)) return
    dispatch(Model.moveDispatch(address, workspacePreset, followWorkspace, Hyprland.usingLua))
    if (!followWorkspace) holdActivation(address)
  }

  // Discord activates itself about a second after its window maps, and Omarchy's focus_on_activate would follow it.
  readonly property int activationGraceMs: 8000
  property var heldWindows: []

  function holdActivation(address) {
    dispatch(Model.propDispatch(address, "focus_on_activate", "0", Hyprland.usingLua))
    heldWindows = heldWindows.concat([address])
    activationTimer.restart()
  }

  Timer {
    id: activationTimer
    interval: root.activationGraceMs
    onTriggered: {
      for (var i = 0; i < root.heldWindows.length; i++) {
        root.dispatch(Model.propDispatch(root.heldWindows[i], "focus_on_activate", "unset", Hyprland.usingLua))
      }
      root.heldWindows = []
    }
  }

  // Hyprland's openwindow event names class and address before Quickshell's model carries the window.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "openwindow") return
      var opened = Model.parseOpenWindow(event.data)
      if (!opened || !Model.isAppId(opened.appClass)) return
      if (Model.otherWindows(root.windows, opened.address).length > 0) return
      root.placeWindow(opened.address, opened.workspace)
    }
  }

  // Electron hands a re-launch to the running process, which unhides a tray-hidden instance.
  function open() {
    if (hasWindow) focusWindow(primaryWindow)
    else launch()
  }

  // ps always reports one Discord without --type=, so no main pid means the parse failed.
  function quit() {
    if (!running) return
    if (mainPid === 0) {
      lastError = "Could not find the main Discord process to quit"
      return
    }
    Util.execArgv(["kill", String(mainPid)])
    settle()
  }

  // Discord's own mute survives the mic closing and shows in its UI; PipeWire's does neither.
  function toggleMic() {
    if (voiceKnown) {
      bridge.setMute(!bridge.mute)
      return
    }
    if (captureNode && captureNode.audio) captureNode.audio.muted = !captureNode.audio.muted
  }

  function toggleDeaf() {
    if (voiceKnown) bridge.setDeaf(!bridge.deaf)
  }

  function hangUp() {
    if (voiceKnown) bridge.hangUp()
  }

  function setMicGain(value) {
    if (voiceKnown) bridge.setInputVolume(Math.max(0, Math.min(100, value)))
  }

  function toggleAppMute() {
    if (playbackNode && playbackNode.audio) playbackNode.audio.muted = !playbackNode.audio.muted
  }

  function setAppVolume(value) {
    if (playbackNode && playbackNode.audio) playbackNode.audio.volume = Math.max(0, Math.min(maxVolume, value))
  }

  // Electron takes seconds to start or exit, so re-poll rather than wait out the interval.
  function settle() {
    settleTimer.ticks = 0
    settleTimer.restart()
  }

  Process {
    id: statusProcess
    running: false
    command: ["ps", "-C", "Discord,vesktop", "-o", "pid=,rss=,args="]

    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
    }

    // ps exits 1 with no output when nothing matches, which is Discord down, not a failure.
    onExited: function (exitCode) {
      if (exitCode === 0 || exitCode === 1) {
        root.applyProcesses(statusStdout.text)
        root.lastError = ""
      } else {
        root.lastError = String(statusStderr.text || "") || "Could not read Discord processes"
      }
    }
  }

  Timer {
    interval: root.pollIntervalMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    property int ticks: 0
    interval: root.settleIntervalMs
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= root.settleTicks) settleTimer.running = false
    }
  }

  // A window appearing or closing changes what the poll would say.
  onHasWindowChanged: refresh()
}
