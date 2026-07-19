#include "moon_terrain_sampler.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <map>
#include <mutex>
#include <thread>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace {
constexpr float kTau = static_cast<float>(M_PI * 2.0);
}

void MoonTerrainSampler::configure_fnl(
		FastNoiseLite &fnl,
		int seed_value,
		float period_voxels,
		int octaves,
		float gain,
		float lacunarity) {
	/// Match ZN_FastNoiseLite: set_period(p) → SetFrequency(1/p).
	const float period = period_voxels < 0.0001f ? 0.0001f : period_voxels;
	fnl.SetSeed(seed_value);
	fnl.SetFrequency(1.f / period);
	fnl.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2);
	fnl.SetFractalType(FastNoiseLite::FractalType_FBm);
	fnl.SetFractalOctaves(octaves);
	fnl.SetFractalGain(gain);
	fnl.SetFractalLacunarity(lacunarity);
}

MoonTerrainSampler::MoonTerrainSampler(float radius_voxels, bool bake_macro) :
		radius_voxels_(radius_voxels) {
	const float scale = kVoxelScale;
	configure_fnl(mare_field_, kSeed + 11, 480.f / scale, 2, 0.32f, 2.f);
	configure_fnl(highland_rough_, kSeed + 41, 55.f / scale, 3, 0.42f, 2.f);
	configure_fnl(surface_, kSeed + 73, 20.f / scale, 2, 0.45f, 2.f);
	configure_fnl(regolith_, kSeed + 67, 4.5f / scale, 2, 0.5f, 2.f);
	configure_fnl(crater_density_, kSeed + 83, 2600.f / scale, 2, 0.5f, 2.f);
	configure_fnl(mare_ridge_, kSeed + 91, 1400.f / scale, 2, 0.5f, 2.f);
	build_mare_regions();
	rebuild_crater_index();
	build_ray_sources();
	build_rilles();
	if (bake_macro) {
		macro_ = MoonMacroRelief::acquire(*this, radius_voxels_);
	}
	/// After macro_: cave anchors must read the same H(n) the play field uses.
	build_caves();
}

void MoonTerrainSampler::build_caves() {
	caves_.clear();
	const float radius_m = radius_voxels_ * kVoxelScale;
	const float area = (radius_m / 500.f) * (radius_m / 500.f);
	const float s = std::min(std::pow(area, 0.7f), 100.f);
	const int count = std::clamp(int(kCaveBaseCount * s * 0.5f), 3, 400);
	caves_.reserve(size_t(count));

	for (int i = 0; i < count; ++i) {
		const int cs = kSeed + 9000 + i * 131;

		/// Anchor prefers maria (real lunar lava tubes; also flat floors make
		/// skylight pits legible). Rejection-sample, keep last try as fallback.
		Vector3f n = seed_dir(cs);
		for (int k = 0; k < 8; ++k) {
			const Vector3f cand = seed_dir(cs + k * 977);
			n = cand;
			if (mare_factor(cand * radius_voxels_) > 0.35f) {
				break;
			}
		}

		CaveFeature cave;
		cave.tube_radius = meters_to_voxels(lerpf(7.f, 12.f, hash01(cs + 5)));
		cave.point_count = std::min(4 + int(hash01(cs + 9) * 3.f), CaveFeature::kMaxPoints);

		/// Tangent walk along the sphere; degenerate-projection guarded.
		Vector3f t = seed_dir(cs + 7);
		t = (t - n * t.dot(n));
		if (t.length() < 0.05f) {
			t = n.cross(Vector3f{0.f, 1.f, 0.f});
		}
		t = t.normalized();

		float depth = cave.tube_radius * 1.6f;
		for (int j = 0; j < cave.point_count; ++j) {
			const float h_vox = height_voxels(n);
			cave.pts[j] = n * (radius_voxels_ + h_vox - depth);

			if (j == 0) {
				/// Collapsed skylight over the first tube point: radial shaft
				/// plus a shallow entrance bowl biting into the surface.
				cave.shaft_bottom = cave.pts[0];
				cave.shaft_top = n * (radius_voxels_ + h_vox + meters_to_voxels(20.f));
				cave.shaft_radius = cave.tube_radius * 0.55f;
				cave.entrance_center =
						n * (radius_voxels_ + h_vox + cave.tube_radius * 0.45f);
				cave.entrance_radius = cave.tube_radius * 1.5f;
			}

			const float step_vox = meters_to_voxels(lerpf(40.f, 80.f, hash01(cs + 21 + j * 7)));
			const float ang = step_vox / radius_voxels_;
			const Vector3f n_next = (n * std::cos(ang) + t * std::sin(ang)).normalized();
			t = (t - n_next * t.dot(n_next)).normalized();
			const float yaw = (hash01(cs + 33 + j * 13) - 0.5f) * 0.9f;
			t = (t * std::cos(yaw) + n_next.cross(t) * std::sin(yaw)).normalized();
			n = n_next;
			/// Dive away from the entrance; sealed far end reads as a collapse.
			depth = std::min(
					depth + cave.tube_radius * lerpf(0.15f, 0.5f, hash01(cs + 41 + j * 11)),
					cave.tube_radius * 2.8f);
		}

		const float pad = cave.tube_radius + kCaveSmoothK + 4.f;
		Vector3f mn = cave.pts[0];
		Vector3f mx = cave.pts[0];
		auto grow = [&mn, &mx](const Vector3f &p, float r) {
			mn.x = std::min(mn.x, p.x - r);
			mn.y = std::min(mn.y, p.y - r);
			mn.z = std::min(mn.z, p.z - r);
			mx.x = std::max(mx.x, p.x + r);
			mx.y = std::max(mx.y, p.y + r);
			mx.z = std::max(mx.z, p.z + r);
		};
		for (int j = 0; j < cave.point_count; ++j) {
			grow(cave.pts[j], pad);
		}
		grow(cave.shaft_top, cave.shaft_radius + kCaveSmoothK + 4.f);
		grow(cave.shaft_bottom, cave.shaft_radius + kCaveSmoothK + 4.f);
		grow(cave.entrance_center, cave.entrance_radius + kCaveSmoothK + 4.f);
		cave.aabb_min = mn;
		cave.aabb_max = mx;

		caves_.push_back(cave);
	}
}

