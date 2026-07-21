#include "granular_voxel_field.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>

using namespace godot;

/// Sideways-and-down neighbours: the four faces and the four diagonals, each
/// one step down. Diagonals travel further for the same step down, so they get
/// a smaller share; without that the pile comes out square instead of round.
static const int SPREAD_DX[GranularVoxelField::SPREAD_COUNT] = { 1, -1, 0, 0, 1, 1, -1, -1 };
static const int SPREAD_DZ[GranularVoxelField::SPREAD_COUNT] = { 0, 0, 1, -1, 1, -1, 1, -1 };
static const double SPREAD_WEIGHT[GranularVoxelField::SPREAD_COUNT] = {
	1.0, 1.0, 1.0, 1.0, 0.7071, 0.7071, 0.7071, 0.7071
};

Ref<GranularVoxelField> GranularVoxelField::create(const Vector3i &size, double cell_size) {
	Ref<GranularVoxelField> field;
	field.instantiate();
	field->configure(size, cell_size);
	return field;
}

void GranularVoxelField::configure(const Vector3i &new_size, double new_cell_size) {
	size_ = Vector3i(
			std::max(new_size.x, 1),
			std::max(new_size.y, 1),
			std::max(new_size.z, 1));
	cell_size_ = std::max(new_cell_size, 0.01);
	const size_t count = (size_t)size_.x * (size_t)size_.y * (size_t)size_.z;
	mass_.assign(count, 0.0f);
	solid_.assign(count, 0);
	solid_known_.assign(count, 0);
	queued_.assign(count, 0);
	dirty_flag_.assign(count, 0);
	active_.clear();
	next_.clear();
	dirty_.clear();
	order_.clear();
	last_active_count_ = 0;
	budget_cursor_ = 0;
}

bool GranularVoxelField::in_bounds(int x, int y, int z) const {
	return x >= 0 && x < size_.x && y >= 0 && y < size_.y && z >= 0 && z < size_.z;
}

int GranularVoxelField::index(int x, int y, int z) const {
	return (y * size_.z + z) * size_.x + x;
}

double GranularVoxelField::cell_volume_m3() const {
	return cell_size_ * cell_size_ * cell_size_;
}

void GranularVoxelField::set_solid(int x, int y, int z, bool solid) {
	if (!in_bounds(x, y, z)) {
		return;
	}
	const int i = index(x, y, z);
	solid_[i] = solid ? 1 : 0;
	// Stated explicitly, so it is not overwritten by a later lazy query.
	solid_known_[i] = 1;
}

bool GranularVoxelField::is_solid(int x, int y, int z) {
	return in_bounds(x, y, z) && solid_at(index(x, y, z));
}

/// Rock at a cell, asking `solid_query` the first time and remembering the
/// answer. Everything in the stepping rules goes through here, which is what
/// keeps the callback out of the hot path: a cell is asked once, ever.
bool GranularVoxelField::solid_at(int i) {
	if (solid_known_[i] == 0) {
		solid_known_[i] = 1;
		solid_[i] = 0;
		if (solid_query_.is_valid()) {
			const int y = i / (size_.x * size_.z);
			const int z = (i / size_.x) % size_.z;
			const int x = i % size_.x;
			if ((bool)solid_query_.call(Vector3i(x, y, z))) {
				solid_[i] = 1;
			}
		}
	}
	return solid_[i] != 0;
}

void GranularVoxelField::invalidate_solid(const Vector3i &from_cell, const Vector3i &to_cell) {
	const Vector3i lo(
			std::max(std::min(from_cell.x, to_cell.x), 0),
			std::max(std::min(from_cell.y, to_cell.y), 0),
			std::max(std::min(from_cell.z, to_cell.z), 0));
	const Vector3i hi(
			std::min(std::max(from_cell.x, to_cell.x), size_.x - 1),
			std::min(std::max(from_cell.y, to_cell.y), size_.y - 1),
			std::min(std::max(from_cell.z, to_cell.z), size_.z - 1));
	for (int y = lo.y; y <= hi.y; ++y) {
		for (int z = lo.z; z <= hi.z; ++z) {
			for (int x = lo.x; x <= hi.x; ++x) {
				const int i = index(x, y, z);
				// Forgetting is free; waking is not. Only cells that actually
				// hold material can have lost their support.
				solid_known_[i] = 0;
				if (mass_[i] > 0.0f) {
					wake(x, y, z);
				}
			}
		}
	}
}

