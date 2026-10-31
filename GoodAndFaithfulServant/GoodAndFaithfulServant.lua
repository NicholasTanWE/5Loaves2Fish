local ADDON = "GoodAndFaithfulServant"

-- Source tags. AH is shown separately from everything else.
local SOURCES = { "AH", "Vendor", "Mail", "Other" }
local RANGES = { { "Session", "session" }, { "Today", 1 }, { "7 days", 7 }, { "30 days", 30 }, { "All time", "all" } }

local session = {}  -- per-source totals since login/reload or the last reset; separate from the daily records

local db
local lastMoney
local ahOpen, merchantOpen, mailOpen = false, false, false
local mailTag, mailTagExpires

local function Today()
    return date("%Y-%m-%d")
end

local function Coins(copper)
    local sign = copper < 0 and "-" or ""
    return sign .. GetCoinTextureString(math.abs(copper))
end

----------------------------------------------------------------------
-- Recording
----------------------------------------------------------------------

local function CurrentSource()
    if mailTag and GetTime() < mailTagExpires then
        return mailTag
    end
    mailTag = nil
    if ahOpen then return "AH" end
    if merchantOpen then return "Vendor" end
    if mailOpen then return "Mail" end
    return "Other"
end

local function Record(source, delta)
    local day = db.days[Today()]
    if not day then
        day = {}
        db.days[Today()] = day
    end
    local s = day[source]
    if not s then
        s = { inc = 0, exp = 0 }
        day[source] = s
    end
    if delta > 0 then s.inc = s.inc + delta else s.exp = s.exp - delta end

    local ss = session[source]
    if not ss then
        ss = { inc = 0, exp = 0 }
        session[source] = ss
    end
    if delta > 0 then ss.inc = ss.inc + delta else ss.exp = ss.exp - delta end
end

local function OnMoneyChanged()
    local money = GetMoney()
    if lastMoney then
        local delta = money - lastMoney
        if delta ~= 0 then
            Record(CurrentSource(), delta)
        end
    end
    lastMoney = money
end

-- Classify mail gold before it is taken so the following PLAYER_MONEY is tagged.
local function TagMail(index)
    local _, _, _, _, money, _, _, _, _, _, _, canReply, isGM = GetInboxHeaderInfo(index)
    if not money or money <= 0 then return end
    local invoiceType = GetInboxInvoiceInfo and GetInboxInvoiceInfo(index)
    if invoiceType == "seller" or (not canReply and not isGM) then
        mailTag = "AH"
    else
        mailTag = "Mail"
    end
    mailTagExpires = GetTime() + 3
end

----------------------------------------------------------------------
-- Reporting
----------------------------------------------------------------------

local function Summarize(days)
    local t = { AH = { inc = 0, exp = 0 }, Other = { inc = 0, exp = 0 }, bySource = {} }
    for _, s in ipairs(SOURCES) do t.bySource[s] = { inc = 0, exp = 0 } end
    local function accumulate(src, v)
        local bucket = (src == "AH") and t.AH or t.Other
        bucket.inc = bucket.inc + v.inc
        bucket.exp = bucket.exp + v.exp
        local b = t.bySource[src]
        if b then
            b.inc = b.inc + v.inc
            b.exp = b.exp + v.exp
        end
    end
    if days == "session" then
        for src, v in pairs(session) do accumulate(src, v) end
    elseif days == "all" then
        for _, day in pairs(db.days) do
            for src, v in pairs(day) do accumulate(src, v) end
        end
    else
        local now = time()
        for i = 0, days - 1 do
            local day = db.days[date("%Y-%m-%d", now - i * 86400)]
            if day then
                for src, v in pairs(day) do accumulate(src, v) end
            end
        end
    end
    return t
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------

local frame, rangeIndex = nil, 1

