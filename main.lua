--[[
  Universal Cheat Framework — Delta / Fluent
  Author: Aero
  Version: 2.0.0
  Requires: Delta Executor (Drawing, VirtualUser, writefile optional)
  UI: Fluent (loaded from official releases)
  Architecture: Core + Modules + UI
]]

--============================================================
-- 0. Guard / environment
--============================================================
local ENV = getgenv and getgenv() or _G
if ENV.__UCF_LOADED then
    warn("[UCF] already loaded, aborting duplicate")
    return
end
ENV.__UCF_LOADED = true

local Services = {
    Players      = game:GetService("Players"),
    RunService   = game:GetService("RunService"),
    UserInput    = game:GetService("UserInputService"),
    TweenService = game:GetService("TweenService"),
    Workspace    = game:GetService("Workspace"),
    CoreGui      = game:GetService("CoreGui"),
    HttpService  = game:GetService("HttpService"),
    Lighting     = game:GetService("Lighting"),
    VirtualUser  = game:GetService("VirtualUser"),
}
local LP = Services.Players.LocalPlayer
local Camera = Services.Workspace.CurrentCamera

--============================================================
-- 1. Fluent loader (official releases URL)
--============================================================
local Fluent
do
    local ok, res = pcall(function()
        return loadstring(game:HttpGet(
            "https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"
        ))()
    end)
    if ok and type(res) == "table" then
        Fluent = res
    else
        warn("[UCF] Fluent load failed: " .. tostring(res))
        return
    end
end

--============================================================
-- 2. Utilities
--============================================================
local U = {}

function U.safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn("[UCF] error: " .. tostring(err)) end
    return ok, err
end

function U.notify(title, text, duration)
    U.safe(function()
        Fluent:Notify({ Title = title, Content = text, Duration = duration or 3 })
    end)
end

function U.getChar()
    return LP.Character or LP.CharacterAdded:Wait()
end

function U.getHum()
    local c = U.getChar()
    return c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("HumanoidRootPart")
end

function U.alive()
    local h, hrp = U.getHum()
    return h ~= nil and hrp ~= nil and h.Health > 0
end

function U.getAlivePlayers(excludeLocal)
    local out = {}
    for _, p in ipairs(Services.Players:GetPlayers()) do
        if (not excludeLocal or p ~= LP) and p.Character then
            local h = p.Character:FindFirstChildOfClass("Humanoid")
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            if h and hrp and h.Health > 0 then
                table.insert(out, p)
            end
        end
    end
    return out
end

function U.makeDrawing(class, props)
    local obj
    local ok = pcall(function() obj = Drawing.new(class) end)
    if not ok then return nil end
    if props then
        for k, v in pairs(props) do pcall(function() obj[k] = v end) end
    end
    return obj
end

function U.writeFile(path, data)
    if writefile then
        local ok = pcall(writefile, path, data)
        if ok then return true end
    end
    ENV["__UCF_FILE_" .. path] = data
    return false
end

function U.readFile(path)
    if readfile and isfile and isfile(path) then
        local ok, res = pcall(readfile, path)
        if ok then return res end
    end
    return ENV["__UCF_FILE_" .. path]
end

--============================================================
-- 3. Module registry
--============================================================
local Modules = {}
local ModuleOrder = {}

local function Register(mod)
    assert(type(mod) == "table" and mod.name, "bad module")
    mod.enabled = false
    mod.settings = mod.settings or {}
    Modules[mod.name] = mod
    table.insert(ModuleOrder, mod.name)
end

--============================================================
-- 4. Modules
--============================================================

