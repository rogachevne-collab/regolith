#!/usr/bin/env python3
"""Scan scripts/ for common Godot 4.8 GDScript analyzer warning patterns."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "scripts"

NODE3D_PROPS = {
    "basis",
    "transform",
    "position",
    "rotation",
    "scale",
    "name",
    "visible",
}
CONTROL_PROPS = NODE3D_PROPS | {"text", "size"}
GLOBAL_IDS = {
    "sign",
    "abs",
    "min",
    "max",
    "clamp",
    "range",
    "load",
    "str",
    "hash",
    "seed",
    "exp",
    "log",
    "sin",
    "cos",
    "tan",
    "floor",
    "ceil",
    "round",
    "pow",
    "sqrt",
}

EXTENDS_RE = re.compile(r"^extends\s+(\w+)", re.M)
MEMBER_RE = re.compile(r"^(?:@export\s+)?(?:static\s+)?(?:var|const)\s+(\w+)", re.M)
FUNC_START_RE = re.compile(r"^(?:static\s+)?func\s+(\w+)\s*\(", re.M)
FOR_RE = re.compile(r"^\s*for\s+(\w+)\s+in\b", re.M)
LOCAL_VAR_RE = re.compile(r"^\s*var\s+(\w+)", re.M)
ENUM_ASSIGN_RE = re.compile(r"\.(\w+)\s*=\s*int\s*\([^)]*\)(?!\s*as\s+\w+)", re.M)
TERNARY_VEC_RE = re.compile(
    r"Vector3i\.[A-Z_]+ if .+ else Vector3\.|Vector3\.[A-Z_]+ if .+ else Vector3i\.",
    re.M,
)


def base_props(extends_name: str) -> set[str]:
    if extends_name in {
        "Control",
        "Label",
        "Button",
        "Panel",
        "TextureRect",
        "BaseButton",
    }:
        return CONTROL_PROPS
    if extends_name in {
        "Node3D",
        "StaticBody3D",
        "RigidBody3D",
        "CharacterBody3D",
        "MeshInstance3D",
        "Camera3D",
    }:
        return NODE3D_PROPS
    if extends_name == "Node":
        return {"name", "visible"}
    return set()


def extract_func_signatures(text: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for match in FUNC_START_RE.finditer(text):
        name = match.group(1)
        start = match.start()
        depth = 0
        i = match.end() - 1
        while i < len(text):
            ch = text[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    sig = text[start : i + 1]
                    out.append((name, sig))
                    break
            i += 1
    return out


def extract_params(sig: str) -> list[str]:
    start = sig.find("(")
    end = sig.rfind(")")
    body = sig[start + 1 : end]
    params: list[str] = []
    for chunk in body.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        name = chunk.split(":")[0].split("=")[0].strip()
        if name:
            params.append(name)
    return params


def line_no(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def scan_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    rel = str(path.relative_to(ROOT.parent))
    issues: list[str] = []

    extends_match = EXTENDS_RE.search(text)
    extends_name = extends_match.group(1) if extends_match else ""
    members = set(MEMBER_RE.findall(text))
    base = base_props(extends_name)

    for func_name, sig in extract_func_signatures(text):
        for param in extract_params(sig):
            if param in members:
                issues.append(
                    f"{rel}: SHADOWED_VARIABLE param `{param}` in func `{func_name}`"
                )
            if base and param in base:
                issues.append(
                    f"{rel}: SHADOWED_VARIABLE_BASE_CLASS param `{param}` in func `{func_name}`"
                )
            if param in GLOBAL_IDS:
                issues.append(
                    f"{rel}: SHADOWED_GLOBAL_IDENTIFIER param `{param}` in func `{func_name}`"
                )

    for match in LOCAL_VAR_RE.finditer(text):
        name = match.group(1)
        ln = line_no(text, match.start())
        if base and name in base:
            issues.append(f"{rel}:{ln}: SHADOWED_VARIABLE_BASE_CLASS local `{name}`")
        if name in GLOBAL_IDS:
            issues.append(f"{rel}:{ln}: SHADOWED_GLOBAL_IDENTIFIER local `{name}`")

    for match in FOR_RE.finditer(text):
        name = match.group(1)
        ln = line_no(text, match.start())
        if base and name in base:
            issues.append(f"{rel}:{ln}: SHADOWED_VARIABLE_BASE_CLASS for `{name}`")
        if name in GLOBAL_IDS:
            issues.append(f"{rel}:{ln}: SHADOWED_GLOBAL_IDENTIFIER for `{name}`")

    for match in ENUM_ASSIGN_RE.finditer(text):
        field = match.group(1)
        ln = line_no(text, match.start())
        issues.append(f"{rel}:{ln}: INT_AS_ENUM_WITHOUT_CAST field `{field}`")

    for match in TERNARY_VEC_RE.finditer(text):
        ln = line_no(text, match.start())
        issues.append(f"{rel}:{ln}: INCOMPATIBLE_TERNARY `{match.group(0)}`")

    return issues


def main() -> int:
    all_issues: list[str] = []
    for path in sorted(ROOT.rglob("*.gd")):
        if "addons" in path.parts:
            continue
        all_issues.extend(scan_file(path))

    for issue in sorted(set(all_issues)):
        print(issue)
    print(f"\nTotal: {len(set(all_issues))}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
