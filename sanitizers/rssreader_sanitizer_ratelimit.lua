-- Minimum spacing between calls to a rate-limited sanitizer, kept in memory.
--
-- Instaparser's Trial plan allows 1 call per second and rate-limits (and
-- emails about) anything above it. One call at a time never gets there, since
-- a call takes ~3 s, but Offline Mode's parallel workers would: they start
-- their first calls at the same moment.
--
-- The workers are forked processes and share no memory, so instead of
-- talking to each other they take turns by the clock: before forking, the
-- parent gives worker k of n the slots start + (k + i·n)·interval. Two
-- workers never hold the same slot, so no two calls are closer than the
-- interval, and nothing is written to disk. Outside the workers (previews,
-- the sequential pass) this process's own last call is enough.

local socket = require("socket")

local RateLimit = {}

-- name -> time of this process's last call, and the interval it kept
local last_calls = {}
-- Calls made by workers that have since finished: nothing goes out before
-- external_until + interval.
local external_until = 0
-- Set in a worker: { start, count, index }
local time_slots

-- The spacing a sanitizer entry asks for: its seconds_between_calls, or the
-- given default. 0 turns the limit off.
function RateLimit.intervalFor(sanitizer, default_seconds)
    local seconds = tonumber(type(sanitizer) == "table" and sanitizer.seconds_between_calls)
        or default_seconds
    if not seconds or seconds <= 0 then
        return 0
    end
    return seconds
end

-- Earliest time any limited call may go out from this process, given the
-- calls it has made itself. The parent starts the workers' slots from here.
function RateLimit.nextFreeTime()
    local free = external_until
    for _name, call in pairs(last_calls) do
        free = math.max(free, call.time + call.interval)
    end
    return math.max(free, socket.gettime())
end

-- In a freshly forked worker: this is worker `index` (0-based) of `count`,
-- and slot 0 is at `start`.
function RateLimit.useTimeSlots(start, count, index)
    time_slots = { start = start, count = count, index = index }
end

-- In the parent, once the workers have finished: their calls happened up to
-- now, so the next one waits a full interval from here.
function RateLimit.noteExternalCalls(until_time)
    external_until = math.max(external_until, until_time or socket.gettime())
end

-- Blocks until this call may go out. name: one limit per service.
function RateLimit.wait(name, interval_s)
    if not interval_s or interval_s <= 0 then
        return
    end
    local now = socket.gettime()
    local last = last_calls[name]
    local slot
    if time_slots then
        local period = interval_s * time_slots.count
        local first = time_slots.start + time_slots.index * interval_s
        local turn = math.max(0, math.ceil((now - first) / period))
        slot = first + turn * period
        -- Each slot is used once (a retry takes the next one).
        if last and slot <= last.time then
            slot = slot + period
        end
    else
        slot = now
        if last then
            slot = math.max(slot, last.time + last.interval)
        end
        if external_until > 0 then
            slot = math.max(slot, external_until + interval_s)
        end
    end
    last_calls[name] = { time = slot, interval = interval_s }
    if slot > now then
        socket.sleep(slot - now)
    end
end

return RateLimit
