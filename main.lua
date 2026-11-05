--[[
    Aero v2 - mobile executor UI for Delta (Android)

    Tabs: Move / Aim / Visual / Players
    Features: speed + jump, infinite jump, noclip, fly pad, aimbot with FOV
              circle, ESP (boxes, names, distance, hp), fullbright, safe
              teleport to player.
]]

local OldVersion = getgenv and getgenv().__Aero
if OldVersion and OldVersion.destroy then
    pcall(OldVersion.destroy)
end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")

local LP = Players.LocalPlayer
if not LP then return end

-- Drawing library (Delta has it). Used by ESP + FOV circle.
local DrawingLib = nil
pcall(function()
    if typeof(Drawing) == "table" and Drawing.new then
        DrawingLib = Drawing
    end
end)

local state = {
    speed      = 16,
    jump       = 50,
    lockStats  = false,
    infJump    = false,
    noclip     = false,
    fly        = false,
    flySpeed   = 60,
    aimbot     = false,
    fov        = 150,
    smooth     = 0.35,
    teamCheck  = false,
    predict    = true,
    esp        = false,
    fullbright = false,
}

local destroyed = false

local function getChar() return LP.Character end

local function getHum()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function getHRP()
    local c = getChar()
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart
end

-- ============================================================
--  movement
-- ============================================================
local function applySpeed()
    local h = getHum()
    if h then h.WalkSpeed = state.speed end
end

local function applyJump()
    local h = getHum()
    if not h then return end
    -- games that run on JumpHeight ignore JumpPower until this is flipped
    if h.UseJumpPower ~= true then
        pcall(function() h.UseJumpPower = true end)
    end
    h.JumpPower = state.jump
end

local function applyStats()
    applySpeed()
    applyJump()
end

-- ============================================================
--  noclip (remembers the original CanCollide)
-- ============================================================
local noclipSaved = {}

local function noclipOff()
    for part, value in pairs(noclipSaved) do
        if part and part.Parent then
            pcall(function() part.CanCollide = value end)
        end
    end
    noclipSaved = {}
end

local function noclipOn()
    local c = getChar()
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and p.CanCollide then
            noclipSaved[p] = true
            p.CanCollide = false
        end
    end
end

-- ============================================================
--  fly
-- ============================================================
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
    if h and h.Health > 0 then h.PlatformStand = true end
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

    local h = getHum()
    if not h or h.Health <= 0 then return end
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

-- ============================================================
--  fullbright
-- ============================================================
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
    elseif savedLighting then
        for k, v in pairs(savedLighting) do
            pcall(function() Lighting[k] = v end)
        end
        savedLighting = nil
    end
end

-- ============================================================
--  teleport (safe: offset, floor snap, velocity pin)
-- ============================================================
local function safeTeleport(plr)
    local myChar, myRoot, myHum = getChar(), getHRP(), getHum()
    if not myChar or not myRoot or not myHum or myHum.Health <= 0 then
        return false, "you are dead"
    end

    local tChar = plr.Character
    local tRoot = tChar and tChar:FindFirstChild("HumanoidRootPart")
    local tHum = tChar and tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health <= 0 then
        return false, "target is dead"
    end

    -- land slightly behind the target instead of inside their body:
    -- overlapping parts is what launches you into the void / kills you
    local dest = (tRoot.CFrame * CFrame.new(0, 0, 3.5)).Position

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { myChar, tChar }
    params.IgnoreWater = false

    local hit = workspace:Raycast(dest + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), params)
    if hit then
        dest = hit.Position + Vector3.new(0, 3, 0)
    else
        dest = dest + Vector3.new(0, 1, 0)
    end

    myRoot.AssemblyLinearVelocity = Vector3.zero
    myRoot.AssemblyAngularVelocity = Vector3.zero
    myChar:PivotTo(CFrame.new(dest))

    -- pin velocity right after the move so physics does not yeet us
    task.spawn(function()
        for _ = 1, 8 do
            if destroyed then return end
            local root = getHRP()
            if not root then return end
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            task.wait(0.03)
        end
    end)

    return true
end

