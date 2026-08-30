@tool
extends VBoxContainer

const EvidenceReader := preload("res://addons/performance_budget_guardian/evidence_reader.gd")
const Probe := preload("res://addons/performance_budget_guardian/performance_probe.gd")
const PROBE_SCRIPT_PATH := "res://addons/performance_budget_guardian/performance_probe.gd"
const MAX_VISIBLE_EVIDENCE := 20
const MAX_VISIBLE_INVALID := 10

var _refresh_timer: Timer
var _status_label: Label
var _probe_tree: Tree
var _evidence_tree: Tree
var _failure_tree: Tree
var _details: RichTextLabel
var _locate_button: Button
var _copy_button: Button
var _file_dialog: FileDialog
var _additional_paths: Array[String] = []
var _evidence: Array[Dictionary] = []
var _selected_path := ""


func _ready() -> void:
	name = "Performance Guardian"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_interface()
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.wait_time = 0.25
	_refresh_timer.timeout.connect(refresh)
	add_child(_refresh_timer)
	call_deferred("refresh")


func schedule_refresh() -> void:
	if _refresh_timer == null:
		return
	_refresh_timer.start()


func refresh() -> void:
	var probes := _collect_probe_nodes(EditorInterface.get_edited_scene_root())
	var roots: Array[String] = ["res://results", "res://.performance-guardian"]
	for probe in probes:
		var output := str(probe.get("output_path"))
		if Probe.is_safe_output_path(output):
			roots.append(output.get_base_dir() if output.to_lower().ends_with(".json") else output)
	var discovery := EvidenceReader.discover_paths(roots, _additional_paths)
	var recognized: Array[Dictionary] = []
	var invalid: Array[Dictionary] = []
	for path in discovery.paths:
		var item := EvidenceReader.parse_file(path)
		if item.valid:
			recognized.append(item)
		else:
			invalid.append(item)
	EvidenceReader.sort_evidence(recognized)
	EvidenceReader.sort_evidence(invalid)
	_evidence.clear()
	for index in min(recognized.size(), MAX_VISIBLE_EVIDENCE):
		_evidence.append(recognized[index])
	for index in min(invalid.size(), MAX_VISIBLE_INVALID):
		_evidence.append(invalid[index])
	_render_probe_status(probes, recognized)
	_render_evidence()
	_render_failures()
	var messages: Array[String] = []
	messages.append("%d probe(s), %d recognized evidence file(s)" % [probes.size(), recognized.size()])
	if not invalid.is_empty():
		messages.append("%d invalid or unsupported file(s)" % invalid.size())
	if discovery.truncated:
		messages.append("scan stopped at %d JSON files" % EvidenceReader.MAX_EVIDENCE_FILES)
	_status_label.text = " • ".join(messages)
	_restore_or_clear_selection()


func _build_interface() -> void:
	var toolbar := HBoxContainer.new()
	var title := Label.new()
	title.text = "Performance Guardian"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(title)
	var refresh_button := Button.new()
	refresh_button.text = "Refresh"
	refresh_button.tooltip_text = "Rescan the active scene and project-contained evidence."
	refresh_button.pressed.connect(refresh)
	toolbar.add_child(refresh_button)
	var import_button := Button.new()
	import_button.text = "Add evidence"
	import_button.tooltip_text = "Add a project-contained JSON file for this editor session."
	import_button.pressed.connect(_show_file_dialog)
	toolbar.add_child(import_button)
	add_child(toolbar)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)

	add_child(_section_label("Probe readiness"))
	_probe_tree = _new_tree(["Node", "Profile", "Status", "Output", "Frames"], 130.0)
	add_child(_probe_tree)

	add_child(_section_label("Recent evidence"))
	_evidence_tree = _new_tree(["Type", "Profile", "Status", "Completed", "Path"], 190.0)
	_evidence_tree.item_selected.connect(_on_evidence_selected)
	add_child(_evidence_tree)

	add_child(_section_label("Failed deterministic rules"))
	_failure_tree = _new_tree(["Rule", "Profile", "Measured", "Threshold", "Report"], 145.0)
	_failure_tree.item_selected.connect(_on_failure_selected)
	add_child(_failure_tree)

	var evidence_actions := HBoxContainer.new()
	_locate_button = Button.new()
	_locate_button.text = "Locate"
	_locate_button.disabled = true
	_locate_button.tooltip_text = "Select this project file in Godot's FileSystem dock."
	_locate_button.pressed.connect(_locate_selected)
	evidence_actions.add_child(_locate_button)
	_copy_button = Button.new()
	_copy_button.text = "Copy res:// path"
	_copy_button.disabled = true
	_copy_button.pressed.connect(_copy_selected_path)
	evidence_actions.add_child(_copy_button)
	add_child(evidence_actions)

	add_child(_section_label("Evidence details"))
	_details = RichTextLabel.new()
	_details.bbcode_enabled = false
	_details.fit_content = false
	_details.custom_minimum_size = Vector2(0, 180)
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details.text = "Select evidence or a failed rule to inspect its safe presentation fields."
	add_child(_details)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.json ; JSON evidence"])
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)


