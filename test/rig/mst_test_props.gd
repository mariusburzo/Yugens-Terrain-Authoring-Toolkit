extends RefCounted
class_name MSTTestProps
## Placeholder decoration - crates, mine carts, tree trunks - scattered on the
## cave floor so the navmesh builders can be judged on geometry the height map
## does not describe.
##
## This exists to make one difference measurable. MSTTestNav's merger reads
## height_map, so it can only ever see terrain; a mine cart standing in a
## corridor is invisible to it and agents walk straight through. A Recast bake
## reads real geometry, so the same cart punches a hole in the navmesh.
##
## Every prop is a StaticBody3D with one primitive collision shape, which is what
## NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS looks for.
##
## Footprints are deliberately kept under 2 * agent_radius. Recast erodes each
## walkable surface by the agent radius, so a narrow top erodes to nothing and
## the prop leaves a clean hole. A wide top would survive erosion and leave a
## floating nav island above the floor, which is real behaviour but would muddy
## the measurement below.


const GROUP : String = "mst_nav_prop"
## Props sit on their own collision layer so a game can raycast decoration
## separately from ground - "what did I click, a wall or a tree?".
##
## Bit 3. The terrain's own bodies take collision_layer 17 (bits 1 and 5) plus
## MarchingSquaresTerrain.extra_collision_layer, which defaults to 9, so bits 1,
## 5 and 9 are spoken for.
##
## Identity still comes from GROUP, not from this: a layer says what a body
## collides with, a group says what it is.
const COLLISION_LAYER : int = 1 << 2
const ROOT_NAME : String = "Props"
## Vertices of all-floor margin a prop needs on every side before it is placed,
## so no prop ever sits half inside a wall.
const CLEARANCE_VERTICES : int = 2
## Vertices of the chunk centre kept clear, because chunk centres are the
## endpoints every path test in the rig uses.
const CENTRE_KEEPOUT_VERTICES : int = 3
## Attempts per prop before a chunk is given up on.
const PLACEMENT_ATTEMPTS : int = 60
## Height of each kind above the floor. Read next to the baker's
## effective_max_climb(): a prop shorter than that is stepped onto, not walked
## around, so it leaves no hole in the navmesh however solid it is.
const KIND_HEIGHTS : Dictionary = {
	"Crate": 1.2,
	"MineCart": 1.6,
	"Tree": 5.0,
}
## xz extent of each kind, for the projected-obstruction footprint. A projected
## obstruction is a flat polygon extruded straight up, so this is all the shape
## information it needs - and all it can represent.
const KIND_FOOTPRINTS : Dictionary = {
	"Crate": Vector2(1.2, 1.2),
	"MineCart": Vector2(1.8, 1.2),
	"Tree": Vector2(1.2, 1.2),
}


## Scatters props over every chunk's floor and returns the node holding them.
##
## The root is parented to `parent` rather than to the terrain, and pinned to
## world identity, so the same node can be handed to
## NavigationServer3D.parse_source_geometry_data() as a parse root without
## dragging terrain colliders in with it.
static func scatter(terrain: MarchingSquaresTerrain, per_chunk: int, parent: Node) -> Node3D:
	var root := Node3D.new()
	root.name = ROOT_NAME
	parent.add_child(root)
	root.global_transform = Transform3D.IDENTITY

	var index := 0
	for coords: Vector2i in terrain.chunks.keys():
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[coords]
		if not is_instance_valid(chunk):
			continue
		for position: Vector3 in _sites_in_chunk(chunk, per_chunk, coords):
			var prop := _make_prop(index)
			root.add_child(prop)
			prop.global_position = position
			index += 1
	return root


## World-space floor point under each prop. This is what the nav comparison
## samples: a builder that cannot see props reports the point as walkable.
static func centres(root: Node3D) -> Array:
	var result : Array = []
	if not is_instance_valid(root):
		return result
	for child in root.get_children():
		if child is Node3D:
			result.append((child as Node3D).global_position)
	return result