double GranularVoxelField::mass_at(int x, int y, int z) const {
	return in_bounds(x, y, z) ? (double)mass_[index(x, y, z)] : 0.0;
}

/// Returned rather than filled through an out-parameter, unlike the script:
/// a packed array handed to a bound method arrives as a copy, so writing into
/// it would never reach the caller.
PackedFloat32Array GranularVoxelField::copy_mass_box(const Vector3i &lo, const Vector3i &extent) {
	PackedFloat32Array out;
	const int total = extent.x * extent.y * extent.z;
	out.resize(total);
	float *w = out.ptrw();
	int i = 0;
	for (int y = 0; y < extent.y; ++y) {
		const int cy = lo.y + y;
		for (int z = 0; z < extent.z; ++z) {
			const int cz = lo.z + z;
			if (cy < 0 || cy >= size_.y || cz < 0 || cz >= size_.z) {
				for (int x = 0; x < extent.x; ++x) {
					w[i++] = 0.0f;
				}
				continue;
			}
			const int row = (cy * size_.z + cz) * size_.x;
			for (int x = 0; x < extent.x; ++x) {
				const int cx = lo.x + x;
				w[i++] = (cx >= 0 && cx < size_.x) ? mass_[row + cx] : 0.0f;
			}
		}
	}
	return out;
}

PackedByteArray GranularVoxelField::copy_solid_box(const Vector3i &lo, const Vector3i &extent) {
	PackedByteArray out;
	const int total = extent.x * extent.y * extent.z;
	out.resize(total);
	uint8_t *w = out.ptrw();
	int i = 0;
	for (int y = 0; y < extent.y; ++y) {
		const int cy = lo.y + y;
		for (int z = 0; z < extent.z; ++z) {
			const int cz = lo.z + z;
			if (cy < 0 || cy >= size_.y || cz < 0 || cz >= size_.z) {
				for (int x = 0; x < extent.x; ++x) {
					w[i++] = 0;
				}
				continue;
			}
			const int row = (cy * size_.z + cz) * size_.x;
			for (int x = 0; x < extent.x; ++x) {
				const int cx = lo.x + x;
				if (cx < 0 || cx >= size_.x) {
					w[i++] = 0;
				} else {
					const int j = row + cx;
					w[i++] = solid_known_[j] != 0 ? solid_[j] : (solid_at(j) ? 1 : 0);
				}
			}
		}
	}
	return out;
}

double GranularVoxelField::total_volume_m3() const {
	// Accumulated in double over float32 cells, exactly as the script does.
	double sum = 0.0;
	for (size_t i = 0; i < mass_.size(); ++i) {
		sum += (double)mass_[i];
	}
	return sum * cell_volume_m3();
}

double GranularVoxelField::deposit(int x, int y, int z, double volume_m3) {
	if (volume_m3 <= 0.0 || !in_bounds(x, y, z)) {
		return 0.0;
	}
	const int i = index(x, y, z);
	if (solid_at(i)) {
		return 0.0;
	}
	const double room = FULL - (double)mass_[i];
	if (room <= 0.0) {
		return 0.0;
	}
	const double added = std::min(volume_m3 / cell_volume_m3(), room);
	mass_[i] = (float)((double)mass_[i] + added);
	mark_dirty(i);
	wake(x, y, z);
	return added * cell_volume_m3();
}

