extends CharacterBody3D

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
@export var animation_player_path: NodePath
var animation_player: AnimationPlayer
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var brain: NPCBrain 

# ============================================================
# DEATH
# ============================================================
## Drag in as many particle nodes as you like (GPUParticles3D or
## CPUParticles3D children already sitting on this NPC). They all start
## together at particles_trigger_time and are triggered in place, not
## instanced, so position each one under the NPC wherever you want that
## effect to originate (e.g. the head, or a blood mist at the chest).
@export var death_particles: Array[Node] = []

## Name of the animation to play on death. If the AnimationPlayer
## doesn't have it, the NPC still stops and is removed after
## death_fallback_delay instead of hanging forever.
@export var death_animation_name: String = "Death"

## Used only when death_animation_name isn't found on the
## AnimationPlayer -- how long to wait (with particles playing) before
## removing the NPC.
@export var death_fallback_delay: float = 1.5

## Seconds after the death starts at which the blood explosion plays.
## 0 = immediately. The NPC is kept alive long enough for the particles
## to finish (trigger time + particle lifetime), so a late trigger
## isn't cut off by the NPC being removed.
@export var particles_trigger_time: float = 0.0

## The visual body (mesh/skeleton root) to leave behind as a corpse.
## When the death finishes, this node is moved out of the NPC into the
## current scene, keeping its exact position and pose, and everything
## else on the NPC (collision, head hitbox, nav agent, particles,
## scripts) is freed. Leave empty to remove the whole NPC as before.
@export var body_to_keep: Node3D

## Decal (e.g. a blood pool) that stays hidden until the NPC dies, then
## appears small and grows to its full size over the course of the death.
## Its size in the editor is the FULL size. It is left behind in the
## scene along with the corpse instead of being freed with the NPC.
@export var death_decal: Decal

@export_group("Kill Reward")
@export var time_bonus_on_kill: float = 5.0
@export_group("Death Decal")
## Fraction of the decal's full footprint (X and Z) it starts at when it
## appears. Depth (Y) is never scaled.
@export_range(0.0, 1.0) var decal_start_scale: float = 0.05

## Seconds after the death starts at which the decal appears and begins
## growing (same idea as particles_trigger_time). 0 = immediately.
@export var decal_trigger_time: float = 0.0

## Seconds the decal takes to reach full size once it starts. 0 (or
## less) = grow from the trigger time until the end of the death
## sequence, finishing right as the NPC is fully dead. If trigger time +
## this is longer than the death, the NPC is kept alive until it's done.
@export var decal_grow_time: float = 0.0

var _decal_full_size: Vector3 = Vector3.ONE

var is_dying: bool = false

# ============================================================
# FOCUS SLOWDOWN
# ============================================================
@export_group("Focus Slowdown")
## Fraction of normal speed while the player is focusing on this NPC
## (1.0 = no slowdown, 0.0 = stopped). Also scales animation speed so
## the legs don't skate.
@export_range(0.0, 1.0) var focus_slow_multiplier: float = 0.3

## How quickly the NPC eases into / out of the slowdown.
@export var focus_slow_smoothing_time: float = 0.2

## Read by NPCBrain.move_toward_path() every frame.
var speed_multiplier: float = 1.0
var is_focused: bool = false

func set_focused(value: bool) -> void:
	is_focused = value

func set_brain(new_brain: NPCBrain):
	brain = new_brain

@export_group("Locomotion Animation")
## Animation names looked up on the AnimationPlayer. If one doesn't
## exist, play_animation() silently does nothing -- which is exactly how
## an NPC ends up stuck on Idle while walking -- so _ready() warns about
## any that are missing.
@export var idle_animation_name: String = "Idle"
@export var walk_animation_name: String = "Walk"
@export var run_animation_name: String = "Run"

## Real horizontal speed (measured from how far the NPC actually moved
## this physics frame, NOT commanded velocity) above which it counts as
## moving and gets walk/run. It only drops back to idle once speed falls
## below half of this, so brief stalls don't flicker the animation.
@export var moving_speed_threshold: float = 0.15

var actual_planar_speed: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _has_last_position: bool = false
var _is_moving: bool = false

