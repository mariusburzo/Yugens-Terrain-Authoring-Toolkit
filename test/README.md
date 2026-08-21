# MST cave rig

A measurement rig for one question: **can this terrain addon carry runtime-assembled,
diggable caves?**

The answer is yes, with a specific recipe. Every phase exists to confirm or falsify one
claim about how the addon behaves at runtime, so the numbers below are measured rather
than estimated. Treat a `FAILS` line as a thing to design around, not a bug to fix.

Nothing here touches `addons/`. The rig only uses the addon's public-ish API.

Measured on Godot 4.7, Windows. Figures are quoted as `33x33 / 17x17` chunk dimensions.

## Findings

**Assembly must not go through `add_chunk()`.** It calls `_schedule_collision_refresh()`,
which outside the editor skips its debounce and rebuilds the collision proxy of every
chunk already present, making assembly quadratic — 25 chunks scaled ~7x where linear
would be 2.78x. Attaching chunks directly costs **282 / 131 ms** against **6136 / 2097 ms**,
for identical output including collision on every chunk.

**Pasted baked modules meet cleanly.** Zero mismatched height vertices and zero unmatched
mesh vertices, at both 3x3 (888 / 504 checked) and 5x5 (2960 / 1680). Marching squares
produces matching border geometry either side of a seam whenever the height rows agree,
so the socket scheme holds and the terrain is never the cause of a nav failure.

**A border dig must write the shared vertex in every chunk that owns it.** Skipping the
second write leaves 8 unmatched border vertices — a visible crack.

**Chunks pasted from baked `MSTChunkData` have no `cell_geometry`.** Nav face extraction
returns zero, and the first dig pays a full-chunk cell build: **298 / 82 ms** against a
steady-state **30 / 12 ms**. Warming them on a worker first removes the spike entirely.

**`regenerate_mesh()` leaves the chunk with no collision at all.** It frees every
`StaticBody3D` and only queues the rebuild, one chunk per frame. Confirmed by direct
test, not inferred.

**Digging threads almost completely.** The split is scene-tree access versus pure
computation, not cost. A threaded dig leaves **1.2 / 0.4 ms** on the main thread against
**31 / 13 ms** synchronous, nav rebuild included, and swapping the collision shape instead
of rebuilding the body closes the gap above — 0 of 68 / 0 of 6 in-flight frames were
without collision.

**A per-triangle navmesh does not path across a large cave.** At 4096 polygons per chunk
every one of the 40 adjacent chunk pairs paths fine, but anything more than ~3-4 chunks
long fails. Connectivity was never the problem; Godot's A* does not complete over that
many polygons. Merging coplanar cells into rectangles took 102400 / 25600 polygons down to
**293 / 291**, after which corner-to-corner paths succeed, query cost falls from
3.43 / 1.76 ms to **0.52 / 0.27 ms**, and a single region rebuild falls from
17.6 / 4.6 ms to **2.2 / 0.8 ms**.

**A chunked Recast bake sees decoration, and threads well.** 25 chunks over 16 processors
bake in **354 / 91 ms** on the worker pool against **1323 / 343 ms** serially — 3.7x, and
the shape of the split is what matters more than the ratio: a full rebuild leaves
**2.4 / 1.5 ms** on the main thread, and re-baking a single chunk after a dig leaves
**0.8 / 0.5 ms**. Parsing the props is a one-off 1.6 / 1.3 ms for 33k triangles. The regions
connect across every one of the 40 seams with no manual links, and become queryable in
**one** attempt where the merged navmesh needs 19.

**Growing the bake box by a whole chunk is the demo's single most expensive choice.** It is
right for its 4 m chunks; for a 64 m terrain chunk it voxelises a 192 m box, nine chunks of
work per chunk. Dropping to a 3 m border — Recast only needs `walkable_radius + 3` voxels of
reach past the edge — bakes the same 25 chunks in **75 / 25 ms** instead of 354 / 91, a
**4.7 / 3.6x** saving, with all 40 adjacent pairs still connecting and the corner-to-corner
path still succeeding. This is the configuration the rig leaves live.

**Recast costs more polygons than the merger, not fewer.** 2571 / 2193 against the merger's
1484 / 340, for the same cave. That is the price of geometry it can actually see.

