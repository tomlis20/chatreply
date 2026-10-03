local ADDON_NAME, NS = ...

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
NS.ADDON_PREFIX = "CRply"
NS.MAX_HISTORY = 200
NS.MAX_MSG_LEN = 255

-- Chat events we track and allow replies to
NS.TRACKED_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_CHANNEL",
}

-- Map chat event -> SendChatMessage chatType
NS.EVENT_TO_CHAT_TYPE = {
    CHAT_MSG_SAY            = "SAY",
    CHAT_MSG_YELL           = "YELL",
    CHAT_MSG_WHISPER        = "WHISPER",
    CHAT_MSG_WHISPER_INFORM = "WHISPER",
    CHAT_MSG_PARTY          = "PARTY",
    CHAT_MSG_PARTY_LEADER   = "PARTY",
    CHAT_MSG_RAID           = "RAID",
    CHAT_MSG_RAID_LEADER    = "RAID",
    CHAT_MSG_GUILD          = "GUILD",
    CHAT_MSG_OFFICER        = "OFFICER",
    CHAT_MSG_CHANNEL        = "CHANNEL",
}

-- Map chat event -> addon distribution type for C_ChatInfo.SendAddonMessage
NS.EVENT_TO_ADDON_DIST = {
    CHAT_MSG_PARTY          = "PARTY",
    CHAT_MSG_PARTY_LEADER   = "PARTY",
    CHAT_MSG_RAID           = "RAID",
    CHAT_MSG_RAID_LEADER    = "RAID",
    CHAT_MSG_GUILD          = "GUILD",
    CHAT_MSG_OFFICER        = "GUILD",
    CHAT_MSG_WHISPER        = "WHISPER",
    CHAT_MSG_WHISPER_INFORM = "WHISPER",
}

-------------------------------------------------------------------------------
-- SavedVariables defaults
-------------------------------------------------------------------------------
NS.DEFAULTS = {
    enabled = true,
    showReplyLinks = true,
    embedQuotes = true, -- embed quote in message text so non-addon users can see it
}

-------------------------------------------------------------------------------
-- Ring buffer for message history
-------------------------------------------------------------------------------
local history = {}
local head = 0
local count = 0
local lineIDCounter = 0
local bySender = {} -- ["Name-Realm"] = { lineID1, lineID2, ... }
local byLineID = {} -- [lineID] = index in history

NS.history = history
NS.bySender = bySender
NS.byLineID = byLineID
NS.pendingOutgoing = nil

function NS:NextLineID()
    lineIDCounter = lineIDCounter + 1
    return lineIDCounter
end

function NS:StoreMessage(sender, text, chatType, channel, guid)
    local lineID = self:NextLineID()

    head = (head % self.MAX_HISTORY) + 1
    count = math.min(count + 1, self.MAX_HISTORY)

    -- Evict old entry from indices
    local old = history[head]
    if old then
        byLineID[old.lineID] = nil
        local oldList = bySender[old.sender]
        if oldList then
            for i = #oldList, 1, -1 do
                if oldList[i] == old.lineID then
                    table.remove(oldList, i)
                    break
                end
            end
            if #oldList == 0 then
                bySender[old.sender] = nil
            end
        end
    end

    local record = {
        lineID    = lineID,
        sender    = sender,
        text      = text,
        chatType  = chatType,
        channel   = channel,
        timestamp = GetTime(),
        guid      = guid,
    }

    history[head] = record
    byLineID[lineID] = head

    -- Update sender index
    if not bySender[sender] then
        bySender[sender] = {}
    end
    table.insert(bySender[sender], lineID)

    return lineID
end

function NS:GetMessage(lineID)
    local idx = byLineID[lineID]
    if not idx then return nil end
    return history[idx]
end

function NS:GetLastMessage()
    if count == 0 then return nil end
    return history[head]
end

