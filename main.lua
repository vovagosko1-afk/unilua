--[[
    Aero v2.8.2 - Legacy Delta support
    - Replaced task.spawn/wait with coroutine/wait for old executors.
    - Replaced gethui with direct PlayerGui.
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
local TweenService     = game:GetService("TweenService")
local SoundService     = game:GetService("SoundService")

local LP = Players.LocalPlayer
if not LP then return end

-- Safe function wrappers
local function safeReadFile(path)
    if type(readfile) == "function" then
        local ok, res = pcall(readfile, path)
        if ok then return res end
    end
    return nil
end

local function safeWriteFile(path, content)
    if type(writefile) == "function" then
        local ok, res = pcall(writefile, path, content)
        if ok then return true end
    end
    return false
end

-- Replaced gethui with PlayerGui
local function getGuiParent()
    return LP:WaitForChild("PlayerGui")
end

local DrawingLib = nil
pcall(function()
    local ok, v = pcall(function() return Drawing.new end)
    if ok and type(v) == "function" then DrawingLib = Drawing end
end)

local state = {
    speed = 16, jump = 50, lockStats = false, infJump = false,
    fly = false, flySpeed = 60, clickTp = false,
    aimbot = false, fov = 70, smooth = 0.35, teamCheck = false,
    predict = true, triggerbot = false, triggerFov = 45,
    esp = false, espHealth = true, fullbright = false,
    stats = false, fpsBoost = false, bhop = false,
    spin = false, spinSpeed = 8, theme = "violet", fovColor = "theme",
    visibleCheck = false, targetMode = "closest", hitbox = "head", aimPing = 0.05,
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
    local h = getHum(); if h then h.WalkSpeed = state.speed end
end
local function applyJump()
    local h = getHum(); if not h then return end
    if h.UseJumpPower ~= true then pcall(function() h.UseJumpPower = true end) end
    h.JumpPower = state.jump
end
local function applyStats() applySpeed(); applyJump() end

-- ============================================================
--  fly
-- ============================================================
local flyBV = nil
local flyInput = { f = 0, b = 0, l = 0, r = 0, u = 0, d = 0 }
local function clearFlyInput() for k in pairs(flyInput) do flyInput[k] = 0 end end
local function ensureFlyBody()
    local root = getHRP(); if not root then return end
    if flyBV and flyBV.Parent ~= root then pcall(function() flyBV:Destroy() end); flyBV = nil end
    if not flyBV then
        local bv = Instance.new("BodyVelocity")
        bv.Name = "AeroFly"; bv.MaxForce = Vector3.new(1e6, 1e6, 1e6); bv.Velocity = Vector3.zero
        bv.Parent = root; flyBV = bv
    end
    local h = getHum(); if h and h.Health > 0 then h.PlatformStand = true end
end
local function setFly(on)
    state.fly = on
    if on then ensureFlyBody()
    else
        if flyBV then pcall(function() flyBV:Destroy() end); flyBV = nil end
        local h = getHum(); if h then h.PlatformStand = false end
        clearFlyInput()
    end
end
local function flyStep()
    if not state.fly then return end
    local h = getHum(); if not h or h.Health <= 0 or not getHRP() then return end
    ensureFlyBody()
    local cam = workspace.CurrentCamera; if not cam or not flyBV then return end
    local look = cam.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude < 1e-3 then flat = Vector3.new(0, 0, -1) end
    flat = flat.Unit
    local right = Vector3.new(-flat.Z, 0, flat.X)
    local move = flat * (flyInput.f - flyInput.b) + right * (flyInput.r - flyInput.l) + Vector3.new(0, flyInput.u - flyInput.d, 0)
    if move.Magnitude > 1e-3 then flyBV.Velocity = move.Unit * state.flySpeed
    else flyBV.Velocity = Vector3.zero end
end

-- ============================================================
--  bhop
-- ============================================================
local bhopState = { last = 0 }
local bhopConn = nil
local function bhopStep()
    if not state.bhop then return end
    local h = getHum(); if not h or h.Health <= 0 then return end
    if h:GetState() == Enum.HumanoidStateType.Freefall or h:GetState() == Enum.HumanoidStateType.Jumping then return end
    local now = os.clock(); if now - bhopState.last < 0.05 then return end
    bhopState.last = now
    pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end)
end
local function setBhop(on)
    state.bhop = on
    if on and not bhopConn then
        bhopConn = RunService.Heartbeat:Connect(function() if destroyed then return end; bhopStep() end)
    elseif not on and bhopConn then
        pcall(function() bhopConn:Disconnect() end); bhopConn = nil
    end
end

-- ============================================================
--  spinbot
-- ============================================================
local spinAngle = 0
local function spinStep(dt)
    if not state.spin then return end
    local root, h = getHRP(), getHum()
    if not root or not h or h.Health <= 0 then return end
    spinAngle = (spinAngle + math.rad(state.spinSpeed) * dt * 60) % (math.pi * 2)
    root.CFrame = CFrame.new(root.Position, root.Position + Vector3.new(math.sin(spinAngle), 0, math.cos(spinAngle)))
end

-- ============================================================
--  lighting / fullbright
-- ============================================================
local savedLighting = nil
local function setFullbright(on)
    state.fullbright = on
    if on then
        if not savedLighting then
            savedLighting = { Brightness = Lighting.Brightness, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows }
        end
        Lighting.Brightness = 3; Lighting.Ambient = Color3.fromRGB(150, 150, 150); Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
        Lighting.ClockTime = 14; Lighting.FogEnd = 1e6; Lighting.GlobalShadows = false
    elseif savedLighting then
        for k, v in pairs(savedLighting) do pcall(function() Lighting[k] = v end) end
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
        local ql = nil; pcall(function() ql = settings().Rendering.QualityLevel end)
        boostState = {
            quality = ql,
            lighting = { GlobalShadows = Lighting.GlobalShadows, ShadowSoftness = Lighting.ShadowSoftness, EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale, EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale, FogEnd = Lighting.FogEnd },
            destroyed = {}, hidden = {}
        }
        if ql then pcall(function() settings().Rendering.QualityLevel = 1 end) end
        pcall(function() settings().Rendering.MeshPartDetail = 1 end)
        pcall(function() settings().Rendering.TextureQuality = 1 end)
        Lighting.GlobalShadows = false; Lighting.ShadowSoftness = 0; Lighting.EnvironmentDiffuseScale = 0; Lighting.EnvironmentSpecularScale = 0; Lighting.FogEnd = 1e6
        local ok, list = pcall(function() return workspace:GetDescendants() end)
        if ok then
            for _, inst in ipairs(list) do
                if inst:IsA("ParticleEmitter") or inst:IsA("Fire") or inst:IsA("Smoke") or inst:IsA("Sparkles") or inst:IsA("Beam") or inst:IsA("Trail") then
                    if inst.Enabled then inst.Enabled = false; boostState.hidden[inst] = true end
                elseif inst:IsA("Decal") or inst:IsA("Texture") then
                    pcall(function() inst:Destroy() end); boostState.destroyed[inst] = true
                elseif inst:IsA("PostEffect") then
                    if inst.Enabled then inst.Enabled = false; boostState.hidden[inst] = true end
                end
            end
        end
    elseif boostState then
        for inst in pairs(boostState.hidden) do if inst and inst.Parent then pcall(function() inst.Enabled = true end) end end
        for k, v in pairs(boostState.lighting) do pcall(function() Lighting[k] = v end) end
        if boostState.quality then pcall(function() settings().Rendering.QualityLevel = boostState.quality end) end
        pcall(function() settings().Rendering.MeshPartDetail = 3 end)
        pcall(function() settings().Rendering.TextureQuality = 3 end)
        boostState = nil
    end
end

-- ============================================================
--  teleport
-- ============================================================
local function teleportToPosition(pos)
    local myChar, myRoot = getChar(), getHRP()
    if not myChar or not myRoot then return false end
    myRoot.AssemblyLinearVelocity = Vector3.zero; myRoot.AssemblyAngularVelocity = Vector3.zero
    myChar:PivotTo(CFrame.new(pos))
    coroutine.wrap(function()
        for _ = 1, 8 do
            if destroyed then return end
            local root = getHRP(); if not root then return end
            root.AssemblyLinearVelocity = Vector3.zero; root.AssemblyAngularVelocity = Vector3.zero
            wait(0.03)
        end
    end)()
    return true
end
local function safeTeleport(plr)
    local myChar, myRoot, myHum = getChar(), getHRP(), getHum()
    if not myChar or not myRoot or not myHum or myHum.Health <= 0 then return false, "you are dead" end
    local tChar = plr.Character
    local tRoot = tChar and tChar:FindFirstChild("HumanoidRootPart")
    local tHum = tChar and tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health <= 0 then return false, "target is dead" end
    local dest = (tRoot.CFrame * CFrame.new(0, 0, 3.5)).Position
    local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { myChar, tChar }; params.IgnoreWater = false
    local hit = workspace:Raycast(dest + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), params)
    if hit then dest = hit.Position + Vector3.new(0, 3, 0) else dest = dest + Vector3.new(0, 1, 0) end
    teleportToPosition(dest)
    return true
end

-- ============================================================
--  waypoints
-- ============================================================
local waypoints = (getgenv and getgenv().__AeroWaypoints) or {}
if getgenv then getgenv().__AeroWaypoints = waypoints end
local function saveWaypoint()
    local root = getHRP(); if not root then return nil, "no root" end
    local p = root.Position
    local name = string.format("%.0f,%.0f,%.0f", p.X, p.Y, p.Z)
    if waypoints[name] then return nil, "duplicate" end
    waypoints[name] = p
    return name
end
local function deleteWaypoint(name) waypoints[name] = nil end
local function tpWaypoint(name)
    local p = waypoints[name]; if not p then return false, "missing" end
    return teleportToPosition(p)
end

-- ============================================================
--  server hop / rejoin
-- ============================================================
local function rejoin()
    if game.JobId == "" then return false, "no job id" end
    local ok = pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP) end)
    if ok then return true end
    return false, "teleport failed"
