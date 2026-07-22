"""Generate `src/granular_mc_tables.hpp` — the marching-cubes triangle table.

Derived, not transcribed. The classic 256-row table is usually copied from
Bourke's polygonise.c and trusted; a single mistyped index there is a hole in
the surface that shows up as a black sliver at some rare corner configuration
months later. This script builds the table from first principles and then
*proves* it consistent, so nothing rests on a copy being faithful:

  1. For every corner mask, the crossing edges are exactly the cube edges
     whose endpoints disagree about being inside.
  2. Each cube face pairs its crossing points into segments. A face with two
     diagonal inside corners is the ambiguous case; it is resolved the same
     way every time — separate the inside corners — and the rule depends only
     on the face's own four corner bits, so the two cubes sharing a face can
     never disagree about the contour crossing it. That is the whole of
     crack-freeness, checked below rather than assumed.
  3. Segments close into loops (every crossing edge borders exactly two
     faces), and each loop is fan-triangulated.
  4. Orientation: Godot's front faces wind clockwise, i.e. a front triangle's
     cross(b-a, c-a) points *into* the body (verified against BoxMesh, which
     writes its +Z face with an inward cross product). Loops are oriented so
     the fan normals point from outside toward the material.

Checks, all hard failures:
  - every row uses exactly the crossing edges of its mask;
  - within a row, every triangle edge is either shared by two triangles in
    opposite directions or lies on a cube face;
  - for all 256 x 6 x 256 mask/face/neighbour-mask combinations with matching
    face patterns, the two cubes' boundary segments on the shared face agree
    undirected and oppose directed — watertight and consistently oriented
    across cubes, exhaustively.

Run from anywhere; writes the header next to the other sources:
    python native/regolith_moon_bake/tools/gen_mc_tables.py
"""

from __future__ import annotations

import os
from itertools import product

CORNERS = [
    (0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1),
    (0, 1, 0), (1, 1, 0), (1, 1, 1), (0, 1, 1),
]
EDGES = [
    (0, 1), (1, 2), (2, 3), (3, 0),
    (4, 5), (5, 6), (6, 7), (7, 4),
    (0, 4), (1, 5), (2, 6), (3, 7),
]
# Cyclic corner quads. Orientation of the listing does not matter: segments
# are undirected and triangle orientation is decided geometrically per loop.
FACES = [
    (0, 1, 2, 3),  # y = 0
    (4, 5, 6, 7),  # y = 1
    (0, 3, 7, 4),  # x = 0
    (1, 2, 6, 5),  # x = 1
    (0, 1, 5, 4),  # z = 0
    (3, 2, 6, 7),  # z = 1
]

EDGE_OF_PAIR = {frozenset(pair): index for index, pair in enumerate(EDGES)}


def inside(mask: int, corner: int) -> bool:
    return bool(mask >> corner & 1)


def face_segments(mask: int, face: tuple[int, int, int, int]) -> list[tuple[int, int]]:
    """The contour segments this face contributes, as pairs of crossing edges.

    A pure function of the face's four corner bits — the invariant the
    exhaustive check below leans on.
    """
    quad_edges = [
        EDGE_OF_PAIR[frozenset((face[i], face[(i + 1) % 4]))] for i in range(4)
    ]
    crossing = [
        e for i, e in enumerate(quad_edges)
        if inside(mask, face[i]) != inside(mask, face[(i + 1) % 4])
    ]
    if len(crossing) == 0:
        return []
    if len(crossing) == 2:
        return [(crossing[0], crossing[1])]
    # Four crossings: two diagonal inside corners. Separate them — each inside
    # corner is cut off by the segment joining its two adjacent face edges.
    segments = []
    for i, corner in enumerate(face):
        if not inside(mask, corner):
            continue
        first = EDGE_OF_PAIR[frozenset((face[(i - 1) % 4], corner))]
        second = EDGE_OF_PAIR[frozenset((corner, face[(i + 1) % 4]))]
        segments.append((first, second))
    assert len(segments) == 2
    return segments


def edge_midpoint(edge: int) -> tuple[float, float, float]:
    a, b = EDGES[edge]
    return tuple((CORNERS[a][i] + CORNERS[b][i]) * 0.5 for i in range(3))