void MoonTerrainSampler::build_ray_sources() {
	ray_sources_.clear();
	for (const Crater &cr : craters_) {
		if (cr.age != 0 || cr.cclass != kClassLarge) {
			continue;
		}
		RaySource rs;
		rs.center = cr.center;
		rs.rad = cr.rad;
		rs.cos_far = std::cos(cr.rad * 8.f);
		Vector3f e1 = seed_dir(cr.seed + 3001);
		e1 = (e1 - cr.center * e1.dot(cr.center));
		if (e1.length() < 0.05f) {
			e1 = cr.center.cross(Vector3f{ 0.f, 1.f, 0.f });
		}
		rs.e1 = e1.normalized();
		rs.e2 = cr.center.cross(rs.e1).normalized();
		rs.spokes = float(7 + int(hash01(cr.seed + 3003) * 7.f));
		rs.phase = hash01(cr.seed + 3005) * kTau;
		rs.phase2 = hash01(cr.seed + 3007) * kTau;
		rs.strength = lerpf(0.10f, 0.20f, hash01(cr.seed + 3009));
		ray_sources_.push_back(rs);
	}
}

float MoonTerrainSampler::brightness01(const Vector3f &n) const {
	float mare = 0.f;
	if (macro_ != nullptr) {
		float h_unused = 0.f;
		macro_->sample(n, h_unused, mare);
	} else {
		mare = mare_factor(n * radius_voxels_);
	}
	/// Maria are markedly darker basalt; highlands stay near 1.
	float b = 1.f - mare * 0.38f;

	for (const RaySource &rs : ray_sources_) {
		const float cos_a = clampf(n.dot(rs.center), -1.f, 1.f);
		if (cos_a < rs.cos_far) {
			continue;
		}
		const float t = std::acos(cos_a) / rs.rad;
		if (t < 1.6f) {
			/// Continuous ejecta blanket around the fresh rim.
			b += rs.strength * 0.9f * (1.6f - t) / 1.6f;
		}
		if (t > 0.9f) {
			const float az =
					std::atan2(n.dot(rs.e2), n.dot(rs.e1));
			const float sp = 0.5f + 0.5f * std::cos(az * rs.spokes + rs.phase);
			const float spoke = sp * sp * sp * sp * sp * sp;
			/// Per-spoke length variation so rays end raggedly, not on a circle.
			const float len_var =
					0.55f + 0.45f * (0.5f + 0.5f * std::cos(az * rs.spokes * 0.5f + rs.phase2));
			b += rs.strength * 1.4f * spoke * std::exp(-(t - 1.f) / (2.1f * len_var));
		}
	}
	return clampf(b, 0.5f, 1.45f) / 1.5f;
}

void MoonTerrainSampler::build_rilles() {
	rilles_.clear();
	rille_cells_.assign(kCraterGrid * kCraterGrid * kCraterGrid, {});
	const float radius_m = radius_voxels_ * kVoxelScale;
	const float area = (radius_m / 500.f) * (radius_m / 500.f);
	const float s = std::min(std::pow(area, 0.7f), 100.f);
	const int count = std::clamp(int(2.f * s * 0.35f), 2, 80);

	for (int i = 0; i < count; ++i) {
		const int rs = kSeed + 15000 + i * 257;
		/// Sinuous rilles are mare features (collapsed lava channels).
		Vector3f n = seed_dir(rs);
		for (int k = 0; k < 8; ++k) {
			const Vector3f cand = seed_dir(rs + k * 977);
			n = cand;
			if (mare_factor(cand * radius_voxels_) > 0.3f) {
				break;
			}
		}
		Vector3f t = seed_dir(rs + 7);
		t = t - n * t.dot(n);
		if (t.length() < 0.05f) {
			t = n.cross(Vector3f{ 0.f, 1.f, 0.f });
		}
		t = t.normalized();

		/// Meander walk: short steps + strong yaw = sinuous, not a ditch.
		const int pts = 16 + int(hash01(rs + 9) * 14.f);
		const float base_w = meters_to_voxels(lerpf(30.f, 90.f, hash01(rs + 11)));
		const float depth = lerpf(12.f, 35.f, hash01(rs + 13));

		/// Per-point width factor (smoothed): channels swell and pinch.
		float w_prev = base_w * lerpf(0.6f, 1.4f, hash01(rs + 71));
		for (int j = 1; j < pts; ++j) {
			const float step_vox =
					meters_to_voxels(lerpf(150.f, 350.f, hash01(rs + 21 + j * 7)));
			const float ang = step_vox / radius_voxels_;
			const Vector3f n_next = (n * std::cos(ang) + t * std::sin(ang)).normalized();

			/// Taper toward both ends so the channel emerges/sinks.
			const float f0 = (float(j) - 1.f) / float(pts - 1);
			const float f1 = float(j) / float(pts - 1);
			const float env_a = std::sqrt(std::sin(float(M_PI) * std::max(f0, 0.02f)));
			const float env_b = std::sqrt(std::sin(float(M_PI) * std::min(f1, 0.98f)));
			const float w_next = base_w *
					lerpf(0.6f, 1.4f, hash01(rs + 71 + j * 19)) * 0.5f +
					w_prev * 0.5f;

			RilleSegment seg;
			seg.a = n;
			seg.b = n_next;
			seg.mid = (n + n_next).normalized();
			seg.wa = w_prev * env_a;
			seg.wb = w_next * env_b;
			/// Depth follows width^0.7 — narrows read as shallower rapids.
			seg.da = depth * env_a * std::pow(seg.wa / base_w + 0.001f, 0.7f);
			seg.db = depth * env_b * std::pow(seg.wb / base_w + 0.001f, 0.7f);
			const float w_reach = std::max(base_w * 1.4f, std::max(seg.wa, seg.wb));
			const float reach = ang * 0.5f + w_reach * 3.f / radius_voxels_;
			seg.cos_reach = std::cos(reach);
			w_prev = w_next;

			const int idx = int(rilles_.size());
			rilles_.push_back(seg);
			const int half =
					int(std::ceil(float(kCraterGrid) * reach * 0.5f)) + 1;
			const int c0 = dir_to_cell_index(seg.mid);
			const int cx = c0 % kCraterGrid;
			const int cy = (c0 / kCraterGrid) % kCraterGrid;
			const int cz = c0 / (kCraterGrid * kCraterGrid);
			for (int dz = -half; dz <= half; ++dz) {
				for (int dy = -half; dy <= half; ++dy) {
					for (int dx = -half; dx <= half; ++dx) {
						const int ix = std::clamp(cx + dx, 0, kCraterGrid - 1);
						const int iy = std::clamp(cy + dy, 0, kCraterGrid - 1);
						const int iz = std::clamp(cz + dz, 0, kCraterGrid - 1);
						rille_cells_[ix + iy * kCraterGrid +
								iz * kCraterGrid * kCraterGrid]
								.push_back(idx);
					}
				}
			}

			t = (t - n_next * t.dot(n_next)).normalized();
			const float yaw = (hash01(rs + 33 + j * 13) - 0.5f) * 1.7f;
			t = (t * std::cos(yaw) + n_next.cross(t) * std::sin(yaw)).normalized();
			n = n_next;
		}
	}
}

