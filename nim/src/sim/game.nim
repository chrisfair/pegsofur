## Core rules engine for Pegs of Ur.

import std/[algorithm, math, strformat, strutils]
import data, entropy

type
  RealmState* = object
    index*: int
    name*: string
    color*: Rgba
    seatType*: SeatType
    settlements*: int
    settlementProgress*: array[4, int]
    grain*: int
    wares*: array[WareType, int]
    workProgress*: array[7, int]
    workFirst*: array[7, bool]
    advancements*: array[13, bool]
    calamities*: int

  ScoreBreakdown* = object
    playerIdx*: int
    name*: string
    color*: Rgba
    worksVp*: int
    advancementsVp*: int
    milestonesVp*: int
    bonusVp*: int
    calamities*: int
    totalVp*: int
    tiebreakerWaresValue*: int

  PaymentPlan* = object
    valid*: bool
    cost*: int
    silverUsed*: int
    waresMask*: array[WareType, bool]
    siloGrain*: int
    totalPaid*: int

  BuildSnapshot* = object
    valid*: bool
    settlements*: int
    settlementProgress*: array[4, int]
    workProgress*: array[7, int]
    workFirst*: array[7, bool]
    workFirstOwner*: array[7, int]
    alabaster*: int
    turnBuilders*: int
    finalRoundTriggered*: bool
    finalTriggerReason*: string

  CalamityAlert* = object
    title*: string
    detail*: string

  PegsOfUrGame* = ref object
    entropy*: EntropyPool
    players*: seq[RealmState]
    activePlayerIdx*: int
    roundNumber*: int
    phase*: Phase
    finalRoundTriggered*: bool
    finalTriggerReason*: string
    workFirstOwner*: array[7, int]
    firstTo4AdvOwner*: int
    firstTo8AdvOwner*: int

    diceFaces*: seq[DieFace]
    diceSelectedForReroll*: seq[bool]
    choiceIsBuilders*: seq[bool]
    rollsUsed*: int
    maxRolls*: int
    divinationUsed*: bool
    turnBuilders*: int
    turnSilver*: int
    boughtAdvThisTurn*: bool

    buildSnapshot*: BuildSnapshot
    eventLog*: seq[string]

    lastRolledIndices*: seq[int]
    rollEventSeq*: int
    pendingCalamities*: seq[CalamityAlert]
    gameFinishedTriggered*: bool

proc addLog(g: PegsOfUrGame; msg: string) =
  g.eventLog.add(msg)
  if g.eventLog.len > 160:
    g.eventLog.delete(0)

proc newPegsOfUrGame*(seed: int64 = -1; tpmPath: string = DefaultTpmDevice): PegsOfUrGame =
  result = PegsOfUrGame(
    entropy: newEntropyPool(seed, tpmPath),
    phase: phSetup,
    roundNumber: 1,
    maxRolls: 3,
    firstTo4AdvOwner: -1,
    firstTo8AdvOwner: -1,
  )
  for i in 0 ..< GreatWorks.len:
    result.workFirstOwner[i] = -1

proc isSolo*(g: PegsOfUrGame): bool {.inline.} =
  g.players.len == 1

proc isActiveHuman*(g: PegsOfUrGame): bool {.inline.} =
  if g.phase in {phSetup, phGameOver} or g.players.len == 0:
    return false
  g.players[g.activePlayerIdx].seatType == stHuman

proc playerHasAdv*(g: PegsOfUrGame; pIdx: int; advId: string): bool =
  let aIdx = getAdvancementIndex(advId)
  aIdx >= 0 and g.players[pIdx].advancements[aIdx]

proc playerCompletedWork*(g: PegsOfUrGame; pIdx, gwIdx: int): bool {.inline.} =
  g.players[pIdx].workProgress[gwIdx] >= GreatWorks[gwIdx].builders

proc playerTotalWares*(g: PegsOfUrGame; pIdx: int): int =
  for wt in WareType:
    result += g.players[pIdx].wares[wt]

proc playerWaresSilverValue*(g: PegsOfUrGame; pIdx: int): int =
  for wt in WareType:
    result += wareSilverValue(wt, g.players[pIdx].wares[wt])

proc playerAdvCount*(g: PegsOfUrGame; pIdx: int): int =
  for owned in g.players[pIdx].advancements:
    if owned:
      inc result

proc playerCompletedWorkCount*(g: PegsOfUrGame; pIdx: int): int =
  for gwIdx in 0 ..< GreatWorks.len:
    if g.playerCompletedWork(pIdx, gwIdx):
      inc result

proc playerMaxedWareTrackCount*(g: PegsOfUrGame; pIdx: int): int =
  for wt in WareType:
    if g.players[pIdx].wares[wt] >= wareMaxQty(wt):
      inc result

