-- -----------------------------------------------------------------------
-- Rip Packs: booster packs
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BROWSER_DATA_DIR = CB.BROWSER_DATA_DIR
local Clamp            = CB.Clamp
local CurrentDay       = CB.CurrentDay
local CurrentMonth     = CB.CurrentMonth
local CurrentYear      = CB.CurrentYear
local DL               = CB.DL
local DlBase           = CB.DlBase
local DlRequest        = CB.DlRequest
local OpenTextPrompt   = CB.OpenTextPrompt
local PATCH            = CB.PATCH
local PlaySfx          = CB.PlaySfx
local RAGEFILE_READ    = CB.RAGEFILE_READ
local RAGEFILE_WRITE   = CB.RAGEFILE_WRITE
local RELAY_OUT        = CB.RELAY_OUT
local Refresh          = CB.Refresh
local RelayOut         = CB.RelayOut
local RequestBanner    = CB.RequestBanner
local Toast            = CB.Toast
local Trim             = CB.Trim
local Trouble          = CB.Trouble
local UrlEncode        = CB.UrlEncode
local WebBase          = CB.WebBase
local refs             = CB.refs
local state            = CB.state

-- ---------------------------------------------------------------
-- A booster pack is a pack made on the spot: fifteen songs from all over
-- stepmaniaonline.net, each from a different pack, picked at random within
-- what the player asks for -- the era its audio dates from, who charted it,
-- how hard its Expert chart is, and whether it has every difficulty. Ripping
-- one is the trading-card version of downloading one.
--
-- The finding is the relay's (/api/booster): it reads one song's simfile at a
-- time out of random pack zips until enough pass, which no game could do from
-- Lua. What it finds is only shown: the cards turn over straight away, since
-- the relay's answer already says what is on them, and nothing is downloaded
-- until the player keeps the pack. Keeping it gives it its number and fetches
-- each song through /api/songzip -- the same road a single-song install takes
-- -- into a folder of its own, "Content Booster Pack <n> - <date>". Re-ripping
-- throws the set back and asks for another, leaving out the songs on the table.
--
-- Songs come from packs synced either way, and a pack declares one sync for
-- everything in it. So the folder takes whichever sync most of its songs
-- already have, says so in its Pack.ini, and each song synced the other way
-- has its #OFFSETs moved by the nine milliseconds between them.
--
-- A booster may hold songs the player already has, from a pack in the library
-- or from an earlier booster. Leaving those out emptied exactly the rips
-- people wanted -- an author asking for their own packs, for one -- so
-- nothing is.

local RIP = {}

RIP.SIZE = 15

-- the option rows, top to bottom, and the eras the first one's list holds
RIP.ROWS = { "era", "author", "typed", "avoid", "lo", "hi", "full", "rip", "reset" }
RIP.ERAS = { "modern", "mid", "vintage" }
RIP.ERA_WORDS = {
	modern  = "Modern (2020-present)",
	mid     = "Mid-era (2015-2020)",
	vintage = "Vintage (before 2015)",
}
RIP.ERA_SHORT = { modern = "Modern", mid = "Mid-era", vintage = "Vintage" }

local HISTORY = BROWSER_DATA_DIR .. "boosters.txt"
local METER_MAX = 30

-- what the options are when the tab first opens (state.lua starts them so),
-- and what RESET puts them back to
local DEFAULTS = { typed = "", avoid = "", lo = 8, hi = 14, full = false }

-- the nine milliseconds between the two ways a pack can be synced
local ITG_BIAS = 0.009

-- how long after the cards land a Start is taken as a choice, so the press
-- that ripped the pack cannot also keep it
local DECIDE_GUARD = 1.0

local function Busy()
	local phase = state.rip.phase
	return phase == "searching" or phase == "filling"
end
RIP.Busy = Busy

-- ---------------------------------------------------------------- history

