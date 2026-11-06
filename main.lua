--[[
    Aero v3.0 - mobile executor UI for Delta (Android)
    Tabs: MOVE / AIM / VIS / TP / PLAY
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
local VirtualUser      = game:GetService("VirtualUser")

local LP = Players.LocalPlayer
if not LP then return end

local DrawingLib = nil
pcall(function()
    if Drawing and type(Drawing.new) == "function" then
        DrawingLib = Drawing
    end
end)

local destroyed = false
local conns = {}

local function track(c)
    if c then table.insert(conns, c) end
    return c
end

-- ============================================================
--  state
-- ============================================================
local state = {
    speed = 16, jump = 50,
    lockStats = false, infJump = false, bhop = false,
    noclip = false, fly = false, flySpeed = 60,
    clickTp = false,
    aimbot = false, fov = 150, smooth = 0.35,
    teamCheck = false, predict = true,
    triggerbot = false, triggerFov = 45,
    spin = false, spinSpeed = 180,
    esp = false, espHealth = true, espTracer = false,
    fullbright = false, stats = false, fpsBoost = false,
    antiAfk = false,
}

-- ============================================================
--  helpers
-- ============================================================
local function getChar() return LP.Character end

local function getHum()
    local c = LP.Character
    if not c then return nil end
    return c:FindFirstChildOfClass("Humanoid")
end

local function getHRP()
    local c = LP.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart
end

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function screenSize()
    local cam = workspace.CurrentCamera
    local v = cam and cam.ViewportSize or Vector2.new(390, 780)
    if not v or v.X < 50 or v.Y < 50 then
        v = Vector2.new(390, 780)
    end
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
--  noclip  (physics-step based: wins the race with game scripts)
-- ============================================================
local noclipSaved = {}
local noclipNext = 0

local function noclipOff()
    for part in pairs(noclipSaved) do
        if part and part.Parent then
            pcall(function() part.CanCollide = true end)
        end
    end
    noclipSaved = {}
end

local function noclipStep()
    local now = os.clock()
    if now < noclipNext then return end
    noclipNext = now + 0.05

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
