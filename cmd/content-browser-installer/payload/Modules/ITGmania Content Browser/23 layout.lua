-- -----------------------------------------------------------------------
-- Where everything sits on screen
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local Clamp                = CB.Clamp
local CurrentPack          = CB.CurrentPack
local DetailInFlight       = CB.DetailInFlight
local DedicatedDoubles     = CB.DedicatedDoubles
local FEAT                 = CB.FEAT
local FetchDetail          = CB.FetchDetail
local FormatBytes          = CB.FormatBytes
local InBrowsingMode       = CB.InBrowsingMode
local InLevelView          = CB.InLevelView
local InYearView           = CB.InYearView
local InstalledPage        = CB.InstalledPage
local InstalledPages       = CB.InstalledPages
local LEVEL                = CB.LEVEL
local LO                   = CB.LO
local WebBase              = CB.WebBase
local NetworkBlockedReason = CB.NetworkBlockedReason
local PackTypeOf           = CB.PackTypeOf
local Refresh              = CB.Refresh
local Snd                  = CB.Snd
local Sync                 = CB.Sync
local UP                   = CB.UP
local state                = CB.state

-- One table rather than twenty-one locals: Lua 5.1 caps a function at 60
-- upvalues, and the browser actor tree reads every one of these. Declared in
-- 04 queues.lua, where the download prompt needs the name in scope early;
-- this is where it gets its contents.
LO.W  = _screen.w
LO.H  = _screen.h
LO.CONTENT_TOP = 44
LO.CONTENT_BOT = 440
LO.LIST_X      = 16
LO.LIST_W      = math.floor(LO.W * 0.53)
LO.ROW_H       = 35   -- 7 of these still clear CONTENT_BOT once the bands above are evenly spaced
LO.DL_ROWS     = 3                              -- queue rows before the rest become a count
LO.DIALOG_W    = 400
LO.DIALOG_H    = 170

-- vertical stack: filter tabs / featured grid / list columns.  There is no
-- sub-header band any more -- the active tab already says what you are looking
-- at, and the row it used to occupy is worth more as list space.
-- The tab row sits beside the screen header rather than under it. "FIND
-- CONTENT" is set in the theme's own header and takes a whole row on its own;
-- the rest of that row was empty, and the tabs fit in it, which gives every
-- view below eighteen pixels it did not have.
LO.TABS_X      = 196                            -- clear of the header's wording
LO.TABS_Y      = 22                             -- level with it
LO.TABS_PITCH  = 72
LO.TAB_W       = LO.TABS_PITCH - 6              -- the selectable pill itself
LO.TAB_H       = 20
LO.TABS_RULE_Y = LO.TABS_Y + 12

-- The update chip sits at the right end of the same row, and the row is
-- already full, so the tabs close up to make room for it. They only do that
-- when there is an update to show, which is almost never -- paying eight
-- pixels a tab permanently for a notice that appears twice a year would be the
-- wrong way round. The positions are worked out per refresh instead of once at
-- build time, which is what lets them move at all.
LO.UPD_W       = 56
LO.UPD_PITCH   = 62                             -- what a tab shrinks to
LO.UPD_RIGHT   = LO.W - LO.LIST_X - 26          -- clear of the loading spinner

-- Whether the update chip is on the tab row at all.
--
-- Anything newer counts, including a release the browser cannot install by
-- itself. UP.Blocked() was written for exactly that case and then never asked:
-- a release raising minHelper -- which is most of them, since the helper is the
-- half that gets fixed -- left every player on the old version looking at a row
-- with nothing new on it, being told nothing, while an update sat waiting.
function LO.UpdateShowing()
	return state.open and InBrowsingMode() and (UP.Available() or UP.Blocked())
end

-- ...and whether pressing it can actually finish the job. A blocked one still
-- shows, because knowing is the point, but it does not pulse for attention it
-- cannot reward and Start says what to do instead of failing.
function LO.UpdateActionable()
	return UP.Available()
end

function LO.TabPitch()
	return LO.UpdateShowing() and LO.UPD_PITCH or LO.TABS_PITCH
end

function LO.TabW()
	return LO.TabPitch() - 6
end

function LO.TabX(index)
	return LO.TABS_X + (index - 1) * LO.TabPitch()
end

-- the chip's left edge; it is right-aligned so it cannot drift into the spinner
function LO.UpdX()
	return LO.UPD_RIGHT - LO.UPD_W
