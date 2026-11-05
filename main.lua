--[[
    Aero Delta Utility - single-file executor script
    Roblox on Android via Delta (or any executor with the standard API)

    Features: ESP, camera aimbot with FOV, walk speed / jump power,
              infinite jump, noclip, fly pad, fullbright,
              teleport to player.
]]

-- ===== unload a previous copy =====
if getgenv then
    local old = getgenv().__AeroDelta
    if old and old.destroy then
        pcall(old.destroy)
    end
end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then return end

local state = {
    esp        = false,
    aimbot     = false,
    teamCheck  = false,
    fov        = 160,
    smooth     = 0.30,
    infJump    = false,
    noclip     = false,
    fly        = false,
    flySpeed   = 55,
    fullbright = false,
    speed      = 16,
    jump       = 50,
}

local destroyed = false

-- ===== small helpers =====
local function getChar() return LocalPlayer.Character end

local function getHum()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function getHRP()
    local c = getChar()
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart
end

local function applyMovement()
    local h = getHum()
    if h then
        h.WalkSpeed = state.speed
        h.JumpPower = state.jump
    end
end

-- ===== ESP =====
local espHighlights = {}

local function clearESP()
    for plr, hl in pairs(espHighlights) do
        if hl then pcall(function() hl:Destroy() end) end
        espHighlights[plr] = nil
    end
end

local function espStep()
    if not state.esp then
        if next(espHighlights) then clearESP() end
        return
    end

    for plr, hl in pairs(espHighlights) do
        if not plr.Parent or not plr.Character or not hl or not hl.Parent then
            if hl then pcall(function() hl:Destroy() end) end
            espHighlights[plr] = nil
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local c = plr.Character
            local h = c and c:FindFirstChildOfClass("Humanoid")
            if c and h and h.Health > 0 then
                local hl = espHighlights[plr]
                if not hl or not hl.Parent then
                    hl = Instance.new("Highlight")
                    hl.Name = "AeroESP"
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillTransparency = 0.65
                    hl.OutlineTransparency = 0
                    hl.Parent = c
                    espHighlights[plr] = hl
                end
                hl.Adornee = c
                local color = Color3.fromRGB(255, 80, 80)
                if plr.Team then
                    color = plr.Team.TeamColor.Color
                end
                hl.FillColor = color
                hl.OutlineColor = color
            end
        end
    end
end

-- ===== aimbot =====
local function pickTarget()
    local cam = workspace.CurrentCamera
    if not cam then return nil end

    local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local best, bestDist = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local c = plr.Character
            local head = c and c:FindFirstChild("Head")
            local h = c and c:FindFirstChildOfClass("Humanoid")

            local skip = false
            if state.teamCheck and plr.Team ~= nil and plr.Team == LocalPlayer.Team then
                skip = true
            end

            if head and h and h.Health > 0 and not skip then
                local pos, onScreen = cam:WorldToViewportPoint(head.Position)
                if onScreen then
                    local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
                    if d <= state.fov and d < bestDist then
                        best = head
                        bestDist = d
                    end
                end
            end
        end
    end

    return best
end

local function aimStep(dt)
    if not state.aimbot then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local target = pickTarget()
    if not target then return end

    local goal = CFrame.lookAt(cam.CFrame.Position, target.Position)
    local alpha = math.clamp(dt * 30 * (1.1 - state.smooth), 0, 1)
    cam.CFrame = cam.CFrame:Lerp(goal, alpha)
end

-- ===== fly =====
local flyBV = nil
local flyInput = { f = 0, b = 0, l = 0, r = 0, u = 0, d = 0 }

local function clearFlyInput()
    for k in pairs(flyInput) do flyInput[k] = 0 end
end

local function ensureFlyBody()
    local root = getHRP()
    if not root then return end

    if flyBV and flyBV.Parent ~= root then
        pcall(function() flyBV:Destroy() end)
        flyBV = nil
    end

    if not flyBV then
        local bv = Instance.new("BodyVelocity")
        bv.Name = "AeroFly"
        bv.MaxForce = Vector3.new(1e6, 1e6, 1e6)
        bv.Velocity = Vector3.zero
        bv.Parent = root
        flyBV = bv
    end

    local h = getHum()
    if h then h.PlatformStand = true end
