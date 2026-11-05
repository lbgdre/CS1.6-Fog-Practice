/*
 * speed_hud.sma - standalone speedometer + takeoff speed + FOG, layout after gcljs's speed panel:
 *
 *        312              <- current horizontal speed (integer)
 *      (261.30)           <- takeoff speed of the current jump (shown while airborne)
 *       FOG: 2            <- FOG of that takeoff (shown if <= speed_hud_fog_max)
 *
 * Independent of fog_practice.amxx and of any KZ / jumpstats plugin; stock fakemeta only.
 * speed_hud itself only displays; it does not change movement. But the speeds/FOG it shows while
 * fog_practice is enabled come from altered physics and are NOT legit for records.
 *
 * Why it does not break with fog_practice: jumpstats-style plugins detect a jump from the BUTTON
 * PRESS in PlayerPreThink (IN_JUMP && !oldbuttons on ground) and take the previous frame's
 * velocity as prespeed. fog_practice can move the takeoff to a later frame or replace the takeoff
 * velocity, so press frame != takeoff frame. This plugin instead reads the OUTCOME of each usercmd
 * in FM_CmdEnd (post), which runs after PM_Move / SV_FinishPMove / PlayerPostThink
 * (ReHLDS rehlds/engine/sv_user.cpp SV_RunCmd):
 *   takeoff  = the usercmd started on ground (FL_ONGROUND, MOVETYPE_WALK at FM_CmdStart)
 *              and ended in the air with vz > 0 (PM_Jump gives vz ~200-260; a ledge drop gives
 *              vz <= 0 because of gravity)
 *   takeoff speed = horizontal speed at the end of that usercmd, i.e. what you actually leave the
 *              ground with: after PM_PreventMegaBunnyJumping and that frame's PM_AirMove.
 *   takeoff frame = usercmds (msec > 0) that started on ground, landing -> takeoff, takeoff
 *              included; same counting as fog_practice.
 *   FOG shown = with fog_practice loaded and speed_hud_fog_mode 1 (default): the frame whose
 *              speed you got (fog_practice's "src"). A backward rewrite keeps the takeoff on the
 *              frame you pressed but gives you an earlier frame's speed; then the HUD shows
 *              "FOG: 2 (f3)" = speed of FOG 2, left the ground on frame 3. Queried with
 *              callfunc("fog_api_src", "fog_practice.amxx"); without fog_practice it falls back to
 *              the takeoff frame.
 *   ladder jump = started on a ladder (MOVETYPE_FLY), ended walking in the air with IN_JUMP held;
 *              shown without FOG (like gcljs).
 *   DUCK: n  = on a bhop takeoff (FOG shown): length of your last continuous duck in the air
 *              before the landing that this jump came from, in usercmds (msec > 0) with IN_DUCK
 *              held; the landing usercmd counts as an air frame (it starts in the air).
 *              In the air PM_Duck completes a duck immediately (pm_shared.cpp PM_Duck: "Finish
 *              ducking immediately if ... not on ground"), so IN_DUCK held == ducked there.
 *              0 = you did not duck in the air before that landing.
 */

#include <amxmodx>
#include <fakemeta>

#pragma semicolon 1

#define PLUGIN_NAME     "Speed HUD"
#define PLUGIN_VERSION  "1.2.0"
#define PLUGIN_AUTHOR   "local"

#define MAXP            33
#define HUD_INTERVAL    0.01    // at most one update per 10 ms per viewed player

new g_pEnable, g_pX, g_pY, g_pColor, g_pFogMax, g_pKeep, g_pHold, g_pFogMode, g_pDebug, g_pShowDuck;

new bool:g_bOn[MAXP];
new bool:g_bArmed[MAXP];
new g_iMsec[MAXP], g_iButtons[MAXP], g_iPreFlags[MAXP], g_iPreMovetype[MAXP];

new g_iGround[MAXP];
new bool:g_bShowTakeoff[MAXP];
new Float:g_fTakeoff[MAXP];
new g_iTakeoffFog[MAXP];        // takeoff frame; -1 = ladder jump / no FOG
new g_iTakeoffSrc[MAXP];        // fog_practice source frame; 0 = unknown
new Float:g_fNextHud[MAXP];

new g_iDuckRun[MAXP];           // current/last continuous ducked run in this air phase
new bool:g_bPrevAirDuck[MAXP];  // previous air usercmd had IN_DUCK
new g_iLandDuck[MAXP];          // g_iDuckRun at the last landing; -1 = no landing to report
new g_iTakeoffDuck[MAXP];       // value shown for the current jump; -1 = none