# ============================================================
# PLAYER PROXIMITY LINE
# ============================================================
@export_group("Player Line")
@export var line_enabled: bool = true
## The line appears when the player is closer than this (world units).
@export var line_trigger_distance: float = 10.0
@export var line_thickness: float = 0.03
## Where the line starts, as an offset from the NPC's origin (e.g. eye height).
@export var line_start_offset: Vector3 = Vector3(0, 1.6, 0)
## Where the line ends, as an offset from the player's origin (e.g. chest height).
@export var line_end_offset: Vector3 = Vector3(0, 1.0, 0)
## While the line is being drawn, the NPC turns (left/right only) to face
## the player, and ignores the brain's rotation requests.
@export var face_player_when_line_drawn: bool = true

@export_subgroup("Colors")
## Color the line starts at the moment the NPC spots the player.
@export var line_safe_color: Color = Color.WHITE
## Color it flashes toward as detection builds up.
@export var line_alert_color: Color = Color(1.0, 0.15, 0.15)

@export_subgroup("Detection")
## Seconds the player can stay spotted (white line) before it starts
## flashing red as a warning.
@export var detection_warning_time: float = 2.0
## Total seconds of unbroken detection, counted from when the line first
## appears, before this NPC calls it in -- GameController.capture() fires
## and the round ends. Must be greater than detection_warning_time.
@export var detection_capture_time: float = 4.0
## How fast the red flash pulses right when the warning starts.
@export var flash_speed_min: float = 2.0
## How fast it pulses right before capture -- speeds up as the deadline
## approaches, same idea as the HUD's low-power flash.
@export var flash_speed_max: float = 8.0

@export_subgroup("Line of Sight")
## If true, an obstacle between the NPC and the player breaks the line
## (and resets detection) even within line_trigger_distance.
@export var require_clear_line_of_sight: bool = true
## Layers checked for obstructions -- should match your level geometry,
## not other NPCs/pickups/etc, or they'll block sight too.
@export_flags_3d_physics var line_of_sight_mask: int = 0xFFFFFFFF

var _line_mesh: MeshInstance3D
var _line_material: StandardMaterial3D
var _facing_player: bool = false
var _player_body: Node3D
var _warned_no_player_body: bool = false

var _detection_timer: float = 0.0
var _flash_time: float = 0.0
var _capture_triggered: bool = false

func _ready():
	_resolve_animation_player()
	if animation_player:
		_warn_missing_animations()
		_play(idle_animation_name)
	nav_agent.path_desired_distance = 1.0
	nav_agent.target_desired_distance = 1.0

	# Remember the decal's authored size as its FULL size, then hide it
	# until the NPC dies.
	if death_decal:
		_decal_full_size = death_decal.size
		death_decal.visible = false

	_create_player_line()

## Uses animation_player_path if it's set and valid; otherwise searches
## this NPC's children for the first AnimationPlayer. Without this, an
## unassigned path leaves animation_player null and every animation call
## silently does nothing.
func _resolve_animation_player() -> void:
	if not animation_player_path.is_empty():
		animation_player = get_node_or_null(animation_player_path) as AnimationPlayer

	if not animation_player:
		animation_player = _find_node_of_type(self, "AnimationPlayer") as AnimationPlayer
		if animation_player:
			push_warning("NPCInstance %s: animation_player_path missing/invalid -- auto-found AnimationPlayer at '%s'. Assign it in the Inspector to silence this." % [name, animation_player.get_path()])
		else:
			push_warning("NPCInstance %s: no AnimationPlayer found anywhere under this NPC -- animations cannot play." % name)
			return

	# An active AnimationTree drives the skeleton every frame and
	# overrides whatever AnimationPlayer.play() asks for.
	var tree := _find_node_of_type(self, "AnimationTree") as AnimationTree
	if tree and tree.active:
		push_warning("NPCInstance %s: an active AnimationTree ('%s') is present and will override AnimationPlayer.play() -- Idle/Walk from this script won't show." % [name, tree.get_path()])

func _find_node_of_type(root: Node, type_name: String) -> Node:
	for child in root.get_children():
		if child.is_class(type_name):
			return child
		var found := _find_node_of_type(child, type_name)
		if found:
			return found
	return null

func apply_velocity(new_velocity: Vector3):
	velocity.x = new_velocity.x
	velocity.z = new_velocity.z

func update_rotation_target(target_pos: Vector3):
	# While we're facing the player, don't let the brain turn us away.
	if _facing_player:
		return
	if (target_pos - global_position).length_squared() > 0.01:
		look_at(target_pos, Vector3.UP)

