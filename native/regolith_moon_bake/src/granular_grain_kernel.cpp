#include "granular_grain_kernel.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/quaternion.hpp>

#include <cmath>

using namespace godot;

namespace {

/// `GranularGrainShell._EMPTY` — a basis of three zero vectors, which draws
/// nothing at all.
/// Braces and not parentheses: with parentheses this line is a function
/// declaration, which is the C++ joke that costs an hour.
const Transform3D EMPTY{ Basis{ Vector3{}, Vector3{}, Vector3{} }, Vector3{} };

/// GDScript's `TAU`, which is a double there whatever the build is.
constexpr double TAU_D = 6.28318530717958647692;

/// Wrapping multiply, because GDScript's ints wrap and C++'s signed overflow is
/// undefined. See the header on why this is here before it is needed.
inline int64_t wmul(int64_t a, int64_t b) {
	return int64_t(uint64_t(a) * uint64_t(b));
}

inline int64_t wadd(int64_t a, int64_t b) {
	return int64_t(uint64_t(a) + uint64_t(b));
}

} // namespace

void GranularGrainKernel::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "knobs"), &GranularGrainKernel::configure);
	ClassDB::bind_method(
			D_METHOD("lay", "multimesh", "base", "variant", "index", "cell", "cell_size",
					"mass", "surface_pos", "surface_nrm"),
			&GranularGrainKernel::lay);
	ClassDB::bind_method(
			D_METHOD("layout", "variant", "index", "cell", "cell_size", "mass",
					"surface_pos", "surface_nrm"),
			&GranularGrainKernel::layout);
}

void GranularGrainKernel::configure(const Dictionary &knobs) {
	_max_grains = int(knobs.get("max_grains_per_cell", 8));
	_slots_per_cell = int(knobs.get("slots_per_cell", _max_grains + 1));
	_grain_size_m = double(knobs.get("grain_size_m", 0.13));
	_grain_size_min_fraction = double(knobs.get("grain_size_min_fraction", 0.35));
	_fines_mass = double(knobs.get("fines_mass", 0.04));
	_boulder_chance = double(knobs.get("boulder_chance", 0.05));
	_boulder_min_mass = double(knobs.get("boulder_min_mass", 0.5));
	_boulder_min_m = double(knobs.get("boulder_min_m", 0.22));
	_boulder_max_m = double(knobs.get("boulder_max_m", 0.38));
	_patch_spread_cells = double(knobs.get("patch_spread_cells", 0.8));
	_seat_nestle_cells = double(knobs.get("seat_nestle_cells", 0.06));
	_seat_sink_cells = double(knobs.get("seat_sink_cells", 0.16));
	_seat_floor = double(knobs.get("seat_floor", 0.0));

	_mesh_scales.clear();
	const PackedFloat32Array scales = knobs.get("mesh_scales", PackedFloat32Array());
	for (int i = 0; i < scales.size(); ++i) {
		// Widened from float32 exactly as GDScript widens its own
		// `PackedFloat32Array` when it indexes one.
		_mesh_scales.push_back(double(scales[i]));
	}
	_mesh_offsets.clear();
	const PackedVector3Array offsets = knobs.get("mesh_offsets", PackedVector3Array());
	for (int i = 0; i < offsets.size(); ++i) {
		_mesh_offsets.push_back(offsets[i]);
	}
}

double GranularGrainKernel::unit(int64_t value) {
	int64_t h = value & 0x7fffffffLL;
	h = (h ^ 61) ^ (h >> 16);
	h = (h + (h << 3)) & 0x7fffffffLL;
	h = h ^ (h >> 4);
	h = wmul(h, 0x27d4eb2dLL) & 0x7fffffffLL;
	h = h ^ (h >> 15);
	return double(h & 0xffffLL) / 65535.0;
}

void GranularGrainKernel::put(
		const RID &multimesh, const bool write, Array *out, const int slot,
		const Transform3D &xform) {
	if (write) {
		RenderingServer::get_singleton()->multimesh_instance_set_transform(
				multimesh, slot, xform);
	}
	if (out != nullptr) {
		out->push_back(xform);
	}
}

void GranularGrainKernel::put_custom(
		const RID &multimesh, const bool write, const int slot, const double r,
		const double b) {
	if (!write) {
		return;
	}
	RenderingServer::get_singleton()->multimesh_instance_set_custom_data(
			multimesh, slot, Color(float(r), 0.0f, float(b), 0.0f));
}