public plugin_init()
{
	register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

	g_pEnable  = create_cvar("speed_hud_enable", "1", FCVAR_NONE, "Enable the speed HUD", true, 0.0, true, 1.0);
	g_pX       = create_cvar("speed_hud_x", "-1.0", FCVAR_NONE, "HUD x (-1 = centered)", true, -1.0, true, 1.0);
	g_pY       = create_cvar("speed_hud_y", "0.7", FCVAR_NONE, "HUD y (0-1)", true, -1.0, true, 1.0);
	g_pColor   = create_cvar("speed_hud_color", "255 255 255", FCVAR_NONE, "HUD color R G B");
	g_pFogMax  = create_cvar("speed_hud_fog_max", "8", FCVAR_NONE, "Show FOG only when <= this (gcljs MAX_BHOP_FRAMES = 8)", true, 0.0, true, 1000.0);
	g_pKeep    = create_cvar("speed_hud_keep", "0", FCVAR_NONE, "1 = keep the last takeoff speed after landing", true, 0.0, true, 1.0);
	g_pHold    = create_cvar("speed_hud_hold", "0.02", FCVAR_NONE, "DHUD hold time per update (gcljs uses 0.02)", true, 0.01, true, 1.0);
	g_pFogMode = create_cvar("speed_hud_fog_mode", "1", FCVAR_NONE, "1 = FOG whose speed you got (fog_practice src), 0 = frame you left the ground on", true, 0.0, true, 1.0);
	g_pDebug   = create_cvar("speed_hud_debug", "0", FCVAR_NONE, "1 = log each takeoff (SPDJ) to addons/amxmodx/logs/fog_debug.log", true, 0.0, true, 1.0);
	g_pShowDuck = create_cvar("speed_hud_duck", "1", FCVAR_NONE, "1 = show DUCK: frames ducked in the air before the landing", true, 0.0, true, 1.0);

	register_forward(FM_CmdStart, "fw_CmdStart", 0);
	register_forward(FM_CmdEnd, "fw_CmdEnd_Post", 1);

	register_clcmd("say /speedhud", "cmd_toggle");
	register_clcmd("say_team /speedhud", "cmd_toggle");
	register_clcmd("speedhud", "cmd_toggle");
}

public client_putinserver(id)
{
	g_bOn[id] = true;
	speed_reset(id);
}

public client_disconnected(id)
{
	g_bOn[id] = false;
	speed_reset(id);
}

speed_reset(id)
{
	g_bArmed[id] = false;
	g_iGround[id] = 0;
	g_bShowTakeoff[id] = false;
	g_fTakeoff[id] = 0.0;
	g_iTakeoffFog[id] = -1;
	g_iTakeoffSrc[id] = 0;
	g_fNextHud[id] = 0.0;
	g_iDuckRun[id] = 0;
	g_bPrevAirDuck[id] = false;
	g_iLandDuck[id] = -1;
	g_iTakeoffDuck[id] = -1;
}

public cmd_toggle(id)
{
	g_bOn[id] = !g_bOn[id];
	client_print(id, print_chat, "[Speed HUD] %s", g_bOn[id] ? "ON" : "OFF");
	return PLUGIN_HANDLED;
}

// Snapshot the pre-move state: flags/movetype here are the previous PM_Move's result.
public fw_CmdStart(id, uc_handle)
{
	if (id < 1 || id >= MAXP)
		return FMRES_IGNORED;
	if (!is_user_alive(id) || is_user_bot(id))
	{
		g_bArmed[id] = false;
		return FMRES_IGNORED;
	}
	g_bArmed[id] = true;
	g_iMsec[id] = get_uc(uc_handle, UC_Msec);
	g_iButtons[id] = get_uc(uc_handle, UC_Buttons);
	g_iPreFlags[id] = pev(id, pev_flags);
	g_iPreMovetype[id] = pev(id, pev_movetype);
	return FMRES_IGNORED;
}

