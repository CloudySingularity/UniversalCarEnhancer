if _G.CarSpeedChangerCleanup then
    pcall(_G.CarSpeedChangerCleanup)
end

if Lumen and Lumen.WaitForChannel then
    Lumen.WaitForChannel(5)
end

local Players    = game:GetService("Players")
local Workspace  = game:GetService("Workspace") or workspace
local RunService = game:GetService("RunService")
local player     = Players and Players.LocalPlayer or LocalPlayer

local isRunning       = true
local heartbeatConn   = nil
local dataModelConnId = nil
local win             = nil

local currentSeat     = nil
local currentRoot     = nil
local isRootAnchored  = false

local nowClock      = (os and os.clock) or tick
local lastFrameTime = nowClock and nowClock() or 0

local accel           = 40
local brakeForce      = 125
local speedLimit      = 200
local flightEnabled   = false
local velocityFlight  = false
local flightSpeed     = 1
local driftEnabled    = false
local driftStrength   = 5

local ACCEL_KEYS = { "w", "up", "i", "shift", "space", "e", "mouse4", "mouse5" }
local BRAKE_KEYS = { "s", "down", "k", "space", "ctrl", "q", "x", "c" }
local STOP_KEYS  = { "p", "x", "b", "k", "v", "g", "h", "space" }
local FLIP_KEYS  = { "f", "r", "t", "g", "h", "v", "z", "u" }

local accelKey   = "w"
local brakeKey   = "s"
local stopKey    = "p"
local flipKey    = "f"

local lastStopDown = false
local lastFlipDown = false

local function notify(msg, duration)
    local text = "[CarMod] " .. tostring(msg)
    if Lumen and typeof(Lumen.Notify) == "function" then
        pcall(Lumen.Notify, text, duration or 3)
    elseif typeof(info) == "function" then
        pcall(info, text)
    else
        print(text)
    end
end

local function isKeyDown(key)
    if typeof(isrbxactive) == "function" and not isrbxactive() then
        return false
    end
    if Input and typeof(Input.IsDown) == "function" then
        local ok, down = pcall(Input.IsDown, key)
        if ok then return down == true end
    end
    if typeof(iskeydown) == "function" then
        local ok, down = pcall(iskeydown, key)
        if ok then return down == true end
    end
    return false
end

local function safeReadProp(inst, prop, fallback)
    local ok, val = pcall(function()
        return inst[prop]
    end)
    if ok and val ~= nil then
        return val
    end
    return fallback
end

local function safeWriteProp(inst, prop, value)
    local ok = pcall(function()
        inst:SetProperty(prop, value)
    end)
    if not ok then
        pcall(function()
            inst[prop] = value
        end)
    end
end

local function setLinearVel(part, vec)
    local ok = pcall(function()
        part.AssemblyLinearVelocity = vec
    end)
    if not ok then
        pcall(function()
            part:SetVelocity(vec)
        end)
    end
end

local function getAngularVel(part)
    return safeReadProp(part, "AssemblyAngularVelocity", Vector3.zero)
end

local function setAngularVel(part, vec)
    safeWriteProp(part, "AssemblyAngularVelocity", vec)
end

local function getVehicleAxes(part)
    local refPart = (currentSeat and currentSeat.Parent) and currentSeat or part
    local cf = safeReadProp(refPart, "CFrame", nil)
    if not cf then return nil, nil end

    local look = cf.LookVector
    local flatLook = Vector3.new(look.X, 0, look.Z)
    if flatLook.Magnitude < 0.001 then
        flatLook = Vector3.new(0, 0, -1)
    else
        flatLook = flatLook.Unit
    end
    local flatRight = Vector3.new(-flatLook.Z, 0, flatLook.X)
    return flatLook, flatRight
end

local function clampSpeed(vel)
    if speedLimit == math.huge then return vel end
    local flat = Vector3.new(vel.X, 0, vel.Z)
    if flat.Magnitude > speedLimit then
        local clamped = flat.Unit * speedLimit
        return Vector3.new(clamped.X, vel.Y, clamped.Z)
    end
    return vel
end

local function computeSpeed(vel, flatLook, accelHeld, brakeHeld, dt)
    local flat = Vector3.new(vel.X, 0, vel.Z)
    local forwardSpeed = flat:Dot(flatLook)

    if brakeHeld then
        if forwardSpeed > 1.5 then
            local flatMag = flat.Magnitude
            local decel = brakeForce * dt
            local newMag = math.max(0, flatMag - decel)
            local scale = (flatMag > 0.001) and (newMag / flatMag) or 0
            return Vector3.new(vel.X * scale, vel.Y, vel.Z * scale)
        else
            local revAccel = math.max(accel * 0.6, 15)
            local nextVel = vel - flatLook * (revAccel * dt)
            return Vector3.new(nextVel.X, vel.Y, nextVel.Z)
        end
    elseif accelHeld then
        if forwardSpeed < -1.5 then
            local flatMag = flat.Magnitude
            local decel = math.max(brakeForce * 1.25, accel * 1.5) * dt
            local newMag = math.max(0, flatMag - decel)
            local scale = (flatMag > 0.001) and (newMag / flatMag) or 0
            return Vector3.new(vel.X * scale, vel.Y, vel.Z * scale)
        else
            local nextVel = vel + flatLook * (accel * dt)
            return Vector3.new(nextVel.X, vel.Y, nextVel.Z)
        end
    end

    return vel
