-- Check for table that is shared between executions.
if not shared then
	return warn("No shared, no script.")
end

-- Initialize Luraph globals if they do not exist.
loadstring("getfenv().LPH_NO_VIRTUALIZE = function(...) return ... end")()
getfenv().PP_SCRAMBLE_NUM = function(...) return ... end
getfenv().PP_SCRAMBLE_STR = function(...) return ... end
getfenv().PP_SCRAMBLE_RE_NUM = function(...) return ... end

local StreetLife = {
	connections = {},
	espObjects = {},
	running = true,
	library = nil,
	fovCircle = nil,
	fpsLabel = nil,
	godConnection = nil,
	savedWalkSpeed = nil,
	savedJumpPower = nil,
	savedFieldOfView = nil,
	shooting = false,
	lastPitch = nil,
	lastAmmoScan = 0,
	fpsFrames = 0,
	fpsTimestamp = os.clock(),
	currentFps = 0,
}

-- Constants.
local REPO = "https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/"
local MENU_TITLE = "Street Life Remastered"
local TELEPORTS_FOLDER_NAME = "Teleports"
local LANDMARK_FOLDERS = { "Bank", "Jewel", "Museum", "YachtRobbery", "Oilrig", "Gym", "Arcade", "PDStation", "Halloween" }
local AIM_TARGET_PARTS = { "Head", "Torso", "HumanoidRootPart" }
local AIM_JITTER_PX = 0.6
local TORSO_NAMES = { "UpperTorso", "Torso" }
local AMMO_KEYWORDS = { "ammo", "clip", "mag" }
local STAMINA_KEYWORDS = { "stamina", "energy", "sprint", "endurance", "dash", "fatigue" }
local INF_AMMO_VALUE = 999
local AMMO_SCAN_INTERVAL = 0.25
local STAMINA_INTERVAL = 0.5
local STAMINA_REFILL_THRESHOLD = 90
local STAMINA_MAX = 100
local STAMINA_ATTRIBUTE_FLOOR = 95
local DEFAULT_MAX_HEALTH = 100
local RECOIL_DIRECTION = 1
local RECOIL_PITCH_THRESHOLD = 0.0008
local RECOIL_COMPENSATION = 0.85
local ESP_BOX_RATIO = 1.5
local ESP_HEAD_OFFSET = Vector3.new(0, 2.5, 0)
local ESP_FEET_OFFSET = Vector3.new(0, 3, 0)
local TELEPORT_HEIGHT_OFFSET = Vector3.new(0, 5, 0)
local CAR_GROUND_MIN_SPEED = 5
local SKELETON_LINKS = {
	{ { "Head" }, TORSO_NAMES },
	{ TORSO_NAMES, { "LeftUpperArm", "Left Arm" } },
	{ TORSO_NAMES, { "RightUpperArm", "Right Arm" } },
	{ TORSO_NAMES, { "LeftUpperLeg", "Left Leg" } },
	{ TORSO_NAMES, { "RightUpperLeg", "Right Leg" } },
}
local CAR_TELEPORTS = {
	{ name = "Jewelry", position = Vector3.new(1, 52, -186) },
	{ name = "Yacht", position = Vector3.new(927, 81, -1824) },
	{ name = "Bank", position = Vector3.new(395, 52, 59) },
	{ name = "Museum", position = Vector3.new(1322, 52, -117) },
	{ name = "Mansion", position = Vector3.new(1367, 55, 221) },
	{ name = "Gas Station", position = Vector3.new(309, 52, 179) },
	{ name = "Gunstore 1", position = Vector3.new(604, 52, -368) },
	{ name = "Gunstore 2", position = Vector3.new(35, 70, 551) },
	{ name = "Dealer", position = Vector3.new(242, 52, 309) },
	{ name = "Gun Buyer", position = Vector3.new(1002, 52, -106) },
}

-- Services.
local playersService = game:GetService("Players")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")
local httpService = game:GetService("HttpService")
local teleportService = game:GetService("TeleportService")

-- State.
local localPlayer = playersService.LocalPlayer

---Fetch and execute a remote Lua source through the executor request function.
---@param path string
---@return any
local function fetch(path)
	local response = request({ Url = REPO .. path, Method = "GET" })
	assert(response and response.Success, "Failed to fetch " .. path)
	return loadstring(response.Body)()
end

---Track a connection so it can be disconnected on detach.
---@param connection RBXScriptConnection
---@return RBXScriptConnection
local function track(connection)
	table.insert(StreetLife.connections, connection)
	return connection
end

---Show a notification through the menu library.
---@param text string
local function notify(text)
	if StreetLife.library then
		StreetLife.library:Notify(text, 3)
	end
