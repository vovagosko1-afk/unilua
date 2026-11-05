--[[
  Universal Cheat Framework — Delta / Fluent
  Автор: Aero
  Требования: Delta Executor (Drawing, hookmetamethod, getconnections, firesignal)
  UI: Fluent
  Архитектура: Core + Modules + UI. Каждый модуль = { name, desc, enable, disable, settings }
]]

--============================================================
-- 0. Guard / environment checks
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
}
local LP = Services.Players.LocalPlayer
local Camera = Services.Workspace.CurrentCamera

--============================================================
-- 1. Fluent loader (вставь свой Fluent, если нужен оффлайн)
--============================================================
local Fluent
do
    local ok, res = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Init.lua"))()
    end)
    if ok and type(res) == "table" then
        Fluent = res
    else
        warn("[UCF] Fluent load failed: " .. tostring(res))
        return
    end
end

--============================================================
-- 2. Tiny utilities
--============================================================
local U = {}

function U.safe(fn, ...)
    local args = { ... }
    local ok, err = pcall(function() return fn(table.unpack(args)) end)
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
    return h and hrp and h.Health > 0
end

function U.isLocalPlayer(plr)
    return plr == LP
end

function U.getAlivePlayers()
    local out = {}
    for _, p in ipairs(Services.Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local h = p.Character:FindFirstChildOfClass("Humanoid")
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            if h and hrp and h.Health > 0 then
                table.insert(out, p)
            end
        end
    end
    return out
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

-- ---------- 4.1 ESP ----------
Register({
    name = "ESP",
    desc = "Highlights players through walls",
    settings = {
        Boxes = true,
        Names = true,
        Health = true,
        Distance = true,
        Tracers = false,
        TeamCheck = false,
        MaxDistance = 1000,
    },
    _cache = {},
    _conn = nil,

    _make = function(self, plr)
        local draw = {}
        local ok = pcall(function()
            draw.Box = Drawing.new("Square")
            draw.Box.Thickness = 1
            draw.Box.Filled = false
            draw.Box.Color = Color3.fromRGB(255, 60, 60)

            draw.Name = Drawing.new("Text")
            draw.Name.Size = 14
            draw.Name.Center = true
            draw.Name.Outline = true

            draw.Health = Drawing.new("Text")
            draw.Health.Size = 12
            draw.Health.Center = false
            draw.Health.Outline = true

            draw.Dist = Drawing.new("Text")
            draw.Dist.Size = 12
            draw.Dist.Center = true
            draw.Dist.Outline = true

            draw.Tracer = Drawing.new("Line")
            draw.Tracer.Thickness = 1
            draw.Tracer.Color = Color3.fromRGB(255, 60, 60)
        end)
        if not ok then return nil end
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
        local myPos = U.getHum() and select(2, U.getHum()).Position
        local viewport = Camera.ViewportSize

        for _, plr in ipairs(U.getAlivePlayers()) do
            if self.settings.TeamCheck and plr.Team == LP.Team then
                -- skip
            else
                seen[plr] = true
                local draw = self._cache[plr]
                if not draw then
                    draw = self._make(plr)
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

                        if visible then
                            local h = math.abs(headScreen.Y - footScreen.Y)
                            local w = h * 0.55
                            local x = screenPos.X - w / 2
                            local y = headScreen.Y

                            if self.settings.Boxes then
                                draw.Box.Visible = true
                                draw.Box.Size = Vector2.new(w, h)
                                draw.Box.Position = Vector2.new(x, y)
                            else
                                draw.Box.Visible = false
                            end

                            if self.settings.Names then
                                draw.Name.Visible = true
                                draw.Name.Text = plr.Name
                                draw.Name.Position = Vector2.new(screenPos.X, y - 18)
                            else
                                draw.Name.Visible = false
                            end

                            if self.settings.Health then
                                draw.Health.Visible = true
                                draw.Health.Text = string.format("HP: %d", math.floor(hum.Health))
                                draw.Health.Color = Color3.fromRGB(255, math.floor(255 * hum.Health / hum.MaxHealth), 0)
                                draw.Health.Position = Vector2.new(x + w + 4, y)
                            else
                                draw.Health.Visible = false
                            end

                            if self.settings.Distance then
                                draw.Dist.Visible = true
                                draw.Dist.Text = string.format("%dm", math.floor(dist))
                                draw.Dist.Position = Vector2.new(screenPos.X, y + h + 4)
                            else
                                draw.Dist.Visible = false
                            end

                            if self.settings.Tracers and myPos then
                                local myScreen = Camera:WorldToViewportPoint(myPos)
                                draw.Tracer.Visible = true
                                draw.Tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                                draw.Tracer.To = Vector2.new(screenPos.X, screenPos.Y)
                            else
                                draw.Tracer.Visible = false
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

-- ---------- 4.2 Aimbot ----------
Register({
    name = "Aimbot",
    desc = "Snaps camera to nearest target in FOV",
    settings = {
        FOV = 120,
        Smoothness = 0.15,
        TeamCheck = true,
        WallCheck = true,
        HoldKey = true,
        Key = Enum.UserInputType.MouseButton2,
        Part = "Head",
    },
    _conn = nil,
    _draw = nil,

    _getTarget = function(self)
        local fov = self.settings.FOV / 2
        local center = Camera.ViewportSize / 2
        local best, bestDist = nil, math.huge

        for _, plr in ipairs(U.getAlivePlayers()) do
            if self.settings.TeamCheck and plr.Team == LP.Team then continue end
            local char = plr.Character
            local part = char and char:FindFirstChild(self.settings.Part)
            if part then
                local sp = Camera:WorldToViewportPoint(part.Position)
                if sp.Z > 0 then
                    local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if d <= fov and d < bestDist then
                        if self.settings.WallCheck then
                            local ray = Ray.new(Camera.CFrame.Position, (part.Position - Camera.CFrame.Position))
                            local hit = Services.Workspace:FindPartOnRayWithIgnoreList(ray, {LP.Character, Camera})
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
        return best
    end,

    _step = function(self)
        local target = self._getTarget()
        if target then
            local goal = CFrame.new(Camera.CFrame.Position, target.Position)
            Camera.CFrame = Camera.CFrame:Lerp(goal, self.settings.Smoothness)
        end
    end,

    enable = function(self)
        self._conn = Services.RunService.RenderStepped:Connect(function()
            if self.settings.HoldKey and not Services.UserInput.IsMouseButtonPressed(self.settings.Key) then
                return
            end
            U.safe(self._step, self)
        end)
    end,

    disable = function(self)
        if self._conn then self._conn:Disconnect() self._conn = nil end
    end,
})

-- ---------- 4.3 Fly ----------
Register({
    name = "Fly",
    desc = "Free flight (velocity-based)",
    settings = {
        Speed = 60,
        Key = Enum.KeyCode.F,
    },
    _conn = nil,
    _bv = nil,
    _gyro = nil,

    enable = function(self)
        if not U.alive() then U.notify("Fly", "Dead"); return end
        local char = U.getChar()
        local hrp = char:FindFirstChild("HumanoidRootPart")
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
            if move.Magnitude > 0 then
                move = move.Unit * self.settings.Speed
            end
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

-- ---------- 4.4 Speed ----------
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

-- ---------- 4.5 Noclip ----------
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

-- ---------- 4.6 Teleport ----------
Register({
    name = "Teleport",
    desc = "Teleport to player or coordinates",
    settings = { Target = nil },
    _teleportTo = function(self, vec3)
        local h, hrp = U.getHum()
        if hrp then hrp.CFrame = CFrame.new(vec3 + Vector3.new(0, 3, 0)) end
    end,
    enable = function() end,
    disable = function() end,
})

-- ---------- 4.7 Fullbright ----------
Register({
    name = "Fullbright",
    desc = "Removes darkness",
    settings = {},
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

-- ---------- 4.8 Anti-AFK ----------
Register({
    name = "AntiAFK",
    desc = "Prevents idle kick",
    _conn = nil,
    enable = function(self)
        self._conn = Services.Players.LocalPlayer.Idled:Connect(function()
            local vu = game:GetService("VirtualUser")
            vu:CaptureController()
            vu:ClickButton2(Vector2.zero)
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
    SubTitle = "Universal Cheat Framework",
    TabWidth = 160,
    Size = UDim2.fromOffset(540, 420),
    Acrylic = true,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.RightShift,
})

local Tabs = {
    Main = Window:AddTab({ Title = "Main", Icon = "home" }),
    Visual = Window:AddTab({ Title = "Visual", Icon = "eye" }),
    Combat = Window:AddTab({ Title = "Combat", Icon = "crosshair" }),
    Movement = Window:AddTab({ Title = "Movement", Icon = "move" }),
    Settings = Window:AddTab({ Title = "Settings", Icon = "settings" }),
}

local function Toggle(name, tab)
    local mod = Modules[name]
    if not mod then return end
    tab:AddToggle(name, {
        Title = name,
        Description = mod.desc,
        Default = false,
        Callback = function(v)
            if v then
                U.safe(mod.enable, mod)
                mod.enabled = true
            else
                U.safe(mod.disable, mod)
                mod.enabled = false
            end
        end,
    })
end

-- Main
Toggle("AntiAFK", Tabs.Main)
Toggle("Teleport", Tabs.Main)
Tabs.Main:AddButton({
    Title = "Teleport to player…",
    Description = "Picks nearest alive player",
    Callback = function()
        local players = U.getAlivePlayers()
        if #players == 0 then U.notify("Teleport", "No targets") return end
        local target = players[1]
        for _, p in ipairs(players) do
            local hrp1 = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            local hrp2 = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
            if hrp1 and hrp2 and hrp1.Position.Magnitude < hrp2.Position.Magnitude then target = p end
        end
        local hrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
        if hrp then Modules.Teleport:_teleportTo(hrp.Position) end
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

-- Movement
Toggle("Fly", Tabs.Movement)
Tabs.Movement:AddSlider("fly_speed", { Title = "Fly · Speed", Default = 60, Min = 5, Max = 300, Rounding = 0, Callback = function(v) Modules.Fly.settings.Speed = v end })
Toggle("Speed", Tabs.Movement)
Tabs.Movement:AddSlider("speed_val", { Title = "Speed · Value", Default = 60, Min = 16, Max = 500, Rounding = 0, Callback = function(v) Modules.Speed.settings.Value = v end })
Toggle("Noclip", Tabs.Movement)

-- Settings
Tabs.Settings:AddButton({
    Title = "Unload UCF",
    Description = "Disable all modules and close menu",
    Callback = function()
        for _, name in ipairs(ModuleOrder) do
            local m = Modules[name]
            if m and m.enabled and m.disable then U.safe(m.disable, m) end
        end
        Window:Destroy()
        ENV.__UCF_LOADED = nil
    end,
})

Window:SelectTab(1)
U.notify("UCF", "Loaded · " .. tostring(#ModuleOrder) .. " modules", 4)
