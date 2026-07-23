class_name ElementVisualProjection
extends Node

const VISUAL_PREFIX := "ElementVisual_"
const DRILL_SPIN_SPEED := 7.0
const STATIONARY_DRILL_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/stationary_drill_visual.gd"
)
const ROVER_MODULE_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/rover_module_visual.gd"
)
const CONNECTED_BLOCK_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/connected_block_visual.gd"
)

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _materials: Dictionary = {}
var _known_bodies: Dictionary = {}
var _drill_rotors: Dictionary = {}

func bind(
	world: SimulationWorld,
	physics_projection: SimulationPhysicsProjection
) -> void:
	if _world != null and _world.structural_event.is_connected(
		_on_structural_event
	):
		_world.structural_event.disconnect(_on_structural_event)
	_world = world
	_physics_projection = physics_projection
	_create_materials()
	if _world != null:
		_world.structural_event.connect(_on_structural_event)
	rebuild_all()

func rebuild_all() -> void:
	if _world == null or _physics_projection == null:
		return
	for assembly_id: Variant in _known_bodies.keys():
		_clear_known_body(int(assembly_id))
	for assembly: SimulationAssembly in _world.list_assemblies():
		if assembly.tombstoned:
			continue
		_rebuild_assembly(assembly.assembly_id)

func rebuild_assembly(assembly_id: int) -> void:
	_rebuild_assembly(assembly_id)

func _process(delta: float) -> void:
	if _world == null:
		return
	_resync_replaced_bodies()
	for element_id_variant: Variant in _drill_rotors.keys():
		var element_id := int(element_id_variant)
		var rotor_variant: Variant = _drill_rotors[element_id]
		if not is_instance_valid(rotor_variant):
			_drill_rotors.erase(element_id)
			continue
		var rotor := rotor_variant as Node3D
		var element := _world.get_element(element_id)
		if element == null:
			_drill_rotors.erase(element_id)
			continue
		var running := _stationary_drill_spinning(element)
		var operation_vfx := rotor.get_node_or_null("OperationVfx") as Node3D
		if operation_vfx != null:
			operation_vfx.visible = running
		if running:
			rotor.rotate_x(DRILL_SPIN_SPEED * delta)

## Physics may replace StaticBody→RigidBody (rover activate) without a
## structural event; visuals were children of the freed body.
func _resync_replaced_bodies() -> void:
	if _physics_projection == null:
		return
	var stale: Array[int] = []
	for assembly_id_variant: Variant in _known_bodies.keys():
		var assembly_id := int(assembly_id_variant)
		var known: Variant = _known_bodies.get(assembly_id)
		var current := _physics_projection.get_physics_body(assembly_id)
		if (
			current == null
			or not is_instance_valid(known)
			or known != current
		):
			stale.append(assembly_id)
	for assembly_id: int in stale:
		_rebuild_assembly(assembly_id)

func _stationary_drill_spinning(element: SimulationElement) -> bool:
	if element == null or not element.is_operational():
		return false
	var runtime := _world.ensure_industry_element_runtime(element.element_id)
	if not runtime.machine_enabled:
		return false
	if (
		IndustryArchetypeProfile.drill_requires_power()
		and not runtime.powered
	):
		return false
	return true

func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored":
			rebuild_all()
		&"assembly_spawned":
			_rebuild_assembly(int(event["assembly_id"]))
		&"assembly_changed":
			var changed_assembly_id := int(event["assembly_id"])
			var placed_element_id := int(event.get("placed_element_id", 0))
			var removed_element_id := int(event.get("removed_element_id", 0))
			if (
				placed_element_id > 0
				and _try_append_placed_element(
					changed_assembly_id,
					placed_element_id
				)
			):
				pass
			elif (
				removed_element_id > 0
				and _try_remove_projected_element(
					changed_assembly_id,
					removed_element_id
				)
			):
				pass
			else:
				_rebuild_assembly(changed_assembly_id)
		&"assembly_removed":
			_clear_known_body(int(event["assembly_id"]))
		&"assembly_split":
			_rebuild_assembly(int(event["survivor_assembly_id"]))
			for mapping_variant: Variant in event.get("new_assemblies", []):
				if mapping_variant is Dictionary:
					_rebuild_assembly(int(mapping_variant["assembly_id"]))
		&"assembly_merged":
			_clear_known_body(int(event["loser_assembly_id"]))
			_rebuild_assembly(int(event["survivor_assembly_id"]))
		&"element_state_changed":
			var change_kind := StringName(event.get("change_kind", &""))
			if change_kind in [&"damage", &"repair", &"weld"]:
				_update_element_visual(int(event.get("element_id", 0)))
			else:
				_rebuild_assembly(int(event["assembly_id"]))

