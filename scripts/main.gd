extends Node3D

const Settings = preload("res://scripts/settings.gd")
const Simulation = preload("res://scripts/simulation.gd")
const Bridge = preload("res://scripts/bridge.gd")
const WorldView = preload("res://scripts/world_view.gd")
const Reticle = preload("res://scripts/reticle.gd")
const Presets = preload("res://scripts/presets.gd")
const AimAssist = preload("res://scripts/aim_assist.gd")
const CameraStream = preload("res://scripts/camera_stream.gd")
const CAMERA_RESOLUTIONS = [Vector2i(640, 480), Vector2i(960, 600), Vector2i(1280, 720),
	Vector2i(1280, 1024), Vector2i(1440, 1080), Vector2i(1920, 1080)]

var model: RefCounted
var bridge: RefCounted
var camera_stream: RefCounted
var world: Node3D
var fields: Dictionary = {}
var slider_labels: Dictionary = {}
var robot_select: OptionButton
var team_select: OptionButton
var camera_resolution: OptionButton
var remote: CheckButton
var pause_button: Button
var status_label: Label
var stats_label: Label
var health_label: Label
var event_label: Label
var message_label: Label
var fire_button: Button
var aim_button: Button
var tracking_held = false
var tracking_armor = -1
var main_reticle: Control
var ui_root: Control
var yaw_input: SpinBox
var pitch_input: SpinBox
var model_dialog: FileDialog
var armor_label: Label
var selected_armor = ""
var capture_path = ""
var quit_after = -1.0
var wall_elapsed = 0.0
var capture_requested = false
var no_ipc = false
var first_person_image: TextureRect
var start_remote = false
var has_graphics = true
var _ui_elapsed = 0.0
var _updating_fields = false


func _ready() -> void:
	var config_path = "res://configs/default.cfg"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--config="):
			config_path = arg.trim_prefix("--config=")
		elif arg == "--remote":
			start_remote = true
		elif arg in ["--no-ipc", "--no-network"]:
			no_ipc = true
		elif arg.begins_with("--capture="):
			capture_path = arg.trim_prefix("--capture=")
		elif arg.begins_with("--quit-after-seconds="):
			quit_after = arg.trim_prefix("--quit-after-seconds=").to_float()
	var loaded = Settings.load_file(config_path)
	if not loaded.ok:
		push_error(loaded.error)
		get_tree().quit(2)
		return
	model = Simulation.new(loaded.settings)
	bridge = Bridge.new()
	if not no_ipc:
		var error = bridge.setup(model)
		if error != OK:
			set_process(false)
			set_physics_process(false)
			push_error(bridge.status + " · Close the same-channel simulation or choose a different ipc.channel")
			get_tree().quit(2)
			return
	else:
		bridge.model = model
	bridge.set_enabled(start_remote)
	has_graphics = DisplayServer.get_name() != "headless"
	if has_graphics:
		world = WorldView.new()
		add_child(world)
		world.build(model)
		if not no_ipc:
			camera_stream = CameraStream.new()
			camera_stream.setup(model, bridge, world.sensor_viewport)
		_build_ui()
		_load_fields()
		_connect_live_controls()
	print("Aim Lab ready | session=%s | local_ipc=%s | remote=%s" % [
		model.session_id, bridge.ipc.directory, bridge.enabled])


func _physics_process(dt: float) -> void:
	if model != null:
		if has_graphics and not bridge.enabled:
			_local_command(dt)
		model.step(dt)


func _process(dt: float) -> void:
	if model == null:
		return
	wall_elapsed += dt
	if not no_ipc:
		bridge.poll(dt)
	if has_graphics:
		if bridge.enabled:
			tracking_held = false
			tracking_armor = -1
		world.update_world()
		if camera_stream != null:
			camera_stream.poll()
		_ui_elapsed += dt
		if _ui_elapsed > 0.05:
			_update_status()
			_ui_elapsed = 0.0
		if not capture_path.is_empty() and not capture_requested and wall_elapsed > 1.0:
			capture_requested = true
			_capture(capture_path)
	if quit_after > 0 and wall_elapsed >= quit_after:
		print("FINAL_STATS " + JSON.stringify(model.metrics()))
		get_tree().quit()