end

local function computeDrift(part, vel, flatLook, flatRight, accelHeld, dt)
    local flat = Vector3.new(vel.X, 0, vel.Z)
    local speed = flat.Magnitude
    if speed < 6 then return vel end

    local forwardSpeed = flat:Dot(flatLook)
    local lateralSpeed = flat:Dot(flatRight)

    local steerInput = 0
    if isKeyDown("a") then steerInput = steerInput + 1 end
    if isKeyDown("d") then steerInput = steerInput - 1 end

    if forwardSpeed < -1 then
        steerInput = -steerInput
    end

    local driftFactor = math.clamp(driftStrength / 10, 0.1, 1.0)
    local speedFactor = math.clamp(speed / 35, 0.25, 1.0)

    local angVel = getAngularVel(part)
    local maxYaw = 1.2 + driftStrength * 0.28
    local targetYaw = steerInput * maxYaw * speedFactor
    local yawResponse = (steerInput ~= 0) and 8.0 or 11.0
    local yawAlpha = 1 - math.exp(-yawResponse * dt)
    local newYaw = angVel.Y + (targetYaw - angVel.Y) * yawAlpha

    local rollDamp = math.exp(-3.5 * dt)
    setAngularVel(part, Vector3.new(angVel.X * rollDamp, newYaw, angVel.Z * rollDamp))

    local gripDecayRate = (1.15 - driftFactor) * 4.5
    local newLateral = lateralSpeed * math.exp(-gripDecayRate * dt)

    if steerInput ~= 0 and forwardSpeed > 4 then
        local kick = steerInput * (driftStrength * 4.5) * speedFactor * dt
        newLateral = newLateral + kick
    end

    local maxLateral = math.max(15, speed * (0.40 + driftFactor * 0.35))
    newLateral = math.clamp(newLateral, -maxLateral, maxLateral)

    local newForward = forwardSpeed
    if accelHeld and math.abs(newLateral) > 2 then
        local lostLat = math.max(0, math.abs(lateralSpeed) - math.abs(newLateral))
        newForward = newForward + lostLat * 0.35
    end

    local newFlat = flatLook * newForward + flatRight * newLateral
    return Vector3.new(newFlat.X, vel.Y, newFlat.Z)
end

local function stopVehicle()
    local part = currentRoot or currentSeat
    if not part or not part.Parent or isRootAnchored then return end
    setLinearVel(part, Vector3.zero)
    setAngularVel(part, Vector3.zero)
end

local function flipVehicle()
    local part = currentRoot or currentSeat
    if not part or not part.Parent then return end

    local cf = safeReadProp(part, "CFrame", nil)
    if not cf then return end

    local pos = cf.Position
    local flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    if flatLook.Magnitude < 0.01 then
        flatLook = Vector3.new(1, 0, 0)
    else
        flatLook = flatLook.Unit
    end

    local liftedPos = pos + Vector3.new(0, 0.5, 0)
    pcall(function()
        part.CFrame = CFrame.lookAt(liftedPos, liftedPos + flatLook)
    end)
    setLinearVel(part, Vector3.zero)
    setAngularVel(part, Vector3.zero)
end

local function stepFlight(part)
    local cam = Workspace and Workspace.CurrentCamera
    if not cam then return end

    local camCF = safeReadProp(cam, "CFrame", nil)
    if not camCF then return end

    local rightVec = camCF.RightVector
    local lookVec  = camCF.LookVector

    if velocityFlight then
        local dir = Vector3.zero
        if isKeyDown("w") then dir = dir + lookVec end
        if isKeyDown("s") then dir = dir - lookVec end
        if isKeyDown("d") then dir = dir + rightVec end
        if isKeyDown("a") then dir = dir - rightVec end
        if isKeyDown("e") or isKeyDown("space") then dir = dir + Vector3.new(0, 1, 0) end
        if isKeyDown("q") or isKeyDown("lshift") then dir = dir - Vector3.new(0, 1, 0) end

        local targetVel = Vector3.zero
        if dir.Magnitude > 0.05 then
            targetVel = dir.Unit * (flightSpeed * 100)
        end
        setLinearVel(part, targetVel)
        setAngularVel(part, Vector3.zero)
    else
        local cf = safeReadProp(part, "CFrame", nil)
        if not cf then return end

        local move = Vector3.zero
        if isKeyDown("d") then move = move + rightVec * flightSpeed end
        if isKeyDown("a") then move = move - rightVec * flightSpeed end
        if isKeyDown("w") then move = move + lookVec * flightSpeed end
        if isKeyDown("s") then move = move - lookVec * flightSpeed end
        if isKeyDown("e") or isKeyDown("space") then move = move + Vector3.new(0, 1, 0) * (flightSpeed / 2) end
        if isKeyDown("q") or isKeyDown("lshift") then move = move - Vector3.new(0, 1, 0) * (flightSpeed / 2) end

        pcall(function()
            part.CFrame = CFrame.new(cf.Position + move) * cf.Rotation
        end)
        setLinearVel(part, Vector3.zero)
        setAngularVel(part, Vector3.zero)
    end
