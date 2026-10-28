-- Check for table that is shared between executions.
if not shared then
	return warn("No shared, no script.")
end

-- Initialize Luraph globals if they do not exist.
loadstring("getfenv().LPH_NO_VIRTUALIZE = function(...) return ... end")()
getfenv().PP_SCRAMBLE_NUM = function(...) return ... end
getfenv().PP_SCRAMBLE_STR = function(...) return ... end
getfenv().PP_SCRAMBLE_RE_NUM = function(...) return ... end

local Potent = {
	connections = {},
	esp = {},
	circles = {},
	velocities = {},
	lockedPlayer = nil,
	silentInstalled = false,
	unloaded = false,
}

-- Constants.
local REPO = "https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/"
local MENU_TITLE = "Potent | Tribes 3v3"
local CONFIG_FOLDER = "Potent"
local RENDER_STEP_NAME = "PotentRender"
local IGNORED_FOLDERS = { "Projectiles", "FX" }
local DEFAULT_PROJECTILE_SPEED = 250
local PREDICTION_ITERATIONS = 4
local VELOCITY_SMOOTHING = 0.35
local MAX_TRACKED_SPEED = 150
local TRIGGER_COOLDOWN = 0.2
local ESP_FONT = 2
local BOX_ASPECT = 0.55

-- Services.
local playersService = cloneref(game:GetService("Players"))
local runService = cloneref(game:GetService("RunService"))
local userInputService = cloneref(game:GetService("UserInputService"))
local replicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local lightingService = cloneref(game:GetService("Lighting"))
local virtualUser = cloneref(game:GetService("VirtualUser"))

-- State.
local localPlayer = playersService.LocalPlayer
local Library, Toggles, Options
local weaponsModule
local lightingCache
local triggerHoldUntil
local triggerReadyAt = 0
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

---Fetch a remote source through the executor request function.
---@param url string
---@return string
local function fetchSource(url)
	local response = request({ Url = url, Method = "GET" })
	assert(response and response.StatusCode == 200, "Request failed: " .. url)
	return response.Body
end

---Load and run a module from the Linoria repository.
---@param path string
---@return any
local function loadRemote(path)
	return loadstring(fetchSource(REPO .. path))()
end

---Wrap a callback so a runtime error warns once instead of spamming every frame.
---@param name string
---@param callback function
---@return function
local function guarded(name, callback)
	local warned = false
	return function(...)
		local success, result = pcall(callback, ...)
		if success or warned then
			return
		end
		warned = true
		warn(string.format("[Potent] %s: %s", name, tostring(result)))
	end
end

---Create a Drawing object and apply properties.
---@param class string
---@param properties table
---@return table
local function newDrawing(class, properties)
	local drawing = Drawing.new(class)
	for key, value in pairs(properties) do
		drawing[key] = value
	end
	drawing.Visible = false
	return drawing
end

---Get a character's humanoid root part.
---@param player Player
---@return BasePart?
local function getRoot(player)
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

---Check if the player is alive according to the game and the humanoid.
---@param player Player
---@return boolean
local function isAlive(player)
	if player:GetAttribute("Alive") == false then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

---Check if the player is in the same match as the local player.
---@param player Player
---@return boolean
local function isInMatch(player)
	local myMatch = localPlayer:GetAttribute("MatchId")
	if not myMatch or myMatch == "" then
		return true
	end
	return player:GetAttribute("MatchId") == myMatch
end

---Check if the player is on the local player's team.
---@param player Player
---@return boolean
local function isTeammate(player)
	local myTeam = localPlayer:GetAttribute("Team")
	return myTeam ~= nil and myTeam ~= 0 and myTeam == player:GetAttribute("Team")
end

---Check if the player can be targeted by combat features.
---@param player Player
---@return boolean
local function isTargetable(player)
	if player == localPlayer or not isAlive(player) or not isInMatch(player) then
		return false
	end
	if Toggles.TeamCheck.Value and isTeammate(player) then
		return false
	end
	return getRoot(player) ~= nil
end

