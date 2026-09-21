--[[
	SpinDrive — spin engine.

	Responsible for:
	  - Barrel rotation (barrel spin) while firing AND during ironsight rev-up
	  - Optional rev sound on spin-up / spin-down
	  - Estimated fire RPM (for RoF-buff coupling; see spindrive_rofbuff.lua)

	Generalized version of GatMalite's gatmalite_spin.lua: instead of hard-
	coding GM.find_part/GM.POINTS, this module asks SpinDrive.resolve()
	(from spindrive_core.lua) for each weapon to get profile + part_key, and
	reads the consumer mod's tuning values through that.

	NS-clone rotation (multiple barrels in a circle, as in GatMalite's barrel
	cluster) is intentionally NOT here: that is specific to GatMalite's model
	setup (a_ns_gat_1..6 attachment points) and stays in GatMalite itself,
	which queries SpinDrive.get_spin_angle(weapon) and rotates its clones.
--]]

local SpinDrive = _G.SpinDrive
if not SpinDrive then
	-- spindrive_core.lua and spindrive_spin.lua both hang on the same
	-- hook_id (raycastweaponbase) and therefore load in the order listed
	-- in mod.txt — unlike spindrive_rofbuff.lua (different hook_id), where
	-- that is NOT guaranteed.
	log("[SpinDrive] FATAL: spindrive_spin.lua loaded but _G.SpinDrive is missing. Check hook order in mod.txt (core must come before spin).")
	return
end

-- ============================================================================
-- Tuning constants (global, not per profile — the basic spin physics
-- behaviour is the same for all Gatlings; only times / target RPM per
-- weapon differ via profile.get_tuning()).
-- ============================================================================
local MAX_SPEED = 3600          -- degrees/second at "full speed"
local ADS_REV_FRAC = 0.4        -- target speed during pure ironsight rev-up (fraction of MAX_SPEED)
local KICK_DAMP = 0.5           -- recoil kick damping while Gat is active (0=no kick, 1=vanilla)

-- Spin-sound retrigger (one-shot event, not a loop — see post_spin_sound_once)
local SPIN_SOUND_SPEED_MIN = MAX_SPEED * 0.10
local SPIN_SOUND_RETRIG_MIN = 0.05 -- seconds between retriggers at MAX_SPEED
local SPIN_SOUND_RETRIG_MAX = 0.60 -- seconds between retriggers at low spin speed

-- ============================================================================
-- Tuning resolution (with defaults if a profile omits values)
-- ============================================================================

--- Reads tuning values for weapon/part_key from the responsible profile and
-- fills missing fields with sensible defaults. Fetched fresh each call
-- (no caching), because profile.get_tuning() is usually cheap (table
-- lookup) and values may change at runtime (e.g. RoFBuff skill upgrades).
local function resolve_tuning(profile, part_key, weapon)
	local raw = {}
	local ok, result = pcall(profile.get_tuning, part_key, weapon)
	if ok and type(result) == "table" then
		raw = result
	elseif not ok then
		SpinDrive.dbg("profile", profile.name, "get_tuning() error:", result)
	end

	local accel_time = type(raw.accel_time) == "number" and raw.accel_time > 0 and raw.accel_time or 0.8
	local decel_time = type(raw.decel_time) == "number" and raw.decel_time > 0 and raw.decel_time or 1.0
	local peak_rpm = type(raw.peak_rpm) == "number" and raw.peak_rpm > 0 and raw.peak_rpm or 2000
	local base_rpm = type(raw.base_rpm) == "number" and raw.base_rpm > 0 and raw.base_rpm or nil
	local rpm_pct_min = type(raw.rpm_pct_min) == "number" and raw.rpm_pct_min or (type(raw.rofb_min) == "number" and raw.rofb_min or 1)
	local rpm_pct_max = type(raw.rpm_pct_max) == "number" and raw.rpm_pct_max or (type(raw.rofb_max) == "number" and raw.rofb_max or 1)
	local spread_penalty = type(raw.spread_penalty) == "number" and raw.spread_penalty or 0
	local fire_rate_multiplier = type(raw.fire_rate_multiplier) == "number" and raw.fire_rate_multiplier or 1
	if base_rpm and peak_rpm and base_rpm > 0 and peak_rpm > 0 then
		fire_rate_multiplier = peak_rpm / base_rpm
	end

	return {
		accel = MAX_SPEED / math.max(0.05, accel_time),
		decel = MAX_SPEED / math.max(0.05, decel_time),
		peak_rpm = peak_rpm,
		base_rpm = base_rpm,
		rpm_pct_min = rpm_pct_min,
		rpm_pct_max = rpm_pct_max,
		spread_penalty = spread_penalty,
		fire_rate_multiplier = fire_rate_multiplier
	}
