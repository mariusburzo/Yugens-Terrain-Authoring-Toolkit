# MST cave rig

A measurement rig for one question: **can this terrain addon carry runtime-assembled,
diggable caves?**

It is not a demo and not a game prototype. Every phase exists to confirm or falsify
one specific claim about how the addon behaves at runtime. Run it, read the table,
and treat any `FAILS` line as a thing to design around rather than a bug to fix.

Nothing here touches `addons/`. The rig only uses the addon's public-ish API.

## Running it

Open `test/mst_test_rig.tscn` and play it (F6). Results are printed to the Output
panel as one block. Paste that block back if you want it interpreted.

The addon prints its own `[MST Persistence]` line for every chunk it saves or
hydrates, so expect a few hundred lines of noise first. The results table is the
last thing printed, under a banner — scroll to the bottom.

The suite runs twice, at `33x33` and `17x17` chunk dimensions, because chunk size
is the biggest single lever on per-dig cost and the difference is the point.

Afterwards the last assembled terrain stays in the scene:

- right-drag to orbit, wheel to zoom, **WASD to pan** (Q/E for down/up, Shift to move faster)
- **left-click to dig** — each dig prints its own timing breakdown
- **middle-click to send the red cube there** — a `NavigationAgent3D` walking the
  merged navmesh, so you can watch pathing react to a dig in real time

Several terrains are spread around the origin, so pan to find them: the 3x3 live
terrain at the origin, the 2-chunk nav terrain to the north, the threading terrain
to the south, and the 25-chunk cave from phase 7 to the east.

The two-chunk nav terrain from phase 5 is parked just north of it and also stays
alive. Turn on **Debug > Visible Navigation** before playing to see its regions.
Digging works on either terrain — clicks resolve to whichever one the ray hit — and
on the nav terrain the affected chunks' regions are rebuilt immediately, so the hole
appears in the navmesh as you dig it. That is `nav-repath` made visual.

The final terrain deliberately contains one broken seam (see `seam-dig` below), so
if you spot a crack near a chunk border while looking around, that is the rig
proving its point, not a defect.

## What it claims, and how it decides

| Claim | Passes when |
| --- | --- |
| `assembly-linear` | Pasting modules through `add_chunk()` scales linearly with chunk count |
| `assembly-fast` | Skipping the terrain-wide collision refresh makes assembly materially cheaper |
| `nav-needs-cells` | Chunks hydrated from a baked `MSTChunkData` can produce nav faces without regenerating cell geometry |
| `seam-paste` | Pasted baked modules meet with no mismatched height or mesh vertices |
| `seam-dig` | A border dig needs the shared vertex written in every chunk that owns it — proven by doing it wrong on purpose |
| `dig-uniform-cost` | A dig costs the same whether or not the chunk has been dug before |
| `nav-seam-connect` | Per-chunk nav regions connect across a seam with no manual links |
| `nav-repath` | Blocking and reopening a corridor is reflected after rebuilding only the dug chunks' regions |
| `collision-gap-sync` | A synchronous dig keeps collision between `regenerate_mesh()` and the queued rebuild |
| `warm-then-dig` | After a worker-thread warm-up, the first dig costs no more than a later one |
| `threaded-dig-residue` | A threaded dig leaves less than half the synchronous cost on the main thread |
| `collision-gap-threaded` | A threaded dig keeps collision on every frame the job is in flight |
| `nav-scale-queryable` | A 25-chunk cave becomes queryable in no more frames than a 2-chunk one |
| `nav-scale-query-cost` | A path across the whole cave costs under 2 ms to query |
| `nav-scale-update-cost` | Updating one region on a 25-region map stays under 5 ms on the main thread |
| `nav-scale-seams` | The 25-chunk cave has clean seams, so any path failure is navmesh not geometry |
| `nav-merged-polycount` | Merging coplanar cells cuts the navmesh to under a tenth of the polygons |
| `nav-merged-queryable` | With a merged navmesh, a corner-to-corner path across the cave succeeds |
| `nav-merged-every-hop` | With a merged navmesh, every chunk along the cave edge is reachable |
| `nav-scale-adjacent-pairs` | Every directly adjacent chunk pair can path to its neighbour |
| `nav-merged-adjacent-pairs` | The same, with a merged navmesh |

`assembly-linear` is the one I expect to fail. `add_chunk()` calls
`_schedule_collision_refresh()`, and at runtime that skips its debounce and rebuilds
the collision proxy of every chunk already in the terrain, which would make assembly
quadratic. The `fast` variant exists to measure the same work without that call.

## Timings worth reading

- `1-assembly` — naive vs fast at 9 and 25 chunks. Compare the growth, not the absolute numbers.
- `3-dig` — one dig split into mesh regenerate / collision rebuild / nav face extract.
  Mesh should be small; the other two are whole-chunk passes with no partial path.
- `4-seam-dig` — a border dig costs roughly double, because two chunks rebuild.
- `5-nav` — building and rebuilding per-chunk nav regions.
- `6-threaded` — worker warm-up, then a threaded dig split into main-thread
  prologue + publish versus what the worker absorbed. The main-thread total is the
  number that decides whether digging fits inside a frame.
- `7-nav-scale` — the same nav work on a full 5x5 cave. `map_force_update` is
  synchronous and lands on the main thread, so its cost at 25 regions is the one
  that decides whether per-chunk nav regions scale.

## Files

| File | Role |
| --- | --- |
| `mst_test_rig.tscn` / `rig/mst_test_rig.gd` | Orchestrator, camera, interactive digging |
| `rig/mst_test_modules.gd` | Builds placeholder modules as `MSTChunkData` |
| `rig/mst_test_assembler.gd` | Naive and fast runtime assembly |
| `rig/mst_test_seams.gd` | Height-row and mesh-border seam checks |
| `rig/mst_test_dig.gd` | Runtime digging, with the shared-border-vertex case handled |
| `rig/mst_test_threaded_dig.gd` | The same dig split across a worker thread, plus chunk warm-up |
| `rig/mst_test_nav.gd` | Per-chunk `NavigationRegion3D` building and path tests |
| `rig/mst_test_report.gd` | Collects and prints the results table |
| `tools/export_chunk_as_module.gd` | Editor script: export sculpted chunks as modules |

## Modules

The rig builds its own placeholder modules so it runs with no authored assets. A
module is identified by a 4-bit socket mask of which edges are open. Because every
module carves its passages at the same vertex indices, two modules with matching
sockets share an identical border height row by construction — which is the property
the whole assembly scheme depends on.

Each one is built the way the editor builds a chunk and then exported through
`MSTDataHandler.export_chunk_data()`, so it is the same kind of resource a sculpted
module would be, baked mesh and collision included.

To use real ones instead: sculpt a chunk with the normal brushes, select it in the
scene tree, and run `tools/export_chunk_as_module.gd` with **File > Run**
(Ctrl+Shift+X). It writes to `test/modules/` and derives the socket mask from the
chunk's border rows.

## Not covered on purpose

The graph generator, socket matching beyond a rectangular grid, dig masks, ore and
secrets, ceilings, lighting, and save/load of dug state. None of those have engine
unknowns — they are ordinary code to write once the foundation below them is proven.
Including them here would only make failures harder to localise.
