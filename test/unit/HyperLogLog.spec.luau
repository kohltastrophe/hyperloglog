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

local function appendVarInt(bytes: { number }, value: number)
	while value >= 128 do
		table.insert(bytes, value % 128 + 128)
		value //= 128
	end
	table.insert(bytes, value)
end

-- Encodes sparse entries `{ { index, rho? }, ... }` using the HLL++ 1-bit rho flag format
local function makeSparseEntries(
	p: number,
	entries: { { number } },
	countOverride: number?,
	extraBytes: { number }?
): buffer
	local bytes = {}
	appendVarInt(bytes, countOverride or #entries)
	local diffMask = bit32.lshift(1, 25 - p) - 1
	local prevIndex = -1
	for _, item in entries do
		local index = item[1]
		local rho = item[2]
		local hasRho = if rho ~= nil then 1 elseif bit32.band(index, diffMask) == 0 then 1 else 0
		appendVarInt(bytes, (index - prevIndex - 1) * 2 + hasRho)
		if hasRho == 1 and rho ~= false then
			table.insert(bytes, rho or 1)
		end
		prevIndex = index
	end
	if extraBytes then
		for _, b in extraBytes do
			table.insert(bytes, b)
		end
	end

	local out = buffer.create(1 + #bytes)
	buffer.writeu8(out, 0, p + 128)
	for i, byte in bytes do
		buffer.writeu8(out, i, byte)
	end
	return out
end

local function makeSparseRaw(p: number, payloadBytes: { number }): buffer
	local out = buffer.create(1 + #payloadBytes)
	buffer.writeu8(out, 0, p + 128)
	for i, byte in payloadBytes do
		buffer.writeu8(out, i, byte)
	end
	return out
end

local function toDenseCopy(HyperLogLog: any, hll: any)
	local dense = HyperLogLog.deserialize(makeDense(hll.p, {}))
	dense:merge(hll)
	return dense
end

sert.test("new · default, custom, clamped, and NaN precisions with frozen module", function()
	local HyperLogLog = getHLL()
	sert(table.isfrozen(HyperLogLog))

	local hll = HyperLogLog.new()
	sert.eq(hll.p, 14)
	sert.eq(hll.m, 16384)
	sert(hll._sparse ~= nil)
	sert.eq(hll.buffer, nil)
	sert.eq(hll._count, 0)
	sert.eq(hll:estimate(), 0)

	local hllNan = HyperLogLog.new(0 / 0)
	sert.eq(hllNan.p, 14)
	sert.eq(hllNan.m, 16384)
	sert.eq(hllNan:estimate(), 0)

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

sert.test("add & estimate · numbers, NaNs, strings across all byte lengths, buffers, and duplicates", function()
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

	-- Numbers match 8-byte little-endian f64 buffers, -0 canonicalizes to +0, and all NaNs canonicalize to 0x7FF80000_00000000
	local numHll = HyperLogLog.new()
	local f64BufHll = HyperLogLog.new()
	for _, x in { 0, 1, -42.5, math.pi, 1e50 } do
		numHll:add(x)
		local b = buffer.create(8)
		buffer.writef64(b, 0, x)
		f64BufHll:add(b)
	end
	numHll:add(-0.0)
	numHll:add(0 / 0)
	numHll:add(-(0 / 0))
	numHll:add(math.sqrt(-1))

	local nanBuf = buffer.create(8)
	buffer.writeu32(nanBuf, 0, 0)
	buffer.writeu32(nanBuf, 4, 0x7FF80000)
	f64BufHll:add(nanBuf)
	sert.eq(numHll:serialize(), f64BufHll:serialize())

	-- Strings across 0, 1..3, 4..8, 9..12, 13..16, multi-block, and >16KB temporary buffer match raw buffers
	local strHll = HyperLogLog.new()
	local bufHll = HyperLogLog.new()
	local samples = {
		"",
		"a",
		"ab",
		"abc",
		"abcd",
		"apple",
		"eight_by",
		"nine_byte",
		"ten_bytes!",
		"twelve_bytes",
		"thirteen_byte",
		"sixteen_bytes_ok",
		string.rep("xyz", 30),
		string.rep("xyz", 500), -- grows reusable scratch up to <= 16 KB
		string.rep("abcd", 5000), -- 20 KB (> MAX_SCRATCH_BYTES) exercises standalone buffer path
	}
	for _, s in samples do
		strHll:add(s)
	end
	for i = #samples, 1, -1 do
		bufHll:add(buffer.fromstring(samples[i]))
	end
	strHll:add("apple")
	sert.eq(strHll:estimate(), #samples)
	sert.eq(bufHll:serialize(), strHll:serialize())
end)

sert.test("sparse growth & promotion · 4x buffer growth, threshold saturation, and promotion to dense", function()
	local HyperLogLog = getHLL()

	-- p = 4 -> m = 16 -> max sparse count is (16 * 3) // 16 = 3
	local hll = HyperLogLog.new(4)
	sert.eq(buffer.len(hll._sparse), 16)
	for i = 1, 3 do
		hll:add(i)
	end
	sert(hll._sparse ~= nil)
	sert.eq(hll.buffer, nil)
	sert.eq(hll:estimate(), 3)
	sert.eq(hll._count, 3)

	-- Re-adding existing items hundreds of times never promotes or inflates _count
	for _ = 1, 200 do
		hll:add(1)
		hll:add(2)
		hll:add(3)
	end
	sert(hll._sparse ~= nil)
	sert.eq(hll._count, 3)
	sert.eq(hll:estimate(), 3)

	-- 4th distinct register promotes directly to dense
	hll:add(4)
	sert.eq(hll._sparse, nil)
	sert(hll.buffer ~= nil)
	sert.eq(hll._count, 0)
	sert.eq(buffer.len(hll.buffer), 17)
	sert.eq(buffer.readu8(hll.buffer, 0), 4)

	-- p = 10 -> m = 1024 -> sparse buffer grows 128B -> 512B -> 1024B -> dense above 768
	local h10 = HyperLogLog.new(10)
	sert.eq(buffer.len(h10._sparse), 128)
	for i = 1, 30 do
		h10:add(i)
	end
	sert.eq(buffer.len(h10._sparse), 512)
	for i = 31, 100 do
		h10:add(i)
	end
	sert.eq(buffer.len(h10._sparse), 1024)
	for i = 101, 800 do
		h10:add(i)
	end
	sert.eq(h10._sparse, nil)
	sert(h10.buffer ~= nil)
end)

-- Exact inverse of the 12-byte lookup3 finalizer so tests can deterministically hit any target (hi, lo)
local function craftHash12(hi: number, lo: number): buffer
	local bxor = bit32.bxor
	local lrotate = bit32.lrotate
	local bor = bit32.bor

	local c, b, a = hi, lo, 0

	b = bxor(bor(b + lrotate(a, 25), 0), a)
	a = bxor(bor(a + lrotate(c, 11), 0), c)
	c = bxor(bor(c + lrotate(b, 24), 0), b)
	b = bxor(bor(b + lrotate(a, 14), 0), a)
	a = bxor(bor(a + lrotate(c, 4), 0), c)
	c = bxor(bor(c + lrotate(b, 16), 0), b)
	b = bxor(bor(b + lrotate(a, 25), 0), a)
	a = bxor(bor(a + lrotate(c, 11), 0), c)
	c = bxor(bor(c + lrotate(b, 14), 0), b)

	local out = buffer.create(12)
	buffer.writeu32(out, 0, bor(a - (0xDEADBEEF + 12), 0))
	buffer.writeu32(out, 4, bor(b - (0x9E3779B9 + 12), 0))
	buffer.writeu32(out, 8, bor(c - (0x85EBCA6B + 12), 0))
	return out
end

sert.test(
	"getRho & raiseSparse · handles flagged/unflagged sparse entries, lazy lo, and cached dense updates",
	function()
		local HyperLogLog = getHLL()

		local hll = HyperLogLog.new(14)
		-- Flagged sparse index at p = 14 (lower 11 bits of 25-bit index == 0): index = 5 * 2048 = 10240
		-- Bottom 7 bits of hi = 0, lo has 4 leading zeros -> rho = 7 + 4 + 1 = 12
		local flaggedIdx = bit32.lshift(5, 11)
		local hiFlagged = bit32.lshift(flaggedIdx, 7)
		hll:add(craftHash12(hiFlagged, 0x08000000))
		sert.eq(hll:serialize(), makeSparseEntries(14, { { flaggedIdx, 12 } }))
		sert.eq(hll._count, 1)

		-- Same flagged index, smaller rho (bottom 7 bits has 1 at bit 6 -> rho = 1): does not lower register
		hll:add(craftHash12(hiFlagged + 64, 0))
		sert.eq(hll:serialize(), makeSparseEntries(14, { { flaggedIdx, 12 } }))
		sert.eq(hll._count, 1)

		-- Same flagged index, larger rho (bottom 7 bits = 0, lo = 0 -> rho = 7 + 32 + 1 = 40): raises register
		hll:add(craftHash12(hiFlagged, 0))
		sert.eq(hll:serialize(), makeSparseEntries(14, { { flaggedIdx, 40 } }))
		sert.eq(hll._count, 1)

		-- Unflagged sparse index (lower 11 bits ~= 0): index = 5 omits rho byte in wire encoding
		hll:add(craftHash12(bit32.lshift(5, 7), 0x08000000))
		sert.eq(hll:serialize(), makeSparseEntries(14, { { 5 }, { flaggedIdx, 40 } }))
		sert.eq(hll._count, 2)

		-- Dense lazy `lo` path (rest == 0) + incremental _sum / _zeros maintenance once estimate() is cached
		local dense = toDenseCopy(HyperLogLog, HyperLogLog.new(4))
		sert.eq(dense:estimate(), 0) -- populates _sum = 16, _zeros = 16
		-- Bucket 3 (top 4 bits = 2), bottom 28 bits of hi = 0, lo has 5 leading zeros -> rho = 29 + 5 = 34
		dense:add(craftHash12(bit32.lshift(2, 28), 0x04000000))
		sert.eq(buffer.readu8(dense.buffer, 3), 34)
		sert.eq(dense._zeros, 15)
		-- Raising same non-zero register updates _sum without decrementing _zeros again
		dense:add(craftHash12(bit32.lshift(2, 28), 0))
		sert.eq(buffer.readu8(dense.buffer, 3), 61)
		sert.eq(dense._zeros, 15)
		local cachedEst = dense:estimate()
		dense._sum = nil
		sert.eq(dense:estimate(), cachedEst)

		-- Verify incremental _sum maintenance in bias-corrected / raw harmonic regime (nZeros == 0)
		local fullDense = HyperLogLog.deserialize(makeDense(4, table.create(16, 1)))
		sert.eq(fullDense:estimate(), 18) -- caches _sum = 8, _zeros = 0
		fullDense:add(craftHash12(bit32.lshift(2, 28), 0)) -- raises bucket 3 from 1 to 61 (_sum: 8 -> 7.5 + 2^-61)
		local incSum = fullDense._sum
		local incEst = fullDense:estimate()
		fullDense._sum = nil
		sert.eq(fullDense:estimate(), incEst)
		sert.eq(fullDense._sum, incSum)
	end
)

sert.test(
	"estimate · matches HLL++ reference values across sparse, linear counting, bias-corrected, and large ranges",
	function()
		local HyperLogLog = getHLL()

		-- Sparse linear counting over 2^25 registers
		local sparse = HyperLogLog.new(4)
		sparse._count = 3
		sert.eq(sparse:estimate(), 3)

		sparse._count = 1000
		sert.eq(sparse:estimate(), 1000)

		local function denseWith(p: number, fill: number, overrides: { [number]: number }?)
			local regs = table.create(2 ^ p, fill)
			if overrides then
				for index, rho in overrides do
					regs[index] = rho
				end
			end
			return HyperLogLog.deserialize(makeDense(p, regs))
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
		sert.eq(denseWith(4, 1):estimate(), 18)
		sert.eq(denseWith(4, 2):estimate(), 43)
		sert.eq(denseWith(4, 3):estimate(), 86)
		sert.eq(denseWith(6, 2):estimate(), 179)
		sert.eq(denseWith(6, 3):estimate(), 363)

		-- Bias clamp above MEAN_DATA[1][78] (77.2394) while raw <= 5*m (80)
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
	local hll = HyperLogLog.deserialize(makeDense(4, table.create(16, 1)))
	hll.alpha = 13.2882 * 8
	sert.eq(hll:estimate(), 5)

	-- Setting alpha = 10.4 * 8 makes raw = 10.4 < MEAN_DATA[1][1] (11), clamping to BIAS_DATA[1][1] (10) -> round(0.4) = 0.
	hll._sum = nil
	hll.alpha = 10.4 * 8
	sert.eq(hll:estimate(), 0)
end)

sert.test("duplicates and insertion order do not change serialized registers", function()
	local HyperLogLog = getHLL()

	for _, count in { 10, 200 } do
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

sert.test("merge · union across all sparse/dense combinations, self-merge, and error on precision mismatch", function()
	local HyperLogLog = getHLL()

	-- 1. Sparse + Sparse (staying sparse, plus empty self / empty other / self-merge)
	local sEmpty = HyperLogLog.new(10)
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

	s1:merge(s1) -- self-merge no-op
	s1:merge(sEmpty) -- empty other no-op
	sEmpty:merge(s1) -- empty self fast-copy
	sert.eq(sEmpty:serialize(), s1:serialize())

	s1:merge(s2)
	sert(s1._sparse ~= nil)
	sert.eq(s1:serialize(), sUnion:serialize())

	-- 2. Sparse + Sparse (crossing threshold mid-merge and folding remaining entries into dense)
	local sc1 = HyperLogLog.new(4) -- max sparse = 3
	local sc2 = HyperLogLog.new(4)
	local scUnion = HyperLogLog.new(4)
	for i = 1, 2 do
		sc1:add(i)
		scUnion:add(i)
	end
	for i = 3, 5 do
		sc2:add(i)
		scUnion:add(i)
	end
	sert(sc1._sparse ~= nil)
	sert(sc2._sparse ~= nil)
	sc1:merge(sc2)
	sert.eq(sc1._sparse, nil)
	sert.eq(sc1:serialize(), scUnion:serialize())

	-- 3. Dense + Sparse, Sparse + Dense, and Empty Sparse + Dense (preserving cached _sum)
	local dBase = HyperLogLog.new(4)
	local sExtra = HyperLogLog.new(4)
	local dsUnion = HyperLogLog.new(4)
	for i = 1, 10 do
		dBase:add(i)
		dsUnion:add(i)
	end
	for i = 11, 12 do
		sExtra:add(i)
		dsUnion:add(i)
	end
	sert.eq(dBase._sparse, nil)
	sert(sExtra._sparse ~= nil)
	local dBaseEst = dBase:estimate() -- caches _sum on dBase

	local emptyIntoDense = HyperLogLog.new(4)
	emptyIntoDense:merge(dBase)
	sert.eq(emptyIntoDense._sum, dBase._sum)
	sert.eq(emptyIntoDense:estimate(), dBaseEst)

	local dIntoS = sExtra:clone()
	local sIntoD = dBase:clone()
	sIntoD:merge(HyperLogLog.new(4)) -- merging empty sparse into dense preserves _sum
	sert.eq(sIntoD._sum, dBase._sum)
	dIntoS:merge(dBase)
	sIntoD:merge(sExtra)
	sIntoD:merge(sIntoD) -- dense self-merge no-op
	sert.eq(dIntoS._sparse, nil)
	sert.eq(dIntoS._count, 0)
	sert.eq(dIntoS:serialize(), dsUnion:serialize())
	sert.eq(sIntoD:serialize(), dsUnion:serialize())
	sert.eq(dIntoS:estimate(), dsUnion:estimate())
	sert.eq(sIntoD:estimate(), dsUnion:estimate())

	-- 4. Dense + Dense (covering both 4-byte lanes of the 8-byte unrolled loop, identical chunks, and dominated chunks)
	local dd1 = HyperLogLog.deserialize(makeDense(4, {
		10,
		2,
		10,
		2,
		5,
		5,
		5,
		5,
		1,
		8,
		1,
		8,
		4,
		4,
		4,
		4,
	}))
	local dd2 = HyperLogLog.deserialize(makeDense(4, {
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
	}))
	local preMergeEst = dd1:estimate()
	dd1:merge(dd2)
	sert(dd1:estimate() > preMergeEst)
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

sert.test("clone & clear · independent copies and in-place resets across empty, sparse, and dense modes", function()
	local HyperLogLog = getHLL()

	-- Empty clone & clear
	local empty = HyperLogLog.new(10)
	local emptyClone = empty:clone()
	emptyClone:add("only-in-clone")
	sert.eq(empty:estimate(), 0)
	sert.eq(emptyClone:estimate(), 1)
	emptyClone:clear()
	sert.eq(emptyClone:estimate(), 0)
	sert.eq(emptyClone:serialize(), empty:serialize())

	-- Grown sparse clone & clear (shrinks sparse buffer back to initial 128B)
	local sparse = HyperLogLog.new(10)
	for i = 1, 100 do
		sparse:add(i)
	end
	sert(buffer.len(sparse._sparse) > 128)
	local sparseClone = sparse:clone()
	sert.eq(sparseClone:serialize(), sparse:serialize())
	sparseClone:add(999999)
	sert(buffer.tostring(sparseClone:serialize()) ~= buffer.tostring(sparse:serialize()))

	sparse:clear()
	sert.eq(sparse:estimate(), 0)
	sert.eq(buffer.len(sparse._sparse), 128)
	sparse:add(42)
	sert.eq(sparse:estimate(), 1)

	-- Dense clone & clear (preserves cached _sum on clone, resets dense back to sparse on clear)
	local dense = HyperLogLog.new(4)
	for i = 1, 25 do
		dense:add(i)
	end
	local est = dense:estimate()
	local denseClone = dense:clone()
	sert.eq(denseClone._sum, dense._sum)
	sert.eq(denseClone:estimate(), est)
	denseClone:add("extra-item")

	dense:clear()
	sert.eq(dense.buffer, nil)
	sert(dense._sparse ~= nil)
	sert.eq(dense:estimate(), 0)
	for i = 1, 25 do
		dense:add(i)
	end
	sert.eq(dense:estimate(), est)
end)

sert.test(
	"serialize & deserialize · empty, varint width boundaries, dense copy isolation, and oversize sparse",
	function()
		local HyperLogLog = getHLL()

		-- Empty sparse counter (2 bytes: header + 0 count)
		local empty = HyperLogLog.new(10)
		local emptyBuf = empty:serialize()
		sert.eq(buffer.len(emptyBuf), 2)
		local emptyRestored = HyperLogLog.deserialize(emptyBuf)
		sert(emptyRestored ~= nil)
		sert.eq(emptyRestored.p, 10)
		sert.eq(emptyRestored._count, 0)
		sert.eq(emptyRestored:estimate(), 0)

		-- Single-entry sparse counter (exercises count == 1 skip-sort path)
		local single = HyperLogLog.new(10)
		single:add(1)
		local singleRestored = HyperLogLog.deserialize(single:serialize())
		sert(singleRestored ~= nil)
		sert.eq(singleRestored:serialize(), single:serialize())

		-- Sparse deltaCode varint width boundaries (1, 2, 3, and 4 bytes) + flagged rho
		-- deltaCode = (index - prevIndex - 1) * 2 + hasRho
		local boundaryPayload = makeSparseEntries(14, {
			{ 0, 12 }, -- index 0 (flagged): deltaCode = 1 (1B) + rho 12 (1B)
			{ 65 }, -- index 65 (unflagged): delta = 64 -> deltaCode = 128 (2B)
			{ 65 + 8193 }, -- unflagged: delta = 8192 -> deltaCode = 16384 (3B)
			{ 65 + 8193 + 1048577 }, -- unflagged: delta = 1048576 -> deltaCode = 2097152 (4B)
		})
		local boundaryRestored = HyperLogLog.deserialize(boundaryPayload)
		sert(boundaryRestored ~= nil)
		sert.eq(boundaryRestored:serialize(), boundaryPayload)

		-- Exact varint threshold boundaries for deltaIndex: 63 vs 64 (126/128), 8191 vs 8192, 1048575 vs 1048576
		for _, deltaIdx in { 63, 64, 8191, 8192, 1048575, 1048576 } do
			local idx = if deltaIdx % 2048 == 0 then deltaIdx + 1 else deltaIdx
			local enc = makeSparseEntries(14, { { idx } })
			local dec = HyperLogLog.deserialize(enc)
			sert(dec ~= nil)
			sert.eq(dec:serialize(), enc)
		end

		-- Large sparse counter at p = 18 (> 3500 entries -> > 16 KB scratch buffer path in serialize)
		local largeSparse = HyperLogLog.new(18)
		for i = 1, 4000 do
			largeSparse:add(i)
		end
		sert(largeSparse._sparse ~= nil)
		local largeSparseData = largeSparse:serialize()
		local largeSparseRestored = HyperLogLog.deserialize(largeSparseData)
		sert(largeSparseRestored ~= nil)
		sert.eq(largeSparseRestored:serialize(), largeSparseData)
		local beforeDupCount = largeSparseRestored._count
		for i = 1, 200 do
			largeSparseRestored:add(i)
		end
		sert.eq(largeSparseRestored._count, beforeDupCount)

		-- Dense round-trip and buffer isolation
		local dense = HyperLogLog.new(4)
		for i = 1, 20 do
			dense:add(i)
		end
		sert.eq(dense._sparse, nil)
		local denseData = dense:serialize()
		local denseSnapshot = buffer.tostring(denseData)
		local denseRestored = HyperLogLog.deserialize(denseData)
		sert(denseRestored ~= nil)
		sert.eq(denseRestored._sparse, nil)
		sert.eq(denseRestored:serialize(), denseData)

		-- Mutating caller's input buffer after deserialize does not affect restored HLL
		buffer.writeu8(denseData, 1, 60)
		sert.eq(buffer.tostring(denseRestored:serialize()), denseSnapshot)

		-- Mutating buffer returned by serialize does not affect source HLL
		local serializedOut = denseRestored:serialize()
		buffer.writeu8(serializedOut, 1, 60)
		sert.eq(buffer.tostring(denseRestored:serialize()), denseSnapshot)

		-- Oversize sparse payload (count = 4 > 3 at p = 4) folds directly to dense upon deserialize,
		-- handling both flagged (index = 0) and unflagged entries, plus multiple entries in the same dense bucket
		local over = makeSparseEntries(4, {
			{ 0, 7 }, -- bucket 0, residual = 0 -> rho = 7 + 21 = 28
			{ 1 }, -- bucket 0, residual = 1 -> rho = 21 (< 28, does not overwrite 28)
			{ bit32.lshift(1, 21) + 1 }, -- bucket 1, unflagged -> rho = 21
			{ bit32.lshift(2, 21), 5 }, -- bucket 2, flagged -> rho = 5 + 21 = 26
		})
		local overRestored = HyperLogLog.deserialize(over)
		sert(overRestored ~= nil)
		sert.eq(overRestored._sparse, nil)
		sert(overRestored.buffer ~= nil)
		sert.eq(buffer.readu8(overRestored.buffer, 0), 4)
		sert.eq(buffer.readu8(overRestored.buffer, 1), 28)
		sert.eq(buffer.readu8(overRestored.buffer, 2), 21)
		sert.eq(buffer.readu8(overRestored.buffer, 3), 26)
		local overRoundTrip = HyperLogLog.deserialize(overRestored:serialize())
		sert(overRoundTrip ~= nil)
		sert.eq(overRoundTrip:estimate(), overRestored:estimate())

		-- Sparse payload at exact max load (count == 3 at p = 4) stays sparse upon deserialize
		local exactMax = makeSparseEntries(4, { { 1 }, { 2 }, { 3 } })
		local exactRestored = HyperLogLog.deserialize(exactMax)
		sert(exactRestored ~= nil)
		sert(exactRestored._sparse ~= nil)
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

	-- Empty buffer and 1-byte sparse buffer
	sert.eq(HyperLogLog.deserialize(buffer.create(0)), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, {})), nil)

	-- Precision out of range [4, 18]
	for _, p in { 0, 3, 19, 127 } do
		local bDense = buffer.create(1 + 2 ^ math.clamp(p, 4, 18))
		buffer.writeu8(bDense, 0, p)
		sert.eq(HyperLogLog.deserialize(bDense), nil)

		local bSparse = makeSparseRaw(p, { 0 })
		sert.eq(HyperLogLog.deserialize(bSparse), nil)
	end

	-- Precision boundaries 4 and 18 are valid
	sert(HyperLogLog.deserialize(makeDense(4, {})) ~= nil)
	sert(HyperLogLog.deserialize(makeSparseEntries(18, {})) ~= nil)

	-- Dense wrong length
	for _, len in { 1, 16, 18 } do
		local b = buffer.create(len)
		buffer.writeu8(b, 0, 4)
		sert.eq(HyperLogLog.deserialize(b), nil)
	end

	-- Dense register rank bounds across all four 4-byte lanes of the 16-byte SWAR check
	local maxValidDense = makeDense(4, { [16] = 61 })
	local restoredMaxDense = HyperLogLog.deserialize(maxValidDense)
	sert(restoredMaxDense ~= nil)
	sert.eq(buffer.readu8(restoredMaxDense.buffer, 16), 61)

	for _, pos in { 1, 5, 9, 13, 16 } do
		sert.eq(HyperLogLog.deserialize(makeDense(4, { [pos] = 62 })), nil)
		sert.eq(HyperLogLog.deserialize(makeDense(4, { [pos] = 255 })), nil)
	end

	-- Sparse count missing / truncated / >4-byte varint / exceeding remaining bytes
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 0x80 })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 0x80, 0x80, 0x80, 0x80, 0x01 })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, {}, 1)), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { 1 }, { 2 }, { 3 } }, 5)), nil)

	-- Truncated deltaCode or 5-byte deltaCode varint (both normal and oversize sparse paths)
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 1, 0x80 })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 2, 1, 5 })), nil) -- second entry hits offset >= len
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 2, 1, 5, 0x80 })), nil) -- second entry truncated 2-byte varint
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 2, 1, 5, 0x80, 0x80 })), nil) -- second entry truncated 3-byte varint
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 1, 0x80, 0x80, 0x80, 0x80, 0x01 })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 4, 0x80, 0, 0, 0 })), nil)

	-- Trailing bytes after all count entries (normal and oversize sparse paths)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, {}, nil, { 0x01 })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { 1 }, { 2 }, { 3 }, { 4 } }, nil, { 0x01 })), nil)

	-- Canonical hasRho flag mismatches (hasRho=1 on unflagged index, or hasRho=0 on flagged index)
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 1, 1 * 2 + 1, 5 })), nil) -- index 1 unflagged but hasRho=1
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 1, 0 * 2 + 0 })), nil) -- index 0 flagged but hasRho=0
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 4, 1 * 2 + 1, 5, 2, 2, 2 })), nil) -- oversize flag mismatch

	-- Missing rho byte, rho == 0, rho == 40 (valid), rho == 41 (invalid) in both sparse and oversize paths
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 1, 1 })), nil) -- index 0 flagged, missing rho byte
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { 0, 0 } })), nil)
	sert(HyperLogLog.deserialize(makeSparseEntries(4, { { 0, 40 } })) ~= nil)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { 0, 41 } })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseRaw(4, { 4, 2, 2, 2, bit32.lshift(1, 21) * 2 - 7 })), nil) -- oversize missing rho
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { 0, 0 }, { 1 }, { 2 }, { 3 } })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { 0, 41 }, { 1 }, { 2 }, { 3 } })), nil)

	-- Sparse index bounds: index == 2^25 - 1 is valid, index == 2^25 is invalid (normal and oversize)
	local maxSparseIndex = 2 ^ 25 - 1
	sert(HyperLogLog.deserialize(makeSparseEntries(4, { { maxSparseIndex } })) ~= nil)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { maxSparseIndex + 1 } })), nil)
	sert.eq(HyperLogLog.deserialize(makeSparseEntries(4, { { 1 }, { 2 }, { 3 }, { maxSparseIndex + 1 } })), nil)
