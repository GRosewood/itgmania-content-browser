-- -----------------------------------------------------------------------
-- Every key the browser answers to
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local ActiveTabIndex             = CB.ActiveTabIndex
local ApplyFilterRefetch         = CB.ApplyFilterRefetch
local BROWSER_SCREEN             = CB.BROWSER_SCREEN
local BuildFeatured              = CB.BuildFeatured
local CheckHelper                = CB.CheckHelper
local Clamp                      = CB.Clamp
local CurrentPack                = CB.CurrentPack
local DL                         = CB.DL
local DeletePack                 = CB.DeletePack
local DownloadsActive            = CB.DownloadsActive
local EnterInstalled             = CB.EnterInstalled
local EnterLevelView             = CB.EnterLevelView
local EnterYearView              = CB.EnterYearView
local FEAT                       = CB.FEAT
local FetchDetail                = CB.FetchDetail
local FetchPackTypes             = CB.FetchPackTypes
local FetchPacks                 = CB.FetchPacks
local INST_COLS                  = CB.INST_COLS
local INST_ROWS                  = CB.INST_ROWS
local InInstalledView            = CB.InInstalledView
local InLevelView                = CB.InLevelView
local InYearView                 = CB.InYearView
local InstalledPack              = CB.InstalledPack
-- The table itself is created in 04 and filled in 23, which loads after this
-- part -- but a table crosses by reference, and nothing here reads it until a
-- key is pressed, long after every part has run.
local LO                         = CB.LO
local LEVEL                      = CB.LEVEL
local LeaveBrowser               = CB.LeaveBrowser
local OpenSearchPrompt           = CB.OpenSearchPrompt
local PlaySfx                    = CB.PlaySfx
local ROWS                       = CB.ROWS
local ReclaimInputAfterTextEntry = CB.ReclaimInputAfterTextEntry
local Refresh                    = CB.Refresh
local SONG_ROWS                  = CB.SONG_ROWS
local SelectYear                 = CB.SelectYear
local Snd                        = CB.Snd
local Sync                       = CB.Sync
local TabOrder                   = CB.TabOrder
local Toast                      = CB.Toast
local TotalPages                 = CB.TotalPages
local UP                         = CB.UP
local YearList                   = CB.YearList
local refs                       = CB.refs
local state                      = CB.state


-- Open a pack's detail page.
--
-- Three zones can do it -- the list, the featured grid, the doubles columns
-- -- and the ritual is identical: remember where to come back to, reset the
-- page's cursors, forgive any earlier failed fetch, and ask again. It was
-- pasted at all three call sites once, and the copies were one absent-minded
-- edit away from disagreeing about what opening a pack means.
local function OpenDetail(pack)
	PlaySfx("start")
	state.selected = pack
	state.returnMode = state.mode
	state.mode = "detail"
	state.songCursor = 0
	state.songPick = 1
	state.detailZone = "songs"
	state.detailFailed[pack.id] = nil
	FetchDetail(pack, nil, true)
	Refresh()
end

