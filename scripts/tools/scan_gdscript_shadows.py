#!/usr/bin/env python3
"""Scan scripts/**/*.gd for likely GDScript analyzer shadow warnings."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "scripts"

NODE3D_NAMES = {"basis", "transform", "position", "rotation", "scale", "name", "owner", "visible"}
CONTROL_NAMES = {
    "size", "offset", "text", "theme", "visible", "show", "parent", "name",
    "icon", "disabled", "material", "modulate",
}
NODE_NAMES = {"name", "owner", "parent", "script", "process", "visible"}
GLOBALS = {
    "snapped", "range", "sign", "abs", "min", "max", "floor", "ceil", "round",
    "lerp", "clamp", "seed", "load", "print", "str", "hash",
}

EXTENDS_RE = re.compile(r"^extends\s+(\w+)", re.M)

CONTROL_BASES = {
    "Control", "Panel", "PanelContainer", "Container", "Label", "Button",
    "HBoxContainer", "VBoxContainer", "MarginContainer", "ColorRect",
    "TextureRect", "RichTextLabel", "ScrollContainer", "GridContainer",
    "BoxContainer", "BaseButton", "CheckBox", "LineEdit", "TextEdit",
    "TabContainer", "Tree", "ItemList", "ProgressBar", "Slider",
    "SpinBox", "OptionButton", "MenuButton", "PopupMenu", "PopupPanel",
    "SubViewportContainer", "AspectRatioContainer", "CenterContainer",
    "FlowContainer", "SplitContainer", "ReferenceRect", "NinePatchRect",
    "GraphEdit", "GraphNode", "LinkButton", "TextureButton", "TextureProgressBar",
    "CodeEdit", "ConfirmationDialog", "AcceptDialog", "FileDialog",
    "ColorPickerButton", "MenuBar", "HSplitContainer", "VSplitContainer",
    "HSeparator", "VSeparator", "Range", "ScrollBar", "HScrollBar", "VScrollBar",
}
NODE3D_BASES = {
    "Node3D", "Camera3D", "RigidBody3D", "StaticBody3D", "CharacterBody3D",
    "AnimatableBody3D", "Area3D", "CollisionObject3D", "PhysicsBody3D",
    "MeshInstance3D", "MultiMeshInstance3D", "Skeleton3D", "Marker3D",
    "Path3D", "CSGShape3D", "CSGBox3D", "CSGSphere3D", "VisibleOnScreenNotifier3D",
    "AudioStreamPlayer3D", "NavigationRegion3D", "NavigationAgent3D",
    "SpringArm3D", "RayCast3D", "ShapeCast3D", "VehicleBody3D", "SoftBody3D",
    "GPUParticles3D", "CPUParticles3D", "Light3D", "DirectionalLight3D",
    "OmniLight3D", "SpotLight3D", "Decal", "FogVolume", "XRAnchor3D",
    "XRController3D", "XRNode3D", "GridMap", "Sprite3D", "AnimatedSprite3D",
    "Label3D", "SpriteBase3D", "BoneAttachment3D", "RemoteTransform3D",
    "ImpostorInstance3D", "OpenXRHand", "PhysicalBone3D",
}


def base_kind(extends: str) -> str | None:
    if extends in NODE3D_BASES or extends.endswith("3D"):
        return "node3d"
    if extends in CONTROL_BASES or extends.endswith("Container") or extends.endswith("Panel"):
        return "control"
    if extends == "Node" or extends.endswith("Tree"):
        return "node"
    return None


def scan_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    if "extends SceneTree" in text:
        return []
    m = EXTENDS_RE.search(text)
    if not m:
        return []
    kind = base_kind(m.group(1))
    if kind is None:
        return []

    if kind == "node3d":
        names = NODE3D_NAMES | GLOBALS
    elif kind == "control":
        names = CONTROL_NAMES | GLOBALS
    else:
        names = NODE_NAMES | GLOBALS

    hits: list[str] = []
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for name in names:
            for pat in (
                rf"\bvar\s+{name}\b",
                rf"\bfor\s+{name}\b(?!\.|\s*=\s*)",
                rf"\bfunc\s+\w+\([^)]*\b{name}\s*:",
            ):
                if re.search(pat, line):
                    hits.append(f"{path.relative_to(ROOT.parent)}:{i}: {stripped}")
                    break
    return hits


def main() -> None:
    all_hits: list[str] = []
    for p in sorted(ROOT.rglob("*.gd")):
        if "addons" in p.parts:
            continue
        all_hits.extend(scan_file(p))
    for h in sorted(set(all_hits)):
        print(h)
    print(f"\n# total: {len(set(all_hits))}")


if __name__ == "__main__":
    main()
