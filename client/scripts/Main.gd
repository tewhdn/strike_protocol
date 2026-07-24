extends Node2D

enum Screen { MENU, CONNECTING, LOBBY, MATCH, TRAINING, RESULTS }

const PROTOCOL_VERSION := 1
const DEFAULT_PORT := 8765
const WORLD_DEFAULT := Vector2(1600.0, 900.0)
const PLAYER_SPEED := 260.0
const PLAYER_RADIUS := 18.0
const BULLET_SPEED := 900.0
const MAGAZINE_SIZE := 30
const FIRE_INTERVAL := 0.18
const NETWORK_TICK := 1.0 / 30.0

const C_BACKGROUND := Color("#07111B")
const C_SURFACE := Color("#0D1A27")
const C_SURFACE_2 := Color("#132434")
const C_BORDER := Color("#294054")
const C_GRID := Color("#183044")
const C_TEXT := Color("#F1F7FA")
const C_MUTED := Color("#8298A8")
const C_CYAN := Color("#3FE5D0")
const C_CYAN_DARK := Color("#167B78")
const C_LIME := Color("#B6F36B")
const C_ORANGE := Color("#FF9D4D")
const C_RED := Color("#FF5E68")
const C_BLUE := Color("#55A9FF")

var screen_state := Screen.MENU
var tcp: StrikeTcpClient
var viewport_size := Vector2(1280.0, 720.0)
var rng := RandomNumberGenerator.new()

var name_edit: LineEdit
var host_edit: LineEdit
var port_edit: LineEdit
var room_edit: LineEdit
var menu_fields: Array[LineEdit] = []
var button_rects := {}

var world_size := WORLD_DEFAULT
var camera_position := WORLD_DEFAULT * 0.5
var camera_shake := 0.0
var local_player := {}
var remote_players := {}
var bots: Array = []
var bullets: Array = []
var effects: Array = []
var obstacles: Array[Rect2] = []

var player_name := "Operator"
var local_player_id := "local"
var room_code := "--"
var lobby_players: Array = []
var connection_status := "READY"
var status_detail := "TCP / NDJSON / protocol v1"
var ping_ms := 0
var last_ping_sent := 0

var aim_angle := 0.0
var desktop_mouse_down := false
var fire_cooldown := 0.0
var reload_timer := 0.0
var network_accumulator := 0.0
var input_sequence := 0
var match_time := 600.0
var kills := 0
var deaths := 0
var shots_fired := 0
var shots_hit := 0
var hitmarker_time := 0.0
var death_timer := 0.0

var toast_text := ""
var toast_time := 0.0
var toast_color := C_TEXT

var touch_points := {}
var left_touch_id := -1
var right_touch_id := -1
var left_touch_origin := Vector2.ZERO
var right_touch_origin := Vector2.ZERO
var touch_move := Vector2.ZERO
var touch_aim := Vector2.ZERO

var logo_texture: Texture2D
var player_texture: Texture2D
var enemy_texture: Texture2D
var rifle_texture: Texture2D
var crate_texture: Texture2D
var bullet_texture: Texture2D


func _ready() -> void:
	rng.randomize()
	viewport_size = get_viewport_rect().size
	_build_menu_fields()
	_load_optional_assets()
	_build_arena()
	tcp = StrikeTcpClient.new()
	add_child(tcp)
	tcp.state_changed.connect(_on_tcp_state_changed)
	tcp.message_received.connect(_on_tcp_message)
	tcp.protocol_error.connect(_on_tcp_error)
	get_viewport().size_changed.connect(_on_viewport_resized)
	_reset_local_player()
	queue_redraw()


func _process(delta: float) -> void:
	viewport_size = get_viewport_rect().size
	_layout_menu_fields()
	if toast_time > 0.0:
		toast_time -= delta
	if hitmarker_time > 0.0:
		hitmarker_time -= delta
	if camera_shake > 0.0:
		camera_shake = maxf(0.0, camera_shake - delta * 18.0)

	if _is_gameplay():
		_update_game(delta)
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if _is_gameplay() and not _is_mobile_layout():
			var center := viewport_size * 0.5
			var direction: Vector2 = event.position - center
			if direction.length_squared() > 1.0:
				aim_angle = direction.angle()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_handle_pointer_press(event.position)
		if _is_gameplay():
			desktop_mouse_down = event.pressed

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _is_gameplay() or screen_state == Screen.LOBBY or screen_state == Screen.CONNECTING:
				_return_to_menu()
		elif event.keycode == KEY_R and _is_gameplay():
			_start_reload()
		elif event.keycode == KEY_ENTER and screen_state == Screen.MENU:
			_start_connection()

	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		touch_points[event.index] = event.position


func _handle_pointer_press(position: Vector2) -> void:
	if screen_state == Screen.MENU:
		if _button_contains("connect", position):
			_start_connection()
		elif _button_contains("training", position):
			_start_training()
	elif screen_state == Screen.CONNECTING:
		if _button_contains("cancel", position):
			_return_to_menu()
	elif screen_state == Screen.LOBBY:
		if _button_contains("ready", position):
			_start_online_match()
		elif _button_contains("leave", position):
			_return_to_menu()
	elif screen_state == Screen.RESULTS:
		if _button_contains("again", position):
			_start_training()
		elif _button_contains("menu", position):
			_return_to_menu()
	elif _is_gameplay():
		if _button_contains("leave_match", position):
			_return_to_menu()
		elif _button_contains("reload", position):
			_start_reload()


func _handle_touch(event: InputEventScreenTouch) -> void:
	if not _is_gameplay():
		if event.pressed:
			_handle_pointer_press(event.position)
		return

	if event.pressed:
		if _button_contains("leave_match", event.position):
			_return_to_menu()
			return
		if _button_contains("reload", event.position):
			_start_reload()
			return
		touch_points[event.index] = event.position
		if event.position.x < viewport_size.x * 0.48 and left_touch_id < 0:
			left_touch_id = event.index
			left_touch_origin = event.position
		elif right_touch_id < 0:
			right_touch_id = event.index
			right_touch_origin = event.position
	else:
		touch_points.erase(event.index)
		if event.index == left_touch_id:
			left_touch_id = -1
			touch_move = Vector2.ZERO
		if event.index == right_touch_id:
			right_touch_id = -1
			touch_aim = Vector2.ZERO


func _build_menu_fields() -> void:
	name_edit = _make_line_edit("Callsign", "Operator", 16)
	host_edit = _make_line_edit("Server address", "127.0.0.1", 64)
	port_edit = _make_line_edit("Port", str(DEFAULT_PORT), 5)
	room_edit = _make_line_edit("Room (optional)", "", 8)
	menu_fields = [name_edit, host_edit, port_edit, room_edit]
	for field in menu_fields:
		add_child(field)


func _make_line_edit(placeholder: String, initial_text: String, max_length: int) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.text = initial_text
	edit.max_length = max_length
	edit.clear_button_enabled = false
	edit.add_theme_font_size_override("font_size", 16)
	edit.add_theme_color_override("font_color", C_TEXT)
	edit.add_theme_color_override("font_placeholder_color", C_MUTED)
	edit.add_theme_color_override("caret_color", C_CYAN)
	edit.add_theme_color_override("selection_color", Color(C_CYAN, 0.28))
	edit.add_theme_stylebox_override("normal", _field_style(C_SURFACE_2, C_BORDER))
	edit.add_theme_stylebox_override("focus", _field_style(C_SURFACE_2, C_CYAN_DARK))
	return edit


func _field_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	return style


func _layout_menu_fields() -> void:
	var visible := screen_state == Screen.MENU
	for field in menu_fields:
		field.visible = visible
	if not visible:
		return
	var panel := _menu_panel_rect()
	var gap := 10.0
	var room_width := minf(150.0, panel.size.x * 0.31)
	var name_width := panel.size.x - 60.0 - room_width - gap
	name_edit.position = panel.position + Vector2(30.0, 121.0)
	name_edit.size = Vector2(name_width, 48.0)
	room_edit.position = Vector2(name_edit.position.x + name_width + gap, name_edit.position.y)
	room_edit.size = Vector2(room_width, 48.0)
	var port_width := minf(112.0, panel.size.x * 0.25)
	host_edit.position = panel.position + Vector2(30.0, 205.0)
	host_edit.size = Vector2(panel.size.x - 60.0 - port_width - gap, 48.0)
	port_edit.position = Vector2(host_edit.position.x + host_edit.size.x + gap, host_edit.position.y)
	port_edit.size = Vector2(port_width, 48.0)


func _load_optional_assets() -> void:
	logo_texture = _optional_texture("res://assets/logo.png")
	player_texture = _optional_texture("res://assets/player_blue.png")
	enemy_texture = _optional_texture("res://assets/enemy_red.png")
	rifle_texture = _optional_texture("res://assets/rifle.png")
	crate_texture = _optional_texture("res://assets/crate.png")
	bullet_texture = _optional_texture("res://assets/bullet.png")


