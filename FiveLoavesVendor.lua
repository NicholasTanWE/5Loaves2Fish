--[[
    Five Loaves and Two Fish - vendor helper
    Adds a "Sell Trash" button to the merchant window that sells all grey (poor quality) items.
]]

local ADDON_NAME, ns = ...
local FiveLoaves = ns.FiveLoaves
local U = FiveLoaves.util

local Vendor = {}
FiveLoaves.Vendor = Vendor

local POOR = 0
local STEP = 0.08 -- seconds between sales, to avoid server throttling

local function NumSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) end
    return GetContainerNumSlots(bag)
end

local function SlotInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local i = C_Container.GetContainerItemInfo(bag, slot)
        if not i then return nil end
        return i.quality, i.stackCount or 1, i.itemID, i.hyperlink, i.hasNoValue
    end
    local _, count, _, quality, _, _, link, _, noValue, id = GetContainerItemInfo(bag, slot)
    return quality, count or 1, id, link, noValue
end

local function UseItem(bag, slot)
    if C_Container and C_Container.UseContainerItem then
        C_Container.UseContainerItem(bag, slot)
    else
        UseContainerItem(bag, slot)
    end
end

function Vendor:Collect()
    local list, total = {}, 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, NumSlots(bag) do
            local quality, count, id, link, noValue = SlotInfo(bag, slot)
            if quality == POOR and not noValue and link then
                -- price is nil when item data is not cached yet; still sell it
                local price = select(11, GetItemInfo(link))
                if price == nil or price > 0 then
                    list[#list + 1] = { bag = bag, slot = slot }
                    total = total + (price or 0) * count
                end
            end
        end
    end
    return list, total
end

function Vendor:Update()
    local b = self.button
    if not b then return end
    local list, total = self:Collect()
    self.count, self.total = #list, total
    b:SetEnabled(true)
end

function Vendor:Sell()
    if self.selling and GetTime() - (self.sellStart or 0) < 30 then return end
    if not (MerchantFrame and MerchantFrame:IsShown()) then return end
    local list, total = self:Collect()
    if #list == 0 then
        U.Info("No grey items to sell.")
        return
    end
    self.selling = true
    self.sellStart = GetTime()

    local i = 0
    local function step()
        if not (MerchantFrame and MerchantFrame:IsShown()) then
            self.selling = false
            U.Warn(format("Vendor closed after selling %d of %d grey items.", i, #list))
            return
        end
        i = i + 1
        local e = list[i]
        if not e then
            self.selling = false
            U.Action(format("Sold %d grey item stacks for %s.", #list, U.Money(total)))
            self:Update()
            return
        end
        local ok, err = pcall(UseItem, e.bag, e.slot)
        if not ok then
            self.selling = false
            U.Error("Sell Trash failed: " .. tostring(err))
            return
        end
        C_Timer.After(STEP, step)
    end
    step()
end

function Vendor:CreateButton()
    if self.button or not MerchantFrame then return end
    local b = CreateFrame("Button", "FiveLoavesSellTrashButton", MerchantFrame, "UIPanelButtonTemplate")
    b:SetSize(100, 22)
    b:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 70, -32)
    b:SetText("Sell Trash")
    b:SetScript("OnClick", function() Vendor:Sell() end)
    b:SetScript("OnEnter", function(self)
        Vendor:Update()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Sell all grey items")
        if Vendor.count and Vendor.count > 0 then
            GameTooltip:AddDoubleLine(format("%d stacks", Vendor.count), U.Money(Vendor.total), 1, 1, 1, 1, 1, 1)
        else
            GameTooltip:AddLine("Nothing to sell", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.button = b
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("MERCHANT_SHOW")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_SHOW" then
        local ok, err = pcall(function() Vendor:CreateButton() end)
        if not ok then U.Error("Sell Trash button: " .. tostring(err)) end
    end
    if event == "MERCHANT_SHOW" then Vendor.selling = false end
    if MerchantFrame and MerchantFrame:IsShown() then Vendor:Update() end
end)
