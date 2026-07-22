#include "granular_voxel_field.hpp"
#include "granular_mc_tables.hpp"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

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

Dictionary GranularVoxelField::take_dirty_prep(int chunk_size, int shell_radius) {
	const int total = size_.x * size_.y * size_.z;
	const int plane = size_.x * size_.z;
	if ((int)shell_flag_.size() != total) {
		shell_flag_.assign(total, 0);
	}
	shell_out_.clear();
	// Chunk records, gathered in a small map keyed by the packed chunk index.
	// A collapse touches a handful of chunks however many cells it moves, so
	// this stays tiny — it is the per-cell Vector3i dictionary in the script
	// path that was the cost, not the chunk count.
	struct ChunkBox {
		int cx, cy, cz;
		int lox, loy, loz;
		int hix, hiy, hiz;
	};
	std::vector<ChunkBox> chunks;
	std::unordered_map<int64_t, int> chunk_at;
	const int cw = size_.x / chunk_size + 1;
	const int ch = size_.y / chunk_size + 1;

	// Add one cell to the shell set if it is in bounds and not already there.
	auto add_shell = [&](int cx, int cy, int cz) {
		if (cx < 0 || cy < 0 || cz < 0 || cx >= size_.x || cy >= size_.y || cz >= size_.z) {
			return;
		}
		const int idx = cy * plane + cz * size_.x + cx;
		if (shell_flag_[idx] != 0) {
			return;
		}
		shell_flag_[idx] = 1;
		shell_out_.push_back(idx);
	};

	for (int32_t i : dirty_) {
		dirty_flag_[i] = 0;
		const int cx = i % size_.x;
		const int cy = i / plane;
		const int cz = (i / size_.x) % size_.z;

		// Shell: the cell itself and its neighbours out to the radius. The same
		// six-direction ring the script walked, one step at a time. Skipped
		// entirely when nothing draws chips (`shell_radius < 1`).
		if (shell_radius >= 1) {
			add_shell(cx, cy, cz);
			for (int step = 1; step <= shell_radius; ++step) {
				add_shell(cx - step, cy, cz);
				add_shell(cx + step, cy, cz);
				add_shell(cx, cy, cz - step);
				add_shell(cx, cy, cz + step);
				add_shell(cx, cy - step, cz);
				add_shell(cx, cy + step, cz);
			}
		}

		// Chunk bounds: grow the box of moved cells inside this cell's chunk.
		const int qx = cx / chunk_size;
		const int qy = cy / chunk_size;
		const int qz = cz / chunk_size;
		const int64_t key = (int64_t)qx + (int64_t)qy * cw + (int64_t)qz * cw * ch;
		auto it = chunk_at.find(key);
		if (it == chunk_at.end()) {
			chunk_at.emplace(key, (int)chunks.size());
			chunks.push_back({ qx, qy, qz, cx, cy, cz, cx, cy, cz });
		} else {
			ChunkBox &b = chunks[it->second];
			b.lox = cx < b.lox ? cx : b.lox;
			b.loy = cy < b.loy ? cy : b.loy;
			b.loz = cz < b.loz ? cz : b.loz;
			b.hix = cx > b.hix ? cx : b.hix;
			b.hiy = cy > b.hiy ? cy : b.hiy;
			b.hiz = cz > b.hiz ? cz : b.hiz;
		}
	}
	dirty_.clear();

	// Hand the shell over and clear its flags in the same walk, so the buffer
	// is zero again for next flush without a second pass over the whole field.
	PackedInt32Array shell;
	shell.resize((int)shell_out_.size());
	int32_t *sw = shell.ptrw();
	for (size_t k = 0; k < shell_out_.size(); ++k) {
		sw[k] = shell_out_[k];
		shell_flag_[shell_out_[k]] = 0;
	}

	PackedInt32Array chunk_array;
	chunk_array.resize((int)chunks.size() * 9);
	int32_t *cwp = chunk_array.ptrw();
	for (size_t k = 0; k < chunks.size(); ++k) {
		const ChunkBox &b = chunks[k];
		int32_t *r = cwp + k * 9;
		r[0] = b.cx; r[1] = b.cy; r[2] = b.cz;
		r[3] = b.lox; r[4] = b.loy; r[5] = b.loz;
		r[6] = b.hix; r[7] = b.hiy; r[8] = b.hiz;
	}

	Dictionary out;
	out["shell"] = shell;
	out["chunks"] = chunk_array;
	return out;
}

