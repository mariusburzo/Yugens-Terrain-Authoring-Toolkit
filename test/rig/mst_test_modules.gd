@tool
extends RefCounted
class_name MSTTestModules
## Builds placeholder cave modules as MSTChunkData so the rig can run without
## hand-authored assets.
##
## A module is identified by a 4-bit socket mask: which of its four edges are
## open. Because every module of a given dimension carves its passages at the
## same vertex indices, any two modules that face each other with matching
## sockets share an identical border height row by construction. That is the
## property the whole assembly scheme rests on.
##
## Each module is built the way the editor builds a chunk, then exported through
## MSTDataHandler.export_chunk_data(), so the resulting resource is the same kind
## of thing a sculpted module would be, baked mesh and collision included.


const OPEN_N : int = 1
const OPEN_E : int = 2
const OPEN_S : int = 4
const OPEN_W : int = 8

const FLOOR_HEIGHT : float = 0.0
const WALL_HEIGHT : float = 6.0
# Half-width of a passage, measured in vertices either side of the centre line.
const PASSAGE_HALF_WIDTH : int = 3

var dimensions : Vector3i
var cell_size : Vector2
var modules_built : int = 0

var _terrain : MarchingSquaresTerrain
var _cache : Dictionary = {}


func _init(p_dimensions: Vector3i, p_cell_size: Vector2) -> void:
	dimensions = p_dimensions
	cell_size = p_cell_size


## Creates the factory terrain. Must be awaited before any module is requested,
## because _deferred_enter_tree() clears the chunks dictionary one frame later.
func open(parent: Node) -> void:
	_terrain = MarchingSquaresTerrain.new()
	_terrain.name = "ModuleFactory"
	_terrain.dimensions = dimensions
	_terrain.cell_size = cell_size
	_terrain.bake_grass = false
	_terrain.terrain_lod_enabled = false
	parent.add_child(_terrain)
	# _deferred_enter_tree() is deferred and then awaits another frame of its own
	# at runtime; let it finish before any module chunk is attached.
	for _i in range(3):
		await parent.get_tree().process_frame


func close() -> void:
	if is_instance_valid(_terrain):
		_terrain.free()
	_terrain = null


## Returns the baked module for this socket mask, building it on first request.
func module_for(mask: int) -> MSTChunkData:
	if _cache.has(mask):
		return _cache[mask] as MSTChunkData
	var chunk := _build_chunk(mask)
	var data := MSTDataHandler.export_chunk_data(chunk)
	_cache[mask] = data
	modules_built += 1
	return data


## Socket mask required at a slot in a rectangular layout: open towards every
## neighbour that exists, closed at the outer boundary.
static func mask_for_grid_slot(coords: Vector2i, size: Vector2i) -> int:
	var mask := 0
	if coords.y > 0:
		mask |= OPEN_N
	if coords.x < size.x - 1:
		mask |= OPEN_E
	if coords.y < size.y - 1:
		mask |= OPEN_S
	if coords.x > 0:
		mask |= OPEN_W
	return mask


func _build_chunk(mask: int) -> MarchingSquaresTerrainChunk:
	var chunk := MarchingSquaresTerrainChunk.new()
	chunk.terrain_system = _terrain
	chunk.name = "Module_%d" % mask
	chunk.grass_mode = MarchingSquaresTerrainChunk.GrassMode.GRASSLESS
	# Attached without add_chunk() so authoring does not pay the terrain-wide
	# collision refresh that phase 1 exists to measure. Mesh regeneration is left
	# to us as well, so the build stays synchronous and each module is finished
	# before the next one starts.
	MSTTestAssembler.attach_fast(_terrain, Vector2i(modules_built, 0), chunk)
	write_height_map(chunk, dimensions, mask)
	chunk.regenerate_all_cells(false)
	# regenerate_mesh() frees the collision body and queues an async rebuild.
	# Force it now so the exported module carries baked collision faces.
	chunk.rebuild_collision()
	return chunk


## Carves a module's floor plan into an existing chunk's height map: solid rock,
## a central room, and one corridor per open edge.
static func write_height_map(chunk: MarchingSquaresTerrainChunk, p_dimensions: Vector3i, mask: int) -> void:
	var mid_x := floori(p_dimensions.x / 2.0)
	var mid_z := floori(p_dimensions.z / 2.0)
	var lo_x := maxi(mid_x - PASSAGE_HALF_WIDTH, 0)
	var hi_x := mini(mid_x + PASSAGE_HALF_WIDTH, p_dimensions.x - 1)
	var lo_z := maxi(mid_z - PASSAGE_HALF_WIDTH, 0)
	var hi_z := mini(mid_z + PASSAGE_HALF_WIDTH, p_dimensions.z - 1)

	for z in range(p_dimensions.z):
		for x in range(p_dimensions.x):
			chunk.height_map[z][x] = WALL_HEIGHT

	if mask == 0:
		return

	# Central room.
	var room := PASSAGE_HALF_WIDTH + 2
	for z in range(maxi(mid_z - room, 0), mini(mid_z + room + 1, p_dimensions.z)):
		for x in range(maxi(mid_x - room, 0), mini(mid_x + room + 1, p_dimensions.x)):
			chunk.height_map[z][x] = FLOOR_HEIGHT

	if mask & OPEN_N:
		for z in range(0, mid_z + 1):
			for x in range(lo_x, hi_x + 1):
				chunk.height_map[z][x] = FLOOR_HEIGHT
	if mask & OPEN_S:
		for z in range(mid_z, p_dimensions.z):
			for x in range(lo_x, hi_x + 1):
				chunk.height_map[z][x] = FLOOR_HEIGHT
	if mask & OPEN_E:
		for x in range(mid_x, p_dimensions.x):
			for z in range(lo_z, hi_z + 1):
				chunk.height_map[z][x] = FLOOR_HEIGHT
	if mask & OPEN_W:
		for x in range(0, mid_x + 1):
			for z in range(lo_z, hi_z + 1):
				chunk.height_map[z][x] = FLOOR_HEIGHT