-- ---------- ESP ----------
Register({
    name = "ESP",
    desc = "Highlights players through walls",
    settings = { Boxes = true, Names = true, Health = true, Distance = true,
                 Tracers = false, TeamCheck = false, MaxDistance = 1000 },
    _cache = {}, _conn = nil,

    _make = function(self)
        local draw = {
            Box    = U.makeDrawing("Rectangle", { Thickness = 1, Filled = false, Color = Color3.fromRGB(255, 60, 60) }),
            Name   = U.makeDrawing("Text", { Size = 14, Center = true, Outline = true }),
            Health = U.makeDrawing("Text", { Size = 12, Center = false, Outline = true }),
            Dist   = U.makeDrawing("Text", { Size = 12, Center = true, Outline = true }),
            Tracer = U.makeDrawing("Line", { Thickness = 1, Color = Color3.fromRGB(255, 60, 60) }),
        }
        if not draw.Box and not draw.Name then
            draw.Box = U.makeDrawing("Square", { Thickness = 1, Filled = false, Color = Color3.fromRGB(255, 60, 60) })
        end
        if not (draw.Box or draw.Name) then return nil end
        return draw
    end,

    _update = function(self)
        if not U.alive() then
            for _, d in pairs(self._cache) do
                for _, obj in pairs(d) do pcall(function() obj:Remove() end) end
            end
            self._cache = {}
            return
        end

        local seen = {}
        local _, myHRP = U.getHum()
        local myPos = myHRP and myHRP.Position
        local viewport = Camera.ViewportSize

        for _, plr in ipairs(U.getAlivePlayers(true)) do
            if not (self.settings.TeamCheck and plr.Team == LP.Team) then
                seen[plr] = true
                local draw = self._cache[plr]
                if not draw then
                    draw = self._make(self)
                    if draw then self._cache[plr] = draw end
                end
                if draw then
                    local char = plr.Character
                    local hrp = char and char:FindFirstChild("HumanoidRootPart")
                    local hum = char and char:FindFirstChildOfClass("Humanoid")
                    local head = char and char:FindFirstChild("Head")
                    if hrp and hum and head and hum.Health > 0 then
                        local dist = (Camera.CFrame.Position - hrp.Position).Magnitude
                        local onScreen, screenPos = Camera:WorldToViewportPoint(hrp.Position)
                        local visible = onScreen and dist <= self.settings.MaxDistance
                        local headScreen = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.5, 0))
                        local footScreen = Camera:WorldToViewportPoint(hrp.Position - Vector3.new(0, 3, 0))

                        if visible and draw.Box and draw.Name then
                            local h = math.abs(headScreen.Y - footScreen.Y)
                            local w = h * 0.55
                            local x = screenPos.X - w / 2
                            local y = headScreen.Y

                            draw.Box.Visible = self.settings.Boxes
                            if self.settings.Boxes then
                                draw.Box.Size = Vector2.new(w, h)
                                draw.Box.Position = Vector2.new(x, y)
                            end

                            draw.Name.Visible = self.settings.Names
                            if self.settings.Names then
                                draw.Name.Text = plr.Name
                                draw.Name.Position = Vector2.new(screenPos.X, y - 18)
                            end

                            draw.Health.Visible = self.settings.Health
                            if self.settings.Health then
                                draw.Health.Text = string.format("HP: %d", math.floor(hum.Health))
                                draw.Health.Color = Color3.fromRGB(255, math.floor(255 * hum.Health / hum.MaxHealth), 0)
                                draw.Health.Position = Vector2.new(x + w + 4, y)
                            end

                            draw.Dist.Visible = self.settings.Distance
                            if self.settings.Distance then
                                draw.Dist.Text = string.format("%dm", math.floor(dist))
                                draw.Dist.Position = Vector2.new(screenPos.X, y + h + 4)
                            end

                            draw.Tracer.Visible = self.settings.Tracers and myPos ~= nil
                            if draw.Tracer.Visible then
                                draw.Tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                                draw.Tracer.To = Vector2.new(screenPos.X, screenPos.Y)
                            end
                        else
                            for _, obj in pairs(draw) do
                                pcall(function() obj.Visible = false end)
                            end
                        end
                    end
                end
            end
        end

        for plr, draw in pairs(self._cache) do
            if not seen[plr] then
                for _, obj in pairs(draw) do pcall(function() obj:Remove() end) end
                self._cache[plr] = nil
            end
        end
    end,

    enable = function(self)
        self._conn = Services.RunService.RenderStepped:Connect(function()
            U.safe(self._update, self)
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
        for _, draw in pairs(self._cache) do
            for _, obj in pairs(draw) do pcall(function() obj:Remove() end) end
        end
        self._cache = {}
    end,
})

