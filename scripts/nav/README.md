# MSTChunkedNavMesh

One `NavigationRegion3D` per terrain chunk, baked in parallel from real geometry,
re-baked incrementally when the world changes.

The addon's own `MarchingSquaresTerrainNavMesh` is a single region baked from
`height_map`. Use that for a static level. Use this one when the player digs, and
when there is decoration standing on the ground that agents have to walk around.

## Wiring

```
Terrain (MarchingSquaresTerrain)
+- ChunkedNavMesh   <- mst_chunked_navmesh.gd
Props   (Node3D)    <- crates, carts, trees      layer 3
Statics (Node3D)    <- bridges, ramps, buildings layer 4
Player  (Node3D)
```

In the Inspector on `ChunkedNavMesh`:

| property | value |
| --- | --- |
| `terrain_path` | empty - it uses its parent |
| `bake_settings` | `mst_navmesh_settings.tres` |
| `obstacle_collision_mask` | layer 3 |
| `obstacle_root_path` | `../Props` |
| `static_collision_mask` | layer 4 |
| `static_root_path` | `../Statics` |
| `edge_connections` | **off** |

Both masks double as on/off switches: leave one at 0 and that lane is skipped
entirely. They must not overlap - a body on a shared layer would be carved out
*and* parsed as geometry. The node warns about this in the editor.

Nothing else needs setting up. The per-chunk groups the statics lane parses are
generated and registered automatically; there are no group names to type.

## From gameplay code

```gdscript
# terrain changed - the chunk's collision proxy is a new resource, so it has to
# be re-resolved before the bake
nav.rebake_terrain_at([hit.position])

# a prop was destroyed - the terrain is untouched, so skip that work entirely
nav.remove_obstacle(tree.get_node("Body"))
tree.queue_free()

# a prop was spawned
nav.add_obstacle(crate)
```

All three are non-blocking and coalesce: several calls in one frame produce one
bake. `bake_finished(chunks, msec)` fires when the regions have been published.

Call `rebuild()` after loading or generating a level. `bake_on_ready` does it
once at startup.

## Baking in the editor

**Bake Navigation Meshes** bakes every chunk now and gives the regions an owner,
so they save with the scene. **Clear Baked Navigation** removes them again.

Turn `bake_on_ready` **off** afterwards, or the game discards what you baked and
bakes it again at startup. Everything else keeps working with it off - the chunk
geometry is still resolved at load, so digs and destroyed props still re-bake.

Worth knowing before you press it: the polygons are serialised into the `.tscn`,
and a square kilometre is a lot of polygons. For a level small enough that a
startup bake is not noticeable, leaving `bake_on_ready` on is tidier.

## Startup timing

The terrain is not ready when this node is. `MarchingSquaresTerrain` fills
`chunks` and builds the collision proxies in `_deferred_enter_tree()`, which is
`call_deferred` out of `_enter_tree` and then awaits a process frame of its own
before `initialize_terrain()` runs on each chunk. So the proxies do not exist for
at least two frames after this node's `_ready`.

This node polls for the real condition rather than waiting a fixed number of
frames, and warns if the terrain never gets there. If a bake ever produces zero
polygons, it says so - an empty navmesh and no navmesh at all look identical
otherwise.

## The three source lanes

| lane | mechanism | scoped | thread |
| --- | --- | --- | --- |
| terrain | cached `ConcavePolygonShape3D` proxies, `add_faces()` | yes | worker |
| irregular statics | one parse per non-empty chunk group | yes | main |
| decoration | `add_projected_obstruction()`, 4 vertices each | yes | worker |

A chunk's source is the union of its lanes. Most chunks carry no buildings, so
most chunks have no parse to make - that is where the saving is.

**Which lane does a prop belong on?** If a four-vertex footprint extruded
straight up describes it, it is decoration. If it needs a hole through it, or a
walkable surface on top, it is an irregular static.

## Two settings worth understanding

**`edge_connections` off.** The navigation map's edge-connection margin looks for
neighbouring regions across every free edge on the map, so its cost grows with
total polygons rather than with what changed. At 1024 regions it delayed a dig
becoming walkable by tens of seconds. Regions here meet by exact edge match -
that is what the border trimming and vertex snapping are for - so the margin has
nothing left to fix.

**`active_radius_chunks`.** A disabled region leaves the map entirely, which
bounds both the server's re-sync cost and the polygon graph A\* has to search.
A\* has a search-space limit: on a 1 km map a query gave up around 576 m with
every region live. Set a radius and an `active_focus_path` and the window follows
the player. The cost is that agents cannot path into what is switched off.

## Short props do not block by themselves

A floor and the crate standing on it rasterise into one solid span, so the
column's walkable surface *is* the crate's top, and the only question left is
whether that top is within `agent_max_climb` of its neighbours. Anything under
`reliable_block_height()` gets stepped onto rather than walked around.

That is why the decoration lane exists: a projected obstruction is carved out at
bake time and ignores the climb test entirely.

Measurements behind all of the above are in [test/README.md](../../test/README.md).