-- What boosters.txt holds: how many packs have been kept, which is what
-- numbers the next. (It once listed every song as well, to keep any from
-- coming twice; those lines are passed over.)
function RIP.History()
	local r = state.rip
	if r.history then return r.history end
	local h = { count = 0 }
	local f = RageFileUtil:CreateRageFile()
	if f:Open(HISTORY, RAGEFILE_READ) then
		local body = f:Read() or ""
		f:Close()
		for line in body:gmatch("[^\r\n]+") do
			local count = tonumber(line:match("^count (%d+)"))
			if count then h.count = math.max(h.count, count) end
		end
	end
	f:destroy()
	r.history = h
	return h
end

local function SaveHistory(h)
	local f = RageFileUtil:CreateRageFile()
	if f:Open(HISTORY, RAGEFILE_WRITE) then
		f:Write("count " .. h.count .. "\n")
		f:Close()
	end
	f:destroy()
end

-- The next pack's number: one past every booster already ripped, kept or not
-- -- the history, the library, and whatever folders are on disk.
local function NextNumber(h)
	local top = h.count
	local function Note(name)
		local n = tonumber(tostring(name):match("^Content Booster Pack (%d+)"))
		if n and n > top then top = n end
	end
	for name in ivalues(SONGMAN:GetSongGroupNames()) do Note(name) end
	for name in ivalues(FILEMAN:GetDirListing("/Songs/Content Booster Pack*", true, false)) do Note(name) end
	return top + 1
end

-- ---------------------------------------------------------------- authors

