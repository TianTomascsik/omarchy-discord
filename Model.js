// Pure helpers: no QML objects, no side effects, safe from a property binding.

var KIB_PER_MIB = 1024
var MIB_PER_GIB = 1024
// The two supported clients: the discord package publishes discord/Discord, vesktop vesktop.
var APP_IDS = ["discord", "vesktop"]

function isAppId(value) {
  return APP_IDS.indexOf(String(value || "").toLowerCase()) !== -1
}

// ---------------------------------------------------------------- desktop

// Quickshell 0.3 exposes StartupWMClass as startupClass and no entry id to match.
// Desktop list order is arbitrary, so pick the client last seen running, then APP_IDS order.
function findEntry(applications, preferredId) {
  var list = applications || []
  var wanted = [isAppId(preferredId) ? String(preferredId).toLowerCase() : ""].concat(APP_IDS)
  for (var w = 0; w < wanted.length; w++) {
    if (wanted[w] === "") continue
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (entry && String(entry.startupClass || "").toLowerCase() === wanted[w]) return entry
    }
  }
  return null
}

// The app id of the client actually on screen, which is what disambiguates a later cold launch.
function runningClientId(toplevels) {
  var matched = matchWindows(toplevels)
  return matched.length > 0 ? String(toplevelClass(matched[0])).toLowerCase() : ""
}

// ---------------------------------------------------------------- windows

function toplevelClass(toplevel) {
  if (!toplevel) return ""
  // The Wayland handle carries the app id; the IPC snapshot is the fallback.
  var wayland = toplevel.wayland
  if (wayland && wayland.appId) return String(wayland.appId)
  var ipc = toplevel.lastIpcObject
  return ipc ? String(ipc["class"] || ipc["initialClass"] || "") : ""
}

// hyprctl reports class and initialClass as the client's own app id here.
function matchWindows(toplevels) {
  var list = toplevels || []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (isAppId(toplevelClass(list[i]))) out.push(list[i])
  }
  return out
}

// Hyprland raises urgency from xdg-activation, which Discord uses for a mention.
function anyUrgent(windows) {
  var list = windows || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].urgent === true) return true
  }
  return false
}

function workspaceLabel(toplevel) {
  var workspace = toplevel ? toplevel.workspace : null
  if (!workspace) return ""
  var name = String(workspace.name || "")
  if (name !== "") return name
  return workspace.id === undefined ? "" : String(workspace.id)
}

// ---------------------------------------------------------------- hyprland

// A Lua-configured Hyprland wraps every IPC dispatch in hl.dispatch(...), so the legacy strings are a syntax error there.
function luaString(value) {
  return JSON.stringify(String(value || ""))
}

// "5" and "name:chat" are the same selector in both syntaxes; a bare word is a name.
function workspaceSelector(value) {
  var text = String(value || "").trim()
  if (text === "") return ""
  if (/^[0-9]+$/.test(text) || /^(name|special|empty|prev|previous|e[+-]|r[+-]|[+-])/.test(text)) return text
  return "name:" + text
}

// Quickshell reports a toplevel address as bare hex, and Hyprland's address: selector only matches with the 0x.
function windowTarget(address) {
  var hex = String(address || "").trim()
  if (hex === "") return ""
  return "address:" + (/^0x/i.test(hex) ? hex : "0x" + hex)
}

// focus: hl.dsp.focus({ window = "address:0x1" })  |  focuswindow address:0x1
function focusDispatch(address, usingLua) {
  var target = windowTarget(address)
  if (target === "") return ""
  if (usingLua) return "hl.dsp.focus({ window = " + luaString(target) + " })"
  return "focuswindow " + target
}

// move: hl.dsp.window.move({ workspace = "5", window = "address:0x1", follow = false })  |  movetoworkspacesilent 5,address:0x1
function moveDispatch(address, workspace, follow, usingLua) {
  var selector = workspaceSelector(workspace)
  var target = windowTarget(address)
  if (selector === "" || target === "") return ""
  if (usingLua) {
    return "hl.dsp.window.move({ workspace = " + luaString(selector) + ", window = " + luaString(target)
      + ", follow = " + (follow ? "true" : "false") + " })"
  }
  return (follow ? "movetoworkspace " : "movetoworkspacesilent ") + selector + "," + target
}