// Outcome of the usercmd: after PM_Move, SV_FinishPMove and PlayerPostThink.
public fw_CmdEnd_Post(id)
{
	if (id < 1 || id >= MAXP || !g_bArmed[id])
		return FMRES_IGNORED;
	g_bArmed[id] = false;

	new Float:vel[3];
	pev(id, pev_velocity, vel);
	new postFlags = pev(id, pev_flags);
	new postMovetype = pev(id, pev_movetype);

	new bool:preGround = (g_iPreFlags[id] & FL_ONGROUND) && g_iPreMovetype[id] == MOVETYPE_WALK;
	new bool:postGround = (postFlags & FL_ONGROUND) != 0;

	if (preGround)
	{
		if (g_iMsec[id] > 0 && g_iGround[id] < 100000)
			g_iGround[id]++;

		if (!postGround && postMovetype == MOVETYPE_WALK && vel[2] > 0.0)
		{
			// takeoff (PM_Jump or an emulated takeoff)
			g_fTakeoff[id] = floatsqroot(vel[0] * vel[0] + vel[1] * vel[1]);
			g_iTakeoffFog[id] = (g_iGround[id] > 0) ? g_iGround[id] : 1;
			g_iTakeoffSrc[id] = speed_fog_source(id);
			g_iTakeoffDuck[id] = g_iLandDuck[id];
			g_iLandDuck[id] = -1;
			g_bShowTakeoff[id] = true;
			if (get_pcvar_num(g_pDebug))
				log_to_file("fog_debug.log", "SPDJ id=%d fog=%d src=%d duck=%d xy=%.3f vz=%.3f",
					id, g_iTakeoffFog[id], g_iTakeoffSrc[id], g_iTakeoffDuck[id], g_fTakeoff[id], vel[2]);
		}
	}
	else
	{
		// air usercmd (includes the one in which you land): track the last continuous duck run
		if (g_iPreMovetype[id] == MOVETYPE_WALK && g_iMsec[id] > 0)
		{
			if (g_iButtons[id] & IN_DUCK)
			{
				if (!g_bPrevAirDuck[id])
					g_iDuckRun[id] = 0;
				g_iDuckRun[id]++;
				g_bPrevAirDuck[id] = true;
			}
			else
				g_bPrevAirDuck[id] = false;
		}
		if (postGround)
		{
			g_iLandDuck[id] = g_iDuckRun[id];
			g_iDuckRun[id] = 0;
			g_bPrevAirDuck[id] = false;
		}

		if (g_iPreMovetype[id] == MOVETYPE_FLY && postMovetype == MOVETYPE_WALK && !postGround
			&& (g_iButtons[id] & IN_JUMP))
		{
			// ladder jump: no FOG
			g_fTakeoff[id] = floatsqroot(vel[0] * vel[0] + vel[1] * vel[1]);
			g_iTakeoffFog[id] = -1;
			g_iTakeoffSrc[id] = 0;
			g_iTakeoffDuck[id] = -1;
			g_bShowTakeoff[id] = true;
		}
		else if (postGround && !get_pcvar_num(g_pKeep))
		{
			// landed
			g_bShowTakeoff[id] = false;
		}
	}

	if (!postGround)
		g_iGround[id] = 0;

	speed_draw(id, vel);
	return FMRES_IGNORED;
}

// fog_practice's source frame for this usercmd's takeoff, or 0 if fog_practice is not loaded /
// did not plan this takeoff. callfunc_begin: 1 = ok, 0 = function not found, -1 = plugin not found.
speed_fog_source(id)
{
	if (callfunc_begin("fog_api_src", "fog_practice.amxx") != 1)
		return 0;
	callfunc_push_int(id);
	return callfunc_end();
}

speed_draw(id, const Float:vel[3])
{
	if (!get_pcvar_num(g_pEnable))
		return;

	new Float:now = get_gametime();
	if (now < g_fNextHud[id] && now > g_fNextHud[id] - 1.0)
		return;
	g_fNextHud[id] = now + HUD_INTERVAL;

	new text[96];
	formatex(text, charsmax(text), "%d", floatround(floatsqroot(vel[0] * vel[0] + vel[1] * vel[1])));
	if (g_bShowTakeoff[id])
	{
		new fog = g_iTakeoffFog[id];
		new src = g_iTakeoffSrc[id];
		if (fog >= 0 && fog <= get_pcvar_num(g_pFogMax))
		{
			if (get_pcvar_num(g_pFogMode) && src > 0 && src != fog)
				format(text, charsmax(text), "%s^n(%.2f)^nFOG: %d (f%d)", text, g_fTakeoff[id], src, fog);
			else
				format(text, charsmax(text), "%s^n(%.2f)^nFOG: %d", text, g_fTakeoff[id], fog);
			if (g_iTakeoffDuck[id] >= 0 && get_pcvar_num(g_pShowDuck))
				format(text, charsmax(text), "%s^nDUCK: %d", text, g_iTakeoffDuck[id]);
		}
		else
			format(text, charsmax(text), "%s^n(%.2f)", text, g_fTakeoff[id]);
	}

	new color[16], rgb[3][4];
	get_pcvar_string(g_pColor, color, charsmax(color));
	parse(color, rgb[0], charsmax(rgb[]), rgb[1], charsmax(rgb[]), rgb[2], charsmax(rgb[]));
	new r = clamp(str_to_num(rgb[0]), 0, 255);
	new g = clamp(str_to_num(rgb[1]), 0, 255);
	new b = clamp(str_to_num(rgb[2]), 0, 255);
	new Float:x = get_pcvar_float(g_pX);
	new Float:y = get_pcvar_float(g_pY);
	new Float:hold = get_pcvar_float(g_pHold);

	// the player, plus spectators in first-person / chase on this player (pev_iuser2 == id)
	for (new viewer = 1; viewer < MAXP; viewer++)
	{
		if (!is_user_connected(viewer) || is_user_bot(viewer) || !g_bOn[viewer])
			continue;
		if (viewer != id && (is_user_alive(viewer) || pev(viewer, pev_iuser2) != id))
			continue;
		set_dhudmessage(r, g, b, x, y, 0, 0.0, hold, 0.0, 0.0);
		show_dhudmessage(viewer, "%s", text);
	}
}
