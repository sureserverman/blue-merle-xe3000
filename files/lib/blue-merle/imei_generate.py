#!/usr/bin/env python3
"""IMEI generator for GL-XE3000 (Puli AX).

Uses gl_modem for all modem communication. No raw serial.
"""
import random
import string
import argparse
import subprocess
import re
from functools import reduce
from enum import Enum


class Modes(Enum):
    DETERMINISTIC = 1
    RANDOM = 2
    STATIC = 3


ap = argparse.ArgumentParser()
ap.add_argument("-v", "--verbose", help="Enables verbose output",
                action="store_true")
ap.add_argument("-g", "--generate-only", help="Only generates an IMEI rather than setting it",
                   action="store_true")
modes = ap.add_mutually_exclusive_group()
modes.add_argument("-d", "--deterministic", help="Switches IMEI generation to deterministic mode", action="store_true")
modes.add_argument("-s", "--static", help="Sets user-defined IMEI",
                   action="store")
modes.add_argument("-r", "--random", help="Sets random IMEI",
                   action="store_true")

# Example IMEI: 490154203237518
imei_length = 14  # without validation digit
imei_prefix = ["35674108", "35290611", "35397710", "35323210", "35384110",
               "35982748", "35672011", "35759049", "35266891", "35407115",
               "35538025", "35480910", "35324590", "35901183", "35139729",
               "35479164"]

verbose = False
mode = None
TIMEOUT = 5


def _gl_modem_at(cmd):
    """Run an AT command via gl_modem."""
    try:
        result = subprocess.run(
            ['gl_modem', 'AT', cmd],
            capture_output=True, text=True, timeout=TIMEOUT
        )
        return result.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        if verbose:
            print(f"gl_modem error: {e}")
        return ""


def get_imsi():
    output = _gl_modem_at('AT+CIMI')
    if verbose:
        print(f"AT+CIMI output: {output}")
    imsi_d = re.findall(r'[0-9]{15}', output)
    return "".join(imsi_d).encode()


def get_imei():
    output = _gl_modem_at('AT+GSN')
    if verbose:
        print(f"AT+GSN output: {output}")
    imei_d = re.findall(r'[0-9]{15}', output)
    return "".join(imei_d).encode()


def set_imei(imei):
    cmd_str = f'AT+EGMR=1,7,"{imei}"'
    output = _gl_modem_at(cmd_str)
    if verbose:
        print(f"{cmd_str} output: {output}")

    new_imei = get_imei()
    if verbose:
        print(f"New IMEI: {new_imei} Old IMEI: {imei.encode()}")

    if new_imei == imei.encode():
        print("IMEI has been successfully changed.")
        return True
    else:
        print("IMEI has not been successfully changed.")
        return False


def generate_imei(imei_prefix, imsi_d):
    if mode == Modes.DETERMINISTIC:
        random.seed(imsi_d)

    imei = random.choice(imei_prefix)
    if verbose:
        print(f"IMEI prefix: {imei}")
    random_part_length = imei_length - len(imei)
    imei += "".join(random.sample(string.digits, random_part_length))
    if verbose:
        print(f"IMEI without validation digit: {imei}")

    iteration_1 = "".join([c if i % 2 == 0 else str(2*int(c)) for i, c in enumerate(imei)])
    sum = reduce((lambda a, b: int(a) + int(b)), iteration_1)
    validation_digit = (10 - int(str(sum)[-1])) % 10
    if verbose:
        print(f"Validation digit: {validation_digit}")

    imei = str(imei) + str(validation_digit)
    if verbose:
        print(f"Resulting IMEI: {imei}")
    return imei


def validate_imei(imei):
    if len(imei) != 14:
        print(f"NOT A VALID IMEI: {imei} - IMEI must be 14 characters in length")
        return False

    validation_digit = int(imei[-1])
    imei_verify = imei[0:14]
    iteration_1 = "".join([c if i % 2 == 0 else str(2*int(c)) for i, c in enumerate(imei_verify)])
    sum = reduce((lambda a, b: int(a) + int(b)), iteration_1)
    validation_digit_verify = (10 - int(str(sum)[-1])) % 10

    if validation_digit == validation_digit_verify:
        print(f"{imei} is CORRECT")
        return True

    print(f"NOT A VALID IMEI: {imei}")
    return False


if __name__ == '__main__':
    args = ap.parse_args()
    imsi_d = None
    if args.verbose:
        verbose = args.verbose

    if args.deterministic:
        mode = Modes.DETERMINISTIC
        imsi_d = get_imsi()
    if args.random:
        mode = Modes.RANDOM
    if args.static is not None:
        mode = Modes.STATIC
        static_imei = args.static

    if mode == Modes.STATIC:
        if validate_imei(static_imei):
            set_imei(static_imei)
        else:
            exit(-1)
    else:
        imei = generate_imei(imei_prefix, imsi_d)
        if verbose:
            print(f"Generated new IMEI: {imei}")
        if not args.generate_only:
            if not set_imei(imei):
                exit(-1)

    exit(0)