---Get the currently equipped tool.
---@return Tool?
local function getEquippedTool()
	local character = localPlayer.Character
	return character and character:FindFirstChildOfClass("Tool")
end

---Resolve the tuning table of the equipped weapon.
---@return table?
local function getWeaponTuning()
	local tool = getEquippedTool()
	if not tool or not weaponsModule then
		return nil
	end

	local weaponId = tool:GetAttribute("WeaponId") or tool:GetAttribute("Id") or tool.Name
	local success, weapon = pcall(weaponsModule.Get, weaponId)
	if success and type(weapon) == "table" then
		return weapon.tuning
	end

	-- Fall back to a display name match when the tool is not named after the id.
	local listed, weapons = pcall(weaponsModule.All)
	if not listed or type(weapons) ~= "table" then
		return nil
	end
	for _, entry in pairs(weapons) do
		if type(entry) == "table" and entry.name == tool.Name then
			return entry.tuning
		end
	end
	return nil
end

---Get projectile speed and gravity for the equipped weapon.
---@return number, number
local function getProjectileStats()
	local tuning = getWeaponTuning()
	if not tuning then
		return DEFAULT_PROJECTILE_SPEED, 0
	end
	local speed = tuning.speed or tuning.speedMax or DEFAULT_PROJECTILE_SPEED
	return math.max(speed, 1), tuning.gravity or 0
end

---Estimate velocities for every other player from position deltas.
---@param deltaTime number
local function trackVelocities(deltaTime)
	for _, player in ipairs(playersService:GetPlayers()) do
		if player == localPlayer then
			continue
		end

		local root = getRoot(player)
		if not root then
			Potent.velocities[player] = nil
			continue
		end

		local entry = Potent.velocities[player]
		if not entry then
			Potent.velocities[player] = { position = root.Position, velocity = Vector3.zero }
			continue
		end

		if deltaTime > 0 then
			local rawVelocity = (root.Position - entry.position) / deltaTime
			if rawVelocity.Magnitude > MAX_TRACKED_SPEED then
				rawVelocity = Vector3.zero
			end
			entry.velocity = entry.velocity:Lerp(rawVelocity, VELOCITY_SMOOTHING)
		end
		entry.position = root.Position
	end
end

---Compute the point to aim at with lead and drop compensation.
---@param origin Vector3
---@param player Player
---@param part BasePart
---@return Vector3
local function getAimPosition(origin, player, part)
	local usePrediction = Toggles.Prediction.Value
	local useDrop = Toggles.DropCompensation.Value
	local position = part.Position
	if not usePrediction and not useDrop then
		return position
	end

	local speed, gravity = getProjectileStats()
	local entry = Potent.velocities[player]
	local velocity = entry and entry.velocity or Vector3.zero
	local travelTime = 0

	for _ = 1, PREDICTION_ITERATIONS do
		travelTime = (position - origin).Magnitude / speed
		if usePrediction then
			position = part.Position + velocity * travelTime * Options.PredictionScale.Value
		end
	end

	if useDrop then
		position += Vector3.new(0, 0.5 * gravity * travelTime * travelTime, 0)
	end
	return position
end

---Check line of sight from the camera to a part.
---@param part BasePart
---@return boolean
local function isVisible(part)
	local camera = workspace.CurrentCamera
	local ignore = { localPlayer.Character, part.Parent }
	for _, name in ipairs(IGNORED_FOLDERS) do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(ignore, folder)
		end
	end
	rayParams.FilterDescendantsInstances = ignore

	local origin = camera.CFrame.Position
	return workspace:Raycast(origin, part.Position - origin, rayParams) == nil
end

---Pick the body part name for a target part setting.
---@param setting string
---@return string
local function resolvePartName(setting)
	if setting == "Random" then
		return math.random() < 0.5 and "Head" or "UpperTorso"
	end
	return setting
end

