-- Momentary "x" hitmarker shown over the crosshair when the shooter lands a
-- hit: white normally, yellow on a headshot. Repeated hits (full-auto) just
-- refresh the same element and reset its fade timer instead of stacking.
bestguns.hitmarkers = bestguns.hitmarkers or {} -- [pname] = {id = hudid, job = <after handle>}

function bestguns.show_hitmarker(player, headshot)
  if not player or not player:is_player() then return end
  local name = player:get_player_name()
  local color = headshot and 0xFFFF00 or 0xFFFFFF
  local hm = bestguns.hitmarkers[name]

  if hm and hm.id then
    player:hud_change(hm.id, "number", color)
  else
    hm = {}
    hm.id = player:hud_add({
      hud_elem_type = "text",
      position = {x = 0.5, y = 0.5},
      alignment = {x = 0, y = 0},
      offset = {x = 0, y = 0},
      text = "x",
      number = color,
      z_index = 100,
    })
    bestguns.hitmarkers[name] = hm
  end

  if hm.job then hm.job:cancel() end
  hm.job = core.after(0.18, function()
    local p = core.get_player_by_name(name)
    local cur = bestguns.hitmarkers[name]
    if cur and cur.id and p then
      p:hud_remove(cur.id)
    end
    bestguns.hitmarkers[name] = nil
  end)
end

core.register_on_leaveplayer(function(player)
  bestguns.hitmarkers[player:get_player_name()] = nil
end)

-- Splash-damage explosion for an explosive bullet (bullet def sets
-- `splash_radius`), e.g. a grenade-style secondary fire. Every object within
-- `radius` of `pos` takes damage falling off linearly from `self.damage` at the
-- centre to 0 at the edge - the shooter is NOT excluded, so standing too close
-- to your own blast can hurt you, same as the real weapon this is modelled on.
function bestguns.explode(self, pos)
  local radius = self._splash_radius or 0
  if radius <= 0 then return end

  local shooter = self.shooter_name and core.get_player_by_name(self.shooter_name)
  local puncher = (shooter and shooter:is_valid()) and shooter or self.object

  for _, obj in ipairs(core.get_objects_inside_radius(pos, radius)) do
    if obj:is_valid() then
      local opos = obj:get_pos()
      local dist = vector.distance(pos, opos)
      local dmg = math.max(math.floor(self.damage * (1 - dist / radius)), 0)
      if dmg > 0 then
        local dir = dist > 0.05 and vector.direction(pos, opos) or vector.new(0, 1, 0)
        obj:punch(puncher, 1.0, {
          full_punch_interval = 1.0,
          damage_groups = {fleshy = dmg, ranged = 1, splash = 1}
        }, dir)
      end
    end
  end

  -- Explosion visuals: a bright flash burst plus a lingering smoke cloud, built
  -- from the pack's existing shared textures (no new art needed).
  for _ = 1, math.random(8, 14) do
    core.add_particle({
      pos = pos,
      velocity = {x = bestguns.r(8), y = bestguns.r(8), z = bestguns.r(8)},
      expirationtime = 0.15,
      size = math.random(14, 22),
      texture = "bestguns_muzzle_flash.png^[opacity:" .. math.random(50, 90),
      glow = 14,
    })
  end
  for _ = 1, math.random(14, 22) do
    core.add_particle({
      pos = vector.offset(pos, bestguns.r(0.6), bestguns.r(0.4), bestguns.r(0.6)),
      velocity = {x = bestguns.r(1), y = math.random(1, 3), z = bestguns.r(1)},
      acceleration = {x = 0, y = 1, z = 0},
      expirationtime = math.random(6, 14) / 10,
      size = math.random(10, 22),
      texture = "bestguns_smoke_" .. math.random(3) .. ".png^[opacity:" .. math.random(30, 70),
      glow = math.random(3, 8),
    })
  end

  if self._impact_sound then
    core.sound_play(self._impact_sound, {pos = pos, gain = 1.2, max_hear_distance = 60}, true)
  end
end

