-- -----------------------------------------------------------------------
-- The doubles view
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor   = CB.AccentColor
local BannerPending = CB.BannerPending
local BannerUrlFor  = CB.BannerUrlFor
local FitSprite     = CB.FitSprite
local LO            = CB.LO
local MeasureBanner = CB.MeasureBanner
local RequestBanner = CB.RequestBanner
local ScrollBar     = CB.ScrollBar
local Spinner       = CB.Spinner
local loadedBanner  = CB.loadedBanner
local state         = CB.state

function CB.Screen.DoublesView(ui)
	-- ---------------------------------------------------------------
	-- DOUBLES VIEW: two columns
	--
	-- A pack built for doubles and a pack with four doubles charts buried in it
	-- are two different things to go looking for, so each gets a column rather
	-- than one list with a seam in it the reader has to find.

	local dblAF = Def.ActorFrame{
		Name = "Doubles",
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and state.mode == "doubles")
		end,
	}

	for col = 1, 2 do
		local cx = LO.DblX(col)
		local function Column()
			local d = state.doubles
			return (col == 2) and d.right or d.left
		end
		-- Each column is still coming on its own terms. The dedicated list is
		-- complete the moment itgdb answers -- nothing in it has to be read --
		-- while the partial one is not done until every candidate has been.
		-- One spinner for the whole tab left a finished column looking busy.
		local function Building()
			local d = state.doubles
			if col == 1 then return d.dedicated == nil end
			return d.partial == nil
				or (state.level ~= nil and state.level.status == "loading")
		end

		-- The picker's focus: the whole column lit as one thing, so "you are
		-- choosing between two lists" is something the screen says rather
		-- than something the reader has to deduce from a cursor.
		dblAF[#dblAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(cx - 4, LO.LIST_TOP_TIGHT)
				self:setsize(LO.DBL_W + 8,
					LO.DblTop() - LO.LIST_TOP_TIGHT + LO.DBL_ROWS * LO.ROW_H)
			end,
			SMORefreshMessageCommand = function(self)
				local d = state.doubles
				local on = state.zone == "list" and d.zone ~= "rows" and d.col == col
				self:visible(on)
				if on then self:diffuse(AccentColor()):diffusealpha(0.10) end
			end,
		}

		dblAF[#dblAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(cx, LO.LIST_TOP_TIGHT + 7):zoom(0.5)
				self:maxwidth((LO.DBL_W - 8)/0.5)
			end,
			SMORefreshMessageCommand = function(self)
				local n = #Column()
				local head = (col == 1) and "MADE FOR DOUBLES" or "SOME DOUBLES"
				local more = LO.DoublesGrowing(col) and "+" or ""
				self:settext(n > 0 and (head .. "   " .. n .. more) or head)
				if state.doubles.col == col and state.zone == "list" then
					self:diffuse(AccentColor())
				else
					self:diffuse(0.6, 0.6, 0.6, 1)
				end
			end,
		}

		dblAF[#dblAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(cx, LO.LIST_TOP_TIGHT + 15):setsize(LO.DBL_W, 1)
				self:diffuse(1, 1, 1, 0.13)
			end,
		}

		-- what a column says when it has nothing in it and nothing coming
		dblAF[#dblAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(cx + 4, LO.DblTop() + 14):zoom(0.5)
				self:diffuse(0.55, 0.55, 0.55, 1)
				self:wrapwidthpixels((LO.DBL_W - 12)/0.5)
			end,
			SMORefreshMessageCommand = function(self)
				if #Column() > 0 then self:settext("") return end
				if state.packTypesFailed and not state.smoByName then
					-- the column cannot be built at all without the catalogue,
					-- and saying nothing would read as "there are none"
					self:settext("Could not reach stepmaniaonline.net for its"
						.. " pack list, so these cannot be matched up."
						.. "  &MENULEFT; to try again.")
				elseif col == 1 and state.doubles.blocked then
					-- neither road reached itgdb.net: it is not on the
					-- allowlist and the helper is not there to relay for it
					self:settext("itgdb.net cannot be reached -- it is not"
						.. " on this machine's allowlist."
						.. "  Run the installer again to fix that.")
				elseif Building() then
					self:settext("")
				else
					self:settext("Nothing here.")
				end
			end,
		}

		for slot = 1, LO.DBL_ROWS do
			local function RowPack() return Column()[state.doubles.win[col] + slot] end
			local function RowY() return LO.DblTop() + (slot-1)*LO.ROW_H end
			local function Focused()
				local d = state.doubles
				return d.col == col and d.row == slot
			end
			local bkey = "dbl" .. col .. "_" .. slot

			dblAF[#dblAF+1] = Def.ActorFrame{
				InitCommand = function(self) self:xy(cx, RowY()) end,
				SMORefreshMessageCommand = function(self) self:y(RowY()) end,

				-- focus background
				Def.Quad{
					InitCommand = function(self)
						self:vertalign(top):horizalign(left)
						self:setsize(LO.DBL_W, LO.ROW_H - 3)
					end,
					SMORefreshMessageCommand = function(self)
						if RowPack() == nil then self:visible(false) return end
						self:visible(true)
						if Focused() then
							-- bright only while actually IN the rows; during
							-- the pick the whole column carries the focus
							local inRows = state.zone == "list"
								and state.doubles.zone == "rows"
							self:diffuse(1, 1, 1, inRows and 0.16 or 0.09)
						else
							self:diffuse(1, 1, 1, 0.05)
						end
					end,
				},

				-- a row that has not been placed yet: a dim bar where it will
				-- land, so a column still assembling reads as working
				Def.Quad{
					InitCommand = function(self)
						self:vertalign(top):horizalign(left)
						self:setsize(LO.DBL_W, LO.ROW_H - 3):diffuse(1, 1, 1, 0.045)
					end,
					SMORefreshMessageCommand = function(self)
						self:visible(RowPack() == nil and Building())
					end,
				},
				Def.Quad{
					InitCommand = function(self)
						self:vertalign(top):horizalign(left)
						self:xy(72, 11):setsize(LO.DBL_W/3, 6):diffuse(1, 1, 1, 0.07)
					end,
					SMORefreshMessageCommand = function(self)
						self:visible(RowPack() == nil and Building())
					end,
				},
				Def.Quad{
					InitCommand = function(self)
						self:vertalign(top):horizalign(left)
						self:xy(72, 23):setsize(LO.DBL_W/6, 4):diffuse(1, 1, 1, 0.05)
					end,
					SMORefreshMessageCommand = function(self)
						self:visible(RowPack() == nil and Building())
					end,
				},

				Spinner(38, (LO.ROW_H-3)/2, 0.11, function()
					local pack = RowPack()
					if pack == nil then return Building() end
					return BannerPending(pack)
				end),

				Def.Sprite{
					InitCommand = function(self) self:xy(38, (LO.ROW_H-3)/2) end,
					SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
					SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
					SMOSetBannerCommand = function(self)
						local pack = RowPack()
						local url = pack and BannerUrlFor(pack)
						local path = url and state.banners[url]
						if pack and path then
							if loadedBanner[bkey] ~= path then
								self:Load(path)
								loadedBanner[bkey] = path
							end
							MeasureBanner(self, url)
							FitSprite(self, 68, LO.ROW_H - 9)
							self:diffuse(1, 1, 1, 1)
							self:visible(true)
						elseif url and not state.bannerFailed[url] then
							self:visible(false)
							RequestBanner(url)
						elseif pack then
							-- The dedicated column's rows have no url until the
							-- pack page has been read, so ask for that first
							-- and show the placeholder meanwhile; if the page
							-- has already been read and there is still nothing,
							-- the placeholder is the answer.
							LO.ShowNoBanner(self, bkey, loadedBanner, 68, LO.ROW_H - 9)
							if col == 1 then
								LO.DoublesBanner(pack)
							end
						else
							self:visible(false)
						end
					end,
				},

				-- pack name
				Def.BitmapText{
					Font = "Common Normal",
					InitCommand = function(self)
						self:horizalign(left):xy(80, 11):zoom(0.66)
						self:maxwidth((LO.DBL_W - 92)/0.66)
					end,
					SMORefreshMessageCommand = function(self)
						local pack = RowPack()
						if not pack then self:settext("") return end
						self:settext(pack.name)
						if Focused() and state.zone == "list"
						   and state.doubles.zone == "rows" then
							self:diffuse(AccentColor())
						else
							self:diffuse(1, 1, 1, 1)
						end
						-- the dedicated column was placed without reading, so
						-- its rows go and get their own count
					end,
				},

				-- how much doubles, then the ordinary pack facts
				Def.BitmapText{
					Font = "Common Normal",
					InitCommand = function(self)
						self:horizalign(left):xy(80, 24):zoom(0.46)
						self:diffuse(0.6, 0.6, 0.6, 1)
						self:maxwidth((LO.DBL_W - 92)/0.46)
					end,
					SMORefreshMessageCommand = function(self)
						local pack = RowPack()
						if not pack then self:settext("") return end
						local bits = {}
						if pack.songs > 0 then bits[#bits+1] = pack.songs .. " songs" end
						if pack.sizeStr ~= "" then bits[#bits+1] = pack.sizeStr end
						self:settext(table.concat(bits, "  -  "))
					end,
				},
			}
		end

		dblAF[#dblAF+1] = ScrollBar(
			cx + LO.DBL_W + 5, LO.DblTop(), LO.DBL_ROWS*LO.ROW_H - 8, false,
			function()
				if state.mode ~= "doubles" then return nil end
				return #Column(), LO.DBL_ROWS, state.doubles.win[col]
			end)
	end

	ui[#ui+1] = dblAF
end