-- ============================================================
--  aimbot
-- ============================================================
local function pickTarget()
    local cam = workspace.CurrentCamera
    if not cam then return nil end

    local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local best, bestDist = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local c = plr.Character
            local head = c and c:FindFirstChild("Head")
            local h = c and c:FindFirstChildOfClass("Humanoid")

            local skip = false
            if state.teamCheck and plr.Team ~= nil and plr.Team == LP.Team then
                skip = true
            end

            if head and h and h.Health > 0 and not skip then
                local aimAt = head.Position
                if state.predict then
                    aimAt = aimAt + head.AssemblyLinearVelocity * 0.12
                end
                local pos, onScreen = cam:WorldToViewportPoint(aimAt)
                if onScreen then
                    local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
                    if d <= state.fov and d < bestDist then
                        best, bestDist = aimAt, d
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

    local goal = CFrame.lookAt(cam.CFrame.Position, target)
    local speed = 26 - 24 * state.smooth
    local alpha = math.clamp(dt * speed, 0, 1)
    cam.CFrame = cam.CFrame:Lerp(goal, alpha)
end

-- ============================================================
--  ESP
-- ============================================================
local espItems = {}   -- [player] = { box, name, info }
local espFallback = {} -- [player] = Highlight, only if Drawing is missing

local function hideItem(item)
    if not item then return end
    item.box.Visible = false
    item.name.Visible = false
    item.info.Visible = false
end

local function newItem()
    local item = {}

    item.box = DrawingLib.new("Square")
    item.box.Thickness = 1
    item.box.Filled = false
    item.box.Transparency = 1
    item.box.Visible = false

    item.name = DrawingLib.new("Text")
    item.name.Size = 13
    item.name.Center = true
    item.name.Outline = true
    item.name.Visible = false

    item.info = DrawingLib.new("Text")
    item.info.Size = 12
    item.info.Center = true
    item.info.Outline = true
    item.info.Visible = false

    return item
end

local function removeItem(item)
    if not item then return end
    pcall(function() item.box:Remove() end)
    pcall(function() item.name:Remove() end)
    pcall(function() item.info:Remove() end)
end

local function clearESP()
    for plr, item in pairs(espItems) do
        removeItem(item)
        espItems[plr] = nil
    end
    for plr, hl in pairs(espFallback) do
        pcall(function() hl:Destroy() end)
        espFallback[plr] = nil
    end
end

local function espColor(plr, hum)
    if hum and hum.Health <= 0 then
        return Color3.fromRGB(120, 120, 130)
    end
    if plr.Team then
        return plr.Team.TeamColor.Color
    end
    return Color3.fromRGB(124, 92, 255)
end

-- fallback when the executor has no Drawing library
local function espFallbackStep()
    if not state.esp then
        for plr, hl in pairs(espFallback) do
            pcall(function() hl:Destroy() end)
            espFallback[plr] = nil
        end
        return
    end

    for plr, hl in pairs(espFallback) do
        if not plr.Parent or not plr.Character or not hl or not hl.Parent then
            if hl then pcall(function() hl:Destroy() end) end
            espFallback[plr] = nil
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local c = plr.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if c and hum then
                local hl = espFallback[plr]
                if not hl or not hl.Parent then
                    hl = Instance.new("Highlight")
                    hl.Name = "AeroESP"
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillTransparency = 0.65
                    hl.OutlineTransparency = 0
                    hl.Parent = c
                    espFallback[plr] = hl
                end
                local color = espColor(plr, hum)
                hl.Adornee = c
                hl.FillColor = color
                hl.OutlineColor = color
            end
        end
    end
end

