bestguns = {
    registered_guns = {},
    registered_bullets = {},
    last_fire = {}, -- Tracks cooldowns: [player_name] = timestamp
    burst_start = {}, -- First-shot-accuracy ramp: [player_name] = burst start time
    bursting = {}, -- Burst-fire lock: [player_name] = true while a burst is in progress
    windup = {}, -- Hip-fire wind-up lock: [player_name] = true while the first shot of a hip-fired pull is delayed
    charge_start = {}, -- Hold-to-charge guns: [player_name] = charge start timestamp
    charge_hud = {}, -- Hold-to-charge guns: [player_name] = charge % hud id

    -- Global multiplier applied to all bullet damage. CTF (and any game that
    -- scales player HP up) leaves this at 1; standalone/vanilla-HP games can
    -- lower it (e.g. 0.1) so guns tuned for 200 HP don't one-shot a 20-HP player.
    damage_scale = 1,

    -- Distance damage falloff ("gun_range"). Each gun def carries a `gun_range`
    -- (default 1) = the fraction of full range at which it stays lethal. A shot
    -- does full damage out to `range_full * gun_range` metres, then scales down
    -- linearly to `range_min_damage` of its damage at `range_zero * gun_range`
    -- metres and beyond. Snipers use gun_range ~1 (hit hard far away), pistols
    -- ~0.3 (fall off fast). A gun with gun_range <= 0 gets no falloff at all.
    range_full = 25,
    range_zero = 110,
    range_min_damage = 0.35,

    -- Default downward acceleration (m/s^2) applied to every bullet in flight so
    -- rounds drop over distance. Set to real-world gravity so bullets arc like any
    -- falling object. A bullet def overrides this with its own `gravity` (set 0 for
    -- a dead-straight round).
    bullet_gravity = 9.81,

    -- Sounds played to the shooter when a bullet lands on a target. Point these
    -- at your own ogg files (drop them in sounds/), or set to nil to disable.
    -- Defaults expect sounds/bestguns_hit.ogg and sounds/bestguns_headshot.ogg.
    hit_sound = "bestguns_hit",
    headshot_sound = "bestguns_headshot",

    -- Default sound a bullet plays where it strikes a walkable node, and the
    -- default "whiz" a bullet plays to nearby players as it flies past. A bullet
    -- def overrides these per-bullet with `hit_node_sound` / `whiz_sound` (set
    -- either to false to silence that bullet). Node-/group-specific impact
    -- sounds are looked up in the registries below first.
    default_hit_node_sound = "bestguns_hit_ground",
    default_whiz_sound = "bestguns_whiz",

    -- How close (metres) a bullet must pass to a player for that player to hear
    -- the whiz, and how far away the whiz is still audible. A bullet def may
    -- override the trigger radius with `whiz_distance`.
    whiz_distance = 5,
    whiz_hear_distance = 20,

    -- Node-name and node-group -> impact-sound registries, consulted (node name
    -- first, then groups) when a bullet hits a walkable node, before falling
    -- back to the bullet's own `hit_node_sound` or `default_hit_node_sound`.
    -- Populate via bestguns.set_node_hit_sound / bestguns.set_group_hit_sound,
    -- e.g. bestguns.set_group_hit_sound("cracky", "bestguns_hit_metal").
    node_hit_sounds = {},
    group_hit_sounds = {},
}

-- Outside Capture the Flag, players run on vanilla-ish HP (Mineclonia = 20)
-- rather than CTF's scaled-up ~200, so guns tuned for CTF would one-shot
-- everything. Detect "not CTF" by the absence of its core mod and knock all
-- bullet damage down to a fifth. CTF (ctf_modebase present) keeps the full 1.0.
if not (core.get_modpath("ctf_modebase") or core.get_modpath("ctf_core")) then
    bestguns.damage_scale = 0.076
end

-- Register a node-name- or node-group-specific bullet impact sound. Pass a
-- sound name (string) to set one, or false to explicitly silence hits on that
-- node/group (overriding the per-bullet and global defaults).
function bestguns.set_node_hit_sound(node_name, sound)
    bestguns.node_hit_sounds[node_name] = sound
end
function bestguns.set_group_hit_sound(group_name, sound)
    bestguns.group_hit_sounds[group_name] = sound
end

