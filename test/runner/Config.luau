--!nonstrict
--[[
	Configuration for sert's Studio runner (`python3 tools/sert.py studio` runs `Runner.edit` in the edit DataModel).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local unit = ReplicatedStorage:WaitForChild("unit")
assert(unit:IsA("ModuleScript"), "Expected ReplicatedStorage.unit to be a ModuleScript")

return {
	name = "HyperLogLog",
	characters = false,
	sides = {
		core = { entry = unit },
	},
}