double GranularVoxelField::take(int x, int y, int z) {
	if (!in_bounds(x, y, z)) {
		return 0.0;
	}
	const int i = index(x, y, z);
	const double mass = mass_[i];
	if (mass <= 0.0) {
		return 0.0;
	}
	mass_[i] = 0.0f;
	mark_dirty(i);
	wake(x, y, z);
	return mass * cell_volume_m3();
}

double GranularVoxelField::take_fraction(int x, int y, int z, double fraction) {
	if (fraction <= 0.0 || !in_bounds(x, y, z)) {
		return 0.0;
	}
	const int i = index(x, y, z);
	const double mass = mass_[i];
	if (mass <= 0.0) {
		return 0.0;
	}
	double removed = std::min(mass, mass * fraction);
	// Leaving a sliver behind keeps a cell active for hundreds of sweeps for
	// nothing, the same reason `MIN_MASS` exists at all.
	if (mass - removed < MIN_MASS) {
		removed = mass;
	}
	mass_[i] = (float)(mass - removed);
	// `touch`, not `mark_dirty` — which is what the script does, and is very
	// probably a bug there: every other mutator tells the renderer the cell
	// changed and this one only re-queues it for simulation. Transliterated
	// as-is on purpose. Fixing it belongs in the script first, where the
	// behaviour can be compared against, not smuggled in by a port.
	touch(i);
	wake(x, y, z);
	return removed * cell_volume_m3();
}

void GranularVoxelField::mark_dirty(int i) {
	if (dirty_flag_[i] != 0) {
		return;
	}
	dirty_flag_[i] = 1;
	dirty_.push_back(i);
}

PackedInt32Array GranularVoxelField::take_dirty() {
	PackedInt32Array batch;
	batch.resize((int)dirty_.size());
	int32_t *w = batch.ptrw();
	for (size_t k = 0; k < dirty_.size(); ++k) {
		w[k] = dirty_[k];
		dirty_flag_[dirty_[k]] = 0;
	}
	dirty_.clear();
	return batch;
}

/// Queue a single cell for the next sweep. The `queued_` flag makes this
/// idempotent, so callers can touch the same cell freely.
void GranularVoxelField::touch(int i) {
	if (queued_[i] != 0) {
		return;
	}
	queued_[i] = 1;
	next_.push_back(i);
}

/// Wake a cell and its six face neighbours. Face-only on purpose: a diagonal
/// neighbour is always reached through a face neighbour on the following
/// sweep anyway, and waking all 26 was four times the work for nothing.
void GranularVoxelField::wake(int x, int y, int z) {
	if (!in_bounds(x, y, z)) {
		return;
	}
	touch(index(x, y, z));
	if (x > 0) {
		touch(index(x - 1, y, z));
	}
	if (x < size_.x - 1) {
		touch(index(x + 1, y, z));
	}
	if (y > 0) {
		touch(index(x, y - 1, z));
	}
	if (y < size_.y - 1) {
		touch(index(x, y + 1, z));
	}
	if (z > 0) {
		touch(index(x, y, z - 1));
	}
	if (z < size_.z - 1) {
		touch(index(x, y, z + 1));
	}
}

int GranularVoxelField::step(int max_cells) {
	if (next_.empty() && active_.empty()) {
		last_active_count_ = 0;
		return 0;
	}
	if (!next_.empty()) {
		active_.swap(next_);
		next_.clear();
	}
	order_.swap(active_);
	active_.clear();
	// Sorted so the result never depends on the order cells happened to be
	// woken in — two peers must reach the same pile from the same dig. The
	// index is y-major, so this also walks the backlog bottom-up: material
	// below moves out of the way before the cell above is asked to come down.
	std::sort(order_.begin(), order_.end());
	const int count = (int)order_.size();
	last_pending_count_ = count;
	const int budget = max_cells <= 0 ? count : std::min(max_cells, count);
	for (int k = 0; k < count; ++k) {
		queued_[order_[k]] = 0;
	}
	// The budget is a window that rotates between sweeps, not the first N of a
	// sorted list. The index is y-major, so a sorted prefix is always the
	// lowest cells: with a backlog bigger than the budget the top of a falling
	// column would never be reached and would simply hang in the air.
	const int start = count == 0 ? 0 : budget_cursor_ % count;
	for (int k = 0; k < budget; ++k) {
		step_cell(order_[(start + k) % count]);
	}
	for (int k = budget; k < count; ++k) {
		// Carried, not dropped.
		touch(order_[(start + k) % count]);
	}
	budget_cursor_ = count == 0 ? 0 : (start + budget) % count;
	last_active_count_ = budget;
	return budget;
}

