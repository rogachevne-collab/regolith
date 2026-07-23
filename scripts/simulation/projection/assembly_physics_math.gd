class_name AssemblyPhysicsMath
extends RefCounted


static func _native_available() -> bool:
	return ClassDB.class_exists(&"ConstructionPhysicsMath")


static func velocity_at_point(
	linear_velocity: Vector3,
	angular_velocity: Vector3,
	point_world: Vector3,
	reference_com_world: Vector3
) -> Vector3:
	if _native_available():
		return ClassDB.class_call_static(
			&"ConstructionPhysicsMath",
			&"velocity_at_point",
			linear_velocity,
			angular_velocity,
			point_world,
			reference_com_world
		)
	return (
		linear_velocity
		+ angular_velocity.cross(point_world - reference_com_world)
	)


static func inherit_split_motion(
	parent_linear: Vector3,
	parent_angular: Vector3,
	parent_com_world: Vector3,
	child_com_world: Vector3
) -> Dictionary:
	if _native_available():
		return ClassDB.class_call_static(
			&"ConstructionPhysicsMath",
			&"inherit_split_motion",
			parent_linear,
			parent_angular,
			parent_com_world,
			child_com_world
		)
	return {
		"linear_velocity": velocity_at_point(
			parent_linear,
			parent_angular,
			child_com_world,
			parent_com_world
		),
		"angular_velocity": parent_angular,
	}


static func total_linear_momentum(
	mass_kg: float,
	linear_velocity: Vector3
) -> Vector3:
	return mass_kg * linear_velocity


static func angular_momentum_about_point(
	mass_kg: float,
	com_world: Vector3,
	linear_velocity: Vector3,
	angular_velocity: Vector3,
	inertia_diagonal: Vector3,
	body_basis: Basis,
	reference_world: Vector3
) -> Vector3:
	var offset: Vector3 = com_world - reference_world
	var orbital: Vector3 = offset.cross(mass_kg * linear_velocity)
	var local_inertia: Vector3 = Vector3(
		maxf(inertia_diagonal.x, 0.001),
		maxf(inertia_diagonal.y, 0.001),
		maxf(inertia_diagonal.z, 0.001)
	)
	var local_omega: Vector3 = body_basis.inverse() * angular_velocity
	var spin: Vector3 = body_basis * Vector3(
		local_inertia.x * local_omega.x,
		local_inertia.y * local_omega.y,
		local_inertia.z * local_omega.z
	)
	return orbital + spin


static func merge_dynamic_momentum(
	mass_a: float,
	com_a_world: Vector3,
	linear_a: Vector3,
	angular_a: Vector3,
	inertia_a: Vector3,
	basis_a: Basis,
	mass_b: float,
	com_b_world: Vector3,
	linear_b: Vector3,
	angular_b: Vector3,
	inertia_b: Vector3,
	basis_b: Basis,
	merged_com_world: Vector3,
	merged_mass: float,
	merged_inertia: Vector3,
	merged_basis: Basis
) -> Dictionary:
	if _native_available():
		return ClassDB.class_call_static(
			&"ConstructionPhysicsMath",
			&"merge_dynamic_momentum",
			mass_a,
			com_a_world,
			linear_a,
			angular_a,
			inertia_a,
			basis_a,
			mass_b,
			com_b_world,
			linear_b,
			angular_b,
			inertia_b,
			basis_b,
			merged_com_world,
			merged_mass,
			merged_inertia,
			merged_basis
		)
	var linear_momentum: Vector3 = (
		total_linear_momentum(mass_a, linear_a)
		+ total_linear_momentum(mass_b, linear_b)
	)
	var merged_linear: Vector3 = (
		linear_momentum / maxf(merged_mass, 0.001)
	)
	var angular_momentum: Vector3 = (
		angular_momentum_about_point(
			mass_a,
			com_a_world,
			linear_a,
			angular_a,
			inertia_a,
			basis_a,
			merged_com_world
		)
		+ angular_momentum_about_point(
			mass_b,
			com_b_world,
			linear_b,
			angular_b,
			inertia_b,
			basis_b,
			merged_com_world
		)
	)
	var merged_angular: Vector3 = _angular_velocity_from_momentum(
		angular_momentum,
		merged_inertia,
		merged_basis
	)
	return {
		"linear_velocity": merged_linear,
		"angular_velocity": merged_angular,
		"linear_momentum": linear_momentum,
		"angular_momentum": angular_momentum,
	}


static func compensate_com_change(
	old_com_world: Vector3,
	new_com_world: Vector3,
	linear_velocity: Vector3,
	angular_velocity: Vector3
) -> Vector3:
	if _native_available():
		return ClassDB.class_call_static(
			&"ConstructionPhysicsMath",
			&"compensate_com_change",
			old_com_world,
			new_com_world,
			linear_velocity,
			angular_velocity
		)
	return linear_velocity + angular_velocity.cross(
		new_com_world - old_com_world
	)


static func _angular_velocity_from_momentum(
	angular_momentum: Vector3,
	inertia_diagonal: Vector3,
	body_basis: Basis
) -> Vector3:
	var local_momentum: Vector3 = body_basis.inverse() * angular_momentum
	var local_inertia: Vector3 = Vector3(
		maxf(inertia_diagonal.x, 0.001),
		maxf(inertia_diagonal.y, 0.001),
		maxf(inertia_diagonal.z, 0.001)
	)
	var local_omega: Vector3 = Vector3(
		local_momentum.x / local_inertia.x,
		local_momentum.y / local_inertia.y,
		local_momentum.z / local_inertia.z
	)
	return body_basis * local_omega
