local common = require "core.common"
local style = {}

style.divider_size = common.round(1 * SCALE)
style.scrollbar_size = common.round(4 * SCALE)
style.expanded_scrollbar_size = common.round(12 * SCALE)
style.minimum_thumb_size = common.round(20 * SCALE)
style.contracted_scrollbar_margin = common.round(8 * SCALE)
style.expanded_scrollbar_margin = common.round(12 * SCALE)
style.caret_width = common.round(2 * SCALE)
style.tab_width = common.round(170 * SCALE)

style.padding = {
  x = common.round(14 * SCALE),
  y = common.round(7 * SCALE),
}

style.margin = {
  tab = {
    top = common.round(-style.divider_size * SCALE)
  }
}

-- The function renderer.font.load can accept an option table as a second optional argument.
-- It shoud be like the following:
--
-- {antialiasing= "grayscale", hinting = "full"}
--
-- The possible values for each option are:
-- - for antialiasing: grayscale, subpixel
-- - for hinting: none, slight, full
--
-- Max XL ships with grayscale antialiasing and full hinting by default: this
-- keeps the text crisp without the colored fringes (red/blue) that subpixel
-- antialiasing always produces on LCD screens.
--
-- You can override this per font or from your user configuration. If you
-- prefer the sharper subpixel look and do not mind the fringes, use
-- {antialiasing="subpixel", hinting="slight"}.
local font_options = {antialiasing = "grayscale", hinting = "full"}
style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 15 * SCALE, font_options)
style.big_font = style.font:copy(46 * SCALE)
style.icon_font = renderer.font.load(DATADIR .. "/fonts/icons.ttf", 16 * SCALE, font_options)
style.icon_big_font = style.icon_font:copy(23 * SCALE)
style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 15 * SCALE, font_options)

style.syntax = {}

-- This can be used to override fonts per syntax group.
-- The syntax highlighter will take existing values from this table and
-- override style.code_font on a per-token basis, so you can choose to eg.
-- render comments in an italic font if you want to.
style.syntax_fonts = {}
-- style.syntax_fonts["comment"] = renderer.font.load(path_to_font, size_of_font, rendering_options)

style.log = {}

-- XXL sidebar panels (search, git, ...) resolve their colors through this
-- helper so color themes can rebrand them with a single table:
--
--   style.search = { accent = {...}, panel_bg = {...}, ... }
--
-- (full key list documented in plugins/searchpanel.lua). Every key falls
-- back to a core color, so existing themes keep working unchanged.
function style.panel_theme()
  local s = style.search or {}
  return {
    panel_bg  = s.panel_bg  or style.background2,
    field_bg  = s.field_bg  or style.background3,
    border    = s.border    or style.divider,
    focus     = s.focus     or style.accent,
    accent    = s.accent    or style.accent,
    header_bg = s.header_bg or style.accent,
    header_text = s.header_text or style.background,
    text      = s.text      or style.text,
    dim       = s.dim       or style.dim,
    selection = s.selection or style.selection,
    highlight = s.highlight or style.line_highlight,
    match     = s.match     or style.accent,
    caret     = s.caret     or style.caret or style.text,
    warn      = s.warn      or style.error or style.accent,
    terminal_bg = s.terminal_bg or { 0, 0, 0, 255 },
  }
end

return style