-- ---------- Aimbot ----------
Register({
    name = "Aimbot",
    desc = "Snaps camera to nearest target in FOV",
    settings = { FOV = 120, Smoothness = 0.15, TeamCheck = true, WallCheck = true,
                 HoldKey = true, Key = Enum.UserInputType.MouseButton2, Part = "Head" },
    _conn = nil,

    _getTarget = function(self)
        local fov = self.settings.FOV / 2
        local center = Camera.ViewportSize / 2
        local best, bestDist = nil, math.huge
        for _, plr in ipairs(U.getAlivePlayers(true)) do
            if not (self.settings.TeamCheck and plr.Team == LP.Team) then
                local char = plr.Character
                local part = char and char:FindFirstChild(self.settings.Part)
                if part then
                    local sp = Camera:WorldToViewportPoint(part.Position)
                    if sp.Z > 0 then
                        local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                        if d <= fov and d < bestDist then
                            if self.settings.WallCheck then
                                local ray = Ray.new(Camera.CFrame.Position, (part.Position - Camera.CFrame.Position))
                                local hit = Services.Workspace:FindPartOnRayWithIgnoreList(ray, { LP.Character, Camera })
                                if hit and hit:IsDescendantOf(char) then
                                    best, bestDist = part, d
                                end
                            else
                                best, bestDist = part, d
                            end
                        end
                    end
                end
            end
        end
        return best
    end,

    _step = function(self)
        local target = self._getTarget(self)
        if target then
            local goal = CFrame.new(Camera.CFrame.Position, target.Position)
            Camera.CFrame = Camera.CFrame:Lerp(goal, self.settings.Smoothness)
        end
    end,

    enable = function(self)
        self._conn = Services.RunService.RenderStepped:Connect(function()
            if self.settings.HoldKey and Services.UserInput.IsMouseButtonPressed then
                local ok, pressed = pcall(Services.UserInput.IsMouseButtonPressed, Services.UserInput, self.settings.Key)
                if not ok or not pressed then return end
            end
            U.safe(self._step, self)
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- Fly ----------
Register({
    name = "Fly",
    desc = "Free flight (velocity-based)",
    settings = { Speed = 60 },
    _conn = nil, _bv = nil, _gyro = nil,

    enable = function(self)
        if not U.alive() then U.notify("Fly", "Dead"); return end
        local _, hrp = U.getHum()
        if not hrp then return end

        self._bv = Instance.new("BodyVelocity")
        self._bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
        self._bv.P = 1e4
        self._bv.Velocity = Vector3.zero
        self._bv.Parent = hrp

        self._gyro = Instance.new("BodyGyro")
        self._gyro.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
        self._gyro.P = 1e3
        self._gyro.Parent = hrp

        self._conn = Services.RunService.RenderStepped:Connect(function()
            if not U.alive() then return end
            local cam = Camera.CFrame
            local move = Vector3.zero
            if Services.UserInput:IsKeyDown(Enum.KeyCode.W) then move = move + cam.LookVector end
            if Services.UserInput:IsKeyDown(Enum.KeyCode.S) then move = move - cam.LookVector end
            if Services.UserInput:IsKeyDown(Enum.KeyCode.A) then move = move - cam.RightVector end
            if Services.UserInput:IsKeyDown(Enum.KeyCode.D) then move = move + cam.RightVector end
            if Services.UserInput:IsKeyDown(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
            if Services.UserInput:IsKeyDown(Enum.KeyCode.LeftControl) then move = move - Vector3.new(0, 1, 0) end
            if move.Magnitude > 0 then move = move.Unit * self.settings.Speed end
            self._bv.Velocity = move
            self._gyro.CFrame = cam
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
        if self._bv then self._bv:Destroy() self._bv = nil end
        if self._gyro then self._gyro:Destroy() self._gyro = nil end
    end,
})

-- ---------- Speed ----------
Register({
    name = "Speed",
    desc = "Increases walkspeed",
    settings = { Value = 60 },
    _conn = nil,
    enable = function(self)
        self._conn = Services.RunService.Stepped:Connect(function()
            local h = U.getHum()
            if h then h.WalkSpeed = self.settings.Value end
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
        local h = U.getHum()
        if h then h.WalkSpeed = 16 end
    end,
})

-- ---------- Noclip ----------
Register({
    name = "Noclip",
    desc = "Disables collision with map",
    _conn = nil,
    enable = function(self)
        self._conn = Services.RunService.Stepped:Connect(function()
            local char = U.getChar()
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
            end
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- Teleport ----------
Register({
    name = "Teleport",
    desc = "Teleport to player or coordinates",
    settings = {},
    _teleportTo = function(self, vec3)
        local _, hrp = U.getHum()
        if hrp then hrp.CFrame = CFrame.new(vec3 + Vector3.new(0, 3, 0)) end
    end,
    enable = function() end,
    disable = function() end,
})

-- ---------- Fullbright ----------
Register({
    name = "Fullbright",
    desc = "Removes darkness",
    _saved = nil,
    enable = function(self)
        self._saved = {
            Ambient = Services.Lighting.Ambient,
            OutdoorAmbient = Services.Lighting.OutdoorAmbient,
            Brightness = Services.Lighting.Brightness,
            FogEnd = Services.Lighting.FogEnd,
            FogStart = Services.Lighting.FogStart,
        }
        Services.Lighting.Ambient = Color3.new(1, 1, 1)
        Services.Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
        Services.Lighting.Brightness = 3
        Services.Lighting.FogEnd = 1e9
        Services.Lighting.FogStart = 0
    end,
    disable = function(self)
        if self._saved then
            for k, v in pairs(self._saved) do Services.Lighting[k] = v end
        end
    end,
})

-- ---------- Anti-AFK ----------
Register({
    name = "AntiAFK",
    desc = "Prevents idle kick",
    _conn = nil,
    enable = function(self)
        self._conn = LP.Idled:Connect(function()
            Services.VirtualUser:CaptureController()
            Services.VirtualUser:ClickButton2(Vector2.zero)
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- Infinite Jump ----------
Register({
    name = "InfiniteJump",
    desc = "Jump mid-air",
    _conn = nil,
    enable = function(self)
        self._conn = Services.UserInput.JumpRequest:Connect(function()
            if U.alive() then
                local h = U.getHum()
                if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
            end
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- Walk on Water ----------
Register({
    name = "WalkOnWater",
    desc = "Spawns a platform under your feet",
    _platform = nil, _conn = nil,
    enable = function(self)
        local _, hrp = U.getHum()
        if not hrp then return end
        self._platform = Instance.new("Part")
        self._platform.Size = Vector3.new(6, 1, 6)
        self._platform.Anchored = true
        self._platform.CanCollide = true
        self._platform.Transparency = 1
        self._platform.Name = "UCF_WaterPlatform"
        self._platform.Parent = Services.Workspace
        self._conn = Services.RunService.Stepped:Connect(function()
            local _, h = U.getHum()
            if h and self._platform then
                self._platform.Position = h.Position - Vector3.new(0, 3.5, 0)
            end
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
        if self._platform then self._platform:Destroy() self._platform = nil end
    end,
})

-- ---------- Freeze Players ----------
Register({
    name = "FreezePlayers",
    desc = "Anchors all other players in place",
    _saved = {}, _conn = nil,
    enable = function(self)
        self._conn = Services.RunService.Heartbeat:Connect(function()
            for _, p in ipairs(Services.Players:GetPlayers()) do
                if p ~= LP and p.Character then
                    local hrp = p.Character:FindFirstChild("HumanoidRootPart")
                    if hrp and not self._saved[hrp] then
                        self._saved[hrp] = hrp.Anchored
                        hrp.Anchored = true
                    end
                end
            end
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
        for part, prev in pairs(self._saved) do
            if part and part.Parent then part.Anchored = prev end
        end
        self._saved = {}
    end,
})

-- ---------- Hitbox Expander ----------
Register({
    name = "HitboxExpander",
    desc = "Enlarges player hitboxes",
    settings = { Size = 6, Part = "HumanoidRootPart" },
    _saved = {}, _conn = nil,
    enable = function(self)
        self._conn = Services.RunService.Heartbeat:Connect(function()
            for _, p in ipairs(U.getAlivePlayers(true)) do
                local part = p.Character and p.Character:FindFirstChild(self.settings.Part)
                if part and not self._saved[part] then
                    self._saved[part] = part.Size
                end
                if part then
                    local s = self.settings.Size
                    part.Size = Vector3.new(s, s, s)
                    part.Transparency = 0.7
                    part.CanCollide = false
                end
            end
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
        for part, size in pairs(self._saved) do
            if part and part.Parent then
                part.Size = size
                part.Transparency = 0
                part.CanCollide = true
            end
        end
        self._saved = {}
    end,
})

-- ---------- Kill Aura ----------
Register({
    name = "KillAura",
    desc = "Auto-attacks nearby players (fires Tool)",
    settings = { Range = 30, Delay = 0.25 },
    _conn = nil, _last = 0,
    enable = function(self)
        self._conn = Services.RunService.Heartbeat:Connect(function()
            if os.clock() - self._last < self.settings.Delay then return end
            local _, myHRP = U.getHum()
            if not myHRP then return end
            for _, p in ipairs(U.getAlivePlayers(true)) do
                local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
                if hrp and (hrp.Position - myHRP.Position).Magnitude <= self.settings.Range then
                    local tool = U.getChar():FindFirstChildOfClass("Tool")
                    if tool then
                        pcall(function() tool:Activate() end)
                    end
                    break
                end
            end
            self._last = os.clock()
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- Auto Clicker ----------
Register({
    name = "AutoClicker",
    desc = "Clicks automatically",
    settings = { Delay = 0.1 },
    _conn = nil, _last = 0,
    enable = function(self)
        self._conn = Services.RunService.Heartbeat:Connect(function()
            if os.clock() - self._last < self.settings.Delay then return end
            Services.VirtualUser:CaptureController()
            Services.VirtualUser:ClickButton1(Vector2.new(0, 0), Camera.CFrame)
            self._last = os.clock()
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- Gravity Control ----------
Register({
    name = "GravityControl",
    desc = "Modifies workspace gravity",
    settings = { Value = 196.2 },
    _saved = nil,
    enable = function(self)
        self._saved = Services.Workspace.Gravity
        Services.Workspace.Gravity = self.settings.Value
    end,
    disable = function(self)
        if self._saved then Services.Workspace.Gravity = self._saved end
    end,
})

-- ---------- Anti-Fling ----------
Register({
    name = "AntiFling",
    desc = "Removes external BodyVelocity/AngularVelocity on your HRP",
    _conn = nil,
    enable = function(self)
        self._conn = Services.RunService.Heartbeat:Connect(function()
            local _, hrp = U.getHum()
            if not hrp then return end
            for _, child in ipairs(hrp:GetChildren()) do
                if child:IsA("BodyVelocity") or child:IsA("BodyAngularVelocity") then
                    if child ~= Modules.Fly._bv and child ~= Modules.Fly._gyro then
                        pcall(function() child:Destroy() end)
                    end
                end
            end
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- Waypoint Save/Load ----------
Register({
    name = "Waypoint",
    desc = "Save/load teleport waypoints",
    settings = { path = "ucf_waypoints.json" },
    enable = function() end,
    disable = function() end,
    _points = nil,
    _load = function(self)
        local raw = U.readFile(self.settings.path)
        if raw then
            local ok, decoded = pcall(function() return Services.HttpService:JSONDecode(raw) end)
            if ok and type(decoded) == "table" then self._points = decoded; return end
        end
        self._points = {}
    end,
    save = function(self, name, vec3)
        if not self._points then self:_load() end
        self._points[name] = { x = vec3.X, y = vec3.Y, z = vec3.Z }
        local ok, encoded = pcall(function() return Services.HttpService:JSONEncode(self._points) end)
        if ok then U.writeFile(self.settings.path, encoded) end
    end,
    get = function(self, name)
        if not self._points then self:_load() end
        local p = self._points[name]
        if p then return Vector3.new(p.x, p.y, p.z) end
        return nil
    end,
})

-- ---------- Chat Spam ----------
Register({
    name = "ChatSpam",
    desc = "Repeats a message periodically",
    settings = { Message = "UCF was here", Delay = 2 },
    _conn = nil, _last = 0,
    enable = function(self)
        self._conn = Services.RunService.Heartbeat:Connect(function()
            if os.clock() - self._last < self.settings.Delay then return end
            pcall(function()
                local events = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
                if events then
                    local say = events:FindFirstChild("SayMessageRequest")
                    if say then say:FireServer(self.settings.Message, "All") end
                end
            end)
            self._last = os.clock()
        end)
    end,
    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

--============================================================
-- 5. UI (Fluent)
--============================================================
local Window = Fluent:CreateWindow({
    Title = "UCF · Delta",
    SubTitle = "v2.0.0 · Universal Cheat Framework",
    TabWidth = 160,
    Size = UDim2.fromOffset(580, 460),
    Acrylic = true,
    Theme = "Dark",
})

local Tabs = {
    Main     = Window:AddTab({ Title = "Main", Icon = "home" }),
    Visual   = Window:AddTab({ Title = "Visual", Icon = "eye" }),
    Combat   = Window:AddTab({ Title = "Combat", Icon = "crosshair" }),
    Movement = Window:AddTab({ Title = "Movement", Icon = "move" }),
    Utility  = Window:AddTab({ Title = "Utility", Icon = "tool" }),
    Settings = Window:AddTab({ Title = "Settings", Icon = "settings" }),
}

local function Toggle(name, tab, description)
    local mod = Modules[name]
    if not mod then return end
    tab:AddToggle(name, {
        Title = name,
        Description = description or mod.desc,
        Default = false,
        Callback = function(v)
            if v then U.safe(mod.enable, mod); mod.enabled = true
            else U.safe(mod.disable, mod); mod.enabled = false end
        end,
    })
end

-- Main
Toggle("AntiAFK", Tabs.Main)
Toggle("Teleport", Tabs.Main)
Tabs.Main:AddButton({
    Title = "Teleport to nearest player",
    Callback = function()
        local players = U.getAlivePlayers(true)
        if #players == 0 then U.notify("Teleport", "No targets"); return end
        local _, myHRP = U.getHum()
        local target = players[1]
        local bestDist = math.huge
        for _, p in ipairs(players) do
            local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            if hrp and myHRP then
                local d = (hrp.Position - myHRP.Position).Magnitude
                if d < bestDist then target = p; bestDist = d end
            end
        end
        local hrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
        if hrp then Modules.Teleport:_teleportTo(hrp.Position) end
    end,
})
Tabs.Main:AddButton({
    Title = "Save current position",
    Callback = function()
        local _, hrp = U.getHum()
        if hrp then
            Modules.Waypoint:save("last", hrp.Position)
            U.notify("Waypoint", "Saved last position")
        end
    end,
})
Tabs.Main:AddButton({
    Title = "Load last position",
    Callback = function()
        local p = Modules.Waypoint:get("last")
        if p then Modules.Teleport:_teleportTo(p)
        else U.notify("Waypoint", "No saved position") end
    end,
})

-- Visual
Toggle("ESP", Tabs.Visual)
Tabs.Visual:AddToggle("esp_names", { Title = "ESP · Names", Default = true, Callback = function(v) Modules.ESP.settings.Names = v end })
Tabs.Visual:AddToggle("esp_health", { Title = "ESP · Health", Default = true, Callback = function(v) Modules.ESP.settings.Health = v end })
Tabs.Visual:AddToggle("esp_dist", { Title = "ESP · Distance", Default = true, Callback = function(v) Modules.ESP.settings.Distance = v end })
Tabs.Visual:AddToggle("esp_tracers", { Title = "ESP · Tracers", Default = false, Callback = function(v) Modules.ESP.settings.Tracers = v end })
Tabs.Visual:AddSlider("esp_maxdist", { Title = "ESP · Max Distance", Default = 1000, Min = 50, Max = 5000, Rounding = 0, Callback = function(v) Modules.ESP.settings.MaxDistance = v end })
Toggle("Fullbright", Tabs.Visual)

-- Combat
Toggle("Aimbot", Tabs.Combat)
Tabs.Combat:AddSlider("aim_fov", { Title = "Aimbot · FOV", Default = 120, Min = 10, Max = 360, Rounding = 0, Callback = function(v) Modules.Aimbot.settings.FOV = v end })
Tabs.Combat:AddSlider("aim_smooth", { Title = "Aimbot · Smooth", Default = 15, Min = 1, Max = 100, Rounding = 0, Callback = function(v) Modules.Aimbot.settings.Smoothness = v / 100 end })
Tabs.Combat:AddToggle("aim_wall", { Title = "Aimbot · Wall Check", Default = true, Callback = function(v) Modules.Aimbot.settings.WallCheck = v end })
Tabs.Combat:AddToggle("aim_team", { Title = "Aimbot · Team Check", Default = true, Callback = function(v) Modules.Aimbot.settings.TeamCheck = v end })
Toggle("KillAura", Tabs.Combat)
Tabs.Combat:AddSlider("kill_range", { Title = "KillAura · Range", Default = 30, Min = 5, Max = 100, Rounding = 0, Callback = function(v) Modules.KillAura.settings.Range = v end })
Toggle("HitboxExpander", Tabs.Combat)
Tabs.Combat:AddSlider("hitbox_size", { Title = "Hitbox · Size", Default = 6, Min = 2, Max = 20, Rounding = 0, Callback = function(v) Modules.HitboxExpander.settings.Size = v end })

-- Movement
Toggle("Fly", Tabs.Movement)
Tabs.Movement:AddSlider("fly_speed", { Title = "Fly · Speed", Default = 60, Min = 5, Max = 300, Rounding = 0, Callback = function(v) Modules.Fly.settings.Speed = v end })
Toggle("Speed", Tabs.Movement)
Tabs.Movement:AddSlider("speed_val", { Title = "Speed · Value", Default = 60, Min = 16, Max = 500, Rounding = 0, Callback = function(v) Modules.Speed.settings.Value = v end })
Toggle("Noclip", Tabs.Movement)
Toggle("InfiniteJump", Tabs.Movement)
Toggle("WalkOnWater", Tabs.Movement)
Toggle("GravityControl", Tabs.Movement)
Tabs.Movement:AddSlider("gravity_val", { Title = "Gravity · Value", Default = 196, Min = 0, Max = 500, Rounding = 0, Callback = function(v) Modules.GravityControl.settings.Value = v end })

-- Utility
Toggle("FreezePlayers", Tabs.Utility)
Toggle("AntiFling", Tabs.Utility)
Toggle("AutoClicker", Tabs.Utility)
Tabs.Utility:AddSlider("click_delay", { Title = "AutoClicker · Delay", Default = 10, Min = 1, Max = 100, Rounding = 0, Callback = function(v) Modules.AutoClicker.settings.Delay = v / 100 end })
Toggle("ChatSpam", Tabs.Utility)
Tabs.Utility:AddInput("spam_msg", { Title = "ChatSpam · Message", Default = "UCF was here", Callback = function(v) Modules.ChatSpam.settings.Message = v end })
Tabs.Utility:AddSlider("spam_delay", { Title = "ChatSpam · Delay", Default = 20, Min = 1, Max = 100, Rounding = 0, Callback = function(v) Modules.ChatSpam.settings.Delay = v / 10 end })

-- Settings
Tabs.Settings:AddButton({
    Title = "Unload UCF",
    Callback = function()
        for _, name in ipairs(ModuleOrder) do
            local m = Modules[name]
            if m and m.enabled and m.disable then U.safe(m.disable, m) end
        end
        local ok = pcall(function() Window:Destroy() end)
        if not ok then pcall(function() Window:Close() end) end
        ENV.__UCF_LOADED = nil
    end,
})
Tabs.Settings:AddButton({
    Title = "Print diagnostics",
    Callback = function()
        print("[UCF] Drawing:", type(Drawing))
        print("[UCF] writefile:", type(writefile))
        print("[UCF] modules:", #ModuleOrder)
        print("[UCF] player:", LP.Name)
    end,
})

Window:SelectTab(1)
U.notify("UCF", "Loaded v2.0.0 · " .. tostring(#ModuleOrder) .. " modules", 4)
