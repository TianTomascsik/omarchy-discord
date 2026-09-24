import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
  name: "Model"

  readonly property var discordEntry: ({ startupClass: "discord", id: "discord.desktop" })
  readonly property var vesktopEntry: ({ startupClass: "vesktop", id: "vesktop.desktop" })
  readonly property var strangerEntry: ({ startupClass: "slack", id: "slack.desktop" })
  // Most .desktop files carry no StartupWMClass, and production passes the whole list.
  readonly property var classlessEntry: ({ id: "gimp.desktop" })

  function test_findEntry_prefers_the_client_last_seen_running() {
    var both = [discordEntry, vesktopEntry]
    compare(Model.findEntry(both, "vesktop").id, "vesktop.desktop")
    compare(Model.findEntry(both, "discord").id, "discord.desktop")

    // Desktop list order must not decide it, so the reversed list answers the same.
    compare(Model.findEntry([vesktopEntry, discordEntry], "vesktop").id, "vesktop.desktop")
  }

  function test_findEntry_falls_back_to_APP_IDS_order_not_list_order() {
    // No preference and both installed: discord wins on every machine, either way round.
    compare(Model.findEntry([discordEntry, vesktopEntry], "").id, "discord.desktop")
    compare(Model.findEntry([vesktopEntry, discordEntry], "").id, "discord.desktop")
  }

  function test_findEntry_ignores_a_preference_outside_the_supported_set() {
    // The stranger must be IN the list, or the case passes whether or not the gate exists.
    compare(Model.findEntry([strangerEntry, vesktopEntry], "slack").id, "vesktop.desktop")
  }

  function test_findEntry_returns_null_when_no_client_is_installed() {
    compare(Model.findEntry([strangerEntry], ""), null)
    compare(Model.findEntry([], ""), null)
  }

  function test_findEntry_never_matches_an_entry_without_a_startup_class() {
    // The empty sentinel for an unsupported preference must not select these.
    compare(Model.findEntry([classlessEntry], "slack"), null)
    compare(Model.findEntry([classlessEntry, vesktopEntry], "slack").id, "vesktop.desktop")
  }

  function node(binary, appName, opts) {
    var o = opts || {}
    return {
      ready: true,
      isStream: true,
      isSink: o.sink === true,
      type: 0,
      audio: o.audio === false ? null : ({ muted: false }),
      properties: { "application.process.binary": binary, "application.name": appName }
    }
  }

  function test_isVoiceStream_accepts_the_discord_voice_engine() {
    verify(Model.isVoiceStream(node("Discord", "WEBRTC VoiceEngine", {})))
  }

  function test_isVoiceStream_rejects_a_discord_stream_that_is_not_the_voice_engine() {
    verify(!Model.isVoiceStream(node("Discord", "Chromium input", {})))
  }

  // Measured in a live call: Discord publishes five nodes, and three carry this same name.
  function test_isVoiceStream_rejects_the_discord_playback_and_non_audio_nodes() {
    verify(!Model.isVoiceStream(node("Discord", "WEBRTC VoiceEngine", { sink: true })))
    verify(!Model.isVoiceStream(node("Discord", "WEBRTC VoiceEngine", { audio: false })))
  }

  function test_isVoiceStream_accepts_only_a_vesktop_audio_capture_stream() {
    verify(Model.isVoiceStream(node("vesktop", "vesktop", {})))

    // A screenshare or camera stream is not playback either, so it must not read as a call.
    verify(!Model.isVoiceStream(node("vesktop", "vesktop", { audio: false })))

    // Playback is never a call.
    verify(!Model.isVoiceStream(node("vesktop", "vesktop", { sink: true })))
  }

  // The five nodes a live Discord call actually publishes, three sharing the same name.
  function test_hasVoiceStream_accepts_exactly_the_capture_node_of_a_real_call() {
    var call = [
      node("Discord", "WEBRTC VoiceEngine", {}),                 // 82, Stream/Input/Audio
      node("Discord", "WEBRTC VoiceEngine", { sink: true }),     // 74, Stream/Output/Audio
      node("Discord", "WEBRTC VoiceEngine", { audio: false }),   // 79, no media.class
      node("Discord", "WEBRTC VoiceEngine", { audio: false }),   // 83, no media.class
      node("Discord", "Chromium input", { audio: false })        // 84, no media.class
    ]
    verify(Model.hasVoiceStream(call))
    var accepted = 0
    for (var i = 0; i < call.length; i++) {
      if (Model.isVoiceStream(call[i])) accepted++
    }
    compare(accepted, 1)

    // The same set with the mic gone is not a call, which is what the widget must show.
    verify(!Model.hasVoiceStream(call.slice(1)))
  }

  function test_isVoiceStream_rejects_a_stream_owned_by_neither_client() {
    verify(!Model.isVoiceStream(node("slack", "vesktop", {})))
  }

  function test_isVoiceStream_rejects_a_node_the_tracker_has_not_bound_yet() {
    var unbound = node("vesktop", "vesktop", {})
    unbound.ready = false
    verify(!Model.isVoiceStream(unbound))
  }

  // ---------------------------------------------------------------- hyprland

  function test_focusDispatch_speaks_lua_only_when_hyprland_does() {
    compare(Model.focusDispatch("0x1", false), "focuswindow address:0x1")
    compare(Model.focusDispatch("0x1", true), 'hl.dsp.focus({ window = "address:0x1" })')
    compare(Model.focusDispatch("", true), "")
  }

  // Measured: Quickshell 0.3.1 hands over "55d28f0c6820" and Hyprland 0.56 only resolves "0x55d28f0c6820".
  function test_windowTarget_restores_the_0x_quickshell_drops() {
    compare(Model.windowTarget("55d28f0c6820"), "address:0x55d28f0c6820")
    compare(Model.windowTarget("0x55d28f0c6820"), "address:0x55d28f0c6820")
    compare(Model.windowTarget(" 0X1 "), "address:0X1")
    compare(Model.windowTarget(""), "")
    compare(Model.moveDispatch("55d28f0c6820", "3", false, false), "movetoworkspacesilent 3,address:0x55d28f0c6820")
  }

  function test_moveDispatch_carries_the_follow_flag_in_both_syntaxes() {
    compare(Model.moveDispatch("0x1", "5", false, false), "movetoworkspacesilent 5,address:0x1")
    compare(Model.moveDispatch("0x1", "5", true, false), "movetoworkspace 5,address:0x1")
    compare(Model.moveDispatch("0x1", "5", false, true),
      'hl.dsp.window.move({ workspace = "5", window = "address:0x1", follow = false })')
    compare(Model.moveDispatch("0x1", "5", true, true),
      'hl.dsp.window.move({ workspace = "5", window = "address:0x1", follow = true })')
  }

  function test_propDispatch_sets_a_window_property_in_both_syntaxes() {
    compare(Model.propDispatch("0x1", "focus_on_activate", "0", true),
      'hl.dsp.window.set_prop({ window = "address:0x1", prop = "focus_on_activate", value = "0" })')
    compare(Model.propDispatch("1", "focus_on_activate", "unset", false), "setprop address:0x1 focus_on_activate unset")
    compare(Model.propDispatch("", "focus_on_activate", "0", true), "")
    compare(Model.propDispatch("0x1", "", "0", true), "")
  }

  function test_moveDispatch_is_empty_without_a_target_or_a_preset() {
    compare(Model.moveDispatch("0x1", "", false, true), "")
    compare(Model.moveDispatch("", "5", false, true), "")
  }

  function test_workspaceSelector_prefixes_bare_names_only() {
    compare(Model.workspaceSelector("5"), "5")
    compare(Model.workspaceSelector("chat"), "name:chat")
    compare(Model.workspaceSelector("name:chat"), "name:chat")
    compare(Model.workspaceSelector("special:scratch"), "special:scratch")
    compare(Model.workspaceSelector(" "), "")
  }

  function test_onWorkspace_matches_ids_and_names() {
    verify(Model.onWorkspace({ workspace: { id: 5, name: "5" } }, "5"))
    verify(!Model.onWorkspace({ workspace: { id: 5, name: "5" } }, "3"))
    verify(Model.onWorkspace({ workspace: { id: -1, name: "chat" } }, "chat"))
    verify(!Model.onWorkspace(null, "5"))
    verify(!Model.onWorkspace({ workspace: { id: 5, name: "5" } }, ""))
    verify(Model.sameWorkspace("1", "1"))
    verify(!Model.sameWorkspace("", "1"))
  }

  // Measured: "55d28f0c6820,1,discord,Friends - Discord" is what Hyprland 0.56 sends for Discord's first window.
  function test_parseOpenWindow_splits_three_fields_and_keeps_the_title_whole() {
    var opened = Model.parseOpenWindow("55d28f0c6820,1,discord,Friends, DMs - Discord")
    compare(opened.address, "55d28f0c6820")
    compare(opened.workspace, "1")
    compare(opened.appClass, "discord")
    compare(opened.title, "Friends, DMs - Discord")
    compare(Model.parseOpenWindow("55d28f0c6820,1"), null)
    compare(Model.parseOpenWindow(""), null)
  }

  // Measured on a cold start: "Discord Updater" opens first and the main window arrives while it is still there.
  function test_otherWindows_tells_a_first_window_from_a_second_and_ignores_the_splash() {
    var splash = { address: "0x1", title: "Discord Updater" }
    var main = { address: "0x2", title: "Discord" }
    compare(Model.otherWindows([], "1").length, 0)
    compare(Model.otherWindows([splash], "2").length, 0)
    compare(Model.otherWindows([main], "2").length, 0)
    compare(Model.otherWindows([main], "3").length, 1)
    compare(Model.otherWindows([splash, main], "3").length, 1)
    verify(Model.isSplash(" Discord Updater "))
    verify(!Model.isSplash("Friends - Discord"))
  }

  function test_workspaceOptions_lists_any_ten_numbers_then_named_ones() {
    var options = Model.workspaceOptions([{ id: 1, name: "1" }, { id: -2, name: "chat" }, { id: -3, name: "special:x" }])
    compare(options[0].value, "")
    compare(options.length, 1 + Model.WORKSPACE_PRESET_MAX + 1)
    compare(options[options.length - 1].value, "chat")
  }

  function test_nextOption_wraps_and_recovers_from_an_unknown_value() {
    var options = [{ value: "" }, { value: "1" }, { value: "2" }]
    compare(Model.nextOption(options, ""), "1")
    compare(Model.nextOption(options, "2"), "")
    compare(Model.nextOption(options, "zz"), "")
    compare(Model.nextOption([], "1"), "")
  }

  // ---------------------------------------------------------------- friends

  readonly property var friendList: [
    { id: "1", name: "amy", status: "online" },
    { id: "2", name: "Zed", status: "offline" },
    { id: "3", name: "bob", status: "idle" }
  ]

  function test_watchedRows_take_live_data_and_fall_back_to_the_stored_name() {
    var rows = Model.watchedRows(friendList, [{ id: "2", name: "old zed" }, { id: "9", name: "gone" }])
    compare(rows[0].name, "Zed")
    compare(rows[0].status, "offline")
    compare(rows[1].name, "gone")
    compare(rows[1].status, "unknown")
  }

  function test_watchableFriends_exclude_the_watched_and_sort_by_name() {
    var options = Model.watchableFriends(friendList, [{ id: "1", name: "amy" }])
    compare(options.length, 2)
    compare(options[0].label, "bob")
    compare(options[1].label, "Zed")
    compare(options[1].description, "Offline")
  }

  function test_arrivals_only_count_offline_to_reachable_for_watched_friends() {
    var before = { "1": "offline", "2": "offline", "3": "online" }
    var watched = [{ id: "1", name: "amy" }, { id: "3", name: "bob" }]
    var arrivals = Model.arrivals(before, friendList, watched)
    compare(arrivals.length, 1)
    compare(arrivals[0].id, "1")
    compare(arrivals[0].status, "online")
  }

  function test_arrivals_ignore_a_friend_never_seen_before() {
    // Adding an online friend to the watch list is not that friend coming online.
    compare(Model.arrivals({}, friendList, [{ id: "1", name: "amy" }]).length, 0)
  }

  function test_arrivals_ignore_unwatched_friends() {
    compare(Model.arrivals({ "1": "offline" }, friendList, []).length, 0)
  }

  function test_presence_labels_and_reachability() {
    verify(Model.isOnline("dnd"))
    verify(!Model.isOnline("offline"))
    verify(!Model.isOnline("unknown"))
    compare(Model.presenceLabel("dnd"), "Do not disturb")
    compare(Model.presenceLabel("nonsense"), "Unknown")
    compare(Model.countOnline(friendList), 2)
  }

  function test_parseFriendsFile_reads_the_betterdiscord_plugins_shape() {
    var parsed = Model.parseFriendsFile('{"schema":1,"active":true,"updatedAt":5,"friends":[{"id":1,"name":"GM","status":"ONLINE"},{"id":"2","status":"invisible"},{"name":"nobody"}]}')
    verify(parsed.active)
    compare(parsed.updatedAt, 5)
    compare(parsed.friends.length, 2)
    compare(parsed.friends[0].id, "1")
    compare(parsed.friends[0].status, "online")
    compare(parsed.friends[1].name, "2")
    compare(parsed.friends[1].status, "offline")
  }

  function test_parseFriendsFile_rejects_garbage_and_other_schemas() {
    compare(Model.parseFriendsFile(""), null)
    compare(Model.parseFriendsFile("not json"), null)
    compare(Model.parseFriendsFile('{"schema":2,"friends":[]}'), null)
    compare(Model.parseFriendsFile('[]'), null)
    var stopped = Model.parseFriendsFile('{"schema":1,"active":false}')
    verify(!stopped.active)
    compare(stopped.friends.length, 0)
  }

  function test_friendsFileFresh_expires_a_dead_client() {
    verify(Model.friendsFileFresh(1000, 1000 + Model.FRIENDS_STALE_MS - 1))
    verify(!Model.friendsFileFresh(1000, 1000 + Model.FRIENDS_STALE_MS))
    verify(!Model.friendsFileFresh(0, 5000))
  }

  function test_watchedList_accepts_the_bare_object_the_cli_stores() {
    compare(Model.watchedList([{ id: "1" }]).length, 1)
    compare(Model.watchedList({ id: "1", name: "amy" }).length, 1)
    compare(Model.watchedList({ name: "no id" }).length, 0)
    compare(Model.watchedList(null).length, 0)
    compare(Model.watchedList("x").length, 0)
  }

  function test_addWatched_and_removeWatched_keep_the_list_deduplicated() {
    var one = Model.addWatched([], "1", "amy")
    var same = Model.addWatched(one, "1", "amy again")
    compare(same.length, 1)
    compare(same[0].name, "amy")
    compare(Model.addWatched(one, "", "nobody").length, 1)
    compare(Model.removeWatched(same, "1").length, 0)
    compare(Model.removeWatched(same, "7").length, 1)
  }
}
