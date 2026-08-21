@tool
extends Node3D
class_name MSTChunkedNavMesh
## Chunked, parallel, incremental Recast navigation baking for a
## MarchingSquaresTerrain.
##
## Drop this under the terrain node and it bakes one NavigationRegion3D per
## terrain chunk on a WorkerThreadPool, from real geometry rather than from the
## height map - so trees, mine carts, crates and bridges are in the navmesh, and
## a dig or a felled tree re-bakes only the chunks it touched.
##
## The addon's own MarchingSquaresTerrainNavMesh is one region baked from
## height_map. That is the right tool for a static level. This is the one for a
## level the player edits, with decoration standing on it.
##
## Every default here is a measured result rather than a guess. See
## test/README.md for the numbers behind them; the short version:
##
##   - one region per chunk, not one for the map, so a dig costs 0.66 ms of main
##     thread at 1024 chunks instead of re-baking the world.
##   - three source lanes (terrain / irregular statics / decoration) rather than
##     forcing every category of geometry through one mechanism.
##   - edge connections OFF. The map's edge-connection margin searches every free
##     edge on the map whenever anything changes; at 1024 regions that delayed a
##     dig becoming walkable by tens of seconds. Regions here meet by exact edge
##     match, so the margin buys nothing.
##
## Typical wiring:
##
##   Terrain (MarchingSquaresTerrain)
##   +- ChunkedNavMesh (this)      terrain_path empty -> uses the parent
##   Props   (Node3D)              obstacle_root_path -> here
##   Statics (Node3D)              static_root_path   -> here
##
## and from gameplay code:
##
##   nav.rebake_terrain_at([hit_position])     # after a dig
##   nav.remove_obstacle(tree_body)            # after a tree falls
##
## Both are non-blocking. The node pumps its own bake queue in _process.


## Base name for the generated regions.
const REGION_PREFIX : String = "MSTNavRegion"
const PARSE_ANCHOR_NAME : String = "ParseAnchor"
## Frames to wait for the terrain to finish building its chunk collision before
## giving up and baking whatever exists. Generous because the wait ends the
## moment the condition is met, so the budget only matters when something is
## actually wrong.
const MAX_TERRAIN_WAIT_FRAMES : int = 600

## Emitted when a queued bake actually starts, with how many chunks are in it.
signal bake_started(chunks: int)
## Emitted after the baked meshes have been handed to their regions. `msec` is
## wall time from dispatch to publish, not main-thread cost - main_thread_msec()
## is the figure that decides whether a frame hitches.
signal bake_finished(chunks: int, msec: float)


#region exports

## Bakes every chunk now, in the editor, and adopts the regions into the scene
## so they are saved with it.
##
## A pre-baked map costs nothing at load - which for a handcrafted surface map is
## the whole point, since assembling and baking a square kilometre took over four
## seconds. Turn bake_on_ready off afterwards so the game keeps what was baked
## here instead of throwing it away and starting again.
##
## The cost is scene size: the polygons are serialised into the .tscn, and a
## square kilometre is a lot of polygons. For a level small enough that a startup
## bake is not noticeable, leaving bake_on_ready on and never pressing this is
## the tidier choice.
@export_tool_button("Bake Navigation Meshes", "NavigationRegion3D") var bake_button = func():
	_editor_bake()
## Removes the baked regions from the scene. Does not touch the terrain's own
## painted navmesh permission mask.
@export_tool_button("Clear Baked Navigation", "Clear") var clear_button = func():
	_editor_clear()

@export_group("Terrain")
## The terrain to bake. Leave empty to use this node's parent, which is the
## intended layout and the one the configuration warning checks for.
@export var terrain_path : NodePath

@export_group("Bake")
## Template every chunk's navigation mesh is duplicated from, and the resource
## that also drives what gets parsed.
##
## Assign a NavigationMesh to tune the bake in the Inspector: cell sizes, agent
## metrics, region and edge simplification, the three filters, and
## geometry_parsed_geometry_type. Leave it null and default_settings() applies
## values known to work with this scheme.
##
## Never written to. Each chunk gets its own duplicate with filter_baking_aabb
## and border_size overwritten, because those two belong to the chunking scheme
## rather than to the user.
@export var bake_settings : NavigationMesh
## Bake the whole terrain once at startup, as soon as the terrain's chunk
## collision exists.
##
## Turn this off after an editor bake, or the game will throw those regions away
## and bake them again. Off does not disable anything else: the chunk geometry is
## still resolved at startup, so the incremental rebake paths keep working.
@export var bake_on_ready : bool = true
## Run the per-chunk bakes on WorkerThreadPool. Off bakes them in a plain loop on
## the calling thread, which is only useful for measuring the difference.
@export var parallel : bool = true
## How far past its own bounds each chunk voxelises, in metres, trimmed back off
## afterwards by an equal border_size. 0 means auto: three agent radii, or eight
## cells, whichever is larger.
##
## This is what makes neighbouring chunks agree at the seam. Recast has to run
## its erosion and region building past the chunk edge and reach the same verdict
## its neighbour did; too small and the seams show as unwalkable strips. Larger
## is safe but quadratic - a 32 m chunk grown by 32 m voxelises nine chunks of
## space to produce one.
@export_range(0.0, 64.0, 0.5, "or_greater", "suffix:m") var border_size : float = 0.0
## Take cell_size and cell_height from the navigation map rather than from the
## template.
##
## The map rasterises every region's edges onto its own grid to decide which
## edges pair with which, which is the mechanism this whole chunked scheme rests
## on. Baking finer than the map lets two distinct vertices collide on one key,
## which shows up as seams that quietly fail to connect - Godot warns about it as
## `navmesh_cell_size_mismatch`. So the map is the source of truth and the bake
## follows it. To bake coarser, move the map with apply_to_map() or the
## navigation/3d/default_cell_size project setting.
@export var match_map_cells : bool = true

