extends RefCounted
class_name MSTTestNav
## One NavigationRegion3D per chunk, built from the chunk's own walkable faces.
##
## get_nav_walkable_faces_for_permission() returns chunk-local vertices (the
## addon's own builder multiplies them by chunk.global_transform before merging),
## so parenting the region to the chunk needs no transform work.
##
## Chunks either side of a seam snap their border vertices to exactly the same
## coordinates via _snap_nav_vertex_to_chunk_bounds(), so neighbouring regions
## should connect through the navigation map's edge connections with no manual
## links. The path test below is what decides whether that actually holds.


const REGION_NAME : String = "ChunkNav"
const WELD_PRECISION : float = 100.0


## Face extraction reads cell_geometry, which is empty on chunks hydrated from a
## baked MSTChunkData. Returns the face count without rebuilding anything.
static func walkable_face_count(terrain: MarchingSquaresTerrain, chunk: MarchingSquaresTerrainChunk) -> int:
	var permission : Variant = null
	if terrain.navmesh_painting_enabled:
		permission = chunk.navmesh_permission
	return floori(chunk.get_nav_walkable_faces_for_permission(terrain.nav_max_slope, permission).size() / 3.0)


## Rebuilds cell geometry only if the chunk has none, and reports whether it had to.
static func ensure_cell_geometry(chunk: MarchingSquaresTerrainChunk) -> bool:
	if not chunk.cell_geometry.is_empty():
		return false
	chunk.regenerate_all_cells(false)
	return true


static func build_region(terrain: MarchingSquaresTerrain, chunk: MarchingSquaresTerrainChunk) -> Dictionary:
	var permission : Variant = null
	if terrain.navmesh_painting_enabled:
		permission = chunk.navmesh_permission
	var faces := chunk.get_nav_walkable_faces_for_permission(terrain.nav_max_slope, permission)
	var existing := chunk.get_node_or_null(REGION_NAME) as NavigationRegion3D
	if faces.is_empty():
		# A chunk that lost every walkable face must lose its polygons too,
		# otherwise a rebuilt region silently keeps stale navigation.
		if existing != null:
			existing.navigation_mesh = NavigationMesh.new()
		return {"polygons": 0, "vertices": 0, "region": existing}

	# Welding matters: polygons that share an edge by index are connected inside
	# the region, which keeps the navmesh small and the connectivity unambiguous.
	var vertices := PackedVector3Array()
	var lookup : Dictionary = {}
	var nav_mesh := NavigationMesh.new()
	var polygons : Array[PackedInt32Array] = []
	for index in range(0, faces.size(), 3):
		var polygon := PackedInt32Array()
		for offset in range(3):
			polygon.append(_weld(lookup, vertices, faces[index + offset]))
		polygons.append(polygon)
	nav_mesh.set_vertices(vertices)
	for polygon in polygons:
		nav_mesh.add_polygon(polygon)

	var region := existing
	if region == null:
		region = NavigationRegion3D.new()
		region.name = REGION_NAME
		chunk.add_child(region)
	# Defensive: this is the default, but a region with edge connections switched
	# off would silently never stitch to its neighbours.
	if "use_edge_connections" in region:
		region.use_edge_connections = true
	region.navigation_mesh = nav_mesh
	return {"polygons": polygons.size(), "vertices": vertices.size(), "region": region}


static func _weld(lookup: Dictionary, vertices: PackedVector3Array, vertex: Vector3) -> int:
	var key := "%d,%d,%d" % [
		roundi(vertex.x * WELD_PRECISION),
		roundi(vertex.y * WELD_PRECISION),
		roundi(vertex.z * WELD_PRECISION),
	]
	if lookup.has(key):
		return int(lookup[key])
	var index := vertices.size()
	vertices.append(vertex)
	lookup[key] = index
	return index


static func build_all_regions(terrain: MarchingSquaresTerrain) -> Dictionary:
	var regions := 0
	var polygons := 0
	var regenerated := 0
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		if not is_instance_valid(chunk):
			continue
		if ensure_cell_geometry(chunk):
			regenerated += 1
		var result := build_region(terrain, chunk)
		if int(result["polygons"]) > 0:
			regions += 1
			polygons += int(result["polygons"])
	return {"regions": regions, "polygons": polygons, "chunks_regenerated": regenerated}