func _exit_tree() -> void:
	if camera_stream != null:
		camera_stream.close()
	if bridge != null:
		bridge.close()


func _local_command(dt: float) -> void:
	if model.paused or bridge.enabled:
		tracking_held = false
		tracking_armor = -1
		return
	var focus = get_viewport().gui_get_focus_owner()
	var typing = focus is LineEdit or focus is TextEdit
	var focused = DisplayServer.window_is_focused()
	var was_tracking = tracking_held
	tracking_held = focused and (aim_button.button_pressed or (not typing and Input.is_physical_key_pressed(KEY_F)))
	tracking_armor = -1
	var solution: Dictionary = AimAssist.solve(model) if tracking_held else {}
	if not solution.is_empty():
		tracking_armor = solution.armor_id
		yaw_input.value = rad_to_deg(solution.yaw)
		pitch_input.value = rad_to_deg(solution.pitch)
	elif not typing:
		var direction = Input.get_axis("ui_right", "ui_left")
		var elevation = Input.get_axis("ui_up", "ui_down")
		yaw_input.value += direction * 30.0 * dt
		pitch_input.value += elevation * 20.0 * dt
	var fire = fire_button.button_pressed or (not typing and Input.is_physical_key_pressed(KEY_SPACE))
	if not focused:
		fire = false
	var command = {"control": true, "fire": fire,
		"yaw": deg_to_rad(yaw_input.value), "pitch": deg_to_rad(pitch_input.value)}
	for key in ["yaw", "pitch", "yaw_vel", "pitch_vel"]:
		if solution.has(key):
			command[key] = solution[key]
	model.set_command(command)
	if was_tracking and not tracking_held:
		message_label.text = "Continuous tracking ended · last aim angle retained"


func _input(event: InputEvent) -> void:
	if not has_graphics or not event is InputEventKey or model_dialog.visible:
		return
	if event.physical_keycode not in [KEY_SPACE, KEY_F]:
		return
	var focus = get_viewport().gui_get_focus_owner()
	if focus is LineEdit and focus.get_parent() is SpinBox:
		# Finish a numeric edit before polling fire/tracking; Space must not get trapped in the field.
		if event.pressed:
			focus.get_parent().apply()
	elif focus is LineEdit or focus is TextEdit:
		return
	# Reserve these keys for the simulator, including key-up, so a focused Reset/Pause button cannot activate.
	get_viewport().gui_release_focus()
	get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not has_graphics:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_P:
				_toggle_pause()
			KEY_R:
				_reset_current()
			KEY_V:
				_toggle_view()
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		world.orbit_angle -= event.relative.x * 0.005
		world.orbit_elevation = clampf(world.orbit_elevation + event.relative.y * 0.004, 0.08, 1.3)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			world.orbit_distance = maxf(2.0, world.orbit_distance - 0.7)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			world.orbit_distance = minf(28.0, world.orbit_distance + 0.7)