func _optional_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	var svg_path := path.get_basename() + ".svg"
	if ResourceLoader.exists(svg_path):
		return load(svg_path) as Texture2D
	return null


func _build_arena() -> void:
	var width := world_size.x
	var height := world_size.y
	obstacles = [
		Rect2(width * 0.16, height * 0.18, width * 0.13, 58.0),
		Rect2(width * 0.39, height * 0.10, 66.0, height * 0.25),
		Rect2(width * 0.67, height * 0.17, width * 0.15, 60.0),
		Rect2(width * 0.84, height * 0.39, 68.0, height * 0.25),
		Rect2(width * 0.45, height * 0.43, width * 0.13, height * 0.14),
		Rect2(width * 0.18, height * 0.62, 72.0, height * 0.24),
		Rect2(width * 0.37, height * 0.76, width * 0.17, 58.0),
		Rect2(width * 0.67, height * 0.70, width * 0.14, 58.0),
	]


func _reset_local_player() -> void:
	local_player = {
		"id": local_player_id,
		"name": player_name,
		"pos": world_size * 0.5 + Vector2(-260.0, 0.0),
		"velocity": Vector2.ZERO,
		"hp": 100.0,
		"max_hp": 100.0,
		"ammo": MAGAZINE_SIZE,
		"reserve": 120,
		"team": 0,
	}
	camera_position = local_player["pos"]


func _start_connection() -> void:
	player_name = name_edit.text.strip_edges().left(16)
	if player_name.is_empty():
		player_name = "Operator"
	name_edit.text = player_name
	var host := host_edit.text.strip_edges()
	if host.is_empty():
		host = "127.0.0.1"
		host_edit.text = host
	var port := clampi(port_edit.text.to_int(), 1, 65535)
	if port_edit.text.to_int() <= 0:
		port = DEFAULT_PORT
	port_edit.text = str(port)
	screen_state = Screen.CONNECTING
	connection_status = "CONNECTING"
	status_detail = "%s:%d" % [host, port]
	if tcp.connect_to_server(host, port) != OK:
		screen_state = Screen.MENU
		_show_toast("Could not start connection", C_RED)


func _start_training() -> void:
	tcp.close()
	screen_state = Screen.TRAINING
	player_name = name_edit.text.strip_edges().left(16)
	if player_name.is_empty():
		player_name = "Operator"
	local_player_id = "local"
	world_size = WORLD_DEFAULT
	_build_arena()
	_reset_match()
	_spawn_training_bots(7)
	connection_status = "TRAINING"
	status_detail = "Local simulation"
	_show_toast("Training range active", C_LIME)


func _reset_match() -> void:
	_reset_local_player()
	remote_players.clear()
	bullets.clear()
	effects.clear()
	kills = 0
	deaths = 0
	shots_fired = 0
	shots_hit = 0
	match_time = 600.0
	reload_timer = 0.0
	fire_cooldown = 0.0
	death_timer = 0.0


func _spawn_training_bots(count: int) -> void:
	bots.clear()
	for index in range(count):
		var bot_pos := _safe_spawn_point(index)
		bots.append({
			"id": "bot_%d" % index,
			"name": ["VECTOR", "RAVEN", "KILO", "NOVA", "ECHO", "ROOK", "EMBER"][index % 7],
			"pos": bot_pos,
			"velocity": Vector2.ZERO,
			"hp": 100.0,
			"max_hp": 100.0,
			"angle": 0.0,
			"team": 1,
			"cooldown": rng.randf_range(0.3, 1.4),
			"strafe": -1.0 if index % 2 == 0 else 1.0,
			"dead": 0.0,
		})


func _safe_spawn_point(index: int) -> Vector2:
	var points := [
		Vector2(world_size.x * 0.14, world_size.y * 0.16),
		Vector2(world_size.x * 0.84, world_size.y * 0.15),
		Vector2(world_size.x * 0.86, world_size.y * 0.82),
		Vector2(world_size.x * 0.14, world_size.y * 0.81),
		Vector2(world_size.x * 0.50, world_size.y * 0.13),
		Vector2(world_size.x * 0.50, world_size.y * 0.84),
		Vector2(world_size.x * 0.75, world_size.y * 0.52),
		Vector2(world_size.x * 0.25, world_size.y * 0.51),
	]
	return points[index % points.size()]


func _return_to_menu() -> void:
	desktop_mouse_down = false
	touch_points.clear()
	left_touch_id = -1
	right_touch_id = -1
	if tcp != null and tcp.is_connected_to_server():
		tcp.send_packet({"type": "leave"})
	if tcp != null:
		tcp.close()
	screen_state = Screen.MENU
	connection_status = "READY"
	status_detail = "TCP / NDJSON / protocol v1"


func _is_gameplay() -> bool:
	return screen_state == Screen.MATCH or screen_state == Screen.TRAINING


func _is_mobile_layout() -> bool:
	return DisplayServer.is_touchscreen_available() or viewport_size.x < 820.0


func _button_contains(name: String, point: Vector2) -> bool:
	return button_rects.has(name) and button_rects[name].has_point(point)


func _update_game(delta: float) -> void:
	if death_timer > 0.0:
		death_timer -= delta
		if death_timer <= 0.0:
			local_player["hp"] = 100.0
			local_player["pos"] = world_size * 0.5 + Vector2(-260.0, 0.0)
			local_player["ammo"] = MAGAZINE_SIZE
			local_player["reserve"] = 120
			reload_timer = 0.0
			camera_position = local_player["pos"]

	var move_input := _get_move_input()
	if death_timer <= 0.0:
		var velocity := move_input * PLAYER_SPEED
		local_player["velocity"] = velocity
		if screen_state == Screen.TRAINING:
			local_player["pos"] = _move_with_obstacles(local_player["pos"], velocity * delta, PLAYER_RADIUS)
		else:
			var online_position: Vector2 = local_player.get("pos", Vector2.ZERO) + velocity * delta
			online_position.x = clampf(online_position.x, PLAYER_RADIUS, world_size.x - PLAYER_RADIUS)
			online_position.y = clampf(online_position.y, PLAYER_RADIUS, world_size.y - PLAYER_RADIUS)
			local_player["pos"] = online_position
		var desired_aim := _get_aim_angle()
		if is_finite(desired_aim):
			aim_angle = desired_aim

		fire_cooldown = maxf(0.0, fire_cooldown - delta)
		if reload_timer > 0.0:
			reload_timer -= delta
			if reload_timer <= 0.0:
				var needed := MAGAZINE_SIZE - int(local_player.get("ammo", 0))
				var reserve: int = int(local_player.get("reserve", 0))
				var loaded := mini(needed, reserve)
				local_player["ammo"] = int(local_player.get("ammo", 0)) + loaded
				local_player["reserve"] = reserve - loaded
				_show_toast("Magazine ready", C_CYAN)
		else:
			var wants_fire := desktop_mouse_down or touch_aim.length_squared() > 180.0
			if wants_fire:
				_fire_local_weapon()

	if screen_state == Screen.TRAINING:
		_update_bots(delta)
		match_time = maxf(0.0, match_time - delta)
		if match_time <= 0.0:
			screen_state = Screen.RESULTS
			_show_toast("Training cycle complete", C_LIME)

	_update_bullets(delta)
	_update_effects(delta)
	var target_camera := local_player.get("pos", world_size * 0.5) as Vector2
	camera_position = camera_position.lerp(target_camera, minf(1.0, delta * 8.0))
	if viewport_size.x >= world_size.x:
		camera_position.x = world_size.x * 0.5
	else:
		camera_position.x = clampf(camera_position.x, viewport_size.x * 0.5, world_size.x - viewport_size.x * 0.5)
	if viewport_size.y >= world_size.y:
		camera_position.y = world_size.y * 0.5
	else:
		camera_position.y = clampf(camera_position.y, viewport_size.y * 0.5, world_size.y - viewport_size.y * 0.5)
	network_accumulator += delta
	if screen_state == Screen.MATCH and network_accumulator >= NETWORK_TICK:
		network_accumulator = 0.0
		_send_input_packet(move_input)


func _get_move_input() -> Vector2:
	var input_vector := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input_vector.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_vector.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input_vector.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_vector.y += 1.0
	if touch_move.length_squared() > 0.01:
		input_vector = touch_move
	if input_vector.length_squared() > 1.0:
		input_vector = input_vector.normalized()
	return input_vector


func _get_aim_angle() -> float:
	if touch_aim.length_squared() > 20.0:
		return touch_aim.angle()
	if not _is_mobile_layout():
		return (get_viewport().get_mouse_position() - viewport_size * 0.5).angle()
	return aim_angle