proc computeScoreBreakdown*(g: PegsOfUrGame; pIdx: int): ScoreBreakdown =
  let p = g.players[pIdx]
  var wVp = 0
  for gwIdx in 0 ..< GreatWorks.len:
    if g.playerCompletedWork(pIdx, gwIdx):
      wVp += (if p.workFirst[gwIdx]: GreatWorks[gwIdx].vpFirst else: GreatWorks[gwIdx].vpLater)

  var aVp = 0
  for aIdx in 0 ..< Advancements.len:
    if p.advancements[aIdx]:
      aVp += Advancements[aIdx].vp

  var mVp = 0
  if p.settlements >= MaxSettlements:
    mVp += SevenCitiesVp
  if p.calamities == 0:
    mVp += UnscathedRealmVp
  mVp += g.playerMaxedWareTrackCount(pIdx) * MasterTraderPerTrackVp
  if g.playerCompletedWorkCount(pIdx) >= MasterBuilderWorkCount:
    mVp += MasterBuilderVp
  if g.firstTo4AdvOwner == pIdx:
    mVp += FirstTo4AdvVp
  if g.firstTo8AdvOwner == pIdx:
    mVp += FirstTo8AdvVp

  var bonusVp = mVp
  if g.playerHasAdv(pIdx, "urban_planning"):
    bonusVp += 2 * g.playerCompletedWorkCount(pIdx)
  if g.playerHasAdv(pIdx, "hegemony"):
    bonusVp += p.settlements

  let total = wVp + aVp + bonusVp - p.calamities
  ScoreBreakdown(
    playerIdx: pIdx,
    name: p.name,
    color: p.color,
    worksVp: wVp,
    advancementsVp: aVp,
    milestonesVp: mVp,
    bonusVp: bonusVp,
    calamities: p.calamities,
    totalVp: total,
    tiebreakerWaresValue: g.playerWaresSilverValue(pIdx),
  )

proc getStandings*(g: PegsOfUrGame): seq[ScoreBreakdown] =
  for i in 0 ..< g.players.len:
    result.add(g.computeScoreBreakdown(i))
  result.sort(proc(a, b: ScoreBreakdown): int =
    if a.totalVp != b.totalVp:
      return cmp(b.totalVp, a.totalVp)
    cmp(b.tiebreakerWaresValue, a.tiebreakerWaresValue)
  )

proc beginTurn(g: PegsOfUrGame) =
  let numDice = g.players[g.activePlayerIdx].settlements
  g.diceFaces.setLen(numDice)
  g.diceSelectedForReroll.setLen(numDice)
  g.choiceIsBuilders.setLen(numDice)
  g.lastRolledIndices.setLen(0)

  for i in 0 ..< numDice:
    g.diceFaces[i] = g.entropy.rollDieFace()
    g.diceSelectedForReroll[i] = false
    g.choiceIsBuilders[i] = true
    g.lastRolledIndices.add(i)

  inc g.rollEventSeq
  g.rollsUsed = 1
  g.divinationUsed = false
  g.turnBuilders = 0
  g.turnSilver = 0
  g.boughtAdvThisTurn = false
  g.phase = phRoll
  g.addLog(fmt"— Round {g.roundNumber}: {g.players[g.activePlayerIdx].name}'s turn ({numDice} dice) —")

proc startGame*(g: PegsOfUrGame; configs: openArray[SeatConfig]) =
  g.players.setLen(0)
  g.eventLog.setLen(0)
  g.pendingCalamities.setLen(0)
  g.gameFinishedTriggered = false
  for i in 0 ..< GreatWorks.len:
    g.workFirstOwner[i] = -1
  g.firstTo4AdvOwner = -1
  g.firstTo8AdvOwner = -1

  for cfg in configs:
    if cfg.seatType == stClosed:
      continue
    let idx = g.players.len
    if idx >= 4:
      break
    let defR = RealmDefaults[idx mod 4]
    let nm = if cfg.name.strip().len > 0: cfg.name.strip() else: defR.name
    let col = if cfg.color.a > 0.0'f32: cfg.color else: defR.color
    g.players.add(RealmState(
      index: idx,
      name: nm,
      color: col,
      seatType: cfg.seatType,
      settlements: InitialSettlements,
      grain: InitialGrain,
    ))

  doAssert g.players.len >= 1 and g.players.len <= 4, "Pegs of Ur requires 1 to 4 active seats"
  g.roundNumber = 1
  g.activePlayerIdx = 0
  g.finalRoundTriggered = false
  g.finalTriggerReason = ""
  let rngTag = entropySourceLabel(g.entropy)
  if g.isSolo():
    g.addLog(fmt"Started 1-Player Solo Pegs of Ur ({SoloMaxRounds} Rounds) [RNG: {rngTag}].")
  else:
    g.addLog(fmt"Started {g.players.len}-Realm Pegs of Ur match [RNG: {rngTag}].")
  g.beginTurn()

