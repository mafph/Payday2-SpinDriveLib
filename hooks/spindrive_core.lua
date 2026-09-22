_G.SpinDrive = _G.SpinDrive or {}
local SD = _G.SpinDrive

function getPartStats(weapon)
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
	
	pct
	
	local stats = getPartStats(weapon)
	if stats then
		local desiredRPM = lerp(stats.base_rpm * stats.rpm_pct_min, stats.peak_rpm, pct)
		return desiredRPM / stats.base_rpm
	end

	return 1
end

Hook:PreHook(NewRaycastWeaponBase, "fire_rate_multiplier", "spindrive_FRM", function(self,...)
	local FRM = rampFRM(self)
	if FRM > 1
		return FRM
	end
	return self._fire_rate_multiplier
end