end

local function setFly(on)
    state.fly = on
    if on then
        ensureFlyBody()
    else
        if flyBV then
            pcall(function() flyBV:Destroy() end)
            flyBV = nil
        end
        local h = getHum()
        if h then h.PlatformStand = false end
        clearFlyInput()
    end
end

local function flyStep()
    if not state.fly then return end
    if not getHRP() then return end

    ensureFlyBody()
    local cam = workspace.CurrentCamera
    if not cam or not flyBV then return end

    local look = cam.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude < 1e-3 then flat = Vector3.new(0, 0, -1) end
    flat = flat.Unit
    local right = Vector3.new(-flat.Z, 0, flat.X)

    local move = flat * (flyInput.f - flyInput.b)
        + right * (flyInput.r - flyInput.l)
        + Vector3.new(0, flyInput.u - flyInput.d, 0)

    if move.Magnitude > 1e-3 then
        flyBV.Velocity = move.Unit * state.flySpeed
    else
        flyBV.Velocity = Vector3.zero
    end
end

-- ===== noclip =====
local noclipTouched = {}

local function restoreNoclip()
    for part in pairs(noclipTouched) do
        if part and part.Parent then
            pcall(function() part.CanCollide = true end)
        end
    end
    noclipTouched = {}
end

local function noclipStep()
    local c = getChar()
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then
            if p.CanCollide then
                p.CanCollide = false
                noclipTouched[p] = true
            end
        end
    end
end

-- ===== fullbright =====
local savedLighting = nil

local function setFullbright(on)
    state.fullbright = on
    if on then
        if not savedLighting then
            savedLighting = {
                Brightness     = Lighting.Brightness,
                Ambient        = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                ClockTime      = Lighting.ClockTime,
                FogEnd         = Lighting.FogEnd,
                GlobalShadows  = Lighting.GlobalShadows,
            }
        end
        Lighting.Brightness = 3
        Lighting.Ambient = Color3.fromRGB(150, 150, 150)
        Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1e6
        Lighting.GlobalShadows = false
    else
        if savedLighting then
            for k, v in pairs(savedLighting) do
                pcall(function() Lighting[k] = v end)
            end
            savedLighting = nil
        end
    end
end

-- ===== UI =====
local function resolveGuiParent()
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    if ok and hui then return hui end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local gui = Instance.new("ScreenGui")
gui.Name = "AeroDelta"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = resolveGuiParent()

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(212, 320)
main.Position = UDim2.new(0, 10, 0.5, -160)
main.BackgroundColor3 = Color3.fromRGB(16, 16, 21)
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(45, 45, 58)
stroke.Thickness = 1
stroke.Parent = main

local title = Instance.new("Frame")
title.Size = UDim2.new(1, 0, 0, 32)
title.BackgroundColor3 = Color3.fromRGB(26, 26, 34)
title.BorderSizePixel = 0
title.Parent = main

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 10)
titleCorner.Parent = title

local titleText = Instance.new("TextLabel")
titleText.Size = UDim2.new(1, -70, 1, 0)
titleText.Position = UDim2.fromOffset(10, 0)
titleText.BackgroundTransparency = 1
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 13
titleText.TextColor3 = Color3.fromRGB(235, 235, 245)
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.Text = "AERO // DELTA"
titleText.Parent = title

local hideBtn = Instance.new("TextButton")
hideBtn.Size = UDim2.fromOffset(26, 22)
hideBtn.Position = UDim2.new(1, -34, 0, 5)
hideBtn.BackgroundColor3 = Color3.fromRGB(33, 33, 43)
hideBtn.BorderSizePixel = 0
hideBtn.Font = Enum.Font.GothamBold
hideBtn.TextSize = 14
hideBtn.TextColor3 = Color3.fromRGB(210, 210, 225)
hideBtn.Text = "-"
hideBtn.Parent = title

local hideCorner = Instance.new("UICorner")
hideCorner.CornerRadius = UDim.new(0, 6)
hideCorner.Parent = hideBtn