@export_group("Decoration")
## Physics layers whose bodies become projected obstructions. 0 disables the lane
## entirely.
##
## A projected obstruction is a flat footprint extruded upward and carved out of
## the navmesh at bake time. It costs four vertices instead of a tessellated
## collider, and - the reason it exists here - it ignores Recast's climb test, so
## a prop shorter than reliable_block_height() still blocks. Without it, a floor
## and the crate standing on it rasterise into a single span whose top *is* the
## crate, and the crate becomes something the agent steps onto.
##
## These layers are also kept out of the statics parse, so a body used as an
## obstruction is never additionally collected as geometry.
@export_flags_3d_physics var obstacle_collision_mask : int = 0
## Node whose descendants are scanned for obstacle bodies. Usually the props root.
@export var obstacle_root_path : NodePath
## Grow each footprint by the agent radius.
##
## Recast marks projected obstructions *after* rcErodeWalkableArea has already
## pulled the walkable surface back by the agent radius, so an obstruction gets
## no such margin of its own and agents clip the prop's corners. Expanding the
## footprint restores it. Leave on unless the props are modelled with the
## clearance already built in.
@export var obstacles_expand_by_agent_radius : bool = true

@export_group("Irregular statics")
## Physics layers whose bodies are parsed as real geometry, per chunk. 0 disables
## the lane entirely.
##
## For anything a four-vertex footprint cannot describe: a bridge with a deck to
## walk over and a gap underneath, a ramp, a building with a doorway. These cost
## a real parse, which walks the scene tree and is therefore main-thread bound -
## but only for chunks whose group is non-empty, which on a map where most chunks
## carry no buildings is where the saving comes from.
@export_flags_3d_physics var static_collision_mask : int = 0
## Node whose children are registered into their chunk's static group.
##
## Each direct child holding a matching body joins the group for the chunk it
## stands over. The group name is generated - nothing to type, and nothing to
## keep in sync by hand.
@export var static_root_path : NodePath

@export_group("Navigation map")
## Leave the map's edge-connection margin switched on.
##
## Off by default, and the single most important setting on a large map. The
## margin exists to join regions whose edges do not line up, and it looks for
## neighbours across every free edge on the map - so its cost grows with total
## polygons rather than with what changed. At 1024 regions and ~106k polygons it
## made a dig take tens of seconds to become walkable.
##
## Every region this node produces is edge-aligned by construction, which is what
## the border trimming and vertex snapping are for, so there is nothing left for
## the margin to fix. Turn it on only if you are mixing in regions from elsewhere.
@export var edge_connections : bool = false
## Chunks either side of the focus node whose regions stay enabled. 0 keeps them
## all enabled.
##
## A disabled region leaves the navigation map, so this bounds both costs that
## grow with map size: what the server re-syncs when anything changes, and the
## polygon graph A* has to search. That second one is the real reason - A* has a
## search-space limit, and on a 1 km map a query gave up around 576 m with every
## region live. The cost is that agents cannot path into what is switched off, so
## the window has to cover wherever anyone might need to go, not just what is on
## screen.
@export_range(0, 64, 1) var active_radius_chunks : int = 0
## Node the enabled-region window follows. Usually the player.
@export var active_focus_path : NodePath

@export_group("Advanced")
## Prefix for the generated per-chunk group names. Only worth changing if two of
## these nodes bake different terrains in one scene.
@export var group_prefix : String = "mst_nav"

#endregion


#region results

var parse_msec : float = 0.0
var assemble_msec : float = 0.0
var bake_msec : float = 0.0
var publish_msec : float = 0.0
## Chunks the statics lane actually had to parse. The rest had empty groups.
var statics_parsed : int = 0
var polygons : int = 0
var regions : int = 0
var chunks_baked : int = 0
var source_triangles : int = 0

#endregion


var _terrain : MarchingSquaresTerrain
var _parse_anchor : Node3D
var _settings : NavigationMesh
var _map_cell_size : float = 0.25
var _map_cell_height : float = 0.25

## coords -> {"shape": ConcavePolygonShape3D, "xform": Transform3D, "box": AABB}
## Everything a worker needs about a chunk, resolved on the main thread.
var _chunk_geometry : Dictionary = {}
## coords -> Array of obstruction dictionaries standing over that chunk. Bucketed
## rather than scanned, because testing every prop on every bake is an O(map)
## cost on a path that only ever carves a handful.
var _obstruction_index : Dictionary = {}
## node instance id -> its obstruction entry, so removing one prop is a lookup
## rather than a search.
var _obstacles : Dictionary = {}
## coords -> polygon count of the region published for it, so the totals do not
## need a walk over every live region.
var _region_polygons : Dictionary = {}

## coords -> bool, where the bool is "the terrain proxy under this chunk changed".
## The two rebake entry points differ only in what they put here.
var _pending : Dictionary = {}
var _jobs : Array = []
var _group_task_id : int = -1
var _bake_start_usec : int = 0
var _active_centre : Vector2i = Vector2i(-2147483647, -2147483647)


