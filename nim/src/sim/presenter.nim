## Pure-Nim tabletop UI layout, button synthesis, input handling, and presenter state.

import std/[json, strformat, strutils]
import data, game, ai, physics, online

type
  ButtonAction* = enum
    baNone = 0
    baSelectPlayerTab
    baFollowActiveTurn
    baCycleAiSpeed
    baToggleAudio
    baOpenRules
    baCloseModal
    baOpenSetup
    baCycleSeatType
    baCycleSeatRealmName
    baPresetSolo
    baPresetDuel
    baPresetClassic4P
    baStartConfiguredMatch
    baRollSelected
    baSelectAllRerollable
    baToggleDivination
    baExorcism
    baKeepDiceAndHarvest
    baFlipChoiceDie
    baConfirmChoices
    baBuildSettlementOne
    baBuildSettlementFinish
    baBuildWorkOne
    baBuildWorkBulk
    baConvertCranes
    baAtonement
    baResetBuild
    baFinishBuilding
    baSelectAdvCustomPay
    baAutoBuyAdv
    baToggleBuyWareRow
    baSiloMinus
    baSiloPlus
    baConfirmCustomBuy
    baCancelCustomBuy
    baSkipBuying
    baDiscardWare
    baOpenStandings
    baOpenGlobalStandings
    baRefreshStandings
    baSubmitCurrentStanding
    baToggleStandingsMode
    baOpenOnlineLobby
    baCreateOnlineRoom
    baJoinOnlineRoom
    baStartOnlineMatch
    baPollOnlineRoom
    baOpenSupport
    baOpenStripeSupport1
    baOpenStripeSupport5
    baDismissSupport
    baMarkSupported

  UiButton* = object
    rect*: UiRect
    label*: string
    action*: ButtonAction
    intParam*: int
    intParam2*: int
    bg*: Rgba
    border*: Rgba
    enabled*: bool
    active*: bool

  PegsOfUrPresenter* = ref object
    game*: PegsOfUrGame
    tray*: DiceTraySim
    pegboard*: PegboardSim
    screenW*, screenH*: float

    viewedPlayerIdx*: int
    followActivePlayer*: bool
    divinationArmed*: bool

    selectedBuyAdv*: int
    buyWaresMask*: array[WareType, bool]
    buySiloGrain*: int

    aiSpeed*: AiSpeedKind
    aiWaitTimer*: float
    audioMuted*: bool

    modal*: ModalKind
    seatConfigs*: array[4, SeatConfig]
    setupError*: string

    calamityBannerTitle*: string
    calamityBannerDetail*: string
    calamityTimer*: float

    advScrollOffset*: float
    buttons*: seq[UiButton]
    hoveredButtonIdx*: int
    audioQueue*: seq[AudioEvent]

    lastSyncedRollSeq*: int
    lastSyncedPhase*: Phase

    profile*: PegsProfile
    globalStandings*: seq[StandingEntry]
    standingsMode*: string
    onlineRoom*: OnlineRoomState
    onlineStatusMsg*: string
    joinCodeInput*: string
    onlineMatchActive*: bool
    appliedMoveSeq*: int
    onlinePollTimer*: float
    replayingRemote*: bool
    pendingExternalUrl*: string
    httpTransport*: HttpTransport

const
  RealmNamePool: array[8, string] = [
    "Ur", "Byblos", "Knossos", "Thebes",
    "Ugarit", "Mari", "Assur", "Nineveh",
  ]

proc pushAudio*(p: PegsOfUrPresenter; kind: AudioCueKind; energy: float = 0.8; pitch: float = 1.0) =
  if not p.audioMuted:
    p.audioQueue.add(AudioEvent(kind: kind, energy: energy, pitch: pitch))

proc popAudioEvents*(p: PegsOfUrPresenter): seq[AudioEvent] =
  result = p.audioQueue
  p.audioQueue.setLen(0)

proc topBarRect*(p: PegsOfUrPresenter): UiRect =
  uiRect(14.0, 10.0, p.screenW - 28.0, 54.0)

proc leftColRect*(p: PegsOfUrPresenter): UiRect =
  uiRect(14.0, 74.0, 456.0, p.screenH - 86.0)

proc rightColRect*(p: PegsOfUrPresenter): UiRect =
  let w = 548.0
  uiRect(p.screenW - 14.0 - w, 74.0, w, p.screenH - 86.0)

proc centerColRect*(p: PegsOfUrPresenter): UiRect =
  let lx = 14.0 + 456.0 + 12.0
  let rx = p.screenW - 14.0 - 548.0 - 12.0
  uiRect(lx, 74.0, max(320.0, rx - lx), p.screenH - 86.0)

proc ownerStripRect*(p: PegsOfUrPresenter): UiRect =
  let lc = p.leftColRect()
  uiRect(lc.x, lc.y, lc.w, 36.0)

proc settlementsCardRect*(p: PegsOfUrPresenter): UiRect =
  let lc = p.leftColRect()
  let h = 152.0
  uiRect(lc.x, lc.y + lc.h - h, lc.w, h)

proc pegboardPanelRect*(p: PegsOfUrPresenter): UiRect =
  let lc = p.leftColRect()
  let topY = lc.y + 42.0
  let botY = p.settlementsCardRect().y - 8.0
  uiRect(lc.x, topY, lc.w, max(280.0, botY - topY))

proc diceTrayPanelRect*(p: PegsOfUrPresenter): UiRect =
  let cc = p.centerColRect()
  uiRect(cc.x, cc.y, cc.w, 246.0)

proc calamityBannerRect*(p: PegsOfUrPresenter): UiRect =
  let cc = p.centerColRect()
  uiRect(cc.x, cc.y + 254.0, cc.w, 42.0)

proc actionCardRect*(p: PegsOfUrPresenter): UiRect =
  let cc = p.centerColRect()
  let offset = if p.calamityTimer > 0.0: 304.0 else: 256.0
  let h = if p.game.phase == phBuy and p.selectedBuyAdv >= 0: 196.0 else: 146.0
  uiRect(cc.x, cc.y + offset, cc.w, h)

proc logCardRect*(p: PegsOfUrPresenter): UiRect =
  let cc = p.centerColRect()
  let ac = p.actionCardRect()
  let topY = ac.y + ac.h + 10.0
  uiRect(cc.x, topY, cc.w, max(120.0, cc.y + cc.h - topY))

proc greatWorksAreaRect*(p: PegsOfUrPresenter): UiRect =
  let rc = p.rightColRect()
  uiRect(rc.x + 12.0, rc.y + 32.0, rc.w - 24.0, 344.0)

