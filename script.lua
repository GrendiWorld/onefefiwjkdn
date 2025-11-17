local ZeroTech = {}
ZeroTech.Dependencies = {
    ffi = require("ffi"),
    vector = require("vector"),
    trace = require("gamesense/trace")
}
ZeroTech.Constants = {
    MAX_HISTORY = 50000,
    MAX_DESYNC_HISTORY = 25000,
    MAX_SHOT_HISTORY = 256,
    DESYNC_THRESHOLD = function(ping) return 25 + ping * 0.05 end,
    JITTER_THRESHOLD = function(tickrate) return 50 + (tickrate / 64) * 10 end,
    UPDATE_INTERVAL = function(tickrate) return 0.0001 * (64 / tickrate) end,
    TELEPORT_THRESHOLD = 200,
    MAX_MISSES = 8,
    FOV_THRESHOLD = 180,
    MAX_YAW_DELTA = 360,
    MAX_PITCH_DELTA = 180,
    PING_THRESHOLD = 150,
    MAX_VELOCITY = 2000,
    MAX_ANIM_LAYERS = 15,
    MIN_SIM_TIME_DELTA = function(tickrate) return 0.0005 * (64 / tickrate) end,
    MAX_HITBOX_SHIFT = 25,
    LAG_SPIKE_THRESHOLD = 0.1,
    MAX_DESYNC = 64,
    ML_WINDOW = 256,
    BRUTE_FORCE_ATTEMPTS = 128,
    PATTERN_CONFIDENCE_THRESHOLD = 0.95,
    MAX_TRAIL_SEGMENTS = 1000,
    FAKELAG_THRESHOLD = 16,
    MICRO_DESYNC_MIN = 0.05,
    MICRO_DESYNC_MAX = 1.2,
    LBY_BREAK_MIN = 40,
    EYE_YAW_RATE_MIN = 9.5,
    GOAL_FEET_DELTA_MIN = 48,
    VELOCITY_DIR_THRESHOLD = 7.2,
    PITCH_EXPLOIT_MIN = 88,
    ROLL_DESYNC_MIN = 42,
    LAYER_BREAK_3_MIN = 0.96,
    FAKEWALK_THRESHOLD = 0.12,
    OVERRIDE_CONFIDENCE_MIN = 0.85,
    HISTORY_CONFIDENCE_WINDOW = 24,
    BRUTEFORCE_STAGES = 3
}
ZeroTech.Utils = {
    clamp = function(v, min, max) return math.max(min, math.min(max, v)) end,
    normalize_angle = function(a)
        if not a or type(a) ~= "number" then return 0 end
        a = a % 360
        return a > 180 and (a - 360) or (a < -180 and (a + 360) or a)
    end,
    angle_difference = function(a, b)
        local d = (a - b) % 360
        return d > 180 and (d - 360) or (d <= -180 and (d + 360) or d)
    end,
    angle_to_vector = function(p, y)
        local pr, yr = math.rad(p), math.rad(y)
        local sp, cp = math.sin(pr), math.cos(pr)
        local sy, cy = math.sin(yr), math.cos(yr)
        return cp * cy, cp * sy, -sp
    end,
    vector_to_angle = function(vx, vy, vz)
        local hyp = math.sqrt(vx*vx + vy*vy)
        if hyp < 0.001 then return {x=0, y=0, z=0} end
        return {
            x = math.deg(math.atan2(-vz, hyp)),
            y = math.deg(math.atan2(vy, vx)),
            z = 0
        }
    end,
    time_to_ticks = function(t) return math.floor(0.5 + t / globals.tickinterval()) end,
    ticks_to_time = function(t) return t * globals.tickinterval() end,
    std_dev = function(t)
        if #t < 2 then return 0 end
        local m = 0 for _,v in ipairs(t) do m = m + v end m = m / #t
        local v = 0 for _,x in ipairs(t) do v = v + (x-m)^2 end
        return math.sqrt(v / (#t-1))
    end,
    calculate_distance = function(a,b)
        if not a or not b then return math.huge end
        local dx,dy,dz = a.x-b.x, a.y-b.y, a.z-b.z
        return math.sqrt(dx*dx + dy*dy + dz*dz)
    end,
    calculate_distance_2d = function(a,b)
        if not a or not b then return math.huge end
        local dx,dy = a.x-b.x, a.y-b.y
        return math.sqrt(dx*dx + dy*dy)
    end,
    extrapolate_position = function(pos, vel, ticks)
        local ti = globals.tickinterval()
        return {x=pos.x+vel.x*ti*ticks, y=pos.y+vel.y*ti*ticks, z=pos.z+vel.z*ti*ticks}
    end,
    predict_eye_angles = function(p, ticks)
        local eye = {entity.get_prop(p, "m_angEyeAngles")}
        local vel = {entity.get_prop(p, "m_vecVelocity")}
        if not eye[2] or not vel[1] then return eye end
        local speed = math.sqrt(vel[1]*vel[1] + vel[2]*vel[2])
        if speed < 5 then return eye end
        local yaw = eye[2]
        local vyaw = math.deg(math.atan2(vel[2], vel[1]))
        local delta = ZeroTech.Utils.angle_difference(vyaw, yaw)
        return {x=eye[1], y=ZeroTech.Utils.normalize_angle(yaw + delta*0.26*ticks), z=eye[3] or 0}
    end,
    get_animstate = function(p) return ZeroTech.Entity.get_animation_state(p) end,
    get_layer_weight = function(p, l) local layer = ZeroTech.Entity.get_animation_layers(p, l) return layer and layer.weight or 0 end,
    get_pose = function(p, i) return entity.get_prop(p, "m_flPoseParameter", i) or 0 end,
    is_on_ground = function(p) return bit.band(entity.get_prop(p, "m_fFlags") or 0, 1) == 1 end,
    get_velocity_yaw = function(p)
        local vx,vy = entity.get_prop(p, "m_vecVelocity")
        if not vx then return 0 end
        return math.deg(math.atan2(vy, vx))
    end,
    smoothstep = function(e0,e1,x) x=ZeroTech.Utils.clamp((x-e0)/(e1-e0),0,1) return x*x*(3-2*x) end,
    lerp = function(a,b,t) return a + (b-a)*t end,
    ease_out_quint = function(t) return 1 - math.pow(1-t,5) end,
    predict_desync_side = function(animstate, vel)
        if not animstate then return 1 end
        local er = math.abs(animstate.eye_yaw - animstate.current_feet_yaw)
        local gd = ZeroTech.Utils.angle_difference(animstate.goal_feet_yaw, animstate.current_feet_yaw)
        if er > 11 then return animstate.eye_yaw > animstate.current_feet_yaw and -1 or 1 end
        if math.abs(gd) > 52 then return gd > 0 and -1 or 1 end
        if vel > 280 then
            local vyaw = ZeroTech.Utils.get_velocity_yaw(entity.get_local_player())
            return ZeroTech.Utils.angle_difference(animstate.current_feet_yaw, vyaw) > 0 and 1 or -1
        end
        return 1
    end
}

ZeroTech.Dependencies.ffi.cdef[[
    struct animstate { char pad[0x18]; float duck_amount; char pad1[0xC]; float feet_yaw_rate; char pad2[0x54]; void* entity; void* weapon; float last_update_time; int last_update_frame; float eye_yaw; float pitch; float goal_feet_yaw; float current_feet_yaw; char pad3[0x70]; float velocity_x; float velocity_y; char pad4[0x40]; float min_yaw; float max_yaw; };
    struct animlayer { char pad[0x18]; uint32_t sequence; float prev_cycle; float weight; float weight_delta_rate; float playback_rate; float cycle; void* entity; char pad2[0x4]; };
]]

ZeroTech.Entity = {
    get_ptr = function(ent)
        if not ent then return nil end
        local ptr = entity.get_prop(ent, "m_pEntity")
        return ptr and ptr ~= 0 and ffi.cast("void*", ptr) or nil
    end,
    get_animation_state = function(p)
        local ptr = ZeroTech.Entity.get_ptr(p)
        if not ptr then return nil end
        local state_ptr = ffi.cast("uintptr_t*", ptr + 0x9960)[0]
        if not state_ptr or state_ptr == 0 then return nil end
        return ffi.cast("struct animstate*", state_ptr)[0]
    end,
    get_animation_layers = function(p, layer)
        local ptr = ZeroTech.Entity.get_ptr(p)
        if not ptr then return nil end
        local layers = ffi.cast("struct animlayer(*)[15]", ptr + 0x9E80)[0]
        return layer and layers[layer] or layers
    end,
    is_player_valid = function(p) return p and entity.is_alive(p) and not entity.is_dormant(p) end
}

ZeroTech.Resolver = {
    ui = {
        enabled = ui.new_checkbox("LUA", "A", "Resolver"),
        debug = ui.new_checkbox("LUA", "A", "Debug Info"),
        debug_color = ui.new_color_picker("LUA", "A", "Debug Color", 255, 255, 255, 255)
    },
    player_records = {},
    last_simulation_time = {},
    last_update = globals.realtime(),
    last_valid_tick = globals.tickcount(),
    tickrate = 64,
    create_circular_buffer = function(size)
        local b = {size=size, data={}, head=0}
        function b:push(v) self.head=(self.head%self.size)+1 self.data[self.head]=v end
        function b:get(i) if not i or i<1 or i>self:len() then return nil end return self.data[(self.head-i+self.size)%self.size+1] end
        function b:len() return math.min(self.head,self.size) end
        function b:avg() local s,c=0,0 for i=1,self:len() do local v=self:get(i) if v then s=s+v c=c+1 end end return c>0 and s/c or 0 end
        return b
    end,
    update_tickrate = function()
        local i = globals.tickinterval()
        ZeroTech.Resolver.tickrate = i>0 and math.floor(1/i+0.5) or 64
    end,
    is_server_lagging = function()
        local ct = globals.tickcount()
        local d = ct - ZeroTech.Resolver.last_valid_tick
        ZeroTech.Resolver.last_valid_tick = ct
        return d > ZeroTech.Resolver.tickrate * 0.18
    end,
    get_targets = function()
        local t = {}
        local lp = entity.get_local_player()
        if not lp or not entity.is_alive(lp) then return t end
        local lx,ly = entity.get_prop(lp, "m_vecOrigin")
        local view = {client.camera_angles()}
        if not view[2] then return t end
        for _,p in ipairs(entity.get_players(true)) do
            if ZeroTech.Entity.is_player_valid(p) then
                local px,py = entity.get_prop(p, "m_vecOrigin")
                if px then
                    local dx,dy = px-lx, py-ly
                    local yaw = ZeroTech.Utils.normalize_angle(math.deg(math.atan2(dy,dx))-view[2])
                    if math.abs(yaw)<=ZeroTech.Constants.FOV_THRESHOLD then
                        table.insert(t,{player=p,angle=math.abs(yaw)})
                    end
                end
            end
        end
        table.sort(t,function(a,b) return a.angle<b.angle end)
        local s={} for _,v in ipairs(t) do table.insert(s,v.player) end
        return s
    end,
    get_hitbox_position = function(p,h) local x,y,z=entity.hitbox_position(p,h) return x and {x=x,y=y,z=z} or nil end,
    calculate_velocity = function(p)
        local vx,vy,vz = entity.get_prop(p, "m_vecVelocity")
        if not vx then return 0,{x=0,y=0,z=0} end
        local s = math.sqrt(vx*vx+vy*vy+vz*vz)
        return s<ZeroTech.Constants.MAX_VELOCITY and s or 0, {x=vx,y=vy,z=vz}
    end,
    calculate_velocity_dir = function(p)
        local vx,vy = entity.get_prop(p, "m_vecVelocity")
        if not vx then return 0 end
        local ey = ({entity.get_prop(p, "m_angEyeAngles")})[2] or 0
        local vyaw = math.deg(math.atan2(vy,vx))
        return ZeroTech.Utils.angle_difference(vyaw, ey)
    end,
    detect_aa_type = function(records, player)
        if not records or not records.last_angles or records.last_angles:len()<20 then return "unknown" end
        local yaw, lby, vel, duck, eye, goal, layer6, layer7, layer8, roll, simd = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
        for i=1,math.min(20,records.last_angles:len()) do
            local d=records.last_angles:get(i)
            if d then
                table.insert(yaw,d.angles[2]or 0)
                table.insert(vel,d.velocity or 0)
                table.insert(simd,d.sim_time or 0)
                table.insert(lby,ZeroTech.Utils.get_pose(player,11))
                local a=ZeroTech.Utils.get_animstate(player)
                if a then
                    table.insert(eye,math.abs(a.eye_yaw-a.current_feet_yaw))
                    table.insert(goal,math.abs(ZeroTech.Utils.angle_difference(a.goal_feet_yaw,a.current_feet_yaw)))
                end
table.insert(layer6, ZeroTech.Utils.get_layer_weight(player, 6) or 0)
table.insert(layer7, ZeroTech.Utils.get_layer_weight(player, 7) or 0)
table.insert(layer8, ZeroTech.Utils.get_layer_weight(player, 8) or 0)
table.insert(roll, math.abs(({entity.get_prop(player, "m_angEyeAngles")})[3] or 0))
            end
        end
        local ystd = ZeroTech.Utils.std_dev(yaw)
        local lstd = ZeroTech.Utils.std_dev(lby)
        local sstd = ZeroTech.Utils.std_dev(simd)
        local avgv = vel[#vel]or 0
        local maxl6=layer6[#layer6]or 0
        local maxl7=layer7[#layer7]or 0
        local maxl8=layer8[#layer8]or 0
        local maxeye=eye[#eye]or 0
        local maxgoal=goal[#goal]or 0
        local maxroll=roll[#roll]or 0
        local vdir=ZeroTech.Resolver.calculate_velocity_dir(player)
        if ZeroTech.Resolver.is_server_lagging()or sstd>0.08 then return "fakelag_extreme" end
        if ystd>160 then return "spinbot_v2" end
        if ystd>85 and ystd<145 then return "half_spin_v2" end
        if sstd<ZeroTech.Constants.FAKEWALK_THRESHOLD and avgv>5 and avgv<18 then return "fakewalk" end
        if maxl6>0.965 or maxl7>0.965 or maxl8>0.965 then return "layer_break_v4" end
        if lstd>ZeroTech.Constants.LBY_BREAK_MIN and ystd<7 and avgv<25 then return "lby_breaker_v4" end
        if ystd>0 and ystd<ZeroTech.Constants.MICRO_DESYNC_MAX and ystd>ZeroTech.Constants.MICRO_DESYNC_MIN and records.missed_shots>2 then return "micro_desync_v2" end
        if maxeye>ZeroTech.Constants.EYE_YAW_RATE_MIN then return "eye_yaw_exploit_v2" end
        if maxgoal>ZeroTech.Constants.GOAL_FEET_DELTA_MIN then return "goal_feet_exploit_v2" end
        if math.abs(vdir)>ZeroTech.Constants.VELOCITY_DIR_THRESHOLD then return "velocity_dir_exploit" end
        if maxroll>ZeroTech.Constants.ROLL_DESYNC_MIN then return "roll_desync" end
        if records.missed_shots>6 and ystd<2 then return "anti_resolver_v2" end
        if avgv>320 and ystd<3.5 then return "velocity_exploit_v3" end
        if ystd>65 then return "extreme_jitter_v2" end
        if ystd>42 then return "jitter_v2" end
        if ystd>28 and lstd<12 then return "desync_spam_v2" end
        if ystd>18 and lstd>35 then return "desync_v2" end
        local o={entity.get_prop(player,"m_vecOrigin")} if o[1] then
            local h=ZeroTech.Resolver.get_hitbox_position(player,0)
            if h then
                for d=45,65,10 do
                    local l=ZeroTech.Dependencies.trace.line(player,h.x+d,h.y,h.z+10,o[1],o[2],o[3])
                    local r=ZeroTech.Dependencies.trace.line(player,h.x-d,h.y,h.z+10,o[1],o[2],o[3])
                    if l and r then
                        if l.fraction>0.98 and r.fraction<0.72 then return "freestanding_left_v2" end
                        if r.fraction>0.98 and l.fraction<0.72 then return "freestanding_right_v2" end
                    end
                end
            end
        end
        return "static_v2"
    end,
    ml_confidence_score = function(records)
        if records.desync_history:len()<ZeroTech.Constants.HISTORY_CONFIDENCE_WINDOW then return 0 end
        local l,r=0,0
        for i=1,ZeroTech.Constants.HISTORY_CONFIDENCE_WINDOW do
            local s=records.desync_history:get(i)
            if s then if s>0 then l=l+1 else r=r+1 end end
        end
        local conf = math.max(l,r)/ZeroTech.Constants.HISTORY_CONFIDENCE_WINDOW
        return conf>ZeroTech.Constants.OVERRIDE_CONFIDENCE_MIN and (l>r and 1 or -1) or 0
    end,
    predict_desync = function(player, steam_id, records, aa_type)
        if not records.last_angles or records.last_angles:len()<6 then return (records.learned_side or 1)*58 end
        local animstate = ZeroTech.Utils.get_animstate(player)
        if not animstate then return 0 end
        local velocity = records.last_angles:get(1).velocity or 0
        local duck = entity.get_prop(player, "m_flDuckAmount") or 0
        local ping = entity.get_prop(player, "m_iPing") or 0
        local tick = globals.tickcount()
        local side = ZeroTech.Utils.predict_desync_side(animstate, velocity)
        local conf_side = ZeroTech.Resolver.ml_confidence_score(records)~=0 and ZeroTech.Resolver.ml_confidence_score(records) or side
        local final_side = records.learned_side or conf_side
        local dynamic_max = ZeroTech.Constants.MAX_DESYNC * (1 - ZeroTech.Utils.smoothstep(0,500,velocity))
        local ping_factor = ZeroTech.Utils.lerp(1.0,1.38,ZeroTech.Utils.smoothstep(0,220,ping))
        local duck_factor = duck>0.75 and 1.28 or 1.0
        local air_factor = ZeroTech.Utils.is_on_ground(player) and 1.0 or 1.18
        local layer_break = math.max(ZeroTech.Utils.get_layer_weight(player,6),ZeroTech.Utils.get_layer_weight(player,7),ZeroTech.Utils.get_layer_weight(player,8))>0.965
        local mult = {
            spinbot_v2=1.85, half_spin_v2=2.05, fakelag_extreme=1.32,
            layer_break_v4=2.78, lby_breaker_v4=2.92, micro_desync_v2=0.38,
            eye_yaw_exploit_v2=3.12, goal_feet_exploit_v2=3.25,
            velocity_dir_exploit=2.58, roll_desync=2.48, fakewalk=1.92,
            velocity_exploit_v3=2.28, freestanding_left_v2=2.68,
            freestanding_right_v2=2.68, anti_resolver_v2=3.45,
            extreme_jitter_v2=2.88, jitter_v2=2.48, desync_spam_v2=2.28,
            desync_v2=2.05, hideshot_static_v2=2.58, teleport_exploit=0
        }
        local m = mult[aa_type] or 1.95
        local delta = final_side * dynamic_max * m * ping_factor * duck_factor * air_factor * (1 + records.missed_shots*0.48)
        if aa_type:find("jitter") or aa_type:find("spin") then
            delta = delta + math.sin(tick*0.371)*28
        elseif aa_type=="micro_desync_v2" then
            delta = final_side * (records.missed_shots>5 and 52 or records.missed_shots>2 and 28 or 12)
        elseif aa_type=="anti_resolver_v2" then
            delta = delta + (tick%4<2 and 72 or -72)
        end
        records.desync_history:push(final_side * math.abs(delta))
        return math.min(math.abs(delta),ZeroTech.Constants.MAX_DESYNC) * final_side
    end,
    brute_force_resolve = function(records, base)
        if records.missed_shots<2 then return base end
        local best_conf, best_ang = -math.huge, base
        for stage=1,ZeroTech.Constants.BRUTEFORCE_STAGES do
            local step = 144/(2^(stage-1))
            for off=-72,72,step do
                local test = ZeroTech.Utils.normalize_angle(base + off)
                local score = 0
                if records.learned_side then score = score + (math.abs(ZeroTech.Utils.angle_difference(test,base+records.learned_side*58))<25 and 15 or 0) end
                if records.shot_records:len()>0 then
                    local last = records.shot_records:get(1)
                    if last and last.predicted then score = score + (records.missed_shots*8)/(math.abs(ZeroTech.Utils.angle_difference(test,last.predicted))+1) end
                end
                local pose = ZeroTech.Utils.get_pose(records.last_angles:get(1).player,11)
                score = score + (math.abs(ZeroTech.Utils.angle_difference(test,(pose*120-60)))<20 and 12 or 0)
                if score>best_conf then best_conf,best_ang=score,test end
            end
        end
        return best_ang
    end,
    resolve_angles = function(player)
        local sid = entity.get_steam64(player)
        if not sid or not ZeroTech.Resolver.player_records[sid] then return end
        local r = ZeroTech.Resolver.player_records[sid]
        if not r.last_angles or r.last_angles:len()<5 then return end
        local aa = r.aa_type or "static_v2"
        local base = r.last_angles:get(1).angles[2] or 0
        local delta = ZeroTech.Resolver.predict_desync(player,sid,r,aa)
        local yaw = r.missed_shots>=4 or aa:find("anti_resolver") and ZeroTech.Resolver.brute_force_resolve(r,base) or ZeroTech.Utils.normalize_angle(base+delta)
        r.last_yaw = yaw
        if package.loaded["gamesense/plist"] then
            local plist = require("gamesense/plist")
            plist.set(player,"Force body yaw",yaw)
            plist.set(player,"Correction active",true)
        end
        return yaw
    end,
    record_player = function(player)
        if not ZeroTech.Entity.is_player_valid(player) then return end
        local sid = entity.get_steam64(player)
        if not sid then return end
        if not ZeroTech.Resolver.player_records[sid] then
            ZeroTech.Resolver.player_records[sid] = {
                last_angles = ZeroTech.Resolver.create_circular_buffer(ZeroTech.Constants.MAX_HISTORY),
                desync_history = ZeroTech.Resolver.create_circular_buffer(ZeroTech.Constants.MAX_DESYNC_HISTORY),
                shot_records = ZeroTech.Resolver.create_circular_buffer(ZeroTech.Constants.MAX_SHOT_HISTORY),
                missed_shots = 0, learned_side = nil, last_yaw = nil, aa_type = "static_v2",
                last_teleport_time = 0, last_valid_pos = nil, last_sim_time = 0
            }
        end
        local rec = ZeroTech.Resolver.player_records[sid]
        local sim = entity.get_prop(player,"m_flSimulationTime")or 0
        if sim<=rec.last_sim_time then return end
        rec.last_sim_time = sim
        local eye = {entity.get_prop(player,"m_angEyeAngles")}
        if not eye[2] then return end
        local head = ZeroTech.Resolver.get_hitbox_position(player,0)
        local vel,_ = ZeroTech.Resolver.calculate_velocity(player)
        if head and rec.last_valid_pos and ZeroTech.Utils.calculate_distance(head,rec.last_valid_pos)>ZeroTech.Constants.TELEPORT_THRESHOLD*2.5 then
            rec.last_teleport_time = globals.realtime()
        end
        rec.last_valid_pos = head
        rec.last_angles:push({angles=eye,sim_time=sim,velocity=vel,tick=globals.tickcount(),player=player})
        rec.aa_type = ZeroTech.Resolver.detect_aa_type(rec,player)
    end,
    on_shot_fired = function(e)
        local t = e.target
        if not t then return end
        local sid = entity.get_steam64(t)
        if not sid or not ZeroTech.Resolver.player_records[sid] then return end
        local r = ZeroTech.Resolver.player_records[sid]
        r.shot_records:push({tick=globals.tickcount(),predicted=r.last_yaw or 0,hit=e.hit,hitgroup=e.hitgroup or 0})
        if not e.hit or e.hitgroup==0 then
            r.missed_shots = r.missed_shots + 1
            r.learned_side = r.learned_side and -r.learned_side or (globals.tickcount()%2==0 and 1 or -1)
        else
            r.missed_shots = 0
            r.learned_side = nil
        end
    end,
    update = function()
        if not ui.get(ZeroTech.Resolver.ui.enabled) then
            for _,p in ipairs(entity.get_players(true)) do if package.loaded["gamesense/plist"] then local plist = require("gamesense/plist") plist.set(p,"Correction active",false) end end
            ZeroTech.Resolver.player_records = {}
            ZeroTech.Resolver.last_simulation_time = {}
            return
        end
        local now = globals.realtime()
        if now - ZeroTech.Resolver.last_update < ZeroTech.Constants.UPDATE_INTERVAL(ZeroTech.Resolver.tickrate) then return end
        ZeroTech.Resolver.last_update = now
        ZeroTech.Resolver.update_tickrate()
        for _,p in ipairs(ZeroTech.Resolver.get_targets()) do
            ZeroTech.Resolver.record_player(p)
            ZeroTech.Resolver.resolve_angles(p)
        end
        for sid,rec in pairs(ZeroTech.Resolver.player_records) do
            local alive = false
            for _,p in ipairs(entity.get_players(true)) do if entity.get_steam64(p)==sid then alive=true break end end
            if not alive or (rec.last_teleport_time>0 and globals.realtime()-rec.last_teleport_time>2.5) then
                ZeroTech.Resolver.player_records[sid]=nil
                ZeroTech.Resolver.last_simulation_time[sid]=nil
            end
        end
    end
}

client.set_event_callback("paint", ZeroTech.Resolver.update)
client.set_event_callback("aim_hit", ZeroTech.Resolver.on_shot_fired)
client.set_event_callback("aim_miss", ZeroTech.Resolver.on_shot_fired)

ZeroTech.Visuals = {
    scope = {
        enabled = ui.new_checkbox("LUA", "A", "Scope Lines"),
        color = ui.new_color_picker("LUA", "A", "Color", 100, 255, 100, 255),
        length = ui.new_slider("LUA", "A", "Length", 50, 500, 220, true, "px"),
        gap = ui.new_slider("LUA", "A", "Gap", 5, 100, 18, true, "px"),
        thickness = ui.new_slider("LUA", "A", "Thickness", 1, 5, 2, true, "px"),
        fade_speed = ui.new_slider("LUA", "A", "Fade Speed", 5, 30, 16, true, "fr"),
        rainbow = ui.new_checkbox("LUA", "A", "Rainbow"),
        rainbow_speed = ui.new_slider("LUA", "A", "Rainbow Speed", 1, 100, 12, true, "%")
    },
    anim = { alpha = 0, target = 0, last_tick = 0 },
    is_scoped = function()
        local lp = entity.get_local_player()
        return lp and entity.is_alive(lp) and entity.get_prop(lp, "m_bIsScoped") == 1
    end
}

ZeroTech.BulletTracers = {
    enabled = ui.new_checkbox("LUA", "A", "Bullet Tracers"),
    color = ui.new_color_picker("LUA", "A", "Color", 255, 200, 100, 255),
    thickness = ui.new_slider("LUA", "A", "Thickness", 1, 8, 2, true, "px"),
    duration = ui.new_slider("LUA", "A", "Duration", 5, 50, 18, true, "fr"),
    fade = ui.new_checkbox("LUA", "A", "Fade Effect"),
    gap = ui.new_checkbox("LUA", "A", "Impact Gap"),
    impact_color = ui.new_color_picker("LUA", "A", "Impact Color", 255, 80, 80, 255),
    max_tracers = 64,
    tracers = {},
    calculate_fade = function(start_time, duration, curtime)
        if not ui.get(ZeroTech.BulletTracers.fade) then return 255 end
        local duration_ticks = ui.get(ZeroTech.BulletTracers.duration)
        if duration_ticks <= 0 then return 255 end
        local elapsed = curtime - start_time
        return math.floor(255 * (1 - math.min(elapsed / (duration_ticks * globals.tickinterval()), 1)))
    end
}

ZeroTech.ClanTag = {
    config = {
        animation_speed = 0.15,
        frames = {
            "zero.tech", "zero.te ", "zero.t  ", "zero   ", "zer    ", "ze     ", "z      ", "       ",
            " z     ", "  ze   ", "   zer ", "    zero", "zero.t ", "zero.te", "zero.tech",
            "zero.tech ", "zero.tec ", "zero.te ", "zero.t ", "zero  ", "zer   ", "ze    ", "z     ",
            "zero.tech|", "|zero.tech", "zero.tech ", " zero.tech", "zero.tech "
        }
    },
    state = {
        is_enabled = false,
        last_update = 0,
        current_frame = 1,
        last_clantag = ""
    },
    ui_elements = {
        checkbox = ui.new_checkbox("LUA", "A", "Clan Tag"),
        speed_slider = ui.new_slider("LUA", "A", "Speed", 1, 20, 8, true, "fr")
    },
    safe_set_clantag = function(tag)
        if tag == ZeroTech.ClanTag.state.last_clantag then return end
        local success, err = pcall(client.set_clan_tag, tag or "")
        if success then
            ZeroTech.ClanTag.state.last_clantag = tag or ""
        else
            ZeroTech.ClanTag.state.last_clantag = ""
        end
    end,
    set_clantag = function()
        if not ui.get(ZeroTech.ClanTag.ui_elements.checkbox) then
            if ZeroTech.ClanTag.state.last_clantag ~= "" then
                ZeroTech.ClanTag.safe_set_clantag("")
            end
            return
        end
        local current_time = globals.realtime()
        local speed = math.max(0.05, ui.get(ZeroTech.ClanTag.ui_elements.speed_slider) * 0.05)
        if current_time - ZeroTech.ClanTag.state.last_update < speed then return end
        ZeroTech.ClanTag.state.current_frame = (ZeroTech.ClanTag.state.current_frame % #ZeroTech.ClanTag.config.frames) + 1
        local frame = ZeroTech.ClanTag.config.frames[ZeroTech.ClanTag.state.current_frame]
        ZeroTech.ClanTag.safe_set_clantag(frame)
        ZeroTech.ClanTag.state.last_update = current_time
    end
}

ZeroTech.Trails = {
    data = { last_origin = nil, segments = {} },
    clear_trails = function()
        ZeroTech.Trails.data = { last_origin = nil, segments = {} }
    end,
    enable = ui.new_checkbox("LUA", "B", "Enable Trails"),
    segment_exp = ui.new_slider("LUA", "B", "Trail Segment Expiration", 1, 100, 12, true, "s", 0.1),
    trail_type = ui.new_combobox("LUA", "B", "Trail Type", {"Line", "Advanced Line", "Rect"}),
    color_type = ui.new_combobox("LUA", "B", "Trail Color Type", {"Static", "Chroma", "Gradient Chroma"}),
    static_color = ui.new_color_picker("LUA", "B", "Trail Color", 255, 50, 50, 255),
    chroma_speed = ui.new_slider("LUA", "B", "Trail Chroma Speed Multiplier", 1, 100, 1, true, "%", 0.1),
    line_size = ui.new_slider("LUA", "B", "Line Size", 1, 10, 2, true),
    rect_w = ui.new_slider("LUA", "B", "Rect Width", 1, 50, 6, true),
    rect_h = ui.new_slider("LUA", "B", "Rect Height", 1, 50, 6, true),
    trail_x_width = ui.new_slider("LUA", "B", "Trail X Width", 1, 10, 2, true),
    trail_y_width = ui.new_slider("LUA", "B", "Trail Y Width", 1, 10, 2, true),
    get_fade_rgb = function(seed, speed)
        local r = math.floor(math.sin((globals.realtime() + seed) * speed) * 127 + 128)
        local g = math.floor(math.sin((globals.realtime() + seed) * speed + 2) * 127 + 128)
        local b = math.floor(math.sin((globals.realtime() + seed) * speed + 4) * 127 + 128)
        return r, g, b
    end,
    update_ui_visibility = function()
        local color_type = ui.get(ZeroTech.Trails.color_type)
        local trail_type = ui.get(ZeroTech.Trails.trail_type)
        ui.set_visible(ZeroTech.Trails.static_color, color_type == "Static")
        ui.set_visible(ZeroTech.Trails.chroma_speed, color_type ~= "Static")
        ui.set_visible(ZeroTech.Trails.trail_x_width, trail_type == "Advanced Line")
        ui.set_visible(ZeroTech.Trails.trail_y_width, trail_type == "Advanced Line")
        ui.set_visible(ZeroTech.Trails.line_size, trail_type == "Line")
        ui.set_visible(ZeroTech.Trails.rect_w, trail_type == "Rect")
        ui.set_visible(ZeroTech.Trails.rect_h, trail_type == "Rect")
    end
}

client.set_event_callback("pre_config_save", ZeroTech.Trails.update_ui_visibility)
client.set_event_callback("post_config_load", ZeroTech.Trails.update_ui_visibility)
ui.set_callback(ZeroTech.Trails.color_type, ZeroTech.Trails.update_ui_visibility)
ui.set_callback(ZeroTech.Trails.trail_type, ZeroTech.Trails.update_ui_visibility)

ZeroTech.Watermark = {
    ui = {
        enabled = ui.new_checkbox("LUA", "A", "Watermark"),
        style = ui.new_combobox("LUA", "A", "Style", {"Modern", "Classic", "Minimal", "Glass", "Neon", "Gradient"}),
        accent_color = ui.new_color_picker("LUA", "A", "Accent Color", 100, 150, 255, 255),
        font_size = ui.new_slider("LUA", "A", "Font Size", 10, 30, 14, true, "px"),
        bg_opacity = ui.new_slider("LUA", "A", "BG Opacity", 30, 255, 140, true, "a"),
        border = ui.new_checkbox("LUA", "A", "Border"),
        shadow = ui.new_checkbox("LUA", "A", "Text Shadow"),
        glow = ui.new_checkbox("LUA", "A", "Glow Effect"),
        rounded = ui.new_slider("LUA", "A", "Rounded Corners", 0, 30, 18, true, "px"),
        ping = ui.new_checkbox("LUA", "A", "Ping"),
        fps = ui.new_checkbox("LUA", "A", "FPS"),
        tickrate = ui.new_checkbox("LUA", "A", "Tickrate"),
        draggable = ui.new_checkbox("LUA", "A", "Draggable (Hold Left Click)"),
        reset_pos = ui.new_button("LUA", "A", "Reset Position", function()
            ZeroTech.Watermark.state.pos_x = 15
            ZeroTech.Watermark.state.pos_y = 15
        end)
    },
    state = {
        alpha = 0,
        target_alpha = 0,
        last_tick = 0,
        fps = 0,
        fps_counter = 0,
        last_fps_time = 0,
        pos_x = 15,
        pos_y = 15,
        is_dragging = false,
        drag_start_x = 0,
        drag_start_y = 0
    },
    update_fps = function()
        local curtime = globals.realtime()
        ZeroTech.Watermark.state.fps_counter = ZeroTech.Watermark.state.fps_counter + 1
        if curtime - ZeroTech.Watermark.state.last_fps_time >= 1.0 then
            ZeroTech.Watermark.state.fps = ZeroTech.Watermark.state.fps_counter
            ZeroTech.Watermark.state.fps_counter = 0
            ZeroTech.Watermark.state.last_fps_time = curtime
        end
    end,
    handle_drag = function()
        if not ui.get(ZeroTech.Watermark.ui.enabled) or not ui.get(ZeroTech.Watermark.ui.draggable) then
            ZeroTech.Watermark.state.is_dragging = false
            return
        end
        local mouse_x, mouse_y = ui.mouse_position()
        local is_left_down = client.key_state(0x01)
        if is_left_down and not ZeroTech.Watermark.state.is_dragging then
            local x, y = ZeroTech.Watermark.state.pos_x, ZeroTech.Watermark.state.pos_y
            local w, h = ZeroTech.Watermark.get_size()
            if mouse_x >= x and mouse_x <= x + w and mouse_y >= y and mouse_y <= y + h then
                ZeroTech.Watermark.state.is_dragging = true
                ZeroTech.Watermark.state.drag_start_x = mouse_x - x
                ZeroTech.Watermark.state.drag_start_y = mouse_y - y
            end
        end
        if ZeroTech.Watermark.state.is_dragging then
            if is_left_down then
                ZeroTech.Watermark.state.pos_x = mouse_x - ZeroTech.Watermark.state.drag_start_x
                ZeroTech.Watermark.state.pos_y = mouse_y - ZeroTech.Watermark.state.drag_start_y
                local scr_w, scr_h = client.screen_size()
                ZeroTech.Watermark.state.pos_x = ZeroTech.Utils.clamp(ZeroTech.Watermark.state.pos_x, 0, scr_w - 100)
                ZeroTech.Watermark.state.pos_y = ZeroTech.Utils.clamp(ZeroTech.Watermark.state.pos_y, 0, scr_h - 50)
            else
                ZeroTech.Watermark.state.is_dragging = false
            end
        end
    end,
    get_size = function()
        local text_parts = {"Zero.Tech"}
        if ui.get(ZeroTech.Watermark.ui.ping) then table.insert(text_parts, " | 999ms") end
        if ui.get(ZeroTech.Watermark.ui.fps) then table.insert(text_parts, " | 999 FPS") end
        if ui.get(ZeroTech.Watermark.ui.tickrate) then table.insert(text_parts, " | 999t") end
        local full_text = table.concat(text_parts)
        local text_w, text_h = renderer.measure_text("", full_text)
        local padding_x, padding_y = 16, 10
        return text_w + padding_x * 2, text_h + padding_y * 2
    end,
    render_rounded_rect = function(x, y, w, h, radius, r, g, b, a)
        if radius <= 0 then
            renderer.rectangle(x, y, w, h, r, g, b, a)
            return
        end
        local ir = math.floor(radius)
        if ir <= 0 then return end
        renderer.rectangle(x + ir, y, w - 2*ir, h, r, g, b, a)
        renderer.rectangle(x, y + ir, w, h - 2*ir, r, g, b, a)
        local steps = math.max(6, math.floor(ir * 0.8))
        for i = 0, steps do
            local t = i / steps
            local offset = ir * (1 - t)
            local alpha_step = a * (0.8 + t * 0.2)
            renderer.rectangle(x, y + offset, ir, 1, r, g, b, alpha_step)
            renderer.rectangle(x + offset, y, 1, ir, r, g, b, alpha_step)
            renderer.rectangle(x + w - ir, y + offset, ir, 1, r, g, b, alpha_step)
            renderer.rectangle(x + w - offset - 1, y, 1, ir, r, g, b, alpha_step)
            renderer.rectangle(x, y + h - offset - 1, ir, 1, r, g, b, alpha_step)
            renderer.rectangle(x + offset, y + h - ir, 1, ir, r, g, b, alpha_step)
            renderer.rectangle(x + w - ir, y + h - offset - 1, ir, 1, r, g, b, alpha_step)
            renderer.rectangle(x + w - offset - 1, y + h - ir, 1, ir, r, g, b, alpha_step)
        end
    end,
    render = function()
        if not ui.get(ZeroTech.Watermark.ui.enabled) then
            ZeroTech.Watermark.state.target_alpha = 0
            return
        end
        ZeroTech.Watermark.state.target_alpha = 255
        ZeroTech.Watermark.update_fps()
        ZeroTech.Watermark.handle_drag()
        local tick = globals.tickcount()
        if tick ~= ZeroTech.Watermark.state.last_tick then
            local diff = ZeroTech.Watermark.state.target_alpha - ZeroTech.Watermark.state.alpha
            ZeroTech.Watermark.state.alpha = ZeroTech.Watermark.state.alpha + diff * 0.28
            ZeroTech.Watermark.state.last_tick = tick
        end
        if ZeroTech.Watermark.state.alpha < 1 then return end
        local alpha = math.floor(ZeroTech.Watermark.state.alpha + 0.5)
        local font_size = ui.get(ZeroTech.Watermark.ui.font_size)
        local bg_alpha = ui.get(ZeroTech.Watermark.ui.bg_opacity)
        local rounded = ui.get(ZeroTech.Watermark.ui.rounded)
        local style = ui.get(ZeroTech.Watermark.ui.style)
        local padding_x, padding_y = 16, 10
        local x, y = ZeroTech.Watermark.state.pos_x, ZeroTech.Watermark.state.pos_y
        local text_parts = {"Zero.Tech"}
        if ui.get(ZeroTech.Watermark.ui.ping) then
            table.insert(text_parts, string.format(" | %.0fms", client.latency() * 1000))
        end
        if ui.get(ZeroTech.Watermark.ui.fps) then
            table.insert(text_parts, string.format(" | %d FPS", ZeroTech.Watermark.state.fps))
        end
        if ui.get(ZeroTech.Watermark.ui.tickrate) then
            table.insert(text_parts, string.format(" | %dt", math.floor(1 / globals.tickinterval())))
        end
        local full_text = table.concat(text_parts)
        local text_w, text_h = renderer.measure_text("", full_text)
        local total_w = text_w + padding_x * 2
        local total_h = text_h + padding_y * 2
        local bg_r, bg_g, bg_b = 18, 18, 26
        local border_r, border_g, border_b = 70, 70, 90
        local text_r, text_g, text_b = 255, 255, 255
        local ar, ag, ab = ui.get(ZeroTech.Watermark.ui.accent_color)
        if style == "Modern" then
            bg_r, bg_g, bg_b = 16, 16, 24
            border_r, border_g, border_b = 75, 75, 95
        elseif style == "Classic" then
            bg_r, bg_g, bg_b = 10, 10, 16
            border_r, border_g, border_b = 90, 90, 115
        elseif style == "Minimal" then
            bg_r, bg_g, bg_b = 0, 0, 0
            border_r, border_g, border_b = 40, 40, 50
            text_r, text_g, text_b = 230, 230, 230
            rounded = 0
        elseif style == "Glass" then
            bg_r, bg_g, bg_b = 20, 20, 30
            border_r, border_g, border_b = 110, 110, 140
            bg_alpha = math.floor(bg_alpha * 0.65)
        elseif style == "Neon" then
            bg_r, bg_g, bg_b = 8, 8, 12
            border_r, border_g, border_b = ar, ag, ab
            text_r, text_g, text_b = ar, ag, ab
        elseif style == "Gradient" then
            bg_r, bg_g, bg_b = 12, 12, 20
            border_r, border_g, border_b = ar * 0.7, ag * 0.7, ab * 0.7
        end
        if style == "Gradient" then
            local steps = 12
            for i = 0, steps do
                local t = i / steps
                local cr = bg_r + (ar * 0.35) * t
                local cg = bg_g + (ag * 0.35) * t
                local cb = bg_b + (ab * 0.35) * t
                local ca = bg_alpha * (0.5 + t * 0.5)
                ZeroTech.Watermark.render_rounded_rect(x, y + i * (total_h / steps), total_w, total_h / steps + 1, rounded, cr, cg, cb, ca)
            end
        else
            ZeroTech.Watermark.render_rounded_rect(x, y, total_w, total_h, rounded, bg_r, bg_g, bg_b, bg_alpha)
        end
        if ui.get(ZeroTech.Watermark.ui.glow) then
            for i = 1, 5 do
                local a = alpha * (1 - i/6) * 0.22
                local offset = i * 1.8
                local glow_r = style == "Neon" and ar or 90
                local glow_g = style == "Neon" and ag or 140
                local glow_b = style == "Neon" and ab or 255
                ZeroTech.Watermark.render_rounded_rect(x - offset, y - offset, total_w + offset*2, total_h + offset*2, rounded + offset, glow_r, glow_g, glow_b, a)
            end
        end
        if ui.get(ZeroTech.Watermark.ui.border) then
            if style == "Gradient" then
                local steps = 5
                for i = 0, steps do
                    local t = i / steps
                    local cr = border_r + (ar * 0.45) * t
                    local cg = border_g + (ag * 0.45) * t
                    local cb = border_b + (ab * 0.45) * t
                    local offset = i * 0.8
                    ZeroTech.Watermark.render_rounded_rect(x - offset, y - offset, total_w + offset*2, total_h + offset*2, rounded + offset, cr, cg, cb, alpha * 0.28)
                end
            else
                ZeroTech.Watermark.render_rounded_rect(x - 1, y - 1, total_w + 2, total_h + 2, rounded + 1, border_r, border_g, border_b, alpha)
            end
        end
        if ui.get(ZeroTech.Watermark.ui.shadow) then
            renderer.text(x + padding_x + 1, y + padding_y + 1, 0, 0, 0, alpha * 0.75, "", 0, full_text)
        end
        renderer.text(x + padding_x, y + padding_y, text_r, text_g, text_b, alpha, "", 0, full_text)
        if ui.get(ZeroTech.Watermark.ui.draggable) and ZeroTech.Watermark.state.is_dragging then
            renderer.text(x + total_w - 45, y + total_h + 6, 180, 180, 180, alpha * 0.8, "", 0, "drag")
        end
    end
}

local function update_visibility()
    local enabled = ui.get(ZeroTech.Watermark.ui.enabled)
    local style = ui.get(ZeroTech.Watermark.ui.style)
    ui.set_visible(ZeroTech.Watermark.ui.style, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.accent_color, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.font_size, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.bg_opacity, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.border, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.shadow, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.glow, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.rounded, enabled and (style ~= "Minimal"))
    ui.set_visible(ZeroTech.Watermark.ui.ping, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.fps, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.tickrate, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.draggable, enabled)
    ui.set_visible(ZeroTech.Watermark.ui.reset_pos, enabled and ui.get(ZeroTech.Watermark.ui.draggable))
end

ui.set_callback(ZeroTech.Watermark.ui.enabled, update_visibility)
ui.set_callback(ZeroTech.Watermark.ui.style, update_visibility)
ui.set_callback(ZeroTech.Watermark.ui.draggable, update_visibility)


client.set_event_callback("paint", function()
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then
        ZeroTech.Visuals.anim.target = 0
        ZeroTech.Trails.clear_trails()
        ZeroTech.Watermark.render()
        return
    end

    ZeroTech.Visuals.anim.target = ui.get(ZeroTech.Visuals.scope.enabled) and ZeroTech.Visuals.is_scoped() and 255 or 0
    local tick = globals.tickcount()
    if tick ~= ZeroTech.Visuals.anim.last_tick then
        local speed = ui.get(ZeroTech.Visuals.scope.fade_speed) * 0.08
        local diff = ZeroTech.Visuals.anim.target - ZeroTech.Visuals.anim.alpha
        ZeroTech.Visuals.anim.alpha = ZeroTech.Visuals.anim.alpha + diff * speed
        ZeroTech.Visuals.anim.last_tick = tick
    end

    if ZeroTech.Visuals.anim.alpha >= 1 then
        local w, h = client.screen_size()
        local cx, cy = w * 0.5, h * 0.5
        local len = ui.get(ZeroTech.Visuals.scope.length)
        local gap = ui.get(ZeroTech.Visuals.scope.gap)
        local thick = ui.get(ZeroTech.Visuals.scope.thickness)
        local alpha = math.floor(ZeroTech.Visuals.anim.alpha + 0.5)
        local r, g, b = ui.get(ZeroTech.Visuals.scope.color)
        if ui.get(ZeroTech.Visuals.scope.rainbow) then
            local speed = ui.get(ZeroTech.Visuals.scope.rainbow_speed) * 0.01
            local t = globals.realtime() * speed
            r = math.floor(math.sin(t) * 127 + 128)
            g = math.floor(math.sin(t + 2) * 127 + 128)
            b = math. floor(math.sin(t + 4) * 127 + 128)
        end
        renderer.line(cx - gap, cy, cx - len, cy, r, g, b, alpha, thick)
        renderer.line(cx + gap, cy, cx + len, cy, r, g, b, alpha, thick)
        renderer.line(cx, cy - gap, cx, cy - len, r, g, b, alpha, thick)
        renderer.line(cx, cy + gap, cx, cy + len, r, g, b, alpha, thick)
    end

    if ui.get(ZeroTech.BulletTracers.enabled) then
        local curtime = globals.curtime()
        for i = #ZeroTech.BulletTracers.tracers, 1, -1 do
            local tracer = ZeroTech.BulletTracers.tracers[i]
            if curtime > tracer.start_time + (ui.get(ZeroTech.BulletTracers.duration) * globals.tickinterval()) then
                table.remove(ZeroTech.BulletTracers.tracers, i)
            else
                local x1, y1 = renderer.world_to_screen(tracer.start_x, tracer.start_y, tracer.start_z)
                local x2, y2 = renderer.world_to_screen(tracer.end_x, tracer.end_y, tracer.end_z)
                if x1 and y1 and x2 and y2 then
                    local alpha = ZeroTech.BulletTracers.calculate_fade(tracer.start_time, ui.get(ZeroTech.BulletTracers.duration), curtime)
                    local r1, g1, b1 = ui.get(ZeroTech.BulletTracers.color)
                    renderer.line(x1, y1, x2, y2, r1, g1, b1, math.min(255, alpha), ui.get(ZeroTech.BulletTracers.thickness))
                    if ui.get(ZeroTech.BulletTracers.gap) and alpha > 50 then
                        local r2, g2, b2 = ui.get(ZeroTech.BulletTracers.impact_color)
                        local gap_size = 3
                        renderer.circle(x2, y2, r2, g2, b2, math.min(180, alpha * 0.7), gap_size, 16)
                    end
                end
            end
        end
    end

    if ui.get(ZeroTech.Trails.enable) then
        local cur_time = globals.curtime()
        local x, y, z = entity.get_prop(lp, "m_vecOrigin")
        if not x or not y or not z then return end
        local cur_origin = ZeroTech.Dependencies.vector(x, y, z)
        if not ZeroTech.Trails.data.last_origin then
            ZeroTech.Trails.data.last_origin = cur_origin
        end
        local dist = cur_origin:dist(ZeroTech.Trails.data.last_origin)
        if dist > 0.1 then
            local trail_segment = { pos = cur_origin, exp = cur_time + ui.get(ZeroTech.Trails.segment_exp) * 0.1, x = x, y = y, z = z }
            table.insert(ZeroTech.Trails.data.segments, trail_segment)
            ZeroTech.Trails.data.last_origin = cur_origin
        end
        while #ZeroTech.Trails.data.segments > 0 and ZeroTech.Trails.data.segments[1].exp < cur_time do
            table.remove(ZeroTech.Trails.data.segments, 1)
        end
        while #ZeroTech.Trails.data.segments > ZeroTech.Constants.MAX_TRAIL_SEGMENTS do
            table.remove(ZeroTech.Trails.data.segments, 1)
        end
        local color_type = ui.get(ZeroTech.Trails.color_type)
        local trail_type = ui.get(ZeroTech.Trails.trail_type)
        for i, segment in ipairs(ZeroTech.Trails.data.segments) do
            local x, y = renderer.world_to_screen(segment.x, segment.y, segment.z)
            if x and y then
                local seed = color_type == "Gradient Chroma" and i or 0
                local r, g, b = ZeroTech.Trails.get_fade_rgb(seed, ui.get(ZeroTech.Trails.chroma_speed) * 0.1)
                if color_type == "Static" then
                    r, g, b = ui.get(ZeroTech.Trails.static_color)
                end
                local alpha = math.max(0, math.floor(255 * (1 - (cur_time - segment.exp + ui.get(ZeroTech.Trails.segment_exp) * 0.1) / (ui.get(ZeroTech.Trails.segment_exp) * 0.1))))
                if trail_type == "Line" then
                    if i < #ZeroTech.Trails.data.segments then
                        local segment2 = ZeroTech.Trails.data.segments[i + 1]
                        local x2, y2 = renderer.world_to_screen(segment2.x, segment2.y, segment2.z)
                        if x2 and y2 then
                            local size = ui.get(ZeroTech.Trails.line_size)
                            renderer.line(x, y, x2, y2, r, g, b, alpha, size)
                        end
                    end
                elseif trail_type == "Advanced Line" then
                    if i < #ZeroTech.Trails.data.segments then
                        local segment2 = ZeroTech.Trails.data.segments[i + 1]
                        local x2, y2 = renderer.world_to_screen(segment2.x, segment2.y, segment2.z)
                        if x2 and y2 then
                            local x_width = ui.get(ZeroTech.Trails.trail_x_width)
                            local y_width = ui.get(ZeroTech.Trails.trail_y_width)
                            renderer.line(x, y, x2, y2, r, g, b, alpha, 1)
                            if x_width > 1 or y_width > 1 then
                                renderer.line(x + x_width, y, x2 + x_width, y2, r, g, b, alpha * 0.5, 1)
                                renderer.line(x - x_width, y, x2 - x_width, y2, r, g, b, alpha * 0.5, 1)
                                renderer.line(x, y + y_width, x2, y2 + y_width, r, g, b, alpha * 0.5, 1)
                                renderer.line(x, y - y_width, x2, y2 - y_width, r, g, b, alpha * 0.5, 1)
                            end
                        end
                    end
                else
                    renderer.rectangle(x, y, ui.get(ZeroTech.Trails.rect_w), ui.get(ZeroTech.Trails.rect_h), r, g, b, alpha)
                end
            end
        end
    end

    ZeroTech.ClanTag.set_clantag()

    if ui.get(ZeroTech.Resolver.ui.enabled) and ui.get(ZeroTech.Resolver.ui.debug) then
        for _, player in ipairs(entity.get_players(true)) do
            local steam_id = entity.get_steam64(player)
            local records = ZeroTech.Resolver.player_records[steam_id]
            if records then
                local x, y = renderer.world_to_screen(entity.get_prop(player, "m_vecOrigin"))
                if x and y then
                    local color = records.aa_type == "extreme_jitter" and {255, 50, 50} or
                                  records.aa_type == "jitter" and {255, 100, 100} or
                                  records.aa_type == "jitter_sideswitch" and {255, 150, 150} or
                                  records.aa_type == "desync_spam" and {100, 255, 100} or
                                  records.aa_type == "desync" and {150, 255, 150} or
                                  records.aa_type == "spinbot" and {100, 100, 255} or
                                  records.aa_type == "lby_flick_extreme" and {255, 255, 50} or
                                  records.aa_type == "lby_flick" and {255, 255, 100} or
                                  records.aa_type == "hideshot_perfect" and {255, 50, 255} or
                                  records.aa_type == "hideshot" and {255, 100, 255} or
                                  records.aa_type == "air_crouch_extreme" and {50, 255, 255} or
                                  records.aa_type == "fake_duck" and {100, 255, 255} or
                                  records.aa_type == "micro_jitter" and {255, 200, 100} or
                                  records.aa_type == "resolver_breaker" and {200, 100, 255} or
                                  records.aa_type == "fake_up_extreme" and {255, 150, 200} or
                                  records.aa_type == "snapback_fast" and {150, 255, 150} or
                                  records.aa_type == "layer_glitch" and {150, 150, 255} or
                                  records.aa_type == "rapid_sideswitch" and {255, 100, 200} or
                                  records.aa_type == "subtle_jitter" and {200, 200, 100} or
                                  records.aa_type == "lby_mismatch_extreme" and {255, 255, 200} or
                                  records.aa_type == "velocity_exploit" and {200, 200, 255} or
                                  records.aa_type == "freestanding_left" and {255, 200, 255} or
                                  records.aa_type == "freestanding_right" and {200, 255, 200} or
                                  records.aa_type == "zero_desync" and {255, 150, 150} or
                                  records.aa_type == "crouch_switch" and {150, 255, 200} or
                                  records.aa_type == "layer_break" and {200, 150, 255} or
                                  records.aa_type == "fake_head_extreme" and {255, 200, 200} or
                                  records.aa_type == "half_spin" and {200, 255, 255} or
                                  records.aa_type == "static_lby" and {255, 100, 150} or
                                  records.aa_type == "anti_aim_brute" and {255, 50, 150} or
                                  {200, 200, 200}
                    local r, g, b = ui.get(ZeroTech.Resolver.ui.debug_color)
                    renderer.text(x, y - 30, color[1], color[2], color[3], 255, "c", 0, records.aa_type)
                    renderer.text(x, y - 15, r, g, b, 255, "c", 0, "MS:" .. (records.missed_shots or 0))
                end
            end
        end
    end

    ZeroTech.Resolver.update()
    ZeroTech.Watermark.render()
end)

local ref = {}

ref.enabled   = ui.new_checkbox("LUA", "A", "Auto Duck")
ref.key       = ui.new_hotkey("LUA", "A", "Toggle", true)
ref.duck_mode = ui.new_combobox("LUA", "A", "Duck Mode", {"Start", "Air", "Hold All Flight"})

local state = {
    jumping = false,
    in_air = false,
    duck_held = false
}

local function on_ground()
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return false end
    local flags = entity.get_prop(lp, "m_fFlags")
    return flags and bit.band(flags, 1) == 1
end

local function active()
    return ui.get(ref.enabled) and ui.get(ref.key)
end

client.set_event_callback("setup_command", function(c)
    if not active() then
        if state.duck_held then
            client.exec("-duck")
            state.duck_held = false
        end
        state.jumping = false
        state.in_air = false
        return
    end

    local ground = on_ground()
    local space = client.key_state(0x20) == 1
    local mode = ui.get(ref.duck_mode)

    
    if ground and state.jumping then
        client.exec("-duck")
        state.jumping = false
        state.in_air = false
        state.duck_held = false
        return
    end

    
    if ground and space and not state.jumping then
        state.jumping = true
        state.in_air = false
        if mode == "Start" or mode == "Hold All Flight" then
            client.exec("+duck")
            state.duck_held = true
        end
    end

    
    if not ground and state.jumping and not state.in_air then
        state.in_air = true
        if mode == "Air" or mode == "Hold All Flight" then
            client.exec("+duck")
            state.duck_held = true
        end
    end


    if state.duck_held and not ground then
        client.exec("+duck")
    end

  
    if not ground and state.jumping then
        local tick = globals.tickcount()
        local yaw = client.camera_angles() and client.camera_angles().y or 0
        yaw = yaw * math.pi / 180
        
        local phase = tick * 0.22
        local tilt = math.sin(phase) * 0.79
        
        local wish_dir = yaw + tilt
        local speed = 4.1
        
        local side = math.sin(phase) * 450
        local forward = math.cos(phase) * 40
        
        local sin_dir = math.sin(wish_dir) * speed * 100
        local cos_dir = math.cos(wish_dir) * speed * 100
        
        c.sidemove = side > 0 and cos_dir or sin_dir
        c.forwardmove = forward
    end
end)

ui.set(ref.enabled, true)
ui.set(ref.key, true)
ui.set(ref.duck_mode, "Hold All Flight")

client.set_event_callback("bullet_impact", function(e)
    if not ui.get(ZeroTech.BulletTracers.enabled) then return end
    local local_player = entity.get_local_player()
    if not local_player or client.userid_to_entindex(e.userid) ~= local_player then return end
    local eye_pos = {client.eye_position()}
    if not eye_pos[1] or not eye_pos[2] or not eye_pos[3] then return end
    local curtime = globals.curtime()
    table.insert(ZeroTech.BulletTracers.tracers, 1, {
        start_x = eye_pos[1], start_y = eye_pos[2], start_z = eye_pos[3],
        end_x = e.x, end_y = e.y, end_z = e.z,
        start_time = curtime
    })
    while #ZeroTech.BulletTracers.tracers > ZeroTech.BulletTracers.max_tracers do
        table.remove(ZeroTech.BulletTracers.tracers)
    end
end)

client.set_event_callback("round_prestart", function()
    ZeroTech.BulletTracers.tracers = {}
    ZeroTech.Trails.clear_trails()
end)

client.set_event_callback("player_disconnect", function(e)
    local steam_id = entity.get_steam64(client.userid_to_entindex(e.userid))
    if steam_id then
        ZeroTech.Resolver.player_records[steam_id] = nil
        ZeroTech.Resolver.last_simulation_time[steam_id] = nil
    end
end)

client.set_event_callback("level_init", function()
    ZeroTech.Resolver.player_records = {}
    ZeroTech.Resolver.last_simulation_time = {}
    ZeroTech.Resolver.last_valid_tick = globals.tickcount()
    ZeroTech.Trails.clear_trails()
end)

ui.set_callback(ZeroTech.ClanTag.ui_elements.checkbox, function()
    ZeroTech.ClanTag.state.is_enabled = ui.get(ZeroTech.ClanTag.ui_elements.checkbox)
    if not ZeroTech.ClanTag.state.is_enabled then
        ZeroTech.ClanTag.safe_set_clantag("")
    end
end)

ui.set_callback(ZeroTech.ClanTag.ui_elements.speed_slider, function()
    ZeroTech.ClanTag.config.animation_speed = ui.get(ZeroTech.ClanTag.ui_elements.speed_slider) * 0.05
end)

ui.set_callback(ZeroTech.Trails.enable, ZeroTech.Trails.clear_trails)

client.set_event_callback("aim_hit", ZeroTech.Resolver.on_shot_fired)
client.set_event_callback("aim_miss", ZeroTech.Resolver.on_shot_fired)

update_visibility()

ZeroTech.Watermark.render()

