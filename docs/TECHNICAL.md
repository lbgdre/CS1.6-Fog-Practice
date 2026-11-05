# FOG Practice (fog_practice.amxx)

Scroll-wheel bhop practice aid for CS 1.6 on a **local listen server**. When you press jump on
ground frame 1, 2 or 3 after landing, the plugin gives you the best horizontal takeoff speed
of FOG 1, 2 or 3, which removes the luck of where the scroll notch lands.
Practice only. It changes movement physics. Never run it on a public server.

## Files

| File | Purpose |
|---|---|
| `cstrike\addons\amxmodx\scripting\fog_practice.sma` | source (comments cite the engine and PM functions it relies on) |
| `cstrike\addons\amxmodx\plugins\fog_practice.amxx` | compiled with amxxpc 1.10.0.5467, 0 warnings |
| `cstrike\addons\amxmodx\configs\plugins.ini` | `fog_practice.amxx` appended as the **last** line (backup: `plugins.ini.bak`) |
| `cstrike\addons\amxmodx\logs\fog_debug.log` | created when `fog_debug` >= 1 |
| `tools/fog_reference.py` | Python reference math + log checker (outside the game folder) |
| `cstrike\UNINSTALL.txt` | how to remove all of the above |

Environment found: the existing KZ pack already had Metamod 1.21-am and AMX Mod X 1.10.0.5467
installed, with `liblist.gam` already pointing at Metamod. Nothing was reinstalled, and
`liblist.gam` was not touched. Only stock modules are used (`fakemeta`). There is no ReHLDS,
ReGameDLL, ReAPI or Orpheu dependency.

## Companion: speed_hud.amxx (standalone speedometer)

Jumpstats and KZ speed panels detect a jump from the button press in PlayerPreThink and report
the previous frame's velocity. With fog_practice, the press frame is often not the takeoff frame,
so their prespeed and FOG are wrong. `speed_hud.amxx` (source `speed_hud.sma`) is independent of
any other plugin. It reads the result of each usercmd in FM_CmdEnd: a takeoff is a usercmd that
started on ground and ended airborne with vz > 0. It uses gcljs's layout (centered DHUD, y 0.7):
current speed, then `(takeoff speed)` and `FOG: n` while airborne. Spectators watching you see it too.

- Takeoff speed is the horizontal speed after the takeoff frame (cap and that frame's air accel included). It is the speed you actually leave with.
- The takeoff frame is the usercmds on ground, takeoff frame included, counted the same way as fog_practice.
- **FOG shown:** with fog_practice loaded and `speed_hud_fog_mode 1` (default), this is the frame whose speed you got.
  - It's queried from fog_practice's `fog_api_src` via `callfunc`, so there's no hard dependency.
  - After a backward rewrite it reads `FOG: 2 (f3)`: FOG 2's speed, but you left the ground on frame 3.
  - `speed_hud_fog_mode 0` shows the takeoff frame only. That is also what you get without fog_practice.
- **D: n** (duck) is shown on a bhop takeoff, under FOG. It is the length of your last continuous duck in the air before the landing this jump came from.
  - It counts usercmds with IN_DUCK held. The landing usercmd counts, because it starts in the air.
  - 0 means you didn't duck in the air before that landing.
  - `speed_hud_duck 0` hides it.
- `speed_hud_debug 1` logs `SPDJ` lines to `fog_debug.log`. `fog_reference.py check` then compares each one with fog_practice's `FOGJ` for the same takeoff.
- Cvars:
  - `speed_hud_enable` (1)
  - `speed_hud_x` (-1.0) and `speed_hud_y` (0.7)
  - `speed_hud_color` ("255 255 255")
  - `speed_hud_fog_max` (8): hide FOG above this
  - `speed_hud_keep` (0): 1 keeps the takeoff line after landing
  - `speed_hud_hold` (0.02, big-font hold time; redraws every usercmd), `speed_hud_style` (0 big font, default; 1 normal HUD font: every usercmd, never overlaps)
- Toggle: `say /speedhud` or the console command `speedhud`.
- Turn off the KZ plugin's own speed display in its menu so the two don't overlap.

## Cvars / commands

| Name | Default | Meaning |
|---|---|---|
| `fog_enable` | 1 | master switch |
| `fog_max` | 3 | highest FOG considered, clamped to 1-3 (1 = plugin does nothing useful) |
| `fog_fix_vz` | 1 | on a backward rewrite, also use the earlier frame's jump vz (from that frame's fuser2) |
| `fog_debug` | 0 | 1 = one summary line per jump to console + full detail to the log; 2 = full detail to console too |
| `fog_dd` | 1 | double duck: give the speed of a DD pressed on the first possible frame |
| `fog_dd_max` | 3 | DD: best of the first N possible DD FOGs (1-5; 1 = no correction) |
| `say /fog` | | toggle the correction for yourself |
| `say /fogmenu` | | settings menu (saved to `configs/fog_practice.cfg`); speed_hud has `/speedmenu` (saved to `configs/speed_hud.cfg`) |

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

