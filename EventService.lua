-- Connected Discord-GitHub | Discord: sinaadev | Roblox: zeskhh

--[[
    Dynamic Event Framework — EventService + EventManager
    
    This script implements a LiveOps-style event engine for Roblox.
    It combines a scheduler (EventService) and a lifecycle manager (EventManager)
    into one cohesive system that dynamically triggers world events, manages
    their duration, fires client announcements, and distributes rewards.
    
    Architecture overview:
    - EventService owns the scheduler loop. It picks the next eligible event
      using weighted random selection and priority tiers, then delegates
      execution to EventManager.
    - EventManager owns the event lifecycle. Each event has three hooks:
      OnStart, OnUpdate (called every second), and OnEnd. These run inside
      a dedicated task.spawn thread so events never block each other.
    - EventRegistry (external module) tracks cooldowns and active state.
    - EventRewardSystem (external module) distributes coins to all players.
    - RemoteEvents push state changes to all connected clients in real time.
    
    Data flow:
    Scheduler loop → picks event → EventManager.startEvent →
    fires RemoteEvents → runs OnStart/OnUpdate/OnEnd lifecycle →
    distributes rewards → clears active state → scheduler picks next
]]

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

-- Shared framework modules (external, kept separate per single responsibility)
local EventConfig   = require(ReplicatedStorage.Shared.EventFramework.EventConfig)
local EventScheduler = require(ReplicatedStorage.Shared.EventFramework.EventScheduler)
local EventRegistry = require(ReplicatedStorage.Shared.EventFramework.EventRegistry)
local EventRewardSystem = require(ReplicatedStorage.Shared.EventFramework.EventRewardSystem)

-- ============================================================
-- REMOTE REFERENCES
-- These are set lazily on first use so the script can be required
-- before the RemoteEvent instances finish replicating.
-- ============================================================
local startedRemote    -- fires to all clients when an event begins
local endedRemote      -- fires to all clients when an event ends
local announcementRemote -- fires client-side banner notifications
local countdownRemote  -- fires every second with remaining time

-- Tracks running event threads so we can cancel them if needed
-- { [eventId] = { thread: thread, startTime: number } }
local runningEvents = {}

-- ============================================================
-- INTERNAL HELPER — lazy remote resolution
-- Calling WaitForChild here instead of at module load time
-- prevents yielding the entire require chain on startup.
-- ============================================================
local function ensureRemotes()
    if startedRemote then return end
    local remotes = ReplicatedStorage:WaitForChild("Remotes")
    startedRemote     = remotes:WaitForChild("EventStarted")
    endedRemote       = remotes:WaitForChild("EventEnded")
    announcementRemote = remotes:WaitForChild("EventAnnouncement")
    countdownRemote   = remotes:WaitForChild("EventCountdown")
end

-- ============================================================
-- EVENT BEHAVIORS
-- Each entry defines the three lifecycle hooks for one event type.
-- This table-driven approach means adding a new event only requires
-- adding a new key here — no changes to the framework logic below.
-- ============================================================
local EventBehaviors = {}

--[[
    MeteorShower
    A timed hazard event. Logs impact ticks every 5 seconds to simulate
    server-side meteor spawning. In a full implementation OnUpdate would
    spawn physical meteor parts using CFrame math and apply impulse forces.
]]
EventBehaviors["MeteorShower"] = {
    OnStart = function(eventId)
        print("[MeteorShower] Starting — meteors incoming!")
        announcementRemote:FireAllClients("warning", "☄ Meteor Shower Incoming!", "Take cover!")
    end,

    -- Called every second by the lifecycle loop below.
    -- elapsed = seconds since event started, duration = total event length.
    OnUpdate = function(eventId, elapsed, duration)
        if elapsed % 5 == 0 then
            -- In production: spawn a meteor part at a random map position,
            -- apply BodyVelocity pointing downward, destroy on impact.
            print("[MeteorShower] Impact tick at t=" .. elapsed)
        end
    end,

    OnEnd = function(eventId)
        announcementRemote:FireAllClients("success", "☄ Meteor Shower Over", "You survived!")
        EventRewardSystem.giveCompletionRewardToAll(eventId)
    end,
}

