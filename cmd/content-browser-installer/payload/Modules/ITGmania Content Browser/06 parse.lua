-- -----------------------------------------------------------------------
-- Reading the catalogue's HTML
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local CleanText       = CB.CleanText
local FormatBytes     = CB.FormatBytes
local LooksLikeCredit = CB.LooksLikeCredit
local METER_MAX       = CB.METER_MAX
local StripTags       = CB.StripTags
local Trim            = CB.Trim

-- one row from /api/packs/datatables ->
--   {id, name, bytes, sizeStr, songs, types, date, banner}
local function ParsePackRow(row)
	local id, rawname = row[2]:match('href="/pack/(%d+)">(.-)</a>')
	if not id then return nil end
	local pack = {}
	pack.id      = id
	pack.name    = CleanText(rawname)
	pack.banner  = row[1]:match('data%-src="([^"]+)"')
	if pack.banner and pack.banner:find("nobanner", 1, true) then pack.banner = nil end
	pack.bytes   = tonumber(row[3]:match('data%-sort="(%d+)"')) or 0
	pack.sizeStr = FormatBytes(pack.bytes)
	pack.songs   = tonumber(StripTags(row[4]):match("%d+")) or 0
	pack.types   = {}
	for alt in row[5]:gmatch('alt="([^"]+)"') do
		pack.types[#pack.types+1] = alt
	end
	pack.date = Trim(StripTags(row[6])):match("[%d%-]+") or ""
	return pack
end

-- the /pack/<id> page ->
--   {stats={songs,size,charts,difficulty}, labels={}, counts={}, songs={}, author}
local function ParsePackDetail(html)
	local det = { stats = {}, labels = {}, counts = {}, songs = {}, chartTypes = {} }

	for _, key in ipairs({"Songs", "Size", "Charts", "Difficulty", "Sync"}) do
		local v = html:match('>' .. key .. '</small>.-text%-white">%s*(.-)%s*</div>')
		det.stats[key:lower()] = v and CleanText(v) or nil
	end

	-- banner and release date (used for packs that came from the CSV, which
	-- has neither, and for the featured-section date window)
	det.banner = html:match('property="og:image" content="https?://[^"]-(/media/images/packs/[^"]+)"')
	if det.banner and det.banner:find("nobanner", 1, true) then det.banner = nil end
	det.date = html:match('<h5 class="card%-title mb%-0">([%a%.]+ %d+, %d%d%d%d)</h5>')
	det.year = det.date and tonumber(det.date:match("(%d%d%d%d)"))

	-- difficulty distribution from the Chart.js block
	local labels = html:match("labels:%s*%[([^%]]*)%]")
	local counts = html:match("data:%s*%[([^%]]*)%]")
	if labels and counts then
		local rawLabels, rawCounts = {}, {}
		for n in labels:gmatch("%-?%d+") do rawLabels[#rawLabels+1] = tonumber(n) end
		for n in counts:gmatch("%-?%d+") do rawCounts[#rawCounts+1] = tonumber(n) end
		for i, meter in ipairs(rawLabels) do
			-- joke charts get meters in the thousands; they would blow out the
			-- histogram scale and print ranges like "1 - 5454"
			if meter >= 1 and meter <= METER_MAX then
				det.labels[#det.labels+1] = meter
				det.counts[#det.counts+1] = rawCounts[i] or 0
			end
		end
	end

	-- per-song rows from the song table
	local credits = {}
	for tr in html:gmatch("<tr>(.-)</tr>") do
		if tr:find("/song/", 1, true) then
			local tds = {}
			for td in tr:gmatch("<td[^>]*>(.-)</td>") do
				tds[#tds+1] = td
			end
			if #tds >= 8 then
				local song = {}
				song.image    = tds[1]:match('src="([^"]+)"')
				-- the site's "no banner available" placeholder carries no
				-- information; a substituted pack banner does, so that one stays
				if song.image and song.image:find("nobanner", 1, true) then
					song.image = nil
				end
				song.title    = CleanText(tds[2]:match('href="/song/%d+">(.-)</a>') or "")
				song.artist   = CleanText(tds[2]:match('<span class="small translatable text%-gray%-400"[^>]*>(.-)</span>') or "")
				song.subtitle = CleanText(tds[3])
				song.length   = CleanText(tds[4])
				song.bpm      = CleanText(tds[5])
				-- credits are separated by <br> as often as by commas, so the
				-- break has to become a separator rather than vanish
				song.credit   = (CleanText((tds[6]:gsub("<[bB][rR]%s*/?>", ", ")))
					:gsub("[,%s]+$", ""))
				song.meters   = CleanText(tds[8])
				-- The styles column is NOT what this song holds.
				--
				-- It is the page's "Filter By Mode" control, repeated in every
				-- row: the same four buttons -- pump-single, pump-double,
				-- dance-double, dance-single -- with identical markup on every
				-- song of every pack, and no attribute anywhere saying which
				-- of them a song actually has. Reading it as data marked every
				-- song as having every style, which is why a pack's two style
				-- rows always printed the same range and every song row showed
				-- both icons.
				--
				-- So it is not read. What a pack is gets answered from the
				-- catalogue's own pack type and from itgdb's doubles list, both
				-- of which are real. See LO.StyleOf.
				song.styles = nil
				if song.title ~= "" then
					det.songs[#det.songs+1] = song
					if song.credit ~= "" then
						for credit in song.credit:gmatch("[^,]+") do
							credit = Trim(credit)
							if LooksLikeCredit(credit) then
								credits[credit] = (credits[credit] or 0) + 1
							end
						end
					end
				end
			end
			if #det.songs >= 400 then break end
		end
	end

	-- summarize the most common chart credits as the pack "author"
	local ranked = {}
	for name, count in pairs(credits) do
		ranked[#ranked+1] = {name=name, count=count}
	end
	table.sort(ranked, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name   -- stable when two charters tie
	end)
	det.creditCount = #ranked
	if #ranked > 0 then
		local names = {}
		for i = 1, math.min(3, #ranked) do names[#names+1] = ranked[i].name end
		det.author = table.concat(names, ", ")
		if #ranked > 3 then det.author = det.author .. ", ..." end
		-- LooksLikeCredit already screened these at collection time
		det.credits = names
	end

	return det
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.ParsePackDetail = ParsePackDetail
CB.ParsePackRow    = ParsePackRow
