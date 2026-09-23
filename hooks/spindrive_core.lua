_G.SpinDrive = _G.SpinDrive or {}
local SD = _G.SpinDrive

function SD.getPartStats(weapon)
	for _, partId in pairs(weapon._blueprint) do
		local part = tweak_data.weapon.factory.parts[partId]
		local stats = (part.custom_stats or {}).spindrive
		if stats then
			return stats
		end
	end
	return nil
end

local function lerp(min, max, pct)
	return min + ((max - min) * pct)
end

local function rampFRM(weapon)
	local stats = SD.getPartStats(weapon)
	if not weapon._spindrive_pct then weapon._spindrive_pct = 0 end
	if stats then
		local desiredRPM = lerp(
			stats.base_rpm * stats.rpm_pct_min,
			stats.peak_rpm, 
			weapon._spindrive_pct
		)
		return desiredRPM / stats.base_rpm
	end

	return nil
end

Hook:PreHook(NewRaycastWeaponBase, "fire_rate_multiplier", "spindrive_FRM", function(self,...)
	local FRM = rampFRM(self)
	if FRM then
		return FRM
	end
	return self._fire_rate_multiplier
end)


Hook:PostHook(NewRaycastWeaponBase, "_start_action_steelsight", "spindrive_accel_ADS", function(self,...)
	_G.SpinDrive.adsStartTime = t
end)

Hook:PostHook(NewRaycastWeaponBase, "_end_action_steelsight", "spindrive_deccel_ADS", function(self,...)
	_G.SpinDrive.adsEndTime = t
end)

Hook:PostHook(PlayerStandard, "update", "spindriveDt", function(self, t, dt)
	local SD = _G.SpinDrive
	if self._equipped_unit then 
		local wpn_unit = self._equipped_unit
		if wpn_unit and wpn_unit:base() then 
			local wpn = wpn_unit:base()
			if not wpn._spindrive_pct then 
				wpn._spindrive_pct = 0 
			end
			local _spindrive_stats = SD.getPartStats(wpn)
			if _spindrive_stats then
				if self._shooting then 
					wpn._spindrive_pct = math.min(1, wpn._spindrive_pct + dt / _spindrive_stats.accel_time)
				else 
					wpn._spindrive_pct = math.max(0, wpn._spindrive_pct - dt / _spindrive_stats.decel_time)
				end
			end
		end
	end
end)

