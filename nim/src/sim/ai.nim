## Step-by-step AI controller for Easy, Normal, and Hard Pegs of Ur opponents.

import data, game

proc stepRoll(g: PegsOfUrGame; pIdx: int; diff: SeatType) =
  let p = g.players[pIdx]
  let sets = p.settlements
  let hasPlow = g.playerHasAdv(pIdx, "plowshares")
  let hasCanals = g.playerHasAdv(pIdx, "canals")
  let hasPriest = g.playerHasAdv(pIdx, "priesthood")
  let crIdx = getGreatWorkIndex("citadel_ramparts")
  let hasRamparts = g.playerCompletedWork(pIdx, crIdx)

  var omens = 0
  var projGrain = p.grain
  for f in g.diceFaces:
    case f
    of dfOmenWares2: inc omens
    of dfGrain3: projGrain += 3 + (if hasPlow: 1 else: 0)
    of dfGrainOrBuilders2: projGrain += 2 + (if hasPlow: 1 else: 0)
    else: discard

  if g.canUseDivination() and g.rollsUsed >= g.maxRolls:
    let badOmen =
      (omens == 2 and not hasCanals) or
      (omens == 3 and g.isSolo() and not g.playerHasAdv(pIdx, "herbalism")) or
      (omens == 4 and not hasRamparts) or
      (omens >= 5 and not hasPriest)
    if badOmen:
      for i, f in g.diceFaces:
        if f == dfOmenWares2:
          discard g.rerollSingleWithDivination(i)
          return
    if projGrain < sets and diff != stAiEasy:
      for i, f in g.diceFaces:
        if f notin {dfGrain3, dfGrainOrBuilders2}:
          discard g.rerollSingleWithDivination(i)
          return

  if g.rollsUsed < g.maxRolls:
    var wantReroll = false
    var grainRunning = p.grain
    let curWaresVal = g.playerWaresSilverValue(pIdx)

    for i in 0 ..< g.diceFaces.len:
      g.diceSelectedForReroll[i] = false
      if not g.canDieBeToggledForReroll(i):
        continue
      let f = g.diceFaces[i]
      var rerollThis = false

      if diff == stAiEasy:
        if projGrain < sets and f == dfWare1:
          rerollThis = true
        elif f == dfGrain3 and grainRunning >= sets + 3:
          rerollThis = true
      else:
        if f == dfOmenWares2 and g.isSolo() and omens >= 2:
          rerollThis = true
        elif projGrain < sets:
          if f notin {dfGrain3, dfGrainOrBuilders2}:
            if not (f == dfSilver7 and curWaresVal >= 8 and diff == stAiHard):
              rerollThis = true
          else:
            grainRunning += 3
        else:
          if f == dfGrain3:
            if grainRunning >= sets + 2 and not g.playerHasAdv(pIdx, "silos"):
              rerollThis = true
            else:
              grainRunning += 3 + (if hasPlow: 1 else: 0)
          elif f == dfWare1 and g.playerTotalWares(pIdx) >= 5 and not g.playerHasAdv(pIdx, "merchant_fleets"):
            rerollThis = true

        if not g.isSolo() and omens == 3:
          rerollThis = false

      if rerollThis:
        g.diceSelectedForReroll[i] = true
        wantReroll = true

    if wantReroll and g.rerollSelectedDice():
      return

  g.finishRolling()

proc stepAssignChoices(g: PegsOfUrGame; pIdx: int) =
  let p = g.players[pIdx]
  let hasPlow = g.playerHasAdv(pIdx, "plowshares")
  let hasSilos = g.playerHasAdv(pIdx, "silos")
  var grain = p.grain
  for f in g.diceFaces:
    if f == dfGrain3:
      grain += 3 + (if hasPlow: 1 else: 0)

  for i, f in g.diceFaces:
    if f == dfGrainOrBuilders2:
      if grain < p.settlements or (hasSilos and p.settlements >= 5 and g.turnSilver >= 12):
        g.choiceIsBuilders[i] = false
        grain += 2 + (if hasPlow: 1 else: 0)
      else:
        g.choiceIsBuilders[i] = true
  g.confirmChoices()

