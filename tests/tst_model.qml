import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
  name: "Model"

  readonly property var discordEntry: ({ startupClass: "discord", id: "discord.desktop" })
  readonly property var vesktopEntry: ({ startupClass: "vesktop", id: "vesktop.desktop" })
  readonly property var strangerEntry: ({ startupClass: "slack", id: "slack.desktop" })

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
    compare(Model.findEntry([vesktopEntry], "slack").id, "vesktop.desktop")
  }

  function test_findEntry_returns_null_when_no_client_is_installed() {
    compare(Model.findEntry([strangerEntry], ""), null)
    compare(Model.findEntry([], ""), null)
  }

  function node(binary, appName, opts) {
    var o = opts || {}
    return {
      ready: true,
      isStream: true,
      isSink: o.sink === true,
      type: "",
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

  function test_isVoiceStream_accepts_only_a_vesktop_audio_capture_stream() {
    verify(Model.isVoiceStream(node("vesktop", "vesktop", {})))

    // A screenshare or camera stream is not playback either, so it must not read as a call.
    verify(!Model.isVoiceStream(node("vesktop", "vesktop", { audio: false })))

    // Playback is never a call.
    verify(!Model.isVoiceStream(node("vesktop", "vesktop", { sink: true })))
  }

  function test_isVoiceStream_rejects_a_stream_owned_by_neither_client() {
    verify(!Model.isVoiceStream(node("slack", "vesktop", {})))
  }
}