local reopen = Instance.new("TextButton")
reopen.Size = UDim2.fromOffset(36, 36)
reopen.Position = UDim2.new(0, 10, 0, 70)
reopen.BackgroundColor3 = Color3.fromRGB(26, 26, 34)
reopen.BorderSizePixel = 0
reopen.Font = Enum.Font.GothamBold
reopen.TextSize = 16
reopen.TextColor3 = Color3.fromRGB(120, 200, 255)
reopen.Text = "A"
reopen.Visible = false
reopen.Parent = gui

local reopenCorner = Instance.new("UICorner")
reopenCorner.CornerRadius = UDim.new(0, 8)
reopenCorner.Parent = reopen

hideBtn.MouseButton1Click:Connect(function()
    main.Visible = false
    reopen.Visible = true
end)

reopen.MouseButton1Click:Connect(function()
    main.Visible = true
    reopen.Visible = false
end)

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, 0, 1, -32)
scroll.Position = UDim2.fromOffset(0, 32)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 100)
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.Parent = main

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scroll

local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0, 6)
listPad.PaddingBottom = UDim.new(0, 8)
listPad.PaddingLeft = UDim.new(0, 6)
listPad.PaddingRight = UDim.new(0, 6)
listPad.Parent = scroll

local order = 0
local function nextOrder()
    order = order + 1
    return order
end

-- drag by title bar
local dragging = false
local dragStart = nil
local dragOrigin = nil

title.InputBegan:Connect(function(input)
    if destroyed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        dragOrigin = main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

local dragConn = UserInputService.InputChanged:Connect(function(input)
    if destroyed or not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
            dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X,
            dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y
        )
    end
end)

-- ===== widget builders =====
local function makeButton(text, onClick, height)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, height or 30)
    b.BackgroundColor3 = Color3.fromRGB(33, 33, 42)
    b.BorderSizePixel = 0
    b.AutoButtonColor = true
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 13
    b.TextColor3 = Color3.fromRGB(232, 232, 242)
    b.Text = text
    b.LayoutOrder = nextOrder()
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    b.Parent = scroll
    if onClick then
        b.MouseButton1Click:Connect(function()
            local ok, err = pcall(onClick, b)
            if not ok then warn("[Aero] " .. tostring(err)) end
        end)
    end
    return b
end

local function makeLabel(text)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 16)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.GothamBold
    l.TextSize = 11
    l.TextColor3 = Color3.fromRGB(115, 115, 140)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = text
    l.LayoutOrder = nextOrder()
    l.Parent = scroll
    return l
end

local function makeToggle(text, read, write)
    local b = makeButton("", nil)
    local function refresh()
        local on = read()
        b.Text = text .. ": " .. (on and "ON" or "OFF")
        b.BackgroundColor3 = on and Color3.fromRGB(42, 108, 76) or Color3.fromRGB(33, 33, 42)
    end
    b.MouseButton1Click:Connect(function()
        local ok, err = pcall(function()
            write(not read())
        end)
        if not ok then warn("[Aero] " .. tostring(err)) end
        refresh()
    end)
    refresh()
    return b
end

