-- -----------------------------------------------------------------------
-- The pack list
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor    = CB.AccentColor
local BannerPending  = CB.BannerPending
local BannerUrlFor   = CB.BannerUrlFor
local DownloadLoaded = CB.DownloadLoaded
local FetchDetail    = CB.FetchDetail
local FitSprite      = CB.FitSprite
local FormatDate     = CB.FormatDate
local InPackList     = CB.InPackList
local LO             = CB.LO
local MeasureBanner  = CB.MeasureBanner
local PackTypeOf     = CB.PackTypeOf
local ROWS           = CB.ROWS
local RequestBanner  = CB.RequestBanner
local Spinner        = CB.Spinner
local loadedBanner   = CB.loadedBanner
local refs           = CB.refs
local state          = CB.state

function CB.Screen.PackRows()
	-- ---------------------------------------------------------------
	-- LIST VIEW: rows

	local listAF = Def.ActorFrame{
		Name = "List",
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and InPackList())
		end,
	}

	local paging = false   -- whether the bar below is already travelling
	listAF[#listAF+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:setsize(70, 2):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			-- only a real server page: the locally held lists answer at once and
			-- would do nothing but flicker this
			local busy = state.loading and state.fetchReq ~= nil
			if not busy then
				if paging then
					paging = false
					self:stoptweening()
				end
				self:visible(false)
				return
			end
			self:y(LO.ListTop() - 4)
			self:visible(true)
			self:diffuse(AccentColor()):diffusealpha(0.7)
			if not paging then
				paging = true
				self:playcommand("SMOPageSlide")
			end
		end,
		SMOPageSlideCommand = function(self)
			self:stoptweening():x(LO.LIST_X)
			self:linear(0.6):x(LO.LIST_X + LO.LIST_W - 70)
			self:queuecommand("SMOPageSlideBack")
		end,
		SMOPageSlideBackCommand = function(self)
			self:linear(0.6):x(LO.LIST_X)
			self:queuecommand("SMOPageSlide")
		end,
	}

	for i = 1, ROWS do
		local function RowY() return LO.ListTop() + (i-1)*LO.ROW_H end

		local row = Def.ActorFrame{
			InitCommand = function(self)
				self:xy(LO.LIST_X, RowY())
				refs.rows[i] = self
			end,
			SMORefreshMessageCommand = function(self)
				self:y(RowY())
			end,

			-- focus background
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:setsize(LO.LIST_W, LO.ROW_H - 3)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:visible(false) return end
					self:visible(true)
					if i == state.cursor then
						self:diffuse(1, 1, 1, state.zone == "list" and 0.16 or 0.09)
					else
						self:diffuse(1, 1, 1, 0.05)
					end
				end,
			},

			-- a row that has not been found yet: a dim bar where it will land,
			-- so a list that is still assembling reads as working rather than
			-- as empty
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:setsize(LO.LIST_W, LO.ROW_H - 3)
					self:diffuse(1, 1, 1, 0.045)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(state.packs[i] == nil and LO.ListBuilding())
				end,
			},
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:xy(76, 10):setsize(LO.LIST_W/3, 6)
					self:diffuse(1, 1, 1, 0.07)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(state.packs[i] == nil and LO.ListBuilding())
				end,
			},
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:xy(76, 22):setsize(LO.LIST_W/6, 4)
					self:diffuse(1, 1, 1, 0.05)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(state.packs[i] == nil and LO.ListBuilding())
				end,
			},

			-- while a row's art is still on its way, or the row itself has not
			-- arrived, something has to occupy the space
			Spinner(42, (LO.ROW_H-3)/2, 0.11, function()
				local pack = state.packs[i]
				if pack == nil then return LO.RowSpin() end
				return BannerPending(pack)
			end),

			-- banner thumbnail
			Def.Sprite{
				InitCommand = function(self)
					self:xy(42, (LO.ROW_H-3)/2)
				end,
				SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOSetBannerCommand = function(self)
					local pack = state.packs[i]
					local url = pack and BannerUrlFor(pack)
					local path = url and state.banners[url]
					local key = "row" .. i
					if pack and path then
						if loadedBanner[key] ~= path then
							self:Load(path)
							loadedBanner[key] = path
						end
						MeasureBanner(self, url)
						FitSprite(self, 76, LO.ROW_H - 9)
						self:diffuse(1, 1, 1, 1)
						self:visible(true)
					elseif url and state.settled then
						-- on its way; the row's own spinner covers the gap
						self:visible(false)
						RequestBanner(url)
					elseif pack then
						-- No url. For a keyboard row that means the pack page
						-- has not been read yet -- those come from the CSV,
						-- which carries no art -- so ask for it, and show the
						-- placeholder meanwhile rather than a hole. If the page
						-- turns up a banner this is replaced by it; if it does
						-- not, the placeholder was the answer all along.
						if pack.csvOnly and state.open and state.settled then
							FetchDetail(pack)
						end
						LO.ShowNoBanner(self, key, loadedBanner, 76, LO.ROW_H - 9)
					else
						self:visible(false)
					end
				end,
			},

			-- pack name
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(88, 11):zoom(0.72):maxwidth((LO.LIST_W - 176)/0.72)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					self:settext(pack.name)
					if i == state.cursor then
						if state.zone == "list" then self:diffuse(AccentColor()) else self:diffuse(1,1,1,1) end
					else
						self:diffuse(1, 1, 1, 1)
					end
				end,
			},

			-- sub-line: songs / size / date / types
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(88, 25):zoom(0.5):diffuse(0.6, 0.6, 0.6, 1)
					self:maxwidth((LO.LIST_W - 176)/0.5)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					local bits = {}
					if pack.songs > 0 then bits[#bits+1] = pack.songs .. " songs" end
					if pack.sizeStr ~= "" then bits[#bits+1] = pack.sizeStr end
					if pack.date ~= "" then bits[#bits+1] = "added " .. FormatDate(pack.date, true) end
					-- why a search result matched, when it was not the pack name
					if pack.why then bits[#bits+1] = pack.why end
					self:settext(table.concat(bits, "  -  "))
				end,
			},

			-- in a search, which tab the result belongs to; otherwise only the
			-- types the active tab does not already imply
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(LO.LIST_W - 84, (LO.ROW_H-3)/2):zoom(0.5)
					self:maxwidth(40/0.5)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					local ptype = PackTypeOf(pack.id)
					if state.search ~= "" then
						-- results come from every tab at once, so each row says
						-- where it would otherwise have been found
						if ptype == "keyboard" then
							self:settext("KEY"):diffuse(0.55, 0.72, 1, 1)
						elseif ptype == "mixed" then
							self:settext("PAD+KEY"):diffuse(0.55, 0.72, 1, 1)
						elseif ptype == "ddr" then
							self:settext("DDR"):diffuse(1, 0.72, 0.35, 1)
						else
							self:settext("PAD"):diffuse(0.55, 0.55, 0.55, 1)
						end
					elseif ptype == "mixed" then
						self:settext("PAD+KEY"):diffuse(0.55, 0.72, 1, 1)
					elseif ptype == "ddr" then
						self:settext("DDR"):diffuse(1, 0.72, 0.35, 1)
					else
						self:settext("")
					end
				end,
			},

			-- right-aligned status badge
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(right):xy(LO.LIST_W - 8, (LO.ROW_H-3)/2):zoom(0.5)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					local dl = state.downloads[pack.id]
					if dl then
						if dl.status == "active" then
							local pct = 0
							if dl.total > 0 then pct = math.floor(dl.cur / dl.total * 100) end
							self:settext(pct .. "%")
							self:diffuse(AccentColor())
						elseif dl.status == "installing" then
							self:settext("Installing")
							self:diffuse(AccentColor())
						elseif dl.status == "done" then
							self:settext(DownloadLoaded(dl) and "In Library" or "Installed")
							self:diffuse(0.4, 1, 0.4, 1)
						else
							self:settext("Error")
							self:diffuse(1, 0.4, 0.4, 1)
						end
					elseif SONGMAN:DoesSongGroupExist(pack.name) then
						self:settext("In Library")
						self:diffuse(0.45, 0.8, 0.45, 1)
					else
						self:settext("")
					end
				end,
			},
		}

		listAF[#listAF+1] = row
	end
	return listAF
end
