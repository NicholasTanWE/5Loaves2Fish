--[[
    Five Loaves and Two Fish
    Auction House price tracker

    v0.4.0 - MoP Classic: Ores + Herbs
      - scan, low/high/median per day (anomaly filtered), 30 day history
      - tooltip price, history window, buy/sell deal finder, CSV export
]]

local ADDON_NAME, ns = ...

-- ============================================================
-- Constants
-- ============================================================
local HISTORY_DAYS  = 30
local MIN_DAYS_FOR_DEALS = 1   -- earlier days (excluding today) needed before an item can be flagged

local CLASS_TRADEGOODS = 7
local SUBCLASS_METAL   = 7         -- Metal & Stone (ores)
local SUBCLASS_HERB    = 9         -- Herb

-- Prices outside [median * LOW_BOUND, median * HIGH_BOUND] are treated as anomalies
local LOW_BOUND  = 0.10
local HIGH_BOUND = 3.0

local defaults = {
    threshold = 0.20,   -- 20% below/above 30d average counts as a deal
    items     = {},
    lastScan  = 0,
    debug     = false,
}

local FiveLoaves = {
    isScanning   = false,
    scanStart    = 0,
    currentPage  = 0,
    totalScanned = 0,
    pricesByItem = {},
    scanQueue    = {},
    queueIndex   = 1,
    mode         = "search",
}
ns.FiveLoaves = FiveLoaves

-- ============================================================
-- Messaging
-- ============================================================
local function Msg(level, text)
    local colors = { ACTION = "00ff00", INFO = "ffffff", WARN = "ffff00", ERROR = "ff4444" }
    if level == "DEBUG" then
        if not (FiveLoaves.db and FiveLoaves.db.debug) then return end
        text = "[Debug] " .. text
        print("|cff00ff00Five Loaves|r: |cffaaaaaa" .. text .. "|r")
        return
    end
    print("|cff00ff00Five Loaves|r: |cff" .. (colors[level] or "ffffff") .. text .. "|r")
end
local function Action(m) Msg("ACTION", m) end
local function Info(m)   Msg("INFO", m) end
local function Warn(m)   Msg("WARN", m) end
local function Error(m)  Msg("ERROR", m) end
local function Debug(m)  Msg("DEBUG", m) end

-- ============================================================
-- Utility
-- ============================================================
local function GetDayKey(ts) return date("%Y-%m-%d", ts or time()) end

-- Standard coin colours: the unit letter is coloured, the number stays default.
local function Coin(n, unit)
    local colour = unit == "g" and "ffd100" or unit == "s" and "c7c7cf" or "eda55f"
    return format("%d|cff%s%s|r", n, colour, unit)
end

local function Money(copper)
    if not copper or copper <= 0 then return "-" end
    local g = floor(copper / 10000)
    local s = floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return Coin(g, "g") .. " " .. Coin(s, "s") .. " " .. Coin(c, "c")
    elseif s > 0 then return Coin(s, "s") .. " " .. Coin(c, "c")
    else return Coin(c, "c") end
end

local function Median(sorted)
    local n = #sorted
    if n == 0 then return nil end
    if n % 2 == 1 then return sorted[(n + 1) / 2] end
    return floor((sorted[n / 2] + sorted[n / 2 + 1]) / 2)
end

-- Returns low, high, median after dropping anomalous listings
local function AnalyzePrices(prices)
    if not prices or #prices == 0 then return nil end
    table.sort(prices)
    local med = Median(prices)
    local lo, hi = med * LOW_BOUND, med * HIGH_BOUND
    local low, high
    for _, p in ipairs(prices) do
        if p >= lo and p <= hi then
            low = low or p
            high = p
        end
    end
    return low or prices[1], high or prices[#prices], med
end

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- ============================================================
-- Data storage
-- ============================================================
local function ResolveName(itemID, name)
    if name and name ~= "" then return name end
    return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID))
end

function FiveLoaves:EnsureItem(itemID, name)
    local items = self.db.items
    if not items[itemID] then
        items[itemID] = { name = ResolveName(itemID, name) or ("Item " .. itemID), history = {}, lastSeen = 0 }
    else
        local cur = items[itemID].name
        if not cur or cur == "" or cur:find("^Item %d+$") then
            items[itemID].name = ResolveName(itemID, name) or ("Item " .. itemID)
        end
    end
    return items[itemID]
end

function FiveLoaves:RecordPrice(itemID, name, low, high, median, qty)
    if not low or low <= 0 then return end
    local item = self:EnsureItem(itemID, name)
    -- one entry per day: the latest scan of the day replaces earlier ones
    item.history[GetDayKey()] = { low = low, high = high, med = median, qty = qty or 0, time = time() }
    item.currentLow  = low
    item.currentHigh = high
    item.lastSeen    = time()
end

function FiveLoaves:PruneOldHistory()
    local cutoff = time() - (HISTORY_DAYS * 86400)
    for _, item in pairs(self.db.items) do
        for dayKey, e in pairs(item.history) do
            if e.time < cutoff then item.history[dayKey] = nil end
        end
    end
end

-- Average of daily lows over the stored window, optionally excluding today
function FiveLoaves:GetStats(itemID, excludeToday)
    local item = self.db.items[itemID]
    if not item then return nil end
    local today = GetDayKey()
    local sumLow, sumHigh, n = 0, 0, 0
    local minLow, maxHigh
    for day, e in pairs(item.history) do
        if not (excludeToday and day == today) then
            sumLow  = sumLow + e.low
            sumHigh = sumHigh + (e.high or e.low)
            n = n + 1
            minLow  = (not minLow or e.low < minLow) and e.low or minLow
            maxHigh = (not maxHigh or (e.high or e.low) > maxHigh) and (e.high or e.low) or maxHigh
        end
    end
    if n == 0 then return nil end
    return { avgLow = floor(sumLow / n), avgHigh = floor(sumHigh / n), minLow = minLow, maxHigh = maxHigh, days = n }
end

function FiveLoaves:GetCurrentLow(itemID)
    local i = self.db.items[itemID]
    return i and i.currentLow
end

-- ============================================================
-- Scanning (modern AH API: full replicate scan; all items, or ores + herbs if db.herbsOresOnly)
-- ============================================================
local BATCH_SIZE = 500

local function IsTrackedItem(itemID)
    if not FiveLoaves.db.herbsOresOnly then return true end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local _, _, _, _, _, classID, subClassID = getInstant(itemID)
    return classID == CLASS_TRADEGOODS and (subClassID == SUBCLASS_METAL or subClassID == SUBCLASS_HERB)
end

function FiveLoaves:IsAuctionHouseOpen()
    return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())
end