func _update_element_visual(element_id: int) -> void:
	if _world == null or _physics_projection == null or element_id <= 0:
		return
	var element := _world.get_element(element_id)
	if element == null:
		return
	var body := _body_for_element(element_id)
	if body == null:
		return
	var prefix := "%s%d_" % [VISUAL_PREFIX, element_id]
	var material := _material_for(element)
	var rim_material := _rim_material_for(element)
	for child_node: Node in body.get_children():
		if child_node is MeshInstance3D and child_node.name.begins_with(prefix):
			(child_node as MeshInstance3D).material_override = material
		elif (
			child_node is Node3D
			and child_node.has_meta("connected_block_visual")
			and String(child_node.name).begins_with(prefix)
		):
			var fill := child_node.get_node_or_null("Fill") as MeshInstance3D
			var rim := child_node.get_node_or_null("Rim") as MeshInstance3D
			if fill != null:
				fill.material_override = material
			if rim != null:
				rim.material_override = rim_material

## Place/dismantle: mutate visuals in place instead of destroying every mesh on
## a large rover (L25 place was rebuilding 100+ element visuals each time).
func _try_append_placed_element(
	assembly_id: int,
	element_id: int
) -> bool:
	if _world == null or _physics_projection == null or element_id <= 0:
		return false
	var root_body := _physics_projection.get_physics_body(assembly_id)
	var known: Variant = _known_bodies.get(assembly_id)
	if (
		root_body == null
		or not is_instance_valid(known)
		or known != root_body
	):
		return false
	var assembly := _world.get_assembly_raw(assembly_id)
	var element := _world.get_element(element_id)
	if (
		assembly == null
		or assembly.tombstoned
		or element == null
		or element.assembly_id != assembly_id
	):
		return false
	var body := _body_for_element(element_id)
	if body == null:
		return false
	if _element_has_visual(body, element_id):
		return false
	var connected_index := CONNECTED_BLOCK_VISUAL_SCRIPT.build_occupancy(
		_world,
		assembly
	)
	var occupancy_cells: Dictionary = connected_index.get("cells", {})
	var archetype_by_element: Dictionary = connected_index.get(
		"archetypes",
		{}
	)
	if not _attach_element_visuals(
		body,
		assembly_id,
		element,
		occupancy_cells,
		archetype_by_element
	):
		return false
	_refresh_connected_neighbours(
		assembly_id,
		element,
		occupancy_cells,
		archetype_by_element
	)
	return true


func _try_remove_projected_element(
	_assembly_id: int,
	_element_id: int
) -> bool:
	# Dismantle needs neighbour face-mask refresh after the element is gone;
	# fall back to full rebuild until the event carries footprint/neighbours.
	return false


func _rebuild_assembly(assembly_id: int) -> void:
	var assembly := _world.get_assembly_raw(assembly_id)
	var root_body := _physics_projection.get_physics_body(assembly_id)
	if assembly == null or assembly.tombstoned or root_body == null:
		_clear_known_body(assembly_id)
		return
	_clear_assembly_visuals(assembly_id)
	_known_bodies[assembly_id] = root_body
	var connected_index := CONNECTED_BLOCK_VISUAL_SCRIPT.build_occupancy(
		_world,
		assembly
	)
	var occupancy_cells: Dictionary = connected_index.get("cells", {})
	var archetype_by_element: Dictionary = connected_index.get(
		"archetypes",
		{}
	)
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element == null:
			continue
		var body := _body_for_element(element_id)
		if body == null:
			continue
		_attach_element_visuals(
			body,
			assembly_id,
			element,
			occupancy_cells,
			archetype_by_element
		)