func _build_ui() -> void:
	var canvas = CanvasLayer.new()
	add_child(canvas)
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(ui_root)
	var theme_value = Theme.new()
	var font = SystemFont.new()
	font.font_names = PackedStringArray(["Noto Sans CJK SC", "Noto Sans CJK JP", "DejaVu Sans"])
	theme_value.default_font = font
	theme_value.default_font_size = 15
	theme_value.set_color("font_color", "Label", Color("d5e2e9"))
	for type_name in ["Button", "OptionButton", "SpinBox", "CheckButton"]:
		theme_value.set_color("font_color", type_name, Color("d5e2e9"))
	for state in ["normal", "hover", "pressed", "focus"]:
		var style = _panel_style(Color("203647") if state != "hover" else Color("2d4c5d"))
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 7
		style.content_margin_bottom = 7
		theme_value.set_stylebox(state, "Button", style)
		theme_value.set_stylebox(state, "OptionButton", style)
	ui_root.theme = theme_value
	first_person_image = TextureRect.new()
	first_person_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	first_person_image.texture = world.raw_sensor_viewport.get_texture()
	first_person_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	first_person_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	first_person_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(first_person_image)
	_sync_view()
	var sidebar = PanelContainer.new()
	sidebar.position = Vector2(18, 18)
	sidebar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	sidebar.offset_top = 18
	sidebar.offset_bottom = -18
	sidebar.offset_left = 18
	sidebar.offset_right = 338
	sidebar.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.07, 0.11, 0.97)))
	ui_root.add_child(sidebar)
	var margin = MarginContainer.new()
	for name in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(name, 16)
	sidebar.add_child(margin)
	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var column = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	scroll.add_child(column)
	var title = _label("AIM LAB", 30, Color("5be2d4"))
	column.add_child(title)
	column.add_child(_label("RoboMaster · Auto-Aim Sim", 14, Color("91acbb")))
	pause_button = _add_button(column, "P  Pause", _toggle_pause)
	_section(column, "01  Target & Team")
	robot_select = OptionButton.new()
	for robot in Presets.ROBOTS:
		robot_select.add_item(Presets.ROBOTS[robot].label)
		robot_select.set_item_metadata(robot_select.item_count - 1, robot)
	robot_select.item_selected.connect(_robot_selected)
	column.add_child(robot_select)
	team_select = OptionButton.new()
	team_select.add_item("Blue Armor")
	team_select.add_item("Red Armor")
	column.add_child(team_select)
	_add_number(column, "target.max_health", "Set HP", 0, 10000, 1)
	_add_number(column, "target.center.x", "Initial Distance / m", 1, 20, 0.1)
	_add_slider(column, "target.center.z", "Ref Armor Bottom Edge", 0.001, 0.4)
	_add_slider(column, "target.radius", "Armor Extension", 0.05, Presets.MAX_EXTENT)
	_add_slider(column, "target.height_difference", "Armor Height Offset", -0.1, 0.1)
	column.add_child(_label("Bottom edge 1–400 mm · Height diff ≤100 mm", 12, Color("91acbb")))
	_add_toggle(column, "target.translate", "Enable Translation")
	_add_number(column, "target.speed", "Translation Speed / m·s⁻¹", 0, 10, 0.1)
	_add_number(column, "target.acceleration", "Translation Accel / m·s⁻²", 0.1, 50, 0.1)
	_add_number(column, "target.heading", "Translation Heading / °", -180, 180, 1)
	_add_number(column, "target.travel", "Half Travel / m", 0.1, 10, 0.1)
	_add_toggle(column, "target.rotate", "Enable Spin")
	_add_number(column, "target.omega", "Spin Speed / rad·s⁻¹", -25, 25, 0.1)
	_add_number(column, "target.module_width", "Module Outer Width / m", 0.05, 0.3, 0.001)
	_add_number(column, "target.module_height", "Module Outer Height / m", 0.04, 0.3, 0.001)
	_add_number(column, "target.armor_width", "Hit Zone Width (approx) / m", 0.05, 0.3, 0.005)
	_add_number(column, "target.armor_height", "Hit Zone Height (approx) / m", 0.04, 0.3, 0.001)
	_add_number(column, "target.lightbar_spacing", "Light Bar Spacing / m", 0.05, 0.3, 0.005)
	_section(column, "02  Weapon & Gimbal")
	_add_number(column, "weapon.speed", "Muzzle Velocity / m·s⁻¹", 1, 100, 0.5)
	_add_number(column, "weapon.damage", "Damage per Shot / HP", 0, 10000, 1)
	_add_number(column, "weapon.rate", "Rate of Fire / Hz", 0.1, 50, 0.5)
	_add_number(column, "weapon.delay", "Fire Delay / ms", 0, 1000, 1)
	_add_number(column, "gimbal.max_speed", "Gimbal Max Speed / rad·s⁻¹", 0.1, 20, 0.1)
	_add_number(column, "gimbal.max_acceleration", "Angular Accel / rad·s⁻²", 0.1, 500, 1)
	_section(column, "03  Camera")
	camera_resolution = OptionButton.new()
	for size in CAMERA_RESOLUTIONS:
		camera_resolution.add_item("%d × %d" % [size.x, size.y])
		camera_resolution.set_item_metadata(camera_resolution.item_count - 1, size)
	camera_resolution.item_selected.connect(_camera_resolution_selected)
	column.add_child(camera_resolution)
	_add_number(column, "camera.width", "Image Width / px", 160, 3840, 1)
	_add_number(column, "camera.height", "Image Height / px", 120, 2160, 1)
	_add_number(column, "camera.vertical_fov", "Vertical FOV / °", 10, 120, 1)
	_add_slider(column, "camera.brightness_gain", "Exposure Gain / ×", 0, 4)
	fields["camera.brightness_gain"].step = 0.01
	fields["camera.brightness_gain"].value_changed.connect(func(value: float):
		slider_labels["camera.brightness_gain"].text = "Exposure Gain %.2f× · below 1 reduces exposure" % value)
	column.add_child(_label("Resolution and intrinsics update together; round stats are preserved.", 12, Color("91acbb"), true))
	_section(column, "04  Custom Models")
	armor_label = _label("Armor: built-in light bars & textures", 13, Color("91acbb"))
	column.add_child(armor_label)
	_add_button(column, "Choose Armor GLB / glTF", _choose_model)
	_add_button(column, "Restore Built-in Appearance", func():
		selected_armor = ""
		_update_model_labels()
		_apply_fields())
	column.add_child(_label("Parameter changes take effect immediately; editing HP sets current HP.", 12, Color("91acbb"), true))
	var manual_panel = PanelContainer.new()
	manual_panel.position = Vector2(356, 156)
	manual_panel.custom_minimum_size = Vector2(290, 0)
	manual_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.07, 0.11, 0.94)))
	ui_root.add_child(manual_panel)
	var manual_column = VBoxContainer.new()
	manual_column.add_theme_constant_override("separation", 8)
	manual_panel.add_child(manual_column)
	manual_column.add_child(_label("Gimbal Control  /  GIMBAL", 13, Color("5be2d4")))
	yaw_input = _manual_angle(manual_column, "Yaw / °", -180, 180)
	pitch_input = _manual_angle(manual_column, "Pitch / ° · up is negative", rad_to_deg(model.settings.gimbal.pitch_min), rad_to_deg(model.settings.gimbal.pitch_max))
	aim_button = Button.new()
	aim_button.text = "Hold to Track / F"
	aim_button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	aim_button.keep_pressed_outside = true
	manual_column.add_child(aim_button)
	fire_button = Button.new()
	fire_button.text = "Hold to Fire / Space"
	fire_button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	fire_button.keep_pressed_outside = true
	manual_column.add_child(fire_button)
	remote = CheckButton.new()
	remote.text = "Local Auto-Aim Control"
	remote.button_pressed = bridge.enabled
	remote.disabled = not bridge.bound
	remote.toggled.connect(func(value): bridge.set_enabled(value))
	manual_column.add_child(remote)
	_section(column, "05  Scene Controls")
	_add_button(column, "R  Reset Round", _reset_current)
	_add_button(column, "V  Toggle View", _toggle_view)
	_add_button(column, "Save Current Config", _save_config)
	_add_button(column, "Export Stats & Events", _export_stats)
	_add_button(column, "Save Gimbal Image", _capture_sensor)
	column.add_child(_label("Arrow keys: aim · Right-drag: orbit\nScroll: zoom · Grid spacing 1 m", 12, Color("91acbb")))
	var header = PanelContainer.new()
	header.position = Vector2(356, 18)
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_left = 356
	header.offset_right = -18
	header.offset_top = 18
	header.offset_bottom = 138
	header.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.07, 0.11, 0.92)))
	ui_root.add_child(header)
	var header_column = VBoxContainer.new()
	header_column.add_theme_constant_override("separation", 6)
	header.add_child(header_column)
	status_label = _label("", 14, Color("5be2d4"))
	header_column.add_child(status_label)
	stats_label = _label("", 23)
	header_column.add_child(stats_label)
	health_label = _label("", 16, Color("5be2d4"))
	header_column.add_child(health_label)
	var picture = PanelContainer.new()
	picture.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	picture.offset_left = -422
	picture.offset_right = -18
	picture.offset_top = 156
	picture.offset_bottom = 444
	picture.add_theme_stylebox_override("panel", _panel_style(Color("0c1b2a")))
	ui_root.add_child(picture)
	var picture_column = VBoxContainer.new()
	picture.add_child(picture_column)
	picture_column.add_child(_label("Gimbal Camera  /  CAMERA", 13, Color("91acbb")))
	var frame = TextureRect.new()
	frame.texture = world.sensor_viewport.get_texture()
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.custom_minimum_size = Vector2(380, 238)
	picture_column.add_child(frame)
	var sensor_reticle = Reticle.new()
	sensor_reticle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(sensor_reticle)
	main_reticle = Reticle.new()
	main_reticle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_reticle.visible = world.first_person
	ui_root.add_child(main_reticle)
	var footer = PanelContainer.new()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 356
	footer.offset_right = -18
	footer.offset_top = -116
	footer.offset_bottom = -18
	footer.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.07, 0.11, 0.94)))
	ui_root.add_child(footer)
	var footer_column = VBoxContainer.new()
	footer.add_child(footer_column)
	event_label = _label("", 14)
	footer_column.add_child(event_label)
	message_label = _label("RM coords: x forward / y left / z up · Pitch positive downward", 13, Color("91acbb"), true)
	footer_column.add_child(message_label)
	model_dialog = FileDialog.new()
	model_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	model_dialog.access = FileDialog.ACCESS_FILESYSTEM
	model_dialog.filters = PackedStringArray(["*.glb,*.gltf ; 3D glTF model"])
	model_dialog.file_selected.connect(_model_selected)
	ui_root.add_child(model_dialog)