func _section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _new_tree(columns: Array[String], minimum_height: float) -> Tree:
	var tree := Tree.new()
	tree.columns = columns.size()
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	tree.custom_minimum_size = Vector2(0, minimum_height)
	for index in columns.size():
		tree.set_column_title(index, columns[index])
	return tree


func _collect_probe_nodes(root: Node) -> Array[Node]:
	var result: Array[Node] = []
	if root == null:
		return result
	_collect_probe_nodes_recursive(root, result)
	return result


func _collect_probe_nodes_recursive(node: Node, result: Array[Node]) -> void:
	var script = node.get_script()
	if script != null and str(script.resource_path) == PROBE_SCRIPT_PATH:
		result.append(node)
	for child in node.get_children():
		_collect_probe_nodes_recursive(child, result)


func _render_probe_status(probes: Array[Node], all_evidence: Array[Dictionary]) -> void:
	_probe_tree.clear()
	var root := _probe_tree.create_item()
	if probes.is_empty():
		var empty := _probe_tree.create_item(root)
		empty.set_text(0, "No probe in active scene")
		empty.set_text(2, "Not configured")
		return
	for probe in probes:
		var item := _probe_tree.create_item(root)
		var profile := str(probe.get("profile_name"))
		var output := str(probe.get("output_path"))
		var status := _probe_configuration_status(probe)
		var latest: Variant = _latest_capture_for_profile(all_evidence, profile)
		if latest != null:
			status += "; latest %s" % latest.timestamp
		else:
			status += "; no capture found"
		item.set_text(0, str(probe.name))
		item.set_text(1, profile)
		item.set_text(2, status)
		item.set_text(3, output)
		item.set_text(4, "%s + %s / %s" % [probe.get("warmup_frames"), probe.get("measured_frames"), probe.get("sampling_interval_frames")])


func _probe_configuration_status(probe: Node) -> String:
	var profile := str(probe.get("profile_name"))
	var output := str(probe.get("output_path"))
	var run_id := str(probe.get("run_id"))
	var warmup := int(probe.get("warmup_frames"))
	var measured := int(probe.get("measured_frames"))
	var interval := int(probe.get("sampling_interval_frames"))
	if not Probe.is_safe_identifier(profile):
		return "Invalid profile"
	if not Probe.is_safe_output_path(output):
		return "Invalid output"
	if not run_id.is_empty() and not Probe.is_safe_identifier(run_id):
		return "Invalid run ID"
	if warmup < 0 or measured < 1 or interval < 1 or interval > measured:
		return "Invalid frame settings"
	var flags: Array[String] = []
	if not bool(probe.get("auto_start")):
		flags.append("auto-start off")
	if not bool(probe.get("auto_quit")):
		flags.append("auto-quit off")
	return "Ready" if flags.is_empty() else "Ready (%s)" % ", ".join(flags)


func _latest_capture_for_profile(items: Array[Dictionary], profile: String):
	for item in items:
		if item.kind == "capture" and item.profile == profile:
			return item
	return null


func _render_evidence() -> void:
	_evidence_tree.clear()
	var root := _evidence_tree.create_item()
	for evidence in _evidence:
		var item := _evidence_tree.create_item(root)
		item.set_text(0, evidence.type_label)
		item.set_text(1, evidence.profile)
		item.set_text(2, evidence.status if evidence.valid else evidence.reason)
		item.set_text(3, evidence.timestamp if evidence.timestamped else "Untimestamped")
		item.set_text(4, evidence.path)
		item.set_metadata(0, evidence.path)


func _render_failures() -> void:
	_failure_tree.clear()
	var root := _failure_tree.create_item()
	var count := 0
	for evidence in _evidence:
		if not evidence.valid or evidence.kind != "guardian_report":
			continue
		for failure in evidence.failed_rules:
			var item := _failure_tree.create_item(root)
			item.set_text(0, failure.budget_id)
			item.set_text(1, failure.profile)
			item.set_text(2, _failure_measured_text(failure))
			item.set_text(3, _failure_threshold_text(failure))
			item.set_text(4, evidence.path)
			item.set_metadata(0, evidence.path)
			count += 1
	if count == 0:
		var empty := _failure_tree.create_item(root)
		empty.set_text(0, "No failed rules in recognized recent reports")


func _failure_measured_text(failure: Dictionary) -> String:
	if failure.has("candidate_value") and failure.candidate_value != null:
		var baseline := "undefined" if failure.baseline_value == null else _number(failure.baseline_value)
		return "%s → %s %s" % [baseline, _number(failure.candidate_value), failure.unit]
	if failure.measured_value != null:
		return "%s %s" % [_number(failure.measured_value), failure.unit]
	return "Unavailable"


