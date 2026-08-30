@tool
extends RefCounted

const CAPTURE_TYPE := "performance_budget_guardian_capture"
const CALIBRATION_TYPE := "performance_budget_calibration"
const MAX_EVIDENCE_FILES := 1000
const MAX_EVIDENCE_BYTES := 8 * 1024 * 1024
const MAX_DISPLAY_TEXT := 500


static func is_safe_project_path(path: String) -> bool:
	if not path.begins_with("res://") or path.contains("\\"):
		return false
	var relative := path.trim_prefix("res://")
	if relative.is_empty():
		return false
	for part in relative.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return false
	return true


static func is_contained_existing_path(path: String) -> bool:
	if not is_safe_project_path(path):
		return false
	var parts := path.trim_prefix("res://").split("/", true)
	var current := "res://"
	for index in parts.size():
		var access := DirAccess.open(current)
		if access == null or access.is_link(parts[index]):
			return false
		current = current.path_join(parts[index])
	return FileAccess.file_exists(current) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(current))


static func parse_file(path: String) -> Dictionary:
	if not is_contained_existing_path(path) or not FileAccess.file_exists(path):
		return _invalid(path, "Evidence must be an existing project-contained file.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _invalid(path, "Evidence could not be opened.")
	if file.get_length() > MAX_EVIDENCE_BYTES:
		file.close()
		return _invalid(path, "Evidence exceeds the 8 MiB display limit.")
	var text := file.get_as_text()
	file.close()
	return parse_text(path, text)


static func parse_text(path: String, text: String) -> Dictionary:
	if not is_safe_project_path(path):
		return _invalid(path, "Evidence path is unsafe.")
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		return _invalid(path, "Evidence is not a JSON object.")
	if parsed.get("result_type") == CAPTURE_TYPE:
		return _parse_capture(path, parsed)
	if parsed.get("report_type") == CALIBRATION_TYPE:
		return _parse_calibration(path, parsed)
	if parsed.has("deterministic_status") and parsed.has("authoritative_exit_code"):
		return _parse_guardian_report(path, parsed)
	return _invalid(path, "Evidence schema is unsupported.")


static func discover_paths(roots: Array[String], additional_paths: Array[String]) -> Dictionary:
	var found: Dictionary = {}
	var state := {"count": 0, "truncated": false}
	for root in roots:
		if state.truncated:
			break
		if not is_safe_project_path(root):
			continue
		var normalized := root.rstrip("/")
		if FileAccess.file_exists(normalized):
			_add_discovered_file(normalized, found, state)
		elif DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(normalized)) and is_contained_existing_path(normalized):
			_scan_directory(normalized, found, state)
	for path in additional_paths:
		if state.truncated:
			break
		_add_discovered_file(path, found, state)
	var paths: Array[String] = []
	for path in found.keys():
		paths.append(path)
	paths.sort()
	return {"paths": paths, "truncated": state.truncated}


static func sort_evidence(items: Array[Dictionary]) -> void:
	items.sort_custom(_evidence_before)


static func _scan_directory(directory_path: String, found: Dictionary, state: Dictionary) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return
	directory.list_dir_begin()
	while true:
		var name := directory.get_next()
		if name.is_empty():
			break
		if name == "." or name == "..":
			continue
		if directory.is_link(name):
			continue
		var child := directory_path.path_join(name)
		if directory.current_is_dir():
			_scan_directory(child, found, state)
		elif name.to_lower().ends_with(".json"):
			_add_discovered_file(child, found, state)
		if state.truncated:
			break
	directory.list_dir_end()


static func _add_discovered_file(path: String, found: Dictionary, state: Dictionary) -> void:
	if not is_safe_project_path(path) or not path.to_lower().ends_with(".json"):
		return
	if not is_contained_existing_path(path) or not FileAccess.file_exists(path):
		return
	if found.has(path):
		return
	if state.count >= MAX_EVIDENCE_FILES:
		state.truncated = true
		return
	found[path] = true
	state.count += 1


