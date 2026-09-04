#!/usr/bin/env python3
"""Read or update an existing scalar in the project's constrained values YAML.

The experiment host does not need a YAML library. This editor deliberately
supports only existing scalar keys below ``services`` and fails closed when the
requested path is absent or ambiguous.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Sequence


KEY_VALUE = re.compile(r"^(?P<indent> *)(?P<key>[A-Za-z0-9_-]+):(?P<rest>.*)$")


def scalar_locations(lines: Sequence[str]) -> dict[tuple[str, ...], tuple[int, str]]:
    stack: list[tuple[int, str]] = []
    locations: dict[tuple[str, ...], tuple[int, str]] = {}
    seen_service_paths: set[tuple[str, ...]] = set()
    for index, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = KEY_VALUE.match(line.rstrip("\r\n"))
        if not match:
            continue
        indent = len(match.group("indent"))
        while stack and indent <= stack[-1][0]:
            stack.pop()
        key = match.group("key")
        rest = match.group("rest").strip()
        path = tuple(item[1] for item in stack) + (key,)
        if path and path[0] == "services":
            if path in seen_service_paths:
                raise ValueError(f"duplicate YAML path is ambiguous: {'.'.join(path)}")
            seen_service_paths.add(path)
        if rest and not rest.startswith("#"):
            locations[path] = (index, rest)
        else:
            stack.append((indent, key))
    return locations


def decode_scalar(raw: str) -> str:
    stripped = raw.strip()
    if stripped.startswith(('"', "'")):
        try:
            # Python's literal parser accepts an expression followed by a
            # comment and keeps `#` characters that are inside the quotes.
            return str(ast.literal_eval(stripped))
        except (SyntaxError, ValueError):
            pass
    value_without_comment = stripped.split(" #", 1)[0].strip()
    return value_without_comment


def service_key(lines: Sequence[str], requested: str) -> str:
    locations = scalar_locations(lines)
    direct_prefix = ("services", requested)
    if any(path[:2] == direct_prefix for path in locations):
        return requested
    matches = [
        path[1]
        for path, (_index, raw) in locations.items()
        if len(path) == 3
        and path[0] == "services"
        and path[2] == "name"
        and decode_scalar(raw) == requested
    ]
    if len(matches) != 1:
        raise ValueError(f"service {requested!r} was not found unambiguously")
    return matches[0]


def resolve_path(lines: Sequence[str], service: str, field: str) -> tuple[str, ...]:
    field_parts = tuple(part for part in field.split(".") if part)
    if not field_parts:
        raise ValueError("field cannot be empty")
    return ("services", service_key(lines, service), *field_parts)


def get_value(lines: Sequence[str], path: tuple[str, ...]) -> str:
    locations = scalar_locations(lines)
    if path not in locations:
        raise ValueError(f"scalar path not found: {'.'.join(path)}")
    return decode_scalar(locations[path][1])


def set_value(lines: list[str], path: tuple[str, ...], value: str) -> None:
    locations = scalar_locations(lines)
    if path not in locations:
        raise ValueError(f"scalar path not found: {'.'.join(path)}")
    index, _raw = locations[path]
    original = lines[index]
    match = KEY_VALUE.match(original.rstrip("\r\n"))
    if not match:
        raise ValueError(f"cannot edit malformed line {index + 1}")
    newline = "\r\n" if original.endswith("\r\n") else "\n" if original.endswith("\n") else ""
    lines[index] = f"{match.group('indent')}{match.group('key')}: {json.dumps(value)}{newline}"


def atomic_write(path: Path, content: str) -> None:
    original_mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, original_mode)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("get", "set"))
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--service", required=True)
    parser.add_argument("--field", required=True, help="path below a service, e.g. image.tag")
    parser.add_argument("--value", help="new string value; required for set")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.operation == "set" and args.value is None:
        raise SystemExit("--value is required for set")
    lines = args.file.read_text(encoding="utf-8").splitlines(keepends=True)
    path = resolve_path(lines, args.service, args.field)
    if args.operation == "get":
        print(get_value(lines, path))
    else:
        set_value(lines, path, args.value)
        atomic_write(args.file, "".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