proc advancementsAreaRect*(p: PegsOfUrPresenter): UiRect =
  let rc = p.rightColRect()
  let topY = rc.y + 412.0
  uiRect(rc.x + 12.0, topY, rc.w - 24.0, max(160.0, rc.y + rc.h - topY - 12.0))

proc modalCardRect*(p: PegsOfUrPresenter): UiRect =
  let w =
    if p.modal == mkRules: 790.0
    elif p.modal in {mkGameOver, mkGlobalStandings, mkOnlineLobby}: 760.0
    else: 650.0
  let h =
    if p.modal == mkRules: 610.0
    elif p.modal in {mkGlobalStandings, mkOnlineLobby}: 520.0
    elif p.modal == mkGameOver: 450.0
    else: 450.0
  uiRect((p.screenW - w) * 0.5, (p.screenH - h) * 0.5, w, h)

proc isDieClickable*(p: PegsOfUrPresenter; idx: int): bool =
  if p.modal != mkNone or idx < 0 or idx >= p.tray.dice.len:
    return false
  if not p.game.isActiveHuman() or p.tray.isAnimating():
    return false
  let face = p.tray.dice[idx].targetFace
  if p.game.phase == phRoll:
    if p.divinationArmed:
      return true
    return p.game.canDieBeToggledForReroll(idx)
  elif p.game.phase == phAssignChoices:
    return face == dfGrainOrBuilders2
  false

proc syncFromGame*(p: PegsOfUrPresenter) =
  p.pegboard.rect = p.pegboardPanelRect()
  p.tray.rect = p.diceTrayPanelRect()

  if p.followActivePlayer or p.viewedPlayerIdx >= p.game.players.len:
    p.viewedPlayerIdx = p.game.activePlayerIdx

  if p.game.phase != phRoll:
    p.divinationArmed = false
  if p.game.phase != phBuy:
    p.selectedBuyAdv = -1
    for wt in WareType:
      p.buyWaresMask[wt] = false
    p.buySiloGrain = 0

  if p.game.rollEventSeq != p.lastSyncedRollSeq:
    p.lastSyncedRollSeq = p.game.rollEventSeq
    p.tray.triggerRoll(p.game.lastRolledIndices, p.game.diceFaces)
    p.aiWaitTimer = max(p.aiWaitTimer, aiSpeedDelay(p.aiSpeed))
  else:
    p.tray.syncDiceTargets(p.game.diceFaces)

  if p.game.pendingCalamities.len > 0:
    let lastC = p.game.pendingCalamities[^1]
    p.calamityBannerTitle = lastC.title
    p.calamityBannerDetail = lastC.detail
    p.calamityTimer = 4.5
    p.game.pendingCalamities.setLen(0)
    p.pushAudio(akDisaster)

  if p.game.gameFinishedTriggered:
    p.game.gameFinishedTriggered = false
    p.modal = mkGameOver
    p.pushAudio(akFanfare)

  if p.game.players.len > 0:
    let vp = p.game.players[p.viewedPlayerIdx]
    p.pegboard.syncPegboard(p.viewedPlayerIdx, vp.grain, vp.wares, p.audioQueue)

proc addBtn(
  p: PegsOfUrPresenter;
  rc: UiRect;
  label: string;
  action: ButtonAction;
  bg: Rgba;
  border: Rgba;
  intParam: int = 0;
  intParam2: int = 0;
  enabled: bool = true;
  active: bool = false
) =
  p.buttons.add(UiButton(
    rect: rc,
    label: label,
    action: action,
    intParam: intParam,
    intParam2: intParam2,
    bg: bg,
    border: border,
    enabled: enabled,
    active: active,
  ))