---Return the player whose chosen part projects closest to the cursor within fovRadius.
---@param fovRadius number
---@param partName string
---@param wallCheck boolean
---@return Player?, BasePart?, number?
local function getClosestPlayer(fovRadius, partName, wallCheck)
	local camera = workspace.CurrentCamera
	local mousePosition = userInputService:GetMouseLocation()
	local closest, closestPart, closestDistance = nil, nil, fovRadius

	for _, player in ipairs(playersService:GetPlayers()) do
		if not isTargetable(player) then
			continue
		end

		local part = player.Character:FindFirstChild(partName)
		if not part then
			continue
		end

		local screenPosition, onScreen = camera:WorldToViewportPoint(part.Position)
		if not onScreen then
			continue
		end

		local distance = (Vector2.new(screenPosition.X, screenPosition.Y) - mousePosition).Magnitude
		if distance >= closestDistance then
			continue
		end
		if wallCheck and not isVisible(part) then
			continue
		end

		closest, closestPart, closestDistance = player, part, distance
	end

	return closest, closestPart, closestDistance
end

---Update the aimbot for this frame.
---@param camera Camera
local function updateAimbot(camera)
	if not Toggles.AimbotEnabled.Value or not Options.AimbotKey:GetState() then
		Potent.lockedPlayer = nil
		return
	end
	if userInputService:GetFocusedTextBox() or not isrbxactive() then
		return
	end

	local partName = resolvePartName(Options.AimbotPart.Value)
	local player, part
	local locked = Potent.lockedPlayer
	if Toggles.StickyAim.Value and locked and isTargetable(locked) then
		part = locked.Character:FindFirstChild(partName)
		player = part and locked
	end
	if not player then
		player, part = getClosestPlayer(Options.AimbotFov.Value, partName, Toggles.AimbotWallCheck.Value)
	end
	Potent.lockedPlayer = player
	if not player then
		return
	end

	local aimPosition = getAimPosition(camera.CFrame.Position, player, part)
	local alpha = math.clamp(1 - Options.AimbotSmoothing.Value / 100, 0.02, 1)

	if Options.AimbotMethod.Value == "Camera" then
		camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(camera.CFrame.Position, aimPosition), alpha)
		return
	end

	local screenPosition = camera:WorldToViewportPoint(aimPosition)
	if screenPosition.Z <= 0 then
		return
	end
	local delta = (Vector2.new(screenPosition.X, screenPosition.Y) - userInputService:GetMouseLocation()) * alpha
	mousemoverel(delta.X, delta.Y)
end

---Release the trigger if it is currently held.
local function releaseTrigger()
	if triggerHoldUntil then
		mouse1release()
		triggerHoldUntil = nil
	end
end

---Update the triggerbot for this frame.
local function updateTriggerbot()
	if not Toggles.TriggerbotEnabled.Value then
		releaseTrigger()
		return
	end

	local now = os.clock()
	if triggerHoldUntil then
		if now >= triggerHoldUntil then
			releaseTrigger()
			triggerReadyAt = now + TRIGGER_COOLDOWN
		end
		return
	end
	if now < triggerReadyAt or not isrbxactive() or not getEquippedTool() then
		return
	end

	local player = getClosestPlayer(Options.TriggerFov.Value, resolvePartName(Options.TriggerPart.Value), true)
	if not player then
		return
	end
	mouse1press()
	triggerHoldUntil = now + Options.TriggerHold.Value
end

---Compute a silent aim direction for the shot origin.
---@param origin Vector3
---@return Vector3?
local function getSilentDirection(origin)
	if math.random(1, 100) > Options.SilentHitChance.Value then
		return nil
	end

	local partName = resolvePartName(Options.SilentPart.Value)
	local player, part = getClosestPlayer(Options.SilentFov.Value, partName, Toggles.SilentWallCheck.Value)
	if not player then
		return nil
	end

	local direction = getAimPosition(origin, player, part) - origin
	if direction.Magnitude < 1 then
		return nil
	end
	return direction.Unit
end

