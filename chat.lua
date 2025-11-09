-- Lemonphone Chat (modified chat.lua)
-- Original by Daniel Ratcliffe, modified for persistent Lemonphone client
-- Features: logging (-log), saved username, global host, auto startup, labeling

local tArgs = { ... }

-- ===== Logging Support =====
local bLogging = false
for i = 1, #tArgs do
    if tArgs[i] == "-log" then
        bLogging = true
        table.remove(tArgs, i)
        break
    end
end

local logFile
if bLogging then
    logFile = fs.open("chat_log.txt", "a")
    local oldPrint = print
    local oldWrite = write

    local function logWrite(text)
        if logFile then
            logFile.write(text)
            logFile.flush()
        end
    end

    function write(...)
        local t = table.pack(...)
        for i = 1, t.n do
            oldWrite(t[i])
            logWrite(t[i])
        end
    end

    function print(...)
        local t = table.pack(...)
        local text = table.concat(t, " ")
        oldPrint(text)
        logWrite(text .. "\n")
    end

    print("Logging enabled. Output will be written to chat_log.txt")
end

-- ===== Clear screen before running =====
term.clear()
term.setCursorPos(1,1)

-- ===== Utility functions =====
local function printUsage()
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(programName .. " host <hostname>")
    print(programName .. " join")
end

local function openModem()
    for _, sModem in ipairs(peripheral.getNames()) do
        if peripheral.getType(sModem) == "modem" then
            if not rednet.isOpen(sModem) then
                rednet.open(sModem)
            end
            return true
        end
    end
    print("No modems found.")
    return false
end

local function closeModem()
    for _, sModem in ipairs(peripheral.getNames()) do
        if peripheral.getType(sModem) == "modem" then
            if rednet.isOpen(sModem) then
                rednet.close(sModem)
            end
        end
    end
end

-- ===== Colours =====
local highlightColour, textColour
if term.isColour() then
    textColour = colours.white
    highlightColour = colours.yellow
else
    textColour = colours.white
    highlightColour = colours.white
end

-- ===== Command parsing =====
local sCommand = tArgs[1]

if sCommand == "host" then
    --------------------------------------------------------
    -- HOST MODE
    --------------------------------------------------------
    local sHostname = tArgs[2]
    if sHostname == nil then
        printUsage()
        return
    end

    if not openModem() then return end
    rednet.host("chat", sHostname)
    print("Hosting chat server '" .. sHostname .. "'")
    print("0 users connected.")

    local tUsers = {}
    local nUsers = 0

    local function send(sText, nUserID)
        if nUserID then
            local tUser = tUsers[nUserID]
            if tUser then
                rednet.send(tUser.nID, {
                    sType = "text",
                    nUserID = nUserID,
                    sText = sText,
                }, "chat")
            end
        else
            for nUserID, tUser in pairs(tUsers) do
                rednet.send(tUser.nID, {
                    sType = "text",
                    nUserID = nUserID,
                    sText = sText,
                }, "chat")
            end
        end
    end

    local tPingPongTimer = {}
    local function ping(nUserID)
        local tUser = tUsers[nUserID]
        rednet.send(tUser.nID, { sType = "ping to client", nUserID = nUserID }, "chat")
        local timer = os.startTimer(15)
        tUser.bPingPonged = false
        tPingPongTimer[timer] = nUserID
    end

    local function printUsers()
        term.setCursorPos(1, select(2, term.getCursorPos()) - 1)
        term.clearLine()
        print(nUsers .. (nUsers == 1 and " user connected." or " users connected."))
    end

    local ok, err = pcall(parallel.waitForAny,
        function()
            while true do
                local _, timer = os.pullEvent("timer")
                local nUserID = tPingPongTimer[timer]
                if nUserID and tUsers[nUserID] then
                    local tUser = tUsers[nUserID]
                    if not tUser.bPingPonged then
                        send("* " .. tUser.sUsername .. " has timed out")
                        tUsers[nUserID] = nil
                        nUsers = nUsers - 1
                        printUsers()
                    else
                        ping(nUserID)
                    end
                end
            end
        end,
        function()
            while true do
                local nSenderID, tMessage = rednet.receive("chat")
                if type(tMessage) == "table" then
                    if tMessage.sType == "login" then
                        local nUserID = tMessage.nUserID
                        local sUsername = tMessage.sUsername
                        if nUserID and sUsername then
                            tUsers[nUserID] = {
                                nID = nSenderID,
                                nUserID = nUserID,
                                sUsername = sUsername,
                            }
                            nUsers = nUsers + 1
                            printUsers()
                            send("* " .. sUsername .. " has joined the chat")
                            ping(nUserID)
                        end
                    elseif tMessage.sType == "logout" then
                        local tUser = tUsers[tMessage.nUserID]
                        if tUser then
                            send("* " .. tUser.sUsername .. " has left the chat")
                            tUsers[tMessage.nUserID] = nil
                            nUsers = nUsers - 1
                            printUsers()
                        end
                    elseif tMessage.sType == "chat" then
                        local tUser = tUsers[tMessage.nUserID]
                        if tUser then
                            send("<" .. tUser.sUsername .. "> " .. tMessage.sText)
                        end
                    elseif tMessage.sType == "ping to server" then
                        local tUser = tUsers[tMessage.nUserID]
                        if tUser then
                            rednet.send(tUser.nID, { sType = "pong to client", nUserID = tMessage.nUserID }, "chat")
                        end
                    elseif tMessage.sType == "pong to server" then
                        local tUser = tUsers[tMessage.nUserID]
                        if tUser then tUser.bPingPonged = true end
                    end
                end
            end
        end
    )

    if not ok then printError(err) end
    for _, tUser in pairs(tUsers) do
        rednet.send(tUser.nID, { sType = "kick" }, "chat")
    end
    rednet.unhost("chat")
    closeModem()