end

-- ============================================================================
-- Barrel rotation
-- ============================================================================

local function get_spin_object(weapon, part_unit, spin_object_name)
	if not part_unit or not alive(part_unit) then
		return nil
	end
	local ids = Idstring(spin_object_name or "g_barrel_extreme")
	return part_unit:get_object(ids) or part_unit:orientation_object()
end

local function apply_spin_rotation(weapon, profile, part_key, angle)
	local part_unit = weapon._spindrive_part_unit
	if not part_unit or not alive(part_unit) then
		return
	end
	local object = get_spin_object(weapon, part_unit, profile.spin_object_name)
	if object then
		object:set_local_rotation(Rotation(0, 0, angle))
	end
end

-- ============================================================================
-- Camera kick damping (while Gat is actively held/fired)
-- ============================================================================

local function damp_camera_kick(player)
	local cam_ext = player:camera()
	if not cam_ext then
		return
	end
	local cam_unit = cam_ext.camera_unit and cam_ext:camera_unit() or nil
	if not alive(cam_unit) then
		return
	end
	local cam = cam_unit:base()
	if not cam or not cam._recoil_kick then
		return
	end

	local function damp(tbl)
		if not tbl then
			return
		end
		if tbl.accumulated then
			tbl.accumulated = tbl.accumulated * KICK_DAMP
		end
		if tbl.current then
			tbl.current = tbl.current * KICK_DAMP
		end
		if tbl.to_reduce then
			tbl.to_reduce = tbl.to_reduce * KICK_DAMP
		end
	end

	damp(cam._recoil_kick)
	damp(cam._recoil_kick.h)
end

-- ============================================================================
-- Normalize screen-shake (hip vs. ADS same sign, no invert)
-- ============================================================================

local function normalize_shake(weapon)
	if weapon._spindrive_shake_normalized then
		return
	end
	local td = weapon.weapon_tweak_data and weapon:weapon_tweak_data()
	if not td or not td.shake then
		return
	end
	weapon._spindrive_shake_backup = {
		fire_multiplier = td.shake.fire_multiplier,
		fire_steelsight_multiplier = td.shake.fire_steelsight_multiplier
	}
	local mag = 0.35
	td.shake.fire_multiplier = mag
	td.shake.fire_steelsight_multiplier = (30 * mag)
	weapon._spindrive_shake_normalized = true
	SpinDrive.dbg("shake normalized on", tostring(weapon))
end

local function restore_shake(weapon)
	if not weapon or not weapon._spindrive_shake_backup then
		return
	end
	local td = weapon.weapon_tweak_data and weapon:weapon_tweak_data()
	if td and td.shake then
		td.shake.fire_multiplier = weapon._spindrive_shake_backup.fire_multiplier
		td.shake.fire_steelsight_multiplier = weapon._spindrive_shake_backup.fire_steelsight_multiplier
	end
	weapon._spindrive_shake_backup = nil
	weapon._spindrive_shake_normalized = nil
end

-- ============================================================================
-- Ironsight-Erkennung
-- ============================================================================
-- PD2 has no weapon:ads_multiplier() — read via the player movement state.
local function is_in_steelsight()
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then
		return false
	end
	local mov = player:movement()
	if not mov then
		return false
	end
	local state = mov:current_state()
	if state and state.in_steelsight then
		local ok, result = pcall(state.in_steelsight, state)
		return ok and result and true or false
	end
	return false
end

-- ============================================================================
-- Spin sound (one-shot event, retriggered on intervals while the barrel spins)
-- ============================================================================

local function spin_sound_interval(speed)
	local t = 0
	if MAX_SPEED > 0 and speed and speed > 0 then
		t = math.max(0, math.min(1, speed / MAX_SPEED))
	end
	return SPIN_SOUND_RETRIG_MAX + (SPIN_SOUND_RETRIG_MIN - SPIN_SOUND_RETRIG_MAX) * t
end

-- Own SoundSource — NOT _sound_fire, otherwise spin retrigger kills the
-- fire sound (one voice/thread per source).
local function get_spin_sound_source(weapon)
	if not weapon then
		return nil
	end
	if weapon._spindrive_spin_src then
		return weapon._spindrive_spin_src
	end
	if not SoundDevice or not SoundDevice.create_source then
		return nil
	end
	local ok, src = pcall(function()
		return SoundDevice:create_source("spindrive_spin")
	end)
	if not ok or not src then
		return nil
	end
	local unit = weapon._unit
	if alive(unit) then
		pcall(function()
			local link_obj = unit:orientation_object() or (unit.get_object and unit:get_object(Idstring("rp")))
			if link_obj then
				src:link(link_obj)
			end
		end)
	end
	weapon._spindrive_spin_src = src
	return src
