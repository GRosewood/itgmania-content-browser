-- -----------------------------------------------------------------------
-- Sitting inside the title menu, and the entry drawn on it
--
-- Two stretches of the original, in one file on purpose. The row drawn on
-- the title menu and the input hooks that watch it share seven plain
-- variables -- whether the row has focus, whether a choice is on its way out,
-- which engine index is being watched. Those are booleans and numbers, and a
-- boolean handed to another file is a copy: each file would get its own, one
-- file's writes would be invisible to the other, and nothing would say so. So
-- they stay together.
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BROWSER_SCREEN = CB.BROWSER_SCREEN
local PlaySfx        = CB.PlaySfx
local ROWS           = CB.ROWS
local SetRedirect    = CB.SetRedirect
local Trim           = CB.Trim
local UP             = CB.UP
local refs           = CB.refs
local state          = CB.state

-- The engine's title menu scroller is STATIC in Simply Love
-- (ScrollerSecondsPerItem=0, so items never slide; the highlight moves
-- through fixed rows at ScrollerY + 22*index).  Our item occupies the fixed
-- row below the last native choice.  Simply Love draws its "EVENT MODE" /
-- credit text at the very bottom, so we nudge the whole native menu up a few
-- pixels to make room for the extra row.
local titleFocused = false
local titleLeaving = false    -- a choice was activated; ignore input until the screen changes
local titleLastIndex = 0
local titleWatchIndex = -1
local titleWatchFocused = nil
local titleNumChoices = 4

-- Where the engine's selection is about to land, while it has yet to move.
--
-- Input reaches this module before the engine, so TitleGetEngineIndex() stays
-- at its pre-move value for the rest of the pass -- and a repaint made from it
-- lights the row being left. Whenever an event is handed on for the engine to
-- act on, the landing index is recorded here and the rows paint from it, so
-- the very frame of the keypress is already correct. The watcher clears it.
local titlePendingIndex = nil
local TITLE = {
	MENU_SHIFT  = 10,   -- pixels to raise the native menu block
	SPACING     = 22,   -- row pitch, matching the theme's own metric
	INSERT_SLOT = 3,    -- the row our entry takes, ahead of Exit
	ROWS        = 5,
}

local function TitleMenuBaseY()
	-- mirrors the theme metric: ScrollerY=_screen.cy+_screen.h/3.8
	return _screen.cy + _screen.h/3.8 - TITLE.MENU_SHIFT
end

local function TitleItemY()
	return TitleMenuBaseY() + TITLE.SPACING*TITLE.INSERT_SLOT
end

-- rows are 1-based; TITLE.ROWS is the four native choices plus ours

local function TitleRowY(row)
	return TitleMenuBaseY() + TITLE.SPACING*(row-1)
end

-- the engine choice a row stands for, or nil for our own row
local function TitleRowEngineIndex(row)
	local slot = row - 1
	if slot == TITLE.INSERT_SLOT then return nil end
	if slot < TITLE.INSERT_SLOT then return slot end
	return slot - 1
end

-- The label the theme would have drawn.  Simply Love puts it in the choice
-- metric ("screen,ScreenExit;text,Exit") and may translate it, so read the
-- metric and run the result through the screen's string table.
local titleLabelCache = {}

local function TitleChoiceLabel(index)
	if titleLabelCache[index] then return titleLabelCache[index] end
	local label
	local ok, metric = pcall(function()
		return THEME:GetMetric("ScreenTitleMenu", "Choice" .. (index+1))
	end)
	if ok and type(metric) == "string" then
		label = metric:match("text%s*,%s*([^;]+)")
	end
	if label then
		label = Trim(label)
		local okStr, translated = pcall(function()
			return THEME:GetString("ScreenTitleMenu", label)
		end)
		if okStr and type(translated) == "string" and translated ~= "" then
			label = translated
		end
	end
	label = label or ("Choice " .. (index+1))
	titleLabelCache[index] = label
	return label
end

local titleChoiceNames = {"1", "2", "3", "4"}

-- The last selection actually read, so a failed read can hold its ground.
local titleKnownIndex = 0

