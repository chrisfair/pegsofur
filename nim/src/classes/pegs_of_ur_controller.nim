## Godot 4 GDExtension wooden tabletop renderer & audio controller for Pegs of Ur.

import std/[math, random, strformat]
import gdext
import gdext/classes/[
  gdengine,
  gdnode,
  gdnode2d,
  gdcanvasitem,
  gddisplayserver,
  gdresourceloader,
  gdtexture2d,
  gdaudiostream,
  gdaudiostreamplayer,
  gdinputevent,
  gdinputeventmousebutton,
  gdinputeventmousemotion,
  gdthemedb,
  gdfont,
]

import ../sim/[data, entropy, game, physics, presenter]

const AudioPoolSize = 14

type PegsOfUrController* {.gdsync.} = ptr object of Node2D
  presenter: PegsOfUrPresenter
  headless: bool
  rng: Rand

  tableBgTex: gdref Texture2D
  pegboardTex: gdref Texture2D
  diceTrayTex: gdref Texture2D
  parchmentTex: gdref Texture2D
  pegHoleTex: gdref Texture2D
  grainPegTex: gdref Texture2D
  warePegTex: array[WareType, gdref Texture2D]
  dieFaceTex: array[DieFace, gdref Texture2D]

  audioPlayers: array[AudioPoolSize, AudioStreamPlayer]
  audioCursor: int
  settleCursor: int
  bounceForte: array[2, gdref AudioStream]
  bounceMp: gdref AudioStream
  bounceSettle: array[3, gdref AudioStream]
  pegStream: gdref AudioStream
  omenStream: gdref AudioStream
  buildStream: gdref AudioStream
  coinStream: gdref AudioStream
  disasterStream: gdref AudioStream
  fanfareStream: gdref AudioStream

proc toGdColor(c: Rgba): Color {.inline.} =
  color(c.r, c.g, c.b, c.a)

proc toGdRect(rc: UiRect): Rect2 {.inline.} =
  rect2(rc.x, rc.y, rc.w, rc.h)

proc loadTex(path: string): gdref Texture2D =
  let rl = ResourceLoader.singleton
  let gPath = newGdString(path)
  if rl.exists(gPath):
    return rl.load(gPath) as gdref Texture2D
  default(gdref Texture2D)

proc loadStream(path: string): gdref AudioStream =
  let rl = ResourceLoader.singleton
  let gPath = newGdString(path)
  if rl.exists(gPath):
    return rl.load(gPath) as gdref AudioStream
  default(gdref AudioStream)

proc playStream(self: PegsOfUrController; stream: gdref AudioStream; volDb, pitch: float) =
  if self.headless or stream[].isNil:
    return
  let pl = self.audioPlayers[self.audioCursor]
  self.audioCursor = (self.audioCursor + 1) mod AudioPoolSize
  if pl.isNil:
    return
  pl.setStream(stream)
  pl.setVolumeDb(volDb)
  pl.setPitchScale(pitch)
  pl.play()

proc dispatchAudioEvent(self: PegsOfUrController; ev: AudioEvent) =
  if self.headless:
    return
  case ev.kind
  of akWoodBounce:
    let clamped = clamp(ev.energy, 0.06, 1.0)
    let st =
      if clamped >= 0.66:
        self.bounceForte[self.rng.rand(0 .. 1)]
      elif clamped >= 0.34:
        self.bounceMp
      else:
        let idx = self.settleCursor mod 3
        inc self.settleCursor
        self.bounceSettle[idx]
    let pitch = self.rng.rand(0.90 .. 1.08) + (1.0 - clamped) * 0.08
    let volDb = -17.0 + sqrt(clamped) * 14.5
    self.playStream(st, volDb, pitch)
  of akPegTap:
    self.playStream(self.pegStream, -4.0, clamp(ev.pitch * self.rng.rand(0.95 .. 1.05), 0.75, 1.40))
  of akOmenThud:
    self.playStream(self.omenStream, -2.0, self.rng.rand(0.92 .. 1.02))
  of akUiTap:
    self.playStream(self.bounceSettle[1], -11.0, self.rng.rand(1.06 .. 1.16))
  of akBuild:
    self.playStream(self.pegStream, -5.5, 0.88)
    self.playStream(self.buildStream, -9.0, self.rng.rand(0.96 .. 1.05))
  of akCoin:
    self.playStream(self.coinStream, -7.5, self.rng.rand(0.97 .. 1.04))
  of akDisaster:
    self.playStream(self.omenStream, -3.0, 0.94)
    self.playStream(self.disasterStream, -6.5, 1.0)
  of akFanfare:
    self.playStream(self.fanfareStream, -6.0, 1.0)

proc drawText(
  self: PegsOfUrController;
  font: gdref Font;
  x, y: float;
  txt: string;
  size: int32 = 13;
  col: Color = color(0.96, 0.90, 0.76, 1.0);
  maxW: float = -1.0;
  align: HorizontalAlignment = horizontalAlignmentLeft;
  shadow: bool = false
) =
  if font[].isNil or txt.len == 0:
    return
  let gStr = newGdString(txt)
  if shadow:
    self.drawString(font, vector2(x + 1.0, y + 1.5), gStr, align, maxW, size, color(0.04, 0.02, 0.01, 0.88))
  self.drawString(font, vector2(x, y), gStr, align, maxW, size, col)

proc drawWoodCard(self: PegsOfUrController; rc: UiRect; bg, border: Color; width: float = 2.0) =
  let gr = rc.toGdRect()
  self.drawRect(gr, bg, filled = true)
  self.drawRect(gr, border, filled = false, width = width)

