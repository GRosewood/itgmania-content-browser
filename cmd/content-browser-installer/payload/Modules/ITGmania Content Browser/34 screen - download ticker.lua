-- -----------------------------------------------------------------------
-- The download ticker
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor = CB.AccentColor
local Clamp       = CB.Clamp
local DL          = CB.DL
local InLevelView = CB.InLevelView
local InPackList  = CB.InPackList
local LO          = CB.LO
local Spinner     = CB.Spinner
local TotalPages  = CB.TotalPages
local state       = CB.state

function CB.Screen.DownloadTicker(ui)
	-- ---------------------------------------------------------------
	-- The download ticker.
	--
	-- Downloads outlive the screen that started them, so this is the only place
	-- they can be seen from once the player has moved on -- and the only thing
	-- that makes starting a second one feel deliberate rather than lost.
	--
	-- It used to sit in the top right, which is where the tab row went when the
	-- header was condensed, so the two overlapped. Here it has a lane of its
	-- own under the page, inside the band that already covers the engine's
	-- credits: nothing else is drawn there on any screen, so it cannot collide
	-- with a list, a detail page, a dialog or the header.
	local TICK_Y    = LO.CONTENT_BOT + 30
	local TICK_SLOT = 196
	local TICK_GAP  = 14
	local TICK_PITCH = TICK_SLOT + TICK_GAP
	local TICK_SLOTS = 6
	local TICK_LEFT = LO.LIST_X

	-- How far the row has travelled. It only moves when there is more in it
	-- than fits: a queue of one should sit still and be read, not slide.
	local function TickShift()
		local n = #state.dlRows
		local span = n * TICK_PITCH
		local room = LO.W - 2*LO.LIST_X - 120   -- the count on the right keeps its place
		if n <= 1 or span <= room then return 0 end
		-- one continuous crawl, wrapping on the whole row's width
		return -((GetTimeSinceStart() * 26) % span)
	end

	for qi = 1, TICK_SLOTS do
		local function Row() return state.dlRows[qi] end
		local function SlotX() return TICK_LEFT + TickShift() + (qi - 1) * TICK_PITCH end
		local function Showing()
			local dl = Row()
			if not (state.open and not state.textEntryOpen and dl) then return false end
			local x = SlotX()
			return x > -TICK_SLOT and x < LO.W
		end
		-- 1 while working, dropping to 0 across the flare and fade
		local function Alpha()
			local out = DL.Leaving(Row())
			if out <= 0 then return 1 end
			local flare = DL.GLOW_FOR / DL.SHOW_DONE
			if out <= flare then return 1 end
			return Clamp(1 - (out - flare) / (DL.FADE_FOR / DL.SHOW_DONE), 0, 1)
		end

		-- the lit block behind a row that has just finished, which is what
		-- actually catches the eye
		ui[#ui+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:setsize(TICK_SLOT, 15):visible(false)
			end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOTick") end,
			SMOTickCommand = function(self)
				local dl = Row()
				local out = DL.Leaving(dl)
				self:visible(Showing() and out > 0)
				if not (Showing() and out > 0) then return end
				self:xy(SlotX() - 4, TICK_Y - 7)
				local flare = DL.GLOW_FOR / DL.SHOW_DONE
				local lit = (out <= flare) and 1 or Alpha()
				self:diffuse(AccentColor()):diffusealpha(0.55 * lit)
			end,
		}

		ui[#ui+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):zoom(0.42)
				self:maxwidth((TICK_SLOT - 54)/0.42):visible(false)
			end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOTick") end,
			SMOTickCommand = function(self)
				local dl = Row()
				self:visible(Showing())
				if not Showing() then return end
				self:xy(SlotX(), TICK_Y)
				self:settext(dl.name or "")
				local out = DL.Leaving(dl)
				if out > 0 then
					self:diffuse(0.08, 0.08, 0.08, 1):diffusealpha(Alpha())
				else
					self:diffuse(1, 1, 1, 1):diffusealpha(0.9)
				end
			end,
		}

		ui[#ui+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):zoom(0.4):visible(false)
			end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOTick") end,
			SMOTickCommand = function(self)
				local dl = Row()
				self:visible(Showing())
				if not Showing() then return end
				self:xy(SlotX() + TICK_SLOT - 6, TICK_Y)
				local label = DL.RowState(dl)
				if dl.status == "done" then
					label = dl.single and "song added" or "installed"
				end
				self:settext(label)
				local out = DL.Leaving(dl)
				if out > 0 then
					self:diffuse(0.08, 0.08, 0.08, 1):diffusealpha(Alpha())
				elseif dl.status == "error" then
					self:diffuse(1, 0.45, 0.45, 1)
				else
					self:diffuse(AccentColor()):diffusealpha(0.95)
				end
			end,
		}

		-- the progress bar, under the row it belongs to
		ui[#ui+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:setsize(TICK_SLOT, 2):visible(false)
			end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOTick") end,
			SMOTickCommand = function(self)
				local dl = Row()
				local working = Showing() and dl.status ~= "done"
				self:visible(working)
				if not working then return end
				self:xy(SlotX(), TICK_Y + 7)
				local _, frac = DL.RowState(dl)
				if dl.status == "error" then
					self:diffuse(1, 0.35, 0.35, 0.8):setsize(TICK_SLOT, 2)
				else
					self:diffuse(AccentColor())
					self:diffusealpha((frac and frac >= 0) and 0.95 or 0.4)
					self:setsize(math.max(2,
						TICK_SLOT * ((frac and frac >= 0) and frac or 1)), 2)
				end
			end,
		}
	end

	-- what did not fit
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - LO.LIST_X, TICK_Y):zoom(0.38)
			self:diffuse(0.6, 0.6, 0.6, 1):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local extra = #state.dlRows - TICK_SLOTS
			self:visible(state.open and not state.textEntryOpen and extra > 0)
			if extra > 0 then self:settext("+" .. extra .. " more") end
		end,
	}

	-- The ticker moves, so it needs its own clock rather than a refresh: the
	-- one that drives the download rows only ticks while something is active.
	ui[#ui+1] = Def.Actor{
		InitCommand = function(self) self:queuecommand("SMOTickPump") end,
		SMOTickPumpCommand = function(self)
			local busy = state.open and #state.dlRows > 0
			if busy then
				MESSAGEMAN:Broadcast("SMOTick")
				self:sleep(1/20):queuecommand("SMOTickPump")
			else
				self:sleep(0.3):queuecommand("SMOTickPump")
			end
		end,
	}

	-- loading spinner for the very first fetch (the list is empty behind it)
	ui[#ui+1] = Spinner(LO.W/2, LO.H/2, 0.3, function()
		return state.loading and state.mode == "list" and #state.packs == 0
	end)

	-- Where the rows run out with more still to find. It sits directly under
	-- the last row rather than at a fixed height, so it reads as the end of
	-- the list instead of as furniture.
	--
	-- One spot, three honest states. "&MENUDOWN; more" while the walk is
	-- paused and a press will fetch another helping; "finding more..." while
	-- that helping (or the first one) is actually being gathered; nothing
	-- once the list is genuinely complete. It used to draw only the first of
	-- these, so the arrow vanished the instant it was pressed and the spot
	-- sat empty for the whole fetch -- the indicator looked broken exactly
	-- when it was working.
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.LIST_X + LO.LIST_W/2, 0):zoom(0.5):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local lv = state.level
			local atEnd = InLevelView() and lv ~= nil
				and state.page >= TotalPages() and #state.packs > 0
			local finding = atEnd and lv.status == "loading"
			local show = atEnd and (finding or lv.more == true)
			self:visible(show)
			if not show then return end
			self:y(LO.ListTop() + #state.packs * LO.ROW_H + 9)
			if finding then
				self:settext("finding more...")
				self:diffuse(0.6, 0.6, 0.6, 1)
			else
				self:settext("&MENUDOWN; more")
				self:diffuse(AccentColor())
			end
		end,
	}

	-- error / empty-state text
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.LIST_X + LO.LIST_W/2, LO.H/2):zoom(0.7):diffuse(0.8, 0.8, 0.8, 1)
			self:wrapwidthpixels(LO.LIST_W / 0.7)
		end,
		SMORefreshMessageCommand = function(self)
			if not InPackList() then self:settext("") return end
			-- only overlay the error text when there is nothing else to show;
			-- transient errors over a working list surface as a toast instead
			if state.loadErr and #state.packs == 0 then
				self:settext("Could not reach stepmaniaonline.net\n(" .. tostring(state.loadErr) .. ")\n\nPress &MENULEFT; to retry")
			elseif (not state.loading) and not LO.ListBuilding()
			       and #state.packs == 0 and state.lastFetch then
				self:settext("No packs found")
			else
				self:settext("")
			end
		end,
	}
end