proc canDieBeToggledForReroll*(g: PegsOfUrGame; dieIdx: int): bool =
  if g.phase != phRoll or g.rollsUsed >= g.maxRolls:
    return false
  if dieIdx < 0 or dieIdx >= g.diceFaces.len:
    return false
  if g.diceFaces[dieIdx] == dfOmenWares2 and not g.isSolo():
    return false
  true

proc toggleDieForReroll*(g: PegsOfUrGame; dieIdx: int): bool =
  if not g.canDieBeToggledForReroll(dieIdx):
    return false
  g.diceSelectedForReroll[dieIdx] = not g.diceSelectedForReroll[dieIdx]
  true

proc selectAllRerollable*(g: PegsOfUrGame) =
  if g.phase != phRoll or g.rollsUsed >= g.maxRolls:
    return
  var anyUnselected = false
  for i in 0 ..< g.diceFaces.len:
    if g.canDieBeToggledForReroll(i) and not g.diceSelectedForReroll[i]:
      anyUnselected = true
      break
  for i in 0 ..< g.diceFaces.len:
    if g.canDieBeToggledForReroll(i):
      g.diceSelectedForReroll[i] = anyUnselected

proc canRerollSelected*(g: PegsOfUrGame): bool =
  if g.phase != phRoll or g.rollsUsed >= g.maxRolls:
    return false
  for i in 0 ..< g.diceSelectedForReroll.len:
    if g.diceSelectedForReroll[i] and g.canDieBeToggledForReroll(i):
      return true
  false

proc rerollSelectedDice*(g: PegsOfUrGame): bool =
  if not g.canRerollSelected():
    return false
  g.lastRolledIndices.setLen(0)
  for i in 0 ..< g.diceFaces.len:
    if g.diceSelectedForReroll[i] and g.canDieBeToggledForReroll(i):
      g.diceFaces[i] = g.entropy.rollDieFace()
      g.diceSelectedForReroll[i] = false
      g.lastRolledIndices.add(i)
  inc g.rollEventSeq
  inc g.rollsUsed
  let word = if g.lastRolledIndices.len == 1: "die" else: "dice"
  g.addLog(fmt"{g.players[g.activePlayerIdx].name} rerolled {g.lastRolledIndices.len} {word} (Cast {g.rollsUsed}/{g.maxRolls}).")
  true

proc canUseDivination*(g: PegsOfUrGame): bool {.inline.} =
  g.phase == phRoll and g.playerHasAdv(g.activePlayerIdx, "divination") and not g.divinationUsed

proc rerollSingleWithDivination*(g: PegsOfUrGame; dieIdx: int): bool =
  if not g.canUseDivination() or dieIdx < 0 or dieIdx >= g.diceFaces.len:
    return false
  let oldLbl = dieFaceLabel(g.diceFaces[dieIdx])
  g.diceFaces[dieIdx] = g.entropy.rollDieFace()
  g.diceSelectedForReroll[dieIdx] = false
  g.divinationUsed = true
  g.lastRolledIndices = @[dieIdx]
  inc g.rollEventSeq
  let newLbl = dieFaceLabel(g.diceFaces[dieIdx])
  g.addLog(fmt"{g.players[g.activePlayerIdx].name} used Divination: {oldLbl} -> {newLbl}.")
  true

proc checkEndTriggers(g: PegsOfUrGame) =
  if g.finalRoundTriggered:
    return
  for pIdx in 0 ..< g.players.len:
    if g.playerAdvCount(pIdx) >= AdvEndTrigger:
      g.finalRoundTriggered = true
      g.finalTriggerReason = fmt"{g.players[pIdx].name} unlocked {AdvEndTrigger} Advancements!"
      g.addLog(fmt"FINAL ROUND TRIGGERED: {g.finalTriggerReason}")
      return

  var allBuilt = true
  for gwIdx in 0 ..< GreatWorks.len:
    if isGreatWorkActive(gwIdx, g.players.len) and g.workFirstOwner[gwIdx] == -1:
      allBuilt = false
      break
  if allBuilt:
    g.finalRoundTriggered = true
    g.finalTriggerReason = "Every active Great Work has been raised!"
    g.addLog(fmt"FINAL ROUND TRIGGERED: {g.finalTriggerReason}")

proc finishTurn(g: PegsOfUrGame) =
  g.checkEndTriggers()
  let isLastSeat = (g.activePlayerIdx == g.players.len - 1)
  if isLastSeat:
    if g.finalRoundTriggered or (g.isSolo() and g.roundNumber >= SoloMaxRounds):
      g.phase = phGameOver
      g.gameFinishedTriggered = true
      let st = g.getStandings()
      if g.isSolo():
        g.addLog(fmt"=== SOLO COMPLETE! Final Renown: {st[0].totalVp} VP (Wares: {st[0].tiebreakerWaresValue}s) ===")
      else:
        g.addLog(fmt"=== ERA COMPLETE! Victor: {st[0].name} with {st[0].totalVp} Renown! ===")
      return
    inc g.roundNumber
    g.activePlayerIdx = 0
  else:
    inc g.activePlayerIdx
  g.beginTurn()

