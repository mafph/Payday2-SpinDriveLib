_G.SpinDrive = _G.SpinDrive or {}
local SD = _G.SpinDrive

SD.registeredMods = SD.registeredMods or {}

function SD.register(name, stats)
	table.insert(SD.registeredMods, stats)
end