void GranularVoxelField::step_cell(int i) {
	double mass = mass_[i];
	// Only genuinely empty cells are skipped. Skipping everything under
	// `MIN_MASS` strands the residues that spreading leaves behind: specks too
	// small to be worth a transfer, with nothing underneath them, left hanging.
	if (mass <= 0.0) {
		return;
	}
	const int x = i % size_.x;
	const int z = (i / size_.x) % size_.z;
	const int y = i / (size_.x * size_.z);
	// Straight down first: nothing spreads sideways while it can still fall.
	if (y > 0) {
		const int below = index(x, y - 1, z);
		if (!solid_at(below)) {
			const double room = FULL - (double)mass_[below];
			if (room > 0.0) {
				const double movable = std::min(mass, room);
				double moved = movable * fall_rate_;
				// A residue too small to be worth a fraction still has nothing
				// holding it up, so it goes down whole rather than not at all.
				if (moved < MIN_MASS) {
					moved = movable;
				}
				if (moved > 0.0) {
					mass_[i] = (float)((double)mass_[i] - moved);
					mass_[below] = (float)((double)mass_[below] + moved);
					mark_dirty(i);
					mark_dirty(below);
					wake(x, y, z);
					wake(x, y - 1, z);
					mass = mass_[i];
					if (mass < MIN_MASS) {
						return;
					}
				}
			}
		}
	}
	if (y <= 0) {
		return;
	}
	// Resting on something. Sideways-and-down alone is 45 degrees and nothing
	// else; travel along a level is what buys the extra horizontal distance a
	// shallower angle needs. Each is gated by its own threshold, and that pair
	// of thresholds is the material.
	spread(i, x, y, z, mass, y - 1, spread_rate_, spread_min_difference_);
	mass = mass_[i];
	if (mass > 0.0) {
		spread(i, x, y, z, mass, y, lateral_rate_, lateral_min_difference_);
	}
}

void GranularVoxelField::spread(
		int i, int x, int y, int z, double mass, int to_y, double rate, double min_difference) {
	if (rate <= 0.0) {
		return;
	}
	int count = 0;
	double share_total = 0.0;
	for (int k = 0; k < SPREAD_COUNT; ++k) {
		const int nx = x + SPREAD_DX[k];
		const int nz = z + SPREAD_DZ[k];
		if (!in_bounds(nx, to_y, nz)) {
			continue;
		}
		const int ni = index(nx, to_y, nz);
		if (solid_at(ni)) {
			continue;
		}
		const double difference = mass - (double)mass_[ni];
		if (difference <= min_difference) {
			continue;
		}
		const double share = difference * SPREAD_WEIGHT[k];
		spread_targets_[count] = ni;
		// Narrowed on store and widened on use, because the script's scratch
		// is a float32 array while its running total is not. See the class
		// note: this asymmetry is visible in the settled pile.
		spread_shares_[count] = (float)share;
		count += 1;
		share_total += share;
	}
	if (count == 0 || share_total <= 0.0) {
		return;
	}
	// Never hand out more than the cell holds, and split the excess over the
	// targets *and* this cell, so a transfer cannot overshoot into a hole the
	// next sweep has to undo.
	const double budget = std::min(mass, rate * share_total / (double)(count + 1));
	if (budget < MIN_SPREAD_TRANSFER) {
		return;
	}
	for (int k = 0; k < count; ++k) {
		const int ni = spread_targets_[k];
		double amount = budget * ((double)spread_shares_[k] / share_total);
		const double room = FULL - (double)mass_[ni];
		if (room <= 0.0) {
			continue;
		}
		amount = std::min(amount, room);
		if (amount <= 0.0) {
			continue;
		}
		mass_[i] = (float)((double)mass_[i] - amount);
		mass_[ni] = (float)((double)mass_[ni] + amount);
		mark_dirty(i);
		mark_dirty(ni);
		wake(ni % size_.x, ni / (size_.x * size_.z), (ni / size_.x) % size_.z);
	}
	wake(x, y, z);
}