function FiveLoaves:StartScan()
    if self.isScanning then Warn("Scan already in progress.") return end
    if not self:IsAuctionHouseOpen() then
        Error("Open the Auction House first.")
        return
    end
    if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
        Error("This client has no full-scan API (C_AuctionHouse.ReplicateItems).")
        return
    end

    self.isScanning   = true
    self.scanStart    = GetTime()
    self.totalScanned = 0
    self.pricesByItem = {}
    self.typeCache    = {}
    self.scanToken    = (self.scanToken or 0) + 1
    local token = self.scanToken

    Action(format("Requesting full AH scan (%s). This can take a few seconds...", self.db.herbsOresOnly and "ores + herbs only" or "ALL items"))
    self:UpdateStatus("Scanning...")
    C_AuctionHouse.ReplicateItems()

    -- the server may refuse a repeat scan; give up cleanly
    C_Timer.After(60, function()
        if self.isScanning and self.scanToken == token and not self.processing then
            self.isScanning = false
            Warn("No scan data received. The full scan has a cooldown (~15 min); try again later.")
            self:UpdateStatus("Scan timed out")
        end
    end)
end

function FiveLoaves:OnReplicateUpdate()
    if not self.isScanning or self.processing then return end
    local num = C_AuctionHouse.GetNumReplicateItems()
    if not num or num == 0 then return end
    self.processing = true
    Debug("Replicate items: " .. num)
    self:ProcessBatch(0, num, self.scanToken)
end

function FiveLoaves:ProcessBatch(startIndex, num, token)
    if self.scanToken ~= token or not self.isScanning then self.processing = false return end
    local last = min(startIndex + BATCH_SIZE, num)
    for i = startIndex, last - 1 do
        local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
            C_AuctionHouse.GetReplicateItemInfo(i)
        if itemID and buyout and buyout > 0 and count and count > 0 then
            local tracked = self.typeCache[itemID]
            if tracked == nil then
                tracked = IsTrackedItem(itemID) and true or false
                self.typeCache[itemID] = tracked
            end
            if tracked then
                local d = self.pricesByItem[itemID]
                if not d then
                    d = { prices = {}, totalQty = 0 }
                    self.pricesByItem[itemID] = d
                end
                tinsert(d.prices, floor(buyout / count))
                d.totalQty = d.totalQty + count
                if name and name ~= "" then d.name = name end
                self.totalScanned = self.totalScanned + 1
            end
        end
    end
    self:UpdateStatus(format("Scanning... %d%%", floor(last / num * 100)))
    if last < num then
        C_Timer.After(0, function() self:ProcessBatch(last, num, token) end)
    else
        self.processing = false
        self:FinalizeScan()
    end
end

function FiveLoaves:FinalizeScan()
    local count = 0
    for itemID, d in pairs(self.pricesByItem) do
        local ok, err = pcall(function()
            local low, high, med = AnalyzePrices(d.prices)
            if low then
                self:RecordPrice(itemID, d.name, low, high, med, d.totalQty)
                count = count + 1
            end
        end)
        if not ok then Error(format("Failed to record item %d: %s", itemID, tostring(err))) end
    end
    self.db.lastScan = time()
    self:PruneOldHistory()
    self.isScanning = false

    Action(format("Scan complete: %d items updated in %.1fs (%d auctions).",
        count, GetTime() - self.scanStart, self.totalScanned))
    self:UpdateStatus(format("Last scan: %s (%d items)", date("%H:%M"), count))
    self:RefreshList()
end

-- ============================================================
-- Deals
-- ============================================================
function FiveLoaves:FindDeals(kind)
    local out = {}
    local th = self.db.threshold
    for itemID, item in pairs(self.db.items) do
        local s = self:GetStats(itemID, true)
        local cur = item.currentLow
        if s and s.days >= MIN_DAYS_FOR_DEALS and cur and s.avgLow > 0 then
            local diff = (cur - s.avgLow) / s.avgLow
            if (kind == "buy" and diff <= -th) or (kind == "sell" and diff >= th) then
                tinsert(out, { id = itemID, name = item.name, diff = diff, cur = cur, avg = s.avgLow })
            end
        end
    end
    table.sort(out, function(a, b)
        if kind == "buy" then return a.diff < b.diff end
        return a.diff > b.diff
    end)
    return out
end

-- ============================================================
-- Export (CSV shown in a copyable box; addons cannot write files)
-- ============================================================
function FiveLoaves:BuildCSV()
    local lines = { "item_id,name,date,low_copper,high_copper,median_copper,quantity" }
    local ids = {}
    for id in pairs(self.db.items) do tinsert(ids, id) end
    table.sort(ids, function(a, b) return (self.db.items[a].name or "") < (self.db.items[b].name or "") end)
    for _, id in ipairs(ids) do
        local item = self.db.items[id]
        local days = {}
        for day in pairs(item.history) do tinsert(days, day) end
        table.sort(days)
        for _, day in ipairs(days) do
            local e = item.history[day]
            tinsert(lines, format("%d,\"%s\",%s,%d,%d,%d,%d", id, (item.name or ""):gsub('"', '""'),
                day, e.low or 0, e.high or 0, e.med or 0, e.qty or 0))
        end
    end
    return table.concat(lines, "\n")
end