end

local function serverHop()
    local placeId = game.PlaceId
    local urls = {
        "https://games.roproxy.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Asc&limit=100",
        "https://games.rprxy.xyz/v1/games/" .. placeId .. "/servers/Public?sortOrder=Asc&limit=100",
        "https://games.overscan.io/v1/games/" .. placeId .. "/servers/Public?sortOrder=Asc&limit=100"
    }
    local data = nil
    local lastErr = "unknown"
    for _, url in ipairs(urls) do
        local ok, body = pcall(function()
            return game:HttpGet(url, true, { ["User-Agent"] = "Roblox/WinInet", ["Accept"] = "application/json" })
        end)
        if ok and type(body) == "string" then
            local decoded, parsed = pcall(function() return HttpService:JSONDecode(body) end)
            if decoded and type(parsed) == "table" and parsed.data then data = parsed; break
            else lastErr = "bad json" end
        else lastErr = "http " .. tostring(body) end
    end
    if not data or not data.data then return false, lastErr end
    local pool = {}
    for _, srv in ipairs(data.data) do
        if type(srv) == "table" and srv.id and srv.id ~= game.JobId then
            if (tonumber(srv.playing) or 0) < (tonumber(srv.maxPlayers) or 0) then table.insert(pool, srv.id) end
        end
    end
    if #pool == 0 then return false, "no free servers" end
    local target = pool[math.random(1, #pool)]
    local ok2 = pcall(function() TeleportService:TeleportToPlaceInstance(placeId, target, LP) end)
    if ok2 then return true end
    return false, "teleport failed"
end

-- ============================================================
--  aimbot
-- ============================================================
local function hitboxPart(char)
    if state.hitbox == "root" then return char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
    elseif state.hitbox == "torso" then return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("Head") end
    return char:FindFirstChild("Head")
end
local function isVisible(part, origin, filter)
    if not part then return false end
    local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = filter; params.IgnoreWater = true
    local hit = workspace:Raycast(origin, part.Position - origin, params)
    return hit == nil or hit.Instance:IsDescendantOf(part.Parent)
end
local function predictPosition(part, ping)
    if not part then return nil end
    local t = (ping or 0.12) + 0.02
    local pos = part.Position + part.AssemblyLinearVelocity * t
    return pos + Vector3.new(0, -0.5 * workspace.Gravity * t * t * 0.25, 0)
end
local function scoreTarget(head, hum, cam, center, mode)
    local pos, onScreen = cam:WorldToViewportPoint(head.Position)
    if not onScreen then return math.huge end
    local dist = (Vector2.new(pos.X, pos.Y) - center).Magnitude
    if mode == "lowhp" then return hum.Health * 10 + dist * 0.05
    elseif mode == "threat" then return dist * 0.7 + hum.Health * 0.3 end
    return dist
end
local function pickTarget(fov)
    local cam = workspace.CurrentCamera; if not cam then return nil end
    fov = fov or state.fov
    local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local baseFilter = { getChar() }
    local best, bestScore = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local c = plr.Character
            local head = c and c:FindFirstChild("Head")
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            local hb = c and hitboxPart(c)
            local skip = (state.teamCheck and plr.Team ~= nil and plr.Team == LP.Team)
            if head and hum and hb and hum.Health > 0 and not skip then
                local aimAt = hb.Position
                if state.predict then aimAt = predictPosition(hb, state.aimPing) end
                local pos, onScreen = cam:WorldToViewportPoint(aimAt)
                if onScreen then
                    local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
                    if d <= fov then
                        local okVisible = true
                        if state.visibleCheck then
                            local filter = table.clone(baseFilter); table.insert(filter, c)
                            okVisible = isVisible(hb, cam.CFrame.Position, filter)
                        end
                        if okVisible then
                            local score = scoreTarget(hb, hum, cam, center, state.targetMode)
                            if score < bestScore then best, bestScore = aimAt, score end
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
    local cam = workspace.CurrentCamera; if not cam then return end
    if cam.CameraType == Enum.CameraType.Scriptable then return end
    local target = pickTarget(); if not target then return end
    local goal = CFrame.lookAt(cam.CFrame.Position, target)
    local speed = 26 - 24 * state.smooth
    local angle = math.acos(clamp(cam.CFrame.LookVector:Dot(goal.LookVector), -1, 1))
    local factor = clamp(dt * speed * clamp(angle * 2 + 1, 1, 4), 0, 1)
    cam.CFrame = cam.CFrame:Lerp(goal, factor)
end
local lastTrigger = 0
local function fireWeapon()
    if type(mouse1click) == "function" then pcall(mouse1click) return true end
    if type(mouse1press) == "function" and type(mouse1release) == "function" then pcall(mouse1press); pcall(mouse1release); return true end
    local c = getChar(); local tool = c and c:FindFirstChildOfClass("Tool")
    if tool then local ok = pcall(function() tool:Activate() end); if ok then return true end end
    return false
end
local function triggerStep()
    if not state.triggerbot then return end
    local now = os.clock(); if now - lastTrigger < 0.1 then return end
    if pickTarget(state.triggerFov) then lastTrigger = now; fireWeapon() end
end

-- ============================================================
--  ESP
-- ============================================================
local espItems, espHighlights = {}, {}
local function hideItem(item)
    if not item then return end
    item.box.Visible = false; item.name.Visible = false; item.info.Visible = false; item.hpBg.Visible = false; item.hp.Visible = false
end
local function newItem()
    local item = {}
    item.box = DrawingLib.new("Square"); item.box.Thickness = 1; item.box.Filled = false; item.box.Transparency = 1; item.box.Visible = false
    item.name = DrawingLib.new("Text"); item.name.Size = 13; item.name.Center = true; item.name.Outline = true; item.name.Visible = false
    item.info = DrawingLib.new("Text"); item.info.Size = 11; item.info.Center = true; item.info.Outline = true; item.info.Visible = false
    item.hpBg = DrawingLib.new("Square"); item.hpBg.Filled = true; item.hpBg.Color = Color3.fromRGB(12, 12, 16); item.hpBg.Transparency = 0.35; item.hpBg.Visible = false
    item.hp = DrawingLib.new("Square"); item.hp.Filled = true; item.hp.Visible = false
    return item
end
local function removeItem(item)
    if not item then return end
    pcall(function() item.box:Remove() end); pcall(function() item.name:Remove() end); pcall(function() item.info:Remove() end); pcall(function() item.hpBg:Remove() end); pcall(function() item.hp:Remove() end)
end
local function clearESP()
    for plr, item in pairs(espItems) do removeItem(item); espItems[plr] = nil end
    for plr, hl in pairs(espHighlights) do pcall(function() hl:Destroy() end); espHighlights[plr] = nil end
end
local function espColor(plr, hum)
    if hum and hum.Health <= 0 then return Color3.fromRGB(120, 120, 130) end
    if plr.Team then return plr.Team.TeamColor.Color end
    return Color3.fromRGB(124, 92, 255)
end
local function espStep()
    if not state.esp then
        if next(espItems) then for _, item in pairs(espItems) do hideItem(item) end end
        if next(espHighlights) then for _, hl in pairs(espHighlights) do if hl and hl.Parent then hl.Enabled = false end end end
        return
    end
    local cam = workspace.CurrentCamera; if not cam then return end
    local seen = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local c, head, hum = plr.Character, plr.Character and plr.Character:FindFirstChild("Head"), plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
            if c and head and hum then
                seen[plr] = true
                local color = espColor(plr, hum)
                local hl = espHighlights[plr]
                if not hl or not hl.Parent then
                    hl = Instance.new("Highlight"); hl.Name = "AeroHL"; hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillTransparency = 0.65; hl.OutlineTransparency = 0; hl.Parent = c; espHighlights[plr] = hl
                end
                hl.Adornee = c; hl.FillColor = color; hl.OutlineColor = color; hl.Enabled = true
                if DrawingLib then
                    local item = espItems[plr]
                    if not item then item = newItem(); espItems[plr] = item end
                    local top = cam:WorldToViewportPoint(head.Position + Vector3.new(0, 1.4, 0))
                    local bottom = cam:WorldToViewportPoint(head.Position - Vector3.new(0, 2.8, 0))
                    if top.Z > 0 and bottom.Z > 0 then
                        local h = math.abs(bottom.Y - top.Y); if h < 6 then h = 6 end; local w = h * 0.55
                        item.box.Color = color; item.box.Size = Vector2.new(w, h); item.box.Position = Vector2.new(top.X - w * 0.5, top.Y); item.box.Visible = true
                        item.name.Color = color; item.name.Text = plr.Name; item.name.Position = Vector2.new(top.X, top.Y - 16); item.name.Visible = true
                        
                        local dist = math.floor((cam.CFrame.Position - head.Position).Magnitude)
                        local tool = c:FindFirstChildOfClass("Tool")
                        local toolName = tool and tool.Name or "Unarmed"
                        if #toolName > 15 then toolName = string.sub(toolName, 1, 13) .. ".." end
                        
                        item.info.Color = Color3.fromRGB(230, 230, 240); item.info.Text = string.format("%d m | %d hp | %s", dist, math.floor(hum.Health), toolName)
                        item.info.Position = Vector2.new(top.X, top.Y + h + 2); item.info.Visible = true
                        if state.espHealth then
                            local frac = clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                            local barX = top.X - w * 0.5 - 7
                            item.hpBg.Position = Vector2.new(barX, top.Y); item.hpBg.Size = Vector2.new(4, h); item.hpBg.Visible = true
                            item.hp.Position = Vector2.new(barX, top.Y + h * (1 - frac)); item.hp.Size = Vector2.new(4, h * frac)
                            item.hp.Color = Color3.fromRGB(235, 70, 70):Lerp(Color3.fromRGB(80, 235, 130), frac); item.hp.Visible = true
                        else item.hpBg.Visible = false; item.hp.Visible = false end
                    else hideItem(item) end
                end
            end
        end
    end
    for plr, item in pairs(espItems) do if not seen[plr] then hideItem(item) end end
    for plr, hl in pairs(espHighlights) do if not seen[plr] and hl and hl.Parent then hl.Enabled = false end end
end

-- ============================================================
--  UI
-- ============================================================
local Theme = {
    bg = Color3.fromRGB(13, 13, 17), card = Color3.fromRGB(23, 23, 30), cardHi = Color3.fromRGB(29, 29, 38),
    line = Color3.fromRGB(42, 42, 55), text = Color3.fromRGB(234, 234, 244), dim = Color3.fromRGB(138, 138, 160),
    accent = Color3.fromRGB(124, 92, 255), accent2 = Color3.fromRGB(86, 200, 255),
    neonA = Color3.fromRGB(124, 92, 255), neonB = Color3.fromRGB(86, 200, 255),
}
local THEMES = {
    violet = { accent = Color3.fromRGB(124, 92, 255), accent2 = Color3.fromRGB(86, 200, 255), neonA = Color3.fromRGB(124, 92, 255), neonB = Color3.fromRGB(86, 200, 255) },
    cyan   = { accent = Color3.fromRGB(40, 200, 230),  accent2 = Color3.fromRGB(140, 240, 255), neonA = Color3.fromRGB(40, 200, 230),  neonB = Color3.fromRGB(120, 255, 220) },
    green  = { accent = Color3.fromRGB(60, 220, 120),  accent2 = Color3.fromRGB(160, 255, 180), neonA = Color3.fromRGB(60, 220, 120),  neonB = Color3.fromRGB(200, 255, 120) },
    red    = { accent = Color3.fromRGB(235, 70, 90),   accent2 = Color3.fromRGB(255, 150, 100), neonA = Color3.fromRGB(235, 70, 90),   neonB = Color3.fromRGB(255, 160, 60) },
}

local function corner(parent, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = parent; return c end

local destroy
local notify

local gui = Instance.new("ScreenGui")
gui.Name = "Aero"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 1000
gui.Parent = getGuiParent()

-- toasts
local toastHolder = Instance.new("Frame")
toastHolder.Size = UDim2.new(0, 260, 0, 400); toastHolder.AnchorPoint = Vector2.new(1, 0); toastHolder.Position = UDim2.new(1, -12, 0, 12)
toastHolder.BackgroundTransparency = 1; toastHolder.ZIndex = 50; toastHolder.Parent = gui
local toastLayout = Instance.new("UIListLayout"); toastLayout.Padding = UDim.new(0, 6); toastLayout.SortOrder = Enum.SortOrder.LayoutOrder; toastLayout.VerticalAlignment = Enum.VerticalAlignment.Top; toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right; toastLayout.Parent = toastHolder
local toastOrder = 0; local toastActive = {}
local TOAST_COLORS = { info = Color3.fromRGB(86, 200, 255), ok = Color3.fromRGB(80, 235, 130), warn = Color3.fromRGB(255, 180, 70), err = Color3.fromRGB(235, 70, 90) }

local function playNotifySound(kind)
    local s = Instance.new("Sound")
    s.Volume = 0.3
    if kind == "err" then s.SoundId = "rbxassetid://6739879750"
    elseif kind == "warn" then s.SoundId = "rbxassetid://6739879750"
    else s.SoundId = "rbxassetid://6739879750" end
    s.Parent = SoundService
    s:Play()
    coroutine.wrap(function() wait(1); if s then s:Destroy() end end)()
end

notify = function(text, kind, duration)
    if destroyed then return end
    kind = kind or "info"; duration = duration or 2.5; text = tostring(text or "")
    pcall(playNotifySound, kind)
    while #toastActive >= 3 do local old = table.remove(toastActive, 1); if old and old.Parent then old:Destroy() end end
    toastOrder = toastOrder + 1
    local accent = TOAST_COLORS[kind] or TOAST_COLORS.info
    local frame = Instance.new("Frame"); frame.Size = UDim2.new(1, 0, 0, 34); frame.BackgroundColor3 = Theme.card; frame.BackgroundTransparency = 1; frame.BorderSizePixel = 0; frame.ZIndex = 51; frame.LayoutOrder = toastOrder; frame.Parent = toastHolder; corner(frame, 10)
    local stroke = Instance.new("UIStroke"); stroke.Color = accent; stroke.Thickness = 1.5; stroke.Transparency = 1; stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; stroke.Parent = frame
    local bar = Instance.new("Frame"); bar.Size = UDim2.new(0, 3, 1, -10); bar.Position = UDim2.new(0, 6, 0, 5); bar.BackgroundColor3 = accent; bar.BorderSizePixel = 0; bar.ZIndex = 52; bar.Parent = frame; corner(bar, 2)
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, -20, 1, 0); lbl.Position = UDim2.new(0, 14, 0, 0); lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 12; lbl.TextColor3 = Theme.text; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextTruncate = Enum.TextTruncate.AtEnd; lbl.Text = text; lbl.TextTransparency = 1; lbl.ZIndex = 52; lbl.Parent = frame
    table.insert(toastActive, frame)
    TweenService:Create(frame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0.05 }):Play()
    TweenService:Create(stroke, TweenInfo.new(0.18), { Transparency = 0.1 }):Play()
    TweenService:Create(lbl, TweenInfo.new(0.18), { TextTransparency = 0 }):Play()
    coroutine.wrap(function()
        wait(duration)
        if not frame or not frame.Parent then return end
        TweenService:Create(frame, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play(); TweenService:Create(lbl, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
        TweenService:Create(stroke, TweenInfo.new(0.25), { Transparency = 1 }):Play(); TweenService:Create(bar, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
        wait(0.28)
        if frame and frame.Parent then
            local idx = nil; for i, t in ipairs(toastActive) do if t == frame then idx = i break end end
            if idx then table.remove(toastActive, idx) end; frame:Destroy()
        end
    end)()
end

-- panel
local PANEL_W, PANEL_H, TAB_BAR_H = 300, 440, 46
local main = Instance.new("Frame"); main.Name = "AeroMain"; main.Size = UDim2.fromOffset(PANEL_W, PANEL_H); main.Position = UDim2.fromOffset(16, 80); main.BackgroundColor3 = Theme.bg; main.BorderSizePixel = 0; main.Active = true; main.ClipsDescendants = true; main.ZIndex = 10; main.Parent = gui; corner(main, 16)

local mainStroke = Instance.new("UIStroke"); mainStroke.Color = Theme.neonA; mainStroke.Thickness = 2; mainStroke.Transparency = 0.05; mainStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; mainStroke.Parent = main
local mainGradient = Instance.new("UIGradient"); mainGradient.Parent = mainStroke
local mainGlow = Instance.new("UIStroke"); mainGlow.Color = Theme.neonB; mainGlow.Thickness = 6; mainGlow.Transparency = 0.85; mainGlow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; mainGlow.Parent = main
local mainGlowGradient = Instance.new("UIGradient"); mainGlowGradient.Parent = mainGlow

-- reopen (small toggle)
local reopen = Instance.new("TextButton"); reopen.Name = "AeroToggle"; reopen.Size = UDim2.fromOffset(44, 44); reopen.Position = UDim2.fromOffset(16, 16); reopen.BackgroundColor3 = Theme.bg; reopen.BackgroundTransparency = 0.1; reopen.BorderSizePixel = 0; reopen.Font = Enum.Font.GothamBold; reopen.TextSize = 11; reopen.TextColor3 = Theme.accent2; reopen.Text = "aero"; reopen.AutoButtonColor = false; reopen.ZIndex = 10; reopen.Parent = gui; corner(reopen, 22)
local reopenStroke = Instance.new("UIStroke"); reopenStroke.Color = Theme.neonA; reopenStroke.Thickness = 2; reopenStroke.Transparency = 0.05; reopenStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; reopenStroke.Parent = reopen
local reopenGradient = Instance.new("UIGradient"); reopenGradient.Parent = reopenStroke
local reopenGlow = Instance.new("UIStroke"); reopenGlow.Color = Theme.neonB; reopenGlow.Thickness = 5; reopenGlow.Transparency = 0.85; reopenGlow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; reopenGlow.Parent = reopen
local reopenGlowGradient = Instance.new("UIGradient"); reopenGlowGradient.Parent = reopenGlow
local reopenUserMoved = false

-- iridescent setup
local iridescentOffset = 0
local function updateIridescentGradient(gradient, baseColor)
    local lighter = Color3.new(math.min(baseColor.R * 1.5, 1), math.min(baseColor.G * 1.5, 1), math.min(baseColor.B * 1.5, 1))
    local darker = Color3.new(baseColor.R * 0.5, baseColor.G * 0.5, baseColor.B * 0.5)
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0.00, darker), ColorSequenceKeypoint.new(0.25, baseColor),
        ColorSequenceKeypoint.new(0.50, lighter), ColorSequenceKeypoint.new(0.75, baseColor),
        ColorSequenceKeypoint.new(1.00, darker),
    })
end

local function layoutPanel()
    local vp = gui.AbsoluteSize; if vp.X < 10 or vp.Y < 10 then local cam = workspace.CurrentCamera; if cam then vp = cam.ViewportSize end end; if vp.X < 10 then vp = Vector2.new(400, 700) end
    local w = clamp(math.floor(vp.X * 0.52), 258, 340); local h = clamp(math.floor(vp.Y * 0.62), 320, 480)
    PANEL_W = w; PANEL_H = h; main.Size = UDim2.fromOffset(w, h)
    if not reopenUserMoved then reopen.Position = UDim2.fromOffset(16, 16) end
    local padW = 44; reopen.Size = UDim2.fromOffset(padW, padW)
    local cr = reopen:FindFirstChildOfClass("UICorner"); if cr then cr.CornerRadius = UDim.new(0, math.floor(padW * 0.5)) end
    reopen.TextSize = math.floor(padW * 0.25)
end

coroutine.wrap(function() for _ = 1, 30 do if destroyed then return end; if gui.AbsoluteSize.X > 10 and gui.AbsoluteSize.Y > 10 then break end; wait(0.1) end; pcall(layoutPanel) end)()

-- header
local header = Instance.new("Frame"); header.Size = UDim2.new(1, 0, 0, 40); header.BackgroundTransparency = 1; header.Parent = main
local dot = Instance.new("Frame"); dot.Size = UDim2.fromOffset(8, 8); dot.Position = UDim2.new(0, 14, 0, 16); dot.BackgroundColor3 = Theme.accent; dot.BorderSizePixel = 0; dot.Parent = header; corner(dot, 4)
local brand = Instance.new("TextLabel"); brand.Size = UDim2.new(1, -130, 1, 0); brand.Position = UDim2.fromOffset(28, 0); brand.BackgroundTransparency = 1; brand.Font = Enum.Font.GothamBold; brand.TextSize = 15; brand.TextColor3 = Theme.text; brand.TextXAlignment = Enum.TextXAlignment.Left; brand.Text = "AERO"; brand.Parent = header
local brandTag = Instance.new("TextLabel"); brandTag.Size = UDim2.new(1, -130, 1, 0); brandTag.Position = UDim2.fromOffset(78, 0); brandTag.BackgroundTransparency = 1; brandTag.Font = Enum.Font.GothamMedium; brandTag.TextSize = 10; brandTag.TextColor3 = Theme.dim; brandTag.TextXAlignment = Enum.TextXAlignment.Left; brandTag.Text = "v2.8.2"; brandTag.Parent = header

local function headerButton(text, x, onClick)
    local b = Instance.new("TextButton"); b.Size = UDim2.fromOffset(28, 26); b.Position = UDim2.new(1, x, 0, 7); b.BackgroundColor3 = Theme.card; b.BorderSizePixel = 0; b.Font = Enum.Font.GothamBold; b.TextSize = 14; b.TextColor3 = Theme.text; b.Text = text; b.Parent = header; corner(b, 8)
    b.MouseButton1Click:Connect(function() local ok, err = pcall(onClick); if not ok then warn("[Aero] " .. tostring(err)) end end); return b
end
headerButton("_", -70, function() main.Visible = false end)
headerButton("x", -36, function() if destroy then destroy() end end)

local tabBar = Instance.new("Frame"); tabBar.Size = UDim2.new(1, 0, 0, TAB_BAR_H); tabBar.Position = UDim2.new(0, 0, 1, -TAB_BAR_H); tabBar.BackgroundColor3 = Theme.card; tabBar.BorderSizePixel = 0; tabBar.Parent = main
local tabBarLine = Instance.new("Frame"); tabBarLine.Size = UDim2.new(1, 0, 0, 1); tabBarLine.BackgroundColor3 = Theme.line; tabBarLine.BorderSizePixel = 0; tabBarLine.Parent = tabBar
local content = Instance.new("Frame"); content.Size = UDim2.new(1, 0, 1, -(40 + TAB_BAR_H)); content.Position = UDim2.fromOffset(0, 40); content.BackgroundTransparency = 1; content.Parent = main

local tabs, tabButtons = {}, {}
local activeTab, refreshPlayerList, refreshWaypointList, refreshServerInfo = nil, nil, nil, nil

local function newTab(id)
    local sf = Instance.new("ScrollingFrame"); sf.Size = UDim2.new(1, 0, 1, 0); sf.BackgroundTransparency = 1; sf.BorderSizePixel = 0; sf.ScrollBarThickness = 2; sf.ScrollBarImageColor3 = Theme.line; sf.CanvasSize = UDim2.new(0, 0, 0, 0); sf.AutomaticCanvasSize = Enum.AutomaticSize.Y; sf.ScrollingDirection = Enum.ScrollingDirection.Y; sf.Visible = false; sf.Parent = content
    local pad = Instance.new("UIPadding"); pad.PaddingTop = UDim.new(0, 8); pad.PaddingBottom = UDim.new(0, 10); pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8); pad.Parent = sf
    local layout = Instance.new("UIListLayout"); layout.Padding = UDim.new(0, 6); layout.SortOrder = Enum.SortOrder.LayoutOrder; layout.Parent = sf
    tabs[id] = sf; return sf
