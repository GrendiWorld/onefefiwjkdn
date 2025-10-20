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

local function accent()
    return 0, 255, 0, 255
end

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

local max_history = 512
local desync_threshold = 8
local jitter_threshold = 15
local max_desync_history = 256
local update_interval = 0.001
local teleport_threshold = 100
local sim_time_anomaly_threshold = 0.015
local max_misses = 1
local fov_threshold = 75
local max_yaw_delta = 180
local max_pitch_delta = 89
local tickrate = 64
local hideshot_threshold = 0.015
local air_crouch_threshold = 0.15
local ping_threshold = 60
local max_velocity = 450
local max_anim_layers = 15
local min_sim_time_delta = 0.004
local max_hitbox_shift = 6
local lag_spike_threshold = 0.03
local advanced_analysis = true
local brute_force_enabled = true

json.encode_number_precision(6)
json.encode_sparse_array(true, 2, 10)

local resolver = {
    player_records = {},
    last_simulation_time = {},
    last_update = globals.realtime(),
    last_valid_tick = globals.tickcount(),
    brute_force_cache = {}
}

local function create_circular_buffer(size)
    local buffer = { size = size, data = {}, head = 0 }
    function buffer:push(item)
        self.head = (self.head % self.size) + 1
        self.data[self.head] = item
    end
    function buffer:get(index)
        if not index or index < 1 or index > self:len() then return nil end
        return self.data[(self.head - index + self.size) % self.size + 1]
    end
    function buffer:len()
        return math.min(#self.data, self.size)
    end
    function buffer:clear()
        self.data = {}
        self.head = 0
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

local function analyze_anim_layers(player)
    local layer_data = {}
    for i = 0, max_anim_layers - 1 do
        local weight = entity.get_prop(player, "m_AnimOverlay", i) or 0
        local sequence = entity.get_prop(player, "m_AnimOverlay", i, "m_nSequence") or 0
        if weight > 0 then
            table.insert(layer_data, {index = i, weight = weight, sequence = sequence})
        end
    end
    return layer_data
end

local function advanced_aa_detection(records)
    if not records or records.last_angles:len() < 10 then return "none" end

    local yaw_deltas = {}
    local pitch_deltas = {}
    local body_yaw_deltas = {}
    local lby_deltas = {}
    local sim_time_deltas = {}
    local velocity_samples = {}
    local duck_samples = {}
    local layer_sequence_changes = {}
    local tick_base_samples = {}

    for i = 2, records.last_angles:len() do
        local curr = records.last_angles:get(i-1)
        local prev = records.last_angles:get(i)
        if not curr or not prev then break end

        local yaw_delta = math.abs(curr.angles[2] - prev.angles[2])
        yaw_delta = math.min(yaw_delta, max_yaw_delta)
        yaw_deltas[#yaw_deltas + 1] = yaw_delta

        local pitch_delta = math.abs(curr.angles[1] - prev.angles[1])
        pitch_deltas[#pitch_deltas + 1] = pitch_delta

        local curr_body_yaw = entity.get_prop(curr.player, "m_flPoseParameter", 11) * 120 - 60
        local prev_body_yaw = entity.get_prop(prev.player, "m_flPoseParameter", 11) * 120 - 60
        body_yaw_deltas[#body_yaw_deltas + 1] = math.abs(curr_body_yaw - prev_body_yaw)

        local curr_lby = entity.get_prop(curr.player, "m_flLowerBodyYawTarget") or 0
        local prev_lby = entity.get_prop(prev.player, "m_flLowerBodyYawTarget") or 0
        lby_deltas[#lby_deltas + 1] = math.abs(curr_lby - prev_lby)

        sim_time_deltas[#sim_time_deltas + 1] = curr.sim_time - prev.sim_time
        velocity_samples[#velocity_samples + 1] = curr.velocity
        duck_samples[#duck_samples + 1] = entity.get_prop(curr.player, "m_flDuckAmount") or 0
        
        local curr_layers = curr.anim_layers
        local prev_layers = prev.anim_layers
        local seq_change = 0
        if curr_layers[1] and prev_layers[1] then
            seq_change = curr_layers[1].sequence ~= prev_layers[1].sequence and 1 or 0
        end
        layer_sequence_changes[#layer_sequence_changes + 1] = seq_change

        tick_base_samples[#tick_base_samples + 1] = entity.get_prop(curr.player, "m_nTickBase") or 0
    end

    local stats = {
        yaw_avg = 0, yaw_std = 0, yaw_max = 0,
        body_avg = 0, body_std = 0, body_max = 0,
        lby_avg = 0, lby_std = 0,
        sim_avg = 0, sim_std = 0,
        vel_avg = 0, vel_std = 0,
        duck_avg = 0, duck_std = 0,
        seq_changes = 0
    }

    for k, v in pairs(stats) do
        if k:match("avg") then
            local sum = 0
            for _, val in ipairs((function()
                if k == "yaw_avg" then return yaw_deltas
                elseif k == "body_avg" then return body_yaw_deltas
                elseif k == "lby_avg" then return lby_deltas
                elseif k == "sim_avg" then return sim_time_deltas
                elseif k == "vel_avg" then return velocity_samples
                elseif k == "duck_avg" then return duck_samples
                end
            end)()) do sum = sum + val end
            stats[k] = #yaw_deltas > 0 and sum / #yaw_deltas or 0
        elseif k:match("max") then
            stats.yaw_max = math.max(unpack(yaw_deltas))
            stats.body_max = math.max(unpack(body_yaw_deltas))
        elseif k == "seq_changes" then
            stats.seq_changes = 0
            for _, v in ipairs(layer_sequence_changes) do stats.seq_changes = stats.seq_changes + v end
        end
    end

    local variance = function(arr)
        local avg = stats[(arr == yaw_deltas and "yaw_avg") or (arr == body_yaw_deltas and "body_avg") or "sim_avg"]
        local sum_sq = 0
        for _, val in ipairs(arr) do sum_sq = sum_sq + (val - avg)^2 end
        return #arr > 0 and sum_sq / #arr or 0
    end

    stats.yaw_std = math.sqrt(variance(yaw_deltas))
    stats.body_std = math.sqrt(variance(body_yaw_deltas))
    stats.sim_std = math.sqrt(variance(sim_time_deltas))

    local ping = entity.get_prop(records.last_angles:get(1).player, "m_iPing") or 0
    local ping_factor = ping > ping_threshold and 1.2 or 1.0

    if is_server_lagging() then return "lag_spike"
    elseif stats.yaw_max > jitter_threshold * ping_factor and stats.yaw_std > 8 then return "jitter"
    elseif stats.body_max > 45 and stats.yaw_avg > desync_threshold * ping_factor then return "desync"
    elseif stats.sim_std < sim_time_anomaly_threshold * 0.8 then return "fakelag"
    elseif stats.yaw_max > 60 * ping_factor then return "spinbot"
    elseif stats.lby_avg > 25 and stats.body_std > 15 then return "lby_fake"
    elseif stats.yaw_avg > 3 and stats.yaw_avg < 8 and stats.seq_changes > 5 then return "micro_adjust"
    elseif stats.duck_avg > 0.3 and stats.yaw_std > 12 then return "duck_desync"
    elseif stats.vel_avg > 100 and stats.body_max > 35 then return "move_jitter"
    elseif stats.seq_changes > 8 and stats.sim_std < 0.02 then return "layer_exploit"
    elseif stats.yaw_std < 2 and stats.yaw_avg > 1 then return "static_low"
    end

    return "static"
end

local function detect_anti_aim_type(records)
    if advanced_analysis then
        return advanced_aa_detection(records)
    end

    if not records or not records.last_angles or records.last_angles:len() < 5 then return "none" end

    local yaw_deltas = {}
    local pitch_deltas = {}
    local max_yaw_delta_local = 0
    local max_pitch_delta_local = 0
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
        local curr = records.last_angles:get(i-1)
        local prev = records.last_angles:get(i)
        if not curr or not prev then return "none" end

        local yaw_delta = math.abs(curr.angles[2] - prev.angles[2])
        local pitch_delta = math.abs(curr.angles[1] - prev.angles[1])
        yaw_delta = math.min(yaw_delta, max_yaw_delta)
        pitch_delta = math.min(pitch_delta, max_pitch_delta)
        yaw_deltas[i-1] = yaw_delta
        pitch_deltas[i-1] = pitch_delta
        max_yaw_delta_local = math.max(max_yaw_delta_local, yaw_delta)
        max_pitch_delta_local = math.max(max_pitch_delta_local, pitch_delta)
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
        anim_layer_changes[i-1] = #curr_layers ~= #prev_layers or (curr_layers[1] and prev_layers[1] and curr_layers[1].weight ~= prev_layers[1].weight)
        velocity_changes[i-1] = math.abs(curr.velocity - prev.velocity)
        duck_speed_changes[i-1] = math.abs((entity.get_prop(curr.player, "m_flDuckSpeed") or 0) - (entity.get_prop(prev.player, "m_flDuckSpeed") or 0))
        tick_base_changes[i-1] = math.abs((entity.get_prop(curr.player, "m_nTickBase") or 0) - (entity.get_prop(prev.player, "m_nTickBase") or 0))
    end

    if #yaw_deltas == 0 then return "none" end

    local avg_yaw_delta = 0
    for _, delta in ipairs(yaw_deltas) do avg_yaw_delta = avg_yaw_delta + delta end
    avg_yaw_delta = avg_yaw_delta / #yaw_deltas

    local avg_sim_time = 0
    if #sim_time_deltas > 0 then
        for _, delta in ipairs(sim_time_deltas) do avg_sim_time = avg_sim_time + delta end
        avg_sim_time = avg_sim_time / #sim_time_deltas
    end

    local avg_tick_delta = 0
    if #tick_deltas > 0 then
        for _, delta in ipairs(tick_deltas) do avg_tick_delta = avg_tick_delta + delta end
        avg_tick_delta = avg_tick_delta / #tick_deltas
    end

    local avg_body_yaw_delta = 0
    if #body_yaw_deltas > 0 then
        for _, delta in ipairs(body_yaw_deltas) do avg_body_yaw_delta = avg_body_yaw_delta + delta end
        avg_body_yaw_delta = avg_body_yaw_delta / #body_yaw_deltas
    end

    local avg_velocity_change = 0
    if #velocity_changes > 0 then
        for _, delta in ipairs(velocity_changes) do avg_velocity_change = avg_velocity_change + delta end
        avg_velocity_change = avg_velocity_change / #velocity_changes
    end

    local avg_duck_speed_change = 0
    if #duck_speed_changes > 0 then
        for _, delta in ipairs(duck_speed_changes) do avg_duck_speed_change = avg_duck_speed_change + delta end
        avg_duck_speed_change = avg_duck_speed_change / #duck_speed_changes
    end

    local avg_tick_base_change = 0
    if #tick_base_changes > 0 then
        for _, delta in ipairs(tick_base_changes) do avg_tick_base_change = avg_tick_base_change + delta end
        avg_tick_base_change = avg_tick_base_change / #tick_base_changes
    end

    local crouch_changes = 0
    local air_crouch_count = 0
    local anim_change_count = 0
    local move_changes = 0
    local anim_layer_change_count = 0
    for i = 2, #crouch_states do
        if crouch_states[i] ~= crouch_states[i-1] then crouch_changes = crouch_changes + 1 end
        if crouch_states[i] and air_states[i] then air_crouch_count = air_crouch_count + 1 end
        if anim_changes[i-1] then anim_change_count = anim_change_count + 1 end
        if move_states[i] ~= move_states[i-1] then move_changes = move_changes + 1 end
        if anim_layer_changes[i-1] then anim_layer_change_count = anim_layer_change_count + 1 end
    end

    local ping = entity.get_prop(records.last_angles:get(1) and records.last_angles:get(1).player or 0, "m_iPing") or 0
    local ping_factor = ping > ping_threshold and 1.1 or 1.0

    local is_teleporting = false
    for _, dist in ipairs(position_changes) do
        if dist > teleport_threshold then is_teleporting = true; break end
    end

    if is_server_lagging() then return "lag_spike"
    elseif is_teleporting then return "teleport"
    elseif max_yaw_delta_local > jitter_threshold * ping_factor or avg_body_yaw_delta > 40 then return "jitter"
    elseif avg_yaw_delta > desync_threshold * ping_factor or avg_body_yaw_delta > 15 then return "desync"
    elseif avg_sim_time < sim_time_anomaly_threshold or avg_tick_delta > 0.8 or avg_tick_base_change > 2 then return "fakelag"
    elseif max_yaw_delta_local > 55 * ping_factor then return "spinbot"
    elseif avg_yaw_delta > 6 and records.shot_records:len() > 4 then return "custom"
    elseif avg_body_yaw_delta > 7 then return "micro_jitter"
    elseif max_pitch_delta_local > 25 then return "fake_pitch"
    elseif crouch_changes > 2 and air_crouch_count > 1 then return "air_crouch"
    elseif anim_change_count > 2 and avg_sim_time < hideshot_threshold or anim_layer_change_count > 2 then return "hideshot"
    elseif avg_yaw_delta > 1.5 and avg_yaw_delta <= 5 then return "low_delta"
    elseif move_changes > 2 and avg_body_yaw_delta > 10 or avg_velocity_change > 50 then return "defensive"
    elseif avg_body_yaw_delta > 25 and avg_sim_time < 0.025 then return "fake_lby"
    elseif max_yaw_delta_local > 35 and avg_yaw_delta < 10 then return "adaptive_jitter"
    elseif avg_duck_speed_change > 1 and crouch_changes > 3 then return "fake_duck"
    elseif avg_body_yaw_delta > 20 and max_yaw_delta_local > 50 then return "dynamic_lby"
    elseif avg_tick_base_change > 3 and avg_sim_time < 0.03 then return "fake_spin"
    end
    return "static"
end

local function predict_desync_advanced(player, steam_id, records, aa_type)
    if not records or records.last_angles:len() < 5 then return records.learned_side end

    local recent_angles = {}
    for i = 1, math.min(8, records.last_angles:len()) do
        local angle = records.last_angles:get(i)
        if angle then table.insert(recent_angles, angle.angles[2]) end
    end

    local ml_prediction = 0
    if #recent_angles >= 4 then
        local sum = 0
        for i = 2, #recent_angles do
            sum = sum + (recent_angles[i] - recent_angles[i-1])
        end
        ml_prediction = sum / (#recent_angles - 1)
    end

    local velocity, velocity_vec = calculate_velocity(player)
    local is_moving = velocity > 15
    local angle_to_velocity = 0
    if velocity_vec.x ~= 0 or velocity_vec.y ~= 0 then
        angle_to_velocity = math.deg(math.atan2(velocity_vec.y, velocity_vec.x)) - recent_angles[1]
        angle_to_velocity = ((angle_to_velocity % 360 + 540) % 360 - 180)
    end

    local lby = entity.get_prop(player, "m_flLowerBodyYawTarget") or 0
    local body_yaw = (entity.get_prop(player, "m_flPoseParameter", 11) or 0) * 120 - 60
    local lby_delta = math.abs(lby - recent_angles[1])

    local pattern_weights = {0.4, 0.3, 0.2, 0.1}
    local pattern_score = 0
    local pattern_length = math.min(records.desync_history:len(), 4)
    for i = 1, pattern_length do
        local s = records.desync_history:get(i)
        if s then pattern_score = pattern_score + s * pattern_weights[i] end
    end

    local confidence = math.min(records.missed_shots * 0.25 + 0.5, 1.0)
    
    local side = records.learned_side or 1
    if aa_type == "jitter" or aa_type == "micro_jitter" or aa_type == "adaptive_jitter" then
        side = ml_prediction > 0 and 1 or -1
        if pattern_score > 0 then side = 1 elseif pattern_score < 0 then side = -1 end
    elseif aa_type == "desync" or aa_type == "lby_fake" then
        side = lby_delta > 30 and (lby > recent_angles[1] and 1 or -1) or (angle_to_velocity > 0 and 1 or -1)
    elseif aa_type == "spinbot" or aa_type == "fake_spin" then
        side = (globals.tickcount() % 4 < 2) and 1 or -1
    elseif aa_type == "fakelag" then
        side = (records.missed_shots + globals.tickcount()) % 3 == 0 and 1 or -1
    elseif aa_type == "air_crouch" or aa_type == "duck_desync" then
        side = entity.get_prop(player, "m_flDuckAmount") > air_crouch_threshold and 1 or -1
    elseif aa_type == "move_jitter" and is_moving then
        side = angle_to_velocity > 15 and 1 or -1
    elseif aa_type == "layer_exploit" then
        local layers = analyze_anim_layers(player)
        side = #layers > 3 and 1 or -1
    else
        side = pattern_score * confidence > 0 and 1 or -1
    end

    records.desync_history:push(side)
    return side
end

local function brute_force_resolve(player, steam_id, base_angle, records)
    if not brute_force_enabled or not records then return base_angle end
    
    local cache_key = steam_id .. "_" .. globals.tickcount()
    if resolver.brute_force_cache[cache_key] then
        return resolver.brute_force_cache[cache_key]
    end

    local best_angle = base_angle
    local best_score = -math.huge
    local test_angles = {-60, -45, -30, -15, 0, 15, 30, 45, 60}
    
    for _, offset in ipairs(test_angles) do
        local test_angle = base_angle + offset
        local score = 0
        
        local hitbox_pos = get_hitbox_position(player, 0)
        if hitbox_pos then
            local test_pos = {
                x = hitbox_pos.x + math.cos(math.rad(test_angle)) * 58,
                y = hitbox_pos.y + math.sin(math.rad(test_angle)) * 58,
                z = hitbox_pos.z
            }
            
            local trace_result = trace.line(entity.get_local_player(), test_pos.x, test_pos.y, test_pos.z)
            if trace_result and trace_result.fraction > 0.95 then
                score = score + 100
            end
        end
        
        local velocity = calculate_velocity(player)
        if velocity > 15 then
            local move_angle = math.deg(math.atan2(velocity_vec.y, velocity_vec.x))
            local angle_diff = math.abs(((test_angle - move_angle + 540) % 360) - 180)
            score = score - angle_diff * 0.5
        end
        
        if score > best_score then
            best_score = score
            best_angle = test_angle
        end
    end
    
    resolver.brute_force_cache[cache_key] = best_angle
    return best_angle
end

local function smooth_angle(current, target, factor)
    local delta = ((target - current) % 360 + 540) % 360 - 180
    return current + delta * factor
end

local function adjust_hitbox_position(hitbox_pos, aa_type, duck_amount, is_airborne, side)
    if not hitbox_pos then return nil end
    local adjusted = {x = hitbox_pos.x, y = hitbox_pos.y, z = hitbox_pos.z}
    
    local shift_x = math.cos(math.rad(side * 58)) * max_hitbox_shift * 0.8
    local shift_y = math.sin(math.rad(side * 58)) * max_hitbox_shift * 0.8
    
    adjusted.x = adjusted.x + shift_x
    adjusted.y = adjusted.y + shift_y
    
    if aa_type == "air_crouch" and is_airborne and duck_amount > air_crouch_threshold then
        adjusted.z = adjusted.z - max_hitbox_shift * duck_amount * 1.2
    elseif aa_type:match("desync") and duck_amount > 0.1 then
        adjusted.z = adjusted.z - max_hitbox_shift * 0.3 * duck_amount
    elseif aa_type:match("lby") or aa_type == "duck_desync" then
        adjusted.z = adjusted.z - max_hitbox_shift * 0.5
    elseif aa_type:match("jitter") then
        adjusted.z = adjusted.z - max_hitbox_shift * 0.2
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
            shot_records = create_circular_buffer(32),
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
            last_anim_layers = {},
            lby_history = create_circular_buffer(16),
            velocity_history = create_circular_buffer(16)
        }
        resolver.last_simulation_time[steam_id] = 0
    end

    local sim_time = entity.get_prop(player, "m_flSimulationTime") or 0
    if sim_time <= 0 or (resolver.last_simulation_time[steam_id] and sim_time <= resolver.last_simulation_time[steam_id]) or 
       math.abs(sim_time - (resolver.last_simulation_time[steam_id] or 0)) > 1 or 
       math.abs(sim_time - (resolver.last_simulation_time[steam_id] or 0)) < min_sim_time_delta then
        return
    end

    local eye_angles = {entity.get_prop(player, "m_angEyeAngles")}
    if not eye_angles[1] or not eye_angles[2] or math.abs(eye_angles[2]) > max_yaw_delta or math.abs(eye_angles[1]) > max_pitch_delta then
        return
    end

    local hitbox_pos = get_hitbox_position(player, 0)
    local velocity, velocity_vec = calculate_velocity(player)
    local records = resolver.player_records[steam_id]
    local lby = entity.get_prop(player, "m_flLowerBodyYawTarget") or 0

    if hitbox_pos and records.last_valid_pos and calculate_distance(records.last_valid_pos, hitbox_pos) > teleport_threshold then
        records.last_teleport_time = globals.realtime()
        records.anomaly_detected = true
    end
    if hitbox_pos then records.last_valid_pos = hitbox_pos end

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
        anim_layers = anim_layers,
        lby = lby
    })

    records.lby_history:push(lby)
    records.velocity_history:push(velocity)

    records.aa_type = detect_anti_aim_type(records)
    resolver.last_simulation_time[steam_id] = sim_time
    records.last_valid_sim_time = sim_time
    records.last_anim_state = anim_state
    records.last_move_state = velocity > 15
    records.last_anim_layers = anim_layers
end

function resolver.resolve_angles(player)
    if not ui.get(resolver.enabled) then return end

    local steam_id = entity.get_steam64(player)
    if not steam_id or not resolver.player_records[steam_id] then return end

    local records = resolver.player_records[steam_id]
    if not records.last_angles or records.last_angles:len() < 2 then return end

    local aa_type = records.aa_type
    local side = predict_desync_advanced(player, steam_id, records, aa_type)
    records.learned_side = side
    
    local base_angle = records.last_angles:get(1).angles[2]
    local resolve_angle = base_angle

    local desync_amount = ({
        ["lag_spike"] = 95, ["spinbot"] = 120, ["teleport"] = 140, ["fakelag"] = 105,
        ["jitter"] = 65, ["micro_jitter"] = 35, ["adaptive_jitter"] = 70,
        ["desync"] = 58, ["lby_fake"] = 110, ["dynamic_lby"] = 105,
        ["air_crouch"] = 80, ["duck_desync"] = 75, ["fake_duck"] = 85,
        ["hideshot"] = 90, ["layer_exploit"] = 75, ["move_jitter"] = 70,
        ["micro_adjust"] = 25, ["static_low"] = 15
    })[aa_type] or 58

    desync_amount = desync_amount * (1 + math.min(records.missed_shots * 0.35, 2.0))
    desync_amount = math.min(desync_amount, 140)

    local duck_amount = entity.get_prop(player, "m_flDuckAmount") or 0
    local is_airborne = bit.band(entity.get_prop(player, "m_fFlags") or 1, 1) == 0
    local velocity = calculate_velocity(player)

    if aa_type:match("desync") or aa_type:match("jitter") then
        desync_amount = desync_amount * (1 + duck_amount * 0.5)
    end
    if velocity > 120 then
        desync_amount = desync_amount * 1.15
    end

    local smooth_factor = 0.85
    resolve_angle = smooth_angle(base_angle, base_angle + (desync_amount * side), smooth_factor)
    resolve_angle = brute_force_resolve(player, steam_id, resolve_angle, records)
    
    resolve_angle = ((resolve_angle % 360 + 540) % 360 - 180)
    records.last_yaw = resolve_angle

    local adjusted_hitbox = adjust_hitbox_position(records.last_valid_pos, aa_type, duck_amount, is_airborne, side)
    if adjusted_hitbox then
        records.last_valid_pos = adjusted_hitbox
    end

    if plist and plist.set then
        plist.set(player, "Force body yaw value", resolve_angle)
        plist.set(player, "Correction active", true)
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
    records.shot_records:push({
        tick = e.tick,
        predicted_angle = records.last_yaw or 0,
        hit = e.hit,
        teleported = e.teleported,
        damage = e.damage,
        hitgroup = e.hitgroup or 0,
        anim_state = entity.get_prop(target, "m_nPlayerAnimState") or 0,
        anim_layers = analyze_anim_layers(target)
    })

    if not (e.hit and e.hitgroup > 0 and e.damage > 0) then
        records.missed_shots = records.missed_shots + 1
        records.learned_side = -records.learned_side or (globals.tickcount() % 2 == 0 and 1 or -1)
        
        if records.missed_shots >= max_misses * 2 then
            records.desync_history:clear()
            records.missed_shots = math.max(0, records.missed_shots - 2)
        end
    else
        records.missed_shots = math.max(0, records.missed_shots - 1)
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
        resolver.brute_force_cache = {}
        return
    end

    local current_time = globals.realtime()
    if current_time - resolver.last_update < update_interval then return end
    resolver.last_update = current_time

    update_tickrate()
    local targets = get_targets()
    
    for _, player in ipairs(targets) do
        resolver.record_player(player)
        resolver.resolve_angles(player)
    end

    for steam_id, record in pairs(resolver.player_records) do
        local is_valid = false
        for _, player in ipairs(entity.get_players(true)) do
            if entity.get_steam64(player) == steam_id then
                is_valid = true
                break
            end
        end

        local last_teleport = record.last_teleport_time or 0
        local time_since_teleport = current_time - last_teleport

        if not is_valid or time_since_teleport > 1.5 then
            resolver.player_records[steam_id] = nil
            resolver.last_simulation_time[steam_id] = nil
            resolver.brute_force_cache[steam_id .. "_"] = nil
        end
        
        if record.last_angles:len() > max_history then
            record.last_angles:clear()
        end
    end
    
    if globals.tickcount() % 128 == 0 then
        resolver.brute_force_cache = {}
    end
end

local ui_group_a = {"LUA", "A"}
resolver.enabled = ui.new_checkbox(ui_group_a[1], ui_group_a[2], "Resolver", false)

local tracer_enabled = ui.new_checkbox("LUA", "A", "Bullet tracers")
local tracer_color = ui.new_color_picker("LUA", "A", "Tracer color", 255, 255, 255, 255)
local tracer_duration = ui.new_slider("LUA", "A", "Tracer duration", 1, 50, 20, true, "s", 0.1)
local tracer_thickness = ui.new_slider("LUA", "A", "Tracer thickness", 1, 5, 1, true, "px")
local tracer_fade = ui.new_checkbox("LUA", "A", "Tracer fade effect")

local tracer_queue = {}
local max_tracers = 50

local function calculate_fade_alpha(start_time, duration, curtime)
    if not ui.get(tracer_fade) then return 255 end
    local elapsed = curtime - start_time
    local progress = elapsed / duration
    return math.max(0, math.floor(255 * (1 - progress)))
end

client.set_event_callback("bullet_impact", function(e)
    if not ui.get(tracer_enabled) then return end
    local local_player = entity.get_local_player()
    if client.userid_to_entindex(e.userid) ~= local_player then return end

    local lx, ly, lz = client.eye_position()
    local curtime = globals.curtime()
    local duration = ui.get(tracer_duration) * 0.1
    
    tracer_queue[globals.tickcount()] = {
        start_x = lx, start_y = ly, start_z = lz,
        end_x = e.x, end_y = e.y, end_z = e.z,
        start_time = curtime, duration = duration
    }

    local count = 0
    for tick in pairs(tracer_queue) do
        count = count + 1
        if count > max_tracers then tracer_queue[tick] = nil end
    end
end)

client.set_event_callback("paint", function()
    resolver.update()
    
    if not ui.get(tracer_enabled) then return end

    local curtime = globals.curtime()
    local r, g, b = ui.get(tracer_color)
    local thickness = ui.get(tracer_thickness)

    for tick, data in pairs(tracer_queue) do
        if curtime <= data.start_time + data.duration then
            local x1, y1 = renderer.world_to_screen(data.start_x, data.start_y, data.start_z)
            local x2, y2 = renderer.world_to_screen(data.end_x, data.end_y, data.end_z)
            if x1 and x2 and y1 and y2 then
                local alpha = calculate_fade_alpha(data.start_time, data.duration, curtime)
                renderer.line(x1, y1, x2, y2, r, g, b, alpha, thickness)
            end
        else
            tracer_queue[tick] = nil
        end
    end
end)

client.set_event_callback("player_hurt", function(e)
    if not ui.get(resolver.enabled) then return end
    local attacker = client.userid_to_entindex(e.attacker)
    local victim = client.userid_to_entindex(e.userid)
    local local_player = entity.get_local_player()
    if not local_player or attacker ~= local_player or victim == local_player then return end
    resolver.on_shot_fired({
        target = victim,
        hit = true,
        damage = e.dmg_health,
        hitgroup = e.hitgroup,
        tick = globals.tickcount(),
        teleported = false
    })
end)

client.set_event_callback("aim_hit", function(e)
    if not ui.get(resolver.enabled) then return end
    resolver.on_shot_fired({
        target = e.target,
        hit = true,
        damage = e.damage,
        hitgroup = e.hitgroup,
        tick = globals.tickcount(),
        teleported = false
    })
end)

client.set_event_callback("round_prestart", function()
    tracer_queue = {}
end)

client.set_event_callback("unload", function()
    tracer_queue = {}
end)

client.set_event_callback("player_disconnect", function(e)
    local steam_id = entity.get_steam64(e.userid)
    if steam_id then
        resolver.player_records[steam_id] = nil
        resolver.last_simulation_time[steam_id] = nil
        resolver.brute_force_cache[steam_id .. "_"] = nil
    end
end)

client.set_event_callback("round_start", function()
    tracer_queue = {}
    resolver.brute_force_cache = {}
end)

client.set_event_callback("level_init", function()
    resolver.player_records = {}
    resolver.last_simulation_time = {}
    resolver.brute_force_cache = {}
    resolver.last_valid_tick = globals.tickcount()
end)

client.log("zero.tech loaded")