void GranularVoxelField::prime_solid_box(
		const Vector3i &lo,
		const Vector3i &extent,
		const PackedByteArray &sdf_bytes,
		const Vector3i &buffer_size,
		const Vector3i &buffer_origin,
		const Transform3D &cell_to_local,
		double s16_scale) {
	const int voxels = buffer_size.x * buffer_size.y * buffer_size.z;
	if (sdf_bytes.size() < voxels * 2 || voxels <= 0) {
		return;
	}
	const uint8_t *raw = sdf_bytes.ptr();
	const double inv_scale = 1.0 / s16_scale;
	// The buffer's own layout, measured against the plugin: y runs fastest,
	// then x, then z.
	auto sample = [&](int x, int y, int z) -> double {
		x = std::min(std::max(x, 0), buffer_size.x - 1);
		y = std::min(std::max(y, 0), buffer_size.y - 1);
		z = std::min(std::max(z, 0), buffer_size.z - 1);
		const int vi = (y + buffer_size.y * (x + buffer_size.x * z)) * 2;
		const int16_t v = (int16_t)((uint16_t)raw[vi] | ((uint16_t)raw[vi + 1] << 8));
		return (double)v * inv_scale;
	};
	const Vector3i hi = lo + extent;
	for (int y = std::max(lo.y, 0); y < std::min(hi.y, size_.y); ++y) {
		for (int z = std::max(lo.z, 0); z < std::min(hi.z, size_.z); ++z) {
			for (int x = std::max(lo.x, 0); x < std::min(hi.x, size_.x); ++x) {
				const int i = index(x, y, z);
				// Explicit answers win, exactly as they do on the lazy path.
				if (solid_known_[i] != 0) {
					continue;
				}
				// The cell's centre, not the corner it is indexed from: a
				// corner test calls a cell rock only once its lowest face is
				// buried, so material comes to rest a whole cell above the
				// ground it can see, always in the same direction.
				const Vector3 p = cell_to_local.xform(
						Vector3((double)x + 0.5, (double)y + 0.5, (double)z + 0.5));
				const Vector3 rel = p - Vector3(buffer_origin);
				const int bx = (int)Math::floor(rel.x);
				const int by = (int)Math::floor(rel.y);
				const int bz = (int)Math::floor(rel.z);
				const double tx = rel.x - (double)bx;
				const double ty = rel.y - (double)by;
				const double tz = rel.z - (double)bz;
				const double c000 = sample(bx, by, bz);
				const double c100 = sample(bx + 1, by, bz);
				const double c010 = sample(bx, by + 1, bz);
				const double c110 = sample(bx + 1, by + 1, bz);
				const double c001 = sample(bx, by, bz + 1);
				const double c101 = sample(bx + 1, by, bz + 1);
				const double c011 = sample(bx, by + 1, bz + 1);
				const double c111 = sample(bx + 1, by + 1, bz + 1);
				const double sdf = Math::lerp(
						Math::lerp(Math::lerp(c000, c100, tx), Math::lerp(c010, c110, tx), ty),
						Math::lerp(Math::lerp(c001, c101, tx), Math::lerp(c011, c111, tx), ty),
						tz);
				// Solid is `occupancy >= 0.5`, and occupancy is `0.5 - sdf`,
				// so this is exactly the mesher's own inside test.
				solid_known_[i] = 1;
				solid_[i] = sdf <= 0.0 ? 1 : 0;
			}
		}
	}
}