end

local function refreshTabStyles()
    for name, btn in pairs(tabButtons) do
        local on = (name == activeTab)
        btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Theme.dim
        btn.BackgroundColor3 = on and Theme.accent or Theme.cardHi
        btn.BackgroundTransparency = on and 0 or 0.55
    end
end

local function showTab(id)
    for name, frame in pairs(tabs) do frame.Visible = (name == id) end
    activeTab = id; refreshTabStyles()
    if id == "players" and refreshPlayerList then pcall(refreshPlayerList) end
    if id == "way" and refreshWaypointList then pcall(refreshWaypointList) end
    if id == "srv" and refreshServerInfo then pcall(refreshServerInfo) end
end

local tabDefs = { { "move", "MOVE" }, { "aim", "AIM" }, { "vis", "VIS" }, { "players", "PLAY" }, { "way", "WAY" }, { "srv", "SRV" } }
local tabN = #tabDefs
for i, def in ipairs(tabDefs) do
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1 / tabN, -4, 0, 34); b.Position = UDim2.new((i - 1) / tabN, 2, 0, 6); b.BackgroundColor3 = Theme.cardHi; b.BackgroundTransparency = 0.55; b.BorderSizePixel = 0; b.Font = Enum.Font.GothamBold; b.TextSize = 9; b.TextColor3 = Theme.dim; b.Text = def[2]; b.Parent = tabBar; corner(b, 9)
    b.MouseButton1Click:Connect(function() showTab(def[1]) end); tabButtons[def[1]] = b
