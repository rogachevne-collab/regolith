// Standalone parity + benchmark for MoonMacroRelief vs pure-analytic H(n).
// Compiles against moon_terrain_sampler.cpp only (no godot deps).
#include "moon_terrain_sampler.hpp"

/// Friend of MoonTerrainSampler: component breakdowns for diagnostics.
struct MoonSamplerDebug {
	static void breakdown(
			const MoonTerrainSampler &s, const char *tag, const Vector3f &p) {
		const Vector3f domain = p * 9500.f;
		const float mare = s.mare_factor(domain);
		const float hl = 1.f - mare;
		const float cm = s.crater_field_cells(
				s.macro_cells_, p, mare, hl, 0.f, MoonTerrainSampler::kPartsMacroLayer,
				0.f);
		const float cd = s.crater_field_cells(
				s.detail_cells_, p, mare, hl, 0.f, MoonTerrainSampler::kPartsDetailLayer,
				0.f);
		const float ri = s.rille_carve_m(p);
		const float meso = s.highland_meso_roughness(domain, hl);
		const float st = s.surface_texture(domain, mare, hl, 0.f);
		printf("    %s mare=%.5f cratMacro=%.3f cratDetail=%.3f rille=%.3f meso=%.3f surf=%.3f\n",
				tag, double(mare), double(cm), double(cd), double(ri), double(meso),
				double(st));
	}

	static void culprit(
			const MoonTerrainSampler &s, const Vector3f &pa, const Vector3f &pb) {
		const int cell = MoonTerrainSampler::dir_to_cell_index(pa);
		for (int idx : s.macro_cells_[cell]) {
			const Crater &cr = s.craters_[idx];
			float ca = 0.f, ra = 0.f, cb = 0.f, rb = 0.f;
			auto eval = [&](const Vector3f &p, float &c, float &r) {
				const float cos_a =
						MoonTerrainSampler::clampf(p.dot(cr.center), -1.f, 1.f);
				if (cos_a < cr.cos_cutoff) {
					c = 0.f;
					r = 0.f;
					return -1.f;
				}
				const float t = std::acos(cos_a) / cr.rad;
				s.crater_contribution(
						t, cr.depth, cr.rim_frac, cr.cclass, cr.seed, cr.age, true,
						true, c, r);
				return t;
			};
			const float ta = eval(pa, ca, ra);
			const float tb = eval(pb, cb, rb);
			if (std::fabs(ca - cb) + std::fabs(ra - rb) > 1.f) {
				printf("    culprit idx=%d class=%d age=%d rad=%.5f depth=%.1f tA=%.5f tB=%.5f cA=%.2f cB=%.2f rA=%.2f rB=%.2f\n",
						idx, cr.cclass, cr.age, double(cr.rad), double(cr.depth),
						double(ta), double(tb), double(ca), double(cb), double(ra),
						double(rb));
			}
		}
	}
};

#include <chrono>
#include <cstdio>
#include <random>
#include <vector>

using Clock = std::chrono::steady_clock;

