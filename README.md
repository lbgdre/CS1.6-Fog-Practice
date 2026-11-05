# CS 1.6 FOG Practice + Speed HUD (AMX Mod X)

Two AMX Mod X plugins for **Counter-Strike 1.6** bhop practice on a local listen server:

- **fog_practice**: every scroll-wheel bhop gets the best horizontal takeoff speed of FOG 1, 2 or 3 (FOG = frames on ground).
- **speed_hud**: a standalone speedometer showing current speed, takeoff speed, FOG, and how long you ducked before landing. It's laid out like the gcljs speed panel.

> [!WARNING]
> **fog_practice is NOT legit for records.**
> It changes movement physics: it delays jumps and replaces your takeoff velocity so you always get the optimal FOG.
> Any run, time, jumpstat or demo made with it enabled is **not legit**.
> **Disable it before any record attempt**: type `/fog` in chat, set `fog_enable 0`, or remove `fog_practice.amxx` from `plugins.ini`.
> Never run it on a public or competitive server.

## What it is for

Scroll-wheel bhopping makes your FOG random. The same strafe gives a different takeoff speed depending on whether the jump landed on ground frame 1, 2 or 3. fog_practice removes that luck, so you can **practice and test your strafes as if every bhop had optimal FOG**. That shows how much speed your air strafing really gains, and lets you work on strafes and sync without FOG noise.

speed_hud only displays; it doesn't change movement. While fog_practice is on, the numbers it shows come from altered physics, so they are not legit either.

## Requirements

- Counter-Strike 1.6 (Steam), **listen server** (New Game / Create Server).
- Metamod + AMX Mod X 1.10 (tested on 1.10.0.5467 with Metamod 1.21-am).
- Stock modules only (`fakemeta`). It does **not** need ReHLDS, ReGameDLL, ReAPI or Orpheu.

## Install