local function makeStepper(text, read, write, step, minv, maxv, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 30)
    row.BackgroundTransparency = 1
    row.LayoutOrder = nextOrder()
    row.Parent = scroll

    local function mk(txt, right)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(28, 30)
        b.Position = UDim2.new(right and 1 or 0, right and -28 or 0, 0, 0)
        b.BackgroundColor3 = Color3.fromRGB(33, 33, 42)
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 16
        b.TextColor3 = Color3.fromRGB(232, 232, 242)
        b.Text = txt
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = b
        b.Parent = row
        return b
    end

    local minus = mk("-", false)
    local plus = mk("+", true)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -64, 1, 0)
    label.Position = UDim2.fromOffset(32, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Color3.fromRGB(232, 232, 242)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text
    label.Parent = row

    local function format(v)
        if v % 1 ~= 0 then
            local s = string.format("%.2f", v)
            s = s:gsub("0+$", ""):gsub("%.$", "")
            return s
        end
        return tostring(v)
    end

    local function refresh()
        label.Text = text .. ": " .. format(read())
    end

    local function bump(dir)
        local v = read() + step * dir
        if v < minv then v = minv end
        if v > maxv then v = maxv end
        v = math.floor(v * 100 + 0.5) / 100
        write(v)
        refresh()
        if onChange then onChange(v) end
    end

    minus.MouseButton1Click:Connect(function() bump(-1) end)
    plus.MouseButton1Click:Connect(function() bump(1) end)
    refresh()
    return row
end

local function makeHold(parent, text, onDown, onUp, layoutOrder)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 1, 0)
    b.BackgroundColor3 = Color3.fromRGB(33, 33, 42)
    b.BorderSizePixel = 0
    b.AutoButtonColor = false
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 14
    b.TextColor3 = Color3.fromRGB(232, 232, 242)
    b.Text = text
    if layoutOrder then b.LayoutOrder = layoutOrder end
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    b.Parent = parent

    local function isPrimary(input)
        return input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1
    end

    b.InputBegan:Connect(function(input)
        if destroyed or not isPrimary(input) then return end
        b.BackgroundColor3 = Color3.fromRGB(42, 108, 76)
        onDown()
    end)

    b.InputEnded:Connect(function(input)
        if not isPrimary(input) then return end
        b.BackgroundColor3 = Color3.fromRGB(33, 33, 42)
        onUp()
    end)

    return b
end

-- ===== content =====
makeLabel("MOVEMENT")

makeStepper("WalkSpeed", function() return state.speed end,
    function(v) state.speed = v end, 8, 8, 400, applyMovement)

makeStepper("JumpPower", function() return state.jump end,
    function(v) state.jump = v end, 10, 0, 500, applyMovement)

makeToggle("Infinite Jump", function()
    return state.infJump
end, function(v)
    state.infJump = v
end)

makeToggle("Noclip", function()
    return state.noclip
end, function(v)
    state.noclip = v
    if not v then restoreNoclip() end
end)

makeToggle("Fly", function()
    return state.fly
end, function(v)
    setFly(v)
end)

local pad = Instance.new("Frame")
pad.Size = UDim2.new(1, 0, 0, 88)
pad.BackgroundTransparency = 1
pad.LayoutOrder = nextOrder()
pad.Parent = scroll

local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.new(0.32, 0, 0, 28)
grid.CellPadding = UDim2.new(0.02, 0, 0, 2)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = pad

makeHold(pad, "+", function() flyInput.u = 1 end, function() flyInput.u = 0 end, 1)
makeHold(pad, "^", function() flyInput.f = 1 end, function() flyInput.f = 0 end, 2)
makeHold(pad, "-", function() flyInput.d = 1 end, function() flyInput.d = 0 end, 3)
makeHold(pad, "<", function() flyInput.l = 1 end, function() flyInput.l = 0 end, 4)
makeHold(pad, "x", function() clearFlyInput() end, function() end, 5)
makeHold(pad, ">", function() flyInput.r = 1 end, function() flyInput.r = 0 end, 6)
makeHold(pad, "", function() end, function() end, 7)
makeHold(pad, "v", function() flyInput.b = 1 end, function() flyInput.b = 0 end, 8)
makeHold(pad, "", function() end, function() end, 9)

makeStepper("FlySpeed", function() return state.flySpeed end,
    function(v) state.flySpeed = v end, 5, 10, 400)

makeLabel("COMBAT")

makeToggle("Aimbot", function()
    return state.aimbot
end, function(v)
    state.aimbot = v
end)

makeStepper("FOV (px)", function() return state.fov end,
    function(v) state.fov = v end, 20, 20, 600)

makeStepper("Aim smooth", function() return state.smooth end,
    function(v) state.smooth = v end, 0.05, 0.05, 0.95)

makeToggle("Team check", function()
    return state.teamCheck
end, function(v)
    state.teamCheck = v
end)

makeLabel("VISUALS")

makeToggle("ESP", function()
    return state.esp
end, function(v)
    state.esp = v
    if not v then clearESP() end
end)

