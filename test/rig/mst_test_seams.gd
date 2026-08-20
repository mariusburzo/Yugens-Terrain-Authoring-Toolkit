extends RefCounted
class_name MSTTestSeams
## Seam checks for a terrain assembled from pasted baked modules.
##
## add_new_chunk() copies a neighbour's border row into a freshly created blank
## chunk, but nothing repairs the seam when a baked chunk is pasted in. These
## checks look for the two ways that can go wrong: source height rows that
## disagree, and mesh borders that disagree even when the heights match
## (T-junctions from differing marching-squares cases either side of the seam).


const VERTEX_EPSILON : float = 0.01


## Compares the shared height rows of every adjacent chunk pair.
static func check_height_rows(terrain: MarchingSquaresTerrain) -> Dictionary:
	var pairs := 0
	var mismatched_vertices := 0
	var stride_x := terrain.dimensions.x - 1
	var stride_z := terrain.dimensions.z - 1

	for coords: Vector2i in terrain.chunks.keys():
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[coords]
		var east : MarchingSquaresTerrainChunk = terrain.chunks.get(coords + Vector2i(1, 0))
		if east != null:
			pairs += 1
			for z in range(terrain.dimensions.z):
				if not is_equal_approx(float(chunk.height_map[z][stride_x]), float(east.height_map[z][0])):
					mismatched_vertices += 1
		var south : MarchingSquaresTerrainChunk = terrain.chunks.get(coords + Vector2i(0, 1))
		if south != null:
			pairs += 1
			for x in range(terrain.dimensions.x):
				if not is_equal_approx(float(chunk.height_map[stride_z][x]), float(south.height_map[0][x])):
					mismatched_vertices += 1

	return {"pairs": pairs, "mismatched_vertices": mismatched_vertices}


## Compares the actual mesh borders of every adjacent chunk pair. A vertex on
## one side with no counterpart on the other is a crack or a T-junction.
static func check_mesh_borders(terrain: MarchingSquaresTerrain) -> Dictionary:
	var pairs := 0
	var unmatched := 0
	var checked := 0

	for coords: Vector2i in terrain.chunks.keys():
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[coords]
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var neighbour : MarchingSquaresTerrainChunk = terrain.chunks.get(coords + offset)
			if neighbour == null:
				continue
			pairs += 1
			var axis_is_x : bool = offset == Vector2i(1, 0)
			var seam_world : float
			if axis_is_x:
				seam_world = neighbour.global_position.x
			else:
				seam_world = neighbour.global_position.z
			var near := _border_vertices(chunk, axis_is_x, seam_world)
			var far := _border_vertices(neighbour, axis_is_x, seam_world)
			checked += near.size() + far.size()
			for key in near:
				if not far.has(key):
					unmatched += 1
			for key in far:
				if not near.has(key):
					unmatched += 1

	return {"pairs": pairs, "vertices_checked": checked, "unmatched": unmatched}


# Collects the mesh vertices of a chunk that sit on the given world-space seam
# plane, keyed so the two sides can be compared directly.
static func _border_vertices(chunk: MarchingSquaresTerrainChunk, axis_is_x: bool, seam_world: float) -> Dictionary:
	var found : Dictionary = {}
	for tile_coords in chunk._mesh_tiles:
		var tile : MeshInstance3D = chunk._mesh_tiles[tile_coords]
		if not is_instance_valid(tile) or tile.mesh == null:
			continue
		var transform := tile.global_transform
		for surface_idx in range(tile.mesh.get_surface_count()):
			var arrays : Array = tile.mesh.surface_get_arrays(surface_idx)
			if arrays.is_empty():
				continue
			var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var world : Vector3 = transform * vertex
				var distance : float = absf(world.x - seam_world) if axis_is_x else absf(world.z - seam_world)
				if distance > VERTEX_EPSILON:
					continue
				found[_vertex_key(world)] = true
	return found


static func _vertex_key(world: Vector3) -> String:
	return "%d,%d,%d" % [roundi(world.x * 100.0), roundi(world.y * 100.0), roundi(world.z * 100.0)]