-- Resolve the impact sound for a bullet striking `node`. Lookup order:
--   1. bullet_def.hit_node_sounds[node.name]      (per-bullet, exact node)
--   2. bestguns.node_hit_sounds[node.name]        (global, exact node)
--   3. bullet_def.hit_node_sounds["group:"..grp]  (per-bullet, by group)
--   4. bestguns.group_hit_sounds[grp]             (global, by group)
--   5. bullet_def.hit_node_sound                  (bullet's own default)
--   6. bestguns.default_hit_node_sound            (global default)
-- Any level may hold `false` to explicitly mean "silent" (returns nil).
function bestguns.node_hit_sound(bullet_def, node)
    local ndef = core.registered_nodes[node.name] or {}
    local per = bullet_def and bullet_def.hit_node_sounds

    if per and per[node.name] ~= nil then return per[node.name] or nil end
    if bestguns.node_hit_sounds[node.name] ~= nil then
        return bestguns.node_hit_sounds[node.name] or nil
    end

    for g in pairs(ndef.groups or {}) do
        if per and per["group:" .. g] ~= nil then return per["group:" .. g] or nil end
        if bestguns.group_hit_sounds[g] ~= nil then
            return bestguns.group_hit_sounds[g] or nil
        end
    end

    if bullet_def and bullet_def.hit_node_sound ~= nil then
        return bullet_def.hit_node_sound or nil
    end
    return bestguns.default_hit_node_sound
end

-- Overridable hook: return false to forbid a player from firing a given gun.
-- Used by game integrations (e.g. CTF class restrictions). Defaults to allow.
function bestguns.can_use_gun(player, gun_name)
    return true
end

-- [player_name] = the gun name the player most recently fired. Lets a spawned
-- bullet attribute itself to the firing gun even when a custom on_fire (e.g. a
-- shotgun's pellet spread) creates the bullet entity without stamping the gun
-- name on it (see bestguns.on_shot / on_hit below and the bullet on_activate).
bestguns.last_gun = {}

-- Overridable accuracy hooks. No-ops by default, so bestguns carries no hard
-- dependency on a stats mod; a stats mod replaces these to record per-gun
-- shooting accuracy.
--   on_shot: a bullet was fired by player `shooter_name` from gun `gun_name`.
--   on_hit : a fired bullet struck player `target` (`headshot` true on a headshot),
--            fired from gun `gun_name` by player `shooter_name`.
function bestguns.on_shot(shooter_name, gun_name) end
function bestguns.on_hit(shooter_name, gun_name, target, headshot) end

-- Public animation hook. Returns two values for third-person arm posing (see
-- ctf_player's player animation):
--   state      - the gun's action state, one of:
--                  "aim"    - aiming down the sights (RMB held on an ADS gun)
--                  "reload" - mid-reload: a magazine-fed gun with no magazine
--                             inserted, or a direct/break-action gun held open
--                  "hold"   - holding the gun at the ready (default)
--   one_handed - true if the gun def sets `one_handed` (pistols, SMGs, etc.):
--                such guns are held in the right hand only, so the animation
--                leaves the support (left) arm on its normal swing.
-- Returns nil when the player is not wielding a bestguns gun at all.
function bestguns.player_gun_state(player)
    local wielded = player:get_wielded_item()
    local gun_name = wielded:get_name()
    if core.get_item_group(gun_name, "bestguns_gun") == 0 then return nil end

    local def = bestguns.registered_guns[gun_name]
    local meta = wielded:get_meta()
    local ctrl = player:get_player_control()
    local one_handed = def and def.one_handed or false

    -- Reloading: break/direct-action gun held open, or a magazine gun with its
    -- magazine ejected (the pose the player holds while topping it back up).
    if def then
        if def.load_action == "direct" and meta:get_int("is_open") == 1 then
            return "reload", one_handed
        elseif def.load_action == "magazine" and meta:get_int("has_mag") == 0 then
            return "reload", one_handed
        end
    end

    -- Aiming down the sights: RMB, unless the gun has no ADS or repurposes RMB
    -- for a custom alt-fire (in which case RMB isn't "aim").
    if ctrl.RMB and def and not def.no_ads and not def.on_altfire then
        return "aim", one_handed
    end

    return "hold", one_handed
end

function bestguns.scope(player, enable, itemstack, zoom_cancel)  
  local name = player:get_player_name()
  itemstack = itemstack or ItemStack("")
  local gundef = bestguns.registered_guns[itemstack:get_name()] or {zoom = 0.9, scope_size = 2, kick = 2.04}
  bestguns[name] = bestguns[name] or {}
  if bestguns[name].hud_removing or enable then
    bestguns[name].hud_removing = nil
    local oldhud = bestguns[name].hud or {}
    for i,hudid in pairs(oldhud) do
      player:hud_remove(hudid)
    end
    bestguns[name].hud = nil
  end
  local oldhud = bestguns[name].hud
  if oldhud and not enable then
    bestguns[name].hud_removing = 0.1
  end

  bestguns.playerphysics.remove_physics_factor(player, "speed", "bestguns:aiming_speed")

  if enable == "kick" then
    -- `kick` is a recoil-strength number (~1.8 to 4), NOT a raw FOV multiplier.
    -- Feeding it straight into set_fov's multiplier turned big-kick guns (deagle
    -- kick=4 -> 3x FOV!) into nauseating fisheye punches. Map it to a gentle,
    -- bounded widen instead: bigger kick still punches harder, but sanely.
    -- (kick 2.04 -> ~1.04, matching the old baseline; kick 4 -> ~1.08.)
    local punch = math.min(1 + (gundef.kick or 2.04) * 0.02, 1.2)
    player:set_fov(punch, true, 0.1)
    return
  end
  
  
  if not enable then zoom_cancel = true end
  if zoom_cancel then player:set_fov(0, false, 0.1) end
  if not enable then return end
  
  if not bestguns.can_fire(itemstack, player) then return end
  
  if not zoom_cancel then
    player:set_fov(gundef.zoom, true, 0.3)
  end
  
  bestguns.playerphysics.add_physics_factor(player, "speed", "bestguns:aiming_speed", 0.8)


  if not gundef.zoomhud then return end
  bestguns[name].hud = {}
  bestguns[name].hud[1] = player:hud_add({
    type = "image",
    text = gundef.scope_texture or "bestguns_scope.png",
    position = {x=0.5, y=0.5},
    scale = {x = 20*gundef.scope_size, y = 20*gundef.scope_size},
    alignment = {x=0, y=0},
    offset = {x=0, y=0},
  })
  bestguns[name].hud[2] = player:hud_add({
    type = "image",
    text = gundef.scope_hud_texture or "bestguns_scope_hud_cover.png",
    position = {x=0.5, y=0.5},
    scale = {x = 300*gundef.scope_size, y = 300*gundef.scope_size},
    alignment = {x=0, y=0},
    offset = {x=0, y=0},
  })
end

local noise_seed = math.random(9999999)
local noise_seeded = math.random(9999999)
local hi = 0
local lo = 0
function bestguns.r(num, num2)
  noise_seed = noise_seed + 1

  local random_noise = {
     offset = 0,
     scale = 0.25,
     spread = {x = 40, y = 40, z = 40},
     seed = noise_seeded,
     octaves = 5,
     persistence = 1,
  }
  local random_noise2 = table.copy(random_noise)
  random_noise2.seed = random_noise2.seed + 10
  
  local rv_noise = core.get_value_noise(random_noise):get_2d({x = noise_seed, y = 0})
  local rv_noise2 = core.get_value_noise(random_noise2):get_2d({x = noise_seed, y = 0})


  if rv_noise > hi then hi = rv_noise elseif rv_noise < lo then lo = rv_noise end
  if num2 then
    if math.random(2) == 1 then
      final_value = (rv_noise+1)/2*(num2-num)+num
    else
      final_value = (rv_noise2+1)/2*(num2-num)+num
    end
  else
    num2 = num
    num = -num2
    if math.random(2) == 1 then
      final_value = (rv_noise+1)/2*(num2-num)+num
    else
      final_value = (rv_noise2+1)/2*(num2-num)+num
    end
  end
  
  
  return final_value
end





-- Shared muzzle/impact smoke helper. Part of the public API so gun packs (the
-- built-in real_register, battlefront_register, or any external mod) can reuse
-- the same smoke look from their on_fire callbacks.
function bestguns.a_smoke(user, def)
  local look_dir = user:get_look_dir()
  local pos = user:get_pos()
  pos.y = pos.y + 1.5
  def.minsmokes = def.minsmokes or 10
  def.max_smokes = def.max_smokes or 25

  if not def.acceleration then def.acceleration = {x=8, y=8, z=8} end
  for i=1, math.random(def.minsmokes,def.max_smokes) do
    core.add_particle({
      pos = vector.add(pos, vector.multiply(look_dir, 0.5)),
      velocity = user:get_velocity(),
      acceleration = {x=bestguns.r(def.acceleration.x), y=bestguns.r(def.acceleration.y), z=bestguns.r(def.acceleration.z)},
      expirationtime = math.random((def.expirationtime or 0.6)*10)/10,
      size = math.random(def.size or 8),
      texture = def.texture or "bestguns_smoke_"..math.random(3)..".png^[opacity:"..(def.base_opacity or 20).."^[contrast:0:"..math.random((def.smoke_min_brightness or -20), 0),
      glow = math.random(def.glow or 3)
    })
  end
end


local BULLETLOADSPEED = 1

-- Load components
local path = core.get_modpath("bestguns")
-- Resolve controls + playerphysics (reuse globals if present, else bundle them)
dofile(path .. "/compat.lua")
dofile(path .. "/entity.lua")





-- Helper: Update the Magazine item description
local function update_mag_desc(itemstack, gun_name)
    local def = bestguns.registered_guns[gun_name]
    if not def then return end
    
    local meta = itemstack:get_meta()
    local ammo = meta:get_int("ammo_count")
    local b_name = meta:get_string("bullet_name")
    local b_def = bestguns.registered_bullets[b_name]
    local mag_def = core.registered_items[itemstack:get_name()]
    local inv_image = mag_def.inventory_image
    

    local desc = def.description .. " " .. (def.mag_term or "Magazine") .. "\n"
    if ammo > 0 and b_def then
        desc = desc .. ammo .. "/" .. def.mag_capacity .. " x " .. (b_def.description or b_name)
    else
        desc = desc .. "Empty"
    end
    
    meta:set_string("description", desc)
    
    local loaded_texture = mag_def.loaded_texture or "bestguns_red.png"
    meta:set_string("wield_image", inv_image)
    inv_image = inv_image .. "^[lowpart:"..(ammo/def.mag_capacity*100)..":"..loaded_texture
    meta:set_string("inventory_image", inv_image)

end

-- Helper: Update the Gun item description and texture
local function update_gun_desc(itemstack, def)
    local meta = itemstack:get_meta()
    local has_mag = meta:get_int("has_mag") == 1
    local is_open = meta:get_int("is_open") == 1
    local ammo = meta:get_int("ammo_count")
    local inv_image = def.texture_nomag
    local wield_image
    

    local desc = def.description
    if has_mag then
      desc = desc .. "\n[" .. ammo .. "/" .. def.mag_capacity .. "]"
      inv_image = def.texture_mag
    elseif def.load_action == "direct" then
      desc = desc .. "\n[" .. ammo .. "/" .. def.mag_capacity .. "]"
      if is_open then
        wield_image = def.texture_open
        inv_image = wield_image.."^bestguns_open.png"
      end
    else
      desc = desc .. "\n[No Mag]"
    end
    meta:set_string("description", desc)
    local loaded_texture = def.loaded_texture or "bestguns_red.png"
    wield_image = wield_image or inv_image
    meta:set_string("wield_image", wield_image)
    inv_image = inv_image .. "^[lowpart:"..(ammo/def.mag_capacity*100)..":"..loaded_texture
    meta:set_string("inventory_image", inv_image)
    
    
end

-- Public helpers for external mods (loot generation, giving loaded guns, etc.)

-- Put a gun ItemStack into a loaded state. Magazine-fed guns get a magazine
-- inserted automatically. Returns the (modified) itemstack.
function bestguns.fill_gun(itemstack, ammo_count, bullet_name)
    local def = bestguns.registered_guns[itemstack:get_name()]
    if not def then return itemstack end

    local meta = itemstack:get_meta()
    meta:set_int("ammo_count", ammo_count)
    meta:set_string("bullet_name", bullet_name or def.default_bullet)
    meta:set_int("is_open", 0)
    if def.load_action == "magazine" then
        meta:set_int("has_mag", 1)
    end

    update_gun_desc(itemstack, def)
    return itemstack
end

-- Build a loaded magazine ItemStack for a magazine-fed gun.
function bestguns.make_mag(gun_name, ammo_count, bullet_name)
    local def = bestguns.registered_guns[gun_name]
    if not def or def.load_action ~= "magazine" then return ItemStack("") end

    local stack = ItemStack(gun_name .. "_mag")
    local meta = stack:get_meta()
    meta:set_int("ammo_count", ammo_count)
    meta:set_string("bullet_name", bullet_name or def.default_bullet)

    update_mag_desc(stack, gun_name)
    return stack
end

-- Deduct `count` rounds from a gun's currently-loaded ammo in one go (for actions
-- that spend more than one round at once, e.g. an alt-fire that burns a chunk of
-- the cell) and refresh its description/texture to match. Clamps at 0; callers
-- that need to know whether enough ammo was available should check
-- itemstack:get_meta():get_int("ammo_count") themselves before calling this,
-- same as the ammo_count field always required. Returns the new ammo count.
function bestguns.consume_ammo(itemstack, count)
    local def = bestguns.registered_guns[itemstack:get_name()]
    if not def then return 0 end

    local meta = itemstack:get_meta()
    local ammo = math.max(meta:get_int("ammo_count") - count, 0)
    meta:set_int("ammo_count", ammo)
    if ammo == 0 then meta:set_string("bullet_name", "") end

    update_gun_desc(itemstack, def)
    return ammo
end

function bestguns.can_fire(itemstack, user)
  local player_name = user:get_player_name()
  local gun_name = itemstack:get_name()
  local def = bestguns.registered_guns[gun_name]
  if not def then return nil end
  
  local meta = itemstack:get_meta()
  local ammo = meta:get_int("ammo_count")
  local is_open = meta:get_int("is_open") == 1

  -- Check if empty or no magazine
  if is_open or ammo <= 0 then
      bestguns.last_fire[player_name] = now
      return false, "empty_mag_or_empty"
  elseif ammo == 1 then
    return true, "click"
  end

  local bullet_name = meta:get_string("bullet_name")
  local b_def = bestguns.registered_bullets[bullet_name]
  if not b_def then return false, "no_bullet" end
  
  
  return true
end

-- Fire a loaded gun straight out of a dispenser (MineClone2 / Mineclonia), the
-- way a dispenser shoots a bow. There's no player pulling the trigger, so this
-- is a slimmed-down fire_gun: no ADS/recoil/spread-bloom (a dispenser has no
-- aim state), just spend one round, play the shot at the dispenser, and launch a
-- bullet along the dispenser's facing `dir` from `pos`. The bullet carries an
-- empty shooter name = an environmental shot with no kill attribution (the
-- bullet entity itself is the puncher). Always returns the (updated) gun stack
-- so the dispenser keeps it - never returns nil, which would let the dispenser
-- eject/consume the gun. Used by the `_on_dispense` hook on every gun tool.
function bestguns.fire_from_dispenser(itemstack, pos, dir)
    local def = bestguns.registered_guns[itemstack:get_name()]
    if not def then return itemstack end

    local meta = itemstack:get_meta()
    local ammo = meta:get_int("ammo_count")
    local is_open = meta:get_int("is_open") == 1

    -- Can't fire: broken open, or empty. Click the empty sound and leave the gun
    -- untouched in the dispenser.
    if is_open or ammo <= 0 then
        if def.sound_empty then
            core.sound_play(def.sound_empty, {pos = pos, max_hear_distance = 16}, true)
        end
        return itemstack
    end

    local bullet_name = meta:get_string("bullet_name")
    local b_def = bestguns.registered_bullets[bullet_name]
    if not b_def then return itemstack end

    -- Spend one round and refresh the gun's description/texture.
    ammo = ammo - 1
    meta:set_int("ammo_count", ammo)
    if ammo == 0 then meta:set_string("bullet_name", "") end
    update_gun_desc(itemstack, def)

    -- Shot audio at the dispenser.
    local snd = b_def.fire_sound or def.sound_fire
    if snd then
        core.sound_play(snd, {pitch = (math.random(100)-50)*0.002+1, pos = pos, gain = 3, max_hear_distance = 100}, true)
    end

    -- Launch the bullet down the dispenser's facing from just outside its mouth.
    local data = {
        velocity = vector.multiply(dir, b_def.speed or 100),
        shooter_name = "", -- environmental shot: no player, no attribution
        _item = bullet_name,
        _drops = b_def.drops,
        damage = math.floor((b_def.damage or 1) * (def.damage_mult or 1) * bestguns.damage_scale),
        texture = b_def.texture,
        size = b_def.size or 1,
    }
    bestguns.apply_range(data, def)
    local spawn = vector.add(pos, vector.multiply(dir, 0.6))
    core.add_entity(spawn, "bestguns:bullet", core.serialize(data))

    return itemstack
end

-- Main firing function (Supports Semi, Full, and Manual)
-- `charge_mult` (optional): damage/velocity scale for hold-to-charge guns (action ==
-- "charge"), 1 for a fully-charged shot. Ignored (treated as 1) by every other gun.
-- Internal: performs the actual shot (ammo, cooldown, recoil, bullet spawn).
-- The public bestguns.fire_gun wraps this to add the hip-fire wind-up below.
local function do_fire_gun(itemstack, user, charge_mult)
    local player_name = user:get_player_name()
    local gun_name = itemstack:get_name()
    local def = bestguns.registered_guns[gun_name]

    -- Dead men don't shoot. Bail while the player is down (HP 0), which stops any
    -- in-flight auto-fire/burst loop or queued shot from firing off after a kill.
    if user:get_hp() <= 0 then return nil end

    -- Remember the gun being fired so any bullet spawned during this shot (the
    -- default one below, or pellets a custom on_fire launches) can attribute its
    -- shot/hit to this gun. Set before on_fire runs so pellet spreads pick it up.
    bestguns.last_gun[player_name] = gun_name

    local can_fire, reason = bestguns.can_fire(itemstack, user)
    
    if reason == "click" then
      core.after(0.3, function()
        if def.sound_empty and user and user:get_pos() then
          core.sound_play(def.sound_empty, {pos = user:get_pos(), max_hear_distance = 16}, true)
        end
      end)
    elseif not can_fire then
      return
    end


    -- Handle Fire Rate Cooldown
    local now = core.get_us_time() / 1000000
    local last_fire = bestguns.last_fire[player_name] or 0
    if now - last_fire < def.fire_delay then return nil end

    -- First-shot accuracy: a burst starts pinpoint and blooms up to the gun's
    -- set `inaccuracy` over 0.3s of sustained fire. Pausing (>0.15s gap between
    -- shots) resets the burst, so the next shot is dead-on again. Semi/single
    -- guns naturally reset between shots; full-auto spray blooms as you hold.
    if now - last_fire > 0.15 then
        bestguns.burst_start[player_name] = now
    end
    local burst_start = bestguns.burst_start[player_name] or now
    local bloom = math.min((now - burst_start) / 0.3, 1)

    -- Respect external usage restrictions (e.g. CTF class limits)
    if not bestguns.can_use_gun(user, gun_name) then
        bestguns.last_fire[player_name] = now
        if def.sound_empty then
            core.sound_play(def.sound_empty, {pos = user:get_pos(), max_hear_distance = 16}, true)
        end
        return nil
    end

    
    -- Guns with no ADS at all, or that replace RMB with a custom alt-fire, never
    -- touch the scope/FOV kick on fire.
    if def.no_ads or def.on_altfire then
      -- no scope/kick
    elseif def.cancel_scope_on_fire then
      bestguns.scope(user)
    else
      if user:get_player_control().RMB then
        bestguns.scope(user, true, itemstack, true)
      else
        bestguns.scope(user, "kick", itemstack)
      end
      core.after((def.kick_time or 0.02), function()
        if user and user:get_pos() then
          if user:get_player_control().RMB then
            bestguns.scope(user, true, itemstack)
          else
            bestguns.scope(user)
          end
        end
      end)
    end

    local meta = itemstack:get_meta()
    local ammo = meta:get_int("ammo_count")
    local is_open = meta:get_int("is_open") == 1
    
    local bullet_name = meta:get_string("bullet_name")
    local b_def = bestguns.registered_bullets[bullet_name]

    -- Consume ammo
    ammo = ammo - 1
    meta:set_int("ammo_count", ammo)

    update_gun_desc(itemstack, def)
    bestguns.last_fire[player_name] = now

    -- Audio
    local snd = b_def.fire_sound or def.sound_fire
    if snd then
        core.sound_play(snd, {pitch = (math.random(100)-50)*0.002+1, pos = user:get_pos(), gain = 3, max_hear_distance = 100}, true)
    end

    -- Recoil
    local dir = user:get_look_dir()
    local recoil = b_def.recoil or 0
    if recoil > 0 then
        user:add_velocity(vector.multiply(dir, -recoil*0.6))
    end

    -- Spawn Bullet Entity
    local eye_height = user:get_properties().eye_height or 1.625
    local pos = vector.add(user:get_pos(), {x=0, y=eye_height, z=0})
    local eff_inaccuracy = def.inaccuracy * bloom
    local speed_mult = (def.charge_scale_velocity and charge_mult) or 1
    local bullet_vel = vector.multiply(vector.offset(dir, bestguns.r(100)/5000*eff_inaccuracy, bestguns.r(100)/5000*eff_inaccuracy, bestguns.r(100)/5000*eff_inaccuracy), (b_def.speed or 100) * speed_mult)

    if def.on_fire then
      if def.on_fire(itemstack, user, obj) then
        if ammo == 0 then
            meta:set_string("bullet_name", "")
        end
        return itemstack
      end
    end
    
    if ammo == 0 then
        meta:set_string("bullet_name", "")
    end
    
    local data = {
        velocity = bullet_vel,
        shooter_name = player_name,
        _item = bullet_name,
        _gun = gun_name,
        _drops = b_def.drops,
        damage = math.floor((b_def.damage or 1) * (def.damage_mult or 1) * bestguns.damage_scale * (charge_mult or 1)),
        texture = b_def.texture,
        size = b_def.size or 1
    }
    bestguns.apply_range(data, def)
    local obj = core.add_entity(pos, "bestguns:bullet", core.serialize(data))

    -- Custom on_fire callback

    return itemstack
end

-- Public fire entry point. Adds a one-time "wind-up": when you hip-fire (not
-- aiming down the sights), the FIRST shot of a fresh trigger pull is delayed by
-- the gun's wind-up time; every shot after that in the same pull fires at the
-- gun's normal rate. Aiming (RMB on an ADS-capable gun) skips the wind-up
-- entirely, so aiming rewards you with an instant trigger.
--
-- Wind-up length is per-gun via `def.hipfire_windup`, defaulting by action:
-- full-auto guns get HIPFIRE_WINDUP, while semi/single-action guns fire
-- instantly (0). A resolved value of 0 means no delay at all.
--
-- A "fresh" pull = the trigger has been at rest (no shot) for more than 0.15s,
-- the same gap the spread-bloom reset uses. Pass `skip_windup` to fire
-- immediately regardless (used by burst/charge, which are already deliberate).
local HIPFIRE_WINDUP = 0.13
local function gun_windup(def)
    if def.hipfire_windup ~= nil then return def.hipfire_windup end
    if def.action == "full" then return HIPFIRE_WINDUP end
    return 0 -- semi/single-action guns fire instantly
end
function bestguns.fire_gun(itemstack, user, charge_mult, skip_windup)
    local name = user:get_player_name()
    local def = bestguns.registered_guns[itemstack:get_name()]
    if not def then return nil end

    -- A shot is already winding up for this player: don't stack another.
    if bestguns.windup[name] then return nil end

    local windup = gun_windup(def)
    if not skip_windup and windup > 0 then
        local ctrl = user:get_player_control()
        local aiming = ctrl.RMB and not def.no_ads and not def.on_altfire
        local now = core.get_us_time() / 1000000
        local last_fire = bestguns.last_fire[name] or 0

        if not aiming and (now - last_fire) > 0.15 then
            -- Fresh hip-fire pull: delay only this first shot, then it's normal.
            bestguns.windup[name] = true
            core.after(windup, function()
                bestguns.windup[name] = nil
                local player = core.get_player_by_name(name)
                if not player then return end
                local wielded = player:get_wielded_item()
                if wielded:get_name() ~= itemstack:get_name() then return end
                local stack = do_fire_gun(wielded, player, charge_mult)
                if stack then player:set_wielded_item(stack) end
            end)
            return itemstack
        end
    end

    return do_fire_gun(itemstack, user, charge_mult)
end

-- Burst fire: one trigger pull sends a fixed number of rounds (default 3) spaced
-- by `burst_delay`, then locks out re-triggering until the burst finishes plus a
-- short `burst_cooldown`. Holding the trigger simply repeats bursts at that
-- cadence. Each round runs through fire_gun, so ammo, spread bloom, recoil, and
-- sounds all behave exactly like a normal shot.
function bestguns.fire_burst(itemstack, user)
    local name = user:get_player_name()
    local gun_name = itemstack:get_name()
    local def = bestguns.registered_guns[gun_name]

    if bestguns.bursting[name] then return nil end

    -- Fire the first round immediately; bail (no lock) if it couldn't fire
    -- (empty mag, cooldown, action restriction, etc.). Burst rounds skip the
    -- hip-fire wind-up: the burst's own `burst_delay` spacing already sets the
    -- cadence, and a delayed first round would collide with the scheduled ones.
    local first = bestguns.fire_gun(itemstack, user, nil, true)
    if not first then return nil end

    local shots = def.burst_count or 3
    local interval = def.burst_delay or 0.07
    bestguns.bursting[name] = true

    local function shoot(i)
        if i > shots then
            core.after(def.burst_cooldown or 0.15, function()
                bestguns.bursting[name] = nil
            end)
            return
        end
        local player = core.get_player_by_name(name)
        if not player then bestguns.bursting[name] = nil return end
        local wielded = player:get_wielded_item()
        if wielded:get_name() ~= gun_name then bestguns.bursting[name] = nil return end
        local new_stack = bestguns.fire_gun(wielded, player, nil, true)
        if new_stack then player:set_wielded_item(new_stack) end
        core.after(interval, function() shoot(i + 1) end)
    end
    core.after(interval, function() shoot(2) end)

    return first
end

-- Distance-falloff helper. Given a bullet's serialized spawn `data` (already
-- holding the scaled max `damage`) and the firing gun's `def`, stamp the range
-- falloff fields onto `data` so the bullet entity scales its damage down with
-- distance based on the gun's `gun_range`. Guns with gun_range <= 0 are left
-- untouched (constant damage). Shared by fire_gun and any custom on_fire that
-- spawns bullets itself (e.g. shotguns).
function bestguns.apply_range(data, def)
    local gr = def and def.gun_range or 1
    if gr <= 0 then return end
    data.falloff_start = bestguns.range_full * gr
    data.falloff_end   = bestguns.range_zero * gr
    data.damage_min    = math.max(math.floor((data.damage or 0) * bestguns.range_min_damage), 1)
end

-- Bullet Registration
function bestguns.register_bullet(name, def)
    bestguns.registered_bullets[name] = def
    local groups = {bullet = 1}
    if def.not_in_creative_inventory then
        groups.not_in_creative_inventory = 1
    end
    -- Leading ":" overrides the modname-prefix check, so gun packs loaded as
    -- their own mods (bestguns_guns, battlefront_blasters, ...) may register
    -- "bestguns:"-namespaced items through this API.
    core.register_craftitem(":" .. name, {
        description = def.description,
        inventory_image = def.inventory_image,
        groups = groups
    })
end



local reload_timer = {}
bestguns.controls.register_on_press(function(player, key)
  local ctrl = player:get_player_control()
  local wielditem = player:get_wielded_item()
  if core.get_item_group(wielditem:get_name(), "bestguns_gun") == 0 then return end
  local def = bestguns.registered_guns[wielditem:get_name()]
  if key == "RMB" and not ctrl.LMB and not ctrl.sneak then
    -- A gun with a custom on_altfire owns RMB entirely; no_ads means RMB does
    -- nothing at all; otherwise fall back to the default ADS/scope behaviour.
    if def and def.on_altfire then
      def.on_altfire(wielditem, player, "press")
    elseif not (def and def.no_ads) then
      bestguns.scope(player, true, wielditem)
    end
  end
end)
bestguns.controls.register_on_release(function(player, key, length)
  if key == "RMB" then
    local wielditem = player:get_wielded_item()
    local def = bestguns.registered_guns[wielditem:get_name()]
    if def and def.on_altfire then
      def.on_altfire(wielditem, player, "release")
    elseif not (def and def.no_ads) then
      bestguns.scope(player)
    end
  end
  if key ~= "RMB" then return end
  reload_timer[player:get_player_name()] = 0
  bestguns.playerphysics.remove_physics_factor(player, "speed", "bestguns:loading_speed")
end)

-- Hold-to-charge guns (action == "charge"): holding LMB ramps a charge value from
-- 0 to 1 over `charge_time` seconds; releasing fires with damage (and optionally
-- velocity) scaled between `charge_min_mult` and 1. A HUD percentage under the
-- crosshair keeps the player informed of the current charge.
local function bestguns_charge_def(player)
  local wielditem = player:get_wielded_item()
  local def = bestguns.registered_guns[wielditem:get_name()]
  if def and def.action == "charge" then return def, wielditem end
  return nil
end

local function bestguns_remove_charge_hud(name)
  local hud_id = bestguns.charge_hud[name]
  if hud_id then
    local player = core.get_player_by_name(name)
    if player then player:hud_remove(hud_id) end
    bestguns.charge_hud[name] = nil
  end
end

bestguns.controls.register_on_press(function(player, key)
  if key ~= "LMB" then return end
  local def = bestguns_charge_def(player)
  if not def then return end
  local name = player:get_player_name()
  bestguns.charge_start[name] = core.get_us_time() / 1000000
  bestguns_remove_charge_hud(name)
  bestguns.charge_hud[name] = player:hud_add({
    hud_elem_type = "text",
    position = {x = 0.5, y = 0.5},
    alignment = {x = 0, y = 1},
    offset = {x = 0, y = 30},
    text = "0%",
    number = 0xFFFFFF,
    z_index = 100,
  })
end)

bestguns.controls.register_on_hold(function(player, key, length)
  if key ~= "LMB" then return end
  local name = player:get_player_name()
  local start = bestguns.charge_start[name]
  local hud_id = bestguns.charge_hud[name]
  if not start or not hud_id then return end
  local def = bestguns_charge_def(player)
  if not def then return end
  local frac = math.min((core.get_us_time() / 1000000 - start) / (def.charge_time or 1), 1)
  player:hud_change(hud_id, "text", math.floor(frac * 100) .. "%")
end)

bestguns.controls.register_on_release(function(player, key, length)
  if key ~= "LMB" then return end
  local name = player:get_player_name()
  local start = bestguns.charge_start[name]
  bestguns.charge_start[name] = nil
  bestguns_remove_charge_hud(name)
  if not start then return end

  local def, wielditem = bestguns_charge_def(player)
  if not def then return end

  local frac = math.min((core.get_us_time() / 1000000 - start) / (def.charge_time or 1), 1)
  if frac < (def.charge_min or 0) then
    if def.sound_empty then
      core.sound_play(def.sound_empty, {pos = player:get_pos(), max_hear_distance = 16}, true)
    end
    return
  end

  local min_mult = def.charge_min_mult or 0.35
  local charge_mult = min_mult + (1 - min_mult) * frac
  -- Charge guns fire on release after a deliberate hold; skip the hip-fire
  -- wind-up so the shot goes off exactly when the player lets go.
  local new_stack = bestguns.fire_gun(wielditem, player, charge_mult, true)
  if new_stack then player:set_wielded_item(new_stack) end
end)
bestguns.controls.register_on_hold(function(user, key, length)
  if key ~= "RMB" then return end
  local itemstack = user:get_wielded_item()
  local stackname = itemstack:get_name() or "ignore"

  local altfire_def = bestguns.registered_guns[stackname:gsub("_mag$", "")]
  if altfire_def and altfire_def.on_altfire then
    altfire_def.on_altfire(itemstack, user, "hold")
  end

  local direct = core.get_item_group(stackname, "direct_loading") ~= 0
  if core.get_item_group(stackname, "gun_magazine") == 0 and not direct then return end
    
  local name = user:get_player_name()
  reload_timer[name] = (reload_timer[name] or length)
  
  
  local gun_name = stackname:gsub("_mag", "")
  
  local def = bestguns.registered_guns[gun_name]
  
  local loadspeed = def.load_speed or BULLETLOADSPEED
  
  
  
  local meta = itemstack:get_meta()
  local inv = user:get_inventory()
  
  if direct and meta:get_int("is_open") ~= 1 then return end
  
  local ammo_count = meta:get_int("ammo_count")
  if ammo_count < def.mag_capacity then
    bestguns.playerphysics.add_physics_factor(user, "speed", "bestguns:loading_speed", 0.3)
    
    if length - reload_timer[name] < loadspeed then return end
    reload_timer[name] = length -- keep loading the next bullet each loadspeed interval while RMB stays held
    
    local current_bullet = meta:get_string("bullet_name")
    local bullets_needed = 1
    local reloaded = false
    
    
    for i = 1, inv:get_size("main") do
      if bullets_needed <= 0 then break end
      local stack = inv:get_stack("main", i)
      local s_name = stack:get_name()
      local b_def = bestguns.registered_bullets[s_name]
      
      -- Must match gun caliber and not mix bullet types
      if b_def and b_def.caliber == def.caliber then
        if current_bullet == "" or current_bullet == s_name then
          current_bullet = s_name
          local to_take = math.min(stack:get_count(), bullets_needed)
          stack:take_item(to_take)
          inv:set_stack("main", i, stack)
          ammo_count = ammo_count + to_take
          bullets_needed = bullets_needed - to_take
          reloaded = true
        end
      end
    end
    
    local creative = core.is_creative_enabled(name)
    if creative then
      current_bullet = def.default_bullet
      ammo_count = def.mag_capacity
      reloaded = true
    end
    
    if reloaded then
      meta:set_int("ammo_count", ammo_count)
      meta:set_string("bullet_name", current_bullet)
      if direct then
        update_gun_desc(itemstack, def)
      else
        update_mag_desc(itemstack, gun_name)
      end
      
      if def.sound_load_mag then
        core.sound_play(def.sound_load_mag, {pos = user:get_pos(), max_hear_distance = 16}, true)
      end
      if def.load_mag then def.load_mag(itemstack, user) end
    end
  end
  user:set_wielded_item(itemstack)

end)


-- Gun Registration
function bestguns.register_gun(name, def)
  
    
    def.inaccuracy = def.inaccuracy or 0
    def.zoom = def.zoom or 0.9
    def.scope_size = def.scope_size or 1
    
    def.load_action = def.load_action or "magazine"
    local ma = def.load_action == "magazine"
    
  
    bestguns.registered_guns[name] = def
    
    local mag_name = name .. "_mag"
    -- Create specific magazine for this gun
    local rightclick_function = function(itemstack, user, pointed_thing) end
    
    if ma then
      core.register_craftitem(":" .. mag_name, {
          description = def.description .. " " .. (def.mag_term or "Magazine") .. "\nEmpty",
          inventory_image = def.texture_mag_item or def.texture_mag,
          wield_image = def.texture_mag_item or def.texture_mag,
          groups = {gun_magazine = 1},
          stack_max = 1,
          range = 0,
      })

      rightclick_function = function(itemstack, user, pointed_thing)
        local meta = itemstack:get_meta()
        local has_mag = meta:get_int("has_mag") == 1
        local inv = user:get_inventory()
        
        -- Shift + Right Click = Eject Magazine
        if user:get_player_control().sneak then
          if has_mag then
            local mag_stack = ItemStack(mag_name)
            local mag_meta = mag_stack:get_meta()
            mag_meta:set_int("ammo_count", meta:get_int("ammo_count"))
            mag_meta:set_string("bullet_name", meta:get_string("bullet_name"))
            update_mag_desc(mag_stack, name)
            
            if inv:room_for_item("main", mag_stack) then
              inv:add_item("main", mag_stack)
            else
              core.item_drop(mag_stack, user, user:get_pos())
            end
            
            meta:set_int("has_mag", 0)
            meta:set_int("ammo_count", 0)
            meta:set_string("bullet_name", "")
            update_gun_desc(itemstack, def)
            
            if def.mag_remove then
              core.sound_play(def.mag_remove, {pos = user:get_pos(), max_hear_distance = 16}, true)
            end
          end
          -- Right Click = Insert Magazine OR Top-off with loose bullets
          if not has_mag then
            local best_mag = {i=nil, stack=nil, size=-1}
            -- Insert a magazine from inventory
            for i = 1, inv:get_size("main") do
              local stack = inv:get_stack("main", i)
              if stack:get_name() == mag_name then
                local stack_meta = stack:get_meta()
                local mag_ammo_count = stack_meta:get_int("ammo_count") or 0
                if mag_ammo_count > best_mag.size then
                  best_mag = {i=i, stack=stack, size=mag_ammo_count}
                end
              end
            end
            if best_mag.size > -1 then
              local stack_meta = best_mag.stack:get_meta()
              meta:set_int("has_mag", 1)
              meta:set_int("ammo_count", stack_meta:get_int("ammo_count"))
              meta:set_string("bullet_name", stack_meta:get_string("bullet_name"))
              update_gun_desc(itemstack, def)
              
              best_mag.stack:take_item(1)
              inv:set_stack("main", best_mag.i, best_mag.stack)
              
              if def.mag_insert then
                core.sound_play(def.mag_insert, {pos = user:get_pos(), max_hear_distance = 16}, true)
              end
              if def.on_reload then def.on_reload(itemstack, user) end
            end
          end
        end
        return itemstack
      end
    elseif def.load_action == "direct" then
      rightclick_function = function(itemstack, user, pointed_thing)
        local meta = itemstack:get_meta()
        local inv = user:get_inventory()
        local is_open = meta:get_int("is_open") == 1
        
        if user:get_player_control().sneak then
          if not is_open then
            if def.sound_open then
              core.sound_play(def.sound_open, {pos = user:get_pos(), max_hear_distance = 16}, true)
            end
            meta:set_int("is_open", 1)
            reload_timer[user:get_player_name()] = 100
          else
            if def.sound_close then
              core.sound_play(def.sound_close, {pos = user:get_pos(), max_hear_distance = 16}, true)
            end
            meta:set_int("is_open", 0)
          end
        end
        update_gun_desc(itemstack, def)
        return itemstack
      end
    end
    
    local groups = {bestguns_gun = 1}
    if def.load_action == "direct" then
      groups.direct_loading = 1
    end
    
    -- Create the gun tool (":" overrides the modname-prefix check so packs in
    -- their own mods can register "bestguns:"-namespaced tools via this API).
    core.register_tool(":" .. name, {
        description = def.description,
        inventory_image = def.texture_nomag,
        wield_image = def.texture_nomag,
        wield_scale = def.wield_scale or vector.new(1,1,1),
        groups = groups,
        
        -- Left Click: Fire
        on_use = function(itemstack, user, pointed_thing)
            if def.action == "burst" then
                return bestguns.fire_burst(itemstack, user) or itemstack
            elseif def.action == "charge" then
                -- Hold-to-charge guns fire on LMB release, driven by the
                -- controls.register_on_press/on_hold/on_release hooks below.
                return itemstack
            elseif def.action ~= "full" then
                local new_stack = bestguns.fire_gun(itemstack, user)
                return new_stack or itemstack
            end
            return itemstack
        end,
        on_place = rightclick_function,
        on_secondary_use = rightclick_function,
        range = 0,

        -- MineClone2 / Mineclonia: let a dispenser fire the gun like it fires a
        -- bow. This field is inert in games without mcl_dispensers, so it's safe
        -- to always define. `dropdir` is the dispenser's unit facing.
        _on_dispense = function(stack, dispenserpos, droppos, dropnode, dropdir)
            return bestguns.fire_from_dispenser(stack, dispenserpos, dropdir)
        end,
    })
end

core.register_globalstep(function(dtime)
  noise_seeded = noise_seeded + dtime*1000
  for _, player in ipairs(core.get_connected_players()) do

    local name = player:get_player_name()

    if bestguns[name] and bestguns[name].hud_removing then
      local oldopacity = math.floor(bestguns[name].hud_removing * 1000)
      bestguns[name].hud_removing = bestguns[name].hud_removing - dtime
      local oldhud = bestguns[name].hud
      for i,hudid in pairs(oldhud) do
        local newopacity = math.floor(bestguns[name].hud_removing * 1000)
        local basetext = player:hud_get(hudid).text
        if not string.find(basetext, "opacity") then
          basetext = basetext .. "^[opacity:"..newopacity
        end
        basetext = basetext:gsub("acity:"..oldopacity, "acity:"..newopacity)
        player:hud_change(hudid, "text", basetext)
        if newopacity <= 0 then
          for i,hudid2 in pairs(oldhud) do
            player:hud_remove(hudid2)
          end
          bestguns[name].hud = nil
          bestguns[name].hud_removing = nil
          break
        end
      end
    end


    local control = player:get_player_control()
    -- Left mouse button down
    if control.LMB or control.dig then
      local wielded = player:get_wielded_item()
      local gun_name = wielded:get_name()
      local def = bestguns.registered_guns[gun_name]
      
      if def and def.action == "full" then
        local new_stack = bestguns.fire_gun(wielded, player)
        if new_stack then
            player:set_wielded_item(new_stack)
        end
      end
    end
  end
end)


dofile(path .. "/guninfo.lua")

-- The actual weapon rosters now live in separate mods that depend on bestguns:
--   * bestguns_guns        - realistic firearm set (was real_register.lua)
--   * battlefront_blasters - Star Wars Battlefront blasters (was battlefront_register.lua)
-- bestguns itself is now purely the API + shared effects + /guninfo.
