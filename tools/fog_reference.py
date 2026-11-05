#!/usr/bin/env python3
"""
fog_reference.py - reference implementation of the CS 1.6 ground/jump-frame math used by
fog_practice.amxx, plus a checker for the plugin's debug log.

Formulas mirror ReGameDLL_CS regamedll/pm_shared/pm_shared.cpp (default build == stock mp.dll):
  PM_CheckParameters, PM_DropPunchAngle, PM_CalcRoll, AngleVectors, PM_ReduceTimers,
  PM_AddCorrectGravity, PM_FixupGravityVelocity, PM_Jump, PM_PreventMegaBunnyJumping,
  PM_Friction, PM_WalkMove, PM_Accelerate, PM_AirMove, PM_AirAccelerate.
Collisions (PM_FlyMove / PM_WalkMove traces) are NOT modelled: flat open ground is assumed.

Usage:
  python fog_reference.py sanity
  python fog_reference.py sweep
  python fog_reference.py check <path to addons/amxmodx/logs/fog_debug.log> [--tol 0.05] [-v]
"""
import argparse
import math
import re
import struct
import sys
from dataclasses import dataclass

JUMP_SPEED = math.sqrt(2.0 * 800.0 * 45.0)   # PM_JumpHeight(false)
STAMINA_ON_JUMP = 1315.789429                # PM_Jump
CAP_FACTOR = 1.2                             # BUNNYJUMP_MAX_SPEED_FACTOR
CAP_FRACTION = 0.8                           # PM_PreventMegaBunnyJumping
USE_F32 = True                               # round stores to float32 like the C code


def F(x):
    """Round to IEEE float32 (C 'float' store)."""
    if not USE_F32:
        return x
    return struct.unpack("f", struct.pack("f", x))[0]


def V(v):
    return [F(v[0]), F(v[1]), F(v[2])]


@dataclass
class Movevars:
    friction: float = 4.0
    stopspeed: float = 75.0
    edgefriction: float = 2.0
    accelerate: float = 5.0
    airaccelerate: float = 10.0
    gravity: float = 800.0
    maxspeed: float = 320.0      # sv_maxspeed
    rollangle: float = 0.0
    rollspeed: float = 0.0


@dataclass
class Inputs:
    msec: int = 10
    fm: float = 0.0
    sm: float = 0.0
    um: float = 0.0
    ang: tuple = (0.0, 0.0, 0.0)   # cmd.viewangles
    pun: tuple = (0.0, 0.0, 0.0)   # pev->punchangle
    maxspd: float = 250.0          # effective: min(sv_maxspeed, pev->maxspeed)
    entgrav: float = 1.0
    pfric: float = 1.0
    edge: bool = False
    dm: float = 1.0                # PM_Duck move multiplier (0.333 when ducked / unducking)


# ---------------------------------------------------------------- pure math (same as the .sma)

def reduce_fuser2(fu, msec):                       # PM_ReduceTimers
    if fu > 0.0:
        fu = fu - msec
        if fu < 0.0:
            fu = 0.0
    return F(fu)


def stamina(fu):                                   # PM_WalkMove / PM_Jump
    return (100.0 - fu * 0.001 * 19.0) * 0.01 if fu > 0.0 else 1.0


def jump_vz(fu_after_reduce):                      # PM_Jump (before its PM_FixupGravityVelocity)
    return F(JUMP_SPEED * stamina(fu_after_reduce))


def cap(v, maxspd):                                # PM_PreventMegaBunnyJumping
    maxscaled = CAP_FACTOR * maxspd
    if maxscaled <= 0.0:
        return list(v)
    spd = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    if spd <= maxscaled:
        return list(v)
    fr = F((maxscaled / spd) * CAP_FRACTION)
    return V([v[0] * fr, v[1] * fr, v[2] * fr])


def takeoff(vpre, msec, entgrav, maxspd, mv):
    """Velocity handed to PM_AirMove on a jump frame: AddCorrectGravity then the cap."""
    dt = msec * 0.001
    v = [vpre[0], vpre[1], F(vpre[2] - entgrav * mv.gravity * 0.5 * dt)]
    v = cap(v, maxspd)
    return v, math.hypot(v[0], v[1])