-- Where the engine's own selection sits.
--
-- PLAYER_1 deliberately, and NOT GAMESTATE:GetMasterPlayerNumber(): this
-- screen sets SharedSelection, so ChangeSelection writes every player's choice
-- and PLAYER_1 always carries it -- while the master player number is nil here,
-- because nobody has joined yet. Reading the master would fail on exactly this
-- screen, where the theme's own screens read it happily.
local function TitleGetEngineIndex()
	local screen = SCREENMAN:GetTopScreen()
	if not screen or not screen.GetSelectionIndex then return titleKnownIndex end
	-- pcall on the method directly: wrapping it in a fresh closure allocated
	-- garbage on every call, and the title watcher makes this call dozens of
	-- times a second for as long as the title screen is up.
	local ok, index = pcall(screen.GetSelectionIndex, screen, PLAYER_1)
	if ok and type(index) == "number" then
		titleKnownIndex = index
		return index
	end
	-- Holding the last known index rather than answering 0. Zero is a real
	-- selection -- the first row -- so answering it on failure made "could not
	-- read" indistinguishable from "the reader is on the top row", and the
	-- highlight would jump home rather than simply stay put.
	return titleKnownIndex
end

-- The selection the rows should paint from.
--
-- The prediction while one stands, otherwise whatever the engine really says.
local function TitlePaintIndex()
	return titlePendingIndex or TitleGetEngineIndex()
end

-- Record where the engine is about to move to, for the repaint that happens
-- before it gets the chance. Only ever called on a path that hands the event
-- on; a consumed event leaves the index alone and needs no guess.
local function TitlePredict(index)
	titlePendingIndex = index
	-- Tell the watcher what to expect, so a correct guess costs no second
	-- broadcast -- and a wrong one still trips its comparison and repaints.
	titleWatchIndex = index
	titleWatchFocused = titleFocused
end

-- play GainFocus/LoseFocus on one of the engine's scroller choices (0-based
-- index) so the native entry visually loses focus while ours has it
local function TitleSetEngineChoiceFocus(index, hasFocus)
	local screen = SCREENMAN:GetTopScreen()
	if not screen then return end
	local scroller = screen:GetChild("Scroller")
	if not scroller then return end
	local name = titleChoiceNames[index+1]
	if not name then return end
	local choice = scroller:GetChild("ScrollChoice" .. name)
	if not choice then return end
	choice:playcommand(hasFocus and "GainFocus" or "LoseFocus")
end

-- The theme's scroller transform sets each choice's y every frame, so the
-- native rows cannot be repositioned.  They are hidden instead and every row
-- is drawn by this module, which is what allows a row for "Find Content"
-- above Exit and a pitch wider than the theme's 22px.
local function TitleLayoutChoices()
	local screen = SCREENMAN:GetTopScreen()
	if not screen or screen:GetName() ~= "ScreenTitleMenu" then return end
	local scroller = screen:GetChild("Scroller")
	if not scroller then return end
	for index = 0, titleNumChoices - 1 do
		local name = titleChoiceNames[index+1]
		local choice = name and scroller:GetChild("ScrollChoice" .. name)
		if choice then
			pcall(choice.visible, choice, false)
		end
	end
end

-- refocusEngine=false leaves the native highlight alone (used when we let
-- the engine process the same event and move/wrap the selection itself)
local function TitleDefocus(refocusEngine)
	if not titleFocused then return end
	titleFocused = false
	if refocusEngine then
		TitleSetEngineChoiceFocus(TitleGetEngineIndex(), true)
	end
	MESSAGEMAN:Broadcast("SMOTitleRefresh")
end

local function TitleFocus()
	if titleFocused then return end
	titleFocused = true
	TitleSetEngineChoiceFocus(TitleGetEngineIndex(), false)
	if refs.titleItem then refs.titleItem:diffusealpha(1) end
	MESSAGEMAN:Broadcast("SMOTitleRefresh")
end

-- -----------------------------------------------------------------------
-- Title input, attached to the ScreenSystemLayer overlay screen.
--
-- Overlay screens receive input BEFORE the top screen, and a Lua callback
-- that returns true consumes the event entirely (ScreenManager::Input).
-- That lets our extra menu item participate in the title menu's wrap cycle
-- (WrapCursor=true): pressing forward on the last native choice, or backward
-- on the first, lands on "Find Content" instead of wrapping straight past
-- it; leaving our item in either direction hands the event back (or not) so
-- the engine's own selection always ends up on the right native choice.

