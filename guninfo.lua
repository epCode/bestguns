-- /guninfo : a fancy GUI table of every gun a player has ever carried.
--
-- We keep a per-player "seen guns" set, persisted in mod storage, that is
-- topped up by periodically scanning online players' inventories. Any gun (or
-- its magazine) that passes through a player's main inventory gets remembered,
-- so /guninfo can later show that gun's full stat sheet.

local storage = core.get_mod_storage()

-- [player_name] = { [gun_name] = true }
local seen = {}

local function load_seen(pname)
	if seen[pname] then return end
	seen[pname] = {}
	local s = storage:get_string("seen_" .. pname)
	if s ~= "" then
		for g in s:gmatch("[^,]+") do
			seen[pname][g] = true
		end
	end
end

local function save_seen(pname)
	local list = {}
	for g in pairs(seen[pname]) do
		list[#list + 1] = g
	end
	table.sort(list)
	storage:set_string("seen_" .. pname, table.concat(list, ","))
end

core.register_on_joinplayer(function(player)
	load_seen(player:get_player_name())
end)

core.register_on_leaveplayer(function(player)
	seen[player:get_player_name()] = nil
end)

-- Periodically remember any gun that shows up in an online player's inventory.
local scan_timer = 0
core.register_globalstep(function(dtime)
	scan_timer = scan_timer + dtime
	if scan_timer < 3 then return end
	scan_timer = 0

	for _, player in ipairs(core.get_connected_players()) do
		local pname = player:get_player_name()
		load_seen(pname)
		local changed = false
		for _, stack in ipairs(player:get_inventory():get_list("main") or {}) do
			if not stack:is_empty() then
				-- A "<gun>_mag" item counts as having carried "<gun>".
				local gname = stack:get_name():gsub("_mag$", "")
				if bestguns.registered_guns[gname] and not seen[pname][gname] then
					seen[pname][gname] = true
					changed = true
				end
			end
		end
		if changed then save_seen(pname) end
	end
end)

--------------------------------------------------------------------------------
-- Formspec building
--------------------------------------------------------------------------------

-- Trim trailing zeros so "0.50" -> "0.5" and "2.00" -> "2".
local function num(n)
	if n == nil then return "-" end
	local s = string.format("%.2f", n)
	s = s:gsub("%.?0+$", "")
	return s == "" and "0" or s
end

local function bullet_of(def)
	return bestguns.registered_bullets[def.default_bullet] or {}
end

-- Effective per-hit damage, matching the calc in fire_gun().
local function effective_damage(def)
	local b = bullet_of(def)
	return math.floor((b.damage or 0) * (def.damage_mult or 1) * bestguns.damage_scale)
end

local esc = core.formspec_escape

-- Texture used to visualise a gun (the bare weapon, no magazine overlay).
local function gun_texture(def)
	return def.texture_nomag or def.texture_mag or def.inventory_image or "blank.png"
end

-- The loose bullets a gun accepts (all bullets sharing its caliber, default
-- round first). Shown as the per-row "compatible ammo" list.
local function gun_ammo(def)
	local out, seen = {}, {}
	local d = bestguns.registered_bullets[def.default_bullet]
	if d then
		out[#out + 1] = d.description or def.default_bullet
		seen[def.default_bullet] = true
	end
	for bname, b in pairs(bestguns.registered_bullets) do
		if not seen[bname] and b.caliber == def.caliber then
			out[#out + 1] = b.description or bname
		end
	end
	if #out == 0 then out[1] = "-" end
	return out
end

-- All display values for one gun's row, keyed by column id.
local function gun_values(name, def)
	local b = bullet_of(def)
	local dmg = tostring(effective_damage(def))
	if b.shots and b.shots > 1 then
		dmg = dmg .. " x" .. b.shots -- shotgun: per-pellet x pellet count
	end
	local spread = num(def.inaccuracy or 0)
	if (def.inaccuracy or 0) == 0 then spread = spread .. "*" end -- * = pinpoint
	return {
		name   = def.description or name,
		dmg    = dmg,
		speed  = num(b.speed or 0),
		spread = spread,
		action = (def.action or "semi"):upper() .. (def.load_action == "direct" and " DL" or ""),
		delay  = num(def.fire_delay or 0) .. "s",
		zoom   = num(def.zoom or 0.9),
		scope  = def.zoomhud and ("x" .. num(def.scope_size or 1)) or "-",
		recoil = num(b.recoil or 0),
		kick   = num(def.kick or 0),
		mag    = tostring(def.mag_capacity or "-"),
		cal    = def.caliber or "-",
		ammo   = table.concat(gun_ammo(def), "\n"),
	}
end

-- Modern theme palette --------------------------------------------------------
local COL = {
	bg     = "#12141C",   -- window background
	panel  = "#1B1E2A",   -- header panel
	head   = "#2A2F40",   -- table header row
	row_a  = "#242838",   -- row background (odd)
	row_b  = "#1E2130",   -- row background (even)
	full   = "#E5533D",   -- accent: full-auto
	semi   = "#3D9BE5",   -- accent: semi-auto
	name   = "#FFFFFF",
	key    = "#7E8AA3",   -- header labels
	value  = "#EDF1F8",   -- stat values
	ammo   = "#9FB2C9",   -- ammo list
	title  = "#FFD54A",
	sub    = "#8A93A6",
}

-- Column layout (left -> right). `w` in formspec units; `x` filled in below.
local COLS = {
	{ id = "img",    label = "",        w = 1.15 },
	{ id = "name",   label = "WEAPON",  w = 3.15 },
	{ id = "dmg",    label = "DMG",     w = 1.10 },
	{ id = "speed",  label = "SPEED",   w = 1.25 },
	{ id = "spread", label = "SPREAD",  w = 1.35 },
	{ id = "action", label = "ACTION",  w = 1.45 },
	{ id = "delay",  label = "DELAY",   w = 1.15 },
	{ id = "zoom",   label = "ZOOM",    w = 1.10 },
	{ id = "scope",  label = "SCOPE",   w = 1.15 },
	{ id = "recoil", label = "RECOIL",  w = 1.30 },
	{ id = "kick",   label = "KICK",    w = 1.05 },
	{ id = "mag",    label = "MAG",     w = 1.00 },
	{ id = "cal",    label = "CALIBER", w = 1.40 },
	{ id = "ammo",   label = "COMPATIBLE AMMO", w = 4.70 },
}
local COLX = {}
local TABLE_W = 0.25
for _, c in ipairs(COLS) do
	c.x = TABLE_W
	COLX[c.id] = TABLE_W
	TABLE_W = TABLE_W + c.w
end
TABLE_W = TABLE_W + 0.15

local HEADER_H = 0.6
local ROW_H    = 1.15
local IMG_SZ   = 0.9

-- Emit just the (fixed) header row into `out`, relative to the horizontally
-- scrolling container origin.
local function build_header(out)
	out[#out + 1] = string.format("box[0,0;%f,%f;%s]", TABLE_W, HEADER_H, COL.head)
	out[#out + 1] = "style_type[label;font=mono,bold;font_size=*0.72;textcolor=" .. COL.key .. "]"
	for _, c in ipairs(COLS) do
		if c.label ~= "" then
			out[#out + 1] = string.format("label[%f,0.19;%s]", c.x, esc(c.label))
		end
	end
end

-- Emit one row per gun into `out`, relative to the vertically scrolling rows
-- container origin (first row at y = 0).
local function build_rows(gun_names, out)
	for idx, name in ipairs(gun_names) do
		local def = bestguns.registered_guns[name]
		local v = gun_values(name, def)
		local rowy = (idx - 1) * ROW_H
		local accent = (def.action == "full") and COL.full or COL.semi

		out[#out + 1] = string.format("box[0,%f;%f,%f;%s]", rowy, TABLE_W, ROW_H - 0.04,
			(idx % 2 == 1) and COL.row_a or COL.row_b)
		out[#out + 1] = string.format("box[0,%f;0.08,%f;%s]", rowy, ROW_H - 0.04, accent)

		-- Gun icon (square -> no squish).
		out[#out + 1] = string.format("image[%f,%f;%f,%f;%s]",
			COLX.img + 0.12, rowy + (ROW_H - IMG_SZ) / 2, IMG_SZ, IMG_SZ, gun_texture(def))

		-- Weapon name.
		out[#out + 1] = "style_type[label;font=bold;font_size=*1.05;textcolor=" .. COL.name .. "]"
		out[#out + 1] = string.format("label[%f,%f;%s]", COLX.name, rowy + 0.4, esc(v.name))

		-- Numeric / short stat columns.
		out[#out + 1] = "style_type[label;font=bold;font_size=*0.92;textcolor=" .. COL.value .. "]"
		for _, id in ipairs({ "dmg", "speed", "spread", "action", "delay",
				"zoom", "scope", "recoil", "kick", "mag", "cal" }) do
			out[#out + 1] = string.format("label[%f,%f;%s]", COLX[id], rowy + 0.42, esc(v[id]))
		end

		-- Compatible-ammo list (may be multi-line).
		out[#out + 1] = "style_type[label;font=mono;font_size=*0.74;textcolor=" .. COL.ammo .. "]"
		out[#out + 1] = string.format("label[%f,%f;%s]", COLX.ammo, rowy + 0.32, esc(v.ammo))
	end
end

-- Most rows visible at once before the list starts scrolling vertically. Keeps
-- the window a readable height no matter how many guns have been carried.
local VIEW_ROWS = 8

local function build_formspec(gun_names)
	table.sort(gun_names, function(a, b)
		local da, db = bestguns.registered_guns[a], bestguns.registered_guns[b]
		return (da.description or a) < (db.description or b)
	end)

	local W = 19
	local table_y = 1.55

	-- Vertical: cap the visible rows; the rest scroll. `rows_h` is the content
	-- height, `rows_view_h` the (capped) viewport height.
	local rows_h = #gun_names * ROW_H
	local rows_view_h = math.min(rows_h, VIEW_ROWS * ROW_H)
	local vscroll = rows_h > rows_view_h + 0.01

	-- Horizontal: the table is wider than the window, so it scrolls sideways.
	local vsb_area = vscroll and 0.5 or 0.0
	local view_w = W - 0.8 - vsb_area
	local hscroll = TABLE_W > view_w + 0.01

	local hsb_area = hscroll and 0.55 or 0.15
	-- Outer (horizontal) container holds the fixed header + the rows viewport.
	local outer_h = HEADER_H + rows_view_h
	local total_h = table_y + outer_h + hsb_area + 1.15

	local fs = {
		"formspec_version[4]",
		string.format("size[%f,%f]", W, total_h),
		"bgcolor[#00000000;true]",
		string.format("box[0,0;%f,%f;%s]", W, total_h, COL.bg),
		-- Title panel.
		string.format("box[0,0;%f,1.32;%s]", W, COL.panel),
		string.format("box[0,1.32;%f,0.03;%s]", W, COL.title),
		"style_type[label;font=bold;font_size=*1.5;textcolor=" .. COL.title .. "]",
		string.format("label[0.5,0.48;%s]", esc("GUN STATS")),
		"style_type[label;font=normal;font_size=*0.85;textcolor=" .. COL.sub .. "]",
		string.format("label[0.5,0.95;%s]", esc(
			("%d weapon%s carried   -   * pinpoint accuracy   -   DL direct-load   -   scroll to see every weapon & stat")
			:format(#gun_names, #gun_names == 1 and "" or "s"))),
	}

	-- Outer container scrolls horizontally; inside it the header is pinned at the
	-- top while the rows sit in their own vertically scrolling container. Both
	-- share the horizontal scroll, so columns stay aligned under the header.
	fs[#fs + 1] = string.format(
		"scroll_container[0.4,%f;%f,%f;guninfo_h;horizontal;0.1;0.3]",
		table_y, view_w, outer_h)
	build_header(fs)
	fs[#fs + 1] = string.format(
		"scroll_container[0,%f;%f,%f;guninfo_v;vertical;0.1]",
		HEADER_H, TABLE_W, rows_view_h)
	build_rows(gun_names, fs)
	fs[#fs + 1] = "scroll_container_end[]"
	fs[#fs + 1] = "scroll_container_end[]"

	-- Vertical scrollbar: fixed on the right, always visible while you scroll
	-- sideways, aligned with the rows viewport.
	if vscroll then
		fs[#fs + 1] = string.format("scrollbaroptions[arrows=hide;min=0;max=%d]",
			math.ceil((rows_h - rows_view_h) * 10))
		fs[#fs + 1] = string.format("scrollbar[%f,%f;0.3,%f;vertical;guninfo_v;0]",
			0.4 + view_w + 0.1, table_y + HEADER_H, rows_view_h)
	end

	-- Horizontal scrollbar below the table.
	if hscroll then
		fs[#fs + 1] = string.format("scrollbaroptions[arrows=hide;min=0;max=%d]",
			math.ceil((TABLE_W - view_w) * 10))
		fs[#fs + 1] = string.format("scrollbar[0.4,%f;%f,0.3;horizontal;guninfo_h;0]",
			table_y + outer_h + 0.12, view_w)
	end

	fs[#fs + 1] = "style[close;bgcolor=" .. COL.semi .. ";textcolor=#FFFFFF]"
	fs[#fs + 1] = string.format("button_exit[%f,%f;3,0.85;close;Close]",
		W - 3.4, total_h - 1.0)

	return table.concat(fs)
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

core.register_chatcommand("guninfo", {
	description = "Show a visual stat card for every gun you've carried",
	func = function(pname)
		load_seen(pname)
		local names = {}
		for g in pairs(seen[pname]) do
			if bestguns.registered_guns[g] then
				names[#names + 1] = g
			end
		end
		if #names == 0 then
			return true, "You haven't carried any guns yet. Pick one up and run /guninfo again."
		end
		core.show_formspec(pname, "bestguns:guninfo", build_formspec(names))
		return true
	end,
})