-- The charters the relay ranks for this: everyone who released packs in the
-- last two years -- those with packs on arrowcloud's most-played list first,
-- by how many and how high, then the rest by how many packs they released.
-- Rebuilt there weekly; fetched here once a session.
function RIP.FetchAuthors()
	local r = state.rip
	if r.authorsStatus == "loading" or r.authorsStatus == "ready" then return end
	local url = WebBase() .. "/booster/authors.json"
	if not NETWORK:IsUrlAllowed(url) then
		r.authorsStatus = "failed"
		return
	end
	r.authorsStatus = "loading"
	NETWORK:HttpRequest{
		url = url,
		connectTimeout = 10,
		transferTimeout = 30,
		onResponse = function(response)
			if state.retired then return end
			local list
			r.authorsOut = RelayOut(response)
			if response.error == nil and response.statusCode == 200 then
				local ok, data = pcall(JsonDecode, response.body or "")
				if ok and type(data) == "table" and type(data.authors) == "table" then
					list = data.authors
				end
			end
			r.authors = list
			r.authorsStatus = list and "ready" or "failed"
			r.pickAt = Clamp(r.pickAt, 1, math.max(1, list and #list or 1))
			Refresh()
		end,
	}
end

-- Who a rip is limited to: everyone chosen from the list and everyone typed,
-- each once; nobody in particular when there are none.
function RIP.Authors()
	local r = state.rip
	local out, have = {}, {}
	local function Add(name)
		name = Trim(tostring(name or ""))
		if name ~= "" and not have[name:lower()] then
			have[name:lower()] = true
			out[#out+1] = name
		end
	end
	for name in ivalues(r.chosen) do Add(name) end
	for name in (r.typed or ""):gmatch("[^,]+") do Add(name) end
	return out
end

-- Whose charts a rip leaves out: the names typed, each once.
function RIP.Avoid()
	local out, have = {}, {}
	for name in (state.rip.avoid or ""):gmatch("[^,]+") do
		name = Trim(name)
		if name ~= "" and not have[name:lower()] then
			have[name:lower()] = true
			out[#out+1] = name
		end
	end
	return out
end

-- Where an author from the list is among the chosen, or nil.
function RIP.ChosenAt(name)
	for i, have in ipairs(state.rip.chosen) do
		if have == name then return i end
	end
	return nil
end

-- the picker's rows on screen at once; it draws this many
RIP.PICK_ROWS = 12

-- The picker shows one of two lists -- the eras, or the charters -- and ticks
-- any number in it. These are the list it has open, whichever that is.
local function PickSet()
	local r = state.rip
	return r.picking == "era" and r.eras or r.chosen
end

function RIP.PickCount()
	local r = state.rip
	if r.picking == "era" then return #RIP.ERAS end
	return r.authors and #r.authors or 0
end

-- The i-th row: what is ticked by it, what it says, and what is beside it.
function RIP.PickItem(i)
	local r = state.rip
	if r.picking == "era" then
		local era = RIP.ERAS[i]
		if not era then return nil end
		return era, RIP.ERA_WORDS[era], ""
	end
	local a = r.authors and r.authors[i]
	if not a then return nil end
	local n = tonumber(a.popular) or 0
	return tostring(a.name), tostring(a.name), n > 0 and (n .. " popular") or ""
end

-- Where a row's key is among the ticked, or nil.
function RIP.PickTicked(key)
	for i, have in ipairs(PickSet()) do
		if have == key then return i end
	end
	return nil
end

-- The eras ticked, in the list's order rather than the order they were ticked.
function RIP.ErasInOrder()
	local out = {}
	for era in ivalues(RIP.ERAS) do
		for have in ivalues(state.rip.eras) do
			if have == era then out[#out+1] = era break end
		end
	end
	return out
end

-- ---------------------------------------------------------------- sync

local function SyncOf(song)
	-- a pack that says nothing is taken as ITG, as everywhere else here
	return (tostring(song.sync or ""):upper() == "NULL") and "NULL" or "ITG"
end

-- the sync most of the songs already have; ITG on a tie, as for an unknown
local function Majority(songs)
	local null = 0
	for song in ivalues(songs) do
		if SyncOf(song) == "NULL" then null = null + 1 end
	end
	return (null * 2 > #songs) and "NULL" or "ITG"
end

-- The pack's Pack.ini: its one sync, and -- once the songs are in -- a line
-- for each saying where it came from, the sync that pack declared, and
-- whether its offsets were moved to this one. The songs come from packs that
-- disagree, and their own files can disagree too (an .sm left behind by its
-- .ssc, say), so the folder alone cannot tell anyone what was done to it.
local function WritePackIni(pack)
	local lines = {
		"[Group]",
		"# Written by the ITGmania Content Browser.",
		"# A booster pack: songs from all over stepmaniaonline.net. Each was",
		"# moved to this pack's sync if its own pack declared the other one,",
		"# and taken as ITG -- the game's default -- if its pack declared none.",
		"Version=1",
		"SyncOffset=" .. pack.sync,
	}
	-- the pack's own banner, once it is in (FetchBanner)
	if pack.banner then lines[#lines+1] = "Banner=" .. pack.banner end
	if pack.got + pack.failed > 0 then
		lines[#lines+1] = "#"
		for song in ivalues(pack.songs) do
			if song.state == "done" then
				local declared = tostring(song.sync or ""):upper()
				local what
				if song.moved then
					what = string.format("offsets moved %+.3f s to %s", song.moved, pack.sync)
				else
					what = "offsets as they were"
				end
				lines[#lines+1] = string.format("# %s -- from %s, synced %s; %s", tostring(song.folder),
					tostring(song.pack or "?"), declared ~= "" and declared or "(not stated)", what)
			end
		end
	end
	lines[#lines+1] = ""
	local f = RageFileUtil:CreateRageFile()
	if f:Open(pack.dest .. "Pack.ini", RAGEFILE_WRITE) then
		f:Write(table.concat(lines, "\n"))
		f:Close()
	end
	f:destroy()
end

-- ---------------------------------------------------------------- the rip

local Next   -- the songs come one at a time; each lands and asks for the next

-- The pack's own banner, as the music wheel shows it: its wrapper, foil torn
-- open on a wall of the songs that landed in it, drawn by the site from what
-- the pack is (/api/boosterbanner) and copied in beside them. Asked for once
-- the songs are in -- the game asks for one thing at a time, and the songs
-- come first -- while the pack still counts as downloading, so the reload
-- waits for it. A banner that cannot be had costs the pack only its banner.
local function FetchBanner(pack, done)
	local art, meters = {}, {}
	for song in ivalues(pack.songs) do
		if song.state == "done" then
			art[#art+1] = tostring(song.art or ""):match("^/api/songart/(.+)$") or "-"
			meters[#meters+1] = tostring(math.floor(tonumber(song.meter) or 0))
		end
	end
	local url = WebBase() .. "/api/boosterbanner?" .. NETWORK:EncodeQueryParameters{
		n = tostring(pack.n),
		d = pack.date,
		e = table.concat(pack.eras or {}, ","),
		lo = tostring(pack.lo),
		hi = tostring(pack.hi),
		a = table.concat(art, ","),
		m = table.concat(meters, ","),
	}
	if not NETWORK:IsUrlAllowed(url) then return done() end
	local file = "cb-rip-" .. pack.n .. "-banner.jpg"
	NETWORK:HttpRequest{
		url = url,
		downloadFile = file,
		connectTimeout = 10,
		transferTimeout = 30,
		onResponse = function(response)
			if state.retired then return end
			if response.error == nil and response.statusCode == 200
					and FILEMAN:Copy("/Downloads/" .. file, pack.dest .. "banner.jpg") then
				pack.banner = "banner.jpg"
			else
				Trouble(response, "booster banner")
			end
			done()
		end,
	}
end

local function Finish(pack)
	-- the banner first, then the rest of this again with it in
	if pack.got > 0 and not pack.bannerAsked then
		pack.bannerAsked = true
		return FetchBanner(pack, function() Finish(pack) end)
	end
	local r = state.rip
	local h = RIP.History()
	h.count = math.max(h.count, pack.n)
	SaveHistory(h)
	-- now it can say what became of each song
	WritePackIni(pack)

	local dl = state.downloads[pack.dlKey]
	if pack.got == 0 then
		r.phase = "failed"
		pack.msg = pack.relayOut and RELAY_OUT or "none of the songs could be downloaded"
		if dl then dl.status, dl.msg = "error", pack.msg end
	else
		r.phase = "done"
		state.needsReload = true
		state.reloadSongs = state.reloadSongs + pack.got
		DL.Remember(pack.folder)
		if dl then
			dl.status = "done"
			dl.groups = { pack.folder }
			dl.finishedAt = GetTimeSinceStart()
		end
		if not state.open then
			SCREENMAN:SystemMessage(pack.folder .. " ripped (reload songs to play)")
		end
	end
	r.phaseAt = GetTimeSinceStart()
	Refresh()
end

Next = function(pack)
	local index = pack.got + pack.failed + 1
	local song = pack.songs[index]
	if not song then return Finish(pack) end
	song.state = "downloading"
	local zip = "cb-rip-" .. pack.n .. "-" .. index .. ".zip"
	-- the bar: the songs in so far, and the file coming in now as it grows
	-- (DL.Measure reads it off the disk)
	local dl = state.downloads[pack.dlKey]
	if dl then
		dl.fileBase = dl.cur or 0
		dl.file = "/Downloads/" .. zip
	end
	-- a song with a video in it can run past a hundred megabytes
	DlRequest("/api/songzip/" .. song.id .. "/" .. UrlEncode(song.folder), {
		downloadFile = zip,
		connectTimeout = 15,
		transferTimeout = 900,
		onRetry = function(name)
			-- the retry's file starts from nothing
			if dl then
				dl.file = "/Downloads/" .. name
				dl.cur = dl.fileBase or dl.cur
			end
		end,
		onResponse = function(response)
			if state.retired then return end
			-- Unzip must run in here: the engine deletes the download when
			-- this returns
			if RelayOut(response) then
				-- the relay is off, and every song still to come would be
				-- refused the same way: stop here, with what is in
				pack.relayOut = true
				for i = index, #pack.songs do
					pack.songs[i].state = "failed"
					pack.songs[i].landedAt = GetTimeSinceStart()
				end
				pack.failed = #pack.songs - pack.got
				Refresh()
				return Finish(pack)
			end
			if response.error == nil and response.statusCode == 200
			   and FILEMAN:Unzip("/Downloads/" .. response.file, pack.dest, 0) then
				local delta = 0
				if SyncOf(song) ~= pack.sync then
					delta = (pack.sync == "ITG") and ITG_BIAS or -ITG_BIAS
				end
				if delta ~= 0 then
					local moved = false
					for name in ivalues(song.sims or {}) do
						if PATCH.ShiftOffsets(pack.dest .. song.folder .. "/" .. name, delta) then moved = true end
					end
					if moved then song.moved = delta end
				end
				song.state = "done"
				pack.got = pack.got + 1
			else
				song.state = "failed"
				pack.failed = pack.failed + 1
			end
			-- when, so its card can light up as it lands
			song.landedAt = GetTimeSinceStart()
			if dl then
				dl.cur = (dl.fileBase or 0) + (tonumber(song.bytes) or 0)
				dl.file = nil
			end
			Refresh()
			Next(pack)
		end,
	})
end

local function Landed(pack, response)
	local r = state.rip
	if r.pack ~= pack then return end
	local data
	if response.error == nil and response.statusCode == 200 then
		local ok, parsed = pcall(JsonDecode, response.body or "")
		if ok and type(parsed) == "table" then data = parsed end
	end
	local songs = data and data.songs
	if type(songs) ~= "table" or #songs == 0 then
		r.phase = "failed"
		r.phaseAt = GetTimeSinceStart()
		if RelayOut(response) then
			pack.relayOut = true
			pack.msg = RELAY_OUT
		elseif data and data.error then
			-- what the relay said is for the log, not the screen
			Trace("[Content Browser] booster search: " .. tostring(data.error))
			pack.msg = "the search didn't work - try again"
		elseif response.error ~= nil or response.statusCode ~= 200 then
			pack.msg = "the search didn't work: " .. Trouble(response, "booster search")
		else
			pack.msg = "no songs on stepmaniaonline.net match these settings"
		end
		Refresh()
		return
	end

	pack.songs = songs
	pack.short = #songs < RIP.SIZE
	-- the pack's own id, for KEEP to tell the site by (SayKept)
	pack.ripId = type(data.rip) == "string" and data.rip:match("^%x+$") or nil
	pack.total = 0
	for song in ivalues(songs) do
		pack.total = pack.total + (tonumber(song.bytes) or 0)
		song.state = "waiting"
		-- the card art, through the banner cache like any other art
		if type(song.art) == "string" and song.art ~= "" then
			song.artUrl = DlBase() .. song.art
			RequestBanner(song.artUrl, true)
		end
	end

	-- on the table, face up, for the player to keep or throw back
	r.phase = "choosing"
	r.choice = "keep"
	r.phaseAt = GetTimeSinceStart()
	pack.openedAt = r.phaseAt
	Refresh()
end

-- Tell the site the pack was kept, so its list of recent rips can mark it
-- kept and offer it for download: the id the relay gave the pack, and
-- nothing else. Nothing waits on the answer.
local function SayKept(pack)
	if not pack.ripId then return end
	local url = WebBase() .. "/api/rips/kept"
	if not NETWORK:IsUrlAllowed(url) then return end
	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = NETWORK:EncodeQueryParameters{ rip = pack.ripId },
		connectTimeout = 10,
		transferTimeout = 15,
	}
end

-- Keep the pack on the table: give it its number and its folder, and fetch
-- its songs one at a time, each card lighting up as its song lands.
function RIP.Keep()
	local r = state.rip
	local pack = r.pack
	if r.phase ~= "choosing" or not pack then return false end
	-- A library the game may not write: say once where the songs go instead,
	-- as the pack downloads' own dialog would.
	local lib = DL.ReadOnlyLibrary()
	if lib and not state.libraryOk then
		state.libraryOk = true
		Toast("Booster packs go to " .. DL.InsteadWords(lib))
	end

	local h = RIP.History()
	pack.n = NextNumber(h)
	pack.date = string.format("%04d-%02d-%02d", CurrentYear(), CurrentMonth(), CurrentDay())
	pack.folder = "Content Booster Pack " .. pack.n .. " - " .. pack.date
	pack.dest = "/Songs/" .. pack.folder .. "/"
	-- the number is taken now, so a second pack kept this session cannot take
	-- it too
	h.count = math.max(h.count, pack.n)
	SaveHistory(h)

	pack.sync = Majority(pack.songs)
	WritePackIni(pack)
	SayKept(pack)

	-- a download like any other: the ticker shows it, and the reload offer
	-- waits for it
	pack.dlKey = "rip:" .. pack.n
	state.downloads[pack.dlKey] = {
		status = "active", cur = 0, total = pack.total, name = pack.folder, rip = true,
	}
	state.dlOrder[#state.dlOrder+1] = pack.dlKey
	-- the clock that reads its progress off the disk (DL.Measure)
	if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end

	r.phase = "filling"
	r.phaseAt = GetTimeSinceStart()
	Refresh()
	Next(pack)
	return true
end

-- Rip one -- or rip again, throwing back the pack on the table. False and
-- why when it cannot start.
function RIP.Start()
	local r = state.rip
	if Busy() then return false, "a pack is still being ripped" end
	local base = WebBase()
	local url = base .. "/api/booster"
	if not NETWORK:IsUrlAllowed(url) then
		return false, "this needs network access - run the Content Browser installer again"
	end

	local pack = {
		songs = {}, got = 0, failed = 0, authors = RIP.Authors(), avoid = RIP.Avoid(),
		eras = RIP.ErasInOrder(), lo = r.lo, hi = r.hi, full = r.full,
	}
	-- a re-rip asks for songs other than the ones it throws back
	local exclude = {}
	if r.phase == "choosing" and r.pack then
		for song in ivalues(r.pack.songs or {}) do
			if song.key then exclude[#exclude+1] = tostring(song.key) end
		end
	end

	r.pack = pack
	r.phase = "searching"
	r.phaseAt = GetTimeSinceStart()
	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		-- authors one to a line: a credit can have a comma in it. eras is
		-- always sent, even empty: a relay that sees no eras field reads the
		-- old single era instead
		body = NETWORK:EncodeQueryParameters{
			n = tostring(RIP.SIZE),
			eras = table.concat(pack.eras, ","),
			lo = tostring(r.lo),
			hi = tostring(r.hi),
			full = r.full and "1" or "0",
			authors = table.concat(pack.authors, "\n"),
			avoid = table.concat(pack.avoid, "\n"),
			x = table.concat(exclude, ","),
		},
		connectTimeout = 15,
		transferTimeout = 90,
		onResponse = function(response)
			if state.retired then return end
			Landed(pack, response)
		end,
	}
	Refresh()
	return true
end

-- ---------------------------------------------------------------- the tab

-- Every option back to how the tab first opens, and the stage back to an
-- unopened pack -- a pack on the table is thrown back, and a search still
-- running is let go (its answer finds the stage moved on, and is dropped).
-- Not while a kept pack is coming in: its cards are what show it arriving.
function RIP.Reset()
	local r = state.rip
	if r.phase == "filling" then return false, "a pack is still downloading" end
	for key, value in pairs(DEFAULTS) do r[key] = value end
	r.chosen, r.eras = {}, {}
	r.picking = false
	r.pack, r.phase, r.choice = nil, "idle", "keep"
	r.phaseAt = GetTimeSinceStart()
	return true
end

function RIP.Enter()
	state.mode = "rip"
	state.zone = "list"
	state.rip.picking = false
	RIP.History()
	RIP.FetchAuthors()
	Refresh()
end

local function AskNumber(which)
	local r = state.rip
	OpenTextPrompt(
		(which == "lo" and "Lowest" or "Highest") .. " Expert meter (1 to " .. METER_MAX .. ")",
		tostring(r[which]), 2,
		function(answer)
			local v = tonumber(Trim(answer or ""))
			if not v then return end
			v = Clamp(math.floor(v), 1, METER_MAX)
			r[which] = v
			-- the other end moves out of the way rather than refusing
			if r.lo > r.hi then
				if which == "lo" then r.hi = r.lo else r.lo = r.hi end
			end
		end)
end

-- The list open over the tab -- eras or authors: Up and Down move through it,
-- Left and Right a screenful at a time, Start ticks or unticks the row under
-- the cursor, Select unticks them all, and Back closes it with what is ticked.
local function PickInput(button, firstPress)
	local r = state.rip
	local n = RIP.PickCount()
	local isUp    = (button == "MenuUp" or button == "Up")
	local isDown  = (button == "MenuDown" or button == "Down")
	local isLeft  = (button == "MenuLeft" or button == "Left")
	local isRight = (button == "MenuRight" or button == "Right")
	if button == "Back" then
		if not firstPress then return end
		r.picking = false
		PlaySfx("cancel")
	elseif isUp or isDown or isLeft or isRight then
		local step = (isUp and -1) or (isDown and 1) or (isLeft and -RIP.PICK_ROWS) or RIP.PICK_ROWS
		local at = Clamp(r.pickAt + step, 1, math.max(1, n))
		if at == r.pickAt then
			if firstPress then PlaySfx("invalid") end
			return
		end
		r.pickAt = at
		-- the list follows the cursor
		if r.pickAt < r.pickTop then r.pickTop = r.pickAt end
		if r.pickAt >= r.pickTop + RIP.PICK_ROWS then r.pickTop = r.pickAt - RIP.PICK_ROWS + 1 end
		PlaySfx("change")
	elseif button == "Start" and firstPress then
		local key = RIP.PickItem(r.pickAt)
		if not key then return end
		local set = PickSet()
		local i = RIP.PickTicked(key)
		if i then table.remove(set, i) else set[#set+1] = key end
		PlaySfx("change")
	elseif button == "Select" and firstPress then
		local set = PickSet()
		if #set == 0 then
			PlaySfx("invalid")
			return
		end
		for i = #set, 1, -1 do set[i] = nil end
		PlaySfx("change")
	end
	Refresh()
end

-- Open a list over the tab -- "era" or "author" -- on the first row ticked
-- in it when there is one, else on its first row.
local function OpenPicker(kind)
	local r = state.rip
	r.picking = kind
	local first = PickSet()[1]
	local n = RIP.PickCount()
	r.pickAt = 1
	if first then
		for i = 1, n do
			if RIP.PickItem(i) == first then r.pickAt = i break end
		end
	end
	r.pickAt = Clamp(r.pickAt, 1, math.max(1, n))
	r.pickTop = Clamp(r.pickAt - math.floor(RIP.PICK_ROWS / 2), 1, math.max(1, n - RIP.PICK_ROWS + 1))
end

-- Every key the tab's body answers to.
function RIP.Input(button, firstPress)
	local r = state.rip
	if r.picking then return PickInput(button, firstPress) end
	local isUp    = (button == "MenuUp" or button == "Up")
	local isDown  = (button == "MenuDown" or button == "Down")
	local isLeft  = (button == "MenuLeft" or button == "Left")
	local isRight = (button == "MenuRight" or button == "Right")
	local key = RIP.ROWS[r.row]

	if button == "Back" and firstPress then
		PlaySfx("cancel")
		state.zone = "tabs"
	elseif isUp then
		if r.row > 1 then
			r.row = r.row - 1
		elseif firstPress then
			state.zone = "tabs"
		end
		PlaySfx("change")
	elseif isDown then
		if r.row < #RIP.ROWS then
			r.row = r.row + 1
			PlaySfx("change")
		elseif firstPress then
			PlaySfx("invalid")
		end
	elseif isLeft or isRight then
		local step = isRight and 1 or -1
		if key == "lo" then
			r.lo = Clamp(r.lo + step, 1, r.hi)
		elseif key == "hi" then
			r.hi = Clamp(r.hi + step, r.lo, METER_MAX)
		elseif key == "full" then
			-- a yes or no does not repeat while the key is held
			if not firstPress then return end
			r.full = not r.full
		elseif key == "rip" and r.phase == "choosing" then
			-- the button row is a pair while a pack is on the table
			if not firstPress then return end
			r.choice = (r.choice == "keep") and "rerip" or "keep"
		else
			if firstPress then PlaySfx("invalid") end
			Refresh()
			return
		end
		PlaySfx("change")
	elseif button == "Start" and firstPress then
		if key == "era" then
			OpenPicker("era")
			PlaySfx("start")
		elseif key == "author" then
			if r.authorsStatus == "ready" and r.authors and #r.authors > 0 then
				OpenPicker("author")
				PlaySfx("start")
			elseif r.authorsStatus == "failed" then
				r.authorsStatus = nil
				RIP.FetchAuthors()
				PlaySfx("start")
			else
				PlaySfx("invalid")
			end
		elseif key == "typed" then
			PlaySfx("start")
			OpenTextPrompt("Chart authors, separated by commas", r.typed, 160,
				function(answer) r.typed = Trim(answer or "") end)
		elseif key == "avoid" then
			PlaySfx("start")
			OpenTextPrompt("Chart authors to avoid, separated by commas", r.avoid, 160,
				function(answer) r.avoid = Trim(answer or "") end)
		elseif key == "lo" or key == "hi" then
			PlaySfx("start")
			AskNumber(key)
		elseif key == "full" then
			r.full = not r.full
			PlaySfx("change")
		elseif key == "reset" then
			local ok, why = RIP.Reset()
			if ok then
				PlaySfx("cancel")
			else
				PlaySfx("invalid")
				Toast(tostring(why))
			end
		elseif key == "rip" and r.phase == "choosing" and r.choice == "keep" then
			if GetTimeSinceStart() - (r.phaseAt or 0) < DECIDE_GUARD then return end
			RIP.Keep()
			PlaySfx("start")
		elseif key == "rip" then
			-- a rip, or a re-rip of the pack on the table
			if r.phase == "choosing" and GetTimeSinceStart() - (r.phaseAt or 0) < DECIDE_GUARD then
				return
			end
			local ok, why = RIP.Start()
			if ok then
				PlaySfx("start")
			else
				PlaySfx("invalid")
				Toast(tostring(why))
			end
		else
			-- Start on a choice moves it along, as Right does
			return RIP.Input("MenuRight", true)
		end
	elseif button == "Select" and firstPress then
		-- Select clears the row the cursor is on back to "anyone"
		if key == "era" and #r.eras > 0 then
			r.eras = {}
			PlaySfx("change")
		elseif key == "typed" and r.typed ~= "" then
			r.typed = ""
			PlaySfx("change")
		elseif key == "avoid" and r.avoid ~= "" then
			r.avoid = ""
			PlaySfx("change")
		elseif key == "author" and #r.chosen > 0 then
			r.chosen = {}
			PlaySfx("change")
		elseif key == "author" and r.authorsStatus == "failed" then
			r.authorsStatus = nil
			RIP.FetchAuthors()
			PlaySfx("start")
		else
			PlaySfx("invalid")
		end
	end
	Refresh()
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.RIP      = RIP
-- the two the input part reaches at call time, since it loads first
CB.RipEnter = RIP.Enter
CB.RipInput = RIP.Input