end

---Check whether a name contains any of the given keywords.
---@param name string
---@param keywords table
---@return boolean
local function matchesKeyword(name, keywords)
	local lowered = string.lower(name)
	for _, keyword in ipairs(keywords) do
		if string.find(lowered, keyword, 1, true) then
			return true
		end
	end

	return false
end

---Find the first existing child of a character from a list of names.
---@param character Model
---@param names table
---@return BasePart?
local function findPart(character, names)
	for _, name in ipairs(names) do
		local part = character:FindFirstChild(name)
		if part then
			return part
		end
	end

	return nil
end

---Get the local character, humanoid and root part if all are alive.
---@return Model?, Humanoid?, BasePart?
local function getLocalParts()
	local character = localPlayer.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and rootPart and humanoid.Health > 0) then
		return nil
	end

	return character, humanoid, rootPart
end

---Get the vehicle seat the local humanoid is sitting in, if any.
---@param humanoid Humanoid
---@return VehicleSeat?
local function getVehicleSeat(humanoid)
	local seat = humanoid.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		return seat
	end

	return nil
end

---Resolve a world position for a workspace landmark folder or model.
---@param name string
---@return Vector3?
local function getLandmarkPosition(name)
	local landmark = workspace:FindFirstChild(name)
	if not landmark then
		return nil
	end

	if landmark:IsA("Model") then
		return landmark:GetPivot().Position
	end

	for _, descendant in ipairs(landmark:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return descendant.Position
		end
	end

	return nil
end

---Teleport the local character to a world position.
---@param position Vector3
local function teleportTo(position)
	local _, _, rootPart = getLocalParts()
	if not rootPart then
		return
	end

	rootPart.CFrame = CFrame.new(position + TELEPORT_HEIGHT_OFFSET)
end

---Teleport the vehicle the local player is driving to a world position.
---@param position Vector3
local function teleportCar(position)
	local _, humanoid = getLocalParts()
	local seat = humanoid and getVehicleSeat(humanoid)
	if not seat then
		return notify("You must be in a vehicle to teleport!")
	end

	local target = CFrame.new(position + TELEPORT_HEIGHT_OFFSET)
	local vehicle = seat.Parent
	if vehicle:IsA("Model") then
		vehicle:PivotTo(target)
	else
		seat.CFrame = target
	end
end

---Collect the names of every child under a workspace folder.
---@param folderName string
---@return table
local function collectChildNames(folderName)
	local names = {}
	local folder = workspace:FindFirstChild(folderName)
	if not folder then
		return names
	end

	for _, child in ipairs(folder:GetChildren()) do
		table.insert(names, child.Name)
	end

	table.sort(names)
	return names
end

---Collect landmark names that currently exist in the workspace.
---@return table
local function collectLandmarks()
	local names = {}
	for _, name in ipairs(LANDMARK_FOLDERS) do
		if workspace:FindFirstChild(name) then
			table.insert(names, name)
		end
	end

	return names
end

---Collect the configured car teleport names.
---@return table
local function collectCarTeleports()
	local names = {}
	for _, entry in ipairs(CAR_TELEPORTS) do
		table.insert(names, entry.name)
	end

	return names
end

---Look up a car teleport position by name.
---@param name string
---@return Vector3?
local function getCarTeleportPosition(name)
	for _, entry in ipairs(CAR_TELEPORTS) do
		if entry.name == name then
			return entry.position
		end
	end

	return nil
end

---Hop to another public server with free slots.
local function serverHop()
	local url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100", game.PlaceId)
	local success, servers = pcall(function()
		return httpService:JSONDecode(request({ Url = url, Method = "GET" }).Body)
	end)

	if not (success and servers and servers.data) then
		return notify("Server list unavailable.")
	end

	for _, server in ipairs(servers.data) do
		if server.playing < server.maxPlayers and server.id ~= game.JobId then
			return teleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
		end
	end

	notify("No free server found.")
end

---Check line of sight from the camera to a target part.
---@param camera Camera
---@param targetPart BasePart
---@return boolean
local function isVisible(camera, targetPart)
	if not getgenv().Toggles.AimWallCheck.Value then
		return true
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { localPlayer.Character }

	local origin = camera.CFrame.Position
	local result = workspace:Raycast(origin, targetPart.Position - origin, params)
	return result == nil or result.Instance:IsDescendantOf(targetPart.Parent)
end

---Resolve the configured aim target part on a character.
---@param character Model
---@return BasePart?
local function getAimPart(character)
	local name = getgenv().Options.AimTargetPart.Value
	if name == "Torso" then
		return findPart(character, TORSO_NAMES)
	end

	return character:FindFirstChild(name) or character:FindFirstChild("HumanoidRootPart")
end

---Return the aim part whose projection is closest to the cursor within the fov radius.
---@param camera Camera
---@return BasePart?
local function getClosestTarget(camera)
	local closest, closestDist = nil, getgenv().Options.AimFovRadius.Value
	local mousePos = userInputService:GetMouseLocation()

	for _, player in ipairs(playersService:GetPlayers()) do
		if player == localPlayer then continue end
		local character = player.Character
		if not character then continue end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local part = getAimPart(character)
		if not (humanoid and part and humanoid.Health > 0) then continue end

		local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
		if not onScreen then continue end

		local dist = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
		if dist < closestDist and isVisible(camera, part) then
			closest = part
			closestDist = dist
		end
	end

	return closest
end

---Create the drawing objects for a player's ESP.
---@param player Player
local function createEsp(player)
	if player == localPlayer or StreetLife.espObjects[player] then
		return
	end

	local objects = {
		box = Drawing.new("Square"),
		boxOutline = Drawing.new("Square"),
		name = Drawing.new("Text"),
		distance = Drawing.new("Text"),
		healthBack = Drawing.new("Square"),
		health = Drawing.new("Square"),
		tracer = Drawing.new("Line"),
		bones = {},
	}

	objects.box.Filled = false
	objects.box.Thickness = 1
	objects.boxOutline.Filled = false
	objects.boxOutline.Thickness = 3
	objects.boxOutline.Color = Color3.new(0, 0, 0)
	objects.name.Center = true
	objects.name.Outline = true
	objects.name.Size = 14
	objects.distance.Center = true
	objects.distance.Outline = true
	objects.distance.Size = 12
	objects.distance.Color = Color3.fromRGB(160, 140, 140)
	objects.healthBack.Filled = true
	objects.healthBack.Color = Color3.new(0, 0, 0)
	objects.health.Filled = true
	objects.tracer.Thickness = 1

	for index = 1, #SKELETON_LINKS do
		local line = Drawing.new("Line")
		line.Thickness = 1.5
		objects.bones[index] = line
	end

	StreetLife.espObjects[player] = objects
end

---Hide every drawing of a player's ESP.
---@param objects table
local function hideEsp(objects)
	for key, drawing in pairs(objects) do
		if key == "bones" then
			for _, line in ipairs(drawing) do
				line.Visible = false
			end
		else
			drawing.Visible = false
		end
	end
end

---Remove and destroy a player's ESP drawings.
---@param player Player
local function removeEsp(player)
	local objects = StreetLife.espObjects[player]
	if not objects then
		return
	end

	for key, drawing in pairs(objects) do
		if key == "bones" then
			for _, line in ipairs(drawing) do
				line:Remove()
			end
		else
			drawing:Remove()
		end
	end

	StreetLife.espObjects[player] = nil
end

---Update every ESP drawing for the current frame.
---@param camera Camera
local function updateEsp(camera)
	local Toggles, Options = getgenv().Toggles, getgenv().Options
	local enabled = Toggles.EspEnabled.Value
	local color = Options.EspColor.Value
	local viewportSize = camera.ViewportSize

	for player, objects in pairs(StreetLife.espObjects) do
		hideEsp(objects)

		if not enabled then continue end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not (humanoid and rootPart and humanoid.Health > 0) then continue end

		local torso = findPart(character, TORSO_NAMES) or rootPart
		local distance = (camera.CFrame.Position - torso.Position).Magnitude
		if distance > Options.EspMaxDistance.Value then continue end

		local center, onScreen = camera:WorldToViewportPoint(torso.Position)
		if not onScreen then continue end

		local top = camera:WorldToViewportPoint(torso.Position + ESP_HEAD_OFFSET)
		local bottom = camera:WorldToViewportPoint(torso.Position - ESP_FEET_OFFSET)
		local height = math.abs(top.Y - bottom.Y)
		if height < 1 then continue end

		local width = height / ESP_BOX_RATIO

		if Toggles.EspBoxes.Value then
			objects.boxOutline.Size = Vector2.new(width + 2, height + 2)
			objects.boxOutline.Position = Vector2.new(center.X - width / 2 - 1, top.Y - 1)
			objects.boxOutline.Visible = true
			objects.box.Size = Vector2.new(width, height)
			objects.box.Position = Vector2.new(center.X - width / 2, top.Y)
			objects.box.Color = color
			objects.box.Visible = true
		end

		if Toggles.EspHealth.Value then
			local percent = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
			objects.healthBack.Size = Vector2.new(3, height + 2)
			objects.healthBack.Position = Vector2.new(center.X - width / 2 - 6, top.Y - 1)
			objects.healthBack.Visible = true
			objects.health.Size = Vector2.new(1, math.max(height * percent, 1))
			objects.health.Position = Vector2.new(center.X - width / 2 - 5, top.Y + height * (1 - percent))
			objects.health.Color = Color3.fromHSV(percent * 0.3, 1, 1)
			objects.health.Visible = true
		end

		if Toggles.EspNames.Value then
			objects.name.Text = player.Name
			objects.name.Position = Vector2.new(center.X, top.Y - 18)
			objects.name.Color = color
			objects.name.Visible = true
		end

		if Toggles.EspShowDistance.Value then
			objects.distance.Text = string.format("[%dm]", math.floor(distance))
			objects.distance.Position = Vector2.new(center.X, bottom.Y + 2)
			objects.distance.Visible = true
		end

		if Toggles.EspTracers.Value then
			objects.tracer.From = Vector2.new(viewportSize.X / 2, viewportSize.Y)
			objects.tracer.To = Vector2.new(center.X, bottom.Y)
			objects.tracer.Color = color
			objects.tracer.Visible = true
		end

		if Toggles.EspSkeleton.Value then
			for index, link in ipairs(SKELETON_LINKS) do
				local partA, partB = findPart(character, link[1]), findPart(character, link[2])
				if not (partA and partB) then continue end

				local pointA, visibleA = camera:WorldToViewportPoint(partA.Position)
				local pointB, visibleB = camera:WorldToViewportPoint(partB.Position)
				if not (visibleA and visibleB) then continue end

				local line = objects.bones[index]
				line.From = Vector2.new(pointA.X, pointA.Y)
				line.To = Vector2.new(pointB.X, pointB.Y)
				line.Color = color
				line.Visible = true
			end
		end
	end
end

---Move the cursor toward the closest target while the aim key is held.
---@param camera Camera
local function updateAimbot(camera)
	local Toggles, Options = getgenv().Toggles, getgenv().Options
	local mousePos = userInputService:GetMouseLocation()

	StreetLife.fovCircle.Position = mousePos
	StreetLife.fovCircle.Radius = Options.AimFovRadius.Value
	StreetLife.fovCircle.Visible = Toggles.AimShowFov.Value

	if not (Toggles.AimbotEnabled.Value and Options.AimbotKey:GetState()) then
		return
	end

	local part = getClosestTarget(camera)
	if not part then
		return
	end

	local predicted = part.Position
	local rootPart = part.Parent:FindFirstChild("HumanoidRootPart")
	if rootPart and Options.AimPrediction.Value > 0 then
		predicted = predicted + rootPart.AssemblyLinearVelocity * Options.AimPrediction.Value
	end

	local screenPos, onScreen = camera:WorldToViewportPoint(predicted)
	if not onScreen then
		return
	end

	local smoothness = Options.AimSmoothness.Value
	if mousemoverel then
		local jitterX = (math.random() - 0.5) * 2 * AIM_JITTER_PX
		local jitterY = (math.random() - 0.5) * 2 * AIM_JITTER_PX
		mousemoverel((screenPos.X - mousePos.X) / smoothness + jitterX, (screenPos.Y - mousePos.Y) / smoothness + jitterY)
		return
	end

	camera.CFrame = camera.CFrame:Lerp(CFrame.new(camera.CFrame.Position, predicted), 1 / (smoothness * 2))
end

---Counter vertical camera kick while the fire button is held.
---@param camera Camera
local function updateNoRecoil(camera)
	if not (getgenv().Toggles.NoRecoil.Value and StreetLife.shooting and mousemoverel) then
		StreetLife.lastPitch = nil
		return
	end

	local _, pitch = camera.CFrame:ToEulerAnglesYXZ()
	if StreetLife.lastPitch then
		local delta = (pitch - StreetLife.lastPitch) * RECOIL_DIRECTION
		if delta > RECOIL_PITCH_THRESHOLD then
			mousemoverel(0, math.deg(delta) * (camera.ViewportSize.Y / camera.FieldOfView) * RECOIL_COMPENSATION)
		end
	end

	StreetLife.lastPitch = pitch
end

---Apply the custom field of view, restoring the original when disabled.
---@param camera Camera
local function updateCameraFov(camera)
	local Toggles, Options = getgenv().Toggles, getgenv().Options
	if Toggles.CustomFov.Value then
		StreetLife.savedFieldOfView = StreetLife.savedFieldOfView or camera.FieldOfView
		camera.FieldOfView = Options.FovValue.Value
	elseif StreetLife.savedFieldOfView then
		camera.FieldOfView = StreetLife.savedFieldOfView
		StreetLife.savedFieldOfView = nil
	end
end

---Update the fps counter overlay.
local function updateFps()
	StreetLife.fpsFrames = StreetLife.fpsFrames + 1
	if os.clock() - StreetLife.fpsTimestamp >= 1 then
		StreetLife.currentFps = StreetLife.fpsFrames
		StreetLife.fpsFrames = 0
		StreetLife.fpsTimestamp = os.clock()
	end

	StreetLife.fpsLabel.Text = "FPS: " .. StreetLife.currentFps
	StreetLife.fpsLabel.Visible = getgenv().Toggles.ShowFps.Value
end

---Apply walk speed and jump power modifiers for the current frame.
---@param humanoid Humanoid
local function updateMovement(humanoid)
	local Toggles, Options = getgenv().Toggles, getgenv().Options

	if Toggles.SpeedEnabled.Value then
		StreetLife.savedWalkSpeed = StreetLife.savedWalkSpeed or humanoid.WalkSpeed
		humanoid.WalkSpeed = Options.SpeedValue.Value
	elseif StreetLife.savedWalkSpeed then
		humanoid.WalkSpeed = StreetLife.savedWalkSpeed
		StreetLife.savedWalkSpeed = nil
	end

	if Toggles.JumpEnabled.Value then
		StreetLife.savedJumpPower = StreetLife.savedJumpPower or humanoid.JumpPower
		humanoid.UseJumpPower = true
		humanoid.JumpPower = Options.JumpValue.Value
	elseif StreetLife.savedJumpPower then
		humanoid.JumpPower = StreetLife.savedJumpPower
		StreetLife.savedJumpPower = nil
	end
end

---Apply infinite ammo and fast reload to the equipped tool.
---@param character Model
---@param humanoid Humanoid
local function updateGunMods(character, humanoid)
	local Toggles, Options = getgenv().Toggles, getgenv().Options
	local tool = character:FindFirstChildOfClass("Tool")
	if not tool then
		return
	end

	if Toggles.InfAmmo.Value and os.clock() - StreetLife.lastAmmoScan >= AMMO_SCAN_INTERVAL then
		StreetLife.lastAmmoScan = os.clock()

		for _, descendant in ipairs(tool:GetDescendants()) do
			if (descendant:IsA("IntValue") or descendant:IsA("NumberValue")) and matchesKeyword(descendant.Name, AMMO_KEYWORDS) then
				descendant.Value = INF_AMMO_VALUE
			end
		end

		for name, value in pairs(tool:GetAttributes()) do
			if type(value) == "number" and matchesKeyword(name, AMMO_KEYWORDS) then
				tool:SetAttribute(name, INF_AMMO_VALUE)
			end
		end
	end

	if Toggles.FastReload.Value then
		for _, track in ipairs(humanoid:GetPlayingAnimationTracks()) do
			if matchesKeyword(track.Name, { "reload" }) then
				track:AdjustSpeed(Options.ReloadSpeed.Value)
			end
		end
	end
end

---Disable collisions on the local character while noclip is active.
---@param character Model
local function updateNoclip(character)
	if not getgenv().Toggles.Noclip.Value then
		return
	end

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			part.CanCollide = false
		end
	end
end

---Apply car fly and ground speed boost to the driven vehicle.
---@param humanoid Humanoid
---@param camera Camera
---@param deltaTime number
local function updateCar(humanoid, camera, deltaTime)
	local Toggles, Options = getgenv().Toggles, getgenv().Options
	local seat = getVehicleSeat(humanoid)
	if not seat then
		return
	end

	local speed = Options.CarSpeedAmount.Value

	if Toggles.CarFly.Value then
		local velocity = Vector3.zero
		if userInputService:IsKeyDown(Enum.KeyCode.W) then velocity = velocity + camera.CFrame.LookVector * speed end
		if userInputService:IsKeyDown(Enum.KeyCode.S) then velocity = velocity - camera.CFrame.LookVector * speed end
		if userInputService:IsKeyDown(Enum.KeyCode.A) then velocity = velocity - camera.CFrame.RightVector * speed end
		if userInputService:IsKeyDown(Enum.KeyCode.D) then velocity = velocity + camera.CFrame.RightVector * speed end

		seat.AssemblyLinearVelocity = velocity
		seat.AssemblyAngularVelocity = Vector3.zero
		return
	end

	if Toggles.CarSpeed.Value and seat.AssemblyLinearVelocity.Magnitude > CAR_GROUND_MIN_SPEED then
		seat.AssemblyLinearVelocity = seat.AssemblyLinearVelocity + seat.CFrame.LookVector * (speed * deltaTime)
	end
end

---Refill stamina style values found under a container.
---@param container Instance
local function refillStamina(container)
	for _, descendant in ipairs(container:GetDescendants()) do
		if (descendant:IsA("NumberValue") or descendant:IsA("IntValue")) and matchesKeyword(descendant.Name, STAMINA_KEYWORDS) then
			if descendant.Value < STAMINA_REFILL_THRESHOLD then
				descendant.Value = STAMINA_MAX
			end
		end
	end
end

---Keep stamina style values and attributes topped up while enabled.
local function staminaLoop()
	while StreetLife.running do
		task.wait(STAMINA_INTERVAL)

		if not getgenv().Toggles.InfStamina.Value then continue end

		local character = localPlayer.Character
		if character then
			refillStamina(character)

			for name, value in pairs(character:GetAttributes()) do
				if type(value) == "number" and matchesKeyword(name, STAMINA_KEYWORDS) then
					character:SetAttribute(name, math.max(value, STAMINA_ATTRIBUTE_FLOOR))
				end
			end
		end

		refillStamina(localPlayer)
	end
end

---Hook the local humanoid so health is pinned while god mode is enabled.
local function setupGodMode()
	if StreetLife.godConnection then
		StreetLife.godConnection:Disconnect()
		StreetLife.godConnection = nil
	end

	if not getgenv().Toggles.GodMode.Value then
		return
	end

	local _, humanoid = getLocalParts()
	if not humanoid then
		return
	end

	humanoid.MaxHealth = math.huge
	humanoid.Health = math.huge

	StreetLife.godConnection = humanoid.HealthChanged:Connect(function()
		if getgenv().Toggles.GodMode.Value then
			humanoid.Health = math.huge
		end
	end)
end

---Restore the default health values after god mode is disabled.
local function teardownGodMode()
	if StreetLife.godConnection then
		StreetLife.godConnection:Disconnect()
		StreetLife.godConnection = nil
	end

	local _, humanoid = getLocalParts()
	if humanoid then
		humanoid.MaxHealth = DEFAULT_MAX_HEALTH
		humanoid.Health = DEFAULT_MAX_HEALTH
	end
end

---Detach the script and clean up everything it owns.
function StreetLife.detach()
	StreetLife.running = false

	for _, connection in ipairs(StreetLife.connections) do
		connection:Disconnect()
	end

	for player in pairs(StreetLife.espObjects) do
		removeEsp(player)
	end

	if StreetLife.fovCircle then
		StreetLife.fovCircle:Remove()
	end

	if StreetLife.fpsLabel then
		StreetLife.fpsLabel:Remove()
	end

	local camera = workspace.CurrentCamera
	if camera and StreetLife.savedFieldOfView then
		camera.FieldOfView = StreetLife.savedFieldOfView
	end

	local _, humanoid = getLocalParts()
	if humanoid then
		if StreetLife.savedWalkSpeed then
			humanoid.WalkSpeed = StreetLife.savedWalkSpeed
		end

		if StreetLife.savedJumpPower then
			humanoid.JumpPower = StreetLife.savedJumpPower
		end
	end

	teardownGodMode()
	table.clear(StreetLife.connections)
	shared.StreetLife = nil
end

---Build the menu and wire up every feature.
function StreetLife.init()
	local Library = fetch("Library.lua")
	local ThemeManager = fetch("addons/ThemeManager.lua")
	local SaveManager = fetch("addons/SaveManager.lua")
	local Toggles, Options = getgenv().Toggles, getgenv().Options
	StreetLife.library = Library

	StreetLife.fovCircle = Drawing.new("Circle")
	StreetLife.fovCircle.Thickness = 1.5
	StreetLife.fovCircle.Filled = false
	StreetLife.fovCircle.Color = Color3.fromRGB(220, 20, 60)
	StreetLife.fovCircle.Visible = false

	StreetLife.fpsLabel = Drawing.new("Text")
	StreetLife.fpsLabel.Size = 16
	StreetLife.fpsLabel.Outline = true
	StreetLife.fpsLabel.Color = Color3.fromRGB(220, 20, 60)
	StreetLife.fpsLabel.Position = Vector2.new(15, 15)
	StreetLife.fpsLabel.Visible = false

	local window = Library:CreateWindow({ Title = MENU_TITLE, Center = true, AutoShow = true })
	local tabs = {
		combat = window:AddTab("Combat"),
		visuals = window:AddTab("Visuals"),
		player = window:AddTab("Player"),
		teleports = window:AddTab("Teleports"),
		settings = window:AddTab("Settings"),
	}

	-- Aimbot.
	local aimBox = tabs.combat:AddLeftGroupbox("Aimbot")
	aimBox:AddToggle("AimbotEnabled", { Text = "Enable aimbot", Default = false })
	Toggles.AimbotEnabled:AddKeyPicker("AimbotKey", { Default = "MB2", Mode = "Hold", Text = "Aimbot key", NoUI = false })
	aimBox:AddSlider("AimSmoothness", { Text = "Smoothness (1 = instant)", Default = 2, Min = 1, Max = 10, Rounding = 0 })
	aimBox:AddSlider("AimPrediction", { Text = "Prediction", Default = 0.14, Min = 0, Max = 0.5, Rounding = 2 })
	aimBox:AddToggle("AimShowFov", { Text = "Show FOV circle", Default = false })
	aimBox:AddSlider("AimFovRadius", { Text = "FOV radius", Default = 150, Min = 10, Max = 500, Rounding = 0, Suffix = " px" })
	aimBox:AddDropdown("AimTargetPart", { Values = AIM_TARGET_PARTS, Default = 1, Text = "Target part" })
	aimBox:AddToggle("AimWallCheck", { Text = "Wall check", Default = true })

	-- Gun mods.
	local gunBox = tabs.combat:AddRightGroupbox("Gun mods")
	gunBox:AddToggle("InfAmmo", { Text = "Infinite ammo", Default = false })
	gunBox:AddToggle("FastReload", { Text = "Fast reload", Default = false })
	gunBox:AddSlider("ReloadSpeed", { Text = "Reload speed", Default = 3, Min = 1, Max = 10, Rounding = 1, Suffix = "x" })
	gunBox:AddToggle("NoRecoil", { Text = "No recoil", Default = false })

	-- Visuals.
	local espBox = tabs.visuals:AddLeftGroupbox("Player ESP")
	espBox:AddToggle("EspEnabled", { Text = "Enable ESP", Default = false })
	Toggles.EspEnabled:AddColorPicker("EspColor", { Default = Color3.fromRGB(220, 20, 60), Title = "ESP color" })
	espBox:AddSlider("EspMaxDistance", { Text = "Max distance", Default = 1000, Min = 100, Max = 2000, Rounding = 0, Suffix = " studs" })
	espBox:AddToggle("EspBoxes", { Text = "Boxes", Default = true })
	espBox:AddToggle("EspSkeleton", { Text = "Skeleton", Default = false })
	espBox:AddToggle("EspNames", { Text = "Names", Default = true })
	espBox:AddToggle("EspHealth", { Text = "Health bar", Default = false })
	espBox:AddToggle("EspShowDistance", { Text = "Distance", Default = true })
	espBox:AddToggle("EspTracers", { Text = "Tracers", Default = false })

	local miscVisualsBox = tabs.visuals:AddRightGroupbox("Misc")
	miscVisualsBox:AddToggle("CustomFov", { Text = "Custom FOV", Default = false })
	miscVisualsBox:AddSlider("FovValue", { Text = "FOV", Default = 100, Min = 70, Max = 120, Rounding = 0 })
	miscVisualsBox:AddToggle("ShowFps", { Text = "FPS counter", Default = false })

	-- Player.
	local playerBox = tabs.player:AddLeftGroupbox("Player")
	playerBox:AddToggle("GodMode", { Text = "No fall damage / god", Default = false })
	playerBox:AddToggle("InfStamina", { Text = "Infinite stamina", Default = false })
	playerBox:AddToggle("Noclip", { Text = "Noclip", Default = false })
	playerBox:AddToggle("InfiniteJump", { Text = "Infinite jump", Default = false })
	playerBox:AddToggle("SpeedEnabled", { Text = "Walk speed", Default = false })
	playerBox:AddSlider("SpeedValue", { Text = "Speed", Default = 24, Min = 16, Max = 80, Rounding = 0 })
	playerBox:AddToggle("JumpEnabled", { Text = "Jump power", Default = false })
	playerBox:AddSlider("JumpValue", { Text = "Power", Default = 70, Min = 50, Max = 200, Rounding = 0 })

	Toggles.GodMode:OnChanged(function()
		if Toggles.GodMode.Value then
			setupGodMode()
			notify("God mode enabled")
		else
			teardownGodMode()
			notify("God mode disabled")
		end
	end)

	local carBox = tabs.player:AddRightGroupbox("Vehicle")
	carBox:AddToggle("CarFly", { Text = "Car fly (WASD + camera)", Default = false })
	Toggles.CarFly:AddKeyPicker("CarFlyKey", { Default = "F", Mode = "Toggle", SyncToggleState = true, Text = "Car fly", NoUI = false })
	carBox:AddSlider("CarSpeedAmount", { Text = "Fly / boost speed", Default = 150, Min = 50, Max = 500, Rounding = 0 })
	carBox:AddToggle("CarSpeed", { Text = "Ground speed boost", Default = false })

	-- Teleports.
	local carTeleportBox = tabs.teleports:AddLeftGroupbox("Vehicle teleports")
	carTeleportBox:AddDropdown("CarTeleportTarget", { Values = collectCarTeleports(), Default = 1, Text = "Location" })
	carTeleportBox:AddButton({
		Text = "Teleport vehicle",
		Func = function()
			local position = getCarTeleportPosition(Options.CarTeleportTarget.Value)
			if position then
				teleportCar(position)
			end
		end,
	})

	local doorsBox = tabs.teleports:AddRightGroupbox("Doors")
	doorsBox:AddDropdown("DoorTarget", { Values = collectChildNames(TELEPORTS_FOLDER_NAME), Default = 1, Text = "Door" })
	doorsBox:AddButton({
		Text = "Teleport",
		Func = function()
			local folder = workspace:FindFirstChild(TELEPORTS_FOLDER_NAME)
			local door = folder and folder:FindFirstChild(Options.DoorTarget.Value)
			if door and door:IsA("BasePart") then
				teleportTo(door.Position)
			end
		end,
	})

	local landmarksBox = tabs.teleports:AddLeftGroupbox("Landmarks")
	landmarksBox:AddDropdown("LandmarkTarget", { Values = collectLandmarks(), Default = 1, Text = "Landmark" })
	landmarksBox:AddButton({
		Text = "Teleport",
		Func = function()
			local position = getLandmarkPosition(Options.LandmarkTarget.Value)
			if position then
				teleportTo(position)
			end
		end,
	})

	-- Settings.
	local menuBox = tabs.settings:AddLeftGroupbox("Menu")
	menuBox:AddButton({ Text = "Server hop", Func = serverHop })
	menuBox:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
	menuBox:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "End", NoUI = true, Text = "Menu keybind" })
	Library.ToggleKeybind = Options.MenuKeybind

	ThemeManager:SetLibrary(Library)
	SaveManager:SetLibrary(Library)
	SaveManager:IgnoreThemeSettings()
	SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
	ThemeManager:SetFolder("StreetLife")
	SaveManager:SetFolder("StreetLife/StreetLifeRemastered")
	SaveManager:BuildConfigSection(tabs.settings)
	ThemeManager:ApplyToTab(tabs.settings)

	-- Players for ESP.
	for _, player in ipairs(playersService:GetPlayers()) do
		createEsp(player)
	end

	track(playersService.PlayerAdded:Connect(createEsp))
	track(playersService.PlayerRemoving:Connect(removeEsp))

	track(runService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		updateFps()
		updateCameraFov(camera)
		updateAimbot(camera)
		updateNoRecoil(camera)
		updateEsp(camera)
	end))

	track(runService.Heartbeat:Connect(function()
		local character, humanoid = getLocalParts()
		if not humanoid then
			return
		end

		updateMovement(humanoid)
		updateGunMods(character, humanoid)
	end))

	track(runService.Stepped:Connect(function(_, deltaTime)
		local character, humanoid = getLocalParts()
		if not humanoid then
			return
		end

		updateNoclip(character)
		updateCar(humanoid, workspace.CurrentCamera, deltaTime)
	end))

	-- Infinite jump requires a fresh state change on every jump request.
	track(userInputService.JumpRequest:Connect(function()
		if not Toggles.InfiniteJump.Value then
			return
		end

		local _, humanoid = getLocalParts()
		if humanoid then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end))

	track(userInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		StreetLife.shooting = true
		StreetLife.lastPitch = nil
	end))

	track(userInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		StreetLife.shooting = false
		StreetLife.lastPitch = nil
	end))

	-- The humanoid is replaced on respawn, so god mode needs to be re-applied.
	track(localPlayer.CharacterAdded:Connect(function()
		task.wait(1)
		setupGodMode()
	end))

	task.spawn(staminaLoop)

	Library:OnUnload(StreetLife.detach)
end

---This is called when initialization errors.
---@param error string
local function onInitializeError(error)
	warn("Failed to initialize.")
	warn(error)
	warn(debug.traceback())
	StreetLife.detach()
end

-- Detach the previous instance so re-execution starts clean.
if shared.StreetLife then
	shared.StreetLife.detach()
end

shared.StreetLife = StreetLife
xpcall(StreetLife.init, onInitializeError)

return StreetLife
