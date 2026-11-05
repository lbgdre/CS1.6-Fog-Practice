/*
 * fog_practice.sma - "best of FOG 1/2/3" for scroll-wheel bhop PRACTICE.
 *
 * !!! NOT LEGIT FOR RECORDS !!!
 * This plugin changes movement physics: it delays jumps and replaces takeoff velocity so every
 * bhop gets the best FOG. Runs, times, jumpstats or demos made with it enabled are NOT legit.
 * Disable it (say /fog, fog_enable 0, or remove it from plugins.ini) before any record attempt.
 * Purpose: practice and test your strafes as if every bhop had optimal FOG, without the
 * scroll-wheel randomness, on a local listen server.
 *
 * Target: Counter-Strike 1.6, stock Steam engine (listen server), Metamod + AMX Mod X 1.10,
 * stock modules only (fakemeta). No ReHLDS / ReGameDLL / ReAPI / Orpheu.
 *
 * FOG = number of usercmds processed with the player on the ground, landing -> takeoff.
 * FOG n = (n-1) full ground frames + 1 jump frame.
 *
 * ---------------------------------------------------------------------------------------------
 * SOURCE REFERENCES (read-only, cited by function name)
 *   [PM]  ReGameDLL_CS  regamedll/pm_shared/pm_shared.cpp   (default build == stock mp.dll logic)
 *   [SV]  ReHLDS        rehlds/engine/sv_user.cpp            (the #ifndef REHLDS_FIXES path == stock)
 *   [TR]  ReHLDS        rehlds/engine/pmovetst.cpp
 *   [GD]  ReGameDLL_CS  regamedll/dlls/player.cpp
 *
 * WHAT THE ENGINE ACTUALLY DOES PER USERCMD ([SV] SV_RunCmd), in order:
 *   1. usercmd_t cmd = *ucmd;                 <- local copy taken BEFORE the game sees the cmd
 *   2. if (cmd.msec > 50) run two halves recursively (each half goes through all steps below)
 *   3. gEntityInterface.pfnCmdStart(...)      -> FM_CmdStart
 *   4. sv_player->v.button = ucmd->buttons; SV_CheckMovingGround(); v_angle = viewangles
 *   5. SV_PlayerRunPreThink -> pfnPlayerPreThink -> FM_PlayerPreThink (post = after CS PreThink)
 *   6. SV_SetupPMove(pmove, ..., pmcmd = &cmd (stock path), frametime)
 *        copies FROM pev: oldbuttons, velocity, origin, fuser2, flags, maxspeed(clientmaxspeed),
 *        punchangle, gravity, friction, teleport_time(waterjumptime), basevelocity, ...
 *        and pmove->cmd = the step-1 COPY (only REHLDS_FIXES uses ucmd here).
 *   7. pfnPM_Move -> PM_Move -> PM_PlayerMove
 *   8. SV_FinishPMove: copies back to pev; NOTE  ent->v.oldbuttons = ppmove->cmd.buttons;
 *   9. pfnPlayerPostThink, then pfnCmdEnd       -> FM_CmdEnd
 *
 *   CONSEQUENCE: on a stock engine set_uc() in FM_CmdStart does NOT change what PM_PlayerMove
 *   sees (it only changes pev->button for the game DLL). So this plugin never uses set_uc.
 *   Instead it uses pev fields in FM_PlayerPreThink post (step 5), which SV_SetupPMove reads:
 *     - STRIP  a jump : pev->oldbuttons |= IN_JUMP. [PM] PM_Jump returns at "don't pogo stick"
 *                       (oldbuttons & IN_JUMP), the frame stays an ordinary ground frame.
 *     - ALLOW  a jump : pev->oldbuttons &= ~IN_JUMP when the cmd itself carries IN_JUMP.
 *     - EMULATE a takeoff (cmd has no IN_JUMP, or backward rewrite): preset pev->velocity to
 *                       (capped xy, vz) with vz > 180 so [PM] PM_CategorizePosition sets
 *                       onground = -1 at the start of PM_PlayerMove. The engine then runs exactly
 *                       the remainder of a jump frame: no PM_Friction, PM_AirMove (air accel +
 *                       PM_FlyMove collision), PM_CategorizePosition, PM_FixupGravityVelocity.
 *                       vz is preset to the value PM_Jump would write; the frame's
 *                       PM_AddCorrectGravity then plays the part of the PM_FixupGravityVelocity
 *                       call inside PM_Jump (a real jump frame applies the fixup twice), so vz
 *                       during PM_FlyMove and at frame end match a real jump.
 *                       fuser2 = 1315.789429 is written in CmdEnd.
 *
 * ONE-PER-USERCMD GATING: FM_CmdStart arms a flag; FM_PlayerPreThink(post) consumes it; FM_CmdEnd
 * finishes. All three run once per (possibly chopped) usercmd inside SV_RunCmd.
 *
 * GROUND STATE: pev->flags & FL_ONGROUND at PreThink == pmove->onground at the end of the previous
 * PM_Move ([SV] SV_FinishPMove). PM_PlayerMove re-runs PM_CategorizePosition from the same origin,
 * which also forces airborne if velocity[2] > 180, so we require vz <= 180 too. movetype must be
 * MOVETYPE_WALK (ladders set MOVETYPE_FLY via PM_LadderMove, copied back by SV_FinishPMove).
 *
 * PHYSICS (all [PM]) for a ground frame at frametime dt = cmd.msec*0.001:
 *   PM_CheckParameters : clamp f/s/u moves to maxspeed=min(sv_maxspeed, pev->maxspeed); drop
 *                        punchangle; angles = viewangles+punch, roll = PM_CalcRoll*4
 *   PM_ReduceTimers    : fuser2 -= msec, floored at 0
 *   PM_AddCorrectGravity: vz -= gravity*entgrav*0.5*dt
 *   jump pressed (IN_JUMP && !(oldbuttons&IN_JUMP)) -> PM_Jump:
 *        onground=-1; PM_PreventMegaBunnyJumping (3D speed incl. vz=-g/2*dt > 1.2*maxspeed ->
 *        v *= 1.2*maxspeed/spd*0.8); vz = sqrt(2*800*45) * stamina(fuser2); fuser2=1315.789429;
 *        PM_FixupGravityVelocity; then PM_AirMove runs this same frame (friction skipped) and
 *        PM_PlayerMove applies PM_FixupGravityVelocity once more: vz_end = vzJump - g*dt.
 *   else: vz = 0; PM_Friction (edge friction via hull trace 16u ahead, 34u down from feet);
 *        PM_WalkMove: xy *= stamina(fuser2) if fuser2 > 0; PM_Accelerate(sv_accelerate).
 *   stamina(f) = (100 - f*0.001*19) * 0.01
 * ---------------------------------------------------------------------------------------------
 */

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>

#pragma semicolon 1

#define PLUGIN_NAME     "FOG Practice"
#define PLUGIN_VERSION  "1.0.0"
#define PLUGIN_AUTHOR   "local"

#define MAXP            33
#define MAX_FOG         3
#define MAX_DD_FOG      5       // fog_dd_max upper bound
#define REC             7       // ground frames 1..6 are recorded (index 0 unused)

// ---- constants from [PM] ----
#define STAMINA_ON_JUMP     1315.789429     // PM_Jump: pmove->fuser2 = 1315.789429
#define JUMP_SPEED          268.328157      // PM_JumpHeight(false): sqrt(2.0 * 800.0 * 45.0)
#define BHOP_CAP_FACTOR     1.2             // pm_shared.h BUNNYJUMP_MAX_SPEED_FACTOR
#define BHOP_CAP_FRACTION   0.8             // PM_PreventMegaBunnyJumping: (maxscaled/spd) * 0.8
#define AIRBORNE_VZ         180.0           // PM_CategorizePosition: velocity[2] > 180 -> onground = -1
#define EDGE_AHEAD          16.0            // PM_Friction: origin + vel/speed * 16
#define EDGE_DROP           34.0            // PM_Friction: stop[2] = start[2] - 34
#define PLAYER_MINS_Z       -36.0           // player_mins[0][2], standing hull (usehull 0)
#define PLAYER_MINS_Z_DUCK  -18.0           // player_mins[1][2], duck hull (usehull 1)
#define DUCK_MULT           0.333           // pm_shared.h PLAYER_DUCKING_MULTIPLIER (PM_Duck)
#define UNDUCK_RAISE        18.0            // PM_UnDuck (stock path): newOrigin[2] += 18 when on ground
#define CHOICE_EPS          0.001           // a candidate must beat the current best by this much