function FiveLoaves:ShowExport()
    if not self.exportFrame then
        local f = CreateFrame("Frame", "FiveLoavesExportFrame", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(520, 360)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f.TitleText:SetText("Export - Ctrl+A, Ctrl+C, paste into a .csv / Excel")
        local sf = CreateFrame("ScrollFrame", "FiveLoavesExportScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -30)
        sf:SetPoint("BOTTOMRIGHT", -32, 12)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(470)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb)
        f.editBox = eb
        tinsert(UISpecialFrames, "FiveLoavesExportFrame")
        self.exportFrame = f
    end
    self.exportFrame.editBox:SetText(self:BuildCSV())
    self.exportFrame:Show()
    self.exportFrame.editBox:SetFocus()
    self.exportFrame.editBox:HighlightText()
end

-- ============================================================
-- Tooltip
-- ============================================================
local function AvgLow(item, days)
    local cutoff = time() - days * 86400
    local sum, n = 0, 0
    for _, e in pairs(item.history) do
        if e.time >= cutoff and e.low then sum, n = sum + e.low, n + 1 end
    end
    if n == 0 then return nil end
    return floor(sum / n), n
end

-- Compares a price with the item's earlier history (7 days, else all stored days; today excluded).
-- Returns "low" or "high" plus the reference price when it looks like an outlier, nil otherwise.
function FiveLoaves:PriceSanity(itemID, price)
    local item = self.db.items[itemID]
    if not (item and price and price > 0) then return nil end
    local today, cutoff = GetDayKey(), time() - 7 * 86400
    local s7, n7, sAll, nAll = 0, 0, 0, 0
    for day, e in pairs(item.history) do
        if day ~= today and e.low then
            sAll, nAll = sAll + e.low, nAll + 1
            if e.time >= cutoff then s7, n7 = s7 + e.low, n7 + 1 end
        end
    end
    local ref = (n7 > 0 and s7 / n7) or (nAll > 0 and sAll / nAll)
    if not ref or ref <= 0 then return nil end
    ref = floor(ref)
    if price < ref * (self.db.batchMinRatio or 0.5) then return "low", ref end
    if price > ref * (self.db.maxRatio or 3) then return "high", ref end
    return nil, ref
end

-- Adds the vendor sell price when nothing else (e.g. quest reward tooltips) has shown one.
local function AddVendorPrice(tooltip, itemID)
    if tooltip.fiveLoavesVendorDone or not tooltip.GetName then return end
    if tooltip.shownMoneyFrames and tooltip.shownMoneyFrames > 0 then return end
    local name = tooltip:GetName()
    if not name then return end
    local sellLabel = SELL_PRICE or "Sell Price"
    for i = 1, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text:find(sellLabel, 1, true) then
            -- Blizzard's own line: recolour the coin letters in place
            local right = _G[name .. "TextRight" .. i]
            local rtext = right and right:GetText()
            if rtext and not rtext:find("|c", 1, true) then
                local fixed = rtext:gsub("(%d+)([gsc])", function(n, u) return Coin(tonumber(n), u) end)
                if fixed ~= rtext then right:SetText(fixed) tooltip:Show() end
            end
            return
        end
    end
    local price = select(11, GetItemInfo(itemID))
    if not price or price <= 0 then return end
    tooltip.fiveLoavesVendorDone = true
    tooltip:AddDoubleLine("|cffffd100" .. sellLabel .. ":|r", Money(price), 1, 1, 1, 1, 1, 1)
    if not tooltip:IsShown() then tooltip:Show() end
end

local function AddPriceToTooltip(tooltip, itemID)
    if not (itemID and FiveLoaves.db) then return end
    AddVendorPrice(tooltip, itemID)
    if FiveLoaves.db.noTooltip then return end
    if tooltip.fiveLoavesItem == itemID and tooltip.fiveLoavesDone then return end
    local item = FiveLoaves.db.items[itemID]
    if not (item and item.currentLow) then return end
    tooltip.fiveLoavesItem, tooltip.fiveLoavesDone = itemID, true

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("|cff00ff00Last AH scan:|r", Money(item.currentLow), 1, 1, 1, 1, 1, 1)
    local flag, ref = FiveLoaves:PriceSanity(itemID, item.currentLow)
    if flag then
        local pct = floor(math.abs(item.currentLow / ref - 1) * 100 + 0.5)
        tooltip:AddLine(format("|cffff4444Suspicious: scan price is %d%% %s the usual %s|r", pct,
            flag == "low" and "below" or "above", Money(ref)), 1, 1, 1, true)
    end
    local avg, n = AvgLow(item, 7)
    tooltip:AddDoubleLine(format("7 day avg (%d %s):", n or 0, (n == 1) and "day" or "days"),
        avg and Money(avg) or "-", 0.7, 0.7, 0.7, 1, 1, 1)
    tooltip:AddDoubleLine("Scanned:", date("%m-%d %H:%M", item.lastSeen), 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
    if not tooltip:IsShown() then tooltip:Show() end
end

local function HookTooltips()
    local function safeAdd(tt, id)
        local ok, err = pcall(AddPriceToTooltip, tt, id)
        if not ok then Debug("Tooltip error: " .. tostring(err)) end
    end
    local function reset(tt) tt.fiveLoavesDone = nil tt.fiveLoavesVendorDone = nil end

    for _, tt in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
        if tt then
            tt:HookScript("OnTooltipCleared", reset)
            if tt.HasScript and tt:HasScript("OnTooltipSetItem") then
                tt:HookScript("OnTooltipSetItem", function(self)
                    local _, link = self:GetItem()
                    safeAdd(self, ItemIDFromLink(link))
                end)
            end
        end
    end

    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
            local id = data and data.id
            if not id and tt.GetItem then
                local _, link = tt:GetItem()
                id = ItemIDFromLink(link)
            end
            safeAdd(tt, id)
        end)
    end
    -- Alt+click a bag item to open its history
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown() then
            local id = ItemIDFromLink(link)
            if id then FiveLoaves:ShowItem(id) end
        end
    end)
end

-- ============================================================
-- Main window: sortable table (left) + line graph / history (right)
-- ============================================================
local TAB_ID = "FiveLoavesTab"
local ROWS   = 16
local ROW_H  = 22
local COLS = {
    { key = "name", label = "Item",   w = 110, align = "LEFT" },
    { key = "low",  label = "Low",    w = 66,  align = "RIGHT" },
    { key = "high", label = "High",   w = 66,  align = "RIGHT" },
    { key = "avg",  label = "Avg",    w = 66,  align = "RIGHT" },
    { key = "diff", label = "vs Avg", w = 46,  align = "RIGHT" },
    { key = "qty",  label = "Qty",    w = 46,  align = "RIGHT" },
}
local COL_START = 44
local COL_GAP   = 3
local LEFT_W    = COL_START + COL_GAP * #COLS + 6
for _, c in ipairs(COLS) do LEFT_W = LEFT_W + c.w end

-- Item categories for the filter dropdown (item class IDs)
local CATEGORY_CLASSES = { 0, 1, 2, 3, 4, 5, 7, 9, 15 }
local function CategoryName(classID)
    return (GetItemClassInfo and GetItemClassInfo(classID)) or ("Class " .. classID)
end

-- Trade goods subcategories (item subclass IDs under class 7). Some clients return no name
-- for a subclass, so fall back to known names; the menu lists only subclasses present in scan data.
local CLASS_TRADEGOODS_ID = 7
local SUBCLASS_NAMES = {
    [1] = "Parts", [2] = "Explosives", [3] = "Devices", [4] = "Jewelcrafting", [5] = "Cloth",
    [6] = "Leather", [7] = "Metal & Stone", [8] = "Cooking", [9] = "Herb", [10] = "Elemental",
    [11] = "Other", [12] = "Enchanting", [13] = "Materials", [16] = "Inscription",
}
local function SubCategoryName(classID, subID)
    local name = GetItemSubClassInfo and GetItemSubClassInfo(classID, subID)
    if name and name ~= "" then return name end
    if classID == CLASS_TRADEGOODS_ID and SUBCLASS_NAMES[subID] then return SUBCLASS_NAMES[subID] end
    return "Type " .. subID
end

-- Subclasses present in scan data, grouped by item class and sorted by name
function FiveLoaves:SubclassesByClass()
    local seen, byClass = {}, {}
    for id in pairs(self.db.items) do
        local classID, subID = select(6, GetItemInfoInstant(id))
        if classID and subID then
            seen[classID] = seen[classID] or {}
            if not seen[classID][subID] then
                seen[classID][subID] = true
                byClass[classID] = byClass[classID] or {}
                tinsert(byClass[classID], subID)
            end
        end
    end
    for classID, list in pairs(byClass) do
        table.sort(list, function(a, b) return SubCategoryName(classID, a) < SubCategoryName(classID, b) end)
    end
    return byClass
end

local COLOR_LOW  = { 0.25, 1.0, 0.25 }
local COLOR_HIGH = { 1.0, 0.4, 0.4 }