void GranularGrainKernel::build(
		const RID &multimesh, const bool write, Array *out, const int base,
		const int variant, const int64_t index, const Vector3i &cell,
		const double cell_size, const double mass, const Vector3 &surface_pos,
		const Vector3 &surface_nrm) {
	if (variant < 0 || variant >= int(_mesh_scales.size()) ||
			variant >= int(_mesh_offsets.size())) {
		return;
	}
	const double mesh_scale = _mesh_scales[size_t(variant)];
	const Vector3 mesh_offset = _mesh_offsets[size_t(variant)];
	const int x = cell.x;
	const int y = cell.y;
	const int z = cell.z;

	const double held = mass < 1.0 ? mass : 1.0;
	// Through the surface's own floor first, because the mesh underneath is not
	// drawn at the raw fill either — `RENDER_MIN_FILL` subtracts a floor and
	// rescales what is left, and the isosurface is found in *that*.
	const double denom = 1.0 - _seat_floor > 0.001 ? 1.0 - _seat_floor : 0.001;
	const double seated = (held - _seat_floor > 0.0 ? held - _seat_floor : 0.0) / denom;
	const double fill = seated * cell_size;

	const bool on_patch = surface_nrm != Vector3();
	const Vector3 pos_m = surface_pos * real_t(cell_size);
	Vector3 tan_a;
	Vector3 tan_b;
	if (on_patch) {
		// Any two axes spanning the surface: cross the normal with whichever
		// world axis it is least aligned to, so the basis never degenerates.
		const Vector3 ref = std::abs(double(surface_nrm.y)) < 0.9
				? Vector3(0, 1, 0)
				: Vector3(1, 0, 0);
		tan_a = surface_nrm.cross(ref).normalized();
		tan_b = surface_nrm.cross(tan_a);
	}

	if (held < _fines_mass) {
		// The flake skirt is the script's job and is not ported — `lay` only
		// delegates here when `DRAW_FINES` is off, which it is — so this branch
		// always ends the cell rather than falling into the stone path below.
		for (int g = 0; g < _slots_per_cell; ++g) {
			put(multimesh, write, out, base + g, EMPTY);
		}
		return;
	}

	// The occasional boulder, in the slot a plug would use. Chips answer "what
	// is this material"; a boulder answers "how big does it come", and a heap
	// with only one answer in it is what read as cheap.
	if (held >= _boulder_min_mass && unit(wadd(wmul(index, 29), 1)) < _boulder_chance) {
		const double size = _boulder_min_m +
				(_boulder_max_m - _boulder_min_m) * unit(wadd(wmul(index, 29), 7));
		// Lightly dusted — it has been sitting in the spoil, not dropped onto it.
		put_custom(multimesh, write, base, 0.35, unit(wadd(wmul(index, 29), 13)));
		const Basis basis = Basis(Quaternion(
									 Vector3(
											 real_t(unit(wadd(wmul(index, 29), 3)) * 2.0 - 1.0),
											 real_t(unit(wadd(wmul(index, 29), 5)) * 2.0 - 1.0),
											 real_t(unit(wadd(wmul(index, 29), 11)) * 2.0 - 1.0))
											 .normalized(),
									 real_t(unit(wadd(wmul(index, 29), 17)) * TAU_D)))
									.scaled(Vector3(
													real_t(size),
													real_t(size * (0.6 + 0.3 * unit(wadd(wmul(index, 29), 19)))),
													real_t(size * (0.75 + 0.35 * unit(wadd(wmul(index, 29), 23))))) *
											real_t(mesh_scale));
		// Sunk to its waist in the surface, so a bit over a quarter of it stands
		// proud whichever way the surface faces. On the fringe (no patch) it
		// falls back to the fill top.
		Vector3 origin;
		if (surface_nrm != Vector3()) {
			origin = pos_m - surface_nrm * real_t(size * 0.28);
		} else {
			origin = Vector3(
					real_t((double(x) + 0.2 + 0.6 * unit(wadd(wmul(index, 29), 27))) * cell_size),
					real_t(double(y) * cell_size + fill - size * 0.28),
					real_t((double(z) + 0.2 + 0.6 * unit(wadd(wmul(index, 29), 31))) * cell_size));
		}
		put(multimesh, write, out, base, Transform3D(basis, origin + basis.xform(mesh_offset)));
	} else {
		put(multimesh, write, out, base, EMPTY);
	}

	// Character of this patch of ground, sampled coarser than the cell grid:
	// cells rolling their sizes independently is a lattice generator.
	const double patch = unit(
			(int64_t(x >> 2) * 73856093LL) ^ (int64_t(y >> 2) * 19349663LL) ^
			(int64_t(z >> 2) * 83492791LL));
	const double size_mult = 0.7 + 0.6 * patch;
	const double shown_f = std::round(
			double(_max_grains) * held * (0.75 + 0.5 * unit(wmul(index, 9781))) *
			(1.2 - 0.4 * patch));
	int shown = int(shown_f);
	if (shown < 1) {
		shown = 1;
	} else if (shown > _max_grains) {
		shown = _max_grains;
	}

	for (int g = 0; g < _max_grains; ++g) {
		const int slot = base + 1 + g;
		if (g >= shown) {
			put(multimesh, write, out, slot, EMPTY);
			continue;
		}
		const int64_t seed = wadd(wmul(index, int64_t(_max_grains)), int64_t(g));
		const double size_roll = unit(wadd(wmul(seed, 3), 2));
		// Squared, so most chips are small and the big ones are occasional.
		const double size = _grain_size_m * size_mult *
				(_grain_size_min_fraction +
						(1.0 - _grain_size_min_fraction) * size_roll * size_roll);
		const double rise = unit(wadd(wmul(seed, 3), 4));
		// How deep in the material this chip is lying, which is what the shader
		// turns into a dust coating.
		put_custom(multimesh, write, slot, held * rise * rise, unit(wadd(wmul(seed, 11), 9)));

		Vector3 origin;
		if (on_patch) {
			const double a = (unit(wadd(wmul(seed, 3), 0)) - 0.5) * _patch_spread_cells * cell_size;
			const double b = (unit(wadd(wmul(seed, 3), 1)) - 0.5) * _patch_spread_cells * cell_size;
			const double sink = size * (0.15 + 0.35 * rise) + _seat_nestle_cells * cell_size;
			origin = pos_m + tan_a * real_t(a) + tan_b * real_t(b) - surface_nrm * real_t(sink);
		} else {
			// Fringe fallback: no mesh under the cell, so seat on the raw fill
			// top along +Y with the old measured bias.
			const double sink = _seat_sink_cells * seated * cell_size;
			const double half = size * 0.45 < fill * 0.6 ? size * 0.45 : fill * 0.6;
			origin = Vector3(
					real_t((double(x) - 0.15 + 1.3 * unit(wadd(wmul(seed, 3), 0))) * cell_size),
					real_t(double(y) * cell_size + fill * (1.0 - rise * rise) - half - sink),
					real_t((double(z) - 0.15 + 1.3 * unit(wadd(wmul(seed, 3), 1))) * cell_size));
		}
		// Three different edge lengths, then turned to a random attitude: a
		// broken chip, not a pebble.
		const Basis basis = Basis(Quaternion(
									 Vector3(
											 real_t(unit(wadd(wmul(seed, 7), 3)) * 2.0 - 1.0),
											 real_t(unit(wadd(wmul(seed, 7), 5)) * 2.0 - 1.0),
											 real_t(unit(wadd(wmul(seed, 7), 11)) * 2.0 - 1.0))
											 .normalized(),
									 real_t(unit(wadd(wmul(seed, 7), 13)) * TAU_D)))
									.scaled(Vector3(
													real_t(size),
													real_t(size * (0.35 + 0.4 * unit(wadd(wmul(seed, 13), 1)))),
													real_t(size * (0.6 + 0.5 * unit(wadd(wmul(seed, 13), 7))))) *
											real_t(mesh_scale));
		// The mesh's own body is offset from its origin, and that offset turns
		// with the chip.
		put(multimesh, write, out, slot, Transform3D(basis, origin + basis.xform(mesh_offset)));
	}
}

void GranularGrainKernel::lay(
		const RID &multimesh, const int base, const int variant, const int64_t index,
		const Vector3i &cell, const double cell_size, const double mass,
		const Vector3 &surface_pos, const Vector3 &surface_nrm) {
	build(multimesh, true, nullptr, base, variant, index, cell, cell_size, mass,
			surface_pos, surface_nrm);
}

Array GranularGrainKernel::layout(
		const int variant, const int64_t index, const Vector3i &cell,
		const double cell_size, const double mass, const Vector3 &surface_pos,
		const Vector3 &surface_nrm) {
	Array out;
	build(RID(), false, &out, 0, variant, index, cell, cell_size, mass, surface_pos,
			surface_nrm);
	return out;
}