float MoonTerrainSampler::rille_carve_m(const Vector3f &n) const {
	float carve = 0.f;
	const int cell = dir_to_cell_index(n);
	for (int idx : rille_cells_[cell]) {
		const RilleSegment &seg = rilles_[idx];
		if (n.dot(seg.mid) < seg.cos_reach) {
			continue;
		}
		/// Chord-space point-to-segment with along-parameter h: width and
		/// depth are cone-lerped so the channel outline stays continuous.
		const Vector3f pa = n - seg.a;
		const Vector3f ba = seg.b - seg.a;
		const float len_sq = ba.dot(ba);
		const float h =
				len_sq > 0.000001f ? clampf(pa.dot(ba) / len_sq, 0.f, 1.f) : 0.f;
		const float d_vox = (pa - ba * h).length() * radius_voxels_;
		const float w = lerpf(seg.wa, seg.wb, h);
		if (w <= 0.001f) {
			continue;
		}
		const float t = d_vox / w;
		if (t < 1.f) {
			const float q = 1.f - t * t;
			/// min-union: overlapping segments deepen, never stack rims.
			carve = std::min(carve, -lerpf(seg.da, seg.db, h) * q * q);
		}
	}
	return carve;
}

namespace {
inline bool aabb_overlap(
		const Vector3f &a_min,
		const Vector3f &a_max,
		const Vector3f &b_min,
		const Vector3f &b_max) {
	return a_min.x <= b_max.x && a_max.x >= b_min.x && a_min.y <= b_max.y &&
			a_max.y >= b_min.y && a_min.z <= b_max.z && a_max.z >= b_min.z;
}
} // namespace

bool MoonTerrainSampler::caves_touch_aabb(
		const Vector3f &aabb_min, const Vector3f &aabb_max) const {
	for (const CaveFeature &cave : caves_) {
		if (aabb_overlap(cave.aabb_min, cave.aabb_max, aabb_min, aabb_max)) {
			return true;
		}
	}
	return false;
}

void MoonTerrainSampler::gather_caves(
		const Vector3f &aabb_min,
		const Vector3f &aabb_max,
		std::vector<int> &out) const {
	for (size_t i = 0; i < caves_.size(); ++i) {
		if (aabb_overlap(caves_[i].aabb_min, caves_[i].aabb_max, aabb_min, aabb_max)) {
			out.push_back(int(i));
		}
	}
}

float MoonTerrainSampler::sd_capsule(
		const Vector3f &p, const Vector3f &a, const Vector3f &b, float r) {
	const Vector3f pa = p - a;
	const Vector3f ba = b - a;
	const float len_sq = ba.dot(ba);
	const float h = len_sq > 0.000001f ? clampf(pa.dot(ba) / len_sq, 0.f, 1.f) : 0.f;
	return (pa - ba * h).length() - r;
}

float MoonTerrainSampler::cave_carve_sdf_voxels(
		const Vector3f &p, const std::vector<int> &cave_indices) const {
	float d = 1.0e9f;
	for (int idx : cave_indices) {
		const CaveFeature &cave = caves_[idx];
		for (int j = 0; j + 1 < cave.point_count; ++j) {
			d = std::min(d, sd_capsule(p, cave.pts[j], cave.pts[j + 1], cave.tube_radius));
		}
		d = std::min(d, sd_capsule(p, cave.shaft_bottom, cave.shaft_top, cave.shaft_radius));
		d = std::min(d, (p - cave.entrance_center).length() - cave.entrance_radius);
	}
	return d;
}

void MoonTerrainSampler::build_mare_regions() {
	for (int i = 0; i < kMareCount; ++i) {
		mare_centers_[i] = seed_dir(kSeed + 801 + i * 53);
		mare_radii_[i] = lerpf(0.30f, 0.44f, hash01(kSeed + 802 + i * 71));
	}
}

void MoonTerrainSampler::register_class(
		int count,
		int seed_base,
		int class_id,
		float rad_min,
		float rad_max,
		float depth_m,
		float rim_frac) {
	for (int i = 0; i < count; ++i) {
		const Vector3f center = seed_dir(seed_base + i * 17);
		/// Density patches (med and smaller only): floor 0.15 keeps some
		/// peppering everywhere, peaks reach saturation-field density.
		if (class_id >= kClassMed) {
			const float dn = sample_fnl(crater_density_, center * radius_voxels_);
			const float sd = clampf((dn + 0.4f) / 0.8f, 0.f, 1.f);
			const float accept = 0.15f + 0.85f * (sd * sd * (3.f - 2.f * sd));
			if (hash01(seed_base + i * 53) > accept) {
				continue;
			}
		}
		const float u = hash01(seed_base + i * 31);
		register_crater(
				center, lerpf(rad_min, rad_max, u), depth_m, rim_frac, class_id,
				seed_base + i * 17, -1);
	}
}