---Replace the game's aim direction resolver with a silent aim variant.
local function installSilentAim()
	if Potent.silentInstalled then
		return
	end

	setthreadidentity(2)
	local success, combatUtil = pcall(require, localPlayer.PlayerScripts.Combat.Util)
	setthreadidentity(8)
	if not success or type(combatUtil) ~= "table" or type(combatUtil.AimDirection) ~= "function" then
		Library:Notify("Silent aim: Combat.Util not found.", 6)
		return
	end

	local original = combatUtil.AimDirection
	local replacement = newcclosure(function(origin)
		local direction = getSilentDirection(origin)
		if direction then
			return direction
		end
		return original(origin)
	end)
	pcall(setstackhidden, replacement, true)

	combatUtil.AimDirection = replacement
	Potent.silentUtil = combatUtil
	Potent.silentOriginal = original
	Potent.silentInstalled = true
end

---Restore the game's original aim direction resolver.
local function removeSilentAim()
	if not Potent.silentInstalled then
		return
	end
	Potent.silentUtil.AimDirection = Potent.silentOriginal
	Potent.silentInstalled = false
end

---Create the drawing and highlight objects for a player.
---@param player Player
---@return table
local function createEsp(player)
	local highlight = Instance.new("Highlight")
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Enabled = false
	highlight.Parent = gethui()

	local entry = {
		highlight = highlight,
		drawings = {
			boxOutline = newDrawing("Square", { Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0) }),
			box = newDrawing("Square", { Thickness = 1, Filled = false }),
			healthBack = newDrawing("Line", { Thickness = 3, Color = Color3.new(0, 0, 0) }),
			healthFill = newDrawing("Line", { Thickness = 1 }),
			name = newDrawing("Text", { Size = 13, Center = true, Outline = true, Font = ESP_FONT }),
			info = newDrawing("Text", { Size = 12, Center = true, Outline = true, Font = ESP_FONT }),
			tracer = newDrawing("Line", { Thickness = 1 }),
		},
	}
	Potent.esp[player] = entry
	return entry
end

---Hide every ESP object of an entry.
---@param entry table
local function hideEsp(entry)
	for _, drawing in pairs(entry.drawings) do
		drawing.Visible = false
	end
	entry.highlight.Enabled = false
end

---Destroy the ESP objects of a player.
---@param player Player
local function destroyEsp(player)
	local entry = Potent.esp[player]
	if not entry then
		return
	end
	for _, drawing in pairs(entry.drawings) do
		pcall(drawing.Remove, drawing)
	end
	entry.highlight:Destroy()
	Potent.esp[player] = nil
end

