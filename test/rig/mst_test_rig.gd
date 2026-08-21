extends Node3D
class_name MSTTestRig
## Measurement rig for runtime-assembled, diggable cave terrain.
##
## This is not a demo. Every phase exists to confirm or falsify one specific
## claim about how the addon behaves at runtime. Run the scene, read the table
## printed to the output, and treat any FAILS line as the thing to design around.
##
## The suite runs twice, once per chunk dimension, because chunk size is the
## single biggest lever on the per-dig cost.


const CELL_SIZE : Vector2 = Vector2(2.0, 2.0)
## Chunk dimensions are in vertices; the metres in the export names are
## (dimensions.x - 1) * cell_size.x, which is the span a chunk actually covers.
const LARGE_DIMENSIONS : Vector3i = Vector3i(33, 32, 33)
const SMALL_DIMENSIONS : Vector3i = Vector3i(17, 32, 17)
const TINY_DIMENSIONS : Vector3i = Vector3i(9, 32, 9)
## Chunks per side in one bake batch on the large map.
##
## begin_bake() builds a single source for every job it is handed, so baking a
## thousand chunks in one call would give each of them the whole map to filter
## against. Batching keeps each source to a tile plus its border - which is the
## shape a streaming implementation needs anyway. 4 x 4 is 16 chunks, one per
## core on a typical machine.
const LARGE_MAP_BATCH : int = 4
const DIG_REPEATS : int = 5
## How many physics frames a nav query may retry before the failure is treated
## as a real missing connection rather than server sync latency.
const MAX_NAV_SYNC_FRAMES : int = 60
const NAV_SETTLE_FRAMES : int = 20
## How long to watch for the navigation map to publish a change before giving up.
##
## Deliberately much larger than MAX_NAV_SYNC_FRAMES: at 1024 regions the map was
## measured taking longer than a second, so a budget sized for a query retry
## reports "never" for something that does eventually arrive. The point is to get
## the real number, not a verdict.
const MAX_NAV_PUBLISH_FRAMES : int = 900
const NAV_SCALE_GRID : int = 5
const RECAST_NAV_GRID : int = 5
## Props per chunk in the Recast phase. Enough that a missed one is obvious in
## the clearance figures, few enough that no corridor is ever plugged.
const PROPS_PER_CHUNK : int = 6
## Pan speed as a fraction of the orbit distance, so it scales with zoom.
const CAMERA_PAN_SPEED : float = 0.9
const CAMERA_PAN_BOOST : float = 3.0
const AGENT_SPEED : float = 14.0

## Chunk sizes to run the suite at, as the span a chunk covers. Every selected
## size runs the whole suite again, so this is the single biggest lever on how
## long a run takes - and the point of selecting more than one is that chunk size
## is the biggest lever on per-dig cost too.
@export_flags("16 m (9x9):1", "32 m (17x17):2", "64 m (33x33):4") var chunk_sizes : int = 2
## Leaves the last assembled terrain in the scene with a camera so seams can be
## inspected by eye, and left-click digs a hole.
@export var interactive_after_run : bool = true
## Template every chunk's navigation mesh is duplicated from in phase 9, and the
## same resource that decides what source geometry gets parsed.
##
## Point it at test/rig/mst_recast_bake_settings.tres to tune the bake from the
## Inspector - agent metrics, the filters, the simplification knobs, and
## geometry_parsed_geometry_type / geometry_source_geometry_mode. Left null, the
## baker falls back to MSTTestRecastNav.default_settings().
##
## filter_baking_aabb and border_size are overwritten per chunk; whatever the
## resource carries for those two is ignored.
@export var recast_bake_settings : NavigationMesh
## Runs every measured terrain with terrain_lod_enabled on.
##
## Everything before this ran with LOD off, so assembly and dig timings taken
## with it on are not directly comparable to earlier logs - the report says which
## it was.
@export var enable_terrain_lod : bool = true
## Where phase 9 gets its source geometry. See MSTTestRecastNav.SourceMode.
##
## "Cached shapes" reads each chunk's collision proxy and merges a props source
## parsed once - worker-safe and scopeable to a few chunks, but the props are a
## snapshot that goes stale when one is destroyed. "Parsed group" parses
## everything in one group with SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN - always
## current and authoring-driven, but main-thread-only and unscoped.
@export_enum("Cached shapes", "Parsed group", "Parsed chunk groups", "Hybrid") var recast_source_mode : int = 0
## Supplies props to the bake as projected obstructions instead of as parsed
## collision geometry.
##
## A footprint polygon plus an elevation and a height, rather than a tessellated
## BoxShape3D or CylinderShape3D at ~266 triangles each. It also carves
## regardless of agent_max_climb, so the 1.2 m crates that sit inside the
## climb-test band should start blocking. Props are masked out of the parsed
## geometry by collision layer so they are not represented twice.
@export var recast_props_as_obstructions : bool = false
## Leave the navigation map's edge-connection margin switched on.
##
## Off is what the chunked-navmesh demo does, and its reasoning applies here:
## the margin exists to join regions whose edges do not line up, and every region
## this rig produces is edge-aligned by construction - that is what border_size
## trimming and vertex snapping are for. The feature is documented as costly, and
## it searches for neighbours across every free edge on the map, so its cost
## grows with total polygons rather than with what changed.
##
## Suspected cause of the map taking over a second to publish a change at 1024
## regions. Turning it on is the A/B; the seam claims are the tripwire if the
## regions turn out to need it after all.
@export var nav_edge_connections : bool = false
## Chunks either side of the walker whose nav regions stay enabled. 0 keeps them
## all enabled, which is what a 1024-region map does today.
##
## A disabled region leaves the navigation map, so this bounds both costs that
## grow with map size: what the server re-syncs when anything changes, and the
## polygon graph A* searches. Re-applied when the walker crosses into a new
## chunk, which is what a game would do.
@export_range(0, 64, 1) var nav_active_radius_chunks : int = 0

## Phases, in the order they run. Every one builds its own terrain from scratch,
## so switching off the ones you are not reading is a straight saving - the only
## shared cost is authoring the modules, which every phase needs.
##
## To iterate on navmesh work, leave `run_recast_nav` on and the rest off.
@export_group("Phases")
## Phase 1: naive vs direct assembly at 9 and 25 chunks. Four terrains, and the
## naive 5x5 is deliberately the slowest single measurement in the rig - proving
## add_chunk() is quadratic means paying the quadratic.
@export var run_assembly : bool = true
## Phases 2-4: seam checks, digging, and the border-dig case. Produces the
## terrain the interactive camera falls back to.
@export var run_seams_and_digging : bool = true
## Phase 5: two chunk regions, seam connection, block and reopen a corridor.
@export var run_navigation : bool = true
## Phase 6: worker-thread warm-up, threaded dig, collision continuity.
@export var run_threading : bool = true
## Phases 7-8: assembles and warms a full 5x5 cave, per-triangle then merged.
@export var run_nav_scale : bool = true
## Phase 9: bakes the same cave with Recast instead of the height-map merger,
## with props scattered on the floor. The only phase that answers "does the
## navmesh see decoration?".
@export var run_recast_nav : bool = true
## Phase 10: assembles a whole map at the chosen size and bakes it in tiles.
## Slow and memory-hungry by design - it exists to find where this stops working.
@export var run_large_map : bool = false
## Chunks per side for phase 10. At 32 m chunks, 32 x 32 is a square kilometre.
@export var large_map_chunks : Vector2i = Vector2i(32, 32)
@export_group("")

var _report : MSTTestReport
var _live_terrain : MarchingSquaresTerrain
var _live_nav_terrain : MarchingSquaresTerrain
var _camera : Camera3D
var _camera_yaw : float = 0.0
var _camera_pitch : float = -0.9
var _camera_target : Vector3 = Vector3.ZERO
var _camera_distance : float = 120.0
var _dig_count : int = 0
var _dig_in_flight : bool = false
var _agent_body : Node3D
var _agent : NavigationAgent3D
var _agent_target : Vector3 = Vector3.INF
var _active_nav_centre : Vector2i = Vector2i(-9999, -9999)
var _live_props : Node3D
var _live_statics : Node3D
var _recast_baker : MSTTestRecastNav
var _recast_terrain : MarchingSquaresTerrain
var _recast_obstructions : Array = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_report = MSTTestReport.new()
	_report.add_note("terrain_lod_enabled = %s on every measured terrain." % enable_terrain_lod)
	_setup_environment()
	# Every builder has to agree with the navigation map about cell size, or its
	# regions are rasterised onto a grid they were not built for. Read once, up
	# front, so a project that overrides navigation/3d/default_cell_size is
	# followed rather than assumed away.
	MSTTestNav.use_map_cell_size(self)
	var map := get_world_3d().navigation_map
	NavigationServer3D.map_set_use_edge_connections(map, nav_edge_connections)
	_report.add_note("Navigation map edge connections %s (margin %.2f)." % [
		"ON" if nav_edge_connections else "OFF - regions must meet by exact edge match",
		NavigationServer3D.map_get_edge_connection_margin(map)
	])
	await get_tree().process_frame

	# Smallest first: if a size is going to run out of memory on the large map,
	# better to have the cheaper results already printed.
	for entry: Array in [
		[1, "9x9", TINY_DIMENSIONS],
		[2, "17x17", SMALL_DIMENSIONS],
		[4, "33x33", LARGE_DIMENSIONS],
	]:
		if chunk_sizes & int(entry[0]) != 0:
			await _run_suite(String(entry[1]), entry[2] as Vector3i)

	_report.print_all()

	if interactive_after_run:
		_setup_camera()
	else:
		if is_instance_valid(_live_terrain):
			_live_terrain.queue_free()
		if is_instance_valid(_live_nav_terrain):
			_live_nav_terrain.queue_free()
		if is_instance_valid(_live_props):
			_live_props.queue_free()
		if is_instance_valid(_live_statics):
			_live_statics.queue_free()


#region suite

func _run_suite(suite: String, dimensions: Vector3i) -> void:
	var factory := MSTTestModules.new(dimensions, CELL_SIZE)
	await factory.open(self)

	var build_start := Time.get_ticks_usec()
	# Warm the module cache for a 5x5 layout so assembly timings measure paste
	# cost only, not module authoring.
	for coords: Vector2i in MSTTestAssembler.build_layout(Vector2i(5, 5)).keys():
		factory.module_for(MSTTestModules.mask_for_grid_slot(coords, Vector2i(5, 5)))
	_report.add_timing(suite, "0-author", "build %d modules" % factory.modules_built,
		(Time.get_ticks_usec() - build_start) / 1000.0, "one-off, editor-time work in a real project")

	if run_assembly:
		await _phase_assembly(suite, dimensions, factory)
	var terrain : MarchingSquaresTerrain = null
	if run_seams_and_digging:
		terrain = await _phase_seams_and_digging(suite, dimensions, factory)
	if run_navigation:
		await _phase_navigation(suite, dimensions, factory)
	if run_threading:
		await _phase_threading(suite, dimensions, factory)
	if run_nav_scale:
		await _phase_nav_scale(suite, dimensions, factory)
	if run_recast_nav:
		await _phase_recast_nav(suite, dimensions, factory)
	if run_large_map:
		await _phase_large_map(suite, dimensions, factory)

	factory.close()

	# Only phase 2-4 produces a terrain worth keeping. With it switched off the
	# previous suite's terrain must survive rather than be freed against a null.
	if terrain != null:
		if is_instance_valid(_live_terrain) and _live_terrain != terrain:
			_live_terrain.queue_free()
		_live_terrain = terrain


# Claim: pasting baked modules is near-instant because no meshing happens.
# Suspicion: add_chunk() calls _schedule_collision_refresh(), which at runtime
# rebuilds the collision proxy of every chunk already present, making assembly
# quadratic in chunk count.
func _phase_assembly(suite: String, dimensions: Vector3i, factory: MSTTestModules) -> void:
	var results : Dictionary = {}

	for grid_size: int in [3, 5]:
		for mode: String in ["naive", "fast"]:
			var layout := MSTTestAssembler.build_layout(Vector2i(grid_size, grid_size))
			var terrain : MarchingSquaresTerrain = await MSTTestAssembler.make_terrain(
				dimensions, CELL_SIZE, self, "Assembly_%s_%d_%s" % [suite, grid_size, mode], enable_terrain_lod)

			var start := Time.get_ticks_usec()
			if mode == "naive":
				MSTTestAssembler.assemble_naive(terrain, layout, factory)
			else:
				MSTTestAssembler.assemble_fast(terrain, layout, factory)
			var msec := (Time.get_ticks_usec() - start) / 1000.0

			var with_mesh := MSTTestAssembler.count_chunks_with_mesh(terrain)
			var with_collision := MSTTestAssembler.count_chunks_with_collision(terrain)
			results["%s_%d" % [mode, grid_size]] = msec

			_report.add_timing(suite, "1-assembly", "%s %dx%d (%d chunks)" % [mode, grid_size, grid_size, layout.size()],
				msec, "mesh %d/%d, collision %d/%d" % [with_mesh, layout.size(), with_collision, layout.size()])

			terrain.free()
			await get_tree().process_frame

	var naive_ratio := float(results["naive_5"]) / maxf(float(results["naive_3"]), 0.001)
	var fast_ratio := float(results["fast_5"]) / maxf(float(results["fast_3"]), 0.001)
	# 25 chunks against 9 is a 2.78x ratio if the cost is linear per chunk.
	var linear_ratio := 25.0 / 9.0
	var naive_is_quadratic := naive_ratio > linear_ratio * 1.8

	_report.add_claim(
		"assembly-linear",
		"[%s] Assembly through add_chunk() scales linearly with chunk count" % suite,
		not naive_is_quadratic,
		"naive 9->25 chunks scaled %.2fx (linear would be %.2fx); fast path scaled %.2fx" % [naive_ratio, linear_ratio, fast_ratio]
	)
	_report.add_claim(
		"assembly-fast",
		"[%s] Skipping the terrain-wide collision refresh makes assembly materially cheaper" % suite,
		float(results["fast_5"]) < float(results["naive_5"]) * 0.7,
		"5x5 naive %.2f ms vs fast %.2f ms" % [results["naive_5"], results["fast_5"]]
	)