func _attach_element_visuals(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement,
	occupancy_cells: Dictionary,
	archetype_by_element: Dictionary
) -> bool:
	var archetype := element.get_archetype()
	if archetype == null or archetype.colliders.is_empty():
		return false
	if PistonVisual.is_piston_element(element.archetype_id):
		return true
	if ROVER_MODULE_VISUAL_SCRIPT.is_rover_module(element.archetype_id):
		_add_rover_module_visual(body, assembly_id, element)
		return true
	if _attach_scene_visual(body, assembly_id, element, archetype):
		return true
	var use_connected := CONNECTED_BLOCK_VISUAL_SCRIPT.is_connected_archetype(
		element.archetype_id
	)
	var face_mask := 0
	if use_connected:
		face_mask = CONNECTED_BLOCK_VISUAL_SCRIPT.face_occlusion_mask(
			element,
			occupancy_cells,
			archetype_by_element
		)
	for collider_index: int in range(archetype.colliders.size()):
		var collider: ColliderDefinition = archetype.colliders[collider_index]
		if (
			use_connected
			and collider.shape_kind == ColliderDefinition.ShapeKind.BOX
		):
			CONNECTED_BLOCK_VISUAL_SCRIPT.attach_element_visual(
				body,
				assembly_id,
				element,
				collider,
				collider_index,
				face_mask,
				_material_for(element),
				_rim_material_for(element)
			)
			continue
		var mesh := collider.make_preview_mesh(0.96)
		var visual := MeshInstance3D.new()
		visual.name = "%s%d_%d" % [
			VISUAL_PREFIX,
			element.element_id,
			collider_index,
		]
		visual.mesh = mesh
		visual.material_override = _material_for(element)
		visual.transform = GridPoseUtil.collider_local_transform(
			element.origin_cell,
			element.orientation_index,
			collider,
			element.pose_offset
		)
		visual.set_meta("element_visual", true)
		visual.set_meta("assembly_id", assembly_id)
		body.add_child(visual)
	if element.archetype_id == "stationary_drill":
		_add_stationary_drill_visual(body, assembly_id, element)
	return true


## Wizard-baked parts carry their authoring model; show it instead of the
## collider-box "briquettes". The metric frame + visual_offset reproduce
## exactly what the author saw (pivot compensation included).
func _attach_scene_visual(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement,
	archetype: ElementArchetype
) -> bool:
	if archetype.visual_scene_path.is_empty():
		return false
	if not ResourceLoader.exists(archetype.visual_scene_path):
		return false
	var packed := load(archetype.visual_scene_path) as PackedScene
	if packed == null:
		return false
	var instance := packed.instantiate() as Node3D
	if instance == null:
		return false
	instance.name = "%s%d_scene" % [VISUAL_PREFIX, element.element_id]
	var element_pose := (
		GridPoseUtil.element_metric_transform(
			element.origin_cell,
			element.orientation_index,
			element.pose_offset
		)
		* Transform3D(Basis.IDENTITY, archetype.visual_offset)
	)
	var root: Node3D = instance
	if archetype.is_wheel():
		root = _wrap_spinning_wheel(instance, element, archetype)
		root.name = "%s%d_wheel" % [VISUAL_PREFIX, element.element_id]
		root.set_meta("rover_module_visual", true)
		root.set_meta("element_id", element.element_id)
	else:
		instance.transform = element_pose
	root.set_meta("element_visual", true)
	root.set_meta("assembly_id", assembly_id)
	body.add_child(root)
	return true