// Duck state of a ground frame, as PM_Duck will treat it (PM_Duck runs before PM_Jump/PM_Friction):
//   DS_STAND : no IN_DUCK, !bInDuck, !FL_DUCKING -> PM_Duck returns early, moves x1, standing hull
//   DS_UNDUCK: FL_DUCKING, !bInDuck, no IN_DUCK  -> moves x0.333, then PM_UnDuck: origin +18,
//              standing hull, FL_DUCKING cleared (so PM_Jump is allowed). Next frame: DS_STAND.
//   DS_DUCKED: FL_DUCKING, !bInDuck, IN_DUCK held -> stays ducked, moves x0.333, duck hull.
// Not handled (frame left untouched): bInDuck (duck transition; PM_Jump returns if bInDuck &&
// FL_DUCKING), IN_DUCK pressed while standing (starts a transition), unduck with no room.
enum { DS_STAND = 0, DS_UNDUCK, DS_DUCKED };

enum
{
	WHY_OK = 0, WHY_OFF, WHY_DUCK_START, WHY_DUCK_TRANS, WHY_UNDUCK_BLOCKED, WHY_FROZEN, WHY_WATER,
	WHY_WATERJUMP, WHY_OBSERVER, WHY_DEAD, WHY_BASEVEL, WHY_CONVEYOR, WHY_MOVING_GROUND,
	WHY_MAXSPEED, WHY_LADDER
};
new const g_szWhy[][] = {
	"ok", "off", "duck-start", "duck-transition", "unduck-blocked", "frozen/train", "water",
	"waterjump", "observer", "dead", "basevelocity", "conveyor", "moving-ground", "maxspeed", "ladder"
};

enum
{
	ACT_NONE = 0,
	ACT_GROUND,     // ordinary ground frame, plugin did nothing
	ACT_NATURAL,    // a real PM_Jump happens this frame (plugin may have cleared oldbuttons)
	ACT_EMULATE,    // takeoff produced by velocity preset (delayed inject / backward rewrite)
	ACT_STRIP,      // PM_Jump suppressed with oldbuttons |= IN_JUMP
	ACT_DD          // double-duck lift frame (PM_UnDuck with bInDuck on ground: +18, airborne)
};
new const g_szAct[][] = { "none", "ground", "jump", "emul", "strip", "dd" };

new const g_szLogFile[] = "fog_debug.log";   // -> addons/amxmodx/logs/fog_debug.log

// ---- cvars ----
new g_pEnable, g_pMax, g_pFixVz, g_pDebug, g_pDD, g_pDDMax;
new g_pFriction, g_pStopSpeed, g_pEdgeFriction, g_pAccelerate, g_pAirAccelerate;
new g_pGravity, g_pMaxSpeed, g_pRollAngle, g_pRollSpeed;

// movevars snapshot (refreshed per evaluated usercmd)
new Float:mv_friction, Float:mv_stopspeed, Float:mv_edgefriction, Float:mv_accelerate;
new Float:mv_airaccelerate, Float:mv_gravity, Float:mv_maxspeed, Float:mv_rollangle, Float:mv_rollspeed;

new g_tr;
new g_iLadder[128], g_iNumLadders;

// ---- per-player usercmd snapshot (FM_CmdStart) ----
new bool:g_bOn[MAXP];
new bool:g_bInCmd[MAXP];
new g_cmdMsec[MAXP], g_cmdButtons[MAXP];
new Float:g_cmdFwd[MAXP], Float:g_cmdSide[MAXP], Float:g_cmdUp[MAXP];
new Float:g_cmdAng[MAXP][3];

// ---- per-player ground-contact state ----
new g_iGround[MAXP];            // msec>0 usercmds processed on ground since landing
new bool:g_bPreGround[MAXP];    // this usercmd started on ground
new bool:g_bRecThis[MAXP];      // this usercmd was recorded into r_*[c]
new g_iAction[MAXP];
new bool:g_bDelaying[MAXP];
new bool:g_bEvaluated[MAXP];
new g_iPressFrame[MAXP];
new g_iSource[MAXP];            // frame whose velocity was used for an emulated takeoff
new g_iWhyPress[MAXP];          // why the press frame was left untouched (WHY_*)
new g_iDDFirst[MAXP];           // first ground frame of this contact that starts standing (earliest DD press)
new g_iDDPress[MAXP];           // ground frame where the current DD duck press happened
new bool:g_bDDApplied[MAXP];
new Float:g_fDDPre[MAXP], Float:g_fDDCorr[MAXP];
new g_iDDWhy[MAXP][32];
new g_iPlanSrc[MAXP];           // source frame of the takeoff planned for this usercmd (for fog_api_src)
new Float:g_fPlanTime[MAXP];    // gpGlobals->time of that usercmd (svtimebase, same in PreThink and CmdEnd)
new Float:g_fLand[MAXP];
new Float:g_fCand[MAXP][MAX_FOG + 1];
new g_szDec[MAXP][128];

// ---- per-player per-ground-frame records (index = ground frame 1..4) ----
new Float:r_vPre[MAXP][REC][3];
new Float:r_org[MAXP][REC][3];
new Float:r_orgEff[MAXP][REC][3];   // origin PM_Friction/PM_WalkMove will use (after PM_UnDuck)
new Float:r_mult[MAXP][REC];        // PM_Duck move multiplier for this frame
new r_ds[MAXP][REC];
new r_why[MAXP][REC];
new Float:r_pun[MAXP][REC][3];
new Float:r_ang[MAXP][REC][3];
new Float:r_vSet[MAXP][REC][3];
new Float:r_vPost[MAXP][REC][3];
new Float:r_fuPre[MAXP][REC];
new Float:r_fuRed[MAXP][REC];
new Float:r_fuPost[MAXP][REC];
new Float:r_fm[MAXP][REC], Float:r_sm[MAXP][REC], Float:r_um[MAXP][REC];
new Float:r_maxspd[MAXP][REC];
new Float:r_grav[MAXP][REC];
new Float:r_pfric[MAXP][REC];
new r_msec[MAXP][REC];
new r_edge[MAXP][REC];
new r_act[MAXP][REC];

// =============================================================================================
public plugin_init()
{
	register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

	g_pEnable = create_cvar("fog_enable", "1", FCVAR_NONE, "Enable FOG best-of-1/2/3 correction", true, 0.0, true, 1.0);
	g_pMax    = create_cvar("fog_max", "3", FCVAR_NONE, "Highest FOG considered (1-3)", true, 1.0, true, 3.0);
	g_pFixVz  = create_cvar("fog_fix_vz", "1", FCVAR_NONE, "Backward rewrite also uses the earlier frame's jump vz", true, 0.0, true, 1.0);
	g_pDebug  = create_cvar("fog_debug", "0", FCVAR_NONE, "0 off, 1 summary to console + full log, 2 full to console too", true, 0.0, true, 2.0);
	g_pDD     = create_cvar("fog_dd", "1", FCVAR_NONE, "Double duck: give the speed of a DD pressed on the first possible frame", true, 0.0, true, 1.0);
	g_pDDMax  = create_cvar("fog_dd_max", "3", FCVAR_NONE, "DD: best of the first N possible DD FOGs (1-5; 1 = no correction)", true, 1.0, true, 5.0);

	// movevars sources (engine cvars; names as registered by the engine)
	g_pFriction      = get_cvar_pointer("sv_friction");
	g_pStopSpeed     = get_cvar_pointer("sv_stopspeed");
	g_pEdgeFriction  = get_cvar_pointer("edgefriction");
	if (!g_pEdgeFriction)
		g_pEdgeFriction = get_cvar_pointer("sv_edgefriction");
	g_pAccelerate    = get_cvar_pointer("sv_accelerate");
	g_pAirAccelerate = get_cvar_pointer("sv_airaccelerate");
	g_pGravity       = get_cvar_pointer("sv_gravity");
	g_pMaxSpeed      = get_cvar_pointer("sv_maxspeed");
	g_pRollAngle     = get_cvar_pointer("sv_rollangle");
	g_pRollSpeed     = get_cvar_pointer("sv_rollspeed");

	register_forward(FM_CmdStart, "fw_CmdStart", 0);
	register_forward(FM_PlayerPreThink, "fw_PreThink_Post", 1);
	register_forward(FM_CmdEnd, "fw_CmdEnd_Post", 1);

	register_clcmd("say /fog", "cmd_fog");
	register_clcmd("say_team /fog", "cmd_fog");
	register_clcmd("say /fogmenu", "cmd_fogmenu");
	register_clcmd("say_team /fogmenu", "cmd_fogmenu");
	register_clcmd("fogmenu", "cmd_fogmenu");

	g_tr = create_tr2();
}

public plugin_cfg()
{
	// settings saved by /fogmenu
	new path[128];
	fog_cfg_path(path, charsmax(path));
	if (file_exists(path))
	{
		server_cmd("exec ^"%s^"", path);
		server_exec();
	}

	// [PM] PM_Ladder tests the player hull against CONTENTS_LADDER brush models (func_ladder).
	g_iNumLadders = 0;
	new ent = 0;
	while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", "func_ladder")) > 0)
	{
		if (g_iNumLadders < sizeof(g_iLadder))
			g_iLadder[g_iNumLadders++] = ent;
	}
	fog_read_movevars();
	if (get_pcvar_num(g_pDebug))
		fog_log_movevars();
}

public plugin_end()
{
	free_tr2(g_tr);
}