end

local function stop_spin_sound(weapon)
	if not weapon then
		return
	end
	weapon._spindrive_spin_sound_t = nil
end

local function post_spin_sound_once(weapon, event_name)
	if not event_name then
		return
	end
	local src = get_spin_sound_source(weapon)
	if not src then
		if not weapon._spindrive_spin_sound_warned then
			weapon._spindrive_spin_sound_warned = true
			SpinDrive.log("spin sound: could not create SoundSource")
		end
		return
	end
	local ok, event = pcall(function()
		return src:post_event(event_name)
	end)
	if not ok and not weapon._spindrive_spin_sound_warned then
		weapon._spindrive_spin_sound_warned = true
		SpinDrive.log("spin sound: post_event(" .. tostring(event_name) .. ") failed: " .. tostring(event))
	end
end

local function update_spin_sound(weapon, want_spin, dt, speed, event_name)
	if not want_spin or not event_name then
		stop_spin_sound(weapon)
		return
	end
	dt = dt or 0.016
	local interval = spin_sound_interval(speed or 0)
	local tleft = weapon._spindrive_spin_sound_t
	if tleft == nil then
		post_spin_sound_once(weapon, event_name)
		weapon._spindrive_spin_sound_t = interval
		return
	end
	tleft = tleft - dt
	if tleft <= 0 then
		post_spin_sound_once(weapon, event_name)
		tleft = interval
	end
	weapon._spindrive_spin_sound_t = tleft
end

-- ============================================================================
-- Estimated fire RPM (from shot intervals, with fallback to tweak data)
-- ============================================================================

local function theoretical_rpm(weapon)
	local td = weapon.weapon_tweak_data and weapon:weapon_tweak_data()
	if not td then
		return nil
	end
	local interval = nil
	if td.auto and type(td.auto.fire_rate) == "number" and td.auto.fire_rate > 0 then
		interval = td.auto.fire_rate
	elseif td.fire_mode_data and type(td.fire_mode_data.fire_rate) == "number" and td.fire_mode_data.fire_rate > 0 then
		interval = td.fire_mode_data.fire_rate
	elseif td.single and type(td.single.fire_rate) == "number" and td.single.fire_rate > 0 then
		interval = td.single.fire_rate
	end
	if not interval or interval <= 0 then
		return nil
	end
	local mul = 1
	if weapon.fire_rate_multiplier then
		local ok, m = pcall(function() return weapon:fire_rate_multiplier() end)
		if ok and type(m) == "number" and m > 0 then
			mul = m
		end
	end
	return 60 / (interval / mul)
end

-- ============================================================================
-- Main update: per weapon, per frame
-- ============================================================================

