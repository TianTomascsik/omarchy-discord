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
  // A launch that a join caused lands Discord on its workspace without switching, whatever followWorkspace says.
  property bool joinInBackground: true
  // Entries look like { id: "80351110224678912", name: "gm" }.
  property var watchedFriends: []
  // How an arrival is announced: the shell's popup, a sound, or both; "" picks the freedesktop message sound.
  property bool notifyPopup: true
  property bool notifySound: true
  property string notifySoundFile: ""
  readonly property string defaultSoundFile: "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga"
  readonly property string soundFile: notifySoundFile !== "" ? notifySoundFile : defaultSoundFile
  // Entries look like { id: "1", name: "General", guildId: "10", guild: "GM's Server" }.
  property var favouriteChannels: []

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
  readonly property string callChannelId: bridge.channelId

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

  // Source one: the BetterDiscord plugin in betterdiscord/ writes the client's own friend list here.
  readonly property string friendsFilePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy-discord/friends.json"
  property var fileFriends: []
  property bool fileActive: false
  property real fileUpdatedAt: 0
  // Bumped by every poll so a file that stopped updating goes stale without a file event.
  property real clockMs: Date.now()
  readonly property bool friendsFromClient: running && fileActive && Model.friendsFileFresh(fileUpdatedAt, clockMs)

  FileView {
    id: friendsFile
    path: root.friendsFilePath
    watchChanges: true
    blockLoading: false
    printErrors: false
    onFileChanged: reload()
    // text() is a function on the public FileView; the signal comes from the type underneath.
    onTextChanged: root.applyFriendsFile(text())
    onLoadFailed: root.applyFriendsFile("")
  }

  function applyFriendsFile(text) {
    var parsed = Model.parseFriendsFile(text)
    fileActive = parsed !== null && parsed.active
    fileUpdatedAt = parsed !== null ? parsed.updatedAt : 0
    fileFriends = parsed !== null ? parsed.friends : []
    clockMs = Date.now()
  }

  // Source two: the bridge, for an application Discord has approved for relationships.read.
  readonly property var friends: friendsFromClient ? fileFriends : bridge.friends
  readonly property bool friendsKnown: friendsFromClient || bridge.friendsOk
  readonly property string friendsError: friendsFromClient ? "" : bridge.friendsError
  readonly property string friendsScope: bridge.friendsScope
  // The consent row is pointless while the client itself is supplying the list.
  readonly property bool friendsGrantable: !friendsFromClient && bridge.connected && bridge.friendsScope !== "granted"
  readonly property var watchedRows: Model.watchedRows(friends, watchedFriends)
  readonly property var watchableFriends: Model.watchableFriends(friends, watchedFriends)
  readonly property int watchedOnline: Model.countOnline(watchedRows)

  // The first snapshot after a connect only seeds, so nobody gets a storm of stale arrivals.
  property var lastPresence: ({})
  property bool presenceSeeded: false
  property var lastNotifiedAt: ({})
  readonly property int notifyCooldownMs: 60000

  onFriendsChanged: trackPresence()
  onFriendsKnownChanged: if (!friendsKnown) {
    presenceSeeded = false
    lastPresence = {}
  }

  function trackPresence() {
    if (!friendsKnown) return
    if (!presenceSeeded) {
      lastPresence = Model.presenceMap(friends)
      presenceSeeded = true
      return
    }
    var arrivals = Model.arrivals(lastPresence, friends, watchedFriends)
    lastPresence = Model.presenceMap(friends)
    var now = Date.now()
    for (var i = 0; i < arrivals.length; i++) {
      var friend = arrivals[i]
      if (now - (lastNotifiedAt[friend.id] || 0) < notifyCooldownMs) continue
      lastNotifiedAt[friend.id] = now
      notifyOnline(friend)
    }
  }

  // The shell's own notification server plays nothing, so the sound is a separate PipeWire play; the toast raises Discord.
  function notifyOnline(friend) {
    console.log("omarchy-discord notify: " + friend.name + " is " + friend.status)
    if (notifyPopup) {
      Util.execArgv(["omarchy-notification-send", "--app-name", "Discord", "-g", "󰂚", "-u", "normal",
        String(friend.name) + " is online", Model.presenceLabel(friend.status) + " on Discord",
        "--exec", "omarchy-shell", "discord", "raise"])
    }
    if (notifySound) Util.execArgv(["pw-play", soundFile])
  }

  // The panel's test row and the IPC verb, so the popup and the sound can be checked without waiting for a friend.
  function notifyTest() {
    notifyOnline({ id: "test", name: "A watched friend", status: "online" })
  }

  // ------------------------------------------------------------ channels

  readonly property bool channelsKnown: bridge.channelGuilds.length > 0
  readonly property var channelOptions: Model.channelOptions(bridge.channelGuilds, favouriteChannels)
  readonly property var favouriteRows: Model.favouriteRows(favouriteChannels, bridge.channelCounts, callChannelId, pendingJoin, bridge.channelMembers)

  // ------------------------------------------------------------ channel watch

  // Arrivals in a watched favourite: the first member list after a connect only seeds, and a burst is one popup.
  property var lastMembers: ({})
  property bool membersSeeded: false
  property var pendingArrivals: ({})
  property var lastChannelNotifiedAt: ({})
  readonly property int arrivalBatchMs: 2500
  readonly property int channelCooldownMs: 30000

  Connections {
    target: bridge
    function onChannelMembersChanged() { root.trackMembers() }
    function onReadyChanged() {
      if (bridge.ready) return
      root.membersSeeded = false
      root.lastMembers = {}
    }
  }

  function trackMembers() {
    if (!voiceKnown) return
    if (!membersSeeded) {
      lastMembers = bridge.channelMembers
      membersSeeded = true
      return
    }
    var arrivals = Model.channelArrivals(lastMembers, bridge.channelMembers, favouriteChannels, callChannelId)
    lastMembers = bridge.channelMembers
    for (var i = 0; i < arrivals.length; i++) {
      var batch = pendingArrivals[arrivals[i].id] || { name: arrivals[i].name, names: [] }
      batch.names = batch.names.concat(arrivals[i].names)
      pendingArrivals[arrivals[i].id] = batch
    }
    if (arrivals.length > 0) arrivalTimer.restart()
  }

  Timer {
    id: arrivalTimer
    interval: root.arrivalBatchMs
    onTriggered: root.flushArrivals()
  }

  function flushArrivals() {
    var now = Date.now()
    for (var id in pendingArrivals) {
      var batch = pendingArrivals[id]
      if (now - (lastChannelNotifiedAt[id] || 0) >= channelCooldownMs) {
        lastChannelNotifiedAt[id] = now
        notifyArrival(batch.name, batch.names)
      }
    }
    pendingArrivals = {}
  }

  // Same popup and sound switches as a friend's arrival; clicking the toast joins that channel.
  function notifyArrival(channelName, names) {
    var headline = Model.arrivalHeadline(names, channelName)
    console.log("omarchy-discord notify: " + headline)
    if (notifyPopup) {
      Util.execArgv(["omarchy-notification-send", "--app-name", "Discord", "-g", "󰋋", "-u", "normal",
        headline, "Press to join", "--exec", "omarchy-shell", "discord", "join", String(channelName)])
    }
    if (notifySound) Util.execArgv(["pw-play", soundFile])
  }

  // Asked once per bridge session, when the picker opens; 48 round trips are not worth doing unasked.
  function requestChannels() {
    if (voiceKnown && !channelsKnown) bridge.listChannels()
  }

  // A newly saved favourite gets its occupancy without waiting for the next poll.
  onFavouriteChannelsChanged: refresh()

  // ------------------------------------------------------------ join

  // The favourite being joined, "" when none; the hero says why Discord is starting.
  property string pendingJoin: ""
  readonly property bool joining: pendingJoin !== ""
  readonly property string pendingJoinName: Model.favouriteName(favouriteChannels, pendingJoin)
  property string joinError: ""
  property string joinErrorChannel: ""
  property int joinAttempts: 0
  // A cold client answers the first join late or with 4005, so it gets a settle and one retry inside a minute.
  readonly property int joinSettleMs: 3000
  readonly property int joinRetryMs: 5000
  readonly property int joinDeadlineMs: 60000
  readonly property int joinMaxAttempts: 2

  // Returns "ok" or the reason, so the IPC verb and the row share one path.
  function joinChannel(id) {
    var channelId = String(id || "")
    if (channelId === "") return "no such channel"
    if (channelId === callChannelId) return "ok"
    joinError = ""
    joinErrorChannel = ""
    joinAttempts = 0
    if (running && !bridge.configured) {
      joinError = "Voice controls are needed to join"
      joinErrorChannel = channelId
      return joinError
    }
    pendingJoin = channelId
    joinDeadline.restart()
    if (voiceKnown) {
      sendJoin()
    } else if (!running) {
      launch()
    } else {
      bridge.retry()
    }
    return "ok"
  }

  // The row is a toggle: pressing the channel you sit in leaves it; the join verb stays join-only.
  function toggleChannel(id) {
    if (String(id || "") !== "" && String(id) === callChannelId) {
      hangUp()
      return "ok"
    }
    return joinChannel(id)
  }

  function sendJoin() {
    if (pendingJoin === "") return
    joinAttempts += 1
    console.log("omarchy-discord join: " + pendingJoinName + " attempt " + joinAttempts)
    bridge.join(pendingJoin)
  }

  function failJoin(reason) {
    joinError = reason
    joinErrorChannel = pendingJoin
    pendingJoin = ""
    joinDeadline.stop()
    joinRetry.stop()
    console.log("omarchy-discord join failed: " + reason)
  }

  // A bridge that comes up while a join waits gets the join after the voice engine has had a moment.
  onVoiceKnownChanged: if (voiceKnown && pendingJoin !== "") joinSettle.restart()
  onCallChannelIdChanged: if (pendingJoin !== "" && callChannelId === pendingJoin) {
    console.log("omarchy-discord join: landed in " + pendingJoinName)
    pendingJoin = ""
    joinDeadline.stop()
    joinRetry.stop()
  }

  Connections {
    target: bridge
    function onJoinErrorChanged() {
      var error = bridge.joinError
      if (root.pendingJoin === "" || !error || String(error.channelId || "") !== root.pendingJoin) return
      console.log("omarchy-discord join: Discord answered " + error.code + " " + error.message)
      if (Model.joinRetryable(error.code) && root.joinAttempts < root.joinMaxAttempts) {
        joinRetry.restart()
        return
      }
      root.failJoin(Model.joinFailure(error.code, error.message))
    }
  }

  Timer {
    id: joinSettle
    interval: root.joinSettleMs
    onTriggered: root.sendJoin()
  }

  Timer {
    id: joinRetry
    interval: root.joinRetryMs
    onTriggered: root.sendJoin()
  }

  Timer {
    id: joinDeadline
    interval: root.joinDeadlineMs
    onTriggered: if (root.pendingJoin !== "") root.failJoin("Discord did not join " + root.pendingJoinName + " within a minute")
  }

  // ------------------------------------------------------------ actions

  // Re-reads both tiers in case a dispatch was missed; the bridge ignores this while down.
  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
    bridge.refresh(Model.favouriteIds(favouriteChannels))
    clockMs = Date.now()
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
    var follow = Model.placementFollow(followWorkspace, pendingJoin !== "", joinInBackground)
    dispatch(Model.moveDispatch(address, workspacePreset, follow, Hyprland.usingLua))
    if (!follow) holdActivation(address)
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

  function grantFriends() {
    if (friendsGrantable) bridge.grantFriends()
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
