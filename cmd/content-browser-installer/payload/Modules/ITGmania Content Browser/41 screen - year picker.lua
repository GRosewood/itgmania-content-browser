-- -----------------------------------------------------------------------
-- The year picker
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor = CB.AccentColor
local Clamp       = CB.Clamp
local Commify     = CB.Commify
local InYearView  = CB.InYearView
local LO          = CB.LO
local Spinner     = CB.Spinner
local YEAR_SPAN   = CB.YEAR_SPAN
local YearList    = CB.YearList
local state       = CB.state

function CB.Screen.YearPicker(ui)
	-- ---------------------------------------------------------------
	-- YEAR view: the picker that sits where the featured grid normally is

	-- YEAR_SPAN + 1 chips (each year, plus OLDER) share the band width
	local YEAR_CHIP_W = math.floor((LO.W - 2*LO.LIST_X + 10) / (YEAR_SPAN + 1)) - 10
	local YEAR_CHIP_H = 34
	local YEAR_CHIP_Y = LO.FEAT_TOP + 18

	local yearAF = Def.ActorFrame{
		Name = "Years",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and InYearView())
		end,
	}

	yearAF[#yearAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X, LO.FEAT_LABEL_Y):zoom(0.55)
		end,
		SMORefreshMessageCommand = function(self)
			-- "added", never "released": this is the date SMO listed the pack
			local label = "PACKS BY YEAR"
			if state.viewYear == "older" then
				label = "PACKS ADDED TO SMO BEFORE " .. state.yearFloor
			elseif state.viewYear then
				label = "PACKS ADDED TO SMO IN " .. state.viewYear
			end
			if state.recentIndex.status == "loading" then
				-- the bar and the year on the right carry the detail
				label = label .. "   building index..."
			elseif state.localRows then
				label = label .. string.format("   %s packs", Commify(#state.localRows))
			end
			self:settext(label)
			self:diffuse(AccentColor())
		end,
	}

	-- How far the index has walked, where the page counter used to be. Shown
	-- only while it is walking: a full bar sitting there afterwards would be
	-- furniture.
	yearAF[#yearAF+1] = Def.Quad{
		InitCommand = function(self)
			self:horizalign(left):xy(LO.W - LO.LIST_X - 156, LO.FEAT_LABEL_Y + 10)
			self:setsize(140, 4):diffuse(1, 1, 1, 0.16):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.recentIndex.status == "loading")
		end,
	}
	yearAF[#yearAF+1] = Def.Quad{
		InitCommand = function(self)
			self:horizalign(left):xy(LO.W - LO.LIST_X - 156, LO.FEAT_LABEL_Y + 10)
			self:setsize(1, 4):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local idx = state.recentIndex
			self:visible(idx.status == "loading")
			if idx.status ~= "loading" then return end
			self:diffuse(AccentColor())
			self:setsize(math.max(1, 140 * Clamp(idx.frac or 0, 0, 1)), 4)
		end,
	}

	-- The one spinner this view needs, beside the year it is working through
	-- and the bar showing how far it has got. Together they are the whole
	-- answer to "what is it doing", in one place.
	yearAF[#yearAF+1] = Spinner(LO.W - LO.LIST_X - 170, LO.FEAT_LABEL_Y + 5, 0.095, function()
		return state.recentIndex ~= nil and state.recentIndex.status == "loading"
	end)

	-- focus ring first, so the chips draw on top of it and it reads as a border
	yearAF[#yearAF+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left):visible(false)
			self:setsize(YEAR_CHIP_W + 4, YEAR_CHIP_H + 4)
		end,
		SMORefreshMessageCommand = function(self)
			if state.zone ~= "years" then self:visible(false) return end
			local slot = Clamp(state.yearCursor or 1, 1, YEAR_SPAN + 1)
			self:visible(true)
			self:xy(LO.LIST_X + (slot-1)*(YEAR_CHIP_W + 10) - 2, YEAR_CHIP_Y - 2)
			self:diffuse(AccentColor())
		end,
	}

	for slot = 1, YEAR_SPAN + 1 do
		local chipX = LO.LIST_X + (slot-1) * (YEAR_CHIP_W + 10)

		local function YearAt()
			return YearList()[slot]
		end

		yearAF[#yearAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(chipX, YEAR_CHIP_Y):setsize(YEAR_CHIP_W, YEAR_CHIP_H)
			end,
			SMORefreshMessageCommand = function(self)
				if YearAt() == state.viewYear then
					self:diffuse(AccentColor())
					self:diffusealpha(state.zone == "years" and 0.5 or 0.3)
				else
					self:diffuse(0, 0, 0, 0.55)
				end
			end,
		}

		yearAF[#yearAF+1] = Def.BitmapText{
			Font = "Common Bold",
			InitCommand = function(self)
				self:xy(chipX + YEAR_CHIP_W/2, YEAR_CHIP_Y + YEAR_CHIP_H/2 - 1):zoom(0.42)
				self:maxwidth((YEAR_CHIP_W - 8) / 0.42)
			end,
			SMORefreshMessageCommand = function(self)
				local yv = YearAt()
				self:settext(yv == "older" and "OLDER" or tostring(yv or ""))
				local lit = (YearAt() == state.viewYear) and 1 or 0.6
				self:diffuse(lit, lit, lit, 1)
			end,
		}
	end

	ui[#ui+1] = yearAF
end