## Public entry point used by NPCBrain. Idle/Walk/Run are picked by this
## script itself from real movement (see _update_locomotion_animation),
## and jumping has been removed, so those requests are IGNORED here --
## this also keeps any leftover jump/locomotion calls in NPCBrain
## harmless. Anything else passes straight through.
func play_animation(animation_name: String):
	if animation_name in [idle_animation_name, walk_animation_name, run_animation_name, "Idle", "Walk", "Run", "Jump"]:
		return
	_play(animation_name)

func _play(animation_name: String):
	if animation_player and animation_player.has_animation(animation_name):
		if animation_player.current_animation != animation_name:
			animation_player.play(animation_name)

func _update_focus_slow(delta: float) -> void:
	var target: float = focus_slow_multiplier if is_focused else 1.0
	var weight: float = 1.0 - exp(-delta / max(focus_slow_smoothing_time, 0.001))
	speed_multiplier = lerpf(speed_multiplier, target, weight)

	# Slow the animations along with the movement.
	if animation_player:
		animation_player.speed_scale = speed_multiplier

func _physics_process(delta: float):
	if is_dying:
		return

	_update_focus_slow(delta)

	if not brain or not brain.npc_states.has(self):
		return

	var state: Dictionary = brain.npc_states[self]

	# While waiting the NPC must not move AT ALL. The brain zeroes
	# velocity too, but that runs in a different node's update, so it's
	# enforced here as well. On the floor it is fully planted -- no
	# gravity, no move_and_slide -- so slope sliding or leftover
	# velocity can't drift it. In the air it's allowed to fall, but
	# with no horizontal motion.
	var is_waiting: bool = state.waiting and not state.fleeing
	if is_waiting:
		velocity.x = 0.0
		velocity.z = 0.0
		if is_on_floor():
			velocity = Vector3.ZERO
			_update_locomotion_animation(delta)
			return

	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	var was_on_floor = is_on_floor()
	move_and_slide()

	if is_waiting:
		velocity.x = 0.0
		velocity.z = 0.0
	
	# Floor snapping
	if was_on_floor and not is_on_floor() and velocity.y <= 0:
		var snap = Vector3.DOWN * 0.2
		var snap_result = move_and_collide(snap, true)
		if snap_result:
			global_position = snap_result.get_position()

	_update_locomotion_animation(delta)

## Single owner of Idle/Walk/Run. Picks the animation from how far the
## NPC ACTUALLY moved this physics frame (position change, not commanded
## velocity), so an NPC that is being told to move but is blocked plays
## Idle steadily, and anything genuinely moving -- including being
## pushed or sliding -- plays Walk. Hysteresis stops it flickering
## around the threshold.
func _update_locomotion_animation(delta: float) -> void:
	var moved := Vector2(
		global_position.x - _last_position.x,
		global_position.z - _last_position.z
	)
	var had_last_position := _has_last_position
	_last_position = global_position
	_has_last_position = true

	# First frame after spawning: no previous position to compare with
	# (and the spawn teleport would read as a huge burst of speed).
	if not had_last_position:
		return

	actual_planar_speed = moved.length() / max(delta, 0.0001)

	var state: Dictionary = brain.npc_states[self]

	if _is_moving:
		if actual_planar_speed < moving_speed_threshold * 0.5:
			_is_moving = false
	elif actual_planar_speed > moving_speed_threshold:
		_is_moving = true

	if _is_moving:
		_play(run_animation_name if state.fleeing else walk_animation_name)
	else:
		_play(idle_animation_name)

func _warn_missing_animations() -> void:
	if not animation_player:
		return
	for anim_name in [idle_animation_name, walk_animation_name, run_animation_name]:
		if not animation_player.has_animation(anim_name):
			push_warning("NPCInstance %s: animation '%s' not found. Available: %s" % [
				name, anim_name, animation_player.get_animation_list()
			])

# ============================================================
# PLAYER PROXIMITY LINE
# ============================================================
func _create_player_line() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(line_thickness, line_thickness, 1.0)

	_line_material = StandardMaterial3D.new()
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.albedo_color = line_safe_color
	box.material = _line_material

	_line_mesh = MeshInstance3D.new()
	_line_mesh.mesh = box
	_line_mesh.top_level = true  # world-space: ignores the NPC's rotation/scale
	_line_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_line_mesh.visible = false
	add_child(_line_mesh)

func _process(delta: float) -> void:
	_update_player_line(delta)