func _failure_threshold_text(failure: Dictionary) -> String:
	var parts: Array[String] = []
	if failure.get("absolute_failed", false) and failure.maximum_value != null:
		parts.append("max %s %s" % [_number(failure.maximum_value), failure.unit])
	if failure.get("relative_failed", false):
		var increase := "undefined" if failure.get("increase_percent") == null else "%s%%" % _number(failure.increase_percent)
		parts.append("%s vs max %s%%" % [increase, _number(failure.get("maximum_increase_percent"))])
	return "; ".join(parts) if not parts.is_empty() else "Failed"


func _number(value) -> String:
	if value == null:
		return "undefined"
	var numeric := float(value)
	return str(int(numeric)) if numeric == floor(numeric) else ("%.3f" % numeric).rstrip("0").rstrip(".")


func _on_evidence_selected() -> void:
	var item := _evidence_tree.get_selected()
	if item != null:
		_select_path(str(item.get_metadata(0)))


func _on_failure_selected() -> void:
	var item := _failure_tree.get_selected()
	if item != null and item.get_metadata(0) != null:
		_select_path(str(item.get_metadata(0)))


func _select_path(path: String) -> void:
	_selected_path = path
	_locate_button.disabled = path.is_empty() or not EvidenceReader.is_safe_project_path(path)
	_copy_button.disabled = _locate_button.disabled
	for evidence in _evidence:
		if evidence.path == path:
			_details.text = _detail_text(evidence)
			return
	_details.text = "Evidence is no longer available in the current scan."


func _detail_text(evidence: Dictionary) -> String:
	var lines: Array[String] = [
		"%s — %s" % [evidence.type_label, evidence.status],
		"Path: %s" % evidence.path,
		"Profile: %s" % evidence.profile,
	]
	if evidence.kind == "capture":
		lines.append("Completed: %s" % evidence.timestamp)
		lines.append("Run: %s" % evidence.run_id)
		lines.append("Godot/addon: %s / %s" % [evidence.godot_version, evidence.addon_version])
		lines.append("Samples: %d" % evidence.sample_count)
		lines.append("Process p95: %s ms" % _number(evidence.process_p95_ms))
		lines.append("Peak objects/nodes: %d / %d" % [evidence.peak_object_count, evidence.peak_node_count])
		lines.append("Static memory: %s" % ("available" if evidence.memory_available else "unavailable"))
	elif evidence.kind == "guardian_report":
		lines.append("Validator: %s" % evidence.validator_status)
		lines.append("Authoritative exit: %d" % evidence.authoritative_exit_code)
		lines.append("Reason: %s" % evidence.authoritative_exit_reason)
		lines.append("Failed rules: %d" % evidence.failed_rules.size())
		for failure in evidence.failed_rules:
			lines.append("- %s: %s; %s" % [failure.budget_id, _failure_measured_text(failure), _failure_threshold_text(failure)])
	elif evidence.kind == "calibration_report":
		lines.append("Proposal only—not an enforced verdict.")
		lines.append("Validated captures: %d" % evidence.validated_file_count)
		for recommendation in evidence.recommendations:
			lines.append("- %s: observed %s %s; proposed max %s %s; relative allowance %s%%" % [recommendation.budget_id, _number(recommendation.observed_value), recommendation.unit, _number(recommendation.proposed_maximum), recommendation.unit, _number(recommendation.relative_allowance_percent)])
	else:
		lines.append("Reason: %s" % evidence.reason)
	if evidence.has("limitations") and not evidence.limitations.is_empty():
		lines.append("Limitations:")
		for limitation in evidence.limitations:
			lines.append("- %s" % limitation)
	return "\n".join(lines)


func _restore_or_clear_selection() -> void:
	if not _selected_path.is_empty():
		for evidence in _evidence:
			if evidence.path == _selected_path:
				_select_path(_selected_path)
				return
	_selected_path = ""
	_locate_button.disabled = true
	_copy_button.disabled = true
	_details.text = "Select evidence or a failed rule to inspect its safe presentation fields."


func _show_file_dialog() -> void:
	_file_dialog.popup_centered_ratio(0.7)


func _on_file_selected(path: String) -> void:
	if not EvidenceReader.is_safe_project_path(path) or not EvidenceReader.is_contained_existing_path(path):
		_status_label.text = "Selected evidence must remain inside res:// and may not traverse links."
		return
	if path not in _additional_paths:
		_additional_paths.append(path)
	refresh()


func _locate_selected() -> void:
	if EvidenceReader.is_safe_project_path(_selected_path):
		EditorInterface.get_file_system_dock().navigate_to_path(_selected_path)


func _copy_selected_path() -> void:
	if EvidenceReader.is_safe_project_path(_selected_path):
		DisplayServer.clipboard_set(_selected_path)