#region lifecycle

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not _resolve_terrain():
		push_warning("MSTChunkedNavMesh: no MarchingSquaresTerrain found; nothing to bake.")
		return
	apply_edge_connections()
	# Kept on its own line rather than folded into the `if`, because `not await x`
	# is exactly the sort of precedence question nobody should have to answer.
	var terrain_ready : bool = await _await_terrain_geometry()
	if not terrain_ready:
		push_warning("MSTChunkedNavMesh: terrain collision was still incomplete after %d frames. Baking whatever exists." % MAX_TERRAIN_WAIT_FRAMES)
	# prepare() and register_sources() run whether or not this bakes on ready.
	# With pre-baked regions saved in the scene there is nothing to bake at
	# startup, but the incremental paths still need resolved chunk geometry - and
	# without it rebake_terrain_at() would silently do nothing.
	prepare()
	register_sources()
	if bake_on_ready:
		queue_all()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _group_task_id != -1:
		if WorkerThreadPool.is_group_task_completed(_group_task_id):
			_finish_bake()
		return
	if not _pending.is_empty():
		_start_bake()
		return
	_follow_active_window()


## Waits until the terrain actually has geometry to bake, and reports whether it
## got there.
func _await_terrain_geometry() -> bool:
	for _frame in range(MAX_TERRAIN_WAIT_FRAMES):
		if _terrain_geometry_ready():
			return true
		await get_tree().process_frame
	return _terrain_geometry_ready()


## The terrain has chunks, and every one of them has its collision proxy.
##
## Worth polling rather than assuming, because the terrain is not ready when this
## node is. MarchingSquaresTerrain fills `chunks` and builds those proxies in
## _deferred_enter_tree(), which is call_deferred out of _enter_tree and then
## awaits a process frame of its own before calling initialize_terrain() on each
## chunk. So the proxies do not exist for at least two frames after this node's
## _ready - and waiting a fixed number of frames instead of the real condition is
## how you get a map that bakes nothing and says nothing about it.
##
## Polled rather than driven off the terrain's `load_finished` signal because the
## signal may already have fired by the time this connects, and a missed signal
## is the same silent failure in a different disguise.
func _terrain_geometry_ready() -> bool:
	if _terrain == null or _terrain.chunks.is_empty():
		return false
	for chunk: MarchingSquaresTerrainChunk in _terrain.chunks.values():
		if not is_instance_valid(chunk):
			continue
		if find_collision_shape(chunk) == null:
			return false
	return true


func _get_configuration_warnings() -> PackedStringArray:
	var warnings : PackedStringArray = []
	if _find_terrain() == null:
		warnings.append("No terrain. Make this a child of a MarchingSquaresTerrain, or set terrain_path.")
	if obstacle_collision_mask != 0 and obstacle_root_path.is_empty():
		warnings.append("obstacle_collision_mask is set but obstacle_root_path is empty - the decoration lane will find nothing.")
	if static_collision_mask != 0 and static_root_path.is_empty():
		warnings.append("static_collision_mask is set but static_root_path is empty - the statics lane will find nothing.")
	if (obstacle_collision_mask & static_collision_mask) != 0:
		warnings.append("obstacle_collision_mask and static_collision_mask overlap. A body on a shared layer would be both carved out and parsed as geometry.")
	if bake_settings != null and bake_settings.agent_radius <= 0.0:
		warnings.append("bake_settings.agent_radius is 0. Recast erodes nothing and agents will hug walls.")
	return warnings

#endregion


#region public API

## Full rebuild: re-resolves every chunk, re-registers every source, queues the
## whole map. Call after loading or generating a level.
func rebuild() -> void:
	if not _resolve_terrain():
		return
	prepare()
	register_sources()
	queue_all()


## Queues every resolved chunk. prepare() has just re-resolved them all, so none
## of them needs a second look - hence false rather than true.
func queue_all() -> void:
	_pending.clear()
	for coords: Vector2i in _chunk_geometry.keys():
		_pending[coords] = false


## Runs the queued bake to completion inline instead of over the next few frames.
##
## Blocks the calling thread while the workers run, so this is for a loading
## screen or the editor button - not for a dig. The incremental paths are
## deliberately asynchronous.
func bake_now() -> void:
	if _pending.is_empty():
		return
	_start_bake()
	# The serial path already finished inside _start_bake() and left the task id
	# at -1, so this is only the parallel one.
	if _group_task_id != -1:
		_finish_bake()


## Queues a re-bake of chunks whose *terrain* changed - a dig, a raise, a sculpt.
##
## rebuild_collision() puts a new ConcavePolygonShape3D on the chunk, so the
## cached entry is now pointing at the old resource and has to be re-resolved
## before the bake. That is the whole difference between this and rebake_props().
func rebake_terrain(coords_list: Array) -> void:
	for coords: Vector2i in coords_list:
		_queue(coords, true)


## Same, addressed by world position. Handy straight off a raycast hit.
func rebake_terrain_at(world_positions: Array) -> void:
	for world_position: Vector3 in world_positions:
		_queue(chunk_coords_for(world_position), true)


## Queues a re-bake of chunks whose *decoration or statics* changed, with the
## terrain left alone.
##
## The cheaper of the two paths, and the difference is the point: a chunk's
## collision proxy is untouched when a tree falls, so re-resolving it would be a
## node walk and a shape lookup for an answer already known. Only the source
## geometry has to be rebuilt.
func rebake_props(coords_list: Array) -> void:
	for coords: Vector2i in coords_list:
		_queue(coords, false)