// prop: hl.dsp.window.set_prop({ window = "address:0x1", prop = "focus_on_activate", value = "0" })  |  setprop address:0x1 focus_on_activate 0
function propDispatch(address, prop, value, usingLua) {
  var target = windowTarget(address)
  if (target === "" || !prop) return ""
  if (usingLua) {
    return "hl.dsp.window.set_prop({ window = " + luaString(target) + ", prop = " + luaString(prop)
      + ", value = " + luaString(value) + " })"
  }
  return "setprop " + target + " " + prop + " " + String(value)
}

// True when a window already sits on the preset, so nothing has to move.
function sameWorkspace(label, workspace) {
  var selector = workspaceSelector(workspace)
  var current = String(label || "")
  if (selector === "" || current === "") return false
  return current === selector || "name:" + current === selector
}

function onWorkspace(toplevel, workspace) {
  return sameWorkspace(workspaceLabel(toplevel), workspace)
}

// openwindow data reads "55d28f0c6820,1,discord,Friends - Discord"; the title may carry commas, so it is the remainder.
function parseOpenWindow(data) {
  var parts = String(data || "").split(",")
  if (parts.length < 3) return null
  return { address: parts[0], workspace: parts[1], appClass: parts[2], title: parts.slice(3).join(",") }
}

// Measured: Discord opens a "Discord Updater" splash first, and the main window arrives while it is still up.
var SPLASH_TITLES = ["Discord Updater"]

function isSplash(title) {
  return SPLASH_TITLES.indexOf(String(title || "").trim()) !== -1
}

// The Discord windows other than the one named and other than a splash, so a first real window is told apart from a second.
function otherWindows(windows, address) {
  var target = windowTarget(address)
  var out = []
  var list = windows || []
  for (var i = 0; i < list.length; i++) {
    var toplevel = list[i]
    if (!toplevel || windowTarget(toplevel.address) === target || isSplash(toplevel.title)) continue
    out.push(toplevel)
  }
  return out
}

var WORKSPACE_PRESET_MAX = 10
var WORKSPACE_ANY = ""

// The dropdown lists "Any", the ten bound workspaces, then any named ones Hyprland knows about.
function workspaceOptions(workspaces) {
  var options = [{ value: WORKSPACE_ANY, label: "Any workspace" }]
  var seen = {}
  for (var n = 1; n <= WORKSPACE_PRESET_MAX; n++) {
    options.push({ value: String(n), label: "Workspace " + n })
    seen[String(n)] = true
  }
  var list = workspaces || []
  for (var i = 0; i < list.length; i++) {
    var ws = list[i]
    if (!ws) continue
    var name = String(ws.name || "")
    if (name === "" || seen[name] || /^[0-9]+$/.test(name) || name.indexOf("special") === 0) continue
    seen[name] = true
    options.push({ value: name, label: name })
  }
  return options
}

// Enter on the workspace row steps to the next option, wrapping, so the row works without a mouse.
function nextOption(options, value) {
  var list = options || []
  if (list.length === 0) return ""
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].value) === String(value)) return String(list[(i + 1) % list.length].value)
  }
  return String(list[0].value)
}

// ---------------------------------------------------------------- pipewire

// PwNode.properties is only valid once a PwObjectTracker has bound the node.
function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function streamNodes(nodes) {
  var list = nodes || []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].isStream) out.push(list[i])
  }
  return out
}

// Streams say "WEBRTC VoiceEngine", so the process binary alone names the app.
function isOwnedByDiscord(node) {
  return isAppId(nodeProps(node)["application.process.binary"])
}

// vesktop names every stream vesktop, so a call is only its audio capture stream, never video or playback.
// Discord publishes five nodes in a call and only one is the mic, so the name alone is not enough.
function isVoiceStream(node) {
  if (!isOwnedByDiscord(node)) return false
  var name = String(nodeProps(node)["application.name"] || "").toLowerCase()
  if (name !== "webrtc voiceengine" && name !== "vesktop") return false
  return !!node.audio && !isPlaybackStream(node)
}

function hasVoiceStream(nodes) {
  var list = nodes || []
  for (var i = 0; i < list.length; i++) {
    if (isVoiceStream(list[i])) return true
  }
  return false
}

// A playback stream publishes with isSink true, the same test the audio panel uses.
function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  return node.isSink === true
}

