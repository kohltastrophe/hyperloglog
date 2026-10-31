--!nonstrict
--[[
	HyperLogLog test entry for both headless Luau (`python3 tools/sert.py run`) and Roblox Open Cloud (`sert cloud`).
]]

local IS_ROBLOX = game ~= nil

local sert
local options
if IS_ROBLOX then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	sert = require(ReplicatedStorage:WaitForChild("sert")) :: any
	require(ReplicatedStorage:WaitForChild("unit"))
	options = {}
else
	sert = require("@sert") :: any
	options = sert.parseCliArgs(...)
	options.command = "python3 tools/sert.py run -a"
	require("./unit")
end

assert(type(sert.run) == "function", "Expected sert.run to be a function")
return sert.run(options)
