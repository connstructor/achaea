--[[
  magi_test.lua — self-contained smoke test for magi.lua

  Stubs the Mudlet + Legacy/AK host globals, captures the queued command string
  (SETALIAS MAGIATK/MAGIUTIL <cmds>) and the status box (cecho), dofile()s the module,
  and asserts the emitted output for every kill route, the five modes, priority
  pre-emption, the guards, the dual-resource arm/JIT firing, the stormhammer selector,
  and the remaining self-tracked handlers.

  The Magi cast-states (burns/aflame, conflagrate, scalded, calcifiedtorso, calcifiedhead,
  frozen, hypothermia) are read LIVE from AK affstrack, so scenarios plant them with the
  aff()/set_burns() mutators rather than via track handlers.

  Run from this folder:  lua magi_test.lua
]]--

------------------------------------------
-- Capture + Mudlet/framework stubs
------------------------------------------
local last_setalias = nil
local last_notify = nil
local sent = {}
local cechoed = {}

function send(s)
  sent[#sent + 1] = s
  local cmds = s:match("^SETALIAS %u+ (.+)$")
  if cmds then last_setalias = cmds end
end

local timers = {}
local timer_seq = 0
function tempTimer(wait, fn)
  timer_seq = timer_seq + 1
  timers[timer_seq] = { wait = wait, fn = fn, alive = true }
  return timer_seq
end
function killTimer(id) if timers[id] then timers[id].alive = false end return true end
function getEpoch() return 1000 end
function getNetworkLatency() return 0.1 end
function cecho(s) cechoed[#cechoed + 1] = s end
boxEcho = { send = function(m) last_notify = m end }

target = "Bob"
affstrack = { score = {} }
ak = { defs = {}, currenthealth = 100, maxhealth = 100 }
lb = { Bob = { hits = {} } }
gmcp = { Char = { Vitals = { bal = "1", eq = "1" }, Status = { class = "Magi", name = "Me" } },
         Room = { Players = {}, Info = { num = 1234 } } }
Legacy = { Curing = { Affs = {} }, Settings = { Curing = { status = true } } }

dofile("magi.lua")

local DEFAULT_CITIZENSHIP = magi.storm.citizenship

------------------------------------------
-- Test harness
------------------------------------------
local passes, failures = 0, 0

local function expect(name, cond, detail)
  if cond then
    passes = passes + 1
    print("  PASS  " .. name)
  else
    failures = failures + 1
    print("  FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end

local function has_cmd(substr)
  return last_setalias ~= nil and last_setalias:find(substr, 1, true) ~= nil
end
local function expect_cmd(name, substr) expect(name, has_cmd(substr), "got: " .. tostring(last_setalias)) end
local function expect_nocmd(name, substr) expect(name, not has_cmd(substr), "got: " .. tostring(last_setalias)) end

local function fresh_state()
  target = "Bob"
  affstrack = { score = {} }
  ak = { defs = {}, currenthealth = 100, maxhealth = 100 }
  lb = { Bob = { hits = {} } }
  gmcp = { Char = { Vitals = { bal = "1", eq = "1" }, Status = { class = "Magi", name = "Me" } },
           Room = { Players = {}, Info = { num = 1234 } } }
  Legacy = { Curing = { Affs = {} }, Settings = { Curing = { status = true } } }
  magi.reset()
  magi.state.mode = "fire"
  magi.resonance = { earth = 0, water = 0, air = 0, fire = 0 }
  magi.storm.mode = "city"
  magi.storm.enemies = {}
  magi.storm.citizenship = DEFAULT_CITIZENSHIP
  last_setalias = nil
  last_notify = nil
  sent = {}
  cechoed = {}
  timers = {}
  timer_seq = 0
end

-- mutators
local function aff(name, conf) affstrack.score[name] = conf or 100 end
local function set_hp(pct) ak.currenthealth = pct; ak.maxhealth = 100 end
local function set_limb(limb, n) lb.Bob.hits[limb] = n end
local function set_burns(n) affstrack.score.aflame = (n or 0) * 100 end  -- AK: 100 per stack
local function reson(f, w, e, a)
  magi.resonance = { fire = f or 0, water = w or 0, earth = e or 0, air = a or 0 }
end

------------------------------------------
-- Kill routes / priority spine
------------------------------------------

print("\n[1] no target -> graceful skip, nothing queued")
fresh_state()
target = ""
magi.dispatch()
expect("notifies 'No target set'", last_notify == "No target set", last_notify)
expect("queues nothing", last_setalias == nil)

print("\n[2] opener (fire, no state) -> MAGMA + framing + queue contract")
fresh_state()
magi.dispatch()
expect_cmd("P9 magma (not scalded)", "cast magma at Bob")
expect_cmd("preamble stand", "stand")
expect_cmd("preamble wield staff shield", "wield staff569815 shield")
expect_cmd("postamble assess", "assess Bob")
local saw_setalias, saw_queue = false, false
for _, s in ipairs(sent) do
  if s:find("^SETALIAS MAGIATK ") then saw_setalias = true end
  if s == "QUEUE ADDCLEARFULL FREESTAND MAGIATK" then saw_queue = true end
end
expect("emits SETALIAS MAGIATK", saw_setalias)
expect("emits QUEUE ADDCLEARFULL FREESTAND MAGIATK", saw_queue)

print("\n[3] P1 DESTROY -- conflagrate (AK) + hp<35")
fresh_state()
aff("conflagrate")
set_hp(30)
magi.dispatch()
expect_cmd("destroy kill", "cast destroy at Bob")

print("\n[4] P2 SHIELD STRIP -- meteorite pure (no fire/earth reso)")
fresh_state()
ak.defs.shield = true
magi.dispatch()
expect_cmd("meteorite pure 4", "cast meteorite at Bob pure 4")

print("\n[5] P2 meteorite FLAMING when fire will burn (fire 1)")
fresh_state()
ak.defs.shield = true
reson(1, 0, 0, 0)
magi.dispatch()
expect_cmd("meteorite flaming 4", "cast meteorite at Bob flaming 4")

print("\n[6] P3 GLACIATE -- hypothermia (AK) + dual resonance (W2/A2)")
fresh_state()
aff("hypothermia")
reson(0, 2, 0, 2)
magi.dispatch()
expect_cmd("glaciate kill", "cast glaciate at Bob")

print("\n[7] P4 STORMHAMMER kill -- hp<=25, single-target safe")
fresh_state()
set_hp(20)
magi.dispatch()
expect_cmd("stormhammer single", "cast stormhammer at Bob")

print("\n[8] P5 SCINTILLA -- shalestorm up, earth>=2, low burns")
fresh_state()
magi.track.shalestormStart("Bob")
reson(0, 0, 2, 0)
magi.dispatch()
expect_cmd("free scintilla", "staffcast scintilla at Bob")

print("\n[9] P6 EMANATION EARTH -- earth capped + frostbite")
fresh_state()
reson(0, 0, 3, 0)
aff("frostbite", 100)
magi.dispatch()
expect_cmd("emanation earth", "cast emanation at Bob earth")

print("\n[10] P7 HYPOTHERMIA setup -- frozen (AK), not hypothermic, dual reso")
fresh_state()
aff("frozen")
reson(0, 2, 0, 2)
magi.dispatch()
expect_cmd("hypothermia setup", "cast hypothermia at Bob")

print("\n[11] P8 MUDSLIDE -- asthma + water==2")
fresh_state()
aff("asthma", 100)
reson(0, 2, 0, 0)
magi.dispatch()
expect_cmd("mudslide", "cast mudslide at Bob")

print("\n[12] P10 FREEZE -- scalded (AK), shivering, a broken limb (mending busy)")
fresh_state()
aff("scalded")
aff("shivering", 100)
set_limb("left leg", 120)
magi.dispatch()
expect_cmd("freeze (salve pressure)", "cast freeze at Bob")

print("\n[13] P11 CALCIFIED PATH -> freeze (not dehydrate-freeze)")
fresh_state()
aff("scalded")
aff("calcifiedtorso")
aff("frostbite", 100)
magi.dispatch()
expect_cmd("calcified -> freeze", "cast freeze at Bob")

print("\n[14] P11 CALCIFIED PATH -> dehydrate when dehydrate-will-freeze + fire burns")
fresh_state()
aff("scalded")
aff("calcifiedtorso")
aff("frostbite", 100); aff("nausea", 100)
reson(1, 0, 0, 0)
magi.dispatch()
expect_cmd("calcified -> dehydrate", "cast dehydrate at Bob")

print("\n[15] P12 BURNING -> conflagrate when burns>=2 & fire>=2")
fresh_state()
aff("scalded")
set_burns(2)                     -- aflame 200 -> 2 burns
reson(2, 0, 0, 0)
magi.dispatch()
expect_cmd("burning -> conflagrate", "cast conflagrate at Bob")

print("\n[16] P13 SHALESTORM -- scalded, no burns, earth>=2, not active")
fresh_state()
aff("scalded")
reson(0, 0, 2, 0)
magi.dispatch()
expect_cmd("shalestorm", "cast shalestorm at Bob")

print("\n[17] FALLBACK -- shalestorm up but earth<2, fire capped -> emanation fire")
fresh_state()
aff("scalded")
magi.track.shalestormStart("Bob")
reson(3, 0, 0, 0)
magi.dispatch()
expect_cmd("fallback emanation fire", "cast emanation at Bob fire")

print("\n[18] LOCK mode opener -> staffcast horripilation (no 'at')")
fresh_state()
magi.setMode("lock")
magi.dispatch()
expect_cmd("horripilation", "staffcast horripilation Bob")
expect("verbatim has no 'horripilation at'", not has_cmd("horripilation at"))

print("\n[19] LOCK mode, fire==2 -> fulminate instead of horripilation")
fresh_state()
magi.setMode("lock")
reson(2, 0, 0, 0)
magi.dispatch()
expect_cmd("lock fulminate", "cast fulminate at Bob")

print("\n[20] SALVE mode, earth capped -> emanation earth")
fresh_state()
magi.setMode("salve")
reson(0, 0, 3, 0)
magi.dispatch()
expect_cmd("salve emanation earth", "cast emanation at Bob earth")

print("\n[21] GROUP mode, hp<=50 -> stormhammer (higher group threshold)")
fresh_state()
magi.setMode("group")
set_hp(45)
magi.dispatch()
expect_cmd("group stormhammer at 50%", "cast stormhammer at Bob")

print("\n[22] STORMHAMMER multi-target -- enemy list + room players")
fresh_state()
magi.storm.mode = "all"
gmcp.Room.Players = { { name = "Bob" }, { name = "Xith" }, { name = "Yon" }, { name = "Ally" } }
magi.storm.enemies = { Xith = true, Yon = true }
local c22 = magi.storm.command()
expect("3-target sweep, primary first", c22 == "cast stormhammer at Bob and Xith and Yon", c22)

------------------------------------------
-- AK-read mechanic states (verify the affstrack accessors drive the tree)
------------------------------------------

print("\n[23] aflame encoding: 100 per burn stack (250 -> 2 burns -> conflagrate ready)")
fresh_state()
aff("scalded"); reson(2, 0, 0, 0)
set_burns(1)                      -- aflame 100 -> 1 burn: NOT conflagrate-ready
magi.dispatch()
expect_nocmd("1 burn is not conflagrate-ready", "cast conflagrate")
fresh_state()
aff("scalded"); reson(2, 0, 0, 0)
affstrack.score.aflame = 250      -- floor(250/100) = 2 burns
magi.dispatch()
expect_cmd("aflame 250 -> 2 burns -> conflagrate", "cast conflagrate at Bob")

print("\n[24] calcifiedtorso (AK) flips meteorite from frozen to pure")
fresh_state()
ak.defs.shield = true; reson(0, 0, 3, 0)
magi.dispatch()
expect_cmd("no calcify -> frozen meteorite", "cast meteorite at Bob frozen 4")
fresh_state()
ak.defs.shield = true; reson(0, 0, 3, 0)
aff("calcifiedtorso")
magi.dispatch()
expect_cmd("calcifiedtorso -> pure meteorite", "cast meteorite at Bob pure 4")

------------------------------------------
-- Guards
------------------------------------------

print("\n[25] guard: self aeon -> nothing queued")
fresh_state()
Legacy.Curing.Affs.aeon = true
magi.dispatch()
expect("queues nothing under aeon", last_setalias == nil)

print("\n[26] guard: curing paused -> nothing queued")
fresh_state()
Legacy.Settings.Curing.status = false
magi.dispatch()
expect("queues nothing while paused", last_setalias == nil)

print("\n[27] guard: known non-Magi class -> nothing queued")
fresh_state()
gmcp.Char.Status.class = "Sentinel"
magi.dispatch()
expect("queues nothing as wrong class", last_setalias == nil)

print("\n[28] guard tolerance: empty class still fires the real opener")
fresh_state()
gmcp.Char.Status.class = ""
magi.dispatch()
expect("unknown class does not block", last_setalias ~= nil)
expect_cmd("and selects the real opener", "cast magma at Bob")

------------------------------------------
-- Firing model (arm + dual-resource JIT)
------------------------------------------

print("\n[29] arm() with eq+bal up -> fires the real opener now")
fresh_state()
magi.arm("fire")
expect("armed-and-ready dispatches now", last_setalias ~= nil)
expect_cmd("and queued the real opener", "cast magma at Bob")

print("\n[30] arm() off balance -> arms only, notifies ARMED")
fresh_state()
gmcp.Char.Vitals.bal = "0"
magi.arm("fire")
expect("nothing queued off balance", last_setalias == nil)
expect("armed flag set", magi.state.next_bal_armed == true)
expect("notifies ARMED", last_notify == "ARMED", last_notify)

print("\n[31] dual resource: keep the LONGER timer; callback fires without re-gating eqbal")
fresh_state()
gmcp.Char.Vitals.bal = "0"
magi.arm("fire")
magi.on_balance(2.8)
local short_id = magi.state.next_bal_timer
magi.on_eq(3.1)
local long_id = magi.state.next_bal_timer
expect("longer (eq) timer replaced shorter (bal)", long_id ~= short_id)
expect("shorter timer killed", timers[short_id].alive == false)
expect("longer timer live", timers[long_id].alive == true)
fresh_state()
gmcp.Char.Vitals.bal = "0"
magi.arm("fire")
magi.on_balance(3.1)
local keep_id = magi.state.next_bal_timer
magi.on_balance(2.8)
expect("shorter request did not replace longer timer", magi.state.next_bal_timer == keep_id)
last_setalias = nil
timers[keep_id].fn()
expect("timer fired dispatch without eqbal re-gate", last_setalias ~= nil)
expect_cmd("and selected a real spell", "cast magma at Bob")
expect("disarmed after firing", magi.state.next_bal_armed == false)

print("\n[32] on_balance nil / non-numeric -> no-op (no timer, nothing queued)")
fresh_state()
gmcp.Char.Vitals.bal = "0"
magi.arm("fire")
magi.on_balance(nil)
expect("nil interval -> no timer", magi.state.next_bal_timer == nil)
magi.on_balance("x")
expect("non-numeric interval -> no timer", magi.state.next_bal_timer == nil)
expect("nothing queued by guarded on_balance", last_setalias == nil)

------------------------------------------
-- Priority pre-emption (ordering is load-bearing)
------------------------------------------

print("\n[33] pre-emption P1>P2: conflagrate+hp<35+shield -> DESTROY not meteorite")
fresh_state()
aff("conflagrate"); set_hp(30); ak.defs.shield = true
magi.dispatch()
expect_cmd("destroy wins over shield-strip", "cast destroy at Bob")
expect_nocmd("no meteorite", "meteorite")

print("\n[34] pre-emption P1>P4: conflagrate+hp<=25 -> DESTROY not stormhammer")
fresh_state()
aff("conflagrate"); set_hp(20)
magi.dispatch()
expect_cmd("destroy wins over stormhammer", "cast destroy at Bob")
expect_nocmd("no stormhammer", "stormhammer")

print("\n[35] pre-emption P2>P3: shield+hypothermia+freso -> METEORITE not glaciate")
fresh_state()
ak.defs.shield = true; aff("hypothermia"); reson(0, 2, 0, 2)
magi.dispatch()
expect_cmd("meteorite wins over glaciate", "cast meteorite at Bob")
expect_nocmd("no glaciate", "glaciate")

print("\n[36] pre-emption P3>P4: hypothermia+freso+hp<=25 -> GLACIATE not stormhammer")
fresh_state()
aff("hypothermia"); reson(0, 2, 0, 2); set_hp(20)
magi.dispatch()
expect_cmd("glaciate wins over stormhammer", "cast glaciate at Bob")
expect_nocmd("no stormhammer", "stormhammer")

print("\n[37] pre-emption P5>P6: shalestorm+earth3+frostbite -> SCINTILLA not emanation earth")
fresh_state()
magi.track.shalestormStart("Bob"); reson(0, 0, 3, 0); aff("frostbite", 100)
magi.dispatch()
expect_cmd("scintilla wins over emanation earth", "staffcast scintilla at Bob")
expect_nocmd("no emanation earth", "emanation at Bob earth")

------------------------------------------
-- Meteorite variants / scalded pivot / P5 suppression
------------------------------------------

print("\n[38] meteorite FROZEN (water<3, no fire/earth burn room)")
fresh_state()
ak.defs.shield = true; reson(0, 0, 3, 0)
magi.dispatch()
expect_cmd("meteorite frozen 4", "cast meteorite at Bob frozen 4")

print("\n[39] meteorite -> ERODE maintain (all capped)")
fresh_state()
ak.defs.shield = true; reson(0, 3, 3, 0)
magi.dispatch()
expect_cmd("erode maintain", "cast erode at Bob maintain")

print("\n[40] scalded latch (AK) ALONE flips the decision, reson held constant")
fresh_state()
reson(0, 0, 2, 0)
magi.dispatch()
expect_cmd("unscalded -> magma", "cast magma at Bob")
aff("scalded")
magi.dispatch()
expect_cmd("scalded -> shalestorm (P9 skipped, P13)", "cast shalestorm at Bob")

print("\n[41] P5 scintilla suppressed when conflagrate imminent (burns2 & fire2)")
fresh_state()
magi.track.shalestormStart("Bob"); reson(2, 0, 2, 0); set_burns(2)
magi.dispatch()
expect_nocmd("no scintilla when conflagrate imminent", "scintilla")

print("\n[42] P5 scintilla suppressed at burns cap (burns==5)")
fresh_state()
magi.track.shalestormStart("Bob"); reson(0, 0, 2, 0); set_burns(5)
magi.dispatch()
expect_nocmd("no scintilla at burns cap", "scintilla")

------------------------------------------
-- Burning sub-tree arms (P12)
------------------------------------------

print("\n[43] burning sub-tree: fulminate / emanation fire / bombard / emanation water / dehydrate")
local function burning_case(label, f, w, e, a, want)
  fresh_state()
  aff("scalded")        -- skip P9
  set_burns(1)          -- 1 burn -> enter P12, skip conflagrate arm
  reson(f, w, e, a)
  magi.dispatch()
  expect_cmd(label, want)
end
burning_case("fulminate (air0/water2/fire1)", 1, 2, 0, 0, "cast fulminate at Bob")
burning_case("emanation fire (fire==3)", 3, 0, 0, 0, "cast emanation at Bob fire")
burning_case("bombard (earth1, fire0)", 0, 0, 1, 0, "cast bombard at Bob")
burning_case("emanation water (water==3)", 0, 3, 0, 0, "cast emanation at Bob water")
burning_case("default dehydrate (no resonance)", 0, 0, 0, 0, "cast dehydrate at Bob")

------------------------------------------
-- Stormhammer selector modes
------------------------------------------

print("\n[44] stormhammer CITY mode: only same-city enemies swept")
fresh_state()
magi.storm.mode = "city"
gmcp.Room.Players = { { name = "Bob" }, { name = "Xith" }, { name = "Zed" }, { name = "Yon" } }
magi.storm.enemies = { Xith = true, Zed = true, Yon = true }
magi.storm.citizenship = function(n)
  if n == "Bob" or n == "Xith" or n == "Zed" then return "Mhaldor" end
  return "Cyrene"
end
local c44 = magi.storm.command()
expect("city sweeps same-city only, primary first", c44 == "cast stormhammer at Bob and Xith and Zed", c44)

print("\n[45] stormhammer CITY degrades to ALL when no citizenship")
fresh_state()
magi.storm.mode = "city"
gmcp.Room.Players = { { name = "Bob" }, { name = "Yon" } }
magi.storm.enemies = { Yon = true }
local c45 = magi.storm.command()
expect("degrade-to-all includes Yon", c45 == "cast stormhammer at Bob and Yon", c45)

print("\n[46] stormhammer PRIORITY mode honors tprio order")
fresh_state()
magi.storm.mode = "priority"
gmcp.Room.Players = { { name = "Bob" }, { name = "Xith" }, { name = "Yon" } }
magi.storm.enemies = { Xith = true, Yon = true }
tprio = { list = { "Yon", "Xith" } }
local c46 = magi.storm.command()
tprio = nil
expect("priority order (target slot1, then tprio order)", c46 == "cast stormhammer at Bob and Yon and Xith", c46)

print("\n[47] room_players strips 'the soul of '")
fresh_state()
target = "Ghost"
lb = { Ghost = { hits = {} } }
magi.storm.mode = "all"
gmcp.Room.Players = { { name = "the soul of Ghost" } }
local c47 = magi.storm.command()
expect("soul-of prefix stripped", c47 == "cast stormhammer at Ghost", c47)

print("\n[48] storm.setMode validation + empty-list single-target fallback")
fresh_state()
magi.storm.setMode("bogus")
expect("invalid mode rejected", magi.storm.mode ~= "bogus")
magi.storm.setMode("priority")
expect("valid mode accepted", magi.storm.mode == "priority")
magi.storm.mode = "all"
local c48 = magi.storm.command()
expect("empty enemies -> single-target", c48 == "cast stormhammer at Bob", c48)

------------------------------------------
-- Self-tracked handlers that AK can't supply (+ applied-aff fallback latches)
------------------------------------------

print("\n[49] scintilla spark sets the over-cast latch; ignite clears it (no burn -- AK owns aflame)")
fresh_state()
magi.track.scintillaSpark("Bob")
expect("spark latched", magi.state.scintillaSpark == true)
magi.track.scintillaIgnite("Bob")
expect("ignite clears spark", magi.state.scintillaSpark == false)
expect("ignite does not touch aflame", (affstrack.score.aflame or 0) == 0)
fresh_state()
magi.track.scintillaSpark("Someone")
expect("spark ignores non-target", magi.state.scintillaSpark == false)

print("\n[50] shalestorm start/end + anti-illusion (earth reso>0 ignores end)")
fresh_state()
magi.track.shalestormStart("Bob")
reson(0, 0, 2, 0)
magi.track.shalestormEnd("Bob")
expect("shalestorm survives while earth resonance up", magi.state.shalestorm == true)
reson(0, 0, 0, 0)
magi.track.shalestormEnd("Bob")
expect("shalestorm ends once earth resonance gone", magi.state.shalestorm == false)

print("\n[51] applied-aff fallback: bombard/mudslide/blistered + fulminate chain")
fresh_state()
magi.track.bombard("Bob")
expect("bombard latches clumsiness", magi.affs.clumsiness == true)
magi.track.mudslide("Bob")
expect("mudslide latches slickness+prone", magi.affs.slickness == true and magi.affs.prone == true)
magi.track.resFireBlistered("Bob")
expect("blistered latched", magi.affs.blistered == true)
expect("blistered scheduled a 15s timer", timers[1] ~= nil and timers[1].wait == 15)
timers[1].fn()
expect("timer clears blistered", magi.affs.blistered == false)
fresh_state()
aff("epilepsy", 100); aff("fulminated", 100)
magi.track.fulminate("Bob")
expect("fulminate chain lands paralysis", magi.affs.paralysis == true)

print("\n[52] freeze-chain intermediates: freezeRip advances nocaloric -> shivering (AK owns frozen)")
fresh_state()
magi.track.freezeRip("Bob")
expect("stage 1 -> nocaloric", magi.affs.nocaloric == true)
magi.track.freezeRip("Bob")
expect("stage 2 -> shivering", magi.affs.shivering == true)
magi.track.freezeRip("Someone")
expect("freezeRip ignores non-target", true)  -- no crash / no change asserted below
expect("nocaloric still latched after non-target call", magi.affs.nocaloric == true)

print("\n[53] applied-aff latch reads via has_aff: waterbond skips lock horripilation loop")
fresh_state()
magi.setMode("lock")
magi.track.resAff("waterbond", "Bob")
magi.dispatch()
expect("waterbond latch skips horripilation", not has_cmd("horripilation"))
expect_cmd("falls through to magma", "cast magma at Bob")
magi.track.curedAff("waterbond", "Bob")
expect("curedAff clears the latch", magi.affs.waterbond == nil)

------------------------------------------
-- Lifecycle + status
------------------------------------------

print("\n[54] reset wipes OUR state (shalestorm/scintilla/affs); AK states are not ours to clear")
fresh_state()
magi.track.shalestormStart("Bob")
magi.track.scintillaSpark("Bob")
magi.track.resAff("clumsiness", "Bob")
magi.reset()
expect("shalestorm cleared", magi.state.shalestorm == false)
expect("scintilla spark cleared", magi.state.scintillaSpark == false)
expect("applied-aff latches cleared", next(magi.affs) == nil)

print("\n[55] status() renders a box (title / target / resonance / AK burns)")
fresh_state()
reson(2, 1, 3, 0)
set_burns(1)
magi.status()
local box = table.concat(cechoed, "\n")
expect("box shows MAGI", box:find("MAGI", 1, true) ~= nil)
expect("box shows target", box:find("Bob", 1, true) ~= nil)
expect("box shows resonance F", box:find("F:2", 1, true) ~= nil)
expect("box shows burns from aflame", box:find("1/5", 1, true) ~= nil)
expect("box drew a border", box:find("╭", 1, true) ~= nil)

------------------------------------------
-- Summary
------------------------------------------
print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures > 0 and 1 or 0)
