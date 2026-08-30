extends Node

const RESULT_TYPE := "performance_budget_guardian_capture"
const SCHEMA_VERSION := 1
const ADDON_NAME := "Performance Budget Guardian"
const ADDON_VERSION := "1.2.0"
const MEMORY_STORAGE_LIMITATION := "Because the probe accumulates raw samples during capture, static-memory growth includes probe storage overhead and cannot by itself prove a project memory leak."
const PERCENTILE_DEFINITION := "nearest-rank: sort ascending; select one-based rank ceil(p * N), clamped to 1..N"

@export var profile_name := "main_scene"
@export_range(0, 1000000, 1) var warmup_frames := 120
@export_range(1, 1000000, 1) var measured_frames := 600
@export_range(1, 1000000, 1) var sampling_interval_frames := 1
@export var output_path := "res://results"
@export var run_id := ""
@export var source_revision := ""
@export var auto_start := true
@export var auto_quit := false

var _samples: Array[Dictionary] = []
var _memory_static_available := false
var _capture_started_usec := 0
var _measurement_started_usec := 0
var _measurement_finished_usec := 0
var _started_at_utc := ""
var _ended_at_utc := ""
var _resolved_result_path := ""
var _run_id_explicitly_supplied := false


func _ready() -> void:
	if auto_start:
		call_deferred("_run_capture")


