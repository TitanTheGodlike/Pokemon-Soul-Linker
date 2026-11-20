-- Soul Link panel, with three tabs:
--   Team & Links: everyone's team, the links table, rule problems and recent events
--   Routes:       every area in story order, your next encounter and the level cap
--   Graveyard:    every Pokémon that died
-- Its own window next to BizHawk ("panel": "docked" in the profile draws a small text version
-- beside the DS screens instead). It opens to fit the screen BizHawk is on, can be resized, and
-- scales everything (text included) to fill the window. Redrawn only when something changed.
-- Styled after the games: a Pokédex-red header, party-screen plates with HP bars, gym badges,
-- Pokémon text boxes and gravestones.
local game = require("game")
local json = require("json")
local icons = require("icons")
local progress = require("progress")
local sprites = require("sprites")

local hud = {}

local C = {
  bg = 0xFF131620, bg2 = 0xFF171A25,
  plate = 0xFF222839, plate2 = 0xFF1C2131, plateEdge = 0xFF353D55,
  slot = 0xFF2B3248, slotEdge = 0xFF46506E, slotEmpty = 0xFF1A1F2D, slotEmptyEdge = 0xFF242A3B,
  slotDead = 0xFF3A2029, slotDeadEdge = 0xFF94343E,
  text = 0xFFF4F5F8, dim = 0xFFB8BED0, faint = 0xFF7F879E, white = 0xFFFFFFFF,
  ink = 0xFF0E1015, shadow = 0xFF07080B,
  red = 0xFFE3262E, redDark = 0xFF9C141B, redLight = 0xFFFF6B6B,
  good = 0xFF3FBF6A, bad = 0xFFE5484D, warn = 0xFFF59E2E, wait = 0xFF3D8BEA,
  badText = 0xFFFF7A7A,
  gold = 0xFFF8C830, goldEdge = 0xFFA87810, goldHi = 0xFFFFF4B0, badgeOff = 0xFF343B52,
  capBg = 0xFF3A2E1C, capEdge = 0xFF8F6A2C, capText = 0xFFFFCF6A,
  paper = 0xFFF8F8F4, paperText = 0xFF3C3C46, paperShadow = 0xFFD2D2DA, paperDim = 0xFF6C6C7C,
  paperWarn = 0xFFC05A00, paperBad = 0xFFD0242A, dlgEdge = 0xFF1E2433,
  logo = 0xFFFFCB05, logoEdge = 0xFF2A5AA8, logoDeep = 0xFF13306A,
  screen = 0xFF161A24, ballWhite = 0xFFF4F4F4, ballRed = 0xFFE3262E,
  hpFrame = 0xFF1A1E29, hpTag = 0xFFF8B830, hpEmpty = 0xFF4A5164,
  grave = 0xFF231F30, graveEdge = 0xFF3B3550, stone = 0xFF57516E, stoneDark = 0xFF3A3550,
  warnBg = 0xFF3A1F26, warnEdge = 0xFF7A2A34, infoBg = 0xFF1C2A42, infoEdge = 0xFF2E4C7E,
  nextBg = 0xFF2A2330,
  tipBg = 0xFF0D1018, tipEdge = 0xFF56607E, strip = 0xFF1A2031, stripEdge = 0xFF30384F,
}
-- one accent colour per player (you are the first)
local PLAYER_COLORS = { 0xFFFF6B6B, 0xFF4FD1C5, 0xFFFFD166, 0xFFB794F4, 0xFF68D391, 0xFFF6AD55 }
-- one colour per link (its number tag shows on the Pokémon in every team, and on the link's row)
local LINK_COLORS = { 0xFF4E9BFF, 0xFFFF8A3D, 0xFF3DDC97, 0xFFE05CFF, 0xFFFFD43B, 0xFF41E1E1,
  0xFFFF5C8A, 0xFFA3E635, 0xFF9D8CFF, 0xFFFFA8A8 }
local STATUS = {
  alive = { "ALIVE", C.good }, waiting = { "WAITING", C.wait },
  broken = { "MISSED", C.warn }, dead = { "DEAD", C.bad },
}
-- the games' HP bar colours: { bar, its lighter top half }
local HP = { { 0xFF30B858, 0xFF70F0A0 }, { 0xFFD0A000, 0xFFF8E040 }, { 0xFFC02830, 0xFFF86048 } }

local T = 0x00000000 -- no text background: text is drawn straight onto the plates
local floor = math.floor

------------------------------------------------------------------ window
local mode, cv
local W, H = 560, 760         -- the window's inside, in screen pixels
local maxW, maxH = 560, 760   -- the drawing surface (as big as the screen, so resizing just works)
local dpi = 1                 -- Windows display scaling (1.25 = 125%)
local BASE_W = 520            -- layout width in units; the scale is window width / this
local form, pic
local lastSig, lastState
local tab = "team"            -- "team" | "routes" | "graves"
local tabRects = {}
local anims = {}              -- animated Pokémon on the panel: { e, x, y, w, h, bg, after, pose }
local hits = {}               -- areas with an explanation: { id, x, y, w, h, title, lines }
local hover = nil             -- { id, x, y }: the area the mouse is over
local tipRect = nil           -- where the explanation box is (the animations leave it alone)
local drawMs = 0
hud.closed = false

local FONT = "Segoe UI"
local FONT_LOGO = "Segoe UI Black"

local function prop(h, k)
  local ok, v = pcall(forms.getproperty, h, k)
  return ok and tostring(v) or ""
end
local function setp(h, k, v) return pcall(forms.setproperty, h, k, v) end
local function pair(s, a, b)
  local x, y = s:match(a .. "=(%-?[%d%.]+),%s*" .. b .. "=(%-?[%d%.]+)")
  return tonumber(x), tonumber(y)
end

-- the corner points of a rounded rectangle (whole pixels)
local function rrect(x, y, w, h, r)
  r = floor(math.min(r, w / 2, h / 2))
  if r < 2 then return { { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h } } end
  local n = r < 6 and 3 or (r < 14 and 5 or 8)
  local pts = {}
  local function arc(cx, cy, a0)
    for k = 0, n do
      local a = math.rad(a0 + 90 * k / n)
      pts[#pts + 1] = { floor(cx + r * math.cos(a) + 0.5), floor(cy + r * math.sin(a) + 0.5) }
    end
  end
  arc(x + r, y + r, 180)         -- top left
  arc(x + w - r, y + r, 270)     -- top right
  arc(x + w - r, y + h - r, 0)   -- bottom right
  arc(x + r, y + h - r, 90)      -- bottom left
  return pts
end

local function windowCanvas()
  local c = {}
  function c.begin() forms.drawRectangle(pic, 0, 0, W, H, C.bg, C.bg) end
  function c.text(x, y, s, col, size, style, bg, align, font)
    forms.drawText(pic, floor(x), floor(y), s, col or C.text, bg or T,
      math.max(6, floor((size or 9) + 0.5)), font or FONT, style or "regular", align)
  end
  function c.box(x, y, w, h, col)
    if w < 1 or h < 1 then return end
    forms.drawRectangle(pic, floor(x), floor(y), floor(w), floor(h), col, col)
  end
  function c.poly(pts, col)
    local ip = {}
    for i, q in ipairs(pts) do ip[i] = { floor(q[1] + 0.5), floor(q[2] + 0.5) } end
    forms.drawPolygon(pic, ip, 0, 0, col, col)
  end
  -- (a guess: BizHawk can't measure text)
  function c.measure(s, size, style) return #s * size * (style == "bold" and 0.6 or 0.55) end
  -- a rounded box, with an edge of width ew in another colour if given
  function c.rbox(x, y, w, h, r, fill, edge, ew)
    x, y, w, h = floor(x + 0.5), floor(y + 0.5), floor(w + 0.5), floor(h + 0.5)
    if w < 2 or h < 2 then return end
    ew = ew and floor(ew + 0.5) or 0
    if edge and ew >= 1 then
      c.poly(rrect(x, y, w, h, r), edge)
      if w > 2 * ew and h > 2 * ew then c.poly(rrect(x + ew, y + ew, w - 2 * ew, h - 2 * ew, r - ew), fill) end
    else
      c.poly(rrect(x, y, w, h, r), fill)
    end
  end
  function c.image(path, x, y, w, h) forms.drawImage(pic, path, floor(x), floor(y), floor(w), floor(h), true) end
  function c.region(path, sx, sy, sw, sh, x, y, w, h) forms.drawImageRegion(pic, path, sx, sy, sw, sh, x, y, w, h) end
  function c.circle(x, y, d, col) forms.drawEllipse(pic, floor(x), floor(y), floor(d), floor(d), col, col) end
  function c.finish() forms.refresh(pic) end
  return c
end

-- Windows' own drawing, reached through BizHawk's .NET bridge: smooth (anti-aliased) shapes and
-- text, drawn straight onto the panel's picture. Same calls as windowCanvas. Returns nil if the
-- bridge isn't there, and then BizHawk's own (unsmoothed) drawing is used.
local function smoothCanvas()
  local ok, canvas = pcall(function()
    luanet.load_assembly("System.Drawing, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a")
    luanet.load_assembly("System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
    local import, enum = luanet.import_type, luanet.enum
    local Control, IntPtr = import("System.Windows.Forms.Control"), import("System.IntPtr")
    local Graphics, Color = import("System.Drawing.Graphics"), import("System.Drawing.Color")
    local SolidBrush, Font, Bitmap = import("System.Drawing.SolidBrush"), import("System.Drawing.Font"), import("System.Drawing.Bitmap")
    local RectangleF, PointF = import("System.Drawing.RectangleF"), import("System.Drawing.PointF")
    local GraphicsPath = import("System.Drawing.Drawing2D.GraphicsPath")
    local StringFormat = import("System.Drawing.StringFormat")
    local FontStyle = import("System.Drawing.FontStyle")
    local BOLD, REGULAR = enum(FontStyle, "Bold"), enum(FontStyle, "Regular")
    local PIXEL = enum(import("System.Drawing.GraphicsUnit"), "Pixel")
    local SMOOTH = enum(import("System.Drawing.Drawing2D.SmoothingMode"), "AntiAlias")
    local HALF = enum(import("System.Drawing.Drawing2D.PixelOffsetMode"), "Half")
    local Interp = import("System.Drawing.Drawing2D.InterpolationMode")
    local NEAREST, BICUBIC = enum(Interp, "NearestNeighbor"), enum(Interp, "HighQualityBicubic")
    local TEXT = enum(import("System.Drawing.Text.TextRenderingHint"), "AntiAliasGridFit")

    local ctl = Control.FromHandle(IntPtr(pic))
    local img = ctl and ctl.Image
    if not img then error("no picture to draw on") end
    local fmt = StringFormat.GenericTypographic -- no extra space around the text
    local origin = PointF(0, 0)

    local g -- made when first needed (the animations draw between full redraws too)
    local fillPathOf -- g's FillPath (NLua mixes up FillPath's arguments when it's called as g:FillPath)
    local function G()
      if not g then
        g = Graphics.FromImage(img)
        g.SmoothingMode = SMOOTH
        g.PixelOffsetMode = HALF -- whole-pixel boxes stay sharp
        g.TextRenderingHint = TEXT
        fillPathOf = luanet.get_method_bysig(g, "FillPath", "System.Drawing.Brush", "System.Drawing.Drawing2D.GraphicsPath")
      end
      return g
    end
    local brushes, fonts, pictures = {}, {}, {}
    local function brush(col)
      local b = brushes[col]
      if not b then
        b = SolidBrush(Color.FromArgb((col >> 24) & 0xFF, (col >> 16) & 0xFF, (col >> 8) & 0xFF, col & 0xFF))
        brushes[col] = b
      end
      return b
    end
    -- sizes are pixels, like BizHawk's own text
    local function font(family, size, style)
      size = math.max(6, floor(size * 2 + 0.5) / 2)
      local key = family .. "|" .. size .. "|" .. (style or "")
      local f = fonts[key]
      if not f then
        f = Font(family, size, style == "bold" and BOLD or REGULAR, PIXEL)
        fonts[key] = f
      end
      return f
    end
    -- pictures are read once (as a copy, so the file isn't kept locked)
    local function picture(path)
      local im = pictures[path]
      if im == nil then
        local okp, b = pcall(function()
          local raw = Bitmap(path)
          local copy = Bitmap(raw)
          raw:Dispose()
          return copy
        end)
        im = okp and b or false
        pictures[path] = im
      end
      return im or nil
    end
    local function roundPath(x, y, w, h, r)
      local path = GraphicsPath()
      r = math.min(r, w / 2, h / 2)
      if r < 1 then
        path:AddRectangle(RectangleF(x, y, w, h))
      else
        local d = 2 * r
        path:AddArc(x, y, d, d, 180, 90)
        path:AddArc(x + w - d, y, d, d, 270, 90)
        path:AddArc(x + w - d, y + h - d, d, d, 0, 90)
        path:AddArc(x, y + h - d, d, d, 90, 90)
        path:CloseFigure()
      end
      return path
    end
    local function fillPath(path, col)
      G()
      fillPathOf(brush(col), path)
      path:Dispose()
    end

    local c = { smooth = true }
    function c.begin() G():FillRectangle(brush(C.bg), 0, 0, W, H) end
    function c.measure(s, size, style)
      if not s or s == "" then return 0 end
      return G():MeasureString(s, font(FONT, size, style), origin, fmt).Width
    end
    function c.text(x, y, s, col, size, style, bg, align, family)
      if not s or s == "" then return end
      local gr = G()
      local f = font(family or FONT, size or 9, style)
      if align == "center" or align == "right" then
        local w = gr:MeasureString(s, f, origin, fmt).Width
        x = x - (align == "center" and w / 2 or w)
      end
      gr:DrawString(s, f, brush(col or C.text), x, y, fmt)
    end
    function c.box(x, y, w, h, col)
      if w < 1 or h < 1 then return end
      G():FillRectangle(brush(col), floor(x), floor(y), floor(w), floor(h))
    end
    function c.poly(pts, col)
      if #pts < 3 then return end
      local path = GraphicsPath()
      for i = 1, #pts do
        local a, b = pts[i], pts[i % #pts + 1]
        path:AddLine(a[1], a[2], b[1], b[2])
      end
      path:CloseFigure()
      fillPath(path, col)
    end
    function c.rbox(x, y, w, h, r, fill, edge, ew)
      x, y, w, h = floor(x + 0.5), floor(y + 0.5), floor(w + 0.5), floor(h + 0.5)
      if w < 2 or h < 2 then return end
      ew = ew and floor(ew + 0.5) or 0
      if edge and ew >= 1 then
        fillPath(roundPath(x, y, w, h, r), edge)
        if w > 2 * ew and h > 2 * ew then
          fillPath(roundPath(x + ew, y + ew, w - 2 * ew, h - 2 * ew, math.max(0, r - ew)), fill)
        end
      else
        fillPath(roundPath(x, y, w, h, r), fill)
      end
    end
    function c.circle(x, y, d, col)
      if d <= 0 then return end
      G():FillEllipse(brush(col), x, y, d, d)
    end
    -- pixel art (sprites, icons) stays sharp; the smooth pictures in lib/art are scaled smoothly
    local function drawPicture(path, dest, src)
      local im = picture(path)
      if not im then return end
      local gr = G()
      gr.InterpolationMode = path:find("/art/", 1, true) and BICUBIC or NEAREST
      if src then gr:DrawImage(im, dest, src, PIXEL) else gr:DrawImage(im, dest) end
    end
    function c.image(path, x, y, w, h) drawPicture(path, RectangleF(floor(x), floor(y), floor(w), floor(h))) end
    function c.region(path, sx, sy, sw, sh, x, y, w, h)
      drawPicture(path, RectangleF(x, y, w, h), RectangleF(sx, sy, sw, sh))
    end
    function c.finish()
      if g then g:Dispose(); g = nil end
      ctl:Refresh()
    end
    -- a first test of every kind of drawing, so a problem shows up now (and BizHawk's drawing is
    -- used) rather than in the middle of the game
    c.measure("Soul Link", 12, "bold")
    c.text(4, 4, "Soul Link", C.bg, 12, "bold", nil, "center")
    c.rbox(2, 2, 20, 12, 5, C.bg, C.bg, 1)
    c.poly({ { 2, 2 }, { 9.5, 2 }, { 5, 8.5 } }, C.bg)
    c.circle(2, 2, 7.5, C.bg)
    c.box(0, 0, 24, 16, C.bg)
    local art = (_G.SOULLINK_ROOT or ".") .. "/lib/art/ball_16.png"
    c.image(art, 0, 0, 16, 16)
    c.region(art, 0, 0, 8, 8, 0, 0, 8, 8)
    c.box(0, 0, 24, 16, C.bg)
    c.finish()
    return c
  end)
  if not ok then hud.smoothError = tostring(canvas) end
  return ok and canvas or nil
end

local function dockedCanvas()
  local ox = 256
  local c = {}
  function c.begin() gui.drawBox(ox, 0, ox + W, 384, C.bg, C.bg) end
  function c.text(x, y, s, col) gui.pixelText(ox + x, y, s, col or C.text, 0x00000000) end
  function c.box(x, y, w, h, col) gui.drawBox(ox + x, y, ox + x + w, y + h, col, col) end
  function c.rbox(x, y, w, h, r, fill) gui.drawBox(ox + x, y, ox + x + w, y + h, fill, fill) end
  function c.poly() end
  function c.image(path, x, y, w, h) gui.drawImage(path, ox + x, y, w, h) end
  function c.circle(x, y, d, col) gui.drawEllipse(ox + x, y, d, d, col, col) end
  function c.finish() end
  return c
end

-- the usable area of the screen BizHawk is on: maximize the (still invisible) panel once
local function screenArea(f)
  setp(f, "Left", client.xpos() + 40); setp(f, "Top", client.ypos() + 40)
  setp(f, "WindowState", "Maximized")
  local lx, ly = pair(prop(f, "Location"), "X", "Y")
  local sw, sh = pair(prop(f, "Size"), "Width", "Height")
  local cw = pair(prop(f, "ClientSize"), "Width", "Height")
  setp(f, "WindowState", "Normal")
  if not (lx and sw and cw) or sw < 400 then return { x = 0, y = 0, w = 1920, h = 1040 } end
  local b = math.max(0, (sw - cw) // 2) -- a maximized window hangs its border off the screen
  return { x = lx + b, y = ly + b, w = sw - 2 * b, h = sh - 2 * b }
end

-- clicking a tab switches to it (and redraws right away)
local function onClick()
  local mx, my = forms.getMouseX(pic), forms.getMouseY(pic)
  for _, r in ipairs(tabRects) do
    if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h and tab ~= r.id then
      tab = r.id
      lastSig = nil
      if lastState then pcall(hud.draw, lastState) end
    end
  end
end

-- one of BizHawk's own windows by its type ("MainForm", "LuaConsole"), or nil
-- (OpenForms can only be walked with its enumerator here: indexing it gives nil)
local function bizhawkForm(typeName)
  local found = nil
  pcall(function()
    luanet.load_assembly("System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
    local e = luanet.import_type("System.Windows.Forms.Application").OpenForms:GetEnumerator()
    while not found and e:MoveNext() do
      local f = e.Current
      if f:GetType().Name == typeName then found = f end
    end
  end)
  return found
end

local function openWindow()
  form = forms.newform(200, 200, "Soul Link - " .. (hud.title or ""), function() hud.closed = true; form = nil end)
  setp(form, "Opacity", 0)
  local area = screenArea(form)
  -- Windows display scaling, from how much bigger the system font got (13 px tall at 100%)
  local _, fh = pair(prop(form, "CurrentAutoScaleDimensions"), "Width", "Height")
  dpi = math.max(1, floor((fh or 13) / 13 * 4 + 0.5) / 4)

  local margin = floor(24 * dpi)
  local pw = math.min(floor(600 * dpi), area.w - 2 * margin)
  local ph = area.h - 2 * margin
  -- beside BizHawk (right, else left), always inside the screen
  local bx = client.xpos()
  local bRight = bx + client.screenwidth() + floor(16 * dpi)
  local px = bRight + floor(8 * dpi)
  if px + pw > area.x + area.w then
    px = bx - floor(8 * dpi) - pw
    if px < area.x then px = area.x + area.w - pw - margin end
  end
  setp(form, "FormBorderStyle", "Sizable")
  setp(form, "MaximizeBox", true)
  setp(form, "Width", pw); setp(form, "Height", ph)
  setp(form, "Left", px); setp(form, "Top", area.y + margin)
  maxW, maxH = area.w, area.h
  pic = forms.pictureBox(form, 0, 0, maxW, maxH)
  pcall(function() forms.setDefaultBackgroundColor(pic, C.bg) end)
  pcall(function() forms.setDefaultTextBackground(pic, T) end)
  pcall(function() forms.addclick(pic, onClick) end)
  forms.clear(pic, C.bg)
  setp(form, "Opacity", 1)
  hud.closed = false
  lastSig = nil
  W, H = 0, 0
  cv = smoothCanvas() or windowCanvas()
  -- opening the panel makes it the active window; give the focus back to the game, so your
  -- button presses keep going to BizHawk
  local main = bizhawkForm("MainForm")
  if main then pcall(function() main:Activate() end) end
end

-- follow the window's size (the user can resize it)
local function checkSize()
  local cw, ch = pair(prop(form, "ClientSize"), "Width", "Height")
  if not cw then return false end
  cw, ch = math.min(cw, maxW), math.min(ch, maxH)
  if cw ~= W or ch ~= H then W, H = cw, ch; return true end
  return false
end

function hud.setup(panelMode)
  mode = panelMode == "docked" and "docked" or "window"
  if mode == "docked" then
    W = 200
    client.SetGameExtraPadding(0, 0, W, 0)
    cv = dockedCanvas()
  else
    openWindow()
  end
end

function hud.setTitle(t)
  hud.title = t
  if form then pcall(function() forms.settext(form, "Soul Link - " .. t) end) end
end

function hud.reopen()
  if mode == "window" and not form then openWindow() end
end

-- switch tabs from code (dev/testing)
function hud.showTab(id) tab = id; lastSig = nil end

-- where BizHawk says the mouse is over the panel (dev/testing)
function hud.mouse()
  if not pic then return "no panel" end
  return forms.getMouseX(pic) .. "," .. forms.getMouseY(pic)
end

-- for checking the window's size and placement
function hud.debug()
  if not form then return "no window" end
  return string.format("W=%d H=%d max=%dx%d dpi=%.2f tab=%s draw=%dms smooth=%s%s loc=%s size=%s client=%s", W, H,
    maxW, maxH, dpi, tab, drawMs, tostring(cv and cv.smooth or false),
    hud.smoothError and (" (" .. hud.smoothError:sub(1, 120) .. ")") or "",
    prop(form, "Location"), prop(form, "Size"), prop(form, "ClientSize"))
end

function hud.teardown()
  if mode == "docked" then client.SetGameExtraPadding(0, 0, 0, 0) end
  if form then forms.destroy(form); form = nil end
end

------------------------------------------------------------------ helpers
local function clip(s, n)
  s = s or ""
  if #s <= n then return s end
  return s:sub(1, math.max(1, n - 1)) .. "."
end

-- roughly how many characters of text at this font size fit in a width (Segoe UI)
local function fits(width, size, bold)
  return math.max(1, floor(width / (size * (bold and 0.76 or 0.68))))
end

-- a colour made darker (f < 1) or lighter (f > 1)
local function shade(col, f)
  local function ch(v) return math.max(0, math.min(255, floor(v * f + 0.5))) end
  return (col & 0xFF000000) | (ch((col >> 16) & 0xFF) << 16) | (ch((col >> 8) & 0xFF) << 8) | ch(col & 0xFF)
end

-- y offset that centres a line of text of this size in a box of height h
local function mid(h, size) return h / 2 - size * 0.73 end

local function statusPill(text)
  local t = (text or ""):lower()
  if t:find("not running") or t:find("can't") then return C.bad end
  if t:find("test") then return C.wait end
  if t:find("%d players") and not t:find("waiting") then return C.good end
  return C.warn
end

local function areaName(key)
  if key == "starter" then return "Starter" end
  return game.locationName(tonumber(key) or -1)
end

-- how wide a text is (measured when Windows' drawing is used, estimated otherwise)
local function textW(s, size, style)
  if not s or s == "" then return 0 end
  if cv and cv.measure then return cv.measure(s, size, style) end
  return #s * size * (style == "bold" and 0.62 or 0.56)
end

-- a text cut to fit a width, ending in "…" when it had to be cut
local function fit(s, width, size, style)
  s = s or ""
  if not (cv and cv.measure) then return clip(s, fits(width, size, style == "bold")) end
  if width <= 0 then return "" end
  if cv.measure(s, size, style) <= width then return s end
  local n = utf8.len(s) or #s
  local function cut(k) return s:sub(1, (utf8.offset(s, k + 1) or (#s + 1)) - 1) .. "…" end
  local lo, hi = 0, n
  while lo < hi do
    local m = (lo + hi + 1) // 2
    if cv.measure(cut(m), size, style) <= width then lo = m else hi = m - 1 end
  end
  return lo > 0 and cut(lo) or ""
end

-- a text broken into lines that fit a width
local function wrap(s, width, size, style)
  local lines, cur = {}, ""
  for word in (s or ""):gmatch("%S+") do
    local try = cur == "" and word or (cur .. " " .. word)
    if cur ~= "" and textW(try, size, style) > width then
      lines[#lines + 1] = cur
      cur = word
    else
      cur = try
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

-- plain-language meaning of a link's state, and of each player's part in it
local STATUS_HELP = {
  alive = "Everyone has theirs. They share one fate: if one faints, its partners are out too.",
  waiting = "Not everyone has caught their Pokémon here yet.",
  broken = "Someone missed their encounter here, so none of these may be used. Box them.",
  dead = "One of them died, so its partners must be boxed too.",
}
local MEMBER_WORD = { caught = "caught", pending = "not caught yet", failed = "missed", dead = "dead" }
local TAB_HELP = {
  team = { "Team & Links", { "Everyone's team, and which of your Pokémon are linked." } },
  routes = { "Routes", { "Every area in story order: your next encounter, the level cap and everyone's catches." } },
  graves = { "Graveyard", { "Every Pokémon that died in this run, and where." } },
}

-- text with the games' drop shadow under it
local function stext(x, y, s, col, size, style, align, shadow, font)
  local o = math.max(1, floor(size * 0.08 + 0.5))
  cv.text(x + o, y + o, s, shadow or C.shadow, size, style, T, align, font)
  cv.text(x, y, s, col, size, style, T, align, font)
end
local function ptext(x, y, s, col, size, style, align, font) cv.text(x, y, s, col, size, style, T, align, font) end

-- smooth pictures drawn ahead of time (lib/art: our own Poke Ball and logo), because
-- BizHawk draws shapes and text without smoothing; each comes in several heights
local ART = (_G.SOULLINK_ROOT or ".") .. "/lib/art/"
local BALL_SIZES = { 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 128 }
local LOGO_SIZES = { 20, 24, 28, 32, 36, 40, 48, 56, 64, 80, 96 }
local artInfo = {} -- path -> { w, h } or false when missing
local function artFile(prefix, sizes, px)
  local pick = sizes[#sizes]
  for _, n in ipairs(sizes) do if n >= px * 0.97 then pick = n; break end end
  local path = ART .. prefix .. pick .. ".png"
  if artInfo[path] == nil then
    artInfo[path] = false
    local f = io.open(path, "rb")
    if f then
      local head = f:read(24) or ""
      f:close()
      if #head == 24 then artInfo[path] = { w = string.unpack(">I4", head, 17), h = string.unpack(">I4", head, 21) } end
    end
  end
  return artInfo[path] and path, artInfo[path]
end

-- a Poké Ball, d pixels across (ring = with a white ring around it)
local function pokeball(x, y, d, ring)
  local art = artFile(ring and "ballring_" or "ball_", BALL_SIZES, d)
  if art then cv.image(art, x, y, d, d); return end
  x, y, d = floor(x), floor(y), floor(d)
  local o = math.max(1, floor(d * 0.09 + 0.5))
  cv.circle(x, y, d, C.ink)
  cv.circle(x + o, y + o, d - 2 * o, C.ballWhite)
  local cx, cy, r = x + d / 2, y + d / 2, d / 2 - o
  local pts = {}
  for k = 0, 16 do
    local a = math.rad(180 + 180 * k / 16)
    pts[#pts + 1] = { cx + r * math.cos(a), cy + r * math.sin(a) }
  end
  cv.poly(pts, C.ballRed)
  local band = math.max(1, floor(d * 0.1 + 0.5))
  cv.box(x + o, floor(cy - band / 2), d - 2 * o, band, C.ink)
  local bd = floor(d * 0.38 + 0.5)
  cv.circle(floor(cx - bd / 2), floor(cy - bd / 2), bd, C.ink)
  local bi = bd - 2 * o
  if bi > 1 then cv.circle(floor(cx - bi / 2), floor(cy - bi / 2), bi, C.ballWhite) end
end

-- a five-pointed star (marks shiny Pokémon, like the games' summary screen)
local function star(cx, cy, r, col)
  local pts = {}
  for i = 0, 9 do
    local a = -math.pi / 2 + i * math.pi / 5
    local rr = (i % 2 == 0) and r or r * 0.45
    pts[#pts + 1] = { cx + rr * math.cos(a), cy + rr * math.sin(a) }
  end
  cv.poly(pts, col)
end

------------------------------------------------------------------ layout (sizes in units; x scale = pixels)
local U = {
  pad = 14, header = 60, tabTop = 10, tabs = 34, tabGap = 14,
  cardTop = 38, cardParty = 98, cardEmpty = 30, cardGap = 10,
  linksGap = 6, linksTitle = 32, linksHead = 26, row = 44,
  warn = 36, event = 24, bottom = 10,
  infoBox = 78, routeRow = 40, grave = 64,
  strip = 30, stripGap = 10,
}

local function cardHeight(p)
  return U.cardTop + ((#(p.state.party or {}) > 0) and U.cardParty or U.cardEmpty)
end

------------------------------------------------------------------ pieces
-- a pill like the games' type labels: coloured, white text with a dark shadow
local function chip(g, cx, y, w, h, label, col, size)
  local S = g.S
  size = size or S(9)
  cv.rbox(cx - w / 2, y, w, h, h / 2, col, shade(col, 0.6), S(1.5))
  stext(cx, y + mid(h, size), label, C.white, size, "bold", "center", shade(col, 0.35))
end

-- the HP bar from the party screen: dark frame, orange "HP" tag, green/yellow/red bar
local function hpBar(g, x, y, w, f)
  local S = g.S
  local h = S(10)
  cv.rbox(x, y, w, h, S(3), C.hpFrame)
  local ts = S(6.5)
  ptext(x + S(3), y + mid(h, ts), "HP", C.hpTag, ts, "bold")
  local bx, bw = x + S(16), w - S(18)
  local by, bh = y + S(2.5), h - S(5)
  cv.box(bx, by, bw, bh, C.hpEmpty)
  if f > 0 then
    local c = f > 0.5 and HP[1] or (f > 0.2 and HP[2] or HP[3])
    local fw = math.max(1, floor(bw * f))
    cv.box(bx, by, fw, bh, c[1])
    cv.box(bx, by, fw, math.max(1, floor(bh * 0.45)), c[2])
  end
end

-- the eight gym badges like on the trainer card (earned ones in gold); returns its left edge
local function badgeCase(g, right, y, n)
  local S = g.S
  local d, gap = S(9), S(3)
  local x = right - 8 * d - 7 * gap
  for i = 1, 8 do
    local bx = x + (i - 1) * (d + gap)
    if i <= n then
      cv.circle(bx, y, d, C.goldEdge)
      cv.circle(bx + S(1.2), y + S(1.2), d - S(2.4), C.gold)
      cv.circle(bx + d * 0.22, y + d * 0.18, d * 0.32, C.goldHi)
    else
      cv.circle(bx, y, d, C.badgeOff)
    end
  end
  return x
end

-- a section title with a Poké Ball in front
local function heading(g, x, y, text)
  local S = g.S
  pokeball(x, y + S(2), S(18))
  stext(x + S(25), y - S(1), text, C.white, S(12.5), "bold")
end

-- a Pokémon text box: white, a coloured frame and the little red arrow in the corner
local function textBox(g, y, h, frame, label, value, note, noteCol, help)
  local S, x0, inner = g.S, g.x0, g.inner
  cv.rbox(x0, y, inner, h, S(12), C.dlgEdge)
  cv.rbox(x0 + S(2), y + S(2), inner - S(4), h - S(4), S(10), frame)
  cv.rbox(x0 + S(6), y + S(6), inner - S(12), h - S(12), S(7), C.paper)
  local tx = x0 + S(20)
  ptext(tx, y + S(11), label, shade(frame, 0.62), S(9.5), "bold")
  stext(tx, y + S(28), fit(value, inner - S(40), S(15), "bold"), C.paperText, S(15), "bold", nil, C.paperShadow)
  if note then
    ptext(tx, y + S(56), fit(note, inner - S(40), S(10)), noteCol or C.paperDim, S(10))
  end
  if help then
    local lines = {}
    if note then lines[1] = note end
    for _, l in ipairs(help[2]) do lines[#lines + 1] = l end
    g.hit(x0, y, inner, h, help[1], lines)
  end
end

------------------------------------------------------------------ Team & Links tab
local function drawTeam(g, y)
  local st, people, S, x0, inner = g.st, g.people, g.S, g.x0, g.inner

  -- at a glance: your next encounter and the level cap (a click opens the Routes tab)
  do
    local me = people[1]
    local nextKey = g.nextInfo()
    local cap = progress.caps(me.state.badges)[1]
    local hS = S(U.strip)
    cv.rbox(x0, y, inner, hS, S(9), C.strip, C.stripEdge, S(1.2))
    local ls, vs = S(9), S(11)
    local half = (inner - S(20)) / 2
    local function item(x, label, value, w)
      local lw = textW(label, ls, "bold")
      ptext(x, y + mid(hS, ls), label, C.faint, ls, "bold")
      stext(x + lw + S(7), y + mid(hS, vs), fit(value, w - lw - S(10), vs, "bold"), C.white, vs, "bold")
    end
    local nextText = not st.started and "once you have Poké Balls" or (nextKey and areaName(nextKey) or "every area used")
    item(x0 + S(12), "NEXT", nextText, half - S(8))
    if cap then item(x0 + S(12) + half, "CAP", "Lv " .. cap.lv .. "  " .. cap.name, half - S(8)) end
    ptext(x0 + inner - S(10), y + mid(hS, S(13)), "›", C.faint, S(13), "bold", "right")
    tabRects[#tabRects + 1] = { id = "routes", x = floor(x0), y = floor(y), w = floor(inner), h = floor(hS) }
    local lines = { "NEXT: the next new area. The first wild Pokémon you meet there is your encounter." }
    if cap then lines[#lines + 1] = "CAP: keep your Pokémon at Lv " .. cap.lv .. " or lower until you beat " .. cap.name .. "." end
    lines[#lines + 1] = "Click to see every area on the Routes tab."
    g.hit(x0, y, inner, hS, "Your next encounter and level cap", lines)
    y = y + hS + S(U.stripGap)
  end

  -- trainer cards: name, where they are, badges, level cap, and their party like the party screen
  for _, p in ipairs(people) do
    local st2 = p.state or {}
    local party = st2.party or {}
    local cap = progress.levelCap(st2.badges)
    local cardH = S(cardHeight(p))
    cv.rbox(x0, y, inner, cardH, S(12), C.plate, p.accent, S(2))
    local nameSize = S(12.5)
    local nameText = fit(p.name, inner * 0.4, nameSize, "bold") .. (p.me and "  (you)" or "")
    stext(x0 + S(14), y + S(7), nameText, C.white, nameSize, "bold")

    local right = x0 + inner - S(12)
    local is = S(10)
    if cap then
      local capText = "Cap Lv" .. cap
      local cw = textW(capText, is, "bold") + S(16)
      cv.rbox(right - cw, y + S(9), cw, S(21), S(10), C.capBg, C.capEdge, S(1.2))
      ptext(right - cw / 2, y + S(9) + mid(S(21), is), capText, C.capText, is, "bold", "center")
      right = right - cw - S(10)
    end
    local badges = math.min(8, st2.badges or 0)
    right = badgeCase(g, right, y + S(15), badges) - S(10)
    local room = right - (x0 + S(14) + textW(nameText, nameSize, "bold")) - S(8)
    if room > S(30) then
      local where = st2.area and areaName(st2.area) or "?"
      ptext(right, y + S(11), fit(where, room, is), C.dim, is, "regular", "right")
    end
    do
      local who = p.me and "You" or p.name
      local lines = {}
      if st2.area then lines[#lines + 1] = (p.me and "You are" or (p.name .. " is")) .. " on " .. areaName(st2.area) .. "." end
      lines[#lines + 1] = "Gym badges: " .. badges .. " of 8 (the gold dots)."
      if cap then lines[#lines + 1] = "Level cap " .. cap .. ": the strongest Pokémon of the next gym leader. Don't train past it." end
      g.hit(x0, y, inner, S(U.cardTop - 4), who, lines)
    end

    if #party == 0 then
      ptext(x0 + S(14), y + S(U.cardTop + 3), "No Pokémon yet", C.faint, S(10))
    else
      local slotW = (inner - S(16)) / 6
      local sh = S(U.cardParty - 10)
      local sy = y + S(U.cardTop)
      for k = 1, 6 do
        local m = party[k]
        local sx = x0 + S(8) + (k - 1) * slotW
        local w = slotW - S(5)
        if not m then
          cv.rbox(sx, sy, w, sh, S(8), C.slotEmpty, C.slotEmptyEdge, S(1.2))
        elseif m.egg then
          cv.rbox(sx, sy, w, sh, S(8), C.slot, C.slotEdge, S(1.5))
          ptext(sx + w / 2, sy + mid(sh, S(10)), "Egg", C.dim, S(10), "regular", "center")
          g.hit(sx, sy, w, sh, "Egg", { "Eggs don't count as encounters." })
        else
          local dead = (m.hp or 0) == 0
          local over = cap and m.lv and m.lv > cap
          local fill = dead and C.slotDead or C.slot
          cv.rbox(sx, sy, w, sh, S(8), fill, dead and C.slotDeadEdge or (over and C.warn or C.slotEdge), S(1.5))
          local r = g.linkNo(p, m)
          local function tag() if r then g.tag(r, sx - S(6), sy - S(8), S(18)) end end
          if not g.mon(m.sp, sx + S(4), sy + S(4), w - S(8), S(50), fill, { still = dead, after = tag, shiny = m.sh, female = m.f }) then
            ptext(sx + w / 2, sy + S(22), fit(game.speciesName(m.sp), w - S(8), S(9), "bold"), C.text, S(9), "bold", "center")
          end
          tag()
          local ly = sy + S(57)
          stext(sx + S(6), ly, "Lv" .. (m.lv or "?"), dead and C.badText or (over and C.warn or C.white), S(10), "bold")
          local rx = sx + w - S(6)
          if dead then
            chip(g, rx - S(14), ly + S(2), S(28), S(13), "FNT", C.bad, S(7.5))
          elseif over then
            ptext(rx, ly + S(2.5), "over cap", C.warn, S(7.5), "bold", "right")
          else
            ptext(rx, ly + S(2), (m.hp or 0) .. "/" .. (m.mhp or 0), C.dim, S(8.5), "bold", "right")
          end
          local f = (m.mhp and m.mhp > 0) and math.max(0, math.min(1, (m.hp or 0) / m.mhp)) or 0
          hpBar(g, sx + S(5), sy + sh - S(15), w - S(10), f)
          -- what it is and who it's linked with
          local species = game.speciesName(m.sp)
          local title = (m.nick and m.nick ~= "" and m.nick ~= species) and (m.nick .. " (" .. species .. ")") or species
          if m.sh then title = title .. ", shiny" end
          local lines = { "Lv " .. (m.lv or "?") .. "   HP " .. (m.hp or 0) .. "/" .. (m.mhp or 0) }
          if dead then lines[#lines + 1] = "Fainted, so in a Nuzlocke it's dead. Box it." end
          if over then lines[#lines + 1] = "Over the level cap (" .. cap .. "): don't train it more until the next gym." end
          local grp = r and st.groups[r]
          if grp then
            lines[#lines + 1] = "Link " .. r .. " (" .. areaName(grp.key) .. "): " .. g.partners(grp, p)
          else
            lines[#lines + 1] = "Not linked (from before the Poké Balls, or not a first encounter)."
          end
          g.hit(sx, sy, w, sh, title, lines)
        end
      end
    end
    y = y + cardH + S(U.cardGap)
  end

  -- links table
  y = y + S(U.linksGap)
  heading(g, x0, y, "LINKS")
  do
    local sub = st.started and "Same number = linked. If one faints, its partners are out too."
      or "Links start once you have Poké Balls."
    ptext(x0 + S(96), y + S(3), fit(sub, inner - S(96), S(10)), st.started and C.faint or C.wait, S(10))
  end
  y = y + S(U.linksTitle)
  local areaW, chipW = S(136), S(84)
  local colW = (inner - areaW - chipW) / math.max(1, #people)
  local headSize = S(10)
  for i, p in ipairs(people) do
    stext(x0 + areaW + (i - 1) * colW - S(4), y, fit(p.name, colW - S(8), headSize, "bold"), p.accent, headSize, "bold")
  end
  y = y + S(U.linksHead)

  -- room left for rows after the rule problems and (a few) events
  local nWarn = math.min(5, #st.warnings)
  local evShow = math.min(5, #st.events)
  local tail = function(ne) return (nWarn > 0 and S(8 + nWarn * U.warn) or 0) + (ne > 0 and S(8 + ne * U.event) or 0) + S(U.bottom) end
  local rowH = S(U.row)
  local rowsFit = floor((H - y - tail(evShow)) / rowH)
  while rowsFit < #st.groups and evShow > 2 do
    evShow = evShow - 1
    rowsFit = floor((H - y - tail(evShow)) / rowH)
  end
  local groups, hidden = st.groups, 0
  if rowsFit < #groups then
    -- not all fit: the newest links, with a note about the earlier ones
    hidden = #groups - math.max(1, rowsFit - 1)
    groups = {}
    for r = hidden + 1, #st.groups do groups[#groups + 1] = st.groups[r] end
    ptext(x0 + S(6), y + S(6), "+ " .. hidden .. " earlier link" .. (hidden == 1 and "" or "s")
      .. " (make the window taller to see all)", C.faint, S(10))
    y = y + rowH
  end
  local cellSize = S(11.5)
  local ph = rowH - S(5)
  for r, grp in ipairs(groups) do
    local fill = ((r + hidden) % 2 == 1) and C.plate or C.plate2
    cv.rbox(x0, y, inner, ph, S(9), fill, C.plateEdge, S(1.2))
    local num = r + hidden
    g.tag(num, x0 + S(8), y + (ph - S(24)) / 2, S(24))
    local ty = y + mid(ph, cellSize)
    ptext(x0 + S(40), ty, fit(areaName(grp.key), areaW - S(44), cellSize), C.text, cellSize)
    for i, p in ipairs(people) do
      local mem
      for _, m in ipairs(grp.members) do if m.name == p.name or (p.me and m.me) then mem = m end end
      local tx = x0 + areaW + (i - 1) * colW
      if mem then
        local col = (mem.st == "dead" and C.badText) or (mem.st == "failed" and C.warn)
          or (mem.st == "pending" and 0xFF7DB4FF) or C.text
        local label = game.speciesName(mem.sp)
        if mem.st == "dead" then label = label .. " †" elseif mem.st == "failed" then label = label .. " ×" end
        local has = g.mon(mem.sp, tx - S(4), y + S(3), S(36), ph - S(6), fill,
          { still = mem.st == "dead", shiny = mem.sh, female = mem.f })
        -- narrow columns (many players): the picture alone says enough
        if not has or colW >= S(90) then
          local lx = tx + (has and S(36) or 0)
          ptext(lx, ty, fit(label, colW - (lx - tx) - S(4), cellSize), col, cellSize)
        elseif mem.st == "dead" or mem.st == "failed" then
          ptext(tx + S(33), ty, mem.st == "dead" and "†" or "×", col, cellSize, "bold")
        end
      else
        ptext(tx + S(8), ty, "-", C.faint, cellSize)
      end
    end
    local stt = STATUS[grp.status] or { grp.status or "", C.dim }
    chip(g, x0 + inner - chipW / 2 - S(2), y + (ph - S(24)) / 2, chipW - S(14), S(24), stt[1], stt[2])
    g.hit(x0, y, inner, ph, "Link " .. num .. ": " .. areaName(grp.key) .. "  (" .. stt[1]:lower() .. ")", g.linkLines(grp))
    y = y + rowH
  end
  if st.started and #st.groups == 0 then
    ptext(x0 + S(6), y + S(6), "No encounters yet. Catch the first wild Pokémon in each new area.", C.faint, S(10.5))
    y = y + rowH
  end

  -- rule problems
  if nWarn > 0 then y = y + S(8) end
  local warnSize = S(10.5)
  for k = 1, nWarn do
    local w = st.warnings[k]
    local bad = w.lvl == "bad"
    local h = S(U.warn - 5)
    cv.rbox(x0, y, inner, h, S(9), bad and C.warnBg or C.infoBg, bad and C.warnEdge or C.infoEdge, S(1.5))
    local d = S(18)
    local col = bad and C.bad or C.wait
    cv.circle(x0 + S(8), y + (h - d) / 2, d, col)
    ptext(x0 + S(8) + d / 2, y + (h - d) / 2 + mid(d, S(9)), "!", C.white, S(9), "bold", "center")
    ptext(x0 + S(34), y + mid(h, warnSize), fit(w.t, inner - S(44), warnSize), bad and C.badText or 0xFF8CBCFF, warnSize)
    g.hit(x0, y, inner, h, bad and "Rule problem" or "Heads-up", { w.t })
    y = y + S(U.warn)
  end

  -- recent events (newest first)
  if evShow > 0 then y = y + S(8) end
  local ev = st.events
  local evSize = S(10)
  for i = #ev, math.max(1, #ev - evShow + 1), -1 do
    if y + S(U.event) > H then break end
    local e = ev[i]
    local col = e.kind == "bad" and C.warn or (e.kind == "good" and C.good or C.dim)
    cv.circle(x0 + S(2), y + S(7), S(6), col)
    ptext(x0 + S(14), y, fit(e.text, inner - S(16), evSize), col, evSize)
    g.hit(x0, y - S(2), inner, S(U.event), "What just happened", { e.text })
    y = y + S(U.event)
  end
  return y
end

------------------------------------------------------------------ Routes tab
local function drawRoutes(g, y)
  local st, people, S, x0, inner = g.st, g.people, g.S, g.x0, g.inner
  local me = people[1]
  local nextKey, behind, list, used = g.nextInfo()

  -- next encounter, with a warning when that area's link is already lost
  local note, noteCol
  local grpNext = nextKey and g.groupOf[nextKey]
  if grpNext and (grpNext.status == "broken" or grpNext.status == "dead") then
    local who
    for _, m in ipairs(grpNext.members) do if (m.st == "failed" or m.st == "dead") and not m.me then who = m.name end end
    note = (who or "Someone") .. (grpNext.status == "dead" and " lost their Pokémon from here" or " missed their encounter here")
      .. ", so your catch here can't be used."
    noteCol = C.paperBad
  elseif #behind > 0 then
    local names = {}
    for i = 1, math.min(#behind, 4) do names[#names + 1] = areaName(behind[i]) end
    note = "Still open behind you: " .. table.concat(names, ", ") .. (#behind > 4 and (" +" .. (#behind - 4)) or "")
    noteCol = C.paperWarn
  end
  local h1 = S(note and U.infoBox or U.infoBox - 22)
  textBox(g, y, h1, 0xFF5C9CF0, st.started and "NEXT ENCOUNTER" or "NEXT ENCOUNTER (once you have Poké Balls)",
    nextKey and areaName(nextKey) or "Every area is used", note, noteCol, {
      "Next encounter",
      { "Only the first wild Pokémon you meet in each new area counts. Catch it, or that area is used up.",
        "Soul Link: everyone's catch from the same area is linked.",
        "Areas you skipped stay open and still count." } })
  y = y + h1 + S(8)

  -- level cap
  local caps = progress.caps(me.state.badges)
  if caps[1] then
    local over = {}
    for _, m in ipairs(me.state.party or {}) do
      if not m.egg and m.lv and m.lv > caps[1].lv then over[#over + 1] = (m.nick or game.speciesName(m.sp)) .. " Lv" .. m.lv end
    end
    local then_ = {}
    for i = 2, #caps do then_[#then_ + 1] = caps[i].name .. " Lv" .. caps[i].lv end
    local note2, col2 = caps[1].where .. (#then_ > 0 and ("   ·   then " .. table.concat(then_, ", ")) or ""), C.paperDim
    if #over > 0 then note2, col2 = "Over the cap: " .. table.concat(over, ", "), C.paperBad end
    local h2 = S(U.infoBox)
    textBox(g, y, h2, 0xFFF0A030, "LEVEL CAP", "Lv " .. caps[1].lv .. "   " .. caps[1].name, note2, col2, {
      "Level cap",
      { "Don't train your Pokémon past the level of the next gym leader's (or boss's) strongest Pokémon.",
        "The levels are read from your own game, so they're right for randomized games too." } })
    y = y + h2 + S(12)
  end

  -- the area list
  -- the area column takes what the player columns don't need (long names like Driftveil Drawbridge)
  local chipW = S(80)
  local areaW = math.max(S(150), math.min(S(205), inner - chipW - #people * S(72)))
  local colW = (inner - areaW - chipW) / math.max(1, #people)
  local headSize = S(10)
  stext(x0 + S(10), y, "AREA", C.dim, headSize, "bold")
  for i, p in ipairs(people) do
    stext(x0 + areaW + (i - 1) * colW - S(4), y, fit(p.name, colW - S(8), headSize, "bold"), p.accent, headSize, "bold")
  end
  y = y + S(U.linksHead)

  -- rows: the story areas, then (once you get there) the areas after the story
  local furthest, lastStory = 0, 0
  for i, a in ipairs(list) do
    if not a.post then lastStory = i end
    if used[a.key] then furthest = i end
  end
  local showPost = furthest >= lastStory - 1
  local rows, postCount = {}, 0
  for _, a in ipairs(list) do
    if a.post and not showPost and not used[a.key] then postCount = postCount + 1
    else
      if a.post and (#rows == 0 or not rows[#rows].post) then rows[#rows + 1] = { sep = "AFTER THE STORY", post = true } end
      rows[#rows + 1] = a
    end
  end
  if postCount > 0 then rows[#rows + 1] = { sep = "+ " .. postCount .. " more areas after the story", post = true } end

  -- not all fit: a window around the next area
  local rowH = S(U.routeRow)
  local fit_ = math.max(3, floor((H - y - S(U.bottom)) / rowH))
  local focus = 1
  for i, r in ipairs(rows) do if r.key == nextKey then focus = i end end
  local first, last = 1, #rows
  if #rows > fit_ then
    first = math.max(1, focus - 4)
    last = first + fit_ - 1
    if last > #rows then last = #rows; first = math.max(1, last - fit_ + 1) end
    if first > 1 then first = first + 1 end          -- room for the "earlier" note
    if last < #rows then last = last - 1 end         -- room for the "more" note
  end
  if first > 1 then
    ptext(x0 + S(10), y + S(9), "+ " .. (first - 1) .. " earlier areas", C.faint, S(10))
    y = y + rowH
  end
  local cellSize = S(11)
  local ph = rowH - S(4)
  local here = me.state.area
  for i = first, last do
    local a = rows[i]
    if a.sep then
      pokeball(x0 + S(10), y + S(11), S(14))
      ptext(x0 + S(30), y + S(10), a.sep, C.faint, S(9.5), "bold")
    else
      local isNext = a.key == nextKey
      local anyEnc = false
      for _, p in ipairs(people) do if (p.state.enc or {})[a.key] then anyEnc = true end end
      local fill = isNext and C.nextBg or ((i % 2 == 1) and C.plate or C.plate2)
      if isNext then cv.rbox(x0, y, inner, ph, S(9), fill, C.red, S(2))
      else cv.rbox(x0, y, inner, ph, S(9), fill, C.plateEdge, S(1.2)) end
      local ty = y + mid(ph, cellSize)
      local r = g.linkIndex[a.key]
      if r then g.tag(r, x0 + S(10), y + (ph - S(22)) / 2, S(22)) end
      local name = areaName(a.key)
      local nx = x0 + S(40)
      if a.key == here then
        stext(nx, ty, "▶", people[1].accent, cellSize, "bold")
        nx = nx + S(16)
      end
      local nameW = areaW - (nx - x0) - S(6)
      if isNext then stext(nx, ty, fit(name, nameW, cellSize, "bold"), C.white, cellSize, "bold")
      else ptext(nx, ty, fit(name, nameW, cellSize), anyEnc and C.text or C.dim, cellSize) end
      if anyEnc then
        for pi, p in ipairs(people) do
          local e = (p.state.enc or {})[a.key]
          local tx = x0 + areaW + (pi - 1) * colW
          if e then
            local col = (e.st == "dead" and C.badText) or (e.st == "failed" and C.warn) or (e.st == "pending" and 0xFF7DB4FF) or C.text
            local has = g.mon(e.sp, tx - S(4), y + S(3), S(32), ph - S(6), fill,
              { still = e.st == "dead", shiny = e.sh, female = e.f })
            local mark = (e.st == "dead" and " †") or (e.st == "failed" and " ×") or ""
            if not has or colW >= S(90) then
              local lx = tx + (has and S(32) or 0)
              ptext(lx, ty, fit(game.speciesName(e.sp) .. mark, colW - (lx - tx) - S(4), cellSize), col, cellSize)
            elseif mark ~= "" then
              ptext(tx + S(29), ty, mark, col, cellSize, "bold")
            end
          else
            ptext(tx + S(8), ty, "-", C.faint, cellSize)
          end
        end
      end
      local grp = g.groupOf[a.key]
      local cx = x0 + inner - chipW / 2 - S(2)
      local cy, chh = y + (ph - S(22)) / 2, S(22)
      local title, lines = name, {}
      if grp then
        local stt = STATUS[grp.status] or { grp.status or "", C.dim }
        chip(g, cx, cy, chipW - S(12), chh, stt[1], stt[2])
        title = "Link " .. r .. ": " .. name .. "  (" .. stt[1]:lower() .. ")"
        lines = g.linkLines(grp)
      elseif isNext then
        chip(g, cx, cy, chipW - S(12), chh, "NEXT", C.red)
        lines = { "Your next new area: the first wild Pokémon you meet here is your encounter." }
      else
        ptext(cx, y + mid(ph, S(9.5)), a.water and "surf/fish" or "open", C.faint, S(9.5), "regular", "center")
        lines = { a.water and "Only surfing or fishing encounters here: you'll need Surf or a fishing rod."
          or "Nobody has an encounter here yet." }
      end
      if a.key == here then table.insert(lines, 1, "You are here.") end
      g.hit(x0, y, inner, ph, title, lines)
    end
    y = y + rowH
  end
  if last < #rows then
    ptext(x0 + S(10), y + S(9), "+ " .. (#rows - last) .. " more areas (make the window taller to see all)", C.faint, S(10))
    y = y + rowH
  end
  return y
end

------------------------------------------------------------------ Graveyard tab
local function drawGraves(g, y)
  local S, x0, inner = g.S, g.x0, g.inner
  local graves = g.graves
  heading(g, x0, y, "GRAVEYARD")
  if #graves > 0 then
    ptext(x0 + inner, y + S(2), #graves .. " Pokémon lost", C.faint, S(10), "regular", "right")
  end
  y = y + S(34)
  if #graves == 0 then
    ptext(x0 + inner / 2, y + S(30), "No deaths yet. Keep it that way!", C.faint, S(12), "regular", "center")
    return y + S(60)
  end
  local rowH = S(U.grave)
  local fit_ = math.max(1, floor((H - y - S(U.bottom)) / rowH))
  local shown = math.min(#graves, #graves > fit_ and fit_ - 1 or fit_)
  for i = 1, shown do
    local d = graves[i]
    local h = rowH - S(6)
    cv.rbox(x0, y, inner, h, S(11), C.grave, shade(d.owner.accent, 0.55), S(1.5))
    -- a gravestone with the Pokémon on it
    local gw = S(46)
    local gx, gy = x0 + S(12), y + S(5)
    local gh = h - S(10)
    cv.circle(gx, gy, gw, C.stone)
    cv.box(gx, gy + gw / 2, gw, gh - gw / 2 - S(4), C.stone)
    cv.rbox(gx - S(4), gy + gh - S(6), gw + S(8), S(6), S(2), C.stoneDark)
    g.mon(d.sp, gx + S(3), gy + S(4), gw - S(6), gh - S(11), C.stone, { still = true, shiny = d.sh, female = d.f })
    local r = d.area and g.linkIndex[d.area]
    if r then g.tag(r, gx - S(6), y + S(2), S(18)) end
    local tx = x0 + S(70)
    local species = game.speciesName(d.sp)
    local title = d.nick and d.nick ~= species and (d.nick .. "  (" .. species .. ")") or species
    local ownerW = textW(d.owner.name, S(10.5), "bold")
    stext(tx, y + S(7), fit(title, inner - S(90) - ownerW, S(12), "bold") .. "  †", C.white, S(12), "bold")
    stext(x0 + inner - S(12), y + S(9), fit(d.owner.name, inner * 0.3, S(10.5), "bold"), d.owner.accent, S(10.5), "bold", "right")
    local bits = {}
    if d.lv then bits[#bits + 1] = "Lv " .. d.lv end
    if d.area then bits[#bits + 1] = (d.area == "starter" and "the starter" or ("caught on " .. areaName(d.area))) end
    if d.at then bits[#bits + 1] = "died on " .. areaName(d.at) end
    local details = table.concat(bits, "  ·  ")
    ptext(tx, y + S(32), fit(details, inner - S(80), S(10)), C.dim, S(10))
    local lines = { (d.owner.me and "Yours" or (d.owner.name .. "'s")) .. ". " .. details .. "." }
    if r then lines[#lines + 1] = "It was link " .. r .. ", so its partners from there are out too." end
    g.hit(x0, y, inner, h, title .. (d.sh and ", shiny" or ""), lines)
    y = y + rowH
  end
  if shown < #graves then
    ptext(x0 + S(10), y + S(6), "+ " .. (#graves - shown) .. " more (make the window taller to see all)", C.faint, S(10))
    y = y + S(30)
  end
  return y
end

------------------------------------------------------------------ the panel
-- st: status, me = {name, state}, remotes, groups, players, warnings, events, started
local function drawPanel(st)
  if mode == "window" and not form then return end
  if mode == "docked" then hud.drawDocked(st); return end
  lastState = st
  local resized = checkSize()
  if W < 120 or H < 120 then return end -- minimized

  -- everyone in a fixed order: you first, then the others by name (the test buddy isn't shown)
  local people = { { name = st.me and st.me.name or "You", state = st.me and st.me.state or {}, me = true } }
  local others = {}
  for _, p in pairs(st.remotes) do
    if not p.test then others[#others + 1] = { name = p.name or "?", state = p.state or {} } end
  end
  table.sort(others, function(a, b) return a.name < b.name end)
  for _, p in ipairs(others) do people[#people + 1] = p end
  for i, p in ipairs(people) do p.accent = PLAYER_COLORS[(i - 1) % #PLAYER_COLORS + 1] end

  -- skip the redraw when nothing visible changed (drawing text in a window is slow)
  local sig = json.encode({ tab, st.status, people, st.groups, st.warnings, st.events, st.started })
  if sprites.changed then sprites.changed = false; lastSig = nil end -- a new battle sprite is ready
  if sig == lastSig and not resized then hud.animate(); return end
  lastSig = sig
  anims = {}
  hits = {}
  local t0 = os.clock()

  -- links are numbered in the order they were made; each player's Pokemon -> its link number
  local linkOf, linkIndex, groupOf = {}, {}, {}
  for r, grp in ipairs(st.groups) do
    linkIndex[grp.key] = r
    groupOf[grp.key] = grp
    for _, m in ipairs(grp.members) do
      if m.pid then linkOf[(m.me and "\1me" or m.name) .. "|" .. m.pid] = r end
    end
  end

  -- everyone's dead Pokémon, newest first
  local graves = {}
  for _, p in ipairs(people) do
    local list = p.state.graves
    if list then
      for _, d in ipairs(list) do
        graves[#graves + 1] = { sp = d.sp, nick = d.nick, lv = d.lv, area = d.area, at = d.at, t = d.t or 0, owner = p, sh = d.sh, f = d.f }
      end
    else -- older versions only share which encounters died
      for k, e in pairs(p.state.enc or {}) do
        if e.st == "dead" then graves[#graves + 1] = { sp = e.sp, area = k, t = 0, owner = p, sh = e.sh, f = e.f } end
      end
    end
  end
  table.sort(graves, function(a, b) return a.t > b.t end)

  -- scale: as big as the window's width allows, smaller if the team page wouldn't fit the height
  local nWarn = math.min(5, #st.warnings)
  local nEv = math.min(5, #st.events)
  local need = U.header + U.tabTop + U.tabs + U.tabGap + U.strip + U.stripGap + U.linksGap + U.linksTitle + U.linksHead
    + math.max(1, #st.groups) * U.row
    + (nWarn > 0 and (8 + nWarn * U.warn) or 0) + (nEv > 0 and (8 + nEv * U.event) or 0) + U.bottom
  for _, p in ipairs(people) do need = need + cardHeight(p) + U.cardGap end
  local sW = W / BASE_W
  local s = math.min(sW, H / need)
  s = math.max(s, math.min(sW, 0.9 * dpi)) -- not smaller than this: show fewer rows instead
  local function S(v) return v * s end

  local g = {
    st = st, people = people, S = S, s = s, linkIndex = linkIndex, groupOf = groupOf, graves = graves,
  }
  g.x0 = S(U.pad)
  g.inner = W - 2 * g.x0
  function g.linkNo(p, m) return linkOf[(p.me and "\1me" or p.name) .. "|" .. tostring(m.pid)] end
  -- a Pokémon's battle sprite fitted into a box, standing on its bottom edge, and moving like in
  -- battle unless still. bg = the colour under the box (painted over between poses), after = drawn
  -- again on top after each pose. Falls back to the small icon while the sprite is being made.
  -- opt: still, shiny, female (their own colours / look), after
  function g.mon(sp, x, y, w, h, bg, opt)
    opt = opt or {}
    local function shinyStar()
      if not opt.shiny then return end
      local r = math.max(4, math.min(w, h) * 0.15)
      local cx, cy = x + w - r, y + r
      star(cx, cy, r + math.max(1, S(1.2)), C.ink)
      star(cx, cy, r, C.gold)
    end
    local e = sprites.get(sp, opt.shiny, opt.female)
    if e then
      local k = math.min(w / e.fw, h / e.fh, 1)
      local dw, dh = math.max(1, floor(e.fw * k + 0.5)), math.max(1, floor(e.fh * k + 0.5))
      local dx, dy = floor(x + (w - dw) / 2 + 0.5), floor(y + h - dh + 0.5)
      local pose = opt.still and 0 or sprites.pose(e, emu.framecount())
      cv.region(e.path, pose * e.fw, 0, e.fw, e.fh, dx, dy, dw, dh)
      shinyStar()
      if not opt.still then
        local after = opt.after
        anims[#anims + 1] = { e = e, x = dx, y = dy, w = dw, h = dh, bg = bg, pose = pose,
          after = function() shinyStar(); if after then after() end end }
      end
      return true
    end
    local ic = icons.path(sp)
    if not ic then return false end
    local iz = math.min(w, h) * 1.15
    cv.image(ic, x + (w - iz) / 2, y + h - iz * 0.95, iz, iz)
    shinyStar()
    return true
  end
  -- a link's number in a coloured circle
  function g.tag(r, x, y, d)
    local col = LINK_COLORS[(r - 1) % #LINK_COLORS + 1]
    local o = math.max(1, floor(d * 0.09 + 0.5))
    cv.circle(x, y, d, C.ink)
    cv.circle(x + o, y + o, d - 2 * o, col)
    ptext(x + d / 2, y + mid(d, d * 0.44), tostring(r), C.ink, d * 0.44, "bold", "center")
  end
  -- an area that explains itself when the mouse is over it
  function g.hit(x, y, w, h, title, lines)
    hits[#hits + 1] = { id = string.format("%d,%d,%d,%d", floor(x), floor(y), floor(w), floor(h)),
      x = x, y = y, w = w, h = h, title = title, lines = lines or {} }
  end
  -- a link explained: everyone's part in it, then what its state means
  function g.linkLines(grp)
    local lines = {}
    for _, p in ipairs(people) do
      local mem
      for _, m in ipairs(grp.members) do if m.name == p.name or (p.me and m.me) then mem = m end end
      local who = p.me and "You" or p.name
      if mem then
        local what = game.speciesName(mem.sp)
        if mem.was and mem.was ~= mem.sp then what = what .. " (caught as " .. game.speciesName(mem.was) .. ")" end
        lines[#lines + 1] = who .. ": " .. what .. ", " .. (MEMBER_WORD[mem.st] or tostring(mem.st))
      else
        lines[#lines + 1] = who .. ": no encounter here yet"
      end
    end
    lines[#lines + 1] = g.statusText(grp)
    return lines
  end
  -- what a link's state means, naming who missed or lost theirs
  function g.statusText(grp)
    for _, m in ipairs(grp.members) do
      local who = m.me and "You" or m.name
      if grp.status == "dead" and m.st == "dead" then
        return who .. (m.me and " lost " or " lost ") .. game.speciesName(m.sp) .. ", so its partners must be boxed too."
      elseif grp.status == "broken" and m.st == "failed" then
        return who .. " missed the encounter here, so none of these may be used. Box them."
      end
    end
    return STATUS_HELP[grp.status] or ""
  end
  -- who a party Pokémon is linked with
  function g.partners(grp, owner)
    local others = {}
    for _, m in ipairs(grp.members) do
      local mine = (owner.me and m.me) or (not owner.me and not m.me and m.name == owner.name)
      if not mine then others[#others + 1] = game.speciesName(m.sp) .. " (" .. (m.me and "you" or m.name) .. ")" end
    end
    local s = #others > 0 and ("with " .. table.concat(others, ", ")) or "the others haven't caught theirs yet"
    return s .. ". " .. g.statusText(grp)
  end
  -- your next new area (and the areas you skipped), from the story order
  function g.nextInfo()
    local used = {}
    for _, p in ipairs(people) do for k in pairs(p.state.enc or {}) do used[k] = true end end
    local list = progress.areas(used)
    local nextKey, behind = progress.next(list, people[1].state.enc or {})
    return nextKey, behind, list, used
  end
  local x0, inner = g.x0, g.inner

  cv.begin()
  -- the striped background of the games' menus
  local band = math.max(2, floor(S(3)))
  for yy = 0, H, band * 2 do cv.box(0, yy, W, band, C.bg2) end

  -- header: Pokédex red, a Poké Ball, the title in the logo's colours and a status light
  local hb = S(U.header)
  cv.box(0, 0, W, hb, C.red)
  cv.box(0, 0, W, S(3), C.redLight)
  cv.box(0, hb - S(8), W, S(6), C.redDark)
  cv.box(0, hb - S(2), W, S(2) + 1, C.ink)
  local inside = hb - S(8)
  local bd = floor(S(40))
  local by = floor((inside - bd) / 2 + S(1))
  pokeball(x0 - S(2), by, bd, true)
  local lh = floor(S(31))
  local logo, info = artFile("logo_", LOGO_SIZES, lh)
  local tx = x0 + bd + S(10)
  if logo then
    cv.image(logo, tx, floor((inside - lh) / 2 + S(2)), floor(lh * info.w / info.h + 0.5), lh)
  else
    stext(tx, (inside - S(19) * 1.75) / 2, "SOUL LINK", C.logo, S(19), "regular", nil, C.logoEdge, FONT_LOGO)
  end

  local pillSize = S(9.5)
  local pill = clip(st.status or "", fits(inner * 0.44, pillSize, true))
  local led = S(14)
  local pw = cv.measure(pill, pillSize, "bold") + led + S(26)
  local pH = S(28)
  local px, py = W - x0 - pw, (inside - pH) / 2 + S(1)
  cv.rbox(px, py, pw, pH, pH / 2, C.screen, C.ink, S(2))
  local pc = statusPill(st.status)
  local ly = py + (pH - led) / 2
  cv.circle(px + S(8), ly, led, shade(pc, 0.55))
  cv.circle(px + S(9.5), ly + S(1.5), led - S(3), pc)
  cv.circle(px + S(11), ly + S(3), led * 0.3, 0xD0FFFFFF)
  stext(px + S(8) + led + S(8), py + mid(pH, pillSize), pill, C.white, pillSize, "bold")
  do
    local s0 = (st.status or ""):lower()
    local why = s0:find("test") and "Try-it-alone mode: the Test Buddy copies your steps. Nobody else is connected."
      or "How the connection to the other players is doing."
    g.hit(px, py, pw, pH, st.status or "", { why })
  end

  -- tabs, like menu buttons (the chosen one red with a Poké Ball)
  local y = hb + S(U.tabTop)
  local tabs = {
    { id = "team", label = "Team & Links" },
    { id = "routes", label = "Routes" },
    { id = "graves", label = "Graveyard" .. (#graves > 0 and ("  (" .. #graves .. ")") or "") },
  }
  tabRects = {}
  local tw = inner / #tabs
  local th = S(U.tabs)
  for i, t in ipairs(tabs) do
    local tx2 = x0 + (i - 1) * tw
    local active = t.id == tab
    local bx, bw = tx2 + S(3), tw - S(6)
    local ls = S(11)
    local cx = tx2 + tw / 2
    if active then
      cv.rbox(bx, y, bw, th, th / 2, C.red, C.redDark, S(2))
      local lw = cv.measure(t.label, ls, "bold")
      local d = S(16)
      cx = cx + (d + S(6)) / 2
      pokeball(cx - lw / 2 - d - S(6), y + (th - d) / 2, d)
      stext(cx, y + mid(th, ls), t.label, C.white, ls, "bold", "center", C.redDark)
    else
      cv.rbox(bx, y, bw, th, th / 2, C.plate, C.plateEdge, S(1.5))
      ptext(cx, y + mid(th, ls), t.label, C.dim, ls, "regular", "center")
    end
    tabRects[#tabRects + 1] = { id = t.id, x = floor(tx2), y = floor(y), w = floor(tw), h = floor(th) }
    local th_ = TAB_HELP[t.id]
    if th_ then g.hit(tx2, y, tw, th, th_[1], th_[2]) end
  end
  y = y + th + S(U.tabGap)

  local endY
  if tab == "routes" then endY = drawRoutes(g, y)
  elseif tab == "graves" then endY = drawGraves(g, y)
  else endY = drawTeam(g, y) end
  if endY and endY + S(36) < H then
    ptext(W / 2, H - S(24), "Point at anything to see what it means.", C.faint, S(9.5), "regular", "center")
  end

  -- the explanation for what the mouse is over
  tipRect = nil
  local tip
  if hover then
    for _, h in ipairs(hits) do if h.id == hover.id then tip = h end end
    if not tip then hover = nil end
  end
  if tip then
    local maxW = math.min(inner, S(340))
    local ts, ls, lh, pad = S(11), S(10), S(15.5), S(10)
    local body = {}
    for _, l in ipairs(tip.lines) do
      for _, w in ipairs(wrap(l, maxW - 2 * pad, ls)) do body[#body + 1] = w end
    end
    local tw2 = textW(tip.title, ts, "bold")
    for _, l in ipairs(body) do tw2 = math.max(tw2, textW(l, ls)) end
    local w = math.min(maxW, tw2 + 2 * pad)
    local h = 2 * pad + S(15) + #body * lh
    local x, yy = hover.x + S(14), hover.y + S(20)
    if x + w > W - S(6) then x = math.max(S(6), hover.x - w - S(10)) end
    if yy + h > H - S(6) then yy = math.max(S(6), hover.y - h - S(12)) end
    cv.rbox(x + S(2), yy + S(3), w, h, S(9), 0x70000000)
    cv.rbox(x, yy, w, h, S(9), C.tipBg, C.tipEdge, S(1.5))
    stext(x + pad, yy + pad - S(2), fit(tip.title, w - 2 * pad, ts, "bold"), C.white, ts, "bold")
    local ly2 = yy + pad + S(16)
    for _, l in ipairs(body) do
      ptext(x + pad, ly2, l, C.dim, ls)
      ly2 = ly2 + lh
    end
    tipRect = { x = x, y = yy, w = w + S(3), h = h + S(4) }
  end
  cv.finish()
  drawMs = floor((os.clock() - t0) * 1000 + 0.5)
end

-- the message of a (.NET) error, with what caused it
local function describe(err)
  local ok, s = pcall(function()
    local parts, e = {}, err
    while e ~= nil and #parts < 4 do
      local m = type(e) == "userdata" and e.Message or nil
      parts[#parts + 1] = tostring(m or e)
      e = type(e) == "userdata" and e.InnerException or nil
    end
    return table.concat(parts, " / ")
  end)
  return ok and s or tostring(err)
end

-- if Windows' drawing ever fails, switch to BizHawk's own for good (hud.debug() says why)
local function safely(f, ...)
  local ok, err = pcall(f, ...)
  if ok then return end
  if not (cv and cv.smooth) then error(err, 0) end
  hud.smoothError = describe(err)
  print("Soul Link panel: smooth drawing failed, using BizHawk's drawing (" .. hud.smoothError .. ")")
  cv = windowCanvas()
  anims = {}
  lastSig = nil
end

-- BizHawk's Lua Console is hidden a moment after Soul Link starts, when the launcher asks for it
-- (Tools > Lua Console shows it again; the script keeps running). It's done from inside BizHawk:
-- a program hiding another program's window looks like malware to antivirus "behaviour" checks.
local consoleHideAt, consoleDone = nil, false
local function hideLuaConsole()
  if consoleDone then return end
  if os.getenv("SOULLINK_HIDE_CONSOLE") ~= "1" then consoleDone = true; return end
  local f = emu.framecount()
  consoleHideAt = consoleHideAt or f + 90   -- (about 1.5 seconds: let the script finish starting)
  if f < consoleHideAt then return end
  consoleDone = true
  local console = bizhawkForm("LuaConsole")
  if console then pcall(function() console:Hide() end) end
end

function hud.draw(st)
  hideLuaConsole()
  safely(drawPanel, st)
end

-- step the battle animations: only the Pokémon whose pose changed are drawn again
local function animate()
  if mode ~= "window" or not form or #anims == 0 then return end
  local fc = emu.framecount()
  local any = false
  for _, a in ipairs(anims) do
    local pose = sprites.pose(a.e, fc)
    local under = tipRect and a.x < tipRect.x + tipRect.w and tipRect.x < a.x + a.w
      and a.y < tipRect.y + tipRect.h and tipRect.y < a.y + a.h
    if pose ~= a.pose and not under then
      a.pose = pose
      cv.box(a.x, a.y, a.w, a.h, a.bg)
      cv.region(a.e.path, pose * a.e.fw, 0, a.e.fw, a.e.fh, a.x, a.y, a.w, a.h)
      if a.after then a.after() end
      any = true
    end
  end
  if any then cv.finish() end
end
function hud.animate() safely(animate) end

-- which explained area the mouse is over; redraws with its explanation when that changes
local hoverTick = 0
local function pollHover()
  if not pic or not lastState then return end
  local ok, mx, my = pcall(function() return forms.getMouseX(pic), forms.getMouseY(pic) end)
  if not ok or not mx or not my then return end
  local found
  if mx >= 0 and my >= 0 and mx < W and my < H then
    for i = #hits, 1, -1 do -- the last one drawn is on top
      local h = hits[i]
      if mx >= h.x and mx < h.x + h.w and my >= h.y and my < h.y + h.h then found = h; break end
    end
  end
  local id = found and found.id or nil
  if id ~= (hover and hover.id or nil) then
    hover = found and { id = id, x = mx, y = my } or nil
    lastSig = nil
    hud.draw(lastState)
  end
end

-- every frame the panel isn't fully redrawn: make battle sprites a bit at a time, animate, and
-- notice where the mouse is
function hud.tick()
  hideLuaConsole()
  if mode ~= "window" or not form then return end
  hoverTick = hoverTick + 1
  if hoverTick % 4 == 0 then pollHover() end
  sprites.work(4)
  if sprites.changed and lastState then
    pcall(hud.draw, lastState)
    return
  end
  hud.animate()
end

-- small text version beside the DS screens ("panel": "docked")
function hud.drawDocked(st)
  local y = 3
  local function line(s, col) cv.text(4, y, clip(s, 48), col); y = y + 10 end
  cv.begin()
  line("SOUL LINK  " .. (st.status or ""), C.text)
  for _, p in pairs(st.remotes) do
    if not p.test then
      local s = p.state or {}
      line((p.name or "?") .. "  " .. (s.area and game.locationName(tonumber(s.area) or -1) or ""), C.warn)
      for _, m in ipairs(s.party or {}) do
        line(string.format("  Lv%d %s %d/%d", m.lv or 0, game.speciesName(m.sp), m.hp or 0, m.mhp or 0),
          (m.hp == 0) and C.bad or C.text)
      end
    end
  end
  y = y + 4
  for _, g in ipairs(st.groups) do
    local s = STATUS[g.status] or { "", C.dim }
    local names = {}
    for _, m in ipairs(g.members) do names[#names + 1] = game.speciesName(m.sp) end
    line((g.key == "starter" and "Starter" or game.locationName(tonumber(g.key) or -1)) .. "  " .. s[1], s[2])
    line("  " .. table.concat(names, " / "), C.dim)
  end
  for _, w in ipairs(st.warnings) do line("! " .. w.t, w.lvl == "bad" and C.bad or C.wait) end
  cv.finish()
end

return hud
