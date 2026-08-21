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

**Assembling beats parsing, and props dominate either way.** Settled at 17x17 with the two
modes measured side by side in one run, collecting provably identical geometry (same
triangle count, bounds centres 0.000 m apart):

| | full 25 chunks | 9-chunk scope |
| --- | --- | --- |
| cached shapes | 0.55 ms, 42398 tri | **0.39 ms, 33810 tri** |
| one flat group | 1.87 ms, 42398 tri | 1.74 ms, 42398 tri |

Cached is 3.4x faster for a full build and 4.5x faster scoped. An earlier note here claimed
the opposite; it compared `alt: parse terrain from the tree` (terrain only) against an
assembled source that also carried the props, which is not the same geometry.

The more useful number is the scoped triangle count. Terrain scoping works exactly as
intended — 13106 triangles down to 4518, precisely 9/25 — but the scoped source still carries
33810, because all 110 props are merged in whole regardless. **Props are 87% of a scoped
source**, at ~266 triangles each, because the parser tessellates their `CylinderShape3D` and
`BoxShape3D` colliders. That is what per-chunk groups and projected obstructions attack.

**A Recast navmesh does not lie on the surface it was baked from.** Measured at **~0.5 m**
above the floor, consistently, at `cell_height = 0.25` - roughly two cell heights, from voxel
rounding in the poly mesh. Harmless for agents, but it silently broke two measurements here:
clearance was computed as a 3D distance, so every sample carried that 0.5 m as a floor it
could never go below. "0 of 110 props stand on navmesh" and "0 of 25 bridge undersides" were
structurally impossible results, not observations. Clearance is now measured on xz, with the
vertical rise reported separately. Anything comparing a world position against navmesh y has
to expect this offset.

**The hybrid: three lanes, no per-chunk decision.** Terrain from cached collision proxies,
irregular statics parsed one chunk group at a time, decoration carved as obstructions. A
chunk's source is the union of its three lanes, and a chunk with an empty static group makes
no parse call at all. With props as obstructions and no statics in a chunk, the hybrid
degenerates to exactly the cached-shapes path, so it is a strict generalisation rather than
a trade.

All four modes collect identical geometry (14606 triangles, bounds centres 0.000 m apart).
With 25 bridges and 110 props on a 25-chunk cave:

| mode | full build | 9-chunk scope |
| --- | --- | --- |
| cached shapes | 0.49 ms / 14606 tri | 0.17 ms / 6018 tri |
| one flat group | 0.94 ms / 14606 tri | 0.89 ms / 14606 tri |
| per-chunk groups | 1.11 ms / 14606 tri | 0.43 ms / 5058 tri |
| **hybrid** | **0.76 ms / 14606 tri** | **0.30 ms / 5058 tri** |

Cached shapes is still fastest in raw milliseconds, but it cannot scope the parsed half -
6018 triangles against the hybrid's 5058 - and its snapshot goes stale when a static is
destroyed. The hybrid gets the smaller scoped source at roughly half the cost of per-chunk
groups, because terrain never goes through a parse.

**The layer choice is semantic.** Bit 3 (masked out, carved) means *always blocks*, whatever
its height - which is what rescues the 1.2 m crates from the climb-test band. Bit 4 (parsed)
means *physics decides*: walkable, steppable, or walk-under. A bridge on the carve layer
would be sealed solid from the ground up, and a knee-high rock on the carve layer stops being
steppable. Neither failure announces itself.

**Projected obstructions make props free, and change which source mode to pick.** Supplying
each prop as a footprint polygon plus an elevation and a height, with the props' collision
layer masked out of the parse, removes them from the source entirely - `parse 110 props` drops
to **0 triangles**. The source falls from 42398 to 13106 triangles, a 9-chunk scope from
17190 to 4518, and every downstream cost with it:

| | props parsed | props as obstructions |
| --- | --- | --- |
| re-bake one chunk, main thread | 1.12 ms | **0.62 ms** |
| interactive dig, nav on main thread | 0.85-2.05 ms | **0.49-0.76 ms** |
| chop a prop, main thread | 0.66-0.95 ms | **0.45-0.58 ms** |
| bake 25 chunks on the pool | 90.9 ms | 83.4 ms |

