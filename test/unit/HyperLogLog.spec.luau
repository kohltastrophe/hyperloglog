--!nonstrict
local IS_ROBLOX = game ~= nil

local sert = if IS_ROBLOX
	then require(game:GetService("ReplicatedStorage"):WaitForChild("sert")) :: any
	else require("@sert") :: any

local cachedHLL: any = nil
local cachedEnv: any = nil
local cachedMutant: any = false

local function getHLL()
	if IS_ROBLOX then
		if not cachedHLL then
			cachedHLL = require(game:GetService("ReplicatedStorage"):WaitForChild("HyperLogLog"))
		end
		return cachedHLL, nil
	end

	local activeMutant = (_G :: any).__SERT_MUTANT
	if not cachedHLL or cachedMutant ~= activeMutant then
		cachedMutant = activeMutant
		cachedEnv = sert.env.new()
		local root = cachedEnv:mount((require :: any)("@stage"), cachedEnv.game:GetService("ReplicatedStorage"))
		cachedHLL = cachedEnv:require(root)
	end
	return cachedHLL, cachedEnv
end

local function makeDense(p: number, registers: { [number]: number }): buffer
	local b = buffer.create(1 + 2 ^ p)
	buffer.writeu8(b, 0, p)
	for index, rho in registers do
		buffer.writeu8(b, index, rho)
	end
	return b
end

local function writeVarInt(bytes: { number }, value: number)
	while value >= 128 do
		table.insert(bytes, value % 128 + 128)
		value //= 128
	end
	table.insert(bytes, value)
end

