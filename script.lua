-- Проверка зависимостей
local function check_dependencies()
    local status = true
    local function log_dep(dep, loaded)
        if not loaded then
            client.log("Error: Missing dependency ", dep)
            status = false
        end
    end
    log_dep("ffi", pcall(require, "ffi"))
    log_dep("vector", pcall(require, "vector"))
    log_dep("gamesense/trace", pcall(require, "gamesense/trace"))
    return status
end
if not check_dependencies() then
    client.log("Error: Missing dependencies, script may not work correctly")
    return
end

local ffi = require("ffi")
local math = require("math")
local table = require("table")
local vector = require("vector")
local trace = require("gamesense/trace")

-- Утилитные функции
local function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

local function normalize_angle(angle)
    if not angle or type(angle) ~= "number" then return 0 end
    angle = angle % 360
    return angle > 180 and (angle - 360) or (angle < -180 and (angle + 360) or angle)
end

local function angle_difference(dest, src)
    local delta = math.fmod(dest - src, 360)
    return delta > 180 and (delta - 360) or (delta <= -180 and (delta + 360) or delta)
end

local function angle_to_vector(pitch, yaw)
    if not pitch or not yaw then return 0, 0, 0 end
    local p, y = math.rad(pitch), math.rad(yaw)
    local sp, cp, sy, cy = math.sin(p), math.cos(p), math.sin(y), math.cos(y)
    return cp * cy, cp * sy, -sp
end

local function vector_to_angle(a, b)
    local delta = a - b
    local hyp = delta:length2d()
    local angles = {}
    angles.y = math.atan(delta.y / delta.x) * 57.2957795131
    angles.x = math.atan(delta.z / hyp) * 57.2957795131
    angles.z = 0
    if delta.x >= 0 then angles.y = angles.y + 180 end
    return angles
end

local function time_to_ticks(t)
    return math.floor(0.5 + (t / globals.tickinterval()))
end

-- Цветовая схема
local function accent()
    return 0, 255, 0, 255
end

-- FFI определения
ffi.cdef[[
    struct animstate {
        char pad0[0x18];
        float anim_update_timer;
        char pad1[0xC];
        float started_moving_time;
        float last_move_time;
        char pad2[0x10];
        float last_lby_time;
        char pad3[0x8];
        float run_amount;
        char pad4[0x10];
        void* entity;
        void* active_weapon;
        void* last_active_weapon;
        float last_client_side_animation_update_time;
        int last_client_side_animation_update_framecount;
        float eye_timer;
        float eye_angles_y;
        float eye_angles_x;
        float goal_feet_yaw;
        float current_feet_yaw;
        float torso_yaw;
        float last_move_yaw;
        float lean_amount;
        char pad5[0x4];
        float feet_cycle;
        float feet_yaw_rate;
        char pad6[0x4];
        float duck_amount;
        float landing_duck_amount;
        char pad7[0x4];
        float current_origin[3];
        float last_origin[3];
        float velocity_x;
        float velocity_y;
        char pad8[0x4];
        float unknown_float1;
        char pad9[0x8];
        float unknown_float2;
        float unknown_float3;
        float unknown;
        float m_velocity;
        float jump_fall_velocity;
        float clamped_velocity;
        float feet_speed_forwards_or_sideways;
        float feet_speed_unknown_forwards_or_sideways;
        float last_time_started_moving;
        float last_time_stopped_moving;
        bool on_ground;
        bool hit_in_ground_animation;
        char pad10[0x4];
        float time_since_in_air;
        float last_origin_z;
        float head_from_ground_distance_standing;
        float stop_to_full_running_fraction;
        char pad11[0x4];
        float magic_fraction;
        char pad12[0x3C];
        float world_force;
        char pad13[0x1CA];
        float min_yaw;
        float max_yaw;
    };

    struct animlayer {
        char pad_0x0000[0x18];
        uint32_t sequence;
        float prev_cycle;
        float weight;
        float weight_delta_rate;
        float playback_rate;
        float cycle;
        void *entity;
        char pad_0x0038[0x4];
    };
]]

local VTable = {
    get_entry = function(instance, index, type)
        return ffi.cast(type, ffi.cast("void***", instance)[0][index])
    end,
    bind = function(self, module, interface, index, typestring)
        local instance = client.create_interface(module, interface)
        if not instance then
            client.log("Error: Failed to create interface ", module, ":", interface)
            return nil
        end
        local fnptr = self.get_entry(instance, index, ffi.typeof(typestring))
        return function(...) return fnptr(instance, ...) end
    end
}

local get_client_entity = VTable:bind("client.dll", "VClientEntityList003", 3, "void*(__thiscall*)(void*, int)") or function() return nil end

local function get_animation_state(player)
    if not player then return nil end
    local address = type(player) == "cdata" and player or get_client_entity(player)
    if not address or address == ffi.NULL then return nil end
    return ffi.cast("struct animstate*", ffi.cast("char*", ffi.cast("void***", address)) + 39264)[0]
end

local function get_simulation_time(player)
    local pointer = get_client_entity(player)
    if pointer then
        return entity.get_prop(player, "m_flSimulationTime") or 0, ffi.cast("float*", ffi.cast("uintptr_t", pointer) + 620)[0]
    end
    return 0
end

local function get_animation_layers(player, layer)
    local pointer = get_client_entity(player)
    if pointer then
        local anim_layers = ffi.cast("struct animlayer*", ffi.cast("char*", ffi.cast("void***", pointer)) + 14612)
        return layer and anim_layers[layer] or anim_layers
    end
    return nil
end

local function is_player_valid(player)
    return player and entity.is_alive(player) and not entity.is_dormant(player)
end

-- Новый резолвер
local max_history = 256
local desync_threshold = 10
local jitter_threshold = 18
local max_desync_history = 128
local update_interval = 0.002
local teleport_threshold = 120
local sim_time_anomaly_threshold = 0.025
local max_misses = 1
local fov_threshold = 65
local max_yaw_delta = 180
local max_pitch_delta = 90
local tickrate = 64
local hideshot_threshold = 0.02
local air_crouch_threshold = 0.2
local ping_threshold = 70
local max_velocity = 450
local max_anim_layers = 13
local min_sim_time_delta = 0.006
local max_hitbox_shift = 4
local lag_spike_threshold = 0.04

json.encode_number_precision(6)
json.encode_sparse_array(true, 2, 10)

local resolver = {
    player_records = {},
    last_simulation_time = {},
    last_update = globals.realtime(),
    last_valid_tick = globals.tickcount()
}