proc excessWaresToDiscard*(g: PegsOfUrGame; pIdx: int): int =
  if g.playerHasAdv(pIdx, "merchant_fleets"):
    return 0
  max(0, g.playerTotalWares(pIdx) - DefaultWaresLimit)

proc enterDiscardOrEndTurn(g: PegsOfUrGame) =
  if g.excessWaresToDiscard(g.activePlayerIdx) > 0:
    g.phase = phDiscard
  else:
    g.finishTurn()

proc maxPurchasingPower*(g: PegsOfUrGame; pIdx: int): int =
  result = (if pIdx == g.activePlayerIdx: g.turnSilver else: 0) + g.playerWaresSilverValue(pIdx)
  if g.playerHasAdv(pIdx, "silos"):
    result += g.players[pIdx].grain * 6

proc canAffordAnyAdvancement*(g: PegsOfUrGame; pIdx: int): bool =
  let power = g.maxPurchasingPower(pIdx)
  for aIdx in 0 ..< Advancements.len:
    if not g.players[pIdx].advancements[aIdx] and power >= Advancements[aIdx].cost:
      return true
  false

proc enterBuyPhase(g: PegsOfUrGame) =
  if g.canAffordAnyAdvancement(g.activePlayerIdx):
    g.phase = phBuy
  else:
    g.enterDiscardOrEndTurn()

proc enterBuildPhase(g: PegsOfUrGame) =
  let pIdx = g.activePlayerIdx
  let canCranes = g.playerHasAdv(pIdx, "cranes") and g.players[pIdx].wares[wtAlabaster] > 0
  if g.turnBuilders <= 0 and not canCranes:
    g.enterBuyPhase()
    return
  let p = g.players[pIdx]
  g.buildSnapshot = BuildSnapshot(
    valid: true,
    settlements: p.settlements,
    settlementProgress: p.settlementProgress,
    workProgress: p.workProgress,
    workFirst: p.workFirst,
    workFirstOwner: g.workFirstOwner,
    alabaster: p.wares[wtAlabaster],
    turnBuilders: g.turnBuilders,
    finalRoundTriggered: g.finalRoundTriggered,
    finalTriggerReason: g.finalTriggerReason,
  )
  g.phase = phBuild

proc resolveOmenCalamities(g: PegsOfUrGame; omens: int) =
  let pIdx = g.activePlayerIdx
  let pName = g.players[pIdx].name
  if omens <= 1:
    return
  elif omens == 2:
    if g.playerHasAdv(pIdx, "canals"):
      g.addLog(fmt"Blight (2 Omens) averted by {pName}'s Canals!")
    else:
      g.players[pIdx].calamities += 2
      g.addLog(fmt"BLIGHT! (2 Omens) {pName} loses 2 Renown.")
      g.pendingCalamities.add(CalamityAlert(title: "Blight (2 Omens)", detail: fmt"{pName} loses 2 Renown!"))
  elif omens == 3:
    if g.isSolo():
      if g.playerHasAdv(0, "herbalism"):
        g.addLog("Plague (3 Omens) averted by Herbalism!")
      else:
        g.players[0].calamities += 3
        g.addLog(fmt"PLAGUE! (3 Omens, Solo) {pName} loses 3 Renown.")
        g.pendingCalamities.add(CalamityAlert(title: "Plague (3 Omens)", detail: fmt"Solo rule: {pName} loses 3 Renown!"))
    else:
      var victims: seq[string]
      for idx in 0 ..< g.players.len:
        if idx == pIdx:
          continue
        if g.playerHasAdv(idx, "herbalism"):
          g.addLog(fmt"{g.players[idx].name}'s Herbalism warded off Plague.")
        else:
          g.players[idx].calamities += 3
          victims.add(g.players[idx].name)
      if victims.len > 0:
        let msg = victims.join(", ") & " each lose 3 Renown!"
        g.addLog(fmt"PLAGUE! (3 Omens by {pName}) {msg}")
        g.pendingCalamities.add(CalamityAlert(title: "Plague (3 Omens)", detail: msg))
      else:
        g.addLog("Plague (3 Omens) warded off — all rivals hold Herbalism!")
  elif omens == 4:
    let crIdx = getGreatWorkIndex("citadel_ramparts")
    if g.playerCompletedWork(pIdx, crIdx):
      g.addLog(fmt"Raiders (4 Omens) repelled by {pName}'s Citadel Ramparts!")
    else:
      g.players[pIdx].calamities += 4
      g.addLog(fmt"RAIDERS! (4 Omens) {pName} loses 4 Renown.")
      g.pendingCalamities.add(CalamityAlert(title: "Raiders (4 Omens)", detail: fmt"{pName} loses 4 Renown!"))
  else:
    if g.playerHasAdv(pIdx, "priesthood"):
      if g.isSolo():
        g.addLog(fmt"Uprising ({omens} Omens) calmed by {pName}'s Priesthood!")
      else:
        var victims: seq[string]
        for idx in 0 ..< g.players.len:
          if idx == pIdx:
            continue
          if g.playerHasAdv(idx, "priesthood"):
            g.addLog(fmt"{g.players[idx].name}'s Priesthood shielded against Uprising.")
          else:
            for wt in WareType:
              g.players[idx].wares[wt] = 0
            victims.add(g.players[idx].name)
        if victims.len > 0:
          let vJoined = victims.join(", ")
          let msg = fmt"{pName}'s Priesthood turned Uprising upon {vJoined} (all Wares lost)!"
          g.addLog(fmt"ZEALOUS UPRISING! ({omens} Omens) {msg}")
          g.pendingCalamities.add(CalamityAlert(title: fmt"Uprising ({omens} Omens)", detail: msg))
        else:
          g.addLog(fmt"Uprising ({omens} Omens) deflected — all rivals hold Priesthood!")
    else:
      for wt in WareType:
        g.players[pIdx].wares[wt] = 0
      g.addLog(fmt"UPRISING! ({omens} Omens) {pName} lost all stored Wares!")
      g.pendingCalamities.add(CalamityAlert(title: fmt"Uprising ({omens} Omens)", detail: fmt"{pName} loses all stored Wares!"))