local function makeSparse(p: number, count: number, deltas: { number }, extraBytes: { number }?): buffer
	local bytes = {}
	for _, delta in deltas do
		writeVarInt(bytes, delta)
	end
	if extraBytes then
		for _, b in extraBytes do
			table.insert(bytes, b)
		end
	end

	local b = buffer.create(5 + #bytes)
	buffer.writeu8(b, 0, p + 128)
	buffer.writeu32(b, 1, count)
	for i, byte in bytes do
		buffer.writeu8(b, 4 + i, byte)
	end
	return b
end

local function toDenseCopy(HyperLogLog: any, hll: any)
	local dense = HyperLogLog.new(hll.p)
	dense.sparse_registers = nil
	dense.buffer = makeDense(hll.p, {})
	dense:merge(hll)
	return dense
end

sert.test("new · default, custom, and clamped precisions with alpha constants", function()
	local HyperLogLog = getHLL()

	local hll = HyperLogLog.new()
	sert.eq(hll.p, 14)
	sert.eq(hll.m, 16384)
	sert(hll.sparse_registers ~= nil)
	sert.eq(hll.buffer, nil)
	sert.eq(hll.sparse_count, 0)
	sert.eq(hll:estimate(), 0)

	local hll10 = HyperLogLog.new(10)
	sert.eq(hll10.p, 10)
	sert.eq(hll10.m, 1024)

	local hllMin = HyperLogLog.new(0)
	sert.eq(hllMin.p, 4)
	sert.eq(hllMin.m, 16)
	sert.near(hllMin.alpha, 0.673101517 * 256, 1e-6)

	local hll5 = HyperLogLog.new(5)
	sert.eq(hll5.p, 5)
	sert.near(hll5.alpha, 0.697121585 * 1024, 1e-6)

	local hll6 = HyperLogLog.new(6)
	sert.eq(hll6.p, 6)
	sert.near(hll6.alpha, 0.709209798 * 4096, 1e-6)

	local hll7 = HyperLogLog.new(7)
	sert.eq(hll7.p, 7)
	sert.near(hll7.alpha, (0.7213 / (1 + 1.079 / 128)) * 16384, 1e-6)

	local hllMax = HyperLogLog.new(30)
	sert.eq(hllMax.p, 18)
	sert.eq(hllMax.m, 262144)

	local hllFrac = HyperLogLog.new(8.9)
	sert.eq(hllFrac.p, 8)
end)

sert.test("add & estimate · numbers, strings, buffers, and duplicate items", function()
	local HyperLogLog = getHLL()

	local hll = HyperLogLog.new()
	for i = 1, 100 do
		hll:add(i)
	end
	sert.near(hll:estimate(), 100, 5)

	for i = 1, 100 do
		hll:add(i)
	end
	sert.near(hll:estimate(), 100, 5)

	-- Numbers match 8-byte little-endian f64 buffers, and -0 canonicalizes to 0
	local numHll = HyperLogLog.new()
	local f64BufHll = HyperLogLog.new()
	for _, x in { 0, 1, -42.5, math.pi, 1e50 } do
		numHll:add(x)
		local b = buffer.create(8)
		buffer.writef64(b, 0, x)
		f64BufHll:add(b)
	end
	numHll:add(-0.0)
	sert.eq(numHll:serialize(), f64BufHll:serialize())

	-- Strings across empty, tail (1..11), exact 12-byte block, and multi-block (>1024B scratch growth) match buffers
	local strHll = HyperLogLog.new()
	local bufHll = HyperLogLog.new()
	local samples = {
		"ten_bytes!",
		"nine_byte",
		"",
		"a",
		"ab",
		"abc",
		"apple",
		"banana",
		"cherry",
		"twelve_bytes",
		string.rep("xyz", 30),
		string.rep("xyz", 400),
	}
	for _, s in samples do
		strHll:add(s)
	end
	for i = #samples, 1, -1 do
		bufHll:add(buffer.fromstring(samples[i]))
	end
	strHll:add("apple")
	sert.eq(strHll:estimate(), 12)
	sert.eq(bufHll:serialize(), strHll:serialize())
end)

sert.test("sparse to dense transition · switches strictly above m * 0.25 sparse registers", function()
	local HyperLogLog = getHLL()

	-- p = 4 -> m = 16 -> threshold is 4
	local hll = HyperLogLog.new(4)
	for i = 1, 4 do
		hll:add(i)
	end
	sert(hll.sparse_registers ~= nil)
	sert.eq(hll.buffer, nil)
	sert.eq(hll:estimate(), 4)
	sert.eq(hll.sparse_count, 4)

	-- Re-adding an existing item does not increment sparse_count or trigger conversion
	hll:add(1)
	sert(hll.sparse_registers ~= nil)
	sert.eq(hll:estimate(), 4)
	sert.eq(hll.sparse_count, 4)

	hll:add(5)
	sert.eq(hll.sparse_registers, nil)
	sert(hll.buffer ~= nil)
	sert.eq(hll.sparse_count, 0)
	sert.eq(buffer.len(hll.buffer), 17)
	sert.eq(buffer.readu8(hll.buffer, 0), 4)
end)

-- Exact inverse of the 12-byte lookup3 hash so tests can deterministically hit any target (hi, lo)
local function craftHash12(hi: number, lo: number): buffer
	local bxor = bit32.bxor
	local lrotate = bit32.lrotate
	local bor = bit32.bor

	local c, b, a = hi, lo, 0

	-- Invert final
	b = bxor(bor(b + lrotate(a, 25), 0), a)
	a = bxor(bor(a + lrotate(c, 11), 0), c)
	c = bxor(bor(c + lrotate(b, 24), 0), b)
	b = bxor(bor(b + lrotate(a, 14), 0), a)
	a = bxor(bor(a + lrotate(c, 4), 0), c)
	c = bxor(bor(c + lrotate(b, 16), 0), b)
	b = bxor(bor(b + lrotate(a, 25), 0), a)
	a = bxor(bor(a + lrotate(c, 11), 0), c)
	c = bxor(bor(c + lrotate(b, 14), 0), b)

	-- Invert mix
	b = bor(b - a, 0)
	c = bor(bxor(c, lrotate(b, 4)) + b, 0)
	a = bor(a - c, 0)
	b = bor(bxor(b, lrotate(a, 19)) + a, 0)
	c = bor(c - b, 0)
	a = bor(bxor(a, lrotate(c, 16)) + c, 0)
	b = bor(b - a, 0)
	c = bor(bxor(c, lrotate(b, 8)) + b, 0)
	a = bor(a - c, 0)
	b = bor(bxor(b, lrotate(a, 6)) + a, 0)
	c = bor(c - b, 0)
	a = bor(bxor(a, lrotate(c, 4)) + c, 0)

	local out = buffer.create(12)
	buffer.writeu32(out, 0, bor(a - (0xDEADBEEF + 12), 0))
	buffer.writeu32(out, 4, bor(b - (0x9E3779B9 + 12), 0))
	buffer.writeu32(out, 8, bor(c - (0x85EBCA6B + 12), 0))
	return out
end

sert.test("getRho & raiseSparse · handles upper-32 zero run into lo and raising existing sparse register", function()
	local HyperLogLog = getHLL()

	local hll = HyperLogLog.new(14)
	-- Sparse: top 25 bits = index 5, bottom 7 bits of hi = 0, lo has 4 leading zeros -> rho = 7 + 4 + 1 = 12
	hll:add(craftHash12(bit32.lshift(5, 7), 0x08000000))
	sert.eq(hll:serialize(), makeSparse(14, 1, { 5 * 64 + 12 }))
	sert.eq(hll.sparse_count, 1)

	-- Same sparse index 5, smaller rho (bottom 7 bits has 1 at bit 6 -> rho = 1): should not lower register
	hll:add(craftHash12(bit32.lshift(5, 7) + 64, 0))
	sert.eq(hll:serialize(), makeSparse(14, 1, { 5 * 64 + 12 }))
	sert.eq(hll.sparse_count, 1)
	sert.eq(#hll.sparse_registers, 1)

	-- Same sparse index 5, larger rho (bottom 7 bits = 0, lo = 0 -> rho = 7 + 32 + 1 = 40): raises register
	hll:add(craftHash12(bit32.lshift(5, 7), 0))
	sert.eq(hll:serialize(), makeSparse(14, 1, { 5 * 64 + 40 }))
	sert.eq(hll.sparse_count, 1)
end)

sert.test(
	"estimate · matches HLL++ reference values across sparse, linear counting, bias-corrected, and large ranges",
	function()
		local HyperLogLog = getHLL()

		-- Sparse linear counting over 2^25 registers
		local sparse = HyperLogLog.new(4)
		sparse.sparse_registers = { 1, 64 + 1, 128 + 1 }
		sparse.sparse_count = 3
		sert.eq(sparse:estimate(), 3)

		sparse.sparse_count = 1000
		sert.eq(sparse:estimate(), 1000)

		local function denseWith(p: number, fill: number, overrides: { [number]: number }?)
			local regs = table.create(2 ^ p, fill)
			if overrides then
				for index, rho in overrides do
					regs[index] = rho
				end
			end
			local h = HyperLogLog.new(p)
			h.sparse_registers = nil
			h.buffer = makeDense(p, regs)
			return h
		end

		-- Dense linear counting: p=4 (m=16, threshold=10), 8 zeros -> 16 * ln(2) = 11.09 > 10, falls through to bias-corrected
		sert.eq(
			denseWith(4, 1, { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0, [7] = 0, [8] = 0 }):estimate(),
			7
		)
		-- 10 zeros -> 16 * ln(16/10) = 7.52 <= 10, uses linear counting
		sert.eq(
			denseWith(4, 1, {
				[1] = 0,
				[2] = 0,
				[3] = 0,
				[4] = 0,
				[5] = 0,
				[6] = 0,
				[7] = 0,
				[8] = 0,
				[9] = 0,
				[10] = 0,
			}):estimate(),
			8
		)

		-- Dense with no zeros, raw <= 5*m: raw estimate minus interpolated bias
		sert.eq(denseWith(4, 1):estimate(), 18) -- raw 21.54, interpolated bias 3.46 -> 18.08 -> 18
		sert.eq(denseWith(4, 2):estimate(), 43) -- raw 43.08, interpolated bias -0.18 -> 43.26 -> 43
		sert.eq(denseWith(4, 3):estimate(), 86) -- raw 86.16 > 5*16 = 80, no bias correction -> 86
		sert.eq(denseWith(6, 2):estimate(), 179) -- raw 181.56 <= 5*64 = 320, interpolated bias 2.30 -> 179
		sert.eq(denseWith(6, 3):estimate(), 363) -- raw 363.12 > 320, no bias correction -> 363

		-- Bias clamp above MEAN_DATA[1][78] (77.2394) while raw <= 5*m (80):
		-- raw = 172.313988352 / 2.1875 = 78.7721 > 77.2394, biases[78] = -1.7606 -> 78.7721 - (-1.7606) = 80.53 -> 81
		local aboveMaxMean = denseWith(4, 3, { [1] = 2, [2] = 2, [3] = 2, [4] = 5, [5] = 5 })
		sert.eq(aboveMaxMean:estimate(), 81)

		-- Reference test vectors from test/reference_estimates.py across p = 4..18
		local function constant(rho: number): (number) -> number
			return function()
				return rho
			end
		end

		local function leadingOnes(count: number): (number) -> number
			return function(j: number)
				return if j < count then 1 else 0
			end
		end

		local function cycle(first: number, period: number): (number) -> number
			return function(j: number)
				return first + j % period
			end
		end

		local function geometric(first: number, gap: number?): (number) -> number
			if gap then
				return function(j: number)
					return if j % gap == 0 then 0 else first + bit32.countrz(j)
				end
			end
			return function(j: number)
				return first + bit32.countrz(j + 1)
			end
		end

		local referenceCases = {
			{ name = "raw, alpha for m=16", p = 4, rule = constant(4), expected = 172 },
			{ name = "raw, alpha for m=32", p = 5, rule = constant(3), expected = 178 },
			{ name = "raw, alpha for m=64", p = 6, rule = constant(5), expected = 1452 },
			{ name = "raw, alpha for m=1024", p = 10, rule = constant(3), expected = 5903 },
			{ name = "linear counting", p = 10, rule = leadingOnes(100), expected = 105 },
			{ name = "linear counting", p = 14, rule = leadingOnes(1000), expected = 1032 },
			{ name = "bias corrected", p = 4, rule = cycle(0, 3), expected = 12 },
			{ name = "bias corrected", p = 6, rule = cycle(1, 4), expected = 192 },
			{ name = "bias corrected", p = 10, rule = constant(2), expected = 2918 },
			{ name = "bias corrected with empty registers", p = 12, rule = geometric(1, 4), expected = 3901 },
			{ name = "bias corrected", p = 14, rule = geometric(1), expected = 33787 },
			{ name = "bias corrected with empty registers", p = 14, rule = geometric(1, 3), expected = 15981 },
			{ name = "bias corrected", p = 18, rule = geometric(2), expected = 1134485 },
		}

		for _, case in referenceCases do
			local m = 2 ^ case.p
			local b = buffer.create(1 + m)
			buffer.writeu8(b, 0, case.p)
			for j = 0, m - 1 do
				buffer.writeu8(b, 1 + j, case.rule(j))
			end
			local restored = HyperLogLog.deserialize(b)
			sert(restored ~= nil)
			sert.eq(restored:estimate(), case.expected)
			-- Second call exercises the cached _sum / _zeros fast path
			sert.eq(restored:estimate(), case.expected)
		end
	end
)

sert.test("estimate · bias correction at an exact reference point and below minimum mean", function()
	local HyperLogLog = getHLL()

	-- At p=4, MEAN_DATA[1][5] = 13.2882 and BIAS_DATA[1][5] = 8.2882 (so corrected = 5).
	local hll = HyperLogLog.new(4)
	hll.sparse_registers = nil
	hll.buffer = makeDense(4, table.create(16, 1)) -- sum = 16 * 2^-1 = 8
	hll.alpha = 13.2882 * 8
	sert.eq(hll:estimate(), 5)

	-- Setting alpha = 10.4 * 8 makes raw = 10.4 < MEAN_DATA[1][1] (11), clamping to BIAS_DATA[1][1] (10) -> round(0.4) = 0.
	hll.alpha = 10.4 * 8
	sert.eq(hll:estimate(), 0)
end)

sert.test("duplicates and insertion order do not change serialized registers", function()
	local HyperLogLog = getHLL()

	for _, count in { 20, 200 } do
		local forward = HyperLogLog.new(6)
		local reverse = HyperLogLog.new(6)
		local duplicated = HyperLogLog.new(6)

		for i = 1, count do
			forward:add(i)
			reverse:add(count - i + 1)
			duplicated:add(i)
			duplicated:add(i)
		end

		local sForward = forward:serialize()
		sert.eq(reverse:serialize(), sForward)
		sert.eq(duplicated:serialize(), sForward)
	end
end)

sert.test("merge · union across all sparse/dense combinations and error on precision mismatch", function()
	local HyperLogLog = getHLL()

	-- 1. Sparse + Sparse (staying sparse)
	local s1 = HyperLogLog.new(10)
	local s2 = HyperLogLog.new(10)
	local sUnion = HyperLogLog.new(10)
	for i = 1, 10 do
		s1:add(i)
		sUnion:add(i)
	end
	for i = 6, 15 do
		s2:add(i)
		sUnion:add(i)
	end
	s1:merge(s2)
	sert(s1.sparse_registers ~= nil)
	sert.eq(s1:serialize(), sUnion:serialize())

	-- 2. Sparse + Sparse (crossing threshold into dense)
	local sc1 = HyperLogLog.new(4) -- threshold = 4
	local sc2 = HyperLogLog.new(4)
	local scUnion = HyperLogLog.new(4)
	for i = 1, 3 do
		sc1:add(i)
		scUnion:add(i)
	end
	for i = 4, 6 do
		sc2:add(i)
		scUnion:add(i)
	end
	sert(sc1.sparse_registers ~= nil)
	sert(sc2.sparse_registers ~= nil)
	sc1:merge(sc2)
	sert.eq(sc1.sparse_registers, nil)
	sert.eq(sc1:serialize(), scUnion:serialize())

	-- 3. Dense + Sparse and Sparse + Dense
	local dBase = HyperLogLog.new(4)
	local sExtra = HyperLogLog.new(4)
	local dsUnion = HyperLogLog.new(4)
	for i = 1, 10 do
		dBase:add(i)
		dsUnion:add(i)
	end
	for i = 11, 13 do
		sExtra:add(i)
		dsUnion:add(i)
	end
	sert.eq(dBase.sparse_registers, nil)
	sert(sExtra.sparse_registers ~= nil)

	local dIntoS = HyperLogLog.deserialize(sExtra:serialize())
	local sIntoD = HyperLogLog.deserialize(dBase:serialize())
	dIntoS:merge(dBase)
	sIntoD:merge(sExtra)
	sert.eq(dIntoS.sparse_registers, nil)
	sert.eq(dIntoS:serialize(), dsUnion:serialize())
	sert.eq(sIntoD:serialize(), dsUnion:serialize())

	-- 4. Dense + Dense (covering all 4 register lanes i, i+1, i+2, i+3 and identical u32 chunks)
	local dd1 = HyperLogLog.new(4)
	local dd2 = HyperLogLog.new(4)
	dd1.sparse_registers = nil
	dd2.sparse_registers = nil
	dd1.buffer = makeDense(4, {
		10,
		2,
		10,
		2, -- chunk 1: lanes 1,3 higher in dd1; lanes 2,4 higher in dd2
		5,
		5,
		5,
		5, -- chunk 2: identical 4-byte chunk (skipped via readu32 fast path)
		1,
		8,
		1,
		8, -- chunk 3: lanes 1,3 higher in dd2; lanes 2,4 higher in dd1
		4,
		4,
		4,
		4, -- chunk 4: all higher in dd2
	})
	dd2.buffer = makeDense(4, {
		3,
		9,
		3,
		9,
		5,
		5,
		5,
		5,
		7,
		2,
		7,
		2,
		6,
		7,
		8,
		9,
	})
	local preMergeEst = dd1:estimate()
	dd1:merge(dd2)
	sert(dd1:estimate() > preMergeEst)
	-- Merging an already-dominated dense counter does not change estimate
	local postMergeEst = dd1:estimate()
	dd1:merge(dd2)
	sert.eq(dd1:estimate(), postMergeEst)
	sert.eq(
		dd1:serialize(),
		makeDense(4, {
			10,
			9,
			10,
			9,
			5,
			5,
			5,
			5,
			7,
			8,
			7,
			8,
			6,
			7,
			8,
			9,
		})
	)

	-- 5. Precision mismatch throws
	sert.fails(function()
		local a = HyperLogLog.new(8)
		local b = HyperLogLog.new(10)
		a:merge(b)
	end, "Cannot merge HyperLogLog objects with different precision")
end)

sert.test(
	"serialize & deserialize · empty, varint width boundaries, dense copy isolation, and oversize sparse",
	function()
		local HyperLogLog = getHLL()

		-- Empty sparse counter
		local empty = HyperLogLog.new(10)
		local emptyBuf = empty:serialize()
		sert.eq(buffer.len(emptyBuf), 5)
		local emptyRestored = HyperLogLog.deserialize(emptyBuf)
		sert(emptyRestored ~= nil)
		sert.eq(emptyRestored.p, 10)
		sert.eq(emptyRestored.sparse_count, 0)
		sert.eq(emptyRestored:estimate(), 0)

		-- Sparse varint width boundaries (1, 2, 3, 4, and 5 bytes)
		-- Each entry is value = index * 64 + rho (with 1 <= rho <= 40, 0 <= index < 2^25).
		local boundaryVarintHll = HyperLogLog.new(14)
		boundaryVarintHll.sparse_registers = {
			1 * 64 + 1, -- value = 65 (< 128 -> 1-byte varint)
			3 * 64 + 2, -- delta = 194 - 65 = 129 (< 16384 -> 2-byte varint)
			300 * 64 + 3, -- delta = 19203 - 194 = 19009 (< 2097152 -> 3-byte varint)
			40000 * 64 + 4, -- delta = 2560004 - 19203 = 2540801 (< 268435456 -> 4-byte varint)
			5000000 * 64 + 5, -- delta = 320000005 - 2560004 = 317440001 (>= 268435456 -> 5-byte varint)
		}
		boundaryVarintHll.sparse_count = 5
		local boundaryData = boundaryVarintHll:serialize()
		sert.eq(buffer.len(boundaryData), 5 + 1 + 2 + 3 + 4 + 5)
		local boundaryRestored = HyperLogLog.deserialize(boundaryData)
		sert(boundaryRestored ~= nil)
		sert.eq(boundaryRestored:serialize(), boundaryData)

		-- Exact varint threshold boundaries: 127 vs 128, 16383 vs 16384, 2097151 vs 2097152, 268435455 vs 268435456
		for _, targetValue in { 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 268435456 } do
			-- Pick rho in 1..40 so value = index * 64 + rho == targetValue, or test via two entries if targetValue % 64 == 0
			local rem = targetValue % 64
			local h = HyperLogLog.new(14)
			if rem >= 1 and rem <= 40 then
				h.sparse_registers = { targetValue }
				h.sparse_count = 1
			else
				-- First entry at value = 32 (index 0, rho 32), second entry at value = 32 + targetValue
				h.sparse_registers = { 32, 32 + targetValue }
				h.sparse_count = 2
			end
			local enc = h:serialize()
			local dec = HyperLogLog.deserialize(enc)
			sert(dec ~= nil)
			sert.eq(dec:serialize(), enc)
		end

		-- Large sparse counter (>204 registers) exercises scratch buffer reallocation during serialize
		local largeSparse = HyperLogLog.new(12)
		for i = 1, 500 do
			largeSparse:add(i)
		end
		local largeSparseData = largeSparse:serialize()
		local largeSparseRestored = HyperLogLog.deserialize(largeSparseData)
		sert(largeSparseRestored ~= nil)
		sert.eq(largeSparseRestored:serialize(), largeSparseData)

		-- Dense round-trip and buffer isolation
		local dense = HyperLogLog.new(4)
		for i = 1, 20 do
			dense:add(i)
		end
		sert.eq(dense.sparse_registers, nil)
		local denseData = dense:serialize()
		local denseSnapshot = buffer.tostring(denseData)
		local denseRestored = HyperLogLog.deserialize(denseData)
		sert(denseRestored ~= nil)
		sert.eq(denseRestored.sparse_registers, nil)
		sert.eq(denseRestored:serialize(), denseData)

		-- Mutating caller's input buffer after deserialize does not affect restored HLL
		buffer.writeu8(denseData, 1, 60)
		sert.eq(buffer.tostring(denseRestored:serialize()), denseSnapshot)

		-- Mutating buffer returned by serialize does not affect source HLL
		local serializedOut = denseRestored:serialize()
		buffer.writeu8(serializedOut, 1, 60)
		sert.eq(buffer.tostring(denseRestored:serialize()), denseSnapshot)

		-- Sparse payload with count > m * 0.25 folds to dense upon deserialize
		local over = makeSparse(4, 5, { 1, 64, 64, 64, 64 })
		local overRestored = HyperLogLog.deserialize(over)
		sert(overRestored ~= nil)
		sert.eq(overRestored.sparse_registers, nil)
		sert(overRestored.buffer ~= nil)

		-- Sparse payload with count == m * 0.25 stays sparse upon deserialize
		local exactThreshold = makeSparse(4, 4, { 1, 64, 64, 64 })
		local exactRestored = HyperLogLog.deserialize(exactThreshold)
		sert(exactRestored ~= nil)
		sert(exactRestored.sparse_registers ~= nil)
		sert.eq(exactRestored.buffer, nil)
	end
)

sert.test("deserialize · rejects invalid buffers, precisions, dense ranks, and malformed sparse encodings", function()
	local HyperLogLog = getHLL()

	-- Non-buffer inputs
	sert.eq(HyperLogLog.deserialize(nil :: any), nil)
	sert.eq(HyperLogLog.deserialize(123 :: any), nil)
	sert.eq(HyperLogLog.deserialize("not a buffer" :: any), nil)
	sert.eq(HyperLogLog.deserialize({} :: any), nil)

	-- Empty buffer
	sert.eq(HyperLogLog.deserialize(buffer.create(0)), nil)

	-- Precision out of range [4, 18]
	for _, p in { 0, 3, 19, 127 } do
		local bDense = buffer.create(1 + 2 ^ math.clamp(p, 4, 18))
		buffer.writeu8(bDense, 0, p)
		sert.eq(HyperLogLog.deserialize(bDense), nil)

		local bSparse = buffer.create(5)
		buffer.writeu8(bSparse, 0, p + 128)
		sert.eq(HyperLogLog.deserialize(bSparse), nil)
	end

	-- Precision boundaries 4 and 18 are valid
	local validP4 = makeDense(4, {})
	sert(HyperLogLog.deserialize(validP4) ~= nil)
	local validP18 = makeSparse(18, 0, {})
	sert(HyperLogLog.deserialize(validP18) ~= nil)

	-- Dense wrong length
	for _, len in { 1, 16, 18 } do
		local b = buffer.create(len)
		buffer.writeu8(b, 0, 4)
		sert.eq(HyperLogLog.deserialize(b), nil)
	end

	-- Dense register rank bounds: max valid rho is 64 - p + 1 (61 for p = 4)
	local maxValidDense = makeDense(4, { [16] = 61 })
	local restoredMaxDense = HyperLogLog.deserialize(maxValidDense)
	sert(restoredMaxDense ~= nil)
	sert.eq(buffer.readu8(restoredMaxDense.buffer, 16), 61)

	local invalidDense62 = makeDense(4, { [1] = 62 })
	sert.eq(HyperLogLog.deserialize(invalidDense62), nil)

	local invalidDense255 = makeDense(4, { [16] = 255 })
	sert.eq(HyperLogLog.deserialize(invalidDense255), nil)

	-- Sparse buffer shorter than 5-byte header
	for len = 1, 4 do
		local b = buffer.create(len)
		buffer.writeu8(b, 0, 4 + 128)
		sert.eq(HyperLogLog.deserialize(b), nil)
	end

	-- Sparse count with missing varint bytes
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 1, {})), nil)
	-- Truncated mid-varint (continuation bit set on final byte)
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 1, {}, { 0x80 })), nil)
	-- Varint longer than 5 bytes (5 continuation bytes + 1 terminator)
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 1, {}, { 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 })), nil)
	-- Trailing bytes after all count entries
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 0, {}, { 0x01 })), nil)

	-- Sparse rho bounds: rho == 0 is invalid, rho == 40 (SPARSE_MAX_RHO) is valid, rho == 41 is invalid
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 1, { 0 })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 1, { 64 })), nil)
	sert(HyperLogLog.deserialize(makeSparse(4, 1, { 40 })) ~= nil)
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 1, { 41 })), nil)

	-- Sparse index bounds: index == 2^25 - 1 is valid, index == 2^25 is invalid
	local maxSparseIndex = 2 ^ 25 - 1
	sert(HyperLogLog.deserialize(makeSparse(4, 1, { maxSparseIndex * 64 + 1 })) ~= nil)
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 1, { (maxSparseIndex + 1) * 64 + 1 })), nil)

	-- Sparse non-monotonic indices: duplicate index (delta = 1 within same index)
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 2, { 1, 0 })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparse(4, 2, { 1, 1 })), nil)
end)

