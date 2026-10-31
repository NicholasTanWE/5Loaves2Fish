--[[
    Five Loaves and Two Fish - "Watch" tab
    A personal watchlist of items with price statistics from the scan history.
]]

local ADDON_NAME, ns = ...
local FiveLoaves = ns.FiveLoaves
local U = FiveLoaves.util

local Watch = {}
FiveLoaves.Watch = Watch

local ROWS, ROW_H = 16, 22
local DAY = 86400

local COLS = {
    { key = "name",    label = "Name",        w = 110, align = "LEFT" },
    { key = "current", label = "Current",     w = 84, align = "RIGHT" },
    { key = "low",     label = "All-time low", w = 84, align = "RIGHT" },
    { key = "high",    label = "All-time high", w = 84, align = "RIGHT" },
    { key = "avg7",    label = "7d avg",      w = 84, align = "RIGHT" },
    { key = "avg14",   label = "14d avg",     w = 84, align = "RIGHT" },
    { key = "delta",   label = "vs 7d",       w = 60,  align = "RIGHT" },
    { key = "rec",     label = "Action",      w = 56,  align = "CENTER" },
}
local COL_GAP = 6

Watch.sortKey, Watch.sortDesc = "delta", false -- biggest discount first
Watch.offset = 0
Watch.removed = {}

local function ItemIDOf(text)
    if not text or text == "" then return nil end
    local id = tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
    if id then return id end
    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    for itemID, item in pairs(FiveLoaves.db.items) do
        if item.name and item.name:lower() == lower then return itemID end
    end
    local instant = GetItemInfoInstant and GetItemInfoInstant(text)
    return tonumber(instant)
end

Watch.IDOf = ItemIDOf

local function NameOf(id)
    local item = FiveLoaves.db.items[id]
    if item and item.name and not item.name:find("^Item %d+$") then return item.name end
    return (GetItemInfo(id)) or (item and item.name) or ("Item " .. id)
end

-- Average of daily lows over the last n days (today included)
local function AvgLow(item, n)
    local now, sum, count = time(), 0, 0
    for i = 0, n - 1 do
        local e = item.history[date("%Y-%m-%d", now - i * DAY)]
        if e and e.low then sum, count = sum + e.low, count + 1 end
    end
    if count == 0 then return nil end
    return floor(sum / count)
end

local function BuildRow(id)
    local item = FiveLoaves.db.items[id]
    local row = { id = id, name = NameOf(id) }
    if not item then return row end
    row.current = item.currentLow
    for _, e in pairs(item.history) do
        if e.low and (not row.low or e.low < row.low) then row.low = e.low end
        local hi = e.high or e.low
        if hi and (not row.high or hi > row.high) then row.high = hi end
    end
    row.avg7, row.avg14 = AvgLow(item, 7), AvgLow(item, 14)
    if row.current and row.avg7 and row.avg7 > 0 then
        row.delta = (row.current - row.avg7) / row.avg7
        -- Buy / Sell when far below / above the 7d average
        local db = FiveLoaves.db
        row.rec = row.delta <= -db.watchBuyThreshold and 1 or row.delta >= db.watchSellThreshold and 3 or 2
    end
    return row
end

function Watch:GetRows()
    local rows = {}
    for id in pairs(FiveLoaves.db.watch) do tinsert(rows, BuildRow(id)) end
    for id in pairs(self.removed) do
        if not FiveLoaves.db.watch[id] then tinsert(rows, BuildRow(id)) end
    end
    local key, desc = self.sortKey, self.sortDesc
    table.sort(rows, function(a, b)
        local x, y = a[key], b[key]
        if x == y then return a.name < b.name end
        if x == nil then return false end -- items without data always last
        if y == nil then return true end
        if desc then return x > y end
        return x < y
    end)
    return rows
end

function Watch:SortBy(key)
    if self.sortKey == key then
        self.sortDesc = not self.sortDesc
    else
        self.sortKey = key
        self.sortDesc = not (key == "name" or key == "delta")
    end
    self.offset = 0
    self:Refresh()
end

-- Blizzard switches to its own Sell tab on a bag right-click before our hook runs,
-- so the Watch tab counts as active if it was hidden only a moment ago.
function Watch:IsActive()
    local f = self.frame
    if not f then return false end
    return f:IsShown() or (GetTime() - (self.hiddenAt or -10)) < 0.3