func _fire_local_weapon() -> void:
	if fire_cooldown > 0.0 or reload_timer > 0.0:
		return
	var ammo: int = int(local_player.get("ammo", 0))
	if ammo <= 0:
		_start_reload()
		return
	local_player["ammo"] = ammo - 1
	fire_cooldown = FIRE_INTERVAL
	shots_fired += 1
	var origin: Vector2 = local_player["pos"] + Vector2.from_angle(aim_angle) * 27.0
	bullets.append({
		"pos": origin,
		"previous": origin,
		"vel": Vector2.from_angle(aim_angle) * BULLET_SPEED,
		"life": 0.9,
		"team": 0,
		"damage": 28.0,
		"color": C_CYAN,
	})
	effects.append({"type": "muzzle", "pos": origin, "angle": aim_angle, "life": 0.08, "max": 0.08})
	camera_shake = minf(1.0, camera_shake + 0.2)
	if screen_state == Screen.MATCH and tcp.is_connected_to_server():
		tcp.send_packet({"type": "shoot", "angle": aim_angle, "pressed": true})


func _start_reload() -> void:
	if reload_timer > 0.0:
		return
	var ammo: int = int(local_player.get("ammo", 0))
	var reserve: int = int(local_player.get("reserve", 0))
	if ammo >= MAGAZINE_SIZE or reserve <= 0:
		return
	reload_timer = 1.35
	_show_toast("Reloading", C_ORANGE)


func _update_bots(delta: float) -> void:
	var player_pos: Vector2 = local_player.get("pos", world_size * 0.5)
	for index in range(bots.size()):
		var bot: Dictionary = bots[index]
		var dead: float = float(bot.get("dead", 0.0))
		if dead > 0.0:
			dead -= delta
			bot["dead"] = dead
			if dead <= 0.0:
				bot["hp"] = bot.get("max_hp", 100.0)
				bot["pos"] = _safe_spawn_point(index + 1)
			bots[index] = bot
			continue

		var bot_pos: Vector2 = bot.get("pos", Vector2.ZERO)
		var to_player := player_pos - bot_pos
		var distance := to_player.length()
		var direction := to_player.normalized() if distance > 1.0 else Vector2.ZERO
		var strafe := Vector2(-direction.y, direction.x) * float(bot.get("strafe", 1.0))
		var movement := Vector2.ZERO
		if distance > 420.0:
			movement = direction
		elif distance < 210.0:
			movement = -direction + strafe * 0.6
		else:
			movement = strafe * 0.65
		if movement.length_squared() > 1.0:
			movement = movement.normalized()
		bot["velocity"] = movement * (150.0 + index % 3 * 18.0)
		bot_pos = _move_with_obstacles(bot_pos, bot["velocity"] * delta, PLAYER_RADIUS)
		bot["pos"] = bot_pos
		bot["angle"] = to_player.angle()
		var cooldown: float = float(bot.get("cooldown", 0.8)) - delta
		if cooldown <= 0.0 and distance < 980.0 and _has_line_of_sight(bot_pos, player_pos):
			var origin := bot_pos + direction * 25.0
			bullets.append({
				"pos": origin,
				"previous": origin,
				"vel": direction * (BULLET_SPEED * 0.72),
				"life": 1.1,
				"team": 1,
				"damage": 11.0 + index % 3 * 2.0,
				"color": C_RED,
			})
			effects.append({"type": "muzzle", "pos": origin, "angle": direction.angle(), "life": 0.06, "max": 0.06})
			cooldown = rng.randf_range(0.65, 1.35)
		bot["cooldown"] = cooldown
		bots[index] = bot


func _update_bullets(delta: float) -> void:
	for index in range(bullets.size() - 1, -1, -1):
		var bullet: Dictionary = bullets[index]
		var previous: Vector2 = bullet.get("pos", Vector2.ZERO)
		var position: Vector2 = previous + bullet.get("vel", Vector2.ZERO) * delta
		bullet["previous"] = previous
		bullet["pos"] = position
		bullet["life"] = float(bullet.get("life", 0.0)) - delta
		var remove: bool = bullet["life"] <= 0.0 or not Rect2(Vector2.ZERO, world_size).has_point(position)
		if not remove:
			for obstacle in obstacles:
				if obstacle.grow(3.0).has_point(position):
					effects.append({"type": "impact", "pos": position, "life": 0.22, "max": 0.22})
					remove = true
					break
		if not remove and int(bullet.get("team", 0)) == 0:
			for bot_index in range(bots.size()):
				var bot: Dictionary = bots[bot_index]
				if float(bot.get("dead", 0.0)) > 0.0:
					continue
				if position.distance_to(bot.get("pos", Vector2.ZERO)) <= PLAYER_RADIUS + 3.0:
					bot["hp"] = float(bot.get("hp", 100.0)) - float(bullet.get("damage", 28.0))
					bots[bot_index] = bot
					shots_hit += 1
					hitmarker_time = 0.12
					effects.append({"type": "impact", "pos": position, "life": 0.22, "max": 0.22, "enemy": true})
					if float(bot.get("hp", 0.0)) <= 0.0:
						bot["dead"] = 2.0
						bot["hp"] = 0.0
						bots[bot_index] = bot
						kills += 1
						_show_toast("Target down  +%d" % kills, C_LIME)
					remove = true
					break
		elif not remove and int(bullet.get("team", 0)) == 1 and death_timer <= 0.0:
			if position.distance_to(local_player.get("pos", Vector2.ZERO)) <= PLAYER_RADIUS + 3.0:
				local_player["hp"] = float(local_player.get("hp", 100.0)) - float(bullet.get("damage", 11.0))
				effects.append({"type": "impact", "pos": position, "life": 0.22, "max": 0.22, "enemy": false})
				camera_shake = minf(1.0, camera_shake + 0.35)
				if float(local_player.get("hp", 0.0)) <= 0.0:
					local_player["hp"] = 0.0
					death_timer = 2.0
					deaths += 1
					_show_toast("Operator down", C_RED)
				remove = true
		if remove:
			bullets.remove_at(index)
		else:
			bullets[index] = bullet


func _update_effects(delta: float) -> void:
	for index in range(effects.size() - 1, -1, -1):
		var effect: Dictionary = effects[index]
		effect["life"] = float(effect.get("life", 0.0)) - delta
		if effect["life"] <= 0.0:
			effects.remove_at(index)
		else:
			effects[index] = effect


func _move_with_obstacles(position: Vector2, motion: Vector2, radius: float) -> Vector2:
	var candidate := position + motion
	candidate.x = clampf(candidate.x, radius, world_size.x - radius)
	candidate.y = clampf(candidate.y, radius, world_size.y - radius)
	for obstacle in obstacles:
		if obstacle.grow(radius).has_point(candidate):
			var x_candidate := Vector2(candidate.x, position.y)
			var y_candidate := Vector2(position.x, candidate.y)
			if not obstacle.grow(radius).has_point(x_candidate):
				candidate = x_candidate
			elif not obstacle.grow(radius).has_point(y_candidate):
				candidate = y_candidate
			else:
				candidate = position
	return candidate


func _has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	var distance := from.distance_to(to)
	var steps := maxi(1, int(distance / 28.0))
	for index in range(1, steps):
		var point := from.lerp(to, float(index) / float(steps))
		for obstacle in obstacles:
			if obstacle.grow(3.0).has_point(point):
				return false
	return true


func _send_input_packet(move_input: Vector2) -> void:
	if tcp == null or not tcp.is_connected_to_server():
		return
	input_sequence += 1
	var aim_direction := Vector2.from_angle(aim_angle)
	tcp.send_packet({
		"type": "input",
		"seq": input_sequence,
		"move": {"x": move_input.x, "y": move_input.y},
		"aim": {"x": aim_direction.x, "y": aim_direction.y},
		"angle": aim_angle,
		"shoot": desktop_mouse_down or touch_aim.length_squared() > 180.0,
	})


func _on_tcp_state_changed(state: String) -> void:
	match state:
		"connecting":
			connection_status = "CONNECTING"
		"connected":
			connection_status = "HANDSHAKE"
			status_detail = "Negotiating protocol v%d" % PROTOCOL_VERSION
			tcp.send_packet({
				"type": "hello",
				"version": PROTOCOL_VERSION,
				"name": player_name,
			})
		"error":
			connection_status = "CONNECTION ERROR"
		"offline":
			if screen_state == Screen.MATCH or screen_state == Screen.LOBBY:
				screen_state = Screen.MENU
				_show_toast("Server disconnected", C_RED)


func _on_tcp_error(message: String) -> void:
	connection_status = "CONNECTION ERROR"
	status_detail = message
	_show_toast(message, C_RED)
	if screen_state == Screen.CONNECTING:
		screen_state = Screen.MENU