elseif sCommand == "join" then
    --------------------------------------------------------
    -- CLIENT MODE
    --------------------------------------------------------
    local sHostname = "global"
    local sUsername

    -- Prompt or load username
    if fs.exists("chat_username.txt") then
        local f = fs.open("chat_username.txt", "r")
        sUsername = f.readAll():gsub("%s+$", "")
        f.close()
        print("Using saved username: " .. sUsername)
    else
        write("Enter your username: ")
        sUsername = read()
        local f = fs.open("chat_username.txt", "w")
        f.write(sUsername)
        f.close()
    end

    -- Label the computer
    os.setComputerLabel(sUsername .. "'s Lemonphone")

    -- Create startup.lua for auto-run
    local startup = fs.open("startup.lua", "w")
    startup.write('shell.run("netchat join")')
    startup.close()

    -- Connect
    if not openModem() then return end
    write("Looking up " .. sHostname .. "... ")
    local nHostID = rednet.lookup("chat", sHostname)
    if not nHostID then
        print("Failed.")
        return
    else
        print("Success.")
    end

    -- Login
    local nUserID = math.random(1, 2147483647)
    rednet.send(nHostID, { sType = "login", nUserID = nUserID, sUsername = sUsername }, "chat")

    -- Setup ping/pong
    local bPingPonged = true
    local pingPongTimer = os.startTimer(0)
    local function ping()
        rednet.send(nHostID, { sType = "ping to server", nUserID = nUserID }, "chat")
        bPingPonged = false
        pingPongTimer = os.startTimer(15)
    end

    -- Setup chat windows
    local w, h = term.getSize()
    local parentTerm = term.current()
    local titleWindow = window.create(parentTerm, 1, 1, w, 1, true)
    local historyWindow = window.create(parentTerm, 1, 2, w, h - 2, true)
    local promptWindow = window.create(parentTerm, 1, h, w, 1, true)
    historyWindow.setCursorPos(1, h - 2)

    term.clear()
    term.setTextColour(textColour)
    term.redirect(promptWindow)
    promptWindow.restoreCursor()

    local function drawTitle()
        local w = titleWindow.getSize()
        local sTitle = sUsername .. " on " .. sHostname
        titleWindow.setTextColour(highlightColour)
        titleWindow.setCursorPos(math.floor(w / 2 - #sTitle / 2), 1)
        titleWindow.clearLine()
        titleWindow.write(sTitle)
        promptWindow.restoreCursor()
    end

    local function printMessage(sMessage)
        term.redirect(historyWindow)
        print()
        if sMessage:match("^%*") then
            term.setTextColour(highlightColour)
            write(sMessage)
            term.setTextColour(textColour)
        else
            local sUser = sMessage:match("^<[^>]*>")
            if sUser then
                term.setTextColour(highlightColour)
                write(sUser)
                term.setTextColour(textColour)
                write(sMessage:sub(#sUser + 1))
            else
                write(sMessage)
            end
        end
        term.redirect(promptWindow)
        promptWindow.restoreCursor()
    end

    drawTitle()

    local ok, err = pcall(parallel.waitForAny,
        function()
            while true do
                local ev, timer = os.pullEvent()
                if ev == "timer" and timer == pingPongTimer then
                    if not bPingPonged then
                        printMessage("Server timeout.")
                        return
                    else
                        ping()
                    end
                elseif ev == "term_resize" then
                    local w, h = parentTerm.getSize()
                    titleWindow.reposition(1, 1, w, 1)
                    historyWindow.reposition(1, 2, w, h - 2)
                    promptWindow.reposition(1, h, w, 1)
                end
            end
        end,
        function()
            while true do
                local nSenderID, tMessage = rednet.receive("chat")
                if nSenderID == nHostID and type(tMessage) == "table" and tMessage.nUserID == nUserID then
                    if tMessage.sType == "text" then
                        printMessage(tMessage.sText)
                    elseif tMessage.sType == "ping to client" then
                        rednet.send(nSenderID, { sType = "pong to server", nUserID = nUserID }, "chat")
                    elseif tMessage.sType == "pong to client" then
                        bPingPonged = true
                    elseif tMessage.sType == "kick" then
                        return
                    end
                end
            end
        end,
        function()
            local tSendHistory = {}
            while true do
                promptWindow.setCursorPos(1, 1)
                promptWindow.clearLine()
                promptWindow.setTextColor(highlightColour)
                promptWindow.write(": ")
                promptWindow.setTextColor(textColour)
                local sChat = read(nil, tSendHistory)
                if sChat:match("^/logout") then break end
                rednet.send(nHostID, { sType = "chat", nUserID = nUserID, sText = sChat }, "chat")
                table.insert(tSendHistory, sChat)
            end
        end
    )

    term.redirect(parentTerm)
    term.setCursorBlink(false)
    if not ok then printError(err) end
    rednet.send(nHostID, { sType = "logout", nUserID = nUserID }, "chat")
    closeModem()
    print("Disconnected.")
else
    printUsage()
end