**Whether a short prop blocks is decided in whole voxels, with a band of uncertainty.** A
solid standing on the floor merges with it into one span, so what Recast compares is the
rasterised span tops, and whether a given height lands on N voxels or N+1 depends on where
the bake box's y origin falls. The 1.2 m crates measured this directly: at a nominal 1.0 m
climb and 0.25 m cells they sit inside the band and were stepped onto, leaving
**0.50 / 0.67 m** of clearance — the distance to the floor beside them, not a hole — while
the 1.6 m carts and 5 m trees above the band were carved out cleanly at **1.7-1.8 m**. So
the usable threshold is not `agent_max_climb` but `effective_max_climb() + cell_height`,
exposed as `reliable_block_height()`. Leave a `cell_height` of margin, or carve explicitly.

**Assembling source geometry is not faster than parsing it — that was the wrong reason.**
Building the source from cached collision shapes costs 1.4 / 0.7 ms; parsing the same
colliders out of the scene tree costs 1.2 / 0.4 ms. Both are noise. The reason to assemble
stands anyway: parsing walks the scene tree and can only run on the main thread, while
`get_faces()` and `add_faces()` are resource work a worker can do.

**Nav regions need ~10-20 physics frames before a query works**, even with
`NavigationServer3D.map_force_update()`. An early query returns an empty path, which looks
exactly like "unreachable". The map update itself is cheap and does not scale badly with
region count: **0.35 / 0.10 ms** at 25 regions.

## The recipe

1. **Attach chunks directly**, never through `add_chunk()`.
2. **Warm `cell_geometry` on a worker after pasting** — instant visible geometry from the
   baked mesh, then warm chunks a moment later. ~270 / 72 ms per chunk, parallelisable.
3. **Dig on a worker, publish on the main thread.**
4. **Swap the collision shape, do not rebuild the body.**
5. **Write shared border vertices in every chunk that owns them.**
6. **Merge nav polygons into rectangles**, stepping their perimeters at grid resolution.
7. **Wait ~20 physics frames** after building regions before querying.

## Two things the merger must get right

**Step the perimeter at grid resolution.** Four corners per rectangle is fewer vertices but
silently splits the mesh into islands: Godot matches polygon edges by both endpoints, so a
long edge never pairs with the two shorter ones facing it. Symptom is a 2-point path that
cannot leave its starting polygon.

**Keep rectangles roughly square** (`MERGE_MAX_CELLS`, default 4). Raw greedy merging makes
long thin strips. Corridors are chosen by an A* over the polygon graph whose costs run
between polygon entry points, so elongated polygons distort those costs and the chosen
corridor is often not the direct one — visible as a path running the length of a strip then
turning sharply in open space. Smaller cap means more polygons and better corridors; the
tripwires for going too fine are `nav-merged-queryable` and `nav-merged-every-hop`.

Agent clearance (`AGENT_RADIUS_CELLS`, default 1) drops walkable cells within N cells of a
wall. The erosion pass reads neighbouring chunks' heights through the terrain, so both sides
of a seam reach the same verdict on a shared border cell and the regions still connect.

## Running it

Open `test/mst_test_rig.tscn` and play it (F6). Results print to the Output panel as one
block under a banner — the addon emits a `[MST Persistence]` line per chunk saved or
hydrated, so scroll past a few hundred lines of noise to reach it.

The suite runs twice, at `33x33` and `17x17` chunk dimensions. A full run is around two
minutes, most of it spent building terrain for phases you are probably not reading.

Every phase is behind its own flag on the rig node, under **Phases** in the Inspector. Each
phase builds its own terrain from scratch and none depends on another, so switching one off
is a straight saving — the only shared cost is authoring the modules, which every phase
needs. To iterate on navmesh work, leave `run_recast_nav` on and the rest off:

| Flag | Phase | Cost |
| --- | --- | --- |
| `run_assembly` | 1 — naive vs direct assembly | four terrains; the naive 5x5 is the single slowest measurement in the rig, on purpose |
| `run_seams_and_digging` | 2–4 — seams, digging, border digs | one 3x3 terrain, kept afterwards |
| `run_navigation` | 5 — seam connection, block and reopen | one 2-chunk terrain |
| `run_threading` | 6 — warm-up, threaded dig, collision continuity | one 2x2 terrain |
| `run_nav_scale` | 7–8 — the 25-chunk cave, per-triangle then merged | assembles and warms 25 chunks |
| `run_recast_nav` | 9 — props and chunked Recast baking | assembles 25 chunks, bakes them three times |

Turning off `run_large_dimensions` or `run_small_dimensions` halves whatever is left.

The interactive camera frames whichever terrain survives — the Recast cave if phase 9 ran,
otherwise the largest thing still in the scene — so a nav-only run still opens on the cave
with the props in it rather than on empty space.

Afterwards several terrains stay in the scene:

