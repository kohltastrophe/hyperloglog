# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- HyperLogLog++ cardinality estimator for Luau with configurable precision (`p = 4..18`, default `14`).
- 64-bit lookup3 hashing for numbers, strings, and buffers with SWAR register updates.
- Sparse register representation with automatic promotion to dense `buffer` storage above $m / 4$ active registers.
- LinearCounting and HyperLogLog++ empirical bias correction across all precisions.
- `serialize` and `deserialize` into a standalone `buffer` with varint compression for sparse estimators.
- `merge` to combine estimators of matching precision in place.