end

-- drag
local dragging, dragStart, dragOrigin, btnDragging, btnStart, btnOrigin, btnMoved = false, nil, nil, false, nil, nil, 0
local function isPrimaryInput(input) return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch end

header.InputBegan:Connect(function(input)
    if destroyed or not isPrimaryInput(input) then return end
    dragging = true; local ap = main.AbsolutePosition; local gp = gui.AbsolutePosition; main.AnchorPoint = Vector2.zero; main.Position = UDim2.fromOffset(ap.X - gp.X, ap.Y - gp.Y); dragStart = input.Position; dragOrigin = main.Position
    input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then dragging = false end end)
end)
reopen.InputBegan:Connect(function(input)
    if destroyed or not isPrimaryInput(input) then return end
    btnDragging = true; btnMoved = 0; btnStart = input.Position; local ap = reopen.AbsolutePosition; local gp = gui.AbsolutePosition; reopen.Position = UDim2.fromOffset(ap.X - gp.X, ap.Y - gp.Y); btnOrigin = reopen.Position
    input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then btnDragging = false end end)
end)
reopen.InputEnded:Connect(function(input)
    if destroyed or not isPrimaryInput(input) then return end
    btnDragging = false; if btnMoved >= 8 then reopenUserMoved = true else main.Visible = not main.Visible end
end)
local dragConn = UserInputService.InputChanged:Connect(function(input)
    if destroyed or (input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch) then return end
    local sw, sh = gui.AbsoluteSize.X, gui.AbsoluteSize.Y
    if btnDragging and btnStart then
        local d = input.Position - btnStart; btnMoved = math.max(btnMoved, math.abs(d.X) + math.abs(d.Y))
        reopen.Position = UDim2.new(0, clamp(btnOrigin.X.Offset + d.X, 0, sw - reopen.AbsoluteSize.X), 0, clamp(btnOrigin.Y.Offset + d.Y, 0, sh - reopen.AbsoluteSize.Y))
        return
    end
    if not dragging then return end
    local delta = input.Position - dragStart
    main.Position = UDim2.new(0, clamp(dragOrigin.X.Offset + delta.X, -(PANEL_W - 80), sw - 80), 0, clamp(dragOrigin.Y.Offset + delta.Y, -(PANEL_H - 90), sh - 90))
end)

-- widgets
local uiRefreshers, uiOrder = {}, 0
local function nextOrder() uiOrder = uiOrder + 1; return uiOrder end
local function syncUI() for _, f in ipairs(uiRefreshers) do pcall(f) end end

local function card(parent, height)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, height); row.BackgroundColor3 = Theme.card; row.BorderSizePixel = 0; row.LayoutOrder = nextOrder(); row.Parent = parent; corner(row, 10); return row
end

local function makeSwitch(parent, text, get, set)
    local row = card(parent, 42)
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, -70, 1, 0); lbl.Position = UDim2.fromOffset(12, 0); lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 13; lbl.TextColor3 = Theme.text; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Text = text; lbl.Parent = row
    local pill = Instance.new("Frame"); pill.Size = UDim2.fromOffset(38, 21); pill.Position = UDim2.new(1, -50, 0.5, -10); pill.BackgroundColor3 = Theme.line; pill.BorderSizePixel = 0; pill.Parent = row; corner(pill, 11)
    local knob = Instance.new("Frame"); knob.Size = UDim2.fromOffset(15, 15); knob.Position = UDim2.fromOffset(3, 3); knob.BackgroundColor3 = Color3.fromRGB(225, 225, 236); knob.BorderSizePixel = 0; knob.Parent = pill; corner(knob, 8)
    local hit = Instance.new("TextButton"); hit.Size = UDim2.fromOffset(58, 42); hit.Position = UDim2.new(1, -58, 0, 0); hit.BackgroundTransparency = 1; hit.Text = ""; hit.Parent = row
    local function refresh() local on = get(); pill.BackgroundColor3 = on and Theme.accent or Theme.line; knob.Position = on and UDim2.fromOffset(20, 3) or UDim2.fromOffset(3, 3) end
    hit.MouseButton1Click:Connect(function() local ok, err = pcall(function() set(not get()) end); if not ok then warn("[Aero] " .. tostring(err)) end; refresh() end)
    refresh(); table.insert(uiRefreshers, refresh); return row