## Prop centres grouped by kind, so clearance can be read against prop height.
static func centres_by_kind(root: Node3D) -> Dictionary:
	var result : Dictionary = {}
	if not is_instance_valid(root):
		return result
	for child in root.get_children():
		if not (child is Node3D):
			continue
		var kind := String(child.name).get_slice("_", 0)
		if not result.has(kind):
			result[kind] = []
		result[kind].append((child as Node3D).global_position)
	return result


## Every prop as a projected obstruction: a footprint polygon, a base height and
## an extrusion, instead of a tessellated collision shape.
##
## This is the cheap representation. A parsed BoxShape3D or CylinderShape3D costs
## ~266 triangles once Godot tessellates it; this costs four vertices and two
## floats. It also carves regardless of agent_max_climb, which is what the
## 1.2 m crates need - see MSTTestRecastNav.reliable_block_height().
##
## `margin` is not optional in practice: pass the agent radius. Parsed geometry is
## rasterised into the heightfield *before* Recast erodes it by the agent radius,
## so a parsed prop ends up with that much clearance around it for free. A
## projected obstruction is marked into the compact heightfield *after* erosion,
## so it carves exactly the polygon it is given and nothing more - measured as
## holes hugging each prop, against 1.67-1.82 m for the same props parsed. The
## margin puts that back, and matching it to the agent radius reproduces what
## parsing would have produced.
##
## What it cannot represent is anything you walk *under*: the polygon is extruded
## straight up from its elevation, so an archway or an overhanging branch becomes
## a solid block. Decoration that exists purely to be walked around is the fit.
static func obstructions(root: Node3D, margin: float = 0.0) -> Array:
	var result : Array = []
	if not is_instance_valid(root):
		return result
	for child in root.get_children():
		if not (child is Node3D):
			continue
		var kind := String(child.name).get_slice("_", 0)
		if not KIND_FOOTPRINTS.has(kind):
			continue
		var footprint : Vector2 = KIND_FOOTPRINTS[kind]
		var centre : Vector3 = (child as Node3D).global_position
		var half_x := footprint.x * 0.5 + margin
		var half_z := footprint.y * 0.5 + margin
		# Wound consistently; only the xz outline is read.
		var outline := PackedVector3Array([
			centre + Vector3(-half_x, 0.0, -half_z),
			centre + Vector3(half_x, 0.0, -half_z),
			centre + Vector3(half_x, 0.0, half_z),
			centre + Vector3(-half_x, 0.0, half_z),
		])
		result.append({
			"vertices": outline,
			"elevation": centre.y,
			"height": float(KIND_HEIGHTS[kind]),
			"position": centre,
			"footprint": footprint,
			"margin": margin,
		})
	return result


## Distance from each prop's floor centre to the nearest point the navigation map
## considers walkable.
##
## Near zero means the builder never noticed the prop. A value at or beyond the
## agent radius means the navmesh was carved around it.
static func nav_clearance(terrain: MarchingSquaresTerrain, prop_centres: Array) -> Dictionary:
	if prop_centres.is_empty():
		return {"count": 0, "min": 0.0, "mean": 0.0, "max": 0.0, "on_navmesh": 0, "mean_y": 0.0, "above_floor": 0}
	var map := terrain.get_world_3d().navigation_map
	var total := 0.0
	var smallest := INF
	var largest := 0.0
	# Distance alone cannot tell "the floor here was carved away" from "the floor
	# here was never in the navmesh and the nearest thing is a rock top". The y
	# of the point the map actually returned can.
	var on_navmesh := 0
	var above_floor := 0
	var y_total := 0.0
	for centre: Vector3 in prop_centres:
		var closest := NavigationServer3D.map_get_closest_point(map, centre)
		var distance := closest.distance_to(centre)
		total += distance
		smallest = minf(smallest, distance)
		largest = maxf(largest, distance)
		y_total += closest.y
		if distance < 0.1:
			on_navmesh += 1
		if closest.y - centre.y > 1.0:
			above_floor += 1
	return {
		"count": prop_centres.size(),
		"min": smallest,
		"mean": total / float(prop_centres.size()),
		"max": largest,
		"on_navmesh": on_navmesh,
		"above_floor": above_floor,
		"mean_y": y_total / float(prop_centres.size()),
	}