proc rebuildButtons*(p: PegsOfUrPresenter) =
  p.buttons.setLen(0)
  let warmBg = rgba(0.34'f32, 0.21'f32, 0.10'f32, 0.96'f32)
  let accentBg = rgba(0.54'f32, 0.31'f32, 0.11'f32, 0.98'f32)
  let greenBg = rgba(0.22'f32, 0.44'f32, 0.19'f32, 0.98'f32)
  let redBg = rgba(0.52'f32, 0.19'f32, 0.14'f32, 0.98'f32)
  let brass = rgba(0.84'f32, 0.66'f32, 0.34'f32, 0.95'f32)
  let goldHi = rgba(0.99'f32, 0.84'f32, 0.32'f32, 1.0'f32)

  if p.modal != mkNone:
    let mr = p.modalCardRect()
    case p.modal
    of mkSetup:
      for i in 0 ..< 4:
        let ry = mr.y + 92.0 + float(i) * 46.0
        p.addBtn(
          uiRect(mr.x + 110.0, ry, 210.0, 34.0),
          fmt"Realm: {p.seatConfigs[i].name}",
          baCycleSeatRealmName,
          warmBg,
          brass,
          intParam = i,
        )
        p.addBtn(
          uiRect(mr.x + 332.0, ry, mr.w - 362.0, 34.0),
          seatShortTag(p.seatConfigs[i].seatType),
          baCycleSeatType,
          if p.seatConfigs[i].seatType == stClosed: rgba(0.20'f32, 0.14'f32, 0.10'f32, 0.88'f32) else: accentBg,
          brass,
          intParam = i,
        )

      let py = mr.y + 292.0
      let pw = (mr.w - 76.0) / 3.0
      p.addBtn(uiRect(mr.x + 26.0, py, pw, 32.0), "Preset: 1P Solo", baPresetSolo, warmBg, brass)
      p.addBtn(uiRect(mr.x + 38.0 + pw, py, pw, 32.0), "Preset: 2P Duel", baPresetDuel, warmBg, brass)
      p.addBtn(uiRect(mr.x + 50.0 + pw * 2.0, py, pw, 32.0), "Preset: 4P Classic", baPresetClassic4P, warmBg, brass)

      let by = mr.y + mr.h - 56.0
      p.addBtn(uiRect(mr.x + 80.0, by, 210.0, 38.0), "Resume Current Board", baCloseModal, warmBg, brass)
      p.addBtn(uiRect(mr.x + mr.w - 290.0, by, 210.0, 38.0), "Launch Pegs of Ur", baStartConfiguredMatch, greenBg, goldHi)

    of mkRules:
      p.addBtn(
        uiRect(mr.x + (mr.w - 220.0) * 0.5, mr.y + mr.h - 50.0, 220.0, 36.0),
        "Close Rules Reference",
        baCloseModal,
        accentBg,
        goldHi,
      )

    of mkGameOver:
      let by = mr.y + mr.h - 54.0
      p.addBtn(uiRect(mr.x + 28.0, by, 180.0, 36.0), "Inspect Final Board", baCloseModal, warmBg, brass)
      p.addBtn(uiRect(mr.x + 220.0, by, 210.0, 36.0), "Submit Global Score", baSubmitCurrentStanding, accentBg, goldHi)
      p.addBtn(uiRect(mr.x + 442.0, by, 160.0, 36.0), "New Match", baOpenSetup, warmBg, brass)
      if p.profile.shouldShowSupportPrompt():
        p.addBtn(uiRect(mr.x + 614.0, by, 118.0, 36.0), "Support", baOpenSupport, accentBg, goldHi)

    of mkGlobalStandings:
      let topY = mr.y + 62.0
      let modeLbl = if p.standingsMode == "multi": "Mode: Multiplayer" else: "Mode: Solo (10-Rd)"
      p.addBtn(uiRect(mr.x + 24.0, topY, 175.0, 32.0), modeLbl, baToggleStandingsMode, warmBg, brass)
      p.addBtn(uiRect(mr.x + 208.0, topY, 120.0, 32.0), "Refresh", baRefreshStandings, warmBg, brass)
      p.addBtn(uiRect(mr.x + 336.0, topY, 195.0, 32.0), "Submit Current Score", baSubmitCurrentStanding, accentBg, goldHi)
      if not p.profile.isMicrosoftStore:
        p.addBtn(uiRect(mr.x + mr.w - 144.0, topY, 120.0, 32.0), "Support", baOpenSupport, warmBg, brass)
      p.addBtn(uiRect(mr.x + (mr.w - 180.0) * 0.5, mr.y + mr.h - 50.0, 180.0, 36.0), "Close", baCloseModal, accentBg, goldHi)

    of mkOnlineLobby:
      let rowY = mr.y + 104.0
      p.addBtn(uiRect(mr.x + 28.0, rowY, 175.0, 34.0), "Create 2P Room", baCreateOnlineRoom, accentBg, goldHi, intParam = 2)
      p.addBtn(uiRect(mr.x + 213.0, rowY, 175.0, 34.0), "Create 4P Room", baCreateOnlineRoom, accentBg, goldHi, intParam = 4)
      p.addBtn(uiRect(mr.x + 398.0, rowY, 138.0, 34.0), "Refresh Room", baPollOnlineRoom, warmBg, brass, enabled = p.onlineRoom.code.len == 6)
      if not p.profile.isMicrosoftStore and not p.profile.isUnlimitedOnline():
        p.addBtn(uiRect(mr.x + 546.0, rowY, 186.0, 34.0), "Unlock Unlimited", baOpenSupport, warmBg, goldHi)
      let joinY = mr.y + 150.0
      p.addBtn(uiRect(mr.x + 290.0, joinY, 150.0, 34.0), "Join Room", baJoinOnlineRoom, accentBg, goldHi, enabled = p.joinCodeInput.len == 6)
      p.addBtn(uiRect(mr.x + 452.0, joinY, 210.0, 34.0), "Enter Online Match", baStartOnlineMatch, accentBg, goldHi, enabled = p.onlineRoom.code.len == 6 and p.onlineRoom.players.len >= 2)
      p.addBtn(uiRect(mr.x + (mr.w - 180.0) * 0.5, mr.y + mr.h - 50.0, 180.0, 36.0), "Close", baCloseModal, accentBg, goldHi)

    of mkSupport:
      let rowY = mr.y + 230.0
      p.addBtn(uiRect(mr.x + 44.0, rowY, 175.0, 38.0), "Support $1 (Stripe)", baOpenStripeSupport1, accentBg, goldHi)
      p.addBtn(uiRect(mr.x + 235.0, rowY, 175.0, 38.0), "Support $5 (Stripe)", baOpenStripeSupport5, accentBg, goldHi)
      p.addBtn(uiRect(mr.x + 426.0, rowY, 180.0, 38.0), "I've Supported", baMarkSupported, warmBg, goldHi)
      let by = mr.y + mr.h - 52.0
      p.addBtn(uiRect(mr.x + 140.0, by, 180.0, 34.0), "Don't Show Again", baDismissSupport, warmBg, brass)
      p.addBtn(uiRect(mr.x + 340.0, by, 170.0, 34.0), "Close", baCloseModal, accentBg, goldHi)

    of mkNone:
      discard
    return

  let tb = p.topBarRect()
  var rx = tb.x + tb.w - 10.0
  let audioLbl = if p.audioMuted: "Audio: Off" else: "Audio: On"
  var topBtns = @[
    ("New Match", 92.0, baOpenSetup, accentBg),
    ("Online", 68.0, baOpenOnlineLobby, warmBg),
    ("Standings", 84.0, baOpenGlobalStandings, warmBg),
    ("Rules", 58.0, baOpenRules, warmBg),
    (audioLbl, 84.0, baToggleAudio, warmBg),
    (fmt"AI: {aiSpeedLabel(p.aiSpeed)}", 88.0, baCycleAiSpeed, warmBg),
  ]
  if not p.profile.isMicrosoftStore:
    topBtns.insert(("Support", 70.0, baOpenSupport, warmBg), 3)
  for item in topBtns:
    rx -= item[1]
    p.addBtn(uiRect(rx, tb.y + 10.0, item[1], 34.0), item[0], item[2], item[3], brass)
    rx -= 6.0

  let nPlayers = p.game.players.len
  if nPlayers > 0:
    let tabW = 166.0
    let totalTabsW = float(nPlayers) * tabW + float(nPlayers - 1) * 8.0
    let startX = clamp((p.screenW - totalTabsW) * 0.5, tb.x + 290.0, rx - totalTabsW - 12.0)
    for i in 0 ..< nPlayers:
      let pl = p.game.players[i]
      let sb = p.game.computeScoreBreakdown(i)
      let isAct = (i == p.game.activePlayerIdx)
      let isView = (i == p.viewedPlayerIdx)
      let prefix = if isAct: "▶ " else: ""
      let lbl = fmt"{prefix}{pl.name} ({sb.totalVp} VP)"
      let tabBg = rgba(pl.color.r * 0.42'f32, pl.color.g * 0.42'f32, pl.color.b * 0.42'f32, 0.96'f32)
      p.addBtn(
        uiRect(startX + float(i) * (tabW + 8.0), tb.y + 7.0, tabW, 40.0),
        lbl,
        baSelectPlayerTab,
        tabBg,
        if isAct: goldHi elif isView: rgba(0.92'f32, 0.88'f32, 0.76'f32, 0.95'f32) else: brass,
        intParam = i,
        active = isView,
      )

  let os = p.ownerStripRect()
  p.addBtn(uiRect(os.x + os.w - 106.0, os.y + 4.0, 98.0, 28.0), "Active Turn", baFollowActiveTurn, warmBg, brass)

  let canEditViewed = (p.viewedPlayerIdx == p.game.activePlayerIdx and p.game.isActiveHuman())

  let scRect = p.settlementsCardRect()
  if canEditViewed and p.game.phase == phBuild and p.game.canBuildSettlementBuilder():
    let vp = p.game.players[p.viewedPlayerIdx]
    let slot = vp.settlements - InitialSettlements
    let rowY = scRect.y + 48.0 + float(slot) * 24.0
    p.addBtn(uiRect(scRect.x + scRect.w - 150.0, rowY - 2.0, 62.0, 22.0), "+1 B", baBuildSettlementOne, accentBg, brass)
    let rem = SettlementCosts[slot] - vp.settlementProgress[slot]
    if rem > 1 and p.game.turnBuilders >= rem:
      p.addBtn(uiRect(scRect.x + scRect.w - 82.0, rowY - 2.0, 74.0, 22.0), fmt"Fill ({rem}B)", baBuildSettlementFinish, greenBg, goldHi, intParam = rem)

  let ac = p.actionCardRect()
  let btnY = ac.y + ac.h - 44.0
  if p.game.phase == phGameOver:
    p.addBtn(uiRect(ac.x + 16.0, btnY, 240.0, 34.0), "Show Final Standings Table", baOpenStandings, accentBg, goldHi)
  elif p.game.isActiveHuman():
    let anim = p.tray.isAnimating()
    case p.game.phase
    of phRoll:
      var bx = ac.x + 14.0
      if p.game.rollsUsed < p.game.maxRolls:
        p.addBtn(uiRect(bx, btnY, 152.0, 34.0), "Roll Selected Dice", baRollSelected, accentBg, goldHi, enabled = p.game.canRerollSelected() and not anim)
        bx += 160.0
        p.addBtn(uiRect(bx, btnY, 162.0, 34.0), "Select All Rerollable", baSelectAllRerollable, warmBg, brass, enabled = not anim)
        bx += 170.0
      p.addBtn(uiRect(bx, btnY, 174.0, 34.0), "Keep Dice & Gather ->", baKeepDiceAndHarvest, greenBg, goldHi, enabled = not anim)

      var rx2 = ac.x + 14.0
      if p.game.canUseDivination():
        let dTxt = if p.divinationArmed: "Cancel Divination" else: "Divination (1 Die)"
        p.addBtn(uiRect(rx2, btnY - 36.0, 156.0, 28.0), dTxt, baToggleDivination, if p.divinationArmed: greenBg else: warmBg, goldHi, enabled = not anim, active = p.divinationArmed)
        rx2 += 164.0
      if p.game.canUseExorcism():
        p.addBtn(uiRect(rx2, btnY - 36.0, 224.0, 28.0), "Exorcism (-5W: -2 Omens, -1 Die)", baExorcism, redBg, goldHi, enabled = not anim)

    of phAssignChoices:
      var bx = ac.x + 14.0
      for i, f in p.game.diceFaces:
        if f == dfGrainOrBuilders2:
          let modeStr = if p.game.choiceIsBuilders[i]: "2 Builders" else: "2 Grain"
          p.addBtn(uiRect(bx, btnY - 36.0, 152.0, 28.0), fmt"Die #{i + 1}: {modeStr}", baFlipChoiceDie, warmBg, brass, intParam = i)
          bx += 158.0
      p.addBtn(uiRect(ac.x + 14.0, btnY, 246.0, 34.0), "Confirm Gather & Feed Realms ->", baConfirmChoices, greenBg, goldHi)

    of phBuild:
      var bx = ac.x + 14.0
      if p.game.canUseAtonement():
        p.addBtn(uiRect(ac.x + 14.0, btnY - 36.0, 244.0, 28.0), "Atonement (3s + 3G -> -1 Calamity)", baAtonement, accentBg, goldHi)
      if p.game.canConvertAlabasterWithCranes():
        let alQ = p.game.players[p.game.activePlayerIdx].wares[wtAlabaster]
        p.addBtn(uiRect(bx, btnY, 224.0, 34.0), fmt"Cranes: 1 Alabaster ({alQ}) -> +3B", baConvertCranes, accentBg, brass)
        bx += 232.0
      p.addBtn(uiRect(bx, btnY, 140.0, 34.0), "Reset Build Step", baResetBuild, warmBg, brass)
      bx += 148.0
      let endLbl = if p.game.turnBuilders == 0: "Finish Building ->" else: fmt"End Build ({p.game.turnBuilders}B left) ->"
      p.addBtn(uiRect(bx, btnY, 190.0, 34.0), endLbl, baFinishBuilding, greenBg, goldHi)

    of phBuy:
      let apIdx = p.game.activePlayerIdx
      let ap = p.game.players[apIdx]
      if p.selectedBuyAdv >= 0:
        let aDef = Advancements[p.selectedBuyAdv]
        var paid = p.game.turnSilver + p.buySiloGrain * 6
        var wx = ac.x + 14.0
        let wy = ac.y + 62.0
        for wt in WareType:
          let q = ap.wares[wt]
          if q > 0:
            let val = wareSilverValue(wt, q)
            if p.buyWaresMask[wt]:
              paid += val
            let mark = if p.buyWaresMask[wt]: "[x]" else: "[ ]"
            p.addBtn(
              uiRect(wx, wy, 118.0, 28.0),
              fmt"{mark} {WareNames[wt]} ({val}s)",
              baToggleBuyWareRow,
              if p.buyWaresMask[wt]: accentBg else: warmBg,
              brass,
              intParam = ord(wt),
              active = p.buyWaresMask[wt],
            )
            wx += 122.0

        if p.game.playerHasAdv(apIdx, "silos") and ap.grain > 0:
          p.addBtn(uiRect(ac.x + 14.0, wy + 34.0, 86.0, 26.0), "-1 Grain", baSiloMinus, warmBg, brass, enabled = p.buySiloGrain > 0)
          p.addBtn(uiRect(ac.x + 106.0, wy + 34.0, 116.0, 26.0), "+1 Grain (+6s)", baSiloPlus, warmBg, brass, enabled = p.buySiloGrain < ap.grain)

        p.addBtn(
          uiRect(ac.x + 14.0, btnY, 232.0, 34.0),
          fmt"Unlock: {aDef.name} ({paid}/{aDef.cost}s)",
          baConfirmCustomBuy,
          greenBg,
          goldHi,
          enabled = paid >= aDef.cost,
        )
        p.addBtn(uiRect(ac.x + 254.0, btnY, 122.0, 34.0), "Cancel", baCancelCustomBuy, warmBg, brass)
        p.addBtn(uiRect(ac.x + 384.0, btnY, 174.0, 34.0), "Skip Unlocking ->", baSkipBuying, warmBg, brass)
      else:
        var bx = ac.x + 14.0
        if p.game.canUseAtonement():
          p.addBtn(uiRect(bx, btnY, 244.0, 34.0), "Atonement (3s + 3G -> -1 Calamity)", baAtonement, accentBg, goldHi)
          bx += 252.0
        p.addBtn(uiRect(bx, btnY, 224.0, 34.0), "Skip Advancement & End Turn ->", baSkipBuying, warmBg, brass)

    of phDiscard:
      let ap = p.game.players[p.game.activePlayerIdx]
      var dx = ac.x + 14.0
      for wt in WareType:
        let q = ap.wares[wt]
        if q > 0:
          let loss = wareSilverValue(wt, q) - wareSilverValue(wt, q - 1)
          p.addBtn(
            uiRect(dx, btnY, 122.0, 34.0),
            fmt"-1 {WareNames[wt]} (-{loss}s)",
            baDiscardWare,
            redBg,
            brass,
            intParam = ord(wt),
          )
          dx += 126.0
    else:
      discard

  let gwa = p.greatWorksAreaRect()
  var gwy = gwa.y
  for gwIdx in 0 ..< GreatWorks.len:
    if not isGreatWorkActive(gwIdx, p.game.players.len):
      continue
    if canEditViewed and p.game.phase == phBuild and p.game.canBuildWorkBuilder(gwIdx):
      p.addBtn(uiRect(gwa.x + gwa.w - 134.0, gwy + 8.0, 56.0, 28.0), "+1 B", baBuildWorkOne, accentBg, brass, intParam = gwIdx)
      let req = GreatWorks[gwIdx].builders
      let prog = p.game.players[p.viewedPlayerIdx].workProgress[gwIdx]
      let rem = req - prog
      let bulk = min(rem, p.game.turnBuilders)
      if bulk > 1:
        let bLbl = if p.game.turnBuilders >= rem: fmt"Done ({rem}B)" else: fmt"+{bulk} B"
        p.addBtn(uiRect(gwa.x + gwa.w - 72.0, gwy + 8.0, 68.0, 28.0), bLbl, baBuildWorkBulk, greenBg, goldHi, intParam = gwIdx, intParam2 = bulk)
    gwy += 48.0

  let aa = p.advancementsAreaRect()
  let rowStride = 44.0
  let totalAdvH = float(Advancements.len) * rowStride
  let maxScroll = max(0.0, totalAdvH - aa.h)
  p.advScrollOffset = clamp(p.advScrollOffset, 0.0, maxScroll)

  if canEditViewed and p.game.phase == phBuy and not p.game.boughtAdvThisTurn:
    for aIdx in 0 ..< Advancements.len:
      let ry = aa.y + float(aIdx) * rowStride - p.advScrollOffset
      if ry + 38.0 < aa.y or ry > aa.y + aa.h - 24.0:
        continue
      if p.game.players[p.viewedPlayerIdx].advancements[aIdx]:
        continue
      let plan = p.game.findOptimalPayment(p.game.activePlayerIdx, aIdx)
      if plan.valid:
        p.addBtn(uiRect(aa.x + aa.w - 146.0, ry + 6.0, 58.0, 28.0), "Pay...", baSelectAdvCustomPay, warmBg, brass, intParam = aIdx)
        p.addBtn(uiRect(aa.x + aa.w - 82.0, ry + 6.0, 78.0, 28.0), fmt"Buy ({plan.totalPaid}s)", baAutoBuyAdv, greenBg, goldHi, intParam = aIdx)

