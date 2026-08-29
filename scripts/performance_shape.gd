class_name PerformanceShape
extends Node2D

enum ShapeKind {
	CIRCLE,
	SQUARE,
	TRIANGLE,
	DIAMOND,
	HEXAGON,
}

var velocity := Vector2.ZERO
var angular_velocity := 0.0
var radius := 10.0
var shape_kind := ShapeKind.CIRCLE
var fill_color := Color.WHITE
var movement_bounds := Rect2()
var lifetime := 3.0
var age := 0.0
var fade_out_duration := 0.35
var _retiring := false


func configure(
		bounds: Rect2,
		rng: RandomNumberGenerator,
		size_range: Vector2,
		speed_range: Vector2,
		lifetime_range: Vector2
) -> void:
	movement_bounds = bounds
	radius = rng.randf_range(size_range.x, size_range.y)
	shape_kind = rng.randi_range(ShapeKind.CIRCLE, ShapeKind.HEXAGON)
	fill_color = Color.from_hsv(
		rng.randf(),
		rng.randf_range(0.65, 0.95),
		rng.randf_range(0.85, 1.0),
		1.0
	)
	var direction := Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))
	velocity = direction * rng.randf_range(speed_range.x, speed_range.y)
	angular_velocity = rng.randf_range(-2.5, 2.5)
	lifetime = rng.randf_range(lifetime_range.x, lifetime_range.y)
	fade_out_duration = minf(rng.randf_range(0.2, 0.55), lifetime * 0.3)
	position = _random_position(rng)
	rotation = rng.randf_range(0.0, TAU)
	modulate.a = 0.0
	scale = Vector2.ZERO
	queue_redraw()

	var entrance_duration := minf(rng.randf_range(0.18, 0.5), lifetime * 0.25)
	var entrance := create_tween().set_parallel(true)
	entrance.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	entrance.tween_property(self, "scale", Vector2.ONE, entrance_duration)
	entrance.tween_property(self, "modulate:a", 1.0, entrance_duration)


func _process(delta: float) -> void:
	if _retiring:
		return
	age += delta
	position += velocity * delta
	rotation += angular_velocity * delta
	_bounce_inside_bounds()
	if age >= lifetime - fade_out_duration:
		retire()


func _draw() -> void:
	match shape_kind:
		ShapeKind.CIRCLE:
			draw_circle(Vector2.ZERO, radius, fill_color)
		ShapeKind.SQUARE:
			draw_rect(Rect2(Vector2(-radius, -radius), Vector2.ONE * radius * 2.0), fill_color)
		ShapeKind.TRIANGLE:
			draw_colored_polygon(_regular_polygon(3, -PI / 2.0), fill_color)
		ShapeKind.DIAMOND:
			draw_colored_polygon(PackedVector2Array([
				Vector2(0.0, -radius),
				Vector2(radius, 0.0),
				Vector2(0.0, radius),
				Vector2(-radius, 0.0),
			]), fill_color)
		ShapeKind.HEXAGON:
			draw_colored_polygon(_regular_polygon(6), fill_color)


func set_movement_bounds(bounds: Rect2) -> void:
	movement_bounds = bounds
	_bounce_inside_bounds()


func retire() -> void:
	if _retiring:
		return
	_retiring = true
	var exit_tween := create_tween().set_parallel(true)
	exit_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	exit_tween.tween_property(self, "scale", Vector2.ONE * 0.15, fade_out_duration)
	exit_tween.tween_property(self, "modulate:a", 0.0, fade_out_duration)
	exit_tween.chain().tween_callback(queue_free)


func is_retiring() -> bool:
	return _retiring


func _random_position(rng: RandomNumberGenerator) -> Vector2:
	var left := movement_bounds.position.x + radius
	var right := movement_bounds.end.x - radius
	var top := movement_bounds.position.y + radius
	var bottom := movement_bounds.end.y - radius
	return Vector2(
		movement_bounds.get_center().x if right <= left else rng.randf_range(left, right),
		movement_bounds.get_center().y if bottom <= top else rng.randf_range(top, bottom)
	)


func _bounce_inside_bounds() -> void:
	var left := movement_bounds.position.x + radius
	var right := movement_bounds.end.x - radius
	var top := movement_bounds.position.y + radius
	var bottom := movement_bounds.end.y - radius

	if right <= left:
		position.x = movement_bounds.get_center().x
		velocity.x = 0.0
	elif position.x < left:
		position.x = left
		velocity.x = absf(velocity.x)
	elif position.x > right:
		position.x = right
		velocity.x = -absf(velocity.x)

	if bottom <= top:
		position.y = movement_bounds.get_center().y
		velocity.y = 0.0
	elif position.y < top:
		position.y = top
		velocity.y = absf(velocity.y)
	elif position.y > bottom:
		position.y = bottom
		velocity.y = -absf(velocity.y)


func _regular_polygon(point_count: int, angle_offset := 0.0) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in point_count:
		var angle := angle_offset + TAU * float(index) / float(point_count)
		points.append(Vector2.RIGHT.rotated(angle) * radius)
	return points
