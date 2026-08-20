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
const LARGE_DIMENSIONS : Vector3i = Vector3i(33, 32, 33)
const SMALL_DIMENSIONS : Vector3i = Vector3i(17, 32, 17)
const DIG_REPEATS : int = 5
## How many physics frames a nav query may retry before the failure is treated
## as a real missing connection rather than server sync latency.
const MAX_NAV_SYNC_FRAMES : int = 60
const NAV_SETTLE_FRAMES : int = 20
const NAV_SCALE_GRID : int = 5
## Pan speed as a fraction of the orbit distance, so it scales with zoom.
const CAMERA_PAN_SPEED : float = 0.9
const CAMERA_PAN_BOOST : float = 3.0
const AGENT_SPEED : float = 14.0

@export var run_large_dimensions : bool = true
@export var run_small_dimensions : bool = true
## Leaves the last assembled terrain in the scene with a camera so seams can be
## inspected by eye, and left-click digs a hole.
@export var interactive_after_run : bool = true
## Phase 7 assembles and warms a full 5x5 cave, which is the slowest phase by far.
@export var run_nav_scale : bool = true

var _report : MSTTestReport
var _live_terrain : MarchingSquaresTerrain
var _live_nav_terrain : MarchingSquaresTerrain
var _camera : Camera3D
var _camera_yaw : float = 0.0
var _camera_pitch : float = -0.9
var _camera_target : Vector3 = Vector3.ZERO
var _camera_distance : float = 120.0
var _dig_count : int = 0
var _agent_body : Node3D
var _agent : NavigationAgent3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_report = MSTTestReport.new()
	_setup_environment()
	await get_tree().process_frame

	if run_large_dimensions:
		await _run_suite("33x33", LARGE_DIMENSIONS)
	if run_small_dimensions:
		await _run_suite("17x17", SMALL_DIMENSIONS)

	_report.print_all()

	if interactive_after_run and is_instance_valid(_live_terrain):
		_setup_camera()
	elif is_instance_valid(_live_terrain):
		_live_terrain.queue_free()
		if is_instance_valid(_live_nav_terrain):
			_live_nav_terrain.queue_free()


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

	await _phase_assembly(suite, dimensions, factory)
	var terrain : MarchingSquaresTerrain = await _phase_seams_and_digging(suite, dimensions, factory)
	await _phase_navigation(suite, dimensions, factory)
	await _phase_threading(suite, dimensions, factory)
	if run_nav_scale:
		await _phase_nav_scale(suite, dimensions, factory)

	factory.close()

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
				dimensions, CELL_SIZE, self, "Assembly_%s_%d_%s" % [suite, grid_size, mode])

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
		dimensions, CELL_SIZE, self, "Live_%s" % suite)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)

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
		dimensions, CELL_SIZE, self, "Nav_%s" % suite)
	# Parked just north of the live terrain so both are visible at once with
	# Debug > Visible Navigation switched on.
	terrain.position = Vector3(0.0, 0.0, -float(dimensions.z - 1) * CELL_SIZE.y * 2.0)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)

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
		dimensions, CELL_SIZE, self, "Threaded_%s" % suite)
	terrain.position = Vector3(0.0, 0.0, float(dimensions.z - 1) * CELL_SIZE.y * 4.0)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)

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

	var job := MSTTestThreadedDig.new()
	job.start(terrain, site + Vector2i(3, 0), Vector2i(2, 2), MSTTestModules.WALL_HEIGHT)
	while job.is_running():
		job.sample_collision()
		await get_tree().process_frame
	job.publish()

	var main_thread_msec := job.prologue_msec + job.publish_msec
	_report.add_timing(suite, "6-threaded", "threaded dig: main thread total", main_thread_msec,
		"prologue %.2f + publish %.2f" % [job.prologue_msec, job.publish_msec])
	_report.add_timing(suite, "6-threaded", "threaded dig: worker", job.worker_msec,
		"%d frame(s) in flight" % job.frames_in_flight)
	_report.add_timing(suite, "6-threaded", "same dig done synchronously", float(sync_reference["total_msec"]),
		"for comparison, all on the main thread")

	_report.add_claim(
		"threaded-dig-residue",
		"[%s] A threaded dig leaves less than half the synchronous cost on the main thread" % suite,
		main_thread_msec < float(sync_reference["total_msec"]) * 0.5,
		"main thread %.2f ms (prologue %.2f + publish %.2f) vs %.2f ms synchronous; worker did %.2f ms" % [
			main_thread_msec, job.prologue_msec, job.publish_msec, sync_reference["total_msec"], job.worker_msec
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
		dimensions, CELL_SIZE, self, "NavScale_%s" % suite)
	terrain.position = Vector3(float(dimensions.x - 1) * CELL_SIZE.x * 6.0, 0.0, 0.0)
	MSTTestAssembler.assemble_fast(terrain, layout, factory)

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


func _setup_camera() -> void:
	var stride_x := float(_live_terrain.dimensions.x - 1) * _live_terrain.cell_size.x
	var stride_z := float(_live_terrain.dimensions.z - 1) * _live_terrain.cell_size.y
	_camera_target = Vector3(stride_x * 1.5, 0.0, stride_z * 1.5)
	_camera_distance = maxf(stride_x, stride_z) * 2.2
	_camera = Camera3D.new()
	_camera.name = "RigCamera"
	_camera.far = 4000.0
	add_child(_camera)
	_update_camera()
	_spawn_agent()
	print("[rig] Interactive mode: right-drag orbit, wheel zoom, WASD pan, Q/E down/up, Shift faster.")
	print("[rig] Left-click digs. Middle-click sends the red cube there.")


func _process(delta: float) -> void:
	_move_agent(delta)
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


func _dig_at_screen_position(screen_position: Vector2) -> void:
	var hit := _raycast_from_screen(screen_position)
	if hit.is_empty():
		return

	# Dig whichever terrain was actually hit, not just the live one, so the nav
	# terrain can be dug too and its regions rebuilt in view.
	var terrain := _terrain_from_collider(hit["collider"])
	if terrain == null:
		return

	var local : Vector3 = hit["position"] - terrain.global_position
	var gx := roundi(local.x / terrain.cell_size.x)
	var gz := roundi(local.z / terrain.cell_size.y)
	var result := MSTTestDig.dig_area(terrain, Vector2i(gx - 2, gz - 2), Vector2i(5, 5), MSTTestModules.FLOOR_HEIGHT, true)
	_dig_count += 1

	# Chunks that carry a nav region get it rebuilt, so Debug > Visible
	# Navigation shows the hole appear in the navmesh straight away.
	var nav_msec := 0.0
	var nav_regions := 0
	var nav_start := Time.get_ticks_usec()
	for coords: Vector2i in result["chunks"]:
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks.get(coords)
		if chunk == null or chunk.get_node_or_null(MSTTestNav.REGION_NAME) == null:
			continue
		MSTTestNav.build_merged_region(terrain, chunk)
		nav_regions += 1
	if nav_regions > 0:
		nav_msec = (Time.get_ticks_usec() - nav_start) / 1000.0
		if NavigationServer3D.has_method("map_force_update"):
			NavigationServer3D.map_force_update(terrain.get_world_3d().navigation_map)

	print("[rig] dig %d on %s at (%d, %d): %.2f ms total (mesh %.2f, collision %.2f, nav faces %.2f) across %d chunk(s); %d nav region(s) rebuilt in %.2f ms" % [
		_dig_count, terrain.name, gx, gz, result["total_msec"], result["mesh_msec"], result["collision_msec"],
		result["nav_msec"], result["chunks_affected"], nav_regions, nav_msec
	])


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
	_agent.target_position = target
	# The path is computed against the map, so read it back rather than trusting
	# the click: an unreachable target still produces a partial path.
	await get_tree().physics_frame
	var path := _agent.get_current_navigation_path()
	print("[rig] walker target %s: %d path point(s), %.1f m away" % [
		str(target.round()), path.size(), _agent_body.global_position.distance_to(target)
	])


func _terrain_from_collider(collider: Variant) -> MarchingSquaresTerrain:
	var node := collider as Node
	while node != null:
		var chunk := node as MarchingSquaresTerrainChunk
		if chunk != null:
			return chunk.terrain_system
		node = node.get_parent()
	return null

#endregion