# Claims: baked modules paste without seam cracks; a dig is cheap and localised;
# a border dig needs the shared vertex written in every chunk that owns it.
func _phase_seams_and_digging(suite: String, dimensions: Vector3i, factory: MSTTestModules) -> MarchingSquaresTerrain:
	var layout := MSTTestAssembler.build_layout(Vector2i(3, 3))
	var terrain : MarchingSquaresTerrain = await MSTTestAssembler.make_terrain(
		dimensions, CELL_SIZE, self, "Live_%s" % suite, enable_terrain_lod)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)
	MSTTestAssembler.refresh_lod(terrain)

	# Nav faces are read before anything regenerates cell geometry, because that
	# is the state a freshly assembled cave is actually in.
	var hydrated_faces := 0
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		hydrated_faces += MSTTestNav.walkable_face_count(terrain, chunk)
	_report.add_claim(
		"nav-needs-cells",
		"[%s] Chunks hydrated from baked MSTChunkData can produce nav faces without regenerating cell geometry" % suite,
		hydrated_faces > 0,
		"%d walkable faces across %d hydrated chunks" % [hydrated_faces, terrain.chunks.size()]
	)

	var rows := MSTTestSeams.check_height_rows(terrain)
	var borders := MSTTestSeams.check_mesh_borders(terrain)
	_report.add_claim(
		"seam-paste",
		"[%s] Pasted baked modules meet without cracks" % suite,
		int(rows["mismatched_vertices"]) == 0 and int(borders["unmatched"]) == 0,
		"%d seam pairs: %d mismatched height vertices, %d unmatched mesh vertices of %d checked" % [
			rows["pairs"], rows["mismatched_vertices"], borders["unmatched"], borders["vertices_checked"]
		]
	)

	# A dig into solid rock, diagonally clear of the central room and both
	# corridors, well inside one chunk at either dimension setting. Repeated in
	# place with alternating heights so every pass does real work.
	var rock_offset := MSTTestModules.PASSAGE_HALF_WIDTH + 3
	var interior := Vector2i(floori(dimensions.x / 2.0) + rock_offset, floori(dimensions.z / 2.0) + rock_offset)
	# The first dig on a hydrated chunk is reported separately: a chunk pasted
	# from baked data carries no cell_geometry, so the first regenerate_mesh has
	# to build every cell before it can touch the dug one.
	var first : Dictionary = {}
	var best : Dictionary = {}
	var steady_total := 0.0
	for i in range(DIG_REPEATS):
		var height : float = MSTTestModules.FLOOR_HEIGHT if i % 2 == 0 else MSTTestModules.WALL_HEIGHT
		var result := MSTTestDig.dig_area(terrain, interior, Vector2i(2, 2), height, true)
		if i == 0:
			first = result
			continue
		steady_total += float(result["total_msec"])
		if best.is_empty() or float(result["total_msec"]) < float(best["total_msec"]):
			best = result
	var steady_mean := steady_total / float(DIG_REPEATS - 1)

	_report.add_timing(suite, "3-dig", "first dig on a pasted chunk", float(first["total_msec"]),
		"cold: chunk had no cell geometry")
	_report.add_timing(suite, "3-dig", "steady-state dig (mean of %d)" % (DIG_REPEATS - 1), steady_mean,
		"%d chunk(s) affected" % best["chunks_affected"])
	_report.add_timing(suite, "3-dig", "  mesh regenerate", float(best["mesh_msec"]), "best steady sample")
	_report.add_timing(suite, "3-dig", "  collision rebuild", float(best["collision_msec"]), "whole-chunk proxy, no partial path")
	_report.add_timing(suite, "3-dig", "  nav face extract", float(best["nav_msec"]),
		"%d faces, whole-chunk pass" % best["nav_faces"])

	_report.add_claim(
		"dig-uniform-cost",
		"[%s] A dig costs the same whether or not the chunk has been dug before" % suite,
		float(first["total_msec"]) < steady_mean * 2.0,
		"first dig %.2f ms vs steady-state mean %.2f ms" % [first["total_msec"], steady_mean]
	)

	# Border dig, done correctly and then incorrectly, to show the difference.
	# Both sites stay inside the same chunk row at either dimension setting.
	var border_x := MSTTestDig.east_border_vertex_x(terrain, 0)
	var border_z := floori(dimensions.z / 2.0)
	var correct := MSTTestDig.dig_area(terrain, Vector2i(border_x - 1, border_z - 2), Vector2i(3, 2), MSTTestModules.FLOOR_HEIGHT - 2.0, true)
	var after_correct := MSTTestSeams.check_mesh_borders(terrain)
	var wrong := MSTTestDig.dig_area(terrain, Vector2i(border_x - 1, border_z + 1), Vector2i(3, 2), MSTTestModules.FLOOR_HEIGHT - 2.0, false)
	var after_wrong := MSTTestSeams.check_mesh_borders(terrain)

	_report.add_timing(suite, "4-seam-dig", "border dig (both chunks)", float(correct["total_msec"]),
		"%d chunks affected" % correct["chunks_affected"])
	_report.add_timing(suite, "4-seam-dig", "border dig (one chunk)", float(wrong["total_msec"]),
		"%d chunks affected" % wrong["chunks_affected"])
	_report.add_claim(
		"seam-dig",
		"[%s] A border dig needs the shared vertex written in every chunk that owns it" % suite,
		int(after_correct["unmatched"]) == 0 and int(after_wrong["unmatched"]) > 0,
		"unmatched border vertices: %d after the correct write, %d after the single-chunk write" % [
			after_correct["unmatched"], after_wrong["unmatched"]
		]
	)

	return terrain


# Claim: per-chunk nav regions connect across seams on their own, and a dig only
# needs the dug chunk's region rebuilt.
func _phase_navigation(suite: String, dimensions: Vector3i, factory: MSTTestModules) -> void:
	var layout : Dictionary = {
		Vector2i(0, 0): MSTTestModules.OPEN_E,
		Vector2i(1, 0): MSTTestModules.OPEN_W,
	}
	# The previous suite's nav terrain has to leave the navigation map before this
	# one is measured, otherwise its regions are still counted and its polygons
	# sit close enough to confuse the query.
	if is_instance_valid(_live_nav_terrain):
		_live_nav_terrain.queue_free()
		_live_nav_terrain = null
		await get_tree().physics_frame
		await get_tree().physics_frame

	var terrain : MarchingSquaresTerrain = await MSTTestAssembler.make_terrain(
		dimensions, CELL_SIZE, self, "Nav_%s" % suite, enable_terrain_lod)
	# Parked just north of the live terrain so both are visible at once with
	# Debug > Visible Navigation switched on.
	terrain.position = Vector3(0.0, 0.0, -float(dimensions.z - 1) * CELL_SIZE.y * 2.0)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)
	MSTTestAssembler.refresh_lod(terrain)

	var build_start := Time.get_ticks_usec()
	var built := MSTTestNav.build_all_regions(terrain)
	_report.add_timing(suite, "5-nav", "build %d chunk regions" % built["regions"],
		(Time.get_ticks_usec() - build_start) / 1000.0,
		"%d polygons, %d chunks needed cell geometry" % [built["polygons"], built["chunks_regenerated"]])
	_report.add_note("[%s] %d nav polygons per chunk region: one per walkable triangle. Neither the addon's builder nor this rig merges coplanar triangles into convex polygons." % [
		suite, floori(float(built["polygons"]) / float(maxi(int(built["regions"]), 1)))
	])
	_report.add_note("[%s] Walkable faces include the flat tops of the rock walls, because a heightmap has no ceiling. Agents get a second walkable layer up there unless navmesh_permission excludes it." % suite)

	var from := MSTTestNav.chunk_centre(terrain, Vector2i(0, 0)) + terrain.position
	var to := MSTTestNav.chunk_centre(terrain, Vector2i(1, 0)) + terrain.position
	var connected : Dictionary = await MSTTestNav.try_path_until(terrain, from, to, get_tree(), MAX_NAV_SYNC_FRAMES)
	var seam_gap := INF
	if connected["points"] > 0:
		seam_gap = MSTTestNav.distance_from_seam(terrain, connected["end"], 1)
	_report.add_claim(
		"nav-seam-connect",
		"[%s] Per-chunk nav regions connect across a seam with no manual links" % suite,
		bool(connected["reached"]),
		"%d regions, edge margin %.2f, force_update=%s, %d attempt(s) over %d frames; %d points, ended %.2f m from target and %.2f m from the seam" % [
			connected["regions"], connected["margin"], connected["forced"], connected["attempts"],
			MAX_NAV_SYNC_FRAMES, connected["points"], connected["end_distance"], seam_gap
		]
	)
	_report.add_timing(suite, "5-nav", "frames until the seam path works", float(connected["attempts"]),
		"physics frames after the regions were built" if bool(connected["reached"]) else "never succeeded within the budget")

	# Wall the corridor off at the seam, rebuild only the affected regions, and
	# confirm the map notices.
	var border_x := MSTTestDig.east_border_vertex_x(terrain, 0)
	var mid_z := floori(dimensions.z / 2.0)
	MSTTestDig.dig_area(terrain, Vector2i(border_x - 1, mid_z - MSTTestModules.PASSAGE_HALF_WIDTH - 1),
		Vector2i(3, MSTTestModules.PASSAGE_HALF_WIDTH * 2 + 3), MSTTestModules.WALL_HEIGHT, true)
	var rebuild_start := Time.get_ticks_usec()
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		MSTTestNav.build_region(terrain, chunk)
	var rebuild_msec := (Time.get_ticks_usec() - rebuild_start) / 1000.0
	_report.add_timing(suite, "5-nav", "rebuild 2 chunk regions after a dig", rebuild_msec,
		"per-chunk rebuild, no terrain-wide bake")

	for _i in range(NAV_SETTLE_FRAMES):
		await get_tree().physics_frame
	var blocked := MSTTestNav.try_path(terrain, from, to)

	# Dig it back open and confirm the route returns.
	MSTTestDig.dig_area(terrain, Vector2i(border_x - 1, mid_z - MSTTestModules.PASSAGE_HALF_WIDTH),
		Vector2i(3, MSTTestModules.PASSAGE_HALF_WIDTH * 2 + 1), MSTTestModules.FLOOR_HEIGHT, true)
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		MSTTestNav.build_region(terrain, chunk)
	var reopened : Dictionary = await MSTTestNav.try_path_until(terrain, from, to, get_tree(), MAX_NAV_SYNC_FRAMES)

	_report.add_claim(
		"nav-repath",
		"[%s] Blocking and reopening a corridor is reflected after rebuilding only the dug chunks' regions" % suite,
		not bool(blocked["reached"]) and bool(reopened["reached"]),
		"blocked reached=%s (%.2f m) after %d settle frames; reopened reached=%s (%.2f m) in %d attempt(s)" % [
			blocked["reached"], blocked["end_distance"], NAV_SETTLE_FRAMES,
			reopened["reached"], reopened["end_distance"], reopened["attempts"]
		]
	)

	if is_instance_valid(_live_nav_terrain):
		_live_nav_terrain.queue_free()
	_live_nav_terrain = terrain