proc resolveHarvestFeedCalamities(g: PegsOfUrGame) =
  let pIdx = g.activePlayerIdx
  let hasPlow = g.playerHasAdv(pIdx, "plowshares")
  let hasScaf = g.playerHasAdv(pIdx, "scaffolding")
  let hasCut = g.playerHasAdv(pIdx, "stonecutting")
  let hasMint = g.playerHasAdv(pIdx, "minting")

  var grainGain = 0
  var waresRolled = 0
  var omens = 0
  g.turnBuilders = 0
  g.turnSilver = 0

  for i, f in g.diceFaces:
    case f
    of dfGrain3:
      grainGain += 3 + (if hasPlow: 1 else: 0)
    of dfWare1:
      inc waresRolled
    of dfOmenWares2:
      waresRolled += 2
      inc omens
    of dfBuilders3:
      g.turnBuilders += 3 + (if hasScaf: 1 else: 0)
    of dfGrainOrBuilders2:
      if g.choiceIsBuilders[i]:
        g.turnBuilders += 2 + (if hasScaf: 1 else: 0)
      else:
        grainGain += 2 + (if hasPlow: 1 else: 0)
    of dfSilver7:
      g.turnSilver += (if hasMint: 12 else: 7)

  g.players[pIdx].grain = min(MaxGrain, g.players[pIdx].grain + grainGain)

  var cutBonus = 0
  for n in 0 ..< waresRolled:
    let wt = WareType(n mod 5)
    let maxQ = wareMaxQty(wt)
    g.players[pIdx].wares[wt] = min(maxQ, g.players[pIdx].wares[wt] + 1)
    if wt == wtAlabaster and hasCut and g.players[pIdx].wares[wt] < maxQ:
      inc g.players[pIdx].wares[wt]
      inc cutBonus

  var parts: seq[string]
  if grainGain > 0: parts.add(fmt"+{grainGain} Grain")
  if waresRolled > 0:
    parts.add(if cutBonus > 0: fmt"+{waresRolled} Wares (+{cutBonus} Cut Alabaster)" else: fmt"+{waresRolled} Wares")
  if g.turnBuilders > 0: parts.add(fmt"+{g.turnBuilders} Builders")
  if g.turnSilver > 0: parts.add(fmt"+{g.turnSilver} Silver")
  if omens > 0: parts.add(fmt"{omens} Omen" & (if omens == 1: "" else: "s"))
  if parts.len > 0:
    let pJoined = parts.join(", ")
    g.addLog(fmt"{g.players[pIdx].name} gathered: {pJoined}.")

  let setCnt = g.players[pIdx].settlements
  if g.players[pIdx].grain >= setCnt:
    g.players[pIdx].grain -= setCnt
    g.addLog(fmt"{g.players[pIdx].name} fed {setCnt} settlements ({g.players[pIdx].grain} Grain stored).")
  else:
    let unfed = setCnt - g.players[pIdx].grain
    g.players[pIdx].grain = 0
    g.players[pIdx].calamities += unfed
    g.addLog(fmt"STARVATION! {g.players[pIdx].name} lacked {unfed} Grain (-{unfed} Renown).")
    g.pendingCalamities.add(CalamityAlert(title: "Starvation!", detail: fmt"{g.players[pIdx].name} could not feed {unfed} settlements (-{unfed} Renown)"))

  g.resolveOmenCalamities(omens)
  g.enterBuildPhase()