sert.test("foldSparse · sparse-to-dense conversion preserves exact dense ranks", function()
	local HyperLogLog = getHLL()

	-- Verify against a counter forced to dense from the start across precisions
	for _, p in { 4, 8, 12 } do
		local sparse = HyperLogLog.new(p)
		local dense = toDenseCopy(HyperLogLog, sparse)

		local limit = math.min(200, math.floor(2 ^ p * 0.25))
		for i = 1, limit do
			sparse:add(i)
			dense:add(i)
		end
		sert(sparse.sparse_registers ~= nil)
		sert.eq(toDenseCopy(HyperLogLog, sparse):serialize(), dense:serialize())
	end

	-- Explicit bit-level verification of foldSparse at p = 4 (diff = 21):
	local hll = HyperLogLog.new(4)
	hll.sparse_registers = {
		-- bucket 0, residual = 0, rho_sparse = 7 -> rho = 7 + 21 = 28
		7,
		-- bucket 1, residual has a 1 at its highest bit (bit 20) -> rho = 1
		(bit32.lshift(1, 21) + bit32.lshift(1, 20)) * 64 + 30,
		-- bucket 2, residual has 5 leading zeros then a 1 (bit 15) -> rho = 6
		(bit32.lshift(2, 21) + bit32.lshift(1, 15)) * 64 + 30,
		-- bucket 3, two entries: residual with bit 19 (rho = 2) and residual = 0 (rho = 3 + 21 = 24); max is 24
		(bit32.lshift(3, 21) + bit32.lshift(1, 19)) * 64 + 1,
		bit32.lshift(3, 21) * 64 + 3,
	}
	hll.sparse_count = 5

	local b = toDenseCopy(HyperLogLog, hll).buffer
	sert.eq(buffer.readu8(b, 1), 28)
	sert.eq(buffer.readu8(b, 2), 1)
	sert.eq(buffer.readu8(b, 3), 6)
	sert.eq(buffer.readu8(b, 4), 24)
end)