proc newPegsOfUrPresenter*(
  screenW: float = 1680.0;
  screenH: float = 960.0;
  seed: int64 = -1;
  showSetupModal: bool = true
): PegsOfUrPresenter =
  let g = newPegsOfUrGame(seed)
  let defaultSeats = [
    SeatConfig(name: "Ur", seatType: stHuman, color: RealmDefaults[0].color),
    SeatConfig(name: "Byblos", seatType: stAiNormal, color: RealmDefaults[1].color),
    SeatConfig(name: "Knossos", seatType: stAiHard, color: RealmDefaults[2].color),
    SeatConfig(name: "Thebes", seatType: stAiEasy, color: RealmDefaults[3].color),
  ]
  g.startGame(defaultSeats)

  result = PegsOfUrPresenter(
    game: g,
    tray: newDiceTraySim(if seed >= 0: seed + 17 else: -1),
    pegboard: newPegboardSim(),
    screenW: screenW,
    screenH: screenH,
    followActivePlayer: true,
    selectedBuyAdv: -1,
    aiSpeed: asNormal,
    modal: if showSetupModal: mkSetup else: mkNone,
    seatConfigs: defaultSeats,
    hoveredButtonIdx: -1,
    lastSyncedRollSeq: -1,
    lastSyncedPhase: phSetup,
  )
  result.syncFromGame()
  result.rebuildButtons()