proc finishRolling*(g: PegsOfUrGame) =
  if g.phase != phRoll:
    return
  let pIdx = g.activePlayerIdx
  let hasPlow = g.playerHasAdv(pIdx, "plowshares")
  var guaranteedGrain = g.players[pIdx].grain
  var hasChoice = false

  for f in g.diceFaces:
    if f == dfGrain3:
      guaranteedGrain += 3 + (if hasPlow: 1 else: 0)
    elif f == dfGrainOrBuilders2:
      hasChoice = true

  if hasChoice:
    var neededGrain = g.players[pIdx].settlements - guaranteedGrain
    for i, f in g.diceFaces:
      if f == dfGrainOrBuilders2:
        if neededGrain > 0:
          g.choiceIsBuilders[i] = false
          neededGrain -= (2 + (if hasPlow: 1 else: 0))
        else:
          g.choiceIsBuilders[i] = true
    g.phase = phAssignChoices
  else:
    g.resolveHarvestFeedCalamities()

proc toggleChoiceDie*(g: PegsOfUrGame; dieIdx: int): bool =
  if g.phase != phAssignChoices or dieIdx < 0 or dieIdx >= g.diceFaces.len:
    return false
  if g.diceFaces[dieIdx] != dfGrainOrBuilders2:
    return false
  g.choiceIsBuilders[dieIdx] = not g.choiceIsBuilders[dieIdx]
  true

proc confirmChoices*(g: PegsOfUrGame) =
  if g.phase == phAssignChoices:
    g.resolveHarvestFeedCalamities()

# ==============================================================================
# BUILD PHASE
# ==============================================================================
proc resetBuildStep*(g: PegsOfUrGame): bool =
  if g.phase != phBuild or not g.buildSnapshot.valid:
    return false
  let pIdx = g.activePlayerIdx
  g.players[pIdx].settlements = g.buildSnapshot.settlements
  g.players[pIdx].settlementProgress = g.buildSnapshot.settlementProgress
  g.players[pIdx].workProgress = g.buildSnapshot.workProgress
  g.players[pIdx].workFirst = g.buildSnapshot.workFirst
  g.workFirstOwner = g.buildSnapshot.workFirstOwner
  g.players[pIdx].wares[wtAlabaster] = g.buildSnapshot.alabaster
  g.turnBuilders = g.buildSnapshot.turnBuilders
  g.finalRoundTriggered = g.buildSnapshot.finalRoundTriggered
  g.finalTriggerReason = g.buildSnapshot.finalTriggerReason
  g.checkEndTriggers()
  true

proc canConvertAlabasterWithCranes*(g: PegsOfUrGame): bool {.inline.} =
  g.phase == phBuild and g.playerHasAdv(g.activePlayerIdx, "cranes") and g.players[g.activePlayerIdx].wares[wtAlabaster] > 0

proc convertAlabasterToBuilders*(g: PegsOfUrGame; units: int = 1): bool =
  if not g.canConvertAlabasterWithCranes():
    return false
  let pIdx = g.activePlayerIdx
  let avail = g.players[pIdx].wares[wtAlabaster]
  let used = clamp(units, 1, avail)
  g.players[pIdx].wares[wtAlabaster] = avail - used
  g.turnBuilders += used * 3
  g.addLog(fmt"{g.players[pIdx].name} used Timber Cranes: {used} Alabaster -> +{used * 3} Builders.")
  true

proc canBuildSettlementBuilder*(g: PegsOfUrGame): bool {.inline.} =
  g.phase == phBuild and g.turnBuilders > 0 and g.players[g.activePlayerIdx].settlements < MaxSettlements

proc addBuilderToSettlement*(g: PegsOfUrGame; count: int = 1): int =
  let pIdx = g.activePlayerIdx
  for _ in 0 ..< count:
    if not g.canBuildSettlementBuilder():
      break
    let slot = g.players[pIdx].settlements - InitialSettlements
    let req = SettlementCosts[slot]
    inc g.players[pIdx].settlementProgress[slot]
    dec g.turnBuilders
    inc result
    if g.players[pIdx].settlementProgress[slot] >= req:
      inc g.players[pIdx].settlements
      if g.players[pIdx].settlements >= MaxSettlements:
        g.addLog(fmt"{g.players[pIdx].name} founded Settlement #{g.players[pIdx].settlements} — Seven Cities milestone (+{SevenCitiesVp} Renown)!")
      else:
        g.addLog(fmt"{g.players[pIdx].name} founded Settlement #{g.players[pIdx].settlements}!")

proc canBuildWorkBuilder*(g: PegsOfUrGame; gwIdx: int): bool =
  if g.phase != phBuild or g.turnBuilders <= 0 or gwIdx < 0 or gwIdx >= GreatWorks.len:
    return false
  isGreatWorkActive(gwIdx, g.players.len) and not g.playerCompletedWork(g.activePlayerIdx, gwIdx)

