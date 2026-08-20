extends RefCounted
class_name MSTTestDig
## Runtime terrain mutation, with the border case handled explicitly.
##
## A vertex on a chunk border exists in the height maps of both chunks: index
## dimensions.x - 1 of one chunk is index 0 of the next. draw_height() only
## writes the chunk it is called on, so a border dig has to be applied to every
## chunk that owns the vertex. write_all = false reproduces the bug on purpose
## so the rig can show the difference.


## Every (chunk, local vertex) pair that shares the global vertex (gx, gz).
static func vertex_owners(terrain: MarchingSquaresTerrain, gx: int, gz: int) -> Array:
	var stride_x := terrain.dimensions.x - 1
	var stride_z := terrain.dimensions.z - 1
	var chunk_x := floori(float(gx) / float(stride_x))
	var chunk_z := floori(float(gz) / float(stride_z))
	var local_x := gx - chunk_x * stride_x
	var local_z := gz - chunk_z * stride_z

	var candidates : Array = []
	var x_slots := [[chunk_x, local_x]]
	if local_x == 0:
		x_slots.append([chunk_x - 1, stride_x])
	var z_slots := [[chunk_z, local_z]]
	if local_z == 0:
		z_slots.append([chunk_z - 1, stride_z])

	for x_slot in x_slots:
		for z_slot in z_slots:
			var coords := Vector2i(int(x_slot[0]), int(z_slot[0]))
			if not terrain.chunks.has(coords):
				continue
			candidates.append({
				"coords": coords,
				"chunk": terrain.chunks[coords],
				"local": Vector2i(int(x_slot[1]), int(z_slot[1])),
			})
	return candidates


## Lowers or raises a rectangle of vertices and rebuilds every affected chunk,
## timing the three stages separately. Returns milliseconds per stage.
static func dig_area(
		terrain: MarchingSquaresTerrain,
		origin: Vector2i,
		size: Vector2i,
		height: float,
		write_all: bool
) -> Dictionary:
	var affected : Dictionary = {}

	var write_start := Time.get_ticks_usec()
	for gz in range(origin.y, origin.y + size.y):
		for gx in range(origin.x, origin.x + size.x):
			var owners := vertex_owners(terrain, gx, gz)
			if owners.is_empty():
				continue
			if not write_all:
				owners = [owners[0]]
			for owner in owners:
				var chunk : MarchingSquaresTerrainChunk = owner["chunk"]
				var local : Vector2i = owner["local"]
				chunk.draw_height(local.x, local.y, height)
				affected[owner["coords"]] = chunk
	var write_msec := (Time.get_ticks_usec() - write_start) / 1000.0

	var mesh_start := Time.get_ticks_usec()
	for chunk: MarchingSquaresTerrainChunk in affected.values():
		chunk.regenerate_mesh(false)
	var mesh_msec := (Time.get_ticks_usec() - mesh_start) / 1000.0

	# regenerate_mesh() frees the collision body and queues an async rebuild that
	# runs one chunk per frame, so the chunk is collision-less until then.
	# Rebuilding inline closes that window and makes the cost measurable.
	var collision_start := Time.get_ticks_usec()
	for chunk: MarchingSquaresTerrainChunk in affected.values():
		chunk.rebuild_collision()
	var collision_msec := (Time.get_ticks_usec() - collision_start) / 1000.0

	var nav_start := Time.get_ticks_usec()
	var nav_faces := 0
	for chunk: MarchingSquaresTerrainChunk in affected.values():
		var permission : Variant = null
		if terrain.navmesh_painting_enabled:
			permission = chunk.navmesh_permission
		nav_faces += floori(chunk.get_nav_walkable_faces_for_permission(terrain.nav_max_slope, permission).size() / 3.0)
	var nav_msec := (Time.get_ticks_usec() - nav_start) / 1000.0

	return {
		"chunks": affected.keys(),
		"chunks_affected": affected.size(),
		"write_msec": write_msec,
		"mesh_msec": mesh_msec,
		"collision_msec": collision_msec,
		"nav_msec": nav_msec,
		"nav_faces": nav_faces,
		"total_msec": write_msec + mesh_msec + collision_msec + nav_msec,
	}


## Global vertex index of the border between chunk (x, z) and its east neighbour.
static func east_border_vertex_x(terrain: MarchingSquaresTerrain, chunk_x: int) -> int:
	return (chunk_x + 1) * (terrain.dimensions.x - 1)