proc selectAdvForCustomPay*(p: PegsOfUrPresenter; advIdx: int) =
  p.selectedBuyAdv = advIdx
  let plan = p.game.findOptimalPayment(p.game.activePlayerIdx, advIdx)
  if plan.valid:
    p.buyWaresMask = plan.waresMask
    p.buySiloGrain = plan.siloGrain
  else:
    for wt in WareType:
      p.buyWaresMask[wt] = false
    p.buySiloGrain = 0

proc isGameplayAction(a: ButtonAction): bool =
  a in {
    baRollSelected, baSelectAllRerollable, baToggleDivination, baExorcism, baKeepDiceAndHarvest,
    baFlipChoiceDie, baConfirmChoices, baBuildSettlementOne, baBuildSettlementFinish,
    baBuildWorkOne, baBuildWorkBulk, baConvertCranes, baAtonement, baResetBuild, baFinishBuilding,
    baAutoBuyAdv, baConfirmCustomBuy, baSkipBuying, baDiscardWare,
  }

proc parseButtonAction(name: string): ButtonAction =
  for a in ButtonAction:
    if $a == name:
      return a
  baNone

proc onKeyChar*(p: PegsOfUrPresenter; ch: char): bool =
  if p.modal != mkOnlineLobby:
    return false
  let up = ch.toUpperAscii()
  if up in {'A'..'Z', '0'..'9'} and p.joinCodeInput.len < 6:
    p.joinCodeInput.add(up)
    p.rebuildButtons()
    return true
  false

