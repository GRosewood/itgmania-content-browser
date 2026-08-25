-- -----------------------------------------------------------------------
-- Small actors used all over the screen
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor  = CB.AccentColor
local BannerUrlFor = CB.BannerUrlFor
local Clamp        = CB.Clamp
local DetailInFlight = CB.DetailInFlight
local LO           = CB.LO
local state        = CB.state

-- curve, when given, reshapes the 0..1 position. It exists for one caller; see
-- the pack list's for why a straight ratio is useless there.
local function ScrollBar(x, y, length, horizontal, fn, curve)
	local function Geometry()
		local total, visible, offset = fn()
		if not (total and visible) or total <= visible then return nil end
		local thumb = math.max(14, math.floor(length * (visible / total)))
		local span  = length - thumb
		local pos   = 0
		if total > visible then
			local frac = Clamp(offset or 0, 0, total - visible) / (total - visible)
			if curve then frac = Clamp(curve(frac), 0, 1) end
			pos = math.floor(span * frac + 0.5)
		end
		return thumb, Clamp(pos, 0, span)
	end

	local af = Def.ActorFrame{
		InitCommand = function(self)
			self:xy(x, type(y) == "function" and y() or y):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			if type(y) == "function" then self:y(y()) end
			self:visible(state.open and not state.textEntryOpen and Geometry() ~= nil)
		end,
	}

	-- track
	af[#af+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			if horizontal then
				self:setsize(length, LO.SCROLL_W)
			else
				self:setsize(LO.SCROLL_W, length)
			end
			self:diffuse(1, 1, 1, 0.10)
		end,
	}

	-- thumb
	af[#af+1] = Def.Quad{
		InitCommand = function(self) self:vertalign(top):horizalign(left) end,
		SMORefreshMessageCommand = function(self)
			local thumb, pos = Geometry()
			if not thumb then return end
			if horizontal then
				self:xy(pos, 0):setsize(thumb, LO.SCROLL_W)
			else
				self:xy(0, pos):setsize(LO.SCROLL_W, thumb)
			end
			self:diffuse(AccentColor())
		end,
	}

	return af
end

-- A spinner that matches the rest of Simply Love: 30 frames over one second,
-- tinted with the player colour. visibleFn decides when it shows.
-- x and y may each be a number or a function of one. A caller that has to sit
-- beside text it does not control -- after a value whose width depends on what
-- the value turned out to be -- needs to work its place out per refresh.
local function Spinner(x, y, scale, visibleFn)
	local function at(v) return (type(v) == "function") and v() or v end
	return Def.Sprite{
		Texture = THEME:GetPathG("", "LoadingSpinner 10x3.png"),
		Frames  = Sprite.LinearFrames(30, 1),
		InitCommand = function(self)
			self:xy(at(x), at(y)):zoom(scale):visible(false)
			self:diffuse(AccentColor())
		end,
		SMORefreshMessageCommand = function(self)
			self:xy(at(x), at(y))
			self:visible(state.open and visibleFn() and true or false)
			self:diffuse(AccentColor())
		end,
		SMOBannerReadyMessageCommand = function(self)
			self:visible(state.open and visibleFn() and true or false)
		end,
	}
end

-- A wheel whose parent frame places it.
--
-- Spinner() above answers broadcasts itself, which is right while its position
-- is fixed. It is wrong the moment that position depends on something another
-- actor measures -- the width of a line of text just set, say -- because no two
-- actors have a defined order when a broadcast is delivered. This one carries
-- no commands at all, so it has no order to get wrong: the frame that owns the
-- text sets it, measures it, and calls SpinnerSet below with the answer.
local function SpinnerChild(name, scale)
	return Def.Sprite{
		Name    = name,
		Texture = THEME:GetPathG("", "LoadingSpinner 10x3.png"),
		Frames  = Sprite.LinearFrames(30, 1),
		InitCommand = function(self) self:zoom(scale):visible(false) end,
	}
end

-- Place and show a wheel made by SpinnerChild. The owning frame calls this.
local function SpinnerSet(sprite, x, y, show)
	if not sprite then return end
	local on = state.open and show and true or false
	sprite:visible(on)
	if not on then return end
	sprite:xy(x, y)
	sprite:diffuse(AccentColor())
end

-- true while a pack banner is still on its way in
--
-- A banner inside its ten-minute failure cooldown is NOT on its way in, and a
-- spinning wheel over an empty box says otherwise for the whole session. All
-- three callers of this were making that promise.
local function BannerPending(pack)
	if not pack then return false end
	local url = BannerUrlFor(pack)
	if not url then return DetailInFlight(pack.id) end
	if state.bannerFailed[url] then return false end
	return state.banners[url] == nil
end

-- scale + position a sprite inside a box, preserving aspect ratio
local function FitSprite(sprite, maxw, maxh)
	local w = sprite:GetWidth()
	local h = sprite:GetHeight()
	if w > 0 and h > 0 then
		sprite:zoom(math.min(maxw/w, maxh/h))
	end
end

-- What a pack with no banner shows instead.
--
-- Plenty have none -- the whole keyboard tab is packs the site never had art
-- for -- and hiding the sprite left a hole where every other row had a picture,
-- which read as a row that had failed to load rather than as a pack without a
-- picture. The placeholder is banner-shaped, so the row keeps its shape, and
-- dim, so it never competes with the packs that do have art.
--
-- It goes into the sprite that would have held the banner, so it costs no
-- actor. Each caller passes the key it already uses to avoid reloading the
-- same texture every frame.
-- On LO rather than a bare local so the screen parts that draw placeholders
-- reach it through the table they already import. (Under the old single-file
-- layout this dodged BrowserActor's upvalue ceiling; the split removed the
-- ceiling and kept the address.)
LO.NO_BANNER = LO.ICONS .. "nobanner.png"

-- Whether the artwork shipped, asked once. The answer cannot change while the
-- game runs -- module files are not installed mid-session -- and asking
-- FILEMAN again for every sprite on every refresh walked the VFS for a fact
-- it already had.
local hasNoBanner = FILEMAN:DoesFileExist(LO.NO_BANNER)

function LO.ShowNoBanner(sprite, key, loaded, maxw, maxh)
	local NO_BANNER = LO.NO_BANNER
	if not hasNoBanner then
		sprite:visible(false)
		return
	end
	if loaded[key] ~= NO_BANNER then
		sprite:Load(NO_BANNER)
		loaded[key] = NO_BANNER
	end
	FitSprite(sprite, maxw, maxh)
	sprite:diffuse(1, 1, 1, 0.17)
	sprite:visible(true)
end

-- -----------------------------------------------------------------------
-- browser actor tree

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.BannerPending = BannerPending
CB.FitSprite     = FitSprite
CB.ScrollBar     = ScrollBar
CB.Spinner       = Spinner
CB.SpinnerChild  = SpinnerChild
CB.SpinnerSet    = SpinnerSet