end

local function unload()
    if not isRunning then return end
    isRunning     = false
    flightEnabled = false
    driftEnabled  = false

    if heartbeatConn then
        pcall(function() heartbeatConn:Disconnect() end)
        heartbeatConn = nil
    end

    if dataModelConnId and Lumen and Lumen.RemoveDataModel then
        pcall(Lumen.RemoveDataModel, dataModelConnId)
        dataModelConnId = nil
    end

    local seat = currentSeat
    local root = currentRoot or seat
    if seat and seat.Parent then
        safeWriteProp(seat, "Throttle", 0)
        safeWriteProp(seat, "Steer", 0)
    end
    if root and root.Parent then
        setLinearVel(root, Vector3.zero)
        setAngularVel(root, Vector3.zero)
    end

    currentSeat = nil
    currentRoot = nil

    if win then
        pcall(function() win:Remove() end)
        win = nil
    end

    _G.CarSpeedChangerCleanup = nil
    notify("Unloaded", 2)
end

_G.CarSpeedChangerCleanup = unload

if Lumen and Lumen.OnDataModel then
    local ok, id = pcall(Lumen.OnDataModel, function()
        currentSeat    = nil
        currentRoot    = nil
        isRootAnchored = false
        Players        = game:GetService("Players")
        Workspace      = game:GetService("Workspace") or workspace
        player         = Players and Players.LocalPlayer or LocalPlayer
    end)
    if ok then dataModelConnId = id end
end

spawn(function()
    while isRunning do
        local lp = (Players and Players.LocalPlayer) or LocalPlayer or player
        player = lp

        local char = lp and safeReadProp(lp, "Character", nil)
        local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
        local seat = hum and safeReadProp(hum, "SeatPart", nil)

        if seat and seat.Parent then
            local root = safeReadProp(seat, "AssemblyRootPart", nil) or seat
            currentSeat    = seat
            currentRoot    = root
            isRootAnchored = safeReadProp(root, "Anchored", false) == true
        else
            local foundRoot = nil
            local foundSeat = nil
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp and Workspace then
                local myPos     = safeReadProp(hrp, "Position", nil)
                local pname     = (lp and lp.Name) or ""
                local vehFolder = Workspace:FindFirstChild("Vehicles")
                if myPos and vehFolder then
                    local children = vehFolder:GetChildren()
                    for i = 1, #children do
                        local v = children[i]
                        if v:FindFirstChild("_VehicleState_" .. pname) then
                            local seatPart = v:FindFirstChildWhichIsA("VehicleSeat", true)
                                or v:FindFirstChild("Seat")
                            local candidate = safeReadProp(v, "PrimaryPart", nil)
                                or seatPart
                                or v:FindFirstChildWhichIsA("BasePart")
                            if candidate and candidate:IsA("BasePart") then
                                local p = safeReadProp(candidate, "Position", nil)
                                if p then
                                    local dx, dy, dz = p.X - myPos.X, p.Y - myPos.Y, p.Z - myPos.Z
                                    if (dx * dx + dy * dy + dz * dz) < 400 then
                                        foundRoot = safeReadProp(candidate, "AssemblyRootPart", nil) or candidate
                                        foundSeat = seatPart
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end

            currentSeat    = foundSeat
            currentRoot    = foundRoot
            isRootAnchored = foundRoot and (safeReadProp(foundRoot, "Anchored", false) == true) or false
        end

        wait(0.15)
    end
end)

