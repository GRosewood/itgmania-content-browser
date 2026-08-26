-- -----------------------------------------------------------------------
-- ITGMania Content Browser
-- by GregTech
--
-- A drop-in Simply Love module that adds a "Find Content" entry to the
-- title menu (home screen).  It opens an in-game browser for
-- https://stepmaniaonline.net 's pack index, showing banners, pack info,
-- chart details, and difficulty distributions, and lets you download and
-- install packs directly into /Songs without leaving ITGmania.
--
-- Install: place this file, and the folder of the same name beside it, in
--          Themes/Simply Love/Modules/
-- Requires: ITGmania 1.1+ (uses NETWORK:HttpRequest / FILEMAN:Unzip)
--
-- Network access: ITGmania blocks all hosts by default. The installer adds
-- one entry, 127.0.0.1, so the game can talk to the helper service beside
-- it; the helper relays the browser's reads to the catalogue's three hosts
-- and refuses to reach anything else. A hand install without the helper
-- runs the Enable Network Access script instead, which allowlists those
-- hosts directly. The module itself never edits any preference.
--
-- Copyright (C) 2026 Rosewood <rosewoodsteps@gmail.com>
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License, version 3, as published
-- by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
-- more details.
--
-- You should have received a copy of the GNU General Public License along
-- with this program -- it is the LICENSE.txt sitting beside this file.  If
-- not, see <https://www.gnu.org/licenses/>.
-- -----------------------------------------------------------------------
--
-- THIS FILE IS THE MAP. The browser itself is the folder beside it.
--
-- Simply Love loads every .lua sitting directly in Modules/ and does not look
-- inside folders, so this is the only file it sees. It loads the parts, in the
-- order listed below, and hands the theme back the screens they built.
--
-- Why a folder of parts rather than one file: the browser had grown to eleven
-- thousand lines in a single chunk, and Lua 5.1 puts a hard ceiling on a chunk
-- -- 200 local variables, 60 upvalues per function -- which it had reached
-- exactly. There was no room to add anything without first taking something
-- out. Each file here is its own chunk with its own ceiling, so the limits stop
-- being something to work around. Being able to find things is the better half
-- of the bargain.
--
-- HOW THE PARTS TALK TO EACH OTHER
--
-- One table, built fresh here and passed to every part. A part picks what it
-- needs off it at the top, and puts back whatever the later parts need at the
-- bottom:
--
--     local CB = ...                       -- the shared table
--     local state = CB.state               -- what this part uses
--     ...
--     CB.FetchPacks = FetchPacks           -- what it offers
--
-- Names are copied into locals rather than reached through the table on every
-- use, because a local is a register read and a table field is a hash lookup,
-- and some of these run every frame. The list at the top of a part is therefore
-- also its dependency list, which is the point.
--
-- Two things may never be shared that way, because a copy is a copy:
--
--   * A value that is REASSIGNED after it is shared. A boolean flag handed to
--     another file leaves each file with its own variable; one file writes,
--     the other never sees it, and nothing errors. Code that shares mutable
--     flags lives in one file (the title menu is one file for this reason).
--
--   * A function that is DEFINED LATER than the part that calls it. The copy
--     would be the nil the name held at the time. Those few names are reached
--     through the shared table at call time instead, via a one-line forwarder
--     the part declares at its top -- the cost is one hash lookup per call,
--     paid only by the handful of names that need it.
--
-- Nothing is stored in a global. The browser can be reloaded in place after it
-- updates itself, and a global would let the old, retired copy leak into the
-- new one.
--
-- THE ORDER MATTERS
--
-- A part may only use names that an EARLIER part has set: Lua binds a name when
-- it compiles the line mentioning it, so a part that has not run yet has set
-- nothing. The order below is a dependency order and is checked -- see
-- tools/lua-checks in the repository.
--
-- The parts are named explicitly rather than found by listing the folder. That
-- is deliberate: nothing on the update path ever deletes a file, so a part
-- dropped by a later release would linger on disk forever. Because the list
-- below is the only thing that loads anything, a leftover file is simply
-- ignored instead of quietly becoming live code again.
-- -----------------------------------------------------------------------

local FOLDER = "ITGmania Content Browser"