local function create_circular_buffer(size)
    local buffer = { size = size, data = {}, head = 0 }
    function buffer:push(item)
        self.head = (self.head % self.size) + 1
        self.data[self.head] = item
    end
    function buffer:get(index)
        return self.data[(self.head - index + self.size) % self.size + 1]
    end
    function buffer:len()
        return math.min(#self.data, self.size)
    end
    return buffer
end

local function update_tickrate()
    local interval = globals.tickinterval()
    tickrate = interval > 0 and math.floor(1 / interval) or 64
end

local function is_server_lagging()
    local current_tick = globals.tickcount()
    local tick_delta = current_tick - resolver.last_valid_tick
    resolver.last_valid_tick = current_tick
    return tick_delta > (tickrate * lag_spike_threshold)
end

local function get_targets()
    local targets = {}
    local local_player = entity.get_local_player()
    if not local_player or not entity.is_alive(local_player) then return targets end
    local lx, ly, lz = entity.get_prop(local_player, "m_vecOrigin")
    if not lx or not ly or not lz then return targets end
    local view_angles = {client.camera_angles()}
    if not view_angles[2] then return targets end
    
    for _, player in ipairs(entity.get_players(true)) do
        if entity.is_alive(player) and not entity.is_dormant(player) then
            local px, py, pz = entity.get_prop(player, "m_vecOrigin")
            if px and py and pz then
                local dx, dy = px - lx, py - ly
                local angle = math.deg(math.atan2(dy, dx)) - view_angles[2]
                angle = ((angle % 360 + 540) % 360 - 180)
                if math.abs(angle) <= fov_threshold then
                    table.insert(targets, {player = player, angle = math.abs(angle)})
                end
            end
        end
    end
    table.sort(targets, function(a, b) return a.angle < b.angle end)
    local sorted = {}
    for _, t in ipairs(targets) do table.insert(sorted, t.player) end
    return sorted
end

local function get_hitbox_position(player, hitbox)
    local x, y, z = entity.hitbox_position(player, hitbox)
    return x and {x = x, y = y, z = z} or nil
end

local function calculate_velocity(player)
    local vx, vy, vz = entity.get_prop(player, "m_vecVelocity")
    if not vx or not vy or not vz then return 0, {x = 0, y = 0, z = 0} end
    local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    return speed < max_velocity and speed or 0, {x = vx, y = vy, z = vz}
end

local function calculate_distance(pos1, pos2)
    if not pos1 or not pos2 then return math.huge end
    local dx, dy, dz = pos1.x - pos2.x, pos1.y - pos2.y, pos1.z - pos2.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function is_player_valid_steam(steam_id)
    for _, player in ipairs(entity.get_all("CCSPlayer")) do
        if entity.get_steam64(player) == steam_id then
            return true
        end
    end
    return false
end

local function analyze_anim_layers(player)
    local layer_data = {}
    for i = 0, max_anim_layers - 1 do
        local weight = entity.get_prop(player, "m_AnimOverlay", i) or 0
        if weight > 0 then
            table.insert(layer_data, {index = i, weight = weight})
        end
    end
    return layer_data
end

local function detect_anti_aim_type(records)
    if records.last_angles:len() < 5 then return "none" end

    local yaw_deltas = {}
    local pitch_deltas = {}
    local max_yaw_delta = 0
    local max_pitch_delta = 0
    local sim_time_deltas = {}
    local position_changes = {}
    local tick_deltas = {}
    local body_yaw_deltas = {}
    local crouch_states = {}
    local air_states = {}
    local anim_changes = {}
    local move_states = {}
    local anim_layer_changes = {}
    local velocity_changes = {}
    local duck_speed_changes = {}
    local tick_base_changes = {}
    for i = 2, records.last_angles:len() do
        local curr, prev = records.last_angles:get(i-1), records.last_angles:get(i)
        if not curr or not prev then return "none" end
        local yaw_delta = math.abs(curr.angles[2] - prev.angles[2])
        local pitch_delta = math.abs(curr.angles[1] - prev.angles[1])
        yaw_delta = math.min(yaw_delta, max_yaw_delta)
        pitch_delta = math.min(pitch_delta, max_pitch_delta)
        yaw_deltas[i-1] = yaw_delta
        pitch_deltas[i-1] = pitch_delta
        max_yaw_delta = math.max(max_yaw_delta, yaw_delta)
        max_pitch_delta = math.max(max_pitch_delta, pitch_delta)
        sim_time_deltas[i-1] = curr.sim_time - prev.sim_time
        tick_deltas[i-1] = curr.tick - prev.tick
        if curr.hitbox_pos and prev.hitbox_pos then
            position_changes[i-1] = calculate_distance(curr.hitbox_pos, prev.hitbox_pos)
        else
            position_changes[i-1] = 0
        end
        local body_yaw = entity.get_prop(curr.player, "m_flPoseParameter", 11) or 0
        local prev_body_yaw = entity.get_prop(prev.player, "m_flPoseParameter", 11) or 0
        body_yaw_deltas[i-1] = math.abs(body_yaw - prev_body_yaw) * 180
        crouch_states[i-1] = (entity.get_prop(curr.player, "m_flDuckAmount") or 0) > air_crouch_threshold
        air_states[i-1] = bit.band(entity.get_prop(curr.player, "m_fFlags") or 1, 1) == 0
        anim_changes[i-1] = curr.anim_state ~= prev.anim_state
        move_states[i-1] = curr.velocity > 15
        local curr_layers = analyze_anim_layers(curr.player)
        local prev_layers = analyze_anim_layers(prev.player)
        anim_layer_changes[i-1] = #curr_layers ~= #prev_layers or curr_layers[1] and prev_layers[1] and curr_layers[1].weight ~= prev_layers[1].weight
        velocity_changes[i-1] = math.abs(curr.velocity - prev.velocity)
        duck_speed_changes[i-1] = math.abs((entity.get_prop(curr.player, "m_flDuckSpeed") or 0) - (entity.get_prop(prev.player, "m_flDuckSpeed") or 0))
        tick_base_changes[i-1] = math.abs((entity.get_prop(curr.player, "m_nTickBase") or 0) - (entity.get_prop(prev.player, "m_nTickBase") or 0))
    end

    local avg_yaw_delta, weighted_yaw_delta = 0, 0
    for i, delta in ipairs(yaw_deltas) do
        avg_yaw_delta = avg_yaw_delta + delta
        weighted_yaw_delta = weighted_yaw_delta + delta * (1 - (i-1) / #yaw_deltas)
    end
    avg_yaw_delta = avg_yaw_delta / #yaw_deltas
    weighted_yaw_delta = weighted_yaw_delta / (#yaw_deltas * 0.5)

    local avg_sim_time = 0
    for _, delta in ipairs(sim_time_deltas) do
        avg_sim_time = avg_sim_time + delta
    end
    avg_sim_time = avg_sim_time / #sim_time_deltas

    local avg_tick_delta = 0
    for _, delta in ipairs(tick_deltas) do
        avg_tick_delta = avg_tick_delta + delta
    end
    avg_tick_delta = avg_tick_delta / #tick_deltas

    local avg_body_yaw_delta = 0
    for _, delta in ipairs(body_yaw_deltas) do
        avg_body_yaw_delta = avg_body_yaw_delta + delta
    end
    avg_body_yaw_delta = avg_body_yaw_delta / #body_yaw_deltas

    local avg_velocity_change = 0
    for _, delta in ipairs(velocity_changes) do
        avg_velocity_change = avg_velocity_change + delta
    end
    avg_velocity_change = avg_velocity_change / #velocity_changes

    local avg_duck_speed_change = 0
    for _, delta in ipairs(duck_speed_changes) do
        avg_duck_speed_change = avg_duck_speed_change + delta
    end
    avg_duck_speed_change = avg_duck_speed_change / #duck_speed_changes

    local avg_tick_base_change = 0
    for _, delta in ipairs(tick_base_changes) do
        avg_tick_base_change = avg_tick_base_change + delta
    end
    avg_tick_base_change = avg_tick_base_change / #tick_base_changes

    local crouch_changes = 0
    local air_crouch_count = 0
    local anim_change_count = 0
    local move_changes = 0
    local anim_layer_change_count = 0
    for i = 2, #crouch_states do
        if crouch_states[i] ~= crouch_states[i-1] then
            crouch_changes = crouch_changes + 1
        end
        if crouch_states[i] and air_states[i] then
            air_crouch_count = air_crouch_count + 1
        end
        if anim_changes[i-1] then
            anim_change_count = anim_change_count + 1
        end
        if move_states[i] ~= move_states[i-1] then
            move_changes = move_changes + 1
        end
        if anim_layer_changes[i-1] then
            anim_layer_change_count = anim_layer_change_count + 1
        end
    end

    local ping = entity.get_prop(records.last_angles:get(1) and records.last_angles:get(1).player or 0, "m_iPing") or 0
    local ping_factor = ping > ping_threshold and 1.1 or 1.0

    local is_teleporting = false
    for _, dist in ipairs(position_changes) do
        if dist > teleport_threshold then
            is_teleporting = true
            break
        end
    end

    if is_server_lagging() then
        return "lag_spike"
    elseif is_teleporting then
        return "teleport"
    elseif max_yaw_delta > jitter_threshold * ping_factor or avg_body_yaw_delta > 40 then
        return "jitter"
    elseif avg_yaw_delta > desync_threshold * ping_factor or avg_body_yaw_delta > 15 then
        return "desync"
    elseif avg_sim_time < sim_time_anomaly_threshold or avg_tick_delta > 0.8 or avg_tick_base_change > 2 then
        return "fakelag"
    elseif max_yaw_delta > 55 * ping_factor then
        return "spinbot"
    elseif avg_yaw_delta > 6 and records.shot_records:len() > 4 then
        return "custom"
    elseif avg_body_yaw_delta > 7 then
        return "micro_jitter"
    elseif max_pitch_delta > 25 then
        return "fake_pitch"
    elseif crouch_changes > 2 and air_crouch_count > 1 then
        return "air_crouch"
    elseif anim_change_count > 2 and avg_sim_time < hideshot_threshold or anim_layer_change_count > 2 then
        return "hideshot"
    elseif avg_yaw_delta > 1.5 and avg_yaw_delta <= 5 then
        return "low_delta"
    elseif move_changes > 2 and avg_body_yaw_delta > 10 or avg_velocity_change > 50 then
        return "defensive"
    elseif avg_body_yaw_delta > 25 and avg_sim_time < 0.025 then
        return "fake_lby"
    elseif max_yaw_delta > 35 and avg_yaw_delta < 10 then
        return "adaptive_jitter"
    elseif avg_duck_speed_change > 1 and crouch_changes > 3 then
        return "fake_duck"
    elseif avg_body_yaw_delta > 20 and max_yaw_delta > 50 then
        return "dynamic_lby"
    elseif avg_tick_base_change > 3 and avg_sim_time < 0.03 then
        return "fake_spin"
    end
    return "static"
end

local function predict_desync(player, steam_id, records, aa_type)
    if records.last_angles:len() < 3 then return records.learned_side end

    local yaw_deltas = {}
    local max_delta = 0
    for i = 2, records.last_angles:len() do
        local curr, prev = records.last_angles:get(i-1), records.last_angles:get(i)
        if not curr or not prev then return records.learned_side end
        local delta = math.abs(curr.angles[2] - prev.angles[2])
        delta = math.min(delta, max_yaw_delta)
        yaw_deltas[i-1] = delta
        max_delta = math.max(max_delta, delta)
    end

    local velocity, velocity_vec = calculate_velocity(player)
    local is_moving = velocity > 15 and velocity < max_velocity
    local side = records.learned_side or (globals.tickcount() % 2 == 0 and 1 or -1)

    local angle_to_velocity = 0
    if velocity_vec.x ~= 0 or velocity_vec.y ~= 0 then
        angle_to_velocity = math.deg(math.atan2(velocity_vec.y, velocity_vec.x)) - (records.last_angles:get(1) and records.last_angles:get(1).angles[2] or 0)
        angle_to_velocity = ((angle_to_velocity % 360 + 540) % 360 - 180)
    end

    local avg_delta = 0
    for _, delta in ipairs(yaw_deltas) do
        avg_delta = avg_delta + delta
    end
    avg_delta = avg_delta / #yaw_deltas

    local ping = entity.get_prop(player, "m_iPing") or 0
    local ping_factor = ping > ping_threshold and 1.1 or 1.0

    local pattern_score = 0
    local pattern_length = math.min(records.desync_history:len(), 20)
    for i = 1, pattern_length do
        local s = records.desync_history:get(i)
        if s then
            pattern_score = pattern_score + s * (1 - (i-1) / pattern_length)
        end
    end

    local anim_layers = analyze_anim_layers(player)
    local layer_weight_sum = 0
    for _, layer in ipairs(anim_layers) do
        layer_weight_sum = layer_weight_sum + layer.weight
    end

    if aa_type == "lag_spike" then
        side = records.learned_side or (globals.tickcount() % 2 == 0 and 1 or -1)
    elseif aa_type == "teleport" then
        side = (records.missed_shots + globals.tickcount()) % 2 == 0 and 1 or -1
    elseif aa_type == "jitter" or aa_type == "micro_jitter" or aa_type == "adaptive_jitter" then
        side = yaw_deltas[#yaw_deltas] > 0 and 1 or -1
        if records.desync_history:len() > 8 then
            side = pattern_score >= 0 and 1 or -1
        end
        records.desync_history:push(side)
    elseif aa_type == "desync" then
        if avg_delta > desync_threshold * ping_factor or is_moving then
            side = yaw_deltas[#yaw_deltas] > 0 and 1 or -1
            if math.abs(angle_to_velocity) > 30 then
                side = side * -1
            end
            if records.desync_history:len() > 8 then
                side = pattern_score >= 0 and 1 or -1
            end
            records.desync_history:push(side)
        end
    elseif aa_type == "spinbot" or aa_type == "fake_spin" then
        side = records.desync_history:get(1) or (globals.tickcount() % 2 == 0 and 1 or -1)
    elseif aa_type == "fakelag" then
        side = (records.missed_shots + globals.tickcount()) % 3 == 0 and 1 or -1
    elseif aa_type == "custom" then
        side = records.missed_shots % 2 == 0 and 1 or -1
        if records.desync_history:len() > 8 then
            side = pattern_score >= 0 and 1 or -1
        end
        records.desync_history:push(side)
    elseif aa_type == "fake_pitch" then
        side = (globals.tickcount() % 4 < 2) and 1 or -1
    elseif aa_type == "air_crouch" then
        side = (entity.get_prop(player, "m_flDuckAmount") or 0) > air_crouch_threshold and 1 or -1
        records.desync_history:push(side)
    elseif aa_type == "hideshot" then
        side = records.anim_state % 2 == 0 and 1 or -1
        if layer_weight_sum > 1.2 then
            side = layer_weight_sum % 2 < 1 and 1 or -1
        end
        if records.desync_history:len() > 8 then
            side = pattern_score >= 0 and 1 or -1
        end
        records.desync_history:push(side)
    elseif aa_type == "low_delta" then
        side = avg_delta > 4 and 1 or -1
        records.desync_history:push(side)
    elseif aa_type == "defensive" then
        side = is_moving and (angle_to_velocity > 0 and 1 or -1) or (records.missed_shots % 2 == 0 and 1 or -1)
        if records.desync_history:len() > 8 then
            side = pattern_score >= 0 and 1 or -1
        end
        records.desync_history:push(side)
    elseif aa_type == "fake_lby" or aa_type == "dynamic_lby" then
        side = (records.missed_shots + globals.tickcount()) % 2 == 0 and 1 or -1
        records.desync_history:push(side)
    elseif aa_type == "fake_duck" then
        side = (entity.get_prop(player, "m_flDuckSpeed") or 0) > 1 and 1 or -1
        records.desync_history:push(side)
    end

    if records.desync_history:len() > max_desync_history then
        records.desync_history:push(nil)
    end

    local side_count = pattern_score >= 0 and 1 or -1
    return side_count
end

local function smooth_angle(current, target, factor)
    local delta = ((target - current) % 360 + 540) % 360 - 180
    return current + delta * factor
end

local function adjust_hitbox_position(hitbox_pos, aa_type, duck_amount, is_airborne)
    if not hitbox_pos then return nil end
    local adjusted = {x = hitbox_pos.x, y = hitbox_pos.y, z = hitbox_pos.z}
    if aa_type == "air_crouch" and is_airborne and duck_amount > air_crouch_threshold then
        adjusted.z = adjusted.z - max_hitbox_shift * duck_amount
    elseif aa_type == "defensive" and duck_amount > 0.1 then
        adjusted.z = adjusted.z - max_hitbox_shift * 0.2 * duck_amount
    elseif aa_type == "fake_duck" or aa_type == "fake_lby" or aa_type == "dynamic_lby" then
        adjusted.z = adjusted.z - max_hitbox_shift * 0.4
    elseif aa_type == "adaptive_jitter" or aa_type == "fake_spin" then
        adjusted.z = adjusted.z - max_hitbox_shift * 0.15
    end
    return adjusted
end

function resolver.record_player(player)
    if not ui.get(resolver.enabled) or not entity.is_alive(player) then return end

    local steam_id = entity.get_steam64(player)
    if not steam_id then return end

    if not resolver.player_records[steam_id] then
        resolver.player_records[steam_id] = {
            last_angles = create_circular_buffer(max_history),
            desync_history = create_circular_buffer(max_desync_history),
            shot_records = create_circular_buffer(16),
            missed_shots = 0,
            learned_side = nil,
            last_valid_pos = nil,
            last_yaw = nil,
            aa_type = "none",
            last_teleport_time = 0,
            anomaly_detected = false,
            last_valid_sim_time = 0,
            last_anim_state = 0,
            last_move_state = false,
            last_anim_layers = {}
        }
        resolver.last_simulation_time[steam_id] = 0
    end

    local sim_time = entity.get_prop(player, "m_flSimulationTime") or 0
    if sim_time <= 0 or (resolver.last_simulation_time[steam_id] and sim_time <= resolver.last_simulation_time[steam_id]) or math.abs(sim_time - (resolver.last_simulation_time[steam_id] or 0)) > 1 or math.abs(sim_time - (resolver.last_simulation_time[steam_id] or 0)) < min_sim_time_delta then
        return
    end

    local eye_angles = {entity.get_prop(player, "m_angEyeAngles")}
    if not eye_angles[1] or not eye_angles[2] or math.abs(eye_angles[2]) > max_yaw_delta or math.abs(eye_angles[1]) > max_pitch_delta then
        return
    end

    local hitbox_pos = get_hitbox_position(player, 0)
    local velocity, velocity_vec = calculate_velocity(player)
    local records = resolver.player_records[steam_id]
    if hitbox_pos then
        if records.last_valid_pos and calculate_distance(records.last_valid_pos, hitbox_pos) > teleport_threshold then
            records.last_teleport_time = globals.realtime()
            records.anomaly_detected = true
        end
        records.last_valid_pos = hitbox_pos
    end

    local anim_state = entity.get_prop(player, "m_nPlayerAnimState") or 0
    local anim_layers = analyze_anim_layers(player)
    records.last_angles:push({
        angles = eye_angles,
        sim_time = sim_time,
        hitbox_pos = records.last_valid_pos,
        tick = globals.tickcount(),
        player = player,
        anim_state = anim_state,
        velocity = velocity,
        anim_layers = anim_layers
    })

    records.aa_type = detect_anti_aim_type(records)
    resolver.last_simulation_time[steam_id] = sim_time
    records.last_valid_sim_time = sim_time
    records.last_anim_state = anim_state
    records.last_move_state = velocity > 15
    records.last_anim_layers = anim_layers

    if records.aa_type == "lag_spike" or records.aa_type == "teleport" or records.aa_type == "fakelag" or records.aa_type == "custom" or records.aa_type == "fake_pitch" or records.aa_type == "hideshot" or records.aa_type == "air_crouch" or records.aa_type == "defensive" or records.aa_type == "fake_lby" or records.aa_type == "adaptive_jitter" or records.aa_type == "fake_duck" or records.aa_type == "dynamic_lby" or records.aa_type == "fake_spin" then
        records.anomaly_detected = true
    end
end

function resolver.resolve_angles(player)
    if not ui.get(resolver.enabled) then return end

    local steam_id = entity.get_steam64(player)
    if not steam_id or not resolver.player_records[steam_id] then return end

    local records = resolver.player_records[steam_id]
    if records.last_angles:len() < 2 then return end

    local aa_type = records.aa_type
    records.learned_side = predict_desync(player, steam_id, records, aa_type)
    local base_angle = records.last_angles:get(1) and records.last_angles:get(1).angles[2] or 0
    local resolve_angle = base_angle

    local ping = entity.get_prop(player, "m_iPing") or 0
    local ping_factor = ping > ping_threshold and 1.1 or 1.0
    local duck_amount = entity.get_prop(player, "m_flDuckAmount") or 0
    local is_airborne = bit.band(entity.get_prop(player, "m_fFlags") or 1, 1) == 0
    local velocity = calculate_velocity(player)

    if records.learned_side then
        local desync_amount = aa_type == "lag_spike" and 85 or aa_type == "spinbot" and 105 or aa_type == "teleport" and 125 or aa_type == "fakelag" and 95 or aa_type == "custom" and 85 or aa_type == "micro_jitter" and 30 or aa_type == "air_crouch" and 70 or aa_type == "hideshot" and 80 or aa_type == "low_delta" and 15 or aa_type == "fake_pitch" and 45 or aa_type == "defensive" and 90 or aa_type == "fake_lby" and 100 or aa_type == "adaptive_jitter" and 60 or aa_type == "fake_duck" and 75 or aa_type == "dynamic_lby" and 95 or aa_type == "fake_spin" and 110 or 45
        desync_amount = desync_amount * (1 + math.min(records.missed_shots * 0.3, 1.5)) * ping_factor
        desync_amount = math.min(desync_amount, aa_type == "spinbot" and 165 or aa_type == "teleport" and 155 or aa_type == "lag_spike" and 125 or aa_type == "fake_spin" and 160 or 125)
        if aa_type == "air_crouch" and is_airborne and duck_amount > air_crouch_threshold then
            desync_amount = desync_amount * 1.15
        elseif aa_type == "defensive" and duck_amount > 0.1 then
            desync_amount = desync_amount * 1.05
        elseif aa_type == "fake_duck" or aa_type == "fake_lby" or aa_type == "dynamic_lby" then
            desync_amount = desync_amount * 1.2
        elseif aa_type == "hideshot" and #records.last_anim_layers > 2 then
            desync_amount = desync_amount * 1.03
        elseif aa_type == "adaptive_jitter" or aa_type == "fake_spin" then
            desync_amount = desync_amount * 1.08
        elseif velocity > 140 then
            desync_amount = desync_amount * 1.02
        end
        local smooth_factor = aa_type == "jitter" and 0.75 or aa_type == "micro_jitter" and 0.8 or aa_type == "teleport" and 0.8 or aa_type == "fakelag" and 0.75 or aa_type == "custom" and 0.7 or aa_type == "air_crouch" and 0.75 or aa_type == "hideshot" and 0.8 or aa_type == "low_delta" and 0.65 or aa_type == "fake_pitch" and 0.7 or aa_type == "defensive" and 0.75 or aa_type == "lag_spike" and 0.65 or aa_type == "fake_lby" and 0.8 or aa_type == "adaptive_jitter" and 0.75 or aa_type == "fake_duck" and 0.75 or aa_type == "dynamic_lby" and 0.8 or aa_type == "fake_spin" and 0.8 or 0.6
        resolve_angle = smooth_angle(base_angle, base_angle + (desync_amount * records.learned_side), smooth_factor)
    end

    resolve_angle = ((resolve_angle % 360 + 540) % 360 - 180)
    records.last_yaw = resolve_angle

    local adjusted_hitbox = adjust_hitbox_position(records.last_valid_pos, aa_type, duck_amount, is_airborne)
    if adjusted_hitbox then
        records.last_valid_pos = adjusted_hitbox
    end

    return resolve_angle
end

function resolver.on_shot_fired(e)
    if not ui.get(resolver.enabled) then return end

    local target = e.target
    if not target then return end

    local steam_id = entity.get_steam64(target)
    if not steam_id or not resolver.player_records[steam_id] then return end

    local records = resolver.player_records[steam_id]
    local anim_state = entity.get_prop(target, "m_nPlayerAnimState") or 0
    records.shot_records:push({
        tick = e.tick,
        predicted_angle = records.last_yaw or (records.last_angles:get(1) and records.last_angles:get(1).angles[2] or 0),
        hit = e.hit,
        teleported = e.teleported,
        damage = e.damage,
        hitgroup = e.hitgroup or 0,
        anim_state = anim_state,
        anim_layers = analyze_anim_layers(target)
    })

    records.missed_shots = e.hit and e.hitgroup > 0 and e.damage > 0 and 0 or records.missed_shots + 1

    if records.missed_shots >= max_misses then
        records.learned_side = records.learned_side and -records.learned_side or (globals.tickcount() % 2 == 0 and 1 or -1)
        records.missed_shots = math.max(0, records.missed_shots - 1)
        if records.aa_type == "hideshot" or records.aa_type == "defensive" or records.aa_type == "fake_duck" or records.aa_type == "fake_lby" or records.aa_type == "adaptive_jitter" or records.aa_type == "dynamic_lby" or records.aa_type == "fake_spin" then
            records.learned_side = -records.learned_side
        end
    end
end

function resolver.update()
    if not ui.get(resolver.enabled) then
        for _, player in ipairs(entity.get_players(true)) do
            if plist and plist.set then
                plist.set(player, "Correction active", false)
            end
        end
        resolver.player_records = {}
        resolver.last_simulation_time = {}
        return
    end

    local current_time = globals.realtime()
    if current_time - resolver.last_update < update_interval * (64 / tickrate) then return end
    resolver.last_update = current_time

    update_tickrate()
    local targets = get_targets()
    for _, player in ipairs(targets) do
        resolver.record_player(player)
        local resolved_angle = resolver.resolve_angles(player)

        if resolved_angle then
            if plist and plist.set then
                plist.set(player, "Force body yaw value", resolved_angle)
                plist.set(player, "Correction active", true)
            end
        else
            if plist and plist.set then
                plist.set(player, "Correction active", false)
            end
        end
    end

    for steam_id, _ in pairs(resolver.player_records) do
        if not is_player_valid_steam(steam_id) or (resolver.player_records[steam_id].last_teleport_time > 0 and globals.realtime() - resolver.player_records[steam_id].last_teleport_time > 1.2) then
            resolver.player_records[steam_id] = nil
            resolver.last_simulation_time[steam_id] = nil
        end
    end
end

client.set_event_callback("paint", resolver.update)
client.set_event_callback("aim_fire", resolver.on_shot_fired)
client.set_event_callback("player_disconnect", function(e)
    local steam_id = entity.get_steam64(e.userid)
    if steam_id then
        resolver.player_records[steam_id] = nil
        resolver.last_simulation_time[steam_id] = nil
    end
end)
client.set_event_callback("player_teleported", function(e)
    local steam_id = entity.get_steam64(e.userid)
    if steam_id and resolver.player_records[steam_id] then
        resolver.player_records[steam_id].last_teleport_time = globals.realtime()
        resolver.player_records[steam_id].learned_side = nil
        resolver.player_records[steam_id].anomaly_detected = true
    end
end)
client.set_event_callback("level_init", function()
    resolver.player_records = {}
    resolver.last_simulation_time = {}
    resolver.last_valid_tick = globals.tickcount()
end)

-- UI элементы
local ui_group_a = {"LUA", "A"}
local ui_group_b = {"LUA", "B"}
local resolver = {
    enabled = ui.new_checkbox(ui_group_a[1], ui_group_a[2], "Resolver", false)
}
local scope = {
    enabled = ui.new_checkbox(ui_group_a[1], ui_group_a[2], "Scope Lines", false),
    color = ui.new_color_picker(ui_group_a[1], ui_group_a[2], "Scope Lines Color", 0, 255, 0, 255),
    position = ui.new_slider(ui_group_a[1], ui_group_a[2], "Scope Lines Position", 50, 500, 200, true, "px"),
    offset = ui.new_slider(ui_group_a[1], ui_group_a[2], "Scope Lines Offset", 5, 100, 20, true, "px"),
    fade_speed = ui.new_slider(ui_group_a[1], ui_group_a[2], "Fade Animation Speed", 5, 20, 12, true, "fr"),
    thickness = ui.new_slider(ui_group_a[1], ui_group_a[2], "Scope Lines Thickness", 1, 5, 2, true, "px")
}
local crosshair_correction = {
    enabled = ui.new_checkbox(ui_group_a[1], ui_group_a[2], "Crosshair Correction", false)
}
local trails = {
    enabled = ui.new_checkbox(ui_group_b[1], ui_group_b[2], "Movement Trails", false),
    duration = ui.new_slider(ui_group_b[1], ui_group_b[2], "Trail Duration", 1, 10, 5, true, "s", 0.1),
    color = ui.new_color_picker(ui_group_b[1], ui_group_b[2], "Trail Color", 0, 255, 0, 255),
    style = ui.new_combobox(ui_group_b[1], ui_group_b[2], "Trail Style", {"Line", "Wide Line", "Rectangle", "Glow"}, "Line")
}
local bullet_tracer = {
    enabled = ui.new_checkbox(ui_group_b[1], ui_group_b[2], "Bullet Tracers", false),
    duration = ui.new_slider(ui_group_b[1], ui_group_b[2], "Tracer Duration", 1, 10, 3, true, "s", 0.1),
    color = ui.new_color_picker(ui_group_b[1], ui_group_b[2], "Tracer Color", 0, 255, 0, 255),
    thickness = ui.new_slider(ui_group_b[1], ui_group_b[2], "Tracer Thickness", 1, 5, 2, true, "px")
}
local trashtalk = {
    enabled = ui.new_checkbox(ui_group_b[1], ui_group_b[2], "Trashtalk", false)
}
local hitmarker = {
    enabled = ui.new_checkbox(ui_group_b[1], ui_group_b[2], "Hitmarker", false),
    color = ui.new_color_picker(ui_group_b[1], ui_group_b[2], "Hitmarker Color", 0, 255, 0, 255),
    duration = ui.new_slider(ui_group_b[1], ui_group_b[2], "Hitmarker Duration", 1, 5, 1, true, "s", 0.1)
}
local kill_counter = {
    enabled = ui.new_checkbox(ui_group_b[1], ui_group_b[2], "Kill Counter", false)
}
local hit_streak = {
    enabled = ui.new_checkbox(ui_group_b[1], ui_group_b[2], "Hit Streak", false)
}
local clan_tag = {
    enabled = ui.new_checkbox(ui_group_a[1], ui_group_a[2], "zero.tech Clan Tag", false)
}

-- Безопасное получение ссылок на элементы меню
local refs = {
    rage = {
        dt = { pcall(ui.reference, "RAGE", "Aimbot", "Double tap") and ui.reference("RAGE", "Aimbot", "Double tap") or nil, nil },
        fd = { pcall(ui.reference, "RAGE", "Other", "Duck peek assist") and ui.reference("RAGE", "Other", "Duck peek assist") or nil, nil },
        qp = { nil, nil },
        ovr = { pcall(ui.reference, "RAGE", "Aimbot", "Minimum damage override") and ui.reference("RAGE", "Aimbot", "Minimum damage override") or nil, nil }
    }
}
local success, qp_ref = pcall(ui.reference, "RAGE", "Aimbot", "Quick peek")
if success and qp_ref then
    refs.rage.qp = {qp_ref, qp_ref}
else
    client.log("Warning: 'Quick peek' not found in RAGE->Aimbot, disabling Quick peek support")
end

-- Утилиты для визуалов
local render = {
    animations = {},
    new_anim = function(self, id, target, speed)
        if not self.animations[id] then
            self.animations[id] = { value = target, last_time = globals.curtime() }
        end
        local anim = self.animations[id]
        local cur_time = globals.curtime()
        local delta = cur_time - anim.last_time
        local factor = math.min(delta * speed, 1)
        anim.value = anim.value + (target - anim.value) * factor
        anim.last_time = cur_time
        return anim.value
    end,
    alphen = function(self, alpha)
        return math.max(0, math.min(255, alpha))
    end
}

local scope_overlay = ui.reference("VISUALS", "Effects", "Remove scope overlay")
local alpha = 0
local trail_data = { last_segments = 0 }
local bullet_tracers = { last_tracers = 0 }
local trashtalk_phrases = {
    normal = {
        "Get owned!", "Too easy!", "You're done!", "Nice try!", "EZ win!",
        "Sit down!", "Wrecked!", "Better luck next time!", "Smoked!", "You're out!",
        "Caught you slippin'!", "Outplayed!", "No chance!", "Down you go!", "Too slow!",
        "Owned again!", "Learn to aim!", "Get rekt!", "No skill!", "Bye bye!",
        "Can't touch this!", "You're trash!", "Easy pickings!", "Outclassed!", "Go practice!",
        "You're nothing!", "Wiped out!", "No hope!", "Crushed!", "Get good!",
        "Sayonara!", "You're toast!", "Outgunned!", "No match!", "Deleted!",
        "Back to spawn!", "Outskilled!", "No way!", "Smashed!", "You're history!",
        "Game over!", "Try harder!", "Wasted!", "No escape!", "Donezo!",
        "You're finished!", "Schooled!", "Lights out!", "Try again!", "Owned hard!",
        "No mercy!", "Get clapped!", "You're gone!", "Skill issue!", "Too weak!"
    }
}
local zero_tech_tag = {
    " ", "z ", "ze ", "zer ", "zero ", "zero. ", "zero.t ", "zero.te ", "zero.tec ", "zero.tech ",
    "zero.tec ", "zero.te ", "zero.t ", "zero. ", "zero ", "zer ", "ze ", "z ", " "
}

-- Улучшенные scope lines с пульсацией
client.set_event_callback("paint", function()
    if not ui.get(scope.enabled) then return end
    ui.set(scope_overlay, false)
    local width, height = client.screen_size()
    local offset = (ui.get(scope.offset) * height) / 1080
    local position = (ui.get(scope.position) * height) / 1080
    local speed = ui.get(scope.fade_speed)
    local thickness = ui.get(scope.thickness)
    local r, g, b, a = ui.get(scope.color)
    local player = entity.get_local_player()
    local weapon = entity.get_player_weapon(player)
    local scope_level = weapon and entity.get_prop(weapon, "m_zoomLevel") or 0
    local is_scoped = entity.get_prop(player, "m_bIsScoped") == 1
    local resume_zoom = entity.get_prop(player, "m_bResumeZoom") == 1
    local is_valid = is_player_valid(player) and weapon and scope_level
    local is_active = is_valid and scope_level > 0 and is_scoped and not resume_zoom
    local frame_time = speed > 3 and globals.frametime() * speed or 1
    alpha = clamp(alpha + (is_active and frame_time or -frame_time), 0, 1)
    local pulse = math.sin(globals.curtime() * 3) * 0.1 + 0.9  -- Пульсация прозрачности
    local alpha_pulse = alpha * a * pulse
    if renderer.gradient then
        -- Горизонтальные линии с градиентом
        renderer.gradient(width / 2 - position, height / 2 - thickness / 2, position - offset, thickness, 0, 0, 0, 0, r, g, b, alpha_pulse, true)
        renderer.gradient(width / 2 + offset, height / 2 - thickness / 2, position - offset, thickness, r, g, b, alpha_pulse, 0, 0, 0, 0, true)
        -- Вертикальные линии с градиентом
        renderer.gradient(width / 2 - thickness / 2, height / 2 - position, thickness, position - offset, 0, 0, 0, 0, r, g, b, alpha_pulse, false)
        renderer.gradient(width / 2 - thickness / 2, height / 2 + offset, thickness, position - offset, r, g, b, alpha_pulse, 0, 0, 0, 0, false)
        -- Точки в центре для акцента
        if renderer.circle then
            renderer.circle(width / 2, height / 2, r, g, b, alpha_pulse * 0.5, 3, 0, 1)
        end
    else
        client.log("Error: renderer.gradient not found")
    end
end)

ui.set_callback(scope.enabled, function()
    local enabled = ui.get(scope.enabled)
    alpha = enabled and alpha or 0
    ui.set_visible(scope_overlay, not enabled)
    ui.set_visible(scope.color, enabled)
    ui.set_visible(scope.position, enabled)
    ui.set_visible(scope.offset, enabled)
    ui.set_visible(scope.fade_speed, enabled)
    ui.set_visible(scope.thickness, enabled)
    client[enabled and "set_event_callback" or "unset_event_callback"]("paint_ui", function() ui.set(scope_overlay, true) end)
end)

-- Crosshair correction
client.set_event_callback("paint", function()
    if not ui.get(crosshair_correction.enabled) then return end
    local local_player = entity.get_local_player()
    if not is_player_valid(local_player) then return end
    local width, height = client.screen_size()
    local center_x, center_y = width / 2, height / 2
    for _, player in ipairs(entity.get_players(true)) do
        if resolver.player_records[entity.get_steam64(player)] and resolver.player_records[entity.get_steam64(player)].last_yaw then
            local origin = vector(entity.get_prop(player, "m_vecOrigin") or {x=0, y=0, z=0})
            local angles = resolver.player_records[entity.get_steam64(player)].last_yaw
            local view_offset = vector(entity.get_prop(player, "m_vecViewOffset") or {x=0, y=0, z=0})
            local head_pos = origin + view_offset
            local yaw = normalize_angle(angles)
            local offset = vector(math.cos(math.rad(yaw)) * 50, math.sin(math.rad(yaw)) * 50, 0)
            local corrected_pos = head_pos + offset
            local x, y = renderer.world_to_screen(corrected_pos.x, corrected_pos.y, corrected_pos.z)
            if x and y and renderer.line then
                renderer.line(center_x, center_y, x, y, 0, 255, 0, 100)
            end
        end
    end
end)

-- Улучшенные Movement Trails
local function clear_trails()
    trail_data = { last_segments = 0 }
end

ui.set_callback(ui.new_hotkey(ui_group_b[1], ui_group_b[2], "Clear Trails"), clear_trails)

client.set_event_callback("paint", function()
    if not ui.get(trails.enabled) then return end
    local duration = ui.get(trails.duration)
    local r, g, b, a = ui.get(trails.color)
    local style = ui.get(trails.style)
    ui.set_visible(trails.duration, ui.get(trails.enabled))
    ui.set_visible(trails.color, ui.get(trails.enabled))
    ui.set_visible(trails.style, ui.get(trails.enabled))
    local player = entity.get_local_player()
    if not is_player_valid(player) then return end
    local cur_time = globals.curtime()
    local cur_origin = vector(entity.get_prop(player, "m_vecOrigin") or {x=0, y=0, z=0})
    if not trail_data.last_origin then trail_data.last_origin = cur_origin end
    local dist = cur_origin:dist(trail_data.last_origin)
    if not trail_data.segments then trail_data.segments = {} end
    if dist > 0 then
        local x, y, z = cur_origin.x, cur_origin.y, cur_origin.z
        table.insert(trail_data.segments, { pos = cur_origin, exp = cur_time + duration * 0.1, x = x, y = y, z = z })
    end
    trail_data.last_origin = cur_origin
    for i = #trail_data.segments, 1, -1 do
        if trail_data.segments[i].exp < cur_time then
            table.remove(trail_data.segments, i)
        end
    end
    local batch_lines = {}
    for i, segment in ipairs(trail_data.segments) do
        local x, y = renderer.world_to_screen(segment.x, segment.y, segment.z)
        local alpha = clamp((segment.exp - cur_time) / (duration * 0.1), 0, 1) * a
        local color_factor = 0.5 + 0.5 * (segment.exp - cur_time) / (duration * 0.1)  -- Плавный переход цвета
        local r_fade, g_fade, b_fade = r * color_factor, g * color_factor, b * color_factor
        if x and y then
            if style == "Line" or style == "Wide Line" then
                if i < #trail_data.segments then
                    local next_segment = trail_data.segments[i + 1]
                    local x2, y2 = renderer.world_to_screen(next_segment.x, next_segment.y, next_segment.z)
                    if x2 and y2 and renderer.line then
                        table.insert(batch_lines, {x1 = x, y1 = y, x2 = x2, y2 = y2, r = r_fade, g = g_fade, b = b_fade, a = alpha})
                        if style == "Wide Line" and renderer.circle_outline then
                            renderer.circle_outline(x, y, r_fade, g_fade, b_fade, alpha * 0.5, 3, 0, 1, 2)
                            renderer.circle_outline(x2, y2, r_fade, g_fade, b_fade, alpha * 0.5, 3, 0, 1, 2)
                        end
                    end
                end
            elseif style == "Rectangle" and renderer.rectangle then
                renderer.rectangle(x - 2, y - 2, 4, 4, r_fade, g_fade, b_fade, alpha)
            elseif style == "Glow" and renderer.circle then
                renderer.circle(x, y, r_fade, g_fade, b_fade, alpha * 0.7, 5, 0, 1)
            end
        end
    end
    for _, line in ipairs(batch_lines) do
        if renderer.line then
            renderer.line(line.x1, line.y1, line.x2, line.y2, line.r, line.g, line.b, line.a)
        end
    end
end)

client.set_event_callback("round_start", clear_trails)

-- Улучшенные Bullet Tracers
client.set_event_callback("bullet_impact", function(e)
    if not ui.get(bullet_tracer.enabled) then return end
    local player = entity.get_local_player()
    if not player or entity.get_prop(e.userid, "m_iTeamNum") ~= entity.get_prop(player, "m_iTeamNum") then return end
    local start = vector(entity.get_prop(player, "m_vecOrigin") or {x=0, y=0, z=0}) + vector(entity.get_prop(player, "m_vecViewOffset") or {x=0, y=0, z=0})
    local impact = vector(e.x, e.y, e.z)
    table.insert(bullet_tracers, {
        start = start,
        end_pos = impact,
        time = globals.curtime(),
        duration = ui.get(bullet_tracer.duration)
    })
end)

client.set_event_callback("paint", function()
    if not ui.get(bullet_tracer.enabled) then return end
    local cur_time = globals.curtime()
    local duration = ui.get(bullet_tracer.duration)
    local r, g, b, a = ui.get(bullet_tracer.color)
    local thickness = ui.get(bullet_tracer.thickness)
    ui.set_visible(bullet_tracer.duration, ui.get(bullet_tracer.enabled))
    ui.set_visible(bullet_tracer.color, ui.get(bullet_tracer.enabled))
    ui.set_visible(bullet_tracer.thickness, ui.get(bullet_tracer.enabled))
    local batch_lines = {}
    for i = #bullet_tracers, 1, -1 do
        local tracer = bullet_tracers[i]
        if tracer.time + tracer.duration < cur_time then
            table.remove(bullet_tracers, i)
        else
            local x1, y1 = renderer.world_to_screen(tracer.start.x, tracer.start.y, tracer.start.z)
            local x2, y2 = renderer.world_to_screen(tracer.end_pos.x, tracer.end_pos.y, tracer.end_pos.z)
            local alpha = clamp((tracer.time + tracer.duration - cur_time) / tracer.duration, 0, 1) * a
            local color_factor = 0.6 + 0.4 * (tracer.time + tracer.duration - cur_time) / tracer.duration
            local r_fade, g_fade, b_fade = r * color_factor, g * color_factor, b * color_factor
            if x1 and x2 and renderer.line then
                for t = 1, thickness do
                    table.insert(batch_lines, {
                        x1 = x1 + (t - thickness / 2), y1 = y1,
                        x2 = x2 + (t - thickness / 2), y2 = y2,
                        r = r_fade, g = g_fade, b = b_fade, a = alpha * (1 - (t - 1) / thickness * 0.5)
                    })
                end
                if renderer.circle_outline then
                    renderer.circle_outline(x2, y2, r_fade, g_fade, b_fade, alpha * 0.6, 4, 0, 1, 2)
                end
            end
        end
    end
    for _, line in ipairs(batch_lines) do
        if renderer.line then
            renderer.line(line.x1, line.y1, line.x2, line.y2, line.r, line.g, line.b, line.a)
        end
    end
end)

-- Trashtalk
local last_trashtalk = 0
client.set_event_callback("player_death", function(e)
    if not ui.get(trashtalk.enabled) then return end
    local attacker = client.userid_to_entindex(e.attacker)
    local victim = client.userid_to_entindex(e.userid)
    local local_player = entity.get_local_player()
    if attacker ~= local_player or not is_player_valid(local_player) or not is_player_valid(victim) then return end
    local local_origin = vector(entity.get_prop(local_player, "m_vecOrigin") or {x=0, y=0, z=0})
    local victim_origin = vector(entity.get_prop(victim, "m_vecOrigin") or {x=0, y=0, z=0})
    local trace = client.trace_line(local_player, local_origin.x, local_origin.y, local_origin.z, victim_origin.x, victim_origin.y, victim_origin.z, 0x4600400B)
    if trace and trace.fraction < 0.98 then return end
    local cur_time = globals.curtime()
    local frequency = 1.8
    if cur_time - last_trashtalk < frequency then return end
    local phrase = trashtalk_phrases.normal[math.random(1, #trashtalk_phrases.normal)]
    if #phrase > 120 then phrase = string.sub(phrase, 1, 120) end
    client.exec("say " .. phrase)
    last_trashtalk = cur_time
end)

-- Улучшенный Hitmarker
local hitmarker_time = 0
local hitmarker_scale = 1
client.set_event_callback("aim_hit", function(e)
    if not ui.get(hitmarker.enabled) then return end
    hitmarker_time = globals.curtime()
    hitmarker_scale = 1.5  -- Начальный масштаб для анимации
    client.exec("playvol buttons/blip2 0.6")
end)

client.set_event_callback("paint", function()
    if not ui.get(hitmarker.enabled) then return end
    local cur_time = globals.curtime()
    local duration = ui.get(hitmarker.duration)
    if cur_time - hitmarker_time < duration then
        local width, height = client.screen_size()
        local x, y = width / 2, height / 2
        local r, g, b, a = ui.get(hitmarker.color)
        local alpha = clamp((duration - (cur_time - hitmarker_time)) / duration, 0, 1) * a
        local scale = render:new_anim("hitmarker_scale", 1, 10)  -- Плавное уменьшение масштаба
        local pulse = math.sin(cur_time * 8) * 0.1 + 0.9  -- Пульсация
        if renderer.line and renderer.circle then
            local size = 12 * scale * pulse
            renderer.line(x - size, y - size, x - size / 2, y - size / 2, r, g, b, alpha)
            renderer.line(x + size / 2, y - size / 2, x + size, y - size, r, g, b, alpha)
            renderer.line(x - size, y + size, x - size / 2, y + size / 2, r, g, b, alpha)
            renderer.line(x + size / 2, y + size / 2, x + size, y + size, r, g, b, alpha)
            renderer.circle(x, y, r, g, b, alpha * 0.7, 10 * scale, 0, 1)
            if renderer.circle_outline then
                renderer.circle_outline(x, y, r, g, b, alpha * 0.5, 12 * scale, 0, 1, 2)
            end
        else
            client.log("Error: renderer.line or renderer.circle not found")
        end
    end
end)

-- Kill Counter
local kill_count = 0
client.set_event_callback("player_death", function(e)
    if not ui.get(kill_counter.enabled) then return end
    local attacker = client.userid_to_entindex(e.attacker)
    local local_player = entity.get_local_player()
    if attacker == local_player then
        kill_count = kill_count + 1
    end
end)

client.set_event_callback("round_start", function()
    kill_count = 0
end)

client.set_event_callback("paint", function()
    if not ui.get(kill_counter.enabled) then return end
    local width, height = client.screen_size()
    if renderer.text then
        renderer.text(width - 100, 50, 0, 255, 0, 255, "b", 0, "Kills: " .. kill_count)
    else
        client.log("Error: renderer.text not found for kill counter")
    end
end)

-- Hit Streak
local hit_streak_count = 0
local hit_streak_time = 0
client.set_event_callback("aim_hit", function(e)
    if not ui.get(hit_streak.enabled) then return end
    local cur_time = globals.curtime()
    if cur_time - hit_streak_time > 2 then
        hit_streak_count = 0
    end
    hit_streak_count = hit_streak_count + 1
    hit_streak_time = cur_time
end)

client.set_event_callback("paint", function()
    if not ui.get(hit_streak.enabled) then return end
    local cur_time = globals.curtime()
    if cur_time - hit_streak_time < 2 and hit_streak_count > 1 then
        local width, height = client.screen_size()
        if renderer.text then
            local alpha = clamp((2 - (cur_time - hit_streak_time)) / 2, 0, 1) * 255
            renderer.text(width / 2, height / 2 - 30, 0, 255, 0, alpha, "c", 0, hit_streak_count .. " HIT STREAK")
        else
            client.log("Error: renderer.text not found for hit streak")
        end
    end
end)

-- Clan Tag
local last_tag = 0
client.set_event_callback("paint", function()
    if not ui.get(clan_tag.enabled) then return end
    local cur_time = globals.curtime()
    local index = math.floor(cur_time * 2 % #zero_tech_tag) + 1
    if index ~= last_tag then
        client.set_clan_tag(zero_tech_tag[index])
        last_tag = index
    end
end)

client.set_event_callback("shutdown", function()
    client.set_clan_tag("")
    for _, player in ipairs(entity.get_players(true)) do
        if plist and plist.set then
            plist.set(player, "Correction active", false)
        end
    end
end)

client.log("Script loaded successfully")