## Registers one body as a projected obstruction and queues the chunks it can
## affect. Call when a prop is spawned at runtime.
func add_obstacle(body: CollisionObject3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var entry := _obstruction_for(body)
	if entry.is_empty():
		return
	_obstacles[body.get_instance_id()] = entry
	var coords : Vector2i = entry["coords"]
	if not _obstruction_index.has(coords):
		_obstruction_index[coords] = []
	_obstruction_index[coords].append(entry)
	_queue_neighbourhood(coords)


## Drops one obstruction and queues the chunks it can affect, without touching
## terrain geometry. Call before freeing the prop.
##
## The neighbourhood is queued rather than the single chunk, because a prop near
## a border overhangs its neighbour and because a chunk's bake box reaches past
## its own bounds by border_size anyway.
func remove_obstacle(body: CollisionObject3D) -> void:
	if body == null:
		return
	var key := body.get_instance_id()
	if not _obstacles.has(key):
		return
	var entry : Dictionary = _obstacles[key]
	var coords : Vector2i = entry["coords"]
	_obstacles.erase(key)
	var bucket : Array = _obstruction_index.get(coords, [])
	bucket.erase(entry)
	if bucket.is_empty():
		_obstruction_index.erase(coords)
	_queue_neighbourhood(coords)


## Queues the chunks a parsed static stood over. The node leaving the tree is
## what removes it from the parse, so this only schedules the bake - call it
## before freeing, while the node still has a position.
func remove_static(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	_queue_neighbourhood(chunk_coords_for(node.global_position))


## Enables only the regions within `radius` chunks of `centre`, disabling the
## rest. A negative radius enables everything. O(regions) - call it when the
## centre chunk changes, not every frame.
func set_active_radius(centre: Vector2i, radius: int) -> int:
	var active := 0
	for coords: Vector2i in _chunk_geometry.keys():
		var region := get_node_or_null(_region_name(coords)) as NavigationRegion3D
		if region == null:
			continue
		var wanted := radius < 0 or (
			absi(coords.x - centre.x) <= radius and absi(coords.y - centre.y) <= radius)
		if region.enabled != wanted:
			region.enabled = wanted
		if wanted:
			active += 1
	return active


## Which chunk a world position stands over.
func chunk_coords_for(world_position: Vector3) -> Vector2i:
	if _terrain == null:
		return Vector2i.ZERO
	var local := world_position - _terrain.global_position
	return Vector2i(floori(local.x / chunk_stride_x()), floori(local.z / chunk_stride_z()))


## True while a bake is in flight.
func is_baking() -> bool:
	return _group_task_id != -1


## What the last rebuild actually cost the frame it landed on. Assembly counts,
## because it runs inline; the bake itself does not, because it does not.
func main_thread_msec() -> float:
	return assemble_msec + publish_msec


func clear_regions() -> void:
	for child in get_children():
		if child is NavigationRegion3D:
			child.queue_free()
	_region_polygons.clear()
	polygons = 0
	regions = 0

#endregion


#region settings

## The working copy: the template with match_map_cells applied, or the built-in
## defaults if no template was assigned.
func settings() -> NavigationMesh:
	if _settings == null:
		_settings = bake_settings.duplicate() if bake_settings != null else default_settings()
	return _settings


## What this bakes with when no template resource is assigned, and the reference
## for what a template should contain.
##
## The three filters are set explicitly rather than left at NavigationMesh's
## defaults, because two of them change whether a prop blocks.
## filter_low_hanging_obstacles marks a non-walkable span walkable when its top
## is within agent_max_climb of a walkable neighbour - it makes *more* props
## steppable, which is the opposite of what this bake is for.
static func default_settings() -> NavigationMesh:
	var def := NavigationMesh.new()
	def.cell_size = 0.25
	def.cell_height = 0.25
	def.agent_radius = 1.0
	def.agent_height = 2.0
	def.agent_max_climb = 1.0
	def.agent_max_slope = 45.0
	def.filter_low_hanging_obstacles = false
	def.filter_ledge_spans = false
	def.filter_walkable_low_height_spans = false
	def.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	def.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	return def


## Moves the navigation map onto this node's cell size instead of the other way
## round, and switches match_map_cells off so prepare() stops overwriting them.
## Everything else sharing the map has to agree with it too.
func apply_to_map() -> void:
	if not _resolve_terrain():
		return
	var map := _terrain.get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, settings().cell_size)
	NavigationServer3D.map_set_cell_height(map, settings().cell_height)
	_map_cell_size = settings().cell_size
	_map_cell_height = settings().cell_height
	match_map_cells = false


## Pushes `edge_connections` onto the navigation map. Called from _ready; call it
## again if the flag is changed at runtime.
func apply_edge_connections() -> void:
	if _terrain == null:
		return
	NavigationServer3D.map_set_use_edge_connections(
		_terrain.get_world_3d().navigation_map, edge_connections)


func agent_radius() -> float:
	return settings().agent_radius


## Recast decides its climb test in whole voxels, so agent_max_climb is rounded
## down to a multiple of cell_height. This is the figure that actually applies.
func effective_max_climb() -> float:
	var voxels := floori(settings().agent_max_climb / maxf(settings().cell_height, 0.0001))
	return float(voxels) * settings().cell_height


## Height a prop must exceed before parsed geometry reliably carves it out rather
## than letting agents step onto it.
##
## Whether a given height rasterises to N voxels or N+1 depends on where the bake
## box's y origin lands, so the threshold is a band one cell_height wide rather
## than a number. Anything shorter than this wants the obstacle lane instead.
func reliable_block_height() -> float:
	return effective_max_climb() + settings().cell_height


## The border the seams actually need: enough for Recast to run its erosion and
## region building past the chunk edge, which is a few agent radii, not a chunk.
func effective_border() -> float:
	if border_size > 0.0:
		return border_size
	return maxf(settings().agent_radius * 3.0, settings().cell_size * 8.0)

#endregion


#region main thread: gather

## Resolves everything a worker may not touch: node transforms, the collision
## shape resource on each chunk, and the map's cell size.
func prepare() -> int:
	if not _resolve_terrain():
		return 0
	var map := _terrain.get_world_3d().navigation_map
	_map_cell_size = NavigationServer3D.map_get_cell_size(map)
	_map_cell_height = NavigationServer3D.map_get_cell_height(map)
	# Rebuilt here so an edit to the template between bakes is picked up, and so
	# the template itself is never the thing being written to.
	_settings = bake_settings.duplicate() if bake_settings != null else default_settings()
	if match_map_cells:
		_settings.cell_size = _map_cell_size
		_settings.cell_height = _map_cell_height
	_chunk_geometry.clear()
	_refresh_chunks(_terrain.chunks.keys())

	# Regions saved with the scene by the editor bake are already in the tree, so
	# their polygons are seeded here rather than counted from nothing - otherwise
	# a pre-baked map would report zero until something re-baked it.
	_region_polygons.clear()
	for coords: Vector2i in _chunk_geometry.keys():
		var region := get_node_or_null(_region_name(coords)) as NavigationRegion3D
		if region != null and region.navigation_mesh != null:
			_region_polygons[coords] = region.navigation_mesh.get_polygon_count()

	if _chunk_geometry.is_empty():
		push_warning("MSTChunkedNavMesh: resolved 0 chunks from %d terrain chunk(s) - none had a ConcavePolygonShape3D collision proxy, so there is nothing to bake." % _terrain.chunks.size())
	return _chunk_geometry.size()


## Re-resolves just these chunks. prepare() is O(map) - measured 3.98 ms at 1024
## chunks - which is the wrong shape for a path that only ever touches a handful.
func _refresh_chunks(coords_list: Array) -> void:
	if _terrain == null:
		return
	var span_x := chunk_stride_x()
	var span_z := chunk_stride_z()
	for coords: Vector2i in coords_list:
		var chunk = _terrain.chunks.get(coords)
		if not is_instance_valid(chunk):
			continue
		var shape := find_collision_shape(chunk)
		if shape == null:
			continue
		var origin : Vector3 = chunk.global_position
		_chunk_geometry[coords] = {
			"shape": shape,
			"xform": chunk.global_transform,
			# y is filled in per bake from the assembled geometry's own bounds.
			"box": AABB(Vector3(origin.x, 0.0, origin.z), Vector3(span_x, 0.0, span_z)),
		}


## The chunk's collision proxy, which the addon builds as a single
## ConcavePolygonShape3D on a single hidden StaticBody3D.
static func find_collision_shape(chunk: MarchingSquaresTerrainChunk) -> ConcavePolygonShape3D:
	for child in chunk.get_children():
		if child is StaticBody3D:
			for sub in child.get_children():
				if sub is CollisionShape3D and sub.shape is ConcavePolygonShape3D:
					return sub.shape as ConcavePolygonShape3D
	return null


## Scans both source roots and registers what it finds. Called by rebuild(); call
## it again after a batch of spawns. add_obstacle() covers single ones.
##
## Deliberately does not queue anything. A re-scan is a scan, and making it also
## cost a full-map re-bake would make it something callers avoid.
func register_sources() -> void:
	var start_usec := Time.get_ticks_usec()
	var queued_before : Dictionary = _pending.duplicate()
	_obstacles.clear()
	_obstruction_index.clear()
	if obstacle_collision_mask != 0:
		for body: CollisionObject3D in _bodies_under(get_node_or_null(obstacle_root_path), obstacle_collision_mask):
			add_obstacle(body)
	if static_collision_mask != 0:
		_register_statics(get_node_or_null(static_root_path))
	_pending = queued_before
	parse_msec = (Time.get_ticks_usec() - start_usec) / 1000.0


## Puts each direct child holding a matching body into the group for the chunk it
## stands over. The child, not the body, so GROUPS_WITH_CHILDREN recursion picks
## up whatever an instanced prop scene has underneath it.
func _register_statics(root: Node) -> int:
	if root == null or not is_instance_valid(root):
		return 0
	var registered := 0
	for child in root.get_children():
		if not (child is Node3D):
			continue
		if _bodies_under(child, static_collision_mask).is_empty():
			continue
		var group := static_group_name(chunk_coords_for((child as Node3D).global_position))
		if not child.is_in_group(group):
			child.add_to_group(group)
		registered += 1
	return registered


## Group name for the irregular statics standing over one chunk.
##
## Holds only the statics, never the chunk: the terrain lane already supplies
## that chunk from its cached proxy, and a group holding both would collect the
## same terrain a second time.
func static_group_name(coords: Vector2i) -> String:
	return "%s_static_%d_%d" % [group_prefix, coords.x, coords.y]


## Every CollisionObject3D at or under `node` whose collision_layer meets `mask`.
static func _bodies_under(node: Node, mask: int) -> Array:
	var found : Array = []
	if node == null or not is_instance_valid(node):
		return found
	if node is CollisionObject3D and ((node as CollisionObject3D).collision_layer & mask) != 0:
		found.append(node)
	for child in node.get_children():
		found.append_array(_bodies_under(child, mask))
	return found


## Turns one body into a projected obstruction: the xz rectangle of its collision
## shapes, extruded from their base to their top.
##
## A projected obstruction is a flat polygon swept straight up, so a bounding
## rectangle is not an approximation of the shape - it is the whole of what the
## representation can express. Anything that needs a hole through it, or a
## walkable surface on top of it, belongs on the statics lane instead.
func _obstruction_for(body: CollisionObject3D) -> Dictionary:
	var bounds := _world_shape_bounds(body)
	if bounds.size == Vector3.ZERO:
		return {}
	var margin := agent_radius() if obstacles_expand_by_agent_radius else 0.0
	var min_x := bounds.position.x - margin
	var max_x := bounds.position.x + bounds.size.x + margin
	var min_z := bounds.position.z - margin
	var max_z := bounds.position.z + bounds.size.z + margin
	# One cell of vertical slack either side, so the carve cannot be lost to the
	# voxel grid rounding the base up or the top down.
	var pad := settings().cell_height
	return {
		"vertices": PackedVector3Array([
			Vector3(min_x, 0.0, min_z),
			Vector3(max_x, 0.0, min_z),
			Vector3(max_x, 0.0, max_z),
			Vector3(min_x, 0.0, max_z),
		]),
		"elevation": bounds.position.y - pad,
		"height": bounds.size.y + pad * 2.0,
		"coords": chunk_coords_for(body.global_position),
	}


## World-space bounds of every enabled CollisionShape3D under a body.
static func _world_shape_bounds(body: CollisionObject3D) -> AABB:
	var bounds := AABB()
	var seeded := false
	for child in body.get_children():
		if not (child is CollisionShape3D):
			continue
		var collision_shape := child as CollisionShape3D
		if collision_shape.shape == null or collision_shape.disabled:
			continue
		# get_debug_mesh() covers every shape type without a match on class, and
		# this runs once per prop at registration rather than once per bake.
		var local := collision_shape.shape.get_debug_mesh().get_aabb()
		var world := collision_shape.global_transform * local
		bounds = world if not seeded else bounds.merge(world)
		seeded = true
	return bounds

#endregion


#region bake

func _queue(coords: Vector2i, terrain_changed: bool) -> void:
	if not _chunk_geometry.has(coords):
		return
	# A chunk already queued for a terrain change stays queued for one - the
	# cheaper request must never downgrade the more thorough one.
	_pending[coords] = bool(_pending.get(coords, false)) or terrain_changed


## Queues a chunk and its neighbours without touching terrain geometry. Used by
## the prop paths, where the change can overhang a border.
func _queue_neighbourhood(coords: Vector2i) -> void:
	for neighbour: Vector2i in neighbourhood(coords):
		_queue(neighbour, false)


## The chunks whose geometry a bake of `coords` needs in its source, which is
## everything the grown bake box can reach.
func neighbourhood(coords: Vector2i) -> Array:
	var radius := maxi(1, ceili(effective_border() / maxf(chunk_span(), 0.001)))
	var result : Array = []
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var neighbour := coords + Vector2i(dx, dz)
			if _chunk_geometry.has(neighbour):
				result.append(neighbour)
	return result


func _start_bake() -> void:
	var bake_coords : Array = _pending.keys()
	var needs_refresh : Array = []
	for coords: Vector2i in bake_coords:
		if bool(_pending[coords]):
			needs_refresh.append(coords)
	_pending.clear()
	if not needs_refresh.is_empty():
		_refresh_chunks(needs_refresh)

	var assemble_start := Time.get_ticks_usec()
	var source := _build_source(_source_coords(bake_coords))
	source_triangles = floori(source.get_indices().size() / 3.0)

	var grow := effective_border()
	# The bake box spans the whole y range, because border_size only trims on the
	# xz axes - chunking in y would stack duplicate polygons at the seam. Padded
	# by the agent height so surfaces at the very top or bottom of the geometry
	# are not clipped by their own bake bounds.
	var bounds := source.get_bounds()
	var y_min := bounds.position.y - grow - settings().agent_height
	var y_max := bounds.position.y + bounds.size.y + grow + settings().agent_height

	_jobs.clear()
	for coords: Vector2i in bake_coords:
		var entry : Dictionary = _chunk_geometry.get(coords, {})
		if entry.is_empty():
			continue
		var box : AABB = entry["box"]
		box.position.y = y_min
		box.size.y = y_max - y_min
		# One duplicate per chunk, made here rather than on the worker, so every
		# job owns its NavigationMesh outright before any of them start. All of
		# them only ever read the shared source, which is what makes this safe.
		var chunk_navmesh : NavigationMesh = settings().duplicate()
		chunk_navmesh.filter_baking_aabb = box.grow(grow)
		chunk_navmesh.border_size = grow
		_jobs.append({"coords": coords, "source": source, "navmesh": chunk_navmesh, "baked": false})

	assemble_msec = (Time.get_ticks_usec() - assemble_start) / 1000.0
	chunks_baked = _jobs.size()
	bake_msec = 0.0
	_bake_start_usec = Time.get_ticks_usec()
	if _jobs.is_empty():
		return
	bake_started.emit(chunks_baked)
	if parallel:
		_group_task_id = WorkerThreadPool.add_group_task(
			_bake_one, _jobs.size(), -1, false, "mst chunked navmesh bake")
	else:
		for index in range(_jobs.size()):
			_bake_one(index)
		_finish_bake()


## Which chunks have to be *in the source* for this bake. A chunk's grown box
## reaches into its neighbours, so their geometry has to be there or the polygon
## edges will not line up at the seam. Empty means "all of them", which is both
## correct and cheaper than enumerating a whole map's neighbourhoods.
func _source_coords(bake_coords: Array) -> Array:
	if bake_coords.size() >= _chunk_geometry.size():
		return []
	var wanted : Dictionary = {}
	for coords: Vector2i in bake_coords:
		for neighbour: Vector2i in neighbourhood(coords):
			wanted[neighbour] = true
	return wanted.keys()


## The three lanes, each scoped to the same chunk list:
##
##   terrain           -> cached collision proxies, no scene tree, worker-safe
##   irregular statics -> one parse per non-empty chunk group, main thread
##   decoration        -> projected obstructions, four vertices each
##
## Nothing is chosen per chunk. A chunk's source is the union of its three lanes,
## and a chunk whose static group is empty simply has no parse to make - which on
## a map where most chunks carry no buildings is where the saving comes from.
func _build_source(coords_list: Array) -> NavigationMeshSourceGeometryData3D:
	var source := NavigationMeshSourceGeometryData3D.new()
	var wanted : Array = coords_list if not coords_list.is_empty() else _chunk_geometry.keys()

	for coords: Vector2i in wanted:
		var entry : Dictionary = _chunk_geometry.get(coords, {})
		if entry.is_empty():
			continue
		var shape : ConcavePolygonShape3D = entry["shape"]
		source.add_faces(shape.get_faces(), entry["xform"])

	statics_parsed = 0
	if static_collision_mask != 0 and _terrain != null and _terrain.is_inside_tree():
		var tree := get_tree()
		var anchor := _ensure_parse_anchor()
		var parse_settings := settings().duplicate()
		parse_settings.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		# The mask is the flag: only these layers are collected, so obstacle
		# bodies can never also arrive here as geometry.
		parse_settings.geometry_collision_mask = static_collision_mask
		for coords: Vector2i in wanted:
			var group := static_group_name(coords)
			if tree.get_nodes_in_group(group).is_empty():
				continue
			parse_settings.geometry_source_group_name = group
			# parse_source_geometry_data() *clears* its target before filling it -
			# it does not append. Parsing N groups straight into one accumulator
			# leaves only the last group's geometry, which shows up as a navmesh
			# covering one chunk and nothing else. merge() is what accumulates.
			var partial := NavigationMeshSourceGeometryData3D.new()
			NavigationServer3D.parse_source_geometry_data(parse_settings, partial, anchor)
			source.merge(partial)
			statics_parsed += 1

	for coords: Vector2i in wanted:
		for obstruction: Dictionary in _obstruction_index.get(coords, []):
			source.add_projected_obstruction(
				obstruction["vertices"], obstruction["elevation"], obstruction["height"], true)

	return source


func _bake_one(index: int) -> void:
	var job : Dictionary = _jobs[index]
	# Already carries the template's settings plus this chunk's bake bounds.
	var nav_mesh : NavigationMesh = job["navmesh"]
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, job["source"])
	# Cleared only so the navigation debug draw does not outline the grown box.
	nav_mesh.filter_baking_aabb = AABB()

	# Snap to the map's own rasterisation grid. Polygon indices are untouched, so
	# this cannot change the mesh's topology - it only nudges coincident seam
	# vertices onto exactly equal coordinates, which is what lets the map pair
	# their edges by key instead of by the costly edge-connection search.
	var snap := _map_cell_size * 0.1
	var vertices := nav_mesh.get_vertices()
	for i in range(vertices.size()):
		vertices[i] = vertices[i].snappedf(snap)
	nav_mesh.set_vertices(vertices)

	job["baked"] = true