def friction(v, dt, edge, pfric, mv):              # PM_Friction (ground branch), v[2] == 0
    speed = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    if speed < 0.1:
        return list(v)
    fr = mv.friction * (mv.edgefriction if edge else 1.0) * pfric
    control = mv.stopspeed if speed < mv.stopspeed else speed
    drop = fr * (control * dt)
    ns = max(speed - drop, 0.0) / speed
    return V([v[0] * ns, v[1] * ns, v[2] * ns])


def accelerate(v, wishdir, wishspeed, accel, dt, pfric):     # PM_Accelerate
    cur = v[0] * wishdir[0] + v[1] * wishdir[1] + v[2] * wishdir[2]
    add = wishspeed - cur
    if add <= 0:
        return list(v)
    a = min(accel * dt * wishspeed * pfric, add)
    return V([v[i] + a * wishdir[i] for i in range(3)])


def air_accelerate(v, wishdir, wishspeed, accel, dt, pfric):  # PM_AirAccelerate
    wishspd = min(wishspeed, 30.0)
    cur = v[0] * wishdir[0] + v[1] * wishdir[1] + v[2] * wishdir[2]
    add = wishspd - cur
    if add <= 0:
        return list(v)
    a = min(accel * wishspeed * dt * pfric, add)
    return V([v[i] + a * wishdir[i] for i in range(3)])


def angle_vectors(a):                              # mathlib AngleVectors
    p, y, r = (math.radians(a[0]), math.radians(a[1]), math.radians(a[2]))
    sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    fwd = [cp * cy, cp * sy, -sp]
    right = [(-1 * sr * sp * cy + -1 * cr * -sy), (-1 * sr * sp * sy + -1 * cr * cy), -1 * sr * cp]
    return fwd, right


def calc_roll(ang, vel, rollangle, rollspeed):     # PM_CalcRoll
    _, r = angle_vectors(ang)
    side = vel[0] * r[0] + vel[1] * r[1] + vel[2] * r[2]
    sign = -1.0 if side < 0 else 1.0
    side = abs(side)
    side = side * rollangle / rollspeed if side < rollspeed else rollangle
    return side * sign


def drop_punch(p, dt):                             # PM_DropPunchAngle
    ln = math.sqrt(p[0] ** 2 + p[1] ** 2 + p[2] ** 2)
    n = [c / ln for c in p] if ln != 0 else [0.0, 0.0, 0.0]
    ln = max(ln - (10.0 + ln * 0.5) * dt, 0.0)
    return [c * ln for c in n]


def normalize(v):
    ln = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    return ([c / ln for c in v], ln) if ln != 0 else (list(v), 0.0)


def wish(inp, vel, mv):
    """PM_CheckParameters (+ angles) and the wishdir part of PM_WalkMove / PM_AirMove."""
    dt = inp.msec * 0.001
    fm, sm, um = inp.fm, inp.sm, inp.um
    spd = math.sqrt(sm * sm + fm * fm + um * um)
    if spd != 0 and spd > inp.maxspd:
        r = inp.maxspd / spd
        fm, sm = fm * r, sm * r
    fm, sm = fm * inp.dm, sm * inp.dm             # PM_Duck (runs after PM_CheckParameters)
    pun = drop_punch(list(inp.pun), dt)
    va = [inp.ang[i] + pun[i] for i in range(3)]
    pm = [va[0], va[1], calc_roll(va, vel, mv.rollangle, mv.rollspeed) * 4.0]
    f, r = angle_vectors(pm)
    f, _ = normalize([f[0], f[1], 0.0])
    r, _ = normalize([r[0], r[1], 0.0])
    wv = [f[0] * fm + r[0] * sm, f[1] * fm + r[1] * sm, 0.0]
    wishdir, wishspeed = normalize(wv)
    return wishdir, min(wishspeed, inp.maxspd), pun


# ---------------------------------------------------------------- whole frames

def ground_frame(vpre, fu_pre, inp, mv):
    """One ground usercmd without a jump. Returns (v_post, fuser2_post)."""
    dt = inp.msec * 0.001
    wishdir, wishspeed, _ = wish(inp, vpre, mv)
    fu = reduce_fuser2(fu_pre, inp.msec)
    v = [vpre[0], vpre[1], 0.0]                     # gravity half, then velocity[2] = 0
    v = friction(v, dt, inp.edge, inp.pfric, mv)
    if fu > 0.0:                                    # PM_WalkMove stamina
        s = F(stamina(fu))
        v = V([v[0] * s, v[1] * s, v[2]])
    v[2] = 0.0
    v = accelerate(v, wishdir, wishspeed, mv.accelerate, dt, inp.pfric)
    v[2] = 0.0
    if math.sqrt(v[0] ** 2 + v[1] ** 2) < 1.0:
        v = [0.0, 0.0, 0.0]
    return v, fu                                    # ends on ground -> vz = 0


