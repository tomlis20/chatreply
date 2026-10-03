local _, NS = ...

-------------------------------------------------------------------------------
-- Message filter: store messages + inject [Reply] links
-------------------------------------------------------------------------------

-- Dedup: the filter fires once per ChatFrame for the same message event.
-- We only want to store each message once, and cache quote data so that
-- the second chat frame still sees the quote after the first one consumed
-- pendingOutgoing / pendingAddonData.
local lastMsgKey = nil
local lastLineID = nil
local lastQuoteData = nil

-- Trailing args (bnSenderID, isMobile, isSubtitle, hideSenderInLetterbox,
-- supressRaidIcons) are passed through untouched via `...` so we never
-- nil them out on clients that have them (Retail 12.x, WoW Forever).
local function OnChatMessage(chatFrame, event, message, sender, language, channelName,
    target, flags, unknown, channelNumber, channelName2, unknown2, counter, guid, ...)

    if not NS.db or not NS.db.enabled then
        return false, message, sender, language, channelName, target, flags,
            unknown, channelNumber, channelName2, unknown2, counter, guid, ...
    end

    local normalSender = NS:NormalizeName(sender)

    -- Store in ring buffer (once per unique message, not per chat frame)
    local channel = nil
    if event == "CHAT_MSG_CHANNEL" then
        channel = channelNumber
    end

    local msgKey = event .. "\0" .. sender .. "\0" .. message
    local lineID
    local quoteData

    if msgKey == lastMsgKey then
        -- Duplicate invocation for another chat frame — reuse cached results
        lineID = lastLineID
        quoteData = lastQuoteData
    else
        lineID = NS:StoreMessage(normalSender, message, event, channel, guid)
        lastMsgKey = msgKey
        lastLineID = lineID

        -- Source 1: Our own outgoing reply just coming back
        if NS.pendingOutgoing
            and message == NS.pendingOutgoing.text
            and (GetTime() - NS.pendingOutgoing.time) < 5 then
            quoteData = {
                sender = NS.pendingOutgoing.originalSender,
                text   = NS.pendingOutgoing.originalText,
            }
            NS.pendingOutgoing = nil

        -- Source 2: Addon metadata from another addon user
        elseif NS.pendingAddonData and NS.pendingAddonData[normalSender] then
            local ad = NS.pendingAddonData[normalSender]
            if (GetTime() - ad.time) < 5 then
                quoteData = {
                    sender = NS:ShortName(ad.originalSender),
                    text   = ad.originalText,
                }
                NS.pendingAddonData[normalSender] = nil
            end
        end

        -- Source 3: Parse embedded quote prefix from message text
        if not quoteData then
            local embeddedBlock = string.match(message, "^(%[@[^%]]+%]) .+$")
            if embeddedBlock then
                local qSender, qText = string.match(embeddedBlock, '^%[@(.+): "(.*)"%]$')
                if qSender then
                    quoteData = {
                        sender = qSender,
                        text   = qText or "",
                    }
                end
            end
        end

        lastQuoteData = quoteData
    end

    -- Strip embedded prefix for display when we have quote data
    local actualReply = message
    if quoteData then
        local body = string.match(message, "^%[@[^%]]+%] (.+)$")
        if body then
            actualReply = body
        end
    end

    -- If we have quote context, prepend grey inline quote to display
    local displayMessage
    if quoteData then
        local quotePart
        if quoteData.text and quoteData.text ~= "" then
            local excerpt = quoteData.text
            if #excerpt > 60 then
                excerpt = string.sub(excerpt, 1, 57) .. "..."
            end
            quotePart = "|cff666666[" .. quoteData.sender .. ": \""
                .. excerpt .. "\"]|r "
        else
            quotePart = "|cff666666[" .. quoteData.sender .. "]|r "
        end
        displayMessage = quotePart .. actualReply
    else
        displayMessage = message
    end

    -- Append [Reply] link
    if NS.db.showReplyLinks then
        displayMessage = displayMessage .. " |Haddon:CRply:" .. lineID .. "|h|TInterface\\AddOns\\ChatReply\\Textures\\reply:0|t|h"
    end

    return false, displayMessage, sender, language, channelName, target, flags,
        unknown, channelNumber, channelName2, unknown2, counter, guid, ...
end

-- Register filter for all tracked events
NS:RegisterInit(function()
    for _, event in ipairs(NS.TRACKED_EVENTS) do
        ChatFrame_AddMessageEventFilter(event, OnChatMessage)
    end
end)

-------------------------------------------------------------------------------
-- Handle [Reply] link clicks
-------------------------------------------------------------------------------
NS:RegisterInit(function()
    hooksecurefunc("SetItemRef", function(link, text, button, chatFrame)
        local lineID = string.match(link, "^addon:CRply:(%d+)$")
        if not lineID then return end

        lineID = tonumber(lineID)
        local msg = NS:GetMessage(lineID)
        if not msg then
            NS:Print("That message is no longer in history.")
            return
        end

        if NS.BeginReply then
            NS:BeginReply(msg, chatFrame)
        end
    end)
end)