## What the source says (and why the design differs from "set_uc in CmdStart")

From `rehlds/engine/sv_user.cpp` `SV_RunCmd`, where the `#ifndef REHLDS_FIXES` path is the stock engine:

1. `usercmd_t cmd = *ucmd;` is copied **before** `pfnCmdStart`.
2. `pfnCmdStart`, then `v.button = ucmd->buttons`, then `SV_CheckMovingGround`, then `pfnPlayerPreThink`.
3. `SV_SetupPMove(..., &cmd, ...)`: movement uses **the copy**, so `set_uc()` changes to buttons
   made in FM_CmdStart never reach `PM_PlayerMove` on a stock engine. This step also copies
   `pev->oldbuttons`, velocity, origin, fuser2, flags, maxspeed, gravity and friction into pmove.
4. `PM_Move`, then `SV_FinishPMove` (note `v.oldbuttons = pmove->cmd.buttons`), then `PlayerPostThink`, then `pfnCmdEnd`.

Each of these runs once per usercmd. Commands longer than 50 ms are split in two, and each half
goes through all the steps. So the plugin snapshots the cmd in **FM_CmdStart**, decides and acts in
**FM_PlayerPreThink (post)** (the last hook before SV_SetupPMove), and reads the real result in
**FM_CmdEnd (post)**. The levers are pev fields:

- **Delay (strip):** `oldbuttons |= IN_JUMP`. PM_Jump returns at "don't pogo stick", so the frame is a normal ground frame.
- **Inject, when the cmd has IN_JUMP:** clear `IN_JUMP` from `oldbuttons`. A real PM_Jump runs.
- **Inject without IN_JUMP / backward rewrite:** preset velocity to (capped xy of the chosen frame,
  PM_Jump's vz). Because vz > 180, PM_CategorizePosition puts the player in the air, and the engine
  runs the rest of a jump frame itself: no friction, PM_AirMove with that frame's air accel and
  PM_FlyMove collision, then gravity. A real jump frame runs PM_FixupGravityVelocity twice (once
  inside PM_Jump, once at the end of PM_PlayerMove). Here, the frame's PM_AddCorrectGravity takes
  the place of the first one, so vz matches a real jump at every step. The plugin writes
  `fuser2 = 1315.789429` in CmdEnd.

Ground state: `FL_ONGROUND` at PreThink is the result of the previous PM_CategorizePosition. The
plugin also requires vz <= 180 (PM re-categorizes at the start) and `MOVETYPE_WALK`.

Candidates (per evaluated cmd on ground frame c):
- FOG m <= c: exact. Uses the recorded pre-move velocity of frame m, then PM_AddCorrectGravity (vz = -g/2*dt) and PM_PreventMegaBunnyJumping on 3D speed.
- FOG m > c: predicted. Simulates ground frames with this cmd's inputs repeated: PM_CheckParameters move clamp, punch decay and roll; PM_ReduceTimers; PM_Friction with the real edge hull trace; PM_WalkMove stamina; PM_Accelerate. Then applies the same cap.
- The best is chosen. Ties go to "now", so there's no needless intervention. A delayed jump is re-evaluated with real data on every following ground frame. If an earlier frame turns out better, it becomes a rewrite. Frame `fog_max` is the hard limit.

## Expected results (Python, 100 fps, maxspeed 250, sv_friction 4, flat, W held)

```
landing 299.97 -> FOG1 299.970 (no loss)       landing 310, press f1 -> FOG2 260.52 vs FOG1 239.98
landing 300-350 -> FOG2 wins                    landing 360-420 -> FOG3 wins
landing >= ~430 -> everything caps to ~240
```

Run `python tools/fog_reference.py sweep` for the full table, or `sanity` for the checks.

## In-game test procedure

1. Start CS. In the console: `fps_max 100` (then each usercmd is 10 ms).
2. Use **New Game / Create Server** on a bhop map. In the console, `amxx plugins` should list `FOG Practice ... running`.
3. In the console: `fog_debug 1`. On a listen server the host can set server cvars directly.
4. Scroll-jump a few bhops. Each jump prints a line in the console, for example:
   `[FOG] press f1 -> FOG 2 (src 2) land 310.2 cand 240.0/260.6/232.0 delay -> xy 261.30 vz 227.40`
   - `press`: the ground frame where your jump press arrived
   - `FOG`: the frame you actually took off on
   - `src`: whose velocity you got (smaller than FOG means a rewrite)
   - `cand`: FOG1/2/3 takeoff xy candidates
   - `mode`: now / delay / delay(emul) / rewrite(n) / untouched
   - `xy` and `vz`: velocity after the takeoff frame (includes that frame's air accel and gravity)

   `FOGW` lines are warnings. A "strip failed" or "expected a natural PM_Jump" warning means an engine assumption above is wrong. Paste those.
5. Full detail is in `cstrike\addons\amxmodx\logs\fog_debug.log`:
   - `FOGC`: movevars
   - `FOGF`: every ground frame, with inputs, edge flag, pre/preset/post velocity and fuser2
   - `FOGE`: each evaluation
   - `FOGJ`: the per-jump summary
6. Check it against the reference:
   `python tools/fog_reference.py check "<Half-Life>\cstrike\addons\amxmodx\logs\fog_debug.log"`
   The checker replays every logged frame with the Python formulas and compares the result to the engine's real post-move velocity:
   - ground: plain ground frames
   - strip: delayed frames
   - jump: natural takeoffs
   - emul: emulated takeoffs and rewrites
   - cont: whether each frame's pre-move velocity matches the previous frame's post-move velocity
   - cand: the plugin's exact candidates
   - pred: how far the predictions were from what later happened

   Errors above `--tol` (default 0.05) are listed. A single outlier usually means a wall or step collision, which is not modelled.
7. Toggle with `say /fog` to compare against raw scroll luck.

## Assumptions

- The Steam engine (closed source) orders SV_RunCmd and copies pev to and from pmove the way ReHLDS's non-REHLDS_FIXES path does. The `FOGW` warnings detect it if not.
- Stock `mp.dll` movement equals ReGameDLL's default build (`REGAMEDLL_ADD` / `REGAMEDLL_FIXES` code is ignored).
- Standing hull only. Players and other non-BSP entities are ignored by the edge-friction trace (`IGNORE_MONSTERS`), while the PM trace includes players. This only matters if another player stands at your edge.
- `fog_practice.amxx` is last in plugins.ini, so its PreThink-post hook runs after other AMXX plugins'. A plugin that changes velocity or oldbuttons elsewhere, such as an Orpheu PM_Move hook in the KZ pack, can still interfere. If results look wrong, disable the other movement plugins and retest.

## Limitations

- **Client-prediction stutter.** The client predicts with its own cmd.
  - On a delayed jump, the client predicted a takeoff that the server cancelled.
  - On an emulated takeoff or rewrite, the client predicted something else.

  The client is corrected on the next update, which is a small visible snap.
- **Backward rewrite (FOG < press frame):** takeoff **timing and position are unchanged**. You still
  leave the ground on the frame you pressed, from where you are. Only the velocity is replaced by
  the earlier frame's capped xy (and, with `fog_fix_vz 1`, the earlier frame's jump vz, which is
  slightly lower because stamina was higher then). The jump frame's own air accel and displacement
  use the replaced velocity.
- Emulated takeoffs play no jump step sound. A stripped frame may still play the third-person jump
  animation, because the game DLL saw IN_JUMP in `pev->button`.
- Future-frame prediction assumes the current inputs repeat, flat ground and no collisions. It is
  used only to decide whether to delay, and the next frame is re-decided with real data.
- Ducking. PM_Duck runs before PM_Jump and PM_Friction, and scales the moves by 0.333 whenever you are ducked or unducking.
  - **Handled:** landing ducked and releasing duck (the frame unducks: x0.333, origin +18, standing hull, jump allowed), and staying fully ducked with duck held (x0.333, duck hull).
  - The plugin never emulates a takeoff on an unducking frame. Presetting airborne velocity there would skip PM_UnDuck's +18 raise.
  - **Untouched:** a duck in transition (bInDuck), pressing duck while standing, and an unduck with no room.
- Also not handled (passed through untouched): water, waterjump, ladders, noclip, conveyors and
  moving ground (including sinking bhop blocks), nonzero basevelocity, frozen or on-train players,
  dead players, observers, bots. Also FOG >= 4 jumps and ledge drops.
  - A skipped press shows as `mode=untouched(<reason>)` in `FOGJ`.
  - Every `FOGF` line carries `ds=` (0 stand, 1 unduck, 2 ducked), `dm=` (move multiplier) and `why=`.
- A usercmd with msec 0 is not counted as a ground frame. A press on one is deferred to the next real frame.
- A delayed jump is cancelled, so you get no jump, if you leave the ground, become ineligible, or `/fog` off mid-delay.