# Claims: warming a pasted chunk on a worker removes the cold-dig spike; a
# threaded dig leaves only publication on the main thread; and swapping the
# collision shape instead of rebuilding it closes the frame-long gap where a
# synchronous dig leaves the chunk with no collision at all.
func _phase_threading(suite: String, dimensions: Vector3i, factory: MSTTestModules) -> void:
	var layout := MSTTestAssembler.build_layout(Vector2i(2, 2))
	var terrain : MarchingSquaresTerrain = await MSTTestAssembler.make_terrain(
		dimensions, CELL_SIZE, self, "Threaded_%s" % suite, enable_terrain_lod)
	terrain.position = Vector3(0.0, 0.0, float(dimensions.z - 1) * CELL_SIZE.y * 4.0)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)

	# attach_fast() skips add_chunk(), and add_chunk() is the only runtime path
	# that builds LOD proxies, so they have to be asked for explicitly.
	var lod_proxies_built := MSTTestAssembler.refresh_lod(terrain)

	var chunks : Array = terrain.chunks.values()
	var probe : MarchingSquaresTerrainChunk = terrain.chunks[Vector2i(0, 0)]

	# Does a synchronous dig really leave the chunk collision-less? regenerate_mesh()
	# frees every StaticBody3D and only queues the rebuild, one chunk per frame.
	probe.draw_height(2, 2, MSTTestModules.WALL_HEIGHT)
	probe.regenerate_mesh(false)
	var collision_after_sync := MSTTestThreadedDig.has_collision(probe)
	probe.rebuild_collision()
	_report.add_claim(
		"collision-gap-sync",
		"[%s] A synchronous dig keeps the chunk's collision between regenerate_mesh() and the queued rebuild" % suite,
		collision_after_sync,
		"collision present immediately after regenerate_mesh(): %s" % collision_after_sync
	)

	# Warm every pasted chunk's cell geometry on a worker, without republishing
	# any mesh tiles, then see whether the cold-dig spike is gone.
	var warm_msec := MSTTestThreadedDig.warm_chunks(chunks)
	_report.add_timing(suite, "6-threaded", "warm %d chunks on a worker" % chunks.size(), warm_msec,
		"cell geometry only, no tiles republished")

	# Regions have to exist before the threaded dig, otherwise the worker skips
	# the navmesh entirely and the main-thread figure below flatters itself.
	var built := MSTTestNav.build_all_regions(terrain)
	_report.add_timing(suite, "6-threaded", "build %d chunk regions" % built["regions"], 0.0,
		"so the threaded dig below includes nav work")

	var rock_offset := MSTTestModules.PASSAGE_HALF_WIDTH + 3
	var site := Vector2i(floori(dimensions.x / 2.0) + rock_offset, floori(dimensions.z / 2.0) + rock_offset)
	var after_warm := MSTTestDig.dig_area(terrain, site, Vector2i(2, 2), MSTTestModules.FLOOR_HEIGHT, true)
	var steady := MSTTestDig.dig_area(terrain, site, Vector2i(2, 2), MSTTestModules.WALL_HEIGHT, true)
	_report.add_timing(suite, "6-threaded", "first dig after worker warm-up", float(after_warm["total_msec"]),
		"compare with the cold first dig in phase 3")
	_report.add_claim(
		"warm-then-dig",
		"[%s] After a worker-thread warm-up, the first dig costs no more than a later one" % suite,
		float(after_warm["total_msec"]) < float(steady["total_msec"]) * 2.0,
		"first dig after warm-up %.2f ms vs next dig %.2f ms" % [after_warm["total_msec"], steady["total_msec"]]
	)

	# Now the threaded dig itself, against a synchronous one on the same terrain.
	var sync_reference := MSTTestDig.dig_area(terrain, site + Vector2i(3, 0), Vector2i(2, 2), MSTTestModules.FLOOR_HEIGHT, true)

	# Counted here, not at assembly. The synchronous digs above went through
	# regenerate_mesh(), which frees a LOD proxy and leaves the rebuild to a flag
	# nothing acts on at runtime - so some are already gone by this point, and
	# folding that into the claim would blame the threaded dig for it.
	var lod_proxies_before := MSTTestThreadedDig.count_lod_proxies(terrain)

	var job := MSTTestThreadedDig.new()
	job.start(terrain, site + Vector2i(3, 0), Vector2i(2, 2), MSTTestModules.WALL_HEIGHT)
	while job.is_running():
		job.sample_collision()
		await get_tree().process_frame
	job.publish()

	var main_thread_msec := job.main_thread_msec()
	_report.add_timing(suite, "6-threaded", "threaded dig: main thread total", main_thread_msec,
		"prologue %.2f + join %.2f + publish %.2f" % [job.prologue_msec, job.join_msec, job.publish_msec])
	_report.add_timing(suite, "6-threaded", "threaded dig: worker", job.worker_msec,
		"%d frame(s) in flight" % job.frames_in_flight)
	_report.add_timing(suite, "6-threaded", "same dig done synchronously", float(sync_reference["total_msec"]),
		"for comparison, all on the main thread")

	_report.add_claim(
		"threaded-dig-residue",
		"[%s] A threaded dig leaves less than half the synchronous cost on the main thread" % suite,
		main_thread_msec < float(sync_reference["total_msec"]) * 0.5,
		"main thread %.2f ms (prologue %.2f + join %.2f + publish %.2f) vs %.2f ms synchronous; worker did %.2f ms" % [
			main_thread_msec, job.prologue_msec, job.join_msec, job.publish_msec,
			sync_reference["total_msec"], job.worker_msec
		]
	)
	# A dug chunk that loses its LOD proxy renders nothing past
	# terrain_lod_start_distance, because _configure_proxy_visibility() caps its
	# real tiles at exactly that distance. So "the proxy survived a dig" is a
	# claim about whether a hole appears in the far view, not about tidiness.
	if enable_terrain_lod:
		var lod_proxies_after := MSTTestThreadedDig.count_lod_proxies(terrain)
		_report.add_timing(suite, "6-threaded", "rebuild LOD proxies after the dig", maxf(job.lod_msec, 0.0),
			"included in publish" if job.lod_msec >= 0.0 else "no LOD controller on this addon build")
		_report.add_claim(
			"lod-survives-threaded-dig",
			"[%s] A threaded dig leaves every chunk with a live LOD proxy" % suite,
			lod_proxies_before > 0 and lod_proxies_after == lod_proxies_before,
			"%d proxies before the threaded dig, %d after; %d were built at assembly, so %d had already been lost to the synchronous digs above - regenerate_mesh() frees a proxy and nothing at runtime rebuilds it" % [
				lod_proxies_before, lod_proxies_after, lod_proxies_built,
				lod_proxies_built - lod_proxies_before
			]
		)

	_report.add_claim(
		"collision-gap-threaded",
		"[%s] A threaded dig keeps collision on every frame the job is in flight" % suite,
		job.frames_without_collision == 0,
		"%d of %d in-flight frame(s) had no collision" % [job.frames_without_collision, job.frames_in_flight]
	)

	terrain.queue_free()


# Two regions synced in ten frames. This asks whether that holds when a whole
# cave is on the map, because the per-chunk region scheme only pays off if
# updating one region stays cheap while twenty-five of them exist.
func _phase_nav_scale(suite: String, dimensions: Vector3i, factory: MSTTestModules) -> void:
	# The phase 5 nav terrain has to leave the map first, otherwise its two
	# regions are counted alongside the cave's twenty-five.
	if is_instance_valid(_live_nav_terrain):
		_live_nav_terrain.queue_free()
		_live_nav_terrain = null
		await get_tree().physics_frame
		await get_tree().physics_frame

	var layout := MSTTestAssembler.build_layout(Vector2i(NAV_SCALE_GRID, NAV_SCALE_GRID))
	var terrain : MarchingSquaresTerrain = await MSTTestAssembler.make_terrain(
		dimensions, CELL_SIZE, self, "NavScale_%s" % suite, enable_terrain_lod)
	terrain.position = Vector3(float(dimensions.x - 1) * CELL_SIZE.x * 6.0, 0.0, 0.0)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)
	MSTTestAssembler.refresh_lod(terrain)

	var chunks : Array = terrain.chunks.values()
	var warm_msec := MSTTestThreadedDig.warm_chunks(chunks)
	_report.add_timing(suite, "7-nav-scale", "warm %d chunks on a worker" % chunks.size(), warm_msec,
		"%.1f ms per chunk" % (warm_msec / maxf(float(chunks.size()), 1.0)))

	var build_start := Time.get_ticks_usec()
	var built := MSTTestNav.build_all_regions(terrain)
	_report.add_timing(suite, "7-nav-scale", "build %d chunk regions" % built["regions"],
		(Time.get_ticks_usec() - build_start) / 1000.0, "%d polygons total" % built["polygons"])

	# Corner to opposite corner, crossing every seam on the diagonal.
	var far := NAV_SCALE_GRID - 1
	var from := MSTTestNav.chunk_centre(terrain, Vector2i(0, 0)) + terrain.position
	var to := MSTTestNav.chunk_centre(terrain, Vector2i(far, far)) + terrain.position
	var crossed : Dictionary = await MSTTestNav.try_path_until(terrain, from, to, get_tree(), MAX_NAV_SYNC_FRAMES)
	_report.add_timing(suite, "7-nav-scale", "frames until a cross-cave path works", float(crossed["attempts"]),
		"physics frames" if bool(crossed["reached"]) else "never succeeded within the budget")
	_report.add_claim(
		"nav-scale-queryable",
		"[%s] A %d-chunk cave becomes queryable in no more frames than a 2-chunk one" % [suite, chunks.size()],
		bool(crossed["reached"]) and int(crossed["attempts"]) <= 15,
		"%d regions, %d polygons; corner-to-corner path took %d attempt(s), %d points, ended %.2f m from target" % [
			crossed["regions"], built["polygons"], crossed["attempts"], crossed["points"], crossed["end_distance"]
		]
	)

	# Where did the start point actually land? If the y is the wall height rather
	# than the floor, the query snapped to the rock tops and every result below
	# is about the wrong walkable layer.
	var start_on_map := MSTTestNav.closest_point(terrain, from)
	_report.add_note("[%s] Query start snapped to y=%.2f (floor is %.1f, rock top is %.1f)." % [
		suite, start_on_map.y, MSTTestModules.FLOOR_HEIGHT, MSTTestModules.WALL_HEIGHT
	])

	# Walk the cave chunk by chunk to find where connectivity actually breaks.
	var hops : Array = []
	for x in range(1, NAV_SCALE_GRID):
		hops.append(Vector2i(x, 0))
	for z in range(1, NAV_SCALE_GRID):
		hops.append(Vector2i(NAV_SCALE_GRID - 1, z))
	# Each seam asked on its own. The hop ladder cannot tell a broken seam apart
	# from long paths failing generally; this can.
	var pairs := MSTTestNav.adjacent_pair_failures(terrain, NAV_SCALE_GRID)
	_report.add_claim(
		"nav-scale-adjacent-pairs",
		"[%s] Every directly adjacent chunk pair can path to its neighbour" % suite,
		int(pairs["failed"]) == 0,
		"%d of %d adjacent pairs failed%s" % [
			pairs["failed"], pairs["tested"],
			"" if int(pairs["failed"]) == 0 else "; first: " + str(pairs["first"])
		]
	)

	var broke := MSTTestNav.first_unreachable_hop(terrain, from, hops)
	_report.add_claim(
		"nav-scale-every-hop",
		"[%s] Every chunk along the cave edge is reachable one hop at a time" % suite,
		int(broke["index"]) < 0,
		"all %d hops reachable" % hops.size() if int(broke["index"]) < 0 else
			"first failure at hop %d, chunk %s: %d points, ended %.2f m short" % [
				broke["index"], str(broke["coords"]), broke["points"], broke["end_distance"]
			]
	)

	# Query cost on a settled map, averaged so one sample cannot mislead.
	var query_total := 0.0
	var query_points := 0
	for _i in range(5):
		var query := MSTTestNav.query_msec(terrain, from, to)
		query_total += float(query["msec"])
		query_points = int(query["points"])
	_report.add_timing(suite, "7-nav-scale", "cross-cave path query (mean of 5)", query_total / 5.0,
		"%d points across %d chunks" % [query_points, chunks.size()])
	_report.add_claim(
		"nav-scale-query-cost",
		"[%s] A path across the whole cave costs under 2 ms to query" % suite,
		query_total / 5.0 < 2.0,
		"mean %.3f ms over 5 queries, %d points" % [query_total / 5.0, query_points]
	)

	# The operational question: after digging one chunk, what does updating just
	# that chunk's region cost on the main thread while the rest of the cave sits
	# on the same map?
	var rock_offset := MSTTestModules.PASSAGE_HALF_WIDTH + 3
	var middle := Vector2i(floori(dimensions.x / 2.0), floori(dimensions.z / 2.0))
	var stride_x := dimensions.x - 1
	var stride_z := dimensions.z - 1
	var site := Vector2i(2 * stride_x + middle.x + rock_offset, 2 * stride_z + middle.y + rock_offset)
	MSTTestDig.dig_area(terrain, site, Vector2i(2, 2), MSTTestModules.FLOOR_HEIGHT, true)

	var dug_chunk : MarchingSquaresTerrainChunk = terrain.chunks[Vector2i(2, 2)]
	var region_start := Time.get_ticks_usec()
	MSTTestNav.build_region(terrain, dug_chunk)
	var region_msec := (Time.get_ticks_usec() - region_start) / 1000.0
	var sync_msec := MSTTestNav.force_update_msec(terrain)

	_report.add_timing(suite, "7-nav-scale", "rebuild 1 region of %d" % chunks.size(), region_msec,
		"one chunk's navmesh")
	_report.add_timing(suite, "7-nav-scale", "map_force_update with %d regions" % chunks.size(), sync_msec,
		"synchronous, lands on the main thread")
	_report.add_claim(
		"nav-scale-update-cost",
		"[%s] Updating one region on a %d-region map stays under 5 ms on the main thread" % [suite, chunks.size()],
		region_msec + sync_msec < 5.0,
		"region rebuild %.2f ms + map_force_update %.2f ms = %.2f ms" % [region_msec, sync_msec, region_msec + sync_msec]
	)

	# Geometry check at scale. If the seams are clean here too, then nothing about
	# the failures above is the terrain's fault and it is all navmesh.
	var borders := MSTTestSeams.check_mesh_borders(terrain)
	_report.add_claim(
		"nav-scale-seams",
		"[%s] The %d-chunk cave has clean seams, so any path failure is navmesh not geometry" % [suite, chunks.size()],
		int(borders["unmatched"]) == 0,
		"%d seam pairs: %d unmatched mesh vertices of %d checked" % [
			borders["pairs"], borders["unmatched"], borders["vertices_checked"]
		]
	)

	# Rebuild every region as merged rectangles and re-run the same queries. One
	# polygon per triangle is the prime suspect for the failures above, and
	# merging is wanted regardless for query and rebuild cost.
	var merge_start := Time.get_ticks_usec()
	var merged := MSTTestNav.build_all_merged_regions(terrain)
	_report.add_timing(suite, "8-nav-merged", "rebuild %d regions merged" % merged["regions"],
		(Time.get_ticks_usec() - merge_start) / 1000.0,
		"%d polygons, down from %d" % [merged["polygons"], built["polygons"]])
	_report.add_claim(
		"nav-merged-polycount",
		"[%s] Merging coplanar cells cuts the navmesh to under a tenth of the polygons" % suite,
		int(merged["polygons"]) * 10 < int(built["polygons"]),
		"%d merged polygons vs %d per-triangle" % [merged["polygons"], built["polygons"]]
	)

	var merged_crossed : Dictionary = await MSTTestNav.try_path_until(terrain, from, to, get_tree(), MAX_NAV_SYNC_FRAMES)
	_report.add_claim(
		"nav-merged-queryable",
		"[%s] With a merged navmesh, a corner-to-corner path across the cave succeeds" % suite,
		bool(merged_crossed["reached"]),
		"%d attempt(s), %d points, ended %.2f m from target" % [
			merged_crossed["attempts"], merged_crossed["points"], merged_crossed["end_distance"]
		]
	)
	var merged_broke := MSTTestNav.first_unreachable_hop(terrain, from, hops)
	_report.add_claim(
		"nav-merged-every-hop",
		"[%s] With a merged navmesh, every chunk along the cave edge is reachable" % suite,
		int(merged_broke["index"]) < 0,
		"all %d hops reachable" % hops.size() if int(merged_broke["index"]) < 0 else
			"first failure at hop %d, chunk %s, ended %.2f m short" % [
				merged_broke["index"], str(merged_broke["coords"]), merged_broke["end_distance"]
			]
	)

	var merged_pairs := MSTTestNav.adjacent_pair_failures(terrain, NAV_SCALE_GRID)
	_report.add_claim(
		"nav-merged-adjacent-pairs",
		"[%s] With a merged navmesh, every adjacent chunk pair can path to its neighbour" % suite,
		int(merged_pairs["failed"]) == 0,
		"%d of %d adjacent pairs failed%s" % [
			merged_pairs["failed"], merged_pairs["tested"],
			"" if int(merged_pairs["failed"]) == 0 else "; first: " + str(merged_pairs["first"])
		]
	)

	var merged_query_total := 0.0
	for _i in range(5):
		merged_query_total += float(MSTTestNav.query_msec(terrain, from, to)["msec"])
	_report.add_timing(suite, "8-nav-merged", "cross-cave path query (mean of 5)", merged_query_total / 5.0,
		"compare with the per-triangle figure above")

	var merged_region_start := Time.get_ticks_usec()
	MSTTestNav.build_merged_region(terrain, dug_chunk)
	var merged_region_msec := (Time.get_ticks_usec() - merged_region_start) / 1000.0
	_report.add_timing(suite, "8-nav-merged", "rebuild 1 merged region of %d" % chunks.size(), merged_region_msec,
		"compare with %.2f ms per-triangle" % region_msec)

	# Kept in the scene: this is the only terrain with a full set of nav regions,
	# so it is the one worth looking at with Debug > Visible Navigation on.
	_live_nav_terrain = terrain