end

local activeSlider = nil
local function makeSlider(parent, text, minv, maxv, stepv, get, set, decimals)
    local row = card(parent, 46)
    local nameLbl = Instance.new("TextLabel"); nameLbl.Size = UDim2.new(1, -80, 0, 16); nameLbl.Position = UDim2.fromOffset(12, 7); nameLbl.BackgroundTransparency = 1; nameLbl.Font = Enum.Font.GothamMedium; nameLbl.TextSize = 12; nameLbl.TextColor3 = Theme.dim; nameLbl.TextXAlignment = Enum.TextXAlignment.Left; nameLbl.Text = text; nameLbl.Parent = row
    local valueLbl = Instance.new("TextLabel"); valueLbl.Size = UDim2.fromOffset(58, 16); valueLbl.Position = UDim2.new(1, -70, 0, 7); valueLbl.BackgroundTransparency = 1; valueLbl.Font = Enum.Font.GothamBold; valueLbl.TextSize = 12; valueLbl.TextColor3 = Theme.accent2; valueLbl.TextXAlignment = Enum.TextXAlignment.Right; valueLbl.Parent = row
    local track = Instance.new("Frame"); track.Size = UDim2.new(1, -24, 0, 4); track.Position = UDim2.new(0, 12, 0, 33); track.BackgroundColor3 = Theme.line; track.BorderSizePixel = 0; track.Parent = row; corner(track, 2)
    local fill = Instance.new("Frame"); fill.Size = UDim2.new(0, 0, 1, 0); fill.BackgroundColor3 = Theme.accent; fill.BorderSizePixel = 0; fill.Parent = track; corner(fill, 2)
    local knob = Instance.new("Frame"); knob.Size = UDim2.fromOffset(12, 12); knob.AnchorPoint = Vector2.new(0.5, 0.5); knob.Position = UDim2.new(0, 0, 0.5, 0); knob.BackgroundColor3 = Color3.fromRGB(240, 240, 250); knob.BorderSizePixel = 0; knob.Parent = track; corner(knob, 6)
    local hit = Instance.new("TextButton"); hit.Size = UDim2.new(1, 0, 0, 24); hit.Position = UDim2.new(0, 0, 0, 22); hit.BackgroundTransparency = 1; hit.Text = ""; hit.Parent = row
    local function format(v) if decimals and decimals > 0 then return string.format("%." .. decimals .. "f", v) end return tostring(math.floor(v + 0.5)) end
    local function paint() local v = get(); local f = 0; if maxv > minv then f = clamp((v - minv) / (maxv - minv), 0, 1) end; fill.Size = UDim2.new(f, 0, 1, 0); fill.BackgroundColor3 = Theme.accent; valueLbl.TextColor3 = Theme.accent2; knob.Position = UDim2.new(f, 0, 0.5, 0); valueLbl.Text = format(v) end
    local function valueFromX(x) local ap, asz = hit.AbsolutePosition, hit.AbsoluteSize; local f = clamp((x - ap.X) / math.max(asz.X, 1), 0, 1); local raw = minv + (maxv - minv) * f; local v = math.floor((raw + stepv * 0.5) / stepv) * stepv; v = clamp(v, minv, maxv); v = math.floor(v * 1000 + 0.5) / 1000; set(v); paint() end
    hit.InputBegan:Connect(function(input) if destroyed then return end; if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then activeSlider = valueFromX; valueFromX(input.Position.X) end end)
    paint(); table.insert(uiRefreshers, paint); return row
end

local function makeButton(parent, text, onClick, accent)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1, 0, 0, 34); b.BackgroundColor3 = accent and Theme.accent or Theme.card; b.BorderSizePixel = 0; b.Font = Enum.Font.GothamBold; b.TextSize = 12; b.TextColor3 = accent and Color3.fromRGB(255, 255, 255) or Theme.text; b.Text = text; b.LayoutOrder = nextOrder(); b.Parent = parent; corner(b, 9)
    b.MouseButton1Click:Connect(function() local ok, err = pcall(onClick, b); if not ok then warn("[Aero] " .. tostring(err)) end end); return b
end

local function makeHold(parent, text, onDown, onUp, layoutOrder)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1, 0, 1, 0); b.BackgroundColor3 = Theme.card; b.BorderSizePixel = 0; b.AutoButtonColor = false; b.Font = Enum.Font.GothamBold; b.TextSize = 14; b.TextColor3 = Theme.text; b.Text = text; b.LayoutOrder = layoutOrder; b.Parent = parent; corner(b, 8)
    b.InputBegan:Connect(function(input) if destroyed or not isPrimaryInput(input) then return end; b.BackgroundColor3 = Theme.accent; onDown() end)
    b.InputEnded:Connect(function(input) if not isPrimaryInput(input) then return end; b.BackgroundColor3 = Theme.card; onUp() end); return b
end

local function makeDropdown(parent, text, options, get, set)
    local row = card(parent, 44)
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, -100, 1, 0); lbl.Position = UDim2.fromOffset(12, 0); lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 13; lbl.TextColor3 = Theme.text; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Text = text; lbl.Parent = row
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 80, 0, 26); btn.Position = UDim2.new(1, -92, 0.5, -13); btn.BackgroundColor3 = Theme.cardHi; btn.BorderSizePixel = 0; btn.Font = Enum.Font.GothamBold; btn.TextSize = 11; btn.TextColor3 = Theme.accent2; btn.Text = get(); btn.Parent = row; corner(btn, 6)
    local idx = 1; for i, v in ipairs(options) do if v == get() then idx = i break end end
    btn.MouseButton1Click:Connect(function()
        idx = idx + 1; if idx > #options then idx = 1 end
        local newVal = options[idx]; set(newVal); btn.Text = newVal
    end)
    table.insert(uiRefreshers, function() btn.Text = get(); for i, v in ipairs(options) do if v == get() then idx = i break end end end)
end

local function applyTheme(name)
    local t = THEMES[name] or THEMES.violet
    Theme.accent = t.accent; Theme.accent2 = t.accent2; Theme.neonA = t.neonA; Theme.neonB = t.neonB; state.theme = name
    pcall(function()
        mainStroke.Color = Theme.neonA; mainGlow.Color = Theme.neonB; reopenStroke.Color = Theme.neonA; reopenGlow.Color = Theme.neonB; reopen.TextColor3 = Theme.accent2; dot.BackgroundColor3 = Theme.accent
        updateIridescentGradient(mainGradient, Theme.neonA)
        updateIridescentGradient(mainGlowGradient, Theme.neonB)
        updateIridescentGradient(reopenGradient, Theme.neonA)
        updateIridescentGradient(reopenGlowGradient, Theme.neonB)
        if fovCircle and state.fovColor == "theme" then fovCircle.Color = Theme.accent end
    end)
    pcall(refreshTabStyles); pcall(syncUI); if notify then notify("theme: " .. name, "ok") end
end

-- config system
local function saveConfig()
    local cfg = {
        state = state,
        waypoints = {}
    }
    for k, v in pairs(waypoints) do cfg.waypoints[k] = {x=v.X, y=v.Y, z=v.Z} end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(cfg) end)
    if ok then
        local wOk = safeWriteFile("AeroConfig.json", encoded)
        if wOk then notify("config saved", "ok") else notify("save failed (no writefile)", "err") end
    else notify("encode failed", "err") end
end

local function loadConfig()
    local content = safeReadFile("AeroConfig.json")
    if not content then notify("config not found", "warn") return end
    local dOk, cfg = pcall(function() return HttpService:JSONDecode(content) end)
    if dOk and type(cfg) == "table" then
        if cfg.state then
            for k, v in pairs(cfg.state) do if state[k] ~= nil then state[k] = v end end
        end
        if cfg.waypoints then
            for k in pairs(waypoints) do waypoints[k] = nil end
            for k, v in pairs(cfg.waypoints) do waypoints[k] = Vector3.new(v.x, v.y, v.z) end
        end
        applyStats(); applyTheme(state.theme); syncUI(); refreshWaypointList(); refreshThemeButtons()
        notify("config loaded", "ok")
    else notify("decode failed", "err") end
end

-- MOVE
local moveTab = newTab("move")
makeSlider(moveTab, "WalkSpeed", 8, 400, 4, function() return state.speed end, function(v) state.speed = v; applySpeed() end, 0)
makeSlider(moveTab, "JumpPower", 0, 500, 10, function() return state.jump end, function(v) state.jump = v; applyJump() end, 0)

local presetCard = Instance.new("Frame")
presetCard.Size = UDim2.new(1, 0, 0, 36); presetCard.BackgroundColor3 = Theme.card; presetCard.BorderSizePixel = 0; presetCard.LayoutOrder = nextOrder(); presetCard.Parent = moveTab; corner(presetCard, 10)
local presetRow = Instance.new("Frame")
presetRow.Size = UDim2.new(1, -16, 0, 24); presetRow.Position = UDim2.new(0, 8, 0.5, -12); presetRow.BackgroundTransparency = 1; presetRow.Parent = presetCard
local presetGrid = Instance.new("UIGridLayout")
presetGrid.CellSize = UDim2.new(0.333, -4, 1, 0); presetGrid.CellPadding = UDim2.new(0.01, 0, 0, 0); presetGrid.Parent = presetRow
local speeds = { {n="Normal", v=16}, {n="Sprint", v=35}, {n="Fast", v=80} }
for i, s in ipairs(speeds) do
    local b = Instance.new("TextButton"); b.BackgroundColor3 = Theme.cardHi; b.BorderSizePixel = 0; b.Font = Enum.Font.GothamBold; b.TextSize = 11; b.TextColor3 = Theme.text; b.Text = s.n; b.LayoutOrder = i; b.Parent = presetRow; corner(b, 6)
    b.MouseButton1Click:Connect(function() state.speed = s.v; applySpeed(); syncUI(); notify("speed: " .. s.v, "ok") end)
