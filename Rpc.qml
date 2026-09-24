import QtQuick
import Quickshell.Io
import "Model.js" as Model

// rpc.py owns Discord's binary socket and speaks one JSON object per line.
Item {
  id: root

  // Driven by Service: there is no socket to talk to unless Discord is running.
  property bool active: false

  readonly property int restartDelayMs: 4000
  // A bridge that cannot start stops being retried, rather than respawning python3 forever.
  readonly property int maxRestarts: 5
  property int restarts: 0
  // rpc.py exits 2 when no credentials exist and 3 when Discord would not issue a token; retrying fixes neither.
  readonly property int exitUnconfigured: 2
  readonly property int exitUnauthorized: 3
  // Set by the bridge's last line before exit 3, and only a fresh Discord or a new setup lifts it.
  property bool unauthorized: false

  // Qt hands back a file:// URL and Process needs a plain path.
  readonly property string scriptPath: String(Qt.resolvedUrl("rpc.py")).replace("file://", "")

  property bool configured: true
  // Lets the bridge start while unconfigured, until it answers, so the panel keeps showing setup meanwhile.
  property bool probing: false
  property bool ready: false
  property string error: ""

  property string channel: ""
  property string guild: ""
  property bool mute: false
  property bool deaf: false
  property int inputVolume: 100
  property var speaking: []
  property int ping: 0
  property string voiceState: ""
  // Entries look like {"id":"80351110224678912","name":"gm","status":"online"}; empty without relationships.read.
  property var friends: []
  property bool friendsOk: false
  property string friendsError: ""
  // "granted", "missing" (never asked) or "refused" (Discord said no, friendsError says why).
  property string friendsScope: "missing"
  // The channel the client sits in, by id, so a favourite reads as joined by identity and not by name.
  property string channelId: ""
  // {"123": 2} occupancy for the favourites the last refresh asked about.
  property var channelCounts: ({})
  // {"channelId":"123","code":4005,"message":"..."} for the last refused join, empty otherwise.
  property var joinError: ({})
  // [{id, name, channels:[{id, name}]}] once listChannels() has been answered; cached per bridge session.
  property var channelGuilds: []

  // Not error === "": rpc.py warns on stderr about refusals it survives, and a warning is not a disconnect.
  readonly property bool connected: ready
  readonly property bool inVoice: connected && channel !== ""

  // Cleared while the bridge is down so the panel never shows a stale call.
  function clear() {
    ready = false
    channel = ""
    guild = ""
    speaking = []
    ping = 0
    voiceState = ""
    friends = []
    friendsOk = false
    channelId = ""
    channelCounts = {}
    joinError = {}
    channelGuilds = []
  }

  // Setup happens while the shell runs, so opening the panel re-checks; a refused authorization is not re-asked.
  function retry() {
    probing = true
    // The refusal's reason is the one thing the panel must keep showing until someone acts on it.
    if (!unauthorized) error = ""
    restarts = 0
    holdOff = false
  }

  // New credentials, or an explicit try again, are the only things that raise the consent modal once more.
  function reauthorize() {
    unauthorized = false
    retry()
  }

  function send(message) {
    if (!bridge.running) return
    bridge.write(JSON.stringify(message) + "\n")
  }

  function setMute(value) { send({ cmd: "mute", value: value === true }) }
  function setDeaf(value) { send({ cmd: "deaf", value: value === true }) }
  function setInputVolume(value) { send({ cmd: "inputVolume", value: Math.round(value) }) }
  function grantFriends() { send({ cmd: "grantFriends" }) }
  function hangUp() { send({ cmd: "disconnect" }) }
  function refresh(channelIds) { send({ cmd: "refresh", channels: channelIds instanceof Array ? channelIds : [] }) }
  function join(channelId) { send({ cmd: "join", channelId: String(channelId) }) }
  function listChannels() { send({ cmd: "listChannels" }) }

  // lines look like {"ok":true,"channel":"General","guild":"GM's Server","mute":false,"deaf":false,"inputVolume":100,"speaking":["gm"],"error":"","ping":36,"voiceState":"VOICE_CONNECTED","friends":[],"friendsOk":true,"friendsError":"","channelId":"1","channelCounts":{"1":2},"joinError":{}}
  function applyLine(line) {
    var state = Model.parseRpcLine(line)
    if (!state) return

    // A listing is its own line kind and must never be read as a snapshot, which would blank the call.
    if (state.kind === "channels") {
      root.channelGuilds = state.guilds instanceof Array ? state.guilds : []
      return
    }

    if (state.ok === false) {
      // Only the unconfigured line says the tier can never work; any other error got past that check.
      root.configured = state.configured !== false
      root.unauthorized = state.unauthorized === true
      root.probing = false
      root.error = String(state.error || "Discord RPC failed")
      root.ready = false
      // A fatal line is worth a trace in the shell log, since the bridge exits right after it.
      if (root.unauthorized) console.warn("omarchy-discord bridge: " + root.error)
      return
    }

    root.error = ""
    root.configured = true
    root.probing = false
    root.channel = String(state.channel || "")
    root.guild = String(state.guild || "")
    root.mute = state.mute === true
    root.deaf = state.deaf === true
    root.inputVolume = Math.round(Number(state.inputVolume) || 0)
    root.speaking = state.speaking instanceof Array ? state.speaking : []
    root.ping = Math.round(Number(state.ping) || 0)
    root.voiceState = String(state.voiceState || "")
    root.friends = state.friends instanceof Array ? state.friends : []
    root.friendsOk = state.friendsOk === true
    root.friendsError = String(state.friendsError || "")
    root.friendsScope = String(state.friendsScope || "missing")
    root.channelId = String(state.channelId || "")
    root.channelCounts = state.channelCounts && typeof state.channelCounts === "object" ? state.channelCounts : {}
    root.joinError = state.joinError && typeof state.joinError === "object" ? state.joinError : {}
    root.unauthorized = false
    root.ready = true
    root.restarts = 0
  }

  // Blocks the next start: one delay after a crash, or until retry() once the budget is spent.
  property bool holdOff: false

  // A fresh Discord is a fresh chance, so no failure state outlives the process it belonged to.
  onActiveChanged: if (!active) {
    holdOff = false
    restarts = 0
    error = ""
    unauthorized = false
  }

  Process {
    id: bridge
    running: root.active && (root.configured || root.probing) && !root.holdOff && !root.unauthorized
    command: ["python3", root.scriptPath]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function (line) { root.applyLine(line) }
    }

    // Fatal failures arrive as JSON on stdout, so a line here is a warning worth showing.
    // Every warning the bridge prints is also worth a line in the shell log, where support looks.
    stderr: SplitParser {
      onRead: function (line) {
        var text = String(line).trim()
        if (text === "") return
        root.error = text
        console.warn("omarchy-discord bridge: " + text)
      }
    }

    onRunningChanged: if (!running) root.clear()

    onExited: function (exitCode) {
      // Discord quitting takes the bridge with it, and that is not a failure to count.
      if (!root.active || exitCode === root.exitUnconfigured || exitCode === root.exitUnauthorized) return
      root.holdOff = true
      root.restarts += 1
      // Past the budget the hold stays until retry() or the next Discord lifts it.
      if (root.restarts > root.maxRestarts) {
        root.error = "Discord voice bridge keeps failing, see the shell log"
        return
      }
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: root.restartDelayMs
    onTriggered: root.holdOff = false
  }
}
