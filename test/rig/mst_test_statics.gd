extends RefCounted
class_name MSTTestStatics
## Irregular static geometry: bridges an agent can walk under.
##
## This exists because projected obstructions cannot represent it. An obstruction
## is a footprint extruded straight up, so a bridge supplied as one becomes a
## solid wall - the whole point of a bridge is the gap beneath it. Anything you
## walk under, through, or over has to reach the bake as real geometry, and real
## geometry means a scene parse.
##
## It also puts two walkable layers in one xz column, which is the case phase 9
## had never covered: floor beneath, deck above. NavigationMesh.border_size only
## trims on the xz axes, so each chunk bakes its whole vertical extent in one
## pass - a deck raised above the floor makes every chunk's bake box taller, and
## that shows up in bake time whether or not the deck is over that chunk.
##
## Each bridge is one StaticBody3D carrying a deck, two posts and two railings.
## That is deliberately cheap in triangles: the cost of the parsed lane is
## dominated by one parse call per chunk, not by what the chunk contains, and
## the rig should measure that rather than an inflated triangle count.


const GROUP : String = "mst_nav_static"
## Bit 4. Props hold bit 3, and the terrain's bodies hold 1, 5 and 9.
##
## Unlike props this layer is never masked out of the parse - being parsed is
## the entire reason this category exists.
const COLLISION_LAYER : int = 1 << 3

const DECK_THICKNESS : float = 0.4
const RAILING_HEIGHT : float = 0.8
const POST_SIZE : float = 0.6
## Underside of the deck above the floor. Comfortably over the 2.0 m agent
## height, so the floor below stays walkable and the column really is two-layer.
const DECK_CLEARANCE : float = 3.0


## Puts one bridge over the north corridor of every chunk that has one.
##
## Chunks whose module has no north corridor are skipped rather than given a
## bridge over solid rock - which also means the parsed lane is genuinely empty
## for some chunks, and the hybrid source can be seen skipping them.
static func scatter_bridges(terrain: MarchingSquaresTerrain, parent: Node) -> Node3D:
	var root := Node3D.new()
	root.name = "Statics"
	parent.add_child(root)
	root.global_transform = Transform3D.IDENTITY

	var index := 0
	for coords: Vector2i in terrain.chunks.keys():
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[coords]
		if not is_instance_valid(chunk):
			continue
		var site := _bridge_site(chunk)
		if site == Vector3.INF:
			continue
		var bridge := _make_bridge(index, chunk.cell_size)
		root.add_child(bridge)
		bridge.global_position = site
		index += 1
	return root


## Centre of the north corridor, a few cells in from the room, or INF when this
## chunk's module has no corridor there to span.
static func _bridge_site(chunk: MarchingSquaresTerrainChunk) -> Vector3:
	var dims : Vector3i = chunk.dimensions
	var mid_x := floori(dims.x / 2.0)
	var mid_z := floori(dims.z / 2.0)
	var z := mid_z - MSTTestModules.PASSAGE_HALF_WIDTH - 2
	if z < 1:
		return Vector3.INF
	if absf(float(chunk.height_map[z][mid_x]) - MSTTestModules.FLOOR_HEIGHT) > 0.01:
		return Vector3.INF
	return chunk.global_position + Vector3(
		float(mid_x) * chunk.cell_size.x,
		MSTTestModules.FLOOR_HEIGHT,
		float(z) * chunk.cell_size.y
	)


static func _make_bridge(index: int, cell_size: Vector2) -> StaticBody3D:
	# Spans the corridor and lands its posts just inside the walls, so the deck
	# reaches across without the posts sitting in rock.
	var half_span := float(MSTTestModules.PASSAGE_HALF_WIDTH) * cell_size.x
	var deck_length := half_span * 2.0 + cell_size.x
	var deck_width := cell_size.y * 2.0

	var body := StaticBody3D.new()
	body.name = "Bridge_%d" % index
	body.collision_layer = COLLISION_LAYER
	body.add_to_group(GROUP)

	var deck_y := DECK_CLEARANCE + DECK_THICKNESS * 0.5
	_add_box(body, "Deck", Vector3(deck_length, DECK_THICKNESS, deck_width),
		Vector3(0.0, deck_y, 0.0), Color(0.42, 0.30, 0.18))

	for side: float in [-1.0, 1.0]:
		_add_box(body, "Post%d" % int(side),
			Vector3(POST_SIZE, DECK_CLEARANCE, POST_SIZE),
			Vector3(side * half_span, DECK_CLEARANCE * 0.5, 0.0),
			Color(0.35, 0.25, 0.15))
		_add_box(body, "Railing%d" % int(side),
			Vector3(deck_length, RAILING_HEIGHT, POST_SIZE * 0.5),
			Vector3(0.0, deck_y + DECK_THICKNESS * 0.5 + RAILING_HEIGHT * 0.5, side * deck_width * 0.5),
			Color(0.5, 0.36, 0.22))

	return body


static func _add_box(body: StaticBody3D, part_name: String, size: Vector3, offset: Vector3, colour: Color) -> void:
	var box := BoxMesh.new()
	box.size = size
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = part_name
	mesh_instance.mesh = box
	mesh_instance.position = offset
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	mesh_instance.material_override = material
	body.add_child(mesh_instance)

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = part_name + "Shape"
	collision.shape = shape
	collision.position = offset
	body.add_child(collision)


## World point in the gap under a bridge deck, for checking the floor beneath it
## is still walkable - the thing that separates real geometry from an obstruction.
static func under_deck_points(root: Node3D) -> Array:
	var result : Array = []
	if not is_instance_valid(root):
		return result
	for child in root.get_children():
		if child is Node3D:
			result.append((child as Node3D).global_position)
	return result
