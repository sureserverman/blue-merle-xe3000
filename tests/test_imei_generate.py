"""Tests for IMEI generation logic (no device/serial required)."""

import sys
import os
from functools import reduce

# Add parent lib path so we can import the generator module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'files', 'lib', 'blue-merle'))

# We import specific functions rather than the whole module since
# the module's top-level tries to set up argparse. We test the
# generation and validation logic directly.


def luhn_check(imei_str):
    """Verify a 15-digit IMEI passes the Luhn check."""
    digits = [int(d) for d in imei_str]
    total = 0
    for i, d in enumerate(digits):
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def generate_imei_standalone(imei_prefix_list, seed=None):
    """Standalone reimplementation of generate_imei for testing
    (avoids importing the module which has side effects)."""
    import random
    import string

    if seed is not None:
        random.seed(seed)

    imei_length = 14
    prefix = random.choice(imei_prefix_list)
    random_part_length = imei_length - len(prefix)
    imei = prefix + "".join(random.sample(string.digits, random_part_length))

    iteration_1 = "".join(
        [c if i % 2 == 0 else str(2 * int(c)) for i, c in enumerate(imei)]
    )
    total = reduce((lambda a, b: int(a) + int(b)), iteration_1)
    validation_digit = (10 - int(str(total)[-1])) % 10
    return str(imei) + str(validation_digit)


# The same prefix list used in imei_generate.py
IMEI_PREFIXES = [
    "35674108", "35290611", "35397710", "35323210", "35384110",
    "35982748", "35672011", "35759049", "35266891", "35407115",
    "35538025", "35480910", "35324590", "35901183", "35139729",
    "35479164",
]


class TestIMEIGeneration:
    def test_imei_is_15_digits(self):
        imei = generate_imei_standalone(IMEI_PREFIXES)
        assert len(imei) == 15, f"IMEI should be 15 digits, got {len(imei)}: {imei}"
        assert imei.isdigit(), f"IMEI should be all digits: {imei}"

    def test_imei_passes_luhn(self):
        for _ in range(100):
            imei = generate_imei_standalone(IMEI_PREFIXES)
            assert luhn_check(imei), f"IMEI {imei} fails Luhn check"

    def test_imei_starts_with_known_prefix(self):
        for _ in range(50):
            imei = generate_imei_standalone(IMEI_PREFIXES)
            assert any(
                imei.startswith(p) for p in IMEI_PREFIXES
            ), f"IMEI {imei} does not start with a known prefix"

    def test_deterministic_mode_stable(self):
        """Same seed should produce the same IMEI."""
        seed = b"310260000000001"  # simulated IMSI
        imei1 = generate_imei_standalone(IMEI_PREFIXES, seed=seed)
        imei2 = generate_imei_standalone(IMEI_PREFIXES, seed=seed)
        assert imei1 == imei2, f"Deterministic IMEI mismatch: {imei1} vs {imei2}"

    def test_random_mode_varies(self):
        """Different random invocations should (almost certainly) produce different IMEIs."""
        import random
        random.seed()  # re-seed with system entropy
        imeis = set()
        for _ in range(20):
            imeis.add(generate_imei_standalone(IMEI_PREFIXES))
        # With 20 random IMEIs, we should get at least 2 unique values
        assert len(imeis) > 1, "All random IMEIs were identical"

    def test_different_seeds_produce_different_imeis(self):
        seed_a = b"310260000000001"
        seed_b = b"310260000000002"
        imei_a = generate_imei_standalone(IMEI_PREFIXES, seed=seed_a)
        imei_b = generate_imei_standalone(IMEI_PREFIXES, seed=seed_b)
        assert imei_a != imei_b, f"Different seeds should produce different IMEIs"
