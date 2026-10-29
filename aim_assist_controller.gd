extends Node3D
class_name AimAssistController

# --- AUTO-CONFIGURED PARAMETERS ---
@export_group("Auto Aim-Assist Settings")
@export var assist_enabled: bool = true
@export var fov_cone_degrees: float = 18.0      # Crosshair ke charo taraf active FOV cone
@export var max_lock_distance: float = 120.0    # Maximum weapon range (meters)
@export var rotation_smoothness: float = 12.0   # Lerp damping speed
@export var bullet_speed: float = 450.0         # Projectile speed (m/s) for lead prediction
@export var fire_action_name: String = "fire"   # InputMap action name

# --- INTERNAL AUTO-DISCOVERED REFERENCES ---
var camera: Camera3D = null
var local_character: CharacterBody3D = null
var _bone_cache: Dictionary = {} # { instance_id: { "skeleton": Skeleton3D, "bone_idx": int } }
var _angle_telemetry_buffer: Array[Vector2] = []
var _prev_cam_rot: Vector2 = Vector2.ZERO

const HEAD_BONE_CANDIDATES: PackedStringArray = [
	"Bip01_Head", "Head", "head", "mixamorig:Head", "bone_head"
]

# 1. AUTO-INITIALIZATION: Scene load hote hi apne aap references bind karta hai
func _ready() -> void:
	set_physics_process(true)
	_auto_bind_local_nodes()


func _auto_bind_local_nodes() -> void:
	# Parent CharacterBody3D ko automatically dhoondhna
	var parent_node: Node = get_parent()
	while parent_node != null:
		if parent_node is CharacterBody3D:
			local_character = parent_node
			break
		parent_node = parent_node.get_parent()

	if local_character and not local_character.is_in_group("ActivePlayers"):
		local_character.add_to_group("ActivePlayers")

	# Active Camera3D ko automatically viewport se grab karna
	camera = get_viewport().get_camera_3d()
	if camera:
		_prev_cam_rot = Vector2(camera.rotation.x, camera.rotation.y)


# 2. AUTO-EXECUTING GAME LOOP (Runs 60-120 times/sec automatically)
func _physics_process(delta: float) -> void:
	if not assist_enabled:
		return

	# Agar camera ya player reference missing hai toh auto-rebind karo
	if camera == null or not is_instance_valid(camera):
		camera = get_viewport().get_camera_3d()
		if camera == null:
			return

	if local_character == null or not is_instance_valid(local_character):
		_auto_bind_local_nodes()
		if local_character == null:
			return

	# Telemetry record karna (Anti-Cheat Validator ko feed karne ke liye)
	_record_camera_telemetry()

	# Check karo ki player fire kar raha hai ya touch drag kar raha hai
	if not _is_player_engaging():
		return

	var best_aim_point: Vector3 = Vector3.ZERO
	var smallest_angle_deg: float = fov_cone_degrees
	var has_valid_target: bool = false

	var cam_origin: Vector3 = camera.global_position
	var cam_forward: Vector3 = -camera.global_transform.basis.z.normalized()

	var active_players: Array[Node] = get_tree().get_nodes_in_group("ActivePlayers")

	for entity in active_players:
		if not is_instance_valid(entity) or entity == local_character:
			continue
		if not (entity is Node3D):
			continue

		# Dynamic property check (bina crash hue team_id aur health verify karna)
		var my_team: int = local_character.get("team_id") if "team_id" in local_character else -1
		var enemy_team: int = entity.get("team_id") if "team_id" in entity else -2
		var enemy_hp: float = entity.get("health") if "health" in entity else 100.0

		if (my_team != -1 and my_team == enemy_team) or enemy_hp <= 0.0:
			continue

		# Auto-Extract Head Bone World Position (with fallback to capsule top)
		var head_world_pos: Vector3 = _get_entity_head_world_pos(entity as Node3D)

		# 3D Euclidean Distance Check
		var distance: float = cam_origin.distance_to(head_world_pos)
		if distance > max_lock_distance or distance < 0.5:
			continue

		# Velocity Lead Prediction
		var entity_vel: Vector3 = entity.velocity if (entity is CharacterBody3D) else Vector3.ZERO
		var flight_time: float = distance / max(bullet_speed, 1.0)
		var predicted_pos: Vector3 = head_world_pos + (entity_vel * flight_time)

		# Dot Product FOV Cone Check
		var dir_to_target: Vector3 = (predicted_pos - cam_origin).normalized()
		var dot_product: float = clamp(cam_forward.dot(dir_to_target), -1.0, 1.0)
		var angle_from_crosshair: float = rad_to_deg(acos(dot_product))

		if angle_from_crosshair < smallest_angle_deg:
			if _is_line_of_sight_clear(cam_origin, head_world_pos, entity as Node3D):
				smallest_angle_deg = angle_from_crosshair
				best_aim_point = predicted_pos
				has_valid_target = true

	if has_valid_target:
		_rotate_camera_towards_point(cam_origin, best_aim_point, delta)