function findDiscordStream(nodes, playback) {
  var list = nodes || []
  for (var i = 0; i < list.length; i++) {
    var node = list[i]
    if (!node || !node.audio) continue
    if (isPlaybackStream(node) !== playback) continue
    if (isOwnedByDiscord(node)) return node
  }
  return null
}

// ---------------------------------------------------------------- process

// discord: "239958 272772 /home/gm/.config/discord/app-1.0.154/Discord --type=renderer"
// vesktop: "248461 384348 /usr/lib/vesktop/vesktop"
// The main process is the one with no --type=; signalling a child files a crash report.
function parseProcesses(raw) {
  var lines = String(raw || "").split("\n")
  var count = 0
  var rssKib = 0
  var mainPid = 0

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue

    var fields = line.split(/\s+/)
    var pid = parseInt(fields[0], 10)
    var rss = parseInt(fields[1], 10)
    if (!isFinite(pid) || !isFinite(rss)) continue

    count += 1
    rssKib += rss
    if (mainPid === 0 && fields.slice(2).join(" ").indexOf("--type=") === -1) mainPid = pid
  }

  return { count: count, memoryMib: rssKib / KIB_PER_MIB, mainPid: mainPid }
}

// -------------------------------------------------------------------- rpc

// lines look like {"ok":true,"channel":"General","guild":"GM's Server","mute":false,"speaking":["gm"]}
function parseRpcLine(raw) {
  try {
    var state = JSON.parse(String(raw))
    return state && typeof state === "object" ? state : null
  } catch (error) {
    return null
  }
}

// "General" names half the voice channels in existence, so say whose it is.
function callPlace(channel, guild) {
  if (!channel) return ""
  return guild ? channel + " · " + guild : String(channel)
}

// ---------------------------------------------------------------- signal

// Omarchy has no green or yellow, so quality is glyph strength first (NOTES.md).
var PING_GOOD_MS = 100
var PING_FAIR_MS = 250

function pingQuality(ping, connected) {
  if (!connected) return "none"
  if (!(ping > 0)) return "unknown"
  if (ping <= PING_GOOD_MS) return "good"
  if (ping <= PING_FAIR_MS) return "fair"
  return "poor"
}

function pingGlyph(quality) {
  if (quality === "good") return "󰤨"
  if (quality === "fair") return "󰤢"
  if (quality === "poor") return "󰤟"
  return "󰤯"
}

// ---------------------------------------------------------------- friends

// Discord's reachable presences; everything else, including invisible, reads as offline.
var REACHABLE_STATUSES = ["online", "idle", "dnd"]

function isOnline(status) {
  return REACHABLE_STATUSES.indexOf(String(status || "")) !== -1
}

function presenceLabel(status) {
  var text = String(status || "")
  if (text === "online") return "Online"
  if (text === "idle") return "Idle"
  if (text === "dnd") return "Do not disturb"
  if (text === "offline") return "Offline"
  return "Unknown"
}

// { "80351110224678912": "online", ... } from the bridge's friend list.
function presenceMap(friends) {
  var map = {}
  var list = friends || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id !== undefined) map[String(list[i].id)] = String(list[i].status || "offline")
  }
  return map
}

// Watched entries carry a stored name so the row reads before the bridge is up; live data wins when present.
function watchedRows(friends, watched) {
  var byId = {}
  var list = friends || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id !== undefined) byId[String(list[i].id)] = list[i]
  }
  var out = []
  var wanted = watched || []
  for (var w = 0; w < wanted.length; w++) {
    var entry = wanted[w]
    if (!entry || entry.id === undefined) continue
    var id = String(entry.id)
    var live = byId[id]
    out.push({
      id: id,
      name: live ? String(live.name) : String(entry.name || id),
      status: live ? String(live.status || "offline") : "unknown"
    })
  }
  return out
}

// Dropdown options for the friends not yet watched, names first so the search reads naturally.
function watchableFriends(friends, watched) {
  var taken = {}
  var wanted = watched || []
  for (var w = 0; w < wanted.length; w++) {
    if (wanted[w] && wanted[w].id !== undefined) taken[String(wanted[w].id)] = true
  }
  var out = []
  var list = friends || []
  for (var i = 0; i < list.length; i++) {
    var friend = list[i]
    if (!friend || friend.id === undefined || taken[String(friend.id)]) continue
    out.push({ value: String(friend.id), label: String(friend.name || friend.id), description: presenceLabel(friend.status) })
  }
  out.sort(function (a, b) { return a.label.toLowerCase() < b.label.toLowerCase() ? -1 : (a.label.toLowerCase() > b.label.toLowerCase() ? 1 : 0) })
  return out
}