func _finish_bake() -> void:
	if _group_task_id != -1:
		WorkerThreadPool.wait_for_group_task_completion(_group_task_id)
		_group_task_id = -1
	bake_msec = (Time.get_ticks_usec() - _bake_start_usec) / 1000.0

	var start_usec := Time.get_ticks_usec()
	for job: Dictionary in _jobs:
		# Publishing an unbaked duplicate would hand a region an empty mesh, and
		# look exactly like a chunk that legitimately lost its polygons.
		if not bool(job["baked"]):
			continue
		var nav_mesh : NavigationMesh = job["navmesh"]
		_region_for(job["coords"]).navigation_mesh = nav_mesh
		_region_polygons[job["coords"]] = nav_mesh.get_polygon_count()

	# Totals kept per chunk and adjusted as regions are replaced. Walking every
	# live region to re-count was another O(map) cost on an O(dig) path.
	polygons = 0
	regions = 0
	for count: int in _region_polygons.values():
		if count > 0:
			regions += 1
			polygons += count
	publish_msec = (Time.get_ticks_usec() - start_usec) / 1000.0

	# A bake that produces nothing is the one failure mode that looks identical to
	# no bake at all, so it says so rather than leaving an empty map to be
	# discovered later by an agent that will not move.
	if polygons == 0 and not _jobs.is_empty():
		push_warning("MSTChunkedNavMesh: baked %d chunk(s) from %d source triangle(s) and got 0 polygons. Check that the terrain has walkable surface within agent_max_slope, and that bake_settings cell sizes are not larger than the features." % [
			_jobs.size(), source_triangles
		])

	var published := _jobs.size()
	_jobs.clear()
	bake_finished.emit(published, bake_msec + publish_msec)