static double ms_since(Clock::time_point t0) {
	return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

int main() {
	const float radius = 9500.f;

	auto t0 = Clock::now();
	MoonTerrainSampler analytic(radius, false);
	printf("analytic ctor: %.0f ms (caves=%d)\n", ms_since(t0), int(analytic.caves().size()));

	t0 = Clock::now();
	MoonTerrainSampler macro(radius, true);
	printf("macro ctor (incl. cube bake): %.0f ms\n", ms_since(t0));

	// Random directions, slight bias sanity: uniform on sphere.
	std::mt19937 rng(12345);
	std::uniform_real_distribution<float> uni(-1.f, 1.f);
	const int n_samples = 500000;
	std::vector<Vector3f> dirs;
	dirs.reserve(n_samples);
	while (int(dirs.size()) < n_samples) {
		Vector3f d{ uni(rng), uni(rng), uni(rng) };
		const float l = d.length();
		if (l > 0.05f && l < 1.f) {
			dirs.push_back(d / l);
		}
	}

	// Parity.
	double max_err = 0.0, sum_err = 0.0;
	Vector3f worst{};
	std::vector<float> errs;
	errs.reserve(n_samples);
	for (const Vector3f &d : dirs) {
		const float ha = analytic.height_voxels(d);
		const float hm = macro.height_voxels(d);
		const double e = std::fabs(double(ha) - double(hm));
		errs.push_back(float(e));
		sum_err += e;
		if (e > max_err) {
			max_err = e;
			worst = d;
		}
	}
	std::sort(errs.begin(), errs.end());
	printf("parity over %d dirs: mean %.4f m, p99 %.4f m, max %.4f m at (%.4f,%.4f,%.4f)\n",
			n_samples, sum_err / n_samples, double(errs[size_t(n_samples * 0.99)]),
			max_err, worst.x, worst.y, worst.z);

	// Face-edge continuity: step a tiny arc across every cube edge at random
	// positions; the macro field's jump beyond the analytic field's own change
	// is the interpolation mismatch between adjacent faces.
	{
		std::uniform_real_distribution<float> pos(-0.999f, 0.999f);
		std::uniform_int_distribution<int> face_pick(0, 5);
		double max_jump = 0.0;
		std::vector<float> jumps;
		jumps.reserve(200000);
		Vector3f worst_in{ 1.f, 0.f, 0.f };
		Vector3f worst_out{ 0.f, 1.f, 0.f };
		const float eps = 2e-6f;
		for (int k = 0; k < 200000; ++k) {
			const int face = face_pick(rng);
			const int axis = face >> 1;
			const float s = (face & 1) ? -1.f : 1.f;
			float c[3];
			c[axis] = s;
			// Random point on a face edge: one coord at ±1, other random.
			const bool u_edge = (k & 1) != 0;
			const float edge_sign = (k & 2) ? -1.f : 1.f;
			c[(axis + 1) % 3] = u_edge ? edge_sign : pos(rng);
			c[(axis + 2) % 3] = u_edge ? pos(rng) : edge_sign;
			Vector3f on_edge{ c[0], c[1], c[2] };
			// Cross-edge direction: perturb the ±1 coordinate both ways.
			float d[3] = { c[0], c[1], c[2] };
			const int cross_axis = u_edge ? (axis + 1) % 3 : (axis + 2) % 3;
			d[cross_axis] = c[cross_axis] * (1.f + eps);
			Vector3f outside{ d[0], d[1], d[2] };
			d[cross_axis] = c[cross_axis] * (1.f - eps);
			Vector3f inside{ d[0], d[1], d[2] };
			const float jump_macro = macro.height_voxels(outside.normalized()) -
					macro.height_voxels(inside.normalized());
			const float jump_true = analytic.height_voxels(outside.normalized()) -
					analytic.height_voxels(inside.normalized());
			const double jump = std::fabs(double(jump_macro) - double(jump_true));
			jumps.push_back(float(jump));
			if (jump > max_jump) {
				max_jump = jump;
				worst_in = inside.normalized();
				worst_out = outside.normalized();
			}
		}
		printf("face-edge discontinuity: max %.4f m over 200000 edge crossings\n", max_jump);
		std::sort(jumps.begin(), jumps.end());
		printf("  jump p50 %.5f m, p99 %.5f m, p99.9 %.5f m\n",
				double(jumps[jumps.size() / 2]), double(jumps[size_t(jumps.size() * 0.99)]),
				double(jumps[size_t(jumps.size() * 0.999)]));
		// Dense arc through the worst crossing: consecutive-sample steps reveal
		// whether this is a true step (one big delta) or just a steep slope.
		const Vector3f axis_dir = worst_in.cross(worst_out).normalized();
		double max_step_diff = 0.0, max_step_macro = 0.0, max_step_analytic = 0.0;
		float prev_d = 0.f, prev_m = 0.f, prev_a = 0.f;
		const int arc_n = 400;
		for (int k = 0; k <= arc_n; ++k) {
			const float ang = (float(k) / arc_n - 0.5f) * (4.f / 9500.f); // ±2 m
			const Vector3f p =
					(worst_in * std::cos(ang) + axis_dir.cross(worst_in) * std::sin(ang))
							.normalized();
			const float hm = macro.height_voxels(p);
			const float ha = analytic.height_voxels(p);
			if (k > 0) {
				max_step_diff = std::max(
						max_step_diff, std::fabs(double(hm - ha) - double(prev_d)));
				max_step_macro =
						std::max(max_step_macro, std::fabs(double(hm) - double(prev_m)));
				max_step_analytic =
						std::max(max_step_analytic, std::fabs(double(ha) - double(prev_a)));
			}
			prev_d = hm - ha;
			prev_m = hm;
			prev_a = ha;
		}
		printf("  worst arc (1 cm steps): diff %.4f m, macro-field %.4f m, analytic-field %.4f m\n",
				max_step_diff, max_step_macro, max_step_analytic);

		// Localize the analytic step: find the worst consecutive pair, print
		// cell indices (formula mirrored from dir_to_cell_index) and H values.
		auto cell_of = [](const Vector3f &p) {
			auto axis_cell = [](float c) {
				int v = int(std::floor((c * 0.5f + 0.5f) * 64.f));
				return v < 0 ? 0 : (v > 63 ? 63 : v);
			};
			return axis_cell(p.x) + axis_cell(p.y) * 64 + axis_cell(p.z) * 64 * 64;
		};
		double worst_pair = 0.0;
		Vector3f pa, pb;
		float ha_prev = 0.f;
		for (int k = 0; k <= arc_n; ++k) {
			const float ang = (float(k) / arc_n - 0.5f) * (4.f / 9500.f);
			const Vector3f p =
					(worst_in * std::cos(ang) + axis_dir.cross(worst_in) * std::sin(ang))
							.normalized();
			const float ha = analytic.height_voxels(p);
			if (k > 0 && std::fabs(double(ha) - double(ha_prev)) > worst_pair) {
				worst_pair = std::fabs(double(ha) - double(ha_prev));
				pb = p;
			}
			if (k == 0 || std::fabs(double(ha) - double(ha_prev)) != worst_pair) {
			}
			ha_prev = ha;
			if (worst_pair == std::fabs(double(ha) - double(ha_prev))) {
			}
		}
		// second pass to get pa (point before pb)
		Vector3f prev_p = worst_in;
		for (int k = 0; k <= arc_n; ++k) {
			const float ang = (float(k) / arc_n - 0.5f) * (4.f / 9500.f);
			const Vector3f p =
					(worst_in * std::cos(ang) + axis_dir.cross(worst_in) * std::sin(ang))
							.normalized();
			if (std::fabs(p.x - pb.x) < 1e-9f && std::fabs(p.y - pb.y) < 1e-9f) {
				pa = prev_p;
				break;
			}
			prev_p = p;
		}
		printf("  step pair: H(a)=%.3f H(b)=%.3f cellA=%d cellB=%d\n",
				double(analytic.height_voxels(pa)), double(analytic.height_voxels(pb)),
				cell_of(pa), cell_of(pb));
		printf("  a=(%.7f,%.7f,%.7f) b=(%.7f,%.7f,%.7f)\n",
				pa.x, pa.y, pa.z, pb.x, pb.y, pb.z);
		MoonSamplerDebug::breakdown(analytic, "a:", pa);
		MoonSamplerDebug::breakdown(analytic, "b:", pb);
		MoonSamplerDebug::culprit(analytic, pa, pb);
	}

	// Throughput (volatile sink prevents dead-code elimination).
	volatile float sink = 0.f;
	t0 = Clock::now();
	for (const Vector3f &d : dirs) {
		sink += analytic.height_voxels(d);
	}
	const double t_analytic = ms_since(t0);
	t0 = Clock::now();
	for (const Vector3f &d : dirs) {
		sink += macro.height_voxels(d);
	}
	const double t_macro = ms_since(t0);
	printf("H(n) per call: analytic %.0f ns, macro+detail %.0f ns (%.1fx)\n",
			t_analytic * 1e6 / n_samples, t_macro * 1e6 / n_samples,
			t_analytic / t_macro);
	return sink == 12345.f ? 1 : 0;
}
