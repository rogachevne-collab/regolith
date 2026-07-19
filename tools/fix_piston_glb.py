#!/usr/bin/env python3
"""Normalize Max-exported piston GLBs for Regolith (meters, Y-up, pivots)."""

from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path


COMPONENT_BYTES = {
	5120: 1,
	5121: 1,
	5122: 2,
	5123: 2,
	5125: 4,
	5126: 4,
}
TYPE_COUNTS = {
	"SCALAR": 1,
	"VEC2": 2,
	"VEC3": 3,
	"VEC4": 4,
	"MAT2": 4,
	"MAT3": 9,
	"MAT4": 16,
}


def _pad4(n: int) -> int:
	return (4 - (n % 4)) % 4


def _load_glb(path: Path) -> tuple[dict, bytes]:
	data = path.read_bytes()
	magic, version, length = struct.unpack_from("<4sII", data, 0)
	if magic != b"glTF":
		raise ValueError(f"not a glb: {path}")
	json_len, json_type = struct.unpack_from("<I4s", data, 12)
	if json_type != b"JSON":
		raise ValueError("missing JSON chunk")
	js = json.loads(data[20 : 20 + json_len].decode("utf-8"))
	off = 20 + json_len + _pad4(json_len)
	bin_data = b""
	if off + 8 <= length:
		bin_len, bin_type = struct.unpack_from("<I4s", data, off)
		if bin_type != b"BIN\x00":
			raise ValueError("missing BIN chunk")
		bin_data = bytearray(data[off + 8 : off + 8 + bin_len])
	return js, bin_data


def _write_glb(path: Path, js: dict, bin_data: bytes) -> None:
	json_bytes = json.dumps(js, separators=(",", ":")).encode("utf-8")
	json_pad = b" " * _pad4(len(json_bytes))
	bin_pad = b"\x00" * _pad4(len(bin_data))
	json_chunk = json_bytes + json_pad
	bin_chunk = bin_data + bin_pad
	total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
	out = bytearray()
	out += struct.pack("<4sII", b"glTF", 2, total)
	out += struct.pack("<I4s", len(json_chunk), b"JSON")
	out += json_chunk
	out += struct.pack("<I4s", len(bin_chunk), b"BIN\x00")
	out += bin_chunk
	path.write_bytes(out)


def _accessor_layout(accessor: dict, buffer_views: list[dict]) -> tuple[int, int, int, int]:
	bv = buffer_views[accessor["bufferView"]]
	comp = accessor["componentType"]
	count = TYPE_COUNTS[accessor["type"]]
	comp_size = COMPONENT_BYTES[comp]
	elem_size = comp_size * count
	stride = bv.get("byteStride", elem_size)
	base = bv.get("byteOffset", 0) + accessor.get("byteOffset", 0)
	return base, accessor["count"], stride, elem_size


def _read_f32_vec(bin_data: bytearray, offset: int, n: int) -> list[float]:
	return list(struct.unpack_from(f"<{n}f", bin_data, offset))


def _write_f32_vec(bin_data: bytearray, offset: int, values: list[float]) -> None:
	struct.pack_into(f"<{len(values)}f", bin_data, offset, *values)


def _xform_pos(x: float, y: float, z: float, scale: float) -> tuple[float, float, float]:
	# Max Z-up cm -> Godot/glTF Y-up meters: (x, y, z) -> scale*(x, z, -y)
	return (x * scale, z * scale, -y * scale)


def _xform_dir(x: float, y: float, z: float) -> tuple[float, float, float]:
	nx, ny, nz = x, z, -y
	length = math.sqrt(nx * nx + ny * ny + nz * nz)
	if length <= 1e-12:
		return (0.0, 1.0, 0.0)
	return (nx / length, ny / length, nz / length)


def _transform_accessor_vec3(
	js: dict,
	bin_data: bytearray,
	accessor_index: int,
	mode: str,
	scale: float,
) -> None:
	accessor = js["accessors"][accessor_index]
	if accessor["componentType"] != 5126:
		raise ValueError(f"accessor {accessor_index} is not float32")
	base, count, stride, elem_size = _accessor_layout(accessor, js["bufferViews"])
	if elem_size != 12:
		raise ValueError(f"accessor {accessor_index} is not VEC3 float")
	mins = [math.inf, math.inf, math.inf]
	maxs = [-math.inf, -math.inf, -math.inf]
	for i in range(count):
		off = base + i * stride
		x, y, z = _read_f32_vec(bin_data, off, 3)
		if mode == "pos":
			nx, ny, nz = _xform_pos(x, y, z, scale)
		else:
			nx, ny, nz = _xform_dir(x, y, z)
		_write_f32_vec(bin_data, off, [nx, ny, nz])
		mins[0] = min(mins[0], nx)
		mins[1] = min(mins[1], ny)
		mins[2] = min(mins[2], nz)
		maxs[0] = max(maxs[0], nx)
		maxs[1] = max(maxs[1], ny)
		maxs[2] = max(maxs[2], nz)
	accessor["min"] = mins
	accessor["max"] = maxs