local function update_barrel_spin(weapon, dt)
	if not weapon or not dt or dt <= 0 then
		return
	end

	local profile, part_key = SpinDrive.resolve(weapon)
	if not profile then
		-- No Gatling profile (still) active: let the current ramp spin down
		-- smoothly instead of hard-cutting if residual speed is still present.
		if weapon._spindrive_spin_speed and weapon._spindrive_spin_speed > 0 then
			weapon._spindrive_spin_speed = math.max(0, weapon._spindrive_spin_speed - MAX_SPEED * dt)
		end
		return
	end

	-- Cache part unit for rotation (for apply_spin_rotation); kept current
	-- indirectly via profile.match(), since resolve() re-matches on part swap.
	local part_unit = nil
	if profile.get_part_unit then
		local ok, u = pcall(profile.get_part_unit, weapon, part_key)
		if ok then
			part_unit = u
		end
	end
	weapon._spindrive_part_unit = part_unit

	weapon._spindrive_spin_speed = weapon._spindrive_spin_speed or 0
	weapon._spindrive_spin_angle = weapon._spindrive_spin_angle or 0

	local shooting = weapon._spindrive_shooting
	if shooting == nil then
		shooting = weapon._shooting
	end

	local now = 0
	if TimerManager and TimerManager.game then
		now = TimerManager:game():time()
	end

	-- Single-fire: start/stop_shooting are only brief -> keep drive on briefly
	-- after the shot; see SpinDriveSpinOnFire further below.
	local shot_drive = weapon._spindrive_shot_drive_until and now < weapon._spindrive_shot_drive_until
	local fire_drive = shooting or shot_drive

	local in_ads = is_in_steelsight()

	local tuning = resolve_tuning(profile, part_key, weapon)

	local est_rpm = weapon._spindrive_est_rpm
	if fire_drive then
		if not est_rpm or est_rpm <= 0 then
			est_rpm = theoretical_rpm(weapon) or (tuning.peak_rpm * 0.3)
		end
		local target = MAX_SPEED
		if weapon._spindrive_spin_speed < target then
			weapon._spindrive_spin_speed = math.min(target, weapon._spindrive_spin_speed + tuning.accel * dt)
		else
			weapon._spindrive_spin_speed = math.max(target, weapon._spindrive_spin_speed - tuning.decel * dt)
		end
		weapon._spindrive_ads_revved = false
	elseif in_ads then
		local ads_target = MAX_SPEED * ADS_REV_FRAC
		if weapon._spindrive_spin_speed < ads_target then
			weapon._spindrive_spin_speed = math.min(ads_target, weapon._spindrive_spin_speed + tuning.accel * dt)
		else
			weapon._spindrive_spin_speed = math.max(ads_target, weapon._spindrive_spin_speed - tuning.decel * dt)
		end
		weapon._spindrive_ads_revved = true
	else
		weapon._spindrive_spin_speed = math.max(0, weapon._spindrive_spin_speed - tuning.decel * dt)
		if weapon._spindrive_est_rpm then
			weapon._spindrive_est_rpm = weapon._spindrive_est_rpm * math.max(0, 1 - 2 * dt)
			if weapon._spindrive_est_rpm < 5 then
				weapon._spindrive_est_rpm = nil
			end
		end
		if weapon._spindrive_ads_revved and weapon._spindrive_spin_speed <= 0.01 then
			weapon._spindrive_ads_revved = false
		end
	end

	if weapon._spindrive_spin_speed > 0 then
		weapon._spindrive_spin_angle = weapon._spindrive_spin_angle + weapon._spindrive_spin_speed * dt
		if weapon._spindrive_spin_angle > 360000 then
			weapon._spindrive_spin_angle = weapon._spindrive_spin_angle % 360
		end
		apply_spin_rotation(weapon, profile, part_key, weapon._spindrive_spin_angle)
	end

	update_spin_sound(
		weapon,
		weapon._spindrive_spin_speed >= SPIN_SOUND_SPEED_MIN,
		dt,
		weapon._spindrive_spin_speed,
		profile.ads_rev_sound
	)
end