## brain.player can point at the player scene's root, which doesn't move
## when the character does. This finds the physics body inside it that
## actually moves (or uses brain.player itself if it already is one), and
## caches the result.
func _get_player_body() -> Node3D:
	if is_instance_valid(_player_body):
		return _player_body
	if not is_instance_valid(brain) or not is_instance_valid(brain.player):
		return null

	var root: Node3D = brain.player
	if root is CharacterBody3D or root is RigidBody3D:
		_player_body = root
	else:
		_player_body = _find_node_of_type(root, "CharacterBody3D") as Node3D
		if not _player_body:
			_player_body = _find_node_of_type(root, "RigidBody3D") as Node3D

	if not _player_body:
		if not _warned_no_player_body:
			_warned_no_player_body = true
			push_warning("NPCInstance %s: no CharacterBody3D/RigidBody3D found under brain.player ('%s') -- using that node itself, which may not move with the player." % [name, root.get_path()])
		_player_body = root

	return _player_body

func _update_player_line(delta: float) -> void:
	_facing_player = false

	if not is_instance_valid(_line_mesh):
		return

	if _capture_triggered:
		return  # already called it in -- the round is ending

	if is_dying or not line_enabled:
		_line_mesh.visible = false
		_detection_timer = 0.0
		_flash_time = 0.0
		return

	var player := _get_player_body()
	if not player:
		_line_mesh.visible = false
		_detection_timer = 0.0
		_flash_time = 0.0
		return

	var from := global_position + line_start_offset
	var to := player.global_position + line_end_offset
	var dir := to - from
	var dist := dir.length()

	if dist > line_trigger_distance or dist < 0.01 or not _has_clear_line_of_sight(from, to, player):
		_line_mesh.visible = false
		_detection_timer = 0.0
		_flash_time = 0.0
		return

	dir /= dist
	# Avoid a degenerate basis when the line points straight up/down.
	var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
	var line_basis := Basis.looking_at(dir, up) * Basis.from_scale(Vector3(1.0, 1.0, dist))

	_line_mesh.global_transform = Transform3D(line_basis, (from + to) * 0.5)
	_line_mesh.visible = true

	if face_player_when_line_drawn:
		_face_position(player.global_position)

	_update_detection(delta)

## Turns the NPC left/right toward target_pos. The target is flattened to
## the NPC's own height so it never tilts up or down.
func _face_position(target_pos: Vector3) -> void:
	var flat_target := Vector3(target_pos.x, global_position.y, target_pos.z)
	if (flat_target - global_position).length_squared() > 0.01:
		look_at(flat_target, Vector3.UP)
		_facing_player = true

## Called by CombatController when this NPC's head hitbox is popped.
## Unregisters from the brain FIRST -- otherwise NPCBrain._physics_process
## keeps iterating over this instance next frame and throws
## "previously freed instance" errors once the NPC is actually removed.
## Freezes movement, plays the death animation and particle effect, grows
## the blood pool decal, then removes the NPC once the animation (or
## fallback delay) has played out.
func explode_head() -> void:
	if is_dying:
		return
	is_dying = true
	get_tree().call_group("game_timer", "register_kill", time_bonus_on_kill)
	is_focused = false
	speed_multiplier = 1.0
	_facing_player = false

	if is_instance_valid(_line_mesh):
		_line_mesh.visible = false

	# Stop moving immediately -- is_dying already blocks _physics_process
	# from running move_and_slide again, this just clears any velocity
	# that was already in flight this frame.
	velocity = Vector3.ZERO

	if brain:
		brain.npcs.erase(self)
		brain.npc_states.erase(self)
		remove_from_group("npcs")

	var wait_time: float = death_fallback_delay

	if animation_player:
		# Undo any focus slowdown so the death plays at normal speed.
		animation_player.speed_scale = 1.0
		if animation_player.has_animation(death_animation_name):
			animation_player.play(death_animation_name)
			wait_time = animation_player.get_animation(death_animation_name).length

	var has_particles := false
	for particles in death_particles:
		if is_instance_valid(particles) and "emitting" in particles:
			has_particles = true
			# Keep the NPC around until the longest-lived effect has
			# finished playing.
			var effect_time: float = particles_trigger_time
			if "lifetime" in particles:
				effect_time += particles.lifetime
			wait_time = max(wait_time, effect_time)

	if has_particles:
		if particles_trigger_time > 0.0:
			get_tree().create_timer(particles_trigger_time).timeout.connect(_emit_death_particles)
		else:
			_emit_death_particles()

	# A fixed grow time can run past the animation/particles -- keep the
	# NPC alive until the pool has finished growing.
	if is_instance_valid(death_decal) and decal_grow_time > 0.0:
		wait_time = max(wait_time, decal_trigger_time + decal_grow_time)

	# wait_time is now the full length of the death, so the pool can be
	# timed to finish growing exactly when the NPC is fully dead.
	_start_decal_growth(wait_time)

	await get_tree().create_timer(wait_time).timeout

	_leave_corpse()
	queue_free()