## Deterministic per chunk: the same layout every run, so a timing or a
## reachability difference between two builders is never down to the scatter.
static func _sites_in_chunk(chunk: MarchingSquaresTerrainChunk, wanted: int, coords: Vector2i) -> Array:
	var sites : Array = []
	if wanted <= 0:
		return sites
	var dims : Vector3i = chunk.dimensions
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(coords) ^ 0x5bf03635
	var centre_x := floori(dims.x / 2.0)
	var centre_z := floori(dims.z / 2.0)
	var origin := chunk.global_position

	for _attempt in range(PLACEMENT_ATTEMPTS):
		if sites.size() >= wanted:
			break
		var x := rng.randi_range(CLEARANCE_VERTICES, dims.x - 1 - CLEARANCE_VERTICES)
		var z := rng.randi_range(CLEARANCE_VERTICES, dims.z - 1 - CLEARANCE_VERTICES)
		if absi(x - centre_x) <= CENTRE_KEEPOUT_VERTICES and absi(z - centre_z) <= CENTRE_KEEPOUT_VERTICES:
			continue
		if not _is_clear_floor(chunk, x, z):
			continue
		var candidate := origin + Vector3(
			float(x) * chunk.cell_size.x,
			MSTTestModules.FLOOR_HEIGHT,
			float(z) * chunk.cell_size.y
		)
		# Two props in the same spot would make the clearance figures below
		# ambiguous, so keep them a comfortable stride apart.
		var too_close := false
		for existing: Vector3 in sites:
			if existing.distance_to(candidate) < chunk.cell_size.x * 2.0:
				too_close = true
				break
		if too_close:
			continue
		sites.append(candidate)
	return sites


static func _is_clear_floor(chunk: MarchingSquaresTerrainChunk, x: int, z: int) -> bool:
	for dz in range(-CLEARANCE_VERTICES, CLEARANCE_VERTICES + 1):
		for dx in range(-CLEARANCE_VERTICES, CLEARANCE_VERTICES + 1):
			var height := float(chunk.height_map[z + dz][x + dx])
			if absf(height - MSTTestModules.FLOOR_HEIGHT) > 0.01:
				return false
	return true


static func _make_prop(index: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = COLLISION_LAYER
	body.add_to_group(GROUP)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"

	match index % 3:
		0:
			# Mine cart: long, narrow, and low enough to step over in principle,
			# which is exactly the case a height map cannot represent.
			body.name = "MineCart_%d" % index
			var cart := BoxMesh.new()
			cart.size = Vector3(1.8, 1.6, 1.2)
			mesh_instance.mesh = cart
			var cart_shape := BoxShape3D.new()
			cart_shape.size = cart.size
			collision.shape = cart_shape
			mesh_instance.position = Vector3(0.0, cart.size.y * 0.5, 0.0)
			collision.position = mesh_instance.position
			mesh_instance.material_override = _material(Color(0.45, 0.33, 0.2))
		1:
			body.name = "Tree_%d" % index
			var trunk := CylinderMesh.new()
			trunk.top_radius = 0.5
			trunk.bottom_radius = 0.6
			trunk.height = 5.0
			mesh_instance.mesh = trunk
			var trunk_shape := CylinderShape3D.new()
			trunk_shape.radius = 0.6
			trunk_shape.height = trunk.height
			collision.shape = trunk_shape
			mesh_instance.position = Vector3(0.0, trunk.height * 0.5, 0.0)
			collision.position = mesh_instance.position
			mesh_instance.material_override = _material(Color(0.25, 0.4, 0.22))
		_:
			body.name = "Crate_%d" % index
			var crate := BoxMesh.new()
			crate.size = Vector3(1.2, 1.2, 1.2)
			mesh_instance.mesh = crate
			var crate_shape := BoxShape3D.new()
			crate_shape.size = crate.size
			collision.shape = crate_shape
			mesh_instance.position = Vector3(0.0, crate.size.y * 0.5, 0.0)
			collision.position = mesh_instance.position
			mesh_instance.material_override = _material(Color(0.6, 0.55, 0.3))

	body.add_child(mesh_instance)
	body.add_child(collision)
	return body


static func _material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	return material