---Draw ESP for every player.
---@param camera Camera
local function updateEsp(camera)
	local enabled = Toggles.EspEnabled.Value
	local viewport = camera.ViewportSize
	local cameraPosition = camera.CFrame.Position

	for _, player in ipairs(playersService:GetPlayers()) do
		if player == localPlayer then
			continue
		end

		local entry = Potent.esp[player] or createEsp(player)
		hideEsp(entry)

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local head = character and character:FindFirstChild("Head")
		if not enabled or not humanoid or not root or not head or humanoid.Health <= 0 or not isInMatch(player) then
			continue
		end

		local teammate = isTeammate(player)
		if teammate and not Toggles.EspTeammates.Value then
			continue
		end

		local distance = (root.Position - cameraPosition).Magnitude
		if distance > Options.EspDistanceMax.Value then
			continue
		end

		local color = teammate and Options.TeamColor.Value or Options.EnemyColor.Value
		local drawings = entry.drawings

		if Toggles.Chams.Value then
			entry.highlight.Adornee = character
			entry.highlight.FillColor = color
			entry.highlight.OutlineColor = color
			entry.highlight.FillTransparency = Options.ChamsFill.Value / 100
			entry.highlight.Enabled = true
		end

		local top = camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.7, 0))
		local bottom = camera:WorldToViewportPoint(root.Position - Vector3.new(0, 3, 0))
		if top.Z <= 0 or bottom.Z <= 0 then
			continue
		end

		local height = math.abs(bottom.Y - top.Y)
		local width = height * BOX_ASPECT
		local left = top.X - width / 2
		local feet = Vector2.new(top.X, top.Y + height)

		if Toggles.EspBox.Value then
			drawings.boxOutline.Position = Vector2.new(left, top.Y)
			drawings.boxOutline.Size = Vector2.new(width, height)
			drawings.boxOutline.Visible = true
			drawings.box.Position = Vector2.new(left, top.Y)
			drawings.box.Size = Vector2.new(width, height)
			drawings.box.Color = color
			drawings.box.Visible = true
		end

		if Toggles.EspHealth.Value then
			local ratio = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
			local x = left - 5
			drawings.healthBack.From = Vector2.new(x, feet.Y)
			drawings.healthBack.To = Vector2.new(x, top.Y)
			drawings.healthBack.Visible = true
			drawings.healthFill.From = Vector2.new(x, feet.Y)
			drawings.healthFill.To = Vector2.new(x, feet.Y - height * ratio)
			drawings.healthFill.Color = Color3.fromHSV(ratio * 0.33, 1, 1)
			drawings.healthFill.Visible = true
		end

		if Toggles.EspName.Value then
			drawings.name.Text = player.DisplayName
			drawings.name.Position = Vector2.new(top.X, top.Y - 16)
			drawings.name.Color = color
			drawings.name.Visible = true
		end

		local infoParts = {}
		if Toggles.EspDistance.Value then
			table.insert(infoParts, string.format("%d studs", distance))
		end
		if Toggles.EspTool.Value then
			local tool = character:FindFirstChildOfClass("Tool")
			if tool then
				table.insert(infoParts, tool.Name)
			end
		end
		if #infoParts > 0 then
			drawings.info.Text = table.concat(infoParts, " | ")
			drawings.info.Position = Vector2.new(top.X, feet.Y + 2)
			drawings.info.Color = color
			drawings.info.Visible = true
		end

		if Toggles.EspTracer.Value then
			drawings.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
			drawings.tracer.To = feet
			drawings.tracer.Color = color
			drawings.tracer.Visible = true
		end
	end
end

---Update the FOV circles.
local function updateCircles()
	local mousePosition = userInputService:GetMouseLocation()
	local aimCircle = Potent.circles.aim
	local silentCircle = Potent.circles.silent

	aimCircle.Visible = Toggles.AimbotEnabled.Value and Toggles.DrawAimbotFov.Value
	aimCircle.Position = mousePosition
	aimCircle.Radius = Options.AimbotFov.Value
	aimCircle.Color = Options.FovColor.Value

	silentCircle.Visible = Toggles.SilentAimEnabled.Value and Toggles.DrawSilentFov.Value
	silentCircle.Position = mousePosition
	silentCircle.Radius = Options.SilentFov.Value
	silentCircle.Color = Options.SilentFovColor.Value
end

---Restore the lighting properties changed by the world toggles.
local function restoreLighting()
	if not lightingCache then
		return
	end
	for property, value in pairs(lightingCache.properties) do
		lightingService[property] = value
	end
	if lightingCache.atmosphere then
		lightingCache.atmosphere.Density = lightingCache.density
	end
	lightingCache = nil
end

---Apply fullbright and no fog.
local function updateLighting()
	local fullbright = Toggles.Fullbright.Value
	local noFog = Toggles.NoFog.Value
	if not fullbright and not noFog then
		restoreLighting()
		return
	end

	if not lightingCache then
		local atmosphere = lightingService:FindFirstChildOfClass("Atmosphere")
		lightingCache = {
			atmosphere = atmosphere,
			density = atmosphere and atmosphere.Density,
			properties = {
				Brightness = lightingService.Brightness,
				ClockTime = lightingService.ClockTime,
				GlobalShadows = lightingService.GlobalShadows,
				Ambient = lightingService.Ambient,
				OutdoorAmbient = lightingService.OutdoorAmbient,
				FogEnd = lightingService.FogEnd,
			},
		}
	end

	if fullbright then
		lightingService.Brightness = 2
		lightingService.ClockTime = 14
		lightingService.GlobalShadows = false
		lightingService.Ambient = Color3.new(1, 1, 1)
		lightingService.OutdoorAmbient = Color3.new(1, 1, 1)
	end
	if noFog then
		lightingService.FogEnd = 1e6
		if lightingCache.atmosphere then
			lightingCache.atmosphere.Density = 0
		end
	end