local function espStep()
    if not DrawingLib then
        espFallbackStep()
        return
    end

    if not state.esp then
        for _, item in pairs(espItems) do hideItem(item) end
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then return end

    local seen = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local c = plr.Character
            local head = c and c:FindFirstChild("Head")
            local hum = c and c:FindFirstChildOfClass("Humanoid")

            if c and head and hum then
                seen[plr] = true

                local item = espItems[plr]
                if not item then
                    item = newItem()
                    espItems[plr] = item
                end

                local top = cam:WorldToViewportPoint(head.Position + Vector3.new(0, 1.4, 0))
                local bottom = cam:WorldToViewportPoint(head.Position - Vector3.new(0, 2.8, 0))

                if top.Z > 0 and bottom.Z > 0 then
                    local h = math.abs(bottom.Y - top.Y)
                    local w = h * 0.55
                    if h < 6 then h = 6 end

                    local color = espColor(plr, hum)

                    item.box.Color = color
                    item.box.Size = Vector2.new(w, h)
                    item.box.Position = Vector2.new(top.X - w * 0.5, top.Y)
                    item.box.Visible = true

                    item.name.Color = color
                    item.name.Text = plr.Name
                    item.name.Position = Vector2.new(top.X, top.Y - 16)
                    item.name.Visible = true

                    local dist = math.floor((cam.CFrame.Position - head.Position).Magnitude)
                    item.info.Color = Color3.fromRGB(230, 230, 240)
                    item.info.Text = string.format("%d m   %d hp", dist, math.floor(hum.Health))
                    item.info.Position = Vector2.new(top.X, top.Y + h + 2)
                    item.info.Visible = true
                else
                    hideItem(item)
                end
            end
        end
    end

    for plr, item in pairs(espItems) do
        if not seen[plr] then hideItem(item) end
    end
end

-- ============================================================
--  UI tema
-- ============================================================
local Theme = {
    bg       = Color3.fromRGB(13, 13, 17),
    card     = Color3.fromRGB(23, 23, 30),
    cardHi   = Color3.fromRGB(29, 29, 38),
    line     = Color3.fromRGB(42, 42, 55),
    text     = Color3.fromRGB(234, 234, 244),
    dim      = Color3.fromRGB(138, 138, 160),
    accent   = Color3.fromRGB(124, 92, 255),
    accent2  = Color3.fromRGB(86, 200, 255),
    good     = Color3.fromRGB(68, 200, 140),
}

local function corner(parent, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r)
    c.Parent = parent
    return c
end

local function resolveGuiParent()
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    if ok and hui then return hui end
    return LP:WaitForChild("PlayerGui")
end

-- forward declaration: the header close button runs before the
-- real implementation is defined at the bottom of the file
local destroy

local gui = Instance.new("ScreenGui")
gui.Name = "Aero"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 1000
gui.Parent = resolveGuiParent()

local vp = gui.AbsoluteSize
if vp.X < 10 then vp = Vector2.new(400, 700) end

local PANEL_W = math.clamp(math.floor(vp.X * 0.52), 258, 340)
local PANEL_H = math.clamp(math.floor(vp.Y * 0.62), 320, 480)

local main = Instance.new("Frame")
main.Name = "Panel"
main.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
main.Position = UDim2.new(0, 12, 0.5, -math.floor(PANEL_H * 0.5))
main.BackgroundColor3 = Theme.bg
main.BorderSizePixel = 0
main.Active = true
main.ClipsDescendants = true
main.Parent = gui
corner(main, 16)

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Theme.line
mainStroke.Thickness = 1
mainStroke.Transparency = 0.2
mainStroke.Parent = main

-- header ------------------------------------------------------
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundTransparency = 1
header.Parent = main

local dot = Instance.new("Frame")
dot.Size = UDim2.fromOffset(8, 8)
dot.Position = UDim2.new(0, 14, 0, 16)
dot.BackgroundColor3 = Theme.accent
dot.BorderSizePixel = 0
dot.Parent = header
corner(dot, 4)

local brand = Instance.new("TextLabel")
brand.Size = UDim2.new(1, -120, 1, 0)
brand.Position = UDim2.fromOffset(28, 0)
brand.BackgroundTransparency = 1
brand.Font = Enum.Font.GothamBold
brand.TextSize = 15
brand.TextColor3 = Theme.text
brand.TextXAlignment = Enum.TextXAlignment.Left
brand.Text = "AERO"
brand.Parent = header

local brandTag = Instance.new("TextLabel")
brandTag.Size = UDim2.new(1, -120, 1, 0)
brandTag.Position = UDim2.fromOffset(76, 0)
brandTag.BackgroundTransparency = 1
brandTag.Font = Enum.Font.GothamMedium
brandTag.TextSize = 10
brandTag.TextColor3 = Theme.dim
brandTag.TextXAlignment = Enum.TextXAlignment.Left
brandTag.Text = "mobile"
brandTag.Parent = header