proc progressBoxes(prog, total: int): string =
  for i in 0 ..< total:
    result.add(if i < prog: "■" else: "□")
    if (i + 1) mod 5 == 0 and i + 1 < total:
      result.add(" ")

method ready*(self: PegsOfUrController) {.gdsync.} =
  self.rng = initRand(hardwareOrTimerSeed64())
  self.headless = ($DisplayServer.singleton.getName() == "headless")

  for i in 0 ..< AudioPoolSize:
    let p = instantiate(AudioStreamPlayer)
    self.addChild(p)
    self.audioPlayers[i] = p

  self.tableBgTex = loadTex("res://assets/textures/table_bg.png")
  self.pegboardTex = loadTex("res://assets/textures/pegboard_panel.png")
  self.diceTrayTex = loadTex("res://assets/textures/dice_tray_panel.png")
  self.parchmentTex = loadTex("res://assets/textures/parchment_panel.png")
  self.pegHoleTex = loadTex("res://assets/pegs/peg_hole.png")
  self.grainPegTex = loadTex("res://assets/pegs/peg_grain.png")
  self.warePegTex[wtTimber] = loadTex("res://assets/pegs/peg_timber.png")
  self.warePegTex[wtAlabaster] = loadTex("res://assets/pegs/peg_alabaster.png")
  self.warePegTex[wtCeramics] = loadTex("res://assets/pegs/peg_ceramics.png")
  self.warePegTex[wtLinen] = loadTex("res://assets/pegs/peg_linen.png")
  self.warePegTex[wtIngots] = loadTex("res://assets/pegs/peg_ingots.png")

  for df in DieFace:
    self.dieFaceTex[df] = loadTex(fmt"res://assets/dice/die_face_{ord(df)}.png")

  self.bounceForte[0] = loadStream("res://assets/audio/wood_bounce_f1.wav")
  self.bounceForte[1] = loadStream("res://assets/audio/wood_bounce_f2.wav")
  self.bounceMp = loadStream("res://assets/audio/wood_bounce_mp.wav")
  self.bounceSettle[0] = loadStream("res://assets/audio/wood_settle_1.wav")
  self.bounceSettle[1] = loadStream("res://assets/audio/wood_settle_2.wav")
  self.bounceSettle[2] = loadStream("res://assets/audio/wood_settle_3.wav")
  self.pegStream = loadStream("res://assets/audio/peg_wood.wav")
  self.omenStream = loadStream("res://assets/audio/omen_thud.wav")
  self.buildStream = loadStream("res://assets/audio/build_chisel.wav")
  self.coinStream = loadStream("res://assets/audio/coin_clink.wav")
  self.disasterStream = loadStream("res://assets/audio/disaster_horn.wav")
  self.fanfareStream = loadStream("res://assets/audio/victory_lyre.wav")

  let vp = self.getViewportRect()
  let w = if vp.size.x > 200.0: float(vp.size.x) else: 1680.0
  let h = if vp.size.y > 200.0: float(vp.size.y) else: 960.0
  self.presenter = newPegsOfUrPresenter(w, h, showSetupModal = not self.headless)
  for ev in self.presenter.popAudioEvents():
    self.dispatchAudioEvent(ev)
  self.queueRedraw()

method process*(self: PegsOfUrController; delta: float64) {.gdsync.} =
  if self.presenter.isNil or Engine.singleton.isEditorHint():
    return
  let vp = self.getViewportRect()
  if vp.size.x > 200.0 and vp.size.y > 200.0:
    if abs(float(vp.size.x) - self.presenter.screenW) > 0.5 or abs(float(vp.size.y) - self.presenter.screenH) > 0.5:
      self.presenter.screenW = float(vp.size.x)
      self.presenter.screenH = float(vp.size.y)
      self.presenter.syncFromGame()
      self.presenter.rebuildButtons()

  self.presenter.tick(float(delta))
  for ev in self.presenter.popAudioEvents():
    self.dispatchAudioEvent(ev)
  self.queueRedraw()

method input*(self: PegsOfUrController; event: gdref InputEvent) {.gdsync.} =
  if self.presenter.isNil or event[].isNil or Engine.singleton.isEditorHint():
    return
  let mm = event[] as InputEventMouseMotion
  if not mm.isNil:
    let pos = mm.getPosition()
    self.presenter.onMouseMove(float(pos.x), float(pos.y))
    return

  let mb = event[] as InputEventMouseButton
  if not mb.isNil and mb.isPressed():
    let pos = mb.getPosition()
    let btn = mb.getButtonIndex()
    if btn == mouseButtonLeft:
      discard self.presenter.onMouseClick(float(pos.x), float(pos.y))
    elif btn == mouseButtonWheelUp:
      discard self.presenter.onMouseWheel(float(pos.x), float(pos.y), -1.0)
    elif btn == mouseButtonWheelDown:
      discard self.presenter.onMouseWheel(float(pos.x), float(pos.y), 1.0)
    for ev in self.presenter.popAudioEvents():
      self.dispatchAudioEvent(ev)

