-- Connected Discord-GitHub | Discord: sinaadev | Roblox: zeskhh

--[[
    dynamic event framework - eventservice + eventmanager

    this script is a liveops-style event engine i built for roblox
    it combines a scheduler and a lifecycle manager into one system
    that automatically triggers world events, manages their duration,
    sends announcements to clients, and gives out rewards when they end

    how it works:
    - eventservice runs the scheduler loop, it picks the next event using
      weighted random selection and priority tiers then hands it off to
      the lifecycle logic below
    - each event has three hooks: onstart, onupdate (runs every second),
      and onend, they all run in their own task.spawn thread so two
      events can run at the same time without blocking each other
    - eventregistry (external module) keeps track of cooldowns and
      which events are currently active
    - eventrewardsystem (external module) gives coins to all players
    - remoteevents push state changes to clients in real time

    flow:
    scheduler loop > picks event > startEvent >
    fires remotes > onstart/onupdate/onend lifecycle >
    gives rewards > clears active state > picks next
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

-- external framework modules, kept separate so each one has one job
local EventConfig       = require(ReplicatedStorage.Shared.EventFramework.EventConfig)
local EventScheduler    = require(ReplicatedStorage.Shared.EventFramework.EventScheduler)
local EventRegistry     = require(ReplicatedStorage.Shared.EventFramework.EventRegistry)
local EventRewardSystem = require(ReplicatedStorage.Shared.EventFramework.EventRewardSystem)

-- ============================================================
-- remote references
-- resolved lazily on first use so requiring this module doesnt
-- yield the whole script while remotes are still replicating
-- ============================================================
local startedRemote     -- tells clients an event started
local endedRemote       -- tells clients an event ended
local announcementRemote -- sends banner notifications to clients
local countdownRemote   -- sends remaining time every second

-- stores running event threads so we can cancel them if needed
-- { [eventId] = { thread, startTime } }
local runningEvents = {}

-- ============================================================
-- internal helper - lazy remote resolution
-- only grabs remotes on the first call, every call after
-- that just skips straight through since theyre already set
-- ============================================================
local function ensureRemotes()
    if startedRemote then return end
    local remotes = ReplicatedStorage:WaitForChild("Remotes")
    startedRemote      = remotes:WaitForChild("EventStarted")
    endedRemote        = remotes:WaitForChild("EventEnded")
    announcementRemote = remotes:WaitForChild("EventAnnouncement")
    countdownRemote    = remotes:WaitForChild("EventCountdown")
end

-- ============================================================
-- event behaviors
-- table-driven design, each event type has its own onstart,
-- onupdate, and onend hooks defined here
-- adding a new event type only means adding a new key to this
-- table, no changes needed anywhere else in the framework
-- ============================================================
local EventBehaviors = {}

--[[
    meteorshower
    a timed hazard event, logs an impact tick every 5 seconds
    in a full game onupdate would spawn actual meteor parts using
    cframe math and apply physics impulses on impact
]]
EventBehaviors["MeteorShower"] = {
    OnStart = function(eventId)
        print("[MeteorShower] starting - meteors incoming")
        announcementRemote:FireAllClients("warning", "☄ Meteor Shower Incoming!", "Take cover!")
    end,

    -- elapsed = seconds since event started, duration = total event length
    OnUpdate = function(eventId, elapsed, duration)
        if elapsed % 5 == 0 then
            -- in production this would spawn a meteor part at a random
            -- position above the map, give it a downward velocity,
            -- and destroy it on impact with a blast radius check
            print("[MeteorShower] impact tick at t=" .. elapsed)
        end
    end,

    OnEnd = function(eventId)
        announcementRemote:FireAllClients("success", "☄ Meteor Shower Over", "You survived!")
        EventRewardSystem.giveCompletionRewardToAll(eventId)
    end,
}

--[[
    bloodmoon
    a world-state event that modifies the lighting service directly
    on the server, roblox replicates lighting changes automatically
    so no remote is needed to update clients
    onend restores everything back to default so no cleanup remote needed
]]
EventBehaviors["BloodMoon"] = {
    OnStart = function(eventId)
        print("[BloodMoon] rising")
        announcementRemote:FireAllClients("danger", "🌕 Blood Moon Has Risen!", "Enemies are stronger!")

        -- shift global ambient to deep red to signal the danger state
        -- these values were picked to feel threatening without making
        -- the map too dark to see
        Lighting.Ambient        = Color3.fromRGB(80, 0, 0)
        Lighting.OutdoorAmbient = Color3.fromRGB(60, 0, 0)
        Lighting.ColorShift_Top = Color3.fromRGB(150, 0, 0)
    end,

    OnUpdate = function(eventId, elapsed, duration)
        -- no per-tick logic needed here, the lighting change
        -- persists on its own until onend restores it
    end,

    OnEnd = function(eventId)
        print("[BloodMoon] setting")
        announcementRemote:FireAllClients("info", "🌕 Blood Moon Ended", "The world is safe again.")

        -- restore lighting back to neutral defaults
        Lighting.Ambient        = Color3.fromRGB(70, 70, 70)
        Lighting.OutdoorAmbient = Color3.fromRGB(70, 70, 70)
        Lighting.ColorShift_Top = Color3.fromRGB(0, 0, 0)

        EventRewardSystem.giveCompletionRewardToAll(eventId)
    end,
}

--[[
    treasurehunt
    a collection event with a mid-event warning at 30 seconds left
    shows how onupdate can be used for conditional timed logic
    not just simple per-tick stuff
]]
EventBehaviors["TreasureHunt"] = {
    OnStart = function(eventId)
        print("[TreasureHunt] chests spawning")
        announcementRemote:FireAllClients("success", "🏆 Treasure Hunt Begins!", "Find the chests around the map!")
    end,

    OnUpdate = function(eventId, elapsed, duration)
        local remaining = duration - elapsed
        -- fire a warning exactly once when 30 seconds remain
        -- the == check means this only triggers on one specific tick
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
    doublecoins
    a passive multiplier event with no per-tick logic needed
    in production the economy service would call eventregistry.isActive
    on this event before applying reward amounts and double them
    if it returns true
]]
EventBehaviors["DoubleCoins"] = {
    OnStart = function(eventId)
        print("[DoubleCoins] active")
        announcementRemote:FireAllClients("success", "💰 Double Coins Active!", "All rewards doubled!")
    end,
    OnUpdate = function(eventId, elapsed, duration) end,
    OnEnd = function(eventId)
        announcementRemote:FireAllClients("info", "💰 Double Coins Ended", "Normal rewards restored.")
    end,
}

--[[
    bossinvasion
    a cooperative challenge event, fires an enrage announcement
    at t=30 to simulate difficulty scaling mid-fight
    in production onstart would spawn the boss npc and onend
    would clean it up whether it was defeated or the timer ran out
]]
EventBehaviors["BossInvasion"] = {
    OnStart = function(eventId)
        print("[BossInvasion] boss spawning")
        announcementRemote:FireAllClients("danger", "💀 Boss Invasion!", "A powerful enemy has appeared. Work together!")
    end,

    OnUpdate = function(eventId, elapsed, duration)
        if elapsed == 30 then
            -- simulate the boss entering an enraged phase
            announcementRemote:FireAllClients("warning", "💀 Boss Invasion", "The boss is enraged!")
        end
    end,

    OnEnd = function(eventId)
        announcementRemote:FireAllClients("success", "💀 Boss Defeated!", "Amazing work!")
        EventRewardSystem.giveCompletionRewardToAll(eventId)
    end,
}

-- ============================================================
-- startEvent
-- registers the event as active, fires participation rewards,
-- then runs the full onstart > onupdate loop > onend pipeline
-- inside its own coroutine via task.spawn
-- the reason i use task.spawn here is so two events can run
-- at the same time without either one blocking the other
-- ============================================================
local function startEvent(eventId)
    ensureRemotes()

    local eventData = EventConfig.Events[eventId]
    if not eventData then
        warn("[EventManager] unknown event:", eventId)
        return
    end

    -- prevent the same event from starting twice
    if EventRegistry.isActive(eventId) then
        warn("[EventManager] already active:", eventId)
        return
    end

    local behavior = EventBehaviors[eventId]
    if not behavior then
        warn("[EventManager] no behavior defined for:", eventId)
        return
    end

    print("[EventManager] starting:", eventId)

    -- mark as active and stamp the cooldown before the thread starts
    -- this prevents the scheduler from queueing the same event again
    -- during the brief window before the thread first yields
    EventRegistry.setActive(eventId, true)
    EventRegistry.setCooldown(eventId)

    -- tell all clients this event started and send them the event data
    startedRemote:FireAllClients(eventId, eventData)

    -- give participation coins to every player in the server right now
    EventRewardSystem.giveRewardToAll(eventData.Rewards.Participation)

    -- spawn the lifecycle thread, task.spawn doesnt yield the caller
    -- so the scheduler loop keeps running normally while this runs
    local thread = task.spawn(function()

        -- onstart runs once for setup like lighting changes or spawning
        local ok, err = pcall(behavior.OnStart, eventId)
        if not ok then warn("[EventManager] onstart error:", err) end

        -- tick every second for the full duration of the event
        local elapsed = 0
        while elapsed < eventData.Duration do
            task.wait(1)
            elapsed += 1

            -- push remaining time to all clients on every tick
            countdownRemote:FireAllClients(eventId, eventData.Duration - elapsed)

            local ok2, err2 = pcall(behavior.OnUpdate, eventId, elapsed, eventData.Duration)
            if not ok2 then warn("[EventManager] onupdate error:", err2) end

            -- if the event was force-stopped externally this breaks the loop
            if not EventRegistry.isActive(eventId) then break end
        end

        stopEvent(eventId)
    end)

    runningEvents[eventId] = { thread = thread, startTime = tick() }
end

-- ============================================================
-- stopEvent
-- runs onend cleanup, clears active state, notifies clients
-- can be triggered by the lifecycle loop finishing naturally
-- or called externally to force-stop an event early
-- ============================================================
function stopEvent(eventId)
    if not EventRegistry.isActive(eventId) then return end

    print("[EventManager] stopping:", eventId)

    local behavior = EventBehaviors[eventId]
    if behavior then
        local ok, err = pcall(behavior.OnEnd, eventId)
        if not ok then warn("[EventManager] onend error:", err) end
    end

    -- clear active flag so the scheduler can re-queue this event
    -- once its cooldown timer expires
    EventRegistry.setActive(eventId, false)
    ensureRemotes()
    endedRemote:FireAllClients(eventId)
    runningEvents[eventId] = nil

    print("[EventManager] ended:", eventId)
end

-- ============================================================
-- scheduler loop
-- runs every schedulerinterval seconds
-- checks the manual queue first for admin-forced events,
-- then falls back to automatic weighted random selection
-- ============================================================
local function startSchedulerLoop()
    task.spawn(function()
        -- short startup delay so remotes finish replicating before
        -- the first event could possibly fire
        task.wait(10)

        while true do
            task.wait(EventConfig.SchedulerInterval)

            -- priority 1: manually queued events like admin force-starts
            local queued = EventScheduler.dequeueNext()
            if queued then
                print("[EventService] running queued event:", queued)
                startEvent(queued)
            else
                -- priority 2: automatic selection
                -- getnextevent filters by cooldown, active state, and
                -- stack conflict rules then picks from the highest
                -- priority tier using weighted random selection
                local nextEvent = EventScheduler.getNextEvent()
                if nextEvent then
                    print("[EventService] scheduler picked:", nextEvent.Id)
                    startEvent(nextEvent.Id)
                else
                    print("[EventService] no eligible events this tick")
                end
            end
        end
    end)
end

-- ============================================================
-- public api
-- these are the only functions meant to be called from outside
-- ============================================================
local EventService = {}

-- force-start any event by id, bypasses scheduler and cooldowns
function EventService.forceStart(eventId)
    startEvent(eventId)
end

-- force-stop any currently running event
function EventService.forceStop(eventId)
    stopEvent(eventId)
end

-- returns debug info for all registered events
function EventService.getDebugInfo()
    return EventRegistry.getDebugInfo()
end

-- boot the whole system, call this once from main.server
function EventService.Init()
    ensureRemotes()
    startSchedulerLoop()
    print("[EventService] initialized - interval:", EventConfig.SchedulerInterval, "seconds")
end

return EventService