# Claims: a chunked Recast bake sees decoration that the height-map merger cannot
# see at all; the bakes parallelise over the worker pool; the per-chunk regions
# still meet across seams; and one chunk can be re-baked after a dig cheaply
# enough to matter.
#
# The merger is not being replaced here. It reads height_map and nothing else,
# which is why it is fast and why it is blind. This phase measures the other
# trade.
## All three bakers in phase 9 share one template, so the parallel-vs-serial and
## whole-chunk-vs-trimmed comparisons differ only in the thing being compared.
func _make_recast_baker() -> MSTTestRecastNav:
	var baker := MSTTestRecastNav.new()
	baker.bake_settings = recast_bake_settings
	baker.source_mode = recast_source_mode as MSTTestRecastNav.SourceMode
	baker.obstructions = _recast_obstructions
	if recast_props_as_obstructions:
		# Masked out of every parse, so a prop supplied as an obstruction is not
		# also collected as a collider.
		baker.exclude_collision_mask = MSTTestProps.COLLISION_LAYER
	# Parsed geometry arrives in the root node's local space, and the rig node is
	# the identity-transform node here. The terrain is not - it is parked away
	# from the origin so the suites do not overlap.
	baker.parse_root = self
	return baker


func _phase_recast_nav(suite: String, dimensions: Vector3i, factory: MSTTestModules) -> void:
	# Only one set of regions may be on the navigation map while clearances are
	# measured, or a query lands on the other terrain's polygons.
	if is_instance_valid(_live_nav_terrain):
		_live_nav_terrain.queue_free()
		_live_nav_terrain = null
	if is_instance_valid(_live_props):
		_live_props.queue_free()
		_live_props = null
	if is_instance_valid(_live_statics):
		_live_statics.queue_free()
		_live_statics = null
	for _i in range(2):
		await get_tree().physics_frame

	var layout := MSTTestAssembler.build_layout(Vector2i(RECAST_NAV_GRID, RECAST_NAV_GRID))
	var terrain : MarchingSquaresTerrain = await MSTTestAssembler.make_terrain(
		dimensions, CELL_SIZE, self, "Recast_%s" % suite, enable_terrain_lod)
	terrain.position = Vector3(
		float(dimensions.x - 1) * CELL_SIZE.x * 6.0,
		0.0,
		float(dimensions.z - 1) * CELL_SIZE.y * 7.0
	)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)
	# With LOD on, real tiles are capped at terrain_lod_start_distance and this is
	# the only runtime path that builds the proxies that take over past it.
	MSTTestAssembler.refresh_lod(terrain)

	# Decoration: geometry that exists in the scene but not in the height map.
	var props := MSTTestProps.scatter(terrain, PROPS_PER_CHUNK, self)
	var prop_centres := MSTTestProps.centres(props)
	_live_props = props
	# Irregular geometry an obstruction cannot describe: a deck with a gap under
	# it. This is what the hybrid's parsed lane is for, and it puts two walkable
	# layers in one column, which nothing before this phase covered.
	var statics := MSTTestStatics.scatter_bridges(terrain, self)
	_live_statics = statics

	# Grouping the parents, not the bodies: the addon only adds navmesh_* groups
	# to chunk collision bodies in its editor-only branch, so at runtime they
	# carry none - and WITH_CHILDREN recursion means they do not need to.
	MSTTestRecastNav.new().register_group([terrain, props, statics])

	var far := RECAST_NAV_GRID - 1
	var from := MSTTestNav.chunk_centre(terrain, Vector2i(0, 0)) + terrain.position
	var to := MSTTestNav.chunk_centre(terrain, Vector2i(far, far)) + terrain.position

	# --- the merger, on the same terrain, for the contrast --------------------
	# Vertices are snapped to the navigation map's own rasterisation grid rather
	# than to 0.01, which is what the chunked-navmesh demo does and is strictly
	# safer: two vertices the map already treats as one can no longer weld apart.
	var snap := MSTTestNav.use_map_cell_size(terrain)
	var merged_start := Time.get_ticks_usec()
	var merged := MSTTestNav.build_all_merged_regions(terrain)
	var merged_msec := (Time.get_ticks_usec() - merged_start) / 1000.0
	_report.add_timing(suite, "9-recast", "merger: build %d regions" % merged["regions"], merged_msec,
		"%d polygons, height map only, vertices snapped to %.3f" % [merged["polygons"], snap])
	for _i in range(NAV_SETTLE_FRAMES):
		await get_tree().physics_frame
	var merged_clearance := MSTTestProps.nav_clearance(terrain, prop_centres)
	var merged_path := MSTTestNav.try_path(terrain, from, to)

	MSTTestNav.clear_regions(terrain)
	for _i in range(NAV_SETTLE_FRAMES):
		await get_tree().physics_frame

	# --- Recast, demo-faithful: grow by a whole chunk, bake in parallel -------
	var baker := _make_recast_baker()
	baker.parse_sources([props, statics])
	var prepared := baker.prepare(terrain)
	# Per-chunk groups need the terrain resolved, so this follows prepare().
	# Registering them always, whatever mode is selected, keeps the source-mode
	# comparison below honest.
	# Chunk groups carry everything that gets parsed in that mode. The hybrid's
	# static groups carry only what its parsed lane should collect - the props go
	# in too when they are not being supplied as obstructions, so every mode ends
	# up describing the same world.
	var grouped_nodes := baker.register_chunk_groups([props, statics])
	var static_roots : Array = [statics] if recast_props_as_obstructions else [statics, props]
	var statics_grouped := baker.register_statics(static_roots)
	# Needs the terrain resolved, so it follows prepare(). Bakers made after this
	# pick the list up through _make_recast_baker().
	_recast_obstructions = _build_obstructions(baker, props)
	baker.obstructions = _recast_obstructions
	baker.bake()
	baker.publish()

	_report.add_note("[%s] Bake settings from %s: cell %.2f/%.2f, agent radius %.2f height %.2f climb %.2f slope %.0f, parsed geometry type %d, source mode %d." % [
		suite,
		recast_bake_settings.resource_path if recast_bake_settings != null and not recast_bake_settings.resource_path.is_empty()
			else ("an inline resource" if recast_bake_settings != null else "MSTTestRecastNav.default_settings()"),
		baker.cell_size, baker.cell_height, baker.agent_radius, baker.agent_height,
		baker.agent_max_climb, baker.agent_max_slope,
		baker.settings().geometry_parsed_geometry_type, baker.settings().geometry_source_geometry_mode
	])
	_report.add_note("[%s] Source mode %d (%s); props supplied as %s." % [
		suite, recast_source_mode,
		["cached shapes", "one parsed group", "parsed chunk groups", "hybrid"][recast_source_mode],
		"%d projected obstructions, footprints expanded by the %.2f m agent radius, masked out of the parse" % [
			_recast_obstructions.size(), baker.agent_radius
		] if recast_props_as_obstructions else "parsed collision geometry"
	])
	_report.add_timing(suite, "9-recast", "parse props + statics (main thread)",
		baker.parse_msec, "%d props, %d bridges, %d triangles; only what is not carved or cached" % [
			prop_centres.size(), MSTTestStatics.under_deck_points(statics).size(), baker.prop_triangles
		])
	_report.add_timing(suite, "9-recast", "prepare %d chunks (main thread)" % prepared,
		baker.prepare_msec, "resolve shapes and transforms a worker may not read")
	_report.add_timing(suite, "9-recast", "assemble source geometry", baker.assemble_msec,
		"%d triangles from collision proxies, no scene parse" % baker.source_triangles)
	# Captured now: baker.bake_msec is overwritten by the single-chunk rebuild
	# further down, and the trimmed-border comparison below needs the full-bake
	# figure, not that one.
	var full_bake_msec := baker.bake_msec
	var full_bake_chunks := baker.chunks_baked
	var full_bake_polygons := baker.polygons
	_report.add_timing(suite, "9-recast", "bake %d chunks on the pool" % baker.chunks_baked,
		baker.bake_msec,
		"%.1f ms per chunk, grown by a whole chunk" % (baker.bake_msec / maxf(float(baker.chunks_baked), 1.0)))
	_report.add_timing(suite, "9-recast", "publish %d regions" % baker.regions, baker.publish_msec,
		"%d polygons total" % baker.polygons)
	_report.add_timing(suite, "9-recast", "  of which on the main thread", baker.main_thread_msec(),
		"prepare + assemble + publish; the parse is a one-off")

	# The scene-parsing route the demo uses, purely for the comparison. It is the
	# only option for geometry the rig does not own, and it cannot leave the main
	# thread, so its cost is the argument for assembling from cached shapes.
	var parse_terrain_msec := baker.parse_terrain(terrain)
	_report.add_timing(suite, "9-recast", "alt: parse terrain from the tree", parse_terrain_msec,
		"vs %.2f ms to assemble the same faces off-thread" % baker.assemble_msec)

	for _i in range(NAV_SETTLE_FRAMES):
		await get_tree().physics_frame
	var recast_clearance := MSTTestProps.nav_clearance(terrain, prop_centres)

	# Judged on the props that are taller than the effective climb. The short ones
	# staying walkable is Recast doing what agent_max_climb asks of it, so folding
	# them into this claim would make it fail for the wrong reason.
	var blocking : Array = []
	for kind: String in MSTTestProps.KIND_HEIGHTS.keys():
		if float(MSTTestProps.KIND_HEIGHTS[kind]) > baker.reliable_block_height():
			blocking.append_array(MSTTestProps.centres_by_kind(props).get(kind, []))
	var blocking_clearance := MSTTestProps.nav_clearance(terrain, blocking)
	# Judged on the Recast side alone. Folding in a threshold for the merger made
	# this fail for a reason that had nothing to do with what it claims, and the
	# merger's own numbers are reported below rather than asserted on.
	_report.add_claim(
		"recast-sees-props",
		"[%s] A Recast bake carves out decoration too tall to step onto" % suite,
		# Bounded above as well as below. "Nothing is walkable near this prop" also
		# produces a large clearance, so a lower bound alone passes just as
		# happily for a navmesh that carved the props as for one that failed to
		# bake at all - which is exactly what a broken source mode looks like.
		not blocking.is_empty()
			and float(blocking_clearance["min"]) > baker.agent_radius * 0.5
			and float(blocking_clearance["mean"]) < baker.agent_radius * 4.0,
		"%d of %d props stand above the %.2f m reliable-block height: merger leaves them %.2f m of clearance on average, Recast leaves min/mean/max %.2f/%.2f/%.2f m (agent radius %.1f)" % [
			blocking.size(), prop_centres.size(), baker.reliable_block_height(),
			merged_clearance["mean"],
			blocking_clearance["min"], blocking_clearance["mean"], blocking_clearance["max"],
			baker.agent_radius
		]
	)
	_report.add_note("[%s] Across all %d props Recast leaves min/mean/max %.2f/%.2f/%.2f m of clearance; the merger leaves %.2f/%.2f/%.2f m." % [
		suite, prop_centres.size(),
		recast_clearance["min"], recast_clearance["mean"], recast_clearance["max"],
		merged_clearance["min"], merged_clearance["mean"], merged_clearance["max"]
	])
	# Distance alone conflates two different things. Where the map put the closest
	# point separates them: a point at floor height a few metres away means the
	# floor was carved; a point up at rock-top height means the prop's own floor
	# is not in the navmesh at all, which would be about placement, not carving.
	for builder: Array in [["merger", merged_clearance], ["recast", recast_clearance]]:
		var figures : Dictionary = builder[1]
		_report.add_note("[%s] %s: %d of %d props stand on navmesh (under 0.1 m), %d have their closest point more than 1 m above the floor; closest-point y averages %.2f (floor %.1f, rock top %.1f)." % [
			suite, builder[0], figures["on_navmesh"], figures["count"], figures["above_floor"],
			figures["mean_y"], MSTTestModules.FLOOR_HEIGHT, MSTTestModules.WALL_HEIGHT
		])
		_report.add_note("[%s] %s: navmesh sits %.2f m above the sample point on average - Recast does not lay its polygons on the surface it baked from, so clearance figures here are xz only." % [
			suite, builder[0], figures["mean_rise"]
		])

	# Split by prop kind, because the interesting variable is height. A prop whose
	# top sits below the baker's effective climb is stepped onto rather than
	# walked around, and reports no clearance at all - which is Recast working as
	# specified, not Recast missing the prop.
	_report.add_note("[%s] Climb test resolves in %d voxel(s) of %.2f m against a nominal %.2f m climb. Whether a height rasterises to %d voxels or %d depends on where the bake box's y origin lands, so the threshold is a band: under %.2f m a prop is always stepped onto, over %.2f m always carved out, and in between it is stable per bake but not worth designing around." % [
		suite, baker.climb_voxels(), baker.cell_height, baker.agent_max_climb,
		baker.climb_voxels(), baker.climb_voxels() + 1,
		baker.effective_max_climb(), baker.reliable_block_height()
	])
	for kind: String in MSTTestProps.KIND_HEIGHTS.keys():
		var of_kind : Array = MSTTestProps.centres_by_kind(props).get(kind, [])
		if of_kind.is_empty():
			continue
		var kind_clearance := MSTTestProps.nav_clearance(terrain, of_kind)
		var height : float = MSTTestProps.KIND_HEIGHTS[kind]
		var verdict := "in the ambiguous band"
		if height > baker.reliable_block_height():
			verdict = "above the band, should be carved out"
		elif height <= baker.effective_max_climb():
			verdict = "below the band, should be stepped onto"
		_report.add_note("[%s] %d x %s, %.1f m tall (%s): clearance min/mean/max %.2f/%.2f/%.2f m." % [
			suite, of_kind.size(), kind, height, verdict,
			kind_clearance["min"], kind_clearance["mean"], kind_clearance["max"]
		])

	# The bridge is the case a projected obstruction cannot express. Parsed as
	# real geometry the floor under the deck stays walkable; a footprint extruded
	# straight up would have carved that floor away and sealed the corridor.
	var under_deck : Array = MSTTestStatics.under_deck_points(statics)
	# Props are scattered in the same corridors the bridges span, so some decks
	# have a crate standing under them. That floor is carved by the prop, exactly
	# as it should be - counting it against the bridge would be measuring the
	# wrong thing, so those samples are dropped and reported separately.
	var prop_shadow := baker.agent_radius + 1.5
	var clear_under : Array = []
	for point: Vector3 in under_deck:
		var shadowed := false
		for centre: Vector3 in prop_centres:
			if Vector2(point.x - centre.x, point.z - centre.z).length() < prop_shadow:
				shadowed = true
				break
		if not shadowed:
			clear_under.append(point)

	if not clear_under.is_empty():
		var under := MSTTestProps.nav_clearance(terrain, clear_under, baker.cell_size)
		# Judged on the worst sample against the bake's own resolution, not on a
		# count against a fixed epsilon. Every underside being within a cell of
		# walkable ground is the statement; how many land inside an arbitrary
		# 0.1 m is a fact about voxel quantisation.
		_report.add_claim(
			"recast-walk-under-bridge",
			"[%s] The floor under a bridge deck stays walkable" % suite,
			under["max"] < baker.cell_size * 2.0,
			"worst underside is %.2f m from walkable ground, against a %.2f m cell; %d of %d within one cell (%d of %d decks excluded, a prop stands under them); navmesh %.2f m above the floor, deck at %.1f m" % [
				under["max"], baker.cell_size,
				under["on_navmesh"], clear_under.size(),
				under_deck.size() - clear_under.size(), under_deck.size(),
				under["mean_rise"], MSTTestStatics.DECK_CLEARANCE
			]
		)

	var recast_path : Dictionary = await MSTTestNav.try_path_until(terrain, from, to, get_tree(), MAX_NAV_SYNC_FRAMES)
	var recast_pairs := MSTTestNav.adjacent_pair_failures(terrain, RECAST_NAV_GRID)
	_report.add_claim(
		"recast-seams",
		"[%s] Chunked Recast regions meet across every seam, with no manual links" % suite,
		bool(recast_path["reached"]) and int(recast_pairs["failed"]) == 0,
		"corner-to-corner reached=%s in %d attempt(s), ended %.2f m from target; %d of %d adjacent pairs failed%s" % [
			recast_path["reached"], recast_path["attempts"], recast_path["end_distance"],
			recast_pairs["failed"], recast_pairs["tested"],
			"" if int(recast_pairs["failed"]) == 0 else "; first: " + str(recast_pairs["first"])
		]
	)
	_report.add_note("[%s] For reference the merged navmesh pathed the same corner-to-corner route with %d point(s), ending %.2f m from the target." % [
		suite, merged_path["points"], merged_path["end_distance"]
	])

	# --- the same bakes, serially, so the speed-up is a measured number -------
	var serial := _make_recast_baker()
	serial.parallel = false
	serial.parse_sources([props, statics])
	serial.prepare(terrain)
	serial.bake()
	_report.add_timing(suite, "9-recast", "bake %d chunks serially" % serial.chunks_baked,
		serial.bake_msec, "same work, one thread, never published")
	_report.add_claim(
		"recast-parallel",
		"[%s] Baking chunks on the worker pool is materially faster than one at a time" % suite,
		full_bake_msec < serial.bake_msec * 0.7,
		"pool %.1f ms vs serial %.1f ms over %d chunks on %d processor(s), %.2fx" % [
			full_bake_msec, serial.bake_msec, full_bake_chunks, OS.get_processor_count(),
			serial.bake_msec / maxf(full_bake_msec, 0.001)
		]
	)

	# --- one chunk re-baked after a dig, which is the dig-loop number ---------
	var rock_offset := MSTTestModules.PASSAGE_HALF_WIDTH + 3
	var middle := Vector2i(floori(dimensions.x / 2.0), floori(dimensions.z / 2.0))
	var stride_x := dimensions.x - 1
	var stride_z := dimensions.z - 1
	var dug := Vector2i(RECAST_NAV_GRID / 2, RECAST_NAV_GRID / 2)
	var site := Vector2i(dug.x * stride_x + middle.x + rock_offset, dug.y * stride_z + middle.y + rock_offset)
	MSTTestDig.dig_area(terrain, site, Vector2i(2, 2), MSTTestModules.FLOOR_HEIGHT, true)
	# dig_area() goes through regenerate_mesh(), which frees this chunk's LOD
	# proxy and leaves the rebuild to a pending flag nothing acts on at runtime.
	# Left alone, this terrain - the one kept for the interactive view - would
	# have one chunk rendering nothing past terrain_lod_start_distance. Kept out
	# of dig_area() itself so the phase 3 and 4 dig timings stay comparable.
	MSTTestThreadedDig.rebuild_lod_proxies(terrain)

	# rebuild_collision() frees the body and builds a new shape resource, so the
	# references cached by prepare() are stale and have to be resolved again.
	# Polled rather than waited on, so the bake really is off the frame and the
	# main-thread figure below is not quietly including it.
	var incremental_start := Time.get_ticks_usec()
	baker.refresh_chunks([dug])
	baker.begin_bake([dug], baker.neighbourhood(dug))
	var frames_in_flight := 0
	while baker.is_baking():
		frames_in_flight += 1
		await get_tree().process_frame
	baker.end_bake()
	baker.publish()
	var incremental_msec := (Time.get_ticks_usec() - incremental_start) / 1000.0
	_report.add_timing(suite, "9-recast", "re-bake 1 chunk of %d after a dig" % baker.chunk_coords().size(),
		incremental_msec,
		"prepare %.2f + assemble %.2f + bake %.2f + publish %.2f, %d frame(s) in flight" % [
			baker.prepare_msec, baker.assemble_msec, baker.bake_msec, baker.publish_msec, frames_in_flight
		])
	_report.add_claim(
		"recast-dig-loop",
		"[%s] Re-baking one chunk leaves under 5 ms on the main thread" % suite,
		baker.main_thread_msec() < 5.0,
		"main thread %.2f ms (prepare %.2f + assemble %.2f + publish %.2f); the worker did %.2f ms of baking" % [
			baker.main_thread_msec(), baker.prepare_msec, baker.assemble_msec, baker.publish_msec, baker.bake_msec
		]
	)

	# --- trimmed border: the demo grows by a whole chunk, which is 9x the work -
	var trimmed := _make_recast_baker()
	trimmed.parse_sources([props, statics])
	trimmed.prepare(terrain)
	trimmed.border_size = trimmed.recommended_border()
	trimmed.bake()

	baker.clear_regions()
	for _i in range(NAV_SETTLE_FRAMES):
		await get_tree().physics_frame
	trimmed.publish()
	_report.add_timing(suite, "9-recast", "bake %d chunks, %.0f m border" % [trimmed.chunks_baked, trimmed.border_size],
		trimmed.bake_msec, "%d polygons; vs %.1f ms and %d growing by a whole %.0f m chunk" % [
			trimmed.polygons, full_bake_msec, full_bake_polygons, baker.chunk_span()
		])

	for _i in range(NAV_SETTLE_FRAMES):
		await get_tree().physics_frame
	var trimmed_path : Dictionary = await MSTTestNav.try_path_until(terrain, from, to, get_tree(), MAX_NAV_SYNC_FRAMES)
	var trimmed_pairs := MSTTestNav.adjacent_pair_failures(terrain, RECAST_NAV_GRID)
	var trimmed_ok := bool(trimmed_path["reached"]) and int(trimmed_pairs["failed"]) == 0
	_report.add_claim(
		"recast-trimmed-border",
		"[%s] A border of a few agent radii aligns seams as well as growing by a whole chunk" % suite,
		trimmed_ok,
		"%.0f m border: %d of %d adjacent pairs failed, corner-to-corner reached=%s; %.1f ms for %d chunks vs %.1f ms growing by a whole chunk" % [
			trimmed.border_size, trimmed_pairs["failed"], trimmed_pairs["tested"],
			trimmed_path["reached"], trimmed.bake_msec, trimmed.chunks_baked, full_bake_msec
		]
	)

	# --- cached shapes vs group parsing, for the same geometry ---------------
	# The bake is scoped by filter_baking_aabb either way, so both modes produce
	# the same navmesh. What differs is what it costs to collect the source, and
	# whether that cost tracks the dig or the whole scene.
	# Both bakers are built here with their mode forced. Reusing `baker` made this
	# compare whichever mode the export selected against itself, which reads as a
	# pass and measures nothing.
	var cached := _make_recast_baker()
	cached.source_mode = MSTTestRecastNav.SourceMode.CACHED_SHAPES
	cached.parse_sources([props, statics])
	cached.prepare(terrain)
	var grouped := _make_recast_baker()
	grouped.source_mode = MSTTestRecastNav.SourceMode.PARSED_GROUP
	grouped.prepare(terrain)
	var chunk_grouped := _make_recast_baker()
	chunk_grouped.source_mode = MSTTestRecastNav.SourceMode.PARSED_CHUNK_GROUPS
	chunk_grouped.prepare(terrain)
	var hybrid := _make_recast_baker()
	hybrid.source_mode = MSTTestRecastNav.SourceMode.HYBRID
	hybrid.prepare(terrain)

	var full_start := Time.get_ticks_usec()
	var cached_full := cached.build_source()
	var cached_full_msec := (Time.get_ticks_usec() - full_start) / 1000.0
	full_start = Time.get_ticks_usec()
	var grouped_full := grouped.build_source()
	var grouped_full_msec := (Time.get_ticks_usec() - full_start) / 1000.0

	# The scoped build is what an incremental re-bake actually asks for. Group
	# parsing has no coords_list equivalent, so it does the same global work.
	var scope : Array = cached.neighbourhood(dug)
	var scoped_start := Time.get_ticks_usec()
	var cached_scoped := cached.build_source(scope)
	var cached_scoped_msec := (Time.get_ticks_usec() - scoped_start) / 1000.0
	scoped_start = Time.get_ticks_usec()
	var grouped_scoped := grouped.build_source(scope)
	var grouped_scoped_msec := (Time.get_ticks_usec() - scoped_start) / 1000.0

	# The middle option: parsed, so nothing goes stale, but scoped per chunk so
	# the props come along only for the chunks actually being baked.
	var chunk_full_start := Time.get_ticks_usec()
	var chunk_full := chunk_grouped.build_source()
	var chunk_full_msec := (Time.get_ticks_usec() - chunk_full_start) / 1000.0
	chunk_full_start = Time.get_ticks_usec()
	var chunk_scoped := chunk_grouped.build_source(scope)
	var chunk_scoped_msec := (Time.get_ticks_usec() - chunk_full_start) / 1000.0

	# Three lanes at once: terrain off the cached proxies, statics parsed per
	# chunk, decoration carved.
	var hybrid_start := Time.get_ticks_usec()
	var hybrid_full := hybrid.build_source()
	var hybrid_full_msec := (Time.get_ticks_usec() - hybrid_start) / 1000.0
	var hybrid_full_parses := hybrid.statics_parsed
	hybrid_start = Time.get_ticks_usec()
	var hybrid_scoped := hybrid.build_source(scope)
	var hybrid_scoped_msec := (Time.get_ticks_usec() - hybrid_start) / 1000.0

	var cached_full_tris := floori(cached_full.get_indices().size() / 3.0)
	var grouped_full_tris := floori(grouped_full.get_indices().size() / 3.0)
	_report.add_timing(suite, "9-recast", "source: cached shapes, all %d chunks" % cached.chunk_coords().size(),
		cached_full_msec, "%d triangles, worker-safe" % cached_full_tris)
	_report.add_timing(suite, "9-recast", "source: parsed group, all %d chunks" % cached.chunk_coords().size(),
		grouped_full_msec, "%d triangles, main thread only" % grouped_full_tris)
	_report.add_timing(suite, "9-recast", "source: cached shapes, %d-chunk scope" % scope.size(),
		cached_scoped_msec, "%d triangles" % floori(cached_scoped.get_indices().size() / 3.0))
	_report.add_timing(suite, "9-recast", "source: parsed group, %d-chunk scope" % scope.size(),
		grouped_scoped_msec, "%d triangles; groups have no spatial filter, so this is the global cost" % floori(grouped_scoped.get_indices().size() / 3.0))
	_report.add_timing(suite, "9-recast", "source: chunk groups, all %d chunks" % cached.chunk_coords().size(),
		chunk_full_msec, "%d triangles across %d grouped nodes, one parse per chunk" % [
			floori(chunk_full.get_indices().size() / 3.0), grouped_nodes
		])
	_report.add_timing(suite, "9-recast", "source: chunk groups, %d-chunk scope" % scope.size(),
		chunk_scoped_msec, "%d triangles; scopes the props too, unlike cached shapes" % floori(chunk_scoped.get_indices().size() / 3.0))
	_report.add_timing(suite, "9-recast", "source: hybrid, all %d chunks" % cached.chunk_coords().size(),
		hybrid_full_msec, "%d triangles; %d of %d chunks needed a static parse, %d statics grouped" % [
			floori(hybrid_full.get_indices().size() / 3.0), hybrid_full_parses,
			cached.chunk_coords().size(), statics_grouped
		])
	_report.add_timing(suite, "9-recast", "source: hybrid, %d-chunk scope" % scope.size(),
		hybrid_scoped_msec, "%d triangles; %d of %d chunks in scope needed a static parse" % [
			floori(hybrid_scoped.get_indices().size() / 3.0), hybrid.statics_parsed, scope.size()
		])

	# Bounds, not just triangle counts. parse_source_geometry_data returns
	# geometry in the root node's local space, so a root with a transform on it
	# would agree on triangle count and be offset in space - which would bake 25
	# empty chunks and look like a bug anywhere but here.
	var cached_bounds := cached_full.get_bounds()
	var grouped_bounds := grouped_full.get_bounds()
	var centre_drift := cached_bounds.get_center().distance_to(grouped_bounds.get_center())
	var chunk_full_tris := floori(chunk_full.get_indices().size() / 3.0)
	var hybrid_full_tris := floori(hybrid_full.get_indices().size() / 3.0)
	var chunk_drift := cached_bounds.get_center().distance_to(chunk_full.get_bounds().get_center())
	var hybrid_drift := cached_bounds.get_center().distance_to(hybrid_full.get_bounds().get_center())
	_report.add_claim(
		"recast-source-modes-agree",
		"[%s] All four source modes collect the same geometry, in the same space" % suite,
		cached_full_tris == grouped_full_tris and chunk_full_tris == cached_full_tris
			and hybrid_full_tris == cached_full_tris
			and centre_drift < 0.1 and chunk_drift < 0.1 and hybrid_drift < 0.1,
		"%d cached / %d one group / %d chunk groups / %d hybrid triangles; bounds centres %.3f, %.3f, %.3f m from cached; full build %.2f / %.2f / %.2f / %.2f ms, %d-chunk scope %.2f / %.2f / %.2f / %.2f ms" % [
			cached_full_tris, grouped_full_tris, chunk_full_tris, hybrid_full_tris,
			centre_drift, chunk_drift, hybrid_drift,
			cached_full_msec, grouped_full_msec, chunk_full_msec, hybrid_full_msec,
			scope.size(), cached_scoped_msec, grouped_scoped_msec, chunk_scoped_msec, hybrid_scoped_msec
		]
	)
	_report.add_claim(
		"recast-chunk-groups-scope",
		"[%s] Per-chunk groups scope a parse to the chunks asked for, props included" % suite,
		# Strictly smaller than the unscoped flat group, and never worse than
		# cached shapes. Not strictly smaller than cached: that only held while
		# props were parsed geometry cached shapes had to carry whole. Supply
		# them as projected obstructions and both modes carry pure terrain and
		# scope identically, which is the right answer rather than a regression.
		floori(chunk_scoped.get_indices().size() / 3.0) < floori(grouped_scoped.get_indices().size() / 3.0)
			and floori(chunk_scoped.get_indices().size() / 3.0) <= floori(cached_scoped.get_indices().size() / 3.0),
		"%d-chunk scope: %d triangles from chunk groups vs %d from cached shapes (which cannot scope props) and %d from one flat group (which cannot scope at all)" % [
			scope.size(), floori(chunk_scoped.get_indices().size() / 3.0),
			floori(cached_scoped.get_indices().size() / 3.0),
			floori(grouped_scoped.get_indices().size() / 3.0)
		]
	)

	_report.add_note("[%s] Recast finds the flat tops of the rock walls walkable too, exactly as the merger does. A height map has no ceiling, so there is nothing above them to fail the agent-height test. agent_max_climb keeps the two layers unconnected, but navmesh_permission or a height filter is still what keeps agents off them." % suite)

	# Whichever configuration held its seams stays live, so the walker and the
	# interactive dig below run on a navmesh that works.
	if trimmed_ok:
		_recast_baker = trimmed
	else:
		trimmed.clear_regions()
		for _i in range(2):
			await get_tree().physics_frame
		baker.publish()
		_recast_baker = baker
	_recast_terrain = terrain
	_live_nav_terrain = terrain


