#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cstdint>
#include <vector>

/// One cell's stones, laid: the arithmetic of `GranularGrainShell.lay`, in C++.
///
/// Brought back from Black Math Underworld (`shield_grain_kernel.hpp`), which
/// ported `granular_grain_shell.gd` out of this project in the first place. The
/// arithmetic returns unchanged; what is ours again is the *address*: that
/// project's field is unbounded and seeds its stones off a packed cell key,
/// ours is a dense box and seeds them off the flat `index` — so `index` is
/// passed in rather than derived, and the pictures already on screen do not
/// move by a hair.
///
/// **The thing being ported is a picture, not a rule**, so the bar is different
/// from `GranularVoxelField`'s. That one has to agree with GDScript because a
/// disagreement would be a different world; this one has to agree because a
/// disagreement would be a different *look*, and nobody can review a heap of
/// gravel by eye against a heap of gravel from yesterday. The gate therefore
/// compares transforms, slot for slot — see `scripts/test_granular_grain_kernel.gd`.
///
/// **Why it earned the trip, and why it is not assembly.** Measured over there:
/// a laid cell cost 22 microseconds, and of that the writes into the MultiMesh
/// were 2.4 — the rest was eighty integer hashes and eight quaternion
/// normalisations being interpreted. Fifty cells a pass, sixty passes a second.
/// Compiling that same arithmetic is the whole of the win; hand-written
/// assembly would be arguing with the compiler over the last microsecond of a
/// cell that now costs two, while making a bit-exact port impossible to review.
///
/// **Three places the arithmetic is delicate**, all of them replicated
/// deliberately:
///
///   * **The seeds wrap.** GDScript ints are 64-bit and overflow silently;
///     signed overflow is undefined in C++, so every multiply is done in
///     `uint64_t` and cast back. Our flat indices are far too small to reach
///     that today — the wrap is kept because the seeds are the picture, and a
///     field that grows will not announce the day it starts mattering.
///   * **`Basis`, `Quaternion` and `Vector3::normalized` are the engine's own**,
///     taken from godot-cpp rather than rewritten, because "a rotation about a
///     normalised axis" has more than one correct spelling and only one of them
///     matches what the chips already look like.
///   * **Every intermediate is `double`, and narrows exactly where GDScript
///     narrows** — at the `Vector3` that receives it. A GDScript float is a
///     double whatever the build is, and `Vector3`/`Basis` hold `real_t`; so
///     the script computes wide and narrows on construction, and so does this.
///     Parity therefore holds on a float build and on a double build alike,
///     but only *within* one build: the two do not draw the same scatter, and
///     never did.
///
/// **What stayed in the script, on purpose.** Slot allocation, the `backing`
/// plug and the fines skirt. The first is bookkeeping over a Dictionary that
/// costs nothing to run; the other two are branches the muck never takes
/// (`DRAW_FINES` is off and backing is drawn by a different pass), and porting
/// a branch nobody exercises is how a port grows a second unreviewed picture.
/// `lay` therefore mirrors the script with `backing` false and `DRAW_FINES`
/// false, which is the only way the heap ever calls it.
///
/// It writes through `RenderingServer` by RID rather than through the
/// `MultiMesh` resource: the data lives in the server either way, and this skips
/// a resource call per slot.
class GranularGrainKernel : public godot::RefCounted {
	GDCLASS(GranularGrainKernel, godot::RefCounted)

public:
	/// Every constant the layout is written in, plus the per-variant mesh
	/// scales and offsets. Named after the GDScript constants they come from —
	/// see `GranularGrainShell.configure_kernel`, the only caller.
	void configure(const godot::Dictionary &knobs);

	/// One cell's slots, computed and written. `base` is the cell's first slot
	/// in the variant's pool, `variant` picks the mesh, `index` is the cell's
	/// flat index in the field — the seed every roll here is drawn from, and
	/// the reason it is a parameter: only the caller knows the box it counts
	/// against. `cell` is that same index decoded, handed over rather than
	/// re-derived because the caller has already paid for it.
	void lay(
			const godot::RID &multimesh, int base, int variant, int64_t index,
			const godot::Vector3i &cell, double cell_size, double mass,
			const godot::Vector3 &surface_pos, const godot::Vector3 &surface_nrm);

	/// The same layout, handed back instead of written — the gate's door. One
	/// transform per slot, in slot order.
	godot::Array layout(
			int variant, int64_t index, const godot::Vector3i &cell, double cell_size,
			double mass, const godot::Vector3 &surface_pos,
			const godot::Vector3 &surface_nrm);

protected:
	static void _bind_methods();

private:
	/// `GranularGrainShell._unit` — a deterministic 0..1 from an integer.
	static double unit(int64_t value);

	/// The body both `lay` and `layout` run. `out` collects the slot
	/// transforms; `write` sends them on as they are made.
	void build(
			const godot::RID &multimesh, bool write, godot::Array *out,
			int base, int variant, int64_t index, const godot::Vector3i &cell,
			double cell_size, double mass, const godot::Vector3 &surface_pos,
			const godot::Vector3 &surface_nrm);

	void put(
			const godot::RID &multimesh, bool write, godot::Array *out, int slot,
			const godot::Transform3D &xform);
	void put_custom(
			const godot::RID &multimesh, bool write, int slot, double r, double b);

	int _max_grains = 8;
	int _slots_per_cell = 9;
	double _grain_size_m = 0.13;
	double _grain_size_min_fraction = 0.35;
	double _fines_mass = 0.04;
	double _boulder_chance = 0.05;
	double _boulder_min_mass = 0.5;
	double _boulder_min_m = 0.22;
	double _boulder_max_m = 0.38;
	double _patch_spread_cells = 0.8;
	double _seat_nestle_cells = 0.06;
	double _seat_sink_cells = 0.16;
	double _seat_floor = 0.0;

	std::vector<double> _mesh_scales;
	std::vector<godot::Vector3> _mesh_offsets;
};