func _load_fields() -> void:
	_updating_fields = true
	for path in fields:
		var value = _setting_get(model.settings, path)
		var input: Control = fields[path]
		if input is CheckButton:
			input.button_pressed = value
		else:
			if path == "target.heading":
				value = rad_to_deg(value)
			elif path == "weapon.delay":
				value *= 1000.0
			elif path == "target.max_health":
				value = model.max_health
			elif path == "target.radius":
				value = Presets.extent(model.settings.target)
			elif path == "target.center.z":
				value = Presets.lower_edge(model.settings.target)
			input.value = value
	for i in range(robot_select.item_count):
		if robot_select.get_item_metadata(i) == model.settings.appearance.robot:
			robot_select.select(i)
	team_select.select(0 if model.settings.appearance.team == "blue" else 1)
	_sync_camera_resolution()
	selected_armor = model.settings.appearance.armor_model
	_update_model_labels()
	_update_height_limits()
	_update_spacing_limits(model.settings.target)
	_updating_fields = false


func _connect_live_controls() -> void:
	for path in fields:
		var input: Control = fields[path]
		if input is CheckButton:
			input.toggled.connect(_field_changed.bind(path))
		else:
			input.value_changed.connect(_field_changed.bind(path))
	team_select.item_selected.connect(func(_index): _apply_fields())


