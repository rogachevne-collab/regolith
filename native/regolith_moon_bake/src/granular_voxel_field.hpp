#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
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
	bool is_settled() const { return active_.empty() && next_.empty(); }

	double deposit(int x, int y, int z, double volume_m3);
	double take(int x, int y, int z);
	double take_fraction(int x, int y, int z, double fraction);

	godot::PackedInt32Array take_dirty();
	int step(int max_cells);

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

	/// float32, matching the script's `PackedFloat32Array` scratch. Storing
	/// these as double is a real behaviour change, not a tidy-up.
	float spread_shares_[SPREAD_COUNT] = {};
	int32_t spread_targets_[SPREAD_COUNT] = {};

	godot::Callable solid_query_;

	int last_active_count_ = 0;
	/// Where the next budgeted sweep starts in the sorted active list, so a
	/// backlog cannot starve the same cells sweep after sweep.
	int budget_cursor_ = 0;
};