def _transform_accessor_tangent(
	js: dict,
	bin_data: bytearray,
	accessor_index: int,
) -> None:
	accessor = js["accessors"][accessor_index]
	if accessor["componentType"] != 5126 or accessor["type"] != "VEC4":
		return
	base, count, stride, _elem = _accessor_layout(accessor, js["bufferViews"])
	for i in range(count):
		off = base + i * stride
		x, y, z, w = _read_f32_vec(bin_data, off, 4)
		nx, ny, nz = _xform_dir(x, y, z)
		_write_f32_vec(bin_data, off, [nx, ny, nz, w])


def _shift_accessor_pos(
	js: dict,
	bin_data: bytearray,
	accessor_index: int,
	dy: float,
) -> None:
	if abs(dy) <= 1e-12:
		return
	accessor = js["accessors"][accessor_index]
	base, count, stride, _elem = _accessor_layout(accessor, js["bufferViews"])
	mins = list(accessor["min"])
	maxs = list(accessor["max"])
	for i in range(count):
		off = base + i * stride
		x, y, z = _read_f32_vec(bin_data, off, 3)
		y2 = y + dy
		_write_f32_vec(bin_data, off, [x, y2, z])
	mins[1] += dy
	maxs[1] += dy
	accessor["min"] = mins
	accessor["max"] = maxs


def _mesh_position_accessors(js: dict) -> list[int]:
	out: list[int] = []
	for mesh in js.get("meshes", []):
		for prim in mesh.get("primitives", []):
			pos = prim.get("attributes", {}).get("POSITION")
			if pos is not None:
				out.append(pos)
	return out


def _all_attribute_accessors(js: dict) -> dict[str, list[int]]:
	grouped: dict[str, list[int]] = {
		"POSITION": [],
		"NORMAL": [],
		"TANGENT": [],
	}
	for mesh in js.get("meshes", []):
		for prim in mesh.get("primitives", []):
			attrs = prim.get("attributes", {})
			for key in grouped:
				if key in attrs:
					grouped[key].append(attrs[key])
	return grouped


def _find_named_mesh_nodes(js: dict) -> dict[str, int]:
	found: dict[str, int] = {}
	for i, node in enumerate(js.get("nodes", [])):
		name = node.get("name")
		if name and "mesh" in node:
			found[name] = i
	return found


def _mesh_pos_accessor(js: dict, mesh_index: int) -> int:
	return js["meshes"][mesh_index]["primitives"][0]["attributes"]["POSITION"]


