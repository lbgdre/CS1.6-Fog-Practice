/*
 * speed_hud.sma - standalone speedometer + takeoff speed + FOG.
 *
 * Credit: the HUD layout (centered DHUD at y 0.7, speed / (takeoff speed) / FOG: n, 0.02 hold,
 * FOG shown up to 8) follows the speed panel of gcljs by GameChaos
 * (https://bitbucket.org/GameChaos/gcljs). No gcljs code is used; the detection logic is new.
 *
 * Layout:
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
 *   D: n     = on a bhop takeoff (FOG shown): length of your last continuous duck in the air
 *              before the landing that this jump came from, in usercmds (msec > 0) with IN_DUCK
 *              held; the landing usercmd counts as an air frame (it starts in the air).
 *              In the air PM_Duck completes a duck immediately (pm_shared.cpp PM_Duck: "Finish
 *              ducking immediately if ... not on ground"), so IN_DUCK held == ducked there.
 *              0 = you did not duck in the air before that landing.
 */

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>

#pragma semicolon 1

#define PLUGIN_NAME     "Speed HUD"
#define PLUGIN_VERSION  "1.3.0"
#define PLUGIN_AUTHOR   "local"

#define MAXP            33
// DHUD (director) messages are STACK-based, not channel-based (amxmodx.inc, show_dhudmessage:
// "You can have up to 8 messages displaying at once"): a new one never replaces the old one.
#define HUD_INTERVAL    0.01    // big-font redraw interval (v1.0.0 / gcljs timing)

new g_pEnable, g_pX, g_pY, g_pColor, g_pFogMax, g_pKeep, g_pHold, g_pFogMode, g_pDebug, g_pShowDuck, g_pStyle;
new g_hSync;

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
new bool:g_bPreInDuck[MAXP];    // pev->bInDuck at FM_CmdStart (duck in transition)
new bool:g_bTakeoffDD[MAXP];    // the shown takeoff is a double-duck lift
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
	g_pHold    = create_cvar("speed_hud_hold", "0.02", FCVAR_NONE, "Big-font (DHUD) hold time; redraw is every usercmd (gcljs / v1.0.0: 0.02)", true, 0.01, true, 1.0);
	g_pStyle   = create_cvar("speed_hud_style", "0", FCVAR_NONE, "0 = big font (DHUD), 1 = normal HUD font (redraws every usercmd, never overlaps)", true, 0.0, true, 1.0);
	g_hSync    = CreateHudSyncObj();
	g_pFogMode = create_cvar("speed_hud_fog_mode", "1", FCVAR_NONE, "1 = FOG whose speed you got (fog_practice src), 0 = frame you left the ground on", true, 0.0, true, 1.0);
	g_pDebug   = create_cvar("speed_hud_debug", "0", FCVAR_NONE, "1 = log each takeoff (SPDJ) to addons/amxmodx/logs/fog_debug.log", true, 0.0, true, 1.0);
	g_pShowDuck = create_cvar("speed_hud_duck", "1", FCVAR_NONE, "1 = show D: frames ducked in the air before the landing", true, 0.0, true, 1.0);

	register_forward(FM_CmdStart, "fw_CmdStart", 0);
	register_forward(FM_CmdEnd, "fw_CmdEnd_Post", 1);

	register_clcmd("say /speedhud", "cmd_toggle");
	register_clcmd("say_team /speedhud", "cmd_toggle");
	register_clcmd("speedhud", "cmd_toggle");
	register_clcmd("say /speedmenu", "cmd_speedmenu");
	register_clcmd("say_team /speedmenu", "cmd_speedmenu");
	register_clcmd("speedmenu", "cmd_speedmenu");
}

public plugin_cfg()
{
	// settings saved by /speedmenu
	new path[128];
	speed_cfg_path(path, charsmax(path));
	if (file_exists(path))
	{
		server_cmd("exec ^"%s^"", path);
		server_exec();
	}
}

// =============================================================================================
// /speedmenu. "My HUD" is per player; the rest are server-wide cvars and need ADMIN_CVAR
// (the listen-server host has it). Saved to addons/amxmodx/configs/speed_hud.cfg.
enum
{
	SM_ITEM_ENABLE = 1, SM_ITEM_FOGMODE, SM_ITEM_DUCK, SM_ITEM_COLOR, SM_ITEM_Y, SM_ITEM_X,
	SM_ITEM_FOGMAX, SM_ITEM_DEBUG
};