local function Refresh()
    if not frame or not frame:IsShown() then return end
    local days = RANGES[rangeIndex][2]
    local t = Summarize(days)
    local lines = {}
    local function add(...) lines[#lines + 1] = string.format(...) end

    add("|cffffd100Auction House|r")
    add("  Revenue:  %s", Coins(t.AH.inc))
    add("  Expenses: %s", Coins(t.AH.exp))
    add("  Profit:   %s", Coins(t.AH.inc - t.AH.exp))
    add(" ")
    add("|cffffd100Everything else|r")
    add("  Revenue:  %s", Coins(t.Other.inc))
    add("  Expenses: %s", Coins(t.Other.exp))
    add("  Profit:   %s", Coins(t.Other.inc - t.Other.exp))
    add(" ")
    add("|cffffd100Net profit: %s|r", Coins(t.AH.inc + t.Other.inc - t.AH.exp - t.Other.exp))
    add(" ")
    add("|cffffd100By source|r (revenue / expenses)")

    local best, bestInc = nil, 0
    for _, s in ipairs(SOURCES) do
        local b = t.bySource[s]
        add("  %s: %s / %s", s, Coins(b.inc), Coins(b.exp))
        if b.inc > bestInc then best, bestInc = s, b.inc end
    end
    add(" ")
    add("Highest income source: %s", best and (best .. " (" .. Coins(bestInc) .. ")") or "none yet")

    frame.text:SetText(table.concat(lines, "\n"))
    for i, btn in ipairs(frame.rangeButtons) do
        btn:SetEnabled(i ~= rangeIndex)
    end
    frame.title:SetText("Good and Faithful Servant - " .. RANGES[rangeIndex][1])
end

local function BuildFrame()
    frame = CreateFrame("Frame", "GoodFaithfulFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(380, 340)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame:Hide()
    tinsert(UISpecialFrames, "GoodFaithfulFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOP", 0, -5)

    frame.rangeButtons = {}
    for i, r in ipairs(RANGES) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(66, 22)
        btn:SetPoint("TOPLEFT", 14 + (i - 1) * 70, -30)
        btn:SetText(r[1])
        btn:SetScript("OnClick", function()
            rangeIndex = i
            Refresh()
        end)
        frame.rangeButtons[i] = btn
    end

    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.text:SetPoint("TOPLEFT", 16, -62)
    frame.text:SetJustifyH("LEFT")
    frame.text:SetJustifyV("TOP")

    local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reset:SetSize(170, 22)
    reset:SetPoint("BOTTOMLEFT", 14, 12)
    reset:SetText("Reset session income")
    reset:SetScript("OnClick", function()
        wipe(session)
        Refresh()
    end)
    reset:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Resets the Session tally only; Today, 7 day, 30 day and All time are unaffected.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    reset:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame:SetScript("OnShow", Refresh)
end

local function Toggle()
    if not frame then BuildFrame() end
    frame:SetShown(not frame:IsShown())
end

----------------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------------

local function PositionButton(btn)
    local angle = math.rad(db.minimapAngle or 220)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function BuildMinimapButton()
    local btn = CreateFrame("Button", "GoodFaithfulMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetPoint("CENTER", 0, 1)

    btn:SetScript("OnClick", Toggle)
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(s)
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            PositionButton(s)
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local t = Summarize(1)
        GameTooltip:AddLine("Good and Faithful Servant")
        GameTooltip:AddDoubleLine("AH profit today", Coins(t.AH.inc - t.AH.exp), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Other profit today", Coins(t.Other.inc - t.Other.exp), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine("Click to open. Drag to move.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    PositionButton(btn)
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        GoodFaithfulDB = GoodFaithfulDB or {}
        db = GoodFaithfulDB
        db.days = db.days or {}
        db.minimapAngle = db.minimapAngle or 220
        ev:UnregisterEvent("ADDON_LOADED")
        for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_MONEY",
            "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "MERCHANT_SHOW", "MERCHANT_CLOSED",
            "MAIL_SHOW", "MAIL_CLOSED" }) do
            ev:RegisterEvent(e)
        end
        BuildMinimapButton()
        if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", TagMail) end
        if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", TagMail) end
        -- Posting charges a deposit; tag it as AH even if a stale mail tag is active
        local function TagDeposit()
            mailTag, mailTagExpires = "AH", GetTime() + 3
        end
        if C_AuctionHouse then
            if C_AuctionHouse.PostItem then hooksecurefunc(C_AuctionHouse, "PostItem", TagDeposit) end
            if C_AuctionHouse.PostCommodity then hooksecurefunc(C_AuctionHouse, "PostCommodity", TagDeposit) end
        end
        if PostAuction then hooksecurefunc("PostAuction", TagDeposit) end
        -- Postage (and money attached to a sent mail) is a Mail expense
        if SendMail then
            hooksecurefunc("SendMail", function()
                mailTag, mailTagExpires = "Mail", GetTime() + 3
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        lastMoney = GetMoney()
    elseif event == "PLAYER_MONEY" then
        OnMoneyChanged()
        Refresh()
    elseif event == "AUCTION_HOUSE_SHOW" then ahOpen = true
    elseif event == "AUCTION_HOUSE_CLOSED" then ahOpen = false
    elseif event == "MERCHANT_SHOW" then merchantOpen = true
    elseif event == "MERCHANT_CLOSED" then merchantOpen = false
    elseif event == "MAIL_SHOW" then mailOpen = true
    elseif event == "MAIL_CLOSED" then mailOpen = false
    end
end)

SLASH_GOODFAITHFUL1 = "/gfs"
SlashCmdList.GOODFAITHFUL = function() Toggle() end