/// One pass of the separable kernel along whichever axis `stride` steps. Ends
/// are clamped rather than wrapped, which is why the work box carries a ring
/// the written box does not use.
void GranularVoxelField::blur_axis(
		const std::vector<float> &source,
		std::vector<float> &target,
		int total,
		int stride,
		int axis_size,
		double smooth_centre) const {
	const double scale = 1.0 / (smooth_centre + 2.0);
	const int span = stride * axis_size;
	const int tail = (axis_size - 1) * stride;
	for (int base = 0; base < total; base += span) {
		for (int offset = 0; offset < stride; ++offset) {
			const int start = base + offset;
			const int last = start + tail;
			for (int i = start; i <= last; i += stride) {
				double sum = (double)source[i] * smooth_centre;
				sum += (double)(i > start ? source[i - stride] : source[i]);
				sum += (double)(i < last ? source[i + stride] : source[i]);
				target[i] = (float)(sum * scale);
			}
		}
	}
}

PackedByteArray GranularVoxelField::build_sdf_box(
		const Vector3i &lo,
		const Vector3i &extent,
		int smooth_passes,
		double smooth_centre,
		double render_min_fill,
		double surface_iso,
		double sdf_gain,
		double air_sdf,
		double s16_scale) {
	const int radius = smooth_passes;
	const Vector3i work_lo = lo - Vector3i(radius, radius, radius);
	const Vector3i work_extent = extent + Vector3i(radius, radius, radius) * 2;
	const int work_total = work_extent.x * work_extent.y * work_extent.z;
	if ((int)sdf_occupancy_.size() < work_total) {
		sdf_occupancy_.resize(work_total);
		sdf_scratch_.resize(work_total);
		sdf_mass_.resize(work_total);
		sdf_solid_.resize(work_total);
	}
	// The same bulk reads the script made, without crossing the binding.
	{
		int i = 0;
		for (int y = 0; y < work_extent.y; ++y) {
			const int cy = work_lo.y + y;
			for (int z = 0; z < work_extent.z; ++z) {
				const int cz = work_lo.z + z;
				const bool row_outside = cy < 0 || cy >= size_.y || cz < 0 || cz >= size_.z;
				const int row = row_outside ? 0 : (cy * size_.z + cz) * size_.x;
				for (int x = 0; x < work_extent.x; ++x) {
					const int cx = work_lo.x + x;
					if (row_outside || cx < 0 || cx >= size_.x) {
						sdf_mass_[i] = 0.0f;
						sdf_solid_[i] = 0;
					} else {
						const int j = row + cx;
						sdf_mass_[i] = mass_[j];
						sdf_solid_[i] = solid_known_[j] != 0 ? solid_[j] : (solid_at(j) ? 1 : 0);
					}
					++i;
				}
			}
		}
	}
	// Rock counts as full. Without it the low-pass thins the heap exactly
	// where it meets the ground, and material ends in a feathered lip hanging
	// over the rock instead of sitting in it.
	const double floor_scale = 1.0 / (1.0 - render_min_fill);
	for (int i = 0; i < work_total; ++i) {
		if (sdf_solid_[i] != 0) {
			sdf_occupancy_[i] = 1.0f;
		} else {
			sdf_occupancy_[i] = (float)(
					std::max((double)sdf_mass_[i] - render_min_fill, 0.0) * floor_scale);
		}
	}
	// Separable: passes of three taps each, never one pass of twenty-seven.
	const int strides[3] = { 1, work_extent.x, work_extent.x * work_extent.z };
	const int axis_sizes[3] = { work_extent.x, work_extent.z, work_extent.y };
	bool in_scratch = false;
	for (int round = 0; round < smooth_passes; ++round) {
		for (int axis = 0; axis < 3; ++axis) {
			if (in_scratch) {
				blur_axis(sdf_scratch_, sdf_occupancy_, work_total, strides[axis],
						axis_sizes[axis], smooth_centre);
			} else {
				blur_axis(sdf_occupancy_, sdf_scratch_, work_total, strides[axis],
						axis_sizes[axis], smooth_centre);
			}
			in_scratch = !in_scratch;
		}
	}
	const std::vector<float> &smoothed = in_scratch ? sdf_scratch_ : sdf_occupancy_;

	PackedByteArray out;
	const int total = extent.x * extent.y * extent.z;
	out.resize(total * 2);
	uint8_t *w = out.ptrw();
	const int stride_z = work_extent.x;
	const int stride_y = work_extent.x * work_extent.z;
	const int air = (int)(air_sdf * s16_scale);
	for (int y = 0; y < extent.y; ++y) {
		for (int z = 0; z < extent.z; ++z) {
			// The written box sits inside the work box by the kernel's radius,
			// so walking one row of it is walking one row of the scratch.
			int wi = (y + radius) * stride_y + (z + radius) * stride_z + radius;
			// The buffer's own layout, which is not the field's: y runs
			// fastest, then x, then z.
			int vi = (y + extent.y * extent.x * z) * 2;
			for (int x = 0; x < extent.x; ++x) {
				int encoded = air;
				// Rock belongs to the world's own terrain, which already draws
				// it. The exception is rock directly under material, which is
				// claimed so a heap's underside is buried in the ground rather
				// than stopping exactly at it.
				if (sdf_solid_[wi] == 0 || sdf_mass_[wi + stride_y] > 0.0f) {
					double distance = (surface_iso - (double)smoothed[wi]) * sdf_gain;
					distance = std::min(std::max(distance, -1.0), 1.0);
					encoded = (int)(distance * s16_scale);
				}
				const int16_t v = (int16_t)encoded;
				w[vi] = (uint8_t)(v & 0xff);
				w[vi + 1] = (uint8_t)((v >> 8) & 0xff);
				++wi;
				vi += extent.y * 2;
			}
		}
	}
	return out;
}

