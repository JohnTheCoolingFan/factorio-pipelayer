local Blueprint = require "Blueprint"
local Editor = require "Editor"
local Network = require "Network"

local function on_init()
  Network.on_init()
  Editor.on_init()
  Blueprint.on_init()
end

local function on_load()
  Network.on_load()
  Editor.on_load()
  Blueprint.on_load()
end

local event_handlers = {
  on_built_entity = function(event)
    if event.mod_name then
      Editor.on_robot_built_entity(event)
    else
      Blueprint.on_player_built_entity(event)
      Editor.on_player_built_entity(event)
    end
  end,

  on_robot_built_entity = function(event)
    local robot = event.robot
    local entity = event.created_entity
    local stack = event.stack
    Blueprint.on_robot_built_entity(robot, entity, stack)
    Editor.on_robot_built_entity(robot, entity, stack)
  end,

  on_pre_player_mined_item = function(event)
    Blueprint.on_pre_player_mined_item(event)
  end,

  on_player_mined_entity = function(event)
    Blueprint.on_player_mined_entity(event.player_index, event.entity, event.buffer)
    Editor.on_player_mined_entity(event)
  end,

  on_robot_mined_entity = function(event)
    local robot = event.robot
    local entity = event.entity
    local buffer = event.buffer
    Blueprint.on_robot_mined_entity(robot, entity, buffer)
    Editor.on_robot_mined_entity(robot, entity, buffer)
  end,

  on_player_setup_blueprint = function(event)
    Blueprint.on_player_setup_blueprint(event)
  end,

  on_put_item = function(event)
  end,

  on_player_deconstructed_area = function(event)
    Blueprint.on_player_deconstructed_area(event.player_index, event.area, event.item, event.alt)
  end,

  on_canceled_deconstruction = function(event)
    Blueprint.on_canceled_deconstruction(event.entity, event.player_index)
  end,

  on_player_rotated_entity = function(event)
     Editor.on_player_rotated_entity(event)
  end,

  on_entity_died = function(event)
    Editor.on_entity_died(event)
  end,

  on_runtime_mod_setting_changed = function(event)
    Network.on_runtime_mod_setting_changed(event)
  end,
}

local function on_toggle_editor(event)
  Editor.toggle_editor_status_for_player(event.player_index)
end

local function on_toggle_connector_mode(event)
  Editor.toggle_connector_mode(event.player_index)
end

local function on_tick(event)
  Network.update_all(event.tick)
end

script.on_init(on_init)
script.on_load(on_load)
script.on_nth_tick(1, on_tick)
script.on_event("pipelayer-toggle-editor-view", on_toggle_editor)
script.on_event("pipelayer-toggle-connector-mode", on_toggle_connector_mode)
for event_name, handler in pairs(event_handlers) do
  script.on_event(defines.events[event_name], handler)
end