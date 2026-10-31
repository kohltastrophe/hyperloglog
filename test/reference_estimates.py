"""Expected values for the "Estimate Matches HLL++ Reference Values" test.

An independent HLL++ estimator (Heule et al. 2013, figure 7) that interpolates linearly between the bias
reference points like the Luau module. The bias tables are read from src/init.luau and match the paper's
published data. Run from the repository root: python3 test/reference_estimates.py
"""

import math
import re
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "src" / "init.luau"
THRESHOLD = [10, 20, 40, 80, 220, 400, 900, 1800, 3100, 6500, 11500, 20000, 50000, 120000, 350000]


def read_table(source, name):
    body = source[source.index(f"local {name} = table.freeze({{") :]
    body = body[body.index("{") + 1 : body.index("\n})")]
    body = re.sub(r"--[^\n]*", "", body)
    return [[float(x) for x in re.findall(r"-?\d+(?:\.\d+)?", group)] for group in re.findall(r"\{([^{}]*)\}", body)]


source = SOURCE.read_text()
MEANS, BIASES = read_table(source, "MEAN_DATA"), read_table(source, "BIAS_DATA")
assert len(MEANS) == len(THRESHOLD) == 15, f"expected 15 precision rows in MEAN_DATA, got {len(MEANS)}"
assert len(BIASES) == len(THRESHOLD) == 15, f"expected 15 precision rows in BIAS_DATA, got {len(BIASES)}"
for p_idx, (means_row, biases_row) in enumerate(zip(MEANS, BIASES)):
    assert len(means_row) == len(biases_row) > 0, f"mismatched MEAN_DATA/BIAS_DATA row at p={p_idx + 4}"


def alpha(m):
    return {16: 0.673101517, 32: 0.697121585, 64: 0.709209798}.get(m, 0.7213 / (1 + 1.079 / m))


def bias(raw, p):
    means, biases = MEANS[p - 4], BIASES[p - 4]
    k = next((i for i, mean in enumerate(means) if mean >= raw), len(means))
    if k == 0:
        return biases[0]
    if k == len(means):
        return biases[-1]
    x1, x2, y1, y2 = means[k - 1], means[k], biases[k - 1], biases[k]
    return y1 + (y2 - y1) * ((raw - x1) / (x2 - x1))


def estimate(p, registers):
    m = 1 << p
    zeros = registers.count(0)
    if zeros:
        h = m * math.log(m / zeros)
        if h <= THRESHOLD[p - 4]:
            return h
    raw = alpha(m) * m * m / sum(2.0**-r for r in registers)
    return raw - bias(raw, p) if raw <= 5 * m else raw


def countrz(x):
    return (x & -x).bit_length() - 1


# Register rules, matching the helpers in test/unit/HyperLogLog.spec.luau
def constant(rho):
    return lambda j: rho


def leading_ones(count):
    return lambda j: 1 if j < count else 0


def cycle(first, period):
    return lambda j: first + j % period


def geometric(first, gap=None):
    if gap:
        return lambda j: 0 if j % gap == 0 else first + countrz(j)
    return lambda j: first + countrz(j + 1)


CASES = [
    ("raw, alpha for m=16", 4, "constant(4)"),
    ("raw, alpha for m=32", 5, "constant(3)"),
    ("raw, alpha for m=64", 6, "constant(5)"),
    ("raw, alpha for m=1024", 10, "constant(3)"),
    ("linear counting", 10, "leadingOnes(100)"),
    ("linear counting", 14, "leadingOnes(1000)"),
    ("bias corrected", 4, "cycle(0, 3)"),
    ("bias corrected", 6, "cycle(1, 4)"),
    ("bias corrected", 10, "constant(2)"),
    ("bias corrected with empty registers", 12, "geometric(1, 4)"),
    ("bias corrected", 14, "geometric(1)"),
    ("bias corrected with empty registers", 14, "geometric(1, 3)"),
    ("bias corrected", 18, "geometric(2)"),
]

for name, p, rule in CASES:
    make = eval(rule.replace("leadingOnes", "leading_ones"))
    value = estimate(p, [make(j) for j in range(1 << p)])
    if abs(value - math.floor(value) - 0.5) < 1e-6:
        raise SystemExit(f"{name} p={p}: estimate {value} is too close to a rounding boundary")
    print(f'{{ name = "{name}", p = {p}, rule = {rule}, expected = {math.floor(value + 0.5)} }},')