end)

sert.test("foldSparse · sparse-to-dense conversion preserves exact dense ranks", function()
	local HyperLogLog = getHLL()

	-- Verify against a counter forced to dense from the start across precisions
	for _, p in { 4, 8, 12 } do
		local sparse = HyperLogLog.new(p)
		local dense = toDenseCopy(HyperLogLog, sparse)

		local limit = math.min(200, (2 ^ p * 3) // 16)
		for i = 1, limit do
			sparse:add(i)
			dense:add(i)
		end
		sert(sparse._sparse ~= nil)
		sert.eq(toDenseCopy(HyperLogLog, sparse):serialize(), dense:serialize())
	end

	-- Explicit bit-level verification of sparse-to-dense folding at p = 4 (diff = 21)
	local payload = makeSparseEntries(4, {
		-- bucket 0, residual = 0 (flagged), rho_sparse = 7 -> rho = 7 + 21 = 28
		{ 0, 7 },
		-- bucket 1, residual has a 1 at its highest bit (bit 20) -> rho = 1
		{ bit32.lshift(1, 21) + bit32.lshift(1, 20) },
		-- bucket 2, residual has 5 leading zeros then a 1 (bit 15) -> rho = 6
		{ bit32.lshift(2, 21) + bit32.lshift(1, 15) },
	})
	local hll = HyperLogLog.deserialize(payload)
	sert(hll ~= nil and hll._sparse ~= nil)

	local b = toDenseCopy(HyperLogLog, hll).buffer
	sert.eq(buffer.readu8(b, 1), 28)
	sert.eq(buffer.readu8(b, 2), 1)
	sert.eq(buffer.readu8(b, 3), 6)
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
			local maxSparse = math.max(1, math.min(4, (2 ^ p * 3) // 16))
			local n = g:int(1, maxSparse)
			for i = 1, n do
				hll:add(i * 100 + g:int(0, 15))
			end
		elseif mode == "dense" then
			local n = (2 ^ p * 3) // 16 + g:int(1, 6)
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
		local out = a:clone()
		out:merge(b)
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
			local n = (2 ^ p * 3) // 16 + g:int(1, 3)
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
		local threshold = (2 ^ p * 3) // 16
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

		local hllUnion = hllA:clone()
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
		if got.estUnion < math.max(got.estA, got.estB) then
			return false
		end
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

		assertValidOrNil(rawPayload)

		local validBytes = sketch:serialize()
		local len = buffer.len(validBytes)

		local truncLen = byteIdx % len
		local truncated = buffer.create(truncLen)
		buffer.copy(truncated, 0, validBytes, 0, truncLen)
		sert.eq(HyperLogLog.deserialize(truncated), nil)

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

	-- Idempotence: a:merge(a) == a (both aliased and cloned)
	local aAliased = a:clone()
	aAliased:merge(aAliased)
	sert.eq(aAliased:serialize(), a:serialize())

	local aSelf = a:clone()
	aSelf:merge(a)
	sert.eq(aSelf:serialize(), a:serialize())

	-- Commutativity: merge(a, b) == merge(b, a)
	local ab = a:clone()
	ab:merge(b)
	local ba = b:clone()
	ba:merge(a)
	sert.eq(ab:serialize(), ba:serialize())

	-- Associativity: merge(merge(a, b), c) == merge(a, merge(b, c))
	local abc1 = ab:clone()
	abc1:merge(c)

	local bc = b:clone()
	bc:merge(c)
	local abc2 = a:clone()
	abc2:merge(bc)
	sert.eq(abc1:serialize(), abc2:serialize())
end, { runs = 40 })

sert.model("stateful counter fleet · add, merge, clone, clear, and serialize/deserialize match ground-truth sets", {
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
		cloneInto = {
			gen = function(g)
				return { dst = g:int(1, 3), src = g:int(1, 3) }
			end,
			run = function(sut, arg)
				sut.counters[arg.dst] = sut.counters[arg.src]:clone()
			end,
			next = function(state, arg)
				state.sets[arg.dst] = table.clone(state.sets[arg.src])
			end,
		},
		clear = {
			gen = function(g)
				return g:int(1, 3)
			end,
			run = function(sut, idx)
				sut.counters[idx]:clear()
			end,
			next = function(state, idx)
				state.sets[idx] = {}
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
}, { runs = 30, length = 16 })

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