local function onFrame(dt)
    if not isRunning then return end

    if type(dt) ~= "number" or dt <= 0 then
        local now = nowClock and nowClock() or 0
        dt = (lastFrameTime > 0) and (now - lastFrameTime) or (1 / 60)
        lastFrameTime = now
    elseif nowClock then
        lastFrameTime = nowClock()
    end
    dt = math.clamp(dt, 1 / 240, 0.05)

    local stopDown = isKeyDown(stopKey)
    if stopDown and not lastStopDown then
        stopVehicle()
    end
    lastStopDown = stopDown

    local flipDown = isKeyDown(flipKey)
    if flipDown and not lastFlipDown then
        flipVehicle()
    end
    lastFlipDown = flipDown

    local part = currentRoot or currentSeat
    if not part or not part.Parent then return end

    if flightEnabled then
        stepFlight(part)
        return
    end

    if isRootAnchored then return end

    local accelHeld = isKeyDown(accelKey)
    local brakeHeld = isKeyDown(brakeKey)
    local needsSpeed = (accelHeld or brakeHeld) and (accel > 0 or brakeForce > 0)
    local needsLimit = (speedLimit ~= math.huge)

    if not needsSpeed and not driftEnabled and not needsLimit then
        return
    end

    local vel = safeReadProp(part, "AssemblyLinearVelocity", nil)
    if not vel then return end

    local flatLook, flatRight = getVehicleAxes(part)
    if not flatLook then return end

    local newVel = vel

    if needsSpeed then
        newVel = computeSpeed(newVel, flatLook, accelHeld, brakeHeld, dt)
    end

    if driftEnabled then
        newVel = computeDrift(part, newVel, flatLook, flatRight, accelHeld, dt)
    end

    if needsLimit then
        newVel = clampSpeed(newVel)
    end

    if newVel ~= vel then
        setLinearVel(part, newVel)
    end
end

if RunService and RunService.Heartbeat then
    heartbeatConn = RunService.Heartbeat:Connect(onFrame)
else
    spawn(function()
        while isRunning do
            onFrame()
            wait(0)
        end
    end)
end

win = UI.Window({
    Key    = "car_speed_changer",
    Title  = "Universal Car Modifier",
    Footer = "Lumen",
    Width  = 460,
    Height = 450,
})
win:BindToMenu(true)

local tabDrive = win:Tab("Drive")

local secSpeed = tabDrive:Section("Speed")
secSpeed:SliderInt("Acceleration", 0, 120, 10, function(v)
    accel = v * 4
end)
secSpeed:SliderInt("Brake Force", 0, 400, 50, function(v)
    brakeForce = v * 2.5
end)
secSpeed:SliderInt("Max Speed (0 = Off)", 0, 1000, 200, function(v)
    speedLimit = (v == 0) and math.huge or v
end)

local secDrift = tabDrive:Section("Drift")
secDrift:Toggle("Drift Mode", false, function(v)
    driftEnabled = v
end)
secDrift:SliderInt("Drift Strength", 1, 10, 5, function(v)
    driftStrength = v
end)

local tabFlight = win:Tab("Flight")

local secFlight = tabFlight:Section("Flight")
secFlight:Toggle("Enable Flight", false, function(v)
    flightEnabled = v
    notify(v and "Flight ON" or "Flight OFF", 2)
end)
secFlight:Toggle("Velocity Mode (Anti-Rubberband)", false, function(v)
    velocityFlight = v
end)
secFlight:SliderInt("Flight Speed", 0, 800, 100, function(v)
    flightSpeed = v / 100
end)

local secFlightGuide = tabFlight:Section("Flight Controls")
secFlightGuide:Label("Move: W A S D  |  Up: E / Space  |  Down: Q / Shift")
secFlightGuide:Label("Tip: Turn on Velocity Mode if the server pulls you back.")

local tabBinds = win:Tab("Keybinds")

local secBinds = tabBinds:Section("Vehicle Controls")
secBinds:Dropdown("Accelerate (Hold)", ACCEL_KEYS, 1, function(idx, text)
    accelKey = text or ACCEL_KEYS[idx] or "w"
end)
secBinds:Dropdown("Brake / Reverse (Hold)", BRAKE_KEYS, 1, function(idx, text)
    brakeKey = text or BRAKE_KEYS[idx] or "s"
end)
secBinds:Dropdown("Instant Stop (Press)", STOP_KEYS, 1, function(idx, text)
    stopKey = text or STOP_KEYS[idx] or "p"
end)
secBinds:Dropdown("Flip Car (Press)", FLIP_KEYS, 1, function(idx, text)
    flipKey = text or FLIP_KEYS[idx] or "f"
end)

local tabInfo = win:Tab("Info")

local secGuide = tabInfo:Section("Quick Guide")
secGuide:Label("1. Sit in any vehicle to activate controls automatically.")
secGuide:Label("2. Hold Accelerate or Brake to boost or stop smoothly.")
secGuide:Label("3. Use Drift Mode + A / D while moving to slide corners.")
secGuide:Label("4. Press Stop or Flip anytime if you lose control.")

local secSystem = tabInfo:Section("Script")
secSystem:Button("Unload Script", function()
    unload()
end)

notify("Ready", 3)