# How big a map this recipe actually carries.
#
# Everything before this measures a 25-chunk cave. This assembles a real one -
# 1024 chunks is a square kilometre at 32 m per chunk - and asks which numbers
# stay flat and which do not.
#
# The bake runs in tiles, each sourcing only its own neighbourhood. begin_bake()
# builds one source for every job it is given, so baking all 1024 in one call
# would hand each chunk a source carrying the whole map to filter against. That
# is the shape a streaming implementation would need anyway.
func _phase_large_map(suite: String, dimensions: Vector3i, factory: MSTTestModules) -> void:
	if is_instance_valid(_live_nav_terrain):
		_live_nav_terrain.queue_free()
		_live_nav_terrain = null
	if is_instance_valid(_live_props):
		_live_props.queue_free()
		_live_props = null
	if is_instance_valid(_live_statics):
		_live_statics.queue_free()
		_live_statics = null
	for _i in range(2):
		await get_tree().physics_frame

	var size := Vector2i(maxi(large_map_chunks.x, 1), maxi(large_map_chunks.y, 1))
	var chunk_span := float(dimensions.x - 1) * CELL_SIZE.x
	var total := size.x * size.y
	_report.add_note("[%s] Large map: %d x %d chunks of %.0f m = %.2f x %.2f km (%.2f km2), %d chunks." % [
		suite, size.x, size.y, chunk_span,
		float(size.x) * chunk_span / 1000.0, float(size.y) * chunk_span / 1000.0,
		float(size.x) * chunk_span * float(size.y) * chunk_span / 1000000.0, total
	])
	var memory_before := Performance.get_monitor(Performance.MEMORY_STATIC)

	var terrain : MarchingSquaresTerrain = await MSTTestAssembler.make_terrain(
		dimensions, CELL_SIZE, self, "LargeMap_%s" % suite, enable_terrain_lod)
	# Parked clear of every other terrain in the scene, in both axes.
	terrain.position = Vector3(-chunk_span * float(size.x) - chunk_span * 4.0, 0.0, 0.0)

	# --- assembly, yielding so the window stays alive ------------------------
	var layout := MSTTestAssembler.build_layout(size)
	var keys : Array = layout.keys()
	var assemble_start := Time.get_ticks_usec()
	for index in range(keys.size()):
		var coords : Vector2i = keys[index]
		MSTTestAssembler.attach_one(terrain, coords, int(layout[coords]), factory)
		if index % 128 == 127:
			print("[rig] large map: %d/%d chunks assembled" % [index + 1, total])
			await get_tree().process_frame
	var assemble_msec := (Time.get_ticks_usec() - assemble_start) / 1000.0
	_report.add_timing(suite, "10-large-map", "assemble %d chunks" % total, assemble_msec,
		"%.2f ms per chunk, no cell geometry warmed" % (assemble_msec / float(total)))
	MSTTestAssembler.refresh_lod(terrain)

	# Deliberately no warm_chunks() pass. A Recast bake reads the collision
	# proxies that came with the baked module data, so cell geometry is only
	# needed for digging - at 69 ms per chunk it would be the single largest
	# cost here and none of it would reach the navmesh.
	var props_start := Time.get_ticks_usec()
	var props := MSTTestProps.scatter(terrain, PROPS_PER_CHUNK, self)
	var statics := MSTTestStatics.scatter_bridges(terrain, self)
	var scatter_msec := (Time.get_ticks_usec() - props_start) / 1000.0
	_live_props = props
	_live_statics = statics
	var prop_centres := MSTTestProps.centres(props)
	_report.add_timing(suite, "10-large-map", "scatter decoration", scatter_msec,
		"%d props + %d bridges over %d chunks" % [
			prop_centres.size(), MSTTestStatics.under_deck_points(statics).size(), total
		])

	# --- prepare, group, carve ----------------------------------------------
	var baker := _make_recast_baker()
	baker.border_size = baker.recommended_border()
	baker.parse_sources([props, statics])
	baker.prepare(terrain)
	baker.register_chunk_groups([props, statics])
	var static_roots : Array = [statics] if recast_props_as_obstructions else [statics, props]
	baker.register_statics(static_roots)
	_recast_obstructions = _build_obstructions(baker, props)
	baker.obstructions = _recast_obstructions
	_report.add_timing(suite, "10-large-map", "prepare + group %d chunks" % total,
		baker.prepare_msec, "%d obstructions, %.0f m border" % [
			_recast_obstructions.size(), baker.border_size
		])

	# --- batched bake --------------------------------------------------------
	var batch_side := LARGE_MAP_BATCH
	var bake_msec := 0.0
	var source_msec := 0.0
	var publish_msec := 0.0
	var batches := 0
	var bake_start := Time.get_ticks_usec()
	for batch_z in range(0, size.y, batch_side):
		for batch_x in range(0, size.x, batch_side):
			var tile : Array = []
			var sources : Dictionary = {}
			for z in range(batch_z, mini(batch_z + batch_side, size.y)):
				for x in range(batch_x, mini(batch_x + batch_side, size.x)):
					var coords := Vector2i(x, z)
					tile.append(coords)
					for neighbour: Vector2i in baker.neighbourhood(coords):
						sources[neighbour] = true
			if tile.is_empty():
				continue
			baker.begin_bake(tile, sources.keys())
			baker.end_bake()
			baker.publish()
			source_msec += baker.assemble_msec
			bake_msec += baker.bake_msec
			publish_msec += baker.publish_msec
			batches += 1
			if batches % 4 == 0:
				print("[rig] large map: %d/%d chunks baked" % [
					mini(batches * batch_side * batch_side, total), total
				])
				await get_tree().process_frame
	var bake_total_msec := (Time.get_ticks_usec() - bake_start) / 1000.0

	_report.add_timing(suite, "10-large-map", "build source, %d batches" % batches, source_msec,
		"%d chunks per batch plus a border" % (batch_side * batch_side))
	_report.add_timing(suite, "10-large-map", "bake %d chunks on the pool" % total, bake_msec,
		"%.2f ms per chunk" % (bake_msec / float(total)))
	_report.add_timing(suite, "10-large-map", "publish %d regions" % baker.regions, publish_msec,
		"%d polygons total" % baker.polygons)
	_report.add_timing(suite, "10-large-map", "whole map, wall clock", bake_total_msec,
		"source + bake + publish + frame yields")

	var memory_after := Performance.get_monitor(Performance.MEMORY_STATIC)
	_report.add_timing(suite, "10-large-map", "static memory used", 0.0,
		"%.0f MB before, %.0f MB after, %.1f MB per chunk" % [
			memory_before / 1048576.0, memory_after / 1048576.0,
			(memory_after - memory_before) / 1048576.0 / float(total)
		])

	# --- does a map this size still answer queries? -------------------------
	var far := Vector2i(size.x - 1, size.y - 1)
	var from := MSTTestNav.chunk_centre(terrain, Vector2i(0, 0)) + terrain.position
	var to := MSTTestNav.chunk_centre(terrain, far) + terrain.position
	var crossed : Dictionary = await MSTTestNav.try_path_until(terrain, from, to, get_tree(), MAX_NAV_SYNC_FRAMES)
	_report.add_timing(suite, "10-large-map", "frames until a cross-map path works",
		float(crossed["attempts"]), "physics frames" if bool(crossed["reached"]) else "never succeeded")
	_report.add_claim(
		"large-map-queryable",
		"[%s] A %d-chunk map still answers a corner-to-corner query" % [suite, total],
		bool(crossed["reached"]),
		"%d regions, %d polygons; %d attempt(s), %d points, ended %.2f m from a target %.0f m away" % [
			crossed["regions"], baker.polygons, crossed["attempts"], crossed["points"],
			crossed["end_distance"], from.distance_to(to)
		]
	)

	# How long the map takes to publish a change is the number that decides
	# whether an agent notices a dig. Measured by re-baking one chunk and waiting
	# for the iteration id to move.
	var publish_probe := Vector2i(mini(1, size.x - 1), mini(1, size.y - 1))
	var publish_all : Dictionary = await _measure_nav_publish(terrain, baker, publish_probe)
	_report.add_timing(suite, "10-large-map", "map publishes a change, %d regions" % baker.regions,
		float(publish_all["msec"]),
		"%d physics frames%s" % [
			publish_all["frames"],
			"" if bool(publish_all["published"]) else " - never, within %d" % MAX_NAV_PUBLISH_FRAMES
		])

	# The same measurement with only a working set enabled. A disabled region is
	# off the map, so this is the lever for both sync cost and A* search space.
	if nav_active_radius_chunks > 0:
		var active := baker.set_active_radius(publish_probe, nav_active_radius_chunks)
		for _i in range(NAV_SETTLE_FRAMES):
			await get_tree().physics_frame
		var publish_windowed : Dictionary = await _measure_nav_publish(terrain, baker, publish_probe)
		_report.add_timing(suite, "10-large-map", "map publishes a change, %d enabled" % active,
			float(publish_windowed["msec"]),
			"%d physics frames, radius %d chunks; vs %.0f ms with all %d enabled" % [
				publish_windowed["frames"], nav_active_radius_chunks,
				publish_all["msec"], baker.regions
			])
		baker.set_active_radius(publish_probe, -1)
		for _i in range(NAV_SETTLE_FRAMES):
			await get_tree().physics_frame

	# A corner-to-corner query failing says nothing about where it stops. This
	# walks outward until one does, which is the number that decides how much of
	# the map an agent can be asked to cross in one query.
	var reach := 0
	for step in range(1, size.x):
		var probe := MSTTestNav.chunk_centre(terrain, Vector2i(step, 0)) + terrain.position
		if not bool(MSTTestNav.try_path(terrain, from, probe)["reached"]):
			break
		reach = step
	_report.add_timing(suite, "10-large-map", "path reach along one edge", float(reach),
		"chunks, i.e. %.0f m of a %.0f m edge, before a query stops arriving" % [
			float(reach) * chunk_span, float(size.x) * chunk_span
		])

	var query_total := 0.0
	for _i in range(3):
		query_total += float(MSTTestNav.query_msec(terrain, from, to)["msec"])
	_report.add_timing(suite, "10-large-map", "cross-map path query (mean of 3)", query_total / 3.0,
		"%.0f m apart" % from.distance_to(to))
	_report.add_timing(suite, "10-large-map", "map_force_update with %d regions" % baker.regions,
		MSTTestNav.force_update_msec(terrain), "synchronous, lands on the main thread")

	# --- the number that decides whether it is playable ----------------------
	var middle := Vector2i(size.x / 2, size.y / 2)
	var rock_offset := MSTTestModules.PASSAGE_HALF_WIDTH + 3
	var stride_x := dimensions.x - 1
	var stride_z := dimensions.z - 1
	var site := Vector2i(
		middle.x * stride_x + floori(dimensions.x / 2.0) + rock_offset,
		middle.y * stride_z + floori(dimensions.z / 2.0) + rock_offset
	)
	MSTTestDig.dig_area(terrain, site, Vector2i(2, 2), MSTTestModules.FLOOR_HEIGHT, true)
	MSTTestThreadedDig.rebuild_lod_proxies(terrain, [middle])

	baker.refresh_chunks([middle])
	baker.begin_bake([middle], baker.neighbourhood(middle))
	while baker.is_baking():
		await get_tree().process_frame
	baker.end_bake()
	baker.publish()
	_report.add_timing(suite, "10-large-map", "re-bake 1 chunk of %d after a dig" % total,
		baker.main_thread_msec(),
		"prepare %.2f + source %.2f + publish %.2f; worker did %.2f" % [
			baker.prepare_msec, baker.assemble_msec, baker.publish_msec, baker.bake_msec
		])
	_report.add_claim(
		"large-map-dig-loop",
		"[%s] Re-baking one chunk stays under 5 ms on the main thread with %d regions live" % [suite, baker.regions],
		baker.main_thread_msec() < 5.0,
		"main thread %.2f ms = refresh %.2f + source %.2f + publish %.2f, with %d chunks and %d obstructions on the map" % [
			baker.main_thread_msec(), baker.prepare_msec, baker.assemble_msec,
			baker.publish_msec, baker.chunk_coords().size(), _recast_obstructions.size()
		]
	)

	_recast_baker = baker
	_recast_terrain = terrain
	_live_nav_terrain = terrain

