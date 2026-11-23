## Static data, enums, and pegboard tables for Pegs of Ur.

type
  DieFace* = enum
    dfGrain3 = 0
    dfWare1 = 1
    dfOmenWares2 = 2
    dfBuilders3 = 3
    dfGrainOrBuilders2 = 4
    dfSilver7 = 5

  WareType* = enum
    wtTimber = 0
    wtAlabaster = 1
    wtCeramics = 2
    wtLinen = 3
    wtIngots = 4

  SeatType* = enum
    stHuman = 0
    stAiEasy = 1
    stAiNormal = 2
    stAiHard = 3
    stClosed = 4

  Phase* = enum
    phSetup = 0
    phRoll = 1
    phAssignChoices = 2
    phBuild = 3
    phBuy = 4
    phDiscard = 5
    phGameOver = 6

  ModalKind* = enum
    mkNone = 0
    mkSetup = 1
    mkRules = 2
    mkGameOver = 3
    mkGlobalStandings = 4
    mkOnlineLobby = 5
    mkSupport = 6

  AiSpeedKind* = enum
    asNormal = 0
    asFast = 1
    asSlow = 2

  AudioCueKind* = enum
    akWoodBounce = 0
    akPegTap = 1
    akOmenThud = 2
    akUiTap = 3
    akBuild = 4
    akCoin = 5
    akDisaster = 6
    akFanfare = 7

  Rgba* = object
    r*, g*, b*, a*: float32

  UiRect* = object
    x*, y*, w*, h*: float

  GreatWorkDef* = object
    id*: string
    name*: string
    builders*: int
    vpFirst*: int
    vpLater*: int
    skip2p*: bool
    skip3p*: bool
    note*: string

  AdvancementDef* = object
    id*: string
    name*: string
    cost*: int
    vp*: int
    effect*: string

  SeatConfig* = object
    name*: string
    seatType*: SeatType
    color*: Rgba

  AudioEvent* = object
    kind*: AudioCueKind
    energy*: float
    pitch*: float

const
  MaxGrain* = 15
  InitialGrain* = 3
  InitialSettlements* = 3
  MaxSettlements* = 7
  DefaultWaresLimit* = 6
  SoloMaxRounds* = 14
  AdvEndTrigger* = 8

  SevenCitiesVp* = 3
  UnscathedRealmVp* = 3
  MasterTraderPerTrackVp* = 2
  MasterBuilderWorkCount* = 3
  MasterBuilderVp* = 3
  FirstTo4AdvCount* = 4
  FirstTo4AdvVp* = 2
  FirstTo8AdvCount* = 8
  FirstTo8AdvVp* = 5

  SettlementCosts*: array[4, int] = [3, 4, 5, 6]

  WareNames*: array[WareType, string] = [
    "Timber",
    "Alabaster",
    "Ceramics",
    "Linen",
    "Ingots",
  ]

  WareColors*: array[WareType, Rgba] = [
    Rgba(r: 0.72'f32, g: 0.45'f32, b: 0.22'f32, a: 1.0'f32),
    Rgba(r: 0.68'f32, g: 0.72'f32, b: 0.76'f32, a: 1.0'f32),
    Rgba(r: 0.84'f32, g: 0.42'f32, b: 0.27'f32, a: 1.0'f32),
    Rgba(r: 0.30'f32, g: 0.58'f32, b: 0.86'f32, a: 1.0'f32),
    Rgba(r: 0.90'f32, g: 0.73'f32, b: 0.26'f32, a: 1.0'f32),
  ]

  RealmDefaults*: array[4, tuple[name: string, color: Rgba]] = [
    ("Ur", Rgba(r: 0.24'f32, g: 0.52'f32, b: 0.82'f32, a: 1.0'f32)),
    ("Byblos", Rgba(r: 0.86'f32, g: 0.66'f32, b: 0.22'f32, a: 1.0'f32)),
    ("Knossos", Rgba(r: 0.78'f32, g: 0.31'f32, b: 0.27'f32, a: 1.0'f32)),
    ("Thebes", Rgba(r: 0.58'f32, g: 0.36'f32, b: 0.74'f32, a: 1.0'f32)),
  ]

  GreatWorks*: array[7, GreatWorkDef] = [
    GreatWorkDef(id: "mudbrick_shrine", name: "Mudbrick Shrine", builders: 3, vpFirst: 1, vpLater: 0, skip2p: false, skip3p: false, note: ""),
    GreatWorkDef(id: "standing_stones", name: "Standing Stones", builders: 5, vpFirst: 2, vpLater: 1, skip2p: false, skip3p: false, note: ""),
    GreatWorkDef(id: "river_sanctuary", name: "River Sanctuary", builders: 7, vpFirst: 4, vpLater: 3, skip2p: true, skip3p: false, note: "3-4P / Solo"),
    GreatWorkDef(id: "royal_stele", name: "Royal Stele", builders: 9, vpFirst: 6, vpLater: 4, skip2p: false, skip3p: false, note: ""),
    GreatWorkDef(id: "terraced_groves", name: "Terraced Groves", builders: 11, vpFirst: 8, vpLater: 5, skip2p: false, skip3p: true, note: "2P / 4P / Solo"),
    GreatWorkDef(id: "citadel_ramparts", name: "Citadel Ramparts", builders: 13, vpFirst: 10, vpLater: 6, skip2p: false, skip3p: false, note: "Blocks Raiders"),
    GreatWorkDef(id: "sun_ziggurat", name: "Sun Ziggurat", builders: 15, vpFirst: 12, vpLater: 8, skip2p: true, skip3p: false, note: "3-4P / Solo"),
  ]

  Advancements*: array[13, AdvancementDef] = [
    AdvancementDef(id: "divination", name: "Divination", cost: 10, vp: 2, effect: "Reroll 1 die (even a locked Omen) once per turn"),
    AdvancementDef(id: "canals", name: "Canals", cost: 10, vp: 2, effect: "Blight (2 Omens) has no effect"),
    AdvancementDef(id: "plowshares", name: "Plowshares", cost: 15, vp: 3, effect: "+1 Grain with each Grain die"),
    AdvancementDef(id: "stonecutting", name: "Stonecutting", cost: 15, vp: 3, effect: "+1 Alabaster whenever collecting Alabaster"),
    AdvancementDef(id: "herbalism", name: "Herbalism", cost: 20, vp: 4, effect: "Plague (3 Omens) has no effect"),
    AdvancementDef(id: "minting", name: "Minting", cost: 20, vp: 4, effect: "Silver dice yield 12 Silver instead of 7"),
    AdvancementDef(id: "merchant_fleets", name: "Merchant Fleets", cost: 20, vp: 4, effect: "No 6-Ware storage cap at end of turn"),
    AdvancementDef(id: "priesthood", name: "Priesthood", cost: 25, vp: 7, effect: "Uprising (5+ Omens) strikes rivals instead"),
    AdvancementDef(id: "silos", name: "Royal Silos", cost: 30, vp: 6, effect: "Trade Grain for 6 Silver each when unlocking"),
    AdvancementDef(id: "scaffolding", name: "Scaffolding", cost: 30, vp: 6, effect: "+1 Builder with each Builder die"),
    AdvancementDef(id: "cranes", name: "Timber Cranes", cost: 40, vp: 6, effect: "Trade Alabaster for 3 Builders each when building"),
    AdvancementDef(id: "urban_planning", name: "Urban Planning", cost: 60, vp: 8, effect: "+2 bonus Renown per completed Great Work"),
    AdvancementDef(id: "hegemony", name: "Hegemony", cost: 70, vp: 10, effect: "+1 bonus Renown per Settlement"),
  ]

