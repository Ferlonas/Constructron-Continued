require("util")

local chunk_util = require("script/chunk_util")
local debug_lib = require("script/debug_lib")
local color_lib = require("script/color_lib")
local pathfinder = require("script/pathfinder")

---@module "chunk_util"
---@module "debug_lib"
---@module "color_lib"

local me = {}

me.ensure_globals = function()
    global.registered_entities = global.registered_entities or {}
    global.constructron_statuses = global.constructron_statuses or {}

    global.stack_cache = {} -- rebuild

    global.job_bundle_index = global.job_bundle_index or 1

    global.ghost_index = global.ghost_index or 0
    global.decon_index = global.decon_index or 0
    global.upgrade_index = global.upgrade_index or 0
    global.repair_index = global.repair_index or 0

    global.ghost_entities = global.ghost_entities or {}
    global.deconstruction_entities = global.deconstruction_entities or {}
    global.upgrade_entities = global.upgrade_entities or {}
    global.repair_entities = global.repair_entities or {}

    global.construct_queue = global.construct_queue or {}
    global.deconstruct_queue = global.deconstruct_queue or {}
    global.upgrade_queue = global.upgrade_queue or {}
    global.repair_queue = global.repair_queue or {}

    global.job_bundles = global.job_bundles or {}

    global.constructrons = global.constructrons or {}
    global.service_stations = global.service_stations or {}

    global.constructrons_count = global.constructrons_count or {}
    global.stations_count = global.stations_count or {}

    for s, surface in pairs(game.surfaces) do
        global.constructrons_count[surface.index] = global.constructrons_count[surface.index] or 0
        global.stations_count[surface.index] = global.stations_count[surface.index] or 0
        global.construct_queue[surface.index] = global.construct_queue[surface.index] or {}
        global.deconstruct_queue[surface.index] = global.deconstruct_queue[surface.index] or {}
        global.upgrade_queue[surface.index] = global.upgrade_queue[surface.index] or {}
        global.repair_queue[surface.index] = global.repair_queue[surface.index] or {}
    end

    -- build allowed items cache (used in add_entities_to_chunks)
    global.allowed_items = {}
    for item_name, _ in pairs(game.item_prototypes) do
        local recipes = game.get_filtered_recipe_prototypes({
                {filter = "has-product-item", elem_filters = {{filter = "name", name = item_name}}},
            })
        for _ , recipe in pairs(recipes) do
            if not game.forces["player"].recipes[recipe.name].hidden then -- if the recipe is hidden disallow it
                global.allowed_items[item_name] = true
            end
        end
        if global.allowed_items[item_name] == nil then -- some items do not have recipes so set the item to disallowed
            global.allowed_items[item_name] = false
        end
    end

    -- build required_items cache (used in add_entities_to_chunks)
    global.items_to_place_cache = {}
    for name, v in pairs(game.entity_prototypes) do
        if v.items_to_place_this ~= nil and v.items_to_place_this[1] and v.items_to_place_this[1].name then -- bots will only ever use the first item from this list
            global.items_to_place_cache[name] = {item = v.items_to_place_this[1].name, count = v.items_to_place_this[1].count}
        end
    end
    for name, v in pairs(game.tile_prototypes) do
        if v.items_to_place_this ~= nil and v.items_to_place_this[1] and v.items_to_place_this[1].name then -- bots will only ever use the first item from this list
            global.items_to_place_cache[name] = {item = v.items_to_place_this[1].name, count = v.items_to_place_this[1].count}
        end
    end

    -- settings
    global.construction_job_toggle = settings.global["construct_jobs"].value
    global.rebuild_job_toggle = settings.global["rebuild_jobs"].value
    global.deconstruction_job_toggle = settings.global["deconstruct_jobs"].value
    global.upgrade_job_toggle = settings.global["upgrade_jobs"].value
    global.repair_job_toggle = settings.global["repair_jobs"].value
    global.debug_toggle = settings.global["constructron-debug-enabled"].value
    global.job_start_delay = (settings.global["job-start-delay"].value * 60)
    global.desired_robot_count = settings.global["desired_robot_count"].value
    global.desired_robot_name = settings.global["desired_robot_name"].value
    global.construction_mat_alert = (settings.global["construction_mat_alert"].value * 60)
    global.max_jobtime = (settings.global["max-jobtime-per-job"].value * 60 * 60) --[[@as uint]]
    global.entities_per_tick = settings.global["entities_per_tick"].value --[[@as uint]]
    global.clear_robots_when_idle = settings.global["clear_robots_when_idle"].value --[[@as boolean]]
