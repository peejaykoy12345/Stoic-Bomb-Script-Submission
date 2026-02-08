-- Stoic bomb move module for both player and npcs
local Libraries = game:GetService("ServerScriptService").Libraries
-- It works by taking the model of a player or an npc and an animation id to play
-- If animation does not exist then it creates it
-- If it does then it uses the cache to retrieve it
local AnimationPlayer = require(Libraries.AnimationPlayer) -- Plays the animations
-- CooldownManager fires a remote event to the client when a cooldown is set to trigger the gui
local CooldownManager = require(Libraries.Combat.CooldownManager) -- Handles cooldowns
-- Hitbox creates a hitbox object where I can modify the CFrame, Size, etc just like a normal basepart
-- but with more reliable .Touched function utilizing :GetPartsInBounds()
local Hitbox = require(Libraries.Combat.Hitbox) -- Hitbox
-- Used together mostly with Knockback because it produces a satisfying effect when damaging someone
local Damage = require(Libraries.Combat.Damage) -- Handles the damage
local MiscellaneousUtils = require(Libraries.MiscellaneousUtils) -- Common utils outside of moves
local MoveUtils = require(Libraries.Combat.MoveUtils) -- Common move utilities
local MoveSession = require(Libraries.Combat.MoveSession) -- For move sessions (easy stop or pause)
local Knockback = require(Libraries.Combat.Knockback) -- For velocity and knockback
local CraterModule = require(Libraries.Effects.CraterModule) -- For craters
-- I use pooling because calling :Destroy() is costy and for performance
-- It works checking if vfx is in the pool and if not it clones a template 
-- after done using the vfx is returned to the pool
-- It has a max limit of 50 vfx and the last one to be used gets destroyed to ensure that it doesn't
-- pile up on memory
local PoolingServiceVFX = require(Libraries.PerformanceLibraries.PoolingServiceVFX) -- For performance

local EffectsFolder = workspace.Effects