local function headerButton(text, x, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(28, 26)
    b.Position = UDim2.new(1, x, 0, 7)
    b.BackgroundColor3 = Theme.card
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.TextColor3 = Theme.text
    b.Text = text
    b.Parent = header
    corner(b, 8)
    b.MouseButton1Click:Connect(function()
        local ok, err = pcall(onClick)
        if not ok then warn("[Aero] " .. tostring(err)) end
    end)
    return b
end

local minimizeBtn = headerButton("_", -70, function()
    main.Visible = false
    reopen.Visible = true
end)

local closeBtn = headerButton("x", -36, function()
    if destroyed then return end
    if destroy then
        destroy()
    end
end)

-- tab bar -----------------------------------------------------
local TAB_BAR_H = 46
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, TAB_BAR_H)
tabBar.Position = UDim2.new(0, 0, 1, -TAB_BAR_H)
tabBar.BackgroundColor3 = Theme.card
tabBar.BorderSizePixel = 0
tabBar.Parent = main

local tabBarLine = Instance.new("Frame")
tabBarLine.Size = UDim2.new(1, 0, 0, 1)
tabBarLine.BackgroundColor3 = Theme.line
tabBarLine.BorderSizePixel = 0
tabBarLine.Parent = tabBar

local content = Instance.new("Frame")
content.Size = UDim2.new(1, 0, 1, -(40 + TAB_BAR_H))
content.Position = UDim2.fromOffset(0, 40)
content.BackgroundTransparency = 1
content.Parent = main

local tabs = {}
local tabButtons = {}

local function newTab(id)
    local sf = Instance.new("ScrollingFrame")
    sf.Size = UDim2.new(1, 0, 1, 0)
    sf.BackgroundTransparency = 1
    sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 2
    sf.ScrollBarImageColor3 = Theme.line
    sf.CanvasSize = UDim2.new(0, 0, 0, 0)
    sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sf.ScrollingDirection = Enum.ScrollingDirection.Y
    sf.Visible = false
    sf.Parent = content

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 8)
    pad.PaddingBottom = UDim.new(0, 10)
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = sf

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = sf

    tabs[id] = sf
    return sf
end

local activeTab = nil
local refreshPlayerList

local function showTab(id)
    for name, frame in pairs(tabs) do
        frame.Visible = (name == id)
    end
    for name, btn in pairs(tabButtons) do
        local on = (name == id)
        btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Theme.dim
        btn.BackgroundColor3 = on and Theme.accent or Theme.cardHi
        btn.BackgroundTransparency = on and 0 or 0.55
    end
    activeTab = id
    if id == "players" and refreshPlayerList then
        pcall(refreshPlayerList)
    end
end

local tabDefs = {
    { "move", "MOVE" },
    { "aim", "AIM" },
    { "vis", "VIS" },
    { "players", "PLAY" },
}

for i, def in ipairs(tabDefs) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.25, -8, 0, 34)
    b.Position = UDim2.new((i - 1) * 0.25, 4, 0, 6)
    b.BackgroundColor3 = Theme.cardHi
    b.BackgroundTransparency = 0.55
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = 11
    b.TextColor3 = Theme.dim
    b.Text = def[2]
    b.Parent = tabBar
    corner(b, 9)
    b.MouseButton1Click:Connect(function()
        showTab(def[1])
    end)
    tabButtons[def[1]] = b
end

-- reopen pill -------------------------------------------------
local reopen = Instance.new("TextButton")
reopen.Size = UDim2.fromOffset(54, 54)
reopen.Position = UDim2.new(0, 12, 0, 90)
reopen.BackgroundColor3 = Theme.bg
reopen.BorderSizePixel = 0
reopen.Font = Enum.Font.GothamBold
reopen.TextSize = 12
reopen.TextColor3 = Theme.accent2
reopen.Text = "AERO"
reopen.Visible = false
reopen.Parent = gui
corner(reopen, 27)

local reopenStroke = Instance.new("UIStroke")
reopenStroke.Color = Theme.accent
reopenStroke.Thickness = 1
reopenStroke.Transparency = 0.3
reopenStroke.Parent = reopen

