--[[
	SpinDrive — RoF-buff engine.

	Responsible for:
	  - PlayerManager:Get/Set_Rof_Buff_Addon (global multiplier, as in the
	    original RoFBuffMod-Stable, but generic for all profiles registered
	    with SpinDrive)
	  - Coupling the RoF buff to the actual spin speed (spindrive_spin.lua)
	    instead of a second independent ramp like the original RoFBuffMod.
	    That avoided two slightly different "how fast is the weapon spinning"
	    states that could drift apart (bug GatMalite already had: single-fire
	    never built the RofB_* ramp because it only keyed off _shooting).
	  - fire_rate_multiplier() wrapping per weapon instance (idempotent).
	  - Optional accuracy bonus (spread multiplier) via profile.accuracy
	    from get_tuning().

	This module fully replaces playermanager.lua + playerstandard.lua from
	the old RoFBuffMod-Stable. If RoFBuffMod-Stable is still installed
	separately, it would compete with this module for Get/Set_Rof_Buff_Addon —
	see the compat check below.
--]]

local SpinDrive = _G.SpinDrive
if not SpinDrive then
	-- Load order between different hook_id files (here: playermanager vs.
	-- raycastweaponbase) is determined by the engine, not by the order in
	-- mod.txt. Instead of hard-aborting, minimally initialize and continue —
	-- spindrive_core.lua does not overwrite on its own load (uses
	-- "SpinDrive = SpinDrive or {}"), so the real registry/debug setup
	-- will still be established either way.
	_G.SpinDrive = _G.SpinDrive or {}
	SpinDrive = _G.SpinDrive
	SpinDrive.resolve = SpinDrive.resolve or function() return nil, nil end
	SpinDrive.is_active = SpinDrive.is_active or function() return false end
	SpinDrive.get_spin_speed_fraction = SpinDrive.get_spin_speed_fraction or function() return 0 end
	SpinDrive.log = SpinDrive.log or function(...)
		local n = select("#", ...)
		local parts = {}
		for i = 1, n do parts[i] = tostring((select(i, ...))) end
		log("[SpinDrive] " .. table.concat(parts, " "))
	end
	SpinDrive.dbg = SpinDrive.dbg or function() end
	SpinDrive.log("WARNING: rofbuff.lua loaded before core.lua -- fallback stubs active until core.lua catches up.")
end

-- ============================================================================
-- Compatibility check: is the old RoFBuffMod-Stable installed alongside?
-- ============================================================================
-- The old mod sets _G.RoFBuffModStable = true when loading its
-- newraycastweaponbase.lua. Both mods would independently define
-- PlayerManager:Get/Set_Rof_Buff_Addon — that works technically (last
-- definition wins) but leads to two parallel ramp states and confusing
-- results. We only warn and do not intervene actively, since we do not
-- want to reach further into foreign mod code.
if rawget(_G, "RoFBuffModStable") then
	SpinDrive.log("WARNING: RoFBuffMod-Stable is also installed. Both mods define PlayerManager:Get/Set_Rof_Buff_Addon -- this can lead to inconsistent RoF behaviour. Recommendation: uninstall RoFBuffMod-Stable; SpinDrive covers its functionality.")
end

-- ============================================================================
-- PlayerManager: Get/Set_Rof_Buff_Addon
-- ============================================================================
-- Defined standalone (not wrapped around an existing function), because this
-- is exactly the API surface the old RoFBuffMod provided — other mods/skills
-- that read _Rof_Buff_Addon directly stay compatible.

function PlayerManager:Set_Rof_Buff_Addon(num)
	self._Rof_Buff_Addon = num
end

function PlayerManager:Get_Rof_Buff_Addon()
	return self._Rof_Buff_Addon or 1
end

-- ============================================================================
-- Derive RoF-buff addon from spin speed
-- ============================================================================
-- Instead of a second independent time ramp (like the old RoFBuffMod) we use
-- SpinDrive.get_spin_speed_fraction() from spindrive_spin.lua directly — the
-- spin engine already runs every frame for every active Gat weapon, including
-- single-fire (via the "shot_drive" hold mechanism).

--- Computes the current RoF-buff multiplier for a weapon based on its spin
-- speed (0..1) and the profile.get_tuning() values rpm_pct_min/rpm_pct_max
-- (aliases: rofb_min/rofb_max). Returns nil if no profile is responsible.
local function rof_addon_from_spin(weapon)
	local profile, part_key = SpinDrive.resolve(weapon)
	if not profile then
		return nil
	end

	local ok, tuning = pcall(profile.get_tuning, part_key, weapon)
	if not ok or type(tuning) ~= "table" then
		return nil
	end

	local min_b = type(tuning.rpm_pct_min) == "number" and tuning.rpm_pct_min or 1
	local max_b = type(tuning.rpm_pct_max) == "number" and tuning.rpm_pct_max or 1
	if min_b == max_b then
		-- Profile has RoF buff not configured (or deliberately disabled).
		return nil
	end

	local t = SpinDrive.get_spin_speed_fraction(weapon)

	-- Same S-curve as the original RoFBuffMod-Stable (polynomial fit for a
	-- smooth ease-in/ease-out instead of a linear ramp).
	local func_rat = 33.132 * t^6 - 88.048 * t^5 + 83.984 * t^4 - 34.344 * t^3 + 5.7412 * t^2 + 0.5372 * t + 0.0025
	func_rat = math.max(0, math.min(1, func_rat))

	local addon = min_b + func_rat * (max_b - min_b)

	-- Accuracy coupling: profile.accuracy scales a spread multiplier that
	-- spindrive_spin.lua or the consumer mod can read.
	weapon._spindrive_accuracy_mult = 1 + t * (tuning.accuracy or 0)

	return addon
