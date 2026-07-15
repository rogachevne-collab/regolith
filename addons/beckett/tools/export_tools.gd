@tool
extends RefCounted
class_name BeckettExportTools

## Export tier — list export presets (parsed from export_presets.cfg) and run a headless
## export by shelling out to the Godot binary. Requires export templates for the target
## platform to be installed; the subprocess stdout/stderr is returned so failures show.
## Real exports take minutes — background:true (the default) runs the subprocess as a
## job and the agent polls job_status, so the editor never freezes mid-export.

var server


func _register(registry) -> void:
	registry.register({
		"name": "list_export_presets",
		"description": "List export presets from res://export_presets.cfg: name, platform, runnable, export_path. Configure presets in Project -> Export first.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_list_presets"),
	})
	registry.register({
		"name": "export_project",
		"description": "Export a preset by name via a headless Godot subprocess (--export-release / --export-debug). Writes a binary OUTSIDE res:// — destructive. Needs export templates installed. 'preset' required; 'output_path' overrides the preset's export_path; 'debug':true for a debug build. Runs in the background by default and returns a job_id — poll job_status until running:false (exports take minutes). 'background':false blocks until done instead (freezes the editor; only for tiny projects).",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"preset": {"type": "string"},
			"output_path": {"type": "string"},
			"debug": {"type": "boolean"},
			"pack": {"type": "boolean", "description": "export a .pck resource pack (--export-pack) instead of a platform binary — works without export templates installed; runs via 'godot --main-pack file.pck'"},
			"background": {"type": "boolean", "description": "default true; false = block until the export finishes"},
		}, "required": ["preset"]},
		"handler": Callable(self, "_export"),
	})
	registry.register({
		"name": "job_status",
		"description": "Poll a background job (e.g. an export_project run): pass 'job_id' for running/exit_code/output tail; omit it to list all jobs this session; 'cancel':true kills the job's process.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"job_id": {"type": "string"},
			"cancel": {"type": "boolean"},
		}},
		"handler": Callable(self, "_job_status"),
	})


func _list_presets(_args: Dictionary) -> Dictionary:
	var path := "res://export_presets.cfg"
	if not FileAccess.file_exists(path):
		return {"error": "no export_presets.cfg — define a preset in Project -> Export first"}
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		return {"error": "cannot parse export_presets.cfg: %s" % error_string(err)}
	var presets: Array = []
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			presets.append({
				"name": cfg.get_value(section, "name", ""),
				"platform": cfg.get_value(section, "platform", ""),
				"runnable": cfg.get_value(section, "runnable", false),
				"export_path": cfg.get_value(section, "export_path", ""),
			})
	return {"json": {"count": presets.size(), "presets": presets}}


func _export(args: Dictionary) -> Dictionary:
	var preset := str(args.get("preset", ""))
	if preset.is_empty():
		return {"error": "preset is required"}
	var debug := bool(args.get("debug", false))
	var pack := bool(args.get("pack", false))
	var out_path := str(args.get("output_path", ""))
	if out_path.is_empty():
		var lp := _list_presets({})
		if lp.has("json"):
			for p in lp["json"].get("presets", []):
				if str(p.get("name", "")) == preset:
					out_path = str(p.get("export_path", ""))
					break
		if out_path.is_empty():
			return {"error": "no output_path given and preset '%s' has no export_path set" % preset}
	if pack and out_path.to_lower().ends_with(".exe"):
		out_path = out_path.substr(0, out_path.length() - 4) + ".pck"
	var abs_out := ProjectSettings.globalize_path(out_path) if out_path.begins_with("res://") else out_path
	var proj_dir := ProjectSettings.globalize_path("res://")
	var godot := OS.get_executable_path()
	var flag := "--export-pack" if pack else ("--export-debug" if debug else "--export-release")
	var arguments := ["--headless", "--path", proj_dir, flag, preset, abs_out]

	var prev_enable := OS.get_environment("BECKETT_ENABLE")
	OS.set_environment("BECKETT_ENABLE", "0")

	if bool(args.get("background", true)) and server != null and server.jobs != null:
		var sp: Dictionary = server.jobs.spawn("export", godot, arguments,
			{"preset": preset, "output_path": abs_out, "command": godot + " " + " ".join(arguments)})
		OS.set_environment("BECKETT_ENABLE", prev_enable)
		if sp.has("error"):
			return sp
		return {"json": {
			"ok": true,
			"job_id": sp["job_id"],
			"preset": preset,
			"output_path": abs_out,
			"note": "export running in the background — poll job_status with this job_id until running:false, then check exit_code 0 and that output_path exists",
		}}

	var output: Array = []
	var code := OS.execute(godot, arguments, output, true)
	OS.set_environment("BECKETT_ENABLE", prev_enable)
	var tail := str(output[0]) if not output.is_empty() else ""
	if tail.length() > 4000:
		tail = "...(truncated)...\n" + tail.substr(tail.length() - 4000)
	return {"json": {
		"ok": code == 0 and FileAccess.file_exists(abs_out),
		"exit_code": code,
		"preset": preset,
		"output_path": abs_out,
		"command": godot + " " + " ".join(arguments),
		"output_tail": tail,
	}}


func _job_status(args: Dictionary) -> Dictionary:
	if server == null or server.jobs == null:
		return {"error": "job system unavailable"}
	var id := str(args.get("job_id", ""))
	if id.is_empty():
		return {"json": {"jobs": server.jobs.list()}}
	if bool(args.get("cancel", false)):
		return {"json": server.jobs.cancel(id)}
	var st: Dictionary = server.jobs.status(id)
	if bool(st.get("found", false)) and not bool(st.get("running", true)):
		var meta: Dictionary = st.get("meta", {})
		if meta.has("output_path"):
			st["artifact_exists"] = FileAccess.file_exists(str(meta["output_path"]))
	return {"json": st}
