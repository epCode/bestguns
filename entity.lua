-- Momentary "x" hitmarker shown over the crosshair when the shooter lands a
-- hit: white normally, yellow on a headshot. Repeated hits (full-auto) just
-- refresh the same element and reset its fade timer instead of stacking.
bestguns.hitmarkers = bestguns.hitmarkers or {} -- [pname] = {id = hudid, job = <after handle>}

-- Bullets batter a raised shield far harder than arrows. Mineclonia wears a
-- blocking shield by roughly the damage it soaks (~6 for a bow's arrow) and
-- ignores sub-3-damage hits outright, so bullets - especially our scaled-down
-- rounds - would barely scratch one. Instead, every bullet a shield blocks eats
-- this many points of durability directly: ~10x a typical arrow's ~6. Only
-- applies where shields exist (Mineclonia); games without mcl_shields (CTF) skip it.
local BULLET_SHIELD_WEAR = tonumber(core.settings:get("bestguns_bullet_shield_wear")) or 60

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
  local pname = player:get_player_name()
  bestguns.hitmarkers[pname] = nil
  bestguns.last_gun[pname] = nil
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

-- Is the node occupying world point `p` a liquid (water, lava, ...)? Unknown
-- nodes count as non-liquid. Used to detect a bullet crossing a water surface.
local function is_liquid_at(p)
  local def = core.registered_nodes[core.get_node(p).name]
  return def and def.liquidtype ~= "none" or false
end

-- Binary-search the liquid surface crossing point along the segment `a`->`b`,
-- whose endpoints straddle the surface (one in liquid, one out). Returns a
-- point sitting right on that surface so the splash spawns where it should.
local function find_liquid_boundary(a, b)
  local la = is_liquid_at(a)
  for _ = 1, 7 do
    local mid = vector.multiply(vector.add(a, b), 0.5)
    if is_liquid_at(mid) == la then a = mid else b = mid end
  end
  return vector.multiply(vector.add(a, b), 0.5)
end

-- Splash a bullet makes crossing a liquid surface. `node` is the actual liquid
-- node so the droplets are textured (and shaded) like the water they came from,
-- exactly like the node-hit debris. Entry and exit are deliberately distinct:
--   * ENTRY (bullet punching in): a crown of droplets bursting up and outward
--     with a foam ring on the surface - a big, loud impact.
--   * EXIT (bullet breaking out): a thinner spray flung forward along the
--     bullet's travel direction with a little trailing foam - no crown, quieter.
-- `damage` scales the splash: 30 is the baseline size, lower shrinks it (10 =
-- small plip), higher grows it (60 = double). Guards a sane minimum so a
-- near-zero-damage round still makes a visible ripple.
function bestguns.water_splash(pos, velocity, node, exit, damage)
  local speed = vector.length(velocity)
  local dir = speed > 0.001 and vector.normalize(velocity) or vector.new(0, -1, 0)
  local scale = math.max((damage or 30) / 30, 0.25) / bestguns.damage_scale
  local h_scale = scale / 2

  -- Foam is a water thing - lava (and any hot/molten liquid) skips it entirely,
  -- just throwing the molten droplets. Detected via the `lava` node group with a
  -- name fallback for oddly-grouped moddedliquids.
  local ndef = core.registered_nodes[node.name] or {}
  local foam = not ((ndef.groups and ndef.groups.lava) or node.name:find("lava"))

  core.sound_play("bestguns_splash", {
    pos = pos,
    gain = exit and 0.6 or 1.1,
    max_hear_distance = 30,
    pitch = exit and math.random(80, 120) / 100 or math.random(80, 120) / 100
  }, true)

  if not exit then
    -- Crown of water droplets shooting up and out from the point of entry.
    for _ = 1, math.random(12, math.ceil(20 * (scale))) do
      core.add_particle({
        pos = vector.offset(pos, bestguns.r(0.15), 0, bestguns.r(0.15)),
        velocity = {x = bestguns.r(2.5 * h_scale), y = math.random(20, 65 * h_scale) / 10, z = bestguns.r(2.5 * h_scale)},
        acceleration = {x = 0, y = -9.81, z = 0},
        expirationtime = math.random(4, 9) / 10,
        collisiondetection = true,
        size = math.random(6, 12) / 5,
        node = node,
      })
    end
    -- Foam ring bursting outward across the surface.
    for _ = 1, foam and math.random(4, math.ceil(50 * scale)) or 0 do
      core.add_particle({
        pos = vector.offset(pos, bestguns.r(0.25), 0.02, bestguns.r(0.25)),
        velocity = {x = bestguns.r(1.4 * h_scale), y = math.random(3, 100 * h_scale) / 10, z = bestguns.r(1.4 * h_scale)},
        acceleration = {x = 0, y = -9.81, z = 0},
        expirationtime = math.random(5, 10) / 10,
        size = math.random(18, 28) / 30,
        texture = "bestguns_foam.png^[opacity:" .. math.random(160, 230),
      })
    end
  else
    -- Thin spray of droplets dragged along the bullet's exit direction.
    for _ = 1, math.random(5, 9) do
      core.add_particle({
        pos = vector.offset(pos, bestguns.r(0.1), 0, bestguns.r(0.1)),
        velocity = vector.add(vector.multiply(dir, math.random(15, 35) / 10),
          {x = bestguns.r(1), y = bestguns.r(1), z = bestguns.r(1)}),
        acceleration = {x = 0, y = -9.81, z = 0},
        expirationtime = math.random(3, 6) / 10,
        collisiondetection = true,
        size = math.random(4, 8) / 10 * scale,
        node = node,
      })
    end
    -- A wisp of foam trailing off the exit point.
    for _ = 1, foam and math.random(2, 4) or 0 do
      core.add_particle({
        pos = vector.offset(pos, bestguns.r(0.15), 0, bestguns.r(0.15)),
        velocity = vector.multiply(dir, math.random(5, 12) / 10),
        acceleration = {x = 0, y = -3, z = 0},
        expirationtime = math.random(3, 6) / 10,
        size = math.random(8, 16) / 10 * scale,
        texture = "bestguns_foam.png^[opacity:" .. math.random(120, 190),
      })
    end
  end
end

-- Shortest distance from point `p` to the segment `a`->`b`. Used so a fast
-- bullet whizzes past a player based on its closest approach along the whole
-- step it travelled, not just its (possibly already-passed) end position.
local function dist_point_segment(p, a, b)
  local ab = vector.subtract(b, a)
  local len2 = vector.dot(ab, ab)
  local t = 0
  if len2 > 0 then
    t = vector.dot(vector.subtract(p, a), ab) / len2
    t = math.max(0, math.min(1, t))
  end
  local closest = vector.add(a, vector.multiply(ab, t))
  return vector.distance(p, closest), closest
end

function vector.random(magnitude)
  local x = (math.random() * 2 - 1) * magnitude
  local y = (math.random() * 2 - 1) * magnitude
  local z = (math.random() * 2 - 1) * magnitude
  return {x = x, y = y, z = z}
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
      -- Normally a bullet can't hit the player who fired it. Spawn data can set
      -- _self_hit to lift that (e.g. grenade shards - your own frag can kill you).
      self._self_hit = data._self_hit

      -- Attribute this bullet to the gun that fired it, for accuracy stats. Use
      -- the gun stamped on the spawn data, falling back to the shooter's last
      -- fired gun (covers pellets from a custom on_fire that don't stamp _gun).
      -- Record the shot now that we know the gun; hits are recorded on impact.
      if self.shooter_name and self.shooter_name ~= "" then
        self._gun = data._gun or bestguns.last_gun[self.shooter_name]
        if self._gun then
          bestguns.on_shot(self.shooter_name, self._gun)
        end
      end

      local b_def = self._item and bestguns.registered_bullets[self._item]

      -- Distance-based damage falloff (Star Wars Battlefront style). Damage ramps
      -- from a MAX (the serialized `damage`) down to a MIN between two distances.
      -- Two sources supply the falloff band, in priority order:
      --   1. The firing gun's `gun_range`, stamped onto the spawn data at fire
      --      time by bestguns.apply_range() (falloff_start/end + damage_min).
      --   2. A bullet def declaring `damage_min`, `falloff_start`, `falloff_end`;
      --      its MIN is rescaled by the gun's damage_mult/damage_scale ratio.
      -- With neither, the bullet keeps constant damage (default behaviour).
      self._dmg_max = self.damage
      self._dmg_min = self.damage
      if data.falloff_start and data.falloff_end and data.damage_min then
        self._dmg_min = data.damage_min
        self._falloff_start = data.falloff_start
        self._falloff_end = data.falloff_end
      elseif b_def and b_def.damage_min and b_def.damage and b_def.damage > 0
         and b_def.falloff_start and b_def.falloff_end then
        local scale = self.damage / b_def.damage
        self._dmg_min = math.floor(b_def.damage_min * scale)
        self._falloff_start = b_def.falloff_start
        self._falloff_end = b_def.falloff_end
      end
      self.start_pos = self.object:get_pos()

      -- Track whether the bullet is currently submerged so on_step can spot the
      -- moment it crosses a liquid surface (in or out) and splash accordingly.
      self._in_liquid = is_liquid_at(self.start_pos)

      -- Bullet gravity (m/s^2): every round drops over distance. A bullet def may
      -- override the gentle global default (bestguns.bullet_gravity) with its own
      -- `gravity` - e.g. 0 for a dead-straight energy bolt, or a larger value for
      -- a heavy slugthrower round that arcs noticeably.
      if b_def and b_def.gravity ~= nil then
        self._gravity = b_def.gravity
      else
        self._gravity = bestguns.bullet_gravity
      end

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

      -- Ricochet: a bullet may bounce off walkable nodes up to `bounces` times
      -- (per-bullet def, or overridden per spawn via data._bounces) before it's
      -- spent on the next node hit. Each bounce reflects the velocity about the
      -- struck face and keeps `bounce_restitution` (default 0.5) of its speed. 0 =
      -- the normal behaviour (destroyed on the first node hit). Grenade fragments
      -- use this to ricochet off walls.
      self._bounces = data._bounces or (b_def and b_def.bounces) or 0
      self._bounce_restitution = (b_def and b_def.bounce_restitution) or 0.5

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

      -- Faint bullet trail: emitted in on_step by dropping a puff at a fixed
      -- spacing along the exact path the bullet travels (see there). `trail_carry`
      -- keeps the spacing even across ticks. A bullet def sets `trail = false` to
      -- disable it, or `trail_spacing` (metres) to tune the puff density.
      self._trail = b_def and b_def.trail
      self._trail_spacing = b_def and b_def.trail_spacing
      self._trail_carry = 0
      -- Optional cap (in nodes) on how far the trail is drawn: once the bullet has
      -- travelled this far the puffs stop, even though the bullet flies on. Set per
      -- spawn via data._trail_max (e.g. grenade shards each stop at a random 2-9).
      self._trail_max = data._trail_max
      self._trail_traveled = 0


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

        -- Water splash: bullets aren't stopped by liquids (the hit raycast below
        -- ignores them), but crossing a liquid surface throws a splash. A bullet
        -- moves several nodes per tick, so we can't just compare the two
        -- endpoints - a fast round can dive in and punch back out of a thin sheet
        -- of water in a single step, leaving both ends in air. Instead march the
        -- segment in small samples and splash at every surface crossing found,
        -- textured with the liquid node so the droplets match the water.
        local seg = vector.subtract(next_pos, pos)
        local seg_len = vector.length(seg)
        if seg_len > 0 then
          local step = 0.3
          local sdir = vector.multiply(seg, 1 / seg_len)
          local prev_pos, prev_liquid = pos, self._in_liquid
          local d = step
          while true do
            local at_end = d >= seg_len
            local sample_pos = at_end and next_pos or vector.add(pos, vector.multiply(sdir, d))
            local sample_liquid = is_liquid_at(sample_pos)
            if sample_liquid ~= prev_liquid then
              local surface = find_liquid_boundary(prev_pos, sample_pos)
              local water_node = core.get_node(sample_liquid and sample_pos or prev_pos)
              bestguns.water_splash(surface, self.velocity, water_node, not sample_liquid, self.damage)
              prev_liquid = sample_liquid
            end
            prev_pos = sample_pos
            if at_end then break end
            d = d + step
          end
          self._in_liquid = prev_liquid
        end

        -- Faint bullet trail. Drop a small puff at a fixed spacing along the exact
        -- segment travelled this tick, so the trail is an even line no matter the
        -- bullet's speed or the tick length. `_trail_carry` holds the leftover
        -- distance past the last puff, so spacing stays consistent across ticks
        -- instead of clumping at tick boundaries. Underwater the trail becomes a
        -- line of foam bubbles drifting up, rather than the airborne smoke puff.
        if self._trail ~= false
            and not (self._trail_max and self._trail_traveled >= self._trail_max) then
          local spacing = self._trail_spacing or 0.5
          local seg = vector.subtract(next_pos, pos)
          local seglen = vector.length(seg)
          if seglen > 0 then
            self._trail_traveled = self._trail_traveled + seglen
            local dir = vector.multiply(seg, 1 / seglen)
            local d = spacing - self._trail_carry
            while d <= seglen do
              local puff_pos = vector.add(pos, vector.multiply(dir, d))
              -- Decide bubble-vs-smoke per puff, not per tick: a bullet moves
              -- several nodes a tick and can straddle the surface, so testing the
              -- tick-level self._in_liquid would draw bubbles along the airborne
              -- stretch too. Sample the liquid state at this puff's own position.
              if is_liquid_at(puff_pos) then
                core.add_particle({ -- foam bubble wake, rising slowly
                  pos = puff_pos,
                  velocity = {x = bestguns.r(0.1), y = math.random(1, 3) / 10, z = bestguns.r(0.1)},
                  acceleration = {x = 0, y = 0.15, z = 0},
                  expirationtime = math.random(10, 22) / 10,
                  size = math.random(6, 14) / 10,
                  texture = {
                    name = "bestguns_foam.png^[opacity:" .. math.random(120, 200),
                    alpha_tween = {1, 0},
                  },
                  glow = 0,
                })
              else
                core.add_particle({
                  pos = puff_pos,
                  velocity = vector.random(0.1),
                  expirationtime = math.random(10, 20) / 5,
                  size = math.random(10, 20) / 7,
                  texture = {
                    name = "bestguns_smoke_2.png^[opacity:60",
                    alpha_tween = {1, 0},
                  },
                  glow = 0,
                })
              end
              d = d + spacing
            end
            self._trail_carry = seglen - (d - spacing)
          end
        end

        if not self.shooter_name then return end
        local shooter = core.get_player_by_name(self.shooter_name)

        -- Whiz-by: as the round passes a player (other than the shooter) it plays
        -- a positional "whiz" from its closest approach, once per player per
        -- bullet. Bullets set `whiz_sound = false` to stay silent, or override the
        -- trigger radius with `whiz_distance`.
        local b_def = self._item and bestguns.registered_bullets[self._item]
        local whiz_sound = bestguns.default_whiz_sound
        if b_def and b_def.whiz_sound ~= nil then whiz_sound = b_def.whiz_sound or nil end
        if whiz_sound then
          local trigger = (b_def and b_def.whiz_distance) or bestguns.whiz_distance
          self._whizzed = self._whizzed or {}
          for _, player in ipairs(core.get_connected_players()) do
            local pname = player:get_player_name()
            if pname ~= self.shooter_name and not self._whizzed[pname] then
              local ppos = vector.offset(player:get_pos(), 0, 1.3, 0)
              local d, closest = dist_point_segment(ppos, pos, next_pos)
              -- Skip near-direct hits (those are handled as an impact, not a miss).
              if d < trigger and d > 0.7 then
                self._whizzed[pname] = true
                core.sound_play(whiz_sound, {
                  pos = closest,
                  to_player = pname,
                  gain = math.max(0.25, 1 - d / trigger),
                  max_hear_distance = bestguns.whiz_hear_distance,
                }, true)
              end
            end
          end
        end

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
                -- Prevent the shooter from hitting themselves (unless _self_hit).
                if obj and obj:is_valid() and (self._self_hit or obj ~= shooter) then
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

                    -- A raised shield facing this bullet blocks the hit like any
                    -- projectile, but bullets chew through it ~10x faster than an
                    -- arrow: wear it down explicitly (see BULLET_SHIELD_WEAR). Guarded
                    -- so it's a no-op in games without shields (e.g. CTF).
                    if mcl_shields and obj:is_player() then
                        local can_block = mcl_shields.can_block(obj, self.object:get_pos(),
                            {type = "arrow", direct = self.object})
                        if can_block then
                            mcl_shields.add_wear(obj, BULLET_SHIELD_WEAR)
                        end
                    end

                    obj:punch(puncher, 1.0, {
                        full_punch_interval = 1.0,
                        damage_groups = damage_groups
                    }, self.velocity)

                    -- Accuracy stats: a fired round struck a player. Bots and
                    -- other non-player objects don't count toward hit-rate.
                    if self.shooter_name and self.shooter_name ~= "" and self._gun and obj:is_player() then
                        bestguns.on_hit(self.shooter_name, self._gun, obj, headshot)
                    end

                    -- Hit feedback to the shooter: a momentary "x" hitmarker
                    -- (yellow on a headshot) plus a sound cue.
                    local shooter_player = self.shooter_name and core.get_player_by_name(self.shooter_name)
                    if shooter_player and obj:is_player() then
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

                  -- Impact sound, resolved from the node's name/groups (see
                  -- bestguns.node_hit_sound) with the bullet's own default and
                  -- the global "bestguns_hit_ground" as fallbacks.
                  local hit_snd = bestguns.node_hit_sound(b_def, node)
                  if hit_snd then
                    core.sound_play(hit_snd, {
                      pos = pointed_thing.intersection_point,
                      gain = 1,
                      max_hear_distance = 40,
                    }, true)
                  end

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

                  -- Ricochet off the struck face if the bullet has bounces left.
                  -- Reflect the velocity about the (axis-aligned) face normal by
                  -- flipping its normal component, then damp the whole vector by the
                  -- restitution. Nudge the bullet just off the surface so it doesn't
                  -- immediately re-hit the same node, and end the tick here so it
                  -- flies on from the impact point next step. Effects above still play.
                  if self._bounces and self._bounces > 0 then
                    self._bounces = self._bounces - 1
                    if facedir.x ~= 0 then self.velocity.x = -self.velocity.x end
                    if facedir.y ~= 0 then self.velocity.y = -self.velocity.y end
                    if facedir.z ~= 0 then self.velocity.z = -self.velocity.z end
                    self.velocity = vector.multiply(self.velocity, self._bounce_restitution)
                    self.object:set_pos(vector.add(pointed_thing.intersection_point,
                      vector.multiply(facedir, 0.05)))
                    return
                  end

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