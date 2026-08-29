@tool
extends EditorPlugin

const PROBE_SCRIPT := preload("res://addons/performance_budget_guardian/performance_probe.gd")


func _enter_tree() -> void:
	add_custom_type("PerformanceBudgetProbe", "Node", PROBE_SCRIPT, null)


func _exit_tree() -> void:
	remove_custom_type("PerformanceBudgetProbe")