local function MoneyShort(c)
    if not c or c <= 0 then return "-" end
    local g, s, cc = floor(c / 10000), floor((c % 10000) / 100), c % 100
    if g >= 100 then return Coin(g, "g")
    elseif g > 0 then return Coin(g, "g") .. " " .. Coin(s, "s")
    elseif s > 0 then return Coin(s, "s") .. " " .. Coin(cc, "c")
    else return Coin(cc, "c") end
end

local function ItemIcon(itemID)
    return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID))
        or (GetItemIcon and GetItemIcon(itemID))
        or 134400
end

-- Tradable items in the bags (itemID -> total count); soulbound and quest items are skipped.
function FiveLoaves:GetBagItems()
    local out = {}
    local C = C_Container
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local slots = C and C.GetContainerNumSlots and C.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)
        for slot = 1, slots or 0 do
            local info = C and C.GetContainerItemInfo and C.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local classID = select(6, (C_Item.GetItemInfoInstant or GetItemInfoInstant)(info.itemID))
                if classID ~= 12 then -- quest items
                    out[info.itemID] = (out[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
        end
    end
    return out
end

-- ---------- table data ----------
function FiveLoaves:BuildRows()
    local rows = {}
    local q = (self.searchText or ""):lower()
    local th = self.db.threshold
    local bag = self.mode == "bag" and self:GetBagItems() or nil
    local source = self.db.items
    if bag then
        source = {}
        for id in pairs(bag) do
            source[id] = self.db.items[id] or { history = {}, lastSeen = 0 }
        end
    end
    for id, item in pairs(source) do
        local name = (bag and not self.db.items[id]) and (ResolveName(id) or ("Item " .. id)) or self:EnsureItem(id).name
        if q == "" or name:lower():find(q, 1, true) or tostring(id) == q then
          local classID, subID = select(6, GetItemInfoInstant(id))
          if (not self.category or classID == self.category) and (not self.subCategory or subID == self.subCategory) then
            local s = self:GetStats(id, true)
            local avg = s or self:GetStats(id)
            local diff
            if s and s.days >= MIN_DAYS_FOR_DEALS and item.currentLow and s.avgLow > 0 then
                diff = (item.currentLow - s.avgLow) / s.avgLow
            end
            local keep = true
            if self.mode == "buy" then keep = diff ~= nil and diff <= -th
            elseif self.mode == "sell" then keep = diff ~= nil and diff >= th end
            if keep then
                local e = item.lastSeen and item.lastSeen > 0 and item.history[GetDayKey(item.lastSeen)]
                tinsert(rows, {
                    id = id, name = name,
                    low = item.currentLow or 0, high = item.currentHigh or 0,
                    avg = avg and avg.avgLow or 0, diff = diff, qty = bag and bag[id] or (e and e.qty or 0),
                })
            end
          end
        end
    end
    local key, desc = self.sortKey or "name", self.sortDesc
    table.sort(rows, function(a, b)
        local x, y = a[key], b[key]
        if x == y then return a.name < b.name end
        if x == nil then return false end
        if y == nil then return true end
        if desc then return x > y end
        return x < y
    end)
    return rows
end

FiveLoaves.bagSel = {}

function FiveLoaves:UpdateBagControls()
    local f = self.mainFrame
    if not (f and f.auctionBtn) then return end
    local isBag = self.mode == "bag"
    f.auctionBtn:SetShown(isBag)
    f.clearBtn:SetShown(isBag)
    f.bagStatus:SetShown(isBag)
    f.checkAll:SetShown(isBag)
    if not isBag then return end
    local n, all = 0, true
    for _, r in ipairs(self.lastRows or {}) do
        if self.bagSel[r.id] then n = n + 1 else all = false end
    end
    f.checkAll:SetChecked(n > 0 and all)
    f.auctionBtn:SetText(n > 0 and format("Auction all selected (%d)", n) or "Auction all selected")
    f.auctionBtn:SetEnabled(n > 0 and not (self.Sell and self.Sell.batch))
    f.clearBtn:SetEnabled(next(self.bagSel) ~= nil and not (self.Sell and self.Sell.batch))
end

function FiveLoaves:AuctionSelected()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Warn("Open the Auction House first.") return end
    local ids = {}
    local inBag = self:GetBagItems()
    for id in pairs(self.bagSel) do
        if inBag[id] then ids[#ids + 1] = id end
    end
    if #ids == 0 then return end
    table.sort(ids)
    self.Sell:BatchPost(ids)
end

function FiveLoaves:SortBy(key)
    if self.sortKey == key then
        self.sortDesc = not self.sortDesc
    else
        self.sortKey, self.sortDesc = key, (key ~= "name")
    end
    self.offset = 0
    self:RefreshList()
end

function FiveLoaves:SetMode(mode)
    self.mode = mode
    self.offset = 0
    if self.mainFrame and self.mainFrame.slider then
        self.mainFrame.slider:SetShown(mode == "buy" or mode == "sell")
    end
    if mode == "buy" then self.sortKey, self.sortDesc = "diff", false
    elseif mode == "sell" then self.sortKey, self.sortDesc = "diff", true
    else self.sortKey, self.sortDesc = "name", false end
    self:RefreshList()
end

function FiveLoaves:RefreshList()
    local f = self.mainFrame
    if not (f and f:IsShown()) then return end
    local rows = self:BuildRows()
    self.lastRows = rows
    self.offset = max(0, min(self.offset or 0, #rows - ROWS))

    for i, c in ipairs(COLS) do
        local arrow = ""
        if (self.sortKey or "name") == c.key then arrow = self.sortDesc and " v" or " ^" end
        f.headers[i].label:SetText(((c.key == "qty" and self.mode == "bag") and "In bag" or c.label) .. arrow)
    end

    for i = 1, ROWS do
        local b, r = f.rows[i], rows[i + self.offset]
        if r then
            b.itemID = r.id
            b.icon:SetTexture(ItemIcon(r.id))
            b.cells[1]:SetText(r.name)
            b.cells[2]:SetText(MoneyShort(r.low))
            b.cells[3]:SetText(MoneyShort(r.high))
            b.cells[4]:SetText(MoneyShort(r.avg))
            if r.diff then
                local col = r.diff < 0 and "40ff40" or "ff6060"
                b.cells[5]:SetText(format("|cff%s%+d%%|r", col, floor(r.diff * 100)))
            else
                b.cells[5]:SetText("-")
            end
            b.cells[6]:SetText(r.qty)
            b.check:SetShown(self.mode == "bag")
            b.check:SetChecked(self.bagSel[r.id] and true or false)
            b.sel:SetShown(r.id == self.selected)
            b:Show()
        else
            b:Hide()
        end
    end

    self:UpdateBagControls()
    local label = (self.mode == "bag" and "In bags: ") or (self.mode == "buy" and "Buy now: ") or (self.mode == "sell" and "Sell now: ") or ""
    if #rows == 0 then
        f.listInfo:SetText(label .. "no items" .. ((self.mode == "buy" or self.mode == "sell") and format(" beyond %d%% of the average", floor(self.db.threshold * 100 + 0.5)) or ""))
    else
        f.listInfo:SetText(format("%s%d items (%d-%d) - scroll for more", label, #rows,
            self.offset + 1, min(#rows, self.offset + ROWS)))
    end
end

-- ---------- graph ----------
local function NextLine(g)
    g.nLines = g.nLines + 1
    local l = g.lines[g.nLines]
    if not l then
        l = g.plot:CreateLine(nil, "ARTWORK")
        l:SetThickness(2)
        g.lines[g.nLines] = l
    end
    l:Show()
    return l
end

local function NextDot(g)
    g.nDots = g.nDots + 1
    local d = g.dots[g.nDots]
    if not d then
        d = g.plot:CreateTexture(nil, "OVERLAY")
        d:SetSize(5, 5)
        g.dots[g.nDots] = d
    end
    d:Show()
    return d
end

function FiveLoaves:DrawGraph()
    local f = self.mainFrame
    if not f then return end
    local g = f.graph
    for _, l in ipairs(g.lines) do l:Hide() end
    for _, d in ipairs(g.dots) do d:Hide() end
    g.nLines, g.nDots, g.pts = 0, 0, {}
    for i = 1, 4 do g.grid[i]:Hide(); g.ylabels[i]:SetText("") end

    local item = self.selected and self.db.items[self.selected]
    local plot = g.plot
    local W, H = plot:GetWidth(), plot:GetHeight()
    if not item or W < 20 or H < 20 then
        g.empty:SetText(item and "" or "Select an item from the table")
        g.empty:Show()
        return
    end

    local pts = {}
    for day, e in pairs(item.history) do
        tinsert(pts, { t = e.time, day = day, low = e.low, high = e.high or e.low, qty = e.qty or 0 })
    end
    table.sort(pts, function(a, b) return a.t < b.t end)
    if #pts == 0 then g.empty:SetText("No history yet") g.empty:Show() return end
    g.empty:Hide()

    local vmin, vmax = pts[1].low, pts[1].high
    for _, p in ipairs(pts) do
        vmin = min(vmin, p.low)
        vmax = max(vmax, p.high)
    end
    if vmax <= vmin then vmin, vmax = vmin * 0.9, vmax * 1.1 + 1 end
    local pad = (vmax - vmin) * 0.08
    vmin, vmax = max(0, vmin - pad), vmax + pad

    for i = 1, 4 do
        local frac = (i - 1) / 3
        local grid = g.grid[i]
        grid:ClearAllPoints()
        grid:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, frac * H)
        grid:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, frac * H)
        grid:Show()
        g.ylabels[i]:ClearAllPoints()
        g.ylabels[i]:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, frac * H)
        g.ylabels[i]:SetText(MoneyShort(floor(vmin + (vmax - vmin) * frac)))
    end

    local t1 = time()
    local t0 = t1 - HISTORY_DAYS * 86400
    local function X(t) return max(0, min(W, (t - t0) / (t1 - t0) * W)) end
    local function Y(v) return (v - vmin) / (vmax - vmin) * H end

    local function series(field, color)
        local px, py
        for _, p in ipairs(pts) do
            local x, y = X(p.t), Y(p[field])
            local d = NextDot(g)
            d:SetColorTexture(color[1], color[2], color[3], 1)
            d:ClearAllPoints()
            d:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
            if px then
                local l = NextLine(g)
                l:SetColorTexture(color[1], color[2], color[3], 0.9)
                l:SetStartPoint("BOTTOMLEFT", plot, px, py)
                l:SetEndPoint("BOTTOMLEFT", plot, x, y)
            end
            px, py = x, y
        end
    end
    series("high", COLOR_HIGH)
    series("low", COLOR_LOW)

    for _, p in ipairs(pts) do tinsert(g.pts, { x = X(p.t), p = p }) end
end

-- ---------- right panel ----------
function FiveLoaves:ShowItem(itemID)
    if not self.tabInstalled then Warn("Open the Auction House first.") return end
    if not self.mainFrame:IsShown() then self.selectTab() end
    self.selected = itemID
    self:RenderDetail()
    self:RefreshList()
end

function FiveLoaves:SetRightView(view)
    self.rightView = view
    self:RenderDetail()
end

function FiveLoaves:RenderDetail()
    local f = self.mainFrame
    if not f then return end
    local id = self.selected
    local item = id and self.db.items[id]
    local showGraph = (self.rightView or "graph") == "graph"
    f.graph:SetShown(showGraph)
    f.history:SetShown(not showGraph)

    if not item then
        f.title:SetText(id and ("No data for item " .. id) or "")
        f.stats:SetText(id and "Scan the AH first." or "Click an item in the table.\nAlt+click a bag item to jump to it.")
        f.stats:Show()
        f.grid:Hide()
        f.history:SetText("")
        self:DrawGraph()
        return
    end

    f.title:SetText(format("|T%s:16|t %s", ItemIcon(id), self:EnsureItem(id).name))
    f.stats:Hide()
    f.grid:Show()
    local function win(days)
        local cutoff = time() - days * 86400
        local sl, sh, n = 0, 0, 0
        for _, e in pairs(item.history) do
            if e.time >= cutoff then
                sl = sl + e.low
                sh = sh + (e.high or e.low)
                n = n + 1
            end
        end
        if n == 0 then return nil, nil end
        return floor(sl / n), floor(sh / n)
    end
    local l7, h7 = win(7)
    local l14, h14 = win(14)
    local c = f.grid.cells
    c[1][2]:SetText(Money(item.currentLow)); c[1][3]:SetText(Money(item.currentHigh))
    c[2][2]:SetText(Money(l7));              c[2][3]:SetText(Money(h7))
    c[3][2]:SetText(Money(l14));             c[3][3]:SetText(Money(h14))
    if showGraph then
        self:DrawGraph()
    else
        local days = {}
        for d in pairs(item.history) do tinsert(days, d) end
        table.sort(days, function(a, b) return a > b end)
        local lines = {}
        for _, d in ipairs(days) do
            local e = item.history[d]
            tinsert(lines, format("%s   %s - %s   qty %d", d:sub(6), MoneyShort(e.low), MoneyShort(e.high or e.low), e.qty or 0))
        end
        f.history:SetText(table.concat(lines, "\n"))
    end
end

-- ---------- tab / frame construction ----------
local ownTabs, ownHolder = {}, nil

-- fallback when LibAHTab (shipped with Auctionator) is not available
local function CreateOwnTab(panel, text, header)
    local tabs = AuctionHouseFrame.Tabs
    local offsetX = (WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE) and -14 or 3
    if not ownHolder then
        -- own holder so the template does not append tabs to AuctionHouseFrame.Tabs
        ownHolder = CreateFrame("Frame", nil, AuctionHouseFrame)
        ownHolder:SetSize(10, 10)
        ownHolder:SetPoint("TOPLEFT", tabs[#tabs], "TOPRIGHT")
        hooksecurefunc(AuctionHouseFrame, "SetDisplayMode", function(_, mode)
            if mode ~= nil and #mode > 0 then
                for _, o in ipairs(ownTabs) do
                    o.panel:Hide()
                    PanelTemplates_DeselectTab(o.tab)
                end
            end
        end)
    end
    local tab = CreateFrame("Button", "FiveLoavesAHTab" .. (#ownTabs + 1), ownHolder, "AuctionHouseFrameDisplayModeTabTemplate")
    tab:SetText(text)
    PanelTemplates_TabResize(tab, 20, nil, 70)
    if #ownTabs == 0 then
        tab:SetPoint("TOPLEFT", ownHolder, "TOPLEFT", offsetX, 0)
    else
        tab:SetPoint("TOPLEFT", ownTabs[#ownTabs].tab, "TOPRIGHT", offsetX, 0)
    end
    PanelTemplates_DeselectTab(tab)
    panel:Hide()
    tinsert(ownTabs, { tab = tab, panel = panel })

    tab:SetScript("OnClick", function()
        AuctionHouseFrame:SetDisplayMode({})
        AuctionHouseFrame.displayMode = nil
        for _, t in ipairs(tabs) do PanelTemplates_DeselectTab(t) end
        for _, o in ipairs(ownTabs) do
            o.panel:Hide()
            PanelTemplates_DeselectTab(o.tab)
        end
        PanelTemplates_SelectTab(tab)
        AuctionHouseFrame:SetTitle(header)
        panel:Show()
    end)
    return tab
end

function FiveLoaves:InstallTab()
    if self.tabInstalled or not AuctionHouseFrame or not AuctionHouseFrame.Tabs then return end
    self.tabInstalled = true
    local ok, err = pcall(function() self:InstallTabInner() end)
    if not ok then
        self.tabInstalled = false
        Error("Tab install failed: " .. tostring(err))
    end
end

-- returns a function that selects the new tab
local function AddAHTab(id, panel, text, header)
    local LibAHTab = LibStub and LibStub("LibAHTab-1-0", true)
    if LibAHTab then
        LibAHTab:CreateTab(id, panel, text, header)
        return function() LibAHTab:SetSelected(id) end
    end
    local tab = CreateOwnTab(panel, text, header)
    return function() tab:Click() end
end

function FiveLoaves:InstallTabInner()
    self:CreateMainFrame()
    self.selectTab = AddAHTab(TAB_ID, self.mainFrame, "Loaves", "Five Loaves and Two Fish")
    if self.CreateSellFrame then
        self:CreateSellFrame()
        self.selectSell = AddAHTab(TAB_ID .. "Sell", self.sellFrame, "Loaves Sell", "Five Loaves - Create Auction")
    end
end
local function BuildTable(f)
    f.headers = {}
    local x = COL_START
    for i, c in ipairs(COLS) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(c.w, 18)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 8 + x, -58)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.label:SetAllPoints()
        b.label:SetJustifyH(c.align)
        b:SetScript("OnClick", function() FiveLoaves:SortBy(c.key) end)
        f.headers[i] = b
        c.x = x
        x = x + c.w + COL_GAP
    end

    f.checkAll = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.checkAll:SetSize(22, 22)
    f.checkAll:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -56)
    f.checkAll:Hide()
    f.checkAll:SetScript("OnClick", function(self)
        local on = self:GetChecked()
        for _, r in ipairs(FiveLoaves.lastRows or {}) do
            FiveLoaves.bagSel[r.id] = on and true or nil
        end
        FiveLoaves:RefreshList()
    end)

    f.rows = {}
    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(LEFT_W, ROW_H)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -78 - (i - 1) * ROW_H)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetAllPoints()
        b.sel:SetColorTexture(1, 0.82, 0, 0.18)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(18, 18)
        b.icon:SetPoint("LEFT", 22, 0)
        b.check = CreateFrame("CheckButton", nil, b, "UICheckButtonTemplate")
        b.check:SetSize(22, 22)
        b.check:SetPoint("LEFT", 0, 0)
        b.check:Hide()
        b.check:SetScript("OnClick", function(self)
            local id = self:GetParent().itemID
            FiveLoaves.bagSel[id] = self:GetChecked() and true or nil
            FiveLoaves:UpdateBagControls()
        end)
        b.cells = {}
        for j, c in ipairs(COLS) do
            local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", b, "LEFT", c.x, 0)
            fs:SetWidth(c.w)
            fs:SetHeight(ROW_H)
            fs:SetJustifyH(c.align)
            fs:SetWordWrap(false)
            b.cells[j] = fs
        end
        b:SetScript("OnClick", function(self) FiveLoaves:ShowItem(self.itemID) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.itemID)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.rows[i] = b
    end
end

local function BuildGraph(r)
    local g = CreateFrame("Frame", nil, r)
    g:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -100)
    g:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
    g.lines, g.dots, g.grid, g.ylabels, g.pts = {}, {}, {}, {}, {}
    g.nLines, g.nDots = 0, 0

    local plot = CreateFrame("Frame", nil, g)
    plot:SetPoint("TOPLEFT", g, "TOPLEFT", 58, -22)
    plot:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -10, 26)
    plot:EnableMouse(true)
    g.plot = plot
    local bg = plot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.35)

    for i = 1, 4 do
        local t = plot:CreateTexture(nil, "BORDER")
        t:SetHeight(1)
        t:SetColorTexture(1, 1, 1, 0.12)
        g.grid[i] = t
        g.ylabels[i] = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        g.ylabels[i]:SetJustifyH("RIGHT")
    end

    local legend = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legend:SetPoint("TOPLEFT", 58, -4)
    legend:SetText("|cff40ff40- Daily low|r    |cffff6666- Daily high|r    (30 days)")

    local xl = {
        { "-30d", "BOTTOMLEFT", "LEFT" },
        { "-15d", "BOTTOM", "CENTER" },
        { "today", "BOTTOMRIGHT", "RIGHT" },
    }
    for _, d in ipairs(xl) do
        local fs = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOP", plot, d[2], 0, -4)
        fs:SetText(d[1])
        if d[2] == "BOTTOMLEFT" then fs:ClearAllPoints() fs:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -4) end
        if d[2] == "BOTTOMRIGHT" then fs:ClearAllPoints() fs:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -4) end
    end

    g.empty = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    g.empty:SetPoint("CENTER", plot, "CENTER")

    plot:SetScript("OnSizeChanged", function() FiveLoaves:DrawGraph() end)
    plot:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        g.hover = nil
        GameTooltip:Hide()
    end)
    plot:SetScript("OnEnter", function(self)
        self:SetScript("OnUpdate", function(self)
            if #g.pts == 0 then return end
            local mx = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
            local best, bd
            for _, pt in ipairs(g.pts) do
                local d = abs(pt.x - mx)
                if not bd or d < bd then best, bd = pt, d end
            end
            if best and best.p ~= g.hover then
                g.hover = best.p
                local p = best.p
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:AddLine(p.day, 1, 0.82, 0)
                GameTooltip:AddDoubleLine("Low", Money(p.low), 1, 1, 1, 0.25, 1, 0.25)
                GameTooltip:AddDoubleLine("High", Money(p.high), 1, 1, 1, 1, 0.4, 0.4)
                GameTooltip:AddDoubleLine("Quantity", p.qty, 1, 1, 1, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
    end)
    return g
end

function FiveLoaves:CreateMainFrame()
    if self.mainFrame then return end
    local f = CreateFrame("Frame", "FiveLoavesMainFrame", AuctionHouseFrame)
    f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -28)
    f:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 30)
    f:SetScript("OnShow", function() FiveLoaves:RefreshList() FiveLoaves:RenderDetail() end)
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.95)

    local function button(parent, text, w, point, x, y, fn)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(w, 24)
        b:SetPoint(point, x, y)
        b:SetText(text)
        b:SetScript("OnClick", fn)
        return b
    end
    -- leave room on the left for the AH portrait
    button(f, "Scan AH", 80, "TOPLEFT", 70, -8, function() FiveLoaves:StartScan() end)
    button(f, "Bag", 50, "TOPLEFT", 156, -8, function() FiveLoaves:SetMode(FiveLoaves.mode == "bag" and "search" or "bag") end)
    button(f, "Buy now", 70, "TOPLEFT", 212, -8, function() FiveLoaves:SetMode("buy") end)
    button(f, "Sell now", 70, "TOPLEFT", 288, -8, function() FiveLoaves:SetMode("sell") end)
    local Export = button(f, "Export", 70, "TOPLEFT", 364, -8, function() FiveLoaves:ShowExport() end)

    local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPRIGHT", -14, -10)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
        FiveLoaves.searchText = self:GetText()
        FiveLoaves.offset = 0
        FiveLoaves:RefreshList()
    end)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    f.search = search
    local sl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sl:SetPoint("RIGHT", search, "LEFT", -8, 0)
    sl:SetText("Search:")

    -- category filter (applies to search, Bag, Buy now and Sell now)
    local cat = CreateFrame("Frame", "FiveLoavesCategoryDropdown", f, "UIDropDownMenuTemplate")
    cat:SetPoint("LEFT", Export, "RIGHT", -14, -2)
    UIDropDownMenu_SetWidth(cat, 100)
    local function label()
        if not FiveLoaves.category then return "All categories" end
        local text = CategoryName(FiveLoaves.category)
        if FiveLoaves.subCategory then text = SubCategoryName(FiveLoaves.category, FiveLoaves.subCategory) end
        return text
    end
    local function pick(_, classID, subID)
        FiveLoaves.category, FiveLoaves.subCategory = classID, subID
        UIDropDownMenu_SetText(cat, label())
        CloseDropDownMenus()
        FiveLoaves.offset = 0
        FiveLoaves:RefreshList()
    end
    -- Categories with subclasses open a side menu; clicking the category itself shows all of it
    UIDropDownMenu_Initialize(cat, function(_, level)
        local info
        local subs = FiveLoaves:SubclassesByClass()
        if level == 2 then
            local classID = UIDROPDOWNMENU_MENU_VALUE
            info = UIDropDownMenu_CreateInfo()
            info.text, info.arg1, info.arg2, info.func = "All " .. CategoryName(classID), classID, nil, pick
            info.checked = FiveLoaves.category == classID and FiveLoaves.subCategory == nil
            UIDropDownMenu_AddButton(info, 2)
            for _, subID in ipairs(subs[classID] or {}) do
                info = UIDropDownMenu_CreateInfo()
                info.text, info.arg1, info.arg2, info.func = SubCategoryName(classID, subID), classID, subID, pick
                info.checked = FiveLoaves.category == classID and FiveLoaves.subCategory == subID
                UIDropDownMenu_AddButton(info, 2)
            end
            return
        end
        info = UIDropDownMenu_CreateInfo()
        info.text, info.func, info.checked = "All categories", pick, FiveLoaves.category == nil
        UIDropDownMenu_AddButton(info)
        for _, classID in ipairs(CATEGORY_CLASSES) do
            info = UIDropDownMenu_CreateInfo()
            info.text, info.arg1, info.func = CategoryName(classID), classID, pick
            info.checked = FiveLoaves.category == classID and FiveLoaves.subCategory == nil
            if subs[classID] and #subs[classID] > 1 then
                info.hasArrow, info.value = true, classID
                info.checked = FiveLoaves.category == classID
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(cat, "All categories")
    f.category = cat

    f.statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.statusText:SetPoint("TOPLEFT", 12, -38)
    f.statusText:SetText("Status: Ready")
    f.listInfo = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.listInfo:SetPoint("TOPRIGHT", -14, -38)

    -- cutoff slider, only relevant for Buy now / Sell now
    local sl = CreateFrame("Slider", "FiveLoavesCutoffSlider", f, "OptionsSliderTemplate")
    sl:SetSize(180, 14)
    sl:SetPoint("TOPLEFT", 270, -40)
    sl:SetMinMaxValues(5, 80)
    sl:SetValueStep(5)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    sl:SetValue(floor(self.db.threshold * 100 + 0.5))
    _G[sl:GetName() .. "Low"]:SetText("5%")
    _G[sl:GetName() .. "High"]:SetText("80%")
    sl.label = _G[sl:GetName() .. "Text"]
    sl.label:SetText(format("Cutoff: %d%%", floor(self.db.threshold * 100 + 0.5)))
    sl:SetScript("OnValueChanged", function(s, v)
        v = floor(v / 5 + 0.5) * 5
        s.label:SetText(format("Cutoff: %d%%", v))
        if FiveLoaves.db.threshold ~= v / 100 then
            FiveLoaves.db.threshold = v / 100
            FiveLoaves.offset = 0
            FiveLoaves:RefreshList()
        end
    end)
    sl:Hide()
    f.slider = sl

    BuildTable(f)

    local r = CreateFrame("Frame", nil, f)
    r:SetPoint("TOPLEFT", f, "TOPLEFT", 8 + LEFT_W + 10, -58)
    r:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 44)

    f.auctionBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.auctionBtn:SetSize(190, 26)
    f.auctionBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    f.auctionBtn:SetText("Auction all selected")
    f.auctionBtn:SetScript("OnClick", function() FiveLoaves:AuctionSelected() end)
    f.auctionBtn:Hide()
    f.clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.clearBtn:SetSize(130, 26)
    f.clearBtn:SetPoint("RIGHT", f.auctionBtn, "LEFT", -6, 0)
    f.clearBtn:SetText("Clear selected")
    f.clearBtn:SetScript("OnClick", function()
        wipe(FiveLoaves.bagSel)
        FiveLoaves:RefreshList()
    end)
    f.clearBtn:Hide()
    f.bagStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.bagStatus:SetPoint("RIGHT", f.clearBtn, "LEFT", -10, 0)
    f.bagStatus:SetWidth(170)
    f.bagStatus:SetJustifyH("RIGHT")
    f.bagStatus:Hide()
    f.right = r

    f.title = r:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 0, 0)
    f.title:SetJustifyH("LEFT")
    f.stats = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.stats:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
    f.stats:SetJustifyH("LEFT")
    f.stats:SetJustifyV("TOP")

    -- rows: Now / 7 Day / 14 Day ; columns: Low / High
    local grid = CreateFrame("Frame", nil, r)
    grid:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
    grid:SetSize(300, 58)
    f.grid = grid
    grid.cells = {}
    local colX = { 0, 70, 180 }
    local colW = { 66, 106, 106 }
    local heads = { "", "Low", "High" }
    for j = 1, 3 do
        local h = grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", colX[j], 0)
        h:SetWidth(colW[j])
        h:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
        h:SetText(heads[j])
        if j == 2 then h:SetTextColor(COLOR_LOW[1], COLOR_LOW[2], COLOR_LOW[3]) end
        if j == 3 then h:SetTextColor(COLOR_HIGH[1], COLOR_HIGH[2], COLOR_HIGH[3]) end
    end
    local rowNames = { "Now", "7 Day avg", "14 Day avg" }
    for i = 1, 3 do
        grid.cells[i] = {}
        for j = 1, 3 do
            local fs = grid:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", colX[j], -14 * i - 2)
            fs:SetWidth(colW[j])
            fs:SetJustifyH(j == 1 and "LEFT" or "RIGHT")
            grid.cells[i][j] = fs
            if j == 1 then
                fs:SetText(rowNames[i])
                fs:SetTextColor(1, 0.82, 0)
            end
        end
    end
    local line = grid:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 0, -14)
    line:SetPoint("TOPRIGHT", 0, -14)

    button(r, "Graph", 60, "TOPRIGHT", -66, 2, function() FiveLoaves:SetRightView("graph") end)
    button(r, "History", 60, "TOPRIGHT", 0, 2, function() FiveLoaves:SetRightView("history") end)

    f.graph = BuildGraph(r)
    f.history = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.history:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -104)
    f.history:SetJustifyH("LEFT")
    f.history:SetJustifyV("TOP")
    f.history:Hide()

    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta)
        FiveLoaves.offset = max(0, (FiveLoaves.offset or 0) - delta * 3)
        FiveLoaves:RefreshList()
    end)

    self.mainFrame = f
