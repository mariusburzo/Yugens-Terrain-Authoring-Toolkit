extends RefCounted
class_name MSTTestThreadedDig
## A dig split across a worker thread, following the pattern the addon already
## uses in begin_deferred_initial_build().
##
## Main thread does the height writes, caches each chunk's transform (a worker
## must never read global_position), and snapshots the dirty tile set. The worker
## does everything that is pure computation: cell geometry, mesh surface arrays,
## the collision proxy and the nav faces. Main thread then publishes.
##
## The collision proxy is *swapped* rather than rebuilt. regenerate_mesh() frees
## every StaticBody3D and queues an async rebuild that runs one chunk per frame,
## which leaves the chunk with no collision in between. Assigning a new shape to
## the existing CollisionShape3D keeps the old one live until the new one is
## ready, so there is no window where the player can fall through.


var prologue_msec : float = 0.0
var worker_msec : float = 0.0
var publish_msec : float = 0.0
## Time the main thread spent blocked in wait_to_finish().
##
## Measured separately because it is the number that catches a caller polling
## is_running() wrongly. Poll correctly and this is ~0; exit the loop early and
## the whole worker cost lands here instead, where it would otherwise be
## invisible - publish_msec starts its clock after the join, not before.
var join_msec : float = 0.0
## Cost of rebuilding LOD proxies the dig invalidated. -1 when the addon build
## has no LOD controller at all.
var lod_msec : float = 0.0
var frames_in_flight : int = 0
var frames_without_collision : int = 0

var _terrain : MarchingSquaresTerrain
var _chunks : Array = []
var _dirty_tiles : Dictionary = {}
var _built_meshes : Dictionary = {}
var _built_shapes : Dictionary = {}
var _built_navmeshes : Dictionary = {}
# Resolved on the main thread during start(). The worker cannot call get_node*,
# so which chunks own a nav region has to be settled before it starts.
var _nav_regions : Dictionary = {}
var _thread : Thread
var _lod_invalidated : bool = false


## Applies the height writes and starts the worker. Returns the chunks affected.
func start(terrain: MarchingSquaresTerrain, origin: Vector2i, size: Vector2i, height: float) -> int:
	_terrain = terrain
	var start_usec := Time.get_ticks_usec()

	var affected : Dictionary = {}
	for gz in range(origin.y, origin.y + size.y):
		for gx in range(origin.x, origin.x + size.x):
			for owner in MSTTestDig.vertex_owners(terrain, gx, gz):
				var chunk : MarchingSquaresTerrainChunk = owner["chunk"]
				var local : Vector2i = owner["local"]
				chunk.draw_height(local.x, local.y, height)
				affected[owner["coords"]] = chunk

	for chunk: MarchingSquaresTerrainChunk in affected.values():
		# Must happen on the main thread: the worker reads global_position_cached.
		chunk._cache_global_position_for_thread()
		_dirty_tiles[chunk] = chunk._dirty_mesh_tiles.keys()
		chunk._dirty_mesh_tiles.clear()
		# Node lookups are main-thread only, so resolve the region now and hand
		# the worker a plain reference.
		var region := chunk.get_node_or_null(MSTTestNav.REGION_NAME) as NavigationRegion3D
		if region != null:
			_nav_regions[chunk] = region
		_chunks.append(chunk)

	prologue_msec = (Time.get_ticks_usec() - start_usec) / 1000.0
	_thread = Thread.new()
	_thread.start(_run_worker)
	return _chunks.size()


func is_running() -> bool:
	return _thread != null and _thread.is_alive()


## Coordinates of every chunk this dig touched, for a nav builder that works in
## chunk coordinates rather than node references.
func affected_coords() -> Array:
	var coords : Array = []
	for chunk: MarchingSquaresTerrainChunk in _chunks:
		if is_instance_valid(chunk):
			coords.append(chunk.chunk_coords)
	return coords


## Everything this dig actually cost the frames it ran on.
func main_thread_msec() -> float:
	return prologue_msec + join_msec + publish_msec


## Called once per frame while the job is in flight, to prove the chunk keeps its
## collision for the whole duration.
func sample_collision() -> void:
	frames_in_flight += 1
	for chunk: MarchingSquaresTerrainChunk in _chunks:
		if not has_collision(chunk):
			frames_without_collision += 1
			return


func _run_worker() -> void:
	var start_usec := Time.get_ticks_usec()
	var custom_format := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	custom_format |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT
	custom_format |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT

	for chunk: MarchingSquaresTerrainChunk in _chunks:
		# Same bracketing regenerate_mesh() uses around cell generation.
		chunk._collect_mesh_arrays = false
		chunk.generate_terrain_cells(false)
		chunk._collect_mesh_arrays = true

		var meshes : Dictionary = {}
		for tile_coords: Vector2i in _dirty_tiles[chunk]:
			var arrays : Array = chunk._build_mesh_surface_arrays_for_tile(tile_coords)
			if arrays.is_empty():
				meshes[tile_coords] = null
				continue
			var tile_mesh := ArrayMesh.new()
			tile_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, custom_format)
			meshes[tile_coords] = tile_mesh
		_built_meshes[chunk] = meshes

		_built_shapes[chunk] = chunk._create_simplified_proxy_collision_shape()

		# Only chunks that already carry a region need a new navmesh.
		if _nav_regions.has(chunk):
			_built_navmeshes[chunk] = _build_navmesh(chunk)

	worker_msec = (Time.get_ticks_usec() - start_usec) / 1000.0