func _field_changed(_value: Variant, path: String) -> void:
	_apply_fields(path)


func _camera_resolution_selected(index: int) -> void:
	if _updating_fields:
		return
	var size: Vector2i = camera_resolution.get_item_metadata(index)
	_updating_fields = true
	fields["camera.width"].value = size.x
	fields["camera.height"].value = size.y
	_updating_fields = false
	_apply_fields("camera")


func _sync_camera_resolution() -> void:
	var size = Vector2i(model.settings.camera.width, model.settings.camera.height)
	for index in range(camera_resolution.item_count):
		if camera_resolution.get_item_metadata(index) == size:
			camera_resolution.select(index)
			return
	if camera_resolution.item_count > CAMERA_RESOLUTIONS.size():
		camera_resolution.remove_item(camera_resolution.item_count - 1)
	camera_resolution.add_item("Custom %d × %d" % [size.x, size.y])
	camera_resolution.set_item_metadata(camera_resolution.item_count - 1, size)
	camera_resolution.select(camera_resolution.item_count - 1)


func _apply_fields(changed_path: String = "") -> void:
	if _updating_fields:
		return
	_update_height_limits()
	var s = model.settings.duplicate(true)
	for path in fields:
		if path == "target.radius":
			continue
		if path == "target.max_health" and changed_path not in ["target.max_health", "robot"]:
			continue
		var input: Control = fields[path]
		var value = input.button_pressed if input is CheckButton else input.value
		if path == "target.heading":
			value = deg_to_rad(value)
		elif path == "weapon.delay":
			value /= 1000.0
		_setting_set(s, path, value)
	s.target.center.z = fields["target.center.z"].value + Presets.vertical_half_height(s.target)
	var spacing_error = _update_spacing_limits(s.target)
	if not spacing_error.is_empty():
		message_label.text = spacing_error
		return
	s.target.radius = Presets.radius_for_extent(fields["target.radius"].value, s.target)
	s.appearance.robot = robot_select.get_selected_metadata()
	s.appearance.team = "blue" if team_select.selected == 0 else "red"
	s.appearance.armor_model = selected_armor
	for path in [selected_armor]:
		if not path.is_empty():
			var test_model = preload("res://scripts/visual_assets.gd").load_model(path)
			if test_model == null:
				message_label.text = "Model load failed, settings not applied: " + path.get_file()
				return
			test_model.free()
	var error = Settings.validate(s)
	if not error.is_empty():
		message_label.text = error
		return
	var rebuild: bool = s.appearance != model.settings.appearance
	for key in ["module_width", "module_height", "lightbar_spacing", "lightbar_length"]:
		rebuild = rebuild or s.target[key] != model.settings.target[key]
	model.apply_settings(s, changed_path in ["target.max_health", "robot"])
	_sync_camera_resolution()
	if rebuild:
		world.rebuild_target()
	world.update_world()
	_update_status()
	message_label.text = "Settings applied · " + Presets.ROBOTS[s.appearance.robot].label


