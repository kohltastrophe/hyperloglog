--!strict
--[[
	Compile-fail type probes for HyperLogLog. Every marked line must fail under both `new` and `old` Luau solvers,
	and no other line may fail.
]]

local HyperLogLog = require("../../../src")

local hll = HyperLogLog.new()

local _badPrecision: HyperLogLog.HyperLogLog = HyperLogLog.new("14") -- expect-error: precision must be number?
hll:add(true) -- expect-error: item must be buffer | number | string
hll:add({}) -- expect-error: table is not a valid item
local _badEst: string = hll:estimate() -- expect-error: estimate returns number
hll:merge({} :: { p: number }) -- expect-error: merge requires a HyperLogLog instance
local _badClone: string = hll:clone() -- expect-error: clone returns HyperLogLog
local _badClear: number = hll:clear() -- expect-error: clear returns ()
local _badSer: string = hll:serialize() -- expect-error: serialize returns buffer
local _badDeserArg = HyperLogLog.deserialize("bytes") -- expect-error: deserialize expects buffer
local _badDeserNonNull: HyperLogLog.HyperLogLog = HyperLogLog.deserialize(buffer.create(0)) -- expect-error: deserialize returns HyperLogLog?

return nil