| terrain | where |
| --- | --- |
| `Live_*` — 3x3, the seam and dig phases | origin |
| `Threaded_*` — 2x2, phase 6 | south |
| `NavScale_*` — the 25-chunk cave, all regions merged | east |
| `Recast_*` — the 25-chunk cave with props, regions baked by Recast | far south-east |

Controls:

- right-drag orbit, wheel zoom, **WASD pan**, Q/E down/up, Shift for faster
- **left-click digs** — threaded, and prints where every millisecond went, main thread
  against worker. On the `Recast_*` cave the navmesh follows with a chunked Recast re-bake
  polled across frames; everywhere else it is the merger.
- **middle-click sends the red cube there** — a `NavigationAgent3D`, dropped on whichever
  cave survives the run

Turn on **Debug > Visible Navigation** before playing. The `Recast_*` cave is the one worth
looking at: the holes punched around each crate, cart and tree trunk are geometry the
merger cannot see at all. Digging it and then middle-clicking exercises assembly, digging,
collision and a threaded nav re-bake in one interaction.

The `Live_*` terrain deliberately contains one broken seam (see `seam-dig`), so a crack
near a chunk border there is the rig proving its point, not a defect.

## Claims

| Claim | Passes when | Outcome |
| --- | --- | --- |
| `assembly-linear` | `add_chunk()` scales linearly with chunk count | fails, by design of the test |
| `assembly-fast` | Direct attachment is materially cheaper | holds |
| `nav-needs-cells` | Hydrated chunks can produce nav faces unaided | fails |
| `seam-paste` | Pasted modules meet with no mismatched vertices | holds |
| `seam-dig` | A border dig needs the shared vertex written everywhere | holds |
| `dig-uniform-cost` | A dig costs the same cold as warm | fails |
| `nav-seam-connect` | Per-chunk regions connect across a seam unaided | holds |
| `nav-repath` | Blocking and reopening is reflected after one region rebuild | holds |
| `collision-gap-sync` | A synchronous dig keeps its collision | fails |
| `warm-then-dig` | After a worker warm-up the first dig is a normal dig | holds |
| `threaded-dig-residue` | A threaded dig leaves under half the cost on the main thread | holds |
| `collision-gap-threaded` | A threaded dig keeps collision every frame | holds |
| `nav-scale-seams` | The 25-chunk cave has clean seams | holds |
| `nav-scale-adjacent-pairs` | Every adjacent chunk pair can path to its neighbour | holds |
| `nav-scale-queryable` | A 25-chunk cave is queryable as fast as a 2-chunk one | fails, per-triangle |
| `nav-scale-query-cost` | A cross-cave query costs under 2 ms | fails at 33x33, per-triangle |
| `nav-scale-update-cost` | One region update stays under 5 ms | fails at 33x33, per-triangle |
| `nav-merged-polycount` | Merging cuts polygons to under a tenth | holds |
| `nav-merged-queryable` | A merged navmesh paths corner to corner | holds |
| `nav-merged-every-hop` | Every chunk along the cave edge is reachable | holds |
| `nav-merged-adjacent-pairs` | Every adjacent pair still connects when merged | holds |
| `recast-sees-props` | Recast carves out props too tall to step onto; the merger cannot | holds |
| `recast-seams` | Chunked Recast regions meet across every seam unaided | holds |
| `recast-parallel` | The pool bake beats the same bakes done one at a time | holds |
| `recast-dig-loop` | Re-baking one chunk leaves under 5 ms on the main thread | holds |
| `recast-trimmed-border` | A few-agent-radii border aligns seams as well as a whole chunk | holds |

The three `nav-scale-*` failures all measure the per-triangle path and are superseded by
the `nav-merged-*` results; they are kept as the A/B that identifies the cause.

## Timings worth reading

- `1-assembly` — naive vs fast at 9 and 25 chunks. Compare the growth, not the absolutes.
- `3-dig` — cold first dig vs steady state, split into mesh / collision / nav face extract.
- `4-seam-dig` — a border dig costs roughly double, because two chunks rebuild.
- `6-threaded` — main-thread prologue + publish versus what the worker absorbed. The
  main-thread total decides whether digging fits inside a frame.
- `7-nav-scale` / `8-nav-merged` — the same nav work per-triangle then merged, side by side.
- `9-recast` — the merger and a chunked Recast bake on the same 25-chunk cave, with props on
  the floor. Read three pairs: pool bake vs serial bake, whole-chunk grow vs a 3 m border,
  and assembling source geometry from cached shapes vs parsing it out of the scene tree.
  The `of which on the main thread` row is the one that decides whether this fits a frame.

## Files

