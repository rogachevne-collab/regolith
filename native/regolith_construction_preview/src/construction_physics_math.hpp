#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3.hpp>

/// Native port of AssemblyPhysicsMath (split/merge momentum + COM compensation).
class ConstructionPhysicsMath : public godot::RefCounted {
	GDCLASS(ConstructionPhysicsMath, godot::RefCounted)

public:
	static godot::Vector3 velocity_at_point(
			const godot::Vector3 &linear_velocity,
			const godot::Vector3 &angular_velocity,
			const godot::Vector3 &point_world,
			const godot::Vector3 &reference_com_world);

	static godot::Dictionary inherit_split_motion(
			const godot::Vector3 &parent_linear,
			const godot::Vector3 &parent_angular,
			const godot::Vector3 &parent_com_world,
			const godot::Vector3 &child_com_world);

	static godot::Dictionary merge_dynamic_momentum(
			double mass_a,
			const godot::Vector3 &com_a_world,
			const godot::Vector3 &linear_a,
			const godot::Vector3 &angular_a,
			const godot::Vector3 &inertia_a,
			const godot::Basis &basis_a,
			double mass_b,
			const godot::Vector3 &com_b_world,
			const godot::Vector3 &linear_b,
			const godot::Vector3 &angular_b,
			const godot::Vector3 &inertia_b,
			const godot::Basis &basis_b,
			const godot::Vector3 &merged_com_world,
			double merged_mass,
			const godot::Vector3 &merged_inertia,
			const godot::Basis &merged_basis);

	static godot::Vector3 compensate_com_change(
			const godot::Vector3 &old_com_world,
			const godot::Vector3 &new_com_world,
			const godot::Vector3 &linear_velocity,
			const godot::Vector3 &angular_velocity);

protected:
	static void _bind_methods();

private:
	static godot::Vector3 total_linear_momentum(double mass_kg, const godot::Vector3 &linear_velocity);
	static godot::Vector3 angular_momentum_about_point(
			double mass_kg,
			const godot::Vector3 &com_world,
			const godot::Vector3 &linear_velocity,
			const godot::Vector3 &angular_velocity,
			const godot::Vector3 &inertia_diagonal,
			const godot::Basis &body_basis,
			const godot::Vector3 &reference_world);
	static godot::Vector3 angular_velocity_from_momentum(
			const godot::Vector3 &angular_momentum,
			const godot::Vector3 &inertia_diagonal,
			const godot::Basis &body_basis);
};
