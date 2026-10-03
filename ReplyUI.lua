local _, NS = ...

-------------------------------------------------------------------------------
-- Pending reply state
-------------------------------------------------------------------------------
local pendingReply = nil -- the message record we're replying to
local activeEditBox = nil -- which editbox is being used for this reply

-------------------------------------------------------------------------------
-- Reply indicator frame
-------------------------------------------------------------------------------
local indicator = CreateFrame("Frame", "ChatReplyIndicator", UIParent, "BackdropTemplate")
indicator:SetSize(400, 24)
indicator:SetBackdrop({
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeSize = 1,
})
indicator:SetBackdropColor(0.1, 0.1, 0.1, 0.85)
indicator:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
indicator:SetFrameStrata("DIALOG")
indicator:Hide()

local indicatorText = indicator:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
indicatorText:SetPoint("LEFT", 8, 0)
indicatorText:SetPoint("RIGHT", -24, 0)
indicatorText:SetJustifyH("LEFT")
indicatorText:SetWordWrap(false)

local cancelBtn = CreateFrame("Button", nil, indicator)
cancelBtn:SetSize(16, 16)
cancelBtn:SetPoint("RIGHT", -4, 0)
local cancelLabel = cancelBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
cancelLabel:SetPoint("CENTER", 0, 0)
cancelLabel:SetText("|cffff4444X|r")
cancelBtn:SetScript("OnClick", function()
    NS:CancelReply()
end)

-------------------------------------------------------------------------------
-- Anchor indicator to the given editbox
-------------------------------------------------------------------------------
local function AnchorIndicator(editBox)
    indicator:ClearAllPoints()
    indicator:SetPoint("BOTTOMLEFT", editBox, "TOPLEFT", 0, 0)
    indicator:SetPoint("BOTTOMRIGHT", editBox, "TOPRIGHT", 0, 0)
end

-------------------------------------------------------------------------------
-- Show / hide indicator
-------------------------------------------------------------------------------
local function ShowIndicator(msg, editBox)
    local cleanText = NS:StripLinks(msg.text)
    local shortSender = NS:ShortName(msg.sender)
    local excerpt = cleanText
    if #excerpt > 50 then
        excerpt = string.sub(excerpt, 1, 47) .. "..."
    end

    if editBox then
        AnchorIndicator(editBox)
    end
    indicatorText:SetText("|cffaaaaaaReplying to |r" .. shortSender
        .. "|cffaaaaaa: \"" .. excerpt .. "\"|r")
    indicator:Show()
end

local function HideIndicator()
    indicator:Hide()
end

-------------------------------------------------------------------------------
-- Build chat command for a chat type
-------------------------------------------------------------------------------
local CHAT_TYPE_COMMANDS = {
    WHISPER = "/w ",
    SAY     = "/s ",
    YELL    = "/y ",
    PARTY   = "/p ",
    RAID    = "/ra ",
    GUILD   = "/g ",
    OFFICER = "/o ",
}

-------------------------------------------------------------------------------
-- Begin / Cancel / Send reply
-------------------------------------------------------------------------------
function NS:BeginReply(msg, chatFrame)
    if not self.db or not self.db.enabled then return end

    pendingReply = msg

    -- Determine which chat frame to use
    chatFrame = chatFrame or SELECTED_CHAT_FRAME or ChatFrame1

    -- Open and focus the edit box with the correct chat type
    local chatType = NS.EVENT_TO_CHAT_TYPE[msg.chatType]
    if not chatType then
        chatType = "SAY"
    end

    local cmd
    if chatType == "WHISPER" then
        cmd = "/w " .. self:ShortName(msg.sender) .. " "
    elseif chatType == "CHANNEL" then
        cmd = "/" .. (msg.channel or "1") .. " "
    else
        cmd = CHAT_TYPE_COMMANDS[chatType] or "/s "
    end

    ChatFrame_OpenChat(cmd, chatFrame)

    -- Find which editbox is now active and anchor indicator to it
    local editBox = chatFrame and chatFrame.editBox or ChatFrame1EditBox
    activeEditBox = editBox
    ShowIndicator(msg, editBox)
end

function NS:CancelReply()
    pendingReply = nil
    activeEditBox = nil
    HideIndicator()
end

-------------------------------------------------------------------------------
-- Send hook logic (shared by all editbox hooks)
-------------------------------------------------------------------------------
local function OnEditBoxKeyDown(self, key)
    if key ~= "ENTER" then return end
    if not pendingReply then return end

    local text = self:GetText()
    if not text or text == "" or string.match(text, "^/") then
        return
    end

    local sendText = text

    -- Embed quote prefix in the actual chat message so non-addon users can see it
    if NS.db.embedQuotes then
        local cleanOrig = NS:StripLinks(pendingReply.text)
        -- Strip any existing embedded quote to avoid nesting
        cleanOrig = NS:StripEmbeddedQuote(cleanOrig)
        local shortSender = NS:ShortName(pendingReply.sender)

        -- Sanitize excerpt for embedding (remove ] and " to preserve pattern)
        local excerpt = string.gsub(cleanOrig, '[%]"]', "")
        if #excerpt > 40 then
            excerpt = string.sub(excerpt, 1, 37) .. "..."
        end

        local prefix = '[@' .. shortSender .. ': "' .. excerpt .. '"] '

        -- Only embed if total fits within chat message limit
        if #prefix + #text <= 255 then
            sendText = prefix .. text
            self:SetText(sendText)
        end
    end

    -- Store outgoing reply context so the chat filter can render the quote
    -- when our own message comes back from the server
    NS.pendingOutgoing = {
        text           = sendText,
        originalSender = NS:ShortName(pendingReply.sender),
        originalText   = NS:StripLinks(pendingReply.text),
        time           = GetTime(),
    }

    -- Send addon metadata if available
    local msg = pendingReply
    local addonDist = NS.EVENT_TO_ADDON_DIST[msg.chatType]
    if addonDist and NS.SendReplyMetadata then
        local target = nil
        if addonDist == "WHISPER" then
            target = msg.sender
        end
        NS:SendReplyMetadata(msg, addonDist, target)
    end

    -- Clear pending state
    pendingReply = nil
    activeEditBox = nil
    HideIndicator()
end

local function OnEditBoxEscape(self)
    if pendingReply then
        NS:CancelReply()
    end
end

local function OnEditBoxHide(self)
    if pendingReply then
        NS:CancelReply()
    end
end

-------------------------------------------------------------------------------
-- Hook ALL chat frame editboxes
-------------------------------------------------------------------------------
NS:RegisterInit(function()
    for i = 1, NUM_CHAT_WINDOWS do
        local cf = _G["ChatFrame" .. i]
        local editBox = cf and cf.editBox or _G["ChatFrame" .. i .. "EditBox"]
        if editBox then
            editBox:HookScript("OnKeyDown", OnEditBoxKeyDown)
            editBox:HookScript("OnEscapePressed", OnEditBoxEscape)
            editBox:HookScript("OnHide", OnEditBoxHide)
        end
    end
end)

-------------------------------------------------------------------------------
-- Expose pendingReply for other modules
-------------------------------------------------------------------------------
function NS:GetPendingReply()
    return pendingReply
end
