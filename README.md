# HyperLogLog

[![CI](https://img.shields.io/github/actions/workflow/status/kohltastrophe/hyperloglog/ci.yml?style=for-the-badge)](https://github.com/kohltastrophe/hyperloglog/actions/workflows/ci.yml) [![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/kohltastrophe/hyperloglog/badges/coverage.json&style=for-the-badge)](https://github.com/kohltastrophe/hyperloglog/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/kohltastrophe/hyperloglog?style=for-the-badge)](LICENSE.md)

A HyperLogLog++ cardinality estimator for Luau. It counts distinct numbers, strings, and buffers using at most 16 KB of memory at the default precision (`p = 14`, ~0.81% standard error).

- **Low memory:** Starts in a compact sparse list for small counts and promotes to a fixed `1 + 2^p` byte `buffer` once more than $m / 4$ registers are set.
- **Accurate across all sizes:** Uses LinearCounting for small sets and HyperLogLog++ bias correction below $5m$ across all precisions ($p \in [4, 18]$).
- **Built-in serialization:** [`serialize`](#hyperloglogserialize) and [`deserialize`](#hyperloglogdeserializedata) pack and validate estimators into a standalone `buffer` for `DataStore` or `MessagingService`.
- **Cross-server merging:** [`merge`](#hyperloglogmergeother) combines estimators of matching precision in place.

## Quick Start

```luau
local HyperLogLog = require(path.to.HyperLogLog)

local serverA = HyperLogLog.new(14)
for userId = 1, 10_000 do
	serverA:add(userId)
end
serverA:add("guest:session-42")

print(serverA:estimate()) --> ~10001

-- Save to a buffer for DataStore or MessagingService
local payload = serverA:serialize()
local restored = HyperLogLog.deserialize(payload)

-- Merge counts from another server
local serverB = HyperLogLog.new(14)
for userId = 5_001, 15_000 do
	serverB:add(userId)
end

if restored then
	restored:merge(serverB)
	print(restored:estimate()) --> ~15001
end
```

## Precision, Memory & Standard Error

Pass a precision `p` from `4` to `18` to choose your memory and accuracy trade-off ($m = 2^p$ registers). Estimators start in a compact sparse list and switch to a fixed `1 + m` byte `buffer` once more than $m / 4$ registers are set.

| Precision (`p`) | Registers (`m = 2^p`) | Dense Memory (`1 + m`) | Standard Error (`1.04 / sqrt(m)`) |
| :--- | :--- | :--- | :--- |
| `10` | `1,024` | `1 KB` (`1,025 B`) | `3.25%` |
| `12` | `4,096` | `4 KB` (`4,097 B`) | `1.63%` |
| `14` *(default)* | `16,384` | `16 KB` (`16,385 B`) | `0.81%` |
| `16` | `65,536` | `64 KB` (`65,537 B`) | `0.41%` |
| `18` | `262,144` | `256 KB` (`262,145 B`) | `0.20%` |

## API Reference

### `HyperLogLog.new(precision?)`

```luau
function HyperLogLog.new(precision: number?): HyperLogLog
```

Creates an empty `HyperLogLog` estimator. `precision` is floored and clamped to `[4, 18]` and defaults to `14`.

### `HyperLogLog:add(item)`

```luau
function HyperLogLog:add(item: buffer | number | string): ()
```

Adds a number, string, or buffer to the estimator. Numbers are hashed as 64-bit floats, so `1` and `1.0` count as the same item. Strings and buffers are hashed by their raw bytes, so `"abc"` and `buffer.fromstring("abc")` also match.

### `HyperLogLog:estimate()`

```luau
function HyperLogLog:estimate(): number
```

Returns the estimated number of distinct items added so far, rounded to the nearest integer.

### `HyperLogLog:merge(other)`

```luau
function HyperLogLog:merge(other: HyperLogLog): ()
```

Merges `other` into `self` in place so `self:estimate()` reflects the union of both estimators. Throws an error if `self` and `other` have different precisions.

### `HyperLogLog:serialize()`

```luau
function HyperLogLog:serialize(): buffer
```

Packs the estimator into a standalone `buffer` for storage or network transport. Dense estimators take `1 + 2^p` bytes, and sparse estimators varint-compress their active registers.

### `HyperLogLog.deserialize(data)`

```luau
function HyperLogLog.deserialize(data: buffer): HyperLogLog?
```

Restores a `HyperLogLog` estimator from a buffer created by `HyperLogLog:serialize()`. Dense buffers are copied so the returned estimator never shares memory with `data`. If the buffer is invalid or corrupted, `deserialize` warns and returns `nil`.

## Credits

Thanks to [@XoifailTheGod](https://www.roblox.com/users/558808710) for helping optimize and test the library.

## References

- Heule, Nunkesser, Hall — [*HyperLogLog in Practice: Algorithmic Engineering of a State of The Art Cardinality Estimation Algorithm*](https://research.google.com/pubs/archive/40671.pdf)
- [*HyperLogLog++ Bias Correction Empirical Data*](https://docs.google.com/document/d/1gyjfMHy43U9OWBXxfaeG-3MjGzejW1dlpyMwEYAAWEI/mobilebasic)

## Sponsors

HyperLogLog is free and MIT-licensed. If HyperLogLog is useful to you or your team, you can support its development through [GitHub Sponsors](https://github.com/sponsors/kohltastrophe) or [Ko-fi](https://ko-fi.com/kohltastrophe).

<p align="center">
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-github.svg" alt="GitHub Sponsors" /></a>&nbsp;&nbsp;<a href="https://ko-fi.com/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-kofi.svg" alt="Ko-fi" /></a>
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsors.svg" alt="Sponsors" /></a>
</p>
