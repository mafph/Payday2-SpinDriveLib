--[[
	SpinDrive — generic spin-up / RoF-buff engine for Gatling-style weapons.

	This file is the core: global namespace, debug logging, and the registration
	API that consumer mods (e.g. GatMalite) use to sign up.
	It contains NO gameplay hooks — those live in the other spindrive_*.lua
	files (spin.lua, rofbuff.lua), which all build on _G.SpinDrive and must
	therefore load AFTER this file (see mod.txt).

	Registration idea:
	Every mod that has a Gatling-style weapon calls SpinDrive.register(profile)
	once and receives a profile_id back. From then on SpinDrive knows for each
	weapon instance whether/how it "spins", without hard-coding any part or
	weapon IDs itself.
--]]

_G.SpinDrive = _G.SpinDrive or {}
local SpinDrive = _G.SpinDrive

-- ============================================================================
-- Debug logging
-- ============================================================================
-- Simple global on/off switch (no log levels). Toggle from console:
--   SpinDrive.debug = true
-- or via SpinDrive.set_debug(true/false).
-- Default: off, so normal players are not flooded with logs.
SpinDrive.debug = SpinDrive.debug or false

--- Debug log line. Only printed when SpinDrive.debug == true.
-- Accepts any number of arguments like print/log, joined via tostring.
function SpinDrive.dbg(...)
	if not SpinDrive.debug then
		return
	end
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	log("[SpinDrive] " .. table.concat(parts, " "))
end

