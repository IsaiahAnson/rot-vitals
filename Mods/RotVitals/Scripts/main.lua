--[[--------------------------------------------------------------------------
  RotVitals 1.0.3  -  floating enemy health bars for Grain Rot (UE 5.7 / UE4SS)

  Version numbers here match the released package from 1.0.2 onward. Earlier
  builds carried their own counter: package 1.0.0 shipped script v1.1, and
  package 1.0.1 shipped script v1.2.

  A health bar hovers over every enemy's head, tracks them smoothly at frame
  rate, and reads the live replicated health value - so it works as host or
  as a joining client, and unmodded lobby mates see nothing.

  1.0.3 stops bars flashing through walls. Three separate ways a throttled
  line-of-sight check leaked, all of them the same mistake - letting the
  permissive state win when the answer was not actually known:
    * "not traced yet" counted as visible, because the gate only hid a bar
      once a trace had PROVEN no line of sight. Unknown now counts as hidden;
      nothing goes up until a trace actually succeeds.
    * an enemy last traced while visible came back still flagged visible after
      leaving range or the screen. LOS state now expires after LOS_STALE.
    * a bar already showing survived until TWO traces failed, so stepping
      behind cover left it up for a fifth of a second on the wrong side of the
      wall. Losing sight is now instant, and it is GAINING sight that needs
      consecutive confirmations (LOS_HITS) - LineOfSightTo probes the target's
      head and capsule edges as well as its centre, so one sample can succeed
      on a sliver round a corner. Ties resolve to hidden, boundaries settle
      instead of flickering, and cover hides a bar with a faster fade
      (FADE_OUT_LOS) so it does not trail into the wall behind you.

  1.0.2 adds the flying drones. AHeldenDrone derives from AActor, not
  AHeldenCharacter, so the NotifyOnNewObject/FindAllOf intake never saw them
  and they had no bars at all. They also carry no health of their own - just a
  Default/Wounded/Dead state that follows the health of the character flying
  them - so their bar shows that host's real health by default (CFG.DRONES).
  Intake give-ups are now logged, so "enemy X never gets a bar" is answerable
  from UE4SS.log rather than by guesswork.

  1.0.1 fixed the bar maximum on clients. UHeldenStatsComponent.TotalStats is
  computed locally rather than replicated - the game replicates a recipe
  (ReplicatedStats: stat names + level) and each machine works the totals out
  for itself - and on a machine that does not own the actor that recompute
  does not produce real numbers: every enemy read back a flat 120 max on a
  joining client. CurrentHealth does replicate, which is why only the right
  hand number was wrong. Maximums now come from the game's totals only where
  AActor:HasAuthority() is true, and from the highest health actually
  observed everywhere else. That also fixes a second case the game's own
  numbers could never have covered: a host running a stat mod like
  RotScaling raises max health locally, and that raised maximum never
  reaches clients at all.

  1.0.0 shipped with
    * BORDER: drop shadow + hard black outline + bone rim (gold when enchanted)
    * JITTER FIX: the bar is now placed by our own projection maths using a
      one-frame-ahead camera. The anim-BP hook runs before the camera manager
      updates, so the engine projection originally used placed bars with last
      frame's camera - the error is proportional to how fast the camera is
      moving, which is exactly the "bars jump when I move around an enemy"
      symptom. The maths is checked against the engine's own projection for
      the first 20 samples and only used if it agrees; otherwise it falls
      back to the engine projection. Set CAMERA_LEAD = 0 to disable the correction.
    * WALLS: real line-of-sight test (AController::LineOfSightTo - a bool
      return, no FHitResult out-param, so none of the crash shapes). The
      first cut relied on WasRecentlyRendered, which also counts shadow-only renders,
      so enemies behind walls stayed "visible".
    * range cut from 38 m to 18 m.

  Where the numbers live (CXXHeaderDump verified 2026-08-15):
    AHeldenCharacter.CharacterStats -> UHeldenStatsComponent
      .CurrentHealth, .bInitalized, .TotalStats(FHeldenStats).MaxHealth
    AHeldenCharacter.AppliedCharacterPreset(UHeldenCharacterPreset).CharacterType
      == 4 (EHeldenCharacterType::Enemy); players 1, soul vessels 2, friendly 3
    AHeldenCharacter.CharacterState == 1 (ECharacterState::Dead)
    AHeldenCharacter.Enchantment (FName)

  Landmine compliance (see the Grain Rot notes):
    * no LoopAsync / ExecuteWithDelay timers (fatal) - per-frame BP hook only
    * no FKey / IsInputKeyDown / key pollers - no hotkeys at all
    * no K2_Set*Location, no FHitResult out-params, no trace out-params
    * no FName-from-string function arguments
    * intake is NotifyOnNewObject + a bounded per-frame drain, plus a slow
      catch-up sweep; no FindAllOf polling loops
    * the ABP_HeldenPlayer hook fires once per animated character per frame,
      so all work is gated on os.clock(), never on a frame counter
    * everything is pcall'd with an error cap; a failure degrades the visuals
      rather than taking the game down
--------------------------------------------------------------------------]]