proc rgba*(r, g, b: float32; a: float32 = 1.0'f32): Rgba {.inline.} =
  Rgba(r: r, g: g, b: b, a: a)

proc uiRect*(x, y, w, h: float): UiRect {.inline.} =
  UiRect(x: x, y: y, w: w, h: h)

proc contains*(rc: UiRect; px, py: float): bool {.inline.} =
  px >= rc.x and px <= rc.x + rc.w and py >= rc.y and py <= rc.y + rc.h

proc wareMaxQty*(w: WareType): int {.inline.} =
  8 - ord(w)

proc wareSilverValue*(w: WareType; qty: int): int {.inline.} =
  let clamped = clamp(qty, 0, wareMaxQty(w))
  (ord(w) + 1) * (clamped * (clamped + 1) div 2)

proc isGreatWorkActive*(gwIdx, playerCount: int): bool {.inline.} =
  let gw = GreatWorks[gwIdx]
  if playerCount == 2 and gw.skip2p:
    return false
  if playerCount == 3 and gw.skip3p:
    return false
  true

proc getGreatWorkIndex*(gwId: string): int =
  for i, gw in GreatWorks:
    if gw.id == gwId:
      return i
  -1

proc getAdvancementIndex*(advId: string): int =
  for i, a in Advancements:
    if a.id == advId:
      return i
  -1

proc dieFaceLabel*(face: DieFace): string =
  case face
  of dfGrain3: "3 Grain"
  of dfWare1: "1 Ware"
  of dfOmenWares2: "2 Wares + Omen"
  of dfBuilders3: "3 Builders"
  of dfGrainOrBuilders2: "2 Grain / 2 Builders"
  of dfSilver7: "7 Silver"

proc seatShortTag*(st: SeatType): string =
  case st
  of stHuman: "Human"
  of stAiEasy: "AI Easy"
  of stAiNormal: "AI Normal"
  of stAiHard: "AI Hard"
  of stClosed: "Closed"

proc aiSpeedDelay*(spd: AiSpeedKind): float =
  case spd
  of asNormal: 0.60
  of asFast: 0.20
  of asSlow: 1.10

proc aiSpeedLabel*(spd: AiSpeedKind): string =
  case spd
  of asNormal: "Normal"
  of asFast: "Fast"
  of asSlow: "Slow"