void MoonTerrainSampler::register_crater(
		const Vector3f &center,
		float rad,
		float depth_factor,
		float rim_frac,
		int class_id,
		int seed,
		int forced_age) {
	int age = 1;
	if (forced_age >= 0) {
		age = forced_age;
	} else if (class_id != kClassHuge) {
		const float u_age = hash01(seed + 5);
		age = u_age < 0.15f ? 0 : (u_age < 0.65f ? 1 : 2);
	}

	/// depth_factor is depth/diameter (lunar simple craters ~0.1-0.2):
	/// meter depths on km-wide bowls read as flat noise on big moons.
	const float diameter_m = 2.f * rad * radius_voxels_ * kVoxelScale;
	float depth = std::min(depth_factor * diameter_m, kMaxCraterDepthM) *
			lerpf(0.82f, 1.0f, hash01(seed + 47));
	depth *= age == 0 ? 1.3f : (age == 2 ? 0.4f : 1.f);
	rim_frac *= age == 0 ? 1.35f : (age == 2 ? 0.3f : 1.f);

	const int idx = static_cast<int>(craters_.size());
	craters_.push_back(Crater{
			center, rad, depth, rim_frac, class_id, seed,
			std::cos(rad * 1.35f), age });

	/// Exact influence box (query reads a SINGLE cell, so every cell the
	/// crater touches must be registered): angular reach 1.35*rad over a
	/// [-1,1] cube → rad*1.35*grid/2 cells, +1 for center quantization.
	const int half =
			static_cast<int>(std::ceil(float(kCraterGrid) * rad * 1.35f * 0.5f)) + 1;
	const int c0 = dir_to_cell_index(center);
	const int cx = c0 % kCraterGrid;
	const int cy = (c0 / kCraterGrid) % kCraterGrid;
	const int cz = c0 / (kCraterGrid * kCraterGrid);

	for (int dz = -half; dz <= half; ++dz) {
		for (int dy = -half; dy <= half; ++dy) {
			for (int dx = -half; dx <= half; ++dx) {
				const int ix = std::clamp(cx + dx, 0, kCraterGrid - 1);
				const int iy = std::clamp(cy + dy, 0, kCraterGrid - 1);
				const int iz = std::clamp(cz + dz, 0, kCraterGrid - 1);
				const int cell = ix + iy * kCraterGrid + iz * kCraterGrid * kCraterGrid;
				if (class_id <= kClassMed) {
					macro_cells_[cell].push_back(idx);
				}
				/// Med lands in BOTH: bowl baked in macro, rim analytic.
				if (class_id >= kClassMed) {
					detail_cells_[cell].push_back(idx);
				}
			}
		}
	}
}

void MoonTerrainSampler::rebuild_crater_index() {
	craters_.clear();
	macro_cells_.assign(kCraterGrid * kCraterGrid * kCraterGrid, {});
	detail_cells_.assign(kCraterGrid * kCraterGrid * kCraterGrid, {});
	/// Area-based density scale vs the reference Ø1 km moon. pow 0.7 (not 1.0)
	/// keeps counts sane on big worlds; cap bounds memory. Ø19 km → ~62x.
	const float radius_m = radius_voxels_ * kVoxelScale;
	const float area = (radius_m / 500.f) * (radius_m / 500.f);
	const float s = std::min(std::pow(area, 0.7f), 100.f);
	const int huge_n = std::min(12, std::max(kHugeCraterCount, int(5.f * std::pow(s, 0.35f))));
	/// 6th arg = depth/diameter factor (basins shallower, small craters
	/// relatively deeper — real lunar morphology).
	register_class(huge_n, kSeed + 50, kClassHuge, 0.11f, 0.20f, 0.05f, 0.18f);
	register_class(int(kLargeCraterCount * s), kSeed + 100, kClassLarge, 0.040f, 0.095f, 0.12f, 0.16f);
	const int chain_parent_end = int(craters_.size());
	register_class(int(kMedCraterCount * s), kSeed + 200, kClassMed, 0.015f, 0.044f, 0.14f, 0.14f);
	register_class(int(kSmallCraterCount * s), kSeed + 300, kClassSmall, 0.005f, 0.015f, 0.15f, 0.12f);
	/// Meter-scale peppering near the player; amp-faded away by LOD 2-3.
	register_class(int(kTinyCraterCount * s), kSeed + 400, kClassTiny, 0.0008f, 0.0025f, 0.16f, 0.10f);
	build_secondary_chains(chain_parent_end);
}

void MoonTerrainSampler::build_secondary_chains(int parent_end) {
	/// Ejecta from huge/large impacts falls back in arcs of small craters —
	/// the clustering that makes real crater fields read as LANDSCAPE.
	for (int p = 0; p < parent_end; ++p) {
		const Crater parent = craters_[p]; // copy: vector grows below
		if (hash01(parent.seed + 777) > 0.55f) {
			continue;
		}
		const int chain_count = 1 + (hash01(parent.seed + 778) > 0.6f ? 1 : 0);
		for (int c = 0; c < chain_count; ++c) {
			const int cs = parent.seed + 800 + c * 91;
			Vector3f t = seed_dir(cs);
			t = t - parent.center * t.dot(parent.center);
			if (t.length() < 0.05f) {
				t = parent.center.cross(Vector3f{ 0.f, 1.f, 0.f });
			}
			t = t.normalized();
			const int links = 4 + int(hash01(cs + 1) * 4.f);
			const float sec_rad = parent.rad * lerpf(0.09f, 0.16f, hash01(cs + 2));
			float ang = parent.rad * 1.25f;
			for (int k = 0; k < links; ++k) {
				const Vector3f pos =
						(parent.center * std::cos(ang) + t * std::sin(ang)).normalized();
				const float rad_k = sec_rad * (1.f - 0.35f * float(k) / float(links));
				const int class_k = rad_k >= 0.015f
						? kClassMed
						: (rad_k >= 0.005f ? kClassSmall : kClassTiny);
				/// Secondaries are shallower than primaries of the same size.
				register_crater(
						pos, rad_k, 0.11f, 0.10f, class_k, cs + 7 + k * 13, parent.age);
				ang += rad_k * lerpf(2.6f, 3.6f, hash01(cs + 3 + k * 17));
			}
		}
	}
}