end

---Render step callback.
local function onRender()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	updateCircles()
	updateAimbot(camera)
	updateTriggerbot()
	updateEsp(camera)
	updateLighting()

	if Toggles.FovChanger.Value then
		camera.FieldOfView = Options.FovValue.Value
	end
end

---Heartbeat callback.
---@param deltaTime number
local function onHeartbeat(deltaTime)
	trackVelocities(deltaTime)

	if not Toggles.SpeedBoost.Value then
		return
	end
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and humanoid.MoveDirection.Magnitude > 0 then
		root.CFrame += humanoid.MoveDirection * Options.SpeedValue.Value * deltaTime
	end
end

---Stepped callback.
local function onStepped()
	if not Toggles.Noclip.Value then
		return
	end
	local character = localPlayer.Character
	if not character then
		return
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end
end

---Detach this instance and clean up everything it created.
function Potent.detach()
	if Potent.unloaded then
		return
	end
	Potent.unloaded = true

	pcall(runService.UnbindFromRenderStep, runService, RENDER_STEP_NAME)
	for _, connection in ipairs(Potent.connections) do
		pcall(connection.Disconnect, connection)
	end
	for player in pairs(Potent.esp) do
		destroyEsp(player)
	end
	for _, circle in pairs(Potent.circles) do
		pcall(circle.Remove, circle)
	end

	removeSilentAim()
	restoreLighting()
	releaseTrigger()

	if Library then
		pcall(Library.Unload, Library)
	end
	getgenv().Toggles = nil
	getgenv().Options = nil
end