local CFG = {
    -- Range -----------------------------------------------------------------
    MAX_DIST      = 1800,   -- uu: no bar past this (1 m = 100 uu)
    FADE_DIST     = 1300,   -- uu: start fading out here
    MAX_BARS      = 16,     -- most bars on screen at once (nearest win)

    -- Line of sight ---------------------------------------------------------
    WALL_CHECK    = true,   -- hide bars for enemies behind geometry
    LOS_INTERVAL  = 0.09,   -- s between traces per enemy (staggered)
    -- The asymmetry here matters and it is deliberately biased toward hiding.
    -- Losing sight takes effect on the FIRST failed trace, because a bar that
    -- lingers after you step behind cover is a bar visible through a wall.
    -- Gaining sight needs LOS_HITS traces in a row, so a marginal peek round a
    -- corner - LineOfSightTo also probes the target's head and capsule edges,
    -- so a single sample can succeed on a sliver - does not put a bar up. Ties
    -- resolve to hidden, and boundaries settle instead of flickering.
    LOS_MISSES    = 1,
    LOS_HITS      = 2,
    LOS_STALE     = 0.5,    -- s: after this long without a trace, an enemy has
                            -- to prove line of sight again from scratch
    RENDER_CHECK  = true,   -- also require the enemy to be rendered at all

    -- Placement / size ------------------------------------------------------
    HEAD_OFFSET   = 40,     -- uu above the top of the capsule
    BAR_W         = 128,    -- widget units at reference distance
    BAR_H         = 14,
    BORDER        = 2,      -- 1 px black outline + 1 px rim
    SHADOW_X      = 1.5,
    SHADOW_Y      = 2,
    SEGMENTS      = 4,      -- divider ticks across the track (0 = none)
    REF_DIST      = 800,    -- distance where scale is exactly 1.0
    MIN_SCALE     = 0.70,   -- below ~0.7 the 1 px rim starts to shimmer
    MAX_SCALE     = 1.15,

    -- Flying drones -----------------------------------------------------------
    -- AHeldenDrone is an AActor, not a character, and carries no health of its
    -- own - only a Default/Wounded/Dead state that follows the health of the
    -- host character that flies it (OnHomeHealthChanged_Auth + WoundedThreshold).
    --   "host"  - show that host's real health. Continuous and exact, and it is
    --             what actually decides whether the drone lives. If the host is
    --             also on screen you will see two bars reading the same numbers.
    --   "state" - show the drone's own 3-step state instead, no numbers.
    --   "off"   - no bars on drones.
    DRONES        = "host",
    DRONE_OFFSET  = 55,     -- uu above the drone's origin (it has no capsule)
    DRONE_WOUNDED = 0.40,   -- bar fraction shown for Wounded in "state" mode

    -- Behaviour -------------------------------------------------------------
    SHOW_NUMBERS  = true,   -- "42 / 118" above the bar
    TEXT_SCALE    = 0.46,   -- stock TextBlock font is 24pt; 0.46 ~ 11pt
    HIDE_FULL_HP  = false,  -- true = only show enemies that have been hurt
    HIDE_DEAD     = true,

    -- Tracking --------------------------------------------------------------
    -- The anim hook runs before the camera manager updates, so the camera we
    -- can read is one frame stale. 1.0 projects with the camera extrapolated
    -- a full frame forward. If bars now OVERSHOOT when you spin, set 0.
    CAMERA_LEAD   = 1.0,
    LEAD_MAX_DEG  = 30,     -- ignore rotation jumps bigger than this (cuts)
    LEAD_MAX_UU   = 300,    -- ditto for camera teleports
    POS_SMOOTH    = 0,      -- extra screen-space smoothing, 0 = off, try 45
    CAL_SAMPLES   = 20,     -- projection cross-checks before trusting ours
    CAL_TOLERANCE = 4,      -- px of agreement required

    -- Feel ------------------------------------------------------------------
    GHOST_HOLD    = 0.22,   -- s the ghost bar waits before draining
    GHOST_RATE    = 6.5,    -- higher = faster drain
    PUNCH_TIME    = 0.14,   -- s of hit-punch scale pop
    PUNCH_AMOUNT  = 0.16,   -- extra scale at the peak of the punch
    FADE_IN       = 0.10,
    FADE_OUT      = 0.20,
    FADE_OUT_LOS  = 0.07,   -- snappier fade when cover is what hid it, so the
                            -- bar does not trail behind you into the wall

    -- Pacing ----------------------------------------------------------------
    RANGE_SECS    = 0.15,   -- distance / liveness pass
    RANGE_CHUNK   = 96,     -- enemies examined per pass (round robin)
    SWEEP_SECS    = 12,     -- catch-up FindAllOf sweep
    VIEWPORT_SECS = 2,
    STATUS_SECS   = 60,
    DRAIN_PER_FRAME = 3,
    SETTLE_SECS   = 0.25,   -- wait after spawn before classifying
    MAX_TRIES     = 40,
    ERROR_CAP     = 12,
}

-- Colours (FLinearColor) -----------------------------------------------------
local COL = {
    SHADOW    = { R = 0.00, G = 0.00, B = 0.00, A = 0.42 },
    OUTER     = { R = 0.02, G = 0.018, B = 0.015, A = 0.95 },
    RIM       = { R = 0.55, G = 0.50, B = 0.40, A = 0.88 },
    RIM_ENCH  = { R = 0.90, G = 0.72, B = 0.24, A = 0.95 },
    TRACK     = { R = 0.07, G = 0.065, B = 0.06, A = 0.95 },
    GHOST     = { R = 0.95, G = 0.32, B = 0.22, A = 0.78 },
    GLOSS     = { R = 1.00, G = 1.00, B = 1.00, A = 0.14 },
    SEP       = { R = 0.03, G = 0.028, B = 0.025, A = 0.55 },
    -- health ramp: fraction, R, G, B
    RAMP = {
        { 0.00, 0.94, 0.14, 0.11 },
        { 0.35, 0.98, 0.62, 0.10 },
        { 0.70, 0.44, 0.88, 0.24 },
        { 1.00, 0.24, 0.90, 0.36 },
    },
}

local function Log(m) print("[RotVitals] " .. tostring(m) .. "\n") end

local S = {
    errCount = 0,
    lastTick = 0,
    pc = nil,
    camMgr = nil,
    queue = {},      -- { obj, readyAt, tries }
    memo  = {},      -- full name -> true (already classified, never re-queue)
    list  = {},      -- tracked enemy records
    byKey = {},
    active = {},     -- in-range subset, rebuilt after every range pass
    scanIdx = 1,
    built = false,
    textOK = CFG.SHOW_NUMBERS,
    vw = 1920, vh = 1080,
    nextRange = 0, nextSweep = 0, nextViewport = 0, nextStatus = 0,
    shown = 0,
    hooked = false,
    -- projection self-check
    manualOK = nil,  -- nil = still calibrating, true/false = decided
    calN = 0, calGood = 0, calErr = 0, calDone = false,
    auth = nil,      -- logged once: do we own the enemies we are drawing?
    gaveUp = 0,      -- capped log of intake give-ups, for diagnosing gaps
}

local W = { widget = nil, canvas = nil, bars = {}, wll = nil }

-- Camera state, sampled once per frame. `e*` is the extrapolated camera the
-- bars are actually projected with.
local CAM = {
    have = false,
    x = 0, y = 0, z = 0, pitch = 0, yaw = 0, roll = 0, fov = 90,
    px = 0, py = 0, pz = 0, ppitch = 0, pyaw = 0,
    ex = 0, ey = 0, ez = 0,
    fx = 1, fy = 0, fz = 0,   -- forward
    rx = 0, ry = 1, rz = 0,   -- right
    ux = 0, uy = 0, uz = 1,   -- up
    focal = 800,
    -- raw (un-extrapolated) basis, used while cross-checking the maths
    cfx = 1, cfy = 0, cfz = 0,
    crx = 0, cry = 1, crz = 0,
    cux = 0, cuy = 0, cuz = 1,
}

-- ------------------------------------------------------------------ helpers

local UEHelpers
pcall(function() UEHelpers = require("UEHelpers") end)

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function WrapDeg(a)
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end

local function KeyOf(obj)
    local k
    pcall(function() k = obj:GetFullName() end)
    return k
end

-- World real time changes exactly once per rendered frame (and is immune to
-- pause and time dilation), so it is what tells us whether two anim-hook
-- calls belong to the same frame.
local function WorldTime(pc)
    if S.gps == nil then
        S.gps = StaticFindObject("/Script/Engine.Default__GameplayStatics") or false
    end
    if not S.gps then return nil end
    local t
    local ok = pcall(function() t = S.gps:GetRealTimeSeconds(pc) end)
    if ok and type(t) == "number" then return t end
    S.gps = false
    return nil
end

local function GetPC()
    if S.pc and S.pc:IsValid() then return S.pc end
    S.camMgr = nil
    CAM.have = false
    local pc
    if UEHelpers and UEHelpers.GetPlayerController then
        pcall(function() pc = UEHelpers.GetPlayerController() end)
    end
    if not (pc and pc:IsValid()) then
        pc = nil
        pcall(function()
            local pcs = FindAllOf("PlayerController")
            if not pcs then return end
            for _, c in ipairs(pcs) do
                if c:IsValid() and c.Player and c.Player:IsValid() then pc = c break end
            end
        end)
    end
    S.pc = pc
    return pc
end