end

--- Public query if a consumer mod wants to read the current RoF-buff value
-- without going through PlayerManager (e.g. for UI display).
function SpinDrive.get_rof_buff_addon(weapon)
	return rof_addon_from_spin(weapon)
end

--- Public query for the spread multiplier derived from profile.accuracy
-- (1 = no effect). Consumer mods that have their own _fire_raycast wraps
-- (like the old RoFBuffMod) can use this value instead of their own calc.
function SpinDrive.get_accuracy_multiplier(weapon)
	return weapon and weapon._spindrive_accuracy_mult or 1
end

local function apply_rof_from_spin(weapon)
	if not managers.player or not managers.player.Set_Rof_Buff_Addon then
		return
	end
	local addon = rof_addon_from_spin(weapon)
	if addon then
		managers.player:Set_Rof_Buff_Addon(addon)
	end
end

-- Get_Rof_Buff_Addon wrap: when a Gat profile is active always deliver the
-- spin-based value, even if the value was set to 1 in the meantime
-- (e.g. by a weapon-switch reset from another mod).
local function install_rof_get_wrap()
	if not PlayerManager or PlayerManager._spindrive_rof_get_wrapped then
		return
	end
	PlayerManager._spindrive_rof_get_wrapped = true

	local _orig = PlayerManager.Get_Rof_Buff_Addon
	function PlayerManager:Get_Rof_Buff_Addon()
		local player = self.player_unit and self:player_unit()
		if alive(player) and player.inventory then
			local inv = player:inventory()
			local wu = inv and inv:equipped_unit()
			if alive(wu) and wu.base then
				local weap = wu:base()
				if weap and SpinDrive.is_active(weap) then
					local addon = rof_addon_from_spin(weap)
					if addon then
						return addon
					end
				end
			end
		end
		return _orig(self)
	end

	SpinDrive.log("PlayerManager:Get_Rof_Buff_Addon wrapped (spin-coupled when a registered profile is active)")
end

install_rof_get_wrap()
Hooks:PostHook(PlayerManager, "init", "SpinDriveRofGetWrap", function()
	install_rof_get_wrap()
end)

-- ============================================================================
-- fire_rate_multiplier() wrap per weapon instance (idempotent)
-- ============================================================================
-- Same idea as the old RoFBuffMod: fire_rate_multiplier is wrapped once per
-- instance so Get_Rof_Buff_Addon() is applied on every fire interval.
-- rawget guard prevents double-wrapping on repeated clbk_assembly_complete
-- (e.g. after weapon modification in the inventory).
local function ensure_fire_rate_wrap(weapon)
	if not weapon or rawget(weapon, "_spindrive_rof_wrapped") then
		return
	end
	if type(weapon.fire_rate_multiplier) ~= "function" then
		return
	end
	local _orig_func = weapon.fire_rate_multiplier
	function weapon:fire_rate_multiplier(...)
		local base = _orig_func(self, ...)
		local profile, part_key = SpinDrive.resolve(self)
		local derived = nil
		if profile then
			local ok, tuning = pcall(profile.get_tuning, part_key, weapon)
			if ok and type(tuning) == "table" then
				local base_rpm = type(tuning.base_rpm) == "number" and tuning.base_rpm > 0 and tuning.base_rpm or nil
				local peak_rpm = type(tuning.peak_rpm) == "number" and tuning.peak_rpm > 0 and tuning.peak_rpm or nil
				if base_rpm and peak_rpm then
					derived = peak_rpm / base_rpm
				end
			end
		end
		local base_mult = derived or base
		local get_addon = managers.player and managers.player.Get_Rof_Buff_Addon
		local addon = get_addon and managers.player:Get_Rof_Buff_Addon() or 1
		return base_mult * addon
	end
	rawset(weapon, "_spindrive_rof_wrapped", true)
	SpinDrive.dbg("fire_rate_multiplier wrapped on", tostring(weapon))
end

SpinDrive.ensure_fire_rate_wrap = ensure_fire_rate_wrap

-- ============================================================================
-- Per-frame update: apply RoF buff from spin speed
-- ============================================================================
-- Runs on the same GameSetupUpdate cadence as the spin engine, but as its
-- own hook so spindrive_rofbuff.lua does not crash even without
-- spindrive_spin.lua (if someone deliberately disables the spin module) —
-- get_spin_speed_fraction then simply returns 0 and rof_addon_from_spin
-- cleanly degrades to min_b.
local function rof_update(dt)
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then return end
	local inv = player:inventory()
	if not inv then return end

	local seen = {}

	local function process(wu)
		if not alive(wu) then return end
		local key = wu:key()
		if key and seen[key] then return end
		if key then seen[key] = true end

		local base = wu:base()
		if base and SpinDrive.is_active(base) then
			ensure_fire_rate_wrap(base)
			apply_rof_from_spin(base)
		end

		if base and base._second_gun and alive(base._second_gun) then
			process(base._second_gun)
		end
	end

	process(inv:equipped_unit(1))
	process(inv:equipped_unit(2))
end

Hooks:Add("GameSetupUpdate", "SpinDriveRofBuffUpdate", function(t, dt)
	rof_update(dt)
end)

SpinDrive.log("rofbuff module loaded")