proc stepBuild(g: PegsOfUrGame; pIdx: int; diff: SeatType) =
  if g.canConvertAlabasterWithCranes():
    let alabQty = g.players[pIdx].wares[wtAlabaster]
    let alabVal = wareSilverValue(wtAlabaster, alabQty)
    if alabQty <= 2 or (g.turnSilver + g.playerWaresSilverValue(pIdx) - alabVal >= 30) or g.finalRoundTriggered:
      discard g.convertAlabasterToBuilders(alabQty)
      return

  while g.turnBuilders > 0:
    let sets = g.players[pIdx].settlements
    var targetSets = if diff == stAiEasy: 5 else: 6
    if diff == stAiHard or g.playerHasAdv(pIdx, "plowshares"):
      targetSets = MaxSettlements

    var bestSnatch = -1
    var bestSnatchRatio = -1.0
    let doneWorks = g.playerCompletedWorkCount(pIdx)
    for gwIdx in 0 ..< GreatWorks.len:
      if not g.canBuildWorkBuilder(gwIdx):
        continue
      let rem = GreatWorks[gwIdx].builders - g.players[pIdx].workProgress[gwIdx]
      if rem <= g.turnBuilders:
        var vp = if g.workFirstOwner[gwIdx] == -1: GreatWorks[gwIdx].vpFirst else: GreatWorks[gwIdx].vpLater
        if g.playerHasAdv(pIdx, "urban_planning"):
          vp += 2
        if doneWorks == MasterBuilderWorkCount - 1:
          vp += MasterBuilderVp
        let ratio = float(vp) / float(max(1, rem))
        if vp > 0 and ratio > bestSnatchRatio:
          bestSnatchRatio = ratio
          bestSnatch = gwIdx

    if bestSnatch >= 0 and (bestSnatchRatio >= 0.75 or g.finalRoundTriggered or sets >= targetSets):
      let rem = GreatWorks[bestSnatch].builders - g.players[pIdx].workProgress[bestSnatch]
      discard g.addBuilderToGreatWork(bestSnatch, rem)
      continue

    if sets < targetSets and g.canBuildSettlementBuilder() and (not g.finalRoundTriggered or sets == MaxSettlements - 1 or g.playerHasAdv(pIdx, "hegemony")):
      discard g.addBuilderToSettlement(1)
      continue

    var bestGw = -1
    var bestScore = -1.0
    for gwIdx in 0 ..< GreatWorks.len:
      if not g.canBuildWorkBuilder(gwIdx):
        continue
      let gwDef = GreatWorks[gwIdx]
      let prog = g.players[pIdx].workProgress[gwIdx]
      let rem = gwDef.builders - prog
      var vp = if g.workFirstOwner[gwIdx] == -1: gwDef.vpFirst else: gwDef.vpLater
      if g.playerHasAdv(pIdx, "urban_planning"):
        vp += 2
      if vp <= 0:
        continue
      var score = float(vp) / float(rem)
      if prog > 0:
        score *= 1.35
      if gwDef.id == "citadel_ramparts" and diff == stAiHard and sets >= 5:
        score *= 1.15
      if score > bestScore:
        bestScore = score
        bestGw = gwIdx

    if bestGw >= 0:
      discard g.addBuilderToGreatWork(bestGw, 1)
    elif g.canBuildSettlementBuilder():
      discard g.addBuilderToSettlement(1)
    else:
      break

  g.finishBuilding()

proc stepBuy(g: PegsOfUrGame; pIdx: int; diff: SeatType) =
  var bestAdv = -1
  var bestScore = -999.0
  let earlyFactor = clamp(1.5 - float(g.roundNumber) * 0.12, 0.3, 1.4)

  for aIdx in 0 ..< Advancements.len:
    if g.players[pIdx].advancements[aIdx]:
      continue
    let plan = g.findOptimalPayment(pIdx, aIdx)
    if not plan.valid:
      continue

    let aDef = Advancements[aIdx]
    let overpay = float(plan.totalPaid - plan.cost)
    var utility = float(aDef.vp) * 2.2 - overpay * 0.22
    let nextAdvCnt = g.playerAdvCount(pIdx) + 1
    if g.firstTo4AdvOwner == -1 and nextAdvCnt == FirstTo4AdvCount:
      utility += float(FirstTo4AdvVp) * 2.2
    if g.firstTo8AdvOwner == -1 and nextAdvCnt == FirstTo8AdvCount:
      utility += float(FirstTo8AdvVp) * 2.2

    case aDef.id
    of "divination", "minting": utility += 5.5 * earlyFactor
    of "plowshares": utility += 6.5 * earlyFactor
    of "stonecutting": utility += 6.0 * earlyFactor
    of "scaffolding": utility += 6.2 * earlyFactor
    of "merchant_fleets": utility += 3.0 * earlyFactor
    of "canals": utility += 2.2 * earlyFactor
    of "herbalism": utility += (if g.isSolo(): 4.2 else: 3.8) * earlyFactor
    of "priesthood": utility += 4.0
    of "silos":
      if g.playerHasAdv(pIdx, "plowshares"):
        utility += 4.5 * earlyFactor
    of "cranes":
      utility += (if g.playerHasAdv(pIdx, "stonecutting"): 6.5 else: 3.0) * earlyFactor
    of "urban_planning":
      utility += float(g.playerCompletedWorkCount(pIdx)) * 4.4 + 4.0
    of "hegemony":
      utility += float(g.players[pIdx].settlements) * 2.2 + 4.0
    else: discard

    if diff == stAiEasy:
      utility += float(aIdx) * 0.12
    elif diff == stAiHard and overpay > 12.0 and aDef.cost <= 15 and not g.finalRoundTriggered:
      utility -= 8.0

    if utility > bestScore:
      bestScore = utility
      bestAdv = aIdx

  if bestAdv >= 0 and bestScore > 1.5:
    discard g.buyAdvancement(bestAdv)
  else:
    g.skipBuying()

proc stepDiscard(g: PegsOfUrGame; pIdx: int) =
  var bestWare = wtTimber
  var minLoss = 999999
  var found = false
  for wt in WareType:
    let q = g.players[pIdx].wares[wt]
    if q > 0:
      let loss = wareSilverValue(wt, q) - wareSilverValue(wt, q - 1)
      if not found or loss < minLoss:
        found = true
        minLoss = loss
        bestWare = wt
  if found:
    discard g.discardOneWare(bestWare)

proc takeStep*(g: PegsOfUrGame) =
  if g.phase in {phSetup, phGameOver} or g.players.len == 0:
    return
  let pIdx = g.activePlayerIdx
  let diff = g.players[pIdx].seatType
  case g.phase
  of phRoll: stepRoll(g, pIdx, diff)
  of phAssignChoices: stepAssignChoices(g, pIdx)
  of phBuild: stepBuild(g, pIdx, diff)
  of phBuy: stepBuy(g, pIdx, diff)
  of phDiscard: stepDiscard(g, pIdx)
  else: discard