func _on_tcp_message(message: Dictionary) -> void:
	var kind := str(message.get("type", message.get("t", message.get("event", "")))).to_lower()
	match kind:
		"hello_ok", "welcome", "connected":
			local_player_id = str(_first_value(message, ["player_id", "id", "client_id"], local_player_id))
			connection_status = "AUTHENTICATED"
			var join_packet := {"type": "join"}
			var requested_room := room_edit.text.strip_edges().to_upper()
			if not requested_room.is_empty():
				join_packet["room"] = requested_room
			else:
				join_packet["create"] = true
			tcp.send_packet(join_packet)
		"joined", "room_joined":
			local_player_id = str(_first_value(message, ["player_id", "id", "client_id"], local_player_id))
			room_code = str(_first_value(message, ["room", "room_code", "code"], "OPEN")).to_upper()
			_apply_world_settings(message.get("world", {}))
			lobby_players = _normalise_player_list(_first_value(message, ["players", "members"], []))
			if lobby_players.is_empty():
				lobby_players = [{"id": local_player_id, "name": player_name, "ready": false}]
			screen_state = Screen.LOBBY
			connection_status = "IN LOBBY"
			status_detail = "Room %s" % room_code
			_show_toast("Joined room %s" % room_code, C_CYAN)
			if message.get("snapshot") is Dictionary:
				_apply_snapshot(message["snapshot"])
		"lobby", "room_state":
			room_code = str(_first_value(message, ["room", "room_code", "code"], room_code)).to_upper()
			lobby_players = _normalise_player_list(_first_value(message, ["players", "members"], lobby_players))
		"match_start", "start":
			_apply_world_settings(message.get("world", {}))
			_start_online_match()
		"snapshot", "state", "game_state":
			if screen_state == Screen.LOBBY or screen_state == Screen.CONNECTING:
				_start_online_match()
			_apply_snapshot(message)
		"player_joined":
			var joined_player = _first_value(message, ["player", "member"], message)
			if joined_player is Dictionary:
				lobby_players.append(joined_player)
		"player_left":
			var leaving_id := str(_first_value(message, ["player_id", "id"], ""))
			_remove_lobby_player(leaving_id)
			remote_players.erase(leaving_id)
		"pong":
			var sent := int(_first_value(message, ["ts", "client_ts"], last_ping_sent))
			if sent > 0:
				ping_ms = maxi(0, Time.get_ticks_msec() - sent)
		"error":
			var reason := str(_first_value(message, ["message", "error", "reason"], "Server rejected request"))
			_show_toast(reason, C_RED)
			status_detail = reason
		"killed", "death", "elimination", "eliminated":
			_apply_elimination(message)
		"hit":
			var attacker := str(_first_value(message, ["attacker_id", "attacker", "source"], ""))
			if attacker == local_player_id:
				hitmarker_time = 0.14
				shots_hit += 1
		"respawned":
			var respawned = message.get("player")
			if respawned is Dictionary and str(_first_value(respawned, ["id", "player_id"], "")) == local_player_id:
				local_player["pos"] = _position_from(respawned, local_player.get("pos", world_size * 0.5))
				local_player["hp"] = float(_first_value(respawned, ["hp", "health"], 100.0))
				death_timer = 0.0
		_:
			pass


func _start_online_match() -> void:
	screen_state = Screen.MATCH
	bots.clear()
	bullets.clear()
	effects.clear()
	kills = 0
	deaths = 0
	shots_fired = 0
	shots_hit = 0
	match_time = 600.0
	local_player["id"] = local_player_id
	local_player["name"] = player_name
	connection_status = "LIVE"
	status_detail = "Room %s" % room_code
	_show_toast("Match live", C_LIME)


func _apply_snapshot(message: Dictionary) -> void:
	var server_time = _first_value(message, ["time_left", "remaining", "match_time"], null)
	if server_time != null:
		match_time = maxf(0.0, float(server_time))
	elif message.has("time"):
		match_time = maxf(0.0, 600.0 - float(message["time"]))
	_apply_world_settings(message.get("world", {}))
	var players_value = _first_value(message, ["players", "entities", "clients"], [])
	var flattened := _normalise_player_list(players_value)
	var seen := {}
	for raw in flattened:
		if not (raw is Dictionary):
			continue
		var id := str(_first_value(raw, ["id", "player_id", "client_id"], ""))
		if id.is_empty():
			continue
		seen[id] = true
		var player_position := _position_from(raw, Vector2.ZERO)
		var health := float(_first_value(raw, ["hp", "health"], 100.0))
		var player_angle := float(_first_value(raw, ["angle", "rotation", "aim_angle"], 0.0))
		if id == local_player_id:
			if player_position != Vector2.ZERO:
				local_player["pos"] = (local_player.get("pos", player_position) as Vector2).lerp(player_position, 0.32)
			local_player["hp"] = health
			local_player["max_hp"] = float(_first_value(raw, ["max_hp", "max_health"], 100.0))
			if raw.has("alive") and not bool(raw["alive"]):
				death_timer = maxf(death_timer, float(_first_value(raw, ["respawn_in", "respawn"], 1.0)))
			elif bool(raw.get("alive", true)) and death_timer > 0.0 and health > 0.0:
				death_timer = 0.0
			if raw.has("ammo"):
				local_player["ammo"] = int(raw["ammo"])
			if raw.has("reserve"):
				local_player["reserve"] = int(raw["reserve"])
		else:
			var existing: Dictionary = remote_players.get(id, {})
			existing["id"] = id
			existing["name"] = str(_first_value(raw, ["name", "callsign"], "OPERATOR"))
			existing["pos"] = player_position
			existing["hp"] = health
			existing["max_hp"] = float(_first_value(raw, ["max_hp", "max_health"], 100.0))
			existing["angle"] = player_angle
			existing["team"] = int(_first_value(raw, ["team", "team_id"], 1))
			existing["score"] = int(_first_value(raw, ["score", "kills"], 0))
			remote_players[id] = existing
	var existing_ids := remote_players.keys()
	for existing_id in existing_ids:
		if not seen.has(existing_id):
			remote_players.erase(existing_id)

	var projectiles = _first_value(message, ["bullets", "projectiles", "shots"], null)
	if projectiles is Array:
		for bullet_index in range(bullets.size() - 1, -1, -1):
			if bool(bullets[bullet_index].get("server", false)):
				bullets.remove_at(bullet_index)
		for raw_bullet in projectiles:
			if not (raw_bullet is Dictionary):
				continue
			var bullet_position := _position_from(raw_bullet, Vector2.ZERO)
			var direction := _direction_from(raw_bullet)
			var owner_id := str(_first_value(raw_bullet, ["owner_id", "owner", "player_id"], ""))
			if owner_id == local_player_id:
				continue
			var bullet_team := 0 if owner_id == local_player_id else 1
			bullets.append({
				"pos": bullet_position,
				"previous": bullet_position - direction * 16.0,
				"vel": direction * BULLET_SPEED,
				"life": 0.12,
				"team": int(_first_value(raw_bullet, ["team", "team_id"], bullet_team)),
				"damage": 0.0,
				"color": C_CYAN if bullet_team == 0 else C_ORANGE,
				"server": true,
			})


func _apply_world_settings(value) -> void:
	if not (value is Dictionary):
		return
	var width := float(_first_value(value, ["width", "w", "x"], world_size.x))
	var height := float(_first_value(value, ["height", "h", "y"], world_size.y))
	if width >= 640.0 and height >= 480.0:
		world_size = Vector2(width, height)
		_build_arena()
	if value.get("obstacles") is Array:
		var server_obstacles: Array[Rect2] = []
		for raw in value["obstacles"]:
			if raw is Dictionary:
				var size := Vector2(float(raw.get("width", raw.get("w", 0.0))), float(raw.get("height", raw.get("h", 0.0))))
				if size.x > 0.0 and size.y > 0.0:
					server_obstacles.append(Rect2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)), size.x, size.y))
			elif raw is Array and raw.size() >= 4:
				server_obstacles.append(Rect2(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3])))
		if not server_obstacles.is_empty():
			obstacles = server_obstacles


func _apply_elimination(message: Dictionary) -> void:
	var killer := str(_first_value(message, ["killer_id", "attacker_id", "attacker", "source"], ""))
	var victim := str(_first_value(message, ["victim_id", "target", "player_id"], ""))
	if killer == local_player_id:
		kills += 1
		_show_toast("Elimination confirmed", C_LIME)
	if victim == local_player_id:
		deaths += 1
		death_timer = float(_first_value(message, ["respawn_in", "respawn"], 2.0))
		_show_toast("Awaiting respawn", C_RED)