It also fixes the climb-band problem outright. Parsed, the 1.2 m crates sit inside the band
and get stepped onto - 0.50/0.67/1.01 m of clearance. As obstructions they measure
**1.35/1.49/1.58 m**, identical to the carts and trees, because a carve ignores the climb
test. The margin does not double up, which confirms obstructions are marked after erosion
rather than before; the small undershoot from the ideal 1.6 m is voxel quantisation at
`cell_size = 0.25`.

**This collapses the source-mode question.** Per-chunk groups earned their place by scoping
props, which cached shapes could not do. With props out of the parsed geometry entirely,
both modes carry pure terrain and scope identically (4518 triangles), and cached shapes is
faster again (0.17 ms against 0.32) *and* the only one a worker can run. The staleness
objection moves with the props: it is now the obstruction list that is a snapshot, and it
has to be rebuilt when a prop is destroyed whichever source mode is selected. So the
combination to reach for is **obstructions plus cached shapes**. Per-chunk groups stay worth
having for geometry that has to be real - anything an agent walks under, which a footprint
extruded straight up cannot represent.

**Three ways to collect source geometry, measured against each other.** All three provably
agree - 42398 triangles each, bounds centres 0.000 m apart - so the choice is purely about
cost and staleness. At 17x17, 25 chunks, with a 9-chunk scope being what an incremental
re-bake actually asks for:

| mode | full build | 9-chunk scope | props go stale? | worker-safe? |
| --- | --- | --- | --- | --- |
| cached shapes | 0.54 ms / 42398 tri | **0.39 ms / 33810 tri** | yes, needs a re-parse | yes |
| one flat group | 1.68 ms / 42398 tri | 1.79 ms / 42398 tri | no | no |
| per-chunk groups | 2.39 ms / 42398 tri | **0.85 ms / 17190 tri** | no | no |

Cached shapes is fastest and the only one a worker can run, but it scopes the *terrain*
only - the props snapshot is merged in whole, which is why its scoped source still carries
33810 triangles, and why it has to be told when a prop is destroyed. Per-chunk groups scope
props too, halving the scoped source, and cannot go stale because they collect fresh every
build. They are the worst choice for a *full* build, paying 25 parse-and-merge round trips,
but full builds happen at load rather than in the dig loop.

In the interactive dig that shows up as nav main-thread cost of 0.85-2.05 ms scaling with
chunks touched, against a flat ~2.2 ms for one global group. Chopping a prop costs
**0.66-0.95 ms** on the main thread and 3.9 ms on the worker, with no terrain work at all -
no mesh, collision proxy, cell geometry or LOD proxy, and no `prepare()`, since nothing the
terrain owns has changed.

**`parse_source_geometry_data()` clears its target, it does not append.** Parsing N groups
straight into one accumulator leaves only the last one, which presents as a navmesh covering
a single chunk and every seam failing. The arithmetic identifies it precisely: 2122 triangles
is one chunk of terrain proxy (13106/25 = 524) plus six props (6 x 266), and
`PROPS_PER_CHUNK` is 6. `recast-source-modes-agree` caught it as a 90.5 m bounds-centre drift
before any of it reached a conclusion. Each group is now parsed into a throwaway and
`merge()`d in; merge is the call that accumulates.

That failure also exposed a weak claim. `recast-sees-props` bounded prop clearance only from
*below*, and "nothing walkable anywhere near this prop" clears a lower bound just as easily
as a correctly carved hole - so it passed, reporting a mean clearance of 82 m. It is now
bounded above as well.

**Terrain LOD never touches collision, but it does not maintain itself at runtime.**
`MSTTerrainLodController` only adds a `MeshInstance3D` proxy per chunk and drives
`visibility_range_begin/end`; there is no `StaticBody3D` or shape anywhere in it, so a
static-collider bake and the LOD system are disjoint. Two runtime traps, though, both from
editor-only branches:

- `_lod_controller.apply()` is reachable at runtime only through
  `_apply_visibility_detail_settings()`, called from `add_chunk()` and from property setters.
  The `_process()` handler that acts on the pending-update flag is inside
  `if is_editor()`. So a terrain assembled through `attach_fast()` has LOD **on with no
  proxies at all**, and `MSTTestAssembler.refresh_lod()` exists to build them.
