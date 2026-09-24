# Discord for the Omarchy bar

A bar widget for the Discord desktop app, built the way the first-party
Dropbox and Tailscale plugins are built: vector icon, keyboard-navigable
panel, and next to no configuration.

This is a fork of [thisisgm/omarchy-discord](https://github.com/thisisgm/omarchy-discord)
that adds two things and fixes one:

- **A workspace preset.** Pick the workspace Discord opens on, and every
  launch, whether from the bar, a keybinding or autostart, lands there.
- **Friend notifications.** Watch the friends you care about and get a shell
  notification the moment one of them comes online.
- **Hyprland's Lua config.** The upstream focus action sends legacy dispatcher
  strings, which a Lua-configured Hyprland rejects. Every dispatch now follows
  `Hyprland.usingLua`.

The upstream author's work is what makes all of this possible; the plugin id,
credits and licence are unchanged.

[![On omarchyplugins.com](https://img.shields.io/badge/omarchyplugins.com-listed-8b5cf6)](https://omarchyplugins.com/plugin.html?id=io.github.thisisgm.discord)
[![Latest tag](https://img.shields.io/github/v/tag/TianTomascsik/omarchy-discord?label=version)](https://github.com/TianTomascsik/omarchy-discord/tags)

![The panel during a voice call](preview.png)

The mark is drawn as vector geometry, so it takes the theme's foreground at any
size and sits at the same ink weight as its neighbours:

![The widget in the bar, between the tray and the network icons](docs/bar.png)

While you are in a call the icon grows a dot, and that dot turns the theme's
urgent color whenever the call cannot hear you, which is the state above.

## What it tells you

| Question | Answered by | How |
|---|---|---|
| Is a supported client installed? | `DesktopEntries` | the shell's own desktop entry index, matched on `StartupWMClass=discord` or `StartupWMClass=vesktop` |
| Does it want you? | Hyprland | the window's urgency flag, which Discord raises on a mention or a DM |
| Where is the window? | Hyprland | `toplevels`, with title and workspace |
| Are you in a call? | PipeWire | Discord's WebRTC voice streams exist only while connected |
| How good is the call? | Discord RPC | `VOICE_CONNECTION_STATUS` ping, drawn as signal strength (optional tier) |
| Can the call hear you? | PipeWire | the capture stream, and whether it is muted |
| What does it cost? | `ps` | resident memory and process count |
| Which friends are online? | Discord RPC | `GET_RELATIONSHIPS` and `RELATIONSHIP_UPDATE`, drawn as presence dots (optional tier) |

Nothing polls Discord's servers, and no account, token, or developer
application is involved until you opt into the RPC tier at the bottom of
this page.

## Requirements

- **Omarchy Quattro.** This is built against its shell plugin contract.
- **Discord from the Arch `discord` package, or `vesktop`.** Every signal keys
  off the client's shape: window class `discord`, desktop entry
  `discord.desktop` and a process called `Discord`, or the same three slots
  reading `vesktop`. A Flatpak build, another fork, or Discord run as a web app
  publishes different values and is not supported. Making those work is a real
  change with a real test rather than a configuration knob, so the plugin does
  not pretend otherwise.
- **python3**, and only for the optional voice bridge at the bottom of this
  page. Omarchy already ships it.
- **Hyprland with either config dialect.** The plugin reads
  `Hyprland.usingLua` and speaks `hl.dsp.*` to a Lua-configured compositor and
  the classic `focuswindow` / `movetoworkspacesilent` strings to a `.conf` one.

## Install

```bash
omarchy plugin add https://github.com/TianTomascsik/omarchy-discord.git --enable
```

If the upstream plugin is already installed, point its checkout at this fork
instead, since both carry the same plugin id:

```bash
cd ~/.config/omarchy/plugins/io.github.thisisgm.discord
git remote set-url origin https://github.com/TianTomascsik/omarchy-discord.git
git pull --ff-only
omarchy restart shell
```

Or, from a local checkout:

```bash
cp -r omarchy-discord ~/.config/omarchy/plugins/io.github.thisisgm.discord
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.thisisgm.discord
```

## Replace Discord's own tray icon

Discord registers a tray item of its own, so out of the box you get two Discord
icons in the bar. Omarchy already solves this for its bundled plugins, since the
tray hides Dropbox's item when the Dropbox widget is loaded, but that list lives
in the shell and takes no plugin hook. So hide Discord's item once by hand:

right-click the tray > **Manage** > untick Discord.

That writes `discord_status_icon_1` into the tray's `hidden` list in
`~/.config/omarchy/shell.json`, and it stays hidden across restarts. Untick it
again if you ever remove this widget.

## Using it

The bar icon dims when Discord is not running, turns the theme's urgent
color when Discord wants your attention, and grows a dot while you are in a
voice call. The dot is urgent-colored whenever the call cannot hear you.

| Input | Does |
|---|---|
| Left click | open the panel |
| Middle click | raise Discord, or start it |
| Right click | mute the call mic, or refresh when not in a call |
| Scroll | Discord's volume |
| `o` / `m` / `d` / `r` | raise / mute mic / deafen / refresh |
| `j` `k`, `Enter` | move and activate; `h` `l` set volume on the volume row |
| `Enter` on a section header | fold or unfold it; the fold is remembered |
| `x` on a channel or friend row | remove it from the favourites or the watch list |
| `w` on a channel row | watch it, or stop: the same as its bell |

Every section folds. A folded header keeps its one-line summary on the right,
"3 · silent" for the workspace, "2 online" for friends, the call's name for
voice, so nothing important disappears with the rows. Workspace and Friends
start folded; the call, the windows and the channels start open, since those
are what the panel is opened for.

### Keybindings

The panel is not the only way in. Bind these anywhere:

```bash
omarchy-shell discord raise    # focus the window, or start Discord
omarchy-shell discord mute     # toggle the call microphone
omarchy-shell discord deafen   # toggle deafen (needs the bridge, below)
omarchy-shell discord hangup   # leave the call (needs the bridge, below)
omarchy-shell discord join general   # join the favourite channel named general (needs the bridge)
omarchy-shell discord notifytest     # the friend popup and sound, to check them
omarchy-shell discord toggle   # the panel
```

`join` takes a favourite's name, case-insensitively and with or without the
`#`; an empty name means the first favourite. It answers `ok` or says why not:
`no favourite channels`, `no favourite channel matches x`, `Voice controls are
needed to join`.

`mute` is the interesting one: it works from any workspace without focusing
Discord. Without the optional bridge it mutes Discord's microphone at the
PipeWire level; with it, it presses Discord's own mute button.

Each verb answers `ok`, or says why it did nothing: `no voice bridge`,
`no microphone to mute`, `Discord is not installed`.

## Open Discord on a chosen workspace

The panel's **Workspace** section holds a dropdown of your ten bound workspaces
plus any named ones Hyprland knows about. Pick one and the plugin moves
Discord's first window there the moment it appears, whichever launcher opened
it: the bar, `SUPER + D`, autostart or a tray unhide. Nothing is written to
your Hyprland config, so unpicking it leaves no trace.

By default the move is silent and you stay where you are. The **Switch to it**
toggle, shown once a workspace is picked, follows the window instead. `Enter`
on the row steps through the workspaces for keyboard use.

With switching on, one launch is treated differently: a channel join. Pressing
a favourite, or `omarchy-shell discord join`, is something you do from
wherever you are working, so **Joining a channel** defaults to starting
Discord in the background on its workspace, and only that row's switch makes a
join follow the window like any other launch.

Silent takes one extra step on Omarchy. Discord activates its own window
about a second after it appears, and Omarchy's Hyprland config has
`focus_on_activate` on, so the compositor would follow it anyway. The plugin
therefore turns that property off on the new window for eight seconds and
puts it back, which is long enough for Discord to finish arriving and short
enough that clicking a Discord notification still works as before.

The same two values from a shell:

```bash
omarchy bar set io.github.thisisgm.discord workspace 3
omarchy bar set io.github.thisisgm.discord followWorkspace true --json
omarchy bar set io.github.thisisgm.discord workspace '""' --json   # back to "anywhere"
```

## Favourite voice channels, joined in one press

With the optional RPC tier below set up, the panel gains a **Channels**
section. **Add a channel** searches every voice channel of every server you
are in, and each pick becomes a row: press it and you are in that call, press
it again and you leave. If you are in a different call, Discord moves you. If Discord is not running, the
same press starts it, lands it on your workspace preset, waits for its voice
engine and then joins; the hero reads "Starting Discord to join #general"
meanwhile, and gives up with a reason after a minute. Each row shows the
server and, once the bridge has looked, how many people are in the channel.

Joining goes through Discord's own `SELECT_VOICE_CHANNEL`, so it needs the
bridge; the rows still show without it, and pressing one says so.

Each row also shows who is in the channel, live: the bridge subscribes to
Discord's voice-state events for every favourite, so names appear the moment
someone joins. The bell on a row (or `w` on the keyboard) **watches** the
channel: when someone joins it while you are elsewhere, you get the same popup
and sound a friend's arrival makes, "Fabsi joined #Fummelparty", and pressing
the popup joins you too. People arriving together are one popup, a channel is
announced at most every thirty seconds, and nothing is announced for the
channel you are sitting in.

## Friend notifications

The panel's **Friends** section lets you watch friends and be told when they
come online. **Watch a friend** searches your friend list; each watched friend
gets a row with a presence dot, their name and their status, and its switch
stops watching. When a watched friend goes from offline to online, idle or do
not disturb, the shell raises a notification, and clicking it raises Discord.

Discord only hands the friend list to applications it has approved for the
`relationships.read` scope, and it refuses an ordinary one (measured, see the
RPC section below). So the list comes from inside the client instead: this
repo ships **OmarchyDiscord**, a small plugin for
[BetterDiscord](https://betterdiscord.app) that reads Discord's own friend and
presence stores and writes them to `~/.local/state/omarchy-discord/friends.json`,
readable only by you and never sent anywhere. The widget watches that file.

To enable it:

1. Have BetterDiscord injected into your Discord. On Arch,
   `yay -S betterdiscordctl` then `betterdiscordctl install`, and restart
   Discord. A Discord update removes the injection, so repeat the `install`
   when your BetterDiscord plugins stop appearing in Settings.
2. Copy `betterdiscord/OmarchyDiscord.plugin.js` into
   `~/.config/BetterDiscord/plugins/` and switch it on under
   Settings > Plugins. The Friends section fills in within a second.
3. The file carries a heartbeat every minute; if Discord dies with the plugin
   still marked active, the widget stops trusting the file after three
   minutes and says so.

Without BetterDiscord the section explains where presence comes from and the
rest of the plugin is unaffected. An application Discord *has* approved for
`relationships.read` can use the bridge instead, through the
**Enable friend presence** row.

Three things keep it quiet: the first list after a connect only seeds, so
nobody is announced for merely already being online; a friend added to the
list while online is not an arrival; and one friend cannot fire more than
once a minute.

An arrival, whether a friend coming online or someone joining a watched
channel, is a popup and a sound, each with its own switch in the Friends
section. Omarchy's notification server plays nothing itself, so the sound is
the plugin's: the freedesktop "message-new-instant" sound through PipeWire
(`pw-play`), or any file you name in the `notifySoundFile` setting.
**Send a test notification** fires both so you can check the volume, as does
`omarchy-shell discord notifytest`.

Presence uses the theme like the rest of the panel: foreground for online,
dim for idle, the urgent color for do not disturb, faint for offline. Friends
who are invisible read as offline, which is what Discord shows everyone else
too.

## Settings

Ten, in Setup > Plugins or with `omarchy bar set`:

| Key | Type | Does |
|---|---|---|
| `hideWhenStopped` | boolean | hide the icon when Discord is not running |
| `workspace` | string | workspace id or name Discord opens on; `""` leaves it alone |
| `followWorkspace` | boolean | switch to that workspace instead of moving silently |
| `joinInBackground` | boolean | a channel join starts Discord without switching, even when `followWorkspace` is on |
| `watchedFriends` | array of `{id, name}` | friends to announce; edited from the panel |
| `favouriteChannels` | array of `{id, name, guildId, guild}` | voice channels with a join row; edited from the panel |
| `collapsed` | array of section ids | headers that start folded: `voice`, `setup`, `windows`, `channels`, `workspace`, `friends` |
| `notifyPopup` | boolean | show the shell's popup when a watched friend comes online |
| `notifySound` | boolean | play a sound as well |
| `notifySoundFile` | path | the sound to play; empty means `/usr/share/sounds/freedesktop/stereo/message-new-instant.oga` |

## Limits worth knowing

- **Attention needs a window.** Hyprland can only flag a window that exists,
  so an instance closed to the tray reports nothing. The widget shows
  "Running in the background" and can raise it.
- **Mic control needs an open capture stream.** Discord releases the stream
  when it closes the microphone, and there is nothing to mute at the PipeWire
  level until it comes back. The row appears when the stream does.
- **Vesktop's call dot rides its capture stream.** Vesktop publishes no
  voice-engine name for its streams, so the capture stream is the call signal.
  Unlike Discord it keeps that stream under its own mute, so the dot survives
  muting.
- **Muting here is not Discord's mute button.** Discord's own UI will still
  show you as unmuted while PipeWire feeds it silence.
- **Joining a channel needs the voice controls.** The rows are there without
  them, but only the bridge can press Discord's join button for you.
- **A cold start waits for Discord's voice engine.** Nothing tells the bridge
  when a freshly started client can take a join, so it asks with a timeout,
  retries once, and reports after a minute if Discord never answered.

Both limits go away with the optional bridge below, which drives Discord's own
mute instead.

## Optional: Discord's own voice controls and friend presence

Everything above the Friends section needs no account, token, or setup. Five
things cannot be had that way, because nothing outside Discord knows them:
**which** channel you are in, Discord's own mute and deafen, hanging up, and
which of your friends are online.

Those come from Discord's local RPC socket, and Discord gates it. The socket
refuses any client id that is not a registered application:

```
{"code":4000,"message":"Invalid Client ID"}
```

Client ids are public, so the plugin could ship one, but the `rpc` scope it
needs is approval-gated, and until an app is approved only accounts on its
**App Testers** list may authorize. A shipped client id would therefore work
for the author and for nobody else. There is no anonymous route.

So the bridge is opt-in, and **the plugin is complete without it**. With no
credentials `rpc.py` exits immediately, the panel still knows you are in a call
because PipeWire says so, and the voice section quietly offers to set itself up:

![The panel with no credentials, offering to set up voice controls](docs/setup.png)

To turn it on, open the panel and use **Set up voice controls**, which takes the
two values inline, no terminal. The same thing from a shell, if you prefer:

```bash
python3 ~/.config/omarchy/plugins/io.github.thisisgm.discord/rpc.py --setup
```

That opens the developer portal, prints the two things to create there, and
takes the **Client ID** and **Client Secret**, both on the application's OAuth2
page with the secret behind *Reset Secret*. It then authorizes against your
running Discord, so you find out it worked before you leave the terminal. It
stores the pair in `~/.config/omarchy-discord/credentials.json` and the token
in `~/.local/state/omarchy-discord/token.json`, both `0600`. The panel writes
those values over stdin, so a secret never appears in a command line or in `ps`.

The **Public Key** on *General Information* is a different value: it verifies
interaction webhook signatures and cannot buy a token. It is 64 hex characters,
and `--setup` rejects it by name if you paste it.

Open the panel afterwards, no restart needed, and it gains the call's name,
deafen, mic gain, and a leave-call row, and the mic row starts driving
Discord's own mute. `--probe` re-checks it any time, and says whether friend
presence was granted.

The first consent asks for the three voice scopes only: `rpc`,
`rpc.voice.read` and `rpc.voice.write`. Discord is asked exactly once per
bridge start. If it refuses, the panel keeps the reason on screen, the bridge
stays down rather than asking again every few seconds, and two rows appear:
**Try authorizing again** with the saved application, and **Enter a different
application**. The refusal you are most likely to meet is
`Missing "redirect_uri" in request`, which means the application has no
redirect saved on its OAuth2 page yet; add `http://localhost/omarchy-discord`
there, click **Save Changes**, and try again.

Friend presence rides a fourth scope, `relationships.read`, which Discord
grants only to applications it has approved for it. Measured on an ordinary
application with everything else in order, the answer is
`invalid_scope: The requested scope is invalid, unknown, or malformed`, with
no consent modal and no exception for the application's owner. The
**Enable friend presence** row in the Friends section still asks, because an
approved application would succeed, and a refusal costs nothing: the voice
tier keeps working and Discord's reason is shown. For a personal application,
expect the refusal.

If you are not the application's owner, your account has to be on its **App
Testers** list; the owner is already covered.

## Uninstall

```bash
omarchy plugin remove io.github.thisisgm.discord
rm -rf ~/.config/omarchy-discord ~/.local/state/omarchy-discord
```

Those two directories are the client secret and the token from voice controls, so
they go with the plugin rather than outliving it. Nothing else is left behind except
the tray entry you unticked, if you got that far.

## Contributing

Patches and bug reports are welcome, here for the fork's features and
[upstream](https://github.com/thisisgm/omarchy-discord) for everything the
two share. `CONTRIBUTING.md` has the two-copy layout, how to test a change
against a running shell, and the house rules the code is held to.

The platform facts this depends on, such as how PipeWire names Discord's
streams and what the RPC handshake refuses, live in `knowledge/` as an
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
bundle. Every one of them was measured on a running machine, so the next person
does not have to rediscover them.

## Support

If this saved you an afternoon, the upstream author takes
[coffee](https://buymeacoffee.com/thisisgm).

## License

MIT.
