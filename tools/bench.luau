--!optimize 2
--!native
--!strict
--[[
	Reproducible HyperLogLog++ benchmark suite.
	Run in Luau VM (Client):     .sert/bin/luau -O2 tools/bench.luau
	Run in Luau Native (Server): .sert/bin/luau -O2 --codegen tools/bench.luau
]]

local HyperLogLog = require("../src")

local function runBench(name: string, iters: number, fn: () -> ())
	fn()
	fn()
	local t0 = os.clock()
	for _ = 1, iters do
		fn()
	end
	local elapsed = os.clock() - t0
	print(string.format("%-44s %8.2f ms | %8.3f us/iter", name, elapsed * 1e3, (elapsed * 1e6) / iters))
end

local denseA = HyperLogLog.new(14)
local denseB = HyperLogLog.new(14)
for i = 1, 20_000 do
	denseA:add(i)
end
for i = 10_001, 30_000 do
	denseB:add(i)
end
local denseBytes = denseA:serialize()

local sparse2k = HyperLogLog.new(14)
for i = 1, 2_000 do
	sparse2k:add(i)
end
local sparse2kBytes = sparse2k:serialize()

-- Sparse counter right at p=14 max sparse load (3,072 registers inside 16 KB sparse buffer)
local sparseAtMax = HyperLogLog.new(14)
do
	local i = 1
	while sparseAtMax._sparse ~= nil and sparseAtMax._count < 3_072 do
		sparseAtMax:add(i)
		i += 1
	end
end

local shortStrs = table.create(1_000) :: { string }
local medStrs = table.create(1_000) :: { string }
local bufs16 = table.create(1_000) :: { buffer }
for i = 1, 1_000 do
	shortStrs[i] = string.format("u%d", i)
	medStrs[i] = string.format("player:session:uuid:%08d:extra", i)
	local b = buffer.create(16)
	buffer.writeu32(b, 0, i)
	buffer.writeu32(b, 4, i * 31)
	bufs16[i] = b
end

print(string.format("%-44s %11s | %15s", "Benchmark (p = 14 unless noted)", "Total", "Per Iteration"))
print(string.rep("-", 76))

runBench("add(number) x1000 [dense]", 200, function()
	for i = 1, 1_000 do
		denseA:add(i)
	end
end)

runBench("add(short string <=12B) x1000 [dense]", 200, function()
	for i = 1, 1_000 do
		denseA:add(shortStrs[i])
	end
end)

runBench("add(medium string 34B) x1000 [dense]", 200, function()
	for i = 1, 1_000 do
		denseA:add(medStrs[i])
	end
end)

runBench("add(buffer 16B) x1000 [dense]", 200, function()
	for i = 1, 1_000 do
		denseA:add(bufs16[i])
	end
end)

runBench("new(14) + 5000 add(number) [sparse->dense]", 40, function()
	local h = HyperLogLog.new(14)
	for i = 1, 5_000 do
		h:add(i)
	end
end)

runBench("add(duplicate) x500 at sparse max (3072)", 200, function()
	for i = 1, 500 do
		sparseAtMax:add((i % 100) + 1)
	end
end)

runBench("estimate() uncached [dense]", 500, function()
	denseA._sum = nil
	denseA:estimate()
end)

runBench("estimate() cached [dense]", 5_000, function()
	denseA:estimate()
end)

runBench("estimate() [sparse 2000]", 5_000, function()
	sparse2k:estimate()
end)

runBench("merge(dense, dense)", 500, function()
	denseA:merge(denseB)
end)

runBench("merge(empty sparse, dense)", 500, function()
	local h = HyperLogLog.new(14)
	h:merge(denseB)
end)

runBench("clone() [dense 16KB]", 1_000, function()
	denseA:clone()
end)

runBench("clear() + 100 add(number) [rolling]", 500, function()
	local h = sparse2k:clone()
	h:clear()
	for i = 1, 100 do
		h:add(i)
	end
end)

runBench("serialize() [sparse 2000 -> " .. buffer.len(sparse2kBytes) .. "B]", 200, function()
	sparse2k:serialize()
end)

runBench("deserialize() [sparse 2000]", 200, function()
	HyperLogLog.deserialize(sparse2kBytes)
end)

runBench("serialize() [dense 16385B]", 1_000, function()
	denseA:serialize()
end)

runBench("deserialize() [dense 16385B]", 500, function()
	HyperLogLog.deserialize(denseBytes)
end)