--[[
    BloodMoon
    A world-state event. Modifies Lighting service properties directly
    on the server — changes replicate automatically to all clients.
    OnEnd restores defaults so no cleanup RemoteEvent is needed.
]]
EventBehaviors["BloodMoon"] = {
    OnStart = function(eventId)
        print("[BloodMoon] Rising!")
        announcementRemote:FireAllClients("danger", "🌕 Blood Moon Has Risen!", "Enemies are stronger!")

        -- Shift global ambient lighting to deep red to signal danger state.
        -- Color3.fromRGB values chosen to feel threatening without being unreadable.
        Lighting.Ambient         = Color3.fromRGB(80, 0, 0)
        Lighting.OutdoorAmbient  = Color3.fromRGB(60, 0, 0)
        Lighting.ColorShift_Top  = Color3.fromRGB(150, 0, 0)
    end,

    OnUpdate = function(eventId, elapsed, duration)
        -- No per-tick logic needed. Lighting change is persistent until OnEnd.
    end,

    OnEnd = function(eventId)
        print("[BloodMoon] Setting.")
        announcementRemote:FireAllClients("info", "🌕 Blood Moon Ended", "The world is safe again.")

        -- Restore Lighting to neutral defaults.
        Lighting.Ambient         = Color3.fromRGB(70, 70, 70)
        Lighting.OutdoorAmbient  = Color3.fromRGB(70, 70, 70)
        Lighting.ColorShift_Top  = Color3.fromRGB(0, 0, 0)

        EventRewardSystem.giveCompletionRewardToAll(eventId)
    end,
}

--[[
    TreasureHunt
    A collection event with a mid-event warning at 30 seconds remaining.
    Demonstrates conditional OnUpdate logic for timed sub-announcements.
]]
EventBehaviors["TreasureHunt"] = {
    OnStart = function(eventId)
        print("[TreasureHunt] Chests spawning!")
        announcementRemote:FireAllClients("success", "🏆 Treasure Hunt Begins!", "Find the chests around the map!")
    end,

    OnUpdate = function(eventId, elapsed, duration)
        local remaining = duration - elapsed
        -- Fire a warning announcement exactly once when 30 seconds remain.
        if remaining == 30 then
            announcementRemote:FireAllClients("warning", "🏆 Treasure Hunt", "30 seconds remaining!")
        end
    end,

    OnEnd = function(eventId)
        announcementRemote:FireAllClients("info", "🏆 Treasure Hunt Over", "The chests have disappeared.")
        EventRewardSystem.giveCompletionRewardToAll(eventId)
    end,
}

--[[
    DoubleCoins
    A passive multiplier event. No per-tick logic needed.
    In production the EconomyService would check EventRegistry.isActive("DoubleCoins")
    before applying reward amounts, doubling them when this event is running.
]]
EventBehaviors["DoubleCoins"] = {
    OnStart = function(eventId)
        print("[DoubleCoins] Active!")
        announcementRemote:FireAllClients("success", "💰 Double Coins Active!", "All rewards doubled!")
    end,
    OnUpdate = function(eventId, elapsed, duration) end,
    OnEnd = function(eventId)
        announcementRemote:FireAllClients("info", "💰 Double Coins Ended", "Normal rewards restored.")
    end,
}

--[[
    BossInvasion
    A cooperative challenge event. Fires an enrage announcement at t=30
    to simulate escalating difficulty. In production OnStart would spawn
    a boss NPC model and OnEnd would destroy it.
]]
EventBehaviors["BossInvasion"] = {
    OnStart = function(eventId)
        print("[BossInvasion] Boss spawning!")
        announcementRemote:FireAllClients("danger", "💀 Boss Invasion!", "A powerful enemy has appeared. Work together!")
    end,

    OnUpdate = function(eventId, elapsed, duration)
        if elapsed == 30 then
            -- Simulate the boss entering an enraged phase mid-event.
            announcementRemote:FireAllClients("warning", "💀 Boss Invasion", "The boss is enraged!")
        end
    end,

    OnEnd = function(eventId)
        announcementRemote:FireAllClients("success", "💀 Boss Defeated!", "Amazing work!")
        EventRewardSystem.giveCompletionRewardToAll(eventId)
    end,
}