| File | Role |
| --- | --- |
| `mst_test_rig.tscn` / `rig/mst_test_rig.gd` | Orchestrator, camera, interactive digging, the walker |
| `rig/mst_test_modules.gd` | Builds placeholder modules as `MSTChunkData` |
| `rig/mst_test_assembler.gd` | Naive and direct runtime assembly |
| `rig/mst_test_seams.gd` | Height-row and mesh-border seam checks |
| `rig/mst_test_dig.gd` | Runtime digging, with the shared-border-vertex case handled |
| `rig/mst_test_threaded_dig.gd` | The same dig on a worker, plus chunk warm-up |
| `rig/mst_test_nav.gd` | Per-chunk regions, the merger, clearance, path probes |
| `rig/mst_test_recast_nav.gd` | Chunked Recast baking on the worker pool |
| `rig/mst_test_props.gd` | Placeholder decoration, and the prop-clearance probe |
| `rig/mst_test_report.gd` | Collects and prints the results table |
| `tools/export_chunk_as_module.gd` | Editor script: export sculpted chunks as modules |

## Modules

The rig builds its own placeholder modules so it runs with no authored assets. A module is
identified by a 4-bit socket mask of which edges are open. Because every module carves its
passages at the same vertex indices, two modules with matching sockets share an identical
border height row by construction — the property the whole assembly scheme depends on.

Each is built the way the editor builds a chunk and exported through
`MSTDataHandler.export_chunk_data()`, so it is the same kind of resource a sculpted module
would be, baked mesh and collision included.

To use real ones: sculpt a chunk with the normal brushes, select it in the scene tree, and
run `tools/export_chunk_as_module.gd` with **File > Run** (Ctrl+Shift+X). It writes to
`test/modules/` and derives the socket mask from the chunk's border rows.

## Known gaps

**Rock tops are walkable.** A heightmap has no ceiling, so the flat tops of cave walls are a
second walkable layer and agents can path across them. The clean fix is a reachability pass:
flood-fill the polygon graph from the cave entrance and drop anything unconnected, which
also removes stranded islands — the small-region filtering a Recast bake would have done.

**Warm-up is the load-time cost.** ~270 / 72 ms per chunk on one worker, so a 25-chunk cave
is ~6.8 / 1.8 s. Fan it across cores or spread it over frames.

**Merged vertices now snap to the map's grid.** `_weld()` snaps to
`map_get_cell_size() * 0.1` before welding, so two vertices the navigation map already
treats as one can no longer weld apart. Set it from the live map with
`MSTTestNav.use_map_cell_size()`. Cheap insurance; it should change nothing on a grid whose
vertices are whole multiples of the cell size.

**Polygon counts predate the merge cap.** The 293 / 291 figures were measured before
`MERGE_MAX_CELLS` and the cross-seam erosion landed; expect somewhat more polygons now, and
better path corridors.

## Decoration, and why the merger cannot help (phase 9)

The merger reads `height_map` and nothing else. That is exactly why it is fast, and exactly
why it is blind: a mine cart in a corridor, a tree, a bridge, a building — none of it is in
the height map, so none of it is in the navmesh, and agents walk straight through. Phase 9
scatters props on the cave floor and bakes the same 25 chunks with Recast instead, adapted
from Godot's own `3d/navigation_mesh_chunks` demo.

**What is kept from the demo.** One `NavigationMesh` per chunk bounded by
`filter_baking_aabb`; the bake box grown outward so neighbour geometry is voxelised too,
with `border_size` set to the same amount so the overshoot is trimmed back off — that is
what makes adjacent chunks' polygon edges land on identical coordinates, and identical
edges are what let Godot merge regions by edge key instead of by the costly edge-connection
margin. The whole y range goes in one chunk, because `border_size` only trims on xz.
Vertices are snapped to a tenth of the map's cell size against seam float error.

**What is changed.**

1. *The bakes run as a `WorkerThreadPool` group task.* Only two stages have to stay on the
   main thread: parsing source geometry, which walks the scene tree, and assigning
   `navigation_mesh` to a region. Each job owns its own `NavigationMesh` and they only read
   the shared `NavigationMeshSourceGeometryData3D`, which is what makes that safe.
   `begin_bake()` / `is_baking()` / `end_bake()` is the non-blocking form, so a dig can
   re-bake without stalling the frame.

