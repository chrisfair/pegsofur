## Comprehensive unit, TPM/Timer entropy, rules, AI, physics, and UI presenter test suite.

import std/[math, strutils, unittest]
import sim/[data, entropy, game, ai, physics, presenter]

proc make4pGame(seed: int64 = 42): PegsOfUrGame =
  result = newPegsOfUrGame(seed)
  result.startGame([
    SeatConfig(name: "Ur", seatType: stHuman, color: RealmDefaults[0].color),
    SeatConfig(name: "Byblos", seatType: stHuman, color: RealmDefaults[1].color),
    SeatConfig(name: "Knossos", seatType: stHuman, color: RealmDefaults[2].color),
    SeatConfig(name: "Thebes", seatType: stHuman, color: RealmDefaults[3].color),
  ])

proc makeSoloGame(seed: int64 = 99): PegsOfUrGame =
  result = newPegsOfUrGame(seed)
  result.startGame([
    SeatConfig(name: "Ur", seatType: stHuman, color: RealmDefaults[0].color),
  ])

suite "Pegs of Ur Static Data & Pegboard Ladders":
  test "Ware values, max quantities, Great Work player-count filtering, and helpers":
    check wareSilverValue(wtTimber, 8) == 36
    check wareSilverValue(wtAlabaster, 7) == 56
    check wareSilverValue(wtCeramics, 6) == 63
    check wareSilverValue(wtLinen, 5) == 60
    check wareSilverValue(wtIngots, 4) == 50

    var c1 = 0
    var c2 = 0
    var c3 = 0
    var c4 = 0
    for i in 0 ..< GreatWorks.len:
      if isGreatWorkActive(i, 1): inc c1
      if isGreatWorkActive(i, 2): inc c2
      if isGreatWorkActive(i, 3): inc c3
      if isGreatWorkActive(i, 4): inc c4
    check c1 == 7 and c4 == 7
    check c2 == 5
    check c3 == 6

    check getGreatWorkIndex("citadel_ramparts") == 5
    check getGreatWorkIndex("nonexistent") == -1
    check getAdvancementIndex("divination") == 0
    check getAdvancementIndex("nonexistent") == -1

    for df in DieFace:
      check dieFaceLabel(df).len > 0
    for st in SeatType:
      check seatShortTag(st).len > 0
    for spd in AiSpeedKind:
      check aiSpeedDelay(spd) > 0.0
      check aiSpeedLabel(spd).len > 0
    for ph in Phase:
      check ($ph).len > 0
    for mk in ModalKind:
      check ($mk).len > 0
    for ak in AudioCueKind:
      check ($ak).len > 0
    for wt in WareType:
      check ($wt).len > 0
    check rgba(0.5'f32, 0.4'f32, 0.3'f32).a == 1.0'f32

    let rc = uiRect(10.0, 20.0, 100.0, 50.0)
    check rc.contains(50.0, 40.0)
    check not rc.contains(5.0, 40.0)

suite "Hardware TPM 2.0 TRNG & System Timer Fallback":
  test "Direct TPM2_GetRandom, multi-burst refill, and inaccessible/missing TPM -> System Timer fallback":
    var emptyBuf: array[0, uint8]
    check tpm2GetRandomBytes(emptyBuf) == 0
    check systemTimerSeed64() > 0
    check systemTimerSeed64() != systemTimerSeed64()

    let hwPool = newEntropyPool(-1)
    check entropySourceLabel(hwPool).len > 0
    for es in EntropySourceKind:
      check ($es).len > 0

    var faceCounts: array[DieFace, int]
    for _ in 0 ..< 360:
      let f = hwPool.rollDieFace()
      inc faceCounts[f]
    for df in DieFace:
      check faceCounts[df] > 15

    # Simulate missing or permission-denied TPM -> must fall back to System Timer PRNG
    let timerFallback = newEntropyPool(-1, "/dev/nonexistent_or_unreadable_tpm")
    check timerFallback.source == esSystemTimer
    check entropySourceLabel(timerFallback) == "System Timer Seed"
    discard timerFallback.nextByte()
    var timerCounts: array[DieFace, int]
    for _ in 0 ..< 240:
      inc timerCounts[timerFallback.rollDieFace()]
    for df in DieFace:
      check timerCounts[df] > 10

    check hardwareOrTimerSeed64() > 0
    check hardwareOrTimerSeed64("/dev/nonexistent_or_unreadable_tpm") > 0

    let detPool = newEntropyPool(12345)
    check detPool.source == esDeterministicSeed
    check entropySourceLabel(detPool) == "Deterministic Test Seed"
    discard detPool.nextByte()

    # Verify default unseeded games produce distinct opening rolls (both default & timer fallback)
    let seats = [SeatConfig(name: "Ur", seatType: stHuman, color: RealmDefaults[0].color)]
    var distinctHw = false
    let gA = newPegsOfUrGame()
    gA.startGame(seats)
    for _ in 0 ..< 6:
      let gB = newPegsOfUrGame()
      gB.startGame(seats)
      if gB.diceFaces != gA.diceFaces:
        distinctHw = true
        break
    check distinctHw

    var distinctTimer = false
    let tA = newPegsOfUrGame(-1, "/dev/nonexistent_or_unreadable_tpm")
    tA.startGame(seats)
    for _ in 0 ..< 6:
      let tB = newPegsOfUrGame(-1, "/dev/nonexistent_or_unreadable_tpm")
      tB.startGame(seats)
      if tB.diceFaces != tA.diceFaces:
        distinctTimer = true
        break
    check distinctTimer

    let trayDefault = newDiceTraySim()
    check trayDefault.hoveredDie == -1
    let presDefault = newPegsOfUrPresenter()
    check presDefault.game.players.len == 4

suite "Core Pegs of Ur Rules Engine":
  test "Omen locking, selectAllRerollable, normal rerolls, and Divination":
    let g = make4pGame()
    g.diceFaces = @[dfOmenWares2, dfGrain3, dfWare1]
    check not g.canDieBeToggledForReroll(0)
    check not g.canDieBeToggledForReroll(-1)
    check not g.canDieBeToggledForReroll(99)
    check g.canDieBeToggledForReroll(1)
    check not g.toggleDieForReroll(0)
    check g.toggleDieForReroll(1)
    check g.canRerollSelected()
    check g.rerollSelectedDice()
    check g.rollsUsed == 2

    g.selectAllRerollable()
    g.selectAllRerollable()
    g.selectAllRerollable()
    if g.canRerollSelected():
      check g.rerollSelectedDice()

    let divIdx = getAdvancementIndex("divination")
    g.players[0].advancements[divIdx] = true
    g.diceFaces[0] = dfOmenWares2
    check g.canUseDivination()
    check not g.rerollSingleWithDivination(-1)
    check g.rerollSingleWithDivination(0)
    check not g.canUseDivination()

    let solo = makeSoloGame()
    solo.diceFaces = @[dfOmenWares2, dfGrain3, dfWare1]
    check solo.canDieBeToggledForReroll(0)

  test "Gathering, Stonecutting, Plowshares, Scaffolding, Minting, and Choice Dice":
    let g = make4pGame()
    g.players[0].settlements = 5
    g.players[0].grain = 1
    for id in ["plowshares", "scaffolding", "stonecutting", "minting", "canals"]:
      g.players[0].advancements[getAdvancementIndex(id)] = true

    g.diceFaces = @[
      dfGrain3,
      dfGrainOrBuilders2,
      dfGrainOrBuilders2,
      dfBuilders3,
      dfSilver7,
      dfOmenWares2,
      dfOmenWares2,
      dfWare1,
      dfWare1,
    ]
    g.choiceIsBuilders = @[true, true, true, true, true, true, true, true, true]
    g.finishRolling()
    check g.phase == phAssignChoices
    check "Preview:" in g.computeDicePreview()
    check not g.toggleChoiceDie(0)
    check g.toggleChoiceDie(1)
    check g.toggleChoiceDie(1)
    g.choiceIsBuilders[1] = false
    g.choiceIsBuilders[2] = true
    g.confirmChoices()

    check g.players[0].grain == 3
    check g.turnBuilders == 7
    check g.turnSilver == 12
    check g.players[0].wares == [2, 2, 1, 1, 1]

  test "Starvation and all Omen Calamities (0..6 Omens, Multiplayer & Solo)":
    let g2 = make4pGame()
    g2.players[0].grain = 1
    g2.diceFaces = @[dfOmenWares2, dfOmenWares2, dfWare1]
    check "STARVATION WARNING" in g2.computeDicePreview()
    check "Blight" in g2.computeDicePreview()
    g2.finishRolling()
    check g2.players[0].calamities == 4

    let g1 = make4pGame()
    g1.diceFaces = @[dfOmenWares2, dfGrain3, dfWare1]
    check "1 Omen (Safe)" in g1.computeDicePreview()

    let g3 = make4pGame()
    g3.players[1].advancements[getAdvancementIndex("herbalism")] = true
    g3.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2]
    check "Plague" in g3.computeDicePreview()
    g3.finishRolling()
    check g3.players[0].calamities == 0
    check g3.players[1].calamities == 0
    check g3.players[2].calamities == 3

    let g3AllHerb = make4pGame()
    for idx in 1 .. 3:
      g3AllHerb.players[idx].advancements[getAdvancementIndex("herbalism")] = true
    g3AllHerb.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2]
    g3AllHerb.finishRolling()
    check g3AllHerb.players[2].calamities == 0

    let gs = makeSoloGame()
    gs.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2]
    check "Solo" in gs.computeDicePreview()
    gs.finishRolling()
    check gs.players[0].calamities == 3

    let gsHerb = makeSoloGame()
    gsHerb.players[0].advancements[getAdvancementIndex("herbalism")] = true
    gsHerb.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2]
    gsHerb.finishRolling()
    check gsHerb.players[0].calamities == 0

    let g4 = make4pGame()
    g4.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2]
    check "Raiders" in g4.computeDicePreview()
    g4.finishRolling()
    check g4.players[0].calamities == 4

    let g4Wall = make4pGame()
    g4Wall.players[0].workProgress[getGreatWorkIndex("citadel_ramparts")] = 13
    g4Wall.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2]
    g4Wall.finishRolling()
    check g4Wall.players[0].calamities == 0

    let g5Plain = make4pGame()
    g5Plain.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2]
    check "Uprising" in g5Plain.computeDicePreview()
    g5Plain.finishRolling()
    check g5Plain.playerTotalWares(0) == 0

    let g5Pr = make4pGame()
    let prIdx = getAdvancementIndex("priesthood")
    g5Pr.players[0].advancements[prIdx] = true
    g5Pr.players[1].advancements[prIdx] = true
    g5Pr.players[1].wares[wtTimber] = 2
    g5Pr.players[2].wares[wtAlabaster] = 3
    g5Pr.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2]
    g5Pr.finishRolling()
    check g5Pr.playerTotalWares(0) > 0
    check g5Pr.playerTotalWares(1) == 2
    check g5Pr.playerTotalWares(2) == 0

    let gsPr = makeSoloGame()
    gsPr.players[0].advancements[prIdx] = true
    gsPr.diceFaces = @[dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2, dfOmenWares2]
    gsPr.finishRolling()
    check gsPr.playerTotalWares(0) > 0

  test "Build Phase, Timber Cranes, Reset Undo, Great Work First/Later, and All-Works Trigger":
    let g = make4pGame()
    g.players[0].advancements[getAdvancementIndex("cranes")] = true
    g.players[0].wares[wtAlabaster] = 2
    g.diceFaces = @[dfBuilders3, dfGrain3, dfSilver7]
    g.finishRolling()
    check g.phase == phBuild
    check g.convertAlabasterToBuilders(1)
    check g.turnBuilders == 6
    check g.addBuilderToSettlement(3) == 3
    check g.players[0].settlements == 4
    check g.addBuilderToGreatWork(0, 3) == 3
    check g.workFirstOwner[0] == 0

    check g.resetBuildStep()
    check g.players[0].settlements == 3
    check g.workFirstOwner[0] == -1
    check g.turnBuilders == 3

    g.workFirstOwner = [0, 0, 0, 0, 0, 0, -1]
    g.turnBuilders = 15
    check g.addBuilderToGreatWork(6, 15) == 15
    check g.finalRoundTriggered
    g.finishBuilding()

  test "Advancement Whole-Track Solver, Royal Silos, Custom Pay, and Storage Cap":
    let g = make4pGame()
    g.players[0].advancements[getAdvancementIndex("silos")] = true
    g.players[0].grain = 6
    g.players[0].wares = [3, 2, 2, 1, 0]
    g.diceFaces = @[dfSilver7, dfSilver7, dfSilver7]
    g.finishRolling()
    check g.phase == phBuy

    let scafIdx = getAdvancementIndex("scaffolding")
    check not g.buyAdvancement(scafIdx, [false, false, false, false, false], 0)
    check g.buyAdvancement(scafIdx, [false, false, true, false, false], 0)
    check g.players[0].wares[wtCeramics] == 0
    check g.activePlayerIdx == 1

    g.players[1].wares = [4, 3, 0, 0, 0]
    g.diceFaces = @[dfGrain3, dfGrain3, dfGrain3]
    g.finishRolling()
    if g.phase == phBuy:
      g.skipBuying()
    check g.phase == phDiscard
    check not g.discardOneWare(wtIngots)
    check g.discardOneWare(wtTimber)
    check g.activePlayerIdx == 2

    g.players[2].advancements[getAdvancementIndex("merchant_fleets")] = true
    g.players[2].wares = [4, 4, 0, 0, 0]
    check g.excessWaresToDiscard(2) == 0

  test "Scoring Bonuses (Urban Planning, Hegemony, All 6 Milestones) and Tiebreaker Sorting":
    let g = make4pGame()
    g.players[0].settlements = 5
    g.players[0].workProgress[0] = 3
    g.players[0].workFirst[0] = true
    g.players[0].workProgress[1] = 5
    for id in ["divination", "canals", "plowshares", "urban_planning", "hegemony"]:
      g.players[0].advancements[getAdvancementIndex(id)] = true

    let sb = g.computeScoreBreakdown(0)
    check sb.worksVp == 2
    check sb.advancementsVp == 25
    # Urban Planning (2*2=4) + Hegemony (5) + Unscathed Realm (3) = 12
    check sb.milestonesVp == UnscathedRealmVp
    check sb.bonusVp == 12
    check sb.totalVp == 39

    # Exercise all 6 milestones: Seven Cities (+3), Unscathed (+3), Master Trader (+2*2=4),
    # Master Builder (+3), First to 4 Adv (+2), First to 8 Adv (+5) => 20 milestone VP.
    g.players[0].settlements = MaxSettlements
    g.players[0].workProgress[2] = GreatWorks[2].builders
    g.players[0].wares[wtTimber] = wareMaxQty(wtTimber)
    g.players[0].wares[wtIngots] = wareMaxQty(wtIngots)
    g.firstTo4AdvOwner = 0
    g.firstTo8AdvOwner = 0
    let sbAll = g.computeScoreBreakdown(0)
    check sbAll.milestonesVp == SevenCitiesVp + UnscathedRealmVp + 2 * MasterTraderPerTrackVp + MasterBuilderVp + FirstTo4AdvVp + FirstTo8AdvVp

    # Losing Unscathed when taking a calamity drops milestone VP by 3.
    g.players[0].calamities = 1
    check g.computeScoreBreakdown(0).milestonesVp == sbAll.milestonesVp - UnscathedRealmVp

    # Verify live first-to-4 and first-to-8 advancement triggers via buyAdvancement.
    let gAdv = make4pGame()
    for i in 0 ..< 8:
      gAdv.activePlayerIdx = 0
      gAdv.phase = phBuy
      gAdv.boughtAdvThisTurn = false
      gAdv.turnSilver = 100
      check gAdv.buyAdvancement(i)
    check gAdv.firstTo4AdvOwner == 0
    check gAdv.firstTo8AdvOwner == 0
    check gAdv.finalRoundTriggered

    # Verify 3D face target Euler angles exist for all 6 faces.
    for df in DieFace:
      let (rx, rz) = faceTargetEuler(df)
      check rx >= -PI and rx <= PI
      check rz >= -PI and rz <= PI

    let gt = make4pGame()
    gt.players[0].wares[wtTimber] = 1
    gt.players[1].wares[wtIngots] = 2
    let st = gt.getStandings()
    check st[0].playerIdx == 1

