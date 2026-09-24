---
type: reference
title: What a Hyprland dispatch from Quickshell has to look like on Omarchy
description: A Lua-configured Hyprland wraps every IPC dispatch in hl.dispatch(), and Quickshell hands out window addresses without the 0x that Hyprland's address selector needs
tags: [hyprland, quickshell, lua, dispatch]
status: stable
verified:
  - by: hyprctl against Hyprland 0.56.2 with the Omarchy Lua config, and a throwaway Quickshell 0.3.1 script reading Hyprland.toplevels
    at: 2026-09-24
---

# The Lua wrapper

Omarchy Quattro configures Hyprland in Lua, and a Lua-configured Hyprland
treats the argument of every IPC `dispatch` as a Lua expression handed to
`hl.dispatch(...)`. The legacy strings are therefore a syntax error there:

```
$ hyprctl dispatch focuswindow address:0xdeadbeef
error: [string "return hl.dispatch(focuswindow address:0xdead..."]:1: ')' expected near 'address'
```

The forms that work are the `hl.dsp` constructors, exactly as the shell's own
Workspaces widget sends them:

```
hl.dsp.focus({ window = "address:0x55d28f0c6820" })
hl.dsp.window.move({ workspace = "3", window = "address:0x55d28f0c6820", follow = false })
```

`follow = false` is `movetoworkspacesilent`; `follow = true` is
`movetoworkspace`. Workspace selectors are the same strings in both dialects:
`"3"`, `"name:chat"`, `"special:scratch"`.

`Quickshell.Hyprland` exposes `Hyprland.usingLua`, and the plugin picks the
dialect from it. It reads `false` until the IPC connection is up, measured at
about three seconds after a fresh Quickshell start, and `true` from then on; a
long-running shell has it right long before anyone launches Discord. A `.conf`
Hyprland still gets the legacy strings.

# The missing 0x

`HyprlandToplevel.address` is bare hex: `55d28f0c6820`. Hyprland's `address:`
selector only resolves the `0x` form, and the failure is silent. A
`hl.dsp.window.move` with `address:55d28f0c6820` answers `ok` and moves
nothing, as does one with an address that names no window at all. Nothing
falls back to the active window, so a stale address costs nothing, but a bare
one costs the whole action.

`Model.windowTarget` restores the prefix. The upstream `focuswindow` call sent
the bare address and was therefore a no-op on this Quickshell.

# The event beats the model

Quickshell's `Hyprland.toplevels` gains a window some time after Hyprland
announces it, and its class and workspace fill in later still. Hyprland's own
`openwindow` event, reachable as `Hyprland.rawEvent`, carries
`address,workspace,class,title` the instant the window exists, so the preset
is applied from that event rather than from a property change on the model.
Only the first three fields are split; the title is the remainder because it
may hold commas.

# Silent needs a property, not just a flag

`follow = false` alone does not keep you where you are on Omarchy. Discord
activates its window about a second after it maps, sampled at two-second
intervals as the active workspace jumping to the preset by t=2s, and Omarchy
sets `misc.focus_on_activate = true` in `looknfeel.lua`, so Hyprland follows
that activation. The same property exists per window:

```
hl.dsp.window.set_prop({ window = "address:0x55d28fc9c9a0", prop = "focus_on_activate", value = "0" })
hl.dsp.window.set_prop({ window = "address:0x55d28fc9c9a0", prop = "focus_on_activate", value = "unset" })
```

The table is `{ prop, value, window? }`, `value` has to be a string or
number, an unknown `prop` is refused by name, and `nofocus`,
`noinitialfocus` and `no_initial_focus` are not props; `no_focus` is. The
reply is `ok` for any value, so nothing tells you whether `unset` took; the
plugin holds the property at `0` for eight seconds after a silent placement
and unsets it, and the raise action, which is an activation, is the check
that it came back.

# Nothing comes back

`Hyprland.dispatch` in Quickshell discards Hyprland's reply, so a refused or
ignored dispatch leaves no trace. The plugin logs each command it sends at
debug level, which is what `qs log` shows, and that line is the only evidence
a move was attempted.