#endregion


#region editor

## Bakes everything now and adopts the regions into the edited scene.
##
## Synchronous, unlike every runtime path: a tool button has to be finished when
## it returns, and there is no _process pumping the queue in the editor.
func _editor_bake() -> void:
	# Re-resolved rather than trusted, because terrain_path may have been
	# repointed since whatever last cached it.
	_terrain = null
	if not _resolve_terrain():
		push_error("MSTChunkedNavMesh: no MarchingSquaresTerrain found. Make this a child of one, or set terrain_path.")
		return
	if not _terrain_geometry_ready():
		push_error("MSTChunkedNavMesh: the terrain has no chunk collision to bake from yet. Let it finish loading, or regenerate its chunks, then bake again.")
		return

	rebuild()
	bake_now()
	_adopt_regions()

	print("[MSTChunkedNavMesh] baked %d chunk(s): %d polygon(s) over %d region(s), %d source triangle(s), %d chunk(s) parsed for statics. %.0f ms bake, %.1f ms publish." % [
		chunks_baked, polygons, regions, source_triangles, statics_parsed, bake_msec, publish_msec
	])
	if bake_on_ready:
		print("[MSTChunkedNavMesh] bake_on_ready is on, so the game will discard this and bake again at startup. Turn it off to keep what was just baked.")
	_mark_scene_unsaved()