end
-- one line under the whole header, so the tabs read as a bar rather than as
-- text floating above the page
LO.HEADER_RULE_Y = 42
-- The one vertical gap between bands. Every measurement below is derived from
-- it rather than typed in, so the rhythm cannot drift out again.
LO.GUTTER      = 8
LO.FEAT_LABEL_Y = LO.HEADER_RULE_Y + 14         -- the heading's centre, above the panel
LO.FEAT_PANEL_X = LO.LIST_X                     -- flush with the list rows
LO.FEAT_PANEL_W = LO.W - 2*LO.LIST_X
LO.FEAT_PANEL_Y = LO.FEAT_LABEL_Y + LO.GUTTER
LO.FEAT_PAD    = 4                              -- inside the panel's border
LO.FEAT_PAD_TOP = 8                             -- optically, the top needs more
LO.FEAT_TOP    = LO.FEAT_PANEL_Y + LO.FEAT_PAD_TOP
LO.FEAT_CARD_H = 41                             -- a banner's shape, and it pays for the padding
LO.FEAT_DOT    = 8                              -- the page-dot row's own height
LO.FEAT_GAP    = 4
LO.FEAT_ROW_GAP = 4
LO.FEAT_SPAN   = LO.FEAT_PANEL_W - 2*LO.FEAT_PAD
LO.FEAT_CARD_W = math.floor((LO.FEAT_SPAN - (FEAT.COLS-1)*LO.FEAT_GAP) / FEAT.COLS)

-- Columns are spread across the whole span rather than laid end to end, so the
-- last card finishes exactly on the right margin. Laying them out by width plus
-- a fixed gap left four pixels over, which put the strip's right edge four
-- pixels inside the list's.
function LO.FeatX(col)
	local left = LO.FEAT_PANEL_X + LO.FEAT_PAD
	if FEAT.COLS < 2 then return left end
	local step = (LO.FEAT_SPAN - LO.FEAT_CARD_W) / (FEAT.COLS - 1)
	return left + math.floor(col * step + 0.5)
end

-- two rows of shorter cards fit in the band one row of tall ones used to
LO.FEAT_BOT    = LO.FEAT_TOP + FEAT.ROWS*LO.FEAT_CARD_H
                 + (FEAT.ROWS-1)*LO.FEAT_ROW_GAP
-- the dots' centre: one padding below the cards, then half a dot row
LO.FEAT_RULE_Y = LO.FEAT_BOT + LO.FEAT_PAD + LO.FEAT_DOT/2
-- and one padding below the dot row's bottom edge, not its middle
LO.FEAT_PANEL_H = (LO.FEAT_RULE_Y + LO.FEAT_DOT/2 + LO.FEAT_PAD) - LO.FEAT_PANEL_Y
LO.LIST_TOP    = LO.FEAT_PANEL_Y + LO.FEAT_PANEL_H + LO.GUTTER
-- Without the featured grid: just under the band, which is the tallest thing
-- that can be up there (its subtitle overhangs the panel it sits in, and the
-- year chips end above that). Derived rather than typed, so moving the header
-- moves this too instead of leaving a gap where the old number was.
LO.LIST_TOP_TIGHT = LO.FEAT_TOP + 63
LO.PANE_X      = LO.LIST_X + LO.LIST_W + 12
LO.PANE_W      = LO.W - LO.PANE_X - 16
LO.SCROLL_W    = 4

-- The doubles view: two columns across the whole content width. The ordinary
-- list is barely half the screen because the info pane has the rest, and two
-- lists will not fit in that half at any readable size -- so this view spends
-- the pane's space on the second column instead.
LO.DBL_GAP     = 20
LO.DBL_W       = math.floor((LO.W - 2*LO.LIST_X - LO.DBL_GAP) / 2)
LO.DBL_HEAD    = 22                             -- the column heading and its rule
LO.DBL_ROWS    = LEVEL.DBL_ROWS
function LO.DblX(col) return LO.LIST_X + (col-1)*(LO.DBL_W + LO.DBL_GAP) end
function LO.DblTop() return LO.LIST_TOP_TIGHT + LO.DBL_HEAD end