proc onKeyBackspace*(p: PegsOfUrPresenter): bool =
  if p.modal != mkOnlineLobby or p.joinCodeInput.len == 0:
    return false
  p.joinCodeInput.setLen(p.joinCodeInput.len - 1)
  p.rebuildButtons()
  true

proc executeButtonAction(p: PegsOfUrPresenter; btn: UiButton): bool =
  if not btn.enabled:
    return false
  if p.onlineMatchActive and not p.replayingRemote and isGameplayAction(btn.action) and
      p.game.activePlayerIdx != p.onlineRoom.seat:
    p.onlineStatusMsg = "Waiting for remote opponent's turn..."
    return false
  case btn.action
  of baNone:
    return false
  of baSelectPlayerTab:
    p.viewedPlayerIdx = clamp(btn.intParam, 0, p.game.players.len - 1)
    p.followActivePlayer = (p.viewedPlayerIdx == p.game.activePlayerIdx)
    p.pushAudio(akUiTap)
  of baFollowActiveTurn:
    p.followActivePlayer = true
    p.viewedPlayerIdx = p.game.activePlayerIdx
    p.pushAudio(akUiTap)
  of baCycleAiSpeed:
    p.aiSpeed = AiSpeedKind((ord(p.aiSpeed) + 1) mod 3)
    p.pushAudio(akUiTap)
  of baToggleAudio:
    p.audioMuted = not p.audioMuted
    if not p.audioMuted:
      p.pushAudio(akPegTap)
  of baOpenRules:
    p.modal = mkRules
    p.pushAudio(akUiTap)
  of baCloseModal:
    p.modal = mkNone
    p.setupError = ""
    p.pushAudio(akUiTap)
  of baOpenSetup:
    p.modal = mkSetup
    p.setupError = ""
    p.pushAudio(akUiTap)
  of baOpenStandings:
    p.modal = mkGameOver
    p.pushAudio(akUiTap)
  of baOpenGlobalStandings:
    if p.standingsMode.len == 0:
      p.standingsMode = if p.game.isSolo(): "solo" else: "multi"
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    p.globalStandings = fetchGlobalStandings(p.standingsMode, 10, DefaultApiBase, tr)
    p.modal = mkGlobalStandings
    p.pushAudio(akUiTap)
  of baToggleStandingsMode:
    p.standingsMode = if p.standingsMode == "multi": "solo" else: "multi"
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    p.globalStandings = fetchGlobalStandings(p.standingsMode, 10, DefaultApiBase, tr)
    p.pushAudio(akUiTap)
  of baRefreshStandings:
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    let mode = if p.standingsMode.len > 0: p.standingsMode else: "solo"
    p.globalStandings = fetchGlobalStandings(mode, 10, DefaultApiBase, tr)
    p.onlineStatusMsg = fmt"Refreshed {mode} standings ({p.globalStandings.len} entries)."
    p.pushAudio(akUiTap)
  of baSubmitCurrentStanding:
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    let standings = p.game.getStandings()
    if standings.len > 0:
      let top = standings[0]
      let mode = if p.game.isSolo(): "solo" else: "multi"
      var works = 0
      for w in 0 ..< p.game.workFirstOwner.len:
        if p.game.workFirstOwner[w] == 0: inc works
      var advs = 0
      for a in 0 ..< p.game.players[0].advancements.len:
        if p.game.players[0].advancements[a]: inc advs
      let ok = submitGlobalStanding(p.profile, mode, top.totalVp, max(1, p.game.roundNumber), works, advs, true, DefaultApiBase, tr)
      p.onlineStatusMsg = if ok: fmt"Submitted {top.totalVp} VP to global {mode} standings!" else: "Could not reach global standings server."
      p.standingsMode = mode
      p.globalStandings = fetchGlobalStandings(mode, 10, DefaultApiBase, tr)
      p.modal = mkGlobalStandings
    p.pushAudio(akUiTap)
  of baOpenOnlineLobby:
    p.modal = mkOnlineLobby
    p.pushAudio(akUiTap)
  of baCreateOnlineRoom:
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    let maxP = if btn.intParam >= 2: btn.intParam else: 2
    p.onlineRoom = createOnlineRoom(p.profile, maxP, DefaultApiBase, tr)
    if p.onlineRoom.lastError.len > 0:
      p.onlineStatusMsg = p.onlineRoom.lastError
    else:
      p.onlineStatusMsg = fmt"Room {p.onlineRoom.code} created! Share this code with friends."
      discard saveProfile(p.profile)
    p.pushAudio(akUiTap)
  of baJoinOnlineRoom:
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    p.onlineRoom = joinOnlineRoom(p.profile, p.joinCodeInput, DefaultApiBase, tr)
    if p.onlineRoom.lastError.len > 0:
      p.onlineStatusMsg = p.onlineRoom.lastError
    else:
      discard pollOnlineRoom(p.onlineRoom, DefaultApiBase, tr)
      p.onlineStatusMsg = fmt"Joined room {p.onlineRoom.code} as Seat {p.onlineRoom.seat + 1}!"
      discard saveProfile(p.profile)
    p.pushAudio(akUiTap)
  of baStartOnlineMatch:
    if p.onlineRoom.code.len == 6 and p.onlineRoom.players.len >= 2:
      var seats: array[4, SeatConfig]
      for k in 0 .. 3:
        seats[k] = SeatConfig(name: RealmNamePool[k], seatType: stClosed)
      for idx, pl in p.onlineRoom.players:
        if idx < 4:
          seats[idx] = SeatConfig(name: pl.displayName, seatType: stHuman)
      p.game = newPegsOfUrGame(seed = int64(max(1, p.onlineRoom.seed)))
      p.game.startGame(seats)
      p.viewedPlayerIdx = clamp(p.onlineRoom.seat, 0, p.game.players.len - 1)
      p.followActivePlayer = true
      p.selectedBuyAdv = -1
      p.divinationArmed = false
      p.lastSyncedRollSeq = -1
      p.onlineMatchActive = true
      p.appliedMoveSeq = 0
      p.onlinePollTimer = 0.0
      p.modal = mkNone
      p.onlineStatusMsg = fmt"Online match live in Room {p.onlineRoom.code} (Seat {p.onlineRoom.seat + 1})."
    p.pushAudio(akUiTap)
  of baPollOnlineRoom:
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    if pollOnlineRoom(p.onlineRoom, DefaultApiBase, tr):
      p.onlineStatusMsg = fmt"Room {p.onlineRoom.code}: {p.onlineRoom.players.len}/{p.onlineRoom.maxPlayers} seated ({p.onlineRoom.status})."
    else:
      p.onlineStatusMsg = "Could not refresh room state."
    p.pushAudio(akUiTap)
  of baOpenSupport:
    p.modal = mkSupport
    p.pushAudio(akUiTap)
  of baOpenStripeSupport1:
    p.pendingExternalUrl = buildSupportCheckoutUrl(p.profile.email, 1)
    p.onlineStatusMsg = "Opened voluntary $1 Stripe support link in browser."
    p.pushAudio(akUiTap)
  of baOpenStripeSupport5:
    p.pendingExternalUrl = buildSupportCheckoutUrl(p.profile.email, 5)
    p.onlineStatusMsg = "Opened voluntary $5 Stripe support link in browser."
    p.pushAudio(akUiTap)
  of baMarkSupported:
    p.profile.supported = true
    p.profile.supportTier = "Voluntary Supporter"
    discard saveProfile(p.profile)
    p.onlineStatusMsg = "Thank you! Unlimited online games unlocked."
    p.modal = mkNone
    p.pushAudio(akUiTap)
  of baDismissSupport:
    p.profile.supportPromptDismissed = true
    discard saveProfile(p.profile)
    p.modal = mkNone
    p.pushAudio(akUiTap)
  of baCycleSeatType:
    let i = btn.intParam
    p.seatConfigs[i].seatType = SeatType((ord(p.seatConfigs[i].seatType) + 1) mod 5)
    p.pushAudio(akUiTap)
  of baCycleSeatRealmName:
    let i = btn.intParam
    var nextIdx = 0
    for k, nm in RealmNamePool:
      if nm == p.seatConfigs[i].name:
        nextIdx = (k + 1) mod RealmNamePool.len
        break
    p.seatConfigs[i].name = RealmNamePool[nextIdx]
    p.pushAudio(akUiTap)
  of baPresetSolo:
    p.seatConfigs[0].seatType = stHuman
    for k in 1 .. 3:
      p.seatConfigs[k].seatType = stClosed
    p.pushAudio(akUiTap)
  of baPresetDuel:
    p.seatConfigs[0].seatType = stHuman
    p.seatConfigs[1].seatType = stAiHard
    p.seatConfigs[2].seatType = stClosed
    p.seatConfigs[3].seatType = stClosed
    p.pushAudio(akUiTap)
  of baPresetClassic4P:
    p.seatConfigs[0].seatType = stHuman
    p.seatConfigs[1].seatType = stAiNormal
    p.seatConfigs[2].seatType = stAiHard
    p.seatConfigs[3].seatType = stAiEasy
    p.pushAudio(akUiTap)
  of baStartConfiguredMatch:
    var activeCnt = 0
    for cfg in p.seatConfigs:
      if cfg.seatType != stClosed:
        inc activeCnt
    if activeCnt < 1:
      p.setupError = "Enable at least 1 Human or AI seat to begin."
      return true
    p.setupError = ""
    p.modal = mkNone
    p.followActivePlayer = true
    p.selectedBuyAdv = -1
    p.divinationArmed = false
    p.lastSyncedRollSeq = -1
    p.game.startGame(p.seatConfigs)
    p.pushAudio(akPegTap)
  of baRollSelected:
    discard p.game.rerollSelectedDice()
  of baSelectAllRerollable:
    p.game.selectAllRerollable()
    p.pushAudio(akUiTap)
  of baToggleDivination:
    p.divinationArmed = not p.divinationArmed
    p.pushAudio(akUiTap)
  of baExorcism:
    if p.game.useExorcism():
      p.pushAudio(akOmenThud)
  of baKeepDiceAndHarvest:
    p.pushAudio(akPegTap)
    p.game.finishRolling()
  of baFlipChoiceDie:
    if p.game.toggleChoiceDie(btn.intParam):
      p.pushAudio(akPegTap, 0.85, 1.06)
  of baConfirmChoices:
    p.pushAudio(akPegTap)
    p.game.confirmChoices()
  of baBuildSettlementOne:
    if p.game.addBuilderToSettlement(1) > 0:
      p.pushAudio(akBuild)
  of baBuildSettlementFinish:
    if p.game.addBuilderToSettlement(btn.intParam) > 0:
      p.pushAudio(akBuild)
  of baBuildWorkOne:
    if p.game.addBuilderToGreatWork(btn.intParam, 1) > 0:
      p.pushAudio(akBuild)
  of baBuildWorkBulk:
    if p.game.addBuilderToGreatWork(btn.intParam, btn.intParam2) > 0:
      p.pushAudio(akBuild)
  of baConvertCranes:
    if p.game.convertAlabasterToBuilders(1):
      p.pushAudio(akBuild)
  of baAtonement:
    if p.game.useAtonement():
      p.pushAudio(akFanfare, 0.65, 1.15)
  of baResetBuild:
    if p.game.resetBuildStep():
      p.pushAudio(akUiTap)
  of baFinishBuilding:
    p.pushAudio(akUiTap)
    p.game.finishBuilding()
  of baSelectAdvCustomPay:
    p.selectAdvForCustomPay(btn.intParam)
    p.pushAudio(akUiTap)
  of baAutoBuyAdv:
    if p.game.buyAdvancement(btn.intParam):
      p.pushAudio(akCoin)
  of baToggleBuyWareRow:
    let wt = WareType(btn.intParam)
    if p.game.players[p.game.activePlayerIdx].wares[wt] > 0:
      p.buyWaresMask[wt] = not p.buyWaresMask[wt]
      p.pushAudio(akPegTap, 0.85, 1.04)
  of baSiloMinus:
    p.buySiloGrain = max(0, p.buySiloGrain - 1)
    p.pushAudio(akPegTap, 0.85, 0.95)
  of baSiloPlus:
    let maxG = p.game.players[p.game.activePlayerIdx].grain
    p.buySiloGrain = min(maxG, p.buySiloGrain + 1)
    p.pushAudio(akPegTap, 0.85, 1.06)
  of baConfirmCustomBuy:
    var maskSeq: array[5, bool]
    for wt in WareType:
      maskSeq[ord(wt)] = p.buyWaresMask[wt]
    if p.game.buyAdvancement(p.selectedBuyAdv, maskSeq, p.buySiloGrain):
      p.pushAudio(akCoin)
  of baCancelCustomBuy:
    p.selectedBuyAdv = -1
    p.pushAudio(akUiTap)
  of baSkipBuying:
    p.pushAudio(akUiTap)
    p.game.skipBuying()
  of baDiscardWare:
    if p.game.discardOneWare(WareType(btn.intParam)):
      p.pushAudio(akPegTap, 0.85, 0.88)

  if p.onlineMatchActive and not p.replayingRemote and isGameplayAction(btn.action):
    let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
    if submitOnlineMove(p.onlineRoom, $btn.action, %*{"p1": btn.intParam, "p2": btn.intParam2}, DefaultApiBase, tr):
      p.appliedMoveSeq = p.onlineRoom.turnSeq

  p.syncFromGame()
  p.rebuildButtons()
  true