# Merged rectangles, not one polygon per triangle. A per-triangle rebuild would
# silently undo the merge for whichever chunk was just dug, and a cave with one
# dense chunk in it stops pathing.
func _build_navmesh(chunk: MarchingSquaresTerrainChunk) -> NavigationMesh:
	return MSTTestNav.build_merged_navmesh(chunk, _terrain)["navmesh"]


## Joins the worker and applies everything that has to touch the scene tree.
func publish() -> void:
	var join_start := Time.get_ticks_usec()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	join_msec = (Time.get_ticks_usec() - join_start) / 1000.0
	var start_usec := Time.get_ticks_usec()

	for chunk: MarchingSquaresTerrainChunk in _chunks:
		chunk._baked_mesh_is_complete = false
		var meshes : Dictionary = _built_meshes.get(chunk, {})
		for tile_coords: Vector2i in meshes.keys():
			var tile := chunk._get_or_create_mesh_tile(tile_coords)
			var tile_mesh : ArrayMesh = meshes[tile_coords]
			if tile_mesh != null and chunk._chunk_surface_material != null:
				tile_mesh.surface_set_material(0, chunk._chunk_surface_material)
			tile.mesh = tile_mesh

		var shape : ConcavePolygonShape3D = _built_shapes.get(chunk)
		if shape != null:
			swap_collision_shape(chunk, shape)

		var nav_mesh : NavigationMesh = _built_navmeshes.get(chunk)
		var region : NavigationRegion3D = _nav_regions.get(chunk)
		if nav_mesh != null and is_instance_valid(region):
			region.navigation_mesh = nav_mesh

		# regenerate_mesh() is what normally tells the LOD controller a chunk
		# changed, and this deliberately does not call it, so the distant proxy
		# would keep rendering pre-dig terrain.
		#
		# Invalidating alone is not enough at runtime, and is worse than doing
		# nothing: invalidate_chunk() frees the proxy and only raises a pending
		# flag, and the sole thing that acts on that flag sits inside
		# MarchingSquaresTerrain._process()'s `if is_editor()` branch. Freeing
		# without rebuilding leaves the chunk rendering nothing at all past
		# terrain_lod_start_distance, because _configure_proxy_visibility() gives
		# its real tiles a visibility_range_end of exactly that distance. So the
		# rebuild is driven explicitly below.
		if _terrain != null and _terrain.has_method("_invalidate_terrain_lod_chunk"):
			_terrain._invalidate_terrain_lod_chunk(chunk.chunk_coords)
			_lod_invalidated = true

	# One apply() for the whole batch: it walks the chunks and builds only the
	# proxies that are missing, so this rebuilds exactly the ones just freed.
	if _lod_invalidated:
		lod_msec = rebuild_lod_proxies(_terrain)

	publish_msec = (Time.get_ticks_usec() - start_usec) / 1000.0


## Rebuilds any LOD proxy the terrain is missing, and reports what it cost.
##
## Nothing does this at runtime on its own - see the note in publish(). Returns
## -1.0 when the terrain has no LOD controller, so an older addon build is told
## apart from a build where the work was free.
static func rebuild_lod_proxies(terrain) -> float:
	if terrain == null or not ("_lod_controller" in terrain):
		return -1.0
	var controller = terrain._lod_controller
	if controller == null:
		return -1.0
	var start_usec := Time.get_ticks_usec()
	controller.apply()
	return (Time.get_ticks_usec() - start_usec) / 1000.0


## Live TerrainLODProxy nodes across the terrain, which is what a dig can
## silently take away.
static func count_lod_proxies(terrain) -> int:
	var count := 0
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		if is_instance_valid(chunk) and chunk.get_node_or_null("TerrainLODProxy") != null:
			count += 1
	return count


## Replaces the shape on the existing body instead of freeing and rebuilding it.
static func swap_collision_shape(chunk: MarchingSquaresTerrainChunk, shape: ConcavePolygonShape3D) -> bool:
	for child in chunk.get_children():
		if child is StaticBody3D:
			for sub in child.get_children():
				if sub is CollisionShape3D:
					sub.shape = shape
					return true
	# No body yet (first build); fall back to the addon's own construction.
	chunk._create_collision_body_from_shape(shape)
	return false


static func has_collision(chunk: MarchingSquaresTerrainChunk) -> bool:
	for child in chunk.get_children():
		if child is StaticBody3D:
			for sub in child.get_children():
				if sub is CollisionShape3D and sub.shape != null:
					return true
	return false


## Rebuilds cell_geometry for a chunk on a worker thread without republishing any
## mesh tiles, so a pasted chunk can be warmed without touching how it looks.
## This is rebuild_cell_geometry_for_grass() with the transform caching hoisted
## out to the caller, because that part has to run on the main thread.
static func warm_chunks(chunks: Array) -> float:
	for chunk: MarchingSquaresTerrainChunk in chunks:
		chunk._cache_global_position_for_thread()
		var expected_z := chunk.dimensions.z - 1
		var expected_x := chunk.dimensions.x - 1
		chunk.needs_update = []
		for z in range(expected_z):
			chunk.needs_update.append([])
			for x in range(expected_x):
				chunk.needs_update[z].append(true)

	var start_usec := Time.get_ticks_usec()
	var thread := Thread.new()
	thread.start(func():
		for chunk: MarchingSquaresTerrainChunk in chunks:
			chunk._collect_mesh_arrays = false
			chunk.generate_terrain_cells(false)
			chunk._collect_mesh_arrays = true
	)
	thread.wait_to_finish()
	return (Time.get_ticks_usec() - start_usec) / 1000.0