proc drawPegboard(self: PegsOfUrController; font: gdref Font) =
  let p = self.presenter
  let pb = p.pegboard
  let rc = pb.rect

  if not self.pegboardTex[].isNil:
    self.drawTextureRect(self.pegboardTex, rc.toGdRect(), tile = false)
  else:
    self.drawWoodCard(rc, color(0.32, 0.18, 0.09, 1.0), color(0.76, 0.56, 0.28, 1.0))

  let goldInk = color(0.98, 0.90, 0.72, 0.96)
  let creamInk = color(0.94, 0.85, 0.68, 0.92)
  let dimInk = color(0.76, 0.66, 0.50, 0.78)

  let vp = p.game.players[p.viewedPlayerIdx]
  let hasFleets = p.game.playerHasAdv(p.viewedPlayerIdx, "merchant_fleets")
  let totWares = p.game.playerTotalWares(p.viewedPlayerIdx)
  let totSilver = p.game.playerWaresSilverValue(p.viewedPlayerIdx)

  self.drawText(font, rc.x + 28.0, rc.y + 28.0, "WARES & GRAIN PEGBOARD", 13, goldInk, shadow = true)
  let capTxt =
    if hasFleets: fmt"Wares: {totWares} (No Cap) • {totSilver}s"
    else: fmt"Wares: {totWares}/6 • Value: {totSilver}s"
  let capCol =
    if not hasFleets and totWares > DefaultWaresLimit: color(1.0, 0.50, 0.42, 0.98)
    else: creamInk
  self.drawText(font, rc.x + rc.w * 0.40, rc.y + 28.0, capTxt, 13, capCol, rc.w * 0.60 - 28.0, horizontalAlignmentRight, shadow = true)

  let isActHuman = (p.viewedPlayerIdx == p.game.activePlayerIdx and p.game.isActiveHuman())
  let interDiscard = (isActHuman and p.game.phase == phDiscard)
  let interBuy = (isActHuman and p.game.phase == phBuy and p.selectedBuyAdv >= 0)
  let holeSz = vector2(22.0, 22.0)
  let pegSz = vector2(30.0, 30.0)

  for wt in WareType:
    let rowRc = pb.wareRowRect(wt)
    let cy = pb.wareRowY(wt)
    let isHover = (pb.hoveredWareRow == ord(wt) and pb.waresQty[wt] > 0)

    if interDiscard and pb.waresQty[wt] > 0:
      self.drawRect(rowRc.toGdRect(), color(0.88, 0.24, 0.16, if isHover: 0.30 else: 0.15), filled = true)
      self.drawRect(rowRc.toGdRect(), color(0.95, 0.38, 0.28, 0.75), filled = false, width = 1.5)
    elif interBuy and p.buyWaresMask[wt]:
      self.drawRect(rowRc.toGdRect(), color(0.95, 0.78, 0.20, 0.24), filled = true)
      self.drawRect(rowRc.toGdRect(), color(0.98, 0.82, 0.28, 0.85), filled = false, width = 1.8)

    self.drawCircle(vector2(rc.x + 21.0, cy), 5.5, WareColors[wt].toGdColor())
    self.drawArc(vector2(rc.x + 21.0, cy), 5.5, 0.0, TAU, 18, color(0.98, 0.90, 0.74, 0.55), 1.2)
    self.drawText(font, rc.x + 31.0, cy + 5.0, WareNames[wt], 13, goldInk, shadow = true)

    let maxQ = wareMaxQty(wt)
    for q in 0 .. maxQ:
      let (hx, hy) = pb.wareHoleCenter(wt, q)
      if q < maxQ:
        let (nx, ny) = pb.wareHoleCenter(wt, q + 1)
        self.drawLine(vector2(hx, hy), vector2(nx, ny), color(0.88, 0.72, 0.44, 0.28), 2.2)
      if not self.pegHoleTex[].isNil:
        self.drawTextureRect(self.pegHoleTex, rect2(hx - 11.0, hy - 11.0, holeSz.x, holeSz.y), tile = false)
      let val = wareSilverValue(wt, q)
      let activeHole = (q == pb.waresQty[wt] and q > 0)
      self.drawText(
        font,
        hx - 14.0,
        hy + 20.0,
        if q == 0: "0" else: $val,
        11,
        if activeHole: color(1.0, 0.92, 0.52, 1.0) elif q > 0: creamInk else: dimInk,
        28.0,
        horizontalAlignmentCenter,
        shadow = true,
      )

  let divY = rc.y + rc.h - 102.0
  self.drawLine(vector2(rc.x + 18.0, divY), vector2(rc.x + rc.w - 18.0, divY), color(0.06, 0.03, 0.01, 0.72), 2.0)
  self.drawLine(vector2(rc.x + 18.0, divY + 2.0), vector2(rc.x + rc.w - 18.0, divY + 2.0), color(0.92, 0.78, 0.50, 0.36), 1.2)

  self.drawCircle(vector2(rc.x + 22.0, rc.y + rc.h - 54.0), 6.0, color(0.38, 0.78, 0.30, 1.0))
  self.drawText(font, rc.x + 33.0, rc.y + rc.h - 56.0, "Grain", 14, goldInk, shadow = true)
  self.drawText(font, rc.x + 33.0, rc.y + rc.h - 39.0, fmt"{vp.grain} / 15", 12, creamInk, shadow = true)

  for gq in 0 .. MaxGrain:
    let (gx, gy) = pb.grainHoleCenter(gq)
    if gq != 7 and gq < MaxGrain:
      let (ngx, ngy) = pb.grainHoleCenter(gq + 1)
      self.drawLine(vector2(gx, gy), vector2(ngx, ngy), color(0.88, 0.72, 0.44, 0.24), 2.0)
    if not self.pegHoleTex[].isNil:
      self.drawTextureRect(self.pegHoleTex, rect2(gx - 11.0, gy - 11.0, holeSz.x, holeSz.y), tile = false)
    self.drawText(
      font,
      gx - 12.0,
      gy + 18.0,
      $gq,
      10,
      if gq == vp.grain: color(0.68, 1.0, 0.58, 1.0) else: creamInk,
      24.0,
      horizontalAlignmentCenter,
      shadow = true,
    )

  for wt in WareType:
    let px = pb.warePosX[wt]
    let py = pb.warePosY[wt]
    if interBuy and p.buyWaresMask[wt]:
      self.drawArc(vector2(px, py), 16.5, 0.0, TAU, 28, color(1.0, 0.86, 0.24, 0.95), 2.6)
    elif interDiscard and pb.hoveredWareRow == ord(wt) and pb.waresQty[wt] > 0:
      self.drawArc(vector2(px, py), 16.5, 0.0, TAU, 28, color(0.95, 0.28, 0.20, 0.95), 2.6)
    let tex = self.warePegTex[wt]
    if not tex[].isNil:
      self.drawTextureRect(tex, rect2(px - pegSz.x * 0.5, py - pegSz.y * 0.5, pegSz.x, pegSz.y), tile = false)

  if not self.grainPegTex[].isNil:
    self.drawTextureRect(self.grainPegTex, rect2(pb.grainPosX - pegSz.x * 0.5, pb.grainPosY - pegSz.y * 0.5, pegSz.x, pegSz.y), tile = false)

