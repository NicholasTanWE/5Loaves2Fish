--[[
    Five Loaves and Two Fish - crafting profit panel
    Shown beside the profession window: cost to craft, projected AH value,
    projected disenchant value and a verdict (sell materials / craft and sell / craft and disenchant).
    All prices come from the addon's own scan data (last AH low).
]]

local ADDON_NAME, ns = ...
local FiveLoaves = ns.FiveLoaves
local U = FiveLoaves.util

local Craft = {}
FiveLoaves.Craft = Craft

local AH_CUT = 0.05
local CLASS_WEAPON, CLASS_ARMOR = 2, 4

-- Disenchant results for MoP-era gear: { minILvl, maxILvl, pct, qty, itemID, pct, qty, itemID, ... }
-- (data from Auctionator's disenchant tables)
local DE = {
    [CLASS_ARMOR] = {
        [2] = {
            { 364, 380, 85, 2, 74249, 15, 1, 74250 },
            { 381, 390, 85, 2.5, 74249, 15, 1, 74250 },
            { 391, 410, 85, 3, 74249, 15, 1.5, 74250 },
            { 411, 483, 85, 3.5, 74249, 15, 2, 74250 },
        },
    },
    [CLASS_WEAPON] = {
        [2] = {
            { 351, 380, 85, 2.5, 74249, 15, 1, 74250 },
            { 381, 390, 85, 3, 74249, 15, 1, 74250 },
            { 391, 410, 85, 3.5, 74249, 15, 1.5, 74250 },
            { 411, 483, 85, 4, 74249, 15, 2, 74250 },
        },
    },
}
for _, class in ipairs({ CLASS_ARMOR, CLASS_WEAPON }) do
    DE[class][3] = {
        { 346, 346, 99, 1, 52721, 1, 2, 52721 },
        { 352, 380, 100, 1, 52721 },
        { 381, 424, 100, 1, 74252 },
        { 425, 449, 100, 1, 74247 },
        { 450, 450, 20, 1, 74247, 80, 1, 74252 },
        { 451, 476, 100, 1, 74247 },
    }
    DE[class][4] = {
        { 281, 419, 100, 1, 52722 },
        { 420, 600, 100, 1, 74248 },
    }
end

local function UnitPrice(itemID)
    local it = itemID and FiveLoaves.db.items[itemID]
    return it and it.currentLow
end

-- Price to use for calculations: outliers are replaced by the historical reference.
-- Returns price, flag ("low"/"high"/nil), reference.
local function SaneUnitPrice(itemID)
    local price = UnitPrice(itemID)
    if not price then return nil end
    local flag, ref = FiveLoaves:PriceSanity(itemID, price)
    if flag and ref then return ref, flag, ref, price end
    return price
end

local function ItemIDOf(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- Expected AH value (gross) of disenchanting the item, or nil if not disenchantable.
local function DisenchantValue(link)
    local itemID = ItemIDOf(link)
    if not itemID then return nil end
    local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
    local quality = select(3, GetItemInfo(link))
    local ilvl = (C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)) or select(4, GetItemInfo(link))
    local byQuality = DE[classID]
    local rows = byQuality and quality and byQuality[quality]
    if not rows then return nil end
    if not ilvl then return nil, true end

    for _, r in ipairs(rows) do
        if ilvl >= r[1] and ilvl <= r[2] then
            local total, missing = 0, false
            for i = 3, #r, 3 do
                local price = SaneUnitPrice(r[i + 2])
                if price then
                    total = total + (r[i] / 100) * r[i + 1] * price
                else
                    missing = true
                end
            end
            return floor(total), false, missing
        end
    end
    return nil
end

function Craft:Compute()
    local idx = GetTradeSkillSelectionIndex and GetTradeSkillSelectionIndex()
    if not idx or idx == 0 then return nil end
    local r = { cost = 0, missing = 0 }

    for i = 1, GetTradeSkillNumReagents(idx) do
        local _, _, count = GetTradeSkillReagentInfo(idx, i)
        local price, flag, ref, raw = SaneUnitPrice(ItemIDOf(GetTradeSkillReagentItemLink(idx, i)))
        if flag then
            r.adjusted = (r.adjusted or 0) + 1
            r.warn = r.warn or format("A reagent scan price (%s) looks off - using the usual %s", U.Money(raw), U.Money(ref))
        end
        if price then
            r.cost = r.cost + price * count
        else
            r.missing = r.missing + 1
        end
    end

    local link = GetTradeSkillItemLink(idx)
    if link and link:find("item:") then
        local lo, hi = GetTradeSkillNumMade(idx)
        local made = ((lo or 1) + (hi or lo or 1)) / 2
        local outId = ItemIDOf(link)
        local price = UnitPrice(outId)
        local flag, ref = FiveLoaves:PriceSanity(outId, price)
        if flag == "low" then
            -- a crashed price is not a reliable sale value; leave it out of the verdict
            r.warn = format("Crafted item scan price (%s) is far below the usual %s - AH value ignored", U.Money(price), U.Money(ref))
            price = nil
        elseif flag == "high" then
            r.warn = format("Crafted item scan price (%s) is far above the usual %s - capped at usual", U.Money(price), U.Money(ref))
            price = ref
        end
        r.made = made
        r.ahGross = price and floor(price * made)
        r.ahNet = r.ahGross and floor(r.ahGross * (1 - AH_CUT))
        r.outFlag = flag
        local de, pending, deMissing = DisenchantValue(link)
        r.deGross = de and floor(de * made)
        r.deNet = r.deGross and floor(r.deGross * (1 - AH_CUT))
        r.deMissing = deMissing
        r.pending = pending
    end

    r.matsNet = floor(r.cost * (1 - AH_CUT))
    return r
end

function Craft:Verdict(r)
    local best, label = r.matsNet, "|cffffff00Sell materials|r"
    if r.ahNet and r.ahNet > best then best, label = r.ahNet, "|cff00ff00Craft and sell on AH|r" end
    if r.deNet and r.deNet > best then best, label = r.deNet, "|cff00ccffCraft and disenchant|r" end
    if best <= 0 then return "|cff999999No price data|r" end
    return label, best
end

function Craft:Update()
    local f = self.frame
    if not (f and f:IsVisible()) then return end
    local r = self:Compute()
    if not r then
        f.vCost:SetText("-") f.vAH:SetText("-") f.vDE:SetText("-") f.vVerdict:SetText("") f.vNote:SetText("")
        return
    end

    f.vCost:SetText(U.Money(r.cost) .. (r.missing > 0 and format(" |cffff8800(+%d unpriced)|r", r.missing) or ""))
    f.vAH:SetText(r.ahNet and U.Money(r.ahNet) or "|cff999999n/a|r")
    if r.pending then
        f.vDE:SetText("|cff999999loading...|r")
    elseif r.deNet then
        f.vDE:SetText(U.Money(r.deNet) .. (r.deMissing and " |cffff8800(partial)|r" or ""))
    else
        f.vDE:SetText("|cff999999n/a|r")
    end

    local label, best = self:Verdict(r)
    f.vVerdict:SetText(label)
    local note = best and format("Sell materials: %s   Best: %s", U.Money(r.matsNet), U.Money(best)) or ""
    if r.warn then note = note .. "\n|cffff4444" .. r.warn .. "|r" end
    f.vNote:SetText(note)
end

function Craft:CreatePanel()
    if self.frame or not TradeSkillFrame then return end
    local f = CreateFrame("Frame", "FiveLoavesCraftPanel", TradeSkillFrame, "BackdropTemplate")
    f:SetSize(250, 230)
    f:SetPoint("TOPLEFT", TradeSkillFrame, "TOPRIGHT", -30, -40)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)
    self.frame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Five Loaves - Craft check")

    local function Row(label, y)
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        l:SetPoint("TOPLEFT", 12, y)
        l:SetWidth(100)
        l:SetJustifyH("LEFT")
        l:SetText(label)
        local v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        v:SetPoint("TOPLEFT", 112, y)
        v:SetWidth(130)
        v:SetJustifyH("LEFT")
        return v
    end
    f.vCost = Row("Cost to craft", -38)
    f.vAH = Row("AH value", -62)
    f.vDE = Row("Disenchant", -86)

    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.15)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 12, -110)
    rule:SetPoint("TOPRIGHT", -12, -110)

    f.vVerdict = Row("Verdict", -120)
    f.vVerdict:SetWidth(138)
    f.vNote = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.vNote:SetPoint("TOPLEFT", 12, -146)
    f.vNote:SetWidth(226)
    f.vNote:SetJustifyH("LEFT")

    local foot = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    foot:SetPoint("BOTTOMLEFT", 12, 10)
    foot:SetWidth(226)
    foot:SetJustifyH("LEFT")
    foot:SetText("Last scan lows, AH values after 5% cut.")

    f:SetScript("OnShow", function() Craft:Update() end)

    if TradeSkillFrame_SetSelection then
        hooksecurefunc("TradeSkillFrame_SetSelection", function() Craft:Update() end)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("TRADE_SKILL_SHOW")
ev:RegisterEvent("TRADE_SKILL_UPDATE")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function(_, event)
    if event == "GET_ITEM_INFO_RECEIVED" and not (Craft.frame and Craft.frame:IsVisible()) then return end
    local ok, err = pcall(function()
        Craft:CreatePanel()
        Craft:Update()
    end)
    if not ok then U.Error("Craft panel: " .. tostring(err)) end
end)