end

makeSwitch(moveTab, "Lock stats", function() return state.lockStats end, function(v) state.lockStats = v; if v then applyStats() end end)
makeSwitch(moveTab, "Infinite jump", function() return state.infJump end, function(v) state.infJump = v end)
makeSwitch(moveTab, "BHop", function() return state.bhop end, function(v) setBhop(v); notify("bhop " .. (v and "on" or "off"), v and "ok" or "info") end)
makeSwitch(moveTab, "Fly", function() return state.fly end, function(v) setFly(v); notify("fly " .. (v and "on" or "off"), v and "ok" or "info") end)

local pad = Instance.new("Frame"); pad.Size = UDim2.new(1, 0, 0, 88); pad.BackgroundTransparency = 1; pad.LayoutOrder = nextOrder(); pad.Parent = moveTab
local grid = Instance.new("UIGridLayout"); grid.CellSize = UDim2.new(0.32, 0, 0, 28); grid.CellPadding = UDim2.new(0.02, 0, 0, 2); grid.SortOrder = Enum.SortOrder.LayoutOrder; grid.Parent = pad
makeHold(pad, "+", function() flyInput.u = 1 end, function() flyInput.u = 0 end, 1)
makeHold(pad, "^", function() flyInput.f = 1 end, function() flyInput.f = 0 end, 2)
makeHold(pad, "-", function() flyInput.d = 1 end, function() flyInput.d = 0 end, 3)
makeHold(pad, "<", function() flyInput.l = 1 end, function() flyInput.l = 0 end, 4)
makeHold(pad, "x", function() clearFlyInput() end, function() end, 5)
makeHold(pad, ">", function() flyInput.r = 1 end, function() flyInput.r = 0 end, 6)
makeHold(pad, ">", function() flyInput.r = 1 end, function() flyInput.r = 0 end, 7)
makeHold(pad, "v", function() flyInput.b = 1 end, function() flyInput.b = 0 end, 8)
makeHold(pad, "x", function() clearFlyInput() end, function() end, 9)
makeSlider(moveTab, "Fly speed", 10, 400, 5, function() return state.flySpeed end, function(v) state.flySpeed = v end, 0)
makeSwitch(moveTab, "Click TP", function() return state.clickTp end, function(v) state.clickTp = v; notify("click tp " .. (v and "on" or "off"), v and "ok" or "info") end)

-- AIM
local aimTab = newTab("aim")
makeSwitch(aimTab, "Aimbot", function() return state.aimbot end, function(v) state.aimbot = v; notify("aimbot " .. (v and "on" or "off"), v and "ok" or "info") end)
makeSlider(aimTab, "FOV", 20, 600, 10, function() return state.fov end, function(v) state.fov = v end, 0)
makeSlider(aimTab, "Smoothing", 0, 0.95, 0.05, function() return state.smooth end, function(v) state.smooth = v end, 2)
makeSwitch(aimTab, "Team check", function() return state.teamCheck end, function(v) state.teamCheck = v end)
makeSwitch(aimTab, "Prediction", function() return state.predict end, function(v) state.predict = v end)
makeSlider(aimTab, "Prediction Ping", 0, 0.8, 0.05, function() return state.aimPing end, function(v) state.aimPing = v end, 2)
makeSwitch(aimTab, "Visibility check", function() return state.visibleCheck end, function(v) state.visibleCheck = v end)
makeSwitch(aimTab, "Triggerbot", function() return state.triggerbot end, function(v) state.triggerbot = v; notify("triggerbot " .. (v and "on" or "off"), v and "ok" or "info") end)
makeSlider(aimTab, "Trigger FOV", 5, 300, 5, function() return state.triggerFov end, function(v) state.triggerFov = v end, 0)
makeDropdown(aimTab, "Target Priority", {"closest", "lowhp", "threat"}, function() return state.targetMode end, function(v) state.targetMode = v end)
makeDropdown(aimTab, "Hitbox", {"head", "root", "torso"}, function() return state.hitbox end, function(v) state.hitbox = v end)

local fovColors = { "theme", "cyan", "red", "green", "yellow", "white" }
local fovColorIdx = 1
local fovBtn = makeButton(aimTab, "FOV Color: " .. fovColors[fovColorIdx], function(b)
    fovColorIdx = fovColorIdx + 1
    if fovColorIdx > #fovColors then fovColorIdx = 1 end
    local c = fovColors[fovColorIdx]
    state.fovColor = c
    b.Text = "FOV Color: " .. c
    if fovCircle then
        if c == "theme" then fovCircle.Color = Theme.accent
        elseif c == "cyan" then fovCircle.Color = Color3.fromRGB(86, 200, 255)
        elseif c == "red" then fovCircle.Color = Color3.fromRGB(235, 70, 90)
        elseif c == "green" then fovCircle.Color = Color3.fromRGB(60, 220, 120)
        elseif c == "yellow" then fovCircle.Color = Color3.fromRGB(255, 220, 80)
        elseif c == "white" then fovCircle.Color = Color3.fromRGB(255, 255, 255)
        end
    end
end, false)

-- VIS
local visTab = newTab("vis")
makeSwitch(visTab, "ESP", function() return state.esp end, function(v) state.esp = v; if not v then clearESP() end; notify("esp " .. (v and "on" or "off"), v and "ok" or "info") end)
makeSwitch(visTab, "ESP health bars", function() return state.espHealth end, function(v) state.espHealth = v end)
makeSwitch(visTab, "Fullbright", function() return state.fullbright end, function(v) setFullbright(v) end)
makeSwitch(visTab, "Stats overlay", function() return state.stats end, function(v) state.stats = v end)
makeSwitch(visTab, "FPS booster", function() return state.fpsBoost end, function(v) setFpsBoost(v); notify("fps boost " .. (v and "on" or "off"), v and "ok" or "info") end)
makeSwitch(visTab, "Spinbot", function() return state.spin end, function(v) state.spin = v; if not v then local root = getHRP(); if root then root.CFrame = CFrame.new(root.Position, root.Position + Vector3.new(0, 0, -1)) end end; notify("spinbot " .. (v and "on" or "off"), v and "ok" or "info") end)
makeSlider(visTab, "Spin speed", 1, 30, 1, function() return state.spinSpeed end, function(v) state.spinSpeed = v end, 0)

local themeCard = Instance.new("Frame"); themeCard.Size = UDim2.new(1, 0, 0, 52); themeCard.BackgroundColor3 = Theme.card; themeCard.BorderSizePixel = 0; themeCard.LayoutOrder = nextOrder(); themeCard.Parent = visTab; corner(themeCard, 10)
local themeLbl = Instance.new("TextLabel"); themeLbl.Size = UDim2.new(1, -20, 0, 16); themeLbl.Position = UDim2.fromOffset(12, 6); themeLbl.BackgroundTransparency = 1; themeLbl.Font = Enum.Font.GothamMedium; themeLbl.TextSize = 12; themeLbl.TextColor3 = Theme.dim; themeLbl.TextXAlignment = Enum.TextXAlignment.Left; themeLbl.Text = "Theme"; themeLbl.Parent = themeCard
local themeRow = Instance.new("Frame"); themeRow.Size = UDim2.new(1, -20, 0, 22); themeRow.Position = UDim2.fromOffset(10, 24); themeRow.BackgroundTransparency = 1; themeRow.Parent = themeCard
local themeGrid = Instance.new("UIGridLayout"); themeGrid.CellSize = UDim2.new(0.25, -4, 1, 0); themeGrid.CellPadding = UDim2.new(0.01, 0, 0, 0); themeGrid.SortOrder = Enum.SortOrder.LayoutOrder; themeGrid.Parent = themeRow
local themeButtons = {}; local themeNames = { "violet", "cyan", "green", "red" }
local function refreshThemeButtons() for name, btn in pairs(themeButtons) do local on = (state.theme == name); btn.BackgroundTransparency = on and 0 or 0.35; btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Theme.dim end end
for i, name in ipairs(themeNames) do
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1, 0, 1, 0); b.BackgroundColor3 = THEMES[name].accent; b.BackgroundTransparency = 0.35; b.BorderSizePixel = 0; b.Font = Enum.Font.GothamBold; b.TextSize = 10; b.TextColor3 = Theme.dim; b.Text = name; b.LayoutOrder = i; b.Parent = themeRow; corner(b, 7)
    b.MouseButton1Click:Connect(function() applyTheme(name); refreshThemeButtons() end); themeButtons[name] = b
end
refreshThemeButtons()

local configSaveBtn = makeButton(visTab, "Save Config", saveConfig, true); configSaveBtn.LayoutOrder = nextOrder()
local configLoadBtn = makeButton(visTab, "Load Config", loadConfig, false); configLoadBtn.LayoutOrder = nextOrder()

-- PLAY
local playersTab = newTab("players")
local statusLbl = Instance.new("TextLabel"); statusLbl.Size = UDim2.new(1, 0, 0, 14); statusLbl.BackgroundTransparency = 1; statusLbl.Font = Enum.Font.GothamMedium; statusLbl.TextSize = 10; statusLbl.TextColor3 = Theme.dim; statusLbl.TextXAlignment = Enum.TextXAlignment.Left; statusLbl.Text = ""; statusLbl.LayoutOrder = 2; statusLbl.Parent = playersTab
local playerBox = Instance.new("Frame"); playerBox.Size = UDim2.new(1, 0, 0, 0); playerBox.AutomaticSize = Enum.AutomaticSize.Y; playerBox.BackgroundTransparency = 1; playerBox.LayoutOrder = 1; playerBox.Parent = playersTab
local playerLayout = Instance.new("UIListLayout"); playerLayout.Padding = UDim.new(0, 4); playerLayout.SortOrder = Enum.SortOrder.LayoutOrder; playerLayout.Parent = playerBox