new const g_szColorName[][] = { "white", "green", "yellow", "cyan", "orange", "red", "pink" };
new const g_szColorRGB[][]  = { "255 255 255", "0 255 0", "255 255 0", "0 255 255", "255 128 0", "255 0 0", "255 105 180" };
#define Y_MIN   0.55
#define Y_MAX   0.85
#define Y_STEP  0.05
new const Float:g_fXSteps[] = { -1.0, 0.05, 0.75 };
new const g_szXName[][]     = { "center", "left", "right" };
new const g_iFogMaxSteps[]  = { 3, 5, 8, 10 };

public cmd_speedmenu(id)
{
	speed_menu_show(id, 0);
	return PLUGIN_HANDLED;
}

speed_color_index()
{
	new color[16];
	get_pcvar_string(g_pColor, color, charsmax(color));
	for (new i = 0; i < sizeof(g_szColorRGB); i++)
		if (equal(color, g_szColorRGB[i]))
			return i;
	return -1;
}

speed_x_index()
{
	new Float:x = get_pcvar_float(g_pX);
	for (new i = 0; i < sizeof(g_fXSteps); i++)
		if (floatabs(x - g_fXSteps[i]) < 0.001)
			return i;
	return -1;
}

speed_menu_show(id, page)
{
	new title[128];
	formatex(title, charsmax(title), "\ySpeed HUD \dv%s", PLUGIN_VERSION);
	new menu = menu_create(title, "speed_menu_handler");
	new item[96], info[4];
	new ci = speed_color_index();
	new xi = speed_x_index();

	formatex(item, charsmax(item), "HUD: %s", get_pcvar_num(g_pEnable) ? "\yON" : "\rOFF");
	num_to_str(SM_ITEM_ENABLE, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "FOG shows: \y%s", get_pcvar_num(g_pFogMode) ? "frame of your speed" : "frame you left on");
	num_to_str(SM_ITEM_FOGMODE, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Duck in air: %s", get_pcvar_num(g_pShowDuck) ? "\yON" : "\rOFF");
	num_to_str(SM_ITEM_DUCK, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Color: \y%s", (ci >= 0) ? g_szColorName[ci] : "custom");
	num_to_str(SM_ITEM_COLOR, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	new ynum[16];
	speed_fmt3(get_pcvar_float(g_pY), ynum, charsmax(ynum));
	ynum[4] = 0;    // "0.700" -> "0.70"
	formatex(item, charsmax(item), "Height: \y%s", ynum);
	num_to_str(SM_ITEM_Y, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Horizontal: \y%s", (xi >= 0) ? g_szXName[xi] : "custom");
	num_to_str(SM_ITEM_X, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Show FOG up to: \y%d", get_pcvar_num(g_pFogMax));
	num_to_str(SM_ITEM_FOGMAX, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	formatex(item, charsmax(item), "Debug log: %s", get_pcvar_num(g_pDebug) ? "\yON" : "\rOFF");
	num_to_str(SM_ITEM_DEBUG, info, charsmax(info));
	menu_additem(menu, item, info, ADMIN_CVAR);

	menu_setprop(menu, MPROP_EXIT, MEXIT_ALL);
	menu_display(id, menu, page);
}

public speed_menu_handler(id, menu, item)
{
	if (item == MENU_EXIT || item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}

	new info[4], access, callback;
	menu_item_getinfo(menu, item, access, info, charsmax(info), _, _, callback);
	menu_destroy(menu);
	new page = item / 7;     // newmenus default: 7 items per page

	if (access && !(get_user_flags(id) & access))
	{
		client_print(id, print_chat, "[Speed HUD] You need cvar access to change server-wide settings.");
		speed_menu_show(id, page);
		return PLUGIN_HANDLED;
	}

	new bool:save = true;
	switch (str_to_num(info))
	{
		case SM_ITEM_ENABLE:  set_pcvar_num(g_pEnable, get_pcvar_num(g_pEnable) ? 0 : 1);
		case SM_ITEM_FOGMODE: set_pcvar_num(g_pFogMode, get_pcvar_num(g_pFogMode) ? 0 : 1);
		case SM_ITEM_DUCK:    set_pcvar_num(g_pShowDuck, get_pcvar_num(g_pShowDuck) ? 0 : 1);
		case SM_ITEM_COLOR:
		{
			new ci = speed_color_index();
			set_pcvar_string(g_pColor, g_szColorRGB[(ci + 1) % sizeof(g_szColorRGB)]);
		}
		case SM_ITEM_Y:
		{
			// next 0.05 step above the current value, wrapping 0.85 -> 0.55
			new Float:y = get_pcvar_float(g_pY);
			// +0.01 tolerance: 0.70 is stored as 0.6999.., a plain floor would stay on 0.70
			new k = floatround((y - Y_MIN) / Y_STEP + 0.01, floatround_floor) + 1;
			new Float:next = Y_MIN + float(k) * Y_STEP;
			if (next < Y_MIN || next > Y_MAX + 0.001)
				next = Y_MIN;
			set_pcvar_float(g_pY, next);
		}
		case SM_ITEM_X:
		{
			new xi = speed_x_index();
			set_pcvar_float(g_pX, g_fXSteps[(xi + 1) % sizeof(g_fXSteps)]);
		}
		case SM_ITEM_FOGMAX:
		{
			new cur = get_pcvar_num(g_pFogMax);
			new next = g_iFogMaxSteps[0];
			for (new i = 0; i < sizeof(g_iFogMaxSteps); i++)
			{
				if (g_iFogMaxSteps[i] > cur)
				{
					next = g_iFogMaxSteps[i];
					break;
				}
			}
			set_pcvar_num(g_pFogMax, next);
		}
		case SM_ITEM_DEBUG:   set_pcvar_num(g_pDebug, get_pcvar_num(g_pDebug) ? 0 : 1);
	}
	if (save)
		speed_save_cfg();
	speed_menu_show(id, page);
	return PLUGIN_HANDLED;
}

speed_cfg_path(path[], len)
{
	get_configsdir(path, len);
	add(path, len, "/speed_hud.cfg");
}

speed_save_cfg()
{
	new path[128], color[16];
	speed_cfg_path(path, charsmax(path));
	new f = fopen(path, "wt");
	if (!f)
		return;
	get_pcvar_string(g_pColor, color, charsmax(color));
	fprintf(f, "// speed_hud settings - written by /speedmenu, exec'd on map start. Delete to reset.^n");
	fprintf(f, "speed_hud_enable %d^n", get_pcvar_num(g_pEnable));
	fprintf(f, "speed_hud_fog_mode %d^n", get_pcvar_num(g_pFogMode));
	fprintf(f, "speed_hud_duck %d^n", get_pcvar_num(g_pShowDuck));
	fprintf(f, "speed_hud_keep %d^n", get_pcvar_num(g_pKeep));
	fprintf(f, "speed_hud_color ^"%s^"^n", color);
	new num[16];
	speed_fmt3(get_pcvar_float(g_pX), num, charsmax(num));
	fprintf(f, "speed_hud_x %s^n", num);
	speed_fmt3(get_pcvar_float(g_pY), num, charsmax(num));
	fprintf(f, "speed_hud_y %s^n", num);
	fprintf(f, "speed_hud_fog_max %d^n", get_pcvar_num(g_pFogMax));
	speed_fmt3(get_pcvar_float(g_pHold), num, charsmax(num));
	fprintf(f, "speed_hud_hold %s^n", num);
	fprintf(f, "speed_hud_style %d^n", get_pcvar_num(g_pStyle));
	fprintf(f, "speed_hud_debug %d^n", get_pcvar_num(g_pDebug));
	fclose(f);
}

// AMXX's "%.2f" truncates (0.70 is stored as 0.6999.. and printed "0.69"), so round to
// 3 decimals ourselves.
speed_fmt3(Float:v, out[], len)
{
	new m = floatround(v * 1000.0);
	new sign[2];
	if (m < 0)
	{
		sign[0] = '-';
		m = -m;
	}
	formatex(out, len, "%s%d.%03d", sign, m / 1000, m % 1000);
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
	g_bPreInDuck[id] = false;
	g_bTakeoffDD[id] = false;
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
	g_bPreInDuck[id] = pev(id, pev_bInDuck) != 0;
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

		// double-duck lift (pm_shared.cpp PM_Duck -> PM_UnDuck, stock path): the duck press left
		// bInDuck set without FL_DUCKING, and this usercmd releases duck on ground -> origin +18,
		// airborne for the whole frame. It ends with vz < 0 (gravity), so it is not a "vz > 0" jump.
		new bool:ddLift = g_bPreInDuck[id] && !(g_iPreFlags[id] & FL_DUCKING) && !(g_iButtons[id] & IN_DUCK);

		if (!postGround && postMovetype == MOVETYPE_WALK && (vel[2] > 0.0 || ddLift))
		{
			// takeoff: PM_Jump / an emulated takeoff (vz > 0) or a DD lift
			g_bTakeoffDD[id] = (vel[2] <= 0.0);
			g_fTakeoff[id] = floatsqroot(vel[0] * vel[0] + vel[1] * vel[1]);
			g_iTakeoffFog[id] = (g_iGround[id] > 0) ? g_iGround[id] : 1;
			g_iTakeoffSrc[id] = speed_fog_source(id);
			g_iTakeoffDuck[id] = g_iLandDuck[id];
			g_iLandDuck[id] = -1;
			g_bShowTakeoff[id] = true;
			if (get_pcvar_num(g_pDebug))
				log_to_file("fog_debug.log", "SPDJ id=%d fog=%d src=%d dd=%d duck=%d xy=%.3f vz=%.3f",
					id, g_iTakeoffFog[id], g_iTakeoffSrc[id], g_bTakeoffDD[id] ? 1 : 0, g_iTakeoffDuck[id], g_fTakeoff[id], vel[2]);
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
			g_bTakeoffDD[id] = false;
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

	// style 0 (big DHUD): same timing as v1.0.0 / gcljs, which looked right in game: redraw at most
	// every HUD_INTERVAL (10 ms = every usercmd at 100 fps) with holdtime speed_hud_hold (0.02).
	// A hold equal to the refresh (0.01/0.01) flickers and doubles: the 10 ms server updates drift
	// against the client's frames (fps_max 99.5 = 10.05 ms), so a 1-frame message is shown 0 or 2
	// times. style 1 (normal HUD font): channel-based, every message replaces the previous one.
	new bool:dhud = (get_pcvar_num(g_pStyle) == 0);
	new Float:hold = dhud ? get_pcvar_float(g_pHold) : 0.1;
	new Float:now = get_gametime();
	if (dhud)
	{
		if (now < g_fNextHud[id] && now > g_fNextHud[id] - 1.0)
			return;
		g_fNextHud[id] = now + HUD_INTERVAL;
	}

	new text[96];
	formatex(text, charsmax(text), "%d", floatround(floatsqroot(vel[0] * vel[0] + vel[1] * vel[1])));
	if (g_bShowTakeoff[id])
	{
		new fog = g_iTakeoffFog[id];
		new src = g_iTakeoffSrc[id];
		if (fog >= 0 && fog <= get_pcvar_num(g_pFogMax))
		{
			if (get_pcvar_num(g_pFogMode) && src > 0 && src != fog)
				format(text, charsmax(text), "%s^n(%.2f)^n%sFOG: %d (f%d)", text, g_fTakeoff[id], g_bTakeoffDD[id] ? "DD " : "", src, fog);
			else
				format(text, charsmax(text), "%s^n(%.2f)^n%sFOG: %d", text, g_fTakeoff[id], g_bTakeoffDD[id] ? "DD " : "", fog);
			if (g_iTakeoffDuck[id] >= 0 && get_pcvar_num(g_pShowDuck))
				format(text, charsmax(text), "%s^nD: %d", text, g_iTakeoffDuck[id]);
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

	// the player, plus spectators in first-person / chase on this player (pev_iuser2 == id)
	for (new viewer = 1; viewer < MAXP; viewer++)
	{
		if (!is_user_connected(viewer) || is_user_bot(viewer) || !g_bOn[viewer])
			continue;
		if (viewer != id && (is_user_alive(viewer) || pev(viewer, pev_iuser2) != id))
			continue;
		if (dhud)
		{
			set_dhudmessage(r, g, b, x, y, 0, 0.0, hold, 0.0, 0.0);
			show_dhudmessage(viewer, "%s", text);
		}
		else
		{
			set_hudmessage(r, g, b, x, y, 0, 0.0, hold, 0.0, 0.0, -1);
			ShowSyncHudMsg(viewer, g_hSync, "%s", text);
		}
	}
}