def build_loops(mask: int) -> list[list[int]]:
    adjacency: dict[int, list[int]] = {}
    for face in FACES:
        for a, b in face_segments(mask, face):
            adjacency.setdefault(a, []).append(b)
            adjacency.setdefault(b, []).append(a)
    for edge, neighbours in adjacency.items():
        assert len(neighbours) == 2, (mask, edge, neighbours)
    loops = []
    seen: set[int] = set()
    for start in sorted(adjacency):
        if start in seen:
            continue
        loop = [start]
        seen.add(start)
        previous, current = None, start
        while True:
            step = [n for n in adjacency[current] if n != previous]
            # A two-edge loop would revisit; the assert above already rules
            # out degree != 2, and MC loops have at least three edges.
            following = step[0] if step else adjacency[current][0]
            if following == start:
                break
            loop.append(following)
            seen.add(following)
            previous, current = current, following
        assert len(loop) >= 3, (mask, loop)
        loops.append(loop)
    return loops


def orient_and_fan(mask: int, loop: list[int]) -> list[tuple[int, int, int]]:
    points = [edge_midpoint(e) for e in loop]
    # Newell normal of the polygon.
    normal = [0.0, 0.0, 0.0]
    for i in range(len(points)):
        p, q = points[i], points[(i + 1) % len(points)]
        normal[0] += (p[1] - q[1]) * (p[2] + q[2])
        normal[1] += (p[2] - q[2]) * (p[0] + q[0])
        normal[2] += (p[0] - q[0]) * (p[1] + q[1])
    # From the material this loop wraps, toward the open air: the centroid of
    # the crossing points minus the centroid of the inside endpoints.
    inside_centroid = [0.0, 0.0, 0.0]
    for e in loop:
        a, b = EDGES[e]
        corner = a if inside(mask, a) else b
        for i in range(3):
            inside_centroid[i] += CORNERS[corner][i] / len(loop)
    outward = [
        sum(p[i] for p in points) / len(points) - inside_centroid[i]
        for i in range(3)
    ]
    alignment = sum(normal[i] * outward[i] for i in range(3))
    assert abs(alignment) > 1e-9, (mask, loop)
    # Godot front faces wind clockwise: the fan's cross-product normal must
    # point inward, away from the open air.
    if alignment > 0.0:
        loop = list(reversed(loop))
    return [(loop[0], loop[i], loop[i + 1]) for i in range(1, len(loop) - 1)]


def build_table() -> list[list[tuple[int, int, int]]]:
    table = []
    for mask in range(256):
        triangles = []
        for loop in build_loops(mask):
            triangles.extend(orient_and_fan(mask, loop))
        table.append(triangles)
    return table