suite "AI Simulation, Physics Tray, Pegboard, and UI Presenter":
  test "Complete 1P Solo and 4P AI Full Matches":
    let solo = newPegsOfUrGame(101)
    solo.startGame([SeatConfig(name: "Solo Ur", seatType: stAiHard, color: RealmDefaults[0].color)])
    var steps = 0
    while solo.phase != phGameOver and steps < 2000:
      takeStep(solo)
      inc steps
    check solo.phase == phGameOver
    check solo.roundNumber <= SoloMaxRounds

    let aiDiv = newPegsOfUrGame(77)
    aiDiv.startGame([
      SeatConfig(name: "Ur", seatType: stAiHard, color: RealmDefaults[0].color),
      SeatConfig(name: "Byblos", seatType: stAiNormal, color: RealmDefaults[1].color),
    ])
    aiDiv.players[0].advancements[getAdvancementIndex("divination")] = true
    aiDiv.rollsUsed = 3
    aiDiv.diceFaces = @[dfOmenWares2, dfOmenWares2, dfBuilders3]
    takeStep(aiDiv)
    check aiDiv.divinationUsed

    aiDiv.divinationUsed = false
    aiDiv.players[0].grain = 0
    aiDiv.diceFaces = @[dfBuilders3, dfSilver7, dfWare1]
    takeStep(aiDiv)
    check aiDiv.divinationUsed

    let multi = newPegsOfUrGame(2026)
    multi.startGame([
      SeatConfig(name: "Ur", seatType: stAiHard, color: RealmDefaults[0].color),
      SeatConfig(name: "Byblos", seatType: stAiNormal, color: RealmDefaults[1].color),
      SeatConfig(name: "Knossos", seatType: stAiEasy, color: RealmDefaults[2].color),
      SeatConfig(name: "Thebes", seatType: stAiHard, color: RealmDefaults[3].color),
    ])
    steps = 0
    while multi.phase != phGameOver and steps < 5000:
      if steps == 1:
        multi.players[0].advancements[getAdvancementIndex("divination")] = true
      takeStep(multi)
      inc steps
    check multi.phase == phGameOver
    check multi.finalRoundTriggered

  test "Wooden Dice Tray 3D Bounce, Collisions, and Pegboard Lerp":
    let tray = newDiceTraySim(1234)
    var audio: seq[AudioEvent]
    tray.triggerRoll([0, 1, 2, 3, 4], [dfOmenWares2, dfGrain3, dfBuilders3, dfSilver7, dfWare1])
    check tray.isAnimating()

    tray.dice[0].delay = 0.0
    tray.dice[1].delay = 0.0
    tray.dice[0].posX = 700.0
    tray.dice[0].posY = 180.0
    tray.dice[0].z = 12.0
    tray.dice[0].velX = 180.0
    tray.dice[1].posX = 720.0
    tray.dice[1].posY = 180.0
    tray.dice[1].z = 12.0
    tray.dice[1].velX = -180.0

    for _ in 0 ..< 140:
      tray.stepTray(0.02, audio)
    check not tray.isAnimating()
    check audio.len > 0
    check tray.dieAt(tray.dice[0].posX, tray.dice[0].posY) == 0
    check tray.dieAt(5.0, 5.0) == -1

    let pb = newPegboardSim()
    pb.syncPegboard(0, 3, [0, 0, 0, 0, 0], audio)
    pb.stepPegboard(0.016)
    pb.syncPegboard(0, 5, [2, 1, 0, 0, 0], audio)
    for _ in 0 ..< 20:
      pb.stepPegboard(0.02)
    let (hx, hy) = pb.wareHoleCenter(wtTimber, 0)
    check pb.wareRowAt(hx, hy) == ord(wtTimber)
    check pb.wareRowAt(2.0, 2.0) == -1

  test "Presenter Modals, Buttons, Custom Pay Drawer, Dice/Peg Clicks, Scroll, and AI Ticks":
    let p = newPegsOfUrPresenter(1680.0, 960.0, seed = 555, showSetupModal = true)
    check p.modal == mkSetup

    for act in [baCycleSeatRealmName, baCycleSeatType, baPresetSolo, baPresetDuel, baPresetClassic4P]:
      for b in p.buttons:
        if b.action == act:
          check p.onMouseClick(b.rect.x + 5.0, b.rect.y + 5.0)
          break

    for i in 0 .. 3:
      p.seatConfigs[i].seatType = stClosed
    p.rebuildButtons()
    for b in p.buttons:
      if b.action == baStartConfiguredMatch:
        check p.onMouseClick(b.rect.x + 5.0, b.rect.y + 5.0)
        break
    check p.setupError.len > 0

    for b in p.buttons:
      if b.action == baPresetDuel:
        discard p.onMouseClick(b.rect.x + 5.0, b.rect.y + 5.0)
        break
    for b in p.buttons:
      if b.action == baStartConfiguredMatch:
        check p.onMouseClick(b.rect.x + 5.0, b.rect.y + 5.0)
        break
    check p.modal == mkNone

    for _ in 0 ..< 120:
      p.tick(0.02)
    discard p.popAudioEvents()

    for act in [baOpenRules, baCloseModal, baToggleAudio, baToggleAudio, baCycleAiSpeed, baSelectPlayerTab, baFollowActiveTurn]:
      p.rebuildButtons()
      for b in p.buttons:
        if b.action == act:
          p.onMouseMove(b.rect.x + 4.0, b.rect.y + 4.0)
          discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
          break

    let aa = p.advancementsAreaRect()
    check p.onMouseWheel(aa.x + 20.0, aa.y + 20.0, 2.0)
    check p.onMouseWheel(aa.x + 20.0, aa.y + 20.0, -2.0)

    p.game.players[0].advancements[getAdvancementIndex("divination")] = true
    p.game.diceFaces = @[dfGrainOrBuilders2, dfBuilders3, dfSilver7]
    p.syncFromGame()
    for _ in 0 ..< 90: p.tick(0.02)
    p.rebuildButtons()

    let d0x = p.tray.dice[0].posX
    let d0y = p.tray.dice[0].posY
    p.onMouseMove(d0x, d0y)
    check p.onMouseClick(d0x, d0y)

    for b in p.buttons:
      if b.action == baToggleDivination:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check p.divinationArmed
    check p.onMouseClick(d0x, d0y)
    for _ in 0 ..< 90: p.tick(0.02)

    p.game.diceFaces = @[dfGrainOrBuilders2, dfBuilders3, dfSilver7]
    p.game.choiceIsBuilders = @[true, true, true]
    p.syncFromGame()
    p.rebuildButtons()
    for b in p.buttons:
      if b.action == baKeepDiceAndHarvest:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check p.game.phase == phAssignChoices
    check p.onMouseClick(p.tray.dice[0].posX, p.tray.dice[0].posY)
    for b in p.buttons:
      if b.action == baFlipChoiceDie:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    for b in p.buttons:
      if b.action == baConfirmChoices:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break

    check p.game.phase == phBuild
    p.game.players[0].advancements[getAdvancementIndex("cranes")] = true
    p.game.players[0].wares[wtAlabaster] = 2
    p.game.players[0].advancements[getAdvancementIndex("silos")] = true
    p.game.players[0].grain = 5
    p.game.players[0].wares[wtCeramics] = 3
    p.syncFromGame()
    p.rebuildButtons()
    for act in [baConvertCranes, baBuildSettlementOne, baBuildWorkOne, baBuildWorkBulk, baResetBuild, baBuildSettlementFinish, baFinishBuilding]:
      p.rebuildButtons()
      for b in p.buttons:
        if b.action == act:
          discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
          break

    check p.game.phase == phBuy
    p.rebuildButtons()
    for b in p.buttons:
      if b.action == baSelectAdvCustomPay:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check p.selectedBuyAdv >= 0
    let (chx, chy) = p.pegboard.wareHoleCenter(wtCeramics, 1)
    discard p.onMouseClick(chx, chy)
    for act in [baToggleBuyWareRow, baSiloPlus, baSiloMinus, baCancelCustomBuy]:
      p.rebuildButtons()
      for b in p.buttons:
        if b.action == act and b.enabled:
          discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
          break

    p.selectAdvForCustomPay(getAdvancementIndex("canals"))
    p.rebuildButtons()
    for b in p.buttons:
      if b.action == baConfirmCustomBuy and b.enabled:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break

    p.aiSpeed = asFast
    for _ in 0 ..< 220:
      p.tick(0.03)

    p.game.activePlayerIdx = 0
    p.viewedPlayerIdx = 0
    p.game.phase = phDiscard
    p.game.players[0].wares = [5, 3, 0, 0, 0]
    p.syncFromGame()
    p.rebuildButtons()
    let (thx, thy) = p.pegboard.wareHoleCenter(wtTimber, 1)
    check p.onMouseClick(thx, thy)
    p.rebuildButtons()
    for b in p.buttons:
      if b.action == baDiscardWare:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break

    p.game.phase = phGameOver
    p.game.gameFinishedTriggered = true
    p.syncFromGame()
    p.rebuildButtons()
    check p.modal == mkGameOver
    for b in p.buttons:
      if b.action == baCloseModal:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    p.rebuildButtons()
    for b in p.buttons:
      if b.action == baOpenStandings:
        discard p.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check p.modal == mkGameOver