static func _parse_capture(path: String, data: Dictionary) -> Dictionary:
	if data.get("schema_version") != 1:
		return _invalid(path, "Capture schema version is unsupported.")
	var profile = data.get("profile")
	var run_id = data.get("run_id")
	var ended_at = data.get("ended_at_utc")
	var addon = data.get("addon")
	var samples = data.get("samples")
	var summary = data.get("summary")
	var availability = data.get("metric_availability")
	if not profile is String or not run_id is String or not ended_at is String:
		return _invalid(path, "Capture identity or completion time is malformed.")
	if not addon is Dictionary or not samples is Array or not summary is Dictionary or not availability is Dictionary:
		return _invalid(path, "Capture metadata is malformed.")
	if not _is_canonical_utc(ended_at):
		return _invalid(path, "Capture ended_at_utc is not a canonical UTC timestamp.")
	var timing = summary.get("timing")
	var counts = summary.get("counts")
	if not timing is Dictionary or not counts is Dictionary:
		return _invalid(path, "Capture summary is malformed.")
	var process = timing.get("process_time_ms")
	var object_count = counts.get("object_count")
	var node_count = counts.get("node_count")
	if not process is Dictionary or not object_count is Dictionary or not node_count is Dictionary:
		return _invalid(path, "Capture summary metrics are missing.")
	var process_p95 = process.get("p95")
	var peak_objects = object_count.get("peak")
	var peak_nodes = node_count.get("peak")
	if not _is_number(process_p95) or not _is_number(peak_objects) or not _is_number(peak_nodes):
		return _invalid(path, "Capture summary values are malformed.")
	var memory = availability.get("memory_static_bytes")
	if not memory is Dictionary or not memory.get("available") is bool:
		return _invalid(path, "Capture memory availability is malformed.")
	var limitations := _safe_string_array(data.get("known_limitations", []))
	return {
		"valid": true,
		"kind": "capture",
		"type_label": "Capture",
		"path": path,
		"timestamped": true,
		"timestamp": ended_at,
		"profile": _safe_identifier_text(profile),
		"run_id": _safe_identifier_text(run_id),
		"status": "Not evaluated",
		"godot_version": _safe_text(str(data.get("godot_version", "unknown"))),
		"addon_version": _safe_text(str(addon.get("version", "unknown"))),
		"sample_count": samples.size(),
		"process_p95_ms": float(process_p95),
		"peak_object_count": int(peak_objects),
		"peak_node_count": int(peak_nodes),
		"memory_available": memory.available,
		"limitations": limitations,
	}


static func _parse_guardian_report(path: String, data: Dictionary) -> Dictionary:
	var schema = data.get("schema_version")
	if schema != 1 and schema != 2:
		return _invalid(path, "Guardian report schema version is unsupported.")
	var deterministic_status = data.get("deterministic_status")
	var validator = data.get("validator")
	var budget = data.get("budget")
	var exit_code = data.get("authoritative_exit_code")
	if deterministic_status not in ["passed", "budget_failed", "error"]:
		return _invalid(path, "Guardian deterministic status is unsupported.")
	if not validator is Dictionary or not budget is Dictionary or not _is_number(exit_code) or float(exit_code) != floor(float(exit_code)):
		return _invalid(path, "Guardian report metadata is malformed.")
	var budget_results = budget.get("results")
	if not budget_results is Array:
		return _invalid(path, "Guardian budget results are malformed.")
	var comparison_results: Array = []
	if schema == 2:
		var comparison = data.get("comparison")
		if not comparison is Dictionary or not comparison.get("results") is Array:
			return _invalid(path, "Guardian comparison results are malformed.")
		comparison_results = comparison.results
	var failures := _guardian_failures(budget_results, comparison_results)
	return {
		"valid": true,
		"kind": "guardian_report",
		"type_label": "Guardian report",
		"path": path,
		"timestamped": false,
		"timestamp": "",
		"profile": _report_profile(budget_results, comparison_results),
		"status": _safe_text(str(deterministic_status)),
		"authoritative_exit_code": int(exit_code),
		"authoritative_exit_reason": _safe_text(str(data.get("authoritative_exit_reason", ""))),
		"validator_status": _safe_text(str(validator.get("status", "unknown"))),
		"failed_rules": failures,
		"limitations": _safe_report_limitations(budget.get("limitations", [])),
	}


