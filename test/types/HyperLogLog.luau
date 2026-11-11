--!strict
local HyperLogLog = require("../../src")

type HLL = HyperLogLog.HLL
type Counter = HyperLogLog.HyperLogLog

local hll: Counter = HyperLogLog.new()
local hllCustom: Counter = HyperLogLog.new(10)

hll:add(123)
hll:add("hello")
hll:add(buffer.create(8))

local count: number = hll:estimate()
assert(count >= 0)

local copy: Counter = hll:clone()
copy:clear()

hll:merge(hllCustom)

local serialized: buffer = hll:serialize()
local restored: Counter? = HyperLogLog.deserialize(serialized)

if restored then
	local raw: HLL = {
		p = restored.p,
		m = restored.m,
		alpha = restored.alpha,
		buffer = restored.buffer,
		_sparse = restored._sparse,
		_count = restored._count,
		_sum = restored._sum,
		_zeros = restored._zeros,
	}
	assert(raw.p == 14)
end

return nil