local function HealthColor(f)
    local r = COL.RAMP
    if f <= r[1][1] then return { R = r[1][2], G = r[1][3], B = r[1][4], A = 1 } end
    for i = 1, #r - 1 do
        local a, b = r[i], r[i + 1]
        if f <= b[1] then
            local t = (f - a[1]) / (b[1] - a[1])
            return {
                R = a[2] + (b[2] - a[2]) * t,
                G = a[3] + (b[3] - a[3]) * t,
                B = a[4] + (b[4] - a[4]) * t,
                A = 1,
            }
        end
    end
    local l = r[#r]
    return { R = l[2], G = l[3], B = l[4], A = 1 }
end

-- ------------------------------------------------------------------- camera

-- UE's FRotationMatrix, row 0 = forward, row 1 = right, row 2 = up. Roll is
-- included so camera shake does not throw the projection off.
local function Basis(pitchDeg, yawDeg, rollDeg)
    local p, y, r = math.rad(pitchDeg), math.rad(yawDeg), math.rad(rollDeg or 0)
    local cp, sp = math.cos(p), math.sin(p)
    local cy, sy = math.cos(y), math.sin(y)
    local cr, sr = math.cos(r), math.sin(r)
    return cp * cy, cp * sy, sp,
           sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp,
           -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp
end

-- Samples the camera and works out the transform to project with. Returns the
-- true (un-extrapolated) camera position, which is what distances are from.
local function UpdateCamera(pc)
    local loc, rot, fov
    pcall(function()
        if not (S.camMgr and S.camMgr:IsValid()) then S.camMgr = pc.PlayerCameraManager end
        if S.camMgr and S.camMgr:IsValid() then
            loc = S.camMgr:GetCameraLocation()
            rot = S.camMgr:GetCameraRotation()
            fov = S.camMgr:GetFOVAngle()
        end
    end)
    if loc == nil then
        pcall(function()
            local pawn = pc.Pawn
            if pawn and pawn:IsValid() then loc = pawn:K2_GetActorLocation() end
        end)
        pcall(function() rot = pc:GetControlRotation() end)
    end
    if loc == nil then return nil end

    local x, y, z
    local ok = pcall(function() x, y, z = loc.X, loc.Y, loc.Z end)
    if not (ok and type(x) == "number") then return nil end
    if type(fov) == "number" and fov > 20 and fov < 170 then CAM.fov = fov end

    -- a failed rotation read keeps the last one rather than stalling the HUD
    local pitch, yaw, roll = CAM.pitch, CAM.yaw, CAM.roll
    pcall(function()
        if rot then pitch, yaw, roll = rot.Pitch, rot.Yaw, rot.Roll end
    end)
    if type(pitch) ~= "number" or type(yaw) ~= "number" then pitch, yaw = 0, 0 end
    if type(roll) ~= "number" then roll = 0 end

    CAM.x, CAM.y, CAM.z, CAM.pitch, CAM.yaw, CAM.roll = x, y, z, pitch, yaw, roll
    if not CAM.have then
        CAM.px, CAM.py, CAM.pz, CAM.ppitch, CAM.pyaw = x, y, z, pitch, yaw
        CAM.have = true
    end

    -- one-frame extrapolation, only once the maths is trusted
    local lead = (S.manualOK == true) and CFG.CAMERA_LEAD or 0
    local dx, dy, dz = x - CAM.px, y - CAM.py, z - CAM.pz
    local dyaw = WrapDeg(yaw - CAM.pyaw)
    local dpitch = WrapDeg(pitch - CAM.ppitch)
    local m = CFG.LEAD_MAX_UU
    if dx * dx + dy * dy + dz * dz > m * m then dx, dy, dz = 0, 0, 0 end
    if math.abs(dyaw) > CFG.LEAD_MAX_DEG then dyaw = 0 end
    if math.abs(dpitch) > CFG.LEAD_MAX_DEG then dpitch = 0 end

    CAM.ex, CAM.ey, CAM.ez = x + dx * lead, y + dy * lead, z + dz * lead
    local epitch = Clamp(pitch + dpitch * lead, -89.5, 89.5)
    local eyaw = yaw + dyaw * lead

    CAM.fx, CAM.fy, CAM.fz, CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz =
        Basis(epitch, eyaw, roll)
    if S.manualOK == nil then
        CAM.cfx, CAM.cfy, CAM.cfz, CAM.crx, CAM.cry, CAM.crz, CAM.cux, CAM.cuy, CAM.cuz =
            Basis(pitch, yaw, roll)
    end

    -- UE builds its projection with a horizontal FOV, and the vertical axis
    -- uses the same focal length, so one number covers both.
    local t = math.tan(math.rad(CAM.fov) * 0.5)
    if t > 0.01 then CAM.focal = (S.vw * 0.5) / t end

    CAM.px, CAM.py, CAM.pz, CAM.ppitch, CAM.pyaw = x, y, z, pitch, yaw
    return x, y, z
end

-- Our own world -> widget-space projection. `raw` uses the un-extrapolated
-- camera basis (only used while cross-checking against the engine).
local function ProjectManual(wx, wy, wz, raw)
    local ox, oy, oz = CAM.ex, CAM.ey, CAM.ez
    local fx, fy, fz = CAM.fx, CAM.fy, CAM.fz
    local rx, ry, rz = CAM.rx, CAM.ry, CAM.rz
    local ux, uy, uz = CAM.ux, CAM.uy, CAM.uz
    if raw then
        ox, oy, oz = CAM.x, CAM.y, CAM.z
        fx, fy, fz = CAM.cfx, CAM.cfy, CAM.cfz
        rx, ry, rz = CAM.crx, CAM.cry, CAM.crz
        ux, uy, uz = CAM.cux, CAM.cuy, CAM.cuz
    end
    local dx, dy, dz = wx - ox, wy - oy, wz - oz
    local z = dx * fx + dy * fy + dz * fz
    if z <= 5 then return nil end
    local xr = dx * rx + dy * ry + dz * rz
    local yu = dx * ux + dy * uy + dz * uz
    return S.vw * 0.5 + CAM.focal * xr / z, S.vh * 0.5 - CAM.focal * yu / z
end

-- ------------------------------------------------- engine projection (fallback)

-- UE4SS out-parameter conventions vary (the value can land in the first table
-- passed, in the out table, or in an extra return). Resolve which one this
-- build uses on the first success and then stick to it.
local Proj = { fn = nil, slot = nil }

local function ReadXY(v)
    if v == nil then return nil end
    local x, y
    local ok = pcall(function() x = v.X y = v.Y end)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
    return nil
end

local function TryProject(fnId, pc, wx, wy, wz)
    local a = { X = wx, Y = wy, Z = wz }
    local b = {}
    local ok, r1, r2
    if fnId == 1 then
        if not (W.wll and W.wll:IsValid()) then return nil end
        ok, r1, r2 = pcall(function()
            return W.wll:ProjectWorldLocationToWidgetPosition(pc, a, b, false)
        end)
    else
        ok, r1, r2 = pcall(function()
            return pc:ProjectWorldLocationToScreen(a, b, false)
        end)
    end
    if not ok then return nil end
    if type(r1) == "boolean" and r1 == false then return nil end -- behind camera
    local cands = {
        { 1, b.ScreenPosition }, { 2, a.ScreenPosition },
        { 3, b.ScreenLocation }, { 4, a.ScreenLocation },
        { 5, r2 }, { 6, r1 }, { 7, b },
    }
    local pick = Proj.slot
    if pick then
        for _, c in ipairs(cands) do
            if c[1] == pick then return ReadXY(c[2]) end
        end
        return nil
    end
    for _, c in ipairs(cands) do
        local x, y = ReadXY(c[2])
        if x then
            Proj.fn, Proj.slot = fnId, c[1]
            Log(string.format("engine projection resolved (fn %d, slot %d)", fnId, c[1]))
            return x, y
        end
    end
    return nil
end

local function ProjectEngine(pc, wx, wy, wz)
    if Proj.fn then
        local x, y = TryProject(Proj.fn, pc, wx, wy, wz)
        if x and Proj.fn == 2 then
            local s = W.vpScale or 1
            if s > 0 then return x / s, y / s end
        end
        return x, y
    end
    local x, y = TryProject(1, pc, wx, wy, wz)
    if x then return x, y end
    x, y = TryProject(2, pc, wx, wy, wz)
    if x then
        local s = W.vpScale or 1
        if s > 0 then return x / s, y / s end
    end
    return x, y
end

local function RefreshViewport(pc)
    pcall(function()
        if not (W.wll and W.wll:IsValid()) then return end
        local sc = W.wll:GetViewportScale(pc)
        if type(sc) == "number" and sc > 0.01 then W.vpScale = sc end
        local sz = W.wll:GetViewportSize(pc)
        local x, y = ReadXY(sz)
        if x and x > 16 then
            local s = W.vpScale or 1
            S.vw, S.vh = x / s, y / s
        end
    end)
end

-- ------------------------------------------------------------ widget build

local function RemoveStrays()
    pcall(function()
        local widgets = FindAllOf("UserWidget")
        if not widgets then return end
        for _, w in ipairs(widgets) do
            pcall(function()
                if w:IsValid() then
                    local rt = w.WidgetTree.RootWidget
                    if rt and rt:IsValid()
                        and rt:GetFName():ToString():find("RVHB_Canvas", 1, true) then
                        w:RemoveFromParent()
                    end
                end
            end)
        end
    end)
end

local function DropWidget()
    pcall(function()
        if W.widget and W.widget:IsValid() then W.widget:RemoveFromParent() end
    end)
    W.widget, W.canvas, W.bars = nil, nil, {}
    S.built = false
    for _, e in ipairs(S.list) do e.bar = nil e.alpha = 0 end
end

local function BuildBar(wt, canvas, imgClass, canvasClass, txtClass, i)
    local root = StaticConstructObject(canvasClass, wt, FName("RVHB_B" .. i))
    if not (root and root:IsValid()) then return nil end
    local slot = canvas:AddChildToCanvas(root)
    if not (slot and slot:IsValid()) then return nil end

    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        -- anchored on the bar's bottom edge: that is the point over the head
        slot:SetAlignment({ X = 0.5, Y = 1.0 })
        slot:SetAutoSize(false)
        slot:SetSize({ X = CFG.BAR_W, Y = CFG.BAR_H })
        -- scale (distance + hit punch) grows from the same edge
        root:SetRenderTransformPivot({ X = 0.5, Y = 1.0 })
    end)

    local B  = CFG.BORDER
    local iw = CFG.BAR_W - 2 * B
    local ih = CFG.BAR_H - 2 * B

    local bar = { root = root, slot = slot, iw = iw, ih = ih }

    local function addImage(name, x, y, w, h, color)
        local img = StaticConstructObject(imgClass, wt, FName(name .. i))
        if not (img and img:IsValid()) then return nil, nil end
        local sl = root:AddChildToCanvas(img)
        if not (sl and sl:IsValid()) then return nil, nil end
        pcall(function()
            sl:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
            sl:SetAlignment({ X = 0, Y = 0 })
            sl:SetAutoSize(false)
            sl:SetPosition({ X = x, Y = y })
            sl:SetSize({ X = w, Y = h })
            if color then img:SetColorAndOpacity(color) end
        end)
        return img, sl
    end

    -- back to front: shadow, black outline, rim, track, ghost, fill, gloss
    addImage("RVHB_D", CFG.SHADOW_X, CFG.SHADOW_Y, CFG.BAR_W, CFG.BAR_H, COL.SHADOW)
    addImage("RVHB_F", 0, 0, CFG.BAR_W, CFG.BAR_H, COL.OUTER)
    bar.rim                   = addImage("RVHB_R", 1, 1, CFG.BAR_W - 2, CFG.BAR_H - 2, COL.RIM)
    addImage("RVHB_T", B, B, iw, ih, COL.TRACK)
    bar.ghost, bar.ghostSlot  = addImage("RVHB_G", B, B, iw, ih, COL.GHOST)
    bar.fill,  bar.fillSlot   = addImage("RVHB_H", B, B, iw, ih, HealthColor(1))
    bar.gloss, bar.glossSlot  = addImage("RVHB_L", B, B, iw, ih * 0.42, COL.GLOSS)

    if CFG.SEGMENTS and CFG.SEGMENTS > 1 then
        for k = 1, CFG.SEGMENTS - 1 do
            addImage("RVHB_S" .. k .. "_", B + iw * (k / CFG.SEGMENTS) - 0.5, B, 1, ih, COL.SEP)
        end
    end

    if S.textOK and txtClass and txtClass:IsValid() then
        local ok = pcall(function()
            local txt = StaticConstructObject(txtClass, wt, FName("RVHB_N" .. i))
            if not (txt and txt:IsValid()) then error("no textblock") end
            local tsl = root:AddChildToCanvas(txt)
            if not (tsl and tsl:IsValid()) then error("no text slot") end
            tsl:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
            tsl:SetAlignment({ X = 0.5, Y = 1.0 })
            tsl:SetAutoSize(true)
            tsl:SetPosition({ X = CFG.BAR_W * 0.5, Y = -1 })
            pcall(function()
                txt.ShadowOffset = { X = 1, Y = 1 }
                txt.ShadowColorAndOpacity = { R = 0, G = 0, B = 0, A = 0.85 }
            end)
            -- The stock TextBlock font is 24pt; shrink with a render transform
            -- (pivoted on the bottom edge) instead of rebuilding FSlateFontInfo,
            -- whose FName typeface field is one of the known crash shapes.
            txt:SetRenderTransformPivot({ X = 0.5, Y = 1.0 })
            txt:SetRenderScale({ X = CFG.TEXT_SCALE, Y = CFG.TEXT_SCALE })
            txt:SetVisibility(1)
            bar.text = txt
        end)
        if not ok then
            S.textOK = false
            Log("HP numbers unavailable on this build - bars only")
        end
    end

    pcall(function() root:SetVisibility(1) end)
    bar.vis, bar.alpha, bar.scale = false, -1, -1
    bar.frac, bar.gfrac, bar.label, bar.ench = -1, -1, nil, false
    return bar
