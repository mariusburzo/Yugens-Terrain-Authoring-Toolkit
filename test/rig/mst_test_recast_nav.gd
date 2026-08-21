extends RefCounted
class_name MSTTestRecastNav
## Chunked Recast navmesh baking, adapted from Godot's own
## 3d/navigation_mesh_chunks demo (navmesh_chhunks_demo_3d.gd - the double h is
## in the upstream repo) and made parallel.
##
## Why this exists next to MSTTestNav's merger: the merger reads height_map, so
## it can only ever see terrain. A mine cart in a corridor, a tree, a bridge, a
## building - none of it is in the height map, so none of it is in the navmesh.
## Recast bakes from real geometry, so props carve themselves out for free.
##
## What is kept from the demo:
##   - one NavigationMesh per chunk, bounded by filter_baking_aabb.
##   - the bake box grown outward so neighbouring geometry is voxelised too,
##     with border_size set to the same amount so the overshoot is trimmed back
##     off. That is what makes adjacent chunks' polygon edges land on identical
##     coordinates, and identical edges are what let Godot merge regions by edge
##     key rather than by the costly edge-connection margin.
##   - the whole y range in a single chunk, because border_size only trims on
##     the xz axes; chunking in y would stack duplicate polygons.
##   - vertices snapped to a tenth of the navigation map's cell size, as
##     insurance against rasterisation float error at the seams.
##
## What is changed:
##
## 1. The bakes run as a WorkerThreadPool group task. Only two things have to
##    stay on the main thread: parsing source geometry, which walks the scene
##    tree, and assigning navigation_mesh to a region. Everything between is
##    pure computation over resources. Each job owns its own NavigationMesh and
##    all of them only read the shared NavigationMeshSourceGeometryData3D, which
##    is what makes the parallel bake safe.
##
## 2. Source geometry is assembled, not parsed, wherever it can be. Every chunk
##    already owns one ConcavePolygonShape3D collision proxy, and
##    Shape3D.get_faces() is a resource read with no scene tree in it, so terrain
##    geometry can be fed to NavigationMeshSourceGeometryData3D.add_faces() from
##    a worker. Only the props need a real parse, and props are static, so that
##    happens once and is merged into every later rebuild.
##
## 3. The grow amount is a parameter instead of always being a whole chunk. A
##    whole chunk is right for the demo's 4 m chunks, but a 64 m terrain chunk
##    grown by 64 m voxelises a 192 m box - nine chunks of work per chunk.
##    border_size only has to cover Recast's erosion and region-building reach,
##    which is a few agent radii. recommended_border() returns that; leaving
##    border_size at 0 reproduces the demo faithfully so the two can be compared.
##
## Short props do not block. A prop is only walked around when its top stands
## more than agent_max_climb above the floor, because floor and prop rasterise
## into one span and the prop's top becomes the walkable surface. For decoration
## that must block regardless of height - a mine cart, a barrier - the tool is
## NavigationMeshSourceGeometryData3D.add_projected_obstruction(vertices,
## elevation, height, true), which carves the footprint out at bake time and
## ignores the climb test entirely. This class does not do that yet.
##
## Caveat worth knowing before this goes near a real level: the terrain faces are
## the addon's *simplified* greedy-merged proxy extruded downward by
## collision_thickness, not the visual mesh. For flat-celled cave floors the two
## agree; for sculpted slopes they will not, and parse_terrain() bakes from the
## scene's colliders instead, at a higher and main-thread-bound parse cost.


const REGION_NAME : String = "ChunkNavRecast"
const REGIONS_ROOT_NAME : String = "RecastNavRegions"

#region settings

## Template every chunk's navigation mesh is duplicated from, and the same object
## that drives source geometry parsing.
##
## Assign a NavigationMesh resource to tune the bake in the Inspector instead of
## in code - cell sizes, agent metrics, the region and edge simplification knobs,
## the filters, and the two that decide what gets parsed at all:
## geometry_parsed_geometry_type (static colliders, mesh instances, or both) and
## geometry_source_geometry_mode (a root node's children, or a group). Leave it
## null and default_settings() supplies the values below.
##
## Never mutated. prepare() takes a working copy, and each chunk gets its own
## duplicate of that with filter_baking_aabb and border_size overwritten - those
## two belong to the chunking scheme, not to the user, so whatever the template
## carries for them is ignored.
var bake_settings : NavigationMesh

