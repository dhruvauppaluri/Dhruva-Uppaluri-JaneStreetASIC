#!/usr/bin/env python3
"""Assembler for the 16-bit protocol-processor instruction set."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


OPCODES = {
    "NOP": 0x0,
    "OUT": 0x1,
    "DIR": 0x2,
    "WAIT": 0x3,
    "IN": 0x4,
    "LDI": 0x5,
    "ANDI": 0x6,
    "XORI": 0x7,
    "ADDI": 0x8,
    "SHL": 0x9,
    "SHR": 0xA,
    "JMP": 0xB,
    "JZ": 0xC,
    "JNZ": 0xD,
    "WAIT_PIN": 0xE,
    "HALT": 0xF,
}


def parse_number(token: str, labels: dict[str, int]) -> int:
    key = token.upper()
    if key in labels:
        return labels[key]
    return int(token, 0)


def parse_register(token: str) -> int:
    match = re.fullmatch(r"R([0-3])", token.upper())
    if not match:
        raise ValueError(f"expected R0..R3, got {token!r}")
    return int(match.group(1))


def clean_lines(source: str) -> tuple[list[tuple[int, str]], dict[str, int]]:
    instructions: list[tuple[int, str]] = []
    labels: dict[str, int] = {}

    for line_number, raw_line in enumerate(source.splitlines(), start=1):
        line = raw_line.split(";", 1)[0].split("#", 1)[0].strip()
        if not line:
            continue

        while ":" in line:
            label, line = line.split(":", 1)
            label = label.strip().upper()
            if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", label):
                raise ValueError(f"line {line_number}: invalid label {label!r}")
            if label in labels:
                raise ValueError(f"line {line_number}: duplicate label {label}")
            labels[label] = len(instructions)
            line = line.strip()
            if not line:
                break

        if line:
            instructions.append((line_number, line))

    return instructions, labels


def encode(line: str, labels: dict[str, int]) -> int:
    fields = [field for field in re.split(r"[\s,]+", line.strip()) if field]
    mnemonic = fields[0].upper()
    args = fields[1:]

    if mnemonic not in OPCODES:
        raise ValueError(f"unknown instruction {mnemonic!r}")

    opcode = OPCODES[mnemonic]
    operand = 0

    if mnemonic in {"NOP", "HALT"}:
        if args:
            raise ValueError(f"{mnemonic} takes no operands")
    elif mnemonic == "OUT":
        if len(args) != 1:
            raise ValueError("OUT takes one immediate or register")
        if args[0].upper().startswith("R"):
            operand = 0x800 | (parse_register(args[0]) << 8)
        else:
            operand = parse_number(args[0], labels)
            if not 0 <= operand <= 0xFF:
                raise ValueError("OUT immediate must fit in 8 bits")
    elif mnemonic == "DIR":
        if len(args) != 1:
            raise ValueError("DIR takes one 8-bit mask")
        operand = parse_number(args[0], labels)
        if not 0 <= operand <= 0xFF:
            raise ValueError("DIR mask must fit in 8 bits")
    elif mnemonic == "WAIT":
        if len(args) != 1:
            raise ValueError("WAIT takes one cycle count")
        operand = parse_number(args[0], labels)
        if not 0 <= operand <= 0xFFF:
            raise ValueError("WAIT count must fit in 12 bits")
    elif mnemonic == "IN":
        if len(args) != 1:
            raise ValueError("IN takes one register")
        operand = parse_register(args[0]) << 8
    elif mnemonic in {"LDI", "ANDI", "XORI", "ADDI"}:
        if len(args) != 2:
            raise ValueError(f"{mnemonic} takes a register and immediate")
        immediate = parse_number(args[1], labels)
        if not 0 <= immediate <= 0xFF:
            raise ValueError(f"{mnemonic} immediate must fit in 8 bits")
        operand = (parse_register(args[0]) << 8) | immediate
    elif mnemonic in {"SHL", "SHR"}:
        if len(args) != 1:
            raise ValueError(f"{mnemonic} takes one register")
        operand = parse_register(args[0]) << 8
    elif mnemonic == "JMP":
        if len(args) != 1:
            raise ValueError("JMP takes one address")
        operand = parse_number(args[0], labels)
        if not 0 <= operand <= 31:
            raise ValueError("JMP address must be 0..31")
    elif mnemonic in {"JZ", "JNZ"}:
        if len(args) != 2:
            raise ValueError(f"{mnemonic} takes a register and address")
        address = parse_number(args[1], labels)
        if not 0 <= address <= 31:
            raise ValueError(f"{mnemonic} address must be 0..31")
        operand = (parse_register(args[0]) << 8) | address
    elif mnemonic == "WAIT_PIN":
        if len(args) != 2:
            raise ValueError("WAIT_PIN takes a pin number and level")
        pin = parse_number(args[0], labels)
        level = parse_number(args[1], labels)
        if not 0 <= pin <= 7 or level not in {0, 1}:
            raise ValueError("WAIT_PIN requires pin 0..7 and level 0 or 1")
        operand = (level << 3) | pin

    return (opcode << 12) | operand


def assemble(source: str, depth: int = 32) -> list[int]:
    lines, labels = clean_lines(source)
    if len(lines) > depth:
        raise ValueError(f"program has {len(lines)} instructions; maximum is {depth}")

    words: list[int] = []
    for line_number, line in lines:
        try:
            words.append(encode(line, labels))
        except ValueError as error:
            raise ValueError(f"line {line_number}: {error}") from error

    return words + [0xF000] * (depth - len(words))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--depth", type=int, default=32)
    args = parser.parse_args()

    try:
        words = assemble(args.source.read_text(), args.depth)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    args.output.write_text("".join(f"{word:04x}\n" for word in words))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