- `regenerate_mesh()` calls `invalidate_chunk()`, which frees the proxy and only raises that
  same flag. At runtime nothing rebuilds it, and the chunk then renders **nothing** past
  `terrain_lod_start_distance`, because `_configure_proxy_visibility()` caps its real tiles
  at exactly that distance. `MSTTestThreadedDig` invalidates *and* drives the rebuild
  explicitly; measured at 0.82 ms for 4 chunks, and it is inside the dig's publish, so it
  shows up as main-thread cost (`apply()` walks every chunk, not just the dug ones).

With that in place a threaded dig leaves every chunk a live proxy — 4 before, 4 after — and a
wall dug from far away is correct on zoom-in.

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
- **left-click a prop or a bridge destroys it** — navmesh only. No height changed, so there is
  no mesh, collision proxy, cell geometry or LOD proxy work, and `prepare()` is skipped
  because the cached chunk shapes are still valid. This is the case that separates the source
  modes: with `Cached shapes` the log shows an extra props re-parse, because that mode
  merges a one-off snapshot into every build and the snapshot has just gone stale. The parsed
  modes collect props fresh and simply stop finding it. Props sit on their own collision
  layer (bit 3; the terrain holds bits 1, 5 and 9) so decoration can be queried separately,
  but identity comes from the `mst_nav_prop` group.
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
| `recast-sees-props` | Recast carves out props too tall to step onto | holds |
| `recast-source-modes-agree` | All three source modes collect the same geometry | holds |
| `recast-chunk-groups-scope` | Per-chunk groups scope a parse, props included | holds |
| `recast-sees-props` (obstruction mode) | Crates inside the climb band block too | holds |
| `lod-survives-threaded-dig` | A threaded dig leaves every chunk a live LOD proxy | holds |
| `recast-walk-under-bridge` | The floor under a bridge deck stays walkable | holds once measured on xz; see below |
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
| `rig/mst_recast_bake_settings.tres` | The `NavigationMesh` template phase 9 bakes from |
| `rig/mst_test_props.gd` | Placeholder decoration, and the prop-clearance probe |
| `rig/mst_test_statics.gd` | Bridges: irregular geometry with walk-under clearance |
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

**Open: the merger does not cover most prop positions, and it is not the rock tops.** Phase 9
reports 19 of 110 props standing on merged navmesh, with the closest point averaging 2.71 m
away at y = 0.00 and *zero* props whose closest point is more than 1 m above the floor — so
the queries are landing on floor, not on the walkable wall tops. Props are placed with two
vertices (4 m) of all-floor clearance and the merger erodes one cell (2 m), so they should
sit on navmesh. They mostly do not, and no reading of the merger explains it yet. It does not
affect any Recast result, and the `recast-sees-props` claim no longer depends on it.

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

**Every Recast parameter is a resource, not a constant.** `rig/mst_recast_bake_settings.tres`
is a `NavigationMesh` assigned to the rig node’s `recast_bake_settings`, and each chunk bakes
from a duplicate of it — so agent metrics, the filters, the region and edge simplification
knobs, and crucially `geometry_parsed_geometry_type` and `geometry_source_geometry_mode` are
all editable in the Inspector. The same resource drives parsing, so switching it to
`PARSED_GEOMETRY_MESH_INSTANCES` makes both parse calls collect meshes instead of colliders
with no code change. Two properties are overwritten per chunk and ignored on the template:
`filter_baking_aabb` and `border_size`, which belong to the chunking scheme. The template is
never mutated — `prepare()` takes a working copy, so `match_map_cells` writing the map’s cell
size into it cannot dirty the `.tres`. Leave the export null and
`MSTTestRecastNav.default_settings()` supplies the values the measurements above were taken
with. The resource ships with only the properties those measurements exercised; the rest are
at their defaults and can be added from the Inspector.

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

**Give the cave a ceiling.** Recast drops walkable surface without `agent_height` clearance
above it, so a ceiling removes the walkable rock tops for free - something the merger can
never do, because a height map has no ceiling. Failing that, a reachability flood-fill.

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