def verify(table: list[list[tuple[int, int, int]]]) -> None:
    face_edge_sets = [
        {EDGE_OF_PAIR[frozenset((f[i], f[(i + 1) % 4]))] for i in range(4)}
        for f in FACES
    ]
    for mask, triangles in enumerate(table):
        crossing = {
            e for e, (a, b) in enumerate(EDGES)
            if inside(mask, a) != inside(mask, b)
        }
        used = {index for tri in triangles for index in tri}
        assert used == crossing, (mask, used, crossing)
        directed: dict[tuple[int, int], int] = {}
        for a, b, c in triangles:
            for p, q in ((a, b), (b, c), (c, a)):
                assert p != q, (mask, triangles)
                directed[(p, q)] = directed.get((p, q), 0) + 1
        for (p, q), count in directed.items():
            assert count == 1, (mask, p, q, "edge repeated in one direction")
            if (q, p) in directed:
                continue
            # A boundary edge: both endpoints must live on one cube face.
            assert any(
                p in fs and q in fs for fs in face_edge_sets
            ), (mask, p, q, "internal edge unmatched")

    # Exhaustive gluing: for every face and every pair of masks agreeing on
    # that face's corner pattern, the directed boundary segments must oppose.
    def boundary_on_face(mask: int, face_index: int) -> set[tuple[int, int]]:
        fs = face_edge_sets[face_index]
        directed = set()
        for a, b, c in table[mask]:
            for p, q in ((a, b), (b, c), (c, a)):
                directed.add((p, q))
        return {
            (p, q) for (p, q) in directed
            if (q, p) not in directed and p in fs and q in fs
        }

    # Faces come in opposite pairs seen by the two cubes sharing them; the
    # corner correspondence is by geometry (equal positions once the second
    # cube is shifted one cell along the face axis).
    OPPOSITE = {3: 2, 1: 0, 5: 4}
    for face_a, face_b in OPPOSITE.items():
        # Corner map: corner of cube A on face_a -> corner of cube B on face_b
        # at the same world position, cube B sitting one step along the axis.
        shift = {3: (1, 0, 0), 1: (0, 1, 0), 5: (0, 0, 1)}[face_a]
        corner_map = {}
        for ca in FACES[face_a]:
            pa = CORNERS[ca]
            for cb in FACES[face_b]:
                pb = CORNERS[cb]
                if all(pa[i] == pb[i] + shift[i] for i in range(3)):
                    corner_map[ca] = cb
        assert len(corner_map) == 4
        edge_map = {}
        for e in face_edge_sets[face_a]:
            a, b = EDGES[e]
            edge_map[e] = EDGE_OF_PAIR[frozenset((corner_map[a], corner_map[b]))]
        patterns_a: dict[tuple, list[int]] = {}
        patterns_b: dict[tuple, list[int]] = {}
        for mask in range(256):
            key_a = tuple(inside(mask, c) for c in FACES[face_a])
            key_b = tuple(inside(mask, corner_map[c]) for c in FACES[face_a])
            patterns_a.setdefault(key_a, []).append(mask)
            patterns_b.setdefault(key_b, []).append(mask)
        for key, masks_a in patterns_a.items():
            for mask_a in masks_a:
                segs_a = {
                    (edge_map[p], edge_map[q])
                    for p, q in boundary_on_face(mask_a, face_a)
                }
                for mask_b in patterns_b.get(key, []):
                    segs_b = boundary_on_face(mask_b, face_b)
                    flipped = {(q, p) for p, q in segs_b}
                    assert segs_a == flipped, (
                        face_a, mask_a, mask_b, segs_a, segs_b,
                        "shared face contours disagree",
                    )


def emit(table: list[list[tuple[int, int, int]]]) -> str:
    row_width = max(len(t) * 3 for t in table) + 1
    lines = [
        "// Generated by tools/gen_mc_tables.py — do not edit by hand.",
        "// Regenerate with: python native/regolith_moon_bake/tools/gen_mc_tables.py",
        "//",
        "// Corner c of a cube sits at offset ((c>>0)&1 ^ layout below); see the",
        "// generator for the corner and edge numbering. Triangles are wound for",
        "// Godot's clockwise front faces: cross(b-a, c-a) points into the body.",
        "#pragma once",
        "",
        "namespace granular_mc {",
        "",
        "// Offsets of the eight cube corners, x, y, z per corner.",
        "constexpr int CORNER_OFFSET[8][3] = {",
    ]
    for c in CORNERS:
        lines.append("\t{ %d, %d, %d }," % c)
    lines.append("};")
    lines.append("")
    lines.append("// The two corners of each of the twelve cube edges.")
    lines.append("constexpr int EDGE_CORNERS[12][2] = {")
    for a, b in EDGES:
        lines.append("\t{ %d, %d }," % (a, b))
    lines.append("};")
    lines.append("")
    lines.append("constexpr int TRI_ROW = %d;" % row_width)
    lines.append("")
    lines.append(
        "// TRI_TABLE[mask] lists triangles as triples of edge indices, -1 ends"
    )
    lines.append("// the row. mask bit c is set when corner c is inside (d < 0).")
    lines.append("constexpr signed char TRI_TABLE[256][%d] = {" % row_width)
    for mask, triangles in enumerate(table):
        flat = [str(i) for tri in triangles for i in tri]
        flat.append("-1")
        while len(flat) < row_width:
            flat.append("-1")
        lines.append("\t{ %s }, // %d" % (", ".join(flat), mask))
    lines.append("};")
    lines.append("")
    lines.append("} // namespace granular_mc")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    table = build_table()
    verify(table)
    counts = [len(t) for t in table]
    here = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.join(here, "..", "src", "granular_mc_tables.hpp")
    with open(out_path, "w", newline="\n") as handle:
        handle.write(emit(table))
    print(
        "granular_mc_tables.hpp: 256 cases, max %d triangles, %d non-empty, "
        "all consistency checks passed"
        % (max(counts), sum(1 for c in counts if c))
    )


if __name__ == "__main__":
    main()