def fix_base(src: Path, dst: Path, scale: float = 0.01) -> None:
	js, bin_data = _load_glb(src)
	attrs = _all_attribute_accessors(js)
	for ai in attrs["POSITION"]:
		_transform_accessor_vec3(js, bin_data, ai, "pos", scale)
	for ai in attrs["NORMAL"]:
		_transform_accessor_vec3(js, bin_data, ai, "dir", 1.0)
	for ai in attrs["TANGENT"]:
		_transform_accessor_tangent(js, bin_data, ai)

	# Keep artist's bottom at y=0 (folded assembly rests on ground).
	pos_acc = _mesh_position_accessors(js)
	min_y = min(js["accessors"][ai]["min"][1] for ai in pos_acc)
	for ai in pos_acc:
		_shift_accessor_pos(js, bin_data, ai, -min_y)

	named = _find_named_mesh_nodes(js)
	required = ["PistonBase", "PistonSegment1", "PistonSegment2"]
	missing = [n for n in required if n not in named]
	if missing:
		raise ValueError(f"missing nodes: {missing}; have {sorted(named)}")

	meshes = {
		"PistonBase": js["nodes"][named["PistonBase"]]["mesh"],
		"PistonSegment1": js["nodes"][named["PistonSegment1"]]["mesh"],
		"PistonSegment2": js["nodes"][named["PistonSegment2"]]["mesh"],
	}

	# Put each segment pivot on its own bottom; restore folded pose via translation.
	seg_rest_y: dict[str, float] = {}
	for seg_name in ("PistonSegment1", "PistonSegment2"):
		pos_ai = _mesh_pos_accessor(js, meshes[seg_name])
		seg_min_y = js["accessors"][pos_ai]["min"][1]
		_shift_accessor_pos(js, bin_data, pos_ai, -seg_min_y)
		seg_rest_y[seg_name] = seg_min_y

	js["nodes"] = [
		{
			"name": "PistonBase",
			"mesh": meshes["PistonBase"],
			"children": [1, 2],
		},
		{"name": "PistonSegment1", "mesh": meshes["PistonSegment1"]},
		{"name": "PistonSegment2", "mesh": meshes["PistonSegment2"]},
	]
	js["scenes"] = [{"name": "PistonSmall_Base", "nodes": [0]}]
	js["scene"] = 0
	js.setdefault("asset", {})["generator"] = "regolith/fix_piston_glb.py"
	# Author extras for runtime animation (meters, extension 0..2).
	js["extras"] = {
		"regolith_piston": {
			"housing_height_m": js["accessors"][_mesh_pos_accessor(js, meshes["PistonBase"])][
				"max"
			][1],
			"segment1_extend_y_m": 0.84,
			"segment2_extend_y_m": 1.865,
			"travel_m": 2.0,
		}
	}
	_write_glb(dst, js, bytes(bin_data))
	_print_summary(dst, js)


def fix_head(src: Path, dst: Path, scale: float = 0.01) -> None:
	js, bin_data = _load_glb(src)
	attrs = _all_attribute_accessors(js)
	for ai in attrs["POSITION"]:
		_transform_accessor_vec3(js, bin_data, ai, "pos", scale)
	for ai in attrs["NORMAL"]:
		_transform_accessor_vec3(js, bin_data, ai, "dir", 1.0)
	for ai in attrs["TANGENT"]:
		_transform_accessor_tangent(js, bin_data, ai)

	pos_acc = _mesh_position_accessors(js)
	min_y = min(js["accessors"][ai]["min"][1] for ai in pos_acc)
	for ai in pos_acc:
		_shift_accessor_pos(js, bin_data, ai, -min_y)

	named = _find_named_mesh_nodes(js)
	if "PistonHead" not in named:
		raise ValueError(f"missing PistonHead; have {sorted(named)}")
	mesh_index = js["nodes"][named["PistonHead"]]["mesh"]
	js["nodes"] = [{"name": "PistonHead", "mesh": mesh_index}]
	js["scenes"] = [{"name": "PistonSmall_Head", "nodes": [0]}]
	js["scene"] = 0
	js.setdefault("asset", {})["generator"] = "regolith/fix_piston_glb.py"
	_write_glb(dst, js, bytes(bin_data))
	_print_summary(dst, js)


def _print_summary(path: Path, js: dict) -> None:
	print(f"wrote {path}")
	for i, node in enumerate(js.get("nodes", [])):
		print(
			f"  node[{i}] {node.get('name')} mesh={node.get('mesh')} "
			f"children={node.get('children')}"
		)
	for mi, mesh in enumerate(js.get("meshes", [])):
		pos = mesh["primitives"][0]["attributes"]["POSITION"]
		a = js["accessors"][pos]
		size = [a["max"][k] - a["min"][k] for k in range(3)]
		print(
			f"  mesh[{mi}] y=[{a['min'][1]:.4f},{a['max'][1]:.4f}] "
			f"size=({size[0]:.4f},{size[1]:.4f},{size[2]:.4f})"
		)


def main() -> int:
	assets = Path(r"Y:\RegolithAssets")
	out_dir = Path(r"Y:\regolith\resources\models")
	out_dir.mkdir(parents=True, exist_ok=True)
	fix_base(assets / "PistonSmall_Base.glb.bak", out_dir / "piston_small_base.glb")
	fix_head(assets / "PistonSmall_Head.glb.bak", out_dir / "piston_small_head.glb")
	# Also refresh the artist's folder copies for convenience.
	fix_base(assets / "PistonSmall_Base.glb.bak", assets / "PistonSmall_Base.glb")
	fix_head(assets / "PistonSmall_Head.glb.bak", assets / "PistonSmall_Head.glb")
	return 0


if __name__ == "__main__":
	sys.exit(main())