## Asks the navigation map for a path and reports whether it actually arrives.
##
## The map is force-updated first. Waiting a couple of physics frames is not
## enough: region syncing happens on the navigation server, and these regions
## carry thousands of polygons each, so a query issued too early comes back with
## an empty path that looks exactly like "unreachable".
static func try_path(terrain: MarchingSquaresTerrain, from: Vector3, to: Vector3) -> Dictionary:
	var map := terrain.get_world_3d().navigation_map
	if NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.map_force_update(map)
	var regions := NavigationServer3D.map_get_regions(map).size()
	var margin := NavigationServer3D.map_get_edge_connection_margin(map)
	var path := NavigationServer3D.map_get_path(map, from, to, true)
	if path.is_empty():
		return {
			"reached": false,
			"points": 0,
			"end_distance": INF,
			"end": Vector3.INF,
			"regions": regions,
			"margin": margin,
			"forced": NavigationServer3D.has_method("map_force_update"),
		}
	var end_point := path[path.size() - 1]
	var end_distance := end_point.distance_to(to)
	return {
		"reached": end_distance < maxf(terrain.cell_size.x, terrain.cell_size.y) * 2.0,
		"points": path.size(),
		"end_distance": end_distance,
		"end": end_point,
		"regions": regions,
		"margin": margin,
		"forced": NavigationServer3D.has_method("map_force_update"),
	}


## Cost of a synchronous map update on its own. This is the part that lands on
## the main thread after a region changes, so it is the number that decides
## whether a dig in a large cave stalls the frame.
static func force_update_msec(terrain: MarchingSquaresTerrain) -> float:
	if not NavigationServer3D.has_method("map_force_update"):
		return -1.0
	var map := terrain.get_world_3d().navigation_map
	var start_usec := Time.get_ticks_usec()
	NavigationServer3D.map_force_update(map)
	return (Time.get_ticks_usec() - start_usec) / 1000.0