refreshPlayerList = function()
    for _, child in ipairs(playerBox:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
    local n = 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            n = n + 1; local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid"); local hp = hum and (math.floor(hum.Health) .. " hp") or "loading"
            local row = Instance.new("TextButton"); row.Size = UDim2.new(1, 0, 0, 32); row.BackgroundColor3 = Theme.card; row.BorderSizePixel = 0; row.AutoButtonColor = true; row.Font = Enum.Font.GothamMedium; row.TextSize = 12; row.TextColor3 = Theme.text; row.TextXAlignment = Enum.TextXAlignment.Left; row.Text = "  " .. plr.Name .. "   " .. hp; row.LayoutOrder = n; row.Parent = playerBox; corner(row, 8)
            row.MouseButton1Click:Connect(function() local ok, reason = safeTeleport(plr); if ok then statusLbl.Text = "teleported to " .. plr.Name; notify("tp -> " .. plr.Name, "ok") else statusLbl.Text = "teleport failed: " .. tostring(reason); notify("tp failed: " .. tostring(reason), "err") end end)
        end
    end
    if n == 0 then local l = Instance.new("TextLabel"); l.Size = UDim2.new(1, 0, 0, 24); l.BackgroundTransparency = 1; l.Font = Enum.Font.GothamMedium; l.TextSize = 12; l.TextColor3 = Theme.dim; l.Text = "no players"; l.Parent = playerBox end
end
local rejoinBtn = makeButton(playersTab, "Rejoin server", function() local ok, err = rejoin(); if ok then statusLbl.Text = "rejoining..."; notify("rejoining", "info") else statusLbl.Text = "rejoin failed: " .. tostring(err); notify("rejoin failed: " .. tostring(err), "err") end end, false); rejoinBtn.LayoutOrder = 3
local hopBtn = makeButton(playersTab, "Server hop", function() statusLbl.Text = "searching servers..."; notify("searching servers", "info"); local ok, err = serverHop(); if ok then statusLbl.Text = "hopping..."; notify("hopping", "ok") else statusLbl.Text = "hop failed: " .. tostring(err); notify("hop failed: " .. tostring(err), "err") end end, false); hopBtn.LayoutOrder = 4
local refreshBtn = makeButton(playersTab, "Refresh list", refreshPlayerList, false); refreshBtn.LayoutOrder = 5

-- WAY
local wayTab = newTab("way")
local wayStatus = Instance.new("TextLabel"); wayStatus.Size = UDim2.new(1, 0, 0, 14); wayStatus.BackgroundTransparency = 1; wayStatus.Font = Enum.Font.GothamMedium; wayStatus.TextSize = 10; wayStatus.TextColor3 = Theme.dim; wayStatus.TextXAlignment = Enum.TextXAlignment.Left; wayStatus.Text = "saved this session"; wayStatus.LayoutOrder = 1; wayStatus.Parent = wayTab
local wayBox = Instance.new("Frame"); wayBox.Size = UDim2.new(1, 0, 0, 0); wayBox.AutomaticSize = Enum.AutomaticSize.Y; wayBox.BackgroundTransparency = 1; wayBox.LayoutOrder = 2; wayBox.Parent = wayTab
local wayLayout = Instance.new("UIListLayout"); wayLayout.Padding = UDim.new(0, 4); wayLayout.SortOrder = Enum.SortOrder.LayoutOrder; wayLayout.Parent = wayBox

refreshWaypointList = function()
    for _, child in ipairs(wayBox:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
    local names = {}; for name in pairs(waypoints) do table.insert(names, name) end; table.sort(names)
    if #names == 0 then local l = Instance.new("TextLabel"); l.Size = UDim2.new(1, 0, 0, 24); l.BackgroundTransparency = 1; l.Font = Enum.Font.GothamMedium; l.TextSize = 12; l.TextColor3 = Theme.dim; l.Text = "no waypoints"; l.Parent = wayBox; return end
    for i, name in ipairs(names) do
        local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 34); row.BackgroundColor3 = Theme.card; row.BorderSizePixel = 0; row.LayoutOrder = i; row.Parent = wayBox; corner(row, 8)
        local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, -100, 1, 0); lbl.Position = UDim2.fromOffset(10, 0); lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 11; lbl.TextColor3 = Theme.text; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Text = name; lbl.Parent = row
        local tpBtn = Instance.new("TextButton"); tpBtn.Size = UDim2.fromOffset(42, 26); tpBtn.Position = UDim2.new(1, -92, 0.5, -13); tpBtn.BackgroundColor3 = Theme.accent; tpBtn.BorderSizePixel = 0; tpBtn.Font = Enum.Font.GothamBold; tpBtn.TextSize = 11; tpBtn.TextColor3 = Color3.fromRGB(255, 255, 255); tpBtn.Text = "TP"; tpBtn.Parent = row; corner(tpBtn, 7)
        tpBtn.MouseButton1Click:Connect(function() local ok, err = tpWaypoint(name); wayStatus.Text = ok and ("tp -> " .. name) or ("tp failed: " .. tostring(err)); notify(ok and ("tp -> " .. name) or ("tp failed: " .. tostring(err)), ok and "ok" or "err") end)
        local delBtn = Instance.new("TextButton"); delBtn.Size = UDim2.fromOffset(42, 26); delBtn.Position = UDim2.new(1, -46, 0.5, -13); delBtn.BackgroundColor3 = Theme.cardHi; delBtn.BorderSizePixel = 0; delBtn.Font = Enum.Font.GothamBold; delBtn.TextSize = 11; delBtn.TextColor3 = Color3.fromRGB(255, 120, 120); delBtn.Text = "del"; delBtn.Parent = row; corner(delBtn, 7)
        delBtn.MouseButton1Click:Connect(function() deleteWaypoint(name); refreshWaypointList(); wayStatus.Text = "deleted " .. name; notify("deleted " .. name, "warn") end)
    end
end
local saveBtn = makeButton(wayTab, "Save current position", function() local name, err = saveWaypoint(); if name then refreshWaypointList(); wayStatus.Text = "saved " .. name; notify("saved " .. name, "ok") else wayStatus.Text = "save failed: " .. tostring(err); notify("save failed: " .. tostring(err), "err") end end, true); saveBtn.LayoutOrder = 3
local refreshWayBtn = makeButton(wayTab, "Refresh list", refreshWaypointList, false); refreshWayBtn.LayoutOrder = 4

-- SRV
local srvTab = newTab("srv")
local srvStatus = Instance.new("TextLabel"); srvStatus.Size = UDim2.new(1, 0, 0, 14); srvStatus.BackgroundTransparency = 1; srvStatus.Font = Enum.Font.GothamMedium; srvStatus.TextSize = 10; srvStatus.TextColor3 = Theme.dim; srvStatus.TextXAlignment = Enum.TextXAlignment.Left; srvStatus.Text = ""; srvStatus.LayoutOrder = 1; srvStatus.Parent = srvTab
local srvBox = Instance.new("Frame"); srvBox.Size = UDim2.new(1, 0, 0, 0); srvBox.AutomaticSize = Enum.AutomaticSize.Y; srvBox.BackgroundTransparency = 1; srvBox.LayoutOrder = 2; srvBox.Parent = srvTab
local srvLayout = Instance.new("UIListLayout"); srvLayout.Padding = UDim.new(0, 4); srvLayout.SortOrder = Enum.SortOrder.LayoutOrder; srvLayout.Parent = srvBox
local sessionStart = os.clock()

local function pingMs() local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end); if ok and type(v) == "number" and v >= 0 then return math.floor(v) end; local ok2, v2 = pcall(function() return math.floor(LP:GetNetworkPing() * 1000) end); if ok2 and type(v2) == "number" then return v2 end; return nil end
local function readMemory() local ok, v = pcall(function() return Stats:GetTotalMemoryUsageMb() end); if ok and type(v) == "number" then return math.floor(v) end; local ok2, v2 = pcall(function() return math.floor(gcinfo() / 1024) end); if ok2 and type(v2) == "number" then return v2 end; return nil end

local function serverRow(key, layoutOrder)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 30); row.BackgroundColor3 = Theme.card; row.BorderSizePixel = 0; row.LayoutOrder = layoutOrder; row.Parent = srvBox; corner(row, 8)
    local k = Instance.new("TextLabel"); k.Size = UDim2.new(0.42, 0, 1, 0); k.Position = UDim2.fromOffset(10, 0); k.BackgroundTransparency = 1; k.Font = Enum.Font.GothamMedium; k.TextSize = 11; k.TextColor3 = Theme.dim; k.TextXAlignment = Enum.TextXAlignment.Left; k.Text = key; k.Parent = row
    local v = Instance.new("TextLabel"); v.Size = UDim2.new(0.58, -10, 1, 0); v.Position = UDim2.new(0.42, 0, 0, 0); v.BackgroundTransparency = 1; v.Font = Enum.Font.GothamBold; v.TextSize = 11; v.TextColor3 = Theme.text; v.TextXAlignment = Enum.TextXAlignment.Right; v.TextTruncate = Enum.TextTruncate.AtEnd; v.Text = "--"; v.Parent = row; return v
end

local playerInfoLbl = serverRow("Player info", 1); local jobIdLbl = serverRow("JobId", 2); local placeIdLbl = serverRow("PlaceId", 3); local versionLbl = serverRow("PlaceVersion", 4); local playersLbl = serverRow("Players", 5); local pingLbl = serverRow("Ping", 6); local memLbl = serverRow("Memory", 7); local uptimeLbl = serverRow("Session uptime", 8); local streamingLbl = serverRow("Streaming", 9); local gravityLbl = serverRow("Gravity", 10); local regionLbl = serverRow("Region", 11)