-- How wide the field is about to be, asked before the charts have arrived.
--
-- The empty field drawn under the spinner has to be laid out for the columns
-- the chart will have, or a doubles preview opens as four receptors and jumps
-- to eight the moment the notes land.
--
-- Known outright when this song has been previewed before: its charts were
-- kept, and the one about to open is the one the popup asked for or the same
-- default the arrival will pick. Failing that the pack answers it -- one made
-- for doubles has nothing else in it -- and failing that four, which is what
-- most songs are.
function LO.PreviewLanes()
	local list = Snd.KnownNow()
	if list and #list > 0 then
		local index = Clamp(Snd.want or Snd.DefaultIn(list), 1, #list)
		local lanes = tonumber(list[index] and list[index].lanes)
		if lanes and lanes > 0 then return lanes end
	end
	if LO.StyleOf(CurrentPack()) == "doubles" then return 8 end
	return 4
end

-- A pack in the dedicated column comes from itgdb by name and from the
-- catalogue CSV by id, and the CSV carries no banner -- so its row has nothing
-- to draw until somebody reads the pack page. The walk never reads those pages,
-- because itgdb has already said the pack belongs here and there is nothing
-- left to decide, so the rows fetch their own as they come into view.
--
-- Once each: a page already read, being read, or lately failed is left alone.
function LO.DoublesBanner(pack)
	if not (pack and state.open and state.settled and state.mode == "doubles") then return end
	if pack.banner or state.details[pack.id] ~= nil then return end
	-- FetchDetail already refuses a request that is in flight or lately
	-- failed, and it is the only one of these that knows about the deadline
	-- and the cooldown, so asking it is better than second-guessing it.
	if DetailInFlight(pack.id) then return end
	FetchDetail(pack, function() Refresh() end)
end

-- Can this column still get longer?
--
-- While the walk is running either of them can, because it is still placing
-- packs into both. Once it has settled only the second can, by being asked for
-- more. A column that can grow prints its count with a + on it: the number is
-- how many have been found, not how many there are, and the two should not
-- look like the same claim.
function LO.DoublesGrowing(col)
	local lv = state.level
	if not lv or lv.bucket ~= "doubles" then return false end
	if lv.status == "loading" then return true end
	return col == 2 and lv.more == true
end

-- where this module was installed, for checking that its icons came with it
LO.MODULE_DIR = ((THEME and THEME.GetCurrentThemeDirectory)
	and THEME:GetCurrentThemeDirectory() or "Themes/Simply Love/") .. "Modules/"

-- Where the artwork is, as an absolute path -- and it has to be absolute.
--
-- A Texture handed to Def.<Class>{} is resolved against the directory of the
-- file the Def was written in: the theme stamps _Dir on the node from
-- debug.getinfo().source, and ActorUtil::GetAttrPath glues it onto the front of
-- any path not starting with "/". So a relative "ContentBrowserIcons/x.png"
-- means "beside whichever file this line happens to live in", which is not a
-- thing this code can rely on now that it lives in more than one.
--
-- The leading slash is the whole point. MODULE_DIR on its own does not do it:
-- GetCurrentThemeDirectory returns "Themes/<name>/" with no slash in front, so
-- a path built from it still counts as relative and still gets _Dir prepended.
--
-- Getting this wrong is not a missing icon. A texture that cannot be found is
-- an Abort/Retry/Ignore dialog thrown over the running game.
LO.ICONS = "/" .. LO.MODULE_DIR .. "ContentBrowserIcons/"

-- Is the featured grid on screen?  Everything that reserves the band and
-- everything that starts below it asks this one question, so the grid and the
-- list top can never disagree.  "confirm" is a dialog drawn over whichever
-- list opened it, so it borrows that view's answer instead of claiming to be
-- a plain pack list -- otherwise the rows would jump behind the dialog.
function LO.GridShowing()
	if state.filterMode == "keyboard" then return false end
	return state.search == "" and state.mode == "list"
end

-- The detail view is on screen for its own mode and behind the popup that mode
-- opens. On LO so the screen parts that ask can reach it through the table
-- they already import.
function LO.DetailShowing()
	return state.mode == "detail" or state.mode == "confirm"
end

-- True while a view is still assembling its own rows, as opposed to waiting on
-- a server page. The body shows placeholders rather than claiming to be empty.
-- Whether an empty row should spin while it waits.
--
-- Everywhere but the year view, yes: that row is waiting on its own pack and
-- the spinner sits exactly where the pack will appear. The year view is not
-- like that -- it builds one index for the whole tab, and spinning every empty
-- row turned one thing happening into eight, filling the list with wheels for
-- a job that is neither per-row nor happening there. It has its own spinner
-- now, beside the year it is working through.
function LO.RowSpin()
	if InYearView() then return false end
	return LO.ListBuilding()
end

function LO.ListBuilding()
	if InLevelView() then
		return state.level ~= nil and state.level.status == "loading"
	end
	if InYearView() then
		return state.recentIndex ~= nil and state.recentIndex.status == "loading"
	end
	if state.search ~= "" then return state.loading == true end
	return false
end

-- where the pack list and its info pane start, for the view on screen now
function LO.ListTop()
	if LO.GridShowing() then return LO.LIST_TOP end
	return LO.LIST_TOP_TIGHT
end

-- Where the installed tab is in its own list, and why the network is blocked.
-- Both on LO so the screen parts that ask reach them through the table they
-- already import.
function LO.InstPageText()
	return string.format("   PAGE %d/%d", InstalledPage(), InstalledPages())
end
-- Is this screen wide enough to draw on?
--
-- Everything here is laid out in the engine's virtual pixels, which are 854 by
-- 480 on a widescreen display and 640 by 480 on a 4:3 one -- the height is
-- fixed and the width is what changes. Two hundred and fourteen pixels is a
-- third of the screen: the tab row does not fit, the pack list and its info
-- pane overlap, and the detail page's table runs under the song list.
--
-- None of that is worth trying to reflow. A 4:3 cabinet is a real thing to be
-- playing on and the honest answer is that this screen was not built for it,
-- said plainly, rather than a layout that technically appears and cannot be
-- read.
LO.MIN_WIDTH = 700

function LO.TooNarrow()
	return LO.W < LO.MIN_WIDTH
end

-- Why the browser will not open, or nil when it will.
--
-- The aspect comes first: no amount of network access makes a 4:3 screen wide
-- enough, and being told to run an installer script would be a waste of
-- somebody's afternoon.
function LO.BlockedReason()
	if LO.TooNarrow() then
		return "This browser is built for a widescreen display. This screen is "
			.. math.floor(LO.W) .. " by " .. math.floor(LO.H)
			.. ", which is 4:3, and the layout does not fit in it -- the tab row, "
			.. "the pack list and its details all want width that is not there.\n\n"
			.. "Set the game to a 16:9 or 16:10 aspect ratio in Graphics Options "
			.. "and this will open."
	end
	return NetworkBlockedReason()
end

-- ...and the heading that goes with it.
function LO.BlockedTitle()
	if LO.TooNarrow() then return "Needs A Widescreen Display" end
	return "Network Access Not Enabled"
end

-- the pane keeps its bottom edge pinned, so it grows when the list moves up
function LO.PaneH()
	return LO.CONTENT_BOT - LO.ListTop() - 6
end

-- Start the view the reader has actually settled on.  See LEVEL.Begin --
-- this is the name BrowserActor can afford to say.
--
-- Cycling the tab row enters each view it passes through, which is what makes
-- the row feel live -- and the engine runs one HTTP request at a time, in the
-- order they were asked for, on a single worker thread. So walking from PAD to
-- DOUBLES used to put a popularity ranking, a catalogue crawl and a page of
-- beginner pack reads in the queue ahead of the one list the reader wanted,
-- and Doubles waited behind all of it for several seconds.
--
-- Holding the fetches back a fraction of a second costs a view nothing -- a
-- reader who stops on a tab is still waiting on the network either way -- and
-- it means passing over four tabs to reach the fifth asks for nothing on
-- behalf of the four.
--
-- On LO so the screen part that fires it reaches it through the table it
-- already imports.
function LO.LevelBegin() LEVEL.Begin() end

-- How much of a pack is in one style, and over what difficulties.
--
-- SMO prints one meter range per song covering every chart type that song
-- carries, so a song with singles and doubles cannot be split from the pack
-- page -- and the per-song pages that could split it are one request each,
-- which is two hundred requests for a pack like ITG Hall of Fame. The span
-- here is therefore the span of the songs that carry the style, which is
-- exactly what the song rows beside it show, so nothing on the screen
-- contradicts anything else on it.
--
-- On LO for the same reason as the rest of these: reached through the one
-- table the screen parts already import.
-- What this pack is, as far as anything actually knows.
--
-- SMO's pack page carries no per-song style information: its styles column is
-- a row of filter buttons, identical on every row. So nothing here claims to
-- know which songs are doubles. What is known is the pack's game type, from
-- the catalogue CSV, and whether itgdb lists it as built for doubles -- and
-- that is all this reports.
-- What to zoom a style icon to, for a row of them set beside text.
--
-- The doubles icon is two pads side by side in a square canvas, so each pad is
-- half-size and the graphic is half as tall as the single-pad one. At a shared
-- zoom it therefore reads as a smaller thing rather than a wider one. Drawn at
-- twice the zoom its pads match the single pad and the pair is twice as wide,
-- which is what two pads actually are.
function LO.IconZoom(kind, base)
	return base * ((kind == "doubles") and 2 or 1)
end

-- ...and how much room that takes, for laying out what sits next to it.
function LO.IconWide(kind, base)
	return 96 * LO.IconZoom(kind, base)
end

-- What the pack's own download says about its sync.
--
-- SMO's catalogue is ambiguous here: a pack with no sync tag might carry no
-- Pack.ini, or might simply never have been tagged. The archive knows, and the
-- helper can read it for the price of the zip's central directory -- the same
-- index a preview of that pack already builds. So the row starts by reporting
-- what SMO says and replaces it with what the download actually contains.
--
-- Asked once per pack. A pack that failed is not asked again either: the row
-- falls back to SMO's answer, which is what it said before any of this.
-- Is this pack's page still on its way?
--
-- Most of the table comes from the catalogue and is there the moment the page
-- opens; the rest -- the chart count, the difficulty span, who charted it --
-- lives on the pack page, which is a request. Between the two, those rows have
-- nothing to say, and a blank row reads as "this pack has none of that" rather
-- than "ask again in a second".
--
-- A page that failed is not pending: the row goes back to being empty, because
-- nothing further is coming and a spinner that never stops is worse than a gap.
-- Is this pack's page still coming?
--
-- A spinner is a promise that something is on its way, so this asks whether a
-- request is actually in the air -- not merely whether an answer is missing.
-- Those are different questions and the old one answered yes to both a fetch
-- that was never made and a reply that never arrived, which is how a page
-- ended up spinning at nothing for the rest of the session.
function LO.DetailPending(pack)
	if not (pack and pack.id) then return false end
	if state.details[pack.id] ~= nil then return false end
	return DetailInFlight(pack.id)
end

-- Is the detail page waiting on something that will change by itself?
--
-- Only while a request is genuinely in the air. Its deadline passes on a
-- clock and this module repaints only when told to, so without something
-- ticking the page would keep showing the picture it had when the request
-- was sent -- spinners up, no dashes, no way out offered. Once the answer
-- lands, or the deadline retires it, this goes false and the clock stops.
function LO.DetailTicking()
	if not LO.DetailShowing() then return false end
	local pack = CurrentPack()
	if not (pack and pack.id) then return false end
	if state.details[pack.id] ~= nil then return false end
	return DetailInFlight(pack.id)
end

-- Nothing came, and nothing is coming. The page says so and offers the key
-- that asks again, rather than leaving a row of blanks to be read as a pack
-- with no charts and no author.
function LO.DetailLost(pack)
	if not (pack and pack.id) then return false end
	if state.details[pack.id] ~= nil then return false end
	return not DetailInFlight(pack.id)
end

-- The free-space gate went with the helper that measured it: the game's Lua
-- has no way to ask a disk anything, so a download now proceeds and a full
-- disk fails it honestly partway instead of being predicted. SpaceFor keeps
-- its shape -- with nothing ever measured it always answers yes -- so its
-- callers did not have to learn anything.

-- Is there room for this pack, and what to say when there is not.
--
-- A margin on top of the pack's own size, because a zip is unpacked beside
-- itself: for a moment the archive and the songs it holds are both on the disk,
-- so a download needs about twice what the listing says, and a little over that
-- to leave the machine somewhere to work.
LO.SPACE_MARGIN = 250 * 1024 * 1024

function LO.SpaceFor(pack)
	local free = state.spaceFree
	if not (free and pack) then return true, nil end
	local need = (tonumber(pack.bytes) or 0) * 2 + LO.SPACE_MARGIN
	if need <= free then return true, nil end
	return false, "Not enough room: " .. pack.sizeStr .. " needs about "
		.. FormatBytes(need) .. " free while it unpacks, and "
		.. (state.spaceRoot or "the songs folder") .. " has "
		.. FormatBytes(free) .. "."
end

function LO.PackIniAsk(pack)
	if not (pack and pack.id and state.open and state.settled) then return end
	state.packIni = state.packIni or {}
	if state.packIni[pack.id] ~= nil then return end

	local url = WebBase() .. "/api/packini/" .. tostring(math.floor(pack.id))
	if not NETWORK:IsUrlAllowed(url) then return end

	state.packIni[pack.id] = { status = "asking" }
	NETWORK:HttpRequest{
		url = url,
		connectTimeout = 5,
		transferTimeout = 30,
		onResponse = function(response)
			if state.retired then return end
			local info = { status = "failed" }
			if response.error == nil then
				local ok, data = pcall(JsonDecode, response.body or "")
				if ok and type(data) == "table" and type(data.packIni) == "table" then
					info = {
						status  = "ready",
						present = data.packIni.present == true,
						sync    = data.packIni.sync,
						-- The same read of the same archive index also says
						-- which songs carry Lua, so it comes back on this
						-- response rather than costing a second one.
						mods    = type(data.mods) == "table" and data.mods or nil,
					}
				end
			end
			state.packIni[pack.id] = info
			Refresh()
		end,
	}
end

-- What a pack's archive said about Lua, once it has been read.
function LO.ModsOf(pack)
	local read = pack and state.packIni and state.packIni[pack.id]
	if not (read and read.status == "ready" and read.mods) then return nil end
	return read.mods
end

-- Folder names reduced to letters and digits, which is how the helper compares
-- them too. Song folders get renamed, spaced and bracketed on their way into a
-- pack, and the punctuation is the part that never survives.
function LO.ModKey(text)
	return (tostring(text or ""):lower():gsub("[^a-z0-9]", ""))
end

-- Which rows of a pack's song list carry Lua of their own.
--
-- The archive knows folders and the catalogue knows titles, and the two are
-- alike without being equal: a folder picks up the numbering and the tags a
-- pack organises itself by, so "Ascendanz" lives in "[T02] Ascendanz (SM)".
--
-- Each mod folder is matched to the one song that answers to it best rather
-- than to every song it resembles, which is what stops a folder called Rain
-- from marking Raindrop as well. Same scoring the helper uses when it goes
-- looking for a song to extract: exact wins outright, otherwise whichever
-- overlaps by most, and a coincidence of three or four characters wins
-- nothing.
--
-- Worked out once per pack and kept, because the list it walks does not change
-- and the rows redraw constantly.
function LO.ModRows(pack, det)
	local mods = LO.ModsOf(pack)
	if not (mods and mods.songs and #mods.songs > 0 and det and det.songs) then
		return nil
	end
	local read = state.packIni[pack.id]
	if read.rows and read.rowsFor == #det.songs then return read.rows end

	-- the titles reduced once, rather than once per folder
	local keys = {}
	for index, song in ipairs(det.songs) do keys[index] = LO.ModKey(song.title) end

	local rows = {}
	for folder in ivalues(mods.songs) do
		local got = LO.ModKey(folder)
		if got ~= "" then
			local best, bestScore = nil, 3
			for index, want in ipairs(keys) do
				local score = 0
				if want ~= "" then
					if want == got then
						score = 1000000
					elseif want:find(got, 1, true) then
						score = #got
					elseif got:find(want, 1, true) then
						score = #want
					end
				end
				if score > bestScore then best, bestScore = index, score end
			end
			if best then rows[best] = true end
		end
	end

	read.rows, read.rowsFor = rows, #det.songs
	return rows
end

-- Does the song on this row carry Lua?
--
-- It errs towards saying nothing. A song whose folder was named something its
-- title would never suggest goes unmarked, which understates the pack; the
-- count on the Songs row is read straight from the archive and is right either
-- way.
function LO.SongMods(pack, index)
	if not (pack and index) then return false end
	local rows = LO.ModRows(pack, state.details[pack.id])
	return rows ~= nil and rows[index] == true
end

-- The sync line for a pack, and the one place that decides what is known.
function LO.SyncLine(pack, det)
	local read = pack and state.packIni and state.packIni[pack.id]
	if read and read.status == "ready" then
		-- the download itself, which outranks anything the catalogue says
		if not read.present then
			return "no Pack.ini - machine: " .. Sync.MachineLabel()
		end
		if read.sync == "NULL" then return "Pack.ini: NULL (0ms)" end
		if read.sync == "ITG" then return "Pack.ini: ITG (+9ms)" end
		return "Pack.ini: present, unreadable"
	end

	-- Until then, what the catalogue says. A tag means the copy SMO serves has
	-- a Pack.ini and it says this; no tag means the machine's own
	-- DefaultSyncOffset answers, and that is a per-install preference.
	local sync = tostring((det and det.stats.sync) or (pack and pack.sync) or ""):lower()
	if sync == "null" or sync == "0" then return "SMO Pack.ini: NULL (0ms)" end
	if sync == "itg" then return "SMO Pack.ini: ITG (+9ms)" end
	return "no SMO Pack.ini - machine: " .. Sync.MachineLabel()
end

-- The setup script for the machine this is running on, by name.
--
-- Three are shipped, one per platform, and telling a Linux cabinet to
-- double-click a .bat is worse than saying nothing: it names a file that is
-- there, cannot be run, and sends the reader looking for a Windows machine.
-- HOOKS:GetArchName answers "Windows", "Unix" or "macOS (...)".
function LO.SetupScript()
	local arch = ""
	if HOOKS and HOOKS.GetArchName then
		local ok, name = pcall(HOOKS.GetArchName, HOOKS)
		if ok then arch = tostring(name or "") end
	end
	if arch:find("Windows", 1, true) then
		return "double-click  Enable Network Access.bat"
	end
	if arch:find("macOS", 1, true) or arch:find("Unix", 1, true) then
		return "run  ./enable-network-access.sh"
	end
	-- nothing answered; name them all rather than name the wrong one
	return "run the Enable Network Access script for your system"
end

function LO.StyleOf(pack)
	if not pack then return nil, "" end
	if DedicatedDoubles(pack) then return "doubles", "Doubles" end

	-- SMO's own catalogue can be filtered to packs containing dance-double
	-- charts, and the doubles tab fetches exactly that list. Where it has been
	-- fetched, being on it is SMO saying this pack has doubles in it -- which
	-- is a good deal better than guessing from the pack type.
	--
	-- Only when it is already in hand. Asking for five hundred rows to label
	-- one pack would be a poor trade, so a session that never opens the
	-- doubles tab simply says less rather than paying for more.
	local d = state.doubles
	if d.partial then
		if d.partialById == nil then
			d.partialById = {}
			for row in ivalues(d.partial) do d.partialById[row.id] = true end
		end
		if d.partialById[pack.id] then return "both", "Singles + Doubles" end
	end

	local kind = PackTypeOf(pack.id)
	if kind == "keyboard" then return "keyboard", "Keyboard" end
	return "pad", "Singles"
end

-- The pack's difficulty span, as the page itself reports it. The histogram is
-- the same numbers drawn, so the two cannot disagree.
function LO.PackSpan(det)
	if not (det and det.labels) then return nil, nil end
	local low, high
	for index, meter in ipairs(det.labels) do
		if (det.counts[index] or 0) > 0 then
			if not low then low = meter end
			high = meter
		end
	end
	return low, high
end

-- The player's own noteskin, for the chart preview.
--
-- Loaded the way the theme's own preview loads one: through pcall, because a
-- single broken noteskin in somebody's collection is enough to take a screen
-- down with it, and a browser that will not open is a great deal worse than a
-- preview drawn with the module's own arrows instead.
function LO.NoteSkinName()
	local name
	pcall(function()
		local ps = GAMESTATE and GAMESTATE:GetPlayerState(PLAYER_1)
		name = ps and ps:GetCurrentPlayerOptions():NoteSkin()
	end)
	if type(name) == "string" then name = name:lower() end
	if name and name ~= "" then
		local ok, exists = pcall(NOTESKIN.DoesNoteSkinExist, NOTESKIN, name)
		if ok and exists then return name end
	end
	local ok, all = pcall(NOTESKIN.GetNoteSkinNames, NOTESKIN, false)
	if ok and type(all) == "table" then
		for skin in ivalues(all) do return tostring(skin):lower() end
	end
	return nil
end

-- One piece of that noteskin: a tap note, a receptor, an explosion. Returns
-- nil when there is nothing to load, and the caller falls back to its own.
function LO.NoteActor(column, element)
	if not LO.NOTESKIN then return nil end
	local ok, actor = pcall(NOTESKIN.LoadActorForNoteSkin, NOTESKIN,
		column, element, LO.NOTESKIN)
	if not (ok and actor) then return nil end
	-- dropped for the reason the theme drops it: a noteskin's own InitCommand
	-- can throw, and it would take everything after it with it
	actor.InitCommand = nil
	return actor
end