float MoonTerrainSampler::height_voxels(const Vector3f &n, float stride_m) const {
	const float h_m = height_meters(n, stride_m);
	return meters_to_voxels(clampf(h_m, -kHeightClampM, kHeightClampM));
}

float MoonTerrainSampler::height_meters(const Vector3f &n, float stride_m) const {
	float h = 0.f;
	float mare = 0.f;
	if (macro_ != nullptr) {
		macro_->sample(n, h, mare);
	} else {
		analytic_macro(n, h, mare);
	}
	return h + detail_meters(n, mare, stride_m, h);
}

void MoonTerrainSampler::analytic_macro(
		const Vector3f &n, float &height_m, float &mare01) const {
	const Vector3f domain = n * radius_voxels_;
	const float mare = mare_factor(domain);
	const float highland = 1.f - mare;
	float h = lerpf(-kMariaDepthM, kHighlandLiftM, highland);
	h += highland_meso_roughness(domain, highland);
	/// Linear/landmark features: cost lives in the bake, runtime is free.
	if (mare > 0.05f) {
		/// Wrinkle ridges: sharp-crested waves breaking up flat maria.
		const float r1 = sample_fnl(mare_ridge_, domain);
		const float ridge = std::pow(1.f - std::fabs(r1), 3.f);
		h += mare * ridge * 9.f;
	}
	/// Rilles add their own carve AND seed rim suppression: a canyon crossing
	/// a crater visibly breaks its rim instead of sliding underneath it.
	const float rille = rille_carve_m(n);
	h += rille;
	h += crater_field_cells(
			macro_cells_, n, mare, highland, 0.f, kPartsMacroLayer, rille);
	height_m = h;
	mare01 = mare;
}

float MoonTerrainSampler::detail_meters(
		const Vector3f &n, float mare, float stride_m, float macro_h_m) const {
	const Vector3f domain = n * radius_voxels_;
	const float highland = 1.f - mare;
	/// Macro carve estimate (how deep the baked layer already dug here)
	/// seeds rim suppression: a med/small rim can't ride a wall its own bowl
	/// never dented. Base/meso are small vs crater depths — ignored.
	const float carve_est =
			std::min(0.f, macro_h_m - lerpf(-kMariaDepthM, kHighlandLiftM, highland));
	return crater_field_cells(
					detail_cells_, n, mare, highland, stride_m, kPartsDetailLayer,
					carve_est) +
			surface_texture(domain, mare, highland, stride_m);
}

float MoonTerrainSampler::height_meters_map(const Vector3f &n) const {
	const Vector3f domain = n * radius_voxels_;
	const float mare = mare_factor(domain);
	const float highland = 1.f - mare;
	float h = lerpf(-kMariaDepthM, kHighlandLiftM, highland);
	h += highland_meso_roughness(domain, highland) * 0.35f;
	h += crater_field_map(n, mare, highland);
	return h;
}

// crater_field_map keeps unconditional rims: at map scale rings read fine.

float MoonTerrainSampler::mare_factor(const Vector3f &domain) const {
	const Vector3f n = domain / radius_voxels_;
	float mare = 0.f;
	for (int i = 0; i < kMareCount; ++i) {
		const float ang = std::acos(clampf(n.dot(mare_centers_[i]), -1.f, 1.f));
		const float rad = mare_radii_[i];
		const float edge0 = rad * 0.62f;
		const float edge1 = rad * 0.94f;
		const float t = clampf((ang - edge0) / (edge1 - edge0), 0.f, 1.f);
		const float blob = 1.f - t * t * (3.f - 2.f * t);
		mare = std::max(mare, blob);
	}
	if (mare > 0.04f) {
		const Vector3f scaled = domain * 0.85f;
		const float warp = sample_fnl(mare_field_, scaled);
		mare = clampf(mare + warp * 0.12f * mare * (1.f - mare), 0.f, 1.f);
	}
	return std::pow(clampf(mare, 0.f, 1.f), 1.28f);
}

float MoonTerrainSampler::highland_meso_roughness(const Vector3f &domain, float highland) const {
	if (highland < 0.08f || kHighlandRoughAmpM <= 0.001f) {
		return 0.f;
	}
	const float r = sample_fnl(highland_rough_, domain);
	return highland * r * kHighlandRoughAmpM;
}

float MoonTerrainSampler::surface_texture(
		const Vector3f &domain, float /*mare*/, float highland, float stride_m) const {
	/// Fade each band by its max amplitude; skip the sample entirely at zero.
	const float mid_fade = detail_fade(kSurfaceTextureM, stride_m);
	const float fine_fade = detail_fade(kMicroAmpM, stride_m);
	float h = 0.f;
	if (mid_fade > 0.f) {
		h += sample_fnl(surface_, domain) *
				lerpf(kPlainsTextureM, kSurfaceTextureM, highland) * mid_fade;
	}
	if (fine_fade > 0.f) {
		h += sample_fnl(regolith_, domain) *
				lerpf(kMicroAmpM * 0.45f, kMicroAmpM, highland) * fine_fade;
	}
	return h;
}