proc syncOnlineRoom*(p: PegsOfUrPresenter): int =
  if p.onlineRoom.code.len != 6:
    return 0
  let tr = if p.httpTransport.isNil: defaultHttpTransport else: p.httpTransport
  if not pollOnlineRoom(p.onlineRoom, DefaultApiBase, tr):
    return 0
  if not p.onlineMatchActive:
    p.rebuildButtons()
    return 0
  var applied = 0
  for m in p.onlineRoom.moves:
    if m.seqNum <= p.appliedMoveSeq:
      continue
    p.appliedMoveSeq = m.seqNum
    if m.seat == p.onlineRoom.seat:
      continue
    let act = parseButtonAction(m.action)
    if act != baNone:
      p.replayingRemote = true
      discard p.executeButtonAction(UiButton(action: act, intParam: m.p1, intParam2: m.p2, enabled: true))
      p.replayingRemote = false
      inc applied
  applied

proc onMouseMove*(p: PegsOfUrPresenter; mx, my: float) =
  p.hoveredButtonIdx = -1
  for i in countdown(p.buttons.len - 1, 0):
    if p.buttons[i].rect.contains(mx, my):
      p.hoveredButtonIdx = i
      break

  if p.modal != mkNone:
    p.tray.hoveredDie = -1
    p.pegboard.hoveredWareRow = -1
    return

  p.tray.hoveredDie = p.tray.dieAt(mx, my)
  p.pegboard.hoveredWareRow = p.pegboard.wareRowAt(mx, my)