// Watched friends that were unreachable in the last snapshot and reachable now; an unseen friend is never an arrival.
function arrivals(previous, friends, watched) {
  var before = previous || {}
  var now = presenceMap(friends)
  var names = {}
  var list = friends || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id !== undefined) names[String(list[i].id)] = String(list[i].name || list[i].id)
  }
  var out = []
  var wanted = watched || []
  for (var w = 0; w < wanted.length; w++) {
    var entry = wanted[w]
    if (!entry || entry.id === undefined) continue
    var id = String(entry.id)
    if (before[id] === undefined || isOnline(before[id]) || !isOnline(now[id])) continue
    out.push({ id: id, name: names[id] || String(entry.name || id), status: now[id] })
  }
  return out
}

// Discord's status names, with invisible and anything unknown reading as offline.
function normalizeStatus(status) {
  var text = String(status || "").toLowerCase()
  return isOnline(text) ? text : "offline"
}

// The BetterDiscord plugin writes {"schema":1,"active":true,"updatedAt":1727180000000,"friends":[{"id":"1","name":"GM","status":"online"}]}
function parseFriendsFile(text) {
  var parsed
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (error) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || parsed.schema !== 1) return null
  var friends = []
  var list = parsed.friends instanceof Array ? parsed.friends : []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || entry.id === undefined || entry.id === null || String(entry.id) === "") continue
    friends.push({ id: String(entry.id), name: String(entry.name || entry.id), status: normalizeStatus(entry.status) })
  }
  return { active: parsed.active === true, updatedAt: Number(parsed.updatedAt) || 0, friends: friends }
}

// A file older than this is a client that died with the plugin still marked active.
var FRIENDS_STALE_MS = 180000

function friendsFileFresh(updatedAt, nowMs) {
  return Number(updatedAt) > 0 && nowMs - Number(updatedAt) < FRIENDS_STALE_MS
}

function countOnline(rows) {
  var list = rows || []
  var count = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i] && isOnline(list[i].status)) count++
  }
  return count
}

// `omarchy bar set ... --json` stores a one-entry list as a bare object, so both shapes read as a list.
function watchedList(value) {
  if (value instanceof Array) return value
  if (value && typeof value === "object" && value.id !== undefined) return [value]
  return []
}

function addWatched(watched, id, name) {
  var list = (watched || []).slice()
  var key = String(id || "")
  if (key === "") return list
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].id) === key) return list
  }
  list.push({ id: key, name: String(name || key) })
  return list
}

function removeWatched(watched, id) {
  var key = String(id || "")
  var out = []
  var list = watched || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].id) !== key) out.push(list[i])
  }
  return out
}

// ---------------------------------------------------------------- format

function formatMemory(mib) {
  if (!(mib > 0)) return "--"
  if (mib >= MIB_PER_GIB) return (mib / MIB_PER_GIB).toFixed(1) + " GiB"
  return Math.round(mib) + " MiB"
}

// titles read "#general | GM's Server - Discord"; every one carries the suffix
function windowTitle(toplevel) {
  var title = toplevel && toplevel.title ? String(toplevel.title) : ""
  var suffix = " - Discord"
  if (title.length > suffix.length && title.slice(-suffix.length) === suffix) {
    title = title.slice(0, -suffix.length)
  }
  return title === "" ? "Discord" : title
}

function formatUsage(mib, count) {
  if (!(count > 0)) return "--"
  var processes = count === 1 ? "1 process" : count + " processes"
  return formatMemory(mib) + " · " + processes
}

// The line under the title in the panel hero, and the widget's tooltip.
function statusPhrase(service) {
  if (!service.installed) return "Not installed"
  if (!service.running) return "Not running"
  if (service.attention) return "Wants your attention"
  if (service.inVoice) {
    // The bridge knows which call; PipeWire only knows that there is one.
    var place = callPlace(service.callChannel, service.callGuild)
    if (place === "") return service.micLive ? "In a call" : "In a call · mic closed"
    return service.micLive ? place : place + " · muted"
  }
  if (!service.hasWindow) return "Running in the background"
  if (service.workspace !== "") return "Open on workspace " + service.workspace
  return "Running"
}