## Take cell_size and cell_height from the navigation map at prepare() time.
##
## These are not free parameters. The map keeps its own cell_size and cell_height
## and rasterises every region's edges onto that grid to find which edges pair
## with which - which is the entire mechanism this chunked scheme relies on. Bake
## finer than the map and two distinct vertices can land on one key; Godot warns
## about it (`navmesh_cell_size_mismatch`) precisely because it shows up as seams
## that quietly fail to connect.
##
## So the map is the single source of truth and the bake follows it. To bake
## coarser - 0.5 is the textbook value for a 1 m agent radius, and a quarter of
## the columns - move the *map* with apply_to_map() or the
## navigation/3d/default_cell_size project setting, and this follows it down.
## Switching this off lets the template's own cell values stand.
var match_map_cells : bool = true

## Where the bake's source geometry comes from.
##
## CACHED_SHAPES reads each chunk's ConcavePolygonShape3D proxy through
## get_faces() and merges a props source parsed once at load. Nothing in that
## touches the scene tree, so it can run on a worker, and it can be scoped to a
## few chunks - which is what makes an incremental re-bake after a dig cheap.
## The cost is that the props source is a snapshot: destroy a tree and its hole
## stays in the navmesh until parse_props() runs again.
##
## PARSED_GROUP puts the terrain and the props root in one group and lets
## NavigationServer3D parse it with SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN, which
## recurses into every StaticBody3D beneath them. One call, no snapshot to go
## stale, and adding a node to a group is all it takes to get it into the
## navmesh. The cost is the mirror image: parsing walks the scene tree so it is
## main-thread-only, and get_nodes_in_group has no spatial filter, so a
## single-chunk re-bake re-parses the whole world - cost that scales with the
## scene rather than with the dig.
##
## Grouping the *parent* rather than the bodies matters: the addon only adds
## navmesh_* groups to chunk collision bodies inside its editor-only branch, so
## at runtime they carry none. WITH_CHILDREN recursion means they do not need to.
enum SourceMode { CACHED_SHAPES, PARSED_GROUP }
var source_mode : SourceMode = SourceMode.CACHED_SHAPES
## Group PARSED_GROUP collects from. Applied with register_group().
var group_name : String = "mst_nav_source"
## Node parse_source_geometry_data() is rooted at.
##
## Parsed geometry comes back in the root node's *local* space, so this has to be
## a node whose global transform is identity or the whole source lands offset
## from the world-space bake boxes and every chunk bakes empty. The terrain is
## explicitly not that node - it is positioned. For group mode the root is only
## used for tree access and that transform, so any identity node in the tree does.
var parse_root : Node3D

## Grow and border, in world units. 0 means "one whole chunk", which is what the
## demo does. See recommended_border() for the cheaper alternative.
var border_size : float = 0.0
## false bakes the same chunks in a plain loop on the calling thread, which is
## the only way to state a parallel speed-up as a measured number.
var parallel : bool = true

#endregion

#region settings shortcuts

## Read straight off the working copy, so callers - and the rig's report - see
## whatever the template actually carries rather than a stale mirror of it.

var cell_size : float:
	get: return settings().cell_size
	set(value): settings().cell_size = value

## Vertical voxel size, and the resolution the climb test is decided at.
##
## This is what decides whether a short prop leaves a hole. A prop standing on
## the floor does not rasterise as floor-plus-obstacle: floor and prop merge into
## one solid span, so the column's walkable surface *is* the prop's top, and the
## only question left is whether that top is within agent_max_climb of its
## neighbours. Recast asks that in voxels, floor(agent_max_climb / cell_height),
## so at 0.5 the test only resolved in half-metre steps and a 1.2 m crate rounded
## down into "steppable". At 0.25 the climb test gets 4 voxels and a nominal
## 1.0 m climb is exactly 1.0 m, which is the answer agent_max_climb implies.
var cell_height : float:
	get: return settings().cell_height
	set(value): settings().cell_height = value

var agent_radius : float:
	get: return settings().agent_radius
	set(value): settings().agent_radius = value

var agent_height : float:
	get: return settings().agent_height
	set(value): settings().agent_height = value

## Anything whose top stands less than this above the surrounding floor is
## something the agent steps onto rather than walks around, prop or terrain
## alike. Props shorter than this will not carve a hole no matter how solid they
## are; see reliable_block_height() and the class docs.
var agent_max_climb : float:
	get: return settings().agent_max_climb
	set(value): settings().agent_max_climb = value

var agent_max_slope : float:
	get: return settings().agent_max_slope
	set(value): settings().agent_max_slope = value