## Schedules the decal to appear at decal_trigger_time, then grow.
func _start_decal_growth(total_time: float) -> void:
	if not is_instance_valid(death_decal):
		return

	var grow_time: float
	if decal_grow_time > 0.0:
		grow_time = decal_grow_time
	else:
		# Fill whatever is left of the death after the trigger time.
		grow_time = max(total_time - decal_trigger_time, 0.01)

	if decal_trigger_time > 0.0:
		get_tree().create_timer(decal_trigger_time).timeout.connect(_begin_decal_growth.bind(grow_time))
	else:
		_begin_decal_growth(grow_time)

## Unhides the decal at a small size and grows its X/Z footprint to the
## full authored size. Eased out so the pool spreads quickly at first
## and slows as it settles.
func _begin_decal_growth(grow_time: float) -> void:
	if not is_instance_valid(death_decal):
		return

	death_decal.size = Vector3(
		_decal_full_size.x * decal_start_scale,
		_decal_full_size.y,
		_decal_full_size.z * decal_start_scale
	)
	death_decal.visible = true

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(death_decal, "size", _decal_full_size, max(grow_time, 0.01))

## Moves the corpse (body_to_keep) and the blood pool decal out of the NPC
## and into the current scene so they survive queue_free(). Global
## transforms are captured first and reapplied after reparenting, so
## nothing jumps or snaps.
func _leave_corpse() -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	if is_instance_valid(death_decal):
		# Guarantee the pool ends at exactly full size, whatever the tween did.
		death_decal.size = _decal_full_size
		# Skip if it already lives under the body being kept.
		var under_body: bool = is_instance_valid(body_to_keep) and body_to_keep.is_ancestor_of(death_decal)
		if not under_body:
			_reparent_keep_transform(death_decal, scene_root)

	if is_instance_valid(body_to_keep):
		_reparent_keep_transform(body_to_keep, scene_root)

func _reparent_keep_transform(node: Node3D, new_parent: Node) -> void:
	var saved_transform: Transform3D = node.global_transform
	node.get_parent().remove_child(node)
	new_parent.add_child(node)
	node.global_transform = saved_transform

func _emit_death_particles() -> void:
	for particles in death_particles:
		if is_instance_valid(particles) and "emitting" in particles:
			particles.emitting = true
			
## Checked in addition to line_trigger_distance -- an obstacle between the
## NPC and the player breaks the line even within range.
func _has_clear_line_of_sight(from: Vector3, to: Vector3, player_body: Node3D) -> bool:
	if not require_clear_line_of_sight:
		return true

	var space := get_world_3d().direct_space_state
	if not space:
		return true  # fail open rather than falsely block detection

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self, player_body]
	query.collision_mask = line_of_sight_mask
	var result := space.intersect_ray(query)
	return result.is_empty()


## Advances the detection clock while the line is showing: white while
## safe, flashing red (faster as the deadline nears) once past the
## warning time, and calls in the capture once the timer runs out.
func _update_detection(delta: float) -> void:
	_detection_timer += delta

	if _detection_timer < detection_warning_time:
		_line_material.albedo_color = line_safe_color
		_flash_time = 0.0
	else:
		var alert_progress: float = clampf(
			(_detection_timer - detection_warning_time) /
			max(detection_capture_time - detection_warning_time, 0.001),
			0.0, 1.0
		)
		var speed: float = lerpf(flash_speed_min, flash_speed_max, alert_progress)
		_flash_time += delta * speed
		var pulse: float = (sin(_flash_time * TAU) + 1.0) * 0.5
		_line_material.albedo_color = line_safe_color.lerp(line_alert_color, pulse)

	if _detection_timer >= detection_capture_time:
		_capture_triggered = true
		_line_mesh.visible = false
		get_tree().call_group("game_timer", "capture")