local TitleOverlayInput = function(event)
	local screen = SCREENMAN:GetTopScreen()
	if not screen or screen:GetName() ~= "ScreenTitleMenu" then
		titleFocused = false
		return false
	end
	-- a choice was activated and the screen is tweening out; stay inert so a
	-- button mash can't hijack the pending transition
	if titleLeaving then return false end
	if not (event and event.type and event.GameButton) then return false end
	if event.type == "InputEventType_Release" then return false end

	local button = event.GameButton
	local firstPress = (event.type == "InputEventType_FirstPress")

	-- Simply Love's title menu navigates with MenuLeft/MenuRight on dance
	-- setups and MenuUp/MenuDown elsewhere.  Keyboard/pad Up/Down arrive as
	-- the raw "Up"/"Down" game buttons (which the engine's title menu
	-- ignores), so accept those for our item too.
	local isMenuNav  = (button == "MenuDown" or button == "MenuRight" or
	                    button == "MenuUp"   or button == "MenuLeft")
	local isForward  = (button == "MenuDown" or button == "MenuRight" or button == "Down")
	local isBackward = (button == "MenuUp"   or button == "MenuLeft"  or button == "Up")

	-- this runs BEFORE the engine sees the event, so this is the pre-move
	-- selection index
	local engineIndex = TitleGetEngineIndex()
	-- our row sits between these two native choices
	local above = TITLE.INSERT_SLOT - 1
	local below = TITLE.INSERT_SLOT

	-- the engine keeps re-running its own layout; put the rows back
	TitleLayoutChoices()

	if not titleFocused then
		if isForward and engineIndex == above then
			-- stepping down off the choice above ours
			PlaySfx("titlechange")
			TitleFocus()
			return true
		elseif isBackward and engineIndex == below then
			-- stepping up off the choice below ours
			PlaySfx("titlechange")
			TitleFocus()
			return true
		elseif button == "Start" and firstPress then
			-- a native choice was activated; fade our item out with the rest
			-- and go inert until the screen changes
			titleLeaving = true
			if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
		elseif isMenuNav then
			-- A move between two native choices: nothing to do but let it
			-- through, and repaint from where the engine actually lands.
			--
			-- This used to guess the landing index and paint it immediately,
			-- one step round the wrap. The guess is only right when the engine
			-- moves at all, and it does not always: ScreenSelectMaster only
			-- moves when its own direction map has somewhere to go for that
			-- button, which depends on the theme's layout and the game type.
			-- Where it refused, the row lit up for one watcher tick and then
			-- snapped back -- a press that flashed and scrolled nothing.
			--
			-- The watcher polls every 0.03s and repaints from the real index,
			-- so the cost of not guessing is about two frames of the highlight
			-- trailing the selection, and the benefit is that it is never
			-- somewhere the selection is not.
		end
		return false
	end

	-- our item is focused
	if button == "Start" and firstPress then
		PlaySfx("start")
		titleFocused = false
		titleLeaving = true
		state.open = true  -- flag intent before the screen switch
		if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
		SCREENMAN:SetNewScreen(BROWSER_SCREEN)
		return true
	elseif button == "Back" and firstPress then
		PlaySfx("titlechange")
		TitleDefocus(true)
		return true
	elseif isForward then
		if engineIndex == above then
			if isMenuNav then
				-- let the engine step down onto the choice below ours, and
				-- paint that row now rather than the one being left
				TitlePredict(below)
				TitleDefocus(false)
				return false
			end
			-- raw arrow only: the engine would not move, so stay put and let the
			-- event through so the screen's idle timer still resets
			return false
		else
			PlaySfx("titlechange")
			TitleDefocus(true)
			return true
		end
	elseif isBackward then
		if engineIndex == below then
			if isMenuNav then
				-- let the engine step up onto the choice above ours, and paint
				-- that row now rather than the one being left
				TitlePredict(above)
				TitleDefocus(false)
				return false
			end
			return false
		else
			PlaySfx("titlechange")
			TitleDefocus(true)
			return true
		end
	elseif button == "Coin" or button == "Operator" then
		return false
	end

	-- anything else (Select etc.) has no effect on this screen; pass it
	-- through so the engine's idle timer resets
	return false