## The working copy: the template with match_map_cells applied, or the built-in
## defaults if no template was given. Created on first use so a caller can read
## and write these before prepare() runs.
func settings() -> NavigationMesh:
	if _settings == null:
		_settings = bake_settings.duplicate() if bake_settings != null else default_settings()
	return _settings


## What the rig bakes with when no template resource is assigned. Also the
## reference for what test/rig/mst_recast_bake_settings.tres should contain.
##
## The three filters are set explicitly rather than left to NavigationMesh's
## defaults, because two of them change whether a prop blocks.
## filter_low_hanging_obstacles marks a non-walkable span walkable when its top
## is within agent_max_climb of a walkable neighbour - it makes *more* props
## steppable, which is the opposite of what this bake is for. filter_ledge_spans
## drops surfaces beside a drop the agent cannot survive. And
## filter_walkable_low_height_spans drops walkable surface with less than
## agent_height of clearance above it, which is what a ceiling would need.
static func default_settings() -> NavigationMesh:
	var def_settings := NavigationMesh.new()
	def_settings.cell_size = 0.25
	def_settings.cell_height = 0.25
	def_settings.agent_radius = 1.0
	def_settings.agent_height = 2.0
	def_settings.agent_max_climb = 1.0
	def_settings.agent_max_slope = 45.0
	def_settings.filter_low_hanging_obstacles = false
	def_settings.filter_ledge_spans = false
	def_settings.filter_walkable_low_height_spans = false
	def_settings.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	def_settings.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	return def_settings

#endregion

#region results

var parse_msec : float = 0.0
var prepare_msec : float = 0.0
var assemble_msec : float = 0.0
var bake_msec : float = 0.0
var publish_msec : float = 0.0
var polygons : int = 0
var regions : int = 0
var chunks_baked : int = 0
var source_triangles : int = 0
var prop_triangles : int = 0

#endregion

var _terrain : MarchingSquaresTerrain
var _prop_source : NavigationMeshSourceGeometryData3D
## coords -> {"shape": ConcavePolygonShape3D, "xform": Transform3D, "box": AABB}
## Everything a worker needs about a chunk, resolved on the main thread.
var _chunk_geometry : Dictionary = {}
var _regions_root : Node3D
var _jobs : Array = []
var _group_task_id : int = -1
var _bake_start_usec : int = 0
var _map_cell_size : float = 0.25
var _map_cell_height : float = 0.25
var _settings : NavigationMesh


## Moves the navigation map onto this baker's cell size instead of the other way
## round, and switches match_map_cells off so prepare() stops overwriting them.
##
## Every other builder sharing the map has to agree with it too, or its regions
## start warning instead of ours - MSTTestNav reads the map for the same reason.
func apply_to_map(terrain: MarchingSquaresTerrain) -> void:
	var map := terrain.get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, cell_size)
	NavigationServer3D.map_set_cell_height(map, cell_height)
	_map_cell_size = settings().cell_size
	_map_cell_height = settings().cell_height
	match_map_cells = false


## Recast needs enough border to run its erosion and region building past the
## chunk edge and reach the same verdict its neighbour does. That reach is a few
## agent radii plus a few voxels, not a whole chunk.
func recommended_border() -> float:
	return maxf(agent_radius * 3.0, cell_size * 8.0)


## The climb test's real resolution: how many voxels Recast compares heights in.
## agent_max_climb is rounded down to a whole number of these, so the effective
## climb is climb_voxels() * cell_height, not agent_max_climb. A prop shorter
## than that effective figure is stepped onto instead of walked around.
func climb_voxels() -> int:
	return floori(agent_max_climb / maxf(cell_height, 0.0001))


func effective_max_climb() -> float:
	return float(climb_voxels()) * cell_height


## Height a prop has to exceed before it is reliably carved out of the navmesh
## rather than stepped onto.
##
## effective_max_climb() is not the whole story. Recast decides the climb test in
## whole voxels, and a solid standing on the floor merges with it into one span,
## so what gets compared is the rasterised span tops - and whether a given height
## rasterises to N voxels or N+1 depends on where the bake box's y origin happens
## to land. The threshold is therefore a band one cell_height wide: below
## effective_max_climb() a prop is always stepped onto, above this always carved
## out, and inside the band the answer is stable for a given bake box but is not
## something to design around. Leave a cell_height of margin, or use a projected
## obstruction for props that must block regardless of height.
func reliable_block_height() -> float:
	return effective_max_climb() + cell_height


