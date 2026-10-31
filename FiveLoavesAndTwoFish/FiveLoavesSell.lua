--[[
    Five Loaves and Two Fish - "Loaves Sell" tab
    Right-click an item in your bags while the Auction House is open to list it.
    The unit price is set to the current AH low (live lookup, falling back to the last scan).
]]

local ADDON_NAME, ns = ...
local FiveLoaves = ns.FiveLoaves
local U = FiveLoaves.util

local Sell = { duration = 2 }
FiveLoaves.Sell = Sell

local AH_CUT = 0.05 -- auction house commission on a sale
local DURATIONS = { { id = 1, label = "12 hours" }, { id = 2, label = "24 hours" }, { id = 3, label = "48 hours" } }

local function Digits(box)
    return tonumber(box:GetText()) or 0
end

local function AvgLow(item, days)
    local cutoff = time() - days * 86400
    local sum, n = 0, 0
    for _, e in pairs(item.history) do
        if e.time >= cutoff and e.low then sum, n = sum + e.low, n + 1 end
    end
    if n == 0 then return nil end
    return floor(sum / n)
end

-- Depth check for commodities: the lowest tier is ignored while it is a thin sliver
-- (few units) sitting well below the next tier. Returns price, rawLow, skippedUnits.
local THIN_GAP = 1.25     -- next tier must be at least this much higher
local THIN_MIN_UNITS = 3  -- a bottom slice smaller than this (or MIN_SHARE of the market) is thin
local THIN_SHARE = 0.05

function Sell:DepthAdjusted(itemID)
    local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
    if n == 0 then return nil end
    local list, total = {}, 0
    for i = 1, min(n, 200) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and (r.quantity or 0) > 0 then
            list[#list + 1] = { price = r.unitPrice, qty = r.quantity }
            total = total + r.quantity
        end
    end
    if #list == 0 then return nil end
    if FiveLoaves.db.matchLowest then return list[1].price, list[1].price, 0 end
    local limit = max(THIN_MIN_UNITS, ceil(total * THIN_SHARE))
    local i, skipped = 1, 0
    while i < #list do
        local cur, nxt = list[i], list[i + 1]
        if nxt.price >= cur.price * THIN_GAP and skipped + cur.qty < limit then
            skipped = skipped + cur.qty
            i = i + 1
        else
            break
        end
    end
    return list[i].price, list[1].price, skipped
end

-- ---------- state helpers ----------
function Sell:GetUnitPrice()
    local f = self.frame
    return Digits(f.gold) * 10000 + Digits(f.silver) * 100 + Digits(f.copper)
end

function Sell:SetUnitPrice(c)
    local f = self.frame
    self.settingPrice = true
    f.gold:SetText(floor(c / 10000))
    f.silver:SetText(floor((c % 10000) / 100))
    f.copper:SetText(c % 100)
    self.settingPrice = false
end

function Sell:GetQuantity()
    return Digits(self.frame.qty)
end

function Sell:ScanItem()
    return self.itemID and FiveLoaves.db.items[self.itemID]
end

function Sell:ApplyReferencePrice()
    if self.userEdited then return end
    local item = self:ScanItem()
    local ref = self.live or (item and item.currentLow)
    if ref and ref > 0 then self:SetUnitPrice(ref) end
end

function Sell:QueryLive()
    if not (self.itemID and self.isCommodity) then return end
    local id = self.itemID
    local ok = pcall(function()
        C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(id), {}, true)
    end)
    self.waitingLive = ok and id or nil
end

function Sell:Deposit(qty)
    if not (self.location and qty > 0) then return nil end
    local ok, dep = pcall(function()
        if self.isCommodity then
            return C_AuctionHouse.CalculateCommodityDeposit(self.itemID, self.duration, qty)
        end
        return C_AuctionHouse.CalculateItemDeposit(self.location, self.duration, qty)
    end)
    return ok and dep or nil
end