float MoonTerrainSampler::crater_field_cells(
		const std::vector<std::vector<int>> &cells,
		const Vector3f &n,
		float mare,
		float highland,
		float stride_m,
		int parts,
		float carve_init) const {
	float carve = 0.f;
	float rim = 0.f;
	/// Rims may only ride terrain their own bowl actually dented: bowls
	/// compose by min-union, so a crater swallowed by a deeper carve (bigger
	/// bowl in this list, or carve_init from the other layer / a rille) must
	/// not draw a floating rim ring on that wall. Deferred: suppression needs
	/// the FINAL union depth. Tiny rims (≤ ~0.4 m) skip the machinery.
	constexpr int kMaxPending = 96;
	float pend_r[kMaxPending];
	float pend_floor[kMaxPending];
	int pend_n = 0;
	const int cell = dir_to_cell_index(n);
	for (int idx : cells[cell]) {
		const Crater &crater = craters_[idx];
		/// LOD fade by crater DEPTH (see detail_fade: height-based culling
		/// keeps LOD seams tight; diameter-based tears them).
		const float lod_fade = detail_fade(crater.depth, stride_m);
		if (lod_fade <= 0.f) {
			continue;
		}
		const float cos_a = clampf(n.dot(crater.center), -1.f, 1.f);
		if (cos_a < crater.cos_cutoff) {
			continue;
		}
		const float t = std::acos(cos_a) / crater.rad;
		float visibility = lod_fade * crater_visibility(crater.cclass, highland);
		visibility *= lerpf(1.f, 0.03f, mare);
		if (visibility <= 0.001f) {
			continue;
		}
		const float d = crater.depth * visibility;
		bool bowl_en = true;
		bool rim_en = true;
		if (crater.cclass == kClassMed) {
			bowl_en = parts != kPartsDetailLayer;
			rim_en = parts != kPartsMacroLayer;
		}
		float c = 0.f;
		float r = 0.f;
		crater_contribution(
				t, d, crater.rim_frac, crater.cclass, crater.seed, crater.age,
				bowl_en, rim_en, c, r);
		carve = std::min(carve, c);
		if (r > 0.f) {
			if (crater.cclass >= kClassTiny || pend_n >= kMaxPending) {
				rim = std::max(rim, r);
			} else {
				pend_r[pend_n] = r;
				pend_floor[pend_n] =
						-d * (crater.cclass <= kClassLarge ? 0.86f : 1.f);
				++pend_n;
			}
		}
	}
	const float carve_ref = std::min(carve, carve_init);
	for (int i = 0; i < pend_n; ++i) {
		/// Full rim where the union carve is shallow vs this crater's own
		/// floor; zero where something dug deeper than it ever could.
		const float s0 = clampf(1.f - carve_ref / pend_floor[i], 0.f, 1.f);
		rim = std::max(rim, pend_r[i] * s0 * s0 * (3.f - 2.f * s0));
	}
	return carve + rim;
}

float MoonTerrainSampler::crater_field_map(
		const Vector3f &n, float mare, float highland) const {
	float carve = 0.f;
	float rim = 0.f;
	/// macro_cells_ holds exactly huge/large/med — the classes the map wants.
	const int cell = dir_to_cell_index(n);
	for (int idx : macro_cells_[cell]) {
		const Crater &crater = craters_[idx];
		const float cos_a = clampf(n.dot(crater.center), -1.f, 1.f);
		if (cos_a < crater.cos_cutoff) {
			continue;
		}
		const float t = std::acos(cos_a) / crater.rad;
		float visibility = crater_visibility(crater.cclass, highland);
		visibility *= lerpf(1.f, 0.03f, mare);
		if (visibility <= 0.001f) {
			continue;
		}
		const float d = crater.depth * visibility;
		float c = 0.f;
		float r = 0.f;
		crater_contribution(
				t, d, crater.rim_frac, crater.cclass, crater.seed, crater.age,
				true, true, c, r);
		carve = std::min(carve, c);
		rim = std::max(rim, r);
	}
	return carve + rim;
}

float MoonTerrainSampler::crater_visibility(int cclass, float highland) const {
	float base = lerpf(0.05f, 1.f, highland);
	if (cclass >= kClassMed) {
		base *= lerpf(0.03f, 1.f, highland);
	}
	if (cclass >= kClassSmall) {
		base *= lerpf(0.08f, 1.f, highland);
	}
	return base;
}

