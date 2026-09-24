_G.SpinDrive = _G.SpinDrive or {}
local SD = _G.SpinDrive

function SD.getPartStats(weapon)
	for slot, partId in pairs(weapon._blueprint) do
		local part = tweak_data.weapon.factory.parts[partId]
		local stats = (part.custom_stats or {}).spindrive
		if stats then
			return partId, stats
		end
	end
end

Hooks:OverrideFunction(NewRaycastWeaponBase, "fire_rate_multiplier", function(self, ...)
	return self._fire_rate_multiplier * self._spindrive_mult
end)

Hooks:PostHook(PlayerInventory, "_send_equipped_weapon", "spindrive_init", function(self,...)
	local base = self:equipped_unit():base()
    local partId, stats = _G.SpinDrive.getPartStats(base)
	base._spindrive_partId = partId
	base._spindrive_stats = stats
	base._spindrive_mult = stats and stats.rpm_pct_min or 1
	base._spindrive_pct = 0
	base._spindrive_angle = 0
end)

Hooks:PostHook(PlayerStandard, "update", "spindriveDt", function(self, t, dt)
	local SD = _G.SpinDrive
	if self._equipped_unit then
		local wpn = self._equipped_unit:base()
		local stats = wpn._spindrive_stats
		local pct = wpn._spindrive_pct
		if stats then
			local peak_mult = stats.peak_rpm / stats.base_rpm
			local target, rate
			if self._shooting then
				target, rate = 1, dt / stats.accel_time
			elseif self._state_data.in_steelsight then
				target, rate = stats.rpm_pct_ads, dt / stats.accel_time
			else
				target, rate = 0, dt / stats.decel_time
			end
			pct = pct < target and math.min(target, pct + rate) or math.max(target, pct - rate)
			wpn._spindrive_pct = pct
			wpn._spindrive_mult = peak_mult * stats.rpm_pct_min / (1 - (1 - stats.rpm_pct_min) * pct)
			--spin
			wpn._spindrive_angle = (wpn._spindrive_angle or 0) + stats.peak_rpm * (6 / stats.n_barrels) * pct * dt
			local obj = wpn._parts[wpn._spindrive_partId].unit:orientation_object()
			if stats.spin_axis == "x" then
				obj:set_local_rotation(Rotation(wpn._spindrive_angle, 0, 0))
			elseif stats.spin_axis == "y" then
				obj:set_local_rotation(Rotation(0, wpn._spindrive_angle, 0))
			else
				obj:set_local_rotation(Rotation(0, 0, wpn._spindrive_angle))
			end
		end
	end
end)