function Sell:Update()
    local f = self.frame
    if not f then return end
    local hasItem = self.location ~= nil

    if hasItem then
        f.itemName:SetText(self.link or self.name or "")
        f.itemIcon:SetTexture(self.icon or 134400)
        f.itemCount:SetText(format("%d available in your bags", self.available or 0))
        f.avail:SetText(format("of %d", self.available or 0))
    else
        f.itemName:SetText("|cff999999Right-click an item in your bags|r")
        f.itemIcon:SetTexture(nil)
        f.itemCount:SetText("")
        f.avail:SetText("")
    end

    for _, b in ipairs(f.durButtons) do
        b:SetEnabled(b.durID ~= self.duration)
    end

    local item = self:ScanItem()
    local scanLow = item and item.currentLow
    local avg7 = item and AvgLow(item, 7)
    local liveText = "-"
    if hasItem and self.isCommodity then
        liveText = self.live and U.Money(self.live) or (self.waitingLive and "checking..." or "unavailable")
    end
    f.vLive:SetText(liveText)
    f.vScan:SetText(U.Money(scanLow))
    f.vAvg:SetText(U.Money(avg7))

    local qty, unit = self:GetQuantity(), self:GetUnitPrice()
    f.vTotal:SetText(hasItem and U.Money(qty * unit) or "-")
    local dep = hasItem and self:Deposit(qty)
    f.vDeposit:SetText(dep and U.Money(dep) or "-")
    if hasItem and qty >= 1 and unit > 0 then
        f.analysis:SetText(self:Analyze(qty, unit, dep))
    else
        f.analysis:SetText("")
        f.tAH:SetText("-") f.tVendor:SetText("-") f.tAHMark:SetText("") f.tVendorMark:SetText("")
    end

    local valid = hasItem and qty >= 1 and qty <= (self.available or 0) and unit > 0 and not self.posting
    f.postBtn:SetEnabled(valid and true or false)
end

-- Deal checks: vendor vs AH (after commission and deposit), and price vs history.
function Sell:Analyze(qty, unit, dep)
    local f = self.frame
    local item = self:ScanItem()
    local vendor = self.link and select(11, GetItemInfo(self.link)) or 0
    local ahNet = floor(unit * qty * (1 - AH_CUT)) - (dep or 0)
    local vendorTotal = (vendor or 0) * qty
    local ahWins = ahNet > vendorTotal

    f.tAH:SetText(U.Money(max(ahNet, 0)))
    f.tVendor:SetText(vendorTotal > 0 and U.Money(vendorTotal) or "|cff999999n/a|r")
    f.tAHMark:SetText(ahWins and "|cff00ff00< better|r" or "")
    f.tVendorMark:SetText((vendorTotal > 0 and not ahWins) and "|cff00ff00< better|r" or "")

    local avg7 = item and AvgLow(item, 7)
    local thr = FiveLoaves.db.threshold or 0.20
    local hist
    if avg7 and avg7 > 0 and unit > 0 then
        local pct = (unit - avg7) / avg7
        local shown = floor(abs(pct) * 100 + 0.5)
        if pct <= -thr then
            hist = format("|cffff8800Price is %d%% below the 7 day avg|r - consider holding", shown)
        elseif pct >= thr then
            hist = format("|cff00ff00Price is %d%% above the 7 day avg|r - good time to sell", shown)
        else
            hist = format("Price is near the 7 day avg (%s%d%%)", pct < 0 and "-" or "+", shown)
        end
    else
        hist = "|cff999999No 7 day history to compare|r"
    end
    return hist
end
function Sell:SetStatus(text)
    if self.frame then self.frame.status:SetText(text or "") end
end

function Sell:Clear()
    self.location, self.itemID, self.link, self.name, self.icon = nil, nil, nil, nil, nil
    self.live, self.waitingLive, self.available, self.userEdited = nil, nil, nil, false
    if self.frame then
        self.frame.qty:SetText("")
        self:SetUnitPrice(0)
    end
    self:Update()
end

function Sell:SetItem(loc)
    self.location = loc
    self.itemID = C_Item.GetItemID(loc)
    self.link = C_Item.GetItemLink(loc)
    self.name = self.link and select(1, GetItemInfo(self.link))
    self.icon = C_Item.GetItemIcon(loc)
    self.isCommodity = C_AuctionHouse.GetItemCommodityStatus(loc) == Enum.ItemCommodityStatus.Commodity
    self.available = C_AuctionHouse.GetAvailablePostCount(loc) or 1
    self.live, self.userEdited, self.posting = nil, false, false
    self.frame.qty:SetText(self.isCommodity and self.available or 1)
    self:SetUnitPrice(0)
    self:SetStatus("")
    self:ApplyReferencePrice()
    self:QueryLive()
    self:Update()
end

