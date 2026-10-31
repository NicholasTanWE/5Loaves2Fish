--[[
    Five Loaves and Two Fish - crafting profit panel
    Shown beside the profession window.

    Tailoring / Blacksmithing / Leatherworking:
        cost to craft (AH price for materials, vendor price for vendor materials)
        vs expected disenchant yield (chance x quantity x AH price), and a recommendation:
        sell the materials, or craft the item and disenchant it.
    Other professions:
        cost of materials vs AH price of the crafted item.
]]

local ADDON_NAME, ns = ...
local FiveLoaves = ns.FiveLoaves
local U = FiveLoaves.util

local Craft = {}
FiveLoaves.Craft = Craft

local AH_CUT = 0.05
local CLASS_WEAPON, CLASS_ARMOR = 2, 4

-- Professions whose products are judged by disenchant value (spell IDs, with English fallback names)
local DE_PROFESSIONS = {
    { spell = 2108, name = "Leatherworking" },
    { spell = 3908, name = "Tailoring" },
    { spell = 2018, name = "Blacksmithing" },
}

-- Disenchant results: { minILvl, maxILvl, pct, avgQty, itemID, pct, avgQty, itemID, ... }
local DE = { [CLASS_ARMOR] = {}, [CLASS_WEAPON] = {} }

-- Uncommon (green) gear
local UNCOMMON = {
    -- Vanilla item levels
    { 1, 15, 80, 1.5, 10940, 20, 1.5, 10938 },
    { 16, 20, 75, 1.5, 10940, 20, 1.5, 10939, 5, 1, 10978 },
    { 21, 25, 75, 2.5, 10940, 20, 1.5, 10998, 5, 1, 10978 },
    { 26, 30, 75, 1.5, 11083, 20, 1.5, 11082, 5, 1, 11084 },
    { 31, 35, 75, 2.5, 11083, 20, 1.5, 11134, 5, 1, 11084 },
    { 36, 40, 75, 1.5, 11137, 20, 1.5, 11135, 5, 1, 11138 },
    { 41, 45, 75, 2.5, 11137, 20, 1.5, 11174, 5, 1, 11139 },
    { 46, 50, 75, 1.5, 11176, 20, 1.5, 11175, 5, 1, 11177 },
    { 51, 55, 75, 2.5, 11176, 20, 1.5, 16202, 5, 1, 11178 },
    { 56, 60, 75, 1.5, 16204, 20, 1.5, 16203, 5, 1, 14343 },
    { 61, 65, 75, 2.5, 16204, 20, 2.5, 16203, 5, 1, 14344 },
    -- Mists of Pandaria item levels
    { 364, 380, 85, 2, 74249, 15, 1, 74250 },
    { 381, 390, 85, 2.5, 74249, 15, 1, 74250 },
    { 391, 410, 85, 3, 74249, 15, 1.5, 74250 },
    { 411, 483, 85, 3.5, 74249, 15, 2, 74250 },
}
local RARE = {
    -- Vanilla item levels (shards)
    { 1, 25, 100, 1, 10978 },
    { 26, 35, 100, 1, 11084 },
    { 36, 40, 100, 1, 11138 },
    { 41, 45, 100, 1, 11139 },
    { 46, 50, 100, 1, 11177 },
    { 51, 55, 100, 1, 11178 },
    { 56, 60, 100, 1, 14343 },
    { 61, 65, 100, 1, 14344 },
    -- Mists of Pandaria item levels
    { 346, 346, 99, 1, 52721, 1, 2, 52721 },
    { 352, 380, 100, 1, 52721 },
    { 381, 424, 100, 1, 74252 },
    { 425, 449, 100, 1, 74247 },
    { 450, 450, 20, 1, 74247, 80, 1, 74252 },
    { 451, 476, 100, 1, 74247 },
}
local EPIC = {
    { 281, 419, 100, 1, 52722 },
    { 420, 600, 100, 1, 74248 },
}
for _, class in ipairs({ CLASS_ARMOR, CLASS_WEAPON }) do
    DE[class][2], DE[class][3], DE[class][4] = UNCOMMON, RARE, EPIC
end

-- Items sold by vendors in unlimited quantity: priced at the vendor price, never the AH price.
-- Seeded here and extended automatically from any vendor window you open.
local VENDOR_SEED = {
    [2320] = 8,    -- Coarse Thread
    [2321] = 80,   -- Fine Thread
    [4291] = 400,  -- Silken Thread
    [8343] = 1600, -- Heavy Silken Thread
    [14341] = 4000, -- Rune Thread
}

local function ItemIDOf(link)
    return link and tonumber(link:match("item:(%d+)"))
end

local function VendorPrice(itemID)
    if not itemID then return nil end
    local learned = FiveLoaves.db and FiveLoaves.db.vendorPrices
    return (learned and learned[itemID]) or VENDOR_SEED[itemID]
end

local function LearnVendorPrices()
    local db = FiveLoaves.db
    if not db then return end
    db.vendorPrices = db.vendorPrices or {}
    for i = 1, GetMerchantNumItems() do
        local id = ItemIDOf(GetMerchantItemLink(i))
        local _, _, price, qty, numAvailable, _, _, extCost = GetMerchantItemInfo(i)
        if id and numAvailable == -1 and price and price > 0 and not extCost then
            db.vendorPrices[id] = floor(price / math.max(qty or 1, 1))
        end
    end