import sim/online
import std/[os, json]

suite "Pegs of Ur Online, Quota, Standings & Support":
  test "profile persistence, email validation, 5/day quota, and support prompt":
    check isValidEmail("player@example.com")
    check not isValidEmail("invalid")
    check not isValidEmail("a@b")
    check not isValidEmail("bad space@example.com")

    var prof = initDefaultProfile()
    prof.email = "player@example.com"
    prof.displayName = "UrHero"
    check remainingOnlineGamesToday(prof, "2026-11-23") == FreeDailyOnlineLimit
    check canStartOnlineGame(prof, "2026-11-23")

    for i in 0 ..< FreeDailyOnlineLimit:
      check recordOnlineGameStarted(prof, "2026-11-23")
    check not canStartOnlineGame(prof, "2026-11-23")
    check not recordOnlineGameStarted(prof, "2026-11-23")
    check remainingOnlineGamesToday(prof, "2026-11-23") == 0

    # New day resets daily quota
    check canStartOnlineGame(prof, "2026-11-24")
    check remainingOnlineGamesToday(prof, "2026-11-24") == FreeDailyOnlineLimit

    # Support prompt triggers gently after 3 completed games on Linux/non-Store
    check not shouldShowSupportPrompt(prof)
    prof.recordLocalGameCompleted()
    prof.recordLocalGameCompleted()
    check not shouldShowSupportPrompt(prof)
    prof.recordLocalGameCompleted()
    check shouldShowSupportPrompt(prof)

    # Checkout URLs include client_reference_id
    check "pegsofur_player%40example.com" in buildSupportCheckoutUrl(prof.email, 5)
    check "pegsofur_linux" in buildSupportCheckoutUrl("", 1)

    # Supporter or Microsoft Store buyer gets unlimited online games and no support prompt
    prof.supported = true
    check isUnlimitedOnline(prof)
    check remainingOnlineGamesToday(prof, "2026-11-23") == -1
    check not shouldShowSupportPrompt(prof)
    check recordOnlineGameStarted(prof, "2026-11-23")

    # Disk round-trip
    let tmpPath = getTempDir() / "pegsofur_test_profile.json"
    defer:
      if fileExists(tmpPath): removeFile(tmpPath)
    check saveProfile(prof, tmpPath)
    let loaded = loadProfile(tmpPath)
    check loaded.email == "player@example.com"
    check loaded.displayName == "UrHero"
    check loaded.supported

  test "online API client (standings, rooms, account sync) and presenter modals":
    let mockTransport: HttpTransport = proc(httpMethod, url, body: string): HttpResponseData =
      if "/v1/account" in url:
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"supported":true,"tierLabel":"Supporter","date":"2026-11-23","dailyUsed":2}""")
      if "/v1/standings" in url and httpMethod == "GET":
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"mode":"solo","entries":[{"rank":1,"displayName":"Ur","mode":"solo","score":48,"rounds":10,"worksBuilt":4,"advancements":5,"won":true}]}""")
      if "/v1/standings" in url and httpMethod == "POST":
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"recorded":true}""")
      if "/v1/rooms/join" in url:
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"code":"UR4821","seat":1,"seatToken":"tok2","seed":42,"status":"active","dailyUsed":1}""")
      if "/v1/rooms/move" in url:
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"turnSeq":2}""")
      if "/v1/rooms" in url and httpMethod == "POST":
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"code":"UR4821","seat":0,"seatToken":"tok1","seed":42,"dailyUsed":1}""")
      if "/v1/rooms" in url and httpMethod == "GET":
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"code":"UR4821","hostName":"Ur","maxPlayers":2,"status":"active","turnSeq":1,"players":[{"seat":0,"displayName":"Ur"},{"seat":1,"displayName":"Byblos"}]}""")
      HttpResponseData(statusCode: 404, ok: false, body: """{"error":"not found"}""")

    var prof = initDefaultProfile()
    prof.email = "supporter@example.com"
    check syncAccountStatus(prof, DefaultApiBase, mockTransport)
    check prof.supported

    let entries = fetchGlobalStandings("solo", 10, DefaultApiBase, mockTransport)
    check entries.len == 1
    check entries[0].score == 48

    check submitGlobalStanding(prof, "solo", 48, 10, 4, 5, true, DefaultApiBase, mockTransport)

    var room = createOnlineRoom(prof, 2, DefaultApiBase, mockTransport)
    check room.code == "UR4821"
    check room.seatToken == "tok1"
    check pollOnlineRoom(room, DefaultApiBase, mockTransport)
    check room.players.len == 2
    check submitOnlineMove(room, "Roll", %*{"dice": [1, 2, 3]}, DefaultApiBase, mockTransport)
    check room.turnSeq == 2

    var p2 = initDefaultProfile()
    let joined = joinOnlineRoom(p2, "UR4821", DefaultApiBase, mockTransport)
    check joined.code == "UR4821"
    check joined.seat == 1

    # Exercise presenter modal transitions
    var pr = newPegsOfUrPresenter(1680.0, 960.0, seed = 777, showSetupModal = false)
    pr.profile = initDefaultProfile()
    pr.httpTransport = mockTransport
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baOpenGlobalStandings:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check pr.modal == mkGlobalStandings
    check pr.globalStandings.len == 1
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baToggleStandingsMode:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baRefreshStandings:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baCloseModal:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break

    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baOpenOnlineLobby:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check pr.modal == mkOnlineLobby
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baCreateOnlineRoom:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check pr.onlineRoom.code == "UR4821"
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baPollOnlineRoom:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baCloseModal:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break

    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baOpenSupport:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check pr.modal == mkSupport
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baOpenStripeSupport5:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check "stripe.com" in pr.pendingExternalUrl
    pr.rebuildButtons()
    for b in pr.buttons:
      if b.action == baMarkSupported:
        discard pr.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check pr.profile.supported

  test "two-player online room join via keyboard input and live turn synchronization":
    var sharedMoves = newJArray()
    var sharedSeq = 0
    var sharedPlayers = %*[
      {"seat": 0, "displayName": "Ur"},
      {"seat": 1, "displayName": "Byblos"},
    ]
    let roomServer: HttpTransport = proc(httpMethod, url, body: string): HttpResponseData =
      if "/v1/rooms/join" in url:
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"code":"UR9999","seat":1,"seatToken":"tokB","seed":12345,"status":"active","dailyUsed":1}""")
      if "/v1/rooms/move" in url:
        let j = parseJson(body)
        inc sharedSeq
        let seat = if j["seatToken"].getStr() == "tokA": 0 else: 1
        sharedMoves.add(%*{
          "seq": sharedSeq,
          "seat": seat,
          "action": j["action"].getStr(),
          "payload": j["payload"],
        })
        return HttpResponseData(statusCode: 200, ok: true, body: $(%*{"ok": true, "turnSeq": sharedSeq}))
      if "/v1/rooms" in url and httpMethod == "POST":
        return HttpResponseData(statusCode: 200, ok: true, body: """{"ok":true,"code":"UR9999","seat":0,"seatToken":"tokA","seed":12345,"status":"waiting","dailyUsed":1}""")
      if "/v1/rooms" in url and httpMethod == "GET":
        let resp = %*{
          "ok": true,
          "code": "UR9999",
          "hostName": "Ur",
          "maxPlayers": 2,
          "status": "active",
          "seed": 12345,
          "turnSeq": sharedSeq,
          "players": sharedPlayers,
          "moves": sharedMoves,
        }
        return HttpResponseData(statusCode: 200, ok: true, body: $resp)
      HttpResponseData(statusCode: 404, ok: false, body: """{"error":"not found"}""")

    var p1 = newPegsOfUrPresenter(1680.0, 960.0, seed = 1, showSetupModal = false)
    p1.profile = initDefaultProfile()
    p1.profile.displayName = "Ur"
    p1.httpTransport = roomServer

    var p2 = newPegsOfUrPresenter(1680.0, 960.0, seed = 2, showSetupModal = false)
    p2.profile = initDefaultProfile()
    p2.profile.displayName = "Byblos"
    p2.httpTransport = roomServer

    # P1 creates room
    p1.modal = mkOnlineLobby
    p1.rebuildButtons()
    for b in p1.buttons:
      if b.action == baCreateOnlineRoom:
        discard p1.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check p1.onlineRoom.code == "UR9999"

    # P2 types room code with keyboard + backspace correction and joins
    p2.modal = mkOnlineLobby
    for ch in "ur999x":
      check p2.onKeyChar(ch)
    check p2.onKeyBackspace()
    check p2.onKeyChar('9')
    check p2.joinCodeInput == "UR9999"
    p2.rebuildButtons()
    for b in p2.buttons:
      if b.action == baJoinOnlineRoom:
        discard p2.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check p2.onlineRoom.code == "UR9999"
    check p2.onlineRoom.seat == 1

    # P1 polls & both enter synchronized online match
    discard p1.syncOnlineRoom()
    p1.rebuildButtons()
    for b in p1.buttons:
      if b.action == baStartOnlineMatch:
        discard p1.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    p2.rebuildButtons()
    for b in p2.buttons:
      if b.action == baStartOnlineMatch:
        discard p2.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check p1.onlineMatchActive and p2.onlineMatchActive
    check p1.game.diceFaces == p2.game.diceFaces

    # Let opening dice bounce settle on both clients
    for _ in 0 ..< 160:
      if not p1.tray.isAnimating() and not p2.tray.isAnimating():
        break
      p1.tick(0.05)
      p2.tick(0.05)

    # P2 cannot act during P1's turn
    p2.rebuildButtons()
    for b in p2.buttons:
      if b.action == baKeepDiceAndHarvest:
        check not p2.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break

    # P1 keeps dice & harvests -> P2 auto-polls in tick() and stays in exact sync
    p1.rebuildButtons()
    for b in p1.buttons:
      if b.action == baKeepDiceAndHarvest:
        check p1.onMouseClick(b.rect.x + 4.0, b.rect.y + 4.0)
        break
    check sharedSeq >= 1
    for _ in 0 ..< 20:
      p2.tick(0.1)
    check p2.appliedMoveSeq == sharedSeq
    check p2.game.phase == p1.game.phase

  test "all 7 completed Great Works grant their ongoing perks":
    var g = newPegsOfUrGame(seed = 4242)
    g.startGame([
      SeatConfig(name: "Ur", seatType: stHuman),
      SeatConfig(name: "Closed2", seatType: stClosed),
      SeatConfig(name: "Closed3", seatType: stClosed),
      SeatConfig(name: "Closed4", seatType: stClosed),
    ])
    # Baseline without Great Works
    check g.maxRolls == 3
    check g.wareStorageLimit(0) == DefaultWaresLimit

    # Complete all 7 Great Works for player 0
    for idx, gw in GreatWorks:
      g.players[0].workProgress[idx] = gw.builders
    g.players[0].wares = [5, 3, 0, 0, 0] # 8 total wares
    check g.wareStorageLimit(0) == DefaultWaresLimit + 2
    check g.excessWaresToDiscard(0) == 0

    # New turn grants 4 casts from Standing Stones
    g.players[0].wares = [0, 0, 0, 0, 0]
    for i in 0 ..< g.diceFaces.len:
      g.diceFaces[i] = dfGrain3
    g.finishRolling()
    g.finishBuilding()
    g.skipBuying()
    check g.maxRolls == 4

    # Set all dice to Grain3 so builders/silver/wares come strictly from Great Work perks
    g.players[0].wares = [0, 0, 0, 0, 0]
    g.players[0].grain = 3
    for i in 0 ..< g.diceFaces.len:
      g.diceFaces[i] = dfGrain3
    g.finishRolling()
    # Mudbrick Shrine (+1s) + Citadel Ramparts (+2s) + Sun Ziggurat (+3s) = 6 Silver
    check g.turnSilver == 6
    # Royal Stele (+1B) = 1 Builder
    check g.turnBuilders == 1
    # Sun Ziggurat (+1 Ware) = 1 Timber
    check g.playerTotalWares(0) == 1
    # River Sanctuary (+1G) + Terraced Groves (+1G) + 3*3G = +11G -> 3+11-3 fed = 11 Grain
    check g.players[0].grain == 11