end

function Watch:HandleBagClick(loc)
    if not (loc and loc.IsValid and loc:IsValid()) then return end
    self:AddItemID(C_Item.GetItemID(loc))
    -- drop whatever Blizzard's Sell tab picked up from the same click, then come back
    pcall(function() AuctionHouseFrame.ItemSellFrame:SetItem(nil, nil, false) end)
    pcall(function() AuctionHouseFrame.CommoditiesSellFrame:SetItem(nil, nil, false) end)
    if not self.frame:IsShown() and FiveLoaves.selectWatch then FiveLoaves.selectWatch() end
end

function Watch:Changed()
    self:Refresh()
    FiveLoaves:RefreshList()
end

function Watch:AddItemID(id)
    if not id then return false end
    FiveLoaves.db.watch[id] = true
    self.removed[id] = nil
    U.Action("Watching " .. NameOf(id))
    self:Changed()
    return true
end

function Watch:Add(text)
    local id = ItemIDOf(text)
    if not id then
        U.Warn("Watch: couldn't identify that item. Use an item link, an item ID, or the exact name of a scanned item.")
        return false
    end
    return self:AddItemID(id)
end

-- Removed items stay listed (dimmed star) until the tab is reopened, so a misclick can be undone
function Watch:Remove(id)
    if id and FiveLoaves.db.watch[id] then
        FiveLoaves.db.watch[id] = nil
        self.removed[id] = true
        U.Info("Stopped watching " .. NameOf(id))
        self:Changed()
    end
end

function Watch:Toggle(id)
    if not id then return end
    if FiveLoaves.db.watch[id] then
        self:Remove(id)
    else
        self:AddItemID(id)
    end
end