proc drawDiceTray(self: PegsOfUrController; font: gdref Font) =
  let p = self.presenter
  let tray = p.tray
  let rc = tray.rect

  if not self.diceTrayTex[].isNil:
    self.drawTextureRect(self.diceTrayTex, rc.toGdRect(), tile = false)
  else:
    self.drawWoodCard(rc, color(0.28, 0.16, 0.08, 1.0), color(0.76, 0.56, 0.28, 1.0))

  var hint = "WOODEN DICE TRAY"
  if p.game.isActiveHuman() and not tray.isAnimating():
    if p.game.phase == phRoll:
      if p.divinationArmed:
        hint = "DIVINATION ARMED — Click ANY single die (even a locked Omen) to reroll it!"
      elif p.game.rollsUsed < p.game.maxRolls:
        hint = fmt"Cast {p.game.rollsUsed}/{p.game.maxRolls} — Click dice to mark REROLL, or Keep Dice & Gather"
      else:
        hint = "Cast 3/3 complete — Review dice (or use Divination if unlocked)"
    elif p.game.phase == phAssignChoices:
      hint = "Click each [2 Grain / 2 Builders] die to flip between Grain and Builders"

  self.drawText(font, rc.x + 24.0, rc.y + 23.0, hint, 13, color(0.96, 0.89, 0.74, 0.95), rc.w - 48.0, shadow = true)

  let dieW = tray.effectiveDieSize()

  for d in tray.dice:
    if d.delay > 0.0 and not d.settled:
      continue
    let zNorm = clamp(d.z / 100.0, 0.0, 1.0)
    let sw = dieW * (0.96 - zNorm * 0.22)
    let sa = 0.42 - zNorm * 0.26
    self.drawSetTransform(vector2(d.posX + 5.0 + d.z * 0.24, d.posY + 7.0 + d.z * 0.30), d.angle, vector2(1.0, 1.0))
    self.drawRect(rect2(-sw * 0.48, -sw * 0.48, sw * 0.96, sw * 0.96), color(0.05, 0.02, 0.01, sa), filled = true)
    self.drawSetTransform(vector2(0.0, 0.0), 0.0, vector2(1.0, 1.0))

  for i, d in tray.dice:
    if d.delay > 0.0 and not d.settled:
      continue
    let liftScale = 1.0 + clamp(d.z / 260.0, 0.0, 0.34)
    let dw = dieW * liftScale
    let cx = d.posX
    let cy = d.posY - d.z * 0.55

    self.drawSetTransform(vector2(cx, cy), d.angle, vector2(1.0, 1.0))
    let dRect = rect2(-dw * 0.5, -dw * 0.5, dw, dw)
    let tex = self.dieFaceTex[d.displayFace]
    if not tex[].isNil:
      self.drawTextureRect(tex, dRect, tile = false)

    if d.settled:
      let selReroll = (i < p.game.diceSelectedForReroll.len and p.game.diceSelectedForReroll[i] and p.game.phase == phRoll)
      let lockedOmen = (d.displayFace == dfOmenWares2 and not p.game.isSolo() and p.game.phase == phRoll)
      let ringRect = rect2(-dw * 0.5 - 3.0, -dw * 0.5 - 3.0, dw + 6.0, dw + 6.0)
      if p.divinationArmed and tray.hoveredDie == i:
        self.drawRect(ringRect, color(0.98, 0.78, 0.22, 0.95), filled = false, width = 3.0)
      elif selReroll:
        self.drawRect(ringRect, color(0.98, 0.76, 0.18, 0.95), filled = false, width = 3.2)
      elif lockedOmen:
        self.drawRect(ringRect, color(0.78, 0.18, 0.15, 0.90), filled = false, width = 2.4)
      elif tray.hoveredDie == i and p.isDieClickable(i):
        self.drawRect(ringRect, color(1.0, 0.94, 0.75, 0.78), filled = false, width = 2.2)

    self.drawSetTransform(vector2(0.0, 0.0), 0.0, vector2(1.0, 1.0))

    if d.settled:
      var badge = dieFaceLabel(d.displayFace)
      var bCol = color(0.96, 0.90, 0.78, 0.94)
      if p.game.phase == phRoll:
        if i < p.game.diceSelectedForReroll.len and p.game.diceSelectedForReroll[i]:
          badge = "REROLL"
          bCol = color(1.0, 0.84, 0.28, 1.0)
        elif d.displayFace == dfOmenWares2 and not p.game.isSolo():
          badge = "OMEN LOCKED"
          bCol = color(1.0, 0.46, 0.38, 1.0)
      elif d.displayFace == dfGrainOrBuilders2 and p.game.phase in {phAssignChoices, phBuild, phBuy}:
        let isB = (i < p.game.choiceIsBuilders.len and p.game.choiceIsBuilders[i])
        badge = if isB: "2 Builders" else: "2 Grain"
        bCol = if isB: color(0.58, 0.84, 1.0, 1.0) else: color(0.64, 0.96, 0.54, 1.0)
      self.drawText(font, cx - 56.0, cy + dw * 0.5 + 15.0, badge, 11, bCol, 112.0, horizontalAlignmentCenter, shadow = true)