reopen.MouseButton1Click:Connect(function()
    main.Visible = true
    reopen.Visible = false
end)

-- drag --------------------------------------------------------
local dragging, dragStart, dragOrigin = false, nil, nil

header.InputBegan:Connect(function(input)
    if destroyed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        -- normalise to pure offset so the first drag does not jump
        local ap = main.AbsolutePosition
        local gp = gui.AbsolutePosition
        main.Position = UDim2.fromOffset(ap.X - gp.X, ap.Y - gp.Y)
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
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end

    local delta = input.Position - dragStart
    local nx = dragOrigin.X.Offset + delta.X
    local ny = dragOrigin.Y.Offset + delta.Y
    local sw = gui.AbsoluteSize.X
    local sh = gui.AbsoluteSize.Y
    nx = math.clamp(nx, -(PANEL_W - 80), sw - 80)
    ny = math.clamp(ny, -(PANEL_H - 90), sh - 90)
    main.Position = UDim2.new(0, nx, 0, ny)
end)

-- ============================================================
--  widgets
-- ============================================================
local uiRefreshers = {}
local uiOrder = 0

local function nextOrder()
    uiOrder = uiOrder + 1
    return uiOrder
end

local function syncUI()
    for _, f in ipairs(uiRefreshers) do
        pcall(f)
    end
end

local function card(parent, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = parent
    corner(row, 10)
    return row
end

local function label(parent, text, x, y, w, h, size, color, align)
    local l = Instance.new("TextLabel")
    l.Position = UDim2.fromOffset(x, y)
    l.Size = UDim2.new(1, -(x + 44), 0, h)
    if w then l.Size = UDim2.new(1, w, 0, h) end
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.GothamMedium
    l.TextSize = size or 12
    l.TextColor3 = color or Theme.text
    l.TextXAlignment = align or Enum.TextXAlignment.Left
    l.Text = text
    l.Parent = parent
    return l
end

local function makeSwitch(parent, text, get, set)
    local row = card(parent, 42)

    label(row, text, 12, 0, -60, 42, 13, Theme.text)
    local lbl = row:FindFirstChildOfClass("TextLabel")
    lbl.Size = UDim2.new(1, -70, 1, 0)
    lbl.TextYAlignment = Enum.TextYAlignment.Center

    local pill = Instance.new("Frame")
    pill.Size = UDim2.fromOffset(38, 21)
    pill.Position = UDim2.new(1, -50, 0.5, -10)
    pill.BackgroundColor3 = Theme.line
    pill.BorderSizePixel = 0
    pill.Parent = row
    corner(pill, 11)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(15, 15)
    knob.Position = UDim2.fromOffset(3, 3)
    knob.BackgroundColor3 = Color3.fromRGB(225, 225, 236)
    knob.BorderSizePixel = 0
    knob.Parent = pill
    corner(knob, 8)

    local hit = Instance.new("TextButton")
    hit.Size = UDim2.fromOffset(58, 42)
    hit.Position = UDim2.new(1, -58, 0, 0)
    hit.BackgroundTransparency = 1
    hit.Text = ""
    hit.Parent = row

    local function refresh()
        local on = get()
        pill.BackgroundColor3 = on and Theme.accent or Theme.line
        knob.Position = on and UDim2.fromOffset(20, 3) or UDim2.fromOffset(3, 3)
    end

    hit.MouseButton1Click:Connect(function()
        local ok, err = pcall(function() set(not get()) end)
        if not ok then warn("[Aero] " .. tostring(err)) end
        refresh()
    end)

    refresh()
    table.insert(uiRefreshers, refresh)
    return row
end

local activeSlider = nil

local function makeSlider(parent, text, minv, maxv, stepv, get, set, decimals)
    local row = card(parent, 46)

    local nameLbl = label(row, text, 12, 7, -70, 16, 12, Theme.dim)
    nameLbl.Size = UDim2.new(1, -80, 0, 16)

    local valueLbl = Instance.new("TextLabel")
    valueLbl.Position = UDim2.new(1, -70, 0, 7)
    valueLbl.Size = UDim2.fromOffset(58, 16)
    valueLbl.BackgroundTransparency = 1
    valueLbl.Font = Enum.Font.GothamBold
    valueLbl.TextSize = 12
    valueLbl.TextColor3 = Theme.accent2
    valueLbl.TextXAlignment = Enum.TextXAlignment.Right
    valueLbl.Parent = row

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -24, 0, 4)
    track.Position = UDim2.new(0, 12, 0, 33)
    track.BackgroundColor3 = Theme.line
    track.BorderSizePixel = 0
    track.Parent = row
    corner(track, 2)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = Theme.accent
    fill.BorderSizePixel = 0
    fill.Parent = track
    corner(fill, 2)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(12, 12)
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(0, 0, 0.5, 0)
    knob.BackgroundColor3 = Color3.fromRGB(240, 240, 250)
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 6)

    local hit = Instance.new("TextButton")
    hit.Size = UDim2.new(1, 0, 0, 24)
    hit.Position = UDim2.new(0, 0, 0, 22)
    hit.BackgroundTransparency = 1
    hit.Text = ""
    hit.Parent = row

    local function format(v)
        if decimals and decimals > 0 then
            return string.format("%." .. decimals .. "f", v)
        end
        return tostring(math.floor(v + 0.5))
    end

    local function paint()
        local v = get()
        local f = 0
        if maxv > minv then
            f = math.clamp((v - minv) / (maxv - minv), 0, 1)
        end
        fill.Size = UDim2.new(f, 0, 1, 0)
        knob.Position = UDim2.new(f, 0, 0.5, 0)
        valueLbl.Text = format(v)
    end

    local function valueFromX(x)
        local ap = hit.AbsolutePosition
        local asz = hit.AbsoluteSize
        local f = math.clamp((x - ap.X) / math.max(asz.X, 1), 0, 1)
        local raw = minv + (maxv - minv) * f
        local v = math.floor((raw + stepv * 0.5) / stepv) * stepv
        v = math.clamp(v, minv, maxv)
        v = math.floor(v * 1000 + 0.5) / 1000
        set(v)
        paint()
    end

    hit.InputBegan:Connect(function(input)
        if destroyed then return end
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            activeSlider = valueFromX
            valueFromX(input.Position.X)
        end
    end)

    paint()
    table.insert(uiRefreshers, paint)
    return row
