extends Node
## Global signal hub. Systems talk through here rather than reaching for each other,
## so the HUD, audio, quests and AI can be added or removed independently.

# --- player ---------------------------------------------------------------
signal player_spawned(player: Node3D)
signal player_damaged(amount: float, source: Node)
signal player_healed(amount: float)
signal player_died
signal player_stat_changed(health: float, max_health: float, stamina: float, max_stamina: float)
signal player_state_changed(state: String)
signal footstep(surface: String, position: Vector3, speed: float)

# --- combat ---------------------------------------------------------------
signal arrow_fired(from: Vector3, dir: Vector3, charge: float)
signal melee_swing(index: int)
signal enemy_damaged(enemy: Node, amount: float, crit: bool, hit_pos: Vector3)
signal enemy_died(enemy: Node)
signal enemy_alerted(enemy: Node)
signal combat_state_changed(in_combat: bool)
signal hit_feedback(position: Vector3, strength: float, kind: String)

# --- world ----------------------------------------------------------------
signal location_discovered(id: String, display_name: String)
signal time_phase_changed(phase: String)
signal interact_target_changed(target: Node, prompt: String)

# --- items / quests / dialogue --------------------------------------------
signal item_gained(id: String, count: int)
signal item_lost(id: String, count: int)
signal quest_started(id: String)
signal quest_objective_changed(quest_id: String, objective_id: String, progress: int, total: int)
signal quest_objective_completed(quest_id: String, objective_id: String)
signal quest_completed(id: String)
signal dialogue_started(speaker: String, node_id: String)
signal dialogue_ended
signal notify(title: String, body: String, kind: String)

# --- system ---------------------------------------------------------------
signal game_saved(slot: int)
signal game_loaded(slot: int)
signal request_pause(paused: bool)

# --- dialogue / NPCs (appended by the NPC + dialogue system) ---------------
signal dialogue_node_entered(tree_id: String, node_id: String)
signal dialogue_choice_made(tree_id: String, node_id: String, index: int, text: String)
signal dialogue_event(name: String, source: String)
signal npc_greeted(npc_id: String, display_name: String, line: String)
signal npc_alarmed(npc_id: String, threat: Node)

# --- ui (appended by the interface layer) ----------------------------------
## Point the compass at something. `active` false clears the marker.
signal objective_marker_changed(position: Vector3, active: bool)