proc drawButtons(self: PegsOfUrController; font: gdref Font) =
  let p = self.presenter
  for idx, btn in p.buttons:
    let isHover = (idx == p.hoveredButtonIdx and btn.enabled)
    var bg = btn.bg
    if not btn.enabled:
      bg = rgba(0.20'f32, 0.14'f32, 0.10'f32, 0.65'f32)
    elif isHover:
      bg = rgba(min(1.0'f32, bg.r + 0.09'f32), min(1.0'f32, bg.g + 0.08'f32), min(1.0'f32, bg.b + 0.06'f32), bg.a)

    let brd =
      if not btn.enabled: color(0.38, 0.28, 0.20, 0.50)
      elif isHover or btn.active: color(0.99, 0.86, 0.38, 1.0)
      else: btn.border.toGdColor()

    self.drawWoodCard(btn.rect, bg.toGdColor(), brd, if btn.active: 2.4 else: 1.8)
    let fg = if btn.enabled: color(0.99, 0.94, 0.84, 1.0) else: color(0.60, 0.54, 0.46, 0.85)
    self.drawText(
      font,
      btn.rect.x + 6.0,
      btn.rect.y + btn.rect.h * 0.64,
      btn.label,
      12,
      fg,
      btn.rect.w - 12.0,
      horizontalAlignmentCenter,
      shadow = true,
    )