end

local function makeHold(parent, text, onDown, onUp, layoutOrder)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 1, 0)
    b.BackgroundColor3 = Theme.card
    b.BorderSizePixel = 0
    b.AutoButtonColor = false
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.TextColor3 = Theme.text
    b.Text = text
    if layoutOrder then b.LayoutOrder = layoutOrder end
    b.Parent = parent
    corner(b, 8)

    local function primary(input)
        return input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1
    end

    b.InputBegan:Connect(function(input)
        if destroyed or not primary(input) then return end
        b.BackgroundColor3 = Theme.accent
        onDown()
    end)

    b.InputEnded:Connect(function(input)
        if not primary(input) then return end
        b.BackgroundColor3 = Theme.card
        onUp()
    end)

    return b
end

local function makeButton(parent, text, onClick, accent)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 34)
    b.BackgroundColor3 = accent and Theme.accent or Theme.card
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.TextColor3 = accent and Color3.fromRGB(255, 255, 255) or Theme.text
    b.Text = text
    b.Parent = parent
    corner(b, 9)
    b.MouseButton1Click:Connect(function()
        local ok, err = pcall(onClick, b)
        if not ok then warn("[Aero] " .. tostring(err)) end
    end)
    return b
end

-- ============================================================
--  tabs content
-- ============================================================
local moveTab = newTab("move")
makeSlider(moveTab, "WalkSpeed", 8, 400, 4, function()
    return state.speed
end, function(v)
    state.speed = v
    applySpeed()
end, 0)

makeSlider(moveTab, "JumpPower", 0, 500, 10, function()
    return state.jump
end, function(v)
    state.jump = v
    applyJump()
end, 0)

makeSwitch(moveTab, "Lock stats", function()
    return state.lockStats
end, function(v)
    state.lockStats = v
    if v then applyStats() end
end)

