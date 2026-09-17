-- The Charm of Wands v4.1: physical following; based on the supplied file.
local FOLLOW_RADIUS = 70
local FOLLOW_STOP_RADIUS = 28
local FOLLOW_HEIGHT = 18
local FOLLOW_MAX_SPEED = 8
local FOLLOW_RESPONSE = 35
local FOLLOW_MAX_FORCE = 180
local follow_state = {}
local PICKUP_RADIUS = 24
local WAND_SLOTS = 4
local EFFECT_SIDE_OFFSET = 6
local EFFECT_HEIGHT = 8
local MANAGED_TAG = "charm_of_wands_managed_v2"
local interact_was_down = false
local visual_retry = {}

local DUEL_HERDS = { "cow_jealous_a", "cow_jealous_b" }
local relations_ok, relations_error = pcall(function()
    local path = "data/genome_relations.csv"
    local source = ModTextFileGetContent(path)
    assert(type(source) == "string" and source ~= "", "cannot read genome_relations.csv")
    local first_line = source:match("[^\r\n]+")
    local _, commas = first_line:gsub(",", "")
    local _, semicolons = first_line:gsub(";", "")
    local delimiter = commas >= semicolons and "," or ";"
    local rows = {}
    for line in source:gmatch("[^\r\n]+")
    do
        local row = {}
        for cell in (line .. delimiter):gmatch("(.-)" .. delimiter)
        do
            row[#row + 1] = cell
        end
        rows[#rows + 1] = row
    end
    local function clean(v)
        return (v or ""):gsub('^%s*"?', ''):gsub('"?%s*$', '')
    end
    local header = rows[1]
    while #header > 1 and clean(header[#header]) == ""
    do
        local index = #header
        for _, row in ipairs(rows)
        do
            assert(not row[index] or clean(row[index]) == "", "unexpected trailing CSV column")
            row[index] = nil
        end
    end
    local columns, by_name = {}, {}
    for i = 2, #header do columns[clean(header[i])] = i end
    for i = 2, #rows do by_name[clean(rows[i][1])] = rows[i] end
    assert(columns.player and by_name.player, "unexpected genome table format: missing player")
    for _, name in ipairs(DUEL_HERDS)
    do
        if not columns[name]
        then
            header[#header + 1] = name
            columns[name] = #header
        end
        if not by_name[name]
        then
            local row = { name }
            rows[#rows + 1] = row
            by_name[name] = row
        end
    end

    for _, name in ipairs(DUEL_HERDS)
    do
        for i = 2, #rows do rows[i][columns[name]] = "100" end
        for j = 2, #header do by_name[name][j] = "100" end
    end

    by_name[DUEL_HERDS[1]][columns[DUEL_HERDS[2]]] = "-100"
    by_name[DUEL_HERDS[2]][columns[DUEL_HERDS[1]]] = "-100"
    local output = {}
    for _, row in ipairs(rows)
    do
        for j = 1, #header do row[j] = row[j] or "" end
        output[#output + 1] = table.concat(row, delimiter)
    end
    ModTextFileSetContent(path, table.concat(output, "\n") .. "\n")
end)

local function first(entity, kind)
    return EntityGetFirstComponentIncludingDisabled(entity, kind)
end

local function components(entity, kind)
    return EntityGetComponentIncludingDisabled(entity, kind) or {}
end

local function collect_wands(entity, result)
    result = result or {}
    for _, child in ipairs(EntityGetAllChildren(entity) or {})
    do
        if EntityHasTag(child, "wand")
        then
            result[#result + 1] = child
        else
            collect_wands(child, result)
        end
    end
    return result
end

local function is_charmed_ghost(entity, player_herd)
    if EntityHasTag(entity, MANAGED_TAG) then return true end
    local genome = EntityGetFirstComponentIncludingDisabled(
        entity, "GenomeDataComponent"
    )
    if genome and player_herd ~= nil
        and ComponentGetValue2(genome, "herd_id") == player_herd then
        EntityAddTag(entity, MANAGED_TAG)
        return true
    end
    return false
end

local function remove_timeout(entity)
    for _, component in ipairs(components(entity, "LifetimeComponent"))
    do
        EntityRemoveComponent(entity, component)
    end
    for _, component in ipairs(components(entity, "LuaComponent"))
    do
        if ComponentGetValue2(component, "script_source_file")
            == "data/scripts/misc/drop_all_items.lua" then
            EntityRemoveComponent(entity, component)
        end
    end
end

local function stop_follow(entity)
    follow_state[entity] = nil
end

local function update_follow(entity, px, py)
    local frame = GameGetFrameNum()
    local state = follow_state[entity]

    if state and state.frame == frame then return end

    local x, y = EntityGetTransform(entity)
    local tx, ty = px, py - FOLLOW_HEIGHT
    local dx, dy = tx - x, ty - y
    local distance = math.sqrt(dx * dx + dy * dy)
    local vx, vy, player_vx, player_vy = 0, 0, 0, 0
    if state then
        local elapsed = frame - state.frame

        if elapsed > 0 and elapsed <= 5
            and (x - state.x)^2 + (y - state.y)^2 < 128^2
            and (px - state.px)^2 + (py - state.py)^2 < 128^2 then
            vx, vy = (x - state.x) / elapsed, (y - state.y) / elapsed
            player_vx = (px - state.px) / elapsed
            player_vy = (py - state.py) / elapsed
        end
    end

    local following = state and state.following or false
    if distance > FOLLOW_RADIUS then following = true end
    if distance < FOLLOW_STOP_RADIUS then following = false end
    follow_state[entity] = {
        frame = frame, x = x, y = y, px = px, py = py,
        following = following,
    }

    for _, ai in ipairs(components(entity, "AnimalAIComponent")) do
        ComponentSetValue2(ai, "mHomePosition", tx, ty)
        ComponentSetValue2(ai, "max_distance_to_move_from_home", FOLLOW_RADIUS)
    end
    for _, physics in ipairs(components(entity, "PhysicsAIComponent")) do
        ComponentSetValue2(physics, "target_vec_max_len", following and 15 or 6)
        ComponentSetValue2(physics, "force_balancing_coeff", 1.5)
    end

    if not following or distance < 0.001 then return end

    local speed = math.min(FOLLOW_MAX_SPEED,
        math.max(0, distance - FOLLOW_STOP_RADIUS) * 0.10)
    local wanted_x = dx / distance * speed + player_vx
    local wanted_y = dy / distance * speed + player_vy
    local wanted_length = math.sqrt(wanted_x^2 + wanted_y^2)
    if wanted_length > FOLLOW_MAX_SPEED then
        wanted_x = wanted_x * FOLLOW_MAX_SPEED / wanted_length
        wanted_y = wanted_y * FOLLOW_MAX_SPEED / wanted_length
    end
    local fx = (wanted_x - vx) * FOLLOW_RESPONSE
    local fy = (wanted_y - vy) * FOLLOW_RESPONSE
    local force_length = math.sqrt(fx^2 + fy^2)
    if force_length > FOLLOW_MAX_FORCE then
        fx = fx * FOLLOW_MAX_FORCE / force_length
        fy = fy * FOLLOW_MAX_FORCE / force_length
    end
    PhysicsApplyForce(entity, fx, fy)
end

local function living_ghosts(player)
    local genome = first(player, "GenomeDataComponent")
    local herd = genome and ComponentGetValue2(genome, "herd_id")
    local result = {}
    for _, entity in ipairs(EntityGetWithTag("wand_ghost") or {})
    do
        if EntityGetIsAlive(entity) and is_charmed_ghost(entity, herd)
        then
            remove_timeout(entity)
            local damage = first(entity, "DamageModelComponent")
            if (not damage or ComponentGetValue2(damage, "hp") > 0)
                and #collect_wands(entity) > 0 then
                result[#result + 1] = entity
            end
        end
    end
    return result
end

local function saved_ai(entity)
    for _, c in ipairs(components(entity, "VariableStorageComponent"))
    do
        if ComponentGetValue2(c, "name") == "cow_v3_ai_original" then
            return c
        end
    end
end

local function restore_old_ai(entity, ai)
    local saved = saved_ai(entity)
    if not saved then return end
    for field, value in ComponentGetValue2(saved, "value_string"):gmatch("([^;=]+)=([^;]+)")
    do
        local decoded
        if value == "true" then decoded = true
        elseif value == "false" then decoded = false
        else decoded = tonumber(value) end
        if decoded ~= nil then ComponentSetValue2(ai, field, decoded) end
    end
    ComponentSetValue2(ai, "mGreatestPrey", 0)
    ComponentSetValue2(ai, "mGreatestThreat", 0)
    ComponentSetValue2(ai, "mHasFoundPrey", false)
    ComponentSetValue2(ai, "mCreatureDetectionNextCheck", 0)
    ComponentSetValue2(ai, "mFrameNextGiveUp", 0)
    EntityRemoveComponent(entity, saved)
end

local function storage(entity, name)
    for _, c in ipairs(components(entity, "VariableStorageComponent"))
    do
        if ComponentGetValue2(c, "name") == name then return c end
    end
end

local function set_duel_group(entity, group)
    local ai = first(entity, "AnimalAIComponent")
    local genome = first(entity, "GenomeDataComponent")
    if not ai or not genome then return end
    restore_old_ai(entity, ai)
    local snapshot = storage(entity, "cow_v4_original")
    if group then
        if not snapshot then
            local original = {}
            for _, key in ipairs({"sense_creatures", "tries_to_ranged_attack_friends",
                "dont_counter_attack_own_herd", "max_distance_to_move_from_home",
                "attack_if_damaged_probability", "escape_if_damaged_probability",
                "creature_detection_check_every_x_frames"})
            do
                original[#original + 1] = key .. "=" .. tostring(ComponentGetValue2(ai, key))
            end
            snapshot = EntityAddComponent2(entity, "VariableStorageComponent", {
                name = "cow_v4_original",
                value_int = ComponentGetValue2(genome, "herd_id"),
                value_bool = ComponentGetValue2(genome, "berserk_dont_attack_friends"),
                value_string = table.concat(original, ";"),
            })
        end
        local herd = StringToHerdId(DUEL_HERDS[group])
        if HerdIdToString(herd) ~= DUEL_HERDS[group] then
            error("Duel groups not registered. Fully restart Noita with this mod enabled.")
        end
        if ComponentGetValue2(genome, "herd_id") ~= herd then
            ComponentSetValue2(genome, "herd_id", herd)
            ComponentSetValue2(ai, "mGreatestPrey", 0)
            ComponentSetValue2(ai, "mGreatestThreat", 0)
            ComponentSetValue2(ai, "mHasFoundPrey", false)
            ComponentSetValue2(ai, "mCreatureDetectionNextCheck", 0)
            ComponentSetValue2(ai, "mFrameNextGiveUp", 0)
        end
        ComponentSetValue2(genome, "berserk_dont_attack_friends", true)
        ComponentSetValue2(ai, "sense_creatures", true)
        ComponentSetValue2(ai, "tries_to_ranged_attack_friends", false)
        ComponentSetValue2(ai, "dont_counter_attack_own_herd", true)
        ComponentSetValue2(ai, "attack_if_damaged_probability", 0)
        ComponentSetValue2(ai, "escape_if_damaged_probability", 0)
        ComponentSetValue2(ai, "max_distance_to_move_from_home", 0)
        ComponentSetValue2(ai, "creature_detection_check_every_x_frames", 10)
    elseif snapshot then
        ComponentSetValue2(genome, "herd_id", ComponentGetValue2(snapshot, "value_int"))
        ComponentSetValue2(genome, "berserk_dont_attack_friends", ComponentGetValue2(snapshot, "value_bool"))
        for field, value in ComponentGetValue2(snapshot, "value_string"):gmatch("([^;=]+)=([^;]+)") do
            local decoded
            if value == "true" then decoded = true
            elseif value == "false" then decoded = false
            else decoded = tonumber(value) end
            if decoded ~= nil then ComponentSetValue2(ai, field, decoded) end
        end
        ComponentSetValue2(ai, "mGreatestPrey", 0)
        ComponentSetValue2(ai, "mGreatestThreat", 0)
        ComponentSetValue2(ai, "mHasFoundPrey", false)
        ComponentSetValue2(ai, "mCreatureDetectionNextCheck", 0)
        ComponentSetValue2(ai, "mFrameNextGiveUp", 0)
        EntityRemoveComponent(entity, snapshot)
    end
end

local visual_components = {
    SpriteParticleEmitterComponent = true,
    ParticleEmitterComponent = true,
    SpriteComponent = true,
    LightComponent = true,
}

local function strip_to_visuals(entity)
    for _, c in ipairs(EntityGetAllComponents(entity) or {})
    do
        local kind = ComponentGetTypeName(c)
        if not visual_components[kind]
        then
            EntityRemoveComponent(entity, c)
        else
            EntitySetComponentIsEnabled(entity, c, true)
            if kind == "ParticleEmitterComponent" then
                ComponentSetValue2(c, "create_real_particles", false)
                ComponentSetValue2(c, "emit_real_particles", false)
                ComponentSetValue2(c, "emitter_lifetime_frames", -1)
            elseif kind == "SpriteParticleEmitterComponent" then
                ComponentSetValue2(c, "randomize_position_inside_hitbox", false)
            end
        end
    end
    for _, child in ipairs(EntityGetAllChildren(entity) or {})
    do
        strip_to_visuals(child)
    end
end

local function move_visual_tree(entity, dx, dy)
    for _, child in ipairs(EntityGetAllChildren(entity) or {})
    do
        move_visual_tree(child, dx, dy)
    end
    local x, y, rotation, sx, sy = EntityGetTransform(entity)
    EntitySetTransform(entity, x + dx, y + dy, rotation, sx, sy)
end

local function position_visual(fx, entity)
    local x, y, _, sx = EntityGetTransform(entity)
    local side = (sx or 1) < 0 and -1 or 1
    local wand = collect_wands(entity)[1]
    if wand then
        local wx, wy, angle = EntityGetTransform(wand)
        local dx = wx - x
        if math.abs(dx) > 1 then
            side = dx < 0 and -1 or 1
        elseif angle then
            side = math.cos(angle) < 0 and -1 or 1
        end
        x, y = wx, wy
    end
    local fx_x, fx_y = EntityGetTransform(fx)
    move_visual_tree(fx, x + side * EFFECT_SIDE_OFFSET - fx_x,
        y - EFFECT_HEIGHT - fx_y)
end

local function update_visual(entity, angry)
    local wanted = angry and "cow_v3_berserk" or "cow_v3_charm"
    local fx
    for _, child in ipairs(EntityGetAllChildren(entity) or {})
    do
        if EntityHasTag(child, "cow_v3_visual")
        then
            if EntityHasTag(child, wanted) and not fx then fx = child
            else EntityKill(child) end
        end
    end
    if not fx then
        local frame = GameGetFrameNum()
        if frame < (visual_retry[entity] or 0) then return end
        local path = angry and "data/entities/misc/effect_berserk.xml"
            or "data/entities/misc/effect_charm.xml"
        local x, y = EntityGetTransform(entity)
        local ok, loaded = pcall(EntityLoad, path, x, y)
        if not ok or not loaded or loaded == 0 then
            visual_retry[entity] = frame + 600
            GamePrint("Charm of Wands: cannot load " .. path)
            return
        end
        fx = loaded
        strip_to_visuals(fx)
        EntityAddTag(fx, "cow_v3_visual")
        EntityAddTag(fx, wanted)
        if angry then
            EntityAddComponent2(fx, "GameEffectComponent", {
                effect = "BERSERK", frames = -1,
            })
        end
        EntityAddChild(entity, fx)
    end
    position_visual(fx, entity)
end

function OnWorldPreUpdate()
    local player = (EntityGetWithTag("player_unit") or {})[1]
    if not player then return end
    local ghosts = living_ghosts(player)
    local px, py = EntityGetTransform(player)
    table.sort(ghosts)
    for index, entity in ipairs(ghosts)
    do
        local angry = relations_ok and #ghosts > 1
        set_duel_group(entity, angry and ((index - 1) % 2 + 1) or nil)
        if angry then stop_follow(entity) else update_follow(entity, px, py) end
        update_visual(entity, angry)
    end
end

local function reclaim(entity, player)
    local wands = collect_wands(entity)
    if #wands == 0 then return end

    if #collect_wands(player) + #wands > WAND_SLOTS then
        GamePrint("Free a wand slot first.")
        return
    end

    GameDropAllItems(entity)

    for _, wand in ipairs(wands)
    do
        if EntityGetIsAlive(wand) and EntityGetRootEntity(wand) == entity then
            GamePrint("Wand was not released; ghost kept alive.")
            return
        end
    end

    local all_picked_up = true
    for _, wand in ipairs(wands)
    do
        if EntityGetIsAlive(wand)
        then
            local ok = pcall(GamePickUpInventoryItem, player, wand, true)
            if not ok or EntityGetRootEntity(wand) ~= player then
                all_picked_up = false
            end
        else
            all_picked_up = false
        end
    end

    stop_follow(entity)
    EntityKill(entity)
    if all_picked_up then
        GamePrint("Wand returned.")
    else
        GamePrint("Wand released. Pick it up normally.")
    end
end

function OnWorldPostUpdate()
    local player = (EntityGetWithTag("player_unit") or {})[1]
    if not player then
        interact_was_down = false
        return
    end

    local controls = EntityGetFirstComponentIncludingDisabled(
        player, "ControlsComponent"
    )
    local down = controls
        and ComponentGetValue2(controls, "mButtonDownInteract") or false
    local just_pressed = down and not interact_was_down
    interact_was_down = down

    local px, py = EntityGetTransform(player)
    local nearest, nearest_d2 = nil, PICKUP_RADIUS^2
    local ghosts = living_ghosts(player)
    table.sort(ghosts)
    for index, entity in ipairs(ghosts)
    do
            local angry = relations_ok and #ghosts > 1
            set_duel_group(entity, angry and ((index - 1) % 2 + 1) or nil)
            if angry then stop_follow(entity) else update_follow(entity, px, py) end
            update_visual(entity, angry)
            if just_pressed and not GameIsInventoryOpen() then
                local x, y = EntityGetTransform(entity)
                local d2 = (x - px)^2 + (y - py)^2
                if d2 <= nearest_d2 and #collect_wands(entity) > 0 then
                    nearest, nearest_d2 = entity, d2
                end
            end
    end

    if nearest then reclaim(nearest, player) end
end

do
    local native_summaries = {}
    for _, name in ipairs({ "charm", "berserk" })
    do
        local path = "data/entities/misc/effect_" .. name .. ".xml"
        local ok, content = pcall(ModTextFileGetContent, path)
        local kinds, seen = {}, {}
        if ok and type(content) == "string" and content ~= "" then
            for kind in content:gmatch("<([%w_]+Component)[%s/>]")
            do
                if not seen[kind] then
                    seen[kind] = true
                    kinds[#kinds + 1] = kind:gsub("Component$", "")
                end
            end
            native_summaries[#native_summaries + 1] = name
                .. " XML: " .. table.concat(kinds, ",")
        else
            native_summaries[#native_summaries + 1] = name .. " XML: READ FAILED"
        end
    end

    local function value(component, field)
        if not component then return "NO_COMPONENT" end
        local ok, result = pcall(ComponentGetValue2, component, field)
        return ok and tostring(result) or "READ_ERROR"
    end

    local function inspect_fx(entity, counts, effects)
        for _, c in ipairs(EntityGetAllComponents(entity) or {})
        do
            local kind = ComponentGetTypeName(c)
            counts[kind] = (counts[kind] or 0) + 1
            if kind == "GameEffectComponent" then
                effects[#effects + 1] = value(c, "effect")
                    .. ":" .. value(c, "frames")
            end
        end
        for _, child in ipairs(EntityGetAllChildren(entity) or {})
        do
            inspect_fx(child, counts, effects)
        end
    end

    local ready_at, shown, pending_error
    local update = OnWorldPostUpdate
    function OnWorldPostUpdate()
        local ghosts = EntityGetWithTag("wand_ghost") or {}
        local frame = GameGetFrameNum()
        if #ghosts < 2 then ready_at = nil
        elseif not ready_at then ready_at = frame + 120 end

        if not shown and ready_at and frame >= ready_at then
            shown = true
            GamePrint("=== COW DIAG v4.1 | ghosts=" .. #ghosts .. " ===")
            if not relations_ok then GamePrint("RELATIONS ERROR: " .. tostring(relations_error)) end
            if #ghosts >= 2 then
                GamePrint("rival_relation=" .. tostring(EntityGetHerdRelation(ghosts[1], ghosts[2])))
            end
            for i = 1, math.min(2, #ghosts)
            do
                local entity = ghosts[i]
                local ai = first(entity, "AnimalAIComponent")
                GamePrint("G=" .. entity .. " managed="
                    .. tostring(EntityHasTag(entity, MANAGED_TAG))
                    .. " wands=" .. #collect_wands(entity)
                    .. " herd=" .. value(first(entity, "GenomeDataComponent"), "herd_id"))
                GamePrint("prey=" .. value(ai, "mGreatestPrey")
                    .. " state=" .. value(ai, "ai_state")
                    .. " sense=" .. value(ai, "sense_creatures")
                    .. " found=" .. value(ai, "mHasFoundPrey"))
                GamePrint("attack_friends=" .. value(ai, "tries_to_ranged_attack_friends")
                    .. " ranged=" .. value(ai, "attack_ranged_enabled"))
                local counts, effects, fx_count = {}, {}, 0
                for _, child in ipairs(EntityGetAllChildren(entity) or {})
                do
                    if EntityHasTag(child, "cow_v3_visual") then
                        fx_count = fx_count + 1
                        inspect_fx(child, counts, effects)
                    end
                end
                GamePrint("FX=" .. fx_count
                    .. " emitters=" .. (counts.SpriteParticleEmitterComponent or 0)
                    .. "/" .. (counts.ParticleEmitterComponent or 0)
                    .. " effects=" .. table.concat(effects, ","))
            end
            if pending_error then GamePrint("UPDATE ERROR: " .. pending_error) end
        end

        local ok, err = pcall(update)
        if not ok then pending_error = tostring(err) end
    end

    local pre = OnWorldPreUpdate
    function OnWorldPreUpdate()
        local ok, err = pcall(pre)
        if not ok then pending_error = tostring(err) end
    end
end