func _first_value(source: Dictionary, keys: Array, fallback):
	for key in keys:
		if source.has(key):
			return source[key]
	return fallback


func _normalise_player_list(value) -> Array:
	var result: Array = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				result.append(item)
	elif value is Dictionary:
		for key in value.keys():
			var item = value[key]
			if item is Dictionary:
				var copy: Dictionary = item.duplicate(true)
				if not copy.has("id"):
					copy["id"] = str(key)
				result.append(copy)
	return result


func _position_from(source: Dictionary, fallback: Vector2) -> Vector2:
	if source.has("pos"):
		var pos_value = source["pos"]
		if pos_value is Dictionary:
			return Vector2(float(pos_value.get("x", fallback.x)), float(pos_value.get("y", fallback.y)))
		if pos_value is Array and pos_value.size() >= 2:
			return Vector2(float(pos_value[0]), float(pos_value[1]))
	if source.has("position"):
		var position_value = source["position"]
		if position_value is Dictionary:
			return Vector2(float(position_value.get("x", fallback.x)), float(position_value.get("y", fallback.y)))
		if position_value is Array and position_value.size() >= 2:
			return Vector2(float(position_value[0]), float(position_value[1]))
	if source.has("x") and source.has("y"):
		return Vector2(float(source["x"]), float(source["y"]))
	return fallback


func _direction_from(source: Dictionary) -> Vector2:
	if source.has("vx") or source.has("vy"):
		var velocity := Vector2(float(source.get("vx", 0.0)), float(source.get("vy", 0.0)))
		return velocity.normalized() if velocity.length_squared() > 0.01 else Vector2.RIGHT
	for key in ["direction", "dir", "velocity", "vel"]:
		if source.has(key):
			var value = source[key]
			if value is Dictionary:
				var dictionary_vector := Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
				return dictionary_vector.normalized() if dictionary_vector.length_squared() > 0.01 else Vector2.RIGHT
			if value is Array and value.size() >= 2:
				var array_vector := Vector2(float(value[0]), float(value[1]))
				return array_vector.normalized() if array_vector.length_squared() > 0.01 else Vector2.RIGHT
	var angle := float(_first_value(source, ["angle", "rotation"], 0.0))
	return Vector2.from_angle(angle)


func _remove_lobby_player(id: String) -> void:
	for index in range(lobby_players.size() - 1, -1, -1):
		if str(_first_value(lobby_players[index], ["id", "player_id"], "")) == id:
			lobby_players.remove_at(index)


func _show_toast(message: String, color: Color = C_TEXT) -> void:
	toast_text = message
	toast_color = color
	toast_time = 2.6


func _on_viewport_resized() -> void:
	viewport_size = get_viewport_rect().size
	queue_redraw()


func _draw() -> void:
	button_rects.clear()
	draw_rect(Rect2(Vector2.ZERO, viewport_size), C_BACKGROUND)
	match screen_state:
		Screen.MENU:
			_draw_menu()
		Screen.CONNECTING:
			_draw_connection_screen()
		Screen.LOBBY:
			_draw_lobby()
		Screen.MATCH, Screen.TRAINING:
			_draw_game()
		Screen.RESULTS:
			_draw_results()
	if toast_time > 0.0 and not toast_text.is_empty():
		_draw_toast()


