-- -----------------------------------------------------------------------
-- The featured grid
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
local FEAT          = CB.FEAT
local FitSprite     = CB.FitSprite
local LO            = CB.LO
local MeasureBanner = CB.MeasureBanner
local RequestBanner = CB.RequestBanner
local Spinner       = CB.Spinner
local loadedBanner  = CB.loadedBanner
local state         = CB.state

function CB.Screen.FeaturedGrid(ui)
	-- ---------------------------------------------------------------
	-- featured grid

	local featAF = Def.ActorFrame{
		Name = "Featured",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			-- a search replaces the strip with its own results, and the level and
			-- year views have their own band
			self:visible(state.open and LO.GridShowing())
		end,
	}

	-- The panel: four edges and nothing in the middle, so the background inside
	-- it is the same background as everywhere else. Drawing it as a tinted quad
	-- with a darker one over the top -- the way the dialogs do it -- only works
	-- when the inner quad is opaque; this one was not, and the accent behind it
	-- washed the whole strip green.
	for edge in ivalues({
		{ 0, 0, LO.FEAT_PANEL_W, 1 },                        -- top
		{ 0, LO.FEAT_PANEL_H - 1, LO.FEAT_PANEL_W, 1 },      -- bottom
		{ 0, 0, 1, LO.FEAT_PANEL_H },                        -- left
		{ LO.FEAT_PANEL_W - 1, 0, 1, LO.FEAT_PANEL_H },      -- right
	}) do
		local dx, dy, w, h = edge[1], edge[2], edge[3], edge[4]
		featAF[#featAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(LO.FEAT_PANEL_X + dx, LO.FEAT_PANEL_Y + dy):setsize(w, h)
				-- fixed rather than accented: a container is not a choice, and
				-- nothing about it changes when the theme colour does
				self:diffuse(1, 1, 1, 0.18)
			end,
		}
	end

	featAF[#featAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X, LO.FEAT_LABEL_Y):zoom(0.55)
		end,
		SMORefreshMessageCommand = function(self)
			local f = state.featured
			-- The strip is one thing now -- the packs people are actually
			-- playing, ranked by arrowcloud -- and only ever appears on the tab
			-- it was built for, so naming the scope said nothing the tab row
			-- was not already saying.
			local label = "POPULAR PACKS"
			local ac = state.arrowcloud.status
			if ac == "blocked" or ac == "failed" then
				label = label .. "   (arrowcloud unavailable)"
			end
			if f.status == "loading" and #f.cards == 0 then
				label = label .. "   finding packs..."
			elseif f.status == "ready" and #f.cards == 0 then
				label = label .. "   nothing qualifying right now"
			end
			self:settext(label)
			self:diffuse(AccentColor())
		end,
	}

	for slot = 1, FEAT.VISIBLE do
		local col = (slot - 1) % FEAT.COLS
		local row = math.floor((slot - 1) / FEAT.COLS)
		local cardX = LO.FeatX(col)
		local cardY = LO.FEAT_TOP + row * (LO.FEAT_CARD_H + LO.FEAT_ROW_GAP)

		local function CardAt()
			local index = state.featWindow + slot
			if index > FEAT.TARGET then return nil end   -- surplus stays hidden
			return state.featured.cards[index]
		end
		local function CardFocused()
			return state.zone == "featured"
				and (state.featWindow + slot) == state.featCursor
		end
		-- the size the banner is actually drawn at, so everything else can hug it.
		-- Falls back to the whole card while the image is still on its way, which
		-- is what the empty placeholder wants anyway.
		local function CardArtSize()
			local card = CardAt()
			local pack = card and card.pack
			local url  = pack and BannerUrlFor(pack)
			local aspect = url and state.bannerAspect[url]
			if not aspect or aspect <= 0 then
				return LO.FEAT_CARD_W, LO.FEAT_CARD_H
			end
			if aspect >= LO.FEAT_CARD_W / LO.FEAT_CARD_H then
				return LO.FEAT_CARD_W, LO.FEAT_CARD_W / aspect
			end
			return LO.FEAT_CARD_H * aspect, LO.FEAT_CARD_H
		end

		local card = Def.ActorFrame{
			InitCommand = function(self) self:xy(cardX, cardY) end,

			-- focus ring, behind everything so it reads as a rim
			Def.Quad{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2):visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(CardFocused() and CardAt() ~= nil)
					local w, h = CardArtSize()
					self:setsize(w + 4, h + 4)
					self:diffuse(AccentColor())
				end,
			},

			-- the card itself: a vertical gradient rather than a flat panel, so
			-- the art has something to sit on that is not just background
			Def.Quad{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2)
				end,
				SMORefreshMessageCommand = function(self)
					local card = CardAt()
					local pending = (card == nil)
						and state.featured.status == "loading"
						and (state.featWindow + slot) <= FEAT.TARGET
					self:visible(card ~= nil or pending)
					self:setsize(CardArtSize())
					if not card then
						self:diffusetopedge(color("#26262CF0"))
						self:diffusebottomedge(color("#131318F0"))
						return
					end
					local accent = AccentColor()
					if CardFocused() then
						self:diffusetopedge({accent[1]*0.85, accent[2]*0.85, accent[3]*0.85, 1})
						self:diffusebottomedge({accent[1]*0.22, accent[2]*0.22, accent[3]*0.22, 1})
					else
						self:diffusetopedge({accent[1]*0.40, accent[2]*0.40, accent[3]*0.40, 1})
						self:diffusebottomedge({accent[1]*0.07, accent[2]*0.07, accent[3]*0.07, 1})
					end
				end,
			},

			-- pack art, given as much of the card as it can take
			Def.Sprite{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2)
				end,
				SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOSetBannerCommand = function(self)
					local card = CardAt()
					local pack = card and card.pack
					local url = pack and BannerUrlFor(pack)
					local path = url and state.banners[url]
					local key = "feat" .. slot
					if pack and path then
						if loadedBanner[key] ~= path then
							self:Load(path)
							loadedBanner[key] = path
						end
						MeasureBanner(self, url)
						FitSprite(self, LO.FEAT_CARD_W, LO.FEAT_CARD_H)
						self:diffuse(1, 1, 1, 1)
						self:visible(true)
					elseif url then
						-- still on its way; the card has its own spinner
						self:visible(false)
						RequestBanner(url)
					elseif pack then
						LO.ShowNoBanner(self, key, loadedBanner,
							LO.FEAT_CARD_W, LO.FEAT_CARD_H)
					else
						self:visible(false)
					end
				end,
			},

			-- spinner while this slot is still being filled in
			Spinner(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2, 0.12, function()
				local index = state.featWindow + slot
				local card = state.featured.cards[index]
				if state.mode ~= "list" and state.mode ~= "confirm" then return false end
				if state.search ~= "" then return false end
				if card then return BannerPending(card.pack) end
				return state.featured.status == "loading" and index <= FEAT.TARGET
			end),

			-- a wash of the accent colour over the art while it is highlighted,
			-- strongest at the top so the card still reads bottom-lit
			Def.Quad{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2):visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					if not (CardFocused() and CardAt()) then
						self:visible(false)
						return
					end
					local accent = AccentColor()
					self:visible(true)
					self:setsize(CardArtSize())
					self:diffusetopedge({accent[1], accent[2], accent[3], 0.42})
					self:diffusebottomedge({accent[1], accent[2], accent[3], 0.06})
				end,
			},
		}

		featAF[#featAF+1] = card
	end

	ui[#ui+1] = featAF

	-- Which page of the featured strip you are on: one dot per page.
	--
	-- These were square quads, and the current page was a slightly wider
	-- rectangle -- at five pixels across that reads as grit on the screen
	-- rather than as an indicator. Round, evenly spaced, and the current page
	-- is the accent colour at a size that is clearly deliberate.
	for dot = 1, 8 do
		ui[#ui+1] = Def.Sprite{
			Texture = LO.ICONS .. "dot.png",
			InitCommand = function(self) self:visible(false) end,
			SMORefreshMessageCommand = function(self)
				if not LO.GridShowing() or state.search ~= "" then
					self:visible(false)
					return
				end
				local pages = math.ceil(FEAT.Count() / FEAT.VISIBLE)
				if pages <= 1 or dot > pages then
					self:visible(false)
					return
				end
				local spacing = 13
				local x0 = LO.W/2 - ((pages - 1) * spacing) / 2
				self:visible(true)
				self:xy(x0 + (dot-1)*spacing, LO.FEAT_RULE_Y)
				if dot == FEAT.Page() + 1 then
					self:zoom(7/96):diffuse(AccentColor()):diffusealpha(1)
				else
					self:zoom(5/96):diffuse(1, 1, 1, 0.28)
				end
			end,
		}
	end
end