local BrowserInput = function(event)
	if state.retired then return false end
	if not (event and event.type and event.GameButton) then return false end
	if not state.open then return false end
	if state.textEntryOpen then
		-- safety net: if the watcher chain ever got lost, reclaim here
		local top = SCREENMAN:GetTopScreen()
		if top and top:GetName() == BROWSER_SCREEN then
			ReclaimInputAfterTextEntry()
		end
		return false
	end
	if event.type == "InputEventType_Release" then return false end

	local button = event.GameButton
	local firstPress = (event.type == "InputEventType_FirstPress")

	-- restart the download-progress heartbeat on any input, just in case
	if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end

	if state.mode == "blocked" then
		-- network access is not set up; this screen only explains the fix
		if (button == "Back" or button == "Start") and firstPress then
			PlaySfx("cancel")
			LeaveBrowser("ScreenTitleMenu")
		end
		return false
	end

	if state.mode == "list" or state.mode == "installed" or state.mode == "year"
	   or InLevelView() then
		local isUp    = (button == "MenuUp" or button == "Up")
		local isDown  = (button == "MenuDown" or button == "Down")
		local isLeft  = (button == "MenuLeft" or button == "Left")
		local isRight = (button == "MenuRight" or button == "Right")
		local feat = state.featured

		-- shared handlers

		-- Rebuild the list this view is showing, from its sources rather than
		-- from what is kept.  Two ways to ask, one thing done.
		local function ReloadThisView()
			PlaySfx("start")
			if state.mode == "list" then
				-- A plain filter tab has no list of its own to rebuild; what it
				-- has is pages that are now kept between visits, so asking for
				-- it fresh means dropping those and fetching page one again.
				state.pageCache = {}
				state.pageOffsets = {}
				state.page = 1
				state.cursor = 1
				state.lastFetch = nil
				state.featured.builtAt = nil
				FetchPacks(1)
				BuildFeatured()
			elseif InYearView() then
				LEVEL.Reload("year")
				EnterYearView()
			else
				local bucket = state.mode
				LEVEL.Reload(bucket)
				EnterLevelView(bucket)
				-- asking for it outright is as clear a decision as stopping on
				-- the tab, so it does not wait out the settle
				LEVEL.Begin()
			end
			Toast("Reloading the list...")
			Refresh()
		end

		-- SELECT asks for this tab fresh, whichever tab it is.
		--
		-- It used to be only the views that build a list of their own, because
		-- those were the only ones kept between visits. Every tab is kept now
		-- -- that is what stops a step off a tab and back costing a round of
		-- requests -- so every tab needs a way to say "no, actually go and
		-- look again".
		if button == "Select" and firstPress
		   and (InLevelView() or InYearView() or state.mode == "list") then
			ReloadThisView()
			return false
		end

		if button == "Back" and firstPress then
			-- Back climbs out of where you are before it leaves.
			--
			-- Paging into the older years puts a reader hundreds of rows from
			-- where they started, and one press throwing all of that away is a
			-- poor trade -- Back there almost always means "out of this list",
			-- not "out of the browser". So it steps up a rung at a time: the
			-- pack list to the year row, the year row to the tabs, and only
			-- from the tabs does it leave. The list itself is left where it
			-- was, so coming back down lands where you were.
			if state.zone ~= "tabs" then
				PlaySfx("cancel")
				if InYearView() and state.zone ~= "years" then
					state.zone = "years"
				elseif state.mode == "doubles" and state.doubles.zone == "rows" then
					-- out of the rows is back to choosing a column, not all
					-- the way to the tabs -- the same rung it came down
					state.doubles.zone = "pick"
				else
					state.tabIndex = ActiveTabIndex()
					state.zone = "tabs"
				end
				Refresh()
				return false
			end

			PlaySfx("cancel")
			-- don't offer the song reload while a download is still running;
			-- it would race the unzip and lose track of the new pack
			if state.needsReload and not DownloadsActive() then
				state.reloadIdx = 1
				state.mode = "reload"
				Refresh()
			else
				if DownloadsActive() then
					SCREENMAN:SystemMessage("Pack download continues in the background")
				end
				LeaveBrowser("ScreenTitleMenu")
			end
			return false
		end

		-- the update chip, one step past the last tab
		if state.zone == "update" then
			if isLeft and firstPress then
				state.zone = "tabs"
				PlaySfx("change")
				Refresh()
			elseif isRight and firstPress then
				-- round to the front, the way the tab row already wraps
				state.zone = "tabs"
				state.tabIndex = 1
				PlaySfx("change")
				Refresh()
			elseif isDown and firstPress then
				state.zone = "tabs"
				PlaySfx("change")
				Refresh()
			elseif button == "Start" and firstPress then
				PlaySfx("start")
				state.mode = "update"
				if not UP.Start() then
					UP.job = { phase = "error", done = true, pct = -1,
						error = "the helper is not running" }
				end
				-- start the clock that reads its progress
				if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end
				Refresh()
			elseif button == "Back" and firstPress then
				PlaySfx("cancel")
				LeaveBrowser("ScreenTitleMenu")
			end
			return false
		end

		if state.zone == "tabs" then
			-- One step right off the end of the row is the update chip, when
			-- there is one. It is the only thing up there that is not a view,
			-- so it sits after all of them rather than in among them.
			if isRight and firstPress and state.tabIndex == #TabOrder
			   and UP.Available() then
				state.zone = "update"
				PlaySfx("change")
				Refresh()
				return false
			end

			-- Left/Right cycles the pad/keyboard filter and applies it
			if (isLeft or isRight) and firstPress then
				-- The row is moving. Nothing asks the network on behalf of a
				-- view the cursor is only passing over -- the keyboard list
				-- alone used to queue a pack page per visible row, and on a
				-- single-worker queue those land in front of whatever the
				-- reader actually stops on.
				state.settled = false
				if refs.settle then refs.settle:playcommand("SMOArmSettle") end
				local index = state.tabIndex + (isRight and 1 or -1)
				if index < 1 then index = #TabOrder end
				if index > #TabOrder then index = 1 end
				state.tabIndex = index
				PlaySfx("change")
				local choice = TabOrder[index]
				if choice == "installed" then
					EnterInstalled()
					state.zone = "tabs"
					Refresh()
				elseif choice == "year" then
					EnterYearView()
					state.zone = "tabs"
					Refresh()
				elseif choice == "tech" or choice == "stamina"
				       or choice == "beginner" or choice == "doubles" then
					EnterLevelView(choice)
					state.zone = "tabs"
					Refresh()
				elseif choice == "search" then
					-- only focuses; Start opens the prompt.  Cycling past a tab
					-- must not pop a keyboard up.
					Refresh()
				else
					state.mode = "list"
					state.filterMode = choice
					FetchPackTypes()
					ApplyFilterRefetch()
				end
			elseif button == "Start" and firstPress and TabOrder[state.tabIndex] == "search" then
				PlaySfx("start")
				OpenSearchPrompt()
			elseif isDown or (button == "Start" and firstPress) then
				PlaySfx("change")
				-- moving into the body is as clear a decision as stopping on
				-- the tab, so it does not wait out the settle
				LEVEL.Begin()
				if state.mode == "installed" then
					state.zone = (#state.installed.packs > 0) and "list" or "tabs"
				elseif state.mode == "year" then
					state.zone = "years"
				elseif state.mode == "list" and state.search == ""
				       and (#feat.cards > 0 or feat.status == "loading") then
					state.zone = "featured"
				else
					state.zone = "list"
					-- the doubles tab opens on its column picker, on a
					-- column that has something to look at
					if state.mode == "doubles" then
						local d = state.doubles
						d.zone = "pick"
						if #d.left == 0 and #d.right > 0 then d.col = 2 end
					end
				end
				Refresh()
			end
			return false
		end

		if state.mode == "installed" then
			local inst = state.installed
			local perCol = INST_ROWS / INST_COLS
			local slot   = inst.cursor - inst.window          -- 1 .. INST_ROWS
			local col    = math.floor((slot - 1) / perCol)
			local row    = (slot - 1) % perCol
			local page   = math.floor(inst.window / INST_ROWS)

			-- move to an absolute (page, column, row); false when nothing is
			-- there, which is what makes the edges of the grid feel solid
			local function goTo(p, c, r)
				if p < 0 or c < 0 or c >= INST_COLS then return false end
				if r < 0 or r >= perCol then return false end
				local index = p * INST_ROWS + c * perCol + r + 1
				if index < 1 or index > #inst.packs then return false end
				inst.window = p * INST_ROWS
				inst.cursor = index
				return true
			end

			if isUp then
				-- up the column, carrying back a page at its top
				if goTo(page, col, row - 1) or goTo(page - 1, col, perCol - 1) then
					PlaySfx("change")
				else
					PlaySfx("change")
					state.zone = "tabs"
				end
				Refresh()
			elseif isDown then
				-- down the column, carrying to the next page at its bottom
				if goTo(page, col, row + 1) or goTo(page + 1, col, 0) then
					PlaySfx("change")
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif isLeft then
				if goTo(page, col - 1, row) or goTo(page - 1, INST_COLS - 1, row) then
					PlaySfx("change")
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif isRight then
				if goTo(page, col + 1, row) or goTo(page + 1, 0, row) then
					PlaySfx("change")
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif button == "Select" and firstPress then
				-- Select removes, Start explains.
				--
				-- They were the other way round, with the destructive one on
				-- the button every other list uses to open something. Removing
				-- a pack is the rarer act and the one that cannot be undone, so
				-- it is the one that moved off Start.
				local pack = InstalledPack()
				if not pack or state.removing then
					PlaySfx("invalid")
				elseif state.helper.status ~= "ready" then
					PlaySfx("invalid")
					CheckHelper(true)
					Toast(state.helper.reason or "pack removal is unavailable")
				else
					PlaySfx("start")
					state.mode = "removeconfirm"
					Refresh()
				end
			elseif button == "Start" and firstPress then
				PlaySfx("start")
				state.syncFrom = state.mode
				state.syncPack = InstalledPack()
				state.syncChoice = Sync.Suggest(state.syncPack)
				state.syncNote = nil
				state.mode = "sync"
				Refresh()
			end
			return false
		end

		if state.zone == "years" then
			local years = YearList()
			if isLeft or isRight then
				local want = state.yearCursor + (isRight and 1 or -1)
				if want >= 1 and want <= #years then
					state.yearCursor = want
					PlaySfx("change")
					SelectYear(years[want])
				else
					PlaySfx("invalid")
				end
			elseif isUp then
				PlaySfx("change")
				state.tabIndex = ActiveTabIndex()
				state.zone = "tabs"
				Refresh()
			elseif isDown or (button == "Start" and firstPress) then
				PlaySfx("change")
				state.zone = "list"
				Refresh()
			end
			return false
		end

		if state.zone == "featured" then
			local page, row, col = FEAT.Page(), FEAT.RowCol()
			if isLeft then
				-- along the row, carrying back a page at the left edge
				local moved = (col > 0 and FEAT.Goto(page, row, col - 1))
					or (col == 0 and FEAT.Goto(page - 1, row, FEAT.COLS - 1))
				if moved then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("invalid")
				end
			elseif isRight then
				local moved = (col < FEAT.COLS - 1 and FEAT.Goto(page, row, col + 1))
					or (col == FEAT.COLS - 1 and FEAT.Goto(page + 1, row, 0))
				if moved then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("invalid")
				end
			elseif isUp then
				-- up a row inside the grid, else out to the tabs
				if FEAT.Goto(page, row - 1, col) then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("change")
					state.tabIndex = ActiveTabIndex()
					state.zone = "tabs"
					Refresh()
				end
			elseif isDown then
				-- down a row inside the grid, else on into the list
				if FEAT.Goto(page, row + 1, col) then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("change")
					state.zone = "list"
					Refresh()
				end
			elseif button == "Start" and firstPress then
				local pack = CurrentPack()
				if pack then
					OpenDetail(pack)
				else
					PlaySfx("invalid")
				end
			end
			return false
		end

		-- zone == "list"

		-- The doubles view is two columns rather than a page, so it moves by
		-- its own rules: down a column, across to the other, and the window
		-- follows the cursor instead of the list turning over a page at a time.
		if state.mode == "doubles" then
			local d = state.doubles
			local function Column(c) return (c == 2) and d.right or d.left end

			-- put the cursor on an absolute row of a column, scrolling that
			-- column if the row is off screen; false when there is no such row,
			-- which is what makes the ends of a column feel solid
			local function goTo(c, index)
				local list = Column(c)
				if index < 1 or index > #list then return false end
				if index <= d.win[c] then
					d.win[c] = index - 1
				elseif index > d.win[c] + LEVEL.DBL_ROWS then
					d.win[c] = index - LEVEL.DBL_ROWS
				end
				d.col, d.row = c, index - d.win[c]
				return true
			end

			-- The column picker: both lists on screen, one focused whole.
			--
			-- Without it the cursor arrived already deep inside the left
			-- column, and the only road to the right one was paging to the
			-- left one's end -- a thing nothing on the screen suggested. Here
			-- Left and Right move the focus between the LISTS, Down or Start
			-- dives into the focused one, Up climbs to the tabs; the same
			-- rungs run in reverse on the way out.
			if d.zone ~= "rows" then
				if isLeft or isRight then
					local want = isRight and 2 or 1
					if want ~= d.col then
						PlaySfx("change")
						d.col = want
					else
						PlaySfx("invalid")
					end
					Refresh()
				elseif isDown or (button == "Start" and firstPress) then
					if #Column(d.col) > 0 then
						PlaySfx("change")
						d.zone = "rows"
					else
						-- an empty column can be looked at, not entered
						PlaySfx("invalid")
					end
					Refresh()
				elseif isUp then
					PlaySfx("change")
					state.tabIndex = ActiveTabIndex()
					state.zone = "tabs"
					Refresh()
				end
				return false
			end

			local here = d.win[d.col] + d.row
			if isUp then
				if goTo(d.col, here - 1) then
					PlaySfx("change")
				else
					-- the top of a column climbs back to the column picker
					PlaySfx("change")
					d.zone = "pick"
				end
				Refresh()
			elseif isDown then
				if goTo(d.col, here + 1) then
					PlaySfx("change")
				elseif d.col == 2 and LEVEL.Extend() then
					-- the bottom of the partial column is only the bottom of
					-- what has been read so far
					PlaySfx("change")
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif isLeft or isRight then
				-- Left and Right page the column you are in, the way they page
				-- every other list here. Only at the end of a column do they
				-- hand over to the other one -- so the two columns are sticky,
				-- and a press meant for paging cannot throw the cursor across
				-- the screen.
				local step = isRight and LEVEL.DBL_ROWS or -LEVEL.DBL_ROWS
				local mine = #Column(d.col)
				-- Written out rather than as "isRight and A or B". That form
				-- reads as a conditional right up until A is false, at which
				-- point it quietly answers B instead -- so pressing Right on
				-- the first row of a column, which is where the cursor lands
				-- when it arrives, evaluated (here <= 1), decided the column
				-- had ended, and went off to fetch more packs rather than
				-- turning the page it was asked for.
				local ends
				if isRight then
					ends = (here >= mine)
				else
					ends = (here <= 1)
				end
				if not ends and goTo(d.col, Clamp(here + step, 1, mine)) then
					PlaySfx("change")
				elseif ends then
					local other = isRight and 2 or 1
					if other ~= d.col and #Column(other) > 0
					   and goTo(other, isRight and 1 or #Column(other)) then
						PlaySfx("change")
					elseif isRight and d.col == 2 and LEVEL.Extend() then
						-- the partial column's end is only the end of what has
						-- been read so far
						PlaySfx("change")
					else
						PlaySfx("invalid")
					end
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif button == "Start" and firstPress then
				local pack = CurrentPack()
				if pack then
					OpenDetail(pack)
				else
					PlaySfx("invalid")
				end
			end
			return false
		end

		-- A page request is still out. Swallow navigation until it lands, so a
		-- fast scroll cannot queue up page changes or leave the cursor pointing
		-- into a page that is about to be replaced.
		if state.fetchReq and (isUp or isDown or isLeft or isRight) then
			return false
		end

		if isUp then
			if state.cursor > 1 then
				state.cursor = state.cursor - 1
				PlaySfx("change")
				Refresh()
			elseif state.page > 1 then
				-- still list above: page back rather than leaving it. Holding
				-- Up walks the whole list to its top before the featured grid
				-- takes the cursor.
				PlaySfx("change")
				state.cursor = ROWS
				FetchPacks(state.page - 1, true)
			else
				-- top of the list: move up into whatever strip is above it
				PlaySfx("change")
				if state.mode == "year" then
					state.zone = "years"
				elseif state.mode == "list" and state.search == ""
				       and (#feat.cards > 0 or feat.status == "loading") then
					state.zone = "featured"
				else
					state.tabIndex = ActiveTabIndex()
					state.zone = "tabs"
				end
				Refresh()
			end
		elseif isDown then
			if #state.packs > 0 then
				if state.cursor < #state.packs then
					state.cursor = state.cursor + 1
				elseif state.page < TotalPages() then
					state.cursor = 1
					FetchPacks(state.page + 1, true)
				elseif InLevelView() and LEVEL.Extend() then
					-- end of what has been gathered: go and get more
				elseif InLevelView() and state.level
				       and state.level.status == "loading" then
					-- more is already on its way. The end of a list that is
					-- still growing is not the top of it -- wrapping here made
					-- the same key mean "fetch more" or "throw me to row one"
					-- depending on timing nothing on screen showed.
				else
					state.cursor = 1
				end
				PlaySfx("change")
				Refresh()
			end
		elseif isLeft then
			if state.page > 1 then
				PlaySfx("change")
				state.cursor = 1
				FetchPacks(state.page - 1, true)
			else
				-- The front of the list, and that is all it is.
				--
				-- Left used to rebuild the view from here, which meant a key
				-- pressed for paging could throw away a walk of a hundred pack
				-- pages. Rebuilding is a decision and it has its own button:
				-- SELECT, which the foot of the screen names.
				PlaySfx("invalid")
			end
		elseif isRight then
			if state.page < TotalPages() then
				PlaySfx("change")
				state.cursor = 1
				FetchPacks(state.page + 1, true)
			elseif InLevelView() and LEVEL.Extend() then
				-- end of what has been gathered: go and get more
				PlaySfx("change")
				Refresh()
			else
				PlaySfx("invalid")
			end
		elseif button == "Start" and firstPress then
			local pack = CurrentPack()
			if pack then
				OpenDetail(pack)
			else
				PlaySfx("invalid")
			end
		end
		return false
	end

	if state.mode == "detail" then
		local pack = CurrentPack()
		local det = pack and state.details[pack.id]
		local numSongs = det and #det.songs or 0
		local maxScroll = math.max(0, numSongs - SONG_ROWS)

		-- The highlight moves and the window follows it, rather than the window
		-- dragging songs through fixed rows. Two things fall out of that: a
		-- highlighted song is something "play this one" can refer to, and a
		-- move that stays inside the visible window rebinds no rows at all, so
		-- most presses cost nothing in texture loads.
		local function MovePick(delta)
			if numSongs == 0 then return end
			local want = Clamp(state.songPick + delta, 1, numSongs)
			if want == state.songPick then return end
			state.songPick = want
			if want <= state.songCursor then
				state.songCursor = want - 1
			elseif want > state.songCursor + SONG_ROWS then
				state.songCursor = want - SONG_ROWS
			end
			state.songCursor = Clamp(state.songCursor, 0, maxScroll)
			PlaySfx("change")
			Refresh()
		end

		-- The download button sits above the song list, so Up off the first
		-- song reaches it and Down comes back. It is one press from the top of
		-- the page rather than three through a popup, which is what somebody
		-- who came here to install the pack wanted all along.
		local onButton = (state.detailZone == "download")

		-- While a preview is playing, Up and Down move through the
		-- difficulties it is showing rather than through the song list. The
		-- window is what the reader is looking at, and the difficulties are
		-- laid out in it -- and nothing is fetched to change between them.
		-- Not gated on firstPress: the engine sends repeats while a key is
		-- held, and the song list below takes them. A held Down used to step
		-- the difficulty once and then scroll the song list underneath the
		-- window for as long as it was held.
		if Snd.ChartOn()
		   and (button == "MenuUp" or button == "Up"
		        or button == "MenuDown" or button == "Down") then
			local up = (button == "MenuUp" or button == "Up")
			if Snd.Step(up and -1 or 1) then
				PlaySfx("change")
			else
				PlaySfx("invalid")
			end
			Refresh()
			return false
		end

		if button == "MenuUp" or button == "Up" then
			if onButton then
				PlaySfx("invalid")
			elseif state.songPick <= 1 then
				PlaySfx("change")
				state.detailZone = "download"
				Refresh()
			else
				MovePick(-1)
			end
		elseif button == "MenuDown" or button == "Down" then
			if onButton then
				PlaySfx("change")
				state.detailZone = "songs"
				Refresh()
			else
				MovePick(1)
			end
		elseif button == "MenuLeft" or button == "Left" then
			if onButton then PlaySfx("invalid") else MovePick(-SONG_ROWS) end
		elseif button == "MenuRight" or button == "Right" then
			if onButton then PlaySfx("invalid") else MovePick(SONG_ROWS) end
		elseif button == "Select" and firstPress then
			if Snd.Busy() then
				PlaySfx("cancel")
				Snd.Stop()
			elseif pack and LO.DetailLost(pack) then
				-- Nothing loaded, so there is no song to preview and Select is
				-- free to mean the only thing worth doing here: ask again. The
				-- force flag walks past the failure cooldown, because a person
				-- pressing a key is a better reason to retry than a timer.
				PlaySfx("start")
				state.detailFailed[pack.id] = nil
				FetchDetail(pack, nil, true)
				Refresh()
			elseif not onButton then
				-- hear the song rather than read about it
				Snd.Play(pack, det and det.songs[state.songPick] or nil)
			else
				PlaySfx("invalid")
			end
		elseif button == "Start" and firstPress then
			if Snd.Busy() then
				PlaySfx("cancel")
				Snd.Stop()
			elseif onButton then
				-- the button says one thing, so it does that one thing
				DL.Ask(pack)
				Refresh()
			elseif pack then
				PlaySfx("start")
				state.chooseIdx = 1
				-- the difficulty offered belongs to the song this opened on
				Snd.pick = nil
				state.mode = "confirm"
				Refresh()
			else
				PlaySfx("invalid")
			end
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			Snd.Stop(true)
			-- back to whichever list opened this pack, not always the plain one
			state.mode = state.returnMode or "list"
			state.returnMode = nil
			state.selected = nil
			Refresh()
		end
		return false
	end

	if state.mode == "removeconfirm" then
		if button == "Start" and firstPress then
			local pack = InstalledPack()
			PlaySfx("start")
			state.mode = "installed"
			Refresh()
			if pack then
				Toast("Removing " .. pack.name .. "...")
				DeletePack(pack, function(ok, why)
					if ok then
						-- the files are gone but SONGMAN still holds the group, so
						-- offer the same song reload a download does
						state.needsReload = true
						state.reloadGone = state.reloadGone + 1
						-- and forget that it was ever downloaded: the record is
						-- what the download button reads, and a pack removed
						-- with its record left behind answered "already
						-- installed" for the rest of the session, with nothing
						-- installed and no way to get it back
						DL.Forget(pack)
						Toast("Removed " .. pack.name)
					else
						Toast("Could not remove " .. pack.name .. ": " .. tostring(why))
					end
					-- The row is taken out of the list rather than the list
					-- being rebuilt.
					--
					-- Rebuilding put it straight back. The list is built from
					-- SONGMAN GetSongGroupNames, which is the library the engine
					-- has loaded, not what is on disk -- and the engine goes on
					-- holding a group whose folder has just been deleted until
					-- songs are reloaded. So the rescan faithfully reported the
					-- pack that had, in fact, just been removed.
					--
					-- The cursor stays where it was, so whatever moved up into
					-- that row is what is now under it.
					local inst = state.installed
					local at = inst.cursor
					if ok then
						for i = #inst.packs, 1, -1 do
							local row = inst.packs[i]
							if row == pack or row.name == pack.name then
								table.remove(inst.packs, i)
							end
						end
					end
					local count = #inst.packs
					inst.cursor = Clamp(at, 1, math.max(1, count))
					inst.window = math.min(inst.window,
						math.max(0, math.floor(math.max(0, count - 1) / INST_ROWS) * INST_ROWS))
					Refresh()
				end)
			end
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			state.mode = "installed"
			Refresh()
		end
		return false
	end

	if state.mode == "confirm" then
		-- Up and Down pick the difficulty the preview would play, when the
		-- song has been played once and its difficulties are known. Nothing
		-- else in this dialog uses them.
		if (button == "MenuUp" or button == "Up"
		    or button == "MenuDown" or button == "Down") and firstPress then
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			local song = det and det.songs[state.songPick] or nil
			local up = (button == "MenuUp" or button == "Up")
			if state.chooseIdx == 1 and Snd.Cycle(song, pack, up and -1 or 1) then
				PlaySfx("change")
			else
				PlaySfx("invalid")
			end
			Refresh()
			return false
		end
		local pack = CurrentPack()
		local det = pack and state.details[pack.id]
		local song = det and det.songs[state.songPick] or nil

		if (button == "MenuLeft" or button == "Left"
		    or button == "MenuRight" or button == "Right") and firstPress then
			local step = (button == "MenuRight" or button == "Right") and 1 or -1
			state.chooseIdx = ((state.chooseIdx - 1 + step) % 3) + 1
			PlaySfx("change")
			Refresh()
		elseif button == "Start" and firstPress then
			if state.chooseIdx == 2 then
				-- one song, into the singles pack for its sync
				local ok, why = DL.StartSong(pack, song)
				if ok then
					PlaySfx("start")
					Toast(song.title .. " - going to " .. Sync.SinglesFolder(pack))
					if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end
				else
					PlaySfx("invalid")
					Toast(tostring(why))
				end
				-- the difficulty this dialog was offering goes with it; only a
				-- preview consumes one, and this was not a preview
				Snd.pick = nil
				state.mode = "detail"
				Refresh()
			elseif state.chooseIdx == 1 then
				-- close the dialog first: the sample reports its own progress
				-- into the screen behind it.  Snd.Play takes the pick.
				state.mode = "detail"
				Refresh()
				Snd.Play(pack, song)
			else
				DL.Ask(pack)
				Snd.pick = nil
				state.mode = "detail"
				Refresh()
			end
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			Snd.pick = nil
			state.mode = "detail"
			Refresh()
		end
		return false
	end

	if state.mode == "sync" then
		local pack = state.syncPack
		-- the same test the screen uses: ours to change, or nobody's yet
		local canWrite = (pack ~= nil) and (pack.dir ~= nil)
			and (pack.sync == nil or pack.syncOurs)
		if (button == "MenuLeft" or button == "Left"
		    or button == "MenuRight" or button == "Right") and firstPress then
			if canWrite then
				state.syncChoice = (state.syncChoice == "NULL") and "ITG" or "NULL"
				PlaySfx("change")
			else
				PlaySfx("invalid")
			end
			Refresh()
		elseif button == "Start" and firstPress then
			if state.syncNote then
				-- the OK: the writing is done and this is the way out
				PlaySfx("start")
				state.mode = state.syncFrom or "list"
				state.syncPack = nil
				state.syncNote = nil
				Refresh()
				return false
			end
			if canWrite then
				local ok, why = Sync.Write(pack.dir, state.syncChoice)
				if ok then
					PlaySfx("start")
					state.syncNote = "Written: SyncOffset=" .. state.syncChoice
						.. ". The library was loaded before this file existed, so reload "
						.. "songs (or restart) before it takes effect."
					state.needsReload = true
					-- The row is this same table, so telling it what was just
					-- written updates the list behind the popup at once: the
					-- marker goes green under the cursor while you are still
					-- looking at it.
					--
					-- Told rather than re-read. A rescan would ask the file
					-- manager whether Pack.ini exists, and its answer comes from
					-- a directory listing it caches for half a minute -- so the
					-- file just written can still be invisible, and the row
					-- would sit amber until something else happened. A rescan
					-- also resets the cursor and scroll, throwing away the place
					-- in the list the reader was working through.
					pack.sync     = state.syncChoice
					pack.syncOurs = true
					pack.syncFile = "Pack.ini"
					pack.hasIni   = true
				else
					PlaySfx("invalid")
					state.syncNote = "Not written: " .. tostring(why)
				end
			else
				PlaySfx("cancel")
				state.mode = state.syncFrom or "list"
			end
			Refresh()
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			state.mode = state.syncFrom or "list"
			state.syncPack = nil
			state.syncNote = nil
			Refresh()
		end
		return false
	end

	if state.mode == "update" then
		-- Only a failure has a way out: while it is working, the dialog is a
		-- statement rather than a question, and there is nothing useful a key
		-- could do to a module being written over.
		local failed = UP.job ~= nil and UP.job.phase == "error"
		if failed and (button == "Start" or button == "Back") and firstPress then
			PlaySfx("cancel")
			UP.job = nil
			state.mode = InInstalledView() and "installed"
			             or InYearView() and "year" or "list"
			Refresh()
		end
		return false
	end

	if state.mode == "reload" then
		if (button == "MenuLeft" or button == "Left"
		    or button == "MenuRight" or button == "Right") and firstPress then
			local want = (button == "MenuLeft" or button == "Left") and 1 or 2
			if want ~= state.reloadIdx then
				state.reloadIdx = want
				PlaySfx("change")
			else
				PlaySfx("invalid")
			end
			Refresh()
			return false
		end
		if button == "Start" and firstPress then
			if state.reloadIdx == 2 then
				-- "Not yet" is the same as backing out, and saying so with the
				-- same key as "go" is the point of making it a choice
				PlaySfx("cancel")
				LeaveBrowser("ScreenTitleMenu")
				return false
			end
			PlaySfx("start")
			state.needsReload = false
			state.reloadPacks, state.reloadSongs, state.reloadGone = 0, 0, 0
			state.reloadForUs = true
			LeaveBrowser("ScreenReloadSongsSSM")
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			LeaveBrowser("ScreenTitleMenu")
		end
		return false
	end

	return false
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.BrowserInput = BrowserInput