func _editor_clear() -> void:
	# free() rather than queue_free(), so the scene tree and the inspector show
	# the result of pressing the button rather than the state before it.
	for child in get_children():
		if child is NavigationRegion3D:
			remove_child(child)
			child.free()
	_region_polygons.clear()
	polygons = 0
	regions = 0
	_mark_scene_unsaved()


## Gives every region an owner, which is what makes it save with the scene.
##
## The parse anchor deliberately gets none: it is scaffolding this node rebuilds
## on demand, and saving it would put a stray node in every level.
func _adopt_regions() -> void:
	var scene_root := get_tree().edited_scene_root
	if scene_root == null:
		return
	for child in get_children():
		if child is NavigationRegion3D:
			child.owner = scene_root


func _mark_scene_unsaved() -> void:
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

#endregion


#region regions and helpers

func _region_name(coords: Vector2i) -> String:
	return "%s_%d_%d" % [REGION_PREFIX, coords.x, coords.y]


func _region_for(coords: Vector2i) -> NavigationRegion3D:
	var region := get_node_or_null(_region_name(coords)) as NavigationRegion3D
	if region == null:
		region = NavigationRegion3D.new()
		region.name = _region_name(coords)
		add_child(region)
	# Baked vertices are in world space. Letting a region inherit this node's
	# transform would apply that offset a second time and land every navmesh one
	# chunk away, so it is pinned rather than left to the parent.
	region.global_transform = Transform3D.IDENTITY
	return region