-- ============================================================================
-- Property-Based Tests, Codec Laws, and Stateful Model Testing
-- ============================================================================

local gen = sert.gen

local function sketchEq(a: any, b: any): boolean
	return buffer.tostring(a:serialize()) == buffer.tostring(b:serialize()) and a:estimate() == b:estimate()
end

local function genSketch(p: number)
	return function(g: any)
		local HyperLogLog = getHLL()
		local hll = HyperLogLog.new(p)
		local mode = g:pick({ "empty", "sparse", "dense" })
		if mode == "sparse" then
			local maxSparse = math.max(1, math.min(4, math.floor(2 ^ p * 0.25)))
			local n = g:int(1, maxSparse)
			for i = 1, n do
				hll:add(i * 100 + g:int(0, 15))
			end
		elseif mode == "dense" then
			local n = math.floor(2 ^ p * 0.25) + g:int(1, 6)
			for i = 1, n do
				hll:add(i * 10 + g:int(0, 5))
			end
		end
		return hll
	end
end

sert.laws.algebra("HyperLogLog merge", {
	gen = genSketch(4),
	identity = getHLL().new(4),
	associative = true,
	commutative = true,
	idempotent = true,
	op = function(a, b)
		local HyperLogLog = getHLL()
		local out = HyperLogLog.deserialize(a:serialize())
		sert(out ~= nil)
		local rhs = HyperLogLog.deserialize(b:serialize())
		sert(rhs ~= nil)
		out:merge(rhs)
		return out
	end,
	eq = sketchEq,
}, { runs = 50 })

