-- -----------------------------------------------------------------------
-- The tab row
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor     = CB.AccentColor
local Commify         = CB.Commify
local InBrowsingMode  = CB.InBrowsingMode
local InInstalledView = CB.InInstalledView
local InLevelView     = CB.InLevelView
local InPackList      = CB.InPackList
local InYearView      = CB.InYearView
local LO              = CB.LO
local Spinner         = CB.Spinner
local TabIsActive     = CB.TabIsActive
local TotalPages      = CB.TotalPages
local state           = CB.state

function CB.Screen.Tabs(ui)
	-- ---------------------------------------------------------------
	-- filter tabs (pad / keyboard) and the view tabs

	-- eight tabs now, so the labels lose their filler words; the row sits on
	-- its own line above the readout, so the pitch only has to fit the labels
	local tabDefs = {
		{ view = "search",    label = "SEARCH" },
		{ mode = "pad",       label = "PAD" },
		{ mode = "keyboard",  label = "KEYBOARD" },
		{ view = "beginner",  label = "BEGINNER" },
		{ view = "tech",      label = "ALL AROUND" },
		{ view = "stamina",   label = "STAMINA" },
		{ view = "doubles",   label = "DOUBLES" },
		{ view = "year",      label = "YEARS" },
		{ view = "installed", label = "INSTALLED" },
	}

	local tabsAF = Def.ActorFrame{
		Name = "Tabs",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and InBrowsingMode())
		end,
	}

	for tabIndex, tab in ipairs(tabDefs) do
		local function TabX() return LO.TabX(tabIndex) end

		-- Each tab is a filled pill rather than a word with a line under it:
		-- the row is a menu, and a menu item should look like something you
		-- can land on before you have landed on it. Three states -- the one
		-- the cursor is on, the one the page is showing, and the rest.
		local function TabState()
			if not TabIsActive(tab) then return "idle" end
			return (state.zone == "tabs") and "focus" or "shown"
		end

		tabsAF[#tabsAF+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(left):xy(0, LO.TABS_Y)
			end,
			SMORefreshMessageCommand = function(self)
				self:x(TabX() - 3):setsize(LO.TabW(), LO.TAB_H)
				local how = TabState()
				if how == "focus" then
					self:diffuse(AccentColor()):diffusealpha(1)
				elseif how == "shown" then
					self:diffuse(AccentColor()):diffusealpha(0.26)
				else
					self:diffuse(1, 1, 1, 0.05)
				end
			end,
		}

		-- The icon sits in front of the label, so the label starts further in.
		-- Both the Texture and the existence check use LO.ICONS, which is
		-- absolute on purpose -- a relative Texture resolves against THIS
		-- file's own folder, which is not where the artwork is. See the
		-- LO.ICONS comment in 23 layout.lua.
		local iconName = LO.ICONS .. (tab.view or tab.mode) .. ".png"
		if FILEMAN:DoesFileExist(iconName) then
			tabsAF[#tabsAF+1] = Def.Sprite{
				Texture = iconName,
				InitCommand = function(self)
					-- drawn at 96px, shown at 12
					self:xy(0, LO.TABS_Y):zoom(12/96)
				end,
				SMORefreshMessageCommand = function(self)
					self:x(TabX() + 7)
					local how = TabState()
					if how == "focus" then
						-- dark on the filled pill, which is the only place the
						-- background is bright enough to need it
						self:diffuse(0.08, 0.08, 0.08, 1)
					elseif how == "shown" then
						self:diffuse(AccentColor()):diffusealpha(1)
					else
						self:diffuse(0.55, 0.55, 0.55, 1)
					end
				end,
			}
		end

		tabsAF[#tabsAF+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = tab.label,
			InitCommand = function(self)
				self:horizalign(left):xy(0, LO.TABS_Y):zoom(0.48)
			end,
			SMORefreshMessageCommand = function(self)
				self:x(TabX() + 15):maxwidth((LO.TabW() - 19)/0.48)
				local how = TabState()
				if how == "focus" then
					self:diffuse(0.08, 0.08, 0.08, 1)
				elseif how == "shown" then
					self:diffuse(AccentColor()):diffusealpha(1)
				else
					self:diffuse(0.62, 0.62, 0.62, 1)
				end
			end,
		}
	end

	-- The update chip: the last thing on the header row, and a selectable one.
	--
	-- It is a pill like the tabs because it is reached the same way they are --
	-- right off the end of the row -- and something you can land on should look
	-- like the other things you can land on.
	do
		local function Lit() return state.zone == "update" end

		tabsAF[#tabsAF+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(left):xy(0, LO.TABS_Y):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				self:visible(LO.UpdateShowing())
				if not LO.UpdateShowing() then return end
				self:x(LO.UpdX() - 3):setsize(LO.UPD_W, LO.TAB_H)
				if Lit() then
					self:diffuse(AccentColor()):diffusealpha(1)
				else
					-- a soft pulse, because this is the only thing on the row
					-- that appeared on its own rather than always being there
					local beat = 0.30 + 0.16 * math.sin(GetTimeSinceStart() * 2.4)
					self:diffuse(AccentColor()):diffusealpha(beat)
				end
			end,
		}

		if FILEMAN:DoesFileExist(LO.ICONS .. "download.png") then
			tabsAF[#tabsAF+1] = Def.Sprite{
				Texture = LO.ICONS .. "download.png",
				InitCommand = function(self)
					self:xy(0, LO.TABS_Y):zoom(11/96):visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(LO.UpdateShowing())
					if not LO.UpdateShowing() then return end
					self:x(LO.UpdX() + 7)
					if Lit() then
						self:diffuse(0.08, 0.08, 0.08, 1)
					else
						self:diffuse(1, 1, 1, 0.92)
					end
				end,
			}
		end

		tabsAF[#tabsAF+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = "UPDATE",
			InitCommand = function(self)
				self:horizalign(left):xy(0, LO.TABS_Y):zoom(0.42):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				self:visible(LO.UpdateShowing())
				if not LO.UpdateShowing() then return end
				self:x(LO.UpdX() + 15):maxwidth((LO.UPD_W - 19)/0.42)
				if Lit() then
					self:diffuse(0.08, 0.08, 0.08, 1)
				else
					self:diffuse(1, 1, 1, 0.92)
				end
			end,
		}
	end

	-- a page is on its way; navigation is paused until it lands
	tabsAF[#tabsAF+1] = Spinner(LO.W - LO.LIST_X - 12, LO.TABS_Y, 0.10, function()
		-- The year view used to light this one up as well. It has a spinner of
		-- its own beside the year being indexed now, and two wheels for one job
		-- is one too many.
		return state.fetchReq ~= nil and InPackList()
	end)

	-- one line under the header, separating it from the page
	tabsAF[#tabsAF+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(LO.LIST_X, LO.HEADER_RULE_Y)
			self:setsize(LO.W - 2*LO.LIST_X, 1):diffuse(1, 1, 1, 0.16)
		end,
	}

	-- position readout, in the slot the sub-header used to own
	tabsAF[#tabsAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - LO.LIST_X - 16, LO.FEAT_LABEL_Y):zoom(0.5)
			self:diffuse(0.62, 0.62, 0.62, 1)
		end,
		SMORefreshMessageCommand = function(self)
			if InInstalledView() then
				self:settext(string.format("%d installed", #state.installed.packs))
			elseif InYearView() then
				-- which page of a year you are on is not interesting; how far
				-- the index has got is, because that is what you are waiting on
				local idx = state.recentIndex
				if idx.status == "loading" then
					self:settext(idx.year and ("indexing " .. idx.year) or "indexing...")
				else
					self:settext(Commify(#(state.localRows or {})) .. " packs")
				end
			elseif state.search ~= "" then
				self:settext(string.format("%s%s results for \"%s\"",
					Commify(state.filtered), state.searchCapped and "+" or "", state.search))
			elseif #state.packs == 0 then
				self:settext("")
			elseif InLevelView() then
				local lv = state.level
				-- beginner stops after a page, and doubles is not paged at
				-- all, so neither has a page number to report
				if state.mode == "beginner" or state.mode == "doubles" then
					self:settext("")
				else
					self:settext("Page " .. Commify(state.page) .. "/" .. Commify(TotalPages())
						.. "   -   " .. Commify(state.filtered)
						.. ((lv and lv.more) and "+" or "") .. " packs")
				end
			else
				self:settext(Commify(state.filtered) .. " packs")
			end
		end,
	}

	ui[#ui+1] = tabsAF
end