proc addBuilderToGreatWork*(g: PegsOfUrGame; gwIdx: int; count: int = 1): int =
  let pIdx = g.activePlayerIdx
  for _ in 0 ..< count:
    if not g.canBuildWorkBuilder(gwIdx):
      break
    let gwDef = GreatWorks[gwIdx]
    inc g.players[pIdx].workProgress[gwIdx]
    dec g.turnBuilders
    inc result
    if g.players[pIdx].workProgress[gwIdx] >= gwDef.builders:
      if g.workFirstOwner[gwIdx] == -1:
        g.workFirstOwner[gwIdx] = pIdx
        g.players[pIdx].workFirst[gwIdx] = true
        g.addLog(fmt"{g.players[pIdx].name} was FIRST to raise {gwDef.name} (+{gwDef.vpFirst} Renown)!")
      else:
        g.addLog(fmt"{g.players[pIdx].name} completed {gwDef.name} (+{gwDef.vpLater} Renown).")
      g.checkEndTriggers()

proc finishBuilding*(g: PegsOfUrGame) =
  if g.phase == phBuild:
    g.buildSnapshot.valid = false
    g.enterBuyPhase()

# ==============================================================================
# UNLOCK ADVANCEMENT & DISCARD WARES
# ==============================================================================
proc findOptimalPayment*(g: PegsOfUrGame; pIdx, advIdx: int): PaymentPlan =
  if advIdx < 0 or advIdx >= Advancements.len or g.players[pIdx].advancements[advIdx]:
    return PaymentPlan(valid: false)

  let cost = Advancements[advIdx].cost
  let baseSilver = if pIdx == g.activePlayerIdx: g.turnSilver else: 0
  let p = g.players[pIdx]
  let hasSilos = g.playerHasAdv(pIdx, "silos")
  let maxGrain = if hasSilos: p.grain else: 0

  var bestOverpay = 999999
  var bestGrain = 999999
  var bestWareUnits = 999999
  var bestMask: array[WareType, bool]
  var found = false

  for maskBits in 0 ..< 32:
    var waresVal = 0
    var wareUnits = 0
    for wt in WareType:
      if (maskBits and (1 shl ord(wt))) != 0:
        let q = p.wares[wt]
        if q == 0:
          wareUnits = -1
          break
        waresVal += wareSilverValue(wt, q)
        wareUnits += q
    if wareUnits < 0:
      continue

    let shortfall = cost - (baseSilver + waresVal)
    var grainNeeded = 0
    if shortfall > 0:
      if not hasSilos:
        continue
      grainNeeded = (shortfall + 5) div 6
      if grainNeeded > maxGrain:
        continue

    let paid = baseSilver + waresVal + grainNeeded * 6
    let overpay = paid - cost
    if (not found) or overpay < bestOverpay or
       (overpay == bestOverpay and grainNeeded < bestGrain) or
       (overpay == bestOverpay and grainNeeded == bestGrain and wareUnits < bestWareUnits):
      found = true
      bestOverpay = overpay
      bestGrain = grainNeeded
      bestWareUnits = wareUnits
      for wt in WareType:
        bestMask[wt] = (maskBits and (1 shl ord(wt))) != 0

  if not found:
    return PaymentPlan(valid: false)

  var totalPaid = baseSilver + bestGrain * 6
  for wt in WareType:
    if bestMask[wt]:
      totalPaid += wareSilverValue(wt, p.wares[wt])

  PaymentPlan(
    valid: true,
    cost: cost,
    silverUsed: baseSilver,
    waresMask: bestMask,
    siloGrain: bestGrain,
    totalPaid: totalPaid,
  )