-- ============================================================
-- EVENT LIFECYCLE — startEvent
-- Registers the event as active, fires participation rewards,
-- then runs the full OnStart → OnUpdate loop → OnEnd pipeline
-- inside an independent coroutine via task.spawn.
-- Using task.spawn here is critical — it means two events can
-- run concurrently without either blocking the other.
-- ============================================================
local function startEvent(eventId)
    ensureRemotes()

    local eventData = EventConfig.Events[eventId]
    if not eventData then
        warn("[EventManager] Unknown event:", eventId)
        return
    end

    -- Prevent double-starting the same event.
    if EventRegistry.isActive(eventId) then
        warn("[EventManager] Already active:", eventId)
        return
    end

    local behavior = EventBehaviors[eventId]
    if not behavior then
        warn("[EventManager] No behavior for:", eventId)
        return
    end

    print("[EventManager] Starting:", eventId)

    -- Mark as active and stamp the cooldown before the thread starts.
    -- This prevents the scheduler from queuing the same event again
    -- during the brief window before the thread yields.
    EventRegistry.setActive(eventId, true)
    EventRegistry.setCooldown(eventId)

    -- Notify all clients that this event has started and send event metadata.
    startedRemote:FireAllClients(eventId, eventData)

    -- Award participation coins to every player currently in the server.
    EventRewardSystem.giveRewardToAll(eventData.Rewards.Participation)

    -- Spawn the lifecycle thread. task.spawn does not yield the caller.
    local thread = task.spawn(function()

        -- OnStart: one-time setup (lighting, spawning, announcements).
        local ok, err = pcall(behavior.OnStart, eventId)
        if not ok then warn("[EventManager] OnStart error:", err) end

        -- OnUpdate loop: ticks every second for the event's full duration.
        local elapsed = 0
        while elapsed < eventData.Duration do
            task.wait(1)
            elapsed += 1

            -- Push the remaining time to all clients every tick.
            countdownRemote:FireAllClients(eventId, eventData.Duration - elapsed)

            local ok2, err2 = pcall(behavior.OnUpdate, eventId, elapsed, eventData.Duration)
            if not ok2 then warn("[EventManager] OnUpdate error:", err2) end

            -- Allow external force-stop to break the loop cleanly.
            if not EventRegistry.isActive(eventId) then break end
        end

        -- Lifecycle complete — run teardown.
        stopEvent(eventId)
    end)

    runningEvents[eventId] = { thread = thread, startTime = tick() }
end

-- ============================================================
-- EVENT LIFECYCLE — stopEvent
-- Runs OnEnd cleanup, clears active state, and notifies clients.
-- Can be called by the lifecycle loop above OR externally for
-- force-stopping an event early.
-- ============================================================
function stopEvent(eventId)
    if not EventRegistry.isActive(eventId) then return end

    print("[EventManager] Stopping:", eventId)

    local behavior = EventBehaviors[eventId]
    if behavior then
        local ok, err = pcall(behavior.OnEnd, eventId)
        if not ok then warn("[EventManager] OnEnd error:", err) end
    end

    -- Clear active flag so the scheduler can re-queue this event
    -- once its cooldown expires.
    EventRegistry.setActive(eventId, false)
    ensureRemotes()
    endedRemote:FireAllClients(eventId)
    runningEvents[eventId] = nil

    print("[EventManager] Ended:", eventId)
end

-- ============================================================
-- SCHEDULER LOOP
-- Runs every SchedulerInterval seconds. Checks the manual queue
-- first (for admin-forced events), then falls back to automatic
-- weighted random selection from eligible events.
-- ============================================================
local function startSchedulerLoop()
    task.spawn(function()
        -- Brief startup delay to allow RemoteEvents to finish replicating.
        task.wait(10)

        while true do
            task.wait(EventConfig.SchedulerInterval)

            -- Priority 1: manually queued events (e.g. admin commands).
            local queued = EventScheduler.dequeueNext()
            if queued then
                print("[EventService] Running queued event:", queued)
                startEvent(queued)
            else
                -- Priority 2: automatic weighted random selection.
                -- getNextEvent filters by cooldown, active state, and stack rules,
                -- then picks from the highest priority tier using weighted random.
                local nextEvent = EventScheduler.getNextEvent()
                if nextEvent then
                    print("[EventService] Scheduler picked:", nextEvent.Id)
                    startEvent(nextEvent.Id)
                else
                    print("[EventService] No eligible events this tick")
                end
            end
        end
    end)
end

-- ============================================================
-- PUBLIC API
-- Exposed functions for external use (admin panels, test commands).
-- ============================================================
local EventService = {}

-- Force-start any event by ID, bypassing scheduler and cooldowns.
function EventService.forceStart(eventId)
    startEvent(eventId)
end

-- Force-stop any currently running event.
function EventService.forceStop(eventId)
    stopEvent(eventId)
end

-- Returns debug info for all registered events (active state, cooldowns).
function EventService.getDebugInfo()
    return EventRegistry.getDebugInfo()
end

-- Boot the system. Call once from Main.server.
function EventService.Init()
    ensureRemotes()
    startSchedulerLoop()
    print("[EventService] Initialized — interval:", EventConfig.SchedulerInterval, "seconds")
end

return EventService
