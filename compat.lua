--[[
	bestguns/compat.lua
	-------------------
	Makes bestguns self-contained: it needs a control-event system (press/hold/
	release) and a player physics-factor system, which in some games are provided
	by the standalone `controls` and `playerphysics` mods.

	To have zero hard dependencies while never conflicting when those mods DO
	exist, we reuse the real global when it is present (e.g. inside CTF, which
	ships both), and otherwise install a private bundled copy on the bestguns
	table. Everything in bestguns then talks to `bestguns.controls` /
	`bestguns.playerphysics`, so the exact same code runs standalone or in-game.
]]

--------------------------------------------------------------------------------
-- controls: control press/hold/release events
--------------------------------------------------------------------------------
local controls = rawget(_G, "controls")
if not controls then
	controls = {
		registered_on_press = {},
		registered_on_hold = {},
		registered_on_release = {},
		players = {},
	}

	function controls.register_on_press(callback)
		table.insert(controls.registered_on_press, callback)
	end

	function controls.register_on_hold(callback)
		table.insert(controls.registered_on_hold, callback)
	end

	function controls.register_on_release(callback)
		table.insert(controls.registered_on_release, callback)
	end

	core.register_on_joinplayer(function(player)
		local name = player:get_player_name()
		controls.players[name] = {}
		for key in pairs(player:get_player_control()) do
			controls.players[name][key] = {false}
		end
	end)

	core.register_on_leaveplayer(function(player)
		controls.players[player:get_player_name()] = nil
	end)

	local function update_player_controls(player, player_controls)
		local time_now = core.get_us_time()
		for key, pressed in pairs(player:get_player_control()) do
			if player_controls[key] then
				if pressed and not player_controls[key][1] then
					for _, callback in pairs(controls.registered_on_press) do
						callback(player, key)
					end
					player_controls[key] = {true, time_now}
				elseif pressed and player_controls[key][1] then
					for _, callback in pairs(controls.registered_on_hold) do
						callback(player, key, (time_now - player_controls[key][2]) / 1e6)
					end
				elseif not pressed and player_controls[key][1] then
					for _, callback in pairs(controls.registered_on_release) do
						callback(player, key, (time_now - player_controls[key][2]) / 1e6)
					end
					player_controls[key] = {false}
				end
			end
		end
	end

	core.register_globalstep(function()
		for _, player in pairs(core.get_connected_players()) do
			local name = player:get_player_name()
			if controls.players[name] then
				update_player_controls(player, controls.players[name])
			end
		end
	end)
end

bestguns.controls = controls

--------------------------------------------------------------------------------
-- playerphysics: named, stackable physics-override factors
--------------------------------------------------------------------------------
local playerphysics = rawget(_G, "playerphysics")
if not playerphysics then
	playerphysics = {}

	local function calculate_attribute_product(player, attribute)
		local a = core.deserialize(player:get_meta():get_string("bestguns:physics"))
		local product = 1
		if a == nil or a[attribute] == nil then
			return product
		end
		local factors = a[attribute]
		if type(factors) == "table" then
			for _, factor in pairs(factors) do
				product = product * factor
			end
		end
		return product
	end

	function playerphysics.add_physics_factor(player, attribute, id, value)
		local meta = player:get_meta()
		local a = core.deserialize(meta:get_string("bestguns:physics"))
		if a == nil then
			a = { [attribute] = { [id] = value } }
		elseif a[attribute] == nil then
			a[attribute] = { [id] = value }
		else
			a[attribute][id] = value
		end
		meta:set_string("bestguns:physics", core.serialize(a))
		player:set_physics_override({[attribute] = calculate_attribute_product(player, attribute)})
	end

	function playerphysics.remove_physics_factor(player, attribute, id)
		local meta = player:get_meta()
		local a = core.deserialize(meta:get_string("bestguns:physics"))
		if a == nil or a[attribute] == nil then
			return
		end
		a[attribute][id] = nil
		meta:set_string("bestguns:physics", core.serialize(a))
		player:set_physics_override({[attribute] = calculate_attribute_product(player, attribute)})
	end

	function playerphysics.get_physics_factor(player, attribute, id)
		local a = core.deserialize(player:get_meta():get_string("bestguns:physics"))
		if a == nil or a[attribute] == nil then
			return nil
		end
		return a[attribute][id]
	end
end

bestguns.playerphysics = playerphysics