def jump_frame(vpre, fu_pre, inp, mv, fu_for_vz=None):
    """Natural PM_Jump frame. Returns (v_post, fuser2_post)."""
    dt = inp.msec * 0.001
    g = inp.entgrav * mv.gravity * 0.5 * dt
    wishdir, wishspeed, _ = wish(inp, vpre, mv)
    fu = reduce_fuser2(fu_pre, inp.msec)
    v = [vpre[0], vpre[1], F(vpre[2] - g)]          # PM_AddCorrectGravity
    v = cap(v, inp.maxspd)                          # PM_Jump -> PM_PreventMegaBunnyJumping
    v[2] = jump_vz(fu if fu_for_vz is None else fu_for_vz)
    v[2] = F(v[2] - g)                              # PM_FixupGravityVelocity inside PM_Jump
    v = air_accelerate(v, wishdir, wishspeed, mv.airaccelerate, dt, inp.pfric)   # PM_AirMove
    v[2] = F(v[2] - g)                              # PM_FixupGravityVelocity at end of PM_PlayerMove
    return v, STAMINA_ON_JUMP


def emulated_frame(vset, inp, mv):
    """Frame run by the engine after the plugin preset velocity = vset (vz > 180)."""
    dt = inp.msec * 0.001
    g = inp.entgrav * mv.gravity * 0.5 * dt
    wishdir, wishspeed, _ = wish(inp, vset, mv)
    v = [vset[0], vset[1], F(vset[2] - g)]          # PM_AddCorrectGravity
    v = air_accelerate(v, wishdir, wishspeed, mv.airaccelerate, dt, inp.pfric)
    v[2] = F(v[2] - g)                              # end-of-frame fixup
    return v, STAMINA_ON_JUMP                       # plugin writes fuser2 in CmdEnd


def dd_lift_frame(vstart, fu_pre, inp, mv):
    """Double-duck lift frame: PM_Duck -> PM_UnDuck (+18 with bInDuck) makes the player airborne
    before movement, so: no friction, PM_AirMove with the duck-scaled moves (inp.dm = 0.333),
    gravity halves before and after. fuser2 only decays (no PM_Jump)."""
    dt = inp.msec * 0.001
    g = inp.entgrav * mv.gravity * 0.5 * dt
    wishdir, wishspeed, _ = wish(inp, vstart, mv)
    fu = reduce_fuser2(fu_pre, inp.msec)
    v = [vstart[0], vstart[1], F(vstart[2] - g)]
    v = air_accelerate(v, wishdir, wishspeed, mv.airaccelerate, dt, inp.pfric)
    v[2] = F(v[2] - g)
    return v, fu


def dd_first_frame_speed(vpre_e, fu_e, inp_e, mv):
    """Speed at the lift if the duck had been pressed on frame e (the first possible frame):
    frame e run as a press frame (ground frame, moves x0.333)."""
    pinp = Inputs(**{**inp_e.__dict__, "dm": 0.333})
    v, _ = ground_frame(vpre_e, fu_e, pinp, mv)
    return v


def candidates(vpre1, fu1, inp, mv, fog_max=3):
    """From the state at ground frame 1, takeoff xy for FOG 1..fog_max (inputs repeated)."""
    out = []
    v, fu = list(vpre1), fu1
    for m in range(1, fog_max + 1):
        _, xy = takeoff(v, inp.msec, inp.entgrav, inp.maxspd, mv)
        out.append(xy)
        v, fu = ground_frame(v, fu, inp, mv)
    return out


def best_of(cands, current=1, eps=0.001):
    best, bv = current, cands[current - 1]
    for m, c in enumerate(cands, start=1):
        if m != current and c > bv + eps:
            best, bv = m, c
    return best


# ---------------------------------------------------------------- sanity / sweep

def fuser_at_landing(air_frames, msec=10):
    """fuser2 before ReduceTimers of ground frame 1, after a jump frame + air_frames air cmds."""
    fu = STAMINA_ON_JUMP
    for _ in range(air_frames):
        fu = reduce_fuser2(fu, msec)
    return fu