# Input Auto-Detection (Works with InputMap "fire" OR left mouse / mobile screen press)
func _is_player_engaging() -> bool:
	if local_character.has_method("is_firing_weapon"):
		return local_character.call("is_firing_weapon")
	if InputMap.has_action(fire_action_name) and Input.is_action_pressed(fire_action_name):
		return true
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


# Auto-Bone Scanner & Cache (Har frame find_bone chalane ka CPU overhead bachata hai)
func _get_entity_head_world_pos(entity: Node3D) -> Vector3:
	var inst_id: int = entity.get_instance_id()

	if not _bone_cache.has(inst_id):
		var found_skel: Skeleton3D = null
		var skeletons: Array[Node] = entity.find_children("*", "Skeleton3D", true, false)
		if not skeletons.is_empty():
			found_skel = skeletons[0] as Skeleton3D

		var found_idx: int = -1
		if found_skel != null:
			for bone_name in HEAD_BONE_CANDIDATES:
				found_idx = found_skel.find_bone(bone_name)
				if found_idx != -1:
					break

		_bone_cache[inst_id] = { "skeleton": found_skel, "bone_idx": found_idx }

	var cached: Dictionary = _bone_cache[inst_id]
	var skel: Skeleton3D = cached["skeleton"]
	var b_idx: int = cached["bone_idx"]

	if is_instance_valid(skel) and b_idx != -1:
		return skel.global_transform * skel.get_bone_global_pose(b_idx).origin

	# Fallback: Agar model mein Skeleton3D nahi hai, toh character origin se 1.5m upar Head maano
	return entity.global_position + Vector3(0.0, 1.5, 0.0)


func _is_line_of_sight_clear(from_pos: Vector3, to_pos: Vector3, target_entity: Node3D) -> bool:
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var ray_params := PhysicsRayQueryParameters3D.create(from_pos, to_pos)
	if local_character is CollisionObject3D:
		ray_params.exclude = [local_character.get_rid()]

	var hit_result: Dictionary = space_state.intersect_ray(ray_params)
	if hit_result.is_empty():
		return true
	return hit_result.collider == target_entity


func _rotate_camera_towards_point(cam_pos: Vector3, target_pos: Vector3, delta: float) -> void:
	var d: Vector3 = target_pos - cam_pos
	var horizontal_dist: float = sqrt((d.x * d.x) + (d.z * d.z))

	var target_yaw: float = atan2(-d.x, -d.z)
	var target_pitch: float = atan2(d.y, horizontal_dist)

	var blend_weight: float = 1.0 - exp(-rotation_smoothness * delta)
	camera.rotation.y = lerp_angle(camera.rotation.y, target_yaw, blend_weight)
	camera.rotation.x = clamp(
		lerp_angle(camera.rotation.x, target_pitch, blend_weight),
		deg_to_rad(-85.0),
		deg_to_rad(85.0)
	)


func _record_camera_telemetry() -> void:
	var curr_rot := Vector2(camera.rotation.x, camera.rotation.y)
	var delta_rot := curr_rot - _prev_cam_rot
	_prev_cam_rot = curr_rot

	if delta_rot.length_squared() > 0.000001:
		_angle_telemetry_buffer.append(delta_rot)
		if _angle_telemetry_buffer.size() >= 45:
			var validator = get_node_or_null("/root/ServerAntiCheatValidator")
			if validator and validator.has_method("analyze_camera_angle_telemetry"):
				var my_uid: String = str(local_character.get_instance_id())
				validator.analyze_camera_angle_telemetry(my_uid, _angle_telemetry_buffer.duplicate())
			_angle_telemetry_buffer.clear()