refreshServerInfo = function()
    pcall(function() playerInfoLbl.Text = LP.Name .. " (" .. LP.UserId .. ")" end)
    pcall(function() jobIdLbl.Text = game.JobId ~= "" and game.JobId or "(private)" end)
    pcall(function() placeIdLbl.Text = tostring(game.PlaceId) end)
    pcall(function() versionLbl.Text = tostring(game.PlaceVersion) end)
    pcall(function() playersLbl.Text = string.format("%d / %d", #Players:GetPlayers(), Players.MaxPlayers) end)
    pcall(function() local p = pingMs(); pingLbl.Text = p and (tostring(p) .. " ms") or "--" end)
    pcall(function() local m = readMemory(); memLbl.Text = m and (tostring(m) .. " MB") or "--" end)
    pcall(function() local s = math.floor(os.clock() - sessionStart); uptimeLbl.Text = string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60) end)
    pcall(function() streamingLbl.Text = tostring(workspace.StreamingEnabled) end)
    pcall(function() gravityLbl.Text = string.format("%.0f", workspace.Gravity) end)
    pcall(function()
        local region = "Unknown"
        if RunService:IsStudio() then region = "Studio" else
            local p = pingMs()
            if p then
                if p < 40 then region = "Local/NA"
                elseif p < 80 then region = "EU/NA"
                elseif p < 130 then region = "ASIA"
                else region = "Far" end
            end
        end
        regionLbl.Text = region
    end)
end

local copyBtn = makeButton(srvTab, "Copy JobId", function()
    local jid = game.JobId
    if jid == "" then srvStatus.Text = "no job id (private server)"; notify("no job id", "warn"); return end
    local ok = false; if type(setclipboard) == "function" then ok = pcall(setclipboard, jid) end; if not ok and type(toclipboard) == "function" then ok = pcall(toclipboard, jid) end
    srvStatus.Text = ok and "copied job id" or "clipboard unavailable"; notify(ok and "copied job id" or "clipboard unavailable", ok and "ok" or "err")
end, false); copyBtn.LayoutOrder = 11
local srvRefreshBtn = makeButton(srvTab, "Refresh info", function() refreshServerInfo(); srvStatus.Text = "refreshed"; notify("server info refreshed", "ok") end, false); srvRefreshBtn.LayoutOrder = 12

coroutine.wrap(function() while not destroyed do if activeTab == "srv" and refreshServerInfo then pcall(refreshServerInfo) end; wait(1) end end)()

-- stats overlay
local statsFrame = Instance.new("Frame"); statsFrame.Size = UDim2.fromOffset(220, 24); statsFrame.AnchorPoint = Vector2.new(0.5, 0); statsFrame.Position = UDim2.new(0.5, 0, 0, 10); statsFrame.BackgroundColor3 = Theme.bg; statsFrame.BackgroundTransparency = 0.3; statsFrame.BorderSizePixel = 0; statsFrame.Visible = false; statsFrame.ZIndex = 20; statsFrame.Parent = gui; corner(statsFrame, 12)
local statsStroke = Instance.new("UIStroke"); statsStroke.Color = Theme.line; statsStroke.Thickness = 1; statsStroke.Transparency = 0.35; statsStroke.Parent = statsFrame
local statsLabel = Instance.new("TextLabel"); statsLabel.Size = UDim2.new(1, 0, 1, 0); statsLabel.BackgroundTransparency = 1; statsLabel.Font = Enum.Font.GothamBold; statsLabel.TextSize = 11; statsLabel.TextColor3 = Theme.text; statsLabel.Text = "FPS --   |   -- ms   |   -- MB"; statsLabel.Parent = statsFrame
local statFrames, statFps, lastStatTime = 0, 0, tick()

coroutine.wrap(function()
    while not destroyed do
        local now = tick()
        local elapsed = now - lastStatTime
        if elapsed >= 1 then
            statFps = math.floor(statFrames / elapsed + 0.5)
            statFrames = 0
            lastStatTime = now
        end
        if state.stats then
            local p = pingMs(); local m = readMemory()
            local fpsText = tostring(statFps)
            local pingText = p and (tostring(p) .. " ms") or "--"
            local memText = m and (tostring(m) .. " MB") or "--"
            statsLabel.Text = string.format("FPS %s   |   %s   |   %s", fpsText, pingText, memText)
            if statFps < 30 or (p and p > 150) then statsLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
            elseif statFps < 45 or (p and p > 80) then statsLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
            else statsLabel.TextColor3 = Theme.text end
            statsFrame.Visible = true
        else statsFrame.Visible = false end
        wait(0.25)
    end
end)()

local fovCircle = nil
if DrawingLib then local ok, circle = pcall(function() local c = DrawingLib.new("Circle"); c.Thickness = 1; c.Filled = false; c.Transparency = 0.6; c.Color = Theme.accent; c.Visible = false; return c end); if ok then fovCircle = circle end end

local function frameStep(dt)
    if destroyed then return end
    statFrames = statFrames + 1
    iridescentOffset = (iridescentOffset + dt * 0.15) % 1
    mainGradient.Offset = Vector2.new(iridescentOffset, 0)
    reopenGradient.Offset = Vector2.new(iridescentOffset, 0)
    mainGlowGradient.Offset = Vector2.new(iridescentOffset, 0)
    reopenGlowGradient.Offset = Vector2.new(iridescentOffset, 0)

    if state.aimbot then aimStep(dt) end; if state.triggerbot then triggerStep() end; if state.fly then flyStep() end; if state.spin then spinStep(dt) end; if state.esp or next(espItems) or next(espHighlights) then espStep() end
    if fovCircle then local cam = workspace.CurrentCamera; if state.aimbot and cam then fovCircle.Position = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5); fovCircle.Radius = state.fov; fovCircle.Visible = true else fovCircle.Visible = false end end
end
local bound = pcall(function() RunService:UnbindFromRenderStep("AeroFrame"); RunService:BindToRenderStep("AeroFrame", Enum.RenderPriority.Camera.Value + 1, frameStep) end); if not bound then RunService.RenderStepped:Connect(frameStep) end

local sliderConn = UserInputService.InputChanged:Connect(function(input) if destroyed or not activeSlider then return end; if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement then activeSlider(input.Position.X) end end)
local sliderEndConn = UserInputService.InputEnded:Connect(function(input) if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then activeSlider = nil end end)

local function isOverRect(x, y, obj) if not obj or not obj.Visible then return false end; local ap = obj.AbsolutePosition; local asz = obj.AbsoluteSize; return x >= ap.X and x <= ap.X + asz.X and y >= ap.Y and y <= ap.Y + asz.Y end
local clickTpConn = UserInputService.InputBegan:Connect(function(input, processed)
    if destroyed or not state.clickTp or processed then return end
    if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local x, y = input.Position.X, input.Position.Y; if isOverRect(x, y, main) or isOverRect(x, y, reopen) then return end
    local cam = workspace.CurrentCamera; if not cam then return end; local inset = GuiService:GetGuiInset(); local ray = cam:ViewportPointToRay(x - inset.X, y - inset.Y)
    local filter = {}; local myChar = getChar(); if myChar then table.insert(filter, myChar) end; local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude; params.FilterDescendantsInstances = filter
    local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params); if hit then teleportToPosition(hit.Position + Vector3.new(0, 3, 0)) end
end)

local jumpConn = UserInputService.JumpRequest:Connect(function() if destroyed or not state.infJump then return end; local h = getHum(); if h and h.Health > 0 then h:ChangeState(Enum.HumanoidStateType.Jumping) end end)
local charConn = LP.CharacterAdded:Connect(function() coroutine.wrap(function() wait(0.6); if destroyed then return end; applyStats(); clearFlyInput(); if state.fly then setFly(true) end; if state.esp then clearESP() end end)() end)

coroutine.wrap(function() while not destroyed do if state.lockStats then local h = getHum(); if h and h.Health > 0 then if h.WalkSpeed ~= state.speed then h.WalkSpeed = state.speed end; if h.UseJumpPower ~= true then pcall(function() h.UseJumpPower = true end) end; if h.JumpPower ~= state.jump then h.JumpPower = state.jump end end end; wait(0.4) end end)()

local camConn = nil; if workspace.CurrentCamera then camConn = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function() pcall(layoutPanel) end) end

destroy = function()
    if destroyed then return end; destroyed = true
    pcall(function() RunService:UnbindFromRenderStep("AeroFrame") end)
    for _, conn in ipairs({ dragConn, sliderConn, sliderEndConn, clickTpConn, jumpConn, charConn, camConn, bhopConn }) do if conn then pcall(function() conn:Disconnect() end) end end
    pcall(function() if state.fly then setFly(false) end end); pcall(function() if state.bhop then setBhop(false) end end); pcall(clearESP); pcall(setFullbright, false); pcall(setFpsBoost, false)
    if fovCircle then pcall(function() fovCircle:Remove() end) end; pcall(function() gui:Destroy() end)
    state.esp = false; state.spin = false
    if getgenv then getgenv().__Aero = nil end
end

if getgenv then
    getgenv().__Aero = { destroy = destroy, state = state, notify = notify, applyTheme = applyTheme, themes = THEMES, teleport = safeTeleport, rejoin = rejoin, serverHop = serverHop, waypoints = waypoints, saveWaypoint = saveWaypoint, refreshServerInfo = refreshServerInfo, saveConfig = saveConfig, loadConfig = loadConfig }
end

pcall(function()
    applyTheme(state.theme)
    layoutPanel()
    refreshPlayerList()
    refreshWaypointList()
    refreshServerInfo()
    refreshThemeButtons()
    showTab("move")
    syncUI()
end)
