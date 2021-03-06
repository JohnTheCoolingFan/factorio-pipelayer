local Connector = require "Connector"
local ConnectorSet = require "ConnectorSet"
local Constants = require "Constants"
local Graph = require "lualib.Graph"
local Scheduler = require "lualib.Scheduler"

local debug = function() end
if Constants.DEBUG_ENABLED then
  debug = function(x) log(serpent.block(x, {name = "_"})) end
end

local SURFACE_NAME = Constants.SURFACE_NAME

local active_update_period = 1
local inactive_update_period
local no_fluid_update_period

local pipe_capacity_cache = {}
local function pipe_capacity(name)
  if not pipe_capacity_cache[name] then
    pipe_capacity_cache[name] = game.entity_prototypes[name].fluid_capacity
  end
  return pipe_capacity_cache[name]
end

local function fill_pipe(entity, fluid_name)
  if fluid_name then
    local new_fluid = {name = fluid_name, amount = pipe_capacity(entity.name)}
    entity.fluidbox[1] = new_fluid
  else
    entity.fluidbox[1] = nil
  end
end

local function set_update_periods()
  local base_update_period = settings.global["pipelayer-update-period"].value
  inactive_update_period = base_update_period
  no_fluid_update_period = base_update_period * 5
  log("setting update period to "..base_update_period.." ticks.")
end

local Network = {}

local all_networks
local network_for_entity = {}

function Network.on_init()
  global.all_networks = {}
  global.network_iter = nil
  Network:on_load()
end

function Network.on_load()
  set_update_periods()
  all_networks = global.all_networks
  for _, network in pairs(all_networks) do
    setmetatable(network, {__index = Network})
    Graph.restore(network.graph)
    for unit_number, pipe in pairs(network.pipes) do
      if pipe.valid then
        network_for_entity[pipe.unit_number] = network
      else
        network.pipes[unit_number] = nil
      end
    end
    ConnectorSet.restore(network.connectors)
    Scheduler.schedule(network.next_tick or 0, function(tick) network:update(tick) end)
  end
end

--[[
  {
    fluid_name = "water",
    Graph = Graph(),
    pipes = {
      [unit_number] = pipe_entity,
      ...
    },
    connectors = ConnectorSet()
  }
]]
function Network.new()
  global.network_id = (global.network_id or 0) + 1
  local network_id = global.network_id
  local self = {
    id = network_id,
    fluid_name = nil,
    graph = Graph.new(),
    pipes = {},
    connectors = ConnectorSet.new(),
    next_tick = 0,
  }
  setmetatable(self, {__index = Network})
  Scheduler.schedule(self.next_tick, function(tick) self:update(tick) end)
  all_networks[network_id] = self
  debug("created new network "..network_id)
  return self
end

function Network.for_entity(entity)
  return network_for_entity[entity.unit_number]
end

function Network:destroy()
  if Constants.DEBUG_ENABLED then
    for pipe, id in pairs(network_for_entity) do
      if id == self.id then
        error("Network destroyed while pipe reference exists for pipe "..pipe.unit_number)
      end
    end
  end

  debug("destroyed network "..self.id)
  all_networks[self.id] = nil
  if global.network_iter == self.id then
    global.network_iter = nil
  end
end

function Network:is_singleton()
  local n = next(self.pipes)
  local n2 = next(self.pipes, n)
  return n and not n2
end

function Network:absorb(other_network)
  for _, entity in pairs(other_network.pipes) do
    self:add_underground_pipe(entity)
  end
  for connector in other_network.connectors:all_connectors() do
    self:add_connector(connector)
  end
  if self.fluid_name ~= other_network.fluid_name then
    self:set_fluid(nil)
  end
  other_network:destroy()
end

function Network:add_connector_entity(above, below_unit_number)
  local connector = Connector.new(above, below_unit_number)
  self:add_connector(connector)
end

function Network:add_connector(connector)
  self.connectors:add(connector)
end

function Network:remove_connector_by_below_unit_number(below_unit_number)
  local connector = Connector.for_below_unit_number(below_unit_number)
  if connector then
    self.connectors:remove(connector)
  end
end

function Network:add_underground_pipe(entity)
  assert(entity.surface.name == SURFACE_NAME)
  local unit_number = entity.unit_number
  network_for_entity[unit_number] = self
  self.pipes[unit_number] = entity
  self.graph:add(unit_number)
  for _, neighbor in ipairs(entity.neighbours[1]) do
    self.graph:add(unit_number, neighbor.unit_number)
  end
  fill_pipe(entity, self.fluid_name)
end

function Network:remove_underground_pipe(entity)
  assert(entity.surface.name == SURFACE_NAME)
  local unit_number = entity.unit_number
  self.pipes[unit_number] = nil
  self:remove_connector_by_below_unit_number(unit_number)
  network_for_entity[unit_number] = nil

  if #entity.neighbours[1] > 1 then
    -- multiple connections for this pipe, so this may split the network into multiple new networks
    local fragments = self.graph:removal_fragments(unit_number)
    for i=2,#fragments do
      local fragment = fragments[i]
      local split_network = Network.new()
      for fragment_pipe_unit_number in pairs(fragment) do
        split_network:add_underground_pipe(self.pipes[fragment_pipe_unit_number])
        local connector = Connector.for_below_unit_number(fragment_pipe_unit_number)
        if connector then
          split_network:add_connector(connector)
          self.connectors:remove(connector)
        end
        self.pipes[fragment_pipe_unit_number] = nil
        self.graph:remove(fragment_pipe_unit_number)
      end
      split_network.graph:remove(unit_number)
    end
  end

  self.graph:remove(unit_number)
  if not next(self.pipes) then
    self:destroy()
  end