#region main thread: gather

## Parses props once. Must run on the main thread - parsing walks the scene tree.
##
## Kept separate from the terrain because props are static: this cost is paid at
## load, and every rebuild after a dig merges the result instead of re-parsing.
func parse_props(root: Node) -> int:
	var start_usec := Time.get_ticks_usec()
	_prop_source = NavigationMeshSourceGeometryData3D.new()
	if root != null:
		NavigationServer3D.parse_source_geometry_data(_parse_settings(), _prop_source, root)
	parse_msec = (Time.get_ticks_usec() - start_usec) / 1000.0
	prop_triangles = floori(_prop_source.get_indices().size() / 3.0)
	return prop_triangles


## The demo's route: parse the terrain's colliders out of the scene tree as well,
## rather than assembling them from the cached proxy shapes. Slower and
## main-thread-bound, but it is the honest baseline to measure against, and it is
## the only option for geometry the rig does not own.
func parse_terrain(terrain: MarchingSquaresTerrain) -> float:
	var start_usec := Time.get_ticks_usec()
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_parse_settings(), source, terrain)
	return (Time.get_ticks_usec() - start_usec) / 1000.0


## Resolves everything a worker may not touch: node transforms, the collision
## shape resource on each chunk, and the map's cell size.
func prepare(terrain: MarchingSquaresTerrain) -> int:
	var start_usec := Time.get_ticks_usec()
	_terrain = terrain
	var map := terrain.get_world_3d().navigation_map
	_map_cell_size = NavigationServer3D.map_get_cell_size(map)
	_map_cell_height = NavigationServer3D.map_get_cell_height(map)
	# Rebuilt every prepare() so an edit to the template between bakes is picked
	# up, and so the template itself is never the thing being written to.
	_settings = bake_settings.duplicate() if bake_settings != null else default_settings()
	if match_map_cells:
		_settings.cell_size = _map_cell_size
		_settings.cell_height = _map_cell_height
	_chunk_geometry.clear()

	var span_x := float(terrain.dimensions.x - 1) * terrain.cell_size.x
	var span_z := float(terrain.dimensions.z - 1) * terrain.cell_size.y
	for coords: Vector2i in terrain.chunks.keys():
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[coords]
		if not is_instance_valid(chunk):
			continue
		var shape := find_collision_shape(chunk)
		if shape == null:
			continue
		var origin := chunk.global_position
		_chunk_geometry[coords] = {
			"shape": shape,
			"xform": chunk.global_transform,
			# y is filled in per bake from the assembled geometry's own bounds.
			"box": AABB(Vector3(origin.x, 0.0, origin.z), Vector3(span_x, 0.0, span_z)),
		}

	prepare_msec = (Time.get_ticks_usec() - start_usec) / 1000.0
	return _chunk_geometry.size()


## The chunk's collision proxy, which the addon builds as a single
## ConcavePolygonShape3D on a single hidden StaticBody3D.
static func find_collision_shape(chunk: MarchingSquaresTerrainChunk) -> ConcavePolygonShape3D:
	for child in chunk.get_children():
		if child is StaticBody3D:
			for sub in child.get_children():
				if sub is CollisionShape3D and sub.shape is ConcavePolygonShape3D:
					return sub.shape as ConcavePolygonShape3D
	return null


## Parsing reads the geometry_* properties off a NavigationMesh, so the template
## drives what gets collected as well as how it is baked - switch the template to
## PARSED_GEOMETRY_MESH_INSTANCES or to a group source mode and both parse calls
## follow. Handed a duplicate so nothing downstream can write to the working copy.
func _parse_settings() -> NavigationMesh:
	return settings().duplicate()

#endregion

#region worker safe: assemble and bake

## Builds the source geometry for a set of chunks. Safe on a worker once
## prepare() has run: get_faces() reads a resource, merge() and add_faces() touch
## nothing but the new object.
##
## The whole prop set is merged in every time. filter_baking_aabb keeps the extra
## triangles out of the voxel grid, but they are still copied and still tested,
## so a level with thousands of props wants them bucketed by chunk first.
func build_source(coords_list: Array = []) -> NavigationMeshSourceGeometryData3D:
	if source_mode == SourceMode.PARSED_GROUP:
		return parse_group_source()

	var source := NavigationMeshSourceGeometryData3D.new()
	if _prop_source != null:
		source.merge(_prop_source)
	var wanted : Array = coords_list if not coords_list.is_empty() else _chunk_geometry.keys()
	for coords: Vector2i in wanted:
		var entry : Dictionary = _chunk_geometry.get(coords, {})
		if entry.is_empty():
			continue
		var shape : ConcavePolygonShape3D = entry["shape"]
		source.add_faces(shape.get_faces(), entry["xform"])
	return source


