-- -----------------------------------------------------------------------
-- The screen's outermost frame
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local ActiveTabIndex       = CB.ActiveTabIndex
local BrowserInput         = CB.BrowserInput
local BuildFeatured        = CB.BuildFeatured
local CheckHelper          = CB.CheckHelper
local FetchPackTypes       = CB.FetchPackTypes
local FetchPacks           = CB.FetchPacks
local LO                   = CB.LO
local LiftAboveSystemLayer = CB.LiftAboveSystemLayer
local REFRESH_SECS         = CB.REFRESH_SECS
local AbandonSearch        = CB.AbandonSearch
local Refresh              = CB.Refresh
local SetRedirect          = CB.SetRedirect
local UP                   = CB.UP
local refs                 = CB.refs
local state                = CB.state

function CB.Screen.Frame()
	local af = Def.ActorFrame{
		Name = "SMOFindContentBrowser",

		ModuleCommand = function(self)
			refs.root = self
			LiftAboveSystemLayer(self, true)
			state.open = true
			state.textEntryOpen = false
			state.blockedReason = nil
			state.selected = nil
			state.zone = "list"
			-- stale UI state from a previous visit must not linger
			state.loadErr = nil
			state.loading = false
			-- a search or year slice belongs to the visit that made it; keeping it
			-- would show those rows under whichever tab happens to be active
			state.localRows = nil
			state.viewYear = nil
			AbandonSearch()
			state.search = ""
			-- converge any search term left by an interrupted text entry
			if state.pendingSearch ~= nil then
				state.search = state.pendingSearch
				state.pendingSearch = nil
				state.lastFetch = nil  -- force the refetch below
			end
			state.blockedReason = LO.BlockedReason()
			state.mode = state.blockedReason and "blocked" or "list"
			if state.mode == "list" then
				FetchPackTypes()
				local stale = (state.lastFetch == nil) or (GetTimeSinceStart() - state.lastFetch > REFRESH_SECS)
				if stale or #state.packs == 0 then
					state.page = 1
					state.pageOffsets = {}
					state.pageCache = {}
					FetchPacks(1, false)
				end
				local feat = state.featured
				local featStale = (feat.builtAt == nil) or (GetTimeSinceStart() - feat.builtAt > REFRESH_SECS)
				if feat.status == "idle" or feat.mode ~= state.filterMode or featStale then
					BuildFeatured()
				end
				-- the featured grid is where the eye should land first
				if #state.featured.cards > 0 or state.featured.status == "loading" then
					state.zone = "featured"
				elseif #state.packs == 0 then
					-- ...and the tab row when there is no grid to land on
					-- either, because a cursor in an empty list is a cursor
					-- nothing answers.
					--
					-- The keyboard filter has no featured grid at all --
					-- BuildFeatured returns "ready" holding nothing -- so the
					-- browser opened with the cursor in a pack list that page
					-- one had not arrived in yet. Down does nothing there: the
					-- list branch skips its whole body while the list is empty,
					-- and swallows every arrow outright while a page is in
					-- flight. So the first press vanished and the second one
					-- worked, and which you got depended on how quick the
					-- network was. The tab row always has something on it.
					--
					-- The installed view has drawn this line since it was
					-- written -- zone = packs > 0 and "list" or "tabs" -- and
					-- this is the same rule, applied where it was missing.
					state.tabIndex = ActiveTabIndex()
					state.zone = "tabs"
				end
			end

			MESSAGEMAN:Broadcast("SetHeaderText", {Text="Find Content"})

			local screen = SCREENMAN:GetTopScreen()
			if screen then
				-- make sure any engine-driven transition returns to the title
				screen:SetPrevScreenName("ScreenTitleMenu")
				screen:SetNextScreenName("ScreenTitleMenu")
				screen:AddInputCallback(BrowserInput)
				-- kept so an update can take it off again: the callback is
				-- registered on the screen, which outlives the overlay the
				-- module lives on, so a reload would otherwise leave this copy
				-- handling keys beside the new one
				UP.inputScreen, UP.inputCb = screen, BrowserInput
			end
			SetRedirect(true)

			-- and how much room the drive has, for the download gate
			LO.SpaceAsk()
			-- Say hello to the helper on the way in rather than waiting for the
			-- Installed tab. It costs one loopback request, queued behind the
			-- first page fetch so it cannot delay anything being drawn, and it
			-- is what tells the browser its own version is out of date.
			--
			-- Forced, so the port and token are read off disk again. The helper
			-- picks a fresh port every time it starts and publishes it there,
			-- and it starts again whenever it is upgraded -- so a browser that
			-- trusted the address it learned on its first visit would spend the
			-- rest of the session talking to a port nobody is listening on.
			CheckHelper(true)
			-- and if it had already said hello, ask right now instead
			UP.Check()

			self:playcommand("SMOArmHeartbeat")
			Refresh()
		end,
	}
	return af
end