end

---@param network LuaLogisticNetwork
---@return boolean
me.robots_active = function(network)
    local cell = network.cells[1]
    local all_construction_robots = network.all_construction_robots
    local stationed_bots = cell.stationed_construction_robot_count
    local charging_robots = cell.charging_robots
    local to_charge_robots = cell.to_charge_robots
    local active_bots = (all_construction_robots) - (stationed_bots)

    if ((active_bots == 0) and not next(charging_robots) and not next(to_charge_robots)) then
        return false -- robots are not active
    else
        return true -- robots are active
    end
end

---@param job Job
me.graceful_wrapup = function(job)
    local allowed_actions = {
        ["clear_items"] = true,
        ["retire"] = true,
        ["check_build_chunk"] = true,
        ["check_decon_chunk"] = true,
        ["check_upgrade_chunk"] = true
    }
    for k, value in pairs(global.job_bundles[job.bundle_index]) do -- clear unwanted actions
        if not value.returning_home and not allowed_actions[value.action] then
            global.job_bundles[job.bundle_index][k] = nil
        end
    end
    local new_t = {}
    local i = 1
    for _, v in pairs(global.job_bundles[job.bundle_index]) do -- reindex the job_bundle
        new_t[i] = v
        i = i + 1
    end
    global.job_bundles[job.bundle_index] = new_t
end

---@param grid LuaEquipmentGrid
---@param old_eq LuaEquipment
---@param new_eq string
me.replace_roboports = function(grid, old_eq, new_eq)
    local grid_pos = old_eq.position
    local eq_energy = old_eq.energy
    grid.take{ position = old_eq.position }
    local new_set = grid.put{ name = new_eq, position = grid_pos }
    if new_set then
        new_set.energy = eq_energy
    end
end

---@param grid LuaEquipmentGrid
---@param size 0|1
me.disable_roboports = function(grid, size) -- doesn't really disable them, it sets the size of that cell
    for _, eq in next, grid.equipment do
        if eq.type == "roboport-equipment" and eq.prototype.logistic_parameters.construction_radius > size then
            if not string.find(eq.name, "%-reduced%-") then
                me.replace_roboports(grid, eq, (eq.name .. "-reduced-" .. size ))
            end
        end
    end
end

---@param grid LuaEquipmentGrid
me.enable_roboports = function(grid) -- doesn't really enable roboports, it resets the equipment back to the original
    for _, eq in next, grid.equipment do
        if eq.type == "roboport-equipment" then
            me.replace_roboports(grid, eq, eq.prototype.take_result.name)
        end
    end
end

-------------------------------------------------------------------------------
--  Actions
-------------------------------------------------------------------------------