end

local function Build()
    local pc = GetPC()
    if not (pc and pc:IsValid()) then return false end

    RemoveStrays()

    local wbl         = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local uwClass     = StaticFindObject("/Script/UMG.UserWidget")
    local canvasClass = StaticFindObject("/Script/UMG.CanvasPanel")
    local imgClass    = StaticFindObject("/Script/UMG.Image")
    local txtClass    = StaticFindObject("/Script/UMG.TextBlock")
    W.wll             = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (wbl and wbl:IsValid() and uwClass and uwClass:IsValid()
            and canvasClass and canvasClass:IsValid() and imgClass and imgClass:IsValid()) then
        Log("build failed: UMG classes not found")
        return false
    end

    local widget = wbl:Create(pc, uwClass, pc)
    if not (widget and widget:IsValid()) then
        Log("build failed: could not create UserWidget")
        return false
    end
    local wt = widget.WidgetTree
    if not (wt and wt:IsValid()) then
        Log("build failed: widget has no WidgetTree")
        return false
    end

    local canvas = StaticConstructObject(canvasClass, wt, FName("RVHB_Canvas"))
    if not (canvas and canvas:IsValid()) then
        Log("build failed: could not construct CanvasPanel")
        return false
    end
    wt.RootWidget = canvas

    local bars = {}
    for i = 1, CFG.MAX_BARS do
        local bar = BuildBar(wt, canvas, imgClass, canvasClass, txtClass, i)
        if bar then bars[#bars + 1] = bar end
    end
    if #bars == 0 then
        Log("build failed: no bars could be constructed")
        return false
    end

    widget:AddToViewport(20)
    pcall(function() widget:SetVisibility(3) end)

    W.widget, W.canvas, W.bars = widget, canvas, bars
    S.built = true
    RefreshViewport(pc)
    -- %d on a fractional float is an error in Lua 5.4 - floor everything
    Log(string.format("HUD built (%d bars, viewport %dx%d)",
        #bars, math.floor(S.vw), math.floor(S.vh)))
    return true
end

-- ------------------------------------------------------------- bar drawing

local function HideBar(bar)
    if bar.vis then
        bar.vis = false
        pcall(function() bar.root:SetVisibility(1) end)
    end
end

local function DrawBar(bar, e)
    if not bar.vis then
        bar.vis = true
        pcall(function() bar.root:SetVisibility(3) end)
    end

    pcall(function() bar.slot:SetPosition({ X = e.sx, Y = e.sy }) end)

    local scale = e.scale * (1 + CFG.PUNCH_AMOUNT * e.punch)
    if math.abs(scale - bar.scale) > 0.005 then
        bar.scale = scale
        pcall(function() bar.root:SetRenderScale({ X = scale, Y = scale }) end)
    end

    if math.abs(e.alpha - bar.alpha) > 0.01 then
        bar.alpha = e.alpha
        pcall(function() bar.root:SetRenderOpacity(e.alpha) end)
    end

    if math.abs(e.frac - bar.frac) > 0.0015 then
        bar.frac = e.frac
        local w = bar.iw * e.frac
        if w < 0 then w = 0 end
        pcall(function()
            bar.fillSlot:SetSize({ X = w, Y = bar.ih })
            bar.glossSlot:SetSize({ X = w, Y = bar.ih * 0.42 })
            bar.fill:SetColorAndOpacity(HealthColor(e.frac))
        end)
    end

    if math.abs(e.gfrac - bar.gfrac) > 0.0015 then
        bar.gfrac = e.gfrac
        local w = bar.iw * e.gfrac
        if w < 0 then w = 0 end
        pcall(function() bar.ghostSlot:SetSize({ X = w, Y = bar.ih }) end)
    end

    if bar.ench ~= e.ench and bar.rim then
        bar.ench = e.ench
        pcall(function() bar.rim:SetColorAndOpacity(e.ench and COL.RIM_ENCH or COL.RIM) end)
    end

    if bar.text and S.textOK then
        if e.noNumbers then
            -- a 3-step state bar has no real numbers behind it; inventing
            -- some would be worse than showing none
            if bar.label ~= false then
                bar.label = false
                pcall(function() bar.text:SetVisibility(1) end)
            end
        else
            local label = string.format("%d / %d", math.floor(e.hp + 0.5), math.floor(e.max + 0.5))
            if label ~= bar.label then
                bar.label = label
                local ok = pcall(function()
                    bar.text:SetText(FText(label))
                    bar.text:SetVisibility(3)
                end)
                if not ok then
                    S.textOK = false
                    Log("HP numbers disabled (SetText failed)")
                end
            end
        end
    end
end

-- -------------------------------------------------------------- enemy intake

local function Enqueue(obj, kind)
    if obj == nil then return false end
    local valid = false
    pcall(function() valid = obj:IsValid() end)
    if not valid then return false end
    local key = KeyOf(obj)
    if not key or S.memo[key] or S.byKey[key] then return false end
    S.queue[#S.queue + 1] = {
        obj = obj, key = key, kind = kind or "char",
        readyAt = os.clock() + CFG.SETTLE_SECS, tries = 0,
    }
    return true
end

-- Reads the drone's own Default(0)/Wounded(1)/Dead(2) state.
local function DroneState(d)
    local s
    pcall(function()
        s = d.DroneHealth
        if type(s) ~= "number" then s = tonumber(tostring(s)) end
    end)
    if type(s) ~= "number" then return nil end
    return s
end

-- Flying drones. Not characters: no stats component, no hit points, and no
-- CharacterType to filter on - every AHeldenDrone is hostile. Health comes
-- from the character flying it, which is what its own state tracks anyway.
local function ClassifyDrone(entry)
    local d = entry.obj
    if not (d and d:IsValid()) then return "skip" end
    if CFG.DRONES == "off" then return "skip" end

    local state = DroneState(d)
    if state == 2 then return "skip" end   -- already dead

    local stats, auth, hp, peak, shown, noNumbers = nil, false, 1, 1, 1, false

    if CFG.DRONES == "host" then
        local host
        pcall(function() host = d:GetDroneHost() end)
        if not (host and host:IsValid()) then
            -- the host can stream in after its drone; keep trying, and fall
            -- back to the state bar rather than never drawing anything
            if entry.tries < CFG.MAX_TRIES - 1 then return "retry" end
        else
            pcall(function() stats = host.CharacterStats end)
            if stats and not stats:IsValid() then stats = nil end
            if stats then
                pcall(function() auth = host:HasAuthority() end)
                if auth ~= true then auth = false end
                local mx = 0
                pcall(function() mx = stats.TotalStats.MaxHealth end)
                if type(mx) ~= "number" then mx = 0 end
                hp = 0
                pcall(function() hp = stats.CurrentHealth end)
                if type(hp) ~= "number" then hp = 0 end
                if mx <= 0 and hp <= 0 then return "retry" end
                peak = hp
                if auth and mx > peak then peak = mx end
                shown = (auth and mx > 0) and mx or peak
                if shown < hp then shown = hp end
                if shown <= 0 then shown = 1 end
            end
        end
    end

    if stats == nil then
        -- state bar: a 3-step reading, so the numbers would be invented
        noNumbers = true
        hp = (state == 1) and CFG.DRONE_WOUNDED or 1
        peak, shown = 1, 1
    end

    local e = {
        obj = d, key = entry.key, kind = "drone", stats = stats,
        head = CFG.DRONE_OFFSET,
        max = shown, hp = hp, peak = peak, auth = auth,
        frac = Clamp(hp / shown, 0, 1),
        gfrac = Clamp(hp / shown, 0, 1),
        ghostAt = 0, punch = 0, alpha = 0, scale = 1,
        ench = false, near = false, dist = 0, sx = 0, sy = 0,
        bar = nil, dead = false, noNumbers = noNumbers,
        los = nil, losAt = 0, losMiss = 0, losHit = 0, losRunAt = 0,
    }
    S.list[#S.list + 1] = e
    S.byKey[entry.key] = e
    return "done"
end

-- "done" | "skip" | "retry"
local function Classify(entry)
    local c = entry.obj
    if not (c and c:IsValid()) then return "skip" end

    local raw
    pcall(function()
        local preset = c.AppliedCharacterPreset
        if not (preset and preset:IsValid()) then preset = c.CharacterPreset end
        if preset and preset:IsValid() then raw = preset.CharacterType end
    end)
    if raw == nil then pcall(function() raw = c:GetCharacterType() end) end
    local ctype = raw
    if type(ctype) ~= "number" then ctype = tonumber(tostring(raw)) end
    if ctype == nil then return "retry" end
    if ctype ~= 4 then return "skip" end

    local stats
    pcall(function() stats = c.CharacterStats end)
    if not (stats and stats:IsValid()) then return "retry" end
    local inited = false
    pcall(function() inited = stats.bInitalized end)
    if not inited then return "retry" end

    local maxhp = 0
    pcall(function() maxhp = stats.TotalStats.MaxHealth end)
    if type(maxhp) ~= "number" then maxhp = 0 end

    local hp0 = 0
    pcall(function() hp0 = stats.CurrentHealth end)
    if type(hp0) ~= "number" then hp0 = 0 end
    if maxhp <= 0 and hp0 <= 0 then return "retry" end

    -- TotalStats is computed locally, not replicated: the game replicates a
    -- recipe (ReplicatedStats = stat names + level) and each machine works
    -- the totals out for itself. On a machine that does not own the actor
    -- that recompute does not produce real numbers - every enemy reported a
    -- flat 120 max on a joining client (seen in play 2026-08-16). So only
    -- trust it where we have authority. Everywhere else the highest health
    -- we have actually observed is the honest maximum: enemies are at full
    -- when they spawn, and unlike any local recompute it also follows
    -- host-side stat mods (RotScaling), whose raised maximum never
    -- replicates at all even though the health values it produces do.
    local auth = false
    pcall(function() auth = c:HasAuthority() end)
    if auth ~= true then auth = false end

    -- Bar sits above the capsule; scaled half-height already accounts for the
    -- character's scale. Preset value and a constant back it up.
    local half = 0
    pcall(function()
        local cap = c.CapsuleComponent
        if cap and cap:IsValid() then half = cap:GetScaledCapsuleHalfHeight() end
    end)
    if type(half) ~= "number" or half <= 1 then
        half = 0
        pcall(function()
            local preset = c.AppliedCharacterPreset
            if preset and preset:IsValid() then half = preset.CapsuleHalfHeight end
        end)
    end
    if type(half) ~= "number" or half <= 1 then half = 88 end

    local ench = false
    pcall(function()
        local n = c.Enchantment:ToString()
        ench = (n ~= nil and n ~= "" and n ~= "None")
    end)

    local hp = hp0
    local peak = hp
    if auth and maxhp > peak then peak = maxhp end
    local shown = peak
    if auth and maxhp > 0 then shown = maxhp end
    if shown < hp then shown = hp end
    if shown <= 0 then shown = 1 end

    local e = {
        obj = c, key = entry.key, stats = stats,
        head = half + CFG.HEAD_OFFSET,
        max = shown, hp = hp, peak = peak, auth = auth,
        frac = Clamp(hp / shown, 0, 1),
        gfrac = Clamp(hp / shown, 0, 1),
        ghostAt = 0, punch = 0, alpha = 0, scale = 1,
        ench = ench, near = false, dist = 0, sx = 0, sy = 0,
        bar = nil, dead = false,
        los = nil, losAt = 0, losMiss = 0, losHit = 0, losRunAt = 0,
    }
    if S.auth == nil then
        S.auth = auth
        Log(auth and "authority: host - enemy maximums come from the game's own stats"
                  or "authority: client - enemy maximums come from observed peak health "
                     .. "(the game's totals are not replicated)")
    end
    S.list[#S.list + 1] = e
    S.byKey[entry.key] = e
    return "done"
end

local function DrainQueue(now)
    local budget = CFG.DRAIN_PER_FRAME
    while budget > 0 and #S.queue > 0 and S.queue[1].readyAt <= now do
        budget = budget - 1
        local entry = table.remove(S.queue, 1)
        local fn = (entry.kind == "drone") and ClassifyDrone or Classify
        local ok, verdict = pcall(fn, entry)
        if not ok then
            S.errCount = S.errCount + 1
            S.memo[entry.key] = true
            Log("classify error (" .. S.errCount .. "/" .. CFG.ERROR_CAP .. "): " .. tostring(verdict))
        elseif verdict == "retry" then
            entry.tries = entry.tries + 1
            if entry.tries < CFG.MAX_TRIES then
                entry.readyAt = now + CFG.SETTLE_SECS
                S.queue[#S.queue + 1] = entry
            else
                -- say why, so "enemy X never gets a bar" is answerable
                -- from the log instead of by guesswork
                S.memo[entry.key] = true
                if S.gaveUp < 12 then
                    S.gaveUp = S.gaveUp + 1
                    local cls = "?"
                    pcall(function() cls = entry.obj:GetClass():GetFName():ToString() end)
                    Log(string.format("gave up on %s (%s, %s) after %d tries",
                        entry.key or "?", cls, entry.kind, entry.tries))
                end
            end
        else
            S.memo[entry.key] = true
        end
    end
end

local function Sweep()
    local n, dn = 0, 0
    pcall(function()
        local chars = FindAllOf("HeldenCharacter")
        if not chars then return end
        for _, c in ipairs(chars) do
            if Enqueue(c, "char") then n = n + 1 end
        end
    end)
    -- drones are AActors, not characters, so they need their own sweep
    if CFG.DRONES ~= "off" then
        pcall(function()
            local drones = FindAllOf("HeldenDrone")
            if not drones then return end
            for _, d in ipairs(drones) do
                if Enqueue(d, "drone") then dn = dn + 1 end
            end
        end)
    end
    if n + dn > 0 then
        Log(string.format("sweep queued %d character(s), %d drone(s)", n, dn))
    end
end

pcall(function()
    NotifyOnNewObject("/Script/Helden.HeldenCharacter", function(c) Enqueue(c, "char") end)
end)
pcall(function()
    NotifyOnNewObject("/Script/Helden.HeldenDrone", function(d) Enqueue(d, "drone") end)
end)

-- --------------------------------------------------------------- range pass

-- Walks the tracked list a chunk at a time so the per-frame loop only ever
-- touches enemies that are actually near the camera.
local function RangePass(cx, cy, cz)
    local n = #S.list
    if n == 0 then S.active = {} return end
    if S.scanIdx > n then S.scanIdx = 1 end

    local count = math.min(CFG.RANGE_CHUNK, n)
    for _ = 1, count do
        local i = S.scanIdx
        local e = S.list[i]
        S.scanIdx = i + 1
        if S.scanIdx > n then S.scanIdx = 1 end

        local alive = false
        pcall(function() alive = e.obj:IsValid() end)
        if alive and CFG.HIDE_DEAD then
            if e.kind == "drone" then
                if DroneState(e.obj) == 2 then alive = false end
            else
                -- enum reads have come back as non-numbers before; normalise,
                -- and fall through to the hp <= 0 check if this yields nothing
                pcall(function()
                    local cs = e.obj.CharacterState
                    if type(cs) ~= "number" then cs = tonumber(tostring(cs)) end
                    if cs == 1 then alive = false end
                end)
            end
        end

        if not alive then
            e.dead = true
            e.near = (e.alpha > 0.01)   -- keep it around while its bar fades
        else
            local d = CFG.MAX_DIST + 1
            local ok = pcall(function()
                local l = e.obj:K2_GetActorLocation()
                local dx, dy, dz = l.X - cx, l.Y - cy, l.Z - cz
                d = math.sqrt(dx * dx + dy * dy + dz * dz)
                e.wx, e.wy, e.wz = l.X, l.Y, l.Z
            end)
            if not ok then d = CFG.MAX_DIST + 1 end
            e.dist = d
            e.near = (d <= CFG.MAX_DIST)
        end
    end

    -- retire finished entries (pure Lua, no engine calls - cheap to do every
    -- pass). Only reset the round-robin cursor if the list actually shrank.
    local keep, removed = {}, 0
    for _, e in ipairs(S.list) do
        if e.dead and not e.near and e.bar == nil then
            S.byKey[e.key] = nil
            removed = removed + 1
        else
            keep[#keep + 1] = e
        end
    end
    if removed > 0 then
        S.list = keep
        S.scanIdx = 1
    end

    local act = {}
    for _, e in ipairs(S.list) do
        if e.near then act[#act + 1] = e end
    end
    table.sort(act, function(a, b) return a.dist < b.dist end)
    local cap = CFG.MAX_BARS * 2
    while #act > cap do table.remove(act) end
    S.active = act
end

-- ------------------------------------------------------------- frame update

-- Cross-checks our projection against the engine's until we are confident.
local function Calibrate(pc, e)
    if S.manualOK ~= nil or S.calDone then return end
    if type(e.wx) ~= "number" then return end
    S.calDone = true  -- one sample per frame
    local mx, my = ProjectManual(e.wx, e.wy, e.wz + e.head, true)
    if mx == nil then return end
    local ex, ey = ProjectEngine(pc, e.wx, e.wy, e.wz + e.head)
    if ex == nil then return end
    local err = math.max(math.abs(mx - ex), math.abs(my - ey))
    S.calN = S.calN + 1
    if err > S.calErr then S.calErr = err end
    -- a single bad sample (a shake frame, a camera cut) should not veto it
    if err <= CFG.CAL_TOLERANCE then S.calGood = S.calGood + 1 end
    if S.calN >= CFG.CAL_SAMPLES then
        S.manualOK = (S.calGood >= CFG.CAL_SAMPLES * 0.8)
        if S.manualOK then
            Log(string.format("projection verified (%d/%d samples, worst %.1f px) - "
                .. "camera lead %.2f active", S.calGood, S.calN, S.calErr, CFG.CAMERA_LEAD))
        else
            Log(string.format("projection mismatch (%d/%d samples, worst %.1f px) - staying "
                .. "on the engine projection; bars will lag the camera by a frame",
                S.calGood, S.calN, S.calErr))
        end
    end
end

local function UpdateEnemy(e, pc, dt, now, cx, cy, cz)
    -- Fresh world position every frame. The range pass only runs at ~7 Hz;
    -- driving the bar off that would make it chase a moving enemy in steps.
    if not e.dead then
        local alive = false
        pcall(function() alive = e.obj:IsValid() end)
        if not alive then
            e.dead = true
        else
            local ok = pcall(function()
                local l = e.obj:K2_GetActorLocation()
                e.wx, e.wy, e.wz = l.X, l.Y, l.Z
            end)
            if not ok then e.dead = true end
        end
    end

    local dx, dy, dz = (e.wx or 0) - cx, (e.wy or 0) - cy, (e.wz or 0) - cz
    e.dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    -- depth along the view axis: the behind-the-camera guard for both
    -- projection paths (the engine one's bool return is not dependable)
    local depth = dx * CAM.fx + dy * CAM.fy + dz * CAM.fz

    -- health: read straight off the replicated component every frame so the
    -- bar is never a frame behind a hit.
    if not e.dead then
        local hp = e.hp
        -- A drone's stats belong to its host, not to the actor we validated
        -- above, so the host can die out from under it. Drop to the state bar
        -- rather than reading through a stale component.
        if e.stats and e.kind == "drone" then
            local sv = false
            pcall(function() sv = e.stats:IsValid() end)
            if not sv then e.stats = nil e.noNumbers = true e.peak = 1 e.max = 1 end
        end
        if e.stats then
            pcall(function() hp = e.stats.CurrentHealth end)
        else
            -- state-bar drone: no numbers to read, just the 3-step state
            local st = DroneState(e.obj)
            if st == 2 then e.dead = true
            elseif st == 1 then hp = CFG.DRONE_WOUNDED
            elseif st == 0 then hp = 1 end
        end
        if type(hp) == "number" then
            if hp < e.hp - 0.01 then
                e.punch = 1
                e.ghostAt = now + CFG.GHOST_HOLD
            elseif hp > e.hp + 0.01 then
                e.gfrac = -1 -- healed: let the ghost snap up with the fill
            end
            e.hp = hp
            if hp > e.peak then e.peak = hp end
        end

        -- Maximum: the game's own total only where we own the actor, the
        -- highest health we have seen otherwise. See the note in Classify.
        local mx
        if e.auth then
            pcall(function() mx = e.stats.TotalStats.MaxHealth end)
            if type(mx) ~= "number" or mx <= 0 then mx = nil end
        end
        if mx == nil or mx < e.peak then mx = e.peak end
        if mx < e.hp then mx = e.hp end   -- never render an over-full bar
        if mx > 0 then e.max = mx end

        if e.hp <= 0 then e.dead = true end
    end

    e.frac = Clamp(e.hp / (e.max > 0 and e.max or 1), 0, 1)
    if e.gfrac < e.frac then e.gfrac = e.frac end
    if e.gfrac > e.frac and now >= e.ghostAt then
        local k = 1 - math.exp(-dt * CFG.GHOST_RATE)
        e.gfrac = e.gfrac + (e.frac - e.gfrac) * k
        if e.gfrac - e.frac < 0.002 then e.gfrac = e.frac end
    end
    if e.punch > 0 then
        e.punch = e.punch - dt / CFG.PUNCH_TIME
        if e.punch < 0 then e.punch = 0 end
    end

    -- should the bar be up at all?
    local want = not e.dead and e.dist <= CFG.MAX_DIST and depth > 5
    local losBlocked = false
    if want and CFG.HIDE_FULL_HP and e.frac >= 0.999 then want = false end

    -- cheap first: is it being rendered at all (frustum / distance culling)
    if want and CFG.RENDER_CHECK then
        local seen = true
        pcall(function() seen = e.obj:WasRecentlyRendered(0.25) end)
        if seen == false then want = false end
    end

    -- then the real wall test. WasRecentlyRendered alone is not enough: an
    -- enemy behind a wall still counts as rendered if it casts a shadow into
    -- view, which is why the first cut showed bars through walls.
    if want and CFG.WALL_CHECK then
        -- An enemy we have not traced recently has to prove line of sight
        -- again. Without this, one that was visible before it went out of
        -- range (or off screen) comes back still flagged visible and flashes
        -- a bar through the wall until the misses add up.
        if now - e.losRunAt > CFG.LOS_STALE then
            e.los = nil
            e.losMiss, e.losHit = 0, 0
        end
        if now >= e.losAt then
            e.losAt = now + CFG.LOS_INTERVAL * (0.75 + 0.5 * math.random())
            e.losRunAt = now
            local seen, ok = true, false
            ok = pcall(function()
                seen = pc:LineOfSightTo(e.obj, { X = cx, Y = cy, Z = cz }, false)
            end)
            if not ok then
                CFG.WALL_CHECK = false
                Log("LineOfSightTo unavailable - wall check disabled")
            elseif seen == false then
                e.losHit = 0
                e.losMiss = e.losMiss + 1
                if e.losMiss >= CFG.LOS_MISSES then e.los = false end
            else
                e.losMiss = 0
                e.losHit = e.losHit + 1
                if e.losHit >= CFG.LOS_HITS then e.los = true end
            end
        end
        -- Unknown counts as hidden. Only a confirmed run of successful traces
        -- puts a bar up, and a single failure takes it straight back down.
        if e.los ~= true then
            want = false
            losBlocked = true
        end
    end

    local sx, sy
    if want then
        if S.manualOK == true then
            sx, sy = ProjectManual(e.wx or 0, e.wy or 0, (e.wz or 0) + e.head)
        else
            sx, sy = ProjectEngine(pc, e.wx or 0, e.wy or 0, (e.wz or 0) + e.head)
        end
        if sx == nil then
            want = false
        else
            local m = 120
            if sx < -m or sy < -m or sx > S.vw + m or sy > S.vh + m then want = false end
        end
    end

    if want then
        if CFG.POS_SMOOTH > 0 and e.alpha > 0.01 and e.sx then
            local k = 1 - math.exp(-dt * CFG.POS_SMOOTH)
            e.sx = e.sx + (sx - e.sx) * k
            e.sy = e.sy + (sy - e.sy) * k
        else
            e.sx, e.sy = sx, sy
        end
        e.scale = Clamp(CFG.REF_DIST / (e.dist > 1 and e.dist or 1), CFG.MIN_SCALE, CFG.MAX_SCALE)
        local a = 1
        if e.dist > CFG.FADE_DIST then
            a = 1 - (e.dist - CFG.FADE_DIST) / (CFG.MAX_DIST - CFG.FADE_DIST)
            a = Clamp(a, 0, 1)
        end
        local rate = dt / CFG.FADE_IN
        if e.alpha + rate < a then e.alpha = e.alpha + rate else e.alpha = a end
        if not e.dead then Calibrate(pc, e) end
    else
        local fade = losBlocked and CFG.FADE_OUT_LOS or CFG.FADE_OUT
        e.alpha = e.alpha - dt / fade
        if e.alpha < 0 then e.alpha = 0 end
    end
    e.wantBar = (e.alpha > 0.01)
end

local function AssignBars()
    local bars = W.bars
    local wanted = {}
    for _, e in ipairs(S.active) do
        if e.wantBar then wanted[#wanted + 1] = e end
    end
    table.sort(wanted, function(a, b) return a.dist < b.dist end)
    while #wanted > #bars do table.remove(wanted) end

    -- release bars held by anything not in the winning set
    local held = {}
    for _, e in ipairs(wanted) do if e.bar then held[e.bar] = true end end
    for _, e in ipairs(S.list) do
        if e.bar and not held[e.bar] then
            HideBar(bars[e.bar])
            e.bar = nil
        end
    end

    local used = {}
    for _, e in ipairs(wanted) do if e.bar then used[e.bar] = true end end
    local next_ = 1
    for _, e in ipairs(wanted) do
        if not e.bar then
            while next_ <= #bars and used[next_] do next_ = next_ + 1 end
            if next_ > #bars then break end
            e.bar = next_
            used[next_] = true
            local b = bars[next_]
            b.alpha, b.scale, b.frac, b.gfrac, b.label = -1, -1, -1, -1, nil
        end
    end

    S.shown = 0
    for _, e in ipairs(wanted) do
        if e.bar then
            S.shown = S.shown + 1
            DrawBar(bars[e.bar], e)
        end
    end
end

-- ------------------------------------------------------------ frame driver

local function OnFrame()
    if S.errCount >= CFG.ERROR_CAP then return end

    local now = os.clock()
    if now - S.lastTick < 0.0015 then return end

    local pc = GetPC()
    if not (pc and pc:IsValid()) then return end

    -- Exactly one update per rendered frame. The anim hook fires once per
    -- animated character and os.clock only resolves to a millisecond, so on
    -- a busy frame several calls can slip past a pure time gate - and the
    -- last one through would measure a zero camera delta and cancel the lead
    -- correction, which is worse than not correcting at all.
    local dt
    local wt = WorldTime(pc)
    if wt then
        if S.lastWT then
            local d = wt - S.lastWT
            if d <= 0 then
                if now - S.lastTick < 0.5 then return end  -- same frame
                d = now - S.lastTick                       -- clock stalled
            end
            dt = d
        else
            dt = now - S.lastTick
        end
        S.lastWT = wt
    else
        dt = now - S.lastTick
    end
    S.lastTick = now
    if dt <= 0 then dt = 0.016 end
    if dt > 0.25 then dt = 0.25 end
    S.calDone = false

    if not S.built or not (W.widget and W.widget:IsValid()) then
        if S.built then DropWidget() end
        if now < (S.nextBuild or 0) then return end
        S.nextBuild = now + 1.0
        if not Build() then return end
    end

    if now >= S.nextViewport then
        S.nextViewport = now + CFG.VIEWPORT_SECS
        RefreshViewport(pc)
    end

    if now >= S.nextSweep then
        S.nextSweep = now + CFG.SWEEP_SECS
        pcall(Sweep)
    end

    DrainQueue(now)

    local cx, cy, cz = UpdateCamera(pc)
    if cx == nil then return end

    if now >= S.nextRange then
        S.nextRange = now + CFG.RANGE_SECS
        local ok, err = pcall(RangePass, cx, cy, cz)
        if not ok then
            S.errCount = S.errCount + 1
            Log("range error (" .. S.errCount .. "/" .. CFG.ERROR_CAP .. "): " .. tostring(err))
        end
    end

    for _, e in ipairs(S.active) do
        local ok, err = pcall(UpdateEnemy, e, pc, dt, now, cx, cy, cz)
        if not ok then
            e.dead = true
            e.wantBar = false
            S.errCount = S.errCount + 1
            Log("update error (" .. S.errCount .. "/" .. CFG.ERROR_CAP .. "): " .. tostring(err))
        end
    end

    local ok, err = pcall(AssignBars)
    if not ok then
        S.errCount = S.errCount + 1
        Log("draw error (" .. S.errCount .. "/" .. CFG.ERROR_CAP .. "): " .. tostring(err))
    end

    if now >= S.nextStatus then
        S.nextStatus = now + CFG.STATUS_SECS
        local nd = 0
        for _, e in ipairs(S.list) do if e.kind == "drone" then nd = nd + 1 end end
        Log(string.format("status: %d tracked (%d drones), %d in range, %d bars up, %d queued, "
            .. "projection %s, walls %s, maximums %s",
            #S.list, nd, #S.active, S.shown, #S.queue,
            (S.manualOK == true) and "own+lead" or (S.manualOK == false and "engine" or "calibrating"),
            CFG.WALL_CHECK and "on" or "off",
            (S.auth == true) and "game stats" or (S.auth == false and "observed peak" or "unknown")))
    end
end

local function EnsureHook()
    if S.hooked then return end
    local ok, err = pcall(function()
        RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
            function(self, DeltaTimeX) OnFrame() end)
    end)
    if ok then
        S.hooked = true
        Log("anim-update hook registered")
    else
        Log("hook registration failed (will retry on respawn): " .. tostring(err))
    end
end

EnsureHook()

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
        EnsureHook()
        -- Fires during normal play too (elevator / repossession), so never
        -- tear the HUD down here - only re-resolve what can go stale. The
        -- widget is rebuilt by the frame driver if it stops being valid.
        S.pc = nil
        S.camMgr = nil
        CAM.have = false
        S.lastWT = nil   -- a new world restarts real time
        S.nextSweep = 0
        S.nextViewport = 0
        S.memo = {}
        S.auth = nil   -- may have gone from hosting to joining
    end)
end)

-- Hold the first catch-up sweep off for a few seconds: it is one FindAllOf
-- plus a GetFullName per character, and the object array is at its fattest
-- right after a level load (the RackAndRoll boot-freeze lesson).
S.nextSweep = os.clock() + 3

Log(string.format("loaded 1.0.3 (%d bars, range %dm, lead %.2f, walls %s)",
    CFG.MAX_BARS, math.floor(CFG.MAX_DIST / 100), CFG.CAMERA_LEAD,
    CFG.WALL_CHECK and "on" or "off"))
