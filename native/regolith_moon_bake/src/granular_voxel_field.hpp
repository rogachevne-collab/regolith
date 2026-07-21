#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cstdint>
#include <vector>

/// Native twin of `scripts/simulation/runtime/granular_voxel_field.gd`.
///
/// Not a reimplementation: a transliteration. The GDScript version is the
/// specification, and every rule, threshold and traversal order here exists
/// because it exists there. The point is a field that settles *identically*
/// and costs a fraction — measured, the script pays about nineteen
/// microseconds per cell visited, nearly all of it interpreter overhead
/// rather than arithmetic.
///
/// Two details decide whether "identically" is literally true, and both are
/// easy to get wrong:
///
///   1. Mass is stored as float32 (the script holds it in a
///      `PackedFloat32Array`) while every intermediate is computed in double
///      (a GDScript `float` is a double). So a transfer reads float32, widens,
///      computes in double, and narrows back on store. Doing the arithmetic in
///      float instead drifts in the last bits, and a cellular automaton
///      amplifies last bits into different piles.
///   2. The spread shares are *stored* in a float32 scratch array but their
///      running total accumulates the unrounded doubles. That asymmetry is
///      visible in the result and is reproduced here rather than tidied away.
class GranularVoxelField : public godot::RefCounted {
	GDCLASS(GranularVoxelField, godot::RefCounted)

public:
	static constexpr double DEFAULT_CELL_SIZE_M = 0.25;
	/// A cell holding less than this is treated as empty; chasing the last
	/// fractions of a percent keeps cells active forever.
	static constexpr double MIN_MASS = 0.004;
	/// Smallest transfer worth making when spreading. Falling has no such
	/// floor — anything unsupported must come down whatever its size.
	static constexpr double MIN_SPREAD_TRANSFER = 0.02;
	static constexpr double FULL = 1.0;
	static constexpr int SPREAD_COUNT = 8;

	/// Same shape as the script's factory, so every existing
	/// `GranularVoxelField.create(...)` call site and every `: GranularVoxelField`
	/// annotation keeps working untouched. Taking over the name was the whole
	/// point: leaving it to the script and declaring the field untyped meant
	/// every expression derived from it lost its type too, and this project
	/// treats that as an error — seventeen of them appeared from one `var`.
	static godot::Ref<GranularVoxelField> create(const godot::Vector3i &size, double cell_size);

	void configure(const godot::Vector3i &new_size, double new_cell_size);

	bool in_bounds(int x, int y, int z) const;
	int index(int x, int y, int z) const;
	double cell_volume_m3() const;

	void set_solid(int x, int y, int z, bool solid);
	bool is_solid(int x, int y, int z);
	void invalidate_solid(const godot::Vector3i &from_cell, const godot::Vector3i &to_cell);

	double mass_at(int x, int y, int z) const;
	godot::PackedFloat32Array copy_mass_box(const godot::Vector3i &lo, const godot::Vector3i &extent);
	godot::PackedByteArray copy_solid_box(const godot::Vector3i &lo, const godot::Vector3i &extent);

	double total_volume_m3() const;
	int active_count() const { return last_active_count_; }
	/// Cells that *wanted* to move last sweep, before the budget took its
	/// window. `active_count` can only ever report the budget, so it cannot
	/// answer the question that matters: whether the budget covers the heap.
	/// Above the budget, every cell moves at a fraction of the sweep rate —
	/// 1600 awake against a budget of 160 is twelve hertz per cell, which is
	/// what "the settling looks stepped" turned out to mean.
	int pending_count() const { return last_pending_count_; }
	bool is_settled() const { return active_.empty() && next_.empty(); }

	double deposit(int x, int y, int z, double volume_m3);
	double take(int x, int y, int z);
	double take_fraction(int x, int y, int z, double fraction);

	godot::PackedInt32Array take_dirty();
	int step(int max_cells);

	/// The whole surface-reconstruction pass for one box, returned as the
	/// bytes of a 16-bit SDF channel ready to hand straight to a
	/// `VoxelBuffer`.
	///
	/// This is the other half of the port, and the half that actually costs
	/// the frame. Measured on a cubic-metre-and-a-half collapse: the native
	/// field's sweeps came to 0.106 ms a frame and the script's flush to
	/// 3.450, worst frame 15.69 — ninety-seven per cent of the granular frame
	/// in the reconstruction and the encode, both of them per-voxel GDScript
	/// loops, neither of them fixable in GDScript because the interpreter *is*
	/// the cost.
	///
	/// Everything the script did is done here in the same order: occupancy
	/// with rock counted full, a separable three-tap blur run `smooth_passes`
	/// times over three axes, then the signed distance encoded into the
	/// buffer's own y-fastest layout. Output is byte-for-byte what the script
	/// produced; `GranularVoxelRegionView.VERIFY_NATIVE_SDF` checks that
	/// against the live path rather than taking it on trust.
	/// Establish rock for a box of cells from one bulk read of the world,
	/// instead of one callback per cell.
	///
	/// The lazy `solid_query` is right for a cell here and a cell there, and
	/// badly wrong for a fresh excavation, which asks about thousands at once:
	/// each answer is a GDScript lambda doing eight `get_voxel_f` calls to
	/// sample the terrain trilinearly. Measured, that is 3.2 microseconds a
	/// cell — three milliseconds for a three cubic metre bite and proportional
	/// after that, paid entirely in the frame the spoil appears in. A single
	/// `VoxelTool.copy` of the same neighbourhood moves 32768 voxels in 0.037
	/// ms, against 11.5 ms for reading them one at a time.
	///
	/// So the caller copies the neighbourhood once and hands the raw channel
	/// here, and the sampling happens with no binding crossings at all. Cells
	/// already established — anything `set_solid` was explicit about — are left
	/// alone, exactly as the lazy path leaves them.
	void prime_solid_box(
			const godot::Vector3i &lo,
			const godot::Vector3i &extent,
			const godot::PackedByteArray &sdf_bytes,
			const godot::Vector3i &buffer_size,
			const godot::Vector3i &buffer_origin,
			const godot::Transform3D &cell_to_local,
			double s16_scale);