## Wheels ride their own rigid body (WHEEL-BODY-V1), so travel, steering and
## spin all come from the body itself — nothing here moves per frame. What the
## rig still has to get right is the SEAT: the model must be centred on the
## axle, because that is the point the body turns about. Off-centre and the
## tire orbits the strut instead of rolling.
func _wrap_spinning_wheel(
	instance: Node3D,
	element: SimulationElement,
	archetype: ElementArchetype
) -> Node3D:
	var root := Node3D.new()
	root.transform = Transform3D(
		OrientationUtil.orientation_basis(element.orientation_index),
		GridPoseUtil.oriented_footprint_pivot(
			archetype,
			element.origin_cell,
			element.orientation_index
		)
	)
	var steer := Node3D.new()
	steer.name = "SteerRoot"
	steer.position = root.transform.affine_inverse() * (
		WheelBodyProjectionUtil.axle_point_assembly_local(element)
	)
	root.add_child(steer)
	var spin := Node3D.new()
	spin.name = "SpinRoot"
	# Align model +X with the tip side of the axle line (hub→plug), not the
	# unsigned forward×up sign — that sign is the same on both boards and
	# flipped every right-side hub stub outboard.
	spin.basis = _axle_to_spin_basis(element, root.transform.basis)
	steer.add_child(spin)
	# Centre the tire on the spin origin by measuring it, not by trusting the
	# model's own origin: exporters routinely drop that origin on a side face
	# or a corner (both of ours do), and the part's `visual_offset` records
	# where the AUTHOR's pivot was, which is a different question. A tire that
	# is already centred measures a zero correction, so this costs nothing when
	# the art is right and saves the wheel when it is not.
	instance.transform = Transform3D(
		Basis.IDENTITY,
		-_tire_centre_local(instance)
	)
	spin.add_child(instance)
	return root


## Centre of the biggest mesh under `node`, in `node`'s own frame. Biggest,
## not merged: a wheel model may carry a hub cap or a mount stub, and those
## must not drag the tire off the axle.
func _tire_centre_local(node: Node3D) -> Vector3:
	var best_volume := 0.0
	var centre := Vector3.ZERO
	for entry: Dictionary in _meshes_with_local_transform(node, Transform3D.IDENTITY):
		var mesh_instance: MeshInstance3D = entry["mesh_instance"]
		var bounds: AABB = mesh_instance.mesh.get_aabb()
		var volume := bounds.size.x * bounds.size.y * bounds.size.z
		if volume <= best_volume:
			continue
		best_volume = volume
		centre = (
			(entry["local_transform"] as Transform3D)
			* (bounds.position + bounds.size * 0.5)
		)
	return centre


## Meshes under `node` with their transform relative to it. The scene is not
## in the tree yet when the rig is built, so global_transform is unusable.
func _meshes_with_local_transform(
	node: Node,
	accumulated: Transform3D
) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		found.append({
			"mesh_instance": node as MeshInstance3D,
			"local_transform": accumulated,
		})
	for child: Node in node.get_children():
		var child_transform := accumulated
		if child is Node3D:
			child_transform = accumulated * (child as Node3D).transform
		found.append_array(
			_meshes_with_local_transform(child, child_transform)
		)
	return found


func _axle_to_spin_basis(
	element: SimulationElement,
	root_basis: Basis
) -> Basis:
	var frame := WheelBodyProjectionUtil.wheel_frame_assembly_local(element)
	if frame.is_empty():
		return Basis.IDENTITY
	# Physics axle is forward×up — a signed spin axis, same on both boards
	# when both roll forward. The mesh stub lives on the TIP side of the tire
	# (part +X / wheel_plug). On the right board tip is anti-parallel to that
	# axle; aligning model +X to unsigned axle flipped every starboard hub
	# outboard. Prefer the tip direction on the same line.
	var axle_assembly: Vector3 = Vector3(frame["axle"]).normalized()
	var tip_assembly := (
		WheelBodyProjectionUtil.plug_point_assembly_local(element)
		- WheelBodyProjectionUtil.axle_point_assembly_local(element)
	)
	if tip_assembly.length_squared() > 0.000001:
		var tip_dir := tip_assembly.normalized()
		if axle_assembly.dot(tip_dir) < 0.0:
			axle_assembly = -axle_assembly
	var axle := (root_basis.inverse() * axle_assembly).normalized()
	var up := (root_basis.inverse() * Vector3(frame["up"])).normalized()
	up = (up - axle * up.dot(axle)).normalized()
	if axle.length_squared() <= 0.000001 or up.length_squared() <= 0.000001:
		return Basis.IDENTITY
	return Basis(axle, up, axle.cross(up).normalized())