public client_putinserver(id)
{
	g_bOn[id] = true;
	g_bInCmd[id] = false;
	g_bPreGround[id] = false;
	fog_reset(id);
}

public client_disconnected(id)
{
	g_bOn[id] = false;
	g_bInCmd[id] = false;
	g_bPreGround[id] = false;
	fog_reset(id);
}

public cmd_fog(id)
{
	g_bOn[id] = !g_bOn[id];
	fog_reset(id);
	// KZ Rush style toggle: "[KZ]" and the state in the same color, light blue when enabled,
	// red when disabled ("^3" = sender team color; sender forced to blue / red team)
	if (g_bOn[id])
		client_print_color(id, print_team_blue, "^3[KZ]^1 Fog Practice:^3 enabled");
	else
		client_print_color(id, print_team_red, "^3[KZ]^1 Fog Practice:^3 disabled");
	return PLUGIN_HANDLED;
}

// =============================================================================================
// /fogmenu. Per-player item for everyone; server-wide cvars need ADMIN_CVAR (listen host has it).
// Changed cvars are saved to addons/amxmodx/configs/fog_practice.cfg and exec'd in plugin_cfg.
enum
{
	FM_ITEM_ME = 1, FM_ITEM_ENABLE, FM_ITEM_MAX, FM_ITEM_FIXVZ, FM_ITEM_DEBUG, FM_ITEM_DD, FM_ITEM_DDMAX
};

public cmd_fogmenu(id)
{
	fog_menu_show(id);
	return PLUGIN_HANDLED;
}