void MoonTerrainSampler::crater_contribution(
		float t,
		float d,
		float rim_frac,
		int cclass,
		int crater_seed,
		int age,
		bool bowl_en,
		bool rim_en,
		float &carve,
		float &rim) const {
	carve = 0.f;
	rim = 0.f;

	if (bowl_en && t < 1.f) {
		if (cclass <= kClassLarge) {
			const float floor_depth = -d * 0.86f;
			if (t < 0.38f) {
				if (cclass == kClassHuge && t < 0.26f) {
					/// Gate must reach zero AT the gate (else a step ring).
					const float g = clampf((0.26f - t) / 0.06f, 0.f, 1.f);
					const float peak = std::exp(-std::pow(t / 0.19f, 2.f)) *
							g * g * (3.f - 2.f * g);
					carve = floor_depth + d * 0.14f * peak;
				} else {
					carve = floor_depth;
				}
			} else {
				const float wall_t = (t - 0.38f) / 0.62f;
				float bowl = 0.5f + 0.5f * std::cos(static_cast<float>(M_PI) * wall_t);
				bowl = bowl * bowl;
				carve = lerpf(floor_depth, 0.f, 1.f - bowl);
			}
		} else {
			float bowl = 0.5f + 0.5f * std::cos(static_cast<float>(M_PI) * t);
			bowl = bowl * bowl;
			carve = -d * bowl;
		}
	}

	if (!rim_en) {
		return;
	}

	if (cclass == kClassHuge) {
		const float edge0 = 0.42f;
		const float edge1 = 0.68f;
		const float t0 = clampf((t - edge0) / (edge1 - edge0), 0.f, 1.f);
		const float terrace_env = t0 * t0 * (3.f - 2.f * t0);
		const float edge2 = 1.06f;
		const float edge3 = 0.94f;
		const float t1 = clampf((edge2 - t) / (edge2 - edge3), 0.f, 1.f);
		const float env = terrace_env * (t1 * t1 * (3.f - 2.f * t1));
		if (env > 0.001f) {
			constexpr int step_count = 2;
			for (int tier = 0; tier < step_count; ++tier) {
				const float u0 = hash01(crater_seed + tier * 113);
				const float u1 = hash01(crater_seed + tier * 197 + 3);
				const float tc = lerpf(0.78f, 0.98f, u0) + (u1 - 0.5f) * 0.04f;
				const float tw = lerpf(0.028f, 0.048f, hash01(crater_seed + tier * 311));
				const float terr = std::exp(-std::pow((t - tc) / tw, 2.f));
				const float amp = d * rim_frac * lerpf(0.06f, 0.11f, u1) * env;
				rim = std::max(rim, amp * terr);
			}
		}
	} else {
		float rim_w = lerpf(0.20f, 0.15f, std::min(float(cclass), 3.f) / 3.f);
		float rim_bump;
		if (age == 0) {
			/// Fresh: sharp cusp crest, not a soft gaussian mound.
			rim_bump = std::exp(-std::fabs(t - 1.f) / (rim_w * 0.35f));
		} else {
			if (age == 2) {
				rim_w *= 1.8f;
			}
			rim_bump = std::exp(-std::pow((t - 1.f) / rim_w, 2.f));
		}
		rim = std::max(rim, d * rim_frac * rim_bump);
	}

	if (t > 0.88f) {
		const float edge0 = 0.92f;
		const float edge1 = 1.85f;
		const float t_smooth = clampf((edge1 - t) / (edge1 - edge0), 0.f, 1.f);
		float falloff = t_smooth * t_smooth * (3.f - 2.f * t_smooth);
		falloff *= std::exp(-std::max(0.f, t - 1.f) * 1.6f);
		/// Ramp IN from zero at the 0.88 gate: the old wide gaussian rim used
		/// to mask this step; sharp fresh crests exposed it (parity test).
		const float rise = clampf((t - 0.88f) / 0.14f, 0.f, 1.f);
		falloff *= rise * rise * (3.f - 2.f * rise);
		float ej_amp = d * rim_frac * lerpf(0.42f, 0.26f, std::min(float(cclass), 3.f) / 3.f);
		ej_amp *= age == 0 ? 1.35f : (age == 2 ? 0.15f : 1.f);
		rim = std::max(rim, ej_amp * falloff);
	}

	/// Fade all raised parts to EXACTLY zero before the cos_cutoff reject at
	/// 1.35*rad — the truncated-ejecta step rings the parity test exposed.
	const float cut0 = clampf((1.32f - t) / 0.15f, 0.f, 1.f);
	rim *= cut0 * cut0 * (3.f - 2.f * cut0);
}

Vector3f MoonTerrainSampler::direction_from_node_uv(float u, float v) {
	const float lon = (0.5f - u) * kTau;
	const float ny = inv_skew3(clampf(1.f - 2.f * v, -1.f, 1.f));
	const float r = std::sqrt(std::max(0.f, 1.f - ny * ny));
	return Vector3f{r * std::cos(lon), ny, r * std::sin(lon)}.normalized();
}

int MoonTerrainSampler::dir_to_cell_index(const Vector3f &n) {
	const int x = std::clamp(
			static_cast<int>(std::floor((n.x * 0.5f + 0.5f) * float(kCraterGrid))),
			0,
			kCraterGrid - 1);
	const int y = std::clamp(
			static_cast<int>(std::floor((n.y * 0.5f + 0.5f) * float(kCraterGrid))),
			0,
			kCraterGrid - 1);
	const int z = std::clamp(
			static_cast<int>(std::floor((n.z * 0.5f + 0.5f) * float(kCraterGrid))),
			0,
			kCraterGrid - 1);
	return x + y * kCraterGrid + z * kCraterGrid * kCraterGrid;
}

float MoonTerrainSampler::hash01(int x) {
	/// Match GDScript int (64-bit) wrapping in moon_terrain_generator.gd.
	/// Shift count must be masked — bare `(v>>28)+4` can be ≥64 (UB/crash).
	uint64_t v = uint64_t(int64_t(x)) * 747796405ull + 2891336453ull;
	const uint64_t shift = ((v >> 28) + 4ull) & 63ull;
	v = ((v >> shift) ^ v) * 277803737ull;
	v = (v >> 22) ^ v;
	return float(v & 0xFFFFFFull) / float(0x1000000ull);
}

Vector3f MoonTerrainSampler::seed_dir(int seed_value) {
	const float z = hash01(seed_value) * 2.f - 1.f;
	const float a = hash01(seed_value + 913) * kTau;
	const float r = std::sqrt(std::max(0.f, 1.f - z * z));
	return Vector3f{std::cos(a) * r, z, std::sin(a) * r}.normalized();
}

float MoonTerrainSampler::inv_skew3(float s) {
	const float d = std::sqrt(s * s + 1.f / 27.f);
	const float x = cbrt_signed(s + d) + cbrt_signed(s - d);
	return clampf(x, -1.f, 1.f);
}

float MoonTerrainSampler::cbrt_signed(float a) {
	return (a >= 0.f ? 1.f : -1.f) * std::pow(std::fabs(a), 1.f / 3.f);
}

// ---------------------------------------------------------------------------
// MoonMacroRelief
// ---------------------------------------------------------------------------

namespace {
std::mutex g_macro_registry_mutex;
std::map<int, std::weak_ptr<const MoonMacroRelief>> g_macro_registry;
} // namespace

std::shared_ptr<const MoonMacroRelief> MoonMacroRelief::acquire(
		const MoonTerrainSampler &sampler, float radius_voxels) {
	const int key = int(radius_voxels * 16.f);
	/// Held across build on purpose: a second acquirer of the same radius
	/// must wait and share, not race a duplicate multi-second bake.
	std::lock_guard<std::mutex> guard(g_macro_registry_mutex);
	auto it = g_macro_registry.find(key);
	if (it != g_macro_registry.end()) {
		if (auto existing = it->second.lock()) {
			return existing;
		}
	}
	std::shared_ptr<MoonMacroRelief> built(new MoonMacroRelief());
	built->build(sampler);
	g_macro_registry[key] = built;
	return built;
}