	godot::PackedByteArray build_sdf_box(
			const godot::Vector3i &lo,
			const godot::Vector3i &extent,
			int smooth_passes,
			double smooth_centre,
			double render_min_fill,
			double surface_iso,
			double sdf_gain,
			double air_sdf,
			double s16_scale);

	godot::Vector3i get_size() const { return size_; }
	double get_cell_size() const { return cell_size_; }
	/// Exposed as properties because the region reads `field.size` and
	/// `field.cell_size` constantly and must not care which implementation it
	/// was handed. Setting either re-sizes the field, which is the only
	/// meaning it could have — the script's `create()` says the same thing
	/// with different words.
	void set_size(const godot::Vector3i &v) { configure(v, cell_size_); }
	void set_cell_size(double v) { configure(size_, v); }

	void set_solid_query(const godot::Callable &query) { solid_query_ = query; }
	godot::Callable get_solid_query() const { return solid_query_; }

	void set_fall_rate(double v) { fall_rate_ = v; }
	double get_fall_rate() const { return fall_rate_; }
	void set_spread_rate(double v) { spread_rate_ = v; }
	double get_spread_rate() const { return spread_rate_; }
	void set_spread_min_difference(double v) { spread_min_difference_ = v; }
	double get_spread_min_difference() const { return spread_min_difference_; }
	void set_lateral_rate(double v) { lateral_rate_ = v; }
	double get_lateral_rate() const { return lateral_rate_; }
	void set_lateral_min_difference(double v) { lateral_min_difference_ = v; }
	double get_lateral_min_difference() const { return lateral_min_difference_; }

protected:
	static void _bind_methods();

private:
	bool solid_at(int i);
	void mark_dirty(int i);
	void touch(int i);
	void wake(int x, int y, int z);
	void step_cell(int i);
	void spread(int i, int x, int y, int z, double mass, int to_y, double rate, double min_difference);

	godot::Vector3i size_ = godot::Vector3i(0, 0, 0);
	double cell_size_ = DEFAULT_CELL_SIZE_M;

	double fall_rate_ = 0.7;
	double spread_rate_ = 0.5;
	double spread_min_difference_ = 0.08;
	double lateral_rate_ = 0.12;
	double lateral_min_difference_ = 0.51;

	/// Storage widths match the script's packed arrays exactly. See the note
	/// on the class: these are load-bearing, not an encoding detail.
	std::vector<float> mass_;
	std::vector<uint8_t> solid_;
	std::vector<uint8_t> solid_known_;
	std::vector<uint8_t> queued_;
	std::vector<uint8_t> dirty_flag_;

	std::vector<int32_t> active_;
	std::vector<int32_t> next_;
	std::vector<int32_t> dirty_;
	/// Reused across sweeps so a sort does not allocate every time.
	std::vector<int32_t> order_;

	/// Scratch for `build_sdf_box`, grown to the largest box seen and kept.
	/// float32 rather than double, matching the script's packed arrays: the
	/// blur rounds through these, so their width is part of the result.
	std::vector<float> sdf_mass_;
	std::vector<uint8_t> sdf_solid_;
	std::vector<float> sdf_occupancy_;
	std::vector<float> sdf_scratch_;

	void blur_axis(
			const std::vector<float> &source,
			std::vector<float> &target,
			int total,
			int stride,
			int axis_size,
			double smooth_centre) const;

	/// float32, matching the script's `PackedFloat32Array` scratch. Storing
	/// these as double is a real behaviour change, not a tidy-up.
	float spread_shares_[SPREAD_COUNT] = {};
	int32_t spread_targets_[SPREAD_COUNT] = {};

	godot::Callable solid_query_;

	int last_active_count_ = 0;
	int last_pending_count_ = 0;
	/// Where the next budgeted sweep starts in the sorted active list, so a
	/// backlog cannot starve the same cells sweep after sweep.
	int budget_cursor_ = 0;
};