proc drawModal(self: PegsOfUrController; font: gdref Font) =
  let p = self.presenter
  if p.modal == mkNone:
    return
  self.drawRect(rect2(0.0, 0.0, p.screenW, p.screenH), color(0.04, 0.02, 0.01, 0.78), filled = true)
  let mr = p.modalCardRect()
  self.drawWoodCard(mr, color(0.19, 0.11, 0.05, 0.98), color(0.88, 0.68, 0.34, 0.96), 2.5)

  case p.modal
  of mkSetup:
    self.drawText(font, mr.x + 20.0, mr.y + 36.0, "PEGS OF UR — CRADLE OF REALMS", 20, color(0.99, 0.90, 0.68, 1.0), mr.w - 40.0, horizontalAlignmentCenter, shadow = true)
    self.drawText(font, mr.x + 20.0, mr.y + 62.0, "Configure 1 to 4 City-State Realms (1 Active Seat = 10-Round Solo Chronicle)", 12, color(0.86, 0.78, 0.64, 1.0), mr.w - 40.0, horizontalAlignmentCenter)
    for i in 0 ..< 4:
      let ry = mr.y + 92.0 + float(i) * 46.0
      self.drawRect(rect2(mr.x + 26.0, ry + 3.0, 14.0, 28.0), RealmDefaults[i].color.toGdColor(), filled = true)
      self.drawText(font, mr.x + 48.0, ry + 22.0, fmt"Seat {i + 1}:", 13, color(0.95, 0.88, 0.74, 1.0))
    if p.setupError.len > 0:
      self.drawText(font, mr.x + 20.0, mr.y + 356.0, p.setupError, 13, color(1.0, 0.46, 0.38, 1.0), mr.w - 40.0, horizontalAlignmentCenter)

  of mkRules:
    self.drawText(font, mr.x + 20.0, mr.y + 34.0, "PEGS OF UR — HOW TO PLAY", 18, color(0.99, 0.90, 0.68, 1.0), mr.w - 40.0, horizontalAlignmentCenter, shadow = true)
    let lines = [
      "1. CAST DICE (Up to 3 Casts): Roll 1 wooden die per Settlement you rule (start with 3 Settlements & 3 Grain, max 7).",
      "   Omen faces (2 Wares + Omen) lock immediately unless rerolled via Divination (1 die/turn) or in 1P Solo.",
      "2. GATHER & FEED: Assign [2 Grain / 2 Builders] dice. Wares advance bottom-to-top (Timber -> Ingots).",
      "   Each Settlement consumes 1 Grain; any unfed Settlement suffers Starvation (-1 Renown).",
      "3. OMEN CALAMITIES:",
      "   • 0-1 Omen: Clear skies.",
      "   • 2 Omens (Blight): -2 Renown to you (negated by Canals).",
      "   • 3 Omens (Plague): -3 Renown to ALL RIVALS (negated per rival by Herbalism; strikes YOU in 1P Solo).",
      "   • 4 Omens (Raiders): -4 Renown to you (negated by completed Citadel Ramparts).",
      "   • 5+ Omens (Uprising): Lose ALL stored Wares (with Priesthood, rivals without Priesthood lose all Wares!).",
      "4. CONSTRUCT: Spend Builders on Settlements (costs 3,4,5,6) and Great Works. First finisher claims top Renown.",
      "5. UNLOCK 1 ADVANCEMENT: Spend turn Silver + Ware tracks (whole-track rule: all pegs in a spent row reset to 0).",
      "6. STORAGE & END OF ERA: Keep at most 6 Wares unless holding Merchant Fleets. Equal-turns final round triggers",
      "   when any realm unlocks 5 Advancements or every active Great Work stands complete (or Round 10 in Solo).",
      "   Tiebreaker: highest Silver value of remaining Wares on your Pegboard.",
    ]
    var ly = mr.y + 72.0
    for ln in lines:
      self.drawText(font, mr.x + 28.0, ly, ln, 13, color(0.94, 0.88, 0.76, 1.0))
      ly += 30.0

  of mkGameOver:
    self.drawText(font, mr.x + 20.0, mr.y + 36.0, "ERA COMPLETE — FINAL REALM STANDINGS", 19, color(0.99, 0.90, 0.68, 1.0), mr.w - 40.0, horizontalAlignmentCenter, shadow = true)
    let standings = p.game.getStandings()
    if standings.len > 0:
      let sub =
        if p.game.isSolo(): fmt"10-Round Solo Renown: {standings[0].totalVp} VP  (Remaining Wares: {standings[0].tiebreakerWaresValue}s)"
        else: fmt"Sovereign Victor: {standings[0].name} with {standings[0].totalVp} Renown!  ({p.game.finalTriggerReason})"
      self.drawText(font, mr.x + 20.0, mr.y + 64.0, sub, 14, color(0.90, 0.82, 0.66, 1.0), mr.w - 40.0, horizontalAlignmentCenter)

      let hy = mr.y + 104.0
      let cols = [("Rank / Realm", 24.0), ("Great Works", 230.0), ("Advancements", 335.0), ("Bonus", 455.0), ("Calamities", 520.0), ("Renown", 612.0), ("Wares", 685.0)]
      for c in cols:
        self.drawText(font, mr.x + c[1], hy, c[0], 12, color(0.86, 0.74, 0.50, 1.0))

      for rank, s in standings:
        let ry = mr.y + 122.0 + float(rank) * 52.0
        let rowRc = uiRect(mr.x + 18.0, ry, mr.w - 36.0, 44.0)
        self.drawWoodCard(
          rowRc,
          color(s.color.r * 0.35, s.color.g * 0.35, s.color.b * 0.35, 0.92),
          if rank == 0: color(0.99, 0.84, 0.32, 1.0) else: color(0.52, 0.38, 0.22, 0.85),
        )
        self.drawText(font, mr.x + 28.0, ry + 27.0, fmt"#{rank + 1}  {s.name}", 14, color(0.99, 0.95, 0.86, 1.0))
        self.drawText(font, mr.x + 245.0, ry + 27.0, fmt"+{s.worksVp}", 13, color(0.95, 0.90, 0.80, 1.0))
        self.drawText(font, mr.x + 350.0, ry + 27.0, fmt"+{s.advancementsVp}", 13, color(0.95, 0.90, 0.80, 1.0))
        self.drawText(font, mr.x + 460.0, ry + 27.0, fmt"+{s.bonusVp}", 13, color(0.95, 0.90, 0.80, 1.0))
        self.drawText(font, mr.x + 535.0, ry + 27.0, fmt"-{s.calamities}", 13, color(1.0, 0.62, 0.54, 1.0))
        self.drawText(font, mr.x + 612.0, ry + 27.0, fmt"{s.totalVp} VP", 14, color(1.0, 0.90, 0.50, 1.0))
        self.drawText(font, mr.x + 685.0, ry + 27.0, fmt"{s.tiebreakerWaresValue}s", 13, color(0.90, 0.84, 0.72, 1.0))

  of mkNone:
    discard