def scenario(name, land, fu_pre, inp, mv, expect=None):
    vpre = [land, 0.0, 0.0]
    c = candidates(vpre, fu_pre, inp, mv)
    b = best_of(c)
    fus = []
    fu = fu_pre
    for _ in range(3):
        fu = reduce_fuser2(fu, inp.msec)
        fus.append(f"{fu:.2f}")
    print(f"{name}\n  landing {land:.2f}  fuser2 after reduce f1/f2/f3: {'/'.join(fus)}")
    print("  candidates FOG1..3: " + "  ".join(f"{x:8.3f}" for x in c) + f"   -> best FOG {b}")
    if expect:
        ok = expect(c, b)
        print("  check:", "PASS" if ok else "FAIL")
        return ok
    return True


def cmd_sanity(_args):
    mv = Movevars()
    # W held, looking along the velocity: no ground acceleration above 250 (addspeed < 0)
    inp = Inputs(msec=10, fm=400.0, sm=0.0, ang=(0.0, 0.0, 0.0), maxspd=250.0)
    ok = True
    fu66 = fuser_at_landing(65)     # jump frame + 65 air cmds = 66-frame jump; f1 reduces once more
    print(f"fuser2 at landing after a 66-frame jump (before f1 reduce): {fu66:.4f}\n")

    ok &= scenario("A) landing 299.97 (3D with vz=-4 is just under 300)", 299.97, fu66, inp, mv,
                   lambda c, b: b == 1 and abs(c[0] - 299.97) < 1e-3)
    ok &= scenario("A2) landing 299.98 (just over the cap)", 299.98, fu66, inp, mv,
                   lambda c, b: c[0] < 241)
    ok &= scenario("B) landing 310, 66-frame jump, pressed on f1", 310.0, fu66, inp, mv,
                   lambda c, b: b == 2 and 259.0 < c[1] < 263.0 and 239.0 < c[0] < 241.0)
    ok &= scenario("C) landing 420", 420.0, fu66, inp, mv,
                   lambda c, b: b == 3)
    # strafing on the ground (sidemove only, wishdir perpendicular to v): tiny accel gain
    inp_s = Inputs(msec=10, fm=0.0, sm=250.0, ang=(0.0, 0.0, 0.0), maxspd=250.0)
    ok &= scenario("D) landing 310, strafing (sidemove 250)", 310.0, fu66, inp_s, mv,
                   lambda c, b: b == 2)

    # vz bookkeeping for a real jump frame at 100 fps with fuser2 = 0
    v, _ = jump_frame([280.0, 0.0, 0.0], 0.0, Inputs(msec=10), mv)
    print(f"\nE) natural jump, fuser2 0: vz_post = {v[2]:.4f} (expected {JUMP_SPEED - 8:.4f})")
    ok &= abs(v[2] - (JUMP_SPEED - 8.0)) < 1e-3
    e, _ = emulated_frame([280.0, 0.0, jump_vz(0.0)], Inputs(msec=10), mv)
    print(f"   emulated takeoff preset vz = {jump_vz(0.0):.4f}: vz_post = {e[2]:.4f} (must equal natural)")
    ok &= abs(e[2] - v[2]) < 1e-3
    print("\nALL SANITY CHECKS", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_sweep(_args):
    mv = Movevars()
    inp = Inputs(msec=10, fm=400.0, ang=(0.0, 0.0, 0.0), maxspd=250.0)
    fu = fuser_at_landing(65)
    print(" landing    FOG1     FOG2     FOG3   best")
    s = 240.0
    while s <= 520.0:
        c = candidates([s, 0.0, 0.0], fu, inp, mv)
        print(f"{s:8.2f} {c[0]:8.3f} {c[1]:8.3f} {c[2]:8.3f}   {best_of(c)}")
        s += 10.0
    return 0


# ---------------------------------------------------------------- log checker

KV = re.compile(r"(\w+)=(\S+)")


def parse(line):
    d = {}
    for k, val in KV.findall(line):
        if "," in val:
            try:
                d[k] = [float(x) for x in val.split(",")]
                continue
            except ValueError:
                pass
        try:
            d[k] = float(val) if any(ch in val for ch in ".e") else int(val)
        except ValueError:
            d[k] = val
    return d


def inputs_from(fr):
    return Inputs(msec=int(fr["ms"]), fm=fr["fm"], sm=fr["sm"], um=fr["um"], ang=tuple(fr["ang"]),
                  pun=tuple(fr["pun"]), maxspd=fr["mxs"], entgrav=fr["g"], pfric=fr["pf"],
                  edge=bool(fr["edge"]), dm=fr.get("dm", 1.0))


def cmd_check(args):
    mv = Movevars()
    stats = {"ground": [], "strip": [], "jump": [], "emul": [], "dd": [], "ddcorr": [], "cont": [], "cand": [], "pred": []}
    bad = []
    seq = {}            # id -> {"frames": {f: rec}, "evals": [..]}
    hud, fogj = {}, {}  # speed_hud SPDJ lines / fog_practice FOGJ lines, per player
    njumps = 0
    with open(args.log, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            if "FOGC " in raw:
                d = parse(raw.split("FOGC ", 1)[1])
                mv = Movevars(d["friction"], d["stopspeed"], d["edgefriction"], d["accelerate"],
                              d["airaccelerate"], d["gravity"], d["maxspeed"], d["rollangle"], d["rollspeed"])
            elif "FOGE " in raw:
                d = parse(raw.split("FOGE ", 1)[1])
                s = seq.setdefault(d["id"], {"frames": {}, "evals": []})
                if d["f"] == 1:
                    s["frames"], s["evals"] = {}, []
                s["evals"].append(d)
            elif "FOGF " in raw:
                d = parse(raw.split("FOGF ", 1)[1])
                s = seq.setdefault(d["id"], {"frames": {}, "evals": []})
                if d["f"] == 1 and s["frames"]:
                    s["frames"], s["evals"] = {}, [e for e in s["evals"] if e["f"] == 1]
                s["frames"][d["f"]] = d
                check_frame(d, mv, stats, bad, args)
                prev = s["frames"].get(d["f"] - 1)
                if prev:   # continuity: next frame's pre-move velocity == previous post-move
                    err = max(abs(prev["vpost"][i] - d["vpre"][i]) for i in range(3))
                    stats["cont"].append(err)
                    if err > args.tol:
                        bad.append(f"continuity id={d['id']} f{d['f'] - 1}->f{d['f']}: vpost {prev['vpost']} vs vpre {d['vpre']} "
                                   f"(something between CmdEnd and the next PM changed velocity)")
            elif "FOGJ " in raw:
                d = parse(raw.split("FOGJ ", 1)[1])
                njumps += 1
                s = seq.get(d["id"])
                if s:
                    check_candidates(s, mv, stats, bad, args)
                if args.verbose:
                    print(raw.rstrip())
                seq.pop(d["id"], None)
            elif "FOGD " in raw:
                d = parse(raw.split("FOGD ", 1)[1])
                s_ = seq.get(d["id"])
                fe = s_["frames"].get(d["first"]) if s_ else None
                if d.get("applied") == 1 and fe:
                    v = dd_first_frame_speed(fe["vpre"], fe["fu"], inputs_from(fe), mv)
                    err = abs(math.hypot(v[0], v[1]) - d["corr"])
                    stats["ddcorr"].append(err)
                    if err > args.tol:
                        bad.append(f"id={d['id']} DD lift f{d['lift']}: plugin first-frame speed {d['corr']:.3f} python {math.hypot(v[0], v[1]):.3f}")
                if args.verbose:
                    print(raw.rstrip())
            elif "SPDJ " in raw:
                d = parse(raw.split("SPDJ ", 1)[1])
                hud.setdefault(d["id"], []).append(d)
            elif "FOGW " in raw and args.verbose:
                print("WARN:", raw.rstrip())
            if "FOGJ " in raw:
                fogj.setdefault(parse(raw.split("FOGJ ", 1)[1])["id"], []).append(parse(raw.split("FOGJ ", 1)[1]))

    print(f"jumps logged: {njumps}")
    for pid, hs in hud.items():
        # pair each HUD takeoff with fog_practice's summary of the same takeoff (same xy and vz)
        js = fogj.get(pid, [])
        ok = 0
        for h in hs:
            m = [j for j in js if abs(j["xy"] - h["xy"]) < 0.01 and abs(j["vz"] - h["vz"]) < 0.01]
            if not m:
                continue          # takeoff fog_practice did not log (e.g. fog_debug was 0)
            j = m[-1]
            if h["fog"] == j["fog"] and (h["src"] in (0, j["src"])):
                ok += 1
            else:
                bad.append(f"speed_hud id={pid} xy={h['xy']}: HUD fog={h['fog']} src={h['src']} | "
                           f"fog_practice fog={j['fog']} src={j['src']}")
        print(f"  speed_hud takeoffs n={len(hs)}  matching fog_practice FOG/src: {ok}")
    for k in ("ground", "strip", "jump", "emul", "dd", "ddcorr", "cont", "cand", "pred"):
        xs = stats[k]
        if xs:
            print(f"  {k:7s} n={len(xs):5d}  max|err|={max(xs):.5f}  mean={sum(xs) / len(xs):.5f}")
    label = {"ground": "ground frame vs engine", "strip": "stripped frame vs engine",
             "jump": "natural jump frame vs engine", "emul": "emulated takeoff vs engine",
             "dd": "double-duck lift frame vs engine", "ddcorr": "plugin DD first-frame speed vs python",
             "cont": "post->next pre continuity", "cand": "plugin candidates vs python (exact frames)",
             "pred": "plugin prediction vs what later happened"}
    print("  (" + "; ".join(f"{k}: {v}" for k, v in label.items()) + ")")
    if bad:
        print(f"\n{len(bad)} item(s) above tol {args.tol}:")
        for b in bad[:60]:
            print("  " + b)
        if len(bad) > 60:
            print(f"  ... {len(bad) - 60} more")
    else:
        print(f"\nall compared values within tol {args.tol}")
    return 0 if not bad else 2


def check_frame(fr, mv, stats, bad, args):
    inp = inputs_from(fr)
    act = fr["act"]
    if act in ("ground", "strip"):
        exp, fu = ground_frame(fr["vpre"], fr["fu"], inp, mv)
        key = act
    elif act == "jump":
        exp, fu = jump_frame(fr["vpre"], fr["fu"], inp, mv)
        key = "jump"
    elif act == "emul":
        exp, fu = emulated_frame(fr["vset"], inp, mv)
        key = "emul"
    elif act == "dd":
        start = fr["vset"] if any(abs(x) > 0 for x in fr["vset"]) else fr["vpre"]
        exp, fu = dd_lift_frame(start, fr["fu"], inp, mv)
        key = "dd"
    else:
        return
    if act in ("ground", "strip") and fr.get("air", 0):
        bad.append(f"id={fr['id']} f{fr['f']} act={act} but the player left the ground")
        return
    got = fr["vpost"]
    err = max(abs(exp[i] - got[i]) for i in range(3))
    stats[key].append(err)
    if err > args.tol or abs(fu - fr["fupost"]) > 0.01:
        bad.append(f"id={fr['id']} f{fr['f']} {act}: python {[round(x, 4) for x in exp]} fu {fu:.3f} | "
                   f"engine {got} fu {fr['fupost']:.3f}  (err {err:.4f}; >tol usually = wall/step collision)")


def check_candidates(s, mv, stats, bad, args):
    frames = s["frames"]
    prev_pred = {}
    for ev in s["evals"]:
        c = ev["f"]
        cand = ev["cand"]
        for m in range(1, c + 1):
            fr = frames.get(m)
            if not fr or m > len(cand) or cand[m - 1] == 0.0:
                continue
            _, xy = takeoff(fr["vpre"], int(fr["ms"]), fr["g"], fr["mxs"], mv)
            err = abs(xy - cand[m - 1])
            stats["cand"].append(err)
            if err > args.tol:
                bad.append(f"id={ev['id']} eval f{c}: candidate FOG{m} plugin {cand[m - 1]:.3f} python {xy:.3f}")
            if m in prev_pred:
                stats["pred"].append(abs(prev_pred[m] - xy))
        prev_pred = {m: cand[m - 1] for m in range(c + 1, len(cand) + 1) if cand[m - 1] != 0.0}


def main():
    global USE_F32
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-f32", action="store_true", help="use double precision everywhere")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sanity")
    sub.add_parser("sweep")
    p = sub.add_parser("check")
    p.add_argument("log")
    p.add_argument("--tol", type=float, default=0.05)
    p.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    USE_F32 = not args.no_f32
    return {"sanity": cmd_sanity, "sweep": cmd_sweep, "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