---Build the menu.
---@param ThemeManager table
---@param SaveManager table
local function buildMenu(ThemeManager, SaveManager)
	local Window = Library:CreateWindow({
		Title = MENU_TITLE,
		Center = true,
		AutoShow = false,
		TabPadding = 8,
		MenuFadeTime = 0.2,
	})

	local Tabs = {
		Combat = Window:AddTab("Combat"),
		Visuals = Window:AddTab("Visuals"),
		Player = Window:AddTab("Player"),
		Settings = Window:AddTab("UI Settings"),
	}

	local partValues = { "Head", "UpperTorso", "HumanoidRootPart", "Random" }

	-- Aimbot.
	local aimbotBox = Tabs.Combat:AddLeftGroupbox("Aimbot")
	aimbotBox:AddToggle("AimbotEnabled", { Text = "Enabled", Default = false }):AddKeyPicker("AimbotKey", {
		Default = "MB2",
		Mode = "Hold",
		SyncToggleState = false,
		Text = "Aimbot",
		NoUI = false,
	})
	aimbotBox:AddDropdown("AimbotMethod", { Values = { "Mouse", "Camera" }, Default = 1, Text = "Method" })
	aimbotBox:AddDropdown("AimbotPart", { Values = partValues, Default = 1, Text = "Target part" })
	aimbotBox:AddSlider("AimbotFov", { Text = "FOV", Default = 120, Min = 10, Max = 600, Rounding = 0 })
	aimbotBox:AddSlider("AimbotSmoothing", { Text = "Smoothing", Default = 70, Min = 0, Max = 98, Rounding = 0 })
	aimbotBox:AddToggle("AimbotWallCheck", { Text = "Wall check", Default = true })
	aimbotBox:AddToggle("StickyAim", { Text = "Sticky target", Default = false })

	-- Targeting shared by every combat feature.
	local sharedBox = Tabs.Combat:AddLeftGroupbox("Targeting")
	sharedBox:AddToggle("TeamCheck", { Text = "Team check", Default = true })
	sharedBox:AddToggle("Prediction", { Text = "Lead moving targets", Default = true })
	sharedBox:AddSlider("PredictionScale", { Text = "Lead scale", Default = 1, Min = 0, Max = 2, Rounding = 2 })
	sharedBox:AddToggle("DropCompensation", { Text = "Projectile drop compensation", Default = true })

	-- Silent aim.
	local silentBox = Tabs.Combat:AddRightGroupbox("Silent Aim")
	silentBox:AddToggle("SilentAimEnabled", { Text = "Enabled", Default = false })
	silentBox:AddDropdown("SilentPart", { Values = partValues, Default = 1, Text = "Target part" })
	silentBox:AddSlider("SilentFov", { Text = "FOV", Default = 150, Min = 10, Max = 800, Rounding = 0 })
	silentBox:AddSlider("SilentHitChance", { Text = "Hit chance", Default = 100, Min = 1, Max = 100, Rounding = 0 })
	silentBox:AddToggle("SilentWallCheck", { Text = "Wall check", Default = true })

	Toggles.SilentAimEnabled:OnChanged(function()
		if Toggles.SilentAimEnabled.Value then
			installSilentAim()
		else
			removeSilentAim()
		end
	end)

	-- Triggerbot.
	local triggerBox = Tabs.Combat:AddRightGroupbox("Triggerbot")
	triggerBox:AddToggle("TriggerbotEnabled", { Text = "Enabled", Default = false })
	triggerBox:AddDropdown("TriggerPart", { Values = partValues, Default = 2, Text = "Target part" })
	triggerBox:AddSlider("TriggerFov", { Text = "Trigger radius", Default = 25, Min = 5, Max = 150, Rounding = 0 })
	triggerBox:AddSlider("TriggerHold", { Text = "Hold time (draw)", Default = 0.1, Min = 0, Max = 1.5, Rounding = 2 })

	-- ESP.
	local espBox = Tabs.Visuals:AddLeftGroupbox("ESP")
	espBox:AddToggle("EspEnabled", { Text = "Enabled", Default = false })
	espBox:AddToggle("EspTeammates", { Text = "Show teammates", Default = false })
	espBox:AddToggle("EspBox", { Text = "Box", Default = true })
	espBox:AddToggle("EspName", { Text = "Name", Default = true })
	espBox:AddToggle("EspHealth", { Text = "Health bar", Default = true })
	espBox:AddToggle("EspDistance", { Text = "Distance", Default = true })
	espBox:AddToggle("EspTool", { Text = "Held weapon", Default = true })
	espBox:AddToggle("EspTracer", { Text = "Tracers", Default = false })
	espBox:AddSlider("EspDistanceMax", { Text = "Max distance", Default = 1500, Min = 100, Max = 5000, Rounding = 0 })

	local chamsBox = Tabs.Visuals:AddLeftGroupbox("Chams")
	chamsBox:AddToggle("Chams", { Text = "Enabled", Default = false })
	chamsBox:AddSlider("ChamsFill", { Text = "Fill transparency", Default = 60, Min = 0, Max = 100, Rounding = 0 })

	-- Colors.
	local colorBox = Tabs.Visuals:AddRightGroupbox("Colors")
	colorBox:AddLabel("Enemy"):AddColorPicker("EnemyColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Enemy" })
	colorBox:AddLabel("Team"):AddColorPicker("TeamColor", { Default = Color3.fromRGB(80, 200, 255), Title = "Team" })
	colorBox:AddLabel("Aimbot FOV"):AddColorPicker("FovColor", { Default = Color3.fromRGB(255, 255, 255), Title = "Aimbot FOV" })
	colorBox:AddLabel("Silent FOV"):AddColorPicker("SilentFovColor", { Default = Color3.fromRGB(255, 200, 60), Title = "Silent FOV" })
	colorBox:AddToggle("DrawAimbotFov", { Text = "Draw aimbot FOV", Default = true })
	colorBox:AddToggle("DrawSilentFov", { Text = "Draw silent FOV", Default = true })

	-- World and camera.
	local worldBox = Tabs.Visuals:AddRightGroupbox("World")
	worldBox:AddToggle("Fullbright", { Text = "Fullbright", Default = false })
	worldBox:AddToggle("NoFog", { Text = "No fog", Default = false })
	worldBox:AddToggle("FovChanger", { Text = "Camera FOV", Default = false })
	worldBox:AddSlider("FovValue", { Text = "FOV value", Default = 90, Min = 40, Max = 120, Rounding = 0 })

	-- Movement.
	local moveBox = Tabs.Player:AddLeftGroupbox("Movement")
	moveBox:AddToggle("SpeedBoost", { Text = "Speed boost", Default = false })
	moveBox:AddSlider("SpeedValue", { Text = "Boost (studs/s)", Default = 10, Min = 1, Max = 60, Rounding = 0 })
	moveBox:AddToggle("Noclip", { Text = "Noclip", Default = false })
	moveBox:AddToggle("InfiniteJump", { Text = "Infinite jump", Default = false })

	-- Misc.
	local miscBox = Tabs.Player:AddRightGroupbox("Misc")
	miscBox:AddToggle("AntiAfk", { Text = "Anti AFK", Default = true })

	-- Settings.
	local menuBox = Tabs.Settings:AddLeftGroupbox("Menu")
	menuBox:AddButton("Unload", function()
		Potent.detach()
	end)
	menuBox:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "End", NoUI = true, Text = "Menu keybind" })
	Library.ToggleKeybind = Options.MenuKeybind

	ThemeManager:SetLibrary(Library)
	SaveManager:SetLibrary(Library)
	SaveManager:IgnoreThemeSettings()
	SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
	ThemeManager:SetFolder(CONFIG_FOLDER)
	SaveManager:SetFolder(CONFIG_FOLDER .. "/Tribes3v3")
	SaveManager:BuildConfigSection(Tabs.Settings)
	ThemeManager:ApplyToTab(Tabs.Settings)
	SaveManager:LoadAutoloadConfig()