makeSwitch(moveTab, "Infinite jump", function()
    return state.infJump
end, function(v)
    state.infJump = v
end)

makeSwitch(moveTab, "Noclip", function()
    return state.noclip
end, function(v)
    state.noclip = v
    if not v then noclipOff() end
end)

makeSwitch(moveTab, "Fly", function()
    return state.fly
end, function(v)
    setFly(v)
end)

local pad = Instance.new("Frame")
pad.Size = UDim2.new(1, 0, 0, 88)
pad.BackgroundTransparency = 1
pad.LayoutOrder = nextOrder()
pad.Parent = moveTab

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

makeSlider(moveTab, "Fly speed", 10, 400, 5, function()
    return state.flySpeed
end, function(v)
    state.flySpeed = v
end, 0)

local aimTab = newTab("aim")

makeSwitch(aimTab, "Aimbot", function()
    return state.aimbot
end, function(v)
    state.aimbot = v
end)

makeSlider(aimTab, "FOV", 20, 600, 10, function()
    return state.fov
end, function(v)
    state.fov = v
end, 0)

makeSlider(aimTab, "Smoothing", 0, 0.95, 0.05, function()
    return state.smooth
end, function(v)
    state.smooth = v
end, 2)

makeSwitch(aimTab, "Team check", function()
    return state.teamCheck
end, function(v)
    state.teamCheck = v
end)

makeSwitch(aimTab, "Prediction", function()
    return state.predict
end, function(v)
    state.predict = v
end)

local visTab = newTab("vis")

makeSwitch(visTab, "ESP", function()
    return state.esp
end, function(v)
    state.esp = v
    if not v then clearESP() end
end)

makeSwitch(visTab, "Fullbright", function()
    return state.fullbright
end, function(v)
    setFullbright(v)
end)

local playersTab = newTab("players")
local playerBox = Instance.new("Frame")
playerBox.Size = UDim2.new(1, 0, 0, 0)
playerBox.AutomaticSize = Enum.AutomaticSize.Y
playerBox.BackgroundTransparency = 1
playerBox.LayoutOrder = 1
playerBox.Parent = playersTab

local playerLayout = Instance.new("UIListLayout")
playerLayout.Padding = UDim.new(0, 4)
playerLayout.SortOrder = Enum.SortOrder.LayoutOrder
playerLayout.Parent = playerBox

local statusLbl = Instance.new("TextLabel")statusLbl.Size = UDim2.new(1, 0, 0, 14)
statusLbl.BackgroundTransparency = 1
statusLbl.Font = Enum.Font.GothamMedium
statusLbl.TextSize = 10
statusLbl.TextColor3 = Theme.dim
statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.LayoutOrder = 2
statusLbl.Text = ""
statusLbl.Parent = playersTab

refreshPlayerList = function()
    for _, child in ipairs(playerBox:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end

    local n = 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            n = n + 1
            local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
            local hp = hum and (math.floor(hum.Health) .. " hp") or "loading"

            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, 0, 0, 32)
            row.BackgroundColor3 = Theme.card
            row.BorderSizePixel = 0
            row.AutoButtonColor = true
            row.Font = Enum.Font.GothamMedium
            row.TextSize = 12
            row.TextColor3 = Theme.text
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Text = "  " .. plr.Name .. "   " .. hp
            row.LayoutOrder = n
            row.Parent = playerBox
            corner(row, 8)

            row.MouseButton1Click:Connect(function()
                local ok, err = pcall(safeTeleport, plr)
                if not ok then
                    statusLbl.Text = "teleport failed: " .. tostring(err)
                elseif err then
                    statusLbl.Text = "teleport failed: " .. tostring(err)
                else
                    statusLbl.Text = "teleported to " .. plr.Name
                end
            end)
        end
    end

    if n == 0 then
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 24)
        l.BackgroundTransparency = 1
        l.Font = Enum.Font.GothamMedium
        l.TextSize = 12
        l.TextColor3 = Theme.dim
        l.Text = "no players"
        l.Parent = playerBox
    end
end

local refreshBtn = makeButton(playersTab, "Refresh list", refreshPlayerList, false)
refreshBtn.LayoutOrder = 3
refreshPlayerList()