proc buyAdvancement*(g: PegsOfUrGame; advIdx: int; customMask: openArray[bool] = []; siloGrainSpent: int = -1): bool =
  if g.phase != phBuy or g.boughtAdvThisTurn or advIdx < 0 or advIdx >= Advancements.len:
    return false
  let pIdx = g.activePlayerIdx
  if g.players[pIdx].advancements[advIdx]:
    return false

  var mask: array[WareType, bool]
  var grainToSpend = siloGrainSpent
  if customMask.len == 0 or siloGrainSpent < 0:
    let autoPlan = g.findOptimalPayment(pIdx, advIdx)
    if not autoPlan.valid:
      return false
    mask = autoPlan.waresMask
    grainToSpend = autoPlan.siloGrain
  else:
    for wt in WareType:
      if ord(wt) < customMask.len:
        mask[wt] = customMask[ord(wt)]

  if grainToSpend > 0 and not g.playerHasAdv(pIdx, "silos"):
    return false
  if grainToSpend < 0 or grainToSpend > g.players[pIdx].grain:
    return false

  var paid = g.turnSilver + grainToSpend * 6
  var spentParts: seq[string]
  if g.turnSilver > 0:
    spentParts.add(fmt"{g.turnSilver} Silver")

  for wt in WareType:
    if mask[wt]:
      let q = g.players[pIdx].wares[wt]
      if q <= 0:
        return false
      let val = wareSilverValue(wt, q)
      paid += val
      spentParts.add(fmt"{q} {WareNames[wt]} ({val}s)")

  if grainToSpend > 0:
    spentParts.add(fmt"{grainToSpend} Grain ({grainToSpend * 6}s)")

  let advDef = Advancements[advIdx]
  if paid < advDef.cost:
    return false

  for wt in WareType:
    if mask[wt]:
      g.players[pIdx].wares[wt] = 0
  g.players[pIdx].grain -= grainToSpend
  g.turnSilver = 0
  g.players[pIdx].advancements[advIdx] = true
  g.boughtAdvThisTurn = true

  let summary = if spentParts.len > 0: spentParts.join(", ") else: "0s"
  g.addLog(fmt"{g.players[pIdx].name} unlocked {advDef.name} ({advDef.cost}s, +{advDef.vp} Renown) using {summary}.")
  let advCnt = g.playerAdvCount(pIdx)
  if g.firstTo4AdvOwner == -1 and advCnt >= FirstTo4AdvCount:
    g.firstTo4AdvOwner = pIdx
    g.addLog(fmt"{g.players[pIdx].name} was FIRST to {FirstTo4AdvCount} Advancements (+{FirstTo4AdvVp} Renown)!")
  if g.firstTo8AdvOwner == -1 and advCnt >= FirstTo8AdvCount:
    g.firstTo8AdvOwner = pIdx
    g.addLog(fmt"{g.players[pIdx].name} was FIRST to {FirstTo8AdvCount} Advancements (+{FirstTo8AdvVp} Renown)!")
  g.checkEndTriggers()
  g.enterDiscardOrEndTurn()
  true

proc skipBuying*(g: PegsOfUrGame) =
  if g.phase == phBuy:
    g.enterDiscardOrEndTurn()

proc discardOneWare*(g: PegsOfUrGame; wt: WareType): bool =
  if g.phase != phDiscard:
    return false
  let pIdx = g.activePlayerIdx
  if g.players[pIdx].wares[wt] <= 0:
    return false
  dec g.players[pIdx].wares[wt]
  g.addLog(fmt"{g.players[pIdx].name} discarded 1 {WareNames[wt]} (6-Ware storage cap).")
  if g.excessWaresToDiscard(pIdx) <= 0:
    g.finishTurn()
  true

proc computeDicePreview*(g: PegsOfUrGame): string =
  if g.players.len == 0:
    return ""
  let pIdx = g.activePlayerIdx
  let p = g.players[pIdx]
  let hasPlow = g.playerHasAdv(pIdx, "plowshares")
  let hasScaf = g.playerHasAdv(pIdx, "scaffolding")
  let hasMint = g.playerHasAdv(pIdx, "minting")

  var grGain = 0
  var wGain = 0
  var bGain = 0
  var sGain = 0
  var omens = 0

  for i, f in g.diceFaces:
    case f
    of dfGrain3: grGain += 3 + (if hasPlow: 1 else: 0)
    of dfWare1: inc wGain
    of dfOmenWares2:
      wGain += 2
      inc omens
    of dfBuilders3: bGain += 3 + (if hasScaf: 1 else: 0)
    of dfGrainOrBuilders2:
      if i < g.choiceIsBuilders.len and g.choiceIsBuilders[i]:
        bGain += 2 + (if hasScaf: 1 else: 0)
      else:
        grGain += 2 + (if hasPlow: 1 else: 0)
    of dfSilver7: sGain += (if hasMint: 12 else: 7)

  let totGrain = min(MaxGrain, p.grain + grGain)
  let feedNote =
    if totGrain >= p.settlements:
      fmt"Grain: {totGrain}/{p.settlements} Fed"
    else:
      fmt"STARVATION WARNING: {totGrain}/{p.settlements} (-{p.settlements - totGrain} VP)"

  let omenNote =
    case omens
    of 0: "0 Omens"
    of 1: "1 Omen (Safe)"
    of 2:
      if g.playerHasAdv(pIdx, "canals"): "2 Omens: Blight (Blocked)" else: "2 Omens: Blight (-2 VP!)"
    of 3:
      if g.isSolo(): "3 Omens: Plague (-3 VP Solo!)" else: "3 Omens: Plague (-3 VP Rivals!)"
    of 4:
      let cr = getGreatWorkIndex("citadel_ramparts")
      if g.playerCompletedWork(pIdx, cr): "4 Omens: Raiders (Blocked)" else: "4 Omens: Raiders (-4 VP!)"
    else:
      if g.playerHasAdv(pIdx, "priesthood"): fmt"{omens} Omens: Uprising (Hits Rivals!)" else: fmt"{omens} Omens: Uprising (Lose Wares!)"

  fmt"Preview: +{grGain} Grain, +{wGain} Wares, +{bGain} Builders, +{sGain} Silver  •  {feedNote}  •  {omenNote}"