func _draw_menu() -> void:
	_draw_menu_backdrop()
	if logo_texture != null:
		var logo_width := 216.0 if viewport_size.x >= 700.0 else 168.0
		draw_texture_rect(logo_texture, Rect2(24.0, 18.0, logo_width, logo_width / 3.0), false)
	else:
		var title_size := 38 if viewport_size.x >= 700.0 else 27
		_draw_text("STRIKE PROTOCOL", Vector2(24.0, 64.0), title_size, C_TEXT)
		_draw_text("CROSS-PLATFORM TACTICAL ARENA", Vector2(26.0, 84.0), 11, C_CYAN)

	var panel := _menu_panel_rect()
	_draw_panel(panel, C_SURFACE, C_BORDER, 8)
	_draw_text("DEPLOYMENT", panel.position + Vector2(30.0, 40.0), 22, C_TEXT)
	_draw_text("ARENA ACCESS", panel.position + Vector2(30.0, 66.0), 11, C_CYAN)
	_draw_status_chip(Rect2(panel.end.x - 154.0, panel.position.y + 27.0, 124.0, 28.0), "PROTOCOL V1", C_CYAN)

	_draw_text("CALLSIGN", panel.position + Vector2(30.0, 111.0), 10, C_MUTED)
	var room_label_x := room_edit.position.x - panel.position.x
	_draw_text("ROOM", panel.position + Vector2(room_label_x, 111.0), 10, C_MUTED)
	_draw_text("SERVER", panel.position + Vector2(30.0, 195.0), 10, C_MUTED)
	var port_label_x := port_edit.position.x - panel.position.x
	_draw_text("PORT", panel.position + Vector2(port_label_x, 195.0), 10, C_MUTED)

	var connect_rect := Rect2(panel.position + Vector2(30.0, 278.0), Vector2(panel.size.x - 60.0, 58.0))
	var training_rect := Rect2(panel.position + Vector2(30.0, 347.0), Vector2(panel.size.x - 60.0, 58.0))
	button_rects["connect"] = connect_rect
	button_rects["training"] = training_rect
	_draw_button(connect_rect, "CONNECT TO SERVER", C_CYAN, true, "TCP")
	_draw_button(training_rect, "OFFLINE TRAINING", C_SURFACE_2, false, "BOT")

	draw_line(panel.position + Vector2(30.0, 428.0), panel.position + Vector2(panel.size.x - 30.0, 428.0), C_BORDER, 1.0)
	_draw_small_icon("shield", panel.position + Vector2(36.0, 456.0), C_LIME)
	_draw_text("CHANNEL READY", panel.position + Vector2(57.0, 461.0), 12, C_MUTED)
	_draw_small_icon("bolt", panel.position + Vector2(panel.size.x * 0.63, 456.0), C_ORANGE)
	_draw_text("TCP", panel.position + Vector2(panel.size.x * 0.63 + 22.0, 461.0), 12, C_MUTED)

	var footer_y := viewport_size.y - 24.0
	_draw_text("BUILD 0.1  /  PROTOCOL V1", Vector2(24.0, footer_y), 10, C_MUTED)
	var status_width := ThemeDB.fallback_font.get_string_size(connection_status, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_circle(Vector2(viewport_size.x - status_width - 37.0, footer_y - 4.0), 4.0, C_LIME)
	_draw_text(connection_status, Vector2(viewport_size.x - status_width - 26.0, footer_y), 11, C_TEXT)


func _draw_menu_backdrop() -> void:
	var spacing := 56.0
	var offset := fmod(float(Time.get_ticks_msec()) * 0.006, spacing)
	var grid_color := Color(C_GRID, 0.52)
	var x := -spacing + offset
	while x < viewport_size.x + spacing:
		draw_line(Vector2(x, 0.0), Vector2(x, viewport_size.y), grid_color, 1.0)
		x += spacing
	var y := -spacing + offset
	while y < viewport_size.y + spacing:
		draw_line(Vector2(0.0, y), Vector2(viewport_size.x, y), grid_color, 1.0)
		y += spacing
	var target_center := Vector2(viewport_size.x * 0.15, viewport_size.y * 0.48)
	for radius in [64.0, 112.0, 166.0]:
		draw_arc(target_center, radius, -1.0, 1.2, 48, Color(C_CYAN, 0.08), 2.0)
	var target_center_right := Vector2(viewport_size.x * 0.87, viewport_size.y * 0.67)
	for radius in [52.0, 95.0, 145.0]:
		draw_arc(target_center_right, radius, 2.1, 4.2, 48, Color(C_ORANGE, 0.06), 2.0)


func _draw_connection_screen() -> void:
	_draw_menu_backdrop()
	var center := viewport_size * 0.5
	var panel := Rect2(center - Vector2(240.0, 164.0), Vector2(480.0, 328.0))
	if viewport_size.x < 540.0:
		panel = Rect2(20.0, center.y - 164.0, viewport_size.x - 40.0, 328.0)
	_draw_panel(panel, C_SURFACE, C_BORDER, 8)
	var phase := float(Time.get_ticks_msec() % 1800) / 1800.0
	for ring in range(3):
		var ring_phase := fmod(phase + float(ring) * 0.22, 1.0)
		draw_arc(Vector2(center.x, panel.position.y + 92.0), 29.0 + ring * 8.0, ring_phase * TAU, ring_phase * TAU + 2.0, 28, Color(C_CYAN, 0.9 - ring * 0.22), 3.0)
	_draw_text_center(connection_status, Rect2(panel.position.x, panel.position.y + 134.0, panel.size.x, 42.0), 23, C_TEXT)
	_draw_text_center(status_detail, Rect2(panel.position.x + 16.0, panel.position.y + 176.0, panel.size.x - 32.0, 30.0), 13, C_MUTED)
	var cancel_rect := Rect2(panel.position + Vector2(35.0, 241.0), Vector2(panel.size.x - 70.0, 50.0))
	button_rects["cancel"] = cancel_rect
	_draw_button(cancel_rect, "CANCEL", C_SURFACE_2, false, "X")


func _draw_lobby() -> void:
	_draw_menu_backdrop()
	_draw_top_brand()
	var panel_width := minf(680.0, viewport_size.x - 32.0)
	var panel_height := minf(520.0, viewport_size.y - 128.0)
	var panel := Rect2((viewport_size.x - panel_width) * 0.5, 92.0, panel_width, panel_height)
	_draw_panel(panel, C_SURFACE, C_BORDER, 8)
	_draw_text("ROOM", panel.position + Vector2(28.0, 38.0), 11, C_MUTED)
	_draw_text(room_code, panel.position + Vector2(28.0, 79.0), 33, C_CYAN)
	_draw_status_chip(Rect2(panel.end.x - 155.0, panel.position.y + 27.0, 127.0, 29.0), "TCP CONNECTED", C_LIME)
	draw_line(panel.position + Vector2(28.0, 101.0), panel.position + Vector2(panel.size.x - 28.0, 101.0), C_BORDER, 1.0)
	_draw_text("SQUAD", panel.position + Vector2(28.0, 130.0), 12, C_MUTED)

	var row_y := panel.position.y + 150.0
	var max_rows := mini(6, lobby_players.size())
	for index in range(max_rows):
		var row := Rect2(panel.position.x + 28.0, row_y + index * 48.0, panel.size.x - 56.0, 40.0)
		draw_rect(row, C_SURFACE_2)
		var player: Dictionary = lobby_players[index]
		var id := str(_first_value(player, ["id", "player_id"], ""))
		var display_name := str(_first_value(player, ["name", "callsign"], "OPERATOR"))
		draw_circle(row.position + Vector2(21.0, 20.0), 5.0, C_CYAN if id == local_player_id else C_BLUE)
		_draw_text(display_name, row.position + Vector2(37.0, 26.0), 14, C_TEXT)
		var ready := bool(player.get("ready", false))
		_draw_text("READY" if ready else "WAITING", row.position + Vector2(row.size.x - 83.0, 26.0), 10, C_LIME if ready else C_MUTED)
	if lobby_players.is_empty():
		_draw_text_center("Waiting for operators", Rect2(panel.position.x, row_y + 30.0, panel.size.x, 44.0), 15, C_MUTED)

	var ready_rect := Rect2(panel.position.x + 28.0, panel.end.y - 72.0, panel.size.x * 0.62 - 34.0, 48.0)
	var leave_rect := Rect2(ready_rect.end.x + 10.0, panel.end.y - 72.0, panel.end.x - ready_rect.end.x - 38.0, 48.0)
	button_rects["ready"] = ready_rect
	button_rects["leave"] = leave_rect
	_draw_button(ready_rect, "READY UP", C_CYAN, true, "OK")
	_draw_button(leave_rect, "LEAVE", C_SURFACE_2, false, "X")


func _draw_results() -> void:
	_draw_menu_backdrop()
	var panel_width := minf(560.0, viewport_size.x - 32.0)
	var panel := Rect2((viewport_size.x - panel_width) * 0.5, maxf(72.0, (viewport_size.y - 510.0) * 0.5), panel_width, 510.0)
	_draw_panel(panel, C_SURFACE, C_BORDER, 8)
	_draw_status_chip(Rect2(panel.position.x + 28.0, panel.position.y + 27.0, 130.0, 28.0), "AFTER ACTION", C_LIME)
	_draw_text("TRAINING COMPLETE", panel.position + Vector2(28.0, 98.0), 29, C_TEXT)
	_draw_text("Operator performance summary", panel.position + Vector2(29.0, 124.0), 13, C_MUTED)
	var accuracy := 0.0 if shots_fired <= 0 else float(shots_hit) / float(shots_fired) * 100.0
	var stats := [
		["ELIMINATIONS", str(kills), C_LIME],
		["DEATHS", str(deaths), C_RED],
		["ACCURACY", "%d%%" % int(accuracy), C_CYAN],
	]
	for index in range(stats.size()):
		var rect := Rect2(panel.position.x + 28.0 + index * ((panel.size.x - 68.0) / 3.0), panel.position.y + 166.0, (panel.size.x - 76.0) / 3.0, 112.0)
		_draw_panel(rect, C_SURFACE_2, C_BORDER, 6)
		_draw_text_center(stats[index][0], Rect2(rect.position.x, rect.position.y + 16.0, rect.size.x, 24.0), 10, C_MUTED)
		_draw_text_center(stats[index][1], Rect2(rect.position.x, rect.position.y + 48.0, rect.size.x, 42.0), 28, stats[index][2])
	var again_rect := Rect2(panel.position + Vector2(28.0, 330.0), Vector2(panel.size.x - 56.0, 54.0))
	var menu_rect := Rect2(panel.position + Vector2(28.0, 397.0), Vector2(panel.size.x - 56.0, 48.0))
	button_rects["again"] = again_rect
	button_rects["menu"] = menu_rect
	_draw_button(again_rect, "RUN IT AGAIN", C_CYAN, true, "GO")
	_draw_button(menu_rect, "RETURN TO MENU", C_SURFACE_2, false, "<")


func _draw_game() -> void:
	_draw_world()
	_draw_world_entities()
	_draw_game_hud()
	if _is_mobile_layout():
		_draw_touch_controls()
	else:
		_draw_crosshair(get_viewport().get_mouse_position())
	if death_timer > 0.0:
		draw_rect(Rect2(Vector2.ZERO, viewport_size), Color(C_BACKGROUND, 0.56))
		_draw_text_center("RESPAWNING", Rect2(0.0, viewport_size.y * 0.42, viewport_size.x, 44.0), 26, C_TEXT)
		_draw_text_center("%.1f" % death_timer, Rect2(0.0, viewport_size.y * 0.49, viewport_size.x, 36.0), 19, C_CYAN)


func _draw_world() -> void:
	var view_left := camera_position.x - viewport_size.x * 0.5
	var view_top := camera_position.y - viewport_size.y * 0.5
	var spacing := 80
	var start_x := int(floor(view_left / spacing)) * spacing
	var start_y := int(floor(view_top / spacing)) * spacing
	for world_x in range(start_x, int(view_left + viewport_size.x) + spacing, spacing):
		var screen_x := float(world_x) - view_left
		draw_line(Vector2(screen_x, 0.0), Vector2(screen_x, viewport_size.y), C_GRID, 1.0)
	for world_y in range(start_y, int(view_top + viewport_size.y) + spacing, spacing):
		var screen_y := float(world_y) - view_top
		draw_line(Vector2(0.0, screen_y), Vector2(viewport_size.x, screen_y), C_GRID, 1.0)

	var map_rect := Rect2(_world_to_screen(Vector2.ZERO), world_size)
	draw_rect(map_rect, C_CYAN_DARK, false, 4.0)
	var objective := _world_to_screen(world_size * 0.5)
	draw_circle(objective, 118.0, Color(C_CYAN, 0.035))
	draw_arc(objective, 118.0, 0.0, TAU, 72, Color(C_CYAN, 0.25), 2.0)
	_draw_text_center("CONTROL", Rect2(objective.x - 75.0, objective.y - 12.0, 150.0, 24.0), 10, Color(C_CYAN, 0.45))

	for obstacle in obstacles:
		var screen_rect := Rect2(_world_to_screen(obstacle.position), obstacle.size)
		if not screen_rect.intersects(Rect2(Vector2.ZERO, viewport_size)):
			continue
		draw_rect(Rect2(screen_rect.position + Vector2(5.0, 7.0), screen_rect.size), Color("#03080D"))
		if crate_texture != null and obstacle.size.x < 130.0 and obstacle.size.y < 130.0:
			draw_texture_rect(crate_texture, screen_rect, false)
		else:
			_draw_panel(screen_rect, Color("#172D39"), Color("#385666"), 4)
			var stripe_count := maxi(1, int(screen_rect.size.x / 42.0))
			for stripe in range(stripe_count):
				var sx := screen_rect.position.x + 12.0 + stripe * 42.0
				draw_line(Vector2(sx, screen_rect.position.y + 8.0), Vector2(sx + 18.0, screen_rect.position.y + 8.0), Color(C_MUTED, 0.32), 2.0)


func _draw_world_entities() -> void:
	for bullet in bullets:
		var position := _world_to_screen(bullet.get("pos", Vector2.ZERO))
		var previous := _world_to_screen(bullet.get("previous", bullet.get("pos", Vector2.ZERO)))
		var color: Color = bullet.get("color", C_ORANGE)
		draw_line(previous, position, Color(color, 0.45), 3.0)
		if bullet_texture != null:
			draw_texture_rect(bullet_texture, Rect2(position - Vector2(7.0, 3.0), Vector2(14.0, 6.0)), false, color)
		else:
			draw_circle(position, 2.8, color)

	for effect in effects:
		_draw_effect(effect)

	for bot in bots:
		if float(bot.get("dead", 0.0)) <= 0.0:
			_draw_operator(bot, false)
	for id in remote_players.keys():
		_draw_operator(remote_players[id], false)
	if death_timer <= 0.0:
		var local_visual := local_player.duplicate()
		local_visual["angle"] = aim_angle
		_draw_operator(local_visual, true)


func _draw_operator(operator: Dictionary, is_local: bool) -> void:
	var world_position: Vector2 = operator.get("pos", Vector2.ZERO)
	var position := _world_to_screen(world_position)
	if position.x < -60.0 or position.y < -60.0 or position.x > viewport_size.x + 60.0 or position.y > viewport_size.y + 60.0:
		return
	var angle: float = float(operator.get("angle", 0.0))
	var team: int = int(operator.get("team", 0 if is_local else 1))
	var accent := C_CYAN if is_local else (C_BLUE if team == 0 else C_RED)
	var texture := player_texture if is_local or team == 0 else enemy_texture

	draw_circle(position + Vector2(3.0, 6.0), PLAYER_RADIUS + 5.0, Color("#02070B"))
	draw_circle(position, PLAYER_RADIUS + 7.0, Color(accent, 0.14))
	if texture != null:
		draw_set_transform(position, angle + PI * 0.5, Vector2.ONE)
		draw_texture_rect(texture, Rect2(-27.0, -27.0, 54.0, 54.0), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_circle(position, PLAYER_RADIUS, Color("#162B38") if is_local else Color("#30222A"))
		draw_arc(position, PLAYER_RADIUS, 0.0, TAU, 32, accent, 3.0)
		var forward := Vector2.from_angle(angle)
		var side := Vector2(-forward.y, forward.x)
		var points := PackedVector2Array([
			position + forward * 17.0,
			position - forward * 9.0 + side * 11.0,
			position - forward * 9.0 - side * 11.0,
		])
		draw_colored_polygon(points, accent)

	var muzzle := position + Vector2.from_angle(angle) * 31.0
	draw_line(position + Vector2.from_angle(angle) * 10.0, muzzle, Color("#C6D0D5"), 6.0)
	if rifle_texture != null:
		draw_set_transform(position, angle, Vector2.ONE)
		draw_texture_rect(rifle_texture, Rect2(5.0, -6.0, 36.0, 12.0), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	var hp := clampf(float(operator.get("hp", 100.0)), 0.0, float(operator.get("max_hp", 100.0)))
	var max_hp := maxf(1.0, float(operator.get("max_hp", 100.0)))
	var bar_rect := Rect2(position.x - 25.0, position.y - 37.0, 50.0, 5.0)
	draw_rect(bar_rect, Color("#1A1015"))
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * hp / max_hp, bar_rect.size.y)), C_LIME if hp > max_hp * 0.35 else C_RED)
	var display_name := "YOU" if is_local else str(operator.get("name", "OPERATOR")).to_upper()
	_draw_text_center(display_name, Rect2(position.x - 55.0, position.y + 30.0, 110.0, 18.0), 9, C_TEXT if is_local else C_MUTED)


