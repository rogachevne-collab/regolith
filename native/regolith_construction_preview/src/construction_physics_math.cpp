#include "construction_physics_math.hpp"

#include <algorithm>
#include <cmath>

using namespace godot;

Vector3 ConstructionPhysicsMath::velocity_at_point(
		const Vector3 &linear_velocity,
		const Vector3 &angular_velocity,
		const Vector3 &point_world,
		const Vector3 &reference_com_world) {
	return linear_velocity + angular_velocity.cross(point_world - reference_com_world);
}

Dictionary ConstructionPhysicsMath::inherit_split_motion(
		const Vector3 &parent_linear,
		const Vector3 &parent_angular,
		const Vector3 &parent_com_world,
		const Vector3 &child_com_world) {
	Dictionary out;
	out["linear_velocity"] = velocity_at_point(
			parent_linear, parent_angular, child_com_world, parent_com_world);
	out["angular_velocity"] = parent_angular;
	return out;
}

Vector3 ConstructionPhysicsMath::total_linear_momentum(double mass_kg, const Vector3 &linear_velocity) {
	return linear_velocity * mass_kg;
}

Vector3 ConstructionPhysicsMath::angular_momentum_about_point(
		double mass_kg,
		const Vector3 &com_world,
		const Vector3 &linear_velocity,
		const Vector3 &angular_velocity,
		const Vector3 &inertia_diagonal,
		const Basis &body_basis,
		const Vector3 &reference_world) {
	const Vector3 offset = com_world - reference_world;
	const Vector3 orbital = offset.cross(linear_velocity * mass_kg);
	const Vector3 local_inertia(
			std::max(inertia_diagonal.x, 0.001),
			std::max(inertia_diagonal.y, 0.001),
			std::max(inertia_diagonal.z, 0.001));
	const Vector3 local_omega = body_basis.inverse().xform(angular_velocity);
	const Vector3 spin = body_basis.xform(Vector3(
			local_inertia.x * local_omega.x,
			local_inertia.y * local_omega.y,
			local_inertia.z * local_omega.z));
	return orbital + spin;
}

Vector3 ConstructionPhysicsMath::angular_velocity_from_momentum(
		const Vector3 &angular_momentum,
		const Vector3 &inertia_diagonal,
		const Basis &body_basis) {
	const Vector3 local_momentum = body_basis.inverse().xform(angular_momentum);
	const Vector3 local_inertia(
			std::max(inertia_diagonal.x, 0.001),
			std::max(inertia_diagonal.y, 0.001),
			std::max(inertia_diagonal.z, 0.001));
	const Vector3 local_omega(
			local_momentum.x / local_inertia.x,
			local_momentum.y / local_inertia.y,
			local_momentum.z / local_inertia.z);
	return body_basis.xform(local_omega);
}

Dictionary ConstructionPhysicsMath::merge_dynamic_momentum(
		double mass_a,
		const Vector3 &com_a_world,
		const Vector3 &linear_a,
		const Vector3 &angular_a,
		const Vector3 &inertia_a,
		const Basis &basis_a,
		double mass_b,
		const Vector3 &com_b_world,
		const Vector3 &linear_b,
		const Vector3 &angular_b,
		const Vector3 &inertia_b,
		const Basis &basis_b,
		const Vector3 &merged_com_world,
		double merged_mass,
		const Vector3 &merged_inertia,
		const Basis &merged_basis) {
	const Vector3 linear_momentum =
			total_linear_momentum(mass_a, linear_a) + total_linear_momentum(mass_b, linear_b);
	const Vector3 merged_linear = linear_momentum / std::max(merged_mass, 0.001);
	const Vector3 angular_momentum =
			angular_momentum_about_point(
					mass_a, com_a_world, linear_a, angular_a, inertia_a, basis_a, merged_com_world) +
			angular_momentum_about_point(
					mass_b, com_b_world, linear_b, angular_b, inertia_b, basis_b, merged_com_world);
	const Vector3 merged_angular =
			angular_velocity_from_momentum(angular_momentum, merged_inertia, merged_basis);
	Dictionary out;
	out["linear_velocity"] = merged_linear;
	out["angular_velocity"] = merged_angular;
	out["linear_momentum"] = linear_momentum;
	out["angular_momentum"] = angular_momentum;
	return out;
}

Vector3 ConstructionPhysicsMath::compensate_com_change(
		const Vector3 &old_com_world,
		const Vector3 &new_com_world,
		const Vector3 &linear_velocity,
		const Vector3 &angular_velocity) {
	return linear_velocity + angular_velocity.cross(new_com_world - old_com_world);
}

void ConstructionPhysicsMath::_bind_methods() {
	ClassDB::bind_static_method(
			"ConstructionPhysicsMath",
			D_METHOD("velocity_at_point", "linear_velocity", "angular_velocity", "point_world", "reference_com_world"),
			&ConstructionPhysicsMath::velocity_at_point);
	ClassDB::bind_static_method(
			"ConstructionPhysicsMath",
			D_METHOD("inherit_split_motion", "parent_linear", "parent_angular", "parent_com_world", "child_com_world"),
			&ConstructionPhysicsMath::inherit_split_motion);
	ClassDB::bind_static_method(
			"ConstructionPhysicsMath",
			D_METHOD(
					"merge_dynamic_momentum",
					"mass_a",
					"com_a_world",
					"linear_a",
					"angular_a",
					"inertia_a",
					"basis_a",
					"mass_b",
					"com_b_world",
					"linear_b",
					"angular_b",
					"inertia_b",
					"basis_b",
					"merged_com_world",
					"merged_mass",
					"merged_inertia",
					"merged_basis"),
			&ConstructionPhysicsMath::merge_dynamic_momentum);
	ClassDB::bind_static_method(
			"ConstructionPhysicsMath",
			D_METHOD("compensate_com_change", "old_com_world", "new_com_world", "linear_velocity", "angular_velocity"),
			&ConstructionPhysicsMath::compensate_com_change);
}