## Where the navigation map snaps a world point. The y tells you which walkable
## layer the query landed on: cave floor, or the flat top of the rock.
static func closest_point(terrain: MarchingSquaresTerrain, point: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(terrain.get_world_3d().navigation_map, point)


## Walks the cave one chunk at a time and reports the first hop that cannot be
## reached. A full-diagonal failure says nothing about where the break is; this
## localises it to a single seam, or shows every hop works and only the long
## query fails, which would point at the pathfinder rather than the geometry.
static func first_unreachable_hop(terrain: MarchingSquaresTerrain, from: Vector3, hops: Array) -> Dictionary:
	for index in range(hops.size()):
		var coords : Vector2i = hops[index]
		var target := chunk_centre(terrain, coords) + terrain.position
		var result := try_path(terrain, from, target)
		if not bool(result["reached"]):
			return {
				"index": index,
				"coords": coords,
				"end_distance": result["end_distance"],
				"points": result["points"],
			}
	return {"index": -1, "coords": Vector2i.ZERO, "end_distance": 0.0, "points": 0}


## Cost of one path query on an already-synced map.
static func query_msec(terrain: MarchingSquaresTerrain, from: Vector3, to: Vector3) -> Dictionary:
	var map := terrain.get_world_3d().navigation_map
	var start_usec := Time.get_ticks_usec()
	var path := NavigationServer3D.map_get_path(map, from, to, true)
	return {
		"msec": (Time.get_ticks_usec() - start_usec) / 1000.0,
		"points": path.size(),
	}


## Retries the query once per physics frame until it succeeds or the budget runs
## out, reporting how many attempts it took.
##
## This is what separates the two explanations for a failed path: navigation
## server sync latency, which resolves after some number of frames, and a genuine
## missing edge connection, which never does.
static func try_path_until(terrain: MarchingSquaresTerrain, from: Vector3, to: Vector3, tree: SceneTree, max_frames: int) -> Dictionary:
	var result : Dictionary = {}
	for attempt in range(max_frames):
		result = try_path(terrain, from, to)
		result["attempts"] = attempt + 1
		if bool(result["reached"]):
			return result
		await tree.physics_frame
	return result


## How far the end of a path stopped from the seam plane between two chunks.
## A value near zero means the path reached the seam and could not cross it,
## which is a connection failure rather than an unreachable target.
static func distance_from_seam(terrain: MarchingSquaresTerrain, path_end: Vector3, border_chunk_x: int) -> float:
	var seam_world := terrain.global_position.x + float(border_chunk_x) * float(terrain.dimensions.x - 1) * terrain.cell_size.x
	return absf(path_end.x - seam_world)


## World-space centre of a chunk's central room, a reliable spot to path from.
static func chunk_centre(terrain: MarchingSquaresTerrain, coords: Vector2i) -> Vector3:
	var stride_x := float(terrain.dimensions.x - 1)
	var stride_z := float(terrain.dimensions.z - 1)
	return Vector3(
		(coords.x * stride_x + stride_x * 0.5) * terrain.cell_size.x,
		MSTTestModules.FLOOR_HEIGHT,
		(coords.y * stride_z + stride_z * 0.5) * terrain.cell_size.y
	)


#region merged navmesh

## Builds a chunk's navmesh as merged rectangles instead of one polygon per
## triangle.
##
## The addon's own collision proxy already does this for physics: walk the cell
## grid, take every cell whose four corners share a height, and greedily grow
## rectangles over runs of them. Cells that straddle a height change are dropped,
## which trims one cell of walkable surface along every wall — close to the agent
## radius erosion a Recast bake would have applied anyway.
static func build_merged_navmesh(chunk: MarchingSquaresTerrainChunk) -> Dictionary:
	var dims : Vector3i = chunk.dimensions
	var cell_size : Vector2 = chunk.cell_size
	var cells_x := dims.x - 1
	var cells_z := dims.z - 1
	if cells_x <= 0 or cells_z <= 0:
		return {"navmesh": NavigationMesh.new(), "polygons": 0}

	# Height of each flat cell, or NAN where the cell is not flat.
	var flat : Array = []
	for z in range(cells_z):
		var row : PackedFloat32Array = PackedFloat32Array()
		row.resize(cells_x)
		for x in range(cells_x):
			row[x] = _flat_cell_height(chunk, x, z)
		flat.append(row)

	var used : Array = []
	for z in range(cells_z):
		var row : PackedByteArray = PackedByteArray()
		row.resize(cells_x)
		used.append(row)

	var vertices := PackedVector3Array()
	var lookup : Dictionary = {}
	var polygons : Array[PackedInt32Array] = []

	for z in range(cells_z):
		for x in range(cells_x):
			if used[z][x] == 1:
				continue
			var height : float = flat[z][x]
			if is_nan(height):
				continue

			# Grow east while the height matches, then south while the whole run matches.
			var x_end := x
			while x_end + 1 < cells_x and used[z][x_end + 1] == 0 and _same_height(flat[z][x_end + 1], height):
				x_end += 1
			var z_end := z
			while z_end + 1 < cells_z:
				var row_matches := true
				for scan_x in range(x, x_end + 1):
					if used[z_end + 1][scan_x] == 1 or not _same_height(flat[z_end + 1][scan_x], height):
						row_matches = false
						break
				if not row_matches:
					break
				z_end += 1

			for mark_z in range(z, z_end + 1):
				for mark_x in range(x, x_end + 1):
					used[mark_z][mark_x] = 1

			polygons.append(_rectangle_perimeter(lookup, vertices, x, x_end, z, z_end, height, cell_size))

	var nav_mesh := NavigationMesh.new()
	nav_mesh.set_vertices(vertices)
	for polygon in polygons:
		nav_mesh.add_polygon(polygon)
	return {"navmesh": nav_mesh, "polygons": polygons.size()}


static func _flat_cell_height(chunk: MarchingSquaresTerrainChunk, x: int, z: int) -> float:
	var h00 := float(chunk.height_map[z][x])
	var h01 := float(chunk.height_map[z][x + 1])
	var h10 := float(chunk.height_map[z + 1][x])
	var h11 := float(chunk.height_map[z + 1][x + 1])
	if _same_height(h00, h01) and _same_height(h00, h10) and _same_height(h00, h11):
		return h00
	return NAN


static func _same_height(a: float, b: float) -> bool:
	if is_nan(a) or is_nan(b):
		return false
	return absf(a - b) < 0.01


## Emits a rectangle's outline with a vertex at every grid step, wound so the
## polygon normal points up.
##
## Four corners would be fewer vertices but would not connect: Godot matches
## polygon edges by both endpoints, so one long edge never pairs with the two
## shorter ones facing it. Stepping the perimeter at grid resolution guarantees
## every edge is a unit segment that its neighbour also owns.
static func _rectangle_perimeter(
		lookup: Dictionary,
		vertices: PackedVector3Array,
		x0: int,
		x1: int,
		z0: int,
		z1: int,
		height: float,
		cell_size: Vector2
) -> PackedInt32Array:
	var polygon := PackedInt32Array()
	var vx0 := x0
	var vx1 := x1 + 1
	var vz0 := z0
	var vz1 := z1 + 1

	# West edge going south, then south edge going east, then east going north,
	# then north going west. Each run omits its final point, which the next run
	# contributes.
	for vz in range(vz0, vz1):
		polygon.append(_weld(lookup, vertices, Vector3(float(vx0) * cell_size.x, height, float(vz) * cell_size.y)))
	for vx in range(vx0, vx1):
		polygon.append(_weld(lookup, vertices, Vector3(float(vx) * cell_size.x, height, float(vz1) * cell_size.y)))
	for vz in range(vz1, vz0, -1):
		polygon.append(_weld(lookup, vertices, Vector3(float(vx1) * cell_size.x, height, float(vz) * cell_size.y)))
	for vx in range(vx1, vx0, -1):
		polygon.append(_weld(lookup, vertices, Vector3(float(vx) * cell_size.x, height, float(vz0) * cell_size.y)))
	return polygon


## Paths between the centres of every directly adjacent chunk pair.
##
## The hop ladder walks outward from one corner, so a failure there could mean a
## broken seam or simply that long paths fail. This asks each seam on its own.
static func adjacent_pair_failures(terrain: MarchingSquaresTerrain, grid: int) -> Dictionary:
	var tested := 0
	var failed := 0
	var first_failure := ""
	for z in range(grid):
		for x in range(grid):
			for offset: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var other := Vector2i(x, z) + offset
				if other.x >= grid or other.y >= grid:
					continue
				tested += 1
				var from := chunk_centre(terrain, Vector2i(x, z)) + terrain.position
				var to := chunk_centre(terrain, other) + terrain.position
				var result := try_path(terrain, from, to)
				if not bool(result["reached"]):
					failed += 1
					if first_failure.is_empty():
						first_failure = "%s->%s ended %.2f m short" % [str(Vector2i(x, z)), str(other), result["end_distance"]]
	return {"tested": tested, "failed": failed, "first": first_failure}


static func build_merged_region(terrain: MarchingSquaresTerrain, chunk: MarchingSquaresTerrainChunk) -> int:
	var result := build_merged_navmesh(chunk)
	var region := chunk.get_node_or_null(REGION_NAME) as NavigationRegion3D
	if region == null:
		region = NavigationRegion3D.new()
		region.name = REGION_NAME
		chunk.add_child(region)
	if "use_edge_connections" in region:
		region.use_edge_connections = true
	region.navigation_mesh = result["navmesh"]
	return int(result["polygons"])


static func build_all_merged_regions(terrain: MarchingSquaresTerrain) -> Dictionary:
	var polygons := 0
	var regions := 0
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		if not is_instance_valid(chunk):
			continue
		var count := build_merged_region(terrain, chunk)
		if count > 0:
			regions += 1
			polygons += count
	return {"regions": regions, "polygons": polygons}

#endregion