end

---Connect runtime hooks and loops.
local function connectRuntime()
	Potent.circles.aim = newDrawing("Circle", { Thickness = 1, NumSides = 64, Filled = false })
	Potent.circles.silent = newDrawing("Circle", { Thickness = 1, NumSides = 64, Filled = false })

	runService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, guarded("render", onRender))
	table.insert(Potent.connections, runService.Heartbeat:Connect(guarded("heartbeat", onHeartbeat)))
	table.insert(Potent.connections, runService.Stepped:Connect(guarded("stepped", onStepped)))

	table.insert(Potent.connections, playersService.PlayerRemoving:Connect(function(player)
		destroyEsp(player)
		Potent.velocities[player] = nil
	end))

	table.insert(Potent.connections, userInputService.JumpRequest:Connect(function()
		if not Toggles.InfiniteJump.Value then
			return
		end
		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end))

	table.insert(Potent.connections, localPlayer.Idled:Connect(function()
		if not Toggles.AntiAfk.Value then
			return
		end
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.zero)
	end))
end

---Initialize the script.
local function initializeScript()
	Library = loadRemote("Library.lua")
	local ThemeManager = loadRemote("addons/ThemeManager.lua")
	local SaveManager = loadRemote("addons/SaveManager.lua")

	Toggles = Library.Toggles or getgenv().Toggles
	Options = Library.Options or getgenv().Options
	assert(Toggles and Options, "Linoria did not expose Toggles/Options.")

	setthreadidentity(2)
	local success, weapons = pcall(require, replicatedStorage.Shared.Weapons)
	setthreadidentity(8)
	weaponsModule = success and weapons or nil

	buildMenu(ThemeManager, SaveManager)
	Library:OnUnload(Potent.detach)
	connectRuntime()

	Library:Notify("Potent loaded.", 4)
end

---This is called when initialization errors.
---@param error string
local function onInitializeError(error)
	warn("Failed to initialize.")
	warn(error)
	warn(debug.traceback())
	Potent.detach()
end

if shared.Potent then
	shared.Potent.detach()
end
shared.Potent = Potent

xpcall(initializeScript, onInitializeError)