static func _guardian_failures(budget_results: Array, comparison_results: Array) -> Array[Dictionary]:
	var by_id: Dictionary = {}
	for result in budget_results:
		if not result is Dictionary or result.get("status") != "failed":
			continue
		var identifier := _safe_identifier_text(str(result.get("budget_id", "unknown-rule")))
		by_id[identifier] = {
			"budget_id": identifier,
			"profile": _safe_identifier_text(str(result.get("profile", "unknown"))),
			"metric": _safe_identifier_text(str(result.get("metric", "unknown"))),
			"unit": _safe_identifier_text(str(result.get("unit", ""))),
			"measured_value": _safe_number_or_null(result.get("measured_value")),
			"maximum_value": _safe_number_or_null(result.get("maximum_value")),
			"absolute_failed": true,
			"relative_failed": false,
		}
	for result in comparison_results:
		if not result is Dictionary or result.get("status") != "failed":
			continue
		var identifier := _safe_identifier_text(str(result.get("budget_id", "unknown-rule")))
		var item: Dictionary = by_id.get(identifier, {
			"budget_id": identifier,
			"profile": _safe_identifier_text(str(result.get("profile", "unknown"))),
			"metric": _safe_identifier_text(str(result.get("metric", "unknown"))),
			"unit": _safe_identifier_text(str(result.get("unit", ""))),
			"measured_value": _safe_number_or_null(result.get("candidate_value")),
			"maximum_value": null,
			"absolute_failed": false,
			"relative_failed": false,
		})
		var absolute = result.get("absolute", {})
		var relative = result.get("relative", {})
		if absolute is Dictionary:
			item.absolute_failed = absolute.get("status") == "failed"
			if item.maximum_value == null:
				item.maximum_value = _safe_number_or_null(absolute.get("maximum"))
		if relative is Dictionary:
			item.relative_failed = relative.get("status") == "failed"
			item.maximum_increase_percent = _safe_number_or_null(relative.get("maximum_increase_percent"))
		item.baseline_value = _safe_number_or_null(result.get("baseline_value"))
		item.candidate_value = _safe_number_or_null(result.get("candidate_value"))
		item.delta = _safe_number_or_null(result.get("delta"))
		item.increase_percent = _safe_number_or_null(result.get("increase_percent"))
		by_id[identifier] = item
	var failures: Array[Dictionary] = []
	for identifier in by_id.keys():
		failures.append(by_id[identifier])
	failures.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.budget_id < b.budget_id)
	return failures


static func _parse_calibration(path: String, data: Dictionary) -> Dictionary:
	if data.get("schema_version") != 1 or data.get("status") != "proposal_generated":
		return _invalid(path, "Calibration report schema or status is unsupported.")
	var validator = data.get("validator")
	var recommendations = data.get("recommendations")
	var calibration = data.get("calibration")
	if not validator is Dictionary or not recommendations is Array or not calibration is Dictionary:
		return _invalid(path, "Calibration report metadata is malformed.")
	var safe_recommendations: Array[Dictionary] = []
	for recommendation in recommendations:
		if not recommendation is Dictionary:
			return _invalid(path, "Calibration recommendation is malformed.")
		for key in ["observed_value", "proposed_maximum", "relative_allowance_percent"]:
			if not _is_number(recommendation.get(key)):
				return _invalid(path, "Calibration recommendation values are malformed.")
		safe_recommendations.append({
			"budget_id": _safe_identifier_text(str(recommendation.get("budget_id", "unknown-rule"))),
			"profile": _safe_identifier_text(str(recommendation.get("profile", "unknown"))),
			"metric": _safe_identifier_text(str(recommendation.get("metric", "unknown"))),
			"unit": _safe_identifier_text(str(recommendation.get("unit", ""))),
			"observed_value": float(recommendation.observed_value),
			"proposed_maximum": float(recommendation.proposed_maximum),
			"relative_allowance_percent": float(recommendation.relative_allowance_percent),
		})
	return {
		"valid": true,
		"kind": "calibration_report",
		"type_label": "Calibration proposal",
		"path": path,
		"timestamped": false,
		"timestamp": "",
		"profile": _recommendation_profile(safe_recommendations),
		"status": "Proposal only",
		"validated_file_count": int(validator.get("validated_file_count", 0)),
		"recommendations": safe_recommendations,
		"limitations": _safe_report_limitations(data.get("limitations", [])),
	}