void MoonMacroRelief::build(const MoonTerrainSampler &sampler) {
	height_scale_m_ = MoonTerrainSampler::kHeightClampM;
	const int hs = kHeightFaceN + 2 * kHeightApron;
	const int ms = kMareFaceN + 2 * kMareApron;
	height_.assign(size_t(6) * hs * hs, 0);
	mare_.assign(size_t(6) * ms * ms, 0);

	unsigned worker_count = std::thread::hardware_concurrency();
	worker_count = std::clamp(worker_count, 1u, 32u);

	/// Flat job list = every row of every face, height grid first then mare;
	/// workers pull rows off an atomic counter (rows differ wildly in crater
	/// load — static bands would straggle).
	const int height_rows = 6 * hs;
	const int total_rows = height_rows + 6 * ms;
	std::atomic<int> next_row{ 0 };

	auto worker = [&]() {
		for (;;) {
			const int row = next_row.fetch_add(1);
			if (row >= total_rows) {
				return;
			}
			float h = 0.f;
			float m = 0.f;
			/// Texel (i,j) center: uv01 = (i - apron + 0.5) / N, gnomonic 2*uv01-1.
			if (row < height_rows) {
				const int face = row / hs;
				const int j = row % hs;
				const float v =
						((float(j - kHeightApron) + 0.5f) / float(kHeightFaceN)) * 2.f - 1.f;
				uint16_t *dst = height_.data() + (size_t(face) * hs + j) * hs;
				for (int i = 0; i < hs; ++i) {
					const float u =
							((float(i - kHeightApron) + 0.5f) / float(kHeightFaceN)) * 2.f -
							1.f;
					sampler.analytic_macro(face_uv_to_dir(face, u, v), h, m);
					const float t = std::clamp(
							h / height_scale_m_ * 0.5f + 0.5f, 0.f, 1.f);
					dst[i] = uint16_t(t * 65535.f + 0.5f);
				}
			} else {
				const int mare_row = row - height_rows;
				const int face = mare_row / ms;
				const int j = mare_row % ms;
				const float v =
						((float(j - kMareApron) + 0.5f) / float(kMareFaceN)) * 2.f - 1.f;
				uint8_t *dst = mare_.data() + (size_t(face) * ms + j) * ms;
				for (int i = 0; i < ms; ++i) {
					const float u =
							((float(i - kMareApron) + 0.5f) / float(kMareFaceN)) * 2.f - 1.f;
					sampler.analytic_macro(face_uv_to_dir(face, u, v), h, m);
					dst[i] = uint8_t(std::clamp(m, 0.f, 1.f) * 255.f + 0.5f);
				}
			}
		}
	};

	std::vector<std::thread> threads;
	threads.reserve(worker_count);
	for (unsigned i = 0; i < worker_count; ++i) {
		threads.emplace_back(worker);
	}
	for (std::thread &thread : threads) {
		thread.join();
	}
}

void MoonMacroRelief::sample(const Vector3f &n, float &height_m, float &mare01) const {
	const float c[3] = { n.x, n.y, n.z };
	const float a[3] = { std::fabs(n.x), std::fabs(n.y), std::fabs(n.z) };
	const float amax = std::max(a[0], std::max(a[1], a[2]));

	/// See kFaceBlendQ: weighted blend of every face whose axis ratio is
	/// inside the edge band. One face almost everywhere, 2/3 near edges.
	float raw_h = 0.f;
	float raw_m = 0.f;
	float w_sum = 0.f;
	const float w_floor = kFaceBlendQ * amax;
	for (int axis = 0; axis < 3; ++axis) {
		const float w = a[axis] - w_floor;
		if (w <= 0.f) {
			continue;
		}
		const int face = axis * 2 + (c[axis] < 0.f ? 1 : 0);
		const float inv = 1.f / a[axis];
		const float u = c[(axis + 1) % 3] * inv;
		const float v = c[(axis + 2) % 3] * inv;
		raw_h += w * sample_face_grid(height_, kHeightFaceN, kHeightApron, face, u, v);
		raw_m += w * sample_face_grid(mare_, kMareFaceN, kMareApron, face, u, v);
		w_sum += w;
	}

	const float inv_w = 1.f / w_sum;
	height_m = (raw_h * inv_w / 65535.f * 2.f - 1.f) * height_scale_m_;
	mare01 = raw_m * inv_w / 255.f;
}

Vector3f MoonMacroRelief::face_uv_to_dir(int face, float u, float v) {
	const int axis = face >> 1;
	float c[3];
	c[axis] = (face & 1) ? -1.f : 1.f;
	c[(axis + 1) % 3] = u;
	c[(axis + 2) % 3] = v;
	return Vector3f{ c[0], c[1], c[2] }.normalized();
}

template <typename T>
float MoonMacroRelief::sample_face_grid(
		const std::vector<T> &grid,
		int face_n,
		int apron,
		int face,
		float u,
		float v) {
	const int s = face_n + 2 * apron;
	/// Padded-face coords (see build): for any uv01 within the apron reach
	/// the 2x2 bilinear footprint stays inside this face — no cross-face taps.
	const float fx = (u * 0.5f + 0.5f) * float(face_n) + float(apron) - 0.5f;
	const float fy = (v * 0.5f + 0.5f) * float(face_n) + float(apron) - 0.5f;
	int i0 = std::clamp(int(fx), 0, s - 2);
	int j0 = std::clamp(int(fy), 0, s - 2);
	const float tx = std::clamp(fx - float(i0), 0.f, 1.f);
	const float ty = std::clamp(fy - float(j0), 0.f, 1.f);
	const T *base = grid.data() + (size_t(face) * s + size_t(j0)) * s + size_t(i0);
	const float top = float(base[0]) + (float(base[1]) - float(base[0])) * tx;
	const float bot = float(base[s]) + (float(base[s + 1]) - float(base[s])) * tx;
	return top + (bot - top) * ty;
}
