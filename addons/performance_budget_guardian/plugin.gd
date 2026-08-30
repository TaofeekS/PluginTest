@tool
extends EditorPlugin

const PROBE_SCRIPT := preload("res://addons/performance_budget_guardian/performance_probe.gd")
const DOCK_SCRIPT := preload("res://addons/performance_budget_guardian/performance_guardian_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	add_custom_type("PerformanceBudgetProbe", "Node", PROBE_SCRIPT, null)
	_dock = DOCK_SCRIPT.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	scene_changed.connect(_on_editor_changed)
	scene_saved.connect(_on_scene_saved)
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_filesystem_changed)


func _exit_tree() -> void:
	if scene_changed.is_connected(_on_editor_changed):
		scene_changed.disconnect(_on_editor_changed)
	if scene_saved.is_connected(_on_scene_saved):
		scene_saved.disconnect(_on_scene_saved)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		filesystem.filesystem_changed.disconnect(_on_filesystem_changed)
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.free()
		_dock = null
	remove_custom_type("PerformanceBudgetProbe")


func _on_editor_changed(_scene_root: Node) -> void:
	if _dock != null:
		_dock.schedule_refresh()


func _on_scene_saved(_path: String) -> void:
	if _dock != null:
		_dock.schedule_refresh()


func _on_filesystem_changed() -> void:
	if _dock != null:
		_dock.schedule_refresh()