-- Config so that I can easily tweak move settings
-- Also makes it easier for the balance team or other devs who may not know how to code
-- modify it more easily and safely
local CONFIG = {
	MOVE_NAME = script.Name, -- Move name (in this case it is the script name)
	CRATER = {
		SMALL = { Radius = 22, rockSize = 4 },
		LARGE = { Radius = 33, rockSize = 5 },
		Y_OFFSET = Vector3.new(0, 0, 0) -- No offset but in the future I might tweak this
	},
	HITBOX = {
		SIZE = Vector3.new(40, 40, 40) -- Big hitbox because  this is an aoe move
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
	DAMAGE = 100, -- Damage of the explosion
	DEBUG = false, -- If it is in debug 
    BLOCKABLE = false,
}

local ANIMATION_IDS = {
	STARTUP = 101641222878356, -- For the jump part
	MAIN = 138522549693699 -- Falling part
}

local ASSETS = {
	FLY_VFX = script.Stoic.Fly.Fly.Fly,
	FALL_VFX = script.Stoic.Fall.Fall.Fall,
    -- The explosion VFX
	BOMB_MIDDLE_VFX = script.Stoic["Stoic Bomb"].Middle,
	BOMB_FLOOR_VFX = script.Stoic["Stoic Bomb"].Floor,
	SMOKE_VFX = script.Stoic.Smoke.Smoke
}

local function createInitialCraters(position)
    -- Creates craters at the position + offset
    -- It utilizes an open source module to make craters
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
	local flxVFX = PoolingServiceVFX.GetPooledObject(ASSETS.FLY_VFX) -- Get the vfx from the pool (creates it if not there)
	flxVFX.CFrame = hrp.CFrame -- Set flyVFX to the CFrame
	flxVFX.Parent = EffectsFolder -- Put it in the effects folder
    -- Add reference fallVFX reference to session so that session can return it to the pool once it ends
	session:AddVFX(flxVFX) -- Adding to session ensures VFX is auto cleaned up if move ends early or is interrupted
	
    -- Weld the torso to the flyVFX
	local weld = Instance.new("Weld", flxVFX)
	weld.Part0 = torso -- Welded to torso because it looks better (according to feedback I got from my vfx artist)
	weld.Part1 = flxVFX
	
    -- Auto return to pool just in case session fails (never happened before but just in case)
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

	session:AddVFX(fallVFX) -- Adding to session ensures VFX is auto cleaned up if move ends early or is interrupted

	return fallVFX, fallVFXWeld -- Return both the fallVFX and the weld so it can be both destroy or returned
end

-- Then activate here
local function activateFallVFX(fallVFX, fallVFXWeld, hrp, torso, session)
	-- FallVFX or also known as the FlameVFX
	fallVFX.CFrame = hrp.CFrame -- Set its CFrame to the hrp
	fallVFX.Parent = EffectsFolder -- Then put it in worksplace.Effects

    -- Weld it to the torso
	fallVFXWeld.Part0 = torso -- Welded to torso because it looks better (according to feedback I got from my vfx artist)
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
	local vfx = PoolingServiceVFX.GetPooledObject(vfx_temp) -- Get the pooled vfx
	vfx.Parent = EffectsFolder
    -- We add offset so that vfx can be positioned better
	vfx.CFrame = torso.CFrame * cframe_offset -- Add the offset if any
	session:AddVFX(vfx) -- Adding to session ensures VFX is auto cleaned up if move ends early or is interrupted
    -- Failsafe just in case session doesn't delete it in time
	task.delay(delayTime, function() 
		-- Returns the object to the pool after the delay 
		-- session will do it so that session also removes its reference to it
		session:DeleteVFX(vfx) 
	end)
	
	return vfx -- Returns it so that so other code can use it like calling MiscellaneousUtils.emitEveryParticleEmitter(vfx) on it
end

local function spawnExplosionVFX(torso, fallVFXWeld, fallVFX, session)
	local bombMiddle = addVFXWithDelay(
		ASSETS.BOMB_MIDDLE_VFX, 
		CONFIG.VFX_CLEANUP_DELAYS.BOMB_MIDDLE,
		session, 
		CFrame.new(0, 0, 0), -- No offset
		torso
	)
	
	-- Return it anyway if it reaches this point (Once it's explosion time we dont need fallVFX anymore)
	fallVFXWeld:Destroy()
	session:DeleteVFX(fallVFX)
	
	local bombFloor = addVFXWithDelay(
		ASSETS.BOMB_FLOOR_VFX, 
		CONFIG.VFX_CLEANUP_DELAYS.BOMB_FLOOR, 
		session, 
		CFrame.new(0, 0, 0), -- No offset
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
    -- Loops through particle emitters and using their emit count attribute to get how many to emit
	MiscellaneousUtils.emitEveryParticleEmitter(bombFloor)
	MiscellaneousUtils.emitEveryParticleEmitter(bombMiddle)
	MiscellaneousUtils.emitEveryParticleEmitter(smokeVFX)
end

local function createExplosionHitbox(char, hrp, session)
	-- Creates a custom hitbox
    -- Default mode is "CharacterHit" which means only one hit per model
	local hitbox = Hitbox.CreateHitbox() -- Using Open source module to create hitbox
	hitbox.Size = CONFIG.HITBOX.SIZE
	hitbox.Visualizer = CONFIG.DEBUG -- Visualizer = true if debug is true else false
	hitbox.CFrame = hrp.CFrame -- Hitbox is in the middle of the model

	-- Reference hitbox to session so that it is included in session:Stop()
    -- It stops the hitbox and disconnects the connection
    -- hitbox:Stop() automatically stops the Touched connection and session calls it in session:Stop()
	session.hitbox = hitbox 
	hitbox:Start() -- It starts the hitbox visualizer and allows us to connect Touched

	local damage = CONFIG.DAMAGE

    -- Connect the touched event ()
	hitbox.Touched:Connect(function(hitChar: Model) -- hitbox.Touched is stopped in session:Stop()
		
		-- Checks if the target is still alive,
		-- doesn't have IFrames or other invincible states,
		-- and is not the same as the attacking character
        -- It validates the hit to see if it should even go through
        -- Without this, the attacker will be able to hit himself or an invincible or someone with iframes
        -- can be hit
        -- Or a blocking person will be hit even if they blocking properly
		if not MoveUtils.validateHit(
			char, -- Attacker
			hitChar, -- Victim
		    CONFIG.BLOCKABLE -- false means it's not blockable
		) then return end
		
        -- When session:Stop() is called an auto stun punish is called on the user
        -- This feature is toggleable on session configs
        -- Most moves have stun punish once session ends so I made it automatic to apply stun once session ends
        -- For some moves there is targetStates or targetProperties and AddTarget applied that automatically
		session:AddTarget(hitChar) -- For auto stun punish

        -- Applies damage
		Damage.ApplyDamage(char, hitChar, damage)
		
		local Knockback_Settings = CONFIG.KNOCKBACK
		
		Knockback.ApplyVelocity(
			hitChar, 
			Knockback_Settings.POWER, 
			Knockback_Settings.DURATION,
			Vector3.new(0, 1, 0) -- Direction (upwards)
		)
		
        -- An open source module handles the ragdoll trigger listener
		-- Ragdoll the victim
		local ragdollTrigger = hitChar:FindFirstChild("RagdollTrigger")
		if ragdollTrigger then -- RagdollTrigger has a listener which ragdolls the victim if it turns to true and unragdoll if false
			ragdollTrigger.Value = true
			task.delay(CONFIG.RAGDOLL_DURATION, function()
				-- Checks if it even still has a parent
                -- Failsafe just in case it throws an error
				if ragdollTrigger.Parent then
					ragdollTrigger.Value = false
				end
			end)
		end
	end)
end

local function handleMainSequence(char, session)
    -- Check if it still has these things just in case
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso")
	if not hrp or not torso then return end

    -- It is the falling sequence of the move where the fly, flame start, etc markers will be triggered
	local mainTrack, cleanUp = AnimationPlayer.PlayAnimation(char, ANIMATION_IDS.MAIN)

    -- cleanUp only runs if the track ended or stopped but we reference the cleanUp function to
    -- session just in case cleanUp doesn't run autmatically
    -- runs mainTrack:Stop() and cleanUp() on session:Stop()
	session:AddAnimation(mainTrack, cleanUp)

	local fallVFX, fallVFXWeld = setupFallVFX(hrp, torso, session)
	
    -- Store animation marker name as keys and the value is the callback
    -- This makes connecting markers like this more cleaner
    -- We use markers because task.wait or task.delay is unreliable
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
			createExplosionHitbox(char, hrp, session)
		end,
	}
	
	-- Once track is over Stop it
	local conn = mainTrack.Stopped:Connect(function()
		session:Stop()
	end)

    session:BulkAddAnimationMarker({conn})
	
	-- Connect the connections to main track then store them in session
    -- We store it so session can disconnect them if it needs to e.g session:Stop()
	local connections = MoveUtils.connectMarkerSignals(mainTrack, mainTrackMarkers) 
	session:BulkAddAnimationMarker(connections) -- Session auto disconnects them if :Stop() is called
end

-- Main Move Function
return {
    -- Params contain additional info like camera cframe, the player if the player trigger this,
    -- Params is sometimes important because some moves require camera CFrame or the player not just 
    -- in validating if the player deserves to use this move
    -- Gets char as parameter instead of player so that it is npc friendly
	run = function(char: Model, params: any)
		-- Checks if the player has a state that prevents him from using a move
		-- Checks cooldown
        -- We get the hrp because in all moves we need the hrp of the model
        -- Params is sent here because it checks some player related stuff that npc doesn't have
        -- (There's no player only check yet but we still pass it through just in case we scale it with skill trees)
		local isValid, hrp, reason = MoveUtils.validateMoveRequirements(char, params, CONFIG.MOVE_NAME)
		if not isValid then -- Reason variable is used only when debugging
			return
		end

		local torso = char:FindFirstChild("Torso")
		if not hrp or not torso then return end -- Safety
	
		-- Creates a move session class
		-- If session stops everything stops
		-- Handles any possible errors
		-- References animations, vfx, sounds to pause or stop them
		-- Session methods like session:AddVFX() or session:AddAnimation() makes it references vfx or animations that don't outlast session
		-- By referencing them session can delete the vfx or stop the animation if it is stopped by another script or is interrupted by a move
		-- (By being detected by hitbox automatically stops the victim move session)
        -- It works by using methods to add references to anims, vfx, and storing them until it is stopped
        -- I used this so that it is easy to stop a move when the player is damaged and for easy one-line stops on moves
		local session = MoveSession.new({
			attacker = char,
            -- I have an attacker properties table because in cases like this where only an attacker should have
            -- properties modified I can do that. I also added this because I don't want to write more lines of code
            -- just to disable the humanoid auto rotate or to anchor the hrp and session needs to revert them anyway when
            -- it is stopped
			attackerProperties = {
				disableAutoRotate = true, -- disable auto rotate for the attacker
				anchorHrp = true, -- anchors the hrp
			},
			moveName = script.Name,
            -- I used shared states because
			sharedStates = {"IFrames", "CantUse", "InCutscene"}, -- For the attacker and target
            -- extraStartFunction is purely design choice I wanted the methods to be applied when :Start() is called
			extraStartFunction = function(self)
                -- The reason I have to manually apply this is because in some moves you don't want properties
                -- or states to be applied after it started
				self:ApplyAttackerProperties() -- Applies the attacker properties
				self:SetSharedStatesToAttacker() -- applied the shared states to the attacker for now
			end,
			-- extraEndFunction is a function that is called at the end of :Stop() and it is used
            -- when setting cooldowns, or additional stuff
			extraEndFunction = function()
				CooldownManager.SetCooldown(char, CONFIG.MOVE_NAME, CONFIG.COOLDOWN)
			end,
		})
		
		-- Sometimes session creation is cancelled if another session is
		-- already running.
		if not session then return end

         -- Start the startupTrack
		local startupTrack, cleanUp = AnimationPlayer.PlayAnimation(char, ANIMATION_IDS.STARTUP)

		session:AddAnimation(startupTrack, cleanUp) -- Reference the track in session so session can stop it or pause it

        createInitialCraters(hrp.Position) -- Purely design choice craters make the move feel stronger

        -- Start is required here because it has a failsafe to not be able to use :Stop() if it hasn't 
        -- started
		session:Start()   
		
		local startupTrackHitConnection: RBXScriptConnection?

		startupTrackHitConnection = startupTrack:GetMarkerReachedSignal("Hit"):Connect(function()
			-- Stop the startUp track to begin the falling sequence
            -- We stop it just in case it interferes with the main animation
			startupTrack:Stop()
			startupTrackHitConnection:Disconnect()
			handleMainSequence(char, session)
		end)
	end,
}
