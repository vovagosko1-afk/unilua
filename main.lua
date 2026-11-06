--[[
    Aero v2.1 - mobile executor UI for Delta (Android)
    Tabs: MOVE / AIM / VIS / PLAY
]]

if getgenv and getgenv().__Aero and getgenv().__Aero.destroy then
    pcall(getgenv().__Aero.destroy)
end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")
local TeleportService  = game:GetService("TeleportService")
local HttpService      = game:GetService("HttpService")
local Stats            = game:GetService("Stats")
local GuiService       = game:GetService("GuiService")

local LP = Players.LocalPlayer
if not LP then return end

local DrawingLib = nil
pcall(function()
    if typeof(Drawing) == "table" and Drawing.new then
        DrawingLib = Drawing
    end
end)

local state = {
    speed = 16, jump = 50, lockStats = false, infJump = false,
    noclip = false, fly = false, flySpeed = 60, clickTp = false,
    aimbot = false, fov = 150, smooth = 0.35, teamCheck = false,
    predict = true, triggerbot = false, triggerFov = 45,
    esp = false, espHealth = true, fullbright = false,
    stats = false, fpsBoost = false,
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

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
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
--  noclip
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
--  lighting / fullbright
-- ============================================================
local savedLighting = nil

local function setFullbright(on)
    state.fullbright = on
    if on then
        if not savedLighting then
            savedLighting = {
                Brightness = Lighting.Brightness,
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                ClockTime = Lighting.ClockTime,
                FogEnd = Lighting.FogEnd,
                GlobalShadows = Lighting.GlobalShadows,
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
--  fps booster
-- ============================================================
local boostState = nil

local function setFpsBoost(on)
    state.fpsBoost = on
    if on then
        if boostState then return end
        boostState = {
            effects = {},
            lighting = {
                GlobalShadows = Lighting.GlobalShadows,
                ShadowSoftness = Lighting.ShadowSoftness,
                EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
                EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
            },
        }

        pcall(function() settings().Rendering.QualityLevel = 1 end)
        Lighting.GlobalShadows = false
        Lighting.ShadowSoftness = 0
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0

        local ok, list = pcall(function() return workspace:GetDescendants() end)
        if ok then
            for _, inst in ipairs(list) do
                if inst:IsA("ParticleEmitter") or inst:IsA("Fire") or inst:IsA("Smoke")
                    or inst:IsA("Sparkles") or inst:IsA("Beam") or inst:IsA("Trail") then
                    if inst.Enabled then
                        boostState.effects[inst] = true
                        inst.Enabled = false
                    end
                end
            end
        end
    elseif boostState then
        for inst in pairs(boostState.effects) do
            if inst and inst.Parent then
                pcall(function() inst.Enabled = true end)
            end
        end
        for k, v in pairs(boostState.lighting) do
            pcall(function() Lighting[k] = v end)
        end
        pcall(function() settings().Rendering.QualityLevel = 3 end)
        boostState = nil
    end
end

-- ============================================================
--  teleport
-- ============================================================
local function teleportToPosition(pos)
    local myChar, myRoot = getChar(), getHRP()
    if not myChar or not myRoot then return false end

    myRoot.AssemblyLinearVelocity = Vector3.zero
    myRoot.AssemblyAngularVelocity = Vector3.zero
    myChar:PivotTo(CFrame.new(pos))

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

    teleportToPosition(dest)
    return true
end

-- ============================================================
--  server hop / rejoin
-- ============================================================
local function rejoin()
    if game.JobId == "" then return false, "no job id" end
    local ok = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
    end)
    if ok then return true end
    return false, "teleport failed"
end

local function serverHop()
    local placeId = game.PlaceId
    local url = "https://games.roproxy.com/v1/games/" .. placeId ..
        "/servers/Public?sortOrder=Asc&limit=100"

    local ok, body = pcall(function()
        return game:HttpGet(url, true)
    end)
    if not ok or type(body) ~= "string" then return false, "http failed" end

    local decoded, data = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if not decoded or type(data) ~= "table" or type(data.data) ~= "table" then
        return false, "bad response"
    end

    local pool = {}
    for _, srv in ipairs(data.data) do
        if type(srv) == "table" and srv.id and srv.id ~= game.JobId then
            if (tonumber(srv.playing) or 0) < (tonumber(srv.maxPlayers) or 0) then
                table.insert(pool, srv.id)
            end
        end
    end

    if #pool == 0 then return false, "no free servers" end

    local target = pool[math.random(1, #pool)]
    local ok2 = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId, target, LP)
    end)
    if ok2 then return true end
    return false, "teleport failed"
end

-- ============================================================
--  aim / trigger
-- ============================================================
local function pickTarget(fov)
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    fov = fov or state.fov

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
                    if d <= fov and d < bestDist then
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
    cam.CFrame = cam.CFrame:Lerp(goal, clamp(dt * speed, 0, 1))
end

local lastTrigger = 0

local function fireWeapon()
    if type(mouse1click) == "function" then
        pcall(mouse1click)
        return true
    end
    if type(mouse1press) == "function" and type(mouse1release) == "function" then
        pcall(mouse1press)
        pcall(mouse1release)
        return true
    end
    local c = getChar()
    local tool = c and c:FindFirstChildOfClass("Tool")
    if tool then
        local ok = pcall(function() tool:Activate() end)
        if ok then return true end
    end
    return false
end

local function triggerStep()
    if not state.triggerbot then return end
    local now = os.clock()
    if now - lastTrigger < 0.1 then return end
    if pickTarget(state.triggerFov) then
        lastTrigger = now
        fireWeapon()
    end
end

-- ============================================================
--  ESP
-- ============================================================
local espItems = {}
local espFallback = {}

local function hideItem(item)
    if not item then return end
    item.box.Visible = false
    item.name.Visible = false
    item.info.Visible = false
    item.hpBg.Visible = false
    item.hp.Visible = false
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

    item.hpBg = DrawingLib.new("Square")
    item.hpBg.Filled = true
    item.hpBg.Color = Color3.fromRGB(12, 12, 16)
    item.hpBg.Transparency = 0.35
    item.hpBg.Visible = false

    item.hp = DrawingLib.new("Square")
    item.hp.Filled = true
    item.hp.Visible = false

    return item
end

local function removeItem(item)
    if not item then return end
    pcall(function() item.box:Remove() end)
    pcall(function() item.name:Remove() end)
    pcall(function() item.info:Remove() end)
    pcall(function() item.hpBg:Remove() end)
    pcall(function() item.hp:Remove() end)
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
    if plr.Team then return plr.Team.TeamColor.Color end
    return Color3.fromRGB(124, 92, 255)
end

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
                    if h < 6 then h = 6 end
                    local w = h * 0.55
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

                    if state.espHealth then
                        local maxHp = math.max(hum.MaxHealth, 1)
                        local frac = clamp(hum.Health / maxHp, 0, 1)
                        local barX = top.X - w * 0.5 - 7
                        item.hpBg.Position = Vector2.new(barX, top.Y)
                        item.hpBg.Size = Vector2.new(4, h)
                        item.hpBg.Visible = true
                        item.hp.Position = Vector2.new(barX, top.Y + h * (1 - frac))
                        item.hp.Size = Vector2.new(4, h * frac)
                        item.hp.Color = Color3.fromRGB(235, 70, 70):Lerp(
                            Color3.fromRGB(80, 235, 130), frac)
                        item.hp.Visible = true
                    else
                        item.hpBg.Visible = false
                        item.hp.Visible = false
                    end
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
--  UI
-- ============================================================
local Theme = {
    bg = Color3.fromRGB(13, 13, 17),
    card = Color3.fromRGB(23, 23, 30),
    cardHi = Color3.fromRGB(29, 29, 38),
    line = Color3.fromRGB(42, 42, 55),
    text = Color3.fromRGB(234, 234, 244),
    dim = Color3.fromRGB(138, 138, 160),
    accent = Color3.fromRGB(124, 92, 255),
    accent2 = Color3.fromRGB(86, 200, 255),
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

local PANEL_W = clamp(math.floor(vp.X * 0.52), 258, 340)
local PANEL_H = clamp(math.floor(vp.Y * 0.62), 320, 480)
local TAB_BAR_H = 46

local main = Instance.new("Frame")
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
brand.Size = UDim2.new(1, -130, 1, 0)
brand.Position = UDim2.fromOffset(28, 0)
brand.BackgroundTransparency = 1
brand.Font = Enum.Font.GothamBold
brand.TextSize = 15
brand.TextColor3 = Theme.text
brand.TextXAlignment = Enum.TextXAlignment.Left
brand.Text = "AERO"
brand.Parent = header

local brandTag = Instance.new("TextLabel")
brandTag.Size = UDim2.new(1, -130, 1, 0)
brandTag.Position = UDim2.fromOffset(78, 0)
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

headerButton("_", -70, function()
    main.Visible = false
end)

headerButton("x", -36, function()
    if destroy then destroy() end
end)

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
local activeTab = nil
local refreshPlayerList

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

-- floating toggle
local reopen = Instance.new("TextButton")
reopen.Size = UDim2.fromOffset(50, 50)
reopen.Position = UDim2.new(0, 10, 0, 96)
reopen.BackgroundColor3 = Theme.bg
reopen.BorderSizePixel = 0
reopen.Font = Enum.Font.GothamBold
reopen.TextSize = 13
reopen.TextColor3 = Theme.accent2
reopen.Text = "A"
reopen.Parent = gui
corner(reopen, 25)

local reopenStroke = Instance.new("UIStroke")
reopenStroke.Color = Theme.accent
reopenStroke.Thickness = 1
reopenStroke.Transparency = 0.3
reopenStroke.Parent = reopen

-- ============================================================
--  drag
-- ============================================================
local dragging, dragStart, dragOrigin = false, nil, nil
local btnDragging, btnStart, btnOrigin, btnMoved = false, nil, nil, 0

local function isPrimaryInput(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

header.InputBegan:Connect(function(input)
    if destroyed or not isPrimaryInput(input) then return end
    dragging = true
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
end)

reopen.InputBegan:Connect(function(input)
    if destroyed or not isPrimaryInput(input) then return end
    btnDragging = true
    btnMoved = 0
    btnStart = input.Position
    local ap = reopen.AbsolutePosition
    local gp = gui.AbsolutePosition
    reopen.Position = UDim2.fromOffset(ap.X - gp.X, ap.Y - gp.Y)
    btnOrigin = reopen.Position
    input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End then
            btnDragging = false
        end
    end)
end)

reopen.InputEnded:Connect(function(input)
    if destroyed or not isPrimaryInput(input) then return end
    btnDragging = false
    if btnMoved < 8 then
        main.Visible = not main.Visible
    end
end)

local dragConn = UserInputService.InputChanged:Connect(function(input)
    if destroyed then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end

    local sw = gui.AbsoluteSize.X
    local sh = gui.AbsoluteSize.Y

    if btnDragging and btnStart then
        local d = input.Position - btnStart
        btnMoved = math.max(btnMoved, math.abs(d.X) + math.abs(d.Y))
        local nx = clamp(btnOrigin.X.Offset + d.X, 0, sw - 50)
        local ny = clamp(btnOrigin.Y.Offset + d.Y, 0, sh - 50)
        reopen.Position = UDim2.new(0, nx, 0, ny)
        return
    end

    if not dragging then return end

    local delta = input.Position - dragStart
    local nx = clamp(dragOrigin.X.Offset + delta.X, -(PANEL_W - 80), sw - 80)
    local ny = clamp(dragOrigin.Y.Offset + delta.Y, -(PANEL_H - 90), sh - 90)
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

local function makeSwitch(parent, text, get, set)
    local row = card(parent, 42)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -70, 1, 0)
    lbl.Position = UDim2.fromOffset(12, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextColor3 = Theme.text
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = text
    lbl.Parent = row

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

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = UDim2.new(1, -80, 0, 16)
    nameLbl.Position = UDim2.fromOffset(12, 7)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Font = Enum.Font.GothamMedium
    nameLbl.TextSize = 12
    nameLbl.TextColor3 = Theme.dim
    nameLbl.TextXAlignment = Enum.TextXAlignment.Left
    nameLbl.Text = text
    nameLbl.Parent = row

    local valueLbl = Instance.new("TextLabel")
    valueLbl.Size = UDim2.fromOffset(58, 16)
    valueLbl.Position = UDim2.new(1, -70, 0, 7)
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
            f = clamp((v - minv) / (maxv - minv), 0, 1)
        end
        fill.Size = UDim2.new(f, 0, 1, 0)
        knob.Position = UDim2.new(f, 0, 0.5, 0)
        valueLbl.Text = format(v)
    end

    local function valueFromX(x)
        local ap = hit.AbsolutePosition
        local asz = hit.AbsoluteSize
        local f = clamp((x - ap.X) / math.max(asz.X, 1), 0, 1)
        local raw = minv + (maxv - minv) * f
        local v = math.floor((raw + stepv * 0.5) / stepv) * stepv
        v = clamp(v, minv, maxv)
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

local function makeButton(parent, text, onClick, accent)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 34)
    b.BackgroundColor3 = accent and Theme.accent or Theme.card
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.TextColor3 = accent and Color3.fromRGB(255, 255, 255) or Theme.text
    b.Text = text
    b.LayoutOrder = nextOrder()
    b.Parent = parent
    corner(b, 9)
    b.MouseButton1Click:Connect(function()
        local ok, err = pcall(onClick, b)
        if not ok then warn("[Aero] " .. tostring(err)) end
    end)
    return b
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

    b.InputBegan:Connect(function(input)
        if destroyed or not isPrimaryInput(input) then return end
        b.BackgroundColor3 = Theme.accent
        onDown()
    end)

    b.InputEnded:Connect(function(input)
        if not isPrimaryInput(input) then return end
        b.BackgroundColor3 = Theme.card
        onUp()
    end)

    return b
end

-- ============================================================
--  tabs
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

makeSwitch(moveTab, "Click TP", function()
    return state.clickTp
end, function(v)
    state.clickTp = v
end)

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

makeSwitch(aimTab, "Triggerbot", function()
    return state.triggerbot
end, function(v)
    state.triggerbot = v
end)

makeSlider(aimTab, "Trigger FOV", 5, 300, 5, function()
    return state.triggerFov
end, function(v)
    state.triggerFov = v
end, 0)

local visTab = newTab("vis")

makeSwitch(visTab, "ESP", function()
    return state.esp
end, function(v)
    state.esp = v
    if not v then clearESP() end
end)

makeSwitch(visTab, "ESP health bars", function()
    return state.espHealth
end, function(v)
    state.espHealth = v
end)

makeSwitch(visTab, "Fullbright", function()
    return state.fullbright
end, function(v)
    setFullbright(v)
end)

makeSwitch(visTab, "Stats overlay", function()
    return state.stats
end, function(v)
    state.stats = v
end)

makeSwitch(visTab, "FPS booster", function()
    return state.fpsBoost
end, function(v)
    setFpsBoost(v)
end)

local playersTab = newTab("players")

local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, 0, 0, 14)
statusLbl.BackgroundTransparency = 1
statusLbl.Font = Enum.Font.GothamMedium
statusLbl.TextSize = 10
statusLbl.TextColor3 = Theme.dim
statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.Text = ""
statusLbl.LayoutOrder = 2
statusLbl.Parent = playersTab

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
                local ok, reason = safeTeleport(plr)
                if ok then
                    statusLbl.Text = "teleported to " .. plr.Name
                else
                    statusLbl.Text = "teleport failed: " .. tostring(reason)
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

local rejoinBtn = makeButton(playersTab, "Rejoin server", function()
    local ok, err = rejoin()
    if ok then
        statusLbl.Text = "rejoining..."
    else
        statusLbl.Text = "rejoin failed: " .. tostring(err)
    end
end, false)
rejoinBtn.LayoutOrder = 3

local hopBtn = makeButton(playersTab, "Server hop", function()
    statusLbl.Text = "searching servers..."
    local ok, err = serverHop()
    if ok then
        statusLbl.Text = "hopping..."
    else
        statusLbl.Text = "hop failed: " .. tostring(err)
    end
end, false)
hopBtn.LayoutOrder = 4

local refreshBtn = makeButton(playersTab, "Refresh list", refreshPlayerList, false)
refreshBtn.LayoutOrder = 5

refreshPlayerList()
showTab("move")

-- ============================================================
--  stats overlay
-- ============================================================
local statsFrame = Instance.new("Frame")
statsFrame.Size = UDim2.fromOffset(186, 24)
statsFrame.AnchorPoint = Vector2.new(0.5, 0)
statsFrame.Position = UDim2.new(0.5, 0, 0, 10)
statsFrame.BackgroundColor3 = Theme.bg
statsFrame.BackgroundTransparency = 0.3
statsFrame.BorderSizePixel = 0
statsFrame.Visible = false
statsFrame.Parent = gui
corner(statsFrame, 12)

local statsStroke = Instance.new("UIStroke")
statsStroke.Color = Theme.line
statsStroke.Thickness = 1
statsStroke.Transparency = 0.35
statsStroke.Parent = statsFrame

local statsLabel = Instance.new("TextLabel")
statsLabel.Size = UDim2.new(1, 0, 1, 0)
statsLabel.BackgroundTransparency = 1
statsLabel.Font = Enum.Font.GothamBold
statsLabel.TextSize = 11
statsLabel.TextColor3 = Theme.text
statsLabel.Text = "FPS --   |   -- ms   |   -- MB"
statsLabel.Parent = statsFrame

local statFrames = 0
local statFps = 0
local statClock = os.clock()

local function readPing()
    local ok, v = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" then return math.floor(v) end
    return nil
end

local function readMemory()
    local ok, v = pcall(function()
        return Stats:GetTotalMemoryUsageMb()
    end)
    if ok and type(v) == "number" then return math.floor(v) end
    return nil
end

task.spawn(function()
    while not destroyed do
        local now = os.clock()
        if now - statClock >= 0.5 then
            statFps = math.floor(statFrames / (now - statClock) + 0.5)
            statFrames = 0
            statClock = now
        end

        if state.stats then
            local ping = readPing()
            local mem = readMemory()
            statsLabel.Text = string.format("FPS %d   |   %s ms   |   %s MB",
                statFps,
                ping and tostring(ping) or "--",
                mem and tostring(mem) or "--")
            statsLabel.TextColor3 = statFps < 30
                and Color3.fromRGB(255, 120, 120) or Theme.text
            statsFrame.Visible = true
        else
            statsFrame.Visible = false
        end

        task.wait(0.25)
    end
end)

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

    statFrames = statFrames + 1

    if state.aimbot then aimStep(dt) end
    if state.triggerbot then triggerStep() end
    if state.fly then flyStep() end
    if state.esp then espStep() end

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

local function isOverRect(x, y, obj)
    if not obj or not obj.Visible then return false end
    local ap = obj.AbsolutePosition
    local asz = obj.AbsoluteSize
    return x >= ap.X and x <= ap.X + asz.X and y >= ap.Y and y <= ap.Y + asz.Y
end

local clickTpConn = UserInputService.InputBegan:Connect(function(input, processed)
    if destroyed or not state.clickTp or processed then return end
    if input.UserInputType ~= Enum.UserInputType.Touch
        and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
        return
    end

    local x, y = input.Position.X, input.Position.Y
    if isOverRect(x, y, main) or isOverRect(x, y, reopen) then return end

    local cam = workspace.CurrentCamera
    if not cam then return end

    local inset = GuiService:GetGuiInset()
    local ray = cam:ViewportPointToRay(x - inset.X, y - inset.Y)
    local filter = {}
    local myChar = getChar()
    if myChar then table.insert(filter, myChar) end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = filter

    local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
    if hit then
        teleportToPosition(hit.Position + Vector3.new(0, 3, 0))
    end
end)

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
    if state.fly then setFly(true) end
    if state.noclip then noclipSaved = {} end
    if state.esp then clearESP() end
end)

local addedConn = Players.PlayerAdded:Connect(function()
    if not destroyed and activeTab == "players" then
        pcall(refreshPlayerList)
    end
end)

local removedConn = Players.PlayerRemoving:Connect(function()
    if not destroyed and activeTab == "players" then
        pcall(refreshPlayerList)
    end
end)

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
    for _, conn in ipairs({ dragConn, sliderConn, sliderEndConn, clickTpConn,
        jumpConn, charConn, addedConn, removedConn }) do
        pcall(function() conn:Disconnect() end)
    end

    pcall(function() if state.fly then setFly(false) end end)
    pcall(clearESP)
    pcall(noclipOff)
    pcall(setFullbright, false)
    pcall(setFpsBoost, false)
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
        rejoin = rejoin,
        serverHop = serverHop,
    }
end

syncUI()