Dictionary GranularVoxelField::sample_shell(const PackedInt32Array &cells, bool want_backing) {
	const int plane = size_.x * size_.z;
	const int n = cells.size();
	PackedFloat32Array mass_out;
	PackedFloat32Array open_out;
	PackedFloat32Array back_out;
	mass_out.resize(n);
	open_out.resize(n);
	if (want_backing) {
		back_out.resize(n);
	}
	const int32_t *cp = cells.ptr();
	float *mw = mass_out.ptrw();
	float *ow = open_out.ptrw();
	float *bw = want_backing ? back_out.ptrw() : nullptr;

	for (int k = 0; k < n; ++k) {
		const int i = cp[k];
		const int x = i % size_.x;
		const int y = i / plane;
		const int z = (i / size_.x) % size_.z;
		mw[k] = mass_[i];

		// Smallest fill among the neighbours that are not rock, at a given
		// reach. A neighbour off the edge is empty ground (0) and so counts as
		// open; a rock neighbour is never open and is skipped. All-rock leaves
		// the sentinel, which the view reads as "nothing open here".
		auto min_open = [&](int reach) -> float {
			float best = 1e9f;
			const int off[6][3] = {
				{ reach, 0, 0 }, { -reach, 0, 0 },
				{ 0, reach, 0 }, { 0, -reach, 0 },
				{ 0, 0, reach }, { 0, 0, -reach }
			};
			for (int d = 0; d < 6; ++d) {
				const int nx = x + off[d][0];
				const int ny = y + off[d][1];
				const int nz = z + off[d][2];
				if (nx < 0 || ny < 0 || nz < 0 || nx >= size_.x || ny >= size_.y || nz >= size_.z) {
					best = 0.0f;
					continue;
				}
				const int ni = ny * plane + nz * size_.x + nx;
				if (solid_at(ni)) {
					continue;
				}
				if (mass_[ni] < best) {
					best = mass_[ni];
				}
			}
			return best;
		};

		ow[k] = min_open(1);
		if (want_backing) {
			bw[k] = min_open(2);
		}
	}

	Dictionary out;
	out["mass"] = mass_out;
	out["open"] = open_out;
	out["back"] = back_out;
	return out;
}

double GranularVoxelField::occupancy_at(int x, int y, int z, double render_min_fill) {
	if (x < 0 || y < 0 || z < 0 || x >= size_.x || y >= size_.y || z >= size_.z) {
		return 0.0;
	}
	const int i = (y * size_.z + z) * size_.x + x;
	const double draw_floor = render_min_fill;
	if (!solid_at(i)) {
		return std::max((double)mass_[i] - render_min_fill, 0.0) / (1.0 - render_min_fill);
	}
	// Rock counts as full only where a face neighbour holds material — the same
	// rule the mesher applies, so a corner of rock cannot lift an empty column.
	const int nb[6][3] = {
		{ 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 }
	};
	for (int d = 0; d < 6; ++d) {
		const int nx = x + nb[d][0];
		const int ny = y + nb[d][1];
		const int nz = z + nb[d][2];
		if (nx < 0 || ny < 0 || nz < 0 || nx >= size_.x || ny >= size_.y || nz >= size_.z) {
			continue;
		}
		if (mass_[(ny * size_.z + nz) * size_.x + nx] > draw_floor) {
			return 1.0;
		}
	}
	return 0.0;
}