#endregion


#region scene setup and interaction

func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-55.0, -40.0, 0.0)
	light.light_energy = 1.1
	add_child(light)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.05, 0.07)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.35, 0.36, 0.42)
	environment.ambient_light_energy = 0.6
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	add_child(world_environment)


## Frames whichever terrain is most worth looking at, measured from the chunks it
## actually has rather than from an assumed 3x3. Which one that is depends on
## which phases ran, so with only phase 9 enabled the camera still opens on the
## cave with the props in it instead of on empty space.
func _camera_focus() -> MarchingSquaresTerrain:
	for candidate: MarchingSquaresTerrain in [_recast_terrain, _live_nav_terrain, _live_terrain]:
		if is_instance_valid(candidate) and not candidate.chunks.is_empty():
			return candidate
	return null


static func _terrain_extent(terrain: MarchingSquaresTerrain) -> AABB:
	var stride_x := float(terrain.dimensions.x - 1) * terrain.cell_size.x
	var stride_z := float(terrain.dimensions.z - 1) * terrain.cell_size.y
	var lowest := Vector2i(1 << 30, 1 << 30)
	var highest := Vector2i(-(1 << 30), -(1 << 30))
	for coords: Vector2i in terrain.chunks.keys():
		lowest.x = mini(lowest.x, coords.x)
		lowest.y = mini(lowest.y, coords.y)
		highest.x = maxi(highest.x, coords.x)
		highest.y = maxi(highest.y, coords.y)
	return AABB(
		terrain.global_position + Vector3(float(lowest.x) * stride_x, 0.0, float(lowest.y) * stride_z),
		Vector3(float(highest.x - lowest.x + 1) * stride_x, 0.0, float(highest.y - lowest.y + 1) * stride_z)
	)