-- In the order they load. The number in the filename is that order; it is
-- written down here as well because this list, not the folder, is what runs.
local PARTS = {
	-- The things everything else is built out of.
	"01 state.lua",               -- every piece of state the browser keeps
	"02 text.lua",                -- tidying text, sizes, dates, difficulty colours
	"03 packs.lua",               -- what a pack is, and which ones are on show
	"04 queues.lua",              -- the download queue, and the self-updater
	"05 redraw.lua",              -- telling the screen something changed

	-- Talking to the outside world.
	"06 parse.lua",               -- reading the catalogue's HTML
	"07 banners.lua",             -- fetching pack artwork, a few at a time
	"08 catalogue.lua",           -- asking the catalogue for pages of packs
	"09 search.lua",              -- search
	"10 pack page.lua",           -- fetching one pack's own page

	-- This machine: what is already here, and what can be heard.
	"11 library.lua",             -- the songs folder, pack sync, the preview relay
	"12 sound.lua",               -- song previews and the chart preview
	"13 installed.lua",           -- which packs are already installed

	-- Working out what to show, per tab.
	"14 featured pool.lua",       -- scoring a pack, and the index of what is recent
	"15 levels.lua",              -- the difficulty levels, and the band heading them
	"16 years.lua",               -- browsing by year
	"17 arrowcloud.lua",          -- the second source, and charter lookups
	"18 featured choice.lua",     -- choosing what to feature

	-- Doing things, and being driven.
	"19 downloads.lua",           -- downloading a pack and putting it in place
	"20 network gate.lua",        -- the network gate, and the self-updater
	"21 input.lua",               -- every key the browser answers to
	"22 title menu.lua",          -- the title-menu entry, and the hooks that watch it

	-- Drawing.
	"23 layout.lua",              -- where everything sits on screen
	"24 widgets.lua",             -- small actors used all over

	-- The screen itself. Read "30 screen.lua" first: it is the contents page
	-- for the seventeen files after it, and says what order they go together in.
	"30 screen.lua",
	"31 screen - frame.lua",
	"32 screen - hidden helpers.lua",
	"33 screen - container.lua",
	"34 screen - download ticker.lua",
	"35 screen - tabs.lua",
	"36 screen - featured grid.lua",
	"37 screen - pack rows.lua",
	"38 screen - info pane.lua",
	"39 screen - detail page.lua",
	"40 screen - context band.lua",
	"41 screen - year picker.lua",
	"42 screen - installed view.lua",
	"43 screen - doubles view.lua",
	"44 screen - footer hints.lua",
	"45 screen - chart window.lua",
	"46 screen - dialogs.lua",
	"47 screen - toast.lua",
}

-- The last one, kept out of the list because it is the only part that hands
-- something back: the table of screens this whole file exists to return.
local FINAL = "48 screens.lua"

-- -----------------------------------------------------------------------

-- The shared table. Built here, on every load, and handed to each part in turn.
local CB = {}

-- The screen's pieces live under their own name so the seventeen files that
-- build them do not each need a line of their own here.
CB.Screen = {}

-- Where the parts are.
--
-- Built from the theme's own directory rather than a fixed path, so a fork of
-- Simply Love under another name still finds them. loadfile takes a real
-- filesystem path relative to the game's working directory, which is exactly
-- what the theme's own module loader hands to loadfile a moment before it gets
-- here -- so if this file was found, its folder will be too.
local DIR = THEME:GetCurrentThemeDirectory() .. "Modules/" .. FOLDER .. "/"

-- Load one part and run it.
--
-- assert rather than a quiet skip: a missing or unparseable part means a half
-- built browser, and half a browser is worse than an error message.
local function LoadPart(name)
	local chunk, err = loadfile(DIR .. name)
	if not chunk then
		error("could not load " .. name .. "\n" .. tostring(err), 0)
	end
	return chunk(CB)
end

-- A failure has to reach the PLAYER, not only the log.
--
-- The theme runs this file inside a pcall and hands errors to
-- lua.ReportScriptError -- which is gated behind ShowThemeErrors, off by
-- default, so raising out of here shows nothing: just a title menu quietly
-- missing its Find Content row. A single stray token once cost a whole
-- debugging session that way. The commonest causes are mundane, too --
-- somebody hand-copied the entry file without the folder beside it, or an
-- update was interrupted halfway through writing the parts.
--
-- So a failure is caught here, written to the log in full, and handed back as
-- the one actor this module can still usefully be: a message on the title
-- screen saying what broke. SystemMessage is not gated by anything. It says
-- so once, rather than on every visit to the menu for the rest of the session.
local function Broken(err)
	Trace("Find Content failed to load: " .. tostring(err))
	local told = false
	return {
		ScreenTitleMenu = Def.Actor{
			ModuleCommand = function()
				if told then return end
				told = true
				local line = tostring(err):gsub("\n.*", "")
				SCREENMAN:SystemMessage("Find Content did not load: " .. line
					.. "  (rerun the installer to repair it)")
			end,
		},
	}
end

for i = 1, #PARTS do
	local ok, err = pcall(LoadPart, PARTS[i])
	if not ok then return Broken(err) end
end

-- The theme takes a table of [ScreenName] = actor and puts each actor on that
-- screen. Everything above was preparation for this line.
local ok, screens = pcall(LoadPart, FINAL)
if not ok then return Broken(screens) end
return screens