sert.laws.codec("HyperLogLog binary codec", {
	gen = function(g)
		local p = g:pick({ 4, 6, 8, 10 })
		return genSketch(p)(g)
	end,
	encode = function(hll)
		return hll:serialize()
	end,
	decode = function(bytes)
		local HyperLogLog = getHLL()
		local decoded = HyperLogLog.deserialize(bytes)
		sert(decoded ~= nil)
		return decoded
	end,
	eq = sketchEq,
}, { runs = 50 })

sert.laws.codec("HyperLogLog binary codec (serialize / deserialize)", {
	gen = function(g)
		local p = g:pick({ 4, 6, 10 })
		local HyperLogLog = getHLL()
		local hll = HyperLogLog.new(p)
		local mode = g:pick({ "empty", "sparse", "dense" })
		if mode == "sparse" then
			local n = g:int(1, 3)
			for i = 1, n do
				hll:add(i * 10 + g:int(0, 2))
			end
		elseif mode == "dense" then
			local n = math.floor(2 ^ p * 0.25) + g:int(1, 3)
			for i = 1, n do
				hll:add(i)
			end
		end
		return hll
	end,
	encode = function(hll)
		return hll:serialize()
	end,
	decode = function(bytes)
		local HyperLogLog = getHLL()
		local decoded = HyperLogLog.deserialize(bytes)
		sert(decoded ~= nil)
		return decoded
	end,
	eq = sketchEq,
}, { runs = 40, exhaustive = { size = 3 } })