me.actions = {
    ---@param job Job
    ---@param position MapPosition
    go_to_position = function(job, position)
        local constructron = job.constructron
        job.attempt = job.attempt + 1
        me.disable_roboports(constructron.grid, 1)
        local distance = chunk_util.distance_between(constructron.position, position)
        constructron.grid.inhibit_movement_bonus = (distance < 32)
        constructron.enable_logistics_while_moving = job.landfill_job
        if job.landfill_job then -- is this a landfill job?
            if not constructron.logistic_cell.logistic_network.can_satisfy_request("landfill", 1) then
                me.graceful_wrapup(job) -- no landfill left.. leave
                return
            end
        end
        if distance > 12 then
            pathfinder.init_path_request(constructron, position, job)
        else
            job.path_active = true
            constructron.autopilot_destination = position -- does not use path finder!
        end
    end,

    ---@param job Job
    build = function(job)
        local constructron = job.constructron
        me.enable_roboports(constructron.grid)
        me.set_constructron_status(constructron, 'build_tick', game.tick)
    end,

    ---@param job Job
    deconstruct = function(job)
        local constructron = job.constructron
        me.enable_roboports(constructron.grid)
        me.set_constructron_status(constructron, 'deconstruct_tick', game.tick)
    end,

    ---@param job Job
    ---@param request_items ItemCounts
    request_items = function(job, request_items)
        local constructron = job.constructron
        if global.stations_count[constructron.surface.index] > 0 then
            local merged_items = table.deepcopy(request_items)
            -- get inventory conents
            local inventory_items = {}
            for _, inventory_type in pairs({"spider_trash", "spider_trunk"}) do
                local inventory = constructron.get_inventory(defines.inventory[inventory_type] --[[@as defines.inventory]])
                if inventory ~= nil then
                    local inv_contents = inventory.get_contents()
                    if (inv_contents ~= nil) then
                        for item, count in pairs(inv_contents) do
                            inventory_items[item] = (inventory_items[item] or 0) + count
                        end
                    end
                end
            end
            -- ensure robots are in the inventory
            merged_items[global.desired_robot_name] = global.desired_robot_count
            -- clear unwanted items from inventory
            for item_name, _ in pairs(inventory_items) do
                if not merged_items[item_name] then
                    merged_items[item_name] = 0
                end
            end
            -- request the required items for the job
            local slot = 1
            for name, count in pairs(merged_items) do
                if (global.allowed_items[name] == true) then
                    constructron.set_vehicle_logistic_slot(slot, {
                        name = name,
                        min = count,
                        max = count
                    })
                    slot = slot + 1
                end
            end
        end
    end,

    ---@param job Job
    clear_items = function(job)
        local constructron = job.constructron
        -- for when the constructron returns to service station and needs to empty it's inventory.
        local slot = 1
        local desired_robot_count = global.desired_robot_count
        local desired_robot_name = global.desired_robot_name
        local inventory = constructron.get_inventory(defines.inventory.spider_trunk)
        local filtered_items = {}
        local robot_count = 0
        for i = 1, #inventory do
            local item = inventory[i]
            if item.valid_for_read then
                if not global.clear_robots_when_idle then
                    if not (item.prototype.place_result and item.prototype.place_result.type == "construction-robot") then
                        if not filtered_items[item.name] then
                            constructron.set_vehicle_logistic_slot(slot, {
                                name = item.name,
                                min = 0,
                                max = 0
                            })
                            slot = slot + 1
                            filtered_items[item.name] = true
                        end
                    else
                        robot_count = robot_count + item.count
                        if robot_count > desired_robot_count then
                            if not filtered_items[item.name] then
                                if item.name == desired_robot_name then
                                    constructron.set_vehicle_logistic_slot(slot, {
                                        name = item.name,
                                        min = desired_robot_count --[[@as uint]],
                                        max = desired_robot_count --[[@as uint]]
                                    })
                                else
                                    constructron.set_vehicle_logistic_slot(slot, {
                                        name = item.name,
                                        min = 0,
                                        max = 0
                                    })
                                end
                                slot = slot + 1
                                filtered_items[item.name] = true
                            end
                        end
                    end
                else
                    if not filtered_items[item.name] then
                        constructron.set_vehicle_logistic_slot(slot, {
                            name = item.name,
                            min = 0,
                            max = 0
                        })
                        slot = slot + 1
                        filtered_items[item.name] = true
                    end
                end
            end
        end
    end,

    ---@param job Job
    retire = function(job)
        local constructron = job.constructron
        me.enable_roboports(constructron.grid)
        me.paint_constructron(constructron, 'idle')
        me.set_constructron_status(constructron, 'busy', false)
        if (global.constructrons_count[constructron.surface.index] > 10) then
            local distance = 5 + math.random(5)
            local alpha = math.random(360)
            local offset = {x = (math.cos(alpha) * distance), y = (math.sin(alpha) * distance)}
            local new_position = {x = (constructron.position.x + offset.x), y = (constructron.position.y + offset.y)}
            constructron.autopilot_destination = new_position
        end
    end,

    ---@param _ LuaEntity[]
    ---@param chunk Chunk
    check_build_chunk = function(_, chunk)
        local entity_names = {}
        for name, _ in pairs(chunk.required_items) do
            table.insert(entity_names, name)
        end
        local surface = game.surfaces[chunk.surface]

        if (chunk.minimum.x == chunk.maximum.x) and (chunk.minimum.y == chunk.maximum.y) then
            chunk.minimum.x = chunk.minimum.x - 1
            chunk.minimum.y = chunk.minimum.y - 1
            chunk.maximum.x = chunk.maximum.x + 1
            chunk.maximum.y = chunk.maximum.y + 1
        end

        debug_lib.draw_rectangle(chunk.minimum, chunk.maximum, surface, color_lib.color_alpha(color_lib.colors.blue, 0.5))

        local ghosts = surface.find_entities_filtered {
            area = {chunk.minimum, chunk.maximum},
            type = {"entity-ghost", "tile-ghost", "item-request-proxy"},
            force = "player"
        } or {}
        if next(ghosts) then -- if there are ghosts because inventory doesn't have the items for them, add them to be built for the next job
            debug_lib.DebugLog('added ' .. #ghosts .. ' unbuilt ghosts.')

            for i, entity in ipairs(ghosts) do
                global.ghost_index = global.ghost_index + 1
                global.ghost_entities[global.ghost_index] = entity
            end
            global.ghost_tick = game.tick
        end
    end,

    ---@param chunk Chunk
    check_decon_chunk = function(_, chunk)
        local surface = game.surfaces[chunk.surface]

        if (chunk.minimum.x == chunk.maximum.x) and (chunk.minimum.y == chunk.maximum.y) then
            chunk.minimum.x = chunk.minimum.x - 1
            chunk.minimum.y = chunk.minimum.y - 1
            chunk.maximum.x = chunk.maximum.x + 1
            chunk.maximum.y = chunk.maximum.y + 1
        end

        debug_lib.draw_rectangle(chunk.minimum, chunk.maximum, surface, color_lib.color_alpha(color_lib.colors.red, 0.5))

        local decons = surface.find_entities_filtered {
            area = {chunk.minimum, chunk.maximum},
            to_be_deconstructed = true,
            force = {"player", "neutral"}
        } or {}
        if next(decons) then -- if there are ghosts because inventory doesn't have the items for them, add them to be built for the next job
            debug_lib.DebugLog('added ' .. #decons .. ' to be deconstructed.')

            for i, entity in ipairs(decons) do
                global.decon_index = global.decon_index + 1
                global.deconstruction_entities[global.decon_index] = entity
            end
            global.deconstruct_marked_tick = game.tick
        end
    end,

    ---@param _ LuaEntity[]
    ---@param chunk Chunk
    check_upgrade_chunk = function(_, chunk)
        local surface = game.surfaces[chunk.surface]

        if (chunk.minimum.x == chunk.maximum.x) and (chunk.minimum.y == chunk.maximum.y) then
            chunk.minimum.x = chunk.minimum.x - 1
            chunk.minimum.y = chunk.minimum.y - 1
            chunk.maximum.x = chunk.maximum.x + 1
            chunk.maximum.y = chunk.maximum.y + 1
        end

        debug_lib.draw_rectangle(chunk.minimum, chunk.maximum, surface, color_lib.color_alpha(color_lib.colors.green, 0.5))

        local upgrades = surface.find_entities_filtered {
            area = {chunk.minimum, chunk.maximum},
            force = "player",
            to_be_upgraded = true
        }

        if next(upgrades) then
            debug_lib.DebugLog('added ' .. #upgrades .. ' missed entity upgrades.')
            for i, entity in ipairs(upgrades) do
                global.upgrade_index = global.upgrade_index + 1
                global.upgrade_entities[global.upgrade_index] = entity
            end
            global.upgrade_marked_tick = game.tick
        end
    end
}

-------------------------------------------------------------------------------
--  Conditions
-------------------------------------------------------------------------------

me.conditions = {
    ---@param job Job
    ---@param position MapPosition
    ---@return boolean
    position_done = function(job, position) -- this is condition for action "go_to_position"
        local constructron = job.constructron
        debug_lib.VisualDebugText("Moving to position", constructron, -1, 1)

        local ticks = (game.tick - job.start_tick)
        if not (ticks > 119) then return false end -- not enough time (two seconds) since last check

        local distance_from_pos = chunk_util.distance_between(constructron.position, position)
        if (distance_from_pos < 5) then return true end -- condition is satisfied

        if not job.path_active then -- check if the path is active
            if job.request_pathid and not global.pathfinder_requests[job.request_pathid] then -- check that there is a request
                if ticks > 900 then
                    job.start_tick = game.tick
                    me.actions[job.action](job, table.unpack(job.action_args or {})) -- there is no request, request a path.
                end
            end
            debug_lib.VisualDebugText("Waiting for pathfinder", constructron, -0.5, 1)
            return false -- condition is not met
        end

        if job.landfill_job then -- is this a landfill job?
            if not constructron.logistic_cell or not constructron.logistic_cell.logistic_network.can_satisfy_request("landfill", 1) then
                -- !! Logic gap - Constructrons will return home even if there is other entities to build.
                if not constructron.logistic_cell then
                    debug_lib.VisualDebugText("Job wrapup: Roboports removed", constructron, -0.5, 5)
                else
                    debug_lib.VisualDebugText("Job wrapup: No landfill", constructron, -0.5, 5)
                end
                me.graceful_wrapup(job) -- no landfill left.. leave
                return false
            end
        end

        if job.attempt > 3 and not job.returning_home then
            debug_lib.VisualDebugText("Job wrapup: Too many failed attempts", constructron, -0.5, 5)
            me.graceful_wrapup(job)
            return false
        end

        if not constructron.autopilot_destination then -- path lost recovery
            job.start_tick = game.tick
            me.actions[job.action](job, table.unpack(job.action_args or {})) -- retry
            return false
        end

        local mvmt_last_distance = job.mvmt_last_distance
        local distance = chunk_util.distance_between(constructron.position, constructron.autopilot_destination)
        if (constructron.speed < 0.1) and mvmt_last_distance and ((mvmt_last_distance - distance) < 2) then -- stuck check: if movement has not progressed at least two tiles
            job.mvmt_last_distance = nil
            job.start_tick = game.tick
            me.actions[job.action](job, table.unpack(job.action_args or {})) -- retry
            return false
        end

        job.mvmt_last_distance = distance
        job.start_tick = game.tick
        return false -- condition is not met
    end,

    ---@param job Job
    ---@return boolean
    build_done = function(job)
        local constructron = job.constructron
        debug_lib.VisualDebugText("Constructing", constructron, -1, 1)
        local build_tick = me.get_constructron_status(constructron, 'build_tick')
        local game_tick = game.tick

        if (game_tick - build_tick) > 119 then
            if constructron.logistic_cell then
                local logistic_network = constructron.logistic_cell.logistic_network
                if (me.robots_active(logistic_network)) then
                    me.set_constructron_status(constructron, 'build_tick', game.tick)
                    return false -- robots are active
                else
                    local cell = logistic_network.cells[1]
                    local area = chunk_util.get_area_from_position(constructron.position, cell.construction_radius)
                    local ghosts = constructron.surface.find_entities_filtered {
                        area = area,
                        name = {"entity-ghost", "tile-ghost"},
                        force = constructron.force.name
                    }

                    for _, entity in pairs(ghosts) do
                        -- is the entity in range?
                        if cell.is_in_construction_range(entity.position) then
                            -- can the entity be built?
                            local item = entity.ghost_prototype.items_to_place_this[1]
                            if logistic_network.can_satisfy_request(item.name, (item.count or 1)) then
                                -- construction not yet complete
                                me.set_constructron_status(constructron, 'build_tick', game.tick)
                                return false
                            end
                        end
                    end
                end
                return true -- condition is satisfied
            else
                me.graceful_wrapup(job) -- missing roboports.. leave
                return false
            end
        end
        return false
    end,

    ---@param job Job
    ---@return boolean
    deconstruction_done = function(job)
        local constructron = job.constructron
        debug_lib.VisualDebugText("Deconstructing", constructron, -1, 1)
        local decon_tick = me.get_constructron_status(constructron, 'deconstruct_tick')
        local game_tick = game.tick

        if (game_tick - decon_tick) > 119 then
            if constructron.logistic_cell then
                local logistic_network = constructron.logistic_cell.logistic_network
                if (me.robots_active(logistic_network)) then
                    local empty_stacks = 0
                    local inventory = constructron.get_inventory(defines.inventory.spider_trunk)
                    empty_stacks = empty_stacks + (inventory.count_empty_stacks())
                    if empty_stacks > 0 then
                        me.set_constructron_status(constructron, 'deconstruct_tick', game.tick)
                        return false -- robots are active
                    else
                        me.disable_roboports(constructron.grid, 0)
                        me.graceful_wrapup(job) -- there is no inventory space.. leave
                        return false
                    end
                else
                    local cell = logistic_network.cells[1]
                    local area = chunk_util.get_area_from_position(constructron.position, cell.construction_radius)
                    local decons = constructron.surface.find_entities_filtered {
                        area = area,
                        to_be_deconstructed = true,
                        force = {constructron.force.name, "neutral"}
                    }

                    -- are the entities actually in range?
                    if not ((game_tick - decon_tick) < 900) then
                        for _, entity in pairs(decons) do
                            if cell.is_in_construction_range(entity.position) then
                                -- construction not yet complete
                                me.set_constructron_status(constructron, 'deconstruct_tick', game.tick)
                                return false
                            end
                        end
                    end
                    me.disable_roboports(constructron.grid, 0)
                    return true -- condition is satisfied
                end
            else
                me.graceful_wrapup(job) -- missing roboports.. leave
                return false
            end
        end
        return false
    end,

    ---@param job Job
    ---@return boolean
    upgrade_done = function(job)
        local constructron = job.constructron
        debug_lib.VisualDebugText("Constructing", constructron, -1, 1)
        local build_tick = me.get_constructron_status(constructron, 'build_tick')
        local game_tick = game.tick

        if (game_tick - build_tick) > 119 then
            if constructron.logistic_cell then
                local logistic_network = constructron.logistic_cell.logistic_network
                if (me.robots_active(logistic_network)) then
                    me.set_constructron_status(constructron, 'build_tick', game.tick)
                    return false -- robots are active
                else
                    local cell = logistic_network.cells[1]
                    local area = chunk_util.get_area_from_position(constructron.position, cell.construction_radius)
                    local upgrades = constructron.surface.find_entities_filtered {
                        area = area,
                        to_be_upgraded = true,
                        force = constructron.force.name
                    }

                    for _, entity in pairs(upgrades) do
                        -- is the entity in range?
                        if cell.is_in_construction_range(entity.position) then
                            -- can the entity be built?
                            local target = entity.get_upgrade_target()
                            if logistic_network.can_satisfy_request(target.items_to_place_this[1].name, 1) then
                                -- construction not yet complete
                                me.set_constructron_status(constructron, 'build_tick', game.tick)
                                return false
                            end
                        end
                    end
                end
                return true -- condition is satisfied
            else
                me.graceful_wrapup(job) -- missing roboports.. leave
                return false
            end
        end
        return false
    end,

    ---@param job Job
    ---@return boolean
    request_done = function(job)
        local constructron = job.constructron
        local ticks = (game.tick - job.start_tick)
        local surface_index = constructron.surface.index
        local logistic_condition = true
        debug_lib.VisualDebugText("Awaiting logistics", constructron, -1, 1)
        -- check status of logisitc requests
        local trunk_inventory = constructron.get_inventory(defines.inventory.spider_trunk)
        local trunk = {} -- what we have
        for i = 1, #trunk_inventory do
            local item = trunk_inventory[i]
            if item.valid_for_read then
                trunk[item.name] = (trunk[item.name] or 0) + item.count
            end
        end
        -- ensure that what we do not want has been taken
        local trash_inventory = constructron.get_inventory(defines.inventory.spider_trash)
        if trash_inventory then
            local trash_items = trash_inventory.get_contents()
            if next(trash_items) then
                logistic_condition = false
            end
        end
        -- ensure what we are asking for has been delivered
        for i = 1, constructron.request_slot_count do ---@cast i uint
            local request = constructron.get_vehicle_logistic_slot(i)
            if request then
                if not (((trunk[request.name] or 0) >= request.min) and ((trunk[request.name] or 0) <= request.max)) then
                    logistic_condition = false
                end
            end
        end
        if not logistic_condition then
            if not (job.action == "clear_items") then
                -- alert
                if (ticks > global.construction_mat_alert) then
                    for _, player in pairs(game.players) do
                        player.add_alert(constructron, defines.alert_type.no_material_for_construction)
                    end
                end
                -- station roaming
                if (ticks > global.max_jobtime) and (global.stations_count[(surface_index)] > 0) then
                    local closest_station = me.get_closest_service_station(constructron)
                    for unit_number, station in pairs(job.unused_stations) do
                        if not station.valid then
                            job.unused_stations[unit_number] = nil
                        end
                    end
                    job.unused_stations[closest_station.unit_number] = nil
                    if not (next(job.unused_stations)) then
                        job.unused_stations = me.get_service_stations(surface_index)
                        if not #job.unused_stations == 1 then
                            job.unused_stations[closest_station.unit_number] = nil
                        end
                    end
                    local next_station = me.get_closest_unused_service_station(constructron, job.unused_stations)
                    table.insert(global.job_bundles[job.bundle_index], 1, {
                        action = 'go_to_position',
                        action_args = {next_station.position},
                        leave_condition = 'position_done',
                        leave_args = {next_station.position},
                        constructron = constructron,
                        bundle_index = job.bundle_index
                    })
                    job.start_tick = game.tick
                    debug_lib.VisualDebugText("Trying a different station", constructron, -0.5, 5)
                end
            end
            return false -- condition is not met
        end
        -- clear logistic request and proceed with job
        for i = 1, constructron.request_slot_count do --[[@cast i uint]]
            constructron.clear_vehicle_logistic_slot(i)
        end
        return true -- condition is satisfied
    end,

    ---@return boolean
    pass = function()
        return true
    end
}

-------------------------------------------------------------------------------

me.perform_surface_cleanup = function(_)
    debug_lib.DebugLog('Surface job validation & cleanup')
    for s, surface in pairs(game.surfaces) do
        if not global.constructrons_count[surface.index] or not global.stations_count[surface.index] then
            global.constructrons_count[surface.index] = 0
            global.stations_count[surface.index] = 0
        end
        if (global.constructrons_count[surface.index] <= 0) or (global.stations_count[surface.index] <= 0) then
            debug_lib.DebugLog('No Constructrons or Service Stations found on ' .. surface.name)
            me.force_surface_cleanup(surface)
        end
    end
end

---@param surface LuaSurface
me.force_surface_cleanup = function(surface)
    debug_lib.DebugLog('All job queues on '.. surface.name ..' cleared!')
    global.construct_queue[surface.index] = {}
    global.deconstruct_queue[surface.index] = {}
    global.upgrade_queue[surface.index] = {}
    global.repair_queue[surface.index] = {}
end


---@param event EventData.on_runtime_mod_setting_changed
me.mod_settings_changed = function(event)
    log("mod setting change: " .. event.setting)
    local setting = event.setting
    if setting == "construct_jobs" then
        global.construction_job_toggle = settings.global["construct_jobs"].value
    elseif setting == "rebuild_jobs" then
        global.rebuild_job_toggle = settings.global["rebuild_jobs"].value
    elseif setting == "deconstruct_jobs" then
        global.deconstruction_job_toggle = settings.global["deconstruct_jobs"].value
    elseif setting == "upgrade_jobs" then
        global.upgrade_job_toggle = settings.global["upgrade_jobs"].value
    elseif setting == "repair_jobs" then
        global.repair_job_toggle = settings.global["repair_jobs"].value
    elseif setting == "constructron-debug-enabled" then
        global.debug_toggle = settings.global["constructron-debug-enabled"].value
    elseif setting == "job-start-delay" then
        global.job_start_delay = (settings.global["job-start-delay"].value * 60)
    elseif setting == "desired_robot_count" then
        global.desired_robot_count = settings.global["desired_robot_count"].value
    elseif setting == "desired_robot_name" then
        global.desired_robot_name = settings.global["desired_robot_name"].value
    elseif setting == "construction_mat_alert" then
        global.construction_mat_alert = (settings.global["construction_mat_alert"].value * 60)
    elseif setting == "max-jobtime-per-job" then
        global.max_jobtime = (settings.global["max-jobtime-per-job"].value * 60 * 60)
    elseif setting == "entities_per_tick" then
        global.entities_per_tick = settings.global["entities_per_tick"].value --[[@as uint]]
    elseif setting == "clear_robots_when_idle" then
        global.clear_robots_when_idle = settings.global["clear_robots_when_idle"].value --[[@as boolean]]
    end
end

---@param event EventData.on_surface_created
me.on_surface_created = function(event)
    local index = event.surface_index

    global.construct_queue[index] = {}
    global.deconstruct_queue[index] = {}
    global.upgrade_queue[index] = {}
    global.repair_queue[index] = {}

    global.constructrons_count[index] = 0
    global.stations_count[index] = 0
end

---@param event EventData.on_surface_deleted
me.on_surface_deleted = function(event)
    local index = event.surface_index

    global.construct_queue[index] = nil
    global.deconstruct_queue[index] = nil
    global.upgrade_queue[index] = nil
    global.repair_queue[index] = nil

    global.constructrons_count[index] = nil
    global.stations_count[index] = nil
end

---@param event EventData.on_entity_cloned
me.on_entity_cloned = function(event)
    local entity = event.destination
    if entity.name == 'constructron' or entity.name == "constructron-rocket-powered" then
        local registration_number = script.register_on_entity_destroyed(entity)
        me.paint_constructron(entity, 'idle')
        global.constructrons[entity.unit_number] = entity
        global.registered_entities[registration_number] = {
            name = "constructron",
            surface = entity.surface.index
        }
        global.constructrons_count[entity.surface.index] = global.constructrons_count[entity.surface.index] + 1
    elseif entity.name == "service_station" then
        local registration_number = script.register_on_entity_destroyed(entity)
        global.service_stations[entity.unit_number] = entity
        global.registered_entities[registration_number] = {
            name = "service_station",
            surface = entity.surface.index
        }
        global.stations_count[entity.surface.index] = global.stations_count[entity.surface.index] + 1
    end
end

---@param event
---| EventData.on_entity_destroyed
---| EventData.script_raised_destroy
me.on_entity_destroyed = function(event)
    if global.registered_entities[event.registration_number] then
        local removed_entity = global.registered_entities[event.registration_number]
        if removed_entity.name == "constructron" or removed_entity.name == "constructron-rocket-powered" then
            local surface = removed_entity.surface
            global.constructrons_count[surface] = math.max(0, (global.constructrons_count[surface] or 0) - 1)
            global.constructrons[event.unit_number] = nil
            global.constructron_statuses[event.unit_number] = nil
        elseif removed_entity.name == "service_station" then
            local surface = removed_entity.surface
            global.stations_count[surface] = math.max(0, (global.stations_count[surface] or 0) - 1)
            global.service_stations[event.unit_number] = nil
        end
        global.registered_entities[event.registration_number] = nil
    end
end

---@param constructron LuaEntity
---@param state ConstructronStatus
---@param value uint | boolean
me.set_constructron_status = function(constructron, state, value)
    if global.constructron_statuses[constructron.unit_number] then
        global.constructron_statuses[constructron.unit_number][state] = value
    else
        global.constructron_statuses[constructron.unit_number] = {}
        global.constructron_statuses[constructron.unit_number][state] = value
    end
end

---@param constructron LuaEntity
---@param state ConstructronStatus
---@return uint | boolean?
me.get_constructron_status = function(constructron, state)
    if global.constructron_statuses[constructron.unit_number] then
        return global.constructron_statuses[constructron.unit_number][state]
    end
    return nil
end

---@param surface_index uint
---@return table<uint, LuaEntity>
me.get_service_stations = function(surface_index)
    ---@type table<uint, LuaEntity>
    local stations_on_surface = {}
    for s, station in pairs(global.service_stations) do
        if station and station.valid then
            if (surface_index == station.surface.index) then
                stations_on_surface[station.unit_number] = station
            end
        else
            global.service_stations[s] = nil
        end
    end
    return stations_on_surface or {}
end

---@param constructron LuaEntity
---@return LuaEntity?
me.get_closest_service_station = function(constructron)
    local service_stations = me.get_service_stations(constructron.surface.index)
    if service_stations then
        for unit_number, station in pairs(service_stations) do
            if not station.valid then
                global.service_stations[unit_number] = nil -- could be redundant as entities are now registered
            end
        end
        local service_station_index = chunk_util.get_closest_object(service_stations, constructron.position)
        return service_stations[service_station_index]
    end
end

---@param constructron LuaEntity
---@param unused_stations LuaEntity[]
---@return LuaEntity?
me.get_closest_unused_service_station = function(constructron, unused_stations)
    if unused_stations then
        local unused_stations_index = chunk_util.get_closest_object(unused_stations, constructron.position)
        return unused_stations[unused_stations_index]
    end
end

---@param constructron LuaEntity
---@param color_state "idle" | "construct" | "deconstruct" | "upgrade" | "repair"
me.paint_constructron = function(constructron, color_state)
    if color_state == 'idle' then
        constructron.color = color_lib.color_alpha(color_lib.colors.white, 0.25)
    elseif color_state == 'construct' then
        constructron.color = color_lib.color_alpha(color_lib.colors.blue, 0.4)
    elseif color_state == 'deconstruct' then
        constructron.color = color_lib.color_alpha(color_lib.colors.red, 0.4)
    elseif color_state == 'upgrade' then
        constructron.color = color_lib.color_alpha(color_lib.colors.green, 0.4)
    elseif color_state == 'repair' then
        constructron.color = color_lib.color_alpha(color_lib.colors.charcoal, 0.4)
    end
end

return me
