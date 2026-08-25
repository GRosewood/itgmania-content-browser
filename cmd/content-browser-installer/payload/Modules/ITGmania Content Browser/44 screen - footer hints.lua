-- -----------------------------------------------------------------------
-- The footer hints, and the two frames that go on top of everything
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local InBrowsingMode = CB.InBrowsingMode
local InLevelView    = CB.InLevelView
local InPackList     = CB.InPackList
local CurrentPack    = CB.CurrentPack
local LO             = CB.LO
local ROWS           = CB.ROWS
local ScrollBar      = CB.ScrollBar
local Snd            = CB.Snd
local TabOrder       = CB.TabOrder
local state          = CB.state

function CB.Screen.FooterHints(ui, listAF, pane)
	-- ---------------------------------------------------------------
	-- footer hints

	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.W/2, LO.CONTENT_BOT + 15):zoom(0.55):diffuse(0.75, 0.75, 0.75, 1):maxwidth((LO.W - 20)/0.55)
		end,
		SMORefreshMessageCommand = function(self)
			-- the chip is on the header row, which every browsing view shares,
			-- so it is answered before the view is looked at
			if state.zone == "update" and state.mode ~= "update" then
				self:settext("&START; install it   &MENULEFT; back to the tabs   &BACK; exit")
			elseif state.mode == "list" or InLevelView() then
				if state.zone == "tabs" then
					if TabOrder[state.tabIndex] == "search" then
						self:settext("&MENULEFT;&MENURIGHT; views    &START; type a search    &BACK; exit")
					else
						self:settext("&MENULEFT;&MENURIGHT; views   &MENUDOWN; browse   &SELECT; reload   &BACK; exit")
					end
				elseif state.zone == "featured" then
					self:settext("&MENULEFT;&MENURIGHT; browse    &MENUUP;&MENUDOWN; row    &START; details    &BACK; exit")
				elseif state.mode == "doubles" then
					-- two stages, two different sets of keys: the picker
					-- chooses a LIST, the rows browse inside the chosen one
					if state.doubles.zone ~= "rows" then
						self:settext("&MENULEFT;&MENURIGHT; pick a list   &MENUDOWN; browse it   &MENUUP; views   &SELECT; reload   &BACK; exit")
					else
						self:settext("&MENUUP;&MENUDOWN; browse   &MENULEFT;&MENURIGHT; page   &START; details   &SELECT; reload   &BACK; exit")
					end
				elseif InLevelView() then
					self:settext("&MENUUP;&MENUDOWN; browse   &MENULEFT;&MENURIGHT; page   &START; details   &SELECT; reload   &BACK; exit")
				else
					self:settext("&MENUUP;&MENUDOWN; browse   &MENULEFT;&MENURIGHT; page   &START; details   &SELECT; reload   &BACK; exit")
				end
			elseif state.mode == "year" then
				if state.zone == "tabs" then
					self:settext("&MENULEFT;&MENURIGHT; switch view    &MENUDOWN; pick a year    &BACK; exit")
				elseif state.zone == "years" then
					self:settext("&MENULEFT;&MENURIGHT; year   &MENUDOWN; packs   &MENUUP; views   &SELECT; reload   &BACK; exit")
				else
					self:settext("&MENUUP;&MENUDOWN; browse   &MENURIGHT; page   &START; details   &SELECT; reload   &BACK; exit")
				end
			elseif state.mode == "installed" then
				if state.zone == "tabs" then
					self:settext("&MENULEFT;&MENURIGHT; switch view    &MENUDOWN; your packs    &BACK; exit")
				else
					self:settext("&MENUUP;&MENUDOWN; packs   &MENULEFT;&MENURIGHT; page   &START; fix sync   &SELECT; remove   &BACK; exit")
				end
			elseif state.mode == "detail" and LO.DetailLost(CurrentPack()) then
				self:settext("&SELECT; try again   &START; download   &BACK; back")
			elseif state.mode == "detail" then
				if Snd.ChartOn() then
					self:settext("&MENUUP;&MENUDOWN; difficulty    &SELECT;&START; stop the preview    &BACK; back")
				elseif Snd.Busy() then
					self:settext("&MENUUP;&MENUDOWN; songs    &SELECT;&START; stop the preview    &BACK; back")
				elseif state.detailZone == "download" then
					self:settext("&START; download this pack    &MENUDOWN; back to the songs    &BACK; back")
				else
					self:settext("&MENUUP;&MENUDOWN; songs   &SELECT; preview   &START; song options   &BACK; back")
				end
			elseif state.mode == "sync" or state.mode == "blocked" or state.mode == "confirm"
			       or state.mode == "reload" or state.mode == "removeconfirm"
			       or state.mode == "update" then
				-- a dialog is up; it prints its own hint, so don't double it here
				self:settext("")
			else
				self:settext("")
			end

			-- Anywhere below the tab row, Back climbs a rung rather than
			-- leaving, so it should not be offering to exit. Rewritten here
			-- instead of in each of the dozen strings above, which is where it
			-- would have been forgotten.
			if InBrowsingMode() and state.zone ~= "tabs" and state.mode ~= "update" then
				local text = self:GetText()
				if text:find("&BACK; exit", 1, true) then
					self:settext((text:gsub("&BACK; exit", "&BACK; back")))
				end
			end
		end,
	}

	-- where this page sits in the whole filtered list
	-- Nine and a half thousand packs, seven to a page, over about two hundred
	-- pixels of travel: a straight ratio moves this thumb a sixth of a pixel per
	-- page, so it sits at the top looking broken however far you have paged.
	--
	-- The square root spends the top of the bar on the first pages, where hand
	-- paging actually happens -- one page in is about six pixels down instead of
	-- none -- and still runs all the way to the bottom at the end. It answers
	-- "how far from the top", which is what a reader wants from it here, rather
	-- than a ratio nobody can see.
	ui[#ui+1] = ScrollBar(LO.LIST_X + LO.LIST_W + 3, LO.ListTop, ROWS*LO.ROW_H - 3, false,
		function()
			if not InPackList() then return nil end
			if state.filtered <= 0 then return nil end
			return state.filtered, ROWS, (state.page - 1) * ROWS
		end,
		math.sqrt)

	ui[#ui+1] = listAF
	ui[#ui+1] = pane
end