proc onMouseClick*(p: PegsOfUrPresenter; mx, my: float): bool =
  for i in countdown(p.buttons.len - 1, 0):
    if p.buttons[i].rect.contains(mx, my):
      return p.executeButtonAction(p.buttons[i])

  if p.modal != mkNone:
    return false

  let hitDie = p.tray.dieAt(mx, my)
  if p.isDieClickable(hitDie):
    if p.game.phase == phRoll:
      if p.divinationArmed:
        p.divinationArmed = false
        discard p.game.rerollSingleWithDivination(hitDie)
      elif p.game.toggleDieForReroll(hitDie):
        p.pushAudio(akUiTap)
    elif p.game.phase == phAssignChoices:
      if p.game.toggleChoiceDie(hitDie):
        p.pushAudio(akPegTap, 0.85, 1.08)
    p.syncFromGame()
    p.rebuildButtons()
    return true

  if p.viewedPlayerIdx == p.game.activePlayerIdx and p.game.isActiveHuman():
    let hitRow = p.pegboard.wareRowAt(mx, my)
    if hitRow >= 0:
      let wt = WareType(hitRow)
      if p.game.phase == phDiscard and p.game.discardOneWare(wt):
        p.pushAudio(akPegTap, 0.85, 0.88)
        p.syncFromGame()
        p.rebuildButtons()
        return true
      elif p.game.phase == phBuy and p.selectedBuyAdv >= 0 and p.game.players[p.game.activePlayerIdx].wares[wt] > 0:
        p.buyWaresMask[wt] = not p.buyWaresMask[wt]
        p.pushAudio(akPegTap, 0.85, 1.04)
        p.rebuildButtons()
        return true

  false

proc onMouseWheel*(p: PegsOfUrPresenter; mx, my, wheelDelta: float): bool =
  if p.modal != mkNone:
    return false
  let aa = p.advancementsAreaRect()
  if aa.contains(mx, my):
    let maxScroll = max(0.0, float(Advancements.len) * 44.0 - aa.h)
    p.advScrollOffset = clamp(p.advScrollOffset + wheelDelta * 32.0, 0.0, maxScroll)
    p.rebuildButtons()
    return true
  false

proc tick*(p: PegsOfUrPresenter; delta: float) =
  let dt = clamp(delta, 0.0, 0.1)
  if p.calamityTimer > 0.0:
    p.calamityTimer = max(0.0, p.calamityTimer - dt)

  let wasAnim = p.tray.isAnimating()
  p.tray.stepTray(dt, p.audioQueue)
  p.pegboard.stepPegboard(dt)

  if p.modal == mkNone and p.game.phase notin {phSetup, phGameOver} and not p.game.isActiveHuman():
    if not p.tray.isAnimating():
      p.aiWaitTimer -= dt
      if p.aiWaitTimer <= 0.0:
        p.aiWaitTimer = aiSpeedDelay(p.aiSpeed)
        takeStep(p.game)
        p.syncFromGame()
        p.rebuildButtons()
        return

  if p.onlineMatchActive and p.game.phase notin {phSetup, phGameOver} and
      p.game.activePlayerIdx != p.onlineRoom.seat:
    p.onlinePollTimer += dt
    if p.onlinePollTimer >= 1.5:
      p.onlinePollTimer = 0.0
      discard p.syncOnlineRoom()
  elif p.modal == mkOnlineLobby and p.onlineRoom.code.len == 6:
    p.onlinePollTimer += dt
    if p.onlinePollTimer >= 1.5:
      p.onlinePollTimer = 0.0
      discard p.syncOnlineRoom()

  if wasAnim and not p.tray.isAnimating():
    p.rebuildButtons()