func _setup_camera() -> void:
	var focus := _camera_focus()
	if focus == null:
		print("[rig] Nothing left in the scene to look at - every phase that builds a terrain was skipped.")
		return
	var extent := _terrain_extent(focus)
	_camera_target = extent.get_center()
	_camera_distance = maxf(extent.size.x, extent.size.z) * 1.5
	_camera = Camera3D.new()
	_camera.name = "RigCamera"
	_camera.far = 4000.0
	add_child(_camera)
	_update_camera()
	_spawn_agent()
	print("[rig] Interactive mode on %s: right-drag orbit, wheel zoom, WASD pan, Q/E down/up, Shift faster." % focus.name)
	print("[rig] Left-click digs, or chops down a prop if you click one. Middle-click sends the red cube there.")


func _process(delta: float) -> void:
	_move_agent(delta)
	_update_active_nav_window()
	if not is_instance_valid(_camera):
		return

	# Ground-plane basis derived from the orbit yaw, so W always goes the way the
	# camera is facing.
	var forward := Vector3(-sin(_camera_yaw), 0.0, -cos(_camera_yaw))
	var right := Vector3(cos(_camera_yaw), 0.0, -sin(_camera_yaw))
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move += forward
	if Input.is_key_pressed(KEY_S):
		move -= forward
	if Input.is_key_pressed(KEY_D):
		move += right
	if Input.is_key_pressed(KEY_A):
		move -= right
	if Input.is_key_pressed(KEY_E):
		move += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		move -= Vector3.UP
	if move == Vector3.ZERO:
		return

	# Scaled by zoom so panning feels the same close up and far out.
	var speed := maxf(_camera_distance, 10.0) * CAMERA_PAN_SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= CAMERA_PAN_BOOST
	_camera_target += move.normalized() * speed * delta
	_update_camera()


func _update_camera() -> void:
	if not is_instance_valid(_camera):
		return
	var offset := Vector3(
		cos(_camera_pitch) * sin(_camera_yaw),
		-sin(_camera_pitch),
		cos(_camera_pitch) * cos(_camera_yaw)
	) * _camera_distance
	_camera.position = _camera_target + offset
	_camera.look_at(_camera_target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(_camera):
		return

	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT):
		_camera_yaw -= event.relative.x * 0.006
		_camera_pitch = clampf(_camera_pitch + event.relative.y * 0.006, -1.4, -0.1)
		_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera_distance = maxf(_camera_distance * 0.9, 10.0)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera_distance = minf(_camera_distance * 1.1, 2000.0)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_dig_at_screen_position(event.position)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			var hit := _raycast_from_screen(event.position)
			if not hit.is_empty():
				_send_agent_to(hit["position"])


func _raycast_from_screen(screen_position: Vector2) -> Dictionary:
	var from := _camera.project_ray_origin(screen_position)
	var to := from + _camera.project_ray_normal(screen_position) * 4000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(query)


