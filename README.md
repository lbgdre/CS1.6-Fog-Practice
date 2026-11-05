# CS 1.6 FOG Practice + Speed HUD (AMX Mod X)

Two AMX Mod X plugins for **Counter-Strike 1.6** bhop practice on a local listen server:

- **fog_practice**: every scroll-wheel bhop and double duck gets the speed of the best FOG (frames on ground), so you can practice your strafes without FOG luck.
- **speed_hud**: a speedometer showing your speed, takeoff speed, FOG and air-duck frames.

> [!WARNING]
> **fog_practice is NOT legit for records.**
> It changes movement physics. Any run, time, jumpstat or demo made with it enabled is **not legit**.
> **Disable it before any record attempt** with `/fog`, or remove `fog_practice.amxx` from `plugins.ini`.
> Use it for practice only, and never on a public or competitive server.

## Requirements

- Counter-Strike 1.6 (Steam), played on a **listen server** (New Game / Create Server).
- Metamod + AMX Mod X 1.10.

## Install

1. Copy the `addons` folder from this repo into `Half-Life\cstrike\`.
2. Add these lines to the end of `cstrike\addons\amxmodx\configs\plugins.ini`:
   ```
   fog_practice.amxx
   speed_hud.amxx
   ```
3. Start a listen server. `amxx plugins` in the console should list both.

## Chat commands

| Command | |
|---|---|
| `/fog` | turn FOG Practice on/off for yourself |
| `/fogmenu` | FOG Practice settings |
| `/speedhud` | turn the speed HUD on/off for yourself |
| `/speedmenu` | speed HUD settings |

`fogmenu` and `speedmenu` also work as console commands, so you can bind them to keys.

## /fogmenu

| Item | What it does |
|---|---|
| Plugin for me | on/off for you |
| Plugin for everyone | on/off for the whole server |
| Jump: best of FOG 1 to | 1-3: a bhop gets the best speed of FOG 1 up to this |
| DD gets first frame | on/off: a late double duck gets the speed of a DD on the first possible frame |
| DD: best of first frames | 1-5: how late a DD can be and still be corrected |
| Rewrite uses earlier jump height | on/off: a corrected jump also uses that frame's jump height |
| Debug output | on/off: prints each jump to the console and writes `addons/amxmodx/logs/fog_debug.log` |

## /speedmenu

| Item | What it does |
|---|---|
| HUD | on/off |
| FOG shows | the frame your speed came from, or the frame you left the ground on |
| Duck in air | show the `D:` line |
| Color | white, green, yellow, cyan, orange, red, pink |
| Height | 0.55 to 0.85 |
| Horizontal | center, left, right |
| Show FOG up to | 3, 5, 8, 10 |
| Debug log | on/off |

Settings you change in the menus are saved and loaded on every map start. To reset, delete `addons/amxmodx/configs/fog_practice.cfg` and `speed_hud.cfg`.

## Reading the speed HUD

```
312             current speed
(291.97)        takeoff speed of this jump
FOG: 2          frames on ground before the takeoff
D: 6            frames you held duck in the air before landing
```

- `FOG: 2 (f3)`: FOG Practice gave you FOG 2's speed, but you left the ground on frame 3.
- `DD FOG: 2`: the takeoff was a double duck. The best possible is 2, or 3 after landing ducked.

## Optional: check the plugin against the engine

With **Debug output** on, play a bit, then run:

```
python tools/fog_reference.py check <Half-Life>\cstrike\addons\amxmodx\logs\fog_debug.log
```

Technical details are in [docs/TECHNICAL.md](docs/TECHNICAL.md).

## Credits

* The speed HUD layout follows the speed panel of [gcljs](https://bitbucket.org/GameChaos/gcljs) by GameChaos.