end

-- register the overlay callback once, on the ScreenSystemLayer screen that
-- our module actors live inside (found by walking up the actor tree)
local titleOverlayHooked = false
local function HookTitleOverlayInput(actor)
	if titleOverlayHooked then return true end
	local node = actor
	for _ = 1, 30 do
		local parent = node:GetParent()
		if not parent then break end
		node = parent
	end
	if node and node.AddInputCallback then
		node:AddInputCallback(TitleOverlayInput)
		titleOverlayHooked = true
		return true
	end
	return false
end

-- Fallback for the (unexpected) case where the overlay hook isn't available:
-- watch the selection from a callback on the title screen itself.  This runs
-- AFTER the engine processed the event, so a forward press on the last
-- choice has already wrapped the selection to 0 by the time we see it.
local TitleFallbackInput = function(event)
	if state.retired then return false end
	if titleLeaving then return false end
	if not (event and event.type and event.GameButton) then return false end
	if event.type == "InputEventType_Release" then return false end

	local screen = SCREENMAN:GetTopScreen()
	if not screen or screen:GetName() ~= "ScreenTitleMenu" then return false end

	local button = event.GameButton
	local firstPress = (event.type == "InputEventType_FirstPress")
	local isForward  = (button == "MenuDown" or button == "MenuRight")
	local isBackward = (button == "MenuUp"   or button == "MenuLeft")

	if titleFocused then
		if isBackward or isForward or (button == "Back" and firstPress) then
			PlaySfx("titlechange")
			SetRedirect(false)
			TitleDefocus(true)
		elseif button == "Start" and firstPress then
			PlaySfx("start")
			titleFocused = false
			titleLeaving = true
			SetRedirect(false)
			state.open = true
			if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
			SCREENMAN:SetNewScreen(BROWSER_SCREEN)
		end
		return false
	end

	if isForward or isBackward then
		local current = TitleGetEngineIndex()
		-- detect a wrap in either direction: jumping between the ends means
		-- the selection passed our item's slot
		-- our row is between these two, so the engine skipping straight across
		-- them is what tells us the cursor passed through it
		local steppedDown = isForward  and titleLastIndex == TITLE.INSERT_SLOT-1
		                    and current == TITLE.INSERT_SLOT
		local steppedUp   = isBackward and titleLastIndex == TITLE.INSERT_SLOT
		                    and current == TITLE.INSERT_SLOT-1
		if steppedDown or steppedUp then
			PlaySfx("titlechange")
			TitleFocus()
			SetRedirect(true)
		end
		titleLastIndex = TitleGetEngineIndex()
	elseif button == "Start" and firstPress then
		titleLeaving = true
		if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
	end
	return false
end

-- -----------------------------------------------------------------------
-- title menu actor