## Adds nodes to the group PARSED_GROUP collects from. Pass the terrain and the
## props root; everything with a StaticBody3D under them comes along.
func register_group(nodes: Array) -> void:
	for node: Node in nodes:
		if node != null and is_instance_valid(node) and not node.is_in_group(group_name):
			node.add_to_group(group_name)


## One parse of the whole group. Main thread only, and unscoped by design -
## get_nodes_in_group knows nothing about chunk coordinates, so there is no
## coords_list equivalent here.
##
## The group mode and name are forced onto the copy rather than read from the
## template, so switching source_mode does not also require editing the resource.
func parse_group_source() -> NavigationMeshSourceGeometryData3D:
	var source := NavigationMeshSourceGeometryData3D.new()
	if _terrain == null or not _terrain.is_inside_tree():
		return source
	var parse_settings := settings().duplicate()
	parse_settings.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	parse_settings.geometry_source_group_name = group_name
	var root : Node = parse_root if parse_root != null and is_instance_valid(parse_root) else _terrain
	NavigationServer3D.parse_source_geometry_data(parse_settings, source, root)
	return source


## Bakes bake_coords (default: every chunk) from geometry gathered over
## source_coords (default: the same set), and blocks until done.
##
## The two lists differ for an incremental rebuild: after a dig only the dug
## chunk needs baking, but its grown bake box reaches into its neighbours, so
## their geometry still has to be in the source or its edges will not line up.
func bake(bake_coords: Array = [], source_coords: Array = []) -> void:
	begin_bake(bake_coords, source_coords)
	end_bake()


## prebuilt_source lets a caller move the assembly off the main thread as well.
## It is the one stage that is worker-safe but still runs inline here, because
## every job needs the finished source before any of them can start.
func begin_bake(bake_coords: Array = [], source_coords: Array = [], prebuilt_source: NavigationMeshSourceGeometryData3D = null) -> void:
	var assemble_start := Time.get_ticks_usec()
	var source := prebuilt_source
	if source == null:
		source = build_source(source_coords if not source_coords.is_empty() else bake_coords)
	source_triangles = floori(source.get_indices().size() / 3.0)
	assemble_msec = (Time.get_ticks_usec() - assemble_start) / 1000.0

	var grow : float = border_size if border_size > 0.0 else chunk_span()
	# The bake box spans the whole y range because border_size only trims on the
	# xz axes. Padding by the agent height keeps surfaces at the very top or
	# bottom of the geometry from being clipped by their own bake bounds.
	var bounds := source.get_bounds()
	var y_min := bounds.position.y - grow - agent_height
	var y_max := bounds.position.y + bounds.size.y + grow + agent_height

	_jobs.clear()
	var targets : Array = bake_coords if not bake_coords.is_empty() else _chunk_geometry.keys()
	for coords: Vector2i in targets:
		var entry : Dictionary = _chunk_geometry.get(coords, {})
		if entry.is_empty():
			continue
		var box : AABB = entry["box"]
		box.position.y = y_min
		box.size.y = y_max - y_min
		# One duplicate per chunk, made here rather than on the worker so every
		# job owns its NavigationMesh outright before any of them start.
		var chunk_navmesh : NavigationMesh = settings().duplicate()
		chunk_navmesh.filter_baking_aabb = box.grow(grow)
		chunk_navmesh.border_size = grow
		_jobs.append({
			"coords": coords,
			"source": source,
			"navmesh": chunk_navmesh,
			"baked": false,
		})

	chunks_baked = _jobs.size()
	bake_msec = 0.0
	_bake_start_usec = Time.get_ticks_usec()
	if _jobs.is_empty():
		_group_task_id = -1
	elif parallel:
		_group_task_id = WorkerThreadPool.add_group_task(
			_bake_one, _jobs.size(), -1, false, "mst chunk navmesh bake")
	else:
		_group_task_id = -1
		for index in range(_jobs.size()):
			_bake_one(index)
		bake_msec = (Time.get_ticks_usec() - _bake_start_usec) / 1000.0


## True while the group task is still running, so a caller can keep rendering
## instead of blocking. Poll this, then call end_bake() and publish().
func is_baking() -> bool:
	return _group_task_id != -1 and not WorkerThreadPool.is_group_task_completed(_group_task_id)