function NS:GetLastMessageFrom(sender)
    local list = bySender[sender]
    if not list or #list == 0 then return nil end
    local lineID = list[#list]
    return self:GetMessage(lineID)
end

-------------------------------------------------------------------------------
-- Name normalization
-------------------------------------------------------------------------------
function NS:NormalizeName(name)
    if not name or name == "" then return name end
    if not string.find(name, "-") then
        local realm = GetNormalizedRealmName()
        if realm then
            name = name .. "-" .. realm
        end
    end
    return name
end

function NS:ShortName(fullName)
    if not fullName then return "" end
    return string.match(fullName, "^([^%-]+)") or fullName
end

-------------------------------------------------------------------------------
-- Strip hyperlinks from text (for quoting)
-------------------------------------------------------------------------------
function NS:StripLinks(text)
    if not text then return "" end
    -- Replace |Hfoo|hbar|h with bar (the display text)
    text = string.gsub(text, "|H[^|]*|h(.-)|h", "%1")
    -- Remove color codes
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    -- Remove texture escapes
    text = string.gsub(text, "|T[^|]*|t", "")
    -- Remove atlas escapes
    text = string.gsub(text, "|A[^|]*|a", "")
    return text
end

-------------------------------------------------------------------------------
-- Strip embedded quote prefix [@Name: "text"] from a message
-------------------------------------------------------------------------------
function NS:StripEmbeddedQuote(text)
    if not text then return "" end
    local replyBody = string.match(text, "^%[@[^%]]+%] (.+)$")
    return replyBody or text
end

-------------------------------------------------------------------------------
-- Text hash (sum of bytes mod 65536)
-------------------------------------------------------------------------------
function NS:TextHash(text)
    local sum = 0
    for i = 1, #text do
        sum = sum + string.byte(text, i)
    end
    return sum % 65536
end

-------------------------------------------------------------------------------
-- Print helper
-------------------------------------------------------------------------------
function NS:Print(msg)
    print("|cff00ccff[ChatReply]|r " .. msg)
end

-------------------------------------------------------------------------------
-- Event frame & initialization
-------------------------------------------------------------------------------
local frame = CreateFrame("Frame")
NS.frame = frame

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            -- Initialize SavedVariables
            if not ChatReplyDB then
                ChatReplyDB = {}
            end
            for k, v in pairs(NS.DEFAULTS) do
                if ChatReplyDB[k] == nil then
                    ChatReplyDB[k] = v
                end
            end
            NS.db = ChatReplyDB

            NS:Print("Loaded. Click [Reply] on any message or use /reply.")
            self:UnregisterEvent("ADDON_LOADED")

            -- Fire init callbacks for other modules
            if NS.OnInit then
                for _, fn in ipairs(NS.OnInit) do
                    fn()
                end
            end
        end
    end
end)

-- Callback registration for module init
function NS:RegisterInit(fn)
    if not self.OnInit then
        self.OnInit = {}
    end
    table.insert(self.OnInit, fn)
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_CHATREPLY1 = "/reply"
SLASH_CHATREPLY2 = "/rr"

SlashCmdList["CHATREPLY"] = function(input)
    if not NS.db then
        NS:Print("Addon is still loading.")
        return
    end

    input = strtrim(input or "")

    -- Subcommands that work even when disabled
    if input == "on" then
        NS.db.enabled = true
        NS:Print("Enabled.")
        return
    elseif input == "off" then
        NS.db.enabled = false
        NS:Print("Disabled.")
        return
    elseif input == "links" then
        NS.db.showReplyLinks = not NS.db.showReplyLinks
        NS:Print("Reply links " .. (NS.db.showReplyLinks and "shown" or "hidden") .. ".")
        return
    elseif input == "embed" then
        NS.db.embedQuotes = not NS.db.embedQuotes
        NS:Print("Quote embedding " .. (NS.db.embedQuotes and "enabled (visible to all)" or "disabled (addon users only)") .. ".")
        return
    end

    if not NS.db.enabled then
        NS:Print("Addon is disabled. Use /reply on to enable.")
        return
    end

    local msg
    if input ~= "" then
        local target = NS:NormalizeName(input)
        msg = NS:GetLastMessageFrom(target)
        if not msg then
            NS:Print("No recent message found from " .. input .. ".")
            return
        end
    else
        msg = NS:GetLastMessage()
        if not msg then
            NS:Print("No messages in history.")
            return
        end
    end

    -- Trigger reply UI
    if NS.BeginReply then
        NS:BeginReply(msg)
    end
end