end

-- AH price from this addon's scan (outliers replaced by the historical reference),
-- falling back to Auctionator's database when the item was never scanned here.
local function AHPrice(itemID)
    if not itemID then return nil end
    local it = FiveLoaves.db and FiveLoaves.db.items[itemID]
    local price = it and it.currentLow
    if price and price > 0 then
        local flag, ref = FiveLoaves:PriceSanity(itemID, price)
        return price, flag, ref
    end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local ok, p = pcall(api.GetAuctionPriceByItemID, ADDON_NAME, itemID)
        if ok and p and p > 0 then return p end
    end
    return nil
end

-- Returns price, source ("vendor" / "ah"), flag, usual (historical reference)
local function ItemPrice(itemID)
    local vp = VendorPrice(itemID)
    if vp then return vp, "vendor" end
    local p, flag, ref = AHPrice(itemID)
    return p, p and "ah" or nil, flag, ref
end

local function ItemName(itemID)
    return (GetItemInfo(itemID)) or ("item " .. itemID)
end

local function IsDisenchantProfession()
    local current = GetTradeSkillLine and GetTradeSkillLine()
    if not current then return false end
    for _, p in ipairs(DE_PROFESSIONS) do
        local name
        if C_Spell and C_Spell.GetSpellName then name = C_Spell.GetSpellName(p.spell) end
        if not name and GetSpellInfo then name = GetSpellInfo(p.spell) end
        if current == name or current == p.name then return true end
    end
    return false
end

-- Expected disenchant outcomes for an item link.
-- Returns outcomes ({ pct, qty, itemID, price }), or nil plus a reason / "pending" flag.
local function DisenchantOutcomes(link)
    local itemID = ItemIDOf(link)
    if not itemID then return nil, "not an item" end
    local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
    local _, _, quality, baseIlvl = GetItemInfo(link)
    if not quality then return nil, "loading", true end
    if classID ~= CLASS_ARMOR and classID ~= CLASS_WEAPON then return nil, "not disenchantable" end
    if quality < 2 then return nil, "white quality items can't be disenchanted" end
    local ilvl = (C_Item and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)) or baseIlvl
    if not ilvl or ilvl == 0 then return nil, "loading", true end

    local rows = DE[classID][quality]
    if not rows then return nil, "no yield data for this quality" end

    local match
    for _, r in ipairs(rows) do
        if ilvl >= r[1] and ilvl <= r[2] then match = r break end
    end
    if not match then return nil, format("no yield data for item level %d", ilvl) end

    local outcomes = {}
    for i = 3, #match, 3 do
        local id = match[i + 2]
        tinsert(outcomes, { pct = match[i], qty = match[i + 1], id = id, price = (ItemPrice(id)) })
    end
    return outcomes, ilvl
end

function Craft:Compute()
    local idx = GetTradeSkillSelectionIndex and GetTradeSkillSelectionIndex()
    if not idx or idx == 0 then return nil end
    local r = { cost = 0, ahCost = 0, vendorCost = 0, missing = 0, lines = {}, deMode = IsDisenchantProfession() }

    for i = 1, GetTradeSkillNumReagents(idx) do
        local name, _, count = GetTradeSkillReagentInfo(idx, i)
        local price, src, flag, ref = ItemPrice(ItemIDOf(GetTradeSkillReagentItemLink(idx, i)))
        if flag then
            r.warn = r.warn or format("%s scan price (%s) is %s than its usual %s", name or "A reagent's", U.Money(price), flag == "low" and "lower" or "higher", U.Money(ref))
        end
        local total = price and price * count
        tinsert(r.lines, { name = name or "?", count = count, total = total, vendor = src == "vendor" })
        if price then
            r.cost = r.cost + total
            if src == "vendor" then r.vendorCost = r.vendorCost + total
            else r.ahCost = r.ahCost + total end
        else
            r.missing = r.missing + 1
        end
    end

    local link = GetTradeSkillItemLink(idx)
    if link and link:find("item:") then
        local lo, hi = GetTradeSkillNumMade(idx)
        r.made = ((lo or 1) + (hi or lo or 1)) / 2
        local price, flag, ref = AHPrice(ItemIDOf(link))
        if flag then
            r.warn = r.warn or format("Crafted item scan price (%s) is far %s the usual %s", U.Money(price), flag == "low" and "below" or "above", U.Money(ref))
        end
        r.ahNet = price and floor(price * r.made * (1 - AH_CUT))

        if r.deMode then
            local outcomes, info, pending = DisenchantOutcomes(link)
            if outcomes then
                r.ilvl, r.outcomes = info, outcomes
                local gross, unpriced = 0, false
                for _, o in ipairs(outcomes) do
                    if o.price then gross = gross + o.pct / 100 * o.qty * o.price else unpriced = true end
                end
                r.deNet = floor(gross * r.made * (1 - AH_CUT))
                r.deUnpriced = unpriced
            else
                r.deReason, r.pending = info, pending
                -- not disenchantable: judge it like a potion (materials vs AH value of the item)
                if not pending then
                    r.deMode = false
                    r.noDE = info
                end
            end
        end
    end

    r.matsNet = floor(r.ahCost * (1 - AH_CUT))
    return r