func end_bake() -> void:
	if _group_task_id == -1:
		return
	WorkerThreadPool.wait_for_group_task_completion(_group_task_id)
	_group_task_id = -1
	bake_msec = (Time.get_ticks_usec() - _bake_start_usec) / 1000.0


func _bake_one(index: int) -> void:
	var job : Dictionary = _jobs[index]
	# Already carries the template's settings plus this chunk's bake bounds.
	var nav_mesh : NavigationMesh = job["navmesh"]
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, job["source"])
	# Cleared only so the debug draw does not outline the grown bake box.
	nav_mesh.filter_baking_aabb = AABB()

	# Snap to the map's own rasterisation grid. Polygon indices are untouched, so
	# this cannot change the mesh's topology, only nudge coincident seam vertices
	# onto exactly equal coordinates.
	var snap := _map_cell_size * 0.1
	var vertices := nav_mesh.get_vertices()
	for i in range(vertices.size()):
		vertices[i] = vertices[i].snappedf(snap)
	nav_mesh.set_vertices(vertices)

	job["baked"] = true

#endregion

#region main thread: publish

## Attaches the baked meshes to their regions. Main thread only.
func publish() -> void:
	var start_usec := Time.get_ticks_usec()
	_ensure_regions_root()
	for job: Dictionary in _jobs:
		# Publishing an unbaked duplicate would hand a region an empty mesh and
		# look exactly like a chunk that legitimately lost its polygons.
		if not bool(job["baked"]):
			continue
		_region_for(job["coords"]).navigation_mesh = job["navmesh"]

	# Counted over every live region, not just the ones in this batch, so the
	# totals stay right after an incremental rebuild.
	polygons = 0
	regions = 0
	if is_instance_valid(_regions_root):
		for child in _regions_root.get_children():
			var region := child as NavigationRegion3D
			if region == null or region.navigation_mesh == null:
				continue
			var count := region.navigation_mesh.get_polygon_count()
			if count > 0:
				regions += 1
				polygons += count
	publish_msec = (Time.get_ticks_usec() - start_usec) / 1000.0


func clear_regions() -> void:
	if is_instance_valid(_regions_root):
		_regions_root.free()
	_regions_root = null
	polygons = 0
	regions = 0


func _ensure_regions_root() -> void:
	if is_instance_valid(_regions_root):
		return
	_regions_root = Node3D.new()
	_regions_root.name = REGIONS_ROOT_NAME
	_terrain.add_child(_regions_root)
	# Baked vertices are in world space. Parenting these regions to the chunk, as
	# the merger does with its own chunk-local meshes, would apply the chunk's
	# translation a second time and land every navmesh one chunk away.
	_regions_root.global_transform = Transform3D.IDENTITY


func _region_for(coords: Vector2i) -> NavigationRegion3D:
	var region_name := "%s_%d_%d" % [REGION_NAME, coords.x, coords.y]
	var region := _regions_root.get_node_or_null(region_name) as NavigationRegion3D
	if region == null:
		region = NavigationRegion3D.new()
		region.name = region_name
		_regions_root.add_child(region)
		region.global_transform = Transform3D.IDENTITY
	return region

#endregion

#region helpers

func chunk_span() -> float:
	if _terrain == null:
		return 0.0
	return maxf(
		float(_terrain.dimensions.x - 1) * _terrain.cell_size.x,
		float(_terrain.dimensions.z - 1) * _terrain.cell_size.y
	)


## The chunks whose geometry a bake of coords needs in its source, which is
## everything the grown bake box can reach.
func neighbourhood(coords: Vector2i) -> Array:
	var radius := 1
	if border_size > 0.0:
		radius = maxi(1, ceili(border_size / maxf(chunk_span(), 0.001)))
	var result : Array = []
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var neighbour := coords + Vector2i(dx, dz)
			if _chunk_geometry.has(neighbour):
				result.append(neighbour)
	return result


func chunk_coords() -> Array:
	return _chunk_geometry.keys()


## What a rebuild actually costs the frame it happens on.
##
## Assembly is counted because begin_bake() runs it inline. It touches nothing
## but resources, so a caller that cares can build the source itself on a thread
## and pass it to begin_bake() as prebuilt_source, which leaves only prepare()
## and publish() - node walks and one property assignment per region.
func main_thread_msec() -> float:
	return prepare_msec + assemble_msec + publish_msec

#endregion