1. Copy the `addons` folder from this repo into `Half-Life\cstrike\`. It merges into your existing `addons\amxmodx`.
2. Add these lines to the end of `cstrike\addons\amxmodx\configs\plugins.ini`. Keep `fog_practice` last among movement plugins, so its PreThink hook runs closest to the movement code.
   ```
   fog_practice.amxx
   speed_hud.amxx
   ```
3. Start a listen server and check `amxx plugins` in the console.

To rebuild from source, run `amxxpc fog_practice.sma` and `amxxpc speed_hud.sma`. Both compile with 0 warnings.

## Commands and cvars

### fog_practice

| Name | Default | |
|---|---|---|
| `say /fog` | | toggle for yourself |
| `say /fogmenu` (or console `fogmenu`) | | settings menu |
| `fog_enable` | 1 | master switch |
| `fog_max` | 3 | highest FOG considered (1-3) |
| `fog_fix_vz` | 1 | on a backward rewrite, also use the earlier frame's jump height |
| `fog_debug` | 0 | 1 = summary to console + full log in `addons/amxmodx/logs/fog_debug.log`; 2 = full detail to console |
| `fog_dd` | 1 | double duck: give the speed of a DD pressed on the first possible frame |
| `fog_dd_max` | 3 | DD: best of the first N possible DD FOGs (1-5; 1 = no correction) |

### speed_hud

| Name | Default | |
|---|---|---|
| `say /speedhud` | | toggle for yourself |
| `say /speedmenu` (or console `speedmenu`) | | settings menu |
| `speed_hud_enable` | 1 | |
| `speed_hud_x` / `speed_hud_y` | -1.0 / 0.7 | position |
| `speed_hud_color` | "255 255 255" | |
| `speed_hud_fog_max` | 8 | hide FOG above this |
| `speed_hud_fog_mode` | 1 | 1 = FOG whose speed you got (`FOG: 2 (f3)` after a rewrite), 0 = frame you left the ground on |
| `speed_hud_duck` | 1 | show `D: n` (usercmds ducked in the air before the landing) |
| `speed_hud_keep` | 0 | keep the takeoff line after landing |
| `speed_hud_hold` | 0.02 | big-font hold time; it redraws every usercmd (same as gcljs). Don't set 0.01: messages lasting exactly one frame flicker and double up |
| `speed_hud_style` | 0 | 0 = big font (DHUD, refresh = `speed_hud_hold`); 1 = normal HUD font: redraws every usercmd and never overlaps |
| `speed_hud_debug` | 0 | log `SPDJ` lines next to fog_practice's `FOGJ` |

### Menus

Each plugin has its own menu.
- **`/fogmenu`** (fog_practice): plugin for me, plugin for everyone, jump: best of FOG 1 to N (1-3), DD gets first frame, DD: best of first N frames (1-5), rewrite uses earlier jump height, debug output on/off.
- **`/speedmenu`** (speed_hud): HUD on/off, what FOG shows, the D (duck) line, color, height (0.55-0.85 in 0.05 steps), horizontal position, show FOG up to, debug log.

"For me" items work for everyone. Server-wide items need cvar access (flag `g`). On a listen server the host has it.
Menu changes are saved to `addons/amxmodx/configs/fog_practice.cfg` and `speed_hud.cfg`, which are loaded on every map start. Delete those files to reset to defaults.

### Double duck (DD, CJ / DCJ / MCJ / standup variants)

A ground scroll duck (DD) takes two usercmds:
- **Press frame:** a ground frame, with friction and the 0.333 duck move scale.
- **Lift frame:** with duck released while the duck is still in transition (`bInDuck`), PM_UnDuck raises you 18 units. You are airborne for that whole frame.

DD has no 300 cap, so the earliest DD is the fastest. That's the minimum "DD FOG":
- 2 after a standing landing (gs)
- 3 after a ducked landing, because the first frame is spent standing up (sgs / standup variants)

With `fog_dd 1`, a DD whose lift lands within the first `fog_dd_max` (default 3, range 1-5) possible DD FOGs gets the speed of a DD pressed on the first possible frame. On the lift frame, before movement runs, the plugin replaces your velocity with your recorded first-frame state run through one press frame (friction plus x0.333 accel). The engine then runs the lift itself.
- Lift timing and position are unchanged, like a bhop rewrite.
- The final jump of a CJ / MCJ is a normal bhop and gets the normal best-of-FOG treatment.
- Debug lines: `FOGD` (lift frame, press frame, first possible frame, before/after speed, and a note: `already-first`, `too-late`, `not-better`, or a skip reason).

## How fog_practice works (short)

On the stock engine, changing the usercmd in `FM_CmdStart` does **not** reach the movement code. `SV_RunCmd` copies the cmd before the game sees it. So the plugin acts in `FM_PlayerPreThink` (post) on the pev fields that `SV_SetupPMove` copies into pmove:

- **Delay** a jump: set `oldbuttons |= IN_JUMP`. PM_Jump sees "button held" and skips the jump.
- **Jump now:** clear `IN_JUMP` from `oldbuttons`.
- **Emulate** a takeoff (no IN_JUMP in the cmd, or a backward rewrite): preset velocity with vz > 180. The engine then puts the player in the air and runs the rest of the jump frame itself.

Duck and unduck frames are modelled through PM_Duck's 0.333 move scale and PM_UnDuck's 18-unit raise, including the double-duck lift.
All formulas are cited from ReGameDLL_CS `pm_shared.cpp` and ReHLDS `sv_user.cpp` in the source comments.
See [docs/TECHNICAL.md](docs/TECHNICAL.md) for details, assumptions and limitations.

## Known limitations

- Expect a small client-prediction snap on delayed, emulated and rewritten jumps.
- On a backward rewrite, takeoff timing and position are unchanged. Only the velocity is replaced.
- Emulated takeoffs play no jump sound.
- Left untouched: duck transitions, water, ladders, moving or sinking ground, conveyors, FOG >= 4, and ledge drops.

## Verifying against the engine

`tools/fog_reference.py` is a Python reference of the same physics plus a log checker:

```
python tools/fog_reference.py sanity
python tools/fog_reference.py sweep
python tools/fog_reference.py check <Half-Life>\cstrike\addons\amxmodx\logs\fog_debug.log
```

`check` replays every logged frame and compares it with the engine's real post-move velocity. Delayed, emulated and natural jump frames match to within 0.001 u/s.

## Credits

- Physics references (read-only): [ReGameDLL_CS](https://github.com/s1lentq/ReGameDLL_CS) and [ReHLDS](https://github.com/dreamstalker/rehlds).
- The speed_hud layout follows the speed panel of [gcljs](https://bitbucket.org/GameChaos/gcljs) by GameChaos. No gcljs code is used; the jump detection is new.