showTab("move")

-- ============================================================
--  runtime
-- ============================================================
local fovCircle = nil
if DrawingLib then
    local ok, circle = pcall(function()
        local c = DrawingLib.new("Circle")
        c.Thickness = 1
        c.Filled = false
        c.Transparency = 0.6
        c.Color = Color3.fromRGB(124, 92, 255)
        c.Visible = false
        return c
    end)
    if ok then fovCircle = circle end
end

local function frameStep(dt)
    if destroyed then return end

    if state.aimbot then
        aimStep(dt)
    end
    if state.fly then
        flyStep()
    end
    if state.esp then
        espStep()
    end

    if fovCircle then
        local cam = workspace.CurrentCamera
        if state.aimbot and cam then
            fovCircle.Position = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
            fovCircle.Radius = state.fov
            fovCircle.Visible = true
        else
            fovCircle.Visible = false
        end
    end
end

local bound = pcall(function()
    RunService:UnbindFromRenderStep("AeroFrame")
    RunService:BindToRenderStep("AeroFrame", Enum.RenderPriority.Camera.Value + 1, frameStep)
end)
if not bound then
    RunService.RenderStepped:Connect(frameStep)
end

local sliderConn = UserInputService.InputChanged:Connect(function(input)
    if destroyed or not activeSlider then return end
    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseMovement then
        activeSlider(input.Position.X)
    end
end)

local sliderEndConn = UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then
        activeSlider = nil
    end
end)

-- if a finger lifts outside the pad the button can miss InputEnded:
-- the pad also carries an explicit stop cell ("x") for that case

local jumpConn = UserInputService.JumpRequest:Connect(function()
    if destroyed or not state.infJump then return end
    local h = getHum()
    if h and h.Health > 0 then
        h:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

local charConn = LP.CharacterAdded:Connect(function()
    task.wait(0.6)
    if destroyed then return end
    applyStats()
    clearFlyInput()
    if state.fly then
        setFly(true)
    end
    if state.noclip then
        noclipSaved = {}
    end
    if state.esp then
        clearESP()
    end
end)

local function playerListConn()
    return Players.PlayerAdded:Connect(function()
        if not destroyed and activeTab == "players" then
            pcall(refreshPlayerList)
        end
    end)
end

local addedConn = playerListConn()
local removedConn = Players.PlayerRemoving:Connect(function()
    if not destroyed and activeTab == "players" then
        pcall(refreshPlayerList)
    end
end)

-- stats watchdog (only when locked)
task.spawn(function()
    while not destroyed do
        if state.lockStats then
            local h = getHum()
            if h and h.Health > 0 then
                if h.WalkSpeed ~= state.speed then h.WalkSpeed = state.speed end
                if h.UseJumpPower ~= true then
                    pcall(function() h.UseJumpPower = true end)
                end
                if h.JumpPower ~= state.jump then h.JumpPower = state.jump end
            end
        end
        task.wait(0.4)
    end
end)

-- noclip / esp watchdog
task.spawn(function()
    while not destroyed do
        if state.noclip then
            pcall(noclipOn)
        elseif next(noclipSaved) then
            noclipOff()
        end
        if not state.esp and next(espItems) then
            for _, item in pairs(espItems) do hideItem(item) end
        end
        task.wait(0.15)
    end
end)

-- ============================================================
--  cleanup
-- ============================================================
destroy = function()
    if destroyed then return end
    destroyed = true

    pcall(function() RunService:UnbindFromRenderStep("AeroFrame") end)
    for _, conn in ipairs({ dragConn, sliderConn, sliderEndConn, jumpConn, charConn, addedConn, removedConn }) do
        pcall(function() conn:Disconnect() end)
    end

    pcall(function() if state.fly then setFly(false) end end)
    pcall(clearESP)
    pcall(noclipOff)
    pcall(setFullbright, false)
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    pcall(function() gui:Destroy() end)
    state.esp = false
    state.noclip = false

    if getgenv then getgenv().__Aero = nil end
end

if getgenv then
    getgenv().__Aero = {
        destroy = destroy,
        state = state,
        teleport = safeTeleport,
    }
end

syncUI()
