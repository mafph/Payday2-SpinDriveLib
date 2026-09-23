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

Hooks:OverrideFunction(NewRaycastWeaponBase, "fire_rate_multiplier", function(self, ...)
    return self._fire_rate_multiplier * self._spindrive_mult
end)

Hooks:PostHook(PlayerInventory, "_send_equipped_weapon", "spindrive_init", function(self,...)
	local base = self:equipped_unit():base()
    local stats = _G.SpinDrive.getPartStats(base)
	base._spindrive_stats = stats
	base._spindrive_mult = stats and stats.rpm_pct_min or 1
	base._spindrive_pct = 0
end)

Hooks:PostHook(PlayerStandard, "update", "spindriveDt", function(self, t, dt)
	local SD = _G.SpinDrive
	if self._equipped_unit then
		local wpn = self._equipped_unit:base()
		local stats = wpn._spindrive_stats
		local mult = wpn._spindrive_mult
		local pct = wpn._spindrive_pct
		if stats then
			local peak_mult = stats.peak_rpm / stats.base_rpm
			if self._shooting then 
				pct = math.step(pct, 1, dt / stats.accel_time)
				mult = stats.rpm_pct_min + pct * (peak_mult - stats.rpm_pct_min)
			elseif self._state_data.in_steelsight then
				pct = math.step(pct, stats.rpm_pct_ads, dt / stats.accel_time)
				mult = stats.rpm_pct_min + pct * (peak_mult - stats.rpm_pct_min)
			else
				pct = math.step(pct, 0, dt / stats.decel_time)
				mult = stats.rpm_pct_min + pct * (peak_mult - stats.rpm_pct_min)
			end
			wpn._spindrive_pct = pct
			wpn._spindrive_mult = mult
		end
	end
end)