func _draw_effect(effect: Dictionary) -> void:
	var position := _world_to_screen(effect.get("pos", Vector2.ZERO))
	var life := float(effect.get("life", 0.0))
	var maximum := maxf(0.001, float(effect.get("max", 1.0)))
	var progress := 1.0 - life / maximum
	match str(effect.get("type", "impact")):
		"muzzle":
			var direction := Vector2.from_angle(float(effect.get("angle", 0.0)))
			var side := Vector2(-direction.y, direction.x)
			var size := 15.0 * (1.0 - progress)
			draw_colored_polygon(PackedVector2Array([
				position + direction * size,
				position - direction * 3.0 + side * size * 0.45,
				position - direction * 3.0 - side * size * 0.45,
			]), C_ORANGE)
		_:
			var impact_color := C_RED if bool(effect.get("enemy", false)) else C_ORANGE
			for index in range(5):
				var angle := float(index) / 5.0 * TAU + progress
				var start := position + Vector2.from_angle(angle) * progress * 10.0
				draw_line(start, start + Vector2.from_angle(angle) * (7.0 * (1.0 - progress)), Color(impact_color, 1.0 - progress), 2.0)


func _draw_game_hud() -> void:
	var mobile := _is_mobile_layout()
	var leave_rect := Rect2(18.0, 18.0, 40.0, 40.0)
	button_rects["leave_match"] = leave_rect
	_draw_panel(leave_rect, Color(C_SURFACE, 0.92), C_BORDER, 6)
	_draw_text_center("<", leave_rect, 20, C_TEXT)

	var mode_text := "TRAINING RANGE" if screen_state == Screen.TRAINING else "ROOM %s" % room_code
	_draw_text(mode_text, Vector2(70.0, 36.0), 12, C_TEXT)
	_draw_text("LOCAL SIM" if screen_state == Screen.TRAINING else "%d MS" % ping_ms, Vector2(70.0, 53.0), 9, C_LIME if screen_state == Screen.TRAINING or ping_ms < 100 else C_ORANGE)

	var minutes := int(match_time / 60.0)
	var seconds := int(match_time) % 60
	var timer_rect := Rect2(viewport_size.x * 0.5 - 72.0, 17.0, 144.0, 48.0)
	_draw_panel(timer_rect, Color(C_SURFACE, 0.94), C_BORDER, 6)
	_draw_text_center("%02d:%02d" % [minutes, seconds], Rect2(timer_rect.position.x, timer_rect.position.y + 2.0, timer_rect.size.x, 28.0), 20, C_TEXT)
	_draw_text_center("LIVE" if screen_state == Screen.MATCH else "DRILL", Rect2(timer_rect.position.x, timer_rect.position.y + 28.0, timer_rect.size.x, 15.0), 8, C_RED if screen_state == Screen.MATCH else C_LIME)

	if not mobile:
		_draw_minimap()

	var hp := int(local_player.get("hp", 0))
	var hp_rect := Rect2(20.0, viewport_size.y - 79.0, 230.0, 58.0)
	_draw_panel(hp_rect, Color(C_SURFACE, 0.94), C_BORDER, 6)
	_draw_text("HP", hp_rect.position + Vector2(16.0, 24.0), 10, C_MUTED)
	_draw_text(str(hp), hp_rect.position + Vector2(45.0, 36.0), 25, C_TEXT)
	var health_bar := Rect2(hp_rect.position + Vector2(90.0, 22.0), Vector2(hp_rect.size.x - 106.0, 14.0))
	draw_rect(health_bar, Color("#24141A"))
	draw_rect(Rect2(health_bar.position, Vector2(health_bar.size.x * clampf(float(hp) / 100.0, 0.0, 1.0), health_bar.size.y)), C_LIME if hp > 35 else C_RED)

	var ammo_rect := Rect2(viewport_size.x - 242.0, viewport_size.y - 79.0, 222.0, 58.0)
	_draw_panel(ammo_rect, Color(C_SURFACE, 0.94), C_BORDER, 6)
	var ammo := int(local_player.get("ammo", 0))
	var reserve := int(local_player.get("reserve", 0))
	_draw_text("RIFLE", ammo_rect.position + Vector2(15.0, 21.0), 9, C_MUTED)
	_draw_text("%02d" % ammo, ammo_rect.position + Vector2(15.0, 47.0), 28, C_TEXT)
	_draw_text("/ %03d" % reserve, ammo_rect.position + Vector2(65.0, 44.0), 13, C_MUTED)
	var reload_rect := Rect2(ammo_rect.end.x - 54.0, ammo_rect.position.y + 9.0, 44.0, 40.0)
	button_rects["reload"] = reload_rect
	_draw_panel(reload_rect, C_SURFACE_2, C_BORDER, 5)
	_draw_text_center("R", reload_rect, 14, C_ORANGE if reload_timer > 0.0 else C_TEXT)
	if reload_timer > 0.0:
		draw_arc(reload_rect.get_center(), 15.0, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - reload_timer / 1.35), 24, C_ORANGE, 3.0)

	if screen_state == Screen.TRAINING:
		var score_rect := Rect2(viewport_size.x * 0.5 - 105.0, viewport_size.y - 59.0, 210.0, 37.0)
		_draw_panel(score_rect, Color(C_SURFACE, 0.92), C_BORDER, 5)
		_draw_text_center("KILLS %02d     DEATHS %02d" % [kills, deaths], score_rect, 11, C_TEXT)
	if hitmarker_time > 0.0:
		var center := viewport_size * 0.5
		for sign_x in [-1.0, 1.0]:
			for sign_y in [-1.0, 1.0]:
				draw_line(center + Vector2(sign_x * 7.0, sign_y * 7.0), center + Vector2(sign_x * 14.0, sign_y * 14.0), C_TEXT, 2.0)


