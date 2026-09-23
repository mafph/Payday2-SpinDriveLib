_G.SpinDrive = _G.SpinDrive or {}
local SD = _G.SpinDrive
local dt_sd = SD.dt
local spinStart = SD.spinStart
local spinTime = SD.spinTime
local spinInc = SD.spinInc
spinTime = nil
spinInc = nil

local function getPartStats(weapon)
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
	
	local pct = min(1, elapsed / accel_time)
	
	local stats = getPartStats(weapon)
	if stats then
		local desiredRPM = lerp(stats.base_rpm * stats.rpm_pct_min, stats.peak_rpm, pct)
		return desiredRPM / stats.base_rpm
	end

	return 1
end

Hook:PreHook(NewRaycastWeaponBase, "fire_rate_multiplier", "spindrive_FRM", function(self,...)
	local FRM = rampFRM(self)
	if FRM > 1 then
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

Hook:PostHook(PlayerStandard, "update", "spindriveDt", function(self,...)
	if self._shooting = then 
		_G.SpinDrive.spintime = t - _shooting_t
		_G.SpinDrive.spinDownTime = 0
	else 
		_G.SpinDrive.spinDownTime = _G.SpinDrive.Downspintime + dt
		_G.SpinDrive.spintime
	end
end)

