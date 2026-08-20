@tool
extends EditorScript
## Exports the selected MarchingSquaresTerrainChunk nodes as reusable module
## resources, so hand-sculpted modules can replace the rig's placeholders.
##
## Usage: select one or more chunk nodes in the scene tree, then run this script
## with File > Run (Ctrl+Shift+X) in the script editor.
##
## The chunk must have a complete mesh before exporting, otherwise the module
## carries no baked geometry and pasting it at runtime will trigger a rebuild.


const OUTPUT_DIR : String = "res://test/modules"


func _run() -> void:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var chunks : Array[MarchingSquaresTerrainChunk] = []
	for node: Node in selected:
		if node is MarchingSquaresTerrainChunk:
			chunks.append(node as MarchingSquaresTerrainChunk)

	if chunks.is_empty():
		push_warning("[module export] Select one or more MarchingSquaresTerrainChunk nodes first.")
		return

	if not DirAccess.dir_exists_absolute(OUTPUT_DIR):
		DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)

	for chunk in chunks:
		if chunk.terrain_system == null:
			push_warning("[module export] Skipping %s: no terrain_system." % chunk.name)
			continue
		if not chunk.is_mesh_complete_for_storage():
			push_warning("[module export] %s has no complete baked mesh; the module will need a runtime rebuild." % chunk.name)

		var data := MSTDataHandler.export_chunk_data(chunk)
		var mask := _socket_mask(chunk)
		var path := "%s/%s_mask%d.tres" % [OUTPUT_DIR, chunk.name.to_snake_case(), mask]
		var error := ResourceSaver.save(data, path)
		if error != OK:
			push_error("[module export] Failed to save %s (error %d)." % [path, error])
			continue
		print("[module export] %s -> %s (socket mask %d: %s)" % [chunk.name, path, mask, _mask_to_text(mask)])

	EditorInterface.get_resource_filesystem().scan()


## Derives the socket mask from the chunk's border rows: an edge counts as open
## if any vertex along it sits at or below the midpoint of the chunk's height
## range, which is the same rule the rig's placeholder modules follow.
func _socket_mask(chunk: MarchingSquaresTerrainChunk) -> int:
	var dimensions : Vector3i = chunk.dimensions
	var threshold := _open_threshold(chunk, dimensions)
	var mask := 0
	for x in range(dimensions.x):
		if float(chunk.height_map[0][x]) <= threshold:
			mask |= MSTTestModules.OPEN_N
		if float(chunk.height_map[dimensions.z - 1][x]) <= threshold:
			mask |= MSTTestModules.OPEN_S
	for z in range(dimensions.z):
		if float(chunk.height_map[z][dimensions.x - 1]) <= threshold:
			mask |= MSTTestModules.OPEN_E
		if float(chunk.height_map[z][0]) <= threshold:
			mask |= MSTTestModules.OPEN_W
	return mask


func _open_threshold(chunk: MarchingSquaresTerrainChunk, dimensions: Vector3i) -> float:
	var lowest := INF
	var highest := -INF
	for z in range(dimensions.z):
		for x in range(dimensions.x):
			var height := float(chunk.height_map[z][x])
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	return lowest + (highest - lowest) * 0.5


func _mask_to_text(mask: int) -> String:
	var parts : Array[String] = []
	if mask & MSTTestModules.OPEN_N:
		parts.append("N")
	if mask & MSTTestModules.OPEN_E:
		parts.append("E")
	if mask & MSTTestModules.OPEN_S:
		parts.append("S")
	if mask & MSTTestModules.OPEN_W:
		parts.append("W")
	if parts.is_empty():
		return "solid"
	return "".join(parts)