-- called when the user right-clicks a bag item
function Sell:Pick(loc)
    if not (loc and loc.IsValid and loc:IsValid() and C_AuctionHouse.IsSellItemValid(loc)) then return end
    FiveLoaves:InstallTab()
    if not FiveLoaves.selectSell then return end
    -- drop whatever Blizzard's own Sell tab picked up from the same click
    pcall(function() AuctionHouseFrame.ItemSellFrame:SetItem(nil, nil, false) end)
    pcall(function() AuctionHouseFrame.CommoditiesSellFrame:SetItem(nil, nil, false) end)
    FiveLoaves.selectSell()
    self:SetItem(loc)
end

-- Reasons the user may not want to post: vendor pays more, or the price is well below history.
function Sell:Concerns(qty, unit)
    local out = {}
    local dep = self:Deposit(qty) or 0
    local vendor = self.link and select(11, GetItemInfo(self.link)) or 0
    if vendor and vendor > 0 then
        local ahNet = floor(unit * qty * (1 - AH_CUT)) - dep
        local vendorTotal = vendor * qty
        if vendorTotal >= ahNet then
            out[#out + 1] = format("Selling to the vendor pays more: %s vs %s on the AH (after %d%% cut and deposit).",
                U.Money(vendorTotal), U.Money(max(ahNet, 0)), AH_CUT * 100)
        end
    end
    local avg7 = self:ScanItem() and AvgLow(self:ScanItem(), 7)
    local thr = FiveLoaves.db.threshold or 0.20
    if avg7 and avg7 > 0 and (unit - avg7) / avg7 <= -thr then
        out[#out + 1] = format("Your price is %d%% below the 7 day average (%s) - consider holding.",
            floor((avg7 - unit) / avg7 * 100 + 0.5), U.Money(avg7))
    end
    return out
end