## Digs on a worker and reports where every millisecond went.
##
## The synchronous MSTTestDig.dig_area() is what phases 3 and 4 measure, and at
## 30-190 ms it is a visible frame drop - it is a measurement tool, not something
## to drive interactively. This runs the same work through MSTTestThreadedDig
## instead, so the mesh rebuild, the collision proxy and the cold-chunk cell
## build all land on a worker, and follows it with a Recast re-bake that is
## polled rather than waited on.
##
## The print is the diagnostic: every line separates main-thread cost from worker
## cost, so "which stage is costing me frames" is answered by reading it rather
## than by guessing.
func _dig_at_screen_position(screen_position: Vector2) -> void:
	# A second dig while one is in flight would race the first job's publish.
	if _dig_in_flight:
		return
	var hit := _raycast_from_screen(screen_position)
	if hit.is_empty():
		return

	# A prop under the cursor is chopped down instead of dug around. Identified
	# by group rather than by collision layer: the layer is there so a game can
	# query decoration separately, but the group is what says "this is a prop".
	var prop := _prop_from_collider(hit["collider"])
	if prop != null:
		await _destroy_prop(prop)
		return

	# Dig whichever terrain was actually hit, not just the live one, so the nav
	# terrain can be dug too and its regions rebuilt in view.
	var terrain := _terrain_from_collider(hit["collider"])
	if terrain == null:
		return

	var local : Vector3 = hit["position"] - terrain.global_position
	var gx := roundi(local.x / terrain.cell_size.x)
	var gz := roundi(local.z / terrain.cell_size.y)
	_dig_in_flight = true
	_dig_count += 1

	var job := MSTTestThreadedDig.new()
	job.start(terrain, Vector2i(gx - 2, gz - 2), Vector2i(5, 5), MSTTestModules.FLOOR_HEIGHT)
	while job.is_running():
		# Counts the frame and checks the chunk still has collision on it. The
		# swap-shape design exists to guarantee exactly that, so it is worth
		# proving live rather than only in phase 6.
		job.sample_collision()
		await get_tree().process_frame
	job.publish()
	var dug : Array = job.affected_coords()
	var dig_main_msec := job.main_thread_msec()

	# The navmesh is rebuilt in view, so Debug > Visible Navigation shows the hole
	# appear straight away. Which builder does it depends on which terrain was
	# hit: the Recast cave carries props, so only a Recast re-bake is correct
	# there, and the merged caves have no props for it to miss.
	var nav_main_msec := 0.0
	var nav_worker_msec := 0.0
	var nav_regions := 0
	if _recast_baker != null and terrain == _recast_terrain:
		# The bake box of a dug chunk reaches into its neighbours, so their
		# geometry has to be in the source even though they are not re-baked.
		var source_coords : Dictionary = {}
		for coords: Vector2i in dug:
			for neighbour: Vector2i in _recast_baker.neighbourhood(coords):
				source_coords[neighbour] = true
		# swap_collision_shape() put a new shape resource on each dug chunk, so
		# the references cached for those chunks are stale. Only those.
		_recast_baker.refresh_chunks(dug)
		_recast_baker.begin_bake(dug, source_coords.keys())
		while _recast_baker.is_baking():
			await get_tree().process_frame
		_recast_baker.end_bake()
		_recast_baker.publish()
		nav_regions = _recast_baker.chunks_baked
		nav_worker_msec = _recast_baker.bake_msec
		nav_main_msec = _recast_baker.main_thread_msec()
	else:
		var nav_start := Time.get_ticks_usec()
		for coords: Vector2i in dug:
			var chunk : MarchingSquaresTerrainChunk = terrain.chunks.get(coords)
			if chunk == null or chunk.get_node_or_null(MSTTestNav.REGION_NAME) == null:
				continue
			MSTTestNav.build_merged_region(terrain, chunk)
			nav_regions += 1
		if nav_regions > 0:
			nav_main_msec = (Time.get_ticks_usec() - nav_start) / 1000.0
	var iteration_before := MSTTestNav.map_iteration(terrain)
	if nav_regions > 0 and NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.map_force_update(terrain.get_world_3d().navigation_map)

	print("[rig] dig %d on %s at (%d, %d), %d chunk(s): MAIN THREAD %.2f ms = terrain %.2f (prologue %.2f + join %.2f + publish %.2f) + nav %.2f" % [
		_dig_count, terrain.name, gx, gz, dug.size(),
		dig_main_msec + nav_main_msec, dig_main_msec,
		job.prologue_msec, job.join_msec, job.publish_msec, nav_main_msec
	])
	# A large join means the poll loop exited before the worker did and the main
	# thread blocked for the difference - the one way this can quietly stall.
	print("[rig]   worker: terrain %.2f ms over %d frame(s), nav %.2f ms across %d region(s); %d frame(s) without collision" % [
		job.worker_msec, job.frames_in_flight, nav_worker_msec, nav_regions, job.frames_without_collision
	])
	_dig_in_flight = false

	var published : Dictionary = await _await_nav_iteration(terrain, iteration_before)
	print("[rig]   map published the change after %d physics frame(s), %.1f ms, over %d region(s) with edge connections %s%s" % [
		published["frames"], published["msec"],
		NavigationServer3D.map_get_regions(get_world_3d().navigation_map).size(),
		"ON" if nav_edge_connections else "OFF",
		"" if bool(published["published"]) else " - NOT published within the budget"
	])
	await _repath_agent()


## A red cube driven by a NavigationAgent3D, so the merged navmesh can be seen
## working rather than only reported on. Dropped onto the 25-chunk cave, which is
## the terrain that keeps its regions.
func _spawn_agent() -> void:
	if not is_instance_valid(_live_nav_terrain):
		return

	_agent_body = Node3D.new()
	_agent_body.name = "Walker"
	add_child(_agent_body)
	_agent_body.global_position = MSTTestNav.chunk_centre(_live_nav_terrain, Vector2i(0, 0)) + _live_nav_terrain.position

	var box := BoxMesh.new()
	box.size = Vector3(2.0, 2.0, 2.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.15, 0.15)
	material.emission_enabled = true
	material.emission = Color(0.35, 0.0, 0.0)
	var cube := MeshInstance3D.new()
	cube.name = "Cube"
	cube.mesh = box
	cube.material_override = material
	cube.position = Vector3(0.0, 1.0, 0.0)
	_agent_body.add_child(cube)

	_agent = NavigationAgent3D.new()
	_agent.name = "Agent"
	_agent.radius = 1.0
	_agent.height = 2.0
	_agent.path_desired_distance = 1.0
	_agent.target_desired_distance = 1.5
	_agent.avoidance_enabled = false
	_agent.debug_enabled = true
	_agent_body.add_child(_agent)


## Moves the enabled-region window with the walker, and only when it actually
## crosses into a new chunk - the update is O(regions) and would otherwise be a
## per-frame cost of exactly the kind this is meant to remove.
func _update_active_nav_window() -> void:
	if nav_active_radius_chunks <= 0 or _recast_baker == null:
		return
	if not is_instance_valid(_agent_body) or not is_instance_valid(_recast_terrain):
		return
	var centre := _recast_baker.chunk_coords_for(_agent_body.global_position)
	if centre == _active_nav_centre:
		return
	_active_nav_centre = centre
	var active := _recast_baker.set_active_radius(centre, nav_active_radius_chunks)
	print("[rig]   nav window moved to chunk %s: %d region(s) enabled of %d" % [
		str(centre), active, _recast_baker.chunk_coords().size()
	])


func _move_agent(delta: float) -> void:
	if not is_instance_valid(_agent) or not is_instance_valid(_agent_body):
		return
	if _agent.is_navigation_finished():
		return
	var next := _agent.get_next_path_position()
	var step := next - _agent_body.global_position
	if step.length() < 0.001:
		return
	_agent_body.global_position += step.normalized() * AGENT_SPEED * delta


func _send_agent_to(target: Vector3) -> void:
	if not is_instance_valid(_agent):
		return
	_agent_target = target
	_agent.target_position = target
	# The path is computed against the map, so read it back rather than trusting
	# the click: an unreachable target still produces a partial path.
	await get_tree().physics_frame
	var path := _agent.get_current_navigation_path()
	print("[rig] walker target %s: %d path point(s), %.1f m away" % [
		str(target.round()), path.size(), _agent_body.global_position.distance_to(target)
	])


## Props as projected obstructions, tagged with the chunk each stands over so a
## scoped source can carry only the ones it needs.
func _build_obstructions(baker: MSTTestRecastNav, props: Node3D) -> Array:
	if not recast_props_as_obstructions:
		return []
	# Expanded by the agent radius: an obstruction is marked after Recast has
	# already eroded, so unlike parsed geometry it gets no clearance of its own.
	var list := MSTTestProps.obstructions(props, baker.agent_radius)
	for entry: Dictionary in list:
		entry["coords"] = baker.chunk_coords_for(entry["position"])
	return list


## Anything left-click can destroy: decoration or an irregular static.
##
## Both are handled by the same path because the difference between them lives in
## how they reach the bake, not in what removing one costs. A prop leaves the
## obstruction list; a bridge leaves its chunk's static group. Neither touches
## the terrain.
## Re-bakes one chunk and times how long the map takes to answer with it.
func _measure_nav_publish(terrain: MarchingSquaresTerrain, baker: MSTTestRecastNav, coords: Vector2i) -> Dictionary:
	baker.refresh_chunks([coords])
	baker.begin_bake([coords], baker.neighbourhood(coords))
	while baker.is_baking():
		await get_tree().process_frame
	baker.end_bake()
	var before := MSTTestNav.map_iteration(terrain)
	baker.publish()
	if NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.map_force_update(terrain.get_world_3d().navigation_map)
	return await _await_nav_iteration(terrain, before)


## Waits for the navigation map to publish a new iteration, and says how long it
## took. This is the gap between "the debug draw shows the change" and "a query
## answers with it".
func _await_nav_iteration(terrain: MarchingSquaresTerrain, before: int) -> Dictionary:
	if before < 0:
		return {"frames": -1, "msec": 0.0, "published": false}
	var start_usec := Time.get_ticks_usec()
	for frame in range(MAX_NAV_PUBLISH_FRAMES):
		if MSTTestNav.map_iteration(terrain) != before:
			return {
				"frames": frame,
				"msec": (Time.get_ticks_usec() - start_usec) / 1000.0,
				"published": true,
			}
		await get_tree().physics_frame
	return {
		"frames": MAX_NAV_PUBLISH_FRAMES,
		"msec": (Time.get_ticks_usec() - start_usec) / 1000.0,
		"published": false,
	}


## Makes the walker notice that the map changed under it.
##
## NavigationAgent3D holds the path it is following and does not watch the map,
## so an agent mid-route keeps walking a path computed before the dig - through
## a wall that now exists, or around a prop that no longer does. Re-assigning the
## target is what forces it to ask again. Nothing does this automatically.
func _repath_agent() -> void:
	if not is_instance_valid(_agent) or _agent_target == Vector3.INF:
		return
	if _agent.is_navigation_finished():
		return
	var before := _agent.get_current_navigation_path().size()
	_agent.target_position = _agent_target
	await get_tree().physics_frame
	var after := _agent.get_current_navigation_path().size()
	print("[rig]   walker re-pathed: %d -> %d point(s)" % [before, after])


func _prop_from_collider(collider: Variant) -> Node3D:
	var node := collider as Node
	while node != null:
		if node.is_in_group(MSTTestProps.GROUP) or node.is_in_group(MSTTestStatics.GROUP):
			return node as Node3D
		node = node.get_parent()
	return null


## Chops a prop down and rebuilds only what its absence actually changed.
##
## Nothing about the terrain moved, so there is no mesh to regenerate, no
## collision proxy to rebuild, no cell geometry to warm and no LOD proxy to
## invalidate - and prepare() is skipped too, because the chunk shapes it caches
## are still valid. Only the navmesh is wrong, and only around this chunk.
##
## This is also the case that separates the source modes: CACHED_SHAPES parses
## props once and merges that snapshot into every build, so it has to be told;
## the parsed modes collect props fresh and simply stop finding this one.
func _destroy_prop(prop: Node3D) -> void:
	if _recast_baker == null or not is_instance_valid(_recast_terrain):
		prop.queue_free()
		return

	_dig_in_flight = true
	_dig_count += 1
	var prop_name := String(prop.name)
	var is_static := prop.is_in_group(MSTTestStatics.GROUP)
	var coords := _recast_baker.chunk_coords_for(prop.global_position)

	var start_usec := Time.get_ticks_usec()
	# Out of the tree now, not at the end of the frame. A parsed source mode
	# collects through get_nodes_in_group(), and a node still in the tree is
	# still in that list - queue_free() alone would let it be parsed once more.
	var parent := prop.get_parent()
	if parent != null:
		parent.remove_child(prop)
	prop.queue_free()

	var reparse_msec := _recast_baker.props_changed()
	# The obstruction list is a snapshot too, and this prop has just left it.
	if recast_props_as_obstructions:
		_recast_obstructions = _build_obstructions(_recast_baker, _live_props)
		_recast_baker.obstructions = _recast_obstructions

	# A bridge deck is long enough to reach past its own chunk, so what it was
	# removed from is not necessarily the only chunk whose navmesh changed.
	var affected : Array = [coords] if not is_static else _recast_baker.neighbourhood(coords)
	var sources : Dictionary = {}
	for chunk_coords: Vector2i in affected:
		for neighbour: Vector2i in _recast_baker.neighbourhood(chunk_coords):
			sources[neighbour] = true
	_recast_baker.begin_bake(affected, sources.keys())
	var frames := 0
	while _recast_baker.is_baking():
		frames += 1
		await get_tree().process_frame
	_recast_baker.end_bake()
	_recast_baker.publish()
	var main_msec := _recast_baker.assemble_msec + _recast_baker.publish_msec + maxf(reparse_msec, 0.0)

	var iteration_before := MSTTestNav.map_iteration(_recast_terrain)
	if NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.map_force_update(_recast_terrain.get_world_3d().navigation_map)

	print("[rig] chop %d: %s (%s) on chunk %s, navmesh only: MAIN THREAD %.2f ms = source %.2f + publish %.2f%s" % [
		_dig_count, prop_name,
		"parsed static, left its chunk group" if is_static else "obstruction, left the carve list",
		str(coords), main_msec,
		_recast_baker.assemble_msec, _recast_baker.publish_msec,
		"" if reparse_msec < 0.0 else " + props re-parse %.2f (cached-shapes snapshot went stale)" % reparse_msec
	])
	print("[rig]   worker: nav %.2f ms over %d frame(s); no mesh, collision, cell or LOD work at all" % [
		_recast_baker.bake_msec, frames
	])
	_dig_in_flight = false

	var published : Dictionary = await _await_nav_iteration(_recast_terrain, iteration_before)
	print("[rig]   map published the change after %d physics frame(s), %.1f ms, over %d region(s) with edge connections %s%s" % [
		published["frames"], published["msec"],
		NavigationServer3D.map_get_regions(get_world_3d().navigation_map).size(),
		"ON" if nav_edge_connections else "OFF",
		"" if bool(published["published"]) else " - NOT published within the budget"
	])
	await _repath_agent()


func _terrain_from_collider(collider: Variant) -> MarchingSquaresTerrain:
	var node := collider as Node
	while node != null:
		var chunk := node as MarchingSquaresTerrainChunk
		if chunk != null:
			return chunk.terrain_system
		node = node.get_parent()
	return null

#endregion