static func is_safe_identifier(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	var first := value.substr(0, 1)
	if not first.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789":
		return false
	for index in value.length():
		var character := value.substr(index, 1)
		if not character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			return false
	return true


static func is_safe_source_revision(value: String) -> bool:
	if value.is_empty():
		return true
	if value.length() > 128 or value.begins_with("/") or value.contains("\\"):
		return false
	for part in value.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return false
	for index in value.length():
		var character := value.substr(index, 1)
		if not character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789._-/":
			return false
	return true


static func is_safe_output_path(value: String) -> bool:
	if not value.begins_with("res://") or value.contains("\\"):
		return false
	var relative := value.trim_prefix("res://")
	if relative.is_empty():
		return false
	for part in relative.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return false
	return true


static func parse_nonnegative_integer(value: String):
	if not value.is_valid_int():
		return null
	var parsed := value.to_int()
	return parsed if parsed >= 0 and parsed <= 1000000 else null


func _run_capture() -> void:
	_capture_started_usec = Time.get_ticks_usec()
	_started_at_utc = _utc_timestamp()
	if not _parse_arguments() or not _validate_configuration():
		return
	_resolved_result_path = _resolve_result_path()
	if _resolved_result_path.is_empty():
		_fail("Could not resolve the configured output path", 3)
		return
	if FileAccess.file_exists(ProjectSettings.globalize_path(_resolved_result_path)):
		var collision_message := "Result already exists; provide a new run ID" if _run_id_explicitly_supplied else "Generated result path already exists; rerun to generate a new ID"
		_fail(collision_message, 3)
		return

	for _frame in warmup_frames:
		await get_tree().process_frame

	var baseline_memory := float(Performance.get_monitor(Performance.MEMORY_STATIC))
	_memory_static_available = OS.is_debug_build() and baseline_memory > 0.0
	_measurement_started_usec = Time.get_ticks_usec()
	var sample_index := 0
	for measured_frame in range(1, measured_frames + 1):
		await get_tree().process_frame
		if measured_frame % sampling_interval_frames == 0 or measured_frame == measured_frames:
			sample_index += 1
			_samples.append(_capture_sample(sample_index, measured_frame))
	_measurement_finished_usec = Time.get_ticks_usec()
	_ended_at_utc = _utc_timestamp()

	var result := _build_result()
	if not _write_json_atomically(_resolved_result_path, result):
		_fail("Result output failed; an existing explicit run ID must be replaced by the caller", 3)
		return

	print("PBG_RESULT=%s" % _resolved_result_path)
	if auto_quit:
		get_tree().quit(0)


func _parse_arguments() -> bool:
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--pbg-"):
			continue
		if argument.begins_with("--pbg-profile="):
			profile_name = argument.trim_prefix("--pbg-profile=")
		elif argument.begins_with("--pbg-warmup-frames="):
			var value = parse_nonnegative_integer(argument.trim_prefix("--pbg-warmup-frames="))
			if value == null:
				return _argument_error("--pbg-warmup-frames requires an integer from 0 to 1000000")
			warmup_frames = value
		elif argument.begins_with("--pbg-measured-frames="):
			var value = parse_nonnegative_integer(argument.trim_prefix("--pbg-measured-frames="))
			if value == null:
				return _argument_error("--pbg-measured-frames requires an integer from 1 to 1000000")
			measured_frames = value
		elif argument.begins_with("--pbg-sampling-interval="):
			var value = parse_nonnegative_integer(argument.trim_prefix("--pbg-sampling-interval="))
			if value == null:
				return _argument_error("--pbg-sampling-interval requires an integer from 1 to 1000000")
			sampling_interval_frames = value
		elif argument.begins_with("--pbg-output="):
			output_path = argument.trim_prefix("--pbg-output=")
		elif argument.begins_with("--pbg-run-id="):
			run_id = argument.trim_prefix("--pbg-run-id=")
		elif argument.begins_with("--pbg-source-revision="):
			source_revision = argument.trim_prefix("--pbg-source-revision=")
		elif argument == "--pbg-auto-quit":
			auto_quit = true
		else:
			return _argument_error("Unknown Performance Budget Guardian argument")
	return true


func _validate_configuration() -> bool:
	if not is_safe_identifier(profile_name):
		return _argument_error("Profile names must use 1-64 letters, digits, dot, underscore, or hyphen")
	_run_id_explicitly_supplied = not run_id.is_empty()
	if run_id.is_empty():
		run_id = "%s-%s-%s" % [profile_name, _timestamp_id(), OS.get_process_id()]
	if not is_safe_identifier(run_id):
		return _argument_error("Run IDs must use 1-64 letters, digits, dot, underscore, or hyphen")
	if not is_safe_source_revision(source_revision):
		return _argument_error("Source revisions must be empty or use safe revision characters")
	if warmup_frames < 0 or measured_frames < 1 or sampling_interval_frames < 1:
		return _argument_error("Frame counts are outside their supported ranges")
	if sampling_interval_frames > measured_frames:
		return _argument_error("Sampling interval must not exceed measured frames")
	if not is_safe_output_path(output_path):
		return _argument_error("Output must be a safe project-relative res:// path")
	return true


func _argument_error(message: String) -> bool:
	_fail(message, 2)
	return false


func _capture_sample(sample_index: int, measured_frame: int) -> Dictionary:
	var memory_value = null
	if _memory_static_available:
		memory_value = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	return {
		"sample_index": sample_index,
		"measured_frame": measured_frame,
		"elapsed_measurement_usec": Time.get_ticks_usec() - _measurement_started_usec,
		"process_time_ms": float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0,
		"physics_process_time_ms": float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0,
		"memory_static_bytes": memory_value,
		"object_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_node_count": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	}


func _build_result() -> Dictionary:
	var timing := {}
	for key in ["process_time_ms", "physics_process_time_ms"]:
		timing[key] = _timing_stats(_sample_values(key))
	var counts := {}
	for key in ["memory_static_bytes", "object_count", "node_count", "orphan_node_count"]:
		counts[key] = _series_stats(_sample_values(key, true))
	var limitations := [
		"Global object, node, memory, and timing monitors include engine and addon activity; they are not owned solely by this profile.",
		MEMORY_STORAGE_LIMITATION,
		"Process and physics timing include engine scheduling and probe overhead; no project workload timer is claimed.",
		"Measurements depend on the recorded host and runtime configuration and are not portable performance guarantees.",
		"Headless capture does not establish rendering or GPU performance.",
	]
	var revision_value = source_revision if not source_revision.is_empty() else null
	if revision_value == null:
		limitations.append("No source revision was supplied; the exact source revision is unknown.")
	return {
		"result_type": RESULT_TYPE,
		"schema_version": SCHEMA_VERSION,
		"addon": {"name": ADDON_NAME, "version": ADDON_VERSION},
		"profile": profile_name,
		"project_name": str(ProjectSettings.get_setting("application/config/name", "Unnamed Project")),
		"run_id": run_id,
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"warmup_frames": warmup_frames,
		"measured_frames": measured_frames,
		"sampling_interval_frames": sampling_interval_frames,
		"percentile_definition": PERCENTILE_DEFINITION,
		"started_at_utc": _started_at_utc,
		"ended_at_utc": _ended_at_utc,
		"source_revision": revision_value,
		"headless": DisplayServer.get_name() == "headless",
		"measurement_configuration": {
			"auto_start": auto_start,
			"auto_quit": auto_quit,
			"output_path": output_path,
		},
		"environment": {
			"debug_build": OS.is_debug_build(),
			"os_name": OS.get_name(),
			"os_version": OS.get_version(),
			"display_driver": DisplayServer.get_name(),
		},
		"metric_availability": {
			"memory_static_bytes": {
				"available": _memory_static_available,
				"debug_only": true,
				"reason": "available when a debug build reports a positive MEMORY_STATIC value" if _memory_static_available else "runtime is not a debug build or MEMORY_STATIC did not report a positive value",
			},
		},
		"samples": _samples,
		"summary": {
			"timing": timing,
			"counts": counts,
			"measurement_duration_ms": float(_measurement_finished_usec - _measurement_started_usec) / 1000.0,
			"capture_duration_ms": float(Time.get_ticks_usec() - _capture_started_usec) / 1000.0,
		},
		"known_limitations": limitations,
	}


func _sample_values(key: String, skip_null := false) -> Array:
	var values: Array = []
	for sample in _samples:
		var value = sample.get(key)
		if value == null and skip_null:
			continue
		values.append(value)
	return values


func _timing_stats(values: Array) -> Dictionary:
	var total := 0.0
	var maximum := float(values[0])
	for value in values:
		total += float(value)
		maximum = maxf(maximum, float(value))
	return {"mean": total / values.size(), "p50": _nearest_rank(values, 0.50), "p95": _nearest_rank(values, 0.95), "max": maximum}


func _series_stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"initial": null, "final": null, "peak": null, "delta": null}
	var peak := float(values[0])
	for value in values:
		peak = maxf(peak, float(value))
	return {"initial": values[0], "final": values[-1], "peak": peak, "delta": float(values[-1]) - float(values[0])}