StaticPopupDialogs["FIVELOAVES_CONFIRM_POST"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function() Sell:DoPost() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Sell:Post()
    local loc = self.location
    if loc and C_Item.DoesItemExist(loc) then
        local qty, unit = self:GetQuantity(), self:GetUnitPrice()
        if qty >= 1 and unit > 0 then
            local concerns = self:Concerns(qty, unit)
            if #concerns > 0 then
                StaticPopup_Show("FIVELOAVES_CONFIRM_POST",
                    format("|cffff8800Post anyway?|r\n\n%s\n\nList %d x %s at %s each?",
                        table.concat(concerns, "\n\n"), qty, self.link or "item", U.Money(unit)))
                return
            end
        end
    end
    self:DoPost()
end

function Sell:DoPost()
    local loc = self.location
    if not (loc and C_Item.DoesItemExist(loc)) then
        U.Warn("That item is no longer in your bags.")
        self:Clear()
        return
    end
    local qty, unit = self:GetQuantity(), self:GetUnitPrice()
    if qty < 1 or unit <= 0 then return end

    self.posting = true
    self.pending = { link = self.link, qty = qty, unit = unit }
    self:Update()
    self:SetStatus("Posting...")

    local ok, err
    if self.isCommodity then
        ok, err = pcall(C_AuctionHouse.PostCommodity, loc, self.duration, qty, unit)
    else
        ok, err = pcall(C_AuctionHouse.PostItem, loc, self.duration, qty, nil, unit)
    end
    if not ok then
        self.posting, self.pending = false, nil
        U.Error("Could not post: " .. tostring(err))
        self:SetStatus("|cffff4444Post failed|r")
        self:Update()
        return
    end

    -- re-enable if the server never confirms
    C_Timer.After(8, function()
        if self.posting then
            self.posting = false
            self:SetStatus("No confirmation from the Auction House - check the Auctions tab.")
            self:Update()
        end
    end)
end

function Sell:OnCreated()
    local p = self.pending
    self.posting, self.pending = false, nil
    if p then
        local msg = format("Listed %d x %s at %s each.", p.qty, p.link or "item", U.Money(p.unit))
        U.Action(msg)
        self:SetStatus("|cff00ff00" .. msg .. "|r")
    end
    self:RefreshAvailable()
end

-- ---------- batch posting (Bag view: "Auction all selected") ----------
-- Stackable items (commodities) post as one auction for the whole stack total.
-- Non-stackable items post one auction per item.
local function BagLocations(itemID)
    local out = {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                if C_AuctionHouse.IsSellItemValid(loc) then out[#out + 1] = loc end
            end
        end
    end
    return out
end

local function IsCommodity(loc)
    return C_AuctionHouse.GetItemCommodityStatus(loc) == Enum.ItemCommodityStatus.Commodity
end

local function BatchStatus(text)
    local f = FiveLoaves.mainFrame
    if f and f.bagStatus then f.bagStatus:SetText(text or "") end
end

function Sell:BatchFinish()
    local b = self.batch
    if not b then return end
    self.batch = nil
    local msg = format("Done: %d listed, %d skipped.", b.posted, b.skipped)
    U.Action(msg)
    BatchStatus(msg)
    FiveLoaves:RefreshList()
end

function Sell:BatchSkip(reason)
    local b = self.batch
    b.skipped = b.skipped + 1
    b.phase = "skip"
    U.Warn(format("Skipped %s: %s", b.link or b.name or ("item " .. b.job.id), reason))
    C_Timer.After(0.2, function() self:BatchNext() end)
end

function Sell:BatchNext()
    local b = self.batch
    if not b then return end
    b.phase, b.token = nil, (b.token or 0) + 1
    b.index = b.index + 1
    local job = b.jobs[b.index]
    if not job then return self:BatchFinish() end
    b.job = job
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        U.Warn("Auction House closed - batch stopped.")
        b.skipped = b.skipped + (#b.jobs - b.index + 1)
        return self:BatchFinish()
    end

    local id = job.id
    local rec = FiveLoaves.db.items[id]
    b.name = (rec and rec.name) or ("item " .. id)
    b.link = nil
    BatchStatus(format("Listing %d/%d: %s", b.index, #b.jobs, b.name))

    local loc = BagLocations(id)[1]
    if not loc then return self:BatchSkip("not in bags") end
    b.loc, b.link = loc, C_Item.GetItemLink(loc)
    b.commodity = IsCommodity(loc)
    b.qty = b.commodity and (C_AuctionHouse.GetAvailablePostCount(loc) or 0) or 1
    if b.qty < 1 then return self:BatchSkip("nothing to post") end

    -- look up the live lowest price
    b.phase, b.itemKey = "price", nil
    local token = b.token
    local ok = pcall(function()
        if b.commodity then
            C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(id), {}, true)
        else
            b.itemKey = C_AuctionHouse.GetItemKeyFromItem(loc)
            C_AuctionHouse.SendSearchQuery(b.itemKey,
                { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, true)
        end
    end)
    C_Timer.After(ok and 5 or 0, function()
        if self.batch == b and b.phase == "price" and b.token == token then self:BatchPostNow(nil) end
    end)
end

function Sell:BatchPostNow(livePrice)
    local b = self.batch
    local id = b.job.id
    local item = FiveLoaves.db.items[id]
    local unit = livePrice
    if not unit then
        if not b.commodity then
            -- the scan low is per item ID and would mix item levels, so gear needs a live price
            return self:BatchSkip("live AH price unavailable")
        end
        unit = item and item.currentLow
        if unit and unit > 0 then
            U.Warn(format("%s: live AH price unavailable, using last scan low %s.", b.name, U.Money(unit)))
        end
    end
    if not unit or unit <= 0 then return self:BatchSkip("no AH listings and no scan history to price from") end
    if not C_Item.DoesItemExist(b.loc) then return self:BatchSkip("not in bags") end
    if not (item and item.history and next(item.history)) then
        U.Warn(format("%s: no price history - listing at the live AH low %s with nothing to sanity-check it against.",
            b.link or b.name, U.Money(unit)))
    end

    -- a live price far below history is more likely a mispriced/undercut listing than the real market
    if livePrice and item and item.history then
        local ref = AvgLow(item, 7)
        if not ref then
            local s = FiveLoaves:GetStats(id)
            ref = s and s.avgLow
        end
        local minRatio = FiveLoaves.db.batchMinRatio or 0.5
        if ref and ref > 0 and livePrice < ref * minRatio then
            U.Warn(format("%s: live AH low %s is %d%% below the usual %s - skipped (likely a mispriced listing).",
                b.link or b.name, U.Money(livePrice), floor((1 - livePrice / ref) * 100 + 0.5), U.Money(ref)))
            return self:BatchSkip("live price far below history")
        end
    end

    -- the vendor beats the AH when its price exceeds what the AH nets after cut and deposit
    local vendor = b.link and select(11, GetItemInfo(b.link)) or 0
    if vendor and vendor > 0 then
        local okD, deposit = pcall(function()
            if b.commodity then return C_AuctionHouse.CalculateCommodityDeposit(id, self.duration, b.qty) end
            return C_AuctionHouse.CalculateItemDeposit(b.loc, self.duration, b.qty)
        end)
        local ahNet = floor(unit * b.qty * (1 - AH_CUT)) - (okD and deposit or 0)
        local vendorTotal = vendor * b.qty
        if vendorTotal >= ahNet then
            U.Warn(format("%s: vendor pays more (%s) than the AH nets (%s) - skipped, sell to vendor instead.",
                b.link or b.name, U.Money(vendorTotal), U.Money(max(ahNet, 0))))
            return self:BatchSkip("vendor is worth more")
        end
    end

    b.phase, b.unit = "post", unit
    local token = b.token
    local ok, err
    if b.commodity then
        ok, err = pcall(C_AuctionHouse.PostCommodity, b.loc, self.duration, b.qty, unit)
    else
        ok, err = pcall(C_AuctionHouse.PostItem, b.loc, self.duration, 1, nil, unit)
    end
    if not ok then return self:BatchSkip("post failed: " .. tostring(err)) end
    C_Timer.After(10, function()
        if self.batch == b and b.phase == "post" and b.token == token then
            self:BatchSkip("no confirmation from the Auction House")
        end
    end)
end

function Sell:BatchPost(ids)
    if self.batch then return end
    local jobs = {}
    for _, id in ipairs(ids) do
        local locs = BagLocations(id)
        if locs[1] and IsCommodity(locs[1]) then
            jobs[#jobs + 1] = { id = id }
        else
            for _ = 1, max(#locs, 1) do jobs[#jobs + 1] = { id = id } end
        end
    end
    self.batch = { jobs = jobs, index = 0, posted = 0, skipped = 0 }
    FiveLoaves:UpdateBagControls()
    self:BatchNext()
end

function Sell:BatchOnPriceResult(itemID, itemKey)
    local b = self.batch
    if not (b and b.phase == "price" and b.job.id == itemID) then return end
    local unit
    if b.commodity then
        local raw, skipped
        unit, raw, skipped = self:DepthAdjusted(itemID)
        if unit and skipped and skipped > 0 then
            U.Warn(format("%s: lowest tier was %d unit(s) at %s; ignoring it as a thin outlier and using %s.",
                b.link or b.name, skipped, U.Money(raw), U.Money(unit)))
        end
    else
        local k = b.itemKey
        if not (k and itemKey and itemKey.itemID == k.itemID and itemKey.itemLevel == k.itemLevel
            and itemKey.itemSuffix == k.itemSuffix) then return end
        local info = C_AuctionHouse.GetItemSearchResultInfo(k, 1)
        unit = info and info.buyoutAmount
    end
    self:BatchPostNow(unit)
end

function Sell:BatchOnCreated()
    local b = self.batch
    if not (b and b.phase == "post") then return false end
    b.posted = b.posted + 1
    b.phase = "wait"
    -- untick the item once its last auction is created
    local more = false
    for i = b.index + 1, #b.jobs do
        if b.jobs[i].id == b.job.id then more = true break end
    end
    if not more then FiveLoaves.bagSel[b.job.id] = nil end
    U.Action(format("Listed %d x %s at %s each.", b.qty, b.link or b.name, U.Money(b.unit)))
    C_Timer.After(0.5, function() self:BatchNext() end)
    return true
end

function Sell:RefreshAvailable()
    local loc = self.location
    if not loc then return end
    if not C_Item.DoesItemExist(loc) then
        self.location = nil
        self:Clear()
        return
    end
    local n = C_AuctionHouse.GetAvailablePostCount(loc) or 0
    if n <= 0 then self:Clear() return end
    self.available = n
    if self:GetQuantity() > n then self.frame.qty:SetText(n) end
    self:Update()
end

-- ---------- UI ----------
local function MakeBox(parent, w, letters)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 20)
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    e:SetMaxLetters(letters)
    e:SetJustifyH("RIGHT")
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    return e
end

local function Label(parent, text, x, y, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    if x then fs:SetPoint("TOPLEFT", x, y) end
    fs:SetText(text)
    return fs
end

function FiveLoaves:CreateSellFrame()
    if self.sellFrame then return end
    local f = CreateFrame("Frame", "FiveLoavesSellFrame", AuctionHouseFrame)
    f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -28)
    f:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 30)
    f:Hide()
    Sell.frame = f
    self.sellFrame = f

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.95)

    Label(f, "Create Auction", 70, -16, "GameFontNormalLarge")
    Label(f, "Right-click an item in your bags. Price starts at the current AH low minus 1c.", 70, -40, "GameFontHighlightSmall")

    -- item slot
    local slot = CreateFrame("Frame", nil, f)
    slot:SetSize(44, 44)
    slot:SetPoint("TOPLEFT", 70, -70)
    f.itemIcon = slot:CreateTexture(nil, "ARTWORK")
    f.itemIcon:SetAllPoints()
    local border = slot:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetColorTexture(0.4, 0.4, 0.4, 1)
    f.itemName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.itemName:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -2)
    f.itemName:SetJustifyH("LEFT")
    f.itemCount = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.itemCount:SetPoint("TOPLEFT", f.itemName, "BOTTOMLEFT", 0, -4)

    -- quantity
    Label(f, "Quantity", 70, -140)
    f.qty = MakeBox(f, 60, 5)
    f.qty:SetPoint("TOPLEFT", 200, -136)
    f.qty:SetScript("OnTextChanged", function() Sell:Update() end)
    local maxBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    maxBtn:SetSize(50, 22)
    maxBtn:SetPoint("LEFT", f.qty, "RIGHT", 8, 0)
    maxBtn:SetText("Max")
    maxBtn:SetScript("OnClick", function()
        if Sell.available then f.qty:SetText(Sell.isCommodity and Sell.available or 1) end
    end)
    f.avail = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.avail:SetPoint("LEFT", maxBtn, "RIGHT", 8, 0)

    -- unit price
    Label(f, "Price per unit", 70, -180)
    f.gold = MakeBox(f, 70, 7)
    f.gold:SetPoint("TOPLEFT", 200, -176)
    local gl = Label(f, "|cffffd100g|r", nil, nil, "GameFontHighlight")
    gl:SetPoint("LEFT", f.gold, "RIGHT", 4, 0)
    f.silver = MakeBox(f, 30, 2)
    f.silver:SetPoint("LEFT", gl, "RIGHT", 8, 0)
    local sl = Label(f, "|cffc7c7cfs|r", nil, nil, "GameFontHighlight")
    sl:SetPoint("LEFT", f.silver, "RIGHT", 4, 0)
    f.copper = MakeBox(f, 30, 2)
    f.copper:SetPoint("LEFT", sl, "RIGHT", 8, 0)
    local cl = Label(f, "|cffeda55fc|r", nil, nil, "GameFontHighlight")
    cl:SetPoint("LEFT", f.copper, "RIGHT", 4, 0)
    for _, box in ipairs({ f.gold, f.silver, f.copper }) do
        box:SetScript("OnTextChanged", function(_, user)
            if user and not Sell.settingPrice then Sell.userEdited = true end
            Sell:Update()
        end)
    end

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetSize(120, 22)
    refresh:SetPoint("LEFT", cl, "RIGHT", 14, 0)
    refresh:SetText("Reset to AH low")
    refresh:SetScript("OnClick", function()
        Sell.userEdited = false
        Sell:ApplyReferencePrice()
        Sell:QueryLive()
        Sell:Update()
    end)

    -- duration
    Label(f, "Duration", 70, -220)
    f.durButtons = {}
    for i, d in ipairs(DURATIONS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(80, 22)
        b:SetPoint("TOPLEFT", 200 + (i - 1) * 84, -216)
        b:SetText(d.label)
        b.durID = d.id
        b:SetScript("OnClick", function()
            Sell.duration = d.id
            FiveLoaves.db.sellDuration = d.id
            Sell:Update()
        end)
        f.durButtons[i] = b
    end
    Sell.duration = FiveLoaves.db.sellDuration or 2

    local match = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    match:SetSize(22, 22)
    match:SetPoint("TOPLEFT", 196, -234)
    match:SetChecked(FiveLoaves.db.matchLowest and true or false)
    match.text = match.text or match:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    match.text:SetPoint("LEFT", match, "RIGHT", 2, 0)
    match.text:SetText("Match lowest price (don't ignore thin low tier)")
    match:SetScript("OnClick", function(self)
        FiveLoaves.db.matchLowest = self:GetChecked() or nil
        Sell.userEdited = false
        Sell:QueryLive()
        Sell:Update()
    end)
    f.matchLowest = match
    -- price reference / totals
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.15)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 70, -256)
    rule:SetPoint("TOPRIGHT", -70, -256)

    local rows = {
        { "Lowest on AH now", "vLive" },
        { "Last scan low", "vScan" },
        { "7 day avg low", "vAvg" },
        { "Total buyout", "vTotal" },
        { "Deposit", "vDeposit" },
    }
    for i, r in ipairs(rows) do
        local y = -268 - (i - 1) * 20
        Label(f, r[1], 70, y, "GameFontNormal")
        local v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        v:SetPoint("TOPLEFT", 200, y)
        v:SetWidth(200)
        v:SetJustifyH("LEFT")
        f[r[2]] = v
    end

    Label(f, "Deal check", 430, -268, "GameFontNormal")
    Label(f, "Revenue", 560, -290, "GameFontNormal")
    local rule2 = f:CreateTexture(nil, "ARTWORK")
    rule2:SetColorTexture(1, 1, 1, 0.15)
    rule2:SetHeight(1)
    rule2:SetPoint("TOPLEFT", 430, -308)
    rule2:SetWidth(300)
    local function Cell(x, y, w)
        local v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        v:SetPoint("TOPLEFT", x, y)
        v:SetWidth(w)
        v:SetJustifyH("LEFT")
        return v
    end
    Label(f, "Sell on AH", 430, -316, "GameFontHighlight")
    f.tAH = Cell(560, -316, 110)
    f.tAHMark = Cell(670, -316, 70)
    Label(f, "Sell to vendor", 430, -338, "GameFontHighlight")
    f.tVendor = Cell(560, -338, 110)
    f.tVendorMark = Cell(670, -338, 70)
    Label(f, "AH revenue = price - 5% cut - deposit", 430, -360, "GameFontDisableSmall")
    f.analysis = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.analysis:SetPoint("TOPLEFT", 430, -380)
    f.analysis:SetWidth(330)
    f.analysis:SetJustifyH("LEFT")
    f.analysis:SetJustifyV("TOP")
    f.postBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.postBtn:SetSize(180, 30)
    f.postBtn:SetPoint("BOTTOMLEFT", 70, 18)
    f.postBtn:SetText("Create Auction")
    f.postBtn:SetScript("OnClick", function() Sell:Post() end)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetPoint("LEFT", f.postBtn, "RIGHT", 14, 0)

    f:SetScript("OnShow", function() Sell:RefreshAvailable() Sell:Update() end)
    Sell:Update()
end

-- ---------- bag right-click + events ----------
local function AHReady()
    return AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

local function LocationFromButton(btn)
    local bag = btn.GetBagID and btn:GetBagID() or btn:GetParent():GetID()
    return ItemLocation:CreateFromBagAndSlot(bag, btn:GetID())
end

local function HookBags()
    if ContainerFrameItemButton_OnClick then
        hooksecurefunc("ContainerFrameItemButton_OnClick", function(self, button)
            if button == "RightButton" and AHReady() and not IsModifierKeyDown() then
                local loc = LocationFromButton(self)
                local W = FiveLoaves.Watch
                if W and W:IsActive() then
                    W:HandleBagClick(loc)
                else
                    Sell:Pick(loc)
                end
            end
        end)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        HookBags()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        Sell:BatchOnPriceResult(arg1)
        if Sell.itemID and arg1 == Sell.itemID then
            local price, raw, skipped = Sell:DepthAdjusted(arg1)
            Sell.waitingLive = nil
            if price then
                Sell.live = price
                Sell:ApplyReferencePrice()
                if skipped and skipped > 0 then
                    Sell:SetStatus(format("|cffff8800Ignored %d unit(s) at %s (thin lowest tier)|r", skipped, U.Money(raw)))
                end
            end
            Sell:Update()
        end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        if Sell.batch and arg1 then Sell:BatchOnPriceResult(arg1.itemID, arg1) end
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        if not Sell:BatchOnCreated() then Sell:OnCreated() end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        Sell.posting = false
        if Sell.batch then Sell.batch.skipped = Sell.batch.skipped + (#Sell.batch.jobs - Sell.batch.index) Sell:BatchFinish() end
        Sell:Clear()
    elseif event == "BAG_UPDATE_DELAYED" then
        if Sell.location and Sell.frame and Sell.frame:IsShown() and not Sell.posting then
            Sell:RefreshAvailable()
        end
    end
end)
