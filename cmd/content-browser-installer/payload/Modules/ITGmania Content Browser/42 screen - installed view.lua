-- -----------------------------------------------------------------------
-- The installed-packs view
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor         = CB.AccentColor
local FitSprite           = CB.FitSprite
local FormatDate          = CB.FormatDate
local INST_COLS           = CB.INST_COLS
local INST_ROWS           = CB.INST_ROWS
local InInstalledView     = CB.InInstalledView
local InstalledStatusText = CB.InstalledStatusText
local LO                  = CB.LO
local ScrollBar           = CB.ScrollBar
local Sync                = CB.Sync
local loadedBanner        = CB.loadedBanner
local state               = CB.state

function CB.Screen.InstalledView(ui)
	-- ---------------------------------------------------------------
	-- INSTALLED PACKS view

	local INST_TOP    = LO.FEAT_TOP
	local INST_ROW_H  = 32
	local INST_PER_COL = INST_ROWS / INST_COLS
	local INST_GAP    = 12
	local INST_W      = math.floor(
		(LO.W - 2*LO.LIST_X - (INST_COLS-1)*INST_GAP) / INST_COLS)

	local instAF = Def.ActorFrame{
		Name = "Installed",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and (state.mode == "installed" or state.mode == "removeconfirm"))
		end,
	}

	-- summary line
	instAF[#instAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X, LO.FEAT_LABEL_Y):zoom(0.55)
		end,
		SMORefreshMessageCommand = function(self)
			local inst = state.installed
			local label = string.format("%d PACKS IN YOUR LIBRARY", #inst.packs)
			if #inst.packs > INST_ROWS then
				label = label .. LO.InstPageText()
			end
			if state.helper.status == "absent" then
				label = label .. "   -   removal unavailable"
			end
			self:settext(label)
			self:diffuse(AccentColor())
		end,
	}

	-- The key, under the table: what the three colours mean, and what this
	-- machine does with a pack that does not say anything for itself.
	for item in ivalues({
		{ "good", "sync recorded", 0 },
		{ "warn", "this machine decides", 96 },
	}) do
		local health, label, dx = item[1], item[2], item[3]
		instAF[#instAF+1] = Def.Quad{
			InitCommand = function(self)
				self:xy(LO.LIST_X + 4 + dx, LO.CONTENT_BOT + 4):setsize(7, 7)
				local r, g, b = Sync.HealthColor(health)
				self:diffuse(r, g, b, 1)
			end,
		}
		instAF[#instAF+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = label,
			InitCommand = function(self)
				self:horizalign(left):xy(LO.LIST_X + 13 + dx, LO.CONTENT_BOT + 4)
				self:zoom(0.42):diffuse(0.72, 0.72, 0.72, 1)
			end,
		}
	end

	-- what the unlabelled packs are falling back on
	instAF[#instAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - LO.LIST_X, LO.CONTENT_BOT + 4)
			self:zoom(0.42):diffuse(0.72, 0.72, 0.72, 1)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext("no Pack.ini means this machine decides:  " .. Sync.MachineLabel())
		end,
	}

	for slot = 1, INST_ROWS do
		local rowX = LO.LIST_X
			+ math.floor((slot-1) / INST_PER_COL) * (INST_W + INST_GAP)
		local rowY = INST_TOP + ((slot-1) % INST_PER_COL) * INST_ROW_H

		local function PackAt()
			local inst = state.installed
			return inst.packs[inst.window + slot]
		end
		local function Focused()
			local inst = state.installed
			return state.zone == "list" and (inst.window + slot) == inst.cursor
		end

		-- row background / focus fill
		instAF[#instAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(rowX, rowY):setsize(INST_W, INST_ROW_H - 4)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				self:visible(pack ~= nil)
				if not pack then return end
				if Focused() then
					self:diffuse(AccentColor()):diffusealpha(0.30)
				elseif state.removing == pack.name then
					self:diffuse(0.55, 0.13, 0.16, 0.42)
				else
					self:diffuse(0, 0, 0, (slot % 2 == 0) and 0.34 or 0.5)
				end
			end,
		}

		-- Sync health, as a stripe down the row's leading edge. A stripe rather
		-- than a dot: it reads at a glance down a column of twenty-two rows,
		-- which is the point of colouring them at all.
		instAF[#instAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(rowX, rowY):setsize(4, INST_ROW_H - 4)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				self:visible(pack ~= nil)
				if not pack then return end
				if pack.waiting then
					-- Nothing is known about its sync until the library has it,
					-- and amber would be a claim rather than a gap. A plain
					-- stripe says the row is there and says nothing else.
					self:diffuse(0.45, 0.45, 0.45, 1)
					return
				end
				local r, g, b = Sync.HealthColor((Sync.Health(pack)))
				self:diffuse(r, g, b, 1)
			end,
		}

		-- pack banner
		instAF[#instAF+1] = Def.Sprite{
			InitCommand = function(self)
				self:xy(rowX + 36, rowY + (INST_ROW_H - 4)/2):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				local path = pack and pack.banner
				local key = "inst" .. slot
				if path and path ~= "" then
					if loadedBanner[key] ~= path then
						self:Load(path)
						loadedBanner[key] = path
					end
					FitSprite(self, 64, INST_ROW_H - 8)
					self:visible(true)
				else
					self:visible(false)
				end
			end,
		}

		-- pack name
		instAF[#instAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(rowX + 76, rowY + 8):zoom(0.55)
				self:maxwidth((INST_W - 76 - 96)/0.55)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				self:settext(pack and pack.name or "")
				if pack and state.removing == pack.name then
					self:diffuse(1, 0.62, 0.62, 1)
				else
					self:diffuse(1, 1, 1, 1)
				end
			end,
		}

		-- song count
		instAF[#instAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(rowX + 76, rowY + 20):zoom(0.42)
				self:diffuse(0.6, 0.6, 0.6, 1)
				self:maxwidth((INST_W - 76 - 96)/0.42)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				if not pack then self:settext("") return end
				if pack.waiting then
					-- Nothing else is known about it yet: its song count, its
					-- folder and its sync all come from the loaded library, and
					-- that is exactly what it is waiting for.
					self:settext("downloaded - reload songs to play it")
					return
				end
				local bits = { pack.songs .. (pack.songs == 1 and " song" or " songs") }
				-- only packs this browser installed have a date; the rest say
				-- nothing rather than inventing one
				if pack.added then
					bits[#bits+1] = "added " .. FormatDate(pack.added, true)
				end
				bits[#bits+1] = Sync.RowLabel(pack)
				self:settext(table.concat(bits, "   -   "))
			end,
		}

		-- SMO comparison / removal marker
		instAF[#instAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):xy(rowX + INST_W - 10, rowY + (INST_ROW_H - 4)/2)
				self:zoom(0.5)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				if not pack then self:settext("") return end
				if state.removing == pack.name then
					self:settext("REMOVING...")
					self:diffuse(1, 0.42, 0.42, 1)
					return
				end
				local text, r, g, b = InstalledStatusText(pack)
				self:settext(text)
				self:diffuse(r, g, b, 1)
			end,
		}
	end

	-- empty state
	instAF[#instAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.W/2, INST_TOP + 60):zoom(0.6):diffuse(0.7, 0.7, 0.7, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local inst = state.installed
			if inst.status == "ready" and #inst.packs == 0 then
				self:settext("No song packs found in /Songs.")
			else
				self:settext("")
			end
		end,
	}

	instAF[#instAF+1] = ScrollBar(
		LO.LIST_X + INST_COLS*INST_W + (INST_COLS-1)*INST_GAP + 5,
		INST_TOP, INST_PER_COL*INST_ROW_H - 4, false,
		function()
			if not InInstalledView() then return nil end
			return #state.installed.packs, INST_ROWS, state.installed.window
		end)

	ui[#ui+1] = instAF
end
