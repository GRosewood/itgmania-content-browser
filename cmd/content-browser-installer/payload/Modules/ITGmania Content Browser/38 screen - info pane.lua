-- -----------------------------------------------------------------------
-- The info pane beside the list
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BannerPending = CB.BannerPending
local BannerUrlFor  = CB.BannerUrlFor
local CurrentPack   = CB.CurrentPack
local FetchDetail   = CB.FetchDetail
local FitSprite     = CB.FitSprite
local FormatDate    = CB.FormatDate
local InPackList    = CB.InPackList
local LO            = CB.LO
local MeasureBanner = CB.MeasureBanner
local MeterColor    = CB.MeterColor
local RequestBanner = CB.RequestBanner
local Spinner       = CB.Spinner
local Sync          = CB.Sync
local loadedBanner  = CB.loadedBanner
local refs          = CB.refs
local state         = CB.state

function CB.Screen.InfoPane()
	-- ---------------------------------------------------------------
	-- LIST VIEW: right-hand info pane for the highlighted pack

	local pane = Def.ActorFrame{
		Name = "Pane",
		InitCommand = function(self) self:xy(LO.PANE_X, LO.ListTop()):visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:y(LO.ListTop())
			self:visible(state.open and InPackList() and CurrentPack() ~= nil)
		end,
	}

	pane[#pane+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:setsize(LO.PANE_W, LO.PaneH()):diffuse(1, 1, 1, 0.07)
		end,
		SMORefreshMessageCommand = function(self)
			self:setsize(LO.PANE_W, LO.PaneH())
		end,
	}

	pane[#pane+1] = Def.Sprite{
		InitCommand = function(self) self:xy(LO.PANE_W/2, 38) end,
		SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOSetBannerCommand = function(self)
			local pack = CurrentPack()
			local url = pack and BannerUrlFor(pack)
			local path = url and state.banners[url]
			if pack and path then
				if loadedBanner.pane ~= path then
					self:Load(path)
					loadedBanner.pane = path
				end
				MeasureBanner(self, url)
				FitSprite(self, LO.PANE_W - 40, 62)
				self:diffuse(1, 1, 1, 1)
				self:visible(true)
			elseif url then
				self:visible(false)
				RequestBanner(url)
			elseif pack then
				LO.ShowNoBanner(self, "pane", loadedBanner, LO.PANE_W - 40, 62)
			else
				self:visible(false)
			end
		end,
	}

	pane[#pane+1] = Spinner(LO.PANE_W/2, 38, 0.18, function()
		if not InPackList() then return false end
		return BannerPending(CurrentPack())
	end)

	pane[#pane+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.PANE_W/2, 84):zoom(0.7):maxwidth((LO.PANE_W - 24)/0.7)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			self:settext(pack and pack.name or "")
			self:diffuse(1, 1, 1, 1)

			-- lazy-load details for the highlighted pack while browsing
			-- (only while the browser is actually open, in the list view, and
			-- settled on it rather than passing over its tab)
			if pack and state.open and state.settled and InPackList() then
				FetchDetail(pack)
			end
		end,
	}

	-- info lines under the name
	local infoLines = {
		function(pack, det)
			local songsText = tostring(pack.songs) .. " songs"
			if det and det.stats.charts then songsText = songsText .. "   -   " .. det.stats.charts .. " charts" end
			return songsText
		end,
		function(pack, det)
			local text = pack.sizeStr
			if det and det.stats.difficulty then text = text .. "   -   difficulty " .. det.stats.difficulty end
			return text
		end,
		function(pack, det)
			local date = FormatDate(pack.date)
			if date == "" and det then date = det.date or "" end
			return (date ~= "") and ("Added to SMO on " .. date) or ""
		end,
		function(pack, det)
			if det and det.author then return "charts by " .. det.author end
			if state.detailBusy[pack.id] then return "loading details..." end
			return ""
		end,
		function(pack, det)
			return Sync.Line(pack)
		end,
	}

	for lineIndex, textFn in ipairs(infoLines) do
		pane[#pane+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:xy(LO.PANE_W/2, 96 + lineIndex*13):zoom(0.5):diffuse(0.75, 0.75, 0.75, 1)
				self:maxwidth((LO.PANE_W - 24)/0.5)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				if not pack then self:settext("") return end
				self:settext(textFn(pack, state.details[pack.id]) or "")
			end,
		}
	end

	-- mini difficulty histogram (bars scale to the pane)
	local HIST_MAX_BARS = 30
	local HIST_H = 42
	local function HistY() return LO.PaneH() - 24 end  -- baseline, clear of the caption
	local HIST_W = LO.PANE_W - 48

	for barIndex = 1, HIST_MAX_BARS do
		pane[#pane+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(bottom):visible(false)
				refs.bars[barIndex] = self
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				local visible = InPackList()
				if not (visible and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local maxCount = 1
				for count in ivalues(det.counts) do maxCount = math.max(maxCount, count) end
				local barW = math.max(2, math.floor(HIST_W / #det.counts) - 2)
				local x0 = 24 + (HIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:horizalign(left)
				self:xy(x0 + (barIndex-1)*(barW+2), HistY())
				self:setsize(barW, math.max(2, det.counts[barIndex] / maxCount * HIST_H))
				self:diffuse(MeterColor(det.labels[barIndex], 0.95))
			end,
		}
	end

	pane[#pane+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.PANE_W/2, LO.PaneH() - 11):zoom(0.45):diffuse(0.6, 0.6, 0.6, 1)
		end,
		SMORefreshMessageCommand = function(self)
			self:y(LO.PaneH() - 11)
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if det and #det.labels > 0 then
				self:settext("charts per difficulty  (" .. det.labels[1] .. " - " .. det.labels[#det.labels] .. ")")
			else
				self:settext("")
			end
		end,
	}
	return pane, HIST_MAX_BARS
end
