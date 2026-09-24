---
type: reference
title: Decisions taken while building this plugin, and what they cost
description: The choices that are not obvious from the code, each with the measurement or constraint behind it
tags: [omarchy, design, discord]
status: stable
verified:
  - by: read out of the shipped first-party plugins and Discord's own portal on Omarchy 4.0.0
    at: 2026-08-16
---

# The short IPC target

First-party panels use their module id as the IPC target, which would make this
`omarchy-shell io.github.thisisgm.discord raise`. This one registers `discord`
instead, because that is what a keybinding wants to carry and what the README has
to print. The collision risk is real and accepted.

# AppLibrary is not the launch path

`shell.appLibrary.launch()` runs exactly the
`uwsm-app -- gtk-launch <id>.desktop` this plugin already runs, plus a launch
OSD. It is a private injection documented for the menu's Apps submenu, and no
plugin under `plugins/` consumes it, so depending on it would be less
conventional rather than more.

# The palette has no green

`Color` exposes `foreground`, `background`, `accent`, `urgent` and `muted`, and
that is the whole palette. Discord draws call quality as a green, yellow or red
dot; inventing a green here would break every theme. Quality is expressed as
glyph strength first, using the network panel's own signal arcs from full to
outline, and colour second, `foreground` to dim to `urgent`.

For the same reason, a "no data" placeholder is `--`, which is what the network
panel renders, and not an em dash.

# Three values on the portal page, two of them look interchangeable

A Discord application shows a Client ID (also called Application ID), a Client
Secret behind Reset Secret on the OAuth2 page, and a Public Key on General
Information. Only the first two are wanted here. The Public Key is an Ed25519
key for verifying interaction webhook signatures, exactly 64 hex characters, and
it is the easy one to paste by mistake, so the setup path detects that shape and
says so rather than failing later inside the token exchange.

# Credentials never touch argv

The panel writes the pair to the helper over stdin, one JSON object on one line,
so a secret never appears in a command line or in `ps`. Both files are created
with `os.open` carrying the mode rather than being chmod'd after the write, so
there is no window where they exist at the default umask.

# A refused command is warned, not escalated

One command Discord turns down raises a distinct error that the session
survives; a dead socket still ends the session and reconnects. Telling an
auth-fatal refusal, an expired or revoked token, from an ordinary one would mean
keying on Discord's numeric error codes, and none of those were verified against
the live socket, so the code does not guess at them. The refusal warns on stderr
naming the command instead.

# Things deliberately not built

- **A restart action.** Quit plus start is two clicks, and the relaunch race,
  where Electron hands a launch to a still-dying instance, could not be verified.
- **Discord's own output volume slider.** The bridge implements the command, but
  the panel already has a PipeWire volume slider that answers the same question
  and keeps working outside a call. Two sliders both meaning "how loud is
  Discord" is worse than one. Mic gain was kept because nothing else exposes it.
- **`desktopId`, `windowClass` and `processName` settings.** One box, one shape,
  the Arch `discord` package. A Flatpak or a fork is a real change with a real
  test, not a configuration knob.

# Sections fold, the panel does not tab

Seven sections outgrew the 560 px cap and the panel scrolled. No first-party
panel folds, tabs or pages, so the fold was built out of their parts: a
`PanelSectionHeader` on the left, the section's one-line state on the right in
the caption the audio panel uses for its level, and a `PanelActionButton`
chevron carrying the cursor ring, as the network band switch does in its
header. The whole header row clicks; Enter on it folds. The fold list is a
setting, so it survives restarts, and the defaults fold only what fits its
caption: the workspace preset and the friends list. The cap moved from 560 to
720 px: 640, the Agents panel's number, still scrolled by one header in a call
with a favourite and the defaults open, and the screen has about 1690. The
Flickable stays as the net under a fully opened panel with a long watch list.

# No letter key for join

`j` is cursor-down in every panel and nothing else reads as "join". The
channel rows are one `j` away from the top, and `omarchy-shell discord join`
covers a keybinding, so the panel has no join letter.

# A join is the launch that stays quiet

"Switch to it" answers the question for a launch from the bar or a key: you
asked for Discord, so you get it. A channel join is asked for from wherever
you are working, usually to talk while doing something else, so it gets its
own switch, on by default, that keeps the launch silent. It is only drawn
while "Switch to it" is on, because a silent preset already keeps you put.

# No auto-join on start

A favourite that joined itself whenever Discord came up would ring a channel
every time the client restarted for an update. The one-press row starts
Discord and joins when asked; nothing joins unasked.