func _reset_current() -> void:
	model.reset()
	bridge.reset_session()
	if has_graphics:
		world.rebuild_target()
		pause_button.text = "P  Pause"
		yaw_input.value = 0
		pitch_input.value = 0


func _toggle_pause() -> void:
	model.paused = not model.paused
	model.stop()
	model.session_id = "%d-%d" % [Time.get_ticks_usec(), randi()]
	bridge.reset_session()
	pause_button.text = "P  Resume" if model.paused else "P  Pause"


func _toggle_view() -> void:
	world.first_person = not world.first_person
	main_reticle.visible = world.first_person
	_sync_view()


func _sync_view() -> void:
	first_person_image.visible = world.first_person
	get_viewport().disable_3d = world.first_person


func _robot_selected(index: int) -> void:
	_updating_fields = true
	var preset: Dictionary = Presets.ROBOTS[robot_select.get_item_metadata(index)]
	fields["target.radius"].value = Presets.DEFAULT_EXTENT
	fields["target.armor_width"].value = preset.width
	fields["target.armor_height"].value = preset.height
	fields["target.module_width"].value = preset.module_width
	fields["target.module_height"].value = preset.module_height
	fields["target.max_health"].value = preset.max_health
	fields["target.lightbar_spacing"].value = preset.width
	_updating_fields = false
	_apply_fields("robot")


