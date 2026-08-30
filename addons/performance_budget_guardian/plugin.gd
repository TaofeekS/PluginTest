@tool
extends EditorPlugin

const PROBE_SCRIPT := preload("res://addons/performance_budget_guardian/performance_probe.gd")
const MAIN_SCREEN_SCRIPT := preload("res://addons/performance_budget_guardian/performance_guardian_main_screen.gd")

var _main_screen: Control


func _enter_tree() -> void:
	add_custom_type("PerformanceBudgetProbe", "Node", PROBE_SCRIPT, null)
	_main_screen = MAIN_SCREEN_SCRIPT.new()
	EditorInterface.get_editor_main_screen().add_child(_main_screen)
	_main_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_make_visible(false)
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
	if _main_screen != null:
		var parent := _main_screen.get_parent()
		if parent != null:
			parent.remove_child(_main_screen)
		_main_screen.free()
		_main_screen = null
	remove_custom_type("PerformanceBudgetProbe")


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _main_screen != null:
		_main_screen.visible = visible


func _get_plugin_name() -> String:
	return "Guardian"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")


func _on_editor_changed(_scene_root: Node) -> void:
	if _main_screen != null:
		_main_screen.schedule_refresh()


func _on_scene_saved(_path: String) -> void:
	if _main_screen != null:
		_main_screen.schedule_refresh()


func _on_filesystem_changed() -> void:
	if _main_screen != null:
		_main_screen.schedule_refresh()