method draw*(self: PegsOfUrController) {.gdsync.} =
  if self.presenter.isNil:
    return
  let font = ThemeDB.singleton.getFallbackFont()
  let p = self.presenter

  if not self.tableBgTex[].isNil:
    self.drawTextureRect(self.tableBgTex, rect2(0.0, 0.0, p.screenW, p.screenH), tile = false)
  else:
    self.drawRect(rect2(0.0, 0.0, p.screenW, p.screenH), color(0.14, 0.08, 0.04, 1.0), filled = true)

  let tb = p.topBarRect()
  self.drawWoodCard(tb, color(0.18, 0.10, 0.05, 0.95), color(0.74, 0.56, 0.28, 0.88))
  self.drawText(font, tb.x + 14.0, tb.y + 24.0, "PEGS OF UR", 18, color(0.98, 0.89, 0.68, 1.0), shadow = true)
  let phaseStr =
    case p.game.phase
    of phSetup: "Setup"
    of phRoll: "Cast Dice"
    of phAssignChoices: "Assign Dice"
    of phBuild: "Construct"
    of phBuy: "Advancements"
    of phDiscard: "Store Wares"
    of phGameOver: "Era Complete"
  let rngBadge =
    if p.game.entropy.source == esTpm2Hardware: " • TPM 2.0 TRNG"
    elif p.game.entropy.source == esSystemTimer: " • Timer RNG"
    else: ""
  let subHdr =
    if p.game.isSolo(): fmt"Solo • Round {p.game.roundNumber}/{SoloMaxRounds} • {phaseStr}{rngBadge}"
    else: fmt"Round {p.game.roundNumber} • {phaseStr}{rngBadge}"
  self.drawText(font, tb.x + 14.0, tb.y + 43.0, subHdr, 12, color(0.86, 0.76, 0.58, 1.0))
  if p.game.finalRoundTriggered:
    self.drawText(font, tb.x + 255.0, tb.y + 43.0, "FINAL ROUND!", 12, color(1.0, 0.52, 0.36, 1.0), shadow = true)

  let os = p.ownerStripRect()
  self.drawWoodCard(os, color(0.21, 0.12, 0.06, 0.94), color(0.66, 0.48, 0.24, 0.82))
  let vp = p.game.players[p.viewedPlayerIdx]
  let viewTag = if p.viewedPlayerIdx == p.game.activePlayerIdx: "(Active Turn)" else: "(Inspecting)"
  self.drawText(font, os.x + 12.0, os.y + 23.0, fmt"{vp.name}'s Pegboard {viewTag}", 14, color(0.97, 0.90, 0.75, 1.0), shadow = true)

  self.drawPegboard(font)

  let sc = p.settlementsCardRect()
  self.drawWoodCard(sc, color(0.92, 0.85, 0.71, 0.96), color(0.42, 0.26, 0.12, 0.92))
  self.drawText(font, sc.x + 12.0, sc.y + 20.0, fmt"SETTLEMENTS (Founded: {vp.settlements} / 7 • 1 Grain & 1 Die per Settlement)", 12, color(0.20, 0.10, 0.03, 1.0))
  self.drawText(font, sc.x + 12.0, sc.y + 39.0, "Home Settlements 1–3: [■] [■] [■] Founded", 11, color(0.28, 0.16, 0.06, 1.0))
  for slot in 0 ..< 4:
    let sNum = 4 + slot
    let cost = SettlementCosts[slot]
    let built = vp.settlements >= sNum
    let prog = if built: cost else: vp.settlementProgress[slot]
    let ry = sc.y + 62.0 + float(slot) * 24.0
    let col = if built: color(0.15, 0.44, 0.16, 1.0) else: color(0.20, 0.10, 0.03, 1.0)
    let suffix = if built: "  Founded" else: ""
    self.drawText(font, sc.x + 12.0, ry, fmt"Settlement #{sNum} ({cost}B): {progressBoxes(prog, cost)}{suffix}", 12, col)

  self.drawDiceTray(font)

  if p.calamityTimer > 0.0:
    let cb = p.calamityBannerRect()
    self.drawWoodCard(cb, color(0.48, 0.10, 0.08, 0.96), color(0.98, 0.56, 0.34, 0.96))
    self.drawText(font, cb.x + 14.0, cb.y + 26.0, fmt"{p.calamityBannerTitle} — {p.calamityBannerDetail}", 13, color(1.0, 0.92, 0.84, 1.0), cb.w - 28.0, shadow = true)

  let ac = p.actionCardRect()
  self.drawWoodCard(ac, color(0.19, 0.11, 0.05, 0.95), color(0.74, 0.55, 0.27, 0.88))
  let ap = p.game.players[p.game.activePlayerIdx]
  let titleTxt =
    if p.game.phase == phGameOver: "Era Complete — Final Standings Ready"
    elif not p.game.isActiveHuman(): fmt"{ap.name} ({seatShortTag(ap.seatType)}) is acting..."
    elif p.game.phase == phRoll: fmt"{ap.name} — Cast Phase (Cast {p.game.rollsUsed}/{p.game.maxRolls})"
    elif p.game.phase == phAssignChoices: fmt"{ap.name} — Assign [2 Grain / 2 Builders] Dice"
    elif p.game.phase == phBuild: fmt"{ap.name} — Construction Phase • Builders Remaining: {p.game.turnBuilders}"
    elif p.game.phase == phBuy: fmt"{ap.name} — Civic Advancements • Silver: {p.game.turnSilver}s • Max Power: {p.game.maxPurchasingPower(p.game.activePlayerIdx)}s"
    else: fmt"{ap.name} — Storage Cap! Discard {p.game.excessWaresToDiscard(p.game.activePlayerIdx)} Excess Ware(s)"
  self.drawText(font, ac.x + 14.0, ac.y + 26.0, titleTxt, 15, color(0.98, 0.90, 0.72, 1.0), ac.w - 28.0, shadow = true)

  let subTxt =
    if p.game.phase in {phRoll, phAssignChoices}: p.game.computeDicePreview()
    elif p.game.phase == phBuild: "Assign Builders to Settlements (left) or Great Works (right), then Finish Building."
    elif p.game.phase == phBuy and p.selectedBuyAdv >= 0:
      fmt"Custom Payment for {Advancements[p.selectedBuyAdv].name} ({Advancements[p.selectedBuyAdv].cost}s) — Toggle Ware tracks or Pegs (Silos Grain: {p.buySiloGrain}):"
    elif p.game.phase == phBuy: "Click [Buy] on an affordable Advancement on the right, or [Pay...] to choose specific Ware tracks."
    elif p.game.phase == phDiscard: "Click any Ware peg on your Pegboard or use the buttons below to discard down to 6 Wares."
    else: "Inspect any realm's final board using the Realm tabs above."
  self.drawText(font, ac.x + 14.0, ac.y + 49.0, subTxt, 12, color(0.88, 0.80, 0.66, 1.0), ac.w - 28.0)

  let lc = p.logCardRect()
  self.drawWoodCard(lc, color(0.14, 0.08, 0.04, 0.93), color(0.52, 0.36, 0.18, 0.80))
  self.drawText(font, lc.x + 14.0, lc.y + 21.0, "TABLET CHRONICLE", 12, color(0.84, 0.70, 0.46, 1.0), shadow = true)
  let maxLines = max(3, int((lc.h - 34.0) / 18.0))
  let startLog = max(0, p.game.eventLog.len - maxLines)
  var ly = lc.y + 41.0
  for idx in startLog ..< p.game.eventLog.len:
    self.drawText(font, lc.x + 14.0, ly, p.game.eventLog[idx], 12, color(0.92, 0.86, 0.74, 0.96), lc.w - 28.0)
    ly += 18.0

  let rCol = p.rightColRect()
  if not self.parchmentTex[].isNil:
    self.drawTextureRect(self.parchmentTex, rCol.toGdRect(), tile = false)
  else:
    self.drawWoodCard(rCol, color(0.91, 0.84, 0.70, 1.0), color(0.45, 0.28, 0.12, 1.0))

  self.drawText(font, rCol.x + 14.0, rCol.y + 22.0, "GREAT WORKS (First Finisher Claims Top Renown)", 13, color(0.20, 0.10, 0.03, 1.0))
  let gwa = p.greatWorksAreaRect()
  var gwy = gwa.y
  for gwIdx in 0 ..< GreatWorks.len:
    if not isGreatWorkActive(gwIdx, p.game.players.len):
      continue
    let gwDef = GreatWorks[gwIdx]
    let prog = vp.workProgress[gwIdx]
    let done = prog >= gwDef.builders
    let cardRc = uiRect(gwa.x, gwy, gwa.w, 44.0)
    self.drawWoodCard(
      cardRc,
      if done: color(0.80, 0.88, 0.74, 0.72) else: color(0.94, 0.88, 0.74, 0.62),
      color(0.45, 0.30, 0.14, 0.48),
      1.2,
    )
    let fOwner = p.game.workFirstOwner[gwIdx]
    let vpInfo =
      if fOwner >= 0: fmt"1st: {p.game.players[fOwner].name} ({gwDef.vpFirst}) • Next: {gwDef.vpLater} VP"
      else: fmt"[{gwDef.vpFirst} / {gwDef.vpLater} VP]"
    let noteStr = if gwDef.id == "citadel_ramparts": " • Blocks Raiders" else: ""
    self.drawText(font, cardRc.x + 8.0, cardRc.y + 17.0, fmt"{gwDef.name} ({gwDef.builders}B) — {vpInfo}{noteStr}", 12, color(0.18, 0.09, 0.03, 1.0), cardRc.w - 140.0)
    self.drawText(
      font,
      cardRc.x + 8.0,
      cardRc.y + 35.0,
      fmt"{progressBoxes(prog, gwDef.builders)}  ({prog}/{gwDef.builders})" & (if done: "  Raised!" else: ""),
      11,
      if done: color(0.14, 0.44, 0.16, 1.0) else: color(0.32, 0.19, 0.08, 1.0),
      cardRc.w - 144.0,
    )
    gwy += 48.0

  let aa = p.advancementsAreaRect()
  self.drawLine(vector2(rCol.x + 14.0, aa.y - 26.0), vector2(rCol.x + rCol.w - 14.0, aa.y - 26.0), color(0.42, 0.26, 0.12, 0.55), 1.5)
  self.drawText(font, rCol.x + 14.0, aa.y - 8.0, "CIVIC ADVANCEMENTS (Scroll Wheel • Max 1/Turn • 5 Triggers Final Round)", 12, color(0.20, 0.10, 0.03, 1.0))

  let rowStride = 44.0
  for aIdx in 0 ..< Advancements.len:
    let ry = aa.y + float(aIdx) * rowStride - p.advScrollOffset
    if ry + 40.0 < aa.y or ry > aa.y + aa.h - 20.0:
      continue
    let aDef = Advancements[aIdx]
    let owned = vp.advancements[aIdx]
    let cardRc = uiRect(aa.x, ry, aa.w, 40.0)
    self.drawWoodCard(
      cardRc,
      if owned: color(0.78, 0.87, 0.72, 0.76)
      elif p.selectedBuyAdv == aIdx: color(0.98, 0.90, 0.64, 0.86)
      else: color(0.94, 0.88, 0.74, 0.60),
      color(0.45, 0.30, 0.14, 0.45),
      1.2,
    )
    var owners = ""
    for pi in 0 ..< p.game.players.len:
      if p.game.players[pi].advancements[aIdx]:
        if owners.len > 0: owners.add(",")
        owners.add(p.game.players[pi].name[0 .. min(2, p.game.players[pi].name.high)])
    let ownTag = if owners.len > 0: fmt" [{owners}]" else: ""
    self.drawText(
      font,
      cardRc.x + 8.0,
      cardRc.y + 16.0,
      fmt"{aDef.cost}s • {aDef.name} (+{aDef.vp} VP){ownTag}",
      12,
      if owned: color(0.14, 0.42, 0.15, 1.0) else: color(0.18, 0.09, 0.03, 1.0),
      cardRc.w - 154.0,
    )
    self.drawText(font, cardRc.x + 8.0, cardRc.y + 33.0, aDef.effect, 11, color(0.32, 0.20, 0.09, 1.0), cardRc.w - 154.0)

  if p.modal == mkNone:
    self.drawButtons(font)
  else:
    self.drawModal(font)
    self.drawButtons(font)