func _update_status() -> void:
	var s = model.metrics()
	var health_input: SpinBox = fields["target.max_health"]
	if get_viewport().gui_get_focus_owner() != health_input.get_line_edit():
		_updating_fields = true
		health_input.value = model.health
		_updating_fields = false
	status_label.text = "  %s   ·   T %.2f s   ·   %s   ·   %d FPS" % [
		"PAUSED" if model.paused else "RUNNING", model.time, bridge.status, Engine.get_frames_per_second()]
	stats_label.text = "  Hits %d / %d    %.1f%%    Fired %d    In-flight %d" % [
		s.hit, s.resolved, s.hit_rate * 100.0, s.fired, s.in_flight]
	health_label.text = "  Target HP %d / %d HP  ·  %s  ·  Total Damage %d  ·  Kills %d" % [
		model.health, model.max_health, "Alive" if model.health > 0 else "Destroyed / lights off", s.damage, s.kills]
	health_label.add_theme_color_override("font_color", Color("5be2d4") if model.health > 0 else Color("ff6a72"))
	event_label.text = "  Ground %d  ·  OOB/Timeout %d  ·  Hits/s %.2f\n  Actual Yaw %.2f°  /  Pitch %.2f°    Local cmds %d / rejected %d" % [
		s.ground, s.expired, s.hits_per_second, rad_to_deg(model.yaw),
		rad_to_deg(model.pitch), bridge.received, bridge.rejected]
	if tracking_held:
		message_label.text = "F continuous track · armor %d · Space fire" % tracking_armor if tracking_armor >= 0 else "F continuous track · no live armor in range"


func _choose_model() -> void:
	model_dialog.popup_centered_ratio(0.7)


func _model_selected(path: String) -> void:
	selected_armor = path
	_update_model_labels()
	_apply_fields()


func _update_model_labels() -> void:
	armor_label.text = "Armor: " + (selected_armor.get_file() if not selected_armor.is_empty() else "built-in light bars & textures")


func _save_config() -> void:
	var path = "user://last_scenario.cfg"
	var error = Settings.save_file(model.settings, path)
	message_label.text = "Config saved: " + ProjectSettings.globalize_path(path) if error == OK else "Failed to save config"


func _export_stats() -> void:
	DirAccess.make_dir_recursive_absolute("res://captures")
	var path = "res://captures/round_%s.json" % Time.get_datetime_string_from_system().replace(":", "-")
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		message_label.text = "Export failed: cannot write to captures/"
		return
	var result = model.snapshot()
	result["scenario"] = _json_settings(model.settings)
	result["events"] = model.events
	file.store_string(JSON.stringify(result, "  "))
	message_label.text = "Stats exported: " + ProjectSettings.globalize_path(path)


func _capture_sensor() -> void:
	DirAccess.make_dir_recursive_absolute("res://captures")
	await RenderingServer.frame_post_draw
	var path = "res://captures/camera_%d.png" % Time.get_ticks_msec()
	var error = world.sensor_viewport.get_texture().get_image().save_png(path)
	message_label.text = "Camera image saved: " + ProjectSettings.globalize_path(path) if error == OK else "Failed to save image"


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	var error = get_viewport().get_texture().get_image().save_png(path)
	print("SCREENSHOT %s error=%d" % [path, error])


func _json_settings(s: Dictionary) -> Dictionary:
	var result = s.duplicate(true)
	for section in result:
		for key in result[section]:
			if result[section][key] is Vector3:
				result[section][key] = model.vec(result[section][key])
	return result