end

local M = function(c) return U.Money(c) end

function Craft:Verdict(r)
    if r.deMode then
        if not r.deNet then return "|cff999999No disenchant data|r" end
        -- vendor materials can't be resold at a profit, so skipping the craft just means not buying them
        local craftDE = r.deNet - r.vendorCost
        if craftDE > r.matsNet then
            return "|cff00ccffCraft and disenchant|r", format("Disenchant %s - vendor mats %s = %s vs %s selling materials", M(r.deNet), M(r.vendorCost), M(craftDE), M(r.matsNet))
        end
        return "|cffffff00Sell materials|r", format("Selling materials %s beats craft + disenchant %s", M(r.matsNet), M(max(craftDE, 0)))
    end
    if not r.ahNet then return "|cff999999No AH price for item|r" end
    if r.missing > 0 then return "|cff999999Missing material prices|r" end
    local profit = r.ahNet - r.cost
    if profit > 0 then
        return "|cff00ff00Craft and sell on AH|r", format("Item %s - materials %s = profit %s", M(r.ahNet), M(r.cost), M(profit))
    end
    return "|cffff6060Don't craft|r", format("Item %s is below the materials cost %s", M(r.ahNet), M(r.cost))
end

function Craft:Update()
    local f = self.frame
    if not (f and f:IsVisible()) then return end
    local r = self:Compute()
    if not r then
        f.body:SetText("")
        return
    end

    local L = {}
    local function add(s) tinsert(L, s) end

    add("|cffffd100Materials:|r")
    for _, l in ipairs(r.lines) do
        add(format("  %d x %s%s: %s", l.count, l.name, l.vendor and " |cff999999(vendor)|r" or "",
            l.total and M(l.total) or "|cffff8800no price|r"))
    end
    add("|cffffd100Total cost:|r " .. M(r.cost) .. (r.missing > 0 and format(" |cffff8800(+%d unpriced)|r", r.missing) or ""))

    if r.deMode then
        add("")
        if r.outcomes then
            add(format("|cffffd100Expected disenchant|r |cff999999(item level %d)|r", r.ilvl))
            for _, o in ipairs(r.outcomes) do
                local value = o.price and (" = " .. M(floor(o.qty * o.price))) or " |cffff8800(no AH price)|r"
                add(format("  %d%%: %s x %s%s", o.pct, o.qty, ItemName(o.id), value))
            end
            add(format("  Expected value: %s |cff999999(after cut)|r%s", M(r.deNet), r.deUnpriced and " |cffff8800partial|r" or ""))
        elseif r.pending then
            add("|cffffd100Disenchant:|r |cff999999loading...|r")
        else
            add("|cffffd100Disenchant:|r |cff999999" .. (r.deReason or "n/a") .. "|r")
        end
        add("")
        add("|cffffd100Sell materials:|r " .. M(r.matsNet))
        if r.deNet then add("|cffffd100Craft + disenchant:|r " .. M(max(r.deNet - r.vendorCost, 0))) end
    else
        if r.noDE then
            add("")
            add("|cffffd100Disenchant:|r |cff999999" .. r.noDE .. "|r")
        end
        add("|cffffd100Item on AH:|r " .. (r.ahNet and (M(r.ahNet) .. " |cff999999(after cut)|r") or "|cff999999n/a|r"))
    end

    local label, detail = self:Verdict(r)
    add("")
    add("|cffffd100Verdict:|r " .. label)
    if detail then add("|cff999999" .. detail .. "|r") end
    if r.warn then add("|cffff4444" .. r.warn .. "|r") end

    f.body:SetText(table.concat(L, "\n"))
    f:SetHeight(f.body:GetStringHeight() + 60)
end

function Craft:CreatePanel()
    if self.frame or not TradeSkillFrame then return end
    local f = CreateFrame("Frame", "FiveLoavesCraftPanel", TradeSkillFrame, "BackdropTemplate")
    f:SetSize(380, 260)
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

    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", 14, -38)
    f.body:SetWidth(352)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")

    f:SetScript("OnShow", function() Craft:Update() end)

    if TradeSkillFrame_SetSelection then
        hooksecurefunc("TradeSkillFrame_SetSelection", function() Craft:Update() end)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("TRADE_SKILL_SHOW")
ev:RegisterEvent("TRADE_SKILL_UPDATE")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:RegisterEvent("MERCHANT_SHOW")
ev:RegisterEvent("MERCHANT_UPDATE")
ev:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        pcall(LearnVendorPrices)
        return
    end
    if event == "GET_ITEM_INFO_RECEIVED" and not (Craft.frame and Craft.frame:IsVisible()) then return end
    local ok, err = pcall(function()
        Craft:CreatePanel()
        Craft:Update()
    end)
    if not ok then U.Error("Craft panel: " .. tostring(err)) end
end)