end

function Network:set_connector_mode(entity, mode)
  local connector = Connector.for_entity(entity)
  if mode == "input" then
    self.connectors:add_input(connector)
  elseif mode == "output" then
    self.connectors:add_output(connector)
  else
    error("invalid mode: "..mode)
  end
  connector.mode = mode
end

function Network:toggle_connector_mode(entity)
  local connector = Connector.for_entity(entity)
  local current_mode = connector.mode
  if current_mode == "input" then
    self:set_connector_mode(entity, "output")
  else
    self:set_connector_mode(entity, "input")
  end
  return connector.mode
end

local function foreach_connector(self, callback)
  local to_remove = {}
  for connector in self.connectors:all_connectors() do
    if connector.entity.valid then
      callback(connector)
    else
      to_remove[#to_remove+1] = connector
    end
  end
  for _, connector in ipairs(to_remove) do
    self.connectors:remove(connector)
  end
end

function Network:foreach_underground_entity(callback)
  for unit_number, pipe in pairs(self.pipes) do
    if pipe.valid then
      callback(pipe)
    else
      self.pipes[unit_number] = nil
    end
  end
end

function Network:set_fluid(fluid_name)
  debug("setting fluid for network "..self.id.." to "..(fluid_name or "(nil)"))
  self.fluid_name = fluid_name
  self:foreach_underground_entity(function(entity)
    fill_pipe(entity, self.fluid_name)
  end)
  local surface = game.surfaces[SURFACE_NAME]

  if not fluid_name then
    -- make sure underground connector counterparts reflect content of overworld
    foreach_connector(self, function(connector)
      local counterpart = surface.find_entity("pipelayer-connector", connector.entity.position)
      local fluidbox = connector.entity.fluidbox[1]
      if fluidbox and fluidbox.amount > 0 then
        fill_pipe(counterpart, fluidbox.name)
      end
    end)
  end
end

function Network:infer_fluid_from_connectors()
  local inferred_fluid
  local conflict
  foreach_connector(self, function(connector)
    -- debug("examining connector "..serpent.line(connector))
    local connector_fluidbox = connector.entity.fluidbox[1]
    if connector_fluidbox then
      if inferred_fluid then
        if connector_fluidbox.name ~= inferred_fluid then
          conflict = true
          return
        end
      else
        inferred_fluid = connector_fluidbox.name
      end
    end
  end)
  if conflict then
    return nil
  else
    return inferred_fluid
  end
end

function Network:can_transfer(from, to)
  if not from or not to then return false end
  local fluid_name = self.fluid_name
  return not from:is_conflicting(fluid_name) and not to:is_conflicting(fluid_name)
end

function Network:infer_fluid()
  local fluid_name = self:infer_fluid_from_connectors()
  -- debug("inferred fluid "..(fluid_name or "(nil)").." for network "..self.id)
  if fluid_name ~= self.fluid_name then
    self:set_fluid(fluid_name)
    return true
  end
  return false
end

function Network:reschedule(next_tick)
  self.next_tick = next_tick
  debug{msg="reschedule", next_tick=next_tick, network_id=self.id}
  Scheduler.schedule(next_tick, function(tick) self:update(tick) end)
end

function Network:update(tick)
  if not all_networks[self.id] then return end

  if not self.fluid_name then
    local success = self:infer_fluid()
    if not success then
      self:reschedule(tick + no_fluid_update_period)
      return
    end
  end

  local next_input_connector = self.connectors:next_input()
  local next_output_connector = self.connectors:next_output()
  -- debug{input=next_input_connector, output=next_output_connector}
  if not next_input_connector or not next_output_connector then
    debug("network "..self.id.." is not ready for transfer")
    self:reschedule(tick + inactive_update_period)
    return
  end

  if self:can_transfer(next_input_connector, next_output_connector) then
    debug{
      network=self.id,
      fluid=self.fluid_name,
      from=next_input_connector.entity.position,
      to=next_output_connector.entity.position
    }
    next_input_connector:transfer_to(self.fluid_name, next_output_connector)
  else
    if next_input_connector:is_conflicting(self.fluid_name)
    or next_output_connector:is_conflicting(self.fluid_name) then
      self:set_fluid(nil)
    end
  end

  self:reschedule(tick + active_update_period)
end

function Network.update_all(tick)
  Scheduler.on_tick(tick)
end

function Network.on_runtime_mod_setting_changed(event)
  local name = event.setting
  if name == "pipelayer-transfer-threshold" then
    Connector.on_runtime_mod_setting_changed(event)
  elseif name == "pipelayer-update-period" then
    set_update_periods()
  end
end

return Network