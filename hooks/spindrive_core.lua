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

local function get_src(wpn)
	if not wpn._spin_src then
		wpn._spin_src = SoundDevice:create_source("spindrive_spin")
		wpn._spin_src:link(wpn._unit:orientation_object())
	end
	return wpn._spin_src
end

local function update_spin_sound(wpn, pct, dt)
	local MIN_INT, MAX_INT = 0.05, 0.60
	local MIN_SPEED = 0.10
	
	if pct < MIN_SPEED then
		wpn._spin_snd_t = nil
		return
	end
	local interval = MAX_INT + (MIN_INT - MAX_INT) * pct
	wpn._spin_snd_t = (wpn._spin_snd_t or 0) - dt
	if wpn._spin_snd_t <= 0 then
		get_src(wpn):post_event("minigun_stop")
		wpn._spin_snd_t = interval
	end
end

local function rotatePart(base, partId, axis, angle)
	local part = base and base._parts and base._parts[partId]
	if not part or not part.unit or not alive(part.unit) then return end
	local obj = part.unit:orientation_object()
	if not obj then return end
	if axis == "x" then
		obj:set_local_rotation(Rotation(angle, 0, 0))
	elseif axis == "y" then
		obj:set_local_rotation(Rotation(0, angle, 0))
	else
		obj:set_local_rotation(Rotation(0, 0, angle))
	end
end

local function spinBarrel(wpn, pct, dt)
	local stats = wpn._spindrive_stats
	wpn._spindrive_angle = (wpn._spindrive_angle or 0) + stats.peak_rpm * (6 / stats.n_barrels) * pct * dt

	rotatePart(wpn, wpn._spindrive_partId, stats.spin_axis, wpn._spindrive_angle)

	if wpn._second_gun and alive(wpn._second_gun) then
		local second = wpn._second_gun:base()
		if second and second ~= wpn then
			rotatePart(second, wpn._spindrive_partId, stats.spin_axis, wpn._spindrive_angle)
		end
	end
end

function SD.updateSpin(wpn, pct, dt)
	spinBarrel(wpn, pct, dt)
	update_spin_sound(wpn, pct, dt)
end

Hooks:PostHook(NewRaycastWeaponBase, "spread_multiplier", "SpinDriveSpreadMul", function(self, current_state)
    local vanilla = Hooks:GetReturn()
    return vanilla + (self._spindrive_acc_pen * self._spindrive_pct^1.5 or 0)
end)

Hooks:PostHook(NewRaycastWeaponBase, "fire_rate_multiplier", "SpinDriveFireRateMul", function(self)
    local vanilla = Hooks:GetReturn()
    return vanilla * (self._spindrive_mult or 1)
end)

Hooks:PostHook(NewRaycastWeaponBase, "clbk_assembly_complete", "spindrive_init", function(self,...)
    local partId, stats = _G.SpinDrive.getPartStats(self)
	self._spindrive_partId = partId
	self._spindrive_stats = stats
	self._spindrive_mult = stats and stats.rpm_pct_min or 1
	self._spindrive_acc_pen = stats and stats.spread_penalty or 0
	self._spindrive_pct = 0
	self._spindrive_angle = 0
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

			SD.updateSpin(wpn, pct, dt)
		end
	end
end)
