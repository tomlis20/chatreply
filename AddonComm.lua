local _, NS = ...

-------------------------------------------------------------------------------
-- Addon-to-addon communication
-------------------------------------------------------------------------------
local addonUsers = {} -- ["Name-Realm"] = lastSeenTime
local PRESENCE_TIMEOUT = 1800 -- 30 minutes

NS.addonUsers = addonUsers
NS.pendingAddonData = {} -- [senderNorm] = { time, originalSender, originalText, lineID, hash }

-------------------------------------------------------------------------------
-- Check if a player has the addon
-------------------------------------------------------------------------------
function NS:HasAddon(name)
    local t = addonUsers[name]
    if not t then return false end
    if (GetTime() - t) > PRESENCE_TIMEOUT then
        addonUsers[name] = nil
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- Mark a player as having the addon
-------------------------------------------------------------------------------
local function MarkAddonUser(normalizedName)
    addonUsers[normalizedName] = GetTime()
end

-------------------------------------------------------------------------------
-- Send HELLO presence broadcast
-------------------------------------------------------------------------------
local function SendHello()
    -- Send to guild
    if IsInGuild() then
        C_ChatInfo.SendAddonMessage(NS.ADDON_PREFIX, "HELLO:1", "GUILD")
    end
    -- Send to party/raid
    if IsInGroup(LE_PARTY_CATEGORY_HOME) then
        local dist = IsInRaid() and "RAID" or "PARTY"
        C_ChatInfo.SendAddonMessage(NS.ADDON_PREFIX, "HELLO:1", dist)
    end
end

-------------------------------------------------------------------------------
-- Send reply metadata to addon users
-------------------------------------------------------------------------------
function NS:SendReplyMetadata(originalMsg, distType, target)
    local cleanText = self:StripLinks(originalMsg.text)
    local hash = self:TextHash(cleanText)
    local payload = "R:" .. originalMsg.lineID .. ":"
        .. originalMsg.sender .. ":" .. hash .. ":" .. cleanText

    -- Addon messages have a 255-char limit; truncate if needed
    if #payload > 255 then
        -- Truncate the original text portion to fit
        local headerLen = #("R:" .. originalMsg.lineID .. ":"
            .. originalMsg.sender .. ":" .. hash .. ":")
        local room = 255 - headerLen
        if room > 3 then
            cleanText = string.sub(cleanText, 1, room - 3) .. "..."
            payload = "R:" .. originalMsg.lineID .. ":"
                .. originalMsg.sender .. ":" .. hash .. ":" .. cleanText
        else
            return -- Can't fit meaningful data
        end
    end

    if distType == "WHISPER" and target then
        if self:HasAddon(target) then
            C_ChatInfo.SendAddonMessage(NS.ADDON_PREFIX, payload, "WHISPER", target)
        end
    elseif distType then
        C_ChatInfo.SendAddonMessage(NS.ADDON_PREFIX, payload, distType)
    end
end

-------------------------------------------------------------------------------
-- Handle incoming addon messages
-------------------------------------------------------------------------------
local function OnAddonMessage(prefix, message, dist, sender)
    if prefix ~= NS.ADDON_PREFIX then return end

    local normalSender = NS:NormalizeName(sender)
    MarkAddonUser(normalSender)

    -- Parse message type
    local msgType = string.match(message, "^(%a+):")
    if not msgType then return end

    if msgType == "HELLO" then
        -- Presence confirmed, already marked above
        return
    end

    if msgType == "R" then
        -- Reply metadata: R:<lineID>:<originalSender>:<hash>:<originalText>
        -- Parse carefully: original text is everything after the 4th colon
        local afterR = string.match(message, "^R:(.+)$")
        if not afterR then return end

        -- Split on first 3 colons
        local lineID, rest = string.match(afterR, "^(%d+):(.+)$")
        if not lineID or not rest then return end

        local origSender, rest2 = string.match(rest, "^([^:]+):(.+)$")
        if not origSender or not rest2 then return end

        local hash, origText = string.match(rest2, "^(%d+):(.*)$")
        if not hash then return end

        NS.pendingAddonData[normalSender] = {
            time           = GetTime(),
            lineID         = tonumber(lineID),
            originalSender = origSender,
            originalText   = origText,
            hash           = tonumber(hash),
        }
    end
end

-------------------------------------------------------------------------------
-- Cleanup expired addon data periodically
-------------------------------------------------------------------------------
local CLEANUP_INTERVAL = 60 -- seconds
local lastCleanup = 0

local function CleanupExpired()
    local now = GetTime()
    if (now - lastCleanup) < CLEANUP_INTERVAL then return end
    lastCleanup = now

    -- Clean expired addon user entries
    for name, t in pairs(addonUsers) do
        if (now - t) > PRESENCE_TIMEOUT then
            addonUsers[name] = nil
        end
    end

    -- Clean expired pending addon data (older than 10 seconds)
    for sender, data in pairs(NS.pendingAddonData) do
        if (now - data.time) > 10 then
            NS.pendingAddonData[sender] = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Initialize
-------------------------------------------------------------------------------
NS:RegisterInit(function()
    -- Register addon message prefix
    C_ChatInfo.RegisterAddonMessagePrefix(NS.ADDON_PREFIX)

    -- Event handling
    local commFrame = CreateFrame("Frame")
    commFrame:RegisterEvent("CHAT_MSG_ADDON")
    commFrame:RegisterEvent("GROUP_JOINED")
    commFrame:RegisterEvent("GUILD_ROSTER_UPDATE")

    commFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "CHAT_MSG_ADDON" then
            OnAddonMessage(...)
        elseif event == "GROUP_JOINED" or event == "GUILD_ROSTER_UPDATE" then
            -- Re-announce presence when joining a group or guild updates
            C_Timer.After(2, SendHello)
        end
    end)

    -- Send initial HELLO after a short delay (let systems initialize)
    C_Timer.After(5, SendHello)

    -- Periodic cleanup via a ticker
    C_Timer.NewTicker(CLEANUP_INTERVAL, CleanupExpired)
end)