func _nearest_rank(values: Array, percentile: float) -> float:
	var ordered := values.duplicate()
	ordered.sort()
	var rank := clampi(int(ceil(percentile * ordered.size())), 1, ordered.size())
	return float(ordered[rank - 1])


func _resolve_result_path() -> String:
	var requested := output_path
	if not requested.to_lower().ends_with(".json"):
		requested = requested.path_join("%s.json" % run_id)
	return requested


func _write_json_atomically(project_path: String, result: Dictionary) -> bool:
	if not is_safe_output_path(project_path):
		return false
	var absolute_path := ProjectSettings.globalize_path(project_path)
	var parent_directory := absolute_path.get_base_dir()
	var mkdir_error := DirAccess.make_dir_recursive_absolute(parent_directory)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		return false
	if FileAccess.file_exists(absolute_path):
		return false
	var temporary_path := "%s.tmp.%s" % [absolute_path, OS.get_process_id()]
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(result, "  "))
	file.flush()
	file.close()
	var rename_error := DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary_path)
		return false
	return true


func _utc_timestamp() -> String:
	return "%sZ" % Time.get_datetime_string_from_system(true, false)


func _timestamp_id() -> String:
	return Time.get_datetime_string_from_system(true, false).replace(":", "").replace("-", "")


func _fail(message: String, exit_code: int) -> void:
	push_error("PerformanceBudgetProbe: %s" % message)
	get_tree().quit(exit_code)