static func _report_profile(budget_results: Array, comparison_results: Array) -> String:
	for group in [budget_results, comparison_results]:
		for result in group:
			if result is Dictionary and result.get("profile") is String:
				return _safe_identifier_text(result.profile)
	return "all"


static func _recommendation_profile(recommendations: Array[Dictionary]) -> String:
	if recommendations.is_empty():
		return "all"
	var first: String = recommendations[0].profile
	for recommendation in recommendations:
		if recommendation.profile != first:
			return "multiple"
	return first


static func _safe_string_array(value) -> Array[String]:
	var result: Array[String] = []
	if not value is Array:
		return result
	for item in value:
		if item is String:
			result.append(_safe_text(item))
	return result


static func _safe_report_limitations(value) -> Array[String]:
	var result: Array[String] = []
	if not value is Array:
		return result
	for item in value:
		if item is Dictionary and item.get("statement") is String:
			result.append(_safe_text(item.statement))
		elif item is String:
			result.append(_safe_text(item))
	return result


static func _safe_text(value: String) -> String:
	var single_line := value.replace("\r", " ").replace("\n", " ").strip_edges()
	var lowered := single_line.to_lower()
	if lowered.contains("authorization") or lowered.contains("api_key") or lowered.contains("api-key") or lowered.contains("sk-"):
		return "[withheld unsafe text]"
	if _contains_private_path(single_line):
		return "[withheld unsafe text]"
	return single_line.left(MAX_DISPLAY_TEXT)


static func _safe_identifier_text(value: String) -> String:
	var safe := ""
	for index in min(value.length(), 128):
		var character := value.substr(index, 1)
		if character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			safe += character
	return safe if not safe.is_empty() else "unknown"


static func _contains_private_path(value: String) -> bool:
	var lowered := value.to_lower()
	if lowered.contains("/users/") or lowered.contains("/home/") or lowered.contains("\\users\\"):
		return true
	if value.length() >= 3 and value.substr(0, 1).to_lower() in "abcdefghijklmnopqrstuvwxyz" and value.substr(1, 2) in [":\\", ":/"]:
		return true
	return false


static func _safe_number_or_null(value):
	return float(value) if _is_number(value) else null


static func _is_number(value) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _is_canonical_utc(value: String) -> bool:
	if value.length() != 20 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-":
		return false
	if value.substr(10, 1) != "T" or value.substr(13, 1) != ":" or value.substr(16, 1) != ":" or not value.ends_with("Z"):
		return false
	var digit_ranges := [[0, 4], [5, 2], [8, 2], [11, 2], [14, 2], [17, 2]]
	for range_values in digit_ranges:
		if not value.substr(range_values[0], range_values[1]).is_valid_int():
			return false
	var year := value.substr(0, 4).to_int()
	var month := value.substr(5, 2).to_int()
	var day := value.substr(8, 2).to_int()
	var hour := value.substr(11, 2).to_int()
	var minute := value.substr(14, 2).to_int()
	var second := value.substr(17, 2).to_int()
	if year < 1 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59:
		return false
	return day >= 1 and day <= _days_in_month(year, month)


static func _days_in_month(year: int, month: int) -> int:
	if month == 2:
		var leap := year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
		return 29 if leap else 28
	return 30 if month in [4, 6, 9, 11] else 31


static func _evidence_before(a: Dictionary, b: Dictionary) -> bool:
	if a.valid != b.valid:
		return a.valid
	if a.valid and a.timestamped != b.timestamped:
		return a.timestamped
	if a.valid and a.timestamped and a.timestamp != b.timestamp:
		return a.timestamp > b.timestamp
	if a.kind != b.kind:
		return a.kind < b.kind
	return a.path < b.path


static func _invalid(path: String, reason: String) -> Dictionary:
	return {
		"valid": false,
		"kind": "invalid",
		"type_label": "Invalid evidence",
		"path": path if is_safe_project_path(path) else "[unsafe path]",
		"timestamped": false,
		"timestamp": "",
		"profile": "unknown",
		"status": "Invalid",
		"reason": _safe_text(reason),
	}
