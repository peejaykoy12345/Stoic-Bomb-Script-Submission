-- Stoic bomb move module for both player and npcs
local Libraries = game:GetService("ServerScriptService").Libraries
local AnimationPlayer = require(Libraries.AnimationPlayer) -- Plays the animations
local CooldownManager = require(Libraries.Combat.CooldownManager) -- Handles cooldowns
local Hitbox = require(Libraries.Combat.Hitbox) -- Hitbox
local Damage = require(Libraries.Combat.Damage) -- Handles the damage
local StateManager = require(Libraries.Combat.StateManager) -- Handles states
local MiscellaneousUtils = require(Libraries.MiscellaneousUtils) -- Common utils outside of moves
local MoveUtils = require(Libraries.Combat.MoveUtils) -- Common move utilities
local MoveSession = require(Libraries.Combat.MoveSession) -- For move sessions (easy stop or pause)
local Knockback = require(Libraries.Combat.Knockback) -- For velocity and knockback
local CraterModule = require(Libraries.Effects.CraterModule) -- For craters
local PoolingServiceVFX = require(Libraries.PerformanceLibraries.PoolingServiceVFX) -- For performance

local CONFIG = {
	MOVE_NAME = script.Name,
	CRATER = {
		SMALL = { Radius = 22, rockSize = 4 },
		LARGE = { Radius = 33, rockSize = 5 },
		Y_OFFSET = Vector3.new(0, 0, 0)
	},
	HITBOX = {
		SIZE = Vector3.new(40, 40, 40)
	},
	RAGDOLL_DURATION = 1, -- Duration for ragdoll
    -- Time for automatic clean up (failsafe just in case session doesn't)
	VFX_CLEANUP_DELAYS = {
		FLY = 1.75,
		FALL = 1.75,
		BOMB_MIDDLE = 5,
		BOMB_FLOOR = 5,
		SMOKE = 5
	},
	KNOCKBACK = {
		POWER = 50, -- The speed of knockback
		DURATION = 0.5, -- The cooldown for the knockback
	},
	COOLDOWN = 5, -- The cooldown in seconds
	DAMAGE = 100,
	DEBUG = false, -- 
}

local ANIMATION_IDS = {
	STARTUP = 101641222878356, -- For the jump part
	MAIN = 138522549693699 -- Falling part
}

local ASSETS = {
	FLY_VFX = script.Stoic.Fly.Fly.Fly,
	FALL_VFX = script.Stoic.Fall.Fall.Fall,
	BOMB_MIDDLE_VFX = script.Stoic["Stoic Bomb"].Middle,
	BOMB_FLOOR_VFX = script.Stoic["Stoic Bomb"].Floor,
	SMOKE_VFX = script.Stoic.Smoke.Smoke
}

local function createInitialCraters(position)
    -- Creates craters at the position + offset
	CraterModule.formCrater({
		Position = position + CONFIG.CRATER.Y_OFFSET,
		Radius = CONFIG.CRATER.SMALL.Radius,
		rockSize = CONFIG.CRATER.SMALL.rockSize
	})
	CraterModule.formCrater({
		Position = position + CONFIG.CRATER.Y_OFFSET,
		Radius = CONFIG.CRATER.LARGE.Radius,
		rockSize = CONFIG.CRATER.LARGE.rockSize
	})
end

local function setupFlyVFX(hrp, torso, session)
	local flxVFX = PoolingServiceVFX.GetPooledObject(ASSETS.FLY_VFX)
	flxVFX.CFrame = hrp.CFrame
	flxVFX.Parent = workspace.Effects

	session:AddVFX(flxVFX)
	
	local weld = Instance.new("Weld", flxVFX)
	weld.Part0 = torso
	weld.Part1 = flxVFX
	
	task.delay(CONFIG.VFX_CLEANUP_DELAYS.FLY, function()
		weld:Destroy()
		-- Let session return the pooled object so that the session can removes its reference to it
		session:DeleteVFX(flxVFX)
	end)
end

-- Get it from the pool
local function setupFallVFX(hrp, torso, session)
	local fallVFX = PoolingServiceVFX.GetPooledObject(ASSETS.FALL_VFX)
	local fallVFXWeld = Instance.new("Weld", fallVFX)

	session:AddVFX(fallVFX)

	return fallVFX, fallVFXWeld
end

-- Then activate here
local function activateFallVFX(fallVFX, fallVFXWeld, hrp, torso, session)
	-- FallVFX or also known as the FlameVFX
	fallVFX.CFrame = hrp.CFrame
	fallVFX.Parent = workspace.Effects

	fallVFXWeld.Part0 = torso
	fallVFXWeld.Part1 = fallVFX
	-- This makes it so that the weld attaches without snapping or offset issues
	fallVFXWeld.C0 = fallVFX.CFrame:ToObjectSpace(torso.CFrame * CFrame.new(0, 0, 0))

	task.delay(CONFIG.VFX_CLEANUP_DELAYS.FALL, function()
		fallVFXWeld:Destroy()
		session:DeleteVFX(fallVFX) -- Returns the fallVFX to the pool
	end)
end

-- Helper function to avoid repetition
-- Returns the pooled object, sets an automatic return to pool time and sets the cframe
local function addVFXWithDelay(vfx_temp, delayTime, session, cframe_offset, torso)
	local vfx = PoolingServiceVFX.GetPooledObject(vfx_temp)
	vfx.Parent = workspace.Effects
	vfx.CFrame = torso.CFrame * cframe_offset
	session:AddVFX(vfx) -- Add reference to the VFX
	task.delay(delayTime, function() 
		-- Returns the object to the pool after the delay 
		-- session will do it so that session also removes its reference to it
		session:DeleteVFX(vfx) 
	end)
	
	return vfx
end

local function spawnExplosionVFX(torso, fallVFXWeld, fallVFX, session)
	local bombMiddle = addVFXWithDelay(
		ASSETS.BOMB_MIDDLE_VFX,  
		CONFIG.VFX_CLEANUP_DELAYS.BOMB_MIDDLE,
		session, 
		CFrame.new(0, 0, 0), 
		torso
	)
	
	-- Return it anyway if it reaches this point 
	fallVFXWeld:Destroy()
	session:DeleteVFX(fallVFX)
	
	local bombFloor = addVFXWithDelay(
		ASSETS.BOMB_FLOOR_VFX, 
		CONFIG.VFX_CLEANUP_DELAYS.BOMB_FLOOR, 
		session, 
		CFrame.new(0, 0, 0), 
		torso
	)
	
	local smokeVFX = addVFXWithDelay(
		ASSETS.SMOKE_VFX, 
		CONFIG.VFX_CLEANUP_DELAYS.SMOKE, 
		session, 
		CFrame.new(0, -3, 0), 
		torso
	)
	
	-- Emit the full explosion vfx
	MiscellaneousUtils.emitEveryParticleEmitter(bombFloor)
	MiscellaneousUtils.emitEveryParticleEmitter(bombMiddle)
	MiscellaneousUtils.emitEveryParticleEmitter(smokeVFX)
end

local function createExplosionHitbox(char, hrp, session, params)
	-- Creates a custom hitbox
	local hitbox = Hitbox.CreateHitbox()
	hitbox.Size = CONFIG.HITBOX.SIZE
	hitbox.Visualizer = CONFIG.DEBUG -- Visualizer = true if debug is true else false
	hitbox.CFrame = hrp.CFrame -- Hitbox is in the middle of the model

	-- Reference hitbox to session so that it is included in session:Stop()
	session.hitbox = hitbox
	hitbox:Start()

	local damage = CONFIG.DAMAGE

	hitbox.Touched:Connect(function(hitChar: Model) -- hitbox.Touched is stopped in session:Stop()
		
		-- Checks if the target is still alive,
		-- doesn't have IFrames or other invincible states,
		-- and is not the same as the attacking character
		if not MoveUtils.validateHit(
			char, 
			hitChar, 
			false -- false means it's not blockable
		) then return end
		
		session:AddTarget(hitChar) -- For auto stun punish

		Damage.ApplyDamage(char, hitChar, damage)
		
		local Knockback_Settings = CONFIG.KNOCKBACK
		
		Knockback.ApplyVelocity(
			hitChar, 
			Knockback_Settings.POWER, 
			Knockback_Settings.DURATION,
			Vector3.new(0, 1, 0) -- Direction (upwards)
		)
		
		-- Ragdoll the victim
		local ragdollTrigger = hitChar:FindFirstChild("RagdollTrigger")
		if ragdollTrigger then -- RagdollTrigger has a listener which ragdolls the victim if it turns to true and unragdoll if false
			ragdollTrigger.Value = true
			task.delay(CONFIG.RAGDOLL_DURATION, function()
				-- Checks if it even still has a parent
				if ragdollTrigger.Parent then
					ragdollTrigger.Value = false
				end
			end)
		end
	end)
end

local function handleMainSequence(char, session, params, startupTrack)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso")
	if not hrp or not torso then return end

	local mainTrack, cleanUp = AnimationPlayer.PlayAnimation(char, ANIMATION_IDS.MAIN)

	session:AddAnimation(mainTrack, cleanUp)

	local fallVFX, fallVFXWeld = setupFallVFX(hrp, torso, session)
	
    -- Store animation marker name as keys and the value is the callback
    -- This makes connecting markers like this more cleaner
	local mainTrackMarkers = {
		["Fly"] = function()
			setupFlyVFX(hrp, torso, session)
		end,
		["FlameStart"] = function()
			activateFallVFX(fallVFX, fallVFXWeld, hrp, torso, session)
		end,
		["Explosion"] = function()
			-- This is where the explosion vfx happens
			spawnExplosionVFX(torso, fallVFXWeld, fallVFX, session)
			-- Setup the hitbox for the explosion
			createExplosionHitbox(char, hrp, session, params)
		end,
	}
	
	-- Once track is over Stop it
	mainTrack.Stopped:Connect(function()
		session:Stop()
	end)
	
	-- Connect the connections to main track then store them in session
	local connections = MoveUtils.connectMarkerSignals(mainTrack, mainTrackMarkers) 
	session:BulkAddAnimationMarker(connections) -- Session auto disconnects them if :Stop() is called
end

-- Main Move Function
return {
	run = function(char: Model, params: any)
		-- Checks if the player has a state that prevents him from using a move
		-- Checks cooldown
		local isValid, hrp, reason = MoveUtils.validateMoveRequirements(char, params, CONFIG.MOVE_NAME)
		if not isValid then
			return
		end

		local startupTrack = AnimationPlayer.PlayAnimation(char, ANIMATION_IDS.STARTUP)

		local hrp = char:FindFirstChild("HumanoidRootPart")
		local torso = char:FindFirstChild("Torso")
		if not hrp or not torso then return end

		createInitialCraters(hrp.Position)
	
		-- Make a move session
		-- If session stops everything stops
		-- Handles any possible errors
		-- References animations, vfx, sounds to pause or stop them
		-- Session methods like session:AddVFX() or session:AddAnimation() makes it references vfx or animations that don't outlast session
		-- By referencing them session can delete the vfx or stop the animation if it is stopped by another script 
		-- (By being detected by hitbox automatically stops the victim move session)
		local session = MoveSession.new({
			attacker = char,
			attackerProperties = {
				disableAutoRotate = true, -- disable auto rotate for the attacker
				anchorHrp = true, -- anchors the hrp
			},
			moveName = script.Name,
			sharedStates = {"IFrames", "CantUse", "InCutscene"}, -- For the attacker and target
			extraStartFunction = function(self)
				self:ApplyAttackerProperties() -- Applies the attacker properties
				self:SetSharedStatesToAttacker() -- applied the shared states to the attacker for now
			end,
			-- Set cooldown
			extraEndFunction = function()
				CooldownManager.SetCooldown(char, CONFIG.MOVE_NAME, CONFIG.COOLDOWN)
			end,
		})
		
		-- Sometimes session creation is cancelled if another session is
		-- already running
		if not session then return end

		session:AddAnimation(startupTrack) -- Reference the track in session so session can stop it or pause it

		session:Start()
		
		local startupTrackHitConnection: RBXScriptConnection?

		startupTrackHitConnection = startupTrack:GetMarkerReachedSignal("Hit"):Connect(function()
			-- Stop the startUp track to begin the falling sequence
			startupTrack:Stop()
			startupTrackHitConnection:Disconnect()
			handleMainSequence(char, session, params, startupTrack)
		end)
	end,
}