void GranularVoxelField::_bind_methods() {
	ClassDB::bind_static_method(
			"GranularVoxelField",
			D_METHOD("create", "size", "cell_size"),
			&GranularVoxelField::create,
			DEFVAL(DEFAULT_CELL_SIZE_M));
	ClassDB::bind_method(D_METHOD("configure", "size", "cell_size"), &GranularVoxelField::configure);
	ClassDB::bind_method(D_METHOD("in_bounds", "x", "y", "z"), &GranularVoxelField::in_bounds);
	ClassDB::bind_method(D_METHOD("index", "x", "y", "z"), &GranularVoxelField::index);
	ClassDB::bind_method(D_METHOD("cell_volume_m3"), &GranularVoxelField::cell_volume_m3);
	ClassDB::bind_method(D_METHOD("set_solid", "x", "y", "z", "solid"), &GranularVoxelField::set_solid);
	ClassDB::bind_method(D_METHOD("is_solid", "x", "y", "z"), &GranularVoxelField::is_solid);
	ClassDB::bind_method(
			D_METHOD("invalidate_solid", "from_cell", "to_cell"), &GranularVoxelField::invalidate_solid);
	ClassDB::bind_method(D_METHOD("mass_at", "x", "y", "z"), &GranularVoxelField::mass_at);
	ClassDB::bind_method(D_METHOD("copy_mass_box", "lo", "extent"), &GranularVoxelField::copy_mass_box);
	ClassDB::bind_method(D_METHOD("copy_solid_box", "lo", "extent"), &GranularVoxelField::copy_solid_box);
	ClassDB::bind_method(D_METHOD("total_volume_m3"), &GranularVoxelField::total_volume_m3);
	ClassDB::bind_method(D_METHOD("active_count"), &GranularVoxelField::active_count);
	ClassDB::bind_method(D_METHOD("pending_count"), &GranularVoxelField::pending_count);
	ClassDB::bind_method(D_METHOD("is_settled"), &GranularVoxelField::is_settled);
	ClassDB::bind_method(D_METHOD("deposit", "x", "y", "z", "volume_m3"), &GranularVoxelField::deposit);
	ClassDB::bind_method(D_METHOD("take", "x", "y", "z"), &GranularVoxelField::take);
	ClassDB::bind_method(
			D_METHOD("take_fraction", "x", "y", "z", "fraction"), &GranularVoxelField::take_fraction);
	ClassDB::bind_method(D_METHOD("take_dirty"), &GranularVoxelField::take_dirty);
	ClassDB::bind_method(
			D_METHOD("prime_solid_box", "lo", "extent", "sdf_bytes", "buffer_size",
					"buffer_origin", "cell_to_local", "s16_scale"),
			&GranularVoxelField::prime_solid_box);
	ClassDB::bind_method(
			D_METHOD("build_sdf_box", "lo", "extent", "smooth_passes", "smooth_centre",
					"render_min_fill", "surface_iso", "sdf_gain", "air_sdf", "s16_scale"),
			&GranularVoxelField::build_sdf_box);
	ClassDB::bind_method(D_METHOD("step", "max_cells"), &GranularVoxelField::step, DEFVAL(0));

	ClassDB::bind_method(D_METHOD("get_size"), &GranularVoxelField::get_size);
	ClassDB::bind_method(D_METHOD("set_size", "v"), &GranularVoxelField::set_size);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3I, "size"), "set_size", "get_size");
	ClassDB::bind_method(D_METHOD("get_cell_size"), &GranularVoxelField::get_cell_size);
	ClassDB::bind_method(D_METHOD("set_cell_size", "v"), &GranularVoxelField::set_cell_size);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cell_size"), "set_cell_size", "get_cell_size");
	ClassDB::bind_method(D_METHOD("set_solid_query", "query"), &GranularVoxelField::set_solid_query);
	ClassDB::bind_method(D_METHOD("get_solid_query"), &GranularVoxelField::get_solid_query);
	ADD_PROPERTY(
			PropertyInfo(Variant::CALLABLE, "solid_query"), "set_solid_query", "get_solid_query");

	ClassDB::bind_method(D_METHOD("set_fall_rate", "v"), &GranularVoxelField::set_fall_rate);
	ClassDB::bind_method(D_METHOD("get_fall_rate"), &GranularVoxelField::get_fall_rate);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fall_rate"), "set_fall_rate", "get_fall_rate");
	ClassDB::bind_method(D_METHOD("set_spread_rate", "v"), &GranularVoxelField::set_spread_rate);
	ClassDB::bind_method(D_METHOD("get_spread_rate"), &GranularVoxelField::get_spread_rate);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spread_rate"), "set_spread_rate", "get_spread_rate");
	ClassDB::bind_method(
			D_METHOD("set_spread_min_difference", "v"), &GranularVoxelField::set_spread_min_difference);
	ClassDB::bind_method(
			D_METHOD("get_spread_min_difference"), &GranularVoxelField::get_spread_min_difference);
	ADD_PROPERTY(
			PropertyInfo(Variant::FLOAT, "spread_min_difference"),
			"set_spread_min_difference",
			"get_spread_min_difference");
	ClassDB::bind_method(D_METHOD("set_lateral_rate", "v"), &GranularVoxelField::set_lateral_rate);
	ClassDB::bind_method(D_METHOD("get_lateral_rate"), &GranularVoxelField::get_lateral_rate);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lateral_rate"), "set_lateral_rate", "get_lateral_rate");
	ClassDB::bind_method(
			D_METHOD("set_lateral_min_difference", "v"), &GranularVoxelField::set_lateral_min_difference);
	ClassDB::bind_method(
			D_METHOD("get_lateral_min_difference"), &GranularVoxelField::get_lateral_min_difference);
	ADD_PROPERTY(
			PropertyInfo(Variant::FLOAT, "lateral_min_difference"),
			"set_lateral_min_difference",
			"get_lateral_min_difference");
}