--- Public query for consumer mods that e.g. want to rotate their own clone
-- objects (like GatMalite's NS barrel cluster) to match the spin angle.
function SpinDrive.get_spin_angle(weapon)
	return weapon and weapon._spindrive_spin_angle or 0
end

function SpinDrive.get_spin_speed(weapon)
	return weapon and weapon._spindrive_spin_speed or 0
end

function SpinDrive.get_spin_speed_fraction(weapon)
	local speed = SpinDrive.get_spin_speed(weapon)
	if MAX_SPEED <= 0 then
		return 0
	end
	return math.max(0, math.min(1, speed / MAX_SPEED))
end

--- Public query for the estimated current fire RPM (for RoF-buff coupling
-- outside this module, if a consumer mod needs it).
function SpinDrive.get_estimated_rpm(weapon)
	return weapon and weapon._spindrive_est_rpm or nil
end

-- ============================================================================
-- Hooks
-- ============================================================================

Hooks:PostHook(RaycastWeaponBase, "start_shooting", "SpinDriveSpinStart", function(self)
	if SpinDrive.is_active(self) then
		self._spindrive_shooting = true
		normalize_shake(self)
		SpinDrive.dbg("start_shooting on", tostring(self))
	end

	if self._second_gun and alive(self._second_gun) then
		local second_base = self._second_gun:base()
		if second_base and SpinDrive.is_active(second_base) then
			second_base._spindrive_shooting = true
			normalize_shake(second_base)
		end
	end
end)

Hooks:PostHook(RaycastWeaponBase, "stop_shooting", "SpinDriveSpinStop", function(self)
	self._spindrive_shooting = false
	self._spindrive_shot_drive_until = nil

	if self._second_gun and alive(self._second_gun) then
		local second_base = self._second_gun:base()
		if second_base then
			second_base._spindrive_shooting = false
			second_base._spindrive_shot_drive_until = nil
		end
	end
end)

-- Per shot: estimate RPM + hold single-fire drive (start/stop_shooting are
-- too short on semi-auto to make a ramp visible).
Hooks:PostHook(RaycastWeaponBase, "fire", "SpinDriveSpinOnFire", function(self, ...)
	if not SpinDrive.is_active(self) then
		return
	end

	local now = TimerManager and TimerManager.game and TimerManager:game():time() or 0
	local last = self._spindrive_last_shot_t
	local interval = last and now > last and (now - last) or nil
	local instant_rpm = (interval and interval > 0.001 and interval < 2) and (60 / interval) or nil

	if instant_rpm then
		local prev = self._spindrive_est_rpm or instant_rpm
		self._spindrive_est_rpm = prev * 0.65 + instant_rpm * 0.35
	else
		local profile, part_key = SpinDrive.resolve(self)
		local tuning = profile and resolve_tuning(profile, part_key, self)
		self._spindrive_est_rpm = theoretical_rpm(self) or (tuning and tuning.peak_rpm * 0.25) or 500
	end

	local trpm = theoretical_rpm(self)
	local frm = self.fire_rate_multiplier and self:fire_rate_multiplier() or nil

	SpinDrive.dbg(
		"fire",
		"now=", string.format("%.6f", now),
		"interval=", interval and string.format("%.6f", interval) or "nil",
		"instant=", instant_rpm and string.format("%.3f", instant_rpm) or "nil",
		"rpm=", self._spindrive_est_rpm and string.format("%.3f", self._spindrive_est_rpm) or "nil",
		"theoretical=", trpm and string.format("%.3f", trpm) or "nil",
		"frm=", frm and string.format("%.3f", frm) or "nil",
		"shooting=", tostring(self._spindrive_shooting)
	)

	self._spindrive_last_shot_t = now

	local hold = 0.12
	if trpm and trpm > 0 then
		hold = math.max(0.12, math.min(0.5, 60 / trpm))
	end
	self._spindrive_shot_drive_until = now + hold
end)

--[[
Hooks:PostHook(RaycastWeaponBase, "fire", "FireIntervalDebug", function(self, ...)
	local td = self.weapon_tweak_data and self:weapon_tweak_data()
	local weapon_id = td and td.name_id or "unknown"

	local now = TimerManager and TimerManager.game and TimerManager:game():time() or 0
	local last = self._fire_interval_debug_last_t
	local interval = last and now > last and (now - last) or nil
	local instant_rpm = (interval and interval > 0.001 and interval < 2) and (60 / interval) or nil

	local frm = nil
	if self.fire_rate_multiplier then
		local ok, val = pcall(function()
			return self:fire_rate_multiplier()
		end)
		if ok then
			frm = val
		end
	end

	log(string.format(
		"[FireDebug] weapon=%s now=%.6f interval=%s instant=%s frm=%s",
		tostring(weapon_id),
		now,
		interval and string.format("%.6f", interval) or "nil",
		instant_rpm and string.format("%.3f", instant_rpm) or "nil",
		frm and string.format("%.3f", frm) or "nil"
	))

	self._fire_interval_debug_last_t = now
end)
]]


Hooks:PostHook(NewRaycastWeaponBase, "clbk_assembly_complete", "SpinDriveRofFireRateWrap", function(self)
	if SpinDrive.is_active(self) then
		if SpinDrive.ensure_fire_rate_wrap then
			SpinDrive.ensure_fire_rate_wrap(self)
		end
		normalize_shake(self)
	end
end)

Hooks:PostHook(NewRaycastWeaponBase, "clbk_assembly_complete", "SpinDriveShakeNorm", function(self)
	if SpinDrive.is_active(self) then
		normalize_shake(self)
	end
end)

Hooks:PreHook(NewRaycastWeaponBase, "destroy", "SpinDriveShakeRestore", function(self)
	restore_shake(self)
	stop_spin_sound(self)
	if self._spindrive_spin_src then
		pcall(function() self._spindrive_spin_src:delete() end)
		self._spindrive_spin_src = nil
	end
end)

local function spin_and_kick(dt)
	local player = managers.player and managers.player:player_unit()
	if not alive(player) then return end
	local inv = player:inventory()
	if not inv then return end
	damp_camera_kick(player)

	local seen = {}

	local function process(wu)
		if not alive(wu) then return end
		local key = wu:key()
		if key and seen[key] then return end
		if key then seen[key] = true end

		local base = wu:base()
		if base and SpinDrive.is_active(base) then
			update_barrel_spin(base, dt)
		end

		if base and base._second_gun and alive(base._second_gun) then
			process(base._second_gun)
		end
	end

	process(inv:equipped_unit(1))
	process(inv:equipped_unit(2))
end

Hooks:Add("GameSetupUpdate", "SpinDriveBarrelSpin", function(t, dt)
	spin_and_kick(dt)
end)

SpinDrive.log("spin module loaded")