func _draw_minimap() -> void:
	var rect := Rect2(viewport_size.x - 194.0, 17.0, 174.0, 118.0)
	_draw_panel(rect, Color(C_SURFACE, 0.92), C_BORDER, 6)
	var inner := Rect2(rect.position + Vector2(9.0, 23.0), rect.size - Vector2(18.0, 32.0))
	draw_rect(inner, Color("#08131C"))
	_draw_text("SECTOR MAP", rect.position + Vector2(10.0, 15.0), 8, C_MUTED)
	for obstacle in obstacles:
		var obstacle_rect := Rect2(
			inner.position + obstacle.position / world_size * inner.size,
			obstacle.size / world_size * inner.size
		)
		draw_rect(obstacle_rect, Color(C_MUTED, 0.34))
	var local_dot := inner.position + (local_player.get("pos", world_size * 0.5) as Vector2) / world_size * inner.size
	draw_circle(local_dot, 3.4, C_CYAN)
	for bot in bots:
		if float(bot.get("dead", 0.0)) <= 0.0:
			var bot_dot := inner.position + (bot.get("pos", Vector2.ZERO) as Vector2) / world_size * inner.size
			draw_circle(bot_dot, 2.7, C_RED)
	for id in remote_players.keys():
		var remote: Dictionary = remote_players[id]
		var remote_dot := inner.position + (remote.get("pos", Vector2.ZERO) as Vector2) / world_size * inner.size
		draw_circle(remote_dot, 2.7, C_BLUE if int(remote.get("team", 1)) == 0 else C_RED)


func _draw_touch_controls() -> void:
	var left_origin := left_touch_origin if left_touch_id >= 0 else Vector2(96.0, viewport_size.y - 145.0)
	var right_origin := right_touch_origin if right_touch_id >= 0 else Vector2(viewport_size.x - 96.0, viewport_size.y - 145.0)
	if left_touch_id >= 0 and touch_points.has(left_touch_id):
		var left_displacement: Vector2 = touch_points[left_touch_id] - left_touch_origin
		touch_move = left_displacement.limit_length(68.0) / 68.0
	else:
		touch_move = Vector2.ZERO
	if right_touch_id >= 0 and touch_points.has(right_touch_id):
		var right_displacement: Vector2 = touch_points[right_touch_id] - right_touch_origin
		touch_aim = right_displacement.limit_length(68.0)
		if touch_aim.length_squared() > 20.0:
			aim_angle = touch_aim.angle()
	else:
		touch_aim = Vector2.ZERO

	for origin in [left_origin, right_origin]:
		draw_circle(origin, 68.0, Color(C_SURFACE, 0.44))
		draw_arc(origin, 68.0, 0.0, TAU, 48, Color(C_MUTED, 0.42), 2.0)
	var left_knob := left_origin + touch_move * 42.0
	var right_knob := right_origin + touch_aim.limit_length(42.0)
	draw_circle(left_knob, 24.0, Color(C_CYAN, 0.28))
	draw_arc(left_knob, 24.0, 0.0, TAU, 32, C_CYAN, 2.0)
	draw_circle(right_knob, 24.0, Color(C_ORANGE, 0.28))
	draw_arc(right_knob, 24.0, 0.0, TAU, 32, C_ORANGE, 2.0)


func _draw_crosshair(position: Vector2) -> void:
	var gap := 6.0 + camera_shake * 2.0
	var length := 8.0
	for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(position + direction * gap, position + direction * (gap + length), C_TEXT, 1.5)
	draw_circle(position, 1.8, C_CYAN)


func _draw_toast() -> void:
	var alpha := clampf(toast_time * 2.0, 0.0, 1.0)
	var width := minf(430.0, viewport_size.x - 32.0)
	var rect := Rect2((viewport_size.x - width) * 0.5, 80.0, width, 42.0)
	_draw_panel(rect, Color(C_SURFACE, 0.94 * alpha), Color(toast_color, 0.65 * alpha), 6)
	draw_circle(rect.position + Vector2(19.0, 21.0), 4.0, Color(toast_color, alpha))
	_draw_text_center(toast_text, Rect2(rect.position.x + 25.0, rect.position.y, rect.size.x - 36.0, rect.size.y), 12, Color(C_TEXT, alpha))


func _draw_top_brand() -> void:
	_draw_text("STRIKE PROTOCOL", Vector2(24.0, 41.0), 19, C_TEXT)
	_draw_text("TACTICAL TCP ARENA", Vector2(25.0, 58.0), 8, C_CYAN)


func _draw_button(rect: Rect2, label: String, color: Color, filled: bool, icon_text: String = "") -> void:
	var background := color if filled else C_SURFACE_2
	var border := color if not filled else Color(color, 0.0)
	_draw_panel(rect, background, border, 6)
	if not icon_text.is_empty():
		var icon_rect := Rect2(rect.position + Vector2(9.0, 8.0), Vector2(rect.size.y - 16.0, rect.size.y - 16.0))
		draw_rect(icon_rect, Color(C_BACKGROUND, 0.18 if filled else 0.42))
		_draw_text_center(icon_text, icon_rect, 9, C_BACKGROUND if filled else color)
	_draw_text_center(label, rect, 13, C_BACKGROUND if filled else C_TEXT)


func _draw_status_chip(rect: Rect2, label: String, color: Color) -> void:
	_draw_panel(rect, Color(color, 0.09), Color(color, 0.55), 4)
	draw_circle(rect.position + Vector2(13.0, rect.size.y * 0.5), 3.0, color)
	_draw_text_center(label, Rect2(rect.position.x + 16.0, rect.position.y, rect.size.x - 18.0, rect.size.y), 9, color)


func _draw_panel(rect: Rect2, background: Color, border: Color, radius: int = 6) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0.01 else 0)
	style.set_corner_radius_all(radius)
	draw_style_box(style, rect)


func _draw_text(text: String, position: Vector2, font_size: int, color: Color = C_TEXT) -> void:
	draw_string(ThemeDB.fallback_font, position, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)


func _draw_text_center(text: String, rect: Rect2, font_size: int, color: Color = C_TEXT) -> void:
	var text_size := ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var position := Vector2(
		rect.position.x + (rect.size.x - text_size.x) * 0.5,
		rect.position.y + (rect.size.y - text_size.y) * 0.5 + text_size.y * 0.78
	)
	_draw_text(text, position, font_size, color)


func _draw_small_icon(kind: String, position: Vector2, color: Color) -> void:
	match kind:
		"shield":
			draw_colored_polygon(PackedVector2Array([
				position + Vector2(0.0, -8.0), position + Vector2(7.0, -5.0),
				position + Vector2(6.0, 3.0), position + Vector2(0.0, 9.0),
				position + Vector2(-6.0, 3.0), position + Vector2(-7.0, -5.0),
			]), Color(color, 0.25))
			draw_polyline(PackedVector2Array([
				position + Vector2(0.0, -8.0), position + Vector2(7.0, -5.0),
				position + Vector2(6.0, 3.0), position + Vector2(0.0, 9.0),
				position + Vector2(-6.0, 3.0), position + Vector2(-7.0, -5.0),
				position + Vector2(0.0, -8.0),
			]), color, 1.5)
		_:
			draw_colored_polygon(PackedVector2Array([
				position + Vector2(2.0, -9.0), position + Vector2(-5.0, 1.0),
				position + Vector2(0.0, 1.0), position + Vector2(-2.0, 9.0),
				position + Vector2(7.0, -3.0), position + Vector2(2.0, -3.0),
			]), color)


func _menu_panel_rect() -> Rect2:
	var width := minf(560.0, viewport_size.x - 32.0)
	var height := 498.0
	var y := maxf(92.0, (viewport_size.y - height) * 0.5 + 25.0)
	return Rect2((viewport_size.x - width) * 0.5, y, width, height)


func _world_to_screen(world_position: Vector2) -> Vector2:
	var shake := Vector2.ZERO
	if camera_shake > 0.0:
		var time := float(Time.get_ticks_msec()) * 0.032
		shake = Vector2(sin(time * 1.3), cos(time * 1.7)) * camera_shake * 5.0
	return world_position - camera_position + viewport_size * 0.5 + shake