func _setting_get(s: Dictionary, path: String) -> Variant:
	var parts = path.split(".")
	var value = s[parts[0]][parts[1]]
	if parts.size() == 3:
		return value.x if parts[2] == "x" else value.z
	return value


func _setting_set(s: Dictionary, path: String, value: Variant) -> void:
	var parts = path.split(".")
	if parts.size() == 3:
		var vector: Vector3 = s[parts[0]][parts[1]]
		if parts[2] == "x":
			vector.x = value
		else:
			vector.z = value
		s[parts[0]][parts[1]] = vector
	else:
		s[parts[0]][parts[1]] = value


func _add_number(parent: VBoxContainer, path: String, text: String, minimum: float, maximum: float, step: float) -> void:
	var row = HBoxContainer.new()
	parent.add_child(row)
	var label = _label(text, 13)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var input = SpinBox.new()
	input.min_value = minimum
	input.max_value = maximum
	input.step = step
	input.update_on_text_changed = true
	input.custom_minimum_size.x = 106
	row.add_child(input)
	fields[path] = input


func _add_slider(parent: VBoxContainer, path: String, text: String, minimum: float, maximum: float) -> void:
	var label = _label(text, 13)
	parent.add_child(label)
	var slider = HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.001
	slider.custom_minimum_size = Vector2(0, 24)
	parent.add_child(slider)
	fields[path] = slider
	slider_labels[path] = label


func _update_height_limits() -> void:
	var previous = _updating_fields
	_updating_fields = true
	var height: HSlider = fields["target.center.z"]
	var difference: HSlider = fields["target.height_difference"]
	# The UI edits lower-edge height directly; the model stores the tilted module's center.
	height.min_value = 0.001 + maxf(0.0, -difference.value)
	height.max_value = 0.4 - maxf(0.0, difference.value)
	var lower = height.value
	difference.min_value = maxf(-0.1, 0.001 - lower)
	difference.max_value = minf(0.1, 0.4 - lower)
	slider_labels["target.center.z"].text = "Ref Armor Bottom Edge %.0f mm" % (lower * 1000.0)
	slider_labels["target.height_difference"].text = "Armor Height Offset %+.0f mm" % (difference.value * 1000.0)
	_updating_fields = previous


func _update_spacing_limits(target: Dictionary) -> String:
	var probe = target.duplicate()
	probe.radius = Presets.minimum_radius(target)
	var minimum = ceil((Presets.extent(probe) - 1e-9) * 1000.0) / 1000.0
	if minimum > Presets.MAX_EXTENT:
		return "Current armor size and height offset cannot maintain clearance within 600 mm — reduce size or height offset."
	var previous = _updating_fields
	_updating_fields = true
	var spacing: HSlider = fields["target.radius"]
	spacing.min_value = minimum
	spacing.max_value = Presets.MAX_EXTENT
	slider_labels["target.radius"].text = "Armor Extension %.0f mm · max 600 mm" % (spacing.value * 1000.0)
	_updating_fields = previous
	return ""


func _manual_angle(parent: VBoxContainer, text: String, minimum: float, maximum: float) -> SpinBox:
	_add_number(parent, text, text, minimum, maximum, 0.1)
	var result: SpinBox = fields[text]
	fields.erase(text)
	return result


func _add_toggle(parent: VBoxContainer, path: String, text: String) -> void:
	var button = CheckButton.new()
	button.text = text
	parent.add_child(button)
	fields[path] = button


func _section(parent: VBoxContainer, text: String) -> void:
	var separator = HSeparator.new()
	parent.add_child(separator)
	parent.add_child(_label(text, 14, Color("5be2d4")))


func _add_button(parent: VBoxContainer, text: String, action: Callable) -> Button:
	var button = Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _label(text: String, font_size: int, color: Color = Color("d5e2e9"), wrap: bool = false) -> Label:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _panel_style(color: Color) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color("284353")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style