2. *Source geometry is assembled, not parsed, wherever it can be.* Every chunk already owns
   one `ConcavePolygonShape3D` collision proxy, and `Shape3D.get_faces()` is a resource read
   with no scene tree in it — so terrain geometry goes straight into
   `NavigationMeshSourceGeometryData3D.add_faces()` with the chunk transform cached on the
   main thread. Only props need a real parse, and props are static, so that happens once at
   load and is `merge()`d into every rebuild afterwards. `parse_terrain()` does it the
   demo's way instead, and the phase times both so the difference is on the record.

   This sidesteps the group problem noted earlier: the addon only adds `navmesh_*` groups to
   collision bodies inside its editor-only branch, so at runtime the bodies carry no group
   and a group-filtered parse would find nothing. Reading the shape off the node directly
   needs no group at all.

3. *The grow amount is a parameter.* Growing by a whole chunk is right for the demo's 4 m
   chunks, but a 64 m terrain chunk grown by 64 m voxelises a 192 m box — nine chunks of
   work per chunk. `border_size` only has to cover Recast's erosion and region-building
   reach past the edge, which is `walkable_radius + 3` voxels; `recommended_border()`
   returns 4 m for a 1 m agent at 0.5 m cells, which is 8 voxels. Phase 9 bakes both and
   asks whether the cheap one still holds its seams.

**Caveats this bakes in.** The terrain faces are the addon's *simplified* greedy-merged
proxy extruded downward by `collision_thickness`, not the visual mesh — fine for flat-celled
cave floors, not necessarily for sculpted slopes. The whole prop set is merged into every
rebuild; `filter_baking_aabb` keeps the extra triangles out of the voxel grid but they are
still copied and tested, so a level with thousands of props wants them bucketed by chunk
first. And Recast finds the flat tops of the rock walls walkable too, exactly as the merger
does — a height map has no ceiling, so there is nothing above them to fail the agent-height
test.

**Short props do not block, and that is Recast working as asked.** A prop standing on the
floor does not rasterise as floor-plus-obstacle: the two merge into one solid span, so the
column’s walkable surface *is* the prop’s top, and the only remaining question is whether
that top is within `agent_max_climb` of its neighbours. Recast asks that in whole voxels,
`floor(agent_max_climb / cell_height)`, so at `cell_height = 0.5` the test resolved in
half-metre steps and a 1.2 m crate rounded down into “steppable”. At 0.25 the climb test
gets four voxels and a nominal 1.0 m climb is exactly 1.0 m. `climb_voxels()` and
`effective_max_climb()` report what it really is, and phase 9 prints clearance per prop kind
next to that figure.

**Cell size is not a free parameter.** The navigation map keeps its own `cell_size` and
`cell_height` and rasterises every region’s edges onto that grid to decide which edges pair
with which — the mechanism the whole chunked scheme rests on. Baking finer than the map lets
two distinct vertices land on one key, which is what Godot’s `navmesh_cell_size_mismatch`
warning is about, and it surfaces as seams that quietly fail to connect. So the map is the
single source of truth: the baker takes both values from it in `prepare()`
(`match_map_cells`), and the merger does the same through `MSTTestNav.use_map_cell_size()`,
read once at startup. To bake coarser — 0.5 is the textbook value for a 1 m agent radius and
a quarter of the columns — move the *map* with `apply_to_map()` or the
`navigation/3d/default_cell_size` project setting, and both builders follow it down.

For decoration that must block regardless of height — a mine cart, a barrier — the tool is
`NavigationMeshSourceGeometryData3D.add_projected_obstruction(vertices, elevation, height,
true)`, which carves the footprint at bake time and ignores the climb test. Not wired up yet.

**Props are deliberately narrow** (under `2 * agent_radius` across). Recast erodes every
walkable surface by the agent radius, so a narrow top erodes to nothing and the prop leaves
a clean hole; a wide top would survive and leave a floating nav island, which is real
behaviour but would muddy the clearance measurement.

## Next

**Carve props that must block regardless of height.**
`NavigationMeshSourceGeometryData3D.add_projected_obstruction(vertices, elevation, height,
true)` ignores the climb test entirely, which is the right answer for a mine cart or a
barrier that happens to be short. Not wired up yet.

**Decide per map, not globally.** The merger is heightmap-only and cheap; Recast is
geometry-accurate and re-voxelises data already held as a height grid. The cave may well
want both — merger in the dig loop, Recast when props change — and the handcrafted surface
map wants Recast regardless.

**A reachability pass.** Flood-fill the polygon graph from the cave entrance and drop
anything unconnected. That removes the walkable rock tops and stranded islands in one go,
under either builder.

## Not covered on purpose

The graph generator, socket matching beyond a rectangular grid, dig masks, ore and secrets,
ceilings, lighting, and save/load of dug state. None have engine unknowns — they are
ordinary code to write on top of a foundation that is now measured.