--- Log line that is ALWAYS printed (errors, warnings, setup messages).
-- Use for anything that should be visible even without debug mode
-- (e.g. "profile X registered" or "profile Y invalid").
function SpinDrive.log(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	log("[SpinDrive] " .. table.concat(parts, " "))
end

function SpinDrive.set_debug(on)
	SpinDrive.debug = on and true or false
	SpinDrive.log("debug logging " .. (SpinDrive.debug and "ENABLED" or "disabled"))
end

-- ============================================================================
-- Registry
-- ============================================================================
-- profiles: profile_id -> profile (see SpinDrive.register for the format)
-- A "profile" describes ONE Gatling-style part family (e.g. GatMalite's
-- three barrel lengths, or a single vanilla weapon like the m134).
SpinDrive._profiles = SpinDrive._profiles or {}
SpinDrive._profile_count = SpinDrive._profile_count or 0

--[[
	Expected profile format for SpinDrive.register(profile):

	{
		-- Required: unique, human-readable name for logs (not the ID).
		name = "GatMalite",

		-- Required: function that, for a RaycastWeaponBase instance (`weapon`),
		-- checks whether this profile is responsible and, if so, returns the
		-- matching part_id (or any tuning key), otherwise nil.
		-- SpinDrive walks all registered profiles until one returns non-nil —
		-- so this function should be cheap.
		match = function(weapon) return part_id_or_nil end,

		-- Required: function that, for a given part_id/tuning-key (and optionally
		-- the weapon as second argument), returns the spin tuning values:
		--   accel_time  seconds from 0 to full spin speed
		--   decel_time  seconds from full spin speed to 0
		--   peak_rpm    fire RPM considered "full speed"
		--   rpm_pct_min   fraction of peak_rpm at the low end of the ramp (optional, default 1)
		--   rpm_pct_max   fraction of peak_rpm at the high end of the ramp (optional, default 1)
		--   base_rpm      weapon base RPM without SpinDrive ramp (optional, for UI / fire_rate_multiplier derivation)
		--   accuracy      0..1 how much accuracy improves with the ramp (optional, default 0)
		--   Backward compatibility: rofb_min/rofb_max are still accepted as aliases.
		-- Second argument `weapon` is optional; older profiles that only take
		-- part_key continue to work (Lua ignores extra arguments).
		get_tuning = function(part_key, weapon) return { accel_time=..., decel_time=..., peak_rpm=..., rpm_pct_min=..., rpm_pct_max=..., base_rpm=..., accuracy=... } end,

		-- Optional: name of the sound event to play when revving in ironsight
		-- (e.g. "minigun_stop" as a one-shot rev sound).
		-- If nil, SpinDrive plays no extra sound for this profile.
		ads_rev_sound = "minigun_stop",

		-- Optional: which object on the part unit should be rotated
		-- (Idstring name as string). Default: "g_barrel".
		spin_object_name = "g_barrel",

		-- Optional: function that, for (weapon, part_key), returns the unit of
		-- the rotating part (the "unit" of the mounted barrel part).
		-- Without this function SpinDrive cannot rotate any object — spin
		-- speed/angle are still computed (e.g. for RoF-buff coupling), only
		-- the visual rotation is skipped.
		get_part_unit = function(weapon, part_key) return unit_or_nil end,
	}

	Returns: profile_id (number) for later SpinDrive.unregister(profile_id),
	or nil if the profile is invalid (see SpinDrive.log for the reason).
--]]
function SpinDrive.register(profile)
	if type(profile) ~= "table" then
		SpinDrive.log("register() rejected: profile is not a table")
		return nil
	end
	if type(profile.match) ~= "function" then
		SpinDrive.log("register() rejected: profile.match missing or not a function (name=" .. tostring(profile.name) .. ")")
		return nil
	end
	if type(profile.get_tuning) ~= "function" then
		SpinDrive.log("register() rejected: profile.get_tuning missing or not a function (name=" .. tostring(profile.name) .. ")")
		return nil
	end

	SpinDrive._profile_count = SpinDrive._profile_count + 1
	local profile_id = SpinDrive._profile_count

	SpinDrive._profiles[profile_id] = {
		id = profile_id,
		name = profile.name or ("profile_" .. profile_id),
		match = profile.match,
		get_tuning = profile.get_tuning,
		get_part_unit = profile.get_part_unit,
		ads_rev_sound = profile.ads_rev_sound,
		spin_object_name = profile.spin_object_name or "g_barrel"
	}

	SpinDrive.log("registered profile #" .. profile_id .. " (" .. SpinDrive._profiles[profile_id].name .. ")")
	return profile_id
end

--- Removes a previously registered profile (e.g. on mod reload/cleanup).
function SpinDrive.unregister(profile_id)
	if SpinDrive._profiles[profile_id] then
		SpinDrive.log("unregistered profile #" .. profile_id .. " (" .. SpinDrive._profiles[profile_id].name .. ")")
		SpinDrive._profiles[profile_id] = nil
	end
end

--- Walks all registered profiles and returns the first one responsible for
-- `weapon`. Returns profile, part_key, or nil, nil if none match.
-- Cached per weapon (weapon._spindrive_profile_id / _part_key) so match()
-- does not have to run for every profile every frame — the cache is
-- invalidated when the weapon "visibly" changes (part swap), which we
-- handle with a simple re-check cadence instead of expensive change
-- detection: match() is still called regularly (see SpinDrive spin module),
-- only the iteration over ALL profiles is skipped when the last hit still
-- matches.
function SpinDrive.resolve(weapon)
	if not weapon then
		return nil, nil
	end

	-- Fast path: try the last profile again before walking all of them.
	local cached_id = weapon._spindrive_profile_id
	if cached_id then
		local cached_profile = SpinDrive._profiles[cached_id]
		if cached_profile then
			local ok, part_key = pcall(cached_profile.match, weapon)
			if ok and part_key then
				weapon._spindrive_part_key = part_key
				return cached_profile, part_key
			end
		end
		-- Cache no longer valid (part removed/swapped) -> drop it.
		weapon._spindrive_profile_id = nil
		weapon._spindrive_part_key = nil
	end

	for profile_id, profile in pairs(SpinDrive._profiles) do
		local ok, part_key = pcall(profile.match, weapon)
		if not ok then
			SpinDrive.dbg("profile", profile.name, "match() error:", part_key)
		elseif part_key then
			weapon._spindrive_profile_id = profile_id
			weapon._spindrive_part_key = part_key
			return profile, part_key
		end
	end

	return nil, nil
end

--- Convenience: true/false whether this weapon is currently recognized as
-- "Gatling-style active" by any profile.
function SpinDrive.is_active(weapon)
	local profile = SpinDrive.resolve(weapon)
	return profile ~= nil
end

SpinDrive.log("core loaded (" .. (SpinDrive.debug and "debug ON" or "debug off") .. ")")