-- Switch to Blizzard's Buy tab and search for the item by name
function FiveLoaves:OpenBuy(itemID)
    if not (itemID and AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        U.Warn("Open the Auction House first.")
        return
    end
    local ok, err = pcall(function()
        local mode = AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy
        if mode then AuctionHouseFrame:SetDisplayMode(mode) end
        local bar = AuctionHouseFrame.SearchBar
        bar.SearchBox:SetText(NameOf(itemID))
        bar:StartSearch()
    end)
    if not ok then U.Error("Couldn't open the buy tab: " .. tostring(err)) end
end

local REC_TEXT = { "|cff40ff40Buy|r", "|cffbbbbbbHold|r", "|cffff6060Sell|r" }

local function DeltaText(d)
    local colour = d < 0 and "40ff40" or d > 0 and "ff6060" or "ffffff"
    return format("|cff%s%+.0f%%|r", colour, d * 100)
end

function Watch:Refresh()
    local f = self.frame
    if not (f and f:IsShown()) then return end
    local rows = self:GetRows()
    local maxOffset = max(#rows - ROWS, 0)
    self.offset = min(self.offset, maxOffset)

    for i, b in ipairs(f.rows) do
        local r = rows[self.offset + i]
        if r then
            b.itemID = r.id
            b.icon:SetTexture(U.ItemIcon and U.ItemIcon(r.id) or select(5, GetItemInfoInstant(r.id)))
            b.cells[1]:SetText(r.name)
            b.cells[2]:SetText(U.Money(r.current))
            b.cells[3]:SetText(U.Money(r.low))
            b.cells[4]:SetText(U.Money(r.high))
            b.cells[5]:SetText(U.Money(r.avg7))
            b.cells[6]:SetText(U.Money(r.avg14))
            b.cells[7]:SetText(DeltaText(r.delta))
            b.cells[8]:SetText(r.rec and REC_TEXT[r.rec] or "-")
            local watched = FiveLoaves.db.watch[r.id] and true or false
            b.star.watched = watched
            U.SetStar(b.star, watched)
            b:Show()
        else
            b.itemID = nil
            b:Hide()
        end
    end

    for i, h in ipairs(f.headers) do
        local c = COLS[i]
        local arrow = (c.key == self.sortKey) and (self.sortDesc and " v" or " ^") or ""
        h.label:SetText(c.label .. arrow)
    end
    f.empty:SetShown(#rows == 0)
end

-- Dropping a bag item on the Watch tab adds it
local function ReceiveDrag()
    local kind, id = GetCursorInfo()
    if kind == "item" then
        Watch:AddItemID(id)
        ClearCursor()
    end
end

function FiveLoaves:CreateWatchFrame()
    if self.watchFrame then return end
    local f = CreateFrame("Frame", "FiveLoavesWatchFrame", AuctionHouseFrame)
    f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -28)
    f:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 30)
    f:Hide()
    Watch.frame = f
    self.watchFrame = f

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.95)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 90, -12)
    title:SetText("Watchlist")

    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(260, 22)
    box:SetPoint("TOPLEFT", 230, -12)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    local function submit()
        if Watch:Add(box:GetText()) then box:SetText("") end
        box:ClearFocus()
    end
    box:SetScript("OnEnterPressed", submit)

    local add = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    add:SetSize(70, 22)
    add:SetPoint("LEFT", box, "RIGHT", 8, 0)
    add:SetText("Add")
    add:SetScript("OnClick", submit)

    -- Buy when at least this far below the 7d average; Sell when at least this far above
    local function MakeSlider(name, key, x, fmt)
        local sl = CreateFrame("Slider", name, f, "OptionsSliderTemplate")
        sl:SetSize(220, 14)
        sl:SetPoint("TOPLEFT", x, -72)
        sl:SetMinMaxValues(5, 80)
        sl:SetValueStep(5)
        if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
        sl:SetValue(floor(FiveLoaves.db[key] * 100 + 0.5))
        _G[name .. "Low"]:SetText("5%")
        _G[name .. "High"]:SetText("80%")
        sl.label = _G[name .. "Text"]
        sl.label:SetText(format(fmt, floor(FiveLoaves.db[key] * 100 + 0.5)))
        sl:SetScript("OnValueChanged", function(s, v)
            v = floor(v / 5 + 0.5) * 5
            s.label:SetText(format(fmt, v))
            if FiveLoaves.db[key] ~= v / 100 then
                FiveLoaves.db[key] = v / 100
                Watch:Refresh()
            end
        end)
        return sl
    end
    f.buySlider = MakeSlider("FiveLoavesWatchBuySlider", "watchBuyThreshold", 30, "|cff40ff40Buy|r when %d%% or more below 7d avg")
    f.sellSlider = MakeSlider("FiveLoavesWatchSellSlider", "watchSellThreshold", 330, "|cffff6060Sell|r when %d%% or more above 7d avg")
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 14, -38)
    hint:SetText("Right-click or drag an item from your bags, shift-click a link into the box, or type an ID / exact name. Click a row to open the Buy tab.")

    f.headers = {}
    local x = 28
    for i, c in ipairs(COLS) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(c.w, 18)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 8 + x, -100)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.label:SetAllPoints()
        b.label:SetJustifyH(c.align)
        b:SetScript("OnClick", function() Watch:SortBy(c.key) end)
        f.headers[i] = b
        c.x = x
        x = x + c.w + COL_GAP
    end

    f.rows = {}
    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(x + 24, ROW_H)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -120 - (i - 1) * ROW_H)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(18, 18)
        b.icon:SetPoint("LEFT", 4, 0)
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
        b.star = U.CreateStar(b, function(self) Watch:Toggle(self:GetParent().itemID) end)
        b.star:SetPoint("RIGHT", b, "RIGHT", -4, 0)
        b:SetScript("OnClick", function(self)
            if self.itemID then FiveLoaves:OpenBuy(self.itemID) end
        end)
        b:SetScript("OnReceiveDrag", ReceiveDrag)
        b:SetScript("OnEnter", function(self)
            if not self.itemID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.itemID)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.rows[i] = b
    end

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.empty:SetPoint("TOP", f, "TOP", 0, -240)
    f.empty:SetText("No watched items yet.")

    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta)
        Watch.offset = max(Watch.offset - delta * 3, 0)
        Watch:Refresh()
    end)
    f:SetScript("OnHide", function() Watch.hiddenAt = GetTime() end)
    f:SetScript("OnShow", function()
        wipe(Watch.removed)
        Watch:Refresh()
    end)
    f:SetScript("OnReceiveDrag", ReceiveDrag)

    -- Shift-click inserts the link into the focused box
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if box:HasFocus() and link then
            box:Insert(link)
        end
    end)
end
