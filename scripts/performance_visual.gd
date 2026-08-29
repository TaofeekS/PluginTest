extends Node2D

const DEFAULT_TARGET_COUNT := 25000
const LOAD_STEP := 5000
const MAX_TARGET_COUNT := 250000
const HUD_REFRESH_INTERVAL := 0.2
const PerformanceShapeScript := preload("res://scripts/performance_shape.gd")

@export_range(0, MAX_TARGET_COUNT, 1) var target_count := DEFAULT_TARGET_COUNT
@export_range(1, 25000, 1) var spawn_batch_size := 2500
@export var size_range := Vector2(4.0, 16.0)
@export var speed_range := Vector2(35.0, 150.0)
@export var lifetime_range := Vector2(1.5, 6.0)

@onready var object_container: Node2D = $ObjectContainer
@onready var stats_label: Label = $HUD/MarginContainer/PanelContainer/VBoxContainer/Stats
@onready var state_label: Label = $HUD/MarginContainer/PanelContainer/VBoxContainer/State

var _rng := RandomNumberGenerator.new()
var _movement_bounds := Rect2()
var _hud_elapsed := HUD_REFRESH_INTERVAL


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	object_container.process_mode = Node.PROCESS_MODE_PAUSABLE
	_rng.randomize()
	RenderingServer.set_default_clear_color(Color("090d18"))
	_update_movement_bounds()
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_update_hud()


func _process(delta: float) -> void:
	if not get_tree().paused:
		_reconcile_population()
	_hud_elapsed += delta
	if _hud_elapsed >= HUD_REFRESH_INTERVAL:
		_hud_elapsed = 0.0
		_update_hud()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed or event.echo:
		return
	var typed_character := String.chr(event.unicode) if event.unicode > 0 else ""
	if event.is_action_pressed("ui_up") or typed_character in ["+", "="]:
		target_count = mini(target_count + LOAD_STEP, MAX_TARGET_COUNT)
	elif event.is_action_pressed("ui_down") or typed_character in ["-", "_"]:
		target_count = maxi(target_count - LOAD_STEP, 0)
	elif event.keycode == KEY_R:
		target_count = DEFAULT_TARGET_COUNT
	elif event.keycode == KEY_SPACE:
		get_tree().paused = not get_tree().paused
	else:
		return
	get_viewport().set_input_as_handled()
	_update_hud()


func _reconcile_population() -> void:
	var active_count := _active_shape_count()
	if active_count < target_count:
		var amount_to_spawn := mini(spawn_batch_size, target_count - active_count)
		for _index in amount_to_spawn:
			_spawn_shape()
	elif active_count > target_count:
		var amount_to_retire := mini(spawn_batch_size, active_count - target_count)
		for child in object_container.get_children():
			if amount_to_retire <= 0:
				break
			var shape := child as PerformanceShape
			if shape != null and not shape.is_retiring():
				shape.retire()
				amount_to_retire -= 1


func _active_shape_count() -> int:
	var active_count := 0
	for child in object_container.get_children():
		var shape := child as PerformanceShape
		if shape != null and not shape.is_retiring():
			active_count += 1
	return active_count


func _spawn_shape() -> void:
	var shape := PerformanceShapeScript.new() as PerformanceShape
	object_container.add_child(shape)
	shape.configure(_movement_bounds, _rng, _ordered_range(size_range), _ordered_range(speed_range), _ordered_lifetime_range())


func _ordered_range(value: Vector2) -> Vector2:
	return Vector2(minf(value.x, value.y), maxf(value.x, value.y))


func _ordered_lifetime_range() -> Vector2:
	var ordered := _ordered_range(lifetime_range)
	ordered.x = maxf(ordered.x, 0.2)
	ordered.y = maxf(ordered.y, ordered.x)
	return ordered


func _on_viewport_size_changed() -> void:
	_update_movement_bounds()
	for child in object_container.get_children():
		var shape := child as PerformanceShape
		if shape != null:
			shape.set_movement_bounds(_movement_bounds)


func _update_movement_bounds() -> void:
	_movement_bounds = get_viewport_rect()


func _update_hud() -> void:
	var active_count := object_container.get_child_count()
	stats_label.text = "FPS: %d\nObjects: %s / %s" % [
		Engine.get_frames_per_second(),
		_format_number(active_count),
		_format_number(target_count),
	]
	state_label.text = "PAUSED" if get_tree().paused else "RUNNING"
	state_label.modulate = Color("ffd166") if get_tree().paused else Color("6ee7a8")


func _format_number(value: int) -> String:
	var digits := str(value)
	var formatted := ""
	for index in digits.length():
		if index > 0 and (digits.length() - index) % 3 == 0:
			formatted += ","
		formatted += digits[index]
	return formatted