func _refresh_connected_neighbours(
	assembly_id: int,
	placed: SimulationElement,
	occupancy_cells: Dictionary,
	archetype_by_element: Dictionary
) -> void:
	var archetype := placed.get_archetype()
	if archetype == null:
		return
	var neighbour_ids: Dictionary = {}
	for cell: Vector3i in archetype.get_occupied_cells(
		placed.origin_cell,
		placed.orientation_index
	):
		for face: OrientationUtil.Face in CONNECTED_BLOCK_VISUAL_SCRIPT.FACE_ORDER:
			var neighbour_id: Variant = occupancy_cells.get(
				cell + OrientationUtil.face_to_vector(face)
			)
			if neighbour_id == null:
				continue
			var nid := int(neighbour_id)
			if nid == placed.element_id:
				continue
			if not CONNECTED_BLOCK_VISUAL_SCRIPT.is_connected_archetype(
				String(archetype_by_element.get(nid, ""))
			):
				continue
			neighbour_ids[nid] = true
	for neighbour_id_variant: Variant in neighbour_ids.keys():
		_refresh_one_connected_visual(
			assembly_id,
			int(neighbour_id_variant),
			occupancy_cells,
			archetype_by_element
		)


func _refresh_one_connected_visual(
	assembly_id: int,
	element_id: int,
	occupancy_cells: Dictionary,
	archetype_by_element: Dictionary
) -> void:
	var element := _world.get_element(element_id)
	if element == null:
		return
	if not CONNECTED_BLOCK_VISUAL_SCRIPT.is_connected_archetype(
		element.archetype_id
	):
		return
	var body := _body_for_element(element_id)
	if body == null:
		return
	_clear_element_visuals(body, element_id)
	_attach_element_visuals(
		body,
		assembly_id,
		element,
		occupancy_cells,
		archetype_by_element
	)


func _element_has_visual(body: PhysicsBody3D, element_id: int) -> bool:
	if body == null:
		return false
	var prefix := "%s%d_" % [VISUAL_PREFIX, element_id]
	for child_node: Node in body.get_children():
		if (
			child_node.has_meta("element_visual")
			and String(child_node.name).begins_with(prefix)
		):
			return true
	return false


func _clear_element_visuals(body: PhysicsBody3D, element_id: int) -> void:
	if body == null:
		return
	var prefix := "%s%d_" % [VISUAL_PREFIX, element_id]
	var to_free: Array[Node] = []
	for child_node: Node in body.get_children():
		if (
			child_node.has_meta("element_visual")
			and String(child_node.name).begins_with(prefix)
		):
			to_free.append(child_node)
	for child_node: Node in to_free:
		body.remove_child(child_node)
		child_node.queue_free()


func _add_rover_module_visual(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement
) -> void:
	ROVER_MODULE_VISUAL_SCRIPT.attach_runtime(body, assembly_id, element)

func _add_stationary_drill_visual(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement
) -> void:
	var root: Node3D = STATIONARY_DRILL_VISUAL_SCRIPT.instantiate_for_element(
		element.origin_cell,
		element.orientation_index,
		element.get_archetype()
	)
	root.name = "StationaryDrillWorkingHead_%d" % element.element_id
	root.set_meta("element_visual", true)
	root.set_meta("assembly_id", assembly_id)
	body.add_child(root)
	var rotor: Node3D = STATIONARY_DRILL_VISUAL_SCRIPT.operational_rotor(root)
	if rotor != null:
		_drill_rotors[element.element_id] = rotor

func _clear_visuals(body: PhysicsBody3D, assembly_id: int = 0) -> void:
	for child_node: Node in body.get_children():
		if (
			child_node.has_meta("element_visual")
			and (
				assembly_id == 0
				or int(child_node.get_meta("assembly_id", 0)) == assembly_id
			)
		):
			body.remove_child(child_node)
			child_node.queue_free()

func _clear_known_body(assembly_id: int) -> void:
	_clear_assembly_visuals(assembly_id)
	_known_bodies.erase(assembly_id)