makeToggle("Fullbright", function()
    return state.fullbright
end, function(v)
    setFullbright(v)
end)

makeLabel("PLAYERS")

local playersBox = Instance.new("Frame")
playersBox.Size = UDim2.new(1, 0, 0, 0)
playersBox.AutomaticSize = Enum.AutomaticSize.Y
playersBox.BackgroundTransparency = 1
playersBox.LayoutOrder = nextOrder()
playersBox.Parent = scroll

local boxLayout = Instance.new("UIListLayout")
boxLayout.Padding = UDim.new(0, 3)
boxLayout.SortOrder = Enum.SortOrder.LayoutOrder
boxLayout.Parent = playersBox

local function teleportTo(plr)
    local target = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    local mine = getHRP()
    if target and mine then
        mine.CFrame = target.CFrame + Vector3.new(0, 3, 0)
    end
end

local function refreshPlayers()
    for _, child in ipairs(playersBox:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end

    local n = 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            n = n + 1
            local h = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
            local hp = h and (tostring(math.floor(h.Health)) .. "hp") or "dead"

            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 26)
            b.BackgroundColor3 = Color3.fromRGB(27, 27, 35)
            b.BorderSizePixel = 0
            b.AutoButtonColor = true
            b.Font = Enum.Font.GothamMedium
            b.TextSize = 12
            b.TextColor3 = Color3.fromRGB(220, 220, 232)
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.Text = "  " .. plr.Name .. "  |  " .. hp
            b.LayoutOrder = n
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 5)
            c.Parent = b
            b.Parent = playersBox

            b.MouseButton1Click:Connect(function()
                local ok, err = pcall(teleportTo, plr)
                if not ok then warn("[Aero] " .. tostring(err)) end
            end)
        end
    end

    if n == 0 then
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 20)
        l.BackgroundTransparency = 1
        l.Font = Enum.Font.GothamMedium
        l.TextSize = 12
        l.TextColor3 = Color3.fromRGB(115, 115, 140)
        l.Text = "no players"
        l.Parent = playersBox
    end
end

makeButton("Refresh players", refreshPlayers, 28)
refreshPlayers()

-- ===== runtime bindings =====
local function frameStep(dt)
    if destroyed then return end
    if state.aimbot then aimStep(dt) end
    if state.fly then flyStep() end
end

local bindOk = pcall(function()
    RunService:UnbindFromRenderStep("AeroDelta")
    RunService:BindToRenderStep("AeroDelta", Enum.RenderPriority.Camera.Value + 1, frameStep)
end)
if not bindOk then
    RunService.RenderStepped:Connect(frameStep)
end

task.spawn(function()
    while not destroyed do
        if state.esp then
            pcall(espStep)
        elseif next(espHighlights) then
            clearESP()
        end
        task.wait(0.5)
    end
end)

task.spawn(function()
    while not destroyed do
        if state.noclip then pcall(noclipStep) end
        task.wait(0.15)
    end
end)

local jumpConn = UserInputService.JumpRequest:Connect(function()
    if destroyed or not state.infJump then return end
    local h = getHum()
    if h then
        h:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

local charConn = LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.6)
    if destroyed then return end
    applyMovement()
    if state.fly then
        setFly(true)
    end
    clearESP()
end)

-- ===== cleanup =====
local function destroy()
    if destroyed then return end
    destroyed = true

    pcall(function() RunService:UnbindFromRenderStep("AeroDelta") end)
    if dragConn then pcall(function() dragConn:Disconnect() end) end
    if jumpConn then pcall(function() jumpConn:Disconnect() end) end
    if charConn then pcall(function() charConn:Disconnect() end) end

    pcall(function() if state.fly then setFly(false) end end)
    state.esp = false
    pcall(clearESP)
    state.noclip = false
    pcall(restoreNoclip)
    pcall(setFullbright, false)
    pcall(function() gui:Destroy() end)

    if getgenv then getgenv().__AeroDelta = nil end
end

makeButton("Unload script", destroy, 30)

if getgenv then
    getgenv().__AeroDelta = {
        destroy = destroy,
        state = state,
        teleportTo = teleportTo,
    }
end