sert.laws.differential("HyperLogLog vs exact set oracle", {
	gen = function(g)
		local p = g:pick({ 4, 6, 8, 10 })
		local threshold = math.floor(2 ^ p * 0.25)
		local maxItems = math.min(threshold + 12, 48)
		local itemPool = gen.oneOf({
			gen.int(-50, 50),
			gen.string("abcd", 0, 16),
		})
		return {
			p = p,
			streamA = g:list(itemPool, 0, maxItems),
			streamB = g:list(itemPool, 0, maxItems),
		}
	end,
	sut = function(input)
		local HyperLogLog = getHLL()
		local p = input.p
		local empty = HyperLogLog.new(p)
		local hllA = HyperLogLog.new(p)
		local hllADup = HyperLogLog.new(p)
		local hllB = HyperLogLog.new(p)

		for _, item in input.streamA do
			hllA:add(item)
			hllADup:add(item)
			hllADup:add(item)
		end
		for _, item in input.streamB do
			hllB:add(item)
		end

		local hllUnion = HyperLogLog.deserialize(hllA:serialize())
		sert(hllUnion ~= nil)
		hllUnion:merge(hllB)

		return {
			p = p,
			estEmpty = empty:estimate(),
			estA = hllA:estimate(),
			estADup = hllADup:estimate(),
			sameADupBytes = buffer.tostring(hllA:serialize()) == buffer.tostring(hllADup:serialize()),
			estB = hllB:estimate(),
			estUnion = hllUnion:estimate(),
		}
	end,
	oracle = function(input)
		local setA: { [any]: boolean } = {}
		local setB: { [any]: boolean } = {}
		local setUnion: { [any]: boolean } = {}
		local countA, countB, countUnion = 0, 0, 0

		for _, item in input.streamA do
			local key = if item == 0 then 0 else item
			if not setA[key] then
				setA[key] = true
				countA += 1
			end
			if not setUnion[key] then
				setUnion[key] = true
				countUnion += 1
			end
		end
		for _, item in input.streamB do
			local key = if item == 0 then 0 else item
			if not setB[key] then
				setB[key] = true
				countB += 1
			end
			if not setUnion[key] then
				setUnion[key] = true
				countUnion += 1
			end
		end

		return {
			p = input.p,
			exactEmpty = 0,
			exactA = countA,
			exactB = countB,
			exactUnion = countUnion,
		}
	end,
	eq = function(got, want)
		if got.estEmpty ~= want.exactEmpty then
			return false
		end
		if not got.sameADupBytes or got.estADup ~= got.estA then
			return false
		end
		if want.exactA == 0 and got.estA ~= 0 then
			return false
		end
		if want.exactB == 0 and got.estB ~= 0 then
			return false
		end
		if want.exactUnion == 0 and got.estUnion ~= 0 then
			return false
		end
		-- Monotonicity: count(A U B) >= max(count(A), count(B))
		if got.estUnion < math.max(got.estA, got.estB) then
			return false
		end
		-- Bounded relative error across sparse-to-dense promotion boundaries
		local sigma = 1.04 / math.sqrt(2 ^ got.p)
		local function withinBounds(est: number, exact: number): boolean
			if exact == 0 then
				return est == 0
			end
			local tol = math.max(4, math.ceil(exact * 6 * sigma))
			return math.abs(est - exact) <= tol
		end
		return withinBounds(got.estA, want.exactA)
			and withinBounds(got.estB, want.exactB)
			and withinBounds(got.estUnion, want.exactUnion)
	end,
}, { runs = 60 })