func _body_for_element(element_id: int) -> PhysicsBody3D:
	if _physics_projection == null or element_id <= 0:
		return null
	var record := _physics_projection.get_element_projection(element_id)
	if not record.is_empty():
		return record.get("body") as PhysicsBody3D
	if _world == null:
		return null
	var element := _world.get_element(element_id)
	if element == null:
		return null
	return _physics_projection.get_physics_body(element.assembly_id)

func _clear_assembly_visuals(assembly_id: int) -> void:
	if _world == null or _physics_projection == null:
		return
	var assembly := _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	var cleared: Dictionary = {}
	for element_id: int in assembly.element_ids:
		var body := _body_for_element(element_id)
		if body == null:
			continue
		var body_id := body.get_instance_id()
		if cleared.has(body_id):
			continue
		_clear_visuals(body, assembly_id)
		cleared[body_id] = true

func _material_for(element: SimulationElement) -> StandardMaterial3D:
	var archetype := element.get_archetype()
	if (
		archetype != null
		and (
			archetype.resource_path.begins_with(
				"res://resources/archetypes/slice01/"
			)
			and (
				element.archetype_id.begins_with("rover_")
				or element.archetype_id == "cockpit"
			)
		)
	):
		return _materials["rover"]
	var reason := element.status_reason()
	if reason == &"element_broken":
		return _materials["broken"]
	if reason == &"element_incomplete":
		return _materials["frame"]
	if reason == &"damaged":
		return _materials["damaged"]
	return _materials["operational"]

func _rim_material_for(element: SimulationElement) -> StandardMaterial3D:
	if (
		element.archetype_id.begins_with("rover_")
		or element.archetype_id == "cockpit"
	):
		return _materials["rim_rover"]
	var reason := element.status_reason()
	if reason == &"element_broken":
		return _materials["rim_broken"]
	if reason == &"element_incomplete":
		return _materials["rim_frame"]
	if reason == &"damaged":
		return _materials["rim_damaged"]
	return _materials["rim_operational"]

func _create_materials() -> void:
	if not _materials.is_empty():
		return
	_materials["frame"] = _material(
		Color(0.72, 0.48, 0.22, 1.0),
		0.18,
		false,
		0.82
	)
	_materials["operational"] = _material(
		Color(0.23, 0.38, 0.55, 1.0),
		0.72,
		false
	)
	_materials["damaged"] = _material(
		Color(0.88, 0.55, 0.08, 1.0),
		0.5,
		false
	)
	_materials["broken"] = _material(
		Color(0.55, 0.04, 0.03, 1.0),
		0.25,
		false
	)
	_materials["rover"] = _material(
		Color(0.14, 0.15, 0.17, 1.0),
		0.55,
		false,
		0.78
	)
	_materials["rim_frame"] = _rim_material(
		Color(0.28, 0.16, 0.06, 1.0),
		0.4,
		0.62,
		Color(0.35, 0.2, 0.08)
	)
	_materials["rim_operational"] = _rim_material(
		Color(0.06, 0.1, 0.16, 1.0),
		0.9,
		0.28,
		Color(0.12, 0.2, 0.32)
	)
	_materials["rim_damaged"] = _rim_material(
		Color(0.42, 0.18, 0.02, 1.0),
		0.6,
		0.45,
		Color(0.5, 0.22, 0.04)
	)
	_materials["rim_broken"] = _rim_material(
		Color(0.2, 0.02, 0.02, 1.0),
		0.35,
		0.55,
		Color(0.3, 0.04, 0.04)
	)
	_materials["rim_rover"] = _rim_material(
		Color(0.03, 0.035, 0.04, 1.0),
		0.75,
		0.45,
		Color(0.08, 0.09, 0.1)
	)

func _material(
	color: Color,
	metallic: float,
	transparent: bool,
	roughness: float = 0.42
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

func _rim_material(
	color: Color,
	metallic: float,
	roughness: float,
	emission: Color
) -> StandardMaterial3D:
	var material := _material(color, metallic, false, roughness)
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = 0.35
	return material