fog_menu_show(id)
{
	new title[64];
	formatex(title, charsmax(title), "\yFOG Practice \dv%s", PLUGIN_VERSION);
	new menu = menu_create(title, "fog_menu_handler");
	new item[96], info[4];

	formatex(item, charsmax(item), "Plugin for me: %s", g_bOn[id] ? "\yON" : "\rOFF");
	num_to_str(FM_ITEM_ME, info, charsmax(info));
	menu_additem(menu, item, info);

	formatex(item, charsmax(item), "Plugin for everyone: %s", get_pcvar_num(g_pEnable) ? "\yON" : "\rOFF");
	num_to_str(FM_ITEM_ENABLE, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Jump: best of FOG 1 to: \y%d", clamp(get_pcvar_num(g_pMax), 1, MAX_FOG));
	num_to_str(FM_ITEM_MAX, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "DD gets first frame: %s", get_pcvar_num(g_pDD) ? "\yON" : "\rOFF");
	num_to_str(FM_ITEM_DD, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "DD: best of first frames: \y%d", clamp(get_pcvar_num(g_pDDMax), 1, MAX_DD_FOG));
	num_to_str(FM_ITEM_DDMAX, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Rewrite uses earlier jump height: %s", get_pcvar_num(g_pFixVz) ? "\yON" : "\rOFF");
	num_to_str(FM_ITEM_FIXVZ, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Debug output: %s", get_pcvar_num(g_pDebug) ? "\yON" : "\rOFF");
	num_to_str(FM_ITEM_DEBUG, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	menu_setprop(menu, MPROP_EXIT, MEXIT_ALL);
	menu_display(id, menu, 0);
}

public fog_menu_handler(id, menu, item)
{
	if (item == MENU_EXIT || item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}

	new info[4], access, callback;
	menu_item_getinfo(menu, item, access, info, charsmax(info), _, _, callback);
	menu_destroy(menu);

	if (access && !(get_user_flags(id) & access))
	{
		client_print(id, print_chat, "[FOG] You need cvar access to change server-wide settings.");
		fog_menu_show(id);
		return PLUGIN_HANDLED;
	}

	new bool:save = true;
	switch (str_to_num(info))
	{
		case FM_ITEM_ME:
		{
			cmd_fog(id);
			save = false;
		}
		case FM_ITEM_ENABLE: set_pcvar_num(g_pEnable, get_pcvar_num(g_pEnable) ? 0 : 1);
		case FM_ITEM_MAX:    set_pcvar_num(g_pMax, clamp(get_pcvar_num(g_pMax), 1, MAX_FOG) % MAX_FOG + 1);
		case FM_ITEM_FIXVZ:  set_pcvar_num(g_pFixVz, get_pcvar_num(g_pFixVz) ? 0 : 1);
		case FM_ITEM_DEBUG:  set_pcvar_num(g_pDebug, get_pcvar_num(g_pDebug) ? 0 : 1);   // 2 (full) via cvar only
		case FM_ITEM_DD:     set_pcvar_num(g_pDD, get_pcvar_num(g_pDD) ? 0 : 1);
		case FM_ITEM_DDMAX:  set_pcvar_num(g_pDDMax, clamp(get_pcvar_num(g_pDDMax), 1, MAX_DD_FOG) % MAX_DD_FOG + 1);
	}
	if (save)
		fog_save_cfg();
	fog_menu_show(id);
	return PLUGIN_HANDLED;
}

fog_cfg_path(path[], len)
{
	get_configsdir(path, len);
	add(path, len, "/fog_practice.cfg");
}

fog_save_cfg()
{
	new path[128];
	fog_cfg_path(path, charsmax(path));
	new f = fopen(path, "wt");
	if (!f)
		return;
	fprintf(f, "// fog_practice settings - written by /fogmenu, exec'd on map start. Delete to reset.^n");
	fprintf(f, "fog_enable %d^n", get_pcvar_num(g_pEnable));
	fprintf(f, "fog_max %d^n", clamp(get_pcvar_num(g_pMax), 1, MAX_FOG));
	fprintf(f, "fog_fix_vz %d^n", get_pcvar_num(g_pFixVz));
	fprintf(f, "fog_debug %d^n", get_pcvar_num(g_pDebug));
	fprintf(f, "fog_dd %d^n", get_pcvar_num(g_pDD));
	fprintf(f, "fog_dd_max %d^n", clamp(get_pcvar_num(g_pDDMax), 1, MAX_DD_FOG));
	fclose(f);
}

// =============================================================================================
// FM_CmdStart: snapshot the usercmd. On a stock engine this is the same data PM_PlayerMove
// will use (pmove->cmd is a copy of the cmd taken before pfnCmdStart, [SV] SV_RunCmd).
public fw_CmdStart(id, uc_handle)
{
	if (id < 1 || id >= MAXP)
		return FMRES_IGNORED;

	if (!is_user_alive(id) || is_user_bot(id))
	{
		g_bInCmd[id] = false;
		return FMRES_IGNORED;
	}

	g_bInCmd[id] = true;
	g_cmdMsec[id] = get_uc(uc_handle, UC_Msec);
	g_cmdButtons[id] = get_uc(uc_handle, UC_Buttons);
	get_uc(uc_handle, UC_ForwardMove, g_cmdFwd[id]);
	get_uc(uc_handle, UC_SideMove, g_cmdSide[id]);
	get_uc(uc_handle, UC_UpMove, g_cmdUp[id]);
	get_uc(uc_handle, UC_ViewAngles, g_cmdAng[id]);
	return FMRES_IGNORED;
}

// FM_PlayerPreThink post: last hook before SV_SetupPMove copies pev into pmove. Decide here.
public fw_PreThink_Post(id)
{
	if (id < 1 || id >= MAXP || !g_bInCmd[id])
		return FMRES_IGNORED;

	g_bInCmd[id] = false;
	g_iAction[id] = ACT_NONE;
	g_bPreGround[id] = false;
	g_bRecThis[id] = false;

	new flags = pev(id, pev_flags);
	new Float:vel[3];
	pev(id, pev_velocity, vel);

	if (!(flags & FL_ONGROUND) || vel[2] > AIRBORNE_VZ || pev(id, pev_movetype) != MOVETYPE_WALK)
	{
		if (g_bDelaying[id])
			fog_warn(id, "left ground / ladder / noclip while a jump was delayed: aborted");
		fog_reset(id);
		return FMRES_IGNORED;
	}

	g_bPreGround[id] = true;

	new msec = g_cmdMsec[id];
	new buttons = g_cmdButtons[id];
	new oldb = pev(id, pev_oldbuttons);
	// [PM] PM_Jump: jumps only if IN_JUMP is in cmd.buttons and not in pmove->oldbuttons,
	// and pmove->oldbuttons == pev->oldbuttons == previous cmd.buttons ([SV] SV_FinishPMove).
	new bool:press = (buttons & IN_JUMP) && !(oldb & IN_JUMP);
	new fogmax = clamp(get_pcvar_num(g_pMax), 1, MAX_FOG);

	fog_read_movevars();
	new ds = DS_STAND;
	new why = WHY_OFF;
	if (get_pcvar_num(g_pEnable) != 0 && g_bOn[id])
		why = fog_eligible(id, flags, buttons, ds);
	new bool:active = (why == WHY_OK);

	// ---- usercmd with msec 0: frametime 0, nothing moves, but PM_Jump would still run. ----
	// It does not count as a ground frame. A press here is deferred to the next real frame.
	if (msec == 0)
	{
		if (!active)
		{
			if (g_bDelaying[id])
			{
				fog_warn(id, "became ineligible while a jump was delayed: aborted");
				g_bDelaying[id] = false;
			}
			g_iAction[id] = press ? ACT_NATURAL : ACT_GROUND;
			return FMRES_IGNORED;
		}
		if (g_bDelaying[id] || (press && g_iGround[id] < fogmax))
		{
			if (!g_bDelaying[id])
			{
				g_iPressFrame[id] = g_iGround[id] + 1;
				fog_dec(id, "ms0:defer ");
			}
			set_pev(id, pev_oldbuttons, oldb | IN_JUMP);
			g_bDelaying[id] = true;
			g_iAction[id] = ACT_STRIP;
		}
		else
		{
			g_iAction[id] = press ? ACT_NATURAL : ACT_GROUND;
		}
		return FMRES_IGNORED;
	}

	if (g_iGround[id] < 100000)
		g_iGround[id]++;
	new c = g_iGround[id];

	if (c < REC)
	{
		fog_record_pre(id, c, vel, ds, why);
		g_bRecThis[id] = true;
	}
	if (c == 1)
	{
		g_fLand[id] = fog_len2(vel);
		if (get_pcvar_num(g_pDebug))
			fog_log_movevars();
	}

	if (g_bDelaying[id] && c > fogmax)
	{
		// only possible if fog_max was lowered mid-delay: give the jump back to the player
		fog_warn(id, "fog_max lowered while a jump was delayed: aborted");
		g_bDelaying[id] = false;
		if ((buttons & IN_JUMP) && (oldb & IN_JUMP))
			set_pev(id, pev_oldbuttons, oldb & ~IN_JUMP);
		press = (buttons & IN_JUMP) != 0;
		active = false;
	}

	if (!active)
	{
		if (g_bDelaying[id])
		{
			new msg[96];
			formatex(msg, charsmax(msg), "became ineligible (%s) while a jump was delayed: aborted", g_szWhy[why]);
			fog_warn(id, msg);
			g_bDelaying[id] = false;
		}
		if (press && !g_iPressFrame[id])
		{
			g_iPressFrame[id] = c;
			g_iWhyPress[id] = why;
		}
		g_iAction[id] = press ? ACT_NATURAL : ACT_GROUND;
	}
	else if (g_bDelaying[id] || (press && c <= fogmax))
	{
		if (!g_iPressFrame[id])
			g_iPressFrame[id] = c;
		fog_evaluate(id, c, fogmax, buttons, oldb);
	}
	else
	{
		if (press && !g_iPressFrame[id])
			g_iPressFrame[id] = c;
		g_iAction[id] = press ? ACT_NATURAL : ACT_GROUND;
	}

	// ---- double duck (DD) ----
	// [PM] PM_Duck: IN_DUCK newly pressed (vs oldbuttons) while !FL_DUCKING -> bInDuck = TRUE,
	// the press frame stays a ground frame (friction, moves x0.333). Next usercmd without IN_DUCK
	// while bInDuck -> PM_UnDuck (stock path, no bInDuck guard): on ground origin += 18 with the
	// standing hull -> PM_CategorizePosition: airborne for that whole frame (the "lift").
	new bInDuck = pev(id, pev_bInDuck);
	if (!g_iDDFirst[id] && !(flags & FL_DUCKING) && !bInDuck)
		g_iDDFirst[id] = c;
	if ((buttons & IN_DUCK) && !(oldb & IN_DUCK) && !(flags & FL_DUCKING) && !bInDuck)
		g_iDDPress[id] = c;
	if (bInDuck && !(flags & FL_DUCKING) && !(buttons & IN_DUCK) && fog_unduck_room(id))
		fog_dd_lift(id, c, flags, buttons, vel);

	if (g_bRecThis[id])
		r_act[id][c] = g_iAction[id];

	if (g_iAction[id] == ACT_NATURAL || g_iAction[id] == ACT_EMULATE)
	{
		g_iPlanSrc[id] = (g_iAction[id] == ACT_EMULATE) ? g_iSource[id] : c;
		g_fPlanTime[id] = get_gametime();
	}
	return FMRES_IGNORED;
}

// Optional API for other plugins (e.g. speed_hud via callfunc): the ground frame whose velocity
// this usercmd's takeoff uses (== takeoff frame unless a backward rewrite happened). Valid only
// during the same usercmd (PreThink .. CmdEnd), otherwise 0. Order-independent: decided in PreThink.
public fog_api_src(id)
{
	if (id < 1 || id >= MAXP)
		return 0;
	if (g_fPlanTime[id] == get_gametime())
		return g_iPlanSrc[id];
	return 0;
}

// FM_CmdEnd post: after PM_Move, SV_FinishPMove and PlayerPostThink. Read the real outcome.
public fw_CmdEnd_Post(id)
{
	if (id < 1 || id >= MAXP || !g_bPreGround[id])
		return FMRES_IGNORED;

	g_bPreGround[id] = false;

	new c = g_iGround[id];
	new act = g_iAction[id];
	new Float:vel[3], Float:fu;
	pev(id, pev_velocity, vel);
	pev(id, pev_fuser2, fu);
	new bool:air = !(pev(id, pev_flags) & FL_ONGROUND);

	if (act == ACT_EMULATE)
	{
		if (air)
		{
			// [PM] PM_Jump: pmove->fuser2 = 1315.789429 (the engine did not run PM_Jump for us).
			set_pev(id, pev_fuser2, STAMINA_ON_JUMP);
			fu = STAMINA_ON_JUMP;
		}
		else
		{
			fog_warn(id, "emulated takeoff did not leave the ground");
		}
	}

	new bool:jumped = air && (floatabs(fu - STAMINA_ON_JUMP) < 0.01);

	if (g_bRecThis[id])
	{
		r_vPost[id][c][0] = vel[0];
		r_vPost[id][c][1] = vel[1];
		r_vPost[id][c][2] = vel[2];
		r_fuPost[id][c] = fu;
		if (get_pcvar_num(g_pDebug))
			fog_log_frame(id, c, air);
	}

	if (act == ACT_DD)
	{
		if (!air)
			fog_warn(id, "expected a double-duck lift but the player stayed on ground");
		if (get_pcvar_num(g_pDebug))
		{
			new line[256];
			formatex(line, charsmax(line), "FOGD id=%d lift=%d press=%d first=%d pre=%.3f corr=%.3f applied=%d xy=%.3f vz=%.3f note=%s",
				id, c, g_iDDPress[id], g_iDDFirst[id], g_fDDPre[id], g_fDDCorr[id], g_bDDApplied[id] ? 1 : 0,
				fog_len2(vel), vel[2], g_iDDWhy[id]);
			fog_out(id, get_pcvar_num(g_pDebug) >= 2, line);
			if (is_user_connected(id))
				console_print(id, "[FOG] DD press f%d (first f%d) lift f%d: %.2f -> %.2f %s",
					g_iDDPress[id], g_iDDFirst[id], c, g_fDDPre[id], fog_len2(vel), g_bDDApplied[id] ? "(first-frame speed)" : g_iDDWhy[id]);
		}
	}

	if (act == ACT_STRIP && air)
		fog_warn(id, "strip failed: player left the ground on a stripped frame");
	if (act == ACT_NATURAL && g_bEvaluated[id] && !jumped)
		fog_warn(id, "expected a natural PM_Jump but none happened");

	if (jumped)
	{
		if (get_pcvar_num(g_pDebug))
			fog_log_jump(id, c, act, vel);
		fog_reset(id);
	}
	else if (air)
	{
		// ledge drop (or anything else that left the ground without PM_Jump)
		if (g_bDelaying[id])
			fog_warn(id, "left the ground without a jump while delaying: aborted");
		fog_reset(id);
	}
	return FMRES_IGNORED;
}

// =============================================================================================
// Decision for a usercmd on ground frame c (c <= fogmax), either a fresh press or a delayed jump.
fog_evaluate(id, c, fogmax, buttons, oldb)
{
	g_bEvaluated[id] = true;

	new Float:cand[MAX_FOG + 1], Float:tmp[3];
	new m;

	// FOG <= c: exact, from the recorded pre-move state of that frame
	for (m = 1; m <= c && m <= fogmax; m++)
		cand[m] = fog_takeoff(r_vPre[id][m], r_msec[id][m], r_grav[id][m], r_maxspd[id][m], tmp);

	// FOG > c: predicted, simulating ground frames with this usercmd's inputs repeated
	if (c < fogmax)
	{
		new Float:v[3], Float:org[3], Float:pun[3], Float:fu;
		v = r_vPre[id][c];
		org = r_orgEff[id][c];
		pun = r_pun[id][c];
		fu = r_fuPre[id][c];
		// first simulated frame is frame c itself (if stripped), with its own duck state;
		// after an unduck the player is standing; a held duck stays ducked
		new ds = r_ds[id][c];
		new bool:lost = false;
		for (m = c + 1; m <= fogmax; m++)
		{
			if (lost)
			{
				cand[m] = -1.0;
				continue;
			}
			fog_ground_step(id, v, org, fu, pun, r_msec[id][c], r_fm[id][c], r_sm[id][c], r_um[id][c],
				r_ang[id][c], r_maxspd[id][c], r_pfric[id][c],
				(ds == DS_STAND) ? 1.0 : DUCK_MULT, ds == DS_DUCKED);
			if (ds == DS_UNDUCK)
				ds = DS_STAND;
			// [PM] PM_CategorizePosition at the start of frame m: still on ground at the predicted
			// origin? (small / offset bhop blocks: the extra ground frame can carry you over the
			// edge, and a delayed jump would then be lost). If not, FOG m and later are impossible.
			if (!fog_ground_below(id, org, ds == DS_DUCKED))
			{
				lost = true;
				cand[m] = -1.0;
				continue;
			}
			cand[m] = fog_takeoff(v, r_msec[id][c], r_grav[id][c], r_maxspd[id][c], tmp);
		}
	}

	// best: start at "now" (no intervention); others must beat it by CHOICE_EPS; ties -> lower FOG
	new best = c;
	new Float:bestv = cand[c];
	for (m = 1; m <= fogmax; m++)
	{
		if (m != c && cand[m] > bestv + CHOICE_EPS)
		{
			best = m;
			bestv = cand[m];
		}
	}

	for (m = 1; m <= MAX_FOG; m++)
		g_fCand[id][m] = (m <= fogmax) ? cand[m] : 0.0;

	new dec[32];
	if (best > c)
	{
		// delay forward: stay on ground this frame
		set_pev(id, pev_oldbuttons, oldb | IN_JUMP);
		g_bDelaying[id] = true;
		g_iAction[id] = ACT_STRIP;
		formatex(dec, charsmax(dec), "f%d:delay ", c);
	}
	else
	{
		g_bDelaying[id] = false;
		if (best == c && (buttons & IN_JUMP))
		{
			if (oldb & IN_JUMP)
				set_pev(id, pev_oldbuttons, oldb & ~IN_JUMP);
			g_iAction[id] = ACT_NATURAL;
			g_iSource[id] = c;
			formatex(dec, charsmax(dec), "f%d:now ", c);
		}
		else if (fog_emulate(id, c, best))
		{
			g_iAction[id] = ACT_EMULATE;
			g_iSource[id] = best;
			if (best == c)
				formatex(dec, charsmax(dec), "f%d:now(emul) ", c);
			else
				formatex(dec, charsmax(dec), "f%d:rewrite->%d ", c, best);
		}
		else if (buttons & IN_JUMP)
		{
			// cannot emulate on this frame: take the real jump now
			if (oldb & IN_JUMP)
				set_pev(id, pev_oldbuttons, oldb & ~IN_JUMP);
			g_iAction[id] = ACT_NATURAL;
			g_iSource[id] = c;
			formatex(dec, charsmax(dec), "f%d:fallback-now ", c);
		}
		else if (c < fogmax)
		{
			// cannot emulate and no IN_JUMP: keep the player grounded one more frame
			set_pev(id, pev_oldbuttons, oldb | IN_JUMP);
			g_bDelaying[id] = true;
			g_iAction[id] = ACT_STRIP;
			formatex(dec, charsmax(dec), "f%d:fallback-delay ", c);
		}
		else
		{
			g_iAction[id] = ACT_GROUND;
			formatex(dec, charsmax(dec), "f%d:fallback-lost ", c);
			fog_warn(id, "could not emulate the takeoff on the last allowed frame: jump lost");
		}
	}
	fog_dec(id, dec);

	if (get_pcvar_num(g_pDebug))
	{
		new line[256];
		formatex(line, charsmax(line), "FOGE id=%d f=%d cand=%.3f,%.3f,%.3f best=%d dec=%s",
			id, c, g_fCand[id][1], g_fCand[id][2], g_fCand[id][3], best, dec);
		fog_out(id, get_pcvar_num(g_pDebug) >= 2, line);
	}
}

// DD lift on ground frame c (the duck press was on g_iDDPress). If the press was on the 2nd or 3rd
// possible frame (fog_dd_max), preset the pre-move velocity to what a press on the FIRST possible
// frame would have produced here: that frame's recorded state run through one ground frame with
// the PM_Duck multiplier (= a press frame), fog_ground_step(..., DUCK_MULT). The engine then runs
// the lift frame itself (PM_UnDuck +18, PM_AirMove with x0.333 moves). Lift timing and position
// are unchanged, like a backward rewrite. DD has no PM_PreventMegaBunnyJumping cap, so the earliest
// press is the fastest whenever ground friction outweighs ground acceleration ("not-better" else).
fog_dd_lift(id, c, flags, buttons, const Float:vel[3])
{
	g_iAction[id] = ACT_DD;
	// fog_api_src: the DD FOG whose speed this lift gets (c unless corrected below)
	g_iPlanSrc[id] = c;
	g_fPlanTime[id] = get_gametime();
	g_bDDApplied[id] = false;
	g_fDDPre[id] = fog_len2(vel);
	g_fDDCorr[id] = 0.0;
	copy(g_iDDWhy[id], charsmax(g_iDDWhy[]), "-");

	if (!get_pcvar_num(g_pEnable) || !g_bOn[id] || !get_pcvar_num(g_pDD))
	{
		copy(g_iDDWhy[id], charsmax(g_iDDWhy[]), "off");
		return;
	}
	new ds2;
	new why = fog_eligible(id, flags, buttons, ds2, true);
	if (why != WHY_OK)
	{
		copy(g_iDDWhy[id], charsmax(g_iDDWhy[]), g_szWhy[why]);
		return;
	}
	new e = g_iDDFirst[id], k = g_iDDPress[id];
	if (!e || !k || e >= REC)
	{
		copy(g_iDDWhy[id], charsmax(g_iDDWhy[]), "no-record");
		return;
	}
	// DD FOG = lift frame c (usercmds started on ground, lift included). Best possible = e + 1
	// (press on e, lift on e+1): 2 after a standing landing, 3 after a ducked one (gs / sgs).
	if (c <= e + 1)
	{
		copy(g_iDDWhy[id], charsmax(g_iDDWhy[]), "already-first");
		return;
	}
	if (c - (e + 1) >= clamp(get_pcvar_num(g_pDDMax), 1, MAX_DD_FOG))
	{
		copy(g_iDDWhy[id], charsmax(g_iDDWhy[]), "too-late");
		return;
	}
	#pragma unused k

	new Float:v[3], Float:org[3], Float:pun[3], Float:fu;
	v = r_vPre[id][e];
	org = r_orgEff[id][e];
	pun = r_pun[id][e];
	fu = r_fuPre[id][e];
	fog_ground_step(id, v, org, fu, pun, r_msec[id][e], r_fm[id][e], r_sm[id][e], r_um[id][e],
		r_ang[id][e], r_maxspd[id][e], r_pfric[id][e], DUCK_MULT, false);
	g_fDDCorr[id] = fog_len2(v);

	if (g_fDDCorr[id] <= g_fDDPre[id] + CHOICE_EPS)
	{
		copy(g_iDDWhy[id], charsmax(g_iDDWhy[]), "not-better");
		return;
	}
	v[2] = vel[2];
	set_pev(id, pev_velocity, v);
	g_bDDApplied[id] = true;
	g_iPlanSrc[id] = e + 1;     // speed of the best DD: press on e, lift on e + 1
	if (c < REC)
	{
		r_vSet[id][c][0] = v[0];
		r_vSet[id][c][1] = v[1];
		r_vSet[id][c][2] = v[2];
	}
}

// Takeoff at frame c using the (capped) velocity of frame b. Preset so the engine runs the jump
// frame's remainder (see header). Returns false if the preset would not make the player airborne.
bool:fog_emulate(id, c, b)
{
	// On a DS_UNDUCK frame the preset would make PM_CategorizePosition put the player in the air
	// BEFORE PM_Duck; PM_UnDuck then skips the +18 raise (only done when on ground) and the player
	// would stay ducked / lose 18 units of height. Never emulate there.
	if (r_ds[id][c] == DS_UNDUCK)
		return false;

	new Float:v[3];
	fog_takeoff(r_vPre[id][b], r_msec[id][b], r_grav[id][b], r_maxspd[id][b], v);

	// vz PM_Jump writes: JUMP_SPEED * stamina(fuser2 after PM_ReduceTimers of the jump frame)
	new Float:fuSrc = (get_pcvar_num(g_pFixVz) != 0) ? r_fuRed[id][b] : r_fuRed[id][c];
	new Float:vzJump = fog_jump_vz(fuSrc);

	// A real jump frame: PM_AddCorrectGravity, PM_Jump sets vz then calls PM_FixupGravityVelocity,
	// PM_AirMove/PM_FlyMove, then PM_PlayerMove calls PM_FixupGravityVelocity again at the end.
	// Presetting vz = vzJump lets this frame's PM_AddCorrectGravity stand in for PM_Jump's own
	// fixup, so vz during PM_FlyMove (vzJump - g/2*dt) and at frame end (vzJump - g*dt) match.
	v[2] = vzJump;
	if (v[2] <= AIRBORNE_VZ)
		return false;

	set_pev(id, pev_velocity, v);
	r_vSet[id][c][0] = v[0];
	r_vSet[id][c][1] = v[1];
	r_vSet[id][c][2] = v[2];
	return true;
}

// Returns WHY_OK if the plugin may act on this ground frame; sets ds to the PM_Duck state.
fog_eligible(id, flags, buttons, &ds, bool:ignoreDuck = false)
{
	ds = DS_STAND;
	// FL_FROZEN / FL_ONTRAIN: PM_CheckParameters zeroes the moves
	if (flags & (FL_FROZEN | FL_ONTRAIN))
		return WHY_FROZEN;
	// [PM] PM_Duck / PM_UnDuck / PM_Jump (bInDuck && FL_DUCKING -> no jump)
	if (ignoreDuck)
	{
		// double-duck path: the caller handles the duck state
	}
	else if (pev(id, pev_bInDuck))
		return WHY_DUCK_TRANS;
	else if (flags & FL_DUCKING)
	{
		if (buttons & IN_DUCK)
			ds = DS_DUCKED;
		else if (fog_unduck_room(id))
			ds = DS_UNDUCK;
		else
			return WHY_UNDUCK_BLOCKED;
	}
	else if (buttons & IN_DUCK)
		return WHY_DUCK_START;
	// water: PM_Jump swims at waterlevel >= 2; keep it simple and require dry feet
	if (pev(id, pev_waterlevel) != 0)
		return WHY_WATER;
	new Float:f;
	pev(id, pev_teleport_time, f);          // pmove->waterjumptime ([SV] SV_SetupPMove)
	if (f != 0.0)
		return WHY_WATERJUMP;
	if (pev(id, pev_iuser1) != 0)
		return WHY_OBSERVER;
	if (pev(id, pev_deadflag) != DEAD_NO)
		return WHY_DEAD;
	pev(id, pev_health, f);                 // pmove->dead = health <= 0
	if (f <= 0.0)
		return WHY_DEAD;
	new Float:bv[3];
	pev(id, pev_basevelocity, bv);          // conveyors / pushes: skip
	if (bv[0] != 0.0 || bv[1] != 0.0 || bv[2] != 0.0)
		return WHY_BASEVEL;
	// [GD] CBasePlayer::Jump adds the ground's velocity only for FL_CONVEYOR ground (basevelocity)
	// and for func_train / func_tracktrain / func_vehicle. Other moving brushes, e.g. sinking bhop
	// blocks (func_door), are fine: [SV] SV_PushMove (sv_phys.cpp) carries a player standing on the
	// pusher (groundentity == pusher) with it and keeps FL_ONGROUND for MOVETYPE_WALK; it moves the
	// origin, not the velocity, so none of the FOG math changes.
	new ground = pev(id, pev_groundentity);
	if (ground > 0 && pev_valid(ground))
	{
		if (pev(ground, pev_flags) & FL_CONVEYOR)
			return WHY_CONVEYOR;
		new cls[32];
		pev(ground, pev_classname, cls, charsmax(cls));
		if (equal(cls, "func_train") || equal(cls, "func_tracktrain") || equal(cls, "func_vehicle"))
			return WHY_MOVING_GROUND;
	}
	if (fog_effective_maxspeed(id) <= 0.0)
		return WHY_MAXSPEED;
	if (fog_near_ladder(id))
		return WHY_LADDER;
	return WHY_OK;
}

// [PM] PM_UnDuck (stock path): on ground, newOrigin = origin + 18; unducks unless the standing
// hull at newOrigin starts solid.
bool:fog_unduck_room(id)
{
	new Float:org[3];
	pev(id, pev_origin, org);
	org[2] += UNDUCK_RAISE;
	engfunc(EngFunc_TraceHull, org, org, IGNORE_MONSTERS, HULL_HUMAN, id, g_tr);
	return !get_tr2(g_tr, TR_StartSolid) && !get_tr2(g_tr, TR_AllSolid);
}

bool:fog_near_ladder(id)
{
	if (!g_iNumLadders)
		return false;
	new Float:pmin[3], Float:pmax[3], Float:lmin[3], Float:lmax[3];
	pev(id, pev_absmin, pmin);
	pev(id, pev_absmax, pmax);
	for (new i = 0; i < g_iNumLadders; i++)
	{
		new ent = g_iLadder[i];
		if (!pev_valid(ent))
			continue;
		pev(ent, pev_absmin, lmin);
		pev(ent, pev_absmax, lmax);
		if (pmin[0] - 2.0 <= lmax[0] && pmax[0] + 2.0 >= lmin[0]
		 && pmin[1] - 2.0 <= lmax[1] && pmax[1] + 2.0 >= lmin[1]
		 && pmin[2] - 2.0 <= lmax[2] && pmax[2] + 2.0 >= lmin[2])
			return true;
	}
	return false;
}

// [PM] PM_CheckParameters: pmove->maxspeed = sv_maxspeed; if (clientmaxspeed != 0) min(...)
Float:fog_effective_maxspeed(id)
{
	new Float:client;
	pev(id, pev_maxspeed, client);
	new Float:ms = mv_maxspeed;
	if (client != 0.0 && client < ms)
		ms = client;
	return ms;
}

fog_record_pre(id, c, const Float:vel[3], ds, why)
{
	new msec = g_cmdMsec[id];
	new Float:f;

	r_vPre[id][c][0] = vel[0];
	r_vPre[id][c][1] = vel[1];
	r_vPre[id][c][2] = vel[2];
	pev(id, pev_origin, r_org[id][c]);
	r_orgEff[id][c][0] = r_org[id][c][0];
	r_orgEff[id][c][1] = r_org[id][c][1];
	r_orgEff[id][c][2] = r_org[id][c][2] + ((ds == DS_UNDUCK) ? UNDUCK_RAISE : 0.0);
	r_ds[id][c] = ds;
	r_why[id][c] = why;
	// [PM] PM_Duck scales the moves when IN_DUCK || bInDuck || FL_DUCKING (also on ineligible frames)
	r_mult[id][c] = ((g_cmdButtons[id] & IN_DUCK) || pev(id, pev_bInDuck) || (pev(id, pev_flags) & FL_DUCKING)) ? DUCK_MULT : 1.0;
	pev(id, pev_punchangle, r_pun[id][c]);
	r_ang[id][c][0] = g_cmdAng[id][0];
	r_ang[id][c][1] = g_cmdAng[id][1];
	r_ang[id][c][2] = g_cmdAng[id][2];
	pev(id, pev_fuser2, f);
	r_fuPre[id][c] = f;
	r_fuRed[id][c] = fog_reduce_fuser2(f, msec);
	r_msec[id][c] = msec;
	r_fm[id][c] = g_cmdFwd[id];
	r_sm[id][c] = g_cmdSide[id];
	r_um[id][c] = g_cmdUp[id];
	r_maxspd[id][c] = fog_effective_maxspeed(id);
	pev(id, pev_gravity, f);
	r_grav[id][c] = (f != 0.0) ? f : 1.0;          // PM_AddCorrectGravity: ent_gravity
	pev(id, pev_friction, f);
	r_pfric[id][c] = f;                             // pmove->friction
	new Float:v0[3];
	v0[0] = vel[0];
	v0[1] = vel[1];
	v0[2] = 0.0;                                    // PM_Friction runs after velocity[2] = 0
	r_edge[id][c] = fog_edge_trace(id, r_orgEff[id][c], v0, ds == DS_DUCKED) ? 1 : 0;
	r_vSet[id][c][0] = 0.0;
	r_vSet[id][c][1] = 0.0;
	r_vSet[id][c][2] = 0.0;
	r_vPost[id][c][0] = 0.0;
	r_vPost[id][c][1] = 0.0;
	r_vPost[id][c][2] = 0.0;
	r_fuPost[id][c] = 0.0;
	r_act[id][c] = ACT_NONE;
}

fog_reset(id)
{
	g_iGround[id] = 0;
	g_bDelaying[id] = false;
	g_bEvaluated[id] = false;
	g_iPressFrame[id] = 0;
	g_iSource[id] = 0;
	g_iWhyPress[id] = WHY_OK;
	g_iDDFirst[id] = 0;
	g_iDDPress[id] = 0;
	g_bDDApplied[id] = false;
	g_fDDPre[id] = 0.0;
	g_fDDCorr[id] = 0.0;
	g_iDDWhy[id][0] = 0;
	g_fLand[id] = 0.0;
	g_szDec[id][0] = 0;
	for (new m = 0; m <= MAX_FOG; m++)
		g_fCand[id][m] = 0.0;
}

fog_dec(id, const s[])
{
	add(g_szDec[id], charsmax(g_szDec[]), s);
}

fog_read_movevars()
{
	mv_friction      = g_pFriction      ? get_pcvar_float(g_pFriction)      : 4.0;
	mv_stopspeed     = g_pStopSpeed     ? get_pcvar_float(g_pStopSpeed)     : 75.0;
	mv_edgefriction  = g_pEdgeFriction  ? get_pcvar_float(g_pEdgeFriction)  : 2.0;
	mv_accelerate    = g_pAccelerate    ? get_pcvar_float(g_pAccelerate)    : 5.0;
	mv_airaccelerate = g_pAirAccelerate ? get_pcvar_float(g_pAirAccelerate) : 10.0;
	mv_gravity       = g_pGravity       ? get_pcvar_float(g_pGravity)       : 800.0;
	mv_maxspeed      = g_pMaxSpeed      ? get_pcvar_float(g_pMaxSpeed)      : 320.0;
	mv_rollangle     = g_pRollAngle     ? get_pcvar_float(g_pRollAngle)     : 0.0;
	mv_rollspeed     = g_pRollSpeed     ? get_pcvar_float(g_pRollSpeed)     : 0.0;
}

// =============================================================================================
// Engine-dependent stock: the PM_Friction edge test.
// [PM] PM_Friction: start = origin + vel/speed*16 (xy), start.z = origin.z + player_mins[usehull].z,
// stop = start - 34 (z); PM_PlayerTrace(start, stop, PM_NORMAL). Edge friction iff fraction == 1.
// [TR] PM_PlayerTrace sets fraction = 0 when the trace starts solid, so startsolid => no edge.
// pm usehull 0 (standing) == engine HULL_HUMAN, usehull 1 (ducked) == HULL_HEAD
// ([TR] PM_HullForBsp maps usehull 1 -> model hull 3).
bool:fog_edge_trace(id, const Float:org[3], const Float:v[3], bool:ducked)
{
	new Float:spd = floatsqroot(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
	if (spd < 0.1)
		return false;
	new Float:start[3], Float:stop[3];
	start[0] = org[0] + v[0] / spd * EDGE_AHEAD;
	start[1] = org[1] + v[1] / spd * EDGE_AHEAD;
	start[2] = org[2] + (ducked ? PLAYER_MINS_Z_DUCK : PLAYER_MINS_Z);
	stop[0] = start[0];
	stop[1] = start[1];
	stop[2] = start[2] - EDGE_DROP;
	engfunc(EngFunc_TraceHull, start, stop, IGNORE_MONSTERS, ducked ? HULL_HEAD : HULL_HUMAN, id, g_tr);
	if (get_tr2(g_tr, TR_StartSolid) || get_tr2(g_tr, TR_AllSolid))
		return false;
	new Float:frac;
	get_tr2(g_tr, TR_flFraction, frac);
	return (frac == 1.0);
}

// [PM] PM_CategorizePosition: trace the player hull 2 units down; on ground iff the hit plane's
// normal z >= 0.7 (no hit -> normal 0 -> airborne). allsolid counts as no ground (be safe: a
// FOG we are not sure we can reach is never chosen).
bool:fog_ground_below(id, const Float:org[3], bool:ducked)
{
	new Float:end[3], Float:normal[3];
	end[0] = org[0];
	end[1] = org[1];
	end[2] = org[2] - 2.0;
	engfunc(EngFunc_TraceHull, org, end, IGNORE_MONSTERS, ducked ? HULL_HEAD : HULL_HUMAN, id, g_tr);
	if (get_tr2(g_tr, TR_AllSolid))
		return false;
	get_tr2(g_tr, TR_vecPlaneNormal, normal);
	return (normal[2] >= 0.7);
}

// One predicted ground frame (no jump): updates v, org, fu, pun in place.
fog_ground_step(id, Float:v[3], Float:org[3], &Float:fu, Float:pun[3], msec, Float:fm, Float:sm, Float:um,
	const Float:ang[3], Float:maxspd, Float:pfric, Float:mult, bool:ducked)
{
	new Float:dt = float(msec) * 0.001;
	new Float:wishdir[3], Float:wishspeed;

	fog_wish(ang, pun, v, fm, sm, um, maxspd, dt, mult, wishdir, wishspeed); // PM_CheckParameters + PM_Duck
	fu = fog_reduce_fuser2(fu, msec);                                     // PM_ReduceTimers
	v[2] = 0.0;                                                           // gravity half, then velocity[2] = 0
	new bool:edge = fog_edge_trace(id, org, v, ducked);
	fog_friction(v, dt, edge, pfric, mv_friction, mv_edgefriction, mv_stopspeed);   // PM_Friction
	fog_walk_accel(v, fu, wishdir, wishspeed, dt, pfric, mv_accelerate);             // PM_WalkMove
	org[0] += v[0] * dt;                                                  // flat-ground displacement
	org[1] += v[1] * dt;
}

// =============================================================================================
// Pure-math stocks (mirror [PM]; same formulas in fog_reference.py)

// PM_ReduceTimers (fuser2 part)
stock Float:fog_reduce_fuser2(Float:fu, msec)
{
	if (fu > 0.0)
	{
		fu -= float(msec);
		if (fu < 0.0)
			fu = 0.0;
	}
	return fu;
}

// PM_WalkMove / PM_Jump stamina factor: (100 - fuser2 * 0.001 * 19) * 0.01, only if fuser2 > 0
stock Float:fog_stamina(Float:fu)
{
	if (fu > 0.0)
		return (100.0 - fu * 0.001 * 19.0) * 0.01;
	return 1.0;
}

// PM_Jump vz (before PM_FixupGravityVelocity)
stock Float:fog_jump_vz(Float:fuAfterReduce)
{
	return JUMP_SPEED * fog_stamina(fuAfterReduce);
}

// PM_PreventMegaBunnyJumping
stock fog_cap(Float:v[3], Float:maxspd)
{
	new Float:maxscaled = BHOP_CAP_FACTOR * maxspd;
	if (maxscaled <= 0.0)
		return;
	new Float:spd = floatsqroot(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
	if (spd <= maxscaled)
		return;
	new Float:fraction = (maxscaled / spd) * BHOP_CAP_FRACTION;
	v[0] *= fraction;
	v[1] *= fraction;
	v[2] *= fraction;
}

// Velocity handed to PM_AirMove on a jump frame that starts with pre-move velocity vpre:
// PM_AddCorrectGravity (vz -= entgrav*g*0.5*dt) then PM_PreventMegaBunnyJumping. Returns |xy|.
stock Float:fog_takeoff(const Float:vpre[3], msec, Float:entgrav, Float:maxspd, Float:out[3])
{
	new Float:dt = float(msec) * 0.001;
	out[0] = vpre[0];
	out[1] = vpre[1];
	out[2] = vpre[2] - entgrav * mv_gravity * 0.5 * dt;
	fog_cap(out, maxspd);
	return floatsqroot(out[0] * out[0] + out[1] * out[1]);
}

// PM_Friction math (ground branch). v[2] must already be 0.
stock fog_friction(Float:v[3], Float:dt, bool:edge, Float:pfric, Float:friction, Float:edgefriction, Float:stopspeed)
{
	new Float:speed = floatsqroot(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
	if (speed < 0.1)
		return;
	new Float:fr = edge ? friction * edgefriction : friction;
	fr *= pfric;
	new Float:control = (speed < stopspeed) ? stopspeed : speed;
	new Float:drop = fr * (control * dt);
	new Float:newspeed = speed - drop;
	if (newspeed < 0.0)
		newspeed = 0.0;
	newspeed /= speed;
	v[0] *= newspeed;
	v[1] *= newspeed;
	v[2] *= newspeed;
}

// PM_Accelerate
stock fog_accelerate(Float:v[3], const Float:wishdir[3], Float:wishspeed, Float:accel, Float:dt, Float:pfric)
{
	new Float:currentspeed = v[0] * wishdir[0] + v[1] * wishdir[1] + v[2] * wishdir[2];
	new Float:addspeed = wishspeed - currentspeed;
	if (addspeed <= 0.0)
		return;
	new Float:accelspeed = accel * dt * wishspeed * pfric;
	if (accelspeed > addspeed)
		accelspeed = addspeed;
	v[0] += accelspeed * wishdir[0];
	v[1] += accelspeed * wishdir[1];
	v[2] += accelspeed * wishdir[2];
}

// PM_WalkMove velocity part (stamina, accelerate, spd < 1 clear); basevelocity is 0
stock fog_walk_accel(Float:v[3], Float:fu, const Float:wishdir[3], Float:wishspeed, Float:dt, Float:pfric, Float:accel)
{
	if (fu > 0.0)
	{
		new Float:r = fog_stamina(fu);
		v[0] *= r;
		v[1] *= r;
	}
	v[2] = 0.0;
	fog_accelerate(v, wishdir, wishspeed, accel, dt, pfric);
	v[2] = 0.0;
	if (floatsqroot(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) < 1.0)
	{
		v[0] = 0.0;
		v[1] = 0.0;
		v[2] = 0.0;
	}
}

// mathlib AngleVectors (forward, right)
stock fog_angle_vectors(const Float:a[3], Float:f[3], Float:r[3])
{
	new Float:sy = floatsin(a[1], degrees), Float:cy = floatcos(a[1], degrees);
	new Float:sp = floatsin(a[0], degrees), Float:cp = floatcos(a[0], degrees);
	new Float:sr = floatsin(a[2], degrees), Float:cr = floatcos(a[2], degrees);
	f[0] = cp * cy;
	f[1] = cp * sy;
	f[2] = -sp;
	r[0] = (-1.0 * sr * sp * cy + -1.0 * cr * -sy);
	r[1] = (-1.0 * sr * sp * sy + -1.0 * cr * cy);
	r[2] = -1.0 * sr * cp;
}

// PM_CalcRoll
stock Float:fog_calc_roll(const Float:ang[3], const Float:vel[3], Float:rollangle, Float:rollspeed)
{
	new Float:f[3], Float:r[3];
	fog_angle_vectors(ang, f, r);
	new Float:side = vel[0] * r[0] + vel[1] * r[1] + vel[2] * r[2];
	new Float:sign = (side < 0.0) ? -1.0 : 1.0;
	side = floatabs(side);
	if (side < rollspeed)
		side = side * rollangle / rollspeed;
	else
		side = rollangle;
	return side * sign;
}

// PM_DropPunchAngle
stock fog_drop_punch(Float:p[3], Float:dt)
{
	new Float:len = floatsqroot(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
	if (len != 0.0)
	{
		p[0] /= len;
		p[1] /= len;
		p[2] /= len;
	}
	len -= (10.0 + len * 0.5) * dt;
	if (len < 0.0)
		len = 0.0;
	p[0] *= len;
	p[1] *= len;
	p[2] *= len;
}

// PM_CheckParameters (move clamp, punch, angles), PM_Duck move multiplier (applied after the
// clamp, PM_Duck runs later in PM_PlayerMove) + the wishdir part of PM_WalkMove/PM_AirMove
stock fog_wish(const Float:viewang[3], Float:pun[3], const Float:vel[3], Float:fm, Float:sm, Float:um,
	Float:maxspd, Float:dt, Float:mult, Float:wishdir[3], &Float:wishspeed)
{
	new Float:spd = floatsqroot(sm * sm + fm * fm + um * um);
	if (spd != 0.0 && spd > maxspd)
	{
		new Float:ratio = maxspd / spd;
		fm *= ratio;
		sm *= ratio;
	}
	fm *= mult;
	sm *= mult;
	fog_drop_punch(pun, dt);

	new Float:va[3], Float:pm[3];
	va[0] = viewang[0] + pun[0];
	va[1] = viewang[1] + pun[1];
	va[2] = viewang[2] + pun[2];
	pm[2] = fog_calc_roll(va, vel, mv_rollangle, mv_rollspeed) * 4.0;
	pm[0] = va[0];
	pm[1] = va[1];

	new Float:f[3], Float:r[3];
	fog_angle_vectors(pm, f, r);
	f[2] = 0.0;
	r[2] = 0.0;
	fog_normalize(f);
	fog_normalize(r);

	wishdir[0] = f[0] * fm + r[0] * sm;
	wishdir[1] = f[1] * fm + r[1] * sm;
	wishdir[2] = 0.0;
	wishspeed = fog_normalize(wishdir);
	if (wishspeed > maxspd)
		wishspeed = maxspd;
}

stock Float:fog_normalize(Float:v[3])
{
	new Float:len = floatsqroot(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
	if (len != 0.0)
	{
		v[0] /= len;
		v[1] /= len;
		v[2] /= len;
	}
	return len;
}

stock Float:fog_len2(const Float:v[3])
{
	return floatsqroot(v[0] * v[0] + v[1] * v[1]);
}

// =============================================================================================
// Debug output. Log lines are key=value so fog_reference.py can parse them.

fog_out(id, bool:toConsole, const line[])
{
	log_to_file(g_szLogFile, "%s", line);
	if (toConsole && is_user_connected(id))
		console_print(id, "%s", line);
}

fog_warn(id, const msg[])
{
	if (!get_pcvar_num(g_pDebug))
		return;
	new line[256];
	formatex(line, charsmax(line), "FOGW id=%d f=%d %s", id, g_iGround[id], msg);
	fog_out(id, true, line);
}

fog_log_movevars()
{
	log_to_file(g_szLogFile, "FOGC friction=%.4f stopspeed=%.4f edgefriction=%.4f accelerate=%.4f airaccelerate=%.4f gravity=%.4f maxspeed=%.4f rollangle=%.4f rollspeed=%.4f fog_max=%d fix_vz=%d",
		mv_friction, mv_stopspeed, mv_edgefriction, mv_accelerate, mv_airaccelerate, mv_gravity, mv_maxspeed,
		mv_rollangle, mv_rollspeed, clamp(get_pcvar_num(g_pMax), 1, MAX_FOG), get_pcvar_num(g_pFixVz));
}

fog_log_frame(id, c, bool:air)
{
	new line[640];
	formatex(line, charsmax(line), "FOGF id=%d f=%d ms=%d act=%s vpre=%.4f,%.4f,%.4f fu=%.4f fur=%.4f fm=%.3f sm=%.3f um=%.3f ang=%.4f,%.4f,%.4f pun=%.4f,%.4f,%.4f mxs=%.3f g=%.4f pf=%.4f edge=%d ds=%d dm=%.3f why=%s org=%.3f,%.3f,%.3f vset=%.4f,%.4f,%.4f vpost=%.4f,%.4f,%.4f fupost=%.4f air=%d",
		id, c, r_msec[id][c], g_szAct[r_act[id][c]],
		r_vPre[id][c][0], r_vPre[id][c][1], r_vPre[id][c][2],
		r_fuPre[id][c], r_fuRed[id][c],
		r_fm[id][c], r_sm[id][c], r_um[id][c],
		r_ang[id][c][0], r_ang[id][c][1], r_ang[id][c][2],
		r_pun[id][c][0], r_pun[id][c][1], r_pun[id][c][2],
		r_maxspd[id][c], r_grav[id][c], r_pfric[id][c], r_edge[id][c],
		r_ds[id][c], r_mult[id][c], g_szWhy[r_why[id][c]],
		r_org[id][c][0], r_org[id][c][1], r_org[id][c][2],
		r_vSet[id][c][0], r_vSet[id][c][1], r_vSet[id][c][2],
		r_vPost[id][c][0], r_vPost[id][c][1], r_vPost[id][c][2],
		r_fuPost[id][c], air ? 1 : 0);
	log_to_file(g_szLogFile, "%s", line);
	if (get_pcvar_num(g_pDebug) >= 2 && is_user_connected(id))
		console_print(id, "FOGF f=%d %s v=%.2f->%.2f fu=%.1f", c, g_szAct[r_act[id][c]], fog_len2(r_vPre[id][c]), fog_len2(r_vPost[id][c]), r_fuRed[id][c]);
}

fog_log_jump(id, c, act, const Float:vel[3])
{
	new fus[64], cands[64], mode[40];
	new n = (c < REC - 1) ? c : REC - 1;
	for (new m = 1; m <= n; m++)
		format(fus, charsmax(fus), "%s%s%.1f", fus, (m > 1) ? "/" : "", r_fuRed[id][m]);

	if (g_bEvaluated[id])
	{
		formatex(cands, charsmax(cands), "%.2f/%.2f/%.2f", g_fCand[id][1], g_fCand[id][2], g_fCand[id][3]);
		if (act == ACT_EMULATE)
		{
			if (g_iSource[id] < c)
				formatex(mode, charsmax(mode), "rewrite(%d)", g_iSource[id]);
			else
				copy(mode, charsmax(mode), "delay(emul)");
		}
		else
			copy(mode, charsmax(mode), (c > g_iPressFrame[id]) ? "delay" : "now");
	}
	else
	{
		copy(cands, charsmax(cands), "-");
		formatex(mode, charsmax(mode), "untouched(%s)", g_szWhy[g_iWhyPress[id]]);
	}

	new line[400];
	formatex(line, charsmax(line), "FOGJ id=%d press=%d fog=%d src=%d land=%.2f fu=%s cand=%s dec=%s mode=%s xy=%.3f vz=%.3f",
		id, g_iPressFrame[id], c, (act == ACT_EMULATE) ? g_iSource[id] : c, g_fLand[id], fus, cands,
		g_szDec[id][0] ? g_szDec[id] : "-", mode, fog_len2(vel), vel[2]);
	log_to_file(g_szLogFile, "%s", line);

	if (is_user_connected(id))
		console_print(id, "[FOG] press f%d -> FOG %d (src %d) land %.1f cand %s %s -> xy %.2f vz %.2f",
			g_iPressFrame[id], c, (act == ACT_EMULATE) ? g_iSource[id] : c, g_fLand[id], cands, mode, fog_len2(vel), vel[2]);
}
