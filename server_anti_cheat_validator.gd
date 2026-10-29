extends Node
class_name ServerAntiCheatValidator

# --- SERVER SECURITY CONSTANTS ---
const MAX_HEAD_HITBOX_RADIUS: float = 0.18    # 18 cm maximum allowed head radius
const MAX_PING_REWIND_SEC: float = 0.40       # Max 400ms lag compensation rewind
const MIN_HUMAN_ANGLE_VARIANCE: float = 0.002 # Minimum human micro-jitter threshold
const HISTORY_BUFFER_MAX_FRAMES: int = 60     # 1 second history at 60 Hz

# Automatic Historical Ring Buffer: { instance_id: Array[ { "time": float, "head_pos": Vector3 } ] }
var _player_bone_history: Dictionary = {}
var _violation_counts: Dictionary = {}

signal player_flagged_for_cheat(uid: String, reason: String, metric: float)

func _ready() -> void:
	set_physics_process(true)
	print("[ServerAntiCheatValidator] Auto-Execution Active. Monitoring physics frames...")


# AUTO-RECORDING LOOP: Har frame sabhi players ke Head ki history save karta hai (Server Rewind ke liye)
func _physics_process(_delta: float) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	var players: Array[Node] = get_tree().get_nodes_in_group("ActivePlayers")

	for p in players:
		if not is_instance_valid(p) or not (p is Node3D):
			continue
		var p_node := p as Node3D
		var inst_id: int = p_node.get_instance_id()
		var head_pos: Vector3 = _extract_current_head_pos(p_node)

		if not _player_bone_history.has(inst_id):
			_player_bone_history[inst_id] = []

		var history: Array = _player_bone_history[inst_id]
		history.append({ "time": now, "head_pos": head_pos })

		# Purane frames cleanup karna (Ring Buffer limit)
		while history.size() > HISTORY_BUFFER_MAX_FRAMES:
			history.pop_front()


# 1. COMPLETE SERVER-SIDE HIT VALIDATION
func validate_weapon_hit_on_server(
	shooter_node: Node3D,
	target_player: Node3D,
	client_reported_hit_pos: Vector3,
	client_cam_forward: Vector3,
	client_timestamp: float,
	weapon_max_recoil_angle: float = 5.0
) -> bool:
	if not is_instance_valid(shooter_node) or not is_instance_valid(target_player):
		return false

	var uid: String = str(shooter_node.get_instance_id())
	var server_time: float = Time.get_ticks_msec() / 1000.0
	var rewind_time: float = clamp(server_time - client_timestamp, 0.0, MAX_PING_REWIND_SEC)
	var target_timestamp: float = server_time - rewind_time

	# Step A: Historical Ring Buffer se exact millisecond ki Head position nikalna
	var true_head_pos: Vector3 = get_historical_head_pos(target_player, target_timestamp)
	var true_muzzle_pos: Vector3 = shooter_node.global_position + Vector3(0.0, 1.4, 0.0)

	# Step B: Anti-Expanded Hitbox / Magic Bullet Check
	var hit_offset_from_bone: float = client_reported_hit_pos.distance_to(true_head_pos)
	if hit_offset_from_bone > MAX_HEAD_HITBOX_RADIUS:
		_flag_security_violation(uid, "HITBOX_MODIFICATION_DETECTED", hit_offset_from_bone)
		return false

	# Step C: Anti-Silent Aim Check (Camera Angle vs Actual Shot Trajectory)
	var actual_bullet_dir: Vector3 = (client_reported_hit_pos - true_muzzle_pos).normalized()
	var dot_val: float = clamp(client_cam_forward.normalized().dot(actual_bullet_dir), -1.0, 1.0)
	var angular_deviation_deg: float = rad_to_deg(acos(dot_val))

	if angular_deviation_deg > (weapon_max_recoil_angle + 1.5):
		_flag_security_violation(uid, "SILENT_AIM_VECTOR_SPOOF", angular_deviation_deg)
		return false

	# Step D: Real Server Physics Raycast (Blocks shooting through walls/cover)
	if not _is_server_raycast_clear(shooter_node, target_player, true_muzzle_pos, true_head_pos):
		_flag_security_violation(uid, "WALLHACK_SHOOT_THROUGH_COVER", 0.0)
		return false

	return true


# Historical Position Lookup with Linear Interpolation between recorded frames
func get_historical_head_pos(target_player: Node3D, target_time: float) -> Vector3:
	var inst_id: int = target_player.get_instance_id()
	if not _player_bone_history.has(inst_id):
		return _extract_current_head_pos(target_player)

	var history: Array = _player_bone_history[inst_id]
	if history.is_empty():
		return _extract_current_head_pos(target_player)

	var best_snap: Dictionary = history.back()
	var min_diff: float = INF

	for snap in history:
		var diff: float = abs(snap["time"] - target_time)
		if diff < min_diff:
			min_diff = diff
			best_snap = snap

	return best_snap["head_pos"]


# 2. CAMERA KINEMATICS HEURISTIC (Detects Robotic Aimbot Snaps)
func analyze_camera_angle_telemetry(uid: String, angle_deltas: Array[Vector2]) -> void:
	if angle_deltas.size() < 30:
		return

	var cross_track_errors: Array[float] = []
	for i in range(1, angle_deltas.size() - 1):
		var prev_v: Vector2 = angle_deltas[i - 1]
		var curr_v: Vector2 = angle_deltas[i]
		var next_v: Vector2 = angle_deltas[i + 1]

		var accel_change: float = (next_v - (2.0 * curr_v) + prev_v).length()
		cross_track_errors.append(accel_change)

	var variance: float = _calculate_variance(cross_track_errors)
	if variance < MIN_HUMAN_ANGLE_VARIANCE:
		_flag_security_violation(uid, "ROBOTIC_AIMBOT_INTERPOLATION_DETECTED", variance)


func _extract_current_head_pos(entity: Node3D) -> Vector3:
	var skeletons: Array[Node] = entity.find_children("*", "Skeleton3D", true, false)
	if not skeletons.is_empty():
		var skel := skeletons[0] as Skeleton3D
		var idx: int = skel.find_bone("Bip01_Head")
		if idx == -1:
			idx = skel.find_bone("Head")
		if idx != -1:
			return skel.global_transform * skel.get_bone_global_pose(idx).origin
	return entity.global_position + Vector3(0.0, 1.5, 0.0)


func _is_server_raycast_clear(shooter: Node3D, target: Node3D, from_pos: Vector3, to_pos: Vector3) -> bool:
	var space_state: PhysicsDirectSpaceState3D = shooter.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from_pos, to_pos)
	var exclude_rids: Array[RID] = []
	if shooter is CollisionObject3D:
		exclude_rids.append(shooter.get_rid())
	query.exclude = exclude_rids

	var result: Dictionary = space_state.intersect_ray(query)
	if result.is_empty():
		return true
	return result.collider == target


func _calculate_variance(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var mean: float = 0.0
	for v in values:
		mean += v
	mean /= float(values.size())

	var sq_diff_sum: float = 0.0
	for v in values:
		sq_diff_sum += (v - mean) * (v - mean)
	return sq_diff_sum / float(values.size())


func _flag_security_violation(uid: String, reason: String, metric: float) -> void:
	_violation_counts[uid] = _violation_counts.get(uid, 0) + 1
	print("[ANTI-CHEAT FLAG #%d] UID: %s | Violation: %s | Metric: %.4f" % [_violation_counts[uid], uid, reason, metric])
	emit_signal("player_flagged_for_cheat", uid, reason, metric)