## Identity-transform node the statics parse is rooted at.
##
## parse_source_geometry_data() returns geometry in the root node's *local*
## space, so a root that is positioned shifts the whole source away from the
## world-space bake boxes and every chunk bakes empty. Rather than requiring this
## node to sit at the origin, the parse gets its own anchor pinned there.
func _ensure_parse_anchor() -> Node3D:
	if is_instance_valid(_parse_anchor):
		return _parse_anchor
	_parse_anchor = Node3D.new()
	_parse_anchor.name = PARSE_ANCHOR_NAME
	add_child(_parse_anchor)
	_parse_anchor.global_transform = Transform3D.IDENTITY
	return _parse_anchor


## Moves the enabled-region window with the focus node, and only when it crosses
## into a new chunk - the update is O(regions) and would otherwise be a per-frame
## cost of exactly the kind it exists to remove.
func _follow_active_window() -> void:
	if active_radius_chunks <= 0:
		return
	var focus := get_node_or_null(active_focus_path) as Node3D
	if focus == null:
		return
	var centre := chunk_coords_for(focus.global_position)
	if centre == _active_centre:
		return
	_active_centre = centre
	set_active_radius(centre, active_radius_chunks)


func chunk_stride_x() -> float:
	if _terrain == null:
		return 1.0
	return float(_terrain.dimensions.x - 1) * _terrain.cell_size.x


func chunk_stride_z() -> float:
	if _terrain == null:
		return 1.0
	return float(_terrain.dimensions.z - 1) * _terrain.cell_size.y


func chunk_span() -> float:
	return maxf(chunk_stride_x(), chunk_stride_z())


func _find_terrain() -> MarchingSquaresTerrain:
	if not terrain_path.is_empty():
		return get_node_or_null(terrain_path) as MarchingSquaresTerrain
	return get_parent() as MarchingSquaresTerrain


func _resolve_terrain() -> bool:
	if is_instance_valid(_terrain):
		return true
	_terrain = _find_terrain()
	return _terrain != null

#endregion
