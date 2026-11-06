--[[
    Aero v3.1 - Orion UI edition + improved aimbot
    Tabs: MOVE / AIM / VIS / PLAY / WAY / SRV
    Orion source cascade: shlexware -> NoLag-id fork -> readfile("orion.lua")
    Improved aimbot: visibility check, target priority, hitbox select,
    gravity prediction, adaptive camera lerp, Scriptable guard.
]]

-- ============================================================
--  Orion loader (cascade)
-- ============================================================
local function loadOrion()
    local sources = {
    "https://raw.githubusercontent.com/jensonhirst/Orion/main/source",
    "https://raw.githubusercontent.com/OrionLibrary/Orion/main/source.lua",
    }

    -- 1. try remote URLs
    for _, url in ipairs(sources) do
        local ok, res = pcall(function()
            local src = game:HttpGet(url, true)
            if type(src) ~= "string" or #src < 2000 then
                error("bad source: " .. tostring(src and #src or 0) .. " bytes")
            end
            return loadstring(src)()
        end)
        if ok and type(res) == "table" then
            warn("[Aero] Orion loaded from " .. url)
            return res
        else
            warn("[Aero] Orion source failed: " .. url .. " -> " .. tostring(res))
        end
    end

    -- 2. try local file
    if type(readfile) == "function" then
        local ok, res = pcall(function()
            local src = readfile("orion.lua")
            if type(src) ~= "string" or #src < 2000 then
                error("local orion.lua missing or too small")
            end
            return loadstring(src)()
        end)
        if ok and type(res) == "table" then
            warn("[Aero] Orion loaded from local orion.lua")
            return res
        else
            warn("[Aero] local Orion failed: " .. tostring(res))
        end
    end

    return nil
end

local OrionLib = loadOrion()
if not OrionLib then
    warn("[Aero] could not load Orion. Put orion.lua next to the script, or replace the URL.")
    return
end

-- ============================================================
--  services
-- ============================================================
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
    local ok, v = pcall(function() return Drawing.new end)
    if ok and type(v) == "function" then DrawingLib = Drawing end
end)

-- ============================================================
--  state
-- ============================================================
local state = {
    speed = 16, jump = 50, lockStats = false, infJump = false,
    noclip = false, fly = false, flySpeed = 60, clickTp = false,
    aimbot = false, fov = 150, smooth = 0.35, teamCheck = false,
    predict = true, triggerbot = false, triggerFov = 45,
    esp = false, espHealth = true, fullbright = false,
    stats = false, fpsBoost = false, bhop = false,
    spin = false, spinSpeed = 8, theme = "violet",
    -- aimbot improvements
    visibleCheck = false,
    targetMode = "closest",   -- closest | lowhp | threat
    hitbox = "head",          -- head | root | torso
    aimPing = 0.12,
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
--  noclip (per-part saved state, periodic pass, HRP excluded)
-- ============================================================
local noclipSaved = {}

local function noclipRestore()
    for part, original in pairs(noclipSaved) do
        if part and part.Parent and part:IsA("BasePart") then
            pcall(function() part.CanCollide = original end)
        end
    end
    noclipSaved = {}
end

local function noclipPass()
    local c = getChar()
    if not c then noclipRestore() return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
            if noclipSaved[p] == nil then
                noclipSaved[p] = p.CanCollide
            end
            if p.CanCollide then
                pcall(function() p.CanCollide = false end)
            end
        end
    end
end

local function setNoclip(on)
    state.noclip = on
    if on then
        noclipPass()
        OrionLib:MakeNotification({ Name = "Noclip", Content = "enabled", Time = 3 })
    else
        noclipRestore()
        OrionLib:MakeNotification({ Name = "Noclip", Content = "disabled", Time = 3 })
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
        OrionLib:MakeNotification({ Name = "Fly", Content = "enabled", Time = 3 })
    else
        if flyBV then
            pcall(function() flyBV:Destroy() end)
            flyBV = nil
        end
        local h = getHum()
        if h then h.PlatformStand = false end
        clearFlyInput()
        OrionLib:MakeNotification({ Name = "Fly", Content = "disabled", Time = 3 })
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
--  bhop
-- ============================================================
local bhopLast = 0
local bhopConn = nil
local function bhopStep()
    if not state.bhop then return end
    local h = getHum()
    if not h or h.Health <= 0 then return end
    if h:GetState() == Enum.HumanoidStateType.Freefall
        or h:GetState() == Enum.HumanoidStateType.Jumping then return end
    local now = os.clock()
    if now - bhopLast < 0.05 then return end
    bhopLast = now
    pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end)
end
local function setBhop(on)
    state.bhop = on
    if on and not bhopConn then
        bhopConn = RunService.Heartbeat:Connect(function()
            if destroyed then return end
            bhopStep()
        end)
        OrionLib:MakeNotification({ Name = "BHop", Content = "enabled", Time = 3 })
    elseif not on and bhopConn then
        pcall(function() bhopConn:Disconnect() end)
        bhopConn = nil
        OrionLib:MakeNotification({ Name = "BHop", Content = "disabled", Time = 3 })
    end
end

-- ============================================================
--  spinbot
-- ============================================================
local spinAngle = 0
local function spinStep(dt)
    if not state.spin then return end
    local root = getHRP()
    local h = getHum()
    if not root or not h or h.Health <= 0 then return end
    spinAngle = (spinAngle + math.rad(state.spinSpeed) * dt * 60) % (math.pi * 2)
    local pos = root.Position
    local look = Vector3.new(math.sin(spinAngle), 0, math.cos(spinAngle))
    root.CFrame = CFrame.new(pos, pos + look)
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
        local ql = nil
        pcall(function() ql = settings().Rendering.QualityLevel end)
        boostState = {
            effects = {},
            lighting = {
                GlobalShadows = Lighting.GlobalShadows,
                ShadowSoftness = Lighting.ShadowSoftness,
                EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
                EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
            },
            quality = ql,
        }
        if ql then pcall(function() settings().Rendering.QualityLevel = 1 end) end
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
        if boostState.quality then
            pcall(function() settings().Rendering.QualityLevel = boostState.quality end)
        end
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
    if hit then dest = hit.Position + Vector3.new(0, 3, 0)
    else dest = dest + Vector3.new(0, 1, 0) end
    teleportToPosition(dest)
    return true
end

-- ============================================================
--  waypoints
-- ============================================================
local waypoints = (getgenv and getgenv().__AeroWaypoints) or {}
if getgenv then getgenv().__AeroWaypoints = waypoints end
local function saveWaypoint()
    local root = getHRP()
    if not root then return nil, "no root" end
    local p = root.Position
    local name = string.format("%.0f,%.0f,%.0f", p.X, p.Y, p.Z)
    if waypoints[name] then return nil, "duplicate" end
    waypoints[name] = p
    return name
end
local function deleteWaypoint(name) waypoints[name] = nil end
local function tpWaypoint(name)
    local p = waypoints[name]
    if not p then return false, "missing" end
    return teleportToPosition(p)
end

-- ============================================================
--  rejoin / hop
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
    local ok, body = pcall(function() return game:HttpGet(url, true) end)
    if not ok or type(body) ~= "string" then return false, "http failed" end
    local decoded, data = pcall(function() return HttpService:JSONDecode(body) end)
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
--  AIMBOT (improved)
-- ============================================================
local aimState = { currentTarget = nil }

local function hitboxPart(char)
    if state.hitbox == "root" then
        return char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
    elseif state.hitbox == "torso" then
        return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
            or char:FindFirstChild("Head")
    end
    return char:FindFirstChild("Head")
end

local function isVisible(part, origin, filter)
    if not part then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = filter
    params.IgnoreWater = true
    local dir = part.Position - origin
    local hit = workspace:Raycast(origin, dir, params)
    return hit == nil or hit.Instance:IsDescendantOf(part.Parent)
end

local function predictPosition(part, ping)
    if not part then return nil end
    local v = part.AssemblyLinearVelocity
    local g = workspace.Gravity
    local t = (ping or 0.12) + 0.02
    local pos = part.Position + v * t
    -- vertical drop correction; small because bullets are hitscan in most games
    pos = pos + Vector3.new(0, -0.5 * g * t * t * 0.25, 0)
    return pos
end

local function scoreTarget(head, hum, cam, center, mode)
    local pos, onScreen = cam:WorldToViewportPoint(head.Position)
    if not onScreen then return math.huge end
    local dist = (Vector2.new(pos.X, pos.Y) - center).Magnitude
    if mode == "lowhp" then
        return hum.Health * 10 + dist * 0.05
    elseif mode == "threat" then
        return dist * 0.7 + hum.Health * 0.3
    end
    return dist
end

local function pickTarget(fov)
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    fov = fov or state.fov
    local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local myChar = getChar()
    local baseFilter = { myChar }
    local best, bestScore = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local c = plr.Character
            local head = c and c:FindFirstChild("Head")
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            local hb = c and hitboxPart(c)

            local skip = false
            if state.teamCheck and plr.Team ~= nil and plr.Team == LP.Team then
                skip = true
            end

            if head and hum and hb and hum.Health > 0 and not skip then
                local aimAt = hb.Position
                if state.predict then
                    aimAt = predictPosition(hb, state.aimPing)
                end

                local pos, onScreen = cam:WorldToViewportPoint(aimAt)
                if onScreen then
                    local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
                    if d <= fov then
                        local okVisible = true
                        if state.visibleCheck then
                            local filter = table.clone(baseFilter)
                            table.insert(filter, c)
                            okVisible = isVisible(hb, cam.CFrame.Position, filter)
                        end
                        if okVisible then
                            local score = scoreTarget(hb, hum, cam, center, state.targetMode)
                            if score < bestScore then
                                best, bestScore = aimAt, score
                            end
                        end
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
    -- don't fight server-controlled cameras
    if cam.CameraType == Enum.CameraType.Scriptable then return end

    local target = pickTarget()
    if not target then
        aimState.currentTarget = nil
        return
    end
    aimState.currentTarget = target

    local goal = CFrame.lookAt(cam.CFrame.Position, target)
    local speed = 26 - 24 * state.smooth

    -- adaptive: bigger correction for larger angular error
    local angle = math.acos(clamp(cam.CFrame.LookVector:Dot(goal.LookVector), -1, 1))
    local adaptive = clamp(angle * 2 + 1, 1, 4)
    local factor = clamp(dt * speed * adaptive, 0, 1)

    cam.CFrame = cam.CFrame:Lerp(goal, factor)
end

local lastTrigger = 0
local function fireWeapon()
    if type(mouse1click) == "function" then pcall(mouse1click) return true end
    if type(mouse1press) == "function" and type(mouse1release) == "function" then
        pcall(mouse1press); pcall(mouse1release); return true
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
local espHighlights = {}

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
    item.box.Thickness = 1; item.box.Filled = false
    item.box.Transparency = 1; item.box.Visible = false
    item.name = DrawingLib.new("Text")
    item.name.Size = 13; item.name.Center = true
    item.name.Outline = true; item.name.Visible = false
    item.info = DrawingLib.new("Text")
    item.info.Size = 12; item.info.Center = true
    item.info.Outline = true; item.info.Visible = false
    item.hpBg = DrawingLib.new("Square")
    item.hpBg.Filled = true; item.hpBg.Color = Color3.fromRGB(12, 12, 16)
    item.hpBg.Transparency = 0.35; item.hpBg.Visible = false
    item.hp = DrawingLib.new("Square")
    item.hp.Filled = true; item.hp.Visible = false
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
    for plr, item in pairs(espItems) do removeItem(item); espItems[plr] = nil end
    for plr, hl in pairs(espHighlights) do
        pcall(function() hl:Destroy() end); espHighlights[plr] = nil
    end
end
local function espColor(plr, hum)
    if hum and hum.Health <= 0 then return Color3.fromRGB(120, 120, 130) end
    if plr.Team then return plr.Team.TeamColor.Color end
    return Color3.fromRGB(124, 92, 255)
end
local function espStep()
    if not state.esp then
        if next(espItems) then
            for _, item in pairs(espItems) do hideItem(item) end
        end
        if next(espHighlights) then
            for _, hl in pairs(espHighlights) do
                if hl and hl.Parent then hl.Enabled = false end
            end
        end
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
                local color = espColor(plr, hum)
                local hl = espHighlights[plr]
                if not hl or not hl.Parent then
                    hl = Instance.new("Highlight")
                    hl.Name = "AeroHL"
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillTransparency = 0.65
                    hl.OutlineTransparency = 0
                    hl.Parent = c
                    espHighlights[plr] = hl
                end
                hl.Adornee = c
                hl.FillColor = color
                hl.OutlineColor = color
                hl.Enabled = true
                if DrawingLib then
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
    end
    for plr, item in pairs(espItems) do
        if not seen[plr] then hideItem(item) end
    end
    for plr, hl in pairs(espHighlights) do
        if not seen[plr] then
            if hl and hl.Parent then hl.Enabled = false end
        end
    end
end

-- ============================================================
--  Orion window
-- ============================================================
local Window = OrionLib:MakeWindow({
    Name = "Aero v3.1",
    HidePremium = false,
    SaveConfig = true,
    ConfigFolder = "AeroConfig",
    IntroEnabled = true,
    IntroText = "Aero",
    IntroIcon = "rbxassetid://4483345998",
    Icon = "rbxassetid://4483345998",
    ToggleKeybind = Enum.KeyCode.RightShift,
})

-- ============================================================
--  MOVE tab
-- ============================================================
local MoveTab = Window:MakeTab({ Name = "Move", Icon = "rbxassetid://4483345998", PremiumOnly = false })

MoveTab:AddSlider({
    Name = "WalkSpeed", Min = 8, Max = 400, Default = 16, Color = Color3.fromRGB(124, 92, 255),
    Increment = 4, ValueName = "speed",
    Callback = function(v) state.speed = v; applySpeed() end,
})
MoveTab:AddSlider({
    Name = "JumpPower", Min = 0, Max = 500, Default = 50, Color = Color3.fromRGB(124, 92, 255),
    Increment = 10, ValueName = "power",
    Callback = function(v) state.jump = v; applyJump() end,
})
MoveTab:AddToggle({
    Name = "Lock stats", Default = false,
    Callback = function(v) state.lockStats = v; if v then applyStats() end end,
})
MoveTab:AddToggle({
    Name = "Infinite jump", Default = false,
    Callback = function(v) state.infJump = v end,
})
MoveTab:AddToggle({
    Name = "BHop", Default = false,
    Callback = function(v) setBhop(v) end,
})
MoveTab:AddToggle({
    Name = "Noclip", Default = false,
    Callback = function(v) setNoclip(v) end,
})
MoveTab:AddToggle({
    Name = "Fly", Default = false,
    Callback = function(v) setFly(v) end,
})
MoveTab:AddSlider({
    Name = "Fly speed", Min = 10, Max = 400, Default = 60, Color = Color3.fromRGB(124, 92, 255),
    Increment = 5, ValueName = "speed",
    Callback = function(v) state.flySpeed = v end,
})
MoveTab:AddToggle({
    Name = "Click TP", Default = false,
    Callback = function(v) state.clickTp = v end,
})
MoveTab:AddButton({
    Name = "Fly up (tap)",
    Callback = function()
        flyInput.u = 1
        task.delay(0.15, function() flyInput.u = 0 end)
    end,
})
MoveTab:AddButton({
    Name = "Fly down (tap)",
    Callback = function()
        flyInput.d = 1
        task.delay(0.15, function() flyInput.d = 0 end)
    end,
})
MoveTab:AddButton({
    Name = "Fly clear input",
    Callback = function() clearFlyInput() end,
})

-- ============================================================
--  AIM tab
-- ============================================================
local AimTab = Window:MakeTab({ Name = "Aim", Icon = "rbxassetid://4483345998", PremiumOnly = false })
AimTab:AddToggle({
    Name = "Aimbot", Default = false,
    Callback = function(v) state.aimbot = v end,
})
AimTab:AddSlider({
    Name = "FOV", Min = 20, Max = 600, Default = 150, Color = Color3.fromRGB(124, 92, 255),
    Increment = 10, ValueName = "px",
    Callback = function(v) state.fov = v end,
})
AimTab:AddSlider({
    Name = "Smoothing", Min = 0, Max = 0.95, Default = 0.35, Color = Color3.fromRGB(124, 92, 255),
    Increment = 0.05, ValueName = "smooth",
    Callback = function(v) state.smooth = v end,
})
AimTab:AddToggle({
    Name = "Team check", Default = false,
    Callback = function(v) state.teamCheck = v end,
})
AimTab:AddToggle({
    Name = "Prediction", Default = true,
    Callback = function(v) state.predict = v end,
})
AimTab:AddToggle({
    Name = "Visibility check (anti-wall)",
    Default = false,
    Callback = function(v) state.visibleCheck = v end,
})
AimTab:AddDropdown({
    Name = "Target priority",
    Default = "closest",
    Options = { "closest", "lowhp", "threat" },
    Callback = function(v) state.targetMode = v end,
})
AimTab:AddDropdown({
    Name = "Hitbox",
    Default = "head",
    Options = { "head", "root", "torso" },
    Callback = function(v) state.hitbox = v end,
})
AimTab:AddSlider({
    Name = "Prediction ping (s)",
    Min = 0, Max = 0.5, Default = 0.12, Color = Color3.fromRGB(124, 92, 255),
    Increment = 0.01, ValueName = "s",
    Callback = function(v) state.aimPing = v end,
})
AimTab:AddToggle({
    Name = "Triggerbot", Default = false,
    Callback = function(v) state.triggerbot = v end,
})
AimTab:AddSlider({
    Name = "Trigger FOV", Min = 5, Max = 300, Default = 45, Color = Color3.fromRGB(124, 92, 255),
    Increment = 5, ValueName = "px",
    Callback = function(v) state.triggerFov = v end,
})

-- ============================================================
--  VIS tab
-- ============================================================
local VisTab = Window:MakeTab({ Name = "Visual", Icon = "rbxassetid://4483345998", PremiumOnly = false })
VisTab:AddToggle({
    Name = "ESP", Default = false,
    Callback = function(v) state.esp = v; if not v then clearESP() end end,
})
VisTab:AddToggle({
    Name = "ESP health bars", Default = true,
    Callback = function(v) state.espHealth = v end,
})
VisTab:AddToggle({
    Name = "Fullbright", Default = false,
    Callback = function(v) setFullbright(v) end,
})
VisTab:AddToggle({
    Name = "Stats overlay", Default = false,
    Callback = function(v) state.stats = v end,
})
VisTab:AddToggle({
    Name = "FPS booster", Default = false,
    Callback = function(v) setFpsBoost(v) end,
})
VisTab:AddToggle({
    Name = "Spinbot", Default = false,
    Callback = function(v)
        state.spin = v
        if not v then
            local root = getHRP()
            if root then
                root.CFrame = CFrame.new(root.Position, root.Position + Vector3.new(0, 0, -1))
            end
        end
    end,
})
VisTab:AddSlider({
    Name = "Spin speed", Min = 1, Max = 30, Default = 8, Color = Color3.fromRGB(124, 92, 255),
    Increment = 1, ValueName = "speed",
    Callback = function(v) state.spinSpeed = v end,
})
VisTab:AddDropdown({
    Name = "Theme",
    Default = "violet",
    Options = { "violet", "cyan", "green", "red" },
    Callback = function(selected)
        state.theme = selected
        OrionLib:MakeNotification({
            Name = "Theme",
            Content = "changed to " .. tostring(selected),
            Time = 3,
        })
    end,
})

-- ============================================================
--  PLAY tab
-- ============================================================
local PlayTab = Window:MakeTab({ Name = "Players", Icon = "rbxassetid://4483345998", PremiumOnly = false })

local function playerOptions()
    local o = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then table.insert(o, plr.Name) end
    end
    return o
end

local PlayerDropdown = PlayTab:AddDropdown({
    Name = "Player",
    Default = "",
    Options = playerOptions(),
    Callback = function(v) end,
})
PlayTab:AddButton({
    Name = "Teleport to selected player",
    Callback = function()
        local selected = PlayerDropdown.Value
        if not selected or selected == "" then
            OrionLib:MakeNotification({ Name = "TP", Content = "no player selected", Time = 3 })
            return
        end
        local plr = Players:FindFirstChild(selected)
        if not plr then
            OrionLib:MakeNotification({ Name = "TP", Content = "player not found", Time = 3 })
            return
        end
        local ok, reason = safeTeleport(plr)
        OrionLib:MakeNotification({
            Name = "TP",
            Content = ok and ("teleported to " .. selected) or tostring(reason),
            Time = 3,
        })
    end,
})
PlayTab:AddButton({
    Name = "Refresh player list",
    Callback = function()
        PlayerDropdown:Refresh(playerOptions())
        OrionLib:MakeNotification({ Name = "Players", Content = "refreshed", Time = 3 })
    end,
})
PlayTab:AddButton({
    Name = "Rejoin server",
    Callback = function()
        local ok, err = rejoin()
        OrionLib:MakeNotification({
            Name = "Rejoin", Content = ok and "rejoining..." or tostring(err), Time = 3,
        })
    end,
})
PlayTab:AddButton({
    Name = "Server hop",
    Callback = function()
        OrionLib:MakeNotification({ Name = "Hop", Content = "searching servers...", Time = 3 })
        local ok, err = serverHop()
        if not ok then
            OrionLib:MakeNotification({ Name = "Hop", Content = tostring(err), Time = 3 })
        end
    end,
})

-- ============================================================
--  WAY tab
-- ============================================================
local WayTab = Window:MakeTab({ Name = "Waypoints", Icon = "rbxassetid://4483345998", PremiumOnly = false })

local function waypointOptions()
    local o = {}
    for n in pairs(waypoints) do table.insert(o, n) end
    return o
end

local WaypointDropdown = WayTab:AddDropdown({
    Name = "Saved waypoints",
    Default = "",
    Options = waypointOptions(),
    Callback = function(v) end,
})
WayTab:AddButton({
    Name = "Save current position",
    Callback = function()
        local name, err = saveWaypoint()
        if name then
            WaypointDropdown:Refresh(waypointOptions())
            OrionLib:MakeNotification({ Name = "Waypoint", Content = "saved " .. name, Time = 3 })
        else
            OrionLib:MakeNotification({ Name = "Waypoint", Content = tostring(err), Time = 3 })
        end
    end,
})
WayTab:AddButton({
    Name = "Teleport to selected waypoint",
    Callback = function()
        local sel = WaypointDropdown.Value
        if not sel or sel == "" then
            OrionLib:MakeNotification({ Name = "Waypoint", Content = "nothing selected", Time = 3 })
            return
        end
        local ok, err = tpWaypoint(sel)
        OrionLib:MakeNotification({
            Name = "Waypoint",
            Content = ok and ("tp -> " .. sel) or tostring(err),
            Time = 3,
        })
    end,
})
WayTab:AddButton({
    Name = "Delete selected waypoint",
    Callback = function()
        local sel = WaypointDropdown.Value
        if not sel or sel == "" then return end
        deleteWaypoint(sel)
        WaypointDropdown:Refresh(waypointOptions())
        OrionLib:MakeNotification({ Name = "Waypoint", Content = "deleted " .. sel, Time = 3 })
    end,
})

-- ============================================================
--  SRV tab
-- ============================================================
local SrvTab = Window:MakeTab({ Name = "Server", Icon = "rbxassetid://4483345998", PremiumOnly = false })

local sessionStart = os.clock()
local function pingMs()
    local ok, v = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" and v >= 0 then return math.floor(v) end
    local ok2, v2 = pcall(function() return math.floor(LP:GetNetworkPing() * 1000) end)
    if ok2 and type(v2) == "number" then return v2 end
    return nil
end
local function readMemory()
    local ok, v = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
    if ok and type(v) == "number" then return math.floor(v) end
    local ok2, v2 = pcall(function() return math.floor(gcinfo() / 1024) end)
    if ok2 and type(v2) == "number" then return v2 end
    return nil
end

local srvParagraph = SrvTab:AddParagraph({ Title = "Server info", Content = "loading..." })

local function refreshServerInfo()
    local lines = {}
    table.insert(lines, "JobId: " .. (game.JobId ~= "" and game.JobId or "(private)"))
    table.insert(lines, "PlaceId: " .. tostring(game.PlaceId))
    table.insert(lines, "PlaceVersion: " .. tostring(game.PlaceVersion))
    table.insert(lines, "Players: " .. string.format("%d / %d", #Players:GetPlayers(), Players.MaxPlayers))
    local p = pingMs()
    table.insert(lines, "Ping: " .. (p and (tostring(p) .. " ms") or "--"))
    local m = readMemory()
    table.insert(lines, "Memory: " .. (m and (tostring(m) .. " MB") or "--"))
    local s = math.floor(os.clock() - sessionStart)
    table.insert(lines, "Session uptime: " .. string.format("%02d:%02d:%02d",
        math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60))
    table.insert(lines, "Streaming: " .. tostring(workspace.StreamingEnabled))
    table.insert(lines, "Gravity: " .. string.format("%.0f", workspace.Gravity))
    srvParagraph:Set(table.concat(lines, "\n"))
end
refreshServerInfo()

SrvTab:AddButton({
    Name = "Refresh server info",
    Callback = function()
        refreshServerInfo()
        OrionLib:MakeNotification({ Name = "Server", Content = "refreshed", Time = 3 })
    end,
})
SrvTab:AddButton({
    Name = "Copy JobId",
    Callback = function()
        local jid = game.JobId
        if jid == "" then
            OrionLib:MakeNotification({ Name = "JobId", Content = "private server", Time = 3 })
            return
        end
        local ok = false
        if type(setclipboard) == "function" then ok = pcall(setclipboard, jid) end
        if not ok and type(toclipboard) == "function" then ok = pcall(toclipboard, jid) end
        OrionLib:MakeNotification({
            Name = "JobId", Content = ok and "copied" or "clipboard unavailable", Time = 3,
        })
    end,
})

task.spawn(function()
    while not destroyed do
        pcall(refreshServerInfo)
        task.wait(2)
    end
end)

-- ============================================================
--  stats overlay (custom ScreenGui)
-- ============================================================
local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "AeroStats"
overlayGui.ResetOnSpawn = false
overlayGui.IgnoreGuiInset = true
overlayGui.DisplayOrder = 999
pcall(function()
    local hui = gethui and gethui()
    overlayGui.Parent = hui or LP:WaitForChild("PlayerGui")
end)

local statsFrame = Instance.new("Frame")
statsFrame.Size = UDim2.fromOffset(220, 24)
statsFrame.AnchorPoint = Vector2.new(0.5, 0)
statsFrame.Position = UDim2.new(0.5, 0, 0, 10)
statsFrame.BackgroundColor3 = Color3.fromRGB(13, 13, 17)
statsFrame.BackgroundTransparency = 0.3
statsFrame.BorderSizePixel = 0
statsFrame.Visible = false
statsFrame.Parent = overlayGui
local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 12); c.Parent = statsFrame
local st = Instance.new("UIStroke"); st.Color = Color3.fromRGB(42, 42, 55); st.Thickness = 1; st.Transparency = 0.35; st.Parent = statsFrame
local statsLabel = Instance.new("TextLabel")
statsLabel.Size = UDim2.new(1, 0, 1, 0); statsLabel.BackgroundTransparency = 1
statsLabel.Font = Enum.Font.GothamBold; statsLabel.TextSize = 11
statsLabel.TextColor3 = Color3.fromRGB(234, 234, 244)
statsLabel.Text = "FPS --   |   -- ms   |   -- MB"
statsLabel.Parent = statsFrame

local statFrames = 0
local statFps = 0
local statClock = os.clock()

-- ============================================================
--  FOV circle
-- ============================================================
local fovCircle = nil
if DrawingLib then
    local ok, circle = pcall(function()
        local c = DrawingLib.new("Circle")
        c.Thickness = 1; c.Filled = false; c.Transparency = 0.6
        c.Color = Color3.fromRGB(124, 92, 255); c.Visible = false
        return c
    end)
    if ok then fovCircle = circle end
end

-- ============================================================
--  runtime
-- ============================================================
local function frameStep(dt)
    if destroyed then return end
    statFrames = statFrames + 1

    if state.aimbot then aimStep(dt) end
    if state.triggerbot then triggerStep() end
    if state.fly then flyStep() end
    if state.spin then spinStep(dt) end
    if state.esp or next(espItems) or next(espHighlights) then espStep() end

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
if not bound then RunService.RenderStepped:Connect(frameStep) end

task.spawn(function()
    while not destroyed do
        local now = os.clock()
        if now - statClock >= 0.5 then
            statFps = math.floor(statFrames / (now - statClock) + 0.5)
            statFrames = 0
            statClock = now
        end
        if state.stats then
            local p = pingMs()
            local m = readMemory()
            statsLabel.Text = string.format("FPS %d   |   %s ms   |   %s MB",
                statFps, p and tostring(p) or "--", m and tostring(m) or "--")
            statsLabel.TextColor3 = statFps < 30 and Color3.fromRGB(255, 120, 120) or Color3.fromRGB(234, 234, 244)
            statsFrame.Visible = true
        else
            statsFrame.Visible = false
        end
        task.wait(0.25)
    end
end)

-- click TP
local function isOverOrion(x, y)
    local gui = GuiService:GetGuiObjectsAtPosition(x, y)
    if not gui then return false end
    for _, obj in ipairs(gui) do
        local root = obj
        while root and root.Parent and not root:IsA("ScreenGui") do
            root = root.Parent
        end
        if root and (root.Name == "Orion" or tostring(root.Name):lower():find("orion")) then
            return true
        end
    end
    return false
end

local clickTpConn = UserInputService.InputBegan:Connect(function(input, processed)
    if destroyed or not state.clickTp or processed then return end
    if input.UserInputType ~= Enum.UserInputType.Touch
        and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local x, y = input.Position.X, input.Position.Y
    if isOverOrion(x, y) then return end
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
    if hit then teleportToPosition(hit.Position + Vector3.new(0, 3, 0)) end
end)

-- infinite jump
local jumpConn = UserInputService.JumpRequest:Connect(function()
    if destroyed or not state.infJump then return end
    local h = getHum()
    if h and h.Health > 0 then h:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

-- character respawn
local charConn = LP.CharacterAdded:Connect(function()
    task.wait(0.6)
    if destroyed then return end
    applyStats()
    clearFlyInput()
    if state.fly then setFly(true) end
    if state.noclip then noclipSaved = {} end
    if state.esp then clearESP() end
end)

-- lock stats loop
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

-- noclip loop (fixed)
task.spawn(function()
    while not destroyed do
        if state.noclip then
            pcall(noclipPass)
        elseif next(noclipSaved) then
            pcall(noclipRestore)
        end
        task.wait(0.1)
    end
end)

-- ============================================================
--  init Orion
-- ============================================================
OrionLib:Init()

-- ============================================================
--  external API
-- ============================================================
if getgenv then
    getgenv().__Aero = {
        state = state,
        teleport = safeTeleport,
        rejoin = rejoin,
        serverHop = serverHop,
        waypoints = waypoints,
        saveWaypoint = saveWaypoint,
        refreshServerInfo = refreshServerInfo,
        setNoclip = setNoclip,
        setFly = setFly,
        setBhop = setBhop,
        setFpsBoost = setFpsBoost,
        setFullbright = setFullbright,
        getWindow = function() return Window end,
        getOrion = function() return OrionLib end,
        destroy = function()
            destroyed = true
            pcall(function() RunService:UnbindFromRenderStep("AeroFrame") end)
            pcall(function() if state.fly then setFly(false) end end)
            pcall(function() if state.bhop then setBhop(false) end end)
            pcall(clearESP)
            pcall(noclipRestore)
            pcall(setFullbright, false)
            pcall(setFpsBoost, false)
            if fovCircle then pcall(function() fovCircle:Remove() end) end
            pcall(function() overlayGui:Destroy() end)
            pcall(function() OrionLib:Destroy() end)
            getgenv().__Aero = nil
        end,
    }
end