sert.check(
	"adversarial · add handles boundaryInt, boundaryFloat, malformedString, and buffers across sparse and dense modes",
	{
		gen.pick({ 4, 6, 10 }),
		gen.list(
			gen.oneOf({
				gen.boundaryInt(),
				gen.boundaryFloat(),
				gen.malformedString(),
				gen.bytes(0, 32),
			}),
			1,
			16
		),
	},
	function(p: number, items: { any })
		local HyperLogLog = getHLL()
		local hll = HyperLogLog.new(p)
		local dup = HyperLogLog.new(p)

		for _, item in items do
			hll:add(item)
			dup:add(item)
			dup:add(item)
		end

		local est = hll:estimate()
		sert(est >= 0 and est == math.floor(est) and est < math.huge)
		sert.eq(dup:estimate(), est)
		sert.eq(dup:serialize(), hll:serialize())

		local restored = HyperLogLog.deserialize(hll:serialize())
		sert(restored ~= nil)
		sert.eq(restored:estimate(), est)
	end,
	{ runs = 50 }
)

sert.check(
	"adversarial · deserialize safely validates truncated buffers, bit-flipped headers, corrupted registers, and non-buffers",
	{
		genSketch(4),
		gen.boundaryInt(0, 255),
		gen.boundaryInt(0, 32),
		gen.oneOf({
			gen.malformedString(),
			gen.boundaryInt(),
			gen.boundaryFloat(),
			gen.bytes(0, 24),
			gen.adversarial(1),
		}),
	},
	function(sketch: any, mask: number, byteIdx: number, rawPayload: any)
		local HyperLogLog = getHLL()

		local function assertValidOrNil(candidate: any)
			local restored = HyperLogLog.deserialize(candidate)
			if restored ~= nil then
				sert(restored.p >= 4 and restored.p <= 18)
				local est = restored:estimate()
				sert(est >= 0 and est == math.floor(est) and est < math.huge)
				local reencoded = restored:serialize()
				local roundtripped = HyperLogLog.deserialize(reencoded)
				sert(roundtripped ~= nil)
				sert.eq(roundtripped:estimate(), est)
			end
		end

		-- Arbitrary non-buffer / random buffer payloads
		assertValidOrNil(rawPayload)

		local validBytes = sketch:serialize()
		local len = buffer.len(validBytes)

		-- Truncated buffer prefixes (0 .. len - 1)
		local truncLen = byteIdx % len
		local truncated = buffer.create(truncLen)
		buffer.copy(truncated, 0, validBytes, 0, truncLen)
		sert.eq(HyperLogLog.deserialize(truncated), nil)

		-- Bit-flipped header or payload byte
		local flipped = buffer.create(len)
		buffer.copy(flipped, 0, validBytes)
		local pos = byteIdx % len
		buffer.writeu8(flipped, pos, bit32.bxor(buffer.readu8(flipped, pos), mask % 256))
		assertValidOrNil(flipped)
	end,
	{ runs = 60 }
)

