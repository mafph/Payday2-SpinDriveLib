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

Hooks:PreHook(NewRaycastWeaponBase, "fire_rate_multiplier", "spindrive_FRM", function(self,...)
	local FRM = rampFRM(self)
	if FRM then
		return FRM
	end
	return self._fire_rate_multiplier
end)

Hooks:PostHook(PlayerStandard, "update", "spindriveDt", function(self, t, dt)
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
					wpn._spindrive_pct = math.step(wpn._spindrive_pct, 1, dt / _spindrive_stats.accel_time)
				elseif self:in_steelsight() then
					wpn._spindrive_pct = math.step(wpn._spindrive_pct, _spindrive_stats.rpm_pct_ads or 0.4, dt / _spindrive_stats.accel_time)
				else
					wpn._spindrive_pct = math.step(wpn._spindrive_pct, 0, dt / _spindrive_stats.decel_time)
				end
			end
		end
	end
end)