end

function FiveLoaves:ToggleMainFrame()
    self:InstallTab()
    if not (self.tabInstalled and self.selectTab) then
        Warn("Open the Auction House first - Five Loaves lives in a tab there.")
        return
    end
    self.selectTab()
end

function FiveLoaves:UpdateStatus(text)
    local f = self.mainFrame
    if not (f and f.statusText) then return end
    f.statusText:SetText("Status: " .. (text or (self.isScanning and "Scanning..." or "Ready")))
end

FiveLoaves.util = {
    Money = Money, MoneyShort = MoneyShort, ItemIcon = ItemIcon,
    Action = Action, Info = Info, Warn = Warn, Error = Error, Debug = Debug,
    COLOR_LOW = COLOR_LOW, COLOR_HIGH = COLOR_HIGH,
}

-- ============================================================
-- Events
-- ============================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "Blizzard_AuctionHouseUI" then
            FiveLoaves:InstallTab()
        elseif ... == ADDON_NAME then
            FiveLoavesDB = FiveLoavesDB or CopyTable(defaults)
            for k, v in pairs(defaults) do
                if FiveLoavesDB[k] == nil then
                    FiveLoavesDB[k] = type(v) == "table" and CopyTable(v) or v
                end
            end
            FiveLoaves.db = FiveLoavesDB
            Action("Loaded. Type |cffffff00/5l2f help|r")
        end
    elseif event == "PLAYER_LOGIN" then
        HookTooltips()
        FiveLoaves:InstallTab()
    elseif event == "AUCTION_HOUSE_SHOW" then
        FiveLoaves:InstallTab()
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        FiveLoaves:OnReplicateUpdate()
    elseif event == "BAG_UPDATE_DELAYED" then
        if FiveLoaves.mode == "bag" then FiveLoaves:RefreshList() end
    end
