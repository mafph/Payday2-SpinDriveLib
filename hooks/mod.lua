local SD = _G.SpinDrive

local stats = {
	accel_time = 0.80,
	decel_time = 1.00,
	base_rpm = 3000,
	peak_rpm = 4500,
	rpm_pct_min = 0.13,
	accuracy_penalty = 0.5
}


SD.register("name", stats)

