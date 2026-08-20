@tool
extends RefCounted
class_name MSTTestAssembler
## Two ways of pasting baked modules into a live terrain at runtime.
##
## "naive" goes through MarchingSquaresTerrain.add_chunk() exactly as written.
## "fast" replicates add_chunk() minus _schedule_collision_refresh(), which at
## runtime skips its debounce and rebuilds the collision proxy for EVERY chunk
## already in the terrain (see MSTCollisionController.schedule_refresh). The pair
## exists to measure whether that call makes assembly quadratic in chunk count.
##
## The fast path is a measurement variant, not a proposed patch to the addon.


## Creates a terrain and waits for it to finish initialising.
##
## _deferred_enter_tree() is call_deferred from _enter_tree(), and at runtime it
## then awaits another process frame of its own before it walks the chunks
## dictionary and calls initialize_terrain() on everything it finds. Letting it
## run to completion while the terrain is still empty keeps it from
## re-initialising pasted chunks in the middle of a measurement, and stops it
## resuming on a freed instance when the caller disposes of the terrain.
static func make_terrain(dimensions: Vector3i, cell_size: Vector2, parent: Node, node_name: String) -> MarchingSquaresTerrain:
	var terrain := MarchingSquaresTerrain.new()
	terrain.name = node_name
	terrain.dimensions = dimensions
	terrain.cell_size = cell_size
	terrain.bake_grass = false
	terrain.terrain_lod_enabled = false
	parent.add_child(terrain)
	for _i in range(3):
		await parent.get_tree().process_frame
	return terrain


static func assemble_naive(terrain: MarchingSquaresTerrain, layout: Dictionary, factory: MSTTestModules) -> void:
	for coords: Vector2i in layout.keys():
		var chunk := _prepare_chunk(terrain, int(layout[coords]), factory)
		terrain.add_chunk(coords, chunk, null, false)


static func assemble_fast(terrain: MarchingSquaresTerrain, layout: Dictionary, factory: MSTTestModules) -> void:
	for coords: Vector2i in layout.keys():
		var chunk := _prepare_chunk(terrain, int(layout[coords]), factory)
		attach_fast(terrain, coords, chunk)


static func _prepare_chunk(terrain: MarchingSquaresTerrain, mask: int, factory: MSTTestModules) -> MarchingSquaresTerrainChunk:
	var chunk := MarchingSquaresTerrainChunk.new()
	# import_chunk_data reads terrain_system.storage_mode and bake_*, so the link
	# has to exist before the import runs.
	chunk.terrain_system = terrain
	chunk.grass_mode = MarchingSquaresTerrainChunk.GrassMode.GRASSLESS
	MSTDataHandler.import_chunk_data(chunk, factory.module_for(mask))
	return chunk


## Mirrors add_chunk() without the terrain-wide collision refresh, the navmesh
## invalidation, the owner walk and the visibility pass. Callers that want
## collision are responsible for calling rebuild_collision() themselves.
static func attach_fast(terrain: MarchingSquaresTerrain, coords: Vector2i, chunk: MarchingSquaresTerrainChunk) -> void:
	chunk.chunk_coords = coords
	chunk._skip_save_on_exit = false
	if String(chunk.name).is_empty():
		chunk.name = "Chunk %s" % str(coords)
	terrain.add_child(chunk)
	terrain.chunks[coords] = chunk
	chunk.position = Vector3(
		coords.x * ((terrain.dimensions.x - 1) * terrain.cell_size.x),
		0,
		coords.y * ((terrain.dimensions.z - 1) * terrain.cell_size.y)
	)
	chunk.initialize_terrain(false)


## A rectangular layout whose sockets agree across every shared edge.
static func build_layout(size: Vector2i) -> Dictionary:
	var layout : Dictionary = {}
	for z in range(size.y):
		for x in range(size.x):
			var coords := Vector2i(x, z)
			layout[coords] = MSTTestModules.mask_for_grid_slot(coords, size)
	return layout


## Number of chunks that ended up with a collision body attached.
static func count_chunks_with_collision(terrain: MarchingSquaresTerrain) -> int:
	var count := 0
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		if not is_instance_valid(chunk):
			continue
		for child in chunk.get_children():
			if child is StaticBody3D:
				count += 1
				break
	return count


## Number of chunks that ended up with renderable geometry.
static func count_chunks_with_mesh(terrain: MarchingSquaresTerrain) -> int:
	var count := 0
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		if not is_instance_valid(chunk):
			continue
		if chunk.mesh != null or not chunk._mesh_tiles.is_empty():
			count += 1
	return count