sert.check("adversarial · merge rejects mismatched precisions without mutating target sketch", {
	gen.int(4, 18),
	gen.int(4, 18),
	gen.list(gen.boundaryInt(-100, 100), 0, 8),
}, function(p1: number, p2: number, items: { number })
	if p1 == p2 then
		p2 = if p1 < 18 then p1 + 1 else 4
	end
	local HyperLogLog = getHLL()
	local a = HyperLogLog.new(p1)
	local b = HyperLogLog.new(p2)
	for _, x in items do
		a:add(x)
		b:add(x)
	end
	local beforeBytes = buffer.tostring(a:serialize())
	local beforeEst = a:estimate()

	sert.fails(function()
		a:merge(b)
	end, "Cannot merge HyperLogLog objects with different precision")

	sert.eq(buffer.tostring(a:serialize()), beforeBytes)
	sert.eq(a:estimate(), beforeEst)
end, { runs = 40 })

sert.check("algebraic laws · merge forms a commutative, associative, idempotent semilattice", {
	gen.int(4, 8),
	gen.list(gen.int(1, 60), 0, 12),
	gen.list(gen.int(1, 60), 0, 12),
	gen.list(gen.int(1, 60), 0, 12),
}, function(p: number, itemsA: { number }, itemsB: { number }, itemsC: { number })
	local HyperLogLog = getHLL()

	local function build(list: { number })
		local h = HyperLogLog.new(p)
		for _, x in list do
			h:add(x)
		end
		return h
	end

	local a = build(itemsA)
	local b = build(itemsB)
	local c = build(itemsC)

	-- Idempotence: a:merge(a) == a
	local aSelf = HyperLogLog.deserialize(a:serialize())
	aSelf:merge(a)
	sert.eq(aSelf:serialize(), a:serialize())

	-- Commutativity: merge(a, b) == merge(b, a)
	local ab = HyperLogLog.deserialize(a:serialize())
	ab:merge(b)
	local ba = HyperLogLog.deserialize(b:serialize())
	ba:merge(a)
	sert.eq(ab:serialize(), ba:serialize())

	-- Associativity: merge(merge(a, b), c) == merge(a, merge(b, c))
	local abc1 = HyperLogLog.deserialize(ab:serialize())
	abc1:merge(c)

	local bc = HyperLogLog.deserialize(b:serialize())
	bc:merge(c)
	local abc2 = HyperLogLog.deserialize(a:serialize())
	abc2:merge(bc)
	sert.eq(abc1:serialize(), abc2:serialize())
end, { runs = 40 })

sert.model("stateful counter fleet · add, merge, and serialize/deserialize match ground-truth sets", {
	init = function()
		return {
			sets = { {}, {}, {} } :: { { [number]: boolean } },
		}
	end,
	setup = function()
		local HyperLogLog = getHLL()
		return {
			HyperLogLog = HyperLogLog,
			counters = { HyperLogLog.new(4), HyperLogLog.new(4), HyperLogLog.new(4) },
		}
	end,
	commands = {
		add = {
			gen = function(g)
				return { idx = g:int(1, 3), item = g:int(1, 24) }
			end,
			run = function(sut, arg)
				sut.counters[arg.idx]:add(arg.item)
			end,
			next = function(state, arg)
				state.sets[arg.idx][arg.item] = true
			end,
		},
		merge = {
			gen = function(g)
				return { dst = g:int(1, 3), src = g:int(1, 3) }
			end,
			run = function(sut, arg)
				sut.counters[arg.dst]:merge(sut.counters[arg.src])
			end,
			next = function(state, arg)
				for item in state.sets[arg.src] do
					state.sets[arg.dst][item] = true
				end
			end,
		},
		roundtrip = {
			gen = function(g)
				return g:int(1, 3)
			end,
			run = function(sut, idx)
				local data = sut.counters[idx]:serialize()
				local restored = sut.HyperLogLog.deserialize(data)
				sert(restored ~= nil)
				sut.counters[idx] = restored
			end,
			next = function(_state, _idx) end,
		},
	},
	invariant = function(state, sut)
		local HyperLogLog = sut.HyperLogLog
		for i = 1, 3 do
			local expected = HyperLogLog.new(4)
			for item in state.sets[i] do
				expected:add(item)
			end
			sert.eq(sut.counters[i]:serialize(), expected:serialize())
			sert.eq(sut.counters[i]:estimate(), expected:estimate())
		end
	end,
}, { runs = 25, length = 15 })

-- ============================================================================
-- Statistical Accuracy Across Precisions
-- ============================================================================

sert.each("accuracy · cardinality estimation stays within theoretical error bounds", {
	{ name = "p=4, n=50", p = 4, n = 50, trials = 10 },
	{ name = "p=6, n=200", p = 6, n = 200, trials = 10 },
	{ name = "p=10, n=2000", p = 10, n = 2000, trials = 8 },
	{ name = "p=14, n=5000", p = 14, n = 5000, trials = 4 },
}, function(case)
	local HyperLogLog = getHLL()
	local m = 2 ^ case.p
	local sigma = 1.04 / math.sqrt(m)

	local totalRelErr = 0
	local maxRelErr = 0
	for t = 1, case.trials do
		local hll = HyperLogLog.new(case.p)
		local offset = (t - 1) * case.n
		for i = 1, case.n do
			hll:add(offset + i)
		end
		local est = hll:estimate()
		local relErr = math.abs(est - case.n) / case.n
		totalRelErr += relErr
		maxRelErr = math.max(maxRelErr, relErr)
	end

	local meanRelErr = totalRelErr / case.trials
	sert(meanRelErr <= 2 * sigma, `p={case.p}: mean relative error {meanRelErr} exceeded 2*sigma ({2 * sigma})`)
	sert(maxRelErr <= 5 * sigma, `p={case.p}: max relative error {maxRelErr} exceeded 5*sigma ({5 * sigma})`)
end)

return {}