double GranularVoxelField::smoothed_occupancy_at(
		int x, int y, int z, double render_min_fill, double smooth_centre) {
	// The separable [1, centre, 1] blur, run once over each axis, is the tensor
	// product of the three 1D kernels — so one cell's smoothed value is the
	// 3x3x3 weighted sum of the raw occupancy, with weights w(dx)*w(dy)*w(dz),
	// w(0) = centre and w(+-1) = 1, normalised by (centre + 2)^3. Evaluated this
	// way it equals the mesher's three separable passes exactly.
	const double w[3] = { 1.0, smooth_centre, 1.0 };
	const double norm = (smooth_centre + 2.0);
	const double inv = 1.0 / (norm * norm * norm);
	double sum = 0.0;
	for (int dy = -1; dy <= 1; ++dy) {
		for (int dz = -1; dz <= 1; ++dz) {
			for (int dx = -1; dx <= 1; ++dx) {
				const double weight = w[dx + 1] * w[dy + 1] * w[dz + 1];
				sum += weight * occupancy_at(x + dx, y + dy, z + dz, render_min_fill);
			}
		}
	}
	return sum * inv;
}

Dictionary GranularVoxelField::sample_surface_patches(
		const PackedInt32Array &cells,
		double render_min_fill,
		double smooth_centre,
		double surface_iso) {
	const int plane = size_.x * size_.z;
	const int n = cells.size();
	PackedVector3Array pos_out;
	PackedVector3Array nrm_out;
	pos_out.resize(n);
	nrm_out.resize(n);
	Vector3 *pw = pos_out.ptrw();
	Vector3 *nw = nrm_out.ptrw();
	const int32_t *cp = cells.ptr();

	// The blur weights, as the tensor kernel that one separable pass composes
	// to — see smoothed_occupancy_at. Held here so the seven smoothed values a
	// gradient needs share one 5x5x5 read of occupancy instead of seven 3x3x3s.
	const double w1[3] = { 1.0, smooth_centre, 1.0 };
	const double norm = smooth_centre + 2.0;
	const double blur_inv = 1.0 / (norm * norm * norm);

	// occupancy over a 5x5x5 neighbourhood, indexed [dz+2][dy+2][dx+2].
	double occ[5][5][5];

	for (int k = 0; k < n; ++k) {
		const int i = cp[k];
		const int x = i % size_.x;
		const int y = i / plane;
		const int z = (i / size_.x) % size_.z;

		for (int dz = -2; dz <= 2; ++dz) {
			for (int dy = -2; dy <= 2; ++dy) {
				for (int dx = -2; dx <= 2; ++dx) {
					occ[dz + 2][dy + 2][dx + 2] =
							occupancy_at(x + dx, y + dy, z + dz, render_min_fill);
				}
			}
		}

		// Smoothed occupancy at an offset within [-1,1] of the cell, as the
		// 3x3x3 weighted sum centred there in the local buffer.
		auto smoothed = [&](int ox, int oy, int oz) -> double {
			double sum = 0.0;
			for (int dz = -1; dz <= 1; ++dz) {
				for (int dy = -1; dy <= 1; ++dy) {
					for (int dx = -1; dx <= 1; ++dx) {
						const double weight = w1[dx + 1] * w1[dy + 1] * w1[dz + 1];
						sum += weight * occ[oz + dz + 2][oy + dy + 2][ox + dx + 2];
					}
				}
			}
			return sum * blur_inv;
		};

		const double s0 = smoothed(0, 0, 0);
		// Central difference of the smoothed field: the gradient points into
		// the material (occupancy rises inward), so its negative is outward.
		const double gx = smoothed(1, 0, 0) - smoothed(-1, 0, 0);
		const double gy = smoothed(0, 1, 0) - smoothed(0, -1, 0);
		const double gz = smoothed(0, 0, 1) - smoothed(0, 0, -1);
		const double glen = std::sqrt(gx * gx + gy * gy + gz * gz);

		// In the mesh's frame a cell's sample lives at its *integer* lattice
		// point: `build_mesh_box` emits the vertex for grid sample g at
		// `grid_lo + g`, no half-cell anywhere. Seating patches from cell
		// centres at +0.5 shifted every patch half a cell up the diagonal
		// relative to the drawn surface — chips buried on one flank of a heap
		// and floating a fifth of a metre off the opposite one, the shape right
		// and the whole layer displaced.
		Vector3 centre((real_t)x, (real_t)y, (real_t)z);
		if (glen < 1e-4) {
			// Too flat to orient — an isolated speck, or a cell already deep in
			// the mass. Hand back a zero normal; the caller seats on raw fill.
			pw[k] = centre;
			nw[k] = Vector3(0, 0, 0);
			continue;
		}
		// Outward unit normal, and the surface point reached by stepping from
		// the cell centre along it by the signed distance to the iso level.
		// `(s0 - iso)` is positive inside (occupancy above iso) and the step is
		// outward there, negative (inward) outside — so an exposed cell whose
		// centre sits just inside the mesh puts the patch out on its surface.
		//
		// The central difference spans two cells, so `glen` is twice the true
		// gradient magnitude — the Newton step needs the doubling back, or the
		// patch stops halfway from the centre to the surface. That half-step was
		// visible: chips floating off the heap wherever an exposed cell's centre
		// sat well outside the isosurface (thin walls, grazing slopes), while the
		// tops — centres already near the surface — looked seated.
		const double inv = 1.0 / glen;
		Vector3 normal((real_t)(-gx * inv), (real_t)(-gy * inv), (real_t)(-gz * inv));
		const double step = 2.0 * (s0 - surface_iso) * inv;
		pw[k] = centre + normal * (real_t)step;
		nw[k] = normal;
	}

	Dictionary out;
	out["pos"] = pos_out;
	out["normal"] = nrm_out;
	return out;
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

const std::vector<float> &GranularVoxelField::reconstruct_box(
		const Vector3i &work_lo,
		const Vector3i &work_extent,
		int smooth_passes,
		double smooth_centre,
		double render_min_fill) {
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
	// Rock counts as full where a heap meets it, and as nothing anywhere else.
	//
	// The first half is why this exists: without it the low-pass thins the heap
	// exactly where it touches the ground, and material ends in a feathered lip
	// hanging over the rock instead of sitting in it.
	//
	// The second half is the fix. Counting *all* rock as full let it carry
	// empty cells over the iso level on its own — a cell holding nothing, with
	// rock on a couple of sides, reconstructs above 0.35 and the mesher runs a
	// surface across it. Against real rock that is a stray skin in a crevice;
	// against rock the field only remembers, it is a scrap of surface hanging
	// in mid-air. Gating the *write* on nearby material was not enough, because
	// near a slope there usually is some: a single speck in a neighbour opened
	// the door and the rock behind it still did the lifting.
	//
	// So rock may only thicken a surface that material is already making. Rock
	// that touches no material contributes nothing to anybody, and an empty
	// cell in a corner of it has nothing left to be lifted by. The bedding is
	// untouched: rock under a heap touches the heap by definition.
	const double floor_scale = 1.0 / (1.0 - render_min_fill);
	// The mass at which material starts being drawn at all. Everything that
	// asks "is there material here" asks it against this, not against zero, and
	// that is one invariant rather than three tests that happen to agree:
	//
	//   nothing below the drawing floor may produce geometry by any route.
	//
	// Zero was the hole this closed. A cell holding two per cent contributes
	// nothing of its own — the floor subtracts it away — but it was still
	// enough to promote the rock beside it to full, and full rock lifts the
	// empty cells around it over the iso level. So a trace of material lodged
	// against a wall drew a quarter-metre plate on that wall, made entirely of
	// rock, with nothing in it to dig out and nothing holding it up. Drilling
	// into a standing heap leaves exactly such traces all over the face it
	// splashes against.
	const float draw_floor = (float)render_min_fill;
	const int occ_stride_z = work_extent.x;
	const int occ_stride_y = work_extent.x * work_extent.z;
	{
		int i = 0;
		for (int y = 0; y < work_extent.y; ++y) {
			for (int z = 0; z < work_extent.z; ++z) {
				for (int x = 0; x < work_extent.x; ++x, ++i) {
					if (sdf_solid_[i] == 0) {
						sdf_occupancy_[i] = (float)(
								std::max((double)sdf_mass_[i] - render_min_fill, 0.0) *
								floor_scale);
						continue;
					}
					bool touches_material = false;
					if (x > 0) {
						touches_material = sdf_mass_[i - 1] > draw_floor;
					}
					if (!touches_material && x + 1 < work_extent.x) {
						touches_material = sdf_mass_[i + 1] > draw_floor;
					}
					if (!touches_material && z > 0) {
						touches_material = sdf_mass_[i - occ_stride_z] > draw_floor;
					}
					if (!touches_material && z + 1 < work_extent.z) {
						touches_material = sdf_mass_[i + occ_stride_z] > draw_floor;
					}
					if (!touches_material && y > 0) {
						touches_material = sdf_mass_[i - occ_stride_y] > draw_floor;
					}
					if (!touches_material && y + 1 < work_extent.y) {
						touches_material = sdf_mass_[i + occ_stride_y] > draw_floor;
					}
					sdf_occupancy_[i] = touches_material ? 1.0f : 0.0f;
				}
			}
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
	return in_scratch ? sdf_scratch_ : sdf_occupancy_;
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
	const std::vector<float> &smoothed = reconstruct_box(
			work_lo, work_extent, smooth_passes, smooth_centre, render_min_fill);
	const float draw_floor = (float)render_min_fill;

	PackedByteArray out;
	const int total = extent.x * extent.y * extent.z;
	out.resize(total * 2);
	uint8_t *w = out.ptrw();
	const int stride_z = work_extent.x;
	const int stride_y = work_extent.x * work_extent.z;
	const int air = (int)(air_sdf * s16_scale);
	for (int y = 0; y < extent.y; ++y) {
		const int wy = y + radius;
		for (int z = 0; z < extent.z; ++z) {
			const int wz = z + radius;
			// The written box sits inside the work box by the kernel's radius,
			// so walking one row of it is walking one row of the scratch.
			int wi = wy * stride_y + wz * stride_z + radius;
			// The buffer's own layout, which is not the field's: y runs
			// fastest, then x, then z.
			int vi = (y + extent.y * extent.x * z) * 2;
			for (int x = 0; x < extent.x; ++x) {
				const int wx = x + radius;
				int encoded = air;
				// Is there any loose material here at all, in this cell or
				// touching it?
				//
				// This gate is what stops the surface being manufactured out of
				// rock alone. Rock counts as full in the kernel above, so an
				// *empty* cell tucked into a concave corner of rock is carried
				// over the iso level by its neighbours' 1.0 without holding a
				// gram itself — one rock neighbour already lifts it to a sixth
				// on the first axis, and a corner with rock on several sides
				// clears 0.35. The mesher then ran a surface across it.
				//
				// Against real rock that was merely an extra skin in a crevice.
				// The visible damage came from rock the field only *believes*
				// in: the solid query is memoised and invalidated in a radius
				// around each cut, so rock dug away further out stays "solid"
				// in the field. A shell of surface then hangs in the air where
				// the rock used to be, made of no material whatever, resting on
				// nothing and unable to fall because there is nothing there to
				// fall — the mesh scraps left floating around a dig.
				//
				// A cell with no material within one cell of it cannot be part
				// of a heap's surface under any reading, so this can only
				// remove geometry that was never earned. The underside of a
				// real heap is untouched: those cells hold material themselves.
				bool near_material = sdf_mass_[wi] > draw_floor;
				if (!near_material && wx > 0) {
					near_material = sdf_mass_[wi - 1] > draw_floor;
				}
				if (!near_material && wx + 1 < work_extent.x) {
					near_material = sdf_mass_[wi + 1] > draw_floor;
				}
				if (!near_material && wz > 0) {
					near_material = sdf_mass_[wi - stride_z] > draw_floor;
				}
				if (!near_material && wz + 1 < work_extent.z) {
					near_material = sdf_mass_[wi + stride_z] > draw_floor;
				}
				if (!near_material && wy > 0) {
					near_material = sdf_mass_[wi - stride_y] > draw_floor;
				}
				if (!near_material && wy + 1 < work_extent.y) {
					near_material = sdf_mass_[wi + stride_y] > draw_floor;
				}
				// Bounds-guarded, unlike the bare `wi + stride_y` this used to
				// read: at `smooth_passes = 0` the work box has no ring and the
				// top row's neighbour is off the end of the array.
				const bool material_above =
						(wy + 1 < work_extent.y) && sdf_mass_[wi + stride_y] > draw_floor;
				// Rock belongs to the world's own terrain, which already draws
				// it. The exception is rock directly under material, which is
				// claimed so a heap's underside is buried in the ground rather
				// than stopping exactly at it.
				if (near_material && (sdf_solid_[wi] == 0 || material_above)) {
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

Array GranularVoxelField::build_mesh_box(
		const Vector3i &lo,
		const Vector3i &extent,
		int smooth_passes,
		double smooth_centre,
		double render_min_fill,
		double surface_iso,
		double sdf_gain,
		double air_sdf) {
	// Cells [lo, lo+extent) are marched as cubes; the sample grid runs one
	// cell further out on every side so the boundary cubes have corners, and
	// one further again so every corner has a central-difference gradient.
	// The reconstruction pads that by the kernel radius, exactly as the SDF
	// path pads its written box.
	const int radius = smooth_passes;
	const Vector3i grid_lo = lo - Vector3i(1, 1, 1);
	const Vector3i grid_extent = extent + Vector3i(3, 3, 3);
	const Vector3i work_lo = grid_lo - Vector3i(radius, radius, radius);
	const Vector3i work_extent = grid_extent + Vector3i(radius, radius, radius) * 2;
	const std::vector<float> &smoothed = reconstruct_box(
			work_lo, work_extent, smooth_passes, smooth_centre, render_min_fill);

	// The same gate the SDF encode applies, evaluated over the sample grid:
	// nothing below the drawing floor may produce geometry by any route, and
	// rock may thicken a surface material is making but never make one. Kept
	// as one shared answer per sample rather than re-derived per cube corner.
	//
	// Every sample a cube corner can touch reads its whole neighbourhood from
	// inside the work box (the pad guarantees it at any radius >= 1), so two
	// boxes meeting at a face gate their shared samples from identical values
	// — which is what makes seam vertices bit-identical with no stitching.
	const float draw_floor = (float)render_min_fill;
	const int wex = work_extent.x;
	const int wstride_z = work_extent.x;
	const int wstride_y = work_extent.x * work_extent.z;
	const int grid_total = grid_extent.x * grid_extent.y * grid_extent.z;
	if ((int)mesh_d_.size() < grid_total) {
		mesh_d_.resize(grid_total);
	}
	{
		int gi = 0;
		for (int gy = 0; gy < grid_extent.y; ++gy) {
			for (int gz = 0; gz < grid_extent.z; ++gz) {
				for (int gx = 0; gx < grid_extent.x; ++gx, ++gi) {
					const int wx = gx + radius;
					const int wy = gy + radius;
					const int wz = gz + radius;
					const int wi = (wy * work_extent.z + wz) * wex + wx;
					bool near_material = sdf_mass_[wi] > draw_floor;
					if (!near_material && wx > 0) {
						near_material = sdf_mass_[wi - 1] > draw_floor;
					}
					if (!near_material && wx + 1 < work_extent.x) {
						near_material = sdf_mass_[wi + 1] > draw_floor;
					}
					if (!near_material && wz > 0) {
						near_material = sdf_mass_[wi - wstride_z] > draw_floor;
					}
					if (!near_material && wz + 1 < work_extent.z) {
						near_material = sdf_mass_[wi + wstride_z] > draw_floor;
					}
					if (!near_material && wy > 0) {
						near_material = sdf_mass_[wi - wstride_y] > draw_floor;
					}
					if (!near_material && wy + 1 < work_extent.y) {
						near_material = sdf_mass_[wi + wstride_y] > draw_floor;
					}
					const bool material_above =
							(wy + 1 < work_extent.y) && sdf_mass_[wi + wstride_y] > draw_floor;
					double d = air_sdf;
					if (near_material && (sdf_solid_[wi] == 0 || material_above)) {
						d = (surface_iso - (double)smoothed[wi]) * sdf_gain;
						d = std::min(std::max(d, -1.0), 1.0);
					}
					mesh_d_[gi] = (float)d;
				}
			}
		}
	}

	const int gstride_x = 1;
	const int gstride_z = grid_extent.x;
	const int gstride_y = grid_extent.x * grid_extent.z;
	const int gstrides[3] = { gstride_x, gstride_y, gstride_z };

	// One slot per grid edge — three per sample, one along each axis — holding
	// the index of the vertex already emitted on it, so a vertex shared by up
	// to four cubes is emitted once and the mesh is indexed rather than a soup.
	if ((int)mesh_edge_vertex_.size() < grid_total * 3) {
		mesh_edge_vertex_.resize(grid_total * 3);
	}
	std::fill(mesh_edge_vertex_.begin(), mesh_edge_vertex_.begin() + grid_total * 3, -1);

	std::vector<Vector3> vertices;
	std::vector<Vector3> normals;
	std::vector<int32_t> indices;

	for (int cy = 0; cy < extent.y; ++cy) {
		for (int cz = 0; cz < extent.z; ++cz) {
			for (int cx = 0; cx < extent.x; ++cx) {
				// Cube corners are the samples of cells lo+c and lo+c+1, which
				// sit at +1 in the grid because of the gradient ring.
				const int base = ((cy + 1) * grid_extent.z + (cz + 1)) * grid_extent.x + (cx + 1);
				int corner_index[8];
				int mask = 0;
				for (int c = 0; c < 8; ++c) {
					const int *off = granular_mc::CORNER_OFFSET[c];
					const int sample = base + off[0] * gstride_x + off[1] * gstride_y + off[2] * gstride_z;
					corner_index[c] = sample;
					if (mesh_d_[sample] < 0.0f) {
						mask |= 1 << c;
					}
				}
				if (mask == 0 || mask == 255) {
					continue;
				}
				const signed char *row = granular_mc::TRI_TABLE[mask];
				for (int r = 0; row[r] >= 0; ++r) {
					const int edge = row[r];
					const int corner_a = granular_mc::EDGE_CORNERS[edge][0];
					const int corner_b = granular_mc::EDGE_CORNERS[edge][1];
					const int *off_a = granular_mc::CORNER_OFFSET[corner_a];
					const int *off_b = granular_mc::CORNER_OFFSET[corner_b];
					int axis = 0;
					if (off_a[1] != off_b[1]) {
						axis = 1;
					} else if (off_a[2] != off_b[2]) {
						axis = 2;
					}
					// Canonical end: the sample nearer the origin along the
					// axis, so the same physical edge interpolates the same
					// way whichever cube or box asks for it.
					const bool a_is_base = off_a[axis] < off_b[axis];
					const int sample_base = corner_index[a_is_base ? corner_a : corner_b];
					const int sample_far = corner_index[a_is_base ? corner_b : corner_a];
					const int slot = sample_base * 3 + axis;
					int vertex = mesh_edge_vertex_[slot];
					if (vertex < 0) {
						const float d0 = mesh_d_[sample_base];
						const float d1 = mesh_d_[sample_far];
						const float span = d0 - d1;
						const float t = std::abs(span) > 1e-12f ? d0 / span : 0.5f;
						// Grid coordinates of the base sample, recovered from
						// its linear index; cell units follow from grid_lo.
						const int gy0 = sample_base / gstride_y;
						const int gz0 = (sample_base - gy0 * gstride_y) / gstride_z;
						const int gx0 = sample_base - gy0 * gstride_y - gz0 * gstride_z;
						Vector3 position(
								(float)(grid_lo.x + gx0),
								(float)(grid_lo.y + gy0),
								(float)(grid_lo.z + gz0));
						position[axis] += t;
						// The field's gradient at both ends, interpolated to
						// the crossing: d grows outward, so this points out of
						// the material — the lighting normal wanted.
						Vector3 gradient_base(
								mesh_d_[sample_base + gstride_x] - mesh_d_[sample_base - gstride_x],
								mesh_d_[sample_base + gstride_y] - mesh_d_[sample_base - gstride_y],
								mesh_d_[sample_base + gstride_z] - mesh_d_[sample_base - gstride_z]);
						Vector3 gradient_far(
								mesh_d_[sample_far + gstride_x] - mesh_d_[sample_far - gstride_x],
								mesh_d_[sample_far + gstride_y] - mesh_d_[sample_far - gstride_y],
								mesh_d_[sample_far + gstride_z] - mesh_d_[sample_far - gstride_z]);
						Vector3 normal = gradient_base.lerp(gradient_far, t);
						const real_t length = normal.length();
						normal = length > (real_t)1e-8 ? normal / length : Vector3(0, 1, 0);
						vertex = (int)vertices.size();
						vertices.push_back(position);
						normals.push_back(normal);
						mesh_edge_vertex_[slot] = vertex;
					}
					indices.push_back(vertex);
				}
			}
		}
	}

	if (indices.empty()) {
		return Array();
	}
	PackedVector3Array out_vertices;
	PackedVector3Array out_normals;
	PackedInt32Array out_indices;
	out_vertices.resize(vertices.size());
	out_normals.resize(normals.size());
	out_indices.resize(indices.size());
	{
		Vector3 *vw = out_vertices.ptrw();
		Vector3 *nw = out_normals.ptrw();
		int32_t *iw = out_indices.ptrw();
		std::copy(vertices.begin(), vertices.end(), vw);
		std::copy(normals.begin(), normals.end(), nw);
		std::copy(indices.begin(), indices.end(), iw);
	}
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = out_vertices;
	arrays[Mesh::ARRAY_NORMAL] = out_normals;
	arrays[Mesh::ARRAY_INDEX] = out_indices;
	return arrays;
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
			D_METHOD("take_dirty_prep", "chunk_size", "shell_radius"),
			&GranularVoxelField::take_dirty_prep);
	ClassDB::bind_method(
			D_METHOD("sample_shell", "cells", "want_backing"),
			&GranularVoxelField::sample_shell);
	ClassDB::bind_method(
			D_METHOD("sample_surface_patches", "cells", "render_min_fill", "smooth_centre",
					"surface_iso"),
			&GranularVoxelField::sample_surface_patches);
	ClassDB::bind_method(
			D_METHOD("prime_solid_box", "lo", "extent", "sdf_bytes", "buffer_size",
					"buffer_origin", "cell_to_local", "s16_scale"),
			&GranularVoxelField::prime_solid_box);
	ClassDB::bind_method(
			D_METHOD("build_sdf_box", "lo", "extent", "smooth_passes", "smooth_centre",
					"render_min_fill", "surface_iso", "sdf_gain", "air_sdf", "s16_scale"),
			&GranularVoxelField::build_sdf_box);
	ClassDB::bind_method(
			D_METHOD("build_mesh_box", "lo", "extent", "smooth_passes", "smooth_centre",
					"render_min_fill", "surface_iso", "sdf_gain", "air_sdf"),
			&GranularVoxelField::build_mesh_box);
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