end)

-- ============================================================
-- Slash commands
-- ============================================================
SLASH_FIVELOAVES1 = "/5l2f"
SLASH_FIVELOAVES2 = "/loaves"
SlashCmdList["FIVELOAVES"] = function(msg)
    local cmd, arg = strmatch(strtrim(msg or ""):lower(), "^(%S*)%s*(.-)$")

    if cmd == "" or cmd == "show" or cmd == "open" then
        FiveLoaves:ToggleMainFrame()
    elseif cmd == "scan" then
        FiveLoaves:StartScan()
    elseif cmd == "export" then
        FiveLoaves:ShowExport()
    elseif cmd == "buy" or cmd == "sell" then
        local deals = FiveLoaves:FindDeals(cmd)
        if #deals == 0 then
            Info("No " .. cmd .. " deals (need " .. MIN_DAYS_FOR_DEALS .. "+ days of history).")
        end
        for _, d in ipairs(deals) do
            Info(format("%s: now %s vs avg %s (%+d%%)", d.name, Money(d.cur), Money(d.avg), floor(d.diff * 100)))
        end
    elseif cmd == "threshold" then
        local n = tonumber(arg)
        if n and n > 0 and n < 100 then
            FiveLoaves.db.threshold = n / 100
            if FiveLoaves.mainFrame and FiveLoaves.mainFrame.slider then
                FiveLoaves.mainFrame.slider:SetValue(floor(n / 5 + 0.5) * 5)
            end
            Action(format("Deal threshold set to %d%%", n))
        else
            Info(format("Deal threshold is %d%%. Use /5l2f threshold <1-99>", FiveLoaves.db.threshold * 100))
        end
    elseif cmd == "tooltip" then
        FiveLoaves.db.noTooltip = (arg == "off") or nil
        Info("Item tooltip lines: " .. (FiveLoaves.db.noTooltip and "OFF" or "ON") .. ". Use /5l2f tooltip on|off")
    elseif cmd == "scope" then
        if arg == "herbs" or arg == "all" then
            FiveLoaves.db.herbsOresOnly = (arg == "herbs") or nil
        end
        Info("Scan scope: " .. (FiveLoaves.db.herbsOresOnly and "ores + herbs only" or "ALL items") .. ". Use /5l2f scope all|herbs")
    elseif cmd == "status" then
        local n = 0
        for _ in pairs(FiveLoaves.db.items) do n = n + 1 end
        Info(format("Tracking %d items. Last scan: %s", n,
            FiveLoaves.db.lastScan > 0 and date("%Y-%m-%d %H:%M", FiveLoaves.db.lastScan) or "never"))
    elseif cmd == "debug" then
        FiveLoaves.db.debug = not FiveLoaves.db.debug
        Action("Debug " .. (FiveLoaves.db.debug and "ON" or "OFF"))
    else
        Action("Commands:")
        print("  /5l2f             - Open window")
        print("  /5l2f scan        - Full AH scan (AH open)")
        print("  /5l2f scope all|herbs - Scan every item, or only ores + herbs")
        print("  /5l2f buy | sell  - List deals vs 30d average")
        print("  /5l2f threshold N - Deal threshold in percent")
        print("  /5l2f export      - CSV for Excel")
        print("  /5l2f status | debug")
    end
end

FiveLoaves.GetItemData = function(self, id) return self.db.items[id] end