core.register_entity("bestguns:bullet", {
    initial_properties = {
        physical = false,
        collide_with_objects = false,
        pointable = false,
        visual = "sprite",
        textures = {"blank.png"}, -- Overwritten on_activate
    },
    
    on_activate = function(self, staticdata)
      
      -- Keep bullet from dying to random entity damage
      self.object:set_armor_groups({immortal = 1})
      
      -- Load bullet properties
      local data = core.deserialize(staticdata) or {}
      self.velocity = data.velocity or {x=0, y=0, z=0}
      self.shooter_name = data.shooter_name
      self.damage = data.damage or 0
      self._item = data._item
      self._drops = data._drops or data._item

      local b_def = self._item and bestguns.registered_bullets[self._item]

      -- Distance-based damage falloff (Star Wars Battlefront style). A bullet def
      -- may declare `damage_min`, `falloff_start` and `falloff_end` (metres). The
      -- serialized `damage` is the already-scaled MAX; we derive the scaled MIN
      -- from the same ratio so gun `damage_mult`/`damage_scale` are respected.
      -- Bullets without these fields keep a constant damage (default behaviour).
      self._dmg_max = self.damage
      self._dmg_min = self.damage
      if b_def and b_def.damage_min and b_def.damage and b_def.damage > 0
         and b_def.falloff_start and b_def.falloff_end then
        local scale = self.damage / b_def.damage
        self._dmg_min = math.floor(b_def.damage_min * scale)
        self._falloff_start = b_def.falloff_start
        self._falloff_end = b_def.falloff_end
      end
      self.start_pos = self.object:get_pos()

      -- Optional per-bullet gravity (m/s^2), so a slugthrower-style round can arc
      -- and drop instead of flying arrow-straight like the default energy bolt.
      self._gravity = b_def and b_def.gravity

      -- Per-bullet override of the headshot hit-zone damage multiplier (default
      -- matches the flat 1.8x every bullet used before this was overridable).
      self._headshot_mult = (b_def and b_def.headshot_mult) or 1.8

      -- Explosive/splash bullets (e.g. a grenade-style secondary fire): on its
      -- first impact (object or walkable node) the bullet detonates instead of
      -- doing a single-target hit, damaging everyone within `splash_radius`
      -- (falling off linearly to 0 at the edge) - including the shooter, who can
      -- catch their own blast at close range. See bestguns.explode() below.
      self._splash_radius = b_def and b_def.splash_radius
      self._impact_sound = b_def and b_def.impact_sound

      -- Visual: a bullet def may render as a MESH (e.g. a glowing blaster bolt)
      -- instead of the default flat sprite. Mesh bolts auto-orient along their
      -- flight direction. Any bolt (sprite or mesh) may also set `glow`.
      if b_def and b_def.visual == "mesh" and b_def.mesh then
        local s = data.size or 1
        self.object:set_properties({
          visual = "mesh",
          mesh = b_def.mesh,
          textures = b_def.mesh_textures or {data.texture or "blank.png"},
          visual_size = {x = s, y = s, z = s},
          glow = b_def.glow or 14,
          backface_culling = false,
        })
        local v = self.velocity
        if v and (v.x ~= 0 or v.y ~= 0 or v.z ~= 0) then
          local dir = vector.normalize(v)
          local yaw = math.atan2(-dir.x, dir.z)
          local pitch = math.asin(math.max(-1, math.min(1, dir.y)))
          self.object:set_rotation({x = pitch, y = yaw, z = 0})
        end
      elseif data.texture then
          local s = data.size or 1
          local props = {
              textures = {data.texture},
              visual_size = {x = s, y = s}
          }
          if b_def and b_def.glow then props.glow = b_def.glow end
          self.object:set_properties(props)
      end

      self.timer = 0
      
      
      if self._item and bestguns.registered_bullets[self._item].on_activate then
        return bestguns.registered_bullets[self._item].on_activate(self, dtime, moveresult)
      end
    end,
    
    on_step = function(self, dtime, moveresult)
        self.timer = self.timer + dtime
        if self.timer > 5.0 then -- Timeout safety fallback
            self.object:remove()
            return
        end
        
        if self._item and bestguns.registered_bullets[self._item].on_step then
          if bestguns.registered_bullets[self._item].on_step(self, dtime, moveresult) then return end
        end

        local pos = self.object:get_pos()

        -- Apply distance-based damage falloff (see on_activate). Damage ramps
        -- linearly from max (at/under falloff_start) down to min (at/over
        -- falloff_end) based on how far the bolt has travelled from its origin.
        if self._falloff_start and self._falloff_end and self.start_pos then
          local dist = vector.distance(self.start_pos, pos)
          local f
          if dist <= self._falloff_start then
            f = 0
          elseif dist >= self._falloff_end then
            f = 1
          else
            f = (dist - self._falloff_start) / (self._falloff_end - self._falloff_start)
          end
          self.damage = math.floor(self._dmg_max + (self._dmg_min - self._dmg_max) * f)
        end

        if self._gravity then
          self.velocity.y = self.velocity.y - self._gravity * dtime
        end

        local drag = 0.001

        local in_node = core.get_node(pos)
        local in_def = core.registered_nodes[in_node.name] or {}
        if in_def.liquidtype ~= "none" then
          drag = 0.4
        end
        
        self.velocity = vector.multiply(self.velocity, 1-drag)
        if vector.length(self.velocity) < 1 and self._item then
          core.add_item(pos, ItemStack(self._drops))
          self.object:remove()
          return
        end
        
        --self.object:set_velocity(self.velocity)

        local next_pos = vector.add(pos, vector.multiply(self.velocity, dtime))
        if not self.shooter_name then return end
        local shooter = core.get_player_by_name(self.shooter_name)

        -- Execute Raycast for precise high-speed hit detection
        local ray = core.raycast(pos, next_pos, true, false)
        for pointed_thing in ray do
            if self._splash_radius then
                local impact
                if pointed_thing.type == "object" and pointed_thing.ref and pointed_thing.ref:is_valid() then
                    impact = pointed_thing.intersection_point
                elseif pointed_thing.type == "node" then
                    local node = core.get_node(pointed_thing.under)
                    local ndef = core.registered_nodes[node.name]
                    if ndef and ndef.walkable then
                        impact = pointed_thing.intersection_point
                    end
                end
                if impact then
                    bestguns.explode(self, impact)
                    self.object:remove()
                    return
                end
            elseif pointed_thing.type == "object" then
                local obj = pointed_thing.ref
                -- Prevent the shooter from hitting themselves
                if obj and obj:is_valid() and obj ~= shooter then
                    -- Credit the shooting player so games (e.g. CTF) can attribute
                    -- kills/assists, and tag the hit as ranged damage.
                    local puncher = (shooter and shooter:is_valid()) and shooter or self.object

                    -- Hit-location scaling: where on the target's collision box the
                    -- shot landed decides the damage via a vertical zone
                    -- (head/torso/legs). Works for players and bot luaentities alike
                    -- (both expose a collisionbox).
                    local dmg = self.damage
                    local headshot = false
                    local props = obj:get_properties()
                    local cbox = props and props.collisionbox
                    local ip = pointed_thing.intersection_point
                    if cbox and ip then
                        local opos = obj:get_pos()

                        -- Vertical zone: fraction up the box, 0 = feet, 1 = top.
                        local box_h = math.max(cbox[5] - cbox[2], 0.01)
                        local rel = ((ip.y - opos.y) - cbox[2]) / box_h
                        local zone
                        if rel >= 0.82 then
                            zone = self._headshot_mult -- head (per-bullet override, default 1.8)
                            headshot = true
                        elseif rel >= 0.40 then
                            zone = 1.0      -- torso
                        else
                            zone = 0.55     -- legs
                        end

                        dmg = math.max(math.floor(self.damage * zone), 1)
                    end

                    -- Tag headshots so games (e.g. CTF) can show them in the kill feed.
                    local damage_groups = {fleshy = dmg, ranged = 1}
                    if headshot then damage_groups.headshot = 1 end

                    obj:punch(puncher, 1.0, {
                        full_punch_interval = 1.0,
                        damage_groups = damage_groups
                    }, self.velocity)

                    -- Hit feedback to the shooter: a momentary "x" hitmarker
                    -- (yellow on a headshot) plus a sound cue.
                    local shooter_player = self.shooter_name and core.get_player_by_name(self.shooter_name)
                    if shooter_player then
                        local snd = headshot and bestguns.headshot_sound or bestguns.hit_sound
                        if snd then
                            core.sound_play(snd, {to_player = self.shooter_name, gain = 1.0}, true)
                        end
                        bestguns.show_hitmarker(shooter_player, headshot)
                    end

                    self.object:remove()
                    return
                end
            elseif pointed_thing.type == "node" then
                local node = core.get_node(pointed_thing.under)
                local def = core.registered_nodes[node.name]
                if def and def.walkable then
                  

                  local lp = vector.add(pointed_thing.intersection_point, vector.multiply(self.velocity, -0.0001))
                  for i=1, math.random(1,self.damage*7) do
                    core.add_particle({ -- node_particles
                      pos = lp,
                      velocity = vector.offset(vector.multiply(self.velocity,0.02), bestguns.r(4), bestguns.r(4), bestguns.r(4)),
                      acceleration = {x=0, y=-8.91, z=0},
                      expirationtime = 1,
                      collisiondetection = true,
                      size = math.random(10)/10,
                      node = node
                    })
                  end
                  for i=1, math.random(3,6) do
                    core.add_particle({ -- smoke fast
                      pos = lp,
                      velocity = vector.zero,
                      acceleration = {x=bestguns.r(3), y=bestguns.r(3), z=bestguns.r(3)},
                      expirationtime = math.random(20)/10,
                      size = math.random(10),
                      texture = "bestguns_smoke_"..math.random(3)..".png^[opacity:20",
                      glow = math.random(5)
                    })
                    core.add_particle({ -- smoke stays around
                      pos = vector.offset(lp, bestguns.r(10)/10, bestguns.r(10)/10, bestguns.r(10)/10),
                      velocity = vector.zero,
                      acceleration = {x=0, y=math.random(20)/30, z=0},
                      expirationtime = math.random(10),
                      size = math.random(20),
                      texture = "bestguns_smoke_"..math.random(3)..".png^[opacity:10",
                      glow = math.random(5)
                    })
                    
                    
                  end
                  
                  function get_face_vector(pos, intersection_point)
                    local diff = vector.subtract(intersection_point, pos)
                    local abs_x, abs_y, abs_z = math.abs(diff.x), math.abs(diff.y), math.abs(diff.z)
                    
                    if abs_x > abs_y and abs_x > abs_z then
                        return {x = diff.x > 0 and 1 or -1, y = 0, z = 0}
                    elseif abs_y > abs_z then
                        return {x = 0, y = diff.y > 0 and 1 or -1, z = 0}
                    else
                        return {x = 0, y = 0, z = diff.z > 0 and 1 or -1}
                    end
                  end
                  
                  local facedir = get_face_vector(pointed_thing.under, pointed_thing.intersection_point)
                  local finaldir = vector.zero()
                  
                  for v,val in pairs(facedir) do
                    if val > 0 or val < 0 then
                      finaldir[v] = 0
                    elseif val == 0 then
                      finaldir[v] = 1
                    end
                  end
                  
                  for i=1, math.random(30) do
                    local acc, vel
                    if math.random(6) == 1 then
                      vel = vector.new(bestguns.r(0.6),bestguns.r(0.2),bestguns.r(0.6))
                      acc = vector.new(0,-9,0)
                    end
                    
                    core.add_particle({ -- node_particles
                      pos = vector.add(
                        lp,
                        vector.multiply(
                          vector.new(bestguns.r(0.3), bestguns.r(0.3), bestguns.r(0.3)),
                          finaldir
                        )
                      ),
                      collisiondetection = true,
                      velocity = vel,
                      acceleration = acc,
                      drag = vector.new(2,0,2),
                      expirationtime = math.random(8),
                      size = 3/4.5,
                      node = node,
                    })
                  end
                    
                    self.object:remove()
                    return
                end
            end
        end

        self.object:set_pos(next_pos)
    end
})