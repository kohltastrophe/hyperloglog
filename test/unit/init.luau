--!nonstrict
local IS_ROBLOX = game ~= nil

if IS_ROBLOX then
	local count = 0
	for _, child in script:GetChildren() do
		if child:IsA("ModuleScript") then
			require(child)
			count += 1
		end
	end
	assert(count > 0, "Expected at least one unit spec ModuleScript")
else
	local spec = require("./unit/HyperLogLog.spec")
	assert(type(spec) == "table", "Expected HyperLogLog.spec to return a module table")
end

return {}