local function TitleActor()
	local af = Def.ActorFrame{
		Name = "SMOFindContentTitleItem",

		InitCommand = function(self) refs.titleAF = self end,

		ModuleCommand = function(self)
			-- fresh title screen: reset transient state
			titleFocused = false
			titleLeaving = false
			state.open = false
			state.textEntryOpen = false
			SetRedirect(false)

			-- read the theme's current choice list so we sit underneath it
			local ok, names = pcall(function() return THEME:GetMetric("ScreenTitleMenu", "ChoiceNames") end)
			if ok and type(names) == "string" and names ~= "" then
				local list = {}
				for name in names:gmatch("[^,]+") do
					list[#list+1] = (Trim(name):gsub("[\"']", ""))
				end
				if #list > 0 then
					titleNumChoices = #list
					titleChoiceNames = list
				end
			end
			titleLastIndex = TitleGetEngineIndex()

			-- preferred: consume input ahead of the engine via the overlay
			-- screen; fallback: watch the selection from the title screen
			local hooked = HookTitleOverlayInput(self)

			local screen = SCREENMAN:GetTopScreen()
			if screen then
				if not hooked then
					screen:AddInputCallback(TitleFallbackInput)
					UP.titleScreen, UP.titleCb = screen, TitleFallbackInput
				end
				-- raise the (static) native menu a few pixels so our extra
				-- row fits above Simply Love's bottom "EVENT MODE" text.
				-- Setting y() absolutely keeps this idempotent.
				local scroller = screen:GetChild("Scroller")
				if scroller then
					scroller:y(TitleMenuBaseY())
				end
				-- and spread the choices out, leaving our row free
				TitleLayoutChoices()
			end

			self:playcommand("SMOTitleEnter")
		end,

	}

	-- Watches the engine's selection so the rows follow it. This module sees
	-- input before the engine does, so the index read during an input event is
	-- the pre-move one; polling for the change is simpler than predicting it.
	af[#af+1] = Def.Actor{
		SMOTitleEnterCommand = function(self)
			titleWatchIndex = -1
			titleWatchFocused = nil
			self:stoptweening():queuecommand("SMOTitleWatch")
		end,
		SMOTitleWatchCommand = function(self)
			local screen = SCREENMAN:GetTopScreen()
			if not screen or screen:GetName() ~= "ScreenTitleMenu" then return end
			local index = TitleGetEngineIndex()
			-- Any prediction has done its job by now: the engine handles the
			-- event in the same pass the guess was made in, so by this poll it
			-- has moved. Reality takes over, and the comparison below repaints
			-- if the guess turned out wrong.
			titlePendingIndex = nil
			if index ~= titleWatchIndex or titleFocused ~= titleWatchFocused then
				titleWatchIndex = index
				titleWatchFocused = titleFocused
				MESSAGEMAN:Broadcast("SMOTitleRefresh")
			end
			-- the engine can re-show its own rows on a selection change
			TitleLayoutChoices()
			self:sleep(0.03):queuecommand("SMOTitleWatch")
		end,
	}

	-- One actor per visible row.  The engine's own choices are hidden (see
	-- TitleHideEngineChoices) because their y is reset by the theme's scroller
	-- transform every frame, so there is no way to reposition them; drawing the
	-- rows here is what lets "Find Content" sit above Exit and gives the block
	-- a pitch that is not cramped.
	for row = 1, TITLE.ROWS do
		af[#af+1] = Def.BitmapText{
			Font = "Common Bold",
			InitCommand = function(self)
				if row == TITLE.INSERT_SLOT + 1 then refs.titleItem = self end
				self:shadowlength(0.5)
				self:zoom(0.4)
				self:diffusealpha(0)
			end,

			SMOTitleEnterCommand = function(self)
				self:finishtweening()
				self:playcommand("SMOTitleUpdate")
				-- match the staggered fade-in of the native choices
				self:diffusealpha(0):sleep(row*0.075):linear(0.2):diffusealpha(1)
			end,

			SMOTitleUpdateCommand = function(self)
				local engineIndex = TitleRowEngineIndex(row)
				self:settext(engineIndex and TitleChoiceLabel(engineIndex) or "Find Content")
				self:xy(_screen.cx, TitleRowY(row))

				local focused
				if engineIndex == nil then
					focused = titleFocused
				else
					focused = (not titleFocused) and TitlePaintIndex() == engineIndex
				end

				if focused then
					self:stoptweening():zoom(0.5)
					self:accelerate(0.1):glow(1, 1, 1, 0.5)
					self:decelerate(0.05):glow(1, 1, 1, 0)
					local textColor = PlayerColor(PLAYER_2)
					if ThemePrefs.Get("VisualStyle") == "SRPG10" then
						textColor = GetCurrentColor(true)
					end
					self:diffuse(textColor)
				else
					self:stoptweening():zoom(0.4):glow(1, 1, 1, 0)
					local textColor = color("#888888")
					if ThemePrefs.Get("RainbowMode") then
						textColor = Color.White
					end
					if ThemePrefs.Get("VisualStyle") == "SRPG10" then
						textColor = color(SL.SRPG10.TextColor)
					end
					self:diffuse(textColor)
				end
			end,

			VisualStyleSelectedMessageCommand = function(self)
				self:playcommand("SMOTitleUpdate")
			end,

			SMOTitleRefreshMessageCommand = function(self)
				self:playcommand("SMOTitleUpdate")
			end,

			-- fade out alongside the native choices when leaving the screen
			SMOTitleLeaveCommand = function(self)
				self:stoptweening()
				self:sleep(row*0.075):linear(0.18):diffusealpha(0)
			end,
		}
	end

	return af
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.TitleActor = TitleActor
