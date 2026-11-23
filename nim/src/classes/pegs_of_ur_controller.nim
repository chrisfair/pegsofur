## Godot 4 GDExtension wooden tabletop renderer & audio controller for Pegs of Ur.

import std/[math, os, random, strformat]
import gdext
import gdext/classes/[
  gdengine,
  gdnode,
  gdnode2d,
  gdnode3d,
  gdcanvasitem,
  gddisplayserver,
  gdresourceloader,
  gdtexture2d,
  gdviewport,
  gdsubviewport,
  gdviewporttexture,
  gdcamera3d,
  gdlight3d,
  gddirectionallight3d,
  gdenvironment,
  gdworldenvironment,
  gdgeometryinstance3d,
  gdmeshinstance3d,
  gdmesh,
  gdboxmesh,
  gdplanemesh,
  gdquadmesh,
  gdmaterial,
  gdbasematerial3d,
  gdstandardmaterial3d,
  gdaudiostream,
  gdaudiostreamplayer,
  gdinputevent,
  gdinputeventkey,
  gdinputeventmousebutton,
  gdinputeventmousemotion,
  gdthemedb,
  gdfont,
  gdos,
]

import ../sim/[data, entropy, game, online, physics, presenter]

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

  diceViewport: SubViewport
  diceVpTex: gdref Texture2D
  diceCamera: Camera3D
  dice3dNodes: array[MaxSettlements, Node3D]
  dice3dBlue: array[MaxSettlements, MeshInstance3D]
  dice3dRed: array[MaxSettlements, MeshInstance3D]
  dice3dHover: array[MaxSettlements, MeshInstance3D]
  diceEnv: gdref Environment
  diceWoodMat: gdref StandardMaterial3D
  diceCoreBox: gdref BoxMesh
  diceOutlineBox: gdref BoxMesh
  diceGlowBlueMat: gdref StandardMaterial3D
  diceGlowRedMat: gdref StandardMaterial3D
  diceGlowHoverMat: gdref StandardMaterial3D
  diceFaceQuad: gdref QuadMesh
  diceFaceMats: array[DieFace, gdref StandardMaterial3D]
  diceVpW: int32
  diceVpH: int32

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

const
  DiceCamDist = 14.0
  DiceCamFovDeg = 34.0
  DiceCamTiltDeg = 13.0

proc init3dDiceRig(self: PegsOfUrController) =
  if self.headless:
    return

  let svp = instantiate(SubViewport)
  svp.setTransparentBackground(true)
  svp.setUseOwnWorld3D(true)
  svp.setMsaa3D(msaa4x)
  svp.setUpdateMode(updateAlways)
  self.diceVpW = 640
  self.diceVpH = 246
  svp.setSize(vector2i(self.diceVpW, self.diceVpH))
  self.addChild(svp)
  self.diceViewport = svp
  self.diceVpTex = svp.getTexture() as gdref Texture2D

  self.diceEnv = instantiate(Environment)
  self.diceEnv[].setBackground(bgClearColor)
  self.diceEnv[].setAmbientSource(ambientSourceColor)
  self.diceEnv[].setAmbientLightColor(color(0.72, 0.62, 0.48, 1.0))
  self.diceEnv[].setAmbientLightEnergy(0.72)
  let we = instantiate(WorldEnvironment)
  we.setEnvironment(self.diceEnv)
  svp.addChild(we)

  let cam = instantiate(Camera3D)
  cam.setProjection(projectionPerspective)
  cam.setFov(DiceCamFovDeg)
  let tiltRad = DiceCamTiltDeg * PI / 180.0
  cam.setPosition(vector3(0.0, DiceCamDist * cos(tiltRad), DiceCamDist * sin(tiltRad)))
  cam.setRotation(vector3(-PI * 0.5 + tiltRad, 0.0, 0.0))
  svp.addChild(cam)
  self.diceCamera = cam

  let keyLight = instantiate(DirectionalLight3D)
  keyLight.setColor(color(1.0, 0.95, 0.86, 1.0))
  keyLight.setParam(paramEnergy, 1.35)
  keyLight.setRotationDegrees(vector3(-52.0, -30.0, 0.0))
  svp.addChild(keyLight)

  let fillLight = instantiate(DirectionalLight3D)
  fillLight.setColor(color(0.95, 0.80, 0.60, 1.0))
  fillLight.setParam(paramEnergy, 0.48)
  fillLight.setRotationDegrees(vector3(-35.0, 145.0, 0.0))
  svp.addChild(fillLight)

  self.diceWoodMat = instantiate(StandardMaterial3D)
  self.diceWoodMat[].setAlbedo(color(0.36, 0.21, 0.10, 1.0))
  self.diceWoodMat[].setRoughness(0.58)
  self.diceWoodMat[].setMetallic(0.03)

  self.diceCoreBox = instantiate(BoxMesh)
  self.diceCoreBox[].setSize(vector3(1.0, 1.0, 1.0))

  self.diceOutlineBox = instantiate(BoxMesh)
  self.diceOutlineBox[].setSize(vector3(1.11, 1.11, 1.11))

  proc makeGlowMat(col: Color): gdref StandardMaterial3D =
    result = instantiate(StandardMaterial3D)
    result[].setAlbedo(col)
    result[].setShadingMode(shadingModeUnshaded)
    result[].setCullMode(cullFront)

  self.diceGlowBlueMat = makeGlowMat(color(0.16, 0.78, 1.0, 1.0))
  self.diceGlowRedMat = makeGlowMat(color(1.0, 0.16, 0.14, 1.0))
  self.diceGlowHoverMat = makeGlowMat(color(1.0, 0.90, 0.48, 1.0))

  self.diceFaceQuad = instantiate(QuadMesh)
  self.diceFaceQuad[].setSize(vector2(0.93, 0.93))

  for df in DieFace:
    let fm = instantiate(StandardMaterial3D)
    fm[].setAlbedo(color(1.0, 0.98, 0.94, 1.0))
    fm[].setRoughness(0.46)
    fm[].setMetallic(0.02)
    if not self.dieFaceTex[df][].isNil:
      fm[].setTexture(textureAlbedo, self.dieFaceTex[df])
    self.diceFaceMats[df] = fm

  let faceOffset = 0.502
  for i in 0 ..< MaxSettlements:
    let root = instantiate(Node3D)
    root.setVisible(false)

    let bodyMesh = instantiate(MeshInstance3D)
    bodyMesh.setMesh(self.diceCoreBox as gdref Mesh)
    bodyMesh.setMaterialOverride(self.diceWoodMat as gdref Material)
    root.addChild(bodyMesh)

    let blueMesh = instantiate(MeshInstance3D)
    blueMesh.setMesh(self.diceOutlineBox as gdref Mesh)
    blueMesh.setMaterialOverride(self.diceGlowBlueMat as gdref Material)
    blueMesh.setVisible(false)
    root.addChild(blueMesh)
    self.dice3dBlue[i] = blueMesh

    let redMesh = instantiate(MeshInstance3D)
    redMesh.setMesh(self.diceOutlineBox as gdref Mesh)
    redMesh.setMaterialOverride(self.diceGlowRedMat as gdref Material)
    redMesh.setVisible(false)
    root.addChild(redMesh)
    self.dice3dRed[i] = redMesh

    let hoverMesh = instantiate(MeshInstance3D)
    hoverMesh.setMesh(self.diceOutlineBox as gdref Mesh)
    hoverMesh.setMaterialOverride(self.diceGlowHoverMat as gdref Material)
    hoverMesh.setVisible(false)
    root.addChild(hoverMesh)
    self.dice3dHover[i] = hoverMesh

    # 6 carved face plates flush against the cube, aligned so faceTargetEuler(df) brings df upright to +Y.
    for df in DieFace:
      let plate = instantiate(MeshInstance3D)
      plate.setMesh(self.diceFaceQuad as gdref Mesh)
      plate.setMaterialOverride(self.diceFaceMats[df] as gdref Material)
      case df
      of dfGrain3:
        plate.setPosition(vector3(0.0, faceOffset, 0.0))
        plate.setRotation(vector3(-PI * 0.5, 0.0, 0.0))
      of dfSilver7:
        plate.setPosition(vector3(0.0, -faceOffset, 0.0))
        plate.setRotation(vector3(PI * 0.5, 0.0, 0.0))
      of dfWare1:
        plate.setPosition(vector3(0.0, 0.0, faceOffset))
        plate.setRotation(vector3(0.0, 0.0, 0.0))
      of dfBuilders3:
        plate.setPosition(vector3(0.0, 0.0, -faceOffset))
        plate.setRotation(vector3(PI, 0.0, 0.0))
      of dfOmenWares2:
        plate.setPosition(vector3(faceOffset, 0.0, 0.0))
        plate.setRotation(vector3(0.0, PI * 0.5, -PI * 0.5))
      of dfGrainOrBuilders2:
        plate.setPosition(vector3(-faceOffset, 0.0, 0.0))
        plate.setRotation(vector3(0.0, -PI * 0.5, PI * 0.5))
      root.addChild(plate)

    svp.addChild(root)
    self.dice3dNodes[i] = root

proc sync3dDice(self: PegsOfUrController) =
  if self.headless or self.diceViewport.isNil or self.presenter.isNil:
    return
  let tray = self.presenter.tray
  let rc = tray.rect
  let targetW = max(120'i32, int32(rc.w))
  let targetH = max(90'i32, int32(rc.h))
  if targetW != self.diceVpW or targetH != self.diceVpH:
    self.diceVpW = targetW
    self.diceVpH = targetH
    self.diceViewport.setSize(vector2i(targetW, targetH))

  let halfFovRad = (DiceCamFovDeg * 0.5) * PI / 180.0
  let visH = 2.0 * DiceCamDist * tan(halfFovRad)
  let worldPerPx = visH / max(1.0, rc.h)
  let dieW = tray.effectiveDieSize()
  let cubeScale = dieW * worldPerPx * 0.86
  let centerX = rc.x + rc.w * 0.5
  let centerY = rc.y + rc.h * 0.5

  for i in 0 ..< MaxSettlements:
    let node = self.dice3dNodes[i]
    if node.isNil:
      continue
    if i >= tray.dice.len:
      node.setVisible(false)
      continue
    let d = tray.dice[i]
    if d.delay > 0.0 and not d.settled:
      node.setVisible(false)
      continue
    node.setVisible(true)
    let wx = (d.posX - centerX) * worldPerPx
    let wz = (d.posY - centerY) * worldPerPx
    let wy = cubeScale * 0.5 + d.z * worldPerPx * 0.72
    node.setPosition(vector3(wx, wy, wz))
    node.setScale(vector3(cubeScale, cubeScale, cubeScale))
    node.setRotation(vector3(d.rotX, d.rotY, d.rotZ))

    var showBlue = false
    var showRed = false
    var showHover = false
    if d.settled:
      let p = self.presenter
      let selReroll = (i < p.game.diceSelectedForReroll.len and p.game.diceSelectedForReroll[i] and p.game.phase == phRoll)
      let lockedOmen = (d.displayFace == dfOmenWares2 and not p.game.isSolo() and p.game.phase == phRoll)
      if (p.divinationArmed and tray.hoveredDie == i) or selReroll:
        showBlue = true
      elif lockedOmen:
        showRed = true
      elif tray.hoveredDie == i and p.isDieClickable(i):
        showHover = true

    if not self.dice3dBlue[i].isNil:
      self.dice3dBlue[i].setVisible(showBlue)
    if not self.dice3dRed[i].isNil:
      self.dice3dRed[i].setVisible(showRed)
    if not self.dice3dHover[i].isNil:
      self.dice3dHover[i].setVisible(showHover)

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
  let skipSetup = self.headless or getEnv("PEGS_SKIP_SETUP") == "1"
  self.presenter = newPegsOfUrPresenter(w, h, showSetupModal = not skipSetup)
  self.init3dDiceRig()
  self.sync3dDice()
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
  self.sync3dDice()
  for ev in self.presenter.popAudioEvents():
    self.dispatchAudioEvent(ev)
  self.queueRedraw()

method input*(self: PegsOfUrController; event: gdref InputEvent) {.gdsync.} =
  if self.presenter.isNil or event[].isNil or Engine.singleton.isEditorHint():
    return
  let evKey = event[] as InputEventKey
  if not evKey.isNil and evKey.isPressed() and not evKey.isEcho():
    let kc = evKey.getKeycode()
    if kc == keyBackspace:
      discard self.presenter.onKeyBackspace()
      return
    let uni = evKey.getUnicode()
    if uni >= 32 and uni <= 126:
      discard self.presenter.onKeyChar(char(uni))
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
    let sa = 0.44 - zNorm * 0.26
    self.drawSetTransform(vector2(d.posX + 6.0 + d.z * 0.24, d.posY + 8.0 + d.z * 0.30), d.angle, vector2(1.0, 1.0))
    self.drawRect(rect2(-sw * 0.48, -sw * 0.48, sw * 0.96, sw * 0.96), color(0.05, 0.02, 0.01, sa), filled = true)
    self.drawSetTransform(vector2(0.0, 0.0), 0.0, vector2(1.0, 1.0))

  let use3dDice = (not self.headless) and (not self.diceViewport.isNil) and (not self.diceVpTex[].isNil)
  if use3dDice:
    self.drawTextureRect(self.diceVpTex, rc.toGdRect(), tile = false)

  for i, d in tray.dice:
    if d.delay > 0.0 and not d.settled:
      continue
    let liftScale = 1.0 + clamp(d.z / 260.0, 0.0, 0.34)
    let dw = dieW * liftScale
    let cx = d.posX
    let cy = d.posY - d.z * 0.55

    self.drawSetTransform(vector2(cx, cy), d.angle, vector2(1.0, 1.0))
    if not use3dDice:
      let dRect = rect2(-dw * 0.5, -dw * 0.5, dw, dw)
      let tex = self.dieFaceTex[d.displayFace]
      if not tex[].isNil:
        self.drawTextureRect(tex, dRect, tile = false)

      if d.settled:
        let selReroll = (i < p.game.diceSelectedForReroll.len and p.game.diceSelectedForReroll[i] and p.game.phase == phRoll)
        let lockedOmen = (d.displayFace == dfOmenWares2 and not p.game.isSolo() and p.game.phase == phRoll)
        let ringRect = rect2(-dw * 0.5 - 3.0, -dw * 0.5 - 3.0, dw + 6.0, dw + 6.0)
        if p.divinationArmed and tray.hoveredDie == i:
          self.drawRect(ringRect, color(0.16, 0.78, 1.0, 0.95), filled = false, width = 3.0)
        elif selReroll:
          self.drawRect(ringRect, color(0.16, 0.78, 1.0, 0.95), filled = false, width = 3.2)
        elif lockedOmen:
          self.drawRect(ringRect, color(1.0, 0.16, 0.14, 0.90), filled = false, width = 2.4)
        elif tray.hoveredDie == i and p.isDieClickable(i):
          self.drawRect(ringRect, color(1.0, 0.94, 0.75, 0.78), filled = false, width = 2.2)

    self.drawSetTransform(vector2(0.0, 0.0), 0.0, vector2(1.0, 1.0))

    if d.settled:
      var badge = dieFaceLabel(d.displayFace)
      var bCol = color(0.96, 0.90, 0.78, 0.94)
      if p.game.phase == phRoll:
        if i < p.game.diceSelectedForReroll.len and p.game.diceSelectedForReroll[i]:
          badge = "REROLL"
          bCol = color(0.36, 0.86, 1.0, 1.0)
        elif d.displayFace == dfOmenWares2 and not p.game.isSolo():
          badge = "OMEN LOCKED"
          bCol = color(1.0, 0.34, 0.30, 1.0)
      elif d.displayFace == dfGrainOrBuilders2 and p.game.phase in {phAssignChoices, phBuild, phBuy}:
        let isB = (i < p.game.choiceIsBuilders.len and p.game.choiceIsBuilders[i])
        badge = if isB: "2 Builders" else: "2 Grain"
        bCol = if isB: color(0.58, 0.84, 1.0, 1.0) else: color(0.64, 0.96, 0.54, 1.0)
      self.drawText(font, cx - 56.0, cy + dw * 0.5 + 26.0, badge, 11, bCol, 112.0, horizontalAlignmentCenter, shadow = true)

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
    self.drawText(font, mr.x + 20.0, mr.y + 62.0, fmt"Configure 1 to 4 City-State Realms (1 Active Seat = {SoloMaxRounds}-Round Solo Chronicle)", 12, color(0.86, 0.78, 0.64, 1.0), mr.w - 40.0, horizontalAlignmentCenter)
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
      "6. MILESTONE BONUSES: Seven Cities (+3 VP at 7/7 dice), Unscathed (+3 VP for 0 Calamities), Master Trader",
      "   (+2 VP per maxed Ware track), Master Builder (+3 VP for 3+ Great Works), 1st to 3 (+2), 5 (+3), 8 (+4), 10 Adv (+5).",
      "7. STORAGE & END OF ERA: Keep at most 6 Wares unless holding Merchant Fleets. Equal-turns final round triggers",
      fmt"   when any realm unlocks {AdvEndTrigger} Advancements or every active Great Work stands complete (or Round {SoloMaxRounds} in Solo).",
      "   Tiebreaker: highest Silver value of remaining Wares on your Pegboard.",
    ]
    var ly = mr.y + 68.0
    for ln in lines:
      self.drawText(font, mr.x + 28.0, ly, ln, 12, color(0.94, 0.88, 0.76, 1.0))
      ly += 27.0

  of mkGameOver:
    self.drawText(font, mr.x + 20.0, mr.y + 36.0, "ERA COMPLETE — FINAL REALM STANDINGS", 19, color(0.99, 0.90, 0.68, 1.0), mr.w - 40.0, horizontalAlignmentCenter, shadow = true)
    let standings = p.game.getStandings()
    if standings.len > 0:
      let sub =
        if p.game.isSolo(): fmt"{SoloMaxRounds}-Round Solo Renown: {standings[0].totalVp} VP  (Remaining Wares: {standings[0].tiebreakerWaresValue}s)"
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

  of mkGlobalStandings:
    self.drawText(font, mr.x + 20.0, mr.y + 34.0, "GLOBAL STANDINGS — PEGS OF UR", 19, color(0.99, 0.90, 0.68, 1.0), mr.w - 40.0, horizontalAlignmentCenter, shadow = true)
    let rem = p.profile.remainingOnlineGamesToday()
    let quotaStr =
      if rem < 0: "Online Quota: Unlimited (Supporter)"
      else: fmt"Online Quota: {rem} / {FreeDailyOnlineLimit} free games remaining today"
    let emailStr = if p.profile.email.len > 0: p.profile.email else: "No email linked (profile.json)"
    self.drawText(font, mr.x + 24.0, mr.y + 112.0, fmt"Account: {emailStr}  •  {quotaStr}", 12, color(0.88, 0.80, 0.64, 1.0))
    if p.onlineStatusMsg.len > 0:
      self.drawText(font, mr.x + 24.0, mr.y + 132.0, p.onlineStatusMsg, 12, color(0.68, 0.94, 0.72, 1.0))
    if p.globalStandings.len == 0:
      self.drawText(font, mr.x + 24.0, mr.y + 174.0, "No entries yet for this mode — finish a match and click 'Submit Current Score'!", 13, color(0.86, 0.78, 0.64, 1.0))
    else:
      var ry = mr.y + 160.0
      for idx, e in p.globalStandings:
        if idx >= 9: break
        let line = fmt"#{e.rank}  {e.displayName}  —  {e.score} VP  ({e.worksBuilt} Works, {e.advancements} Adv, {e.rounds} Rds)"
        self.drawText(font, mr.x + 26.0, ry, line, 13, if idx == 0: color(1.0, 0.90, 0.50, 1.0) else: color(0.95, 0.90, 0.80, 1.0))
        ry += 28.0

  of mkOnlineLobby:
    self.drawText(font, mr.x + 20.0, mr.y + 34.0, "ONLINE MULTIPLAYER LOBBY", 19, color(0.99, 0.90, 0.68, 1.0), mr.w - 40.0, horizontalAlignmentCenter, shadow = true)
    let rem = p.profile.remainingOnlineGamesToday()
    let quotaStr =
      if rem < 0: "Unlimited online games active (Supporter / Microsoft Store)"
      else: fmt"Free online allowance: {rem} of {FreeDailyOnlineLimit} games remaining today (offline/AI is always unlimited)"
    self.drawText(font, mr.x + 24.0, mr.y + 70.0, quotaStr, 13, color(0.90, 0.82, 0.66, 1.0), mr.w - 48.0, horizontalAlignmentCenter)
    let codeBox = uiRect(mr.x + 28.0, mr.y + 150.0, 250.0, 34.0)
    self.drawWoodCard(codeBox, color(0.12, 0.07, 0.03, 0.96), color(0.84, 0.66, 0.34, 0.92))
    let codeText = if p.joinCodeInput.len > 0: fmt"Join Code: {p.joinCodeInput}" else: "Type 6-char room code..."
    self.drawText(font, codeBox.x + 12.0, codeBox.y + 22.0, codeText, 13, color(0.98, 0.92, 0.78, 1.0))
    if p.onlineStatusMsg.len > 0:
      self.drawText(font, mr.x + 28.0, mr.y + 212.0, p.onlineStatusMsg, 13, color(0.68, 0.94, 0.72, 1.0))
    if p.onlineRoom.code.len == 6:
      self.drawText(font, mr.x + 28.0, mr.y + 244.0, fmt"Active Room Code: {p.onlineRoom.code}   •   Status: {p.onlineRoom.status}   •   Turn #{p.onlineRoom.turnSeq}", 15, color(1.0, 0.90, 0.50, 1.0))
      var py = mr.y + 278.0
      for pl in p.onlineRoom.players:
        self.drawText(font, mr.x + 36.0, py, fmt"Seat {pl.seat + 1}: {pl.displayName}", 13, color(0.94, 0.88, 0.76, 1.0))
        py += 26.0
    else:
      self.drawText(font, mr.x + 28.0, mr.y + 244.0, "Create a room above OR type a friend's 6-character code and click Join Room.", 13, color(0.86, 0.78, 0.64, 1.0))

  of mkSupport:
    self.drawText(font, mr.x + 20.0, mr.y + 38.0, "SUPPORT PEGS OF UR DEVELOPMENT", 19, color(0.99, 0.90, 0.68, 1.0), mr.w - 40.0, horizontalAlignmentCenter, shadow = true)
    let lines = [
      "Pegs of Ur is free and open-source on Linux with unlimited offline & AI play.",
      fmt"Online networked rooms include {FreeDailyOnlineLimit} free games per day.",
      "Voluntary contributors ($1 or $5 via Stripe) unlock unlimited online games",
      "per day across all devices linked to their supporter email.",
      "",
      "100% optional — zero ads, zero tracking, zero microtransactions.",
    ]
    var ly = mr.y + 84.0
    for ln in lines:
      self.drawText(font, mr.x + 32.0, ly, ln, 13, color(0.94, 0.88, 0.76, 1.0), mr.w - 64.0, horizontalAlignmentCenter)
      ly += 24.0
    if p.onlineStatusMsg.len > 0:
      self.drawText(font, mr.x + 24.0, mr.y + 306.0, p.onlineStatusMsg, 13, color(0.68, 0.94, 0.72, 1.0), mr.w - 48.0, horizontalAlignmentCenter)

  of mkNone:
    discard

  if not self.headless and p.pendingExternalUrl.len > 0:
    let url = p.pendingExternalUrl
    p.pendingExternalUrl = ""
    discard OS.singleton.shellOpen(newGdString(url))

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
  self.drawText(font, sc.x + 12.0, sc.y + 20.0, fmt"SETTLEMENTS (Founded: {vp.settlements} / 7 • 1 Grain & 1 Die each • 7/7 = +{SevenCitiesVp} VP)", 12, color(0.20, 0.10, 0.03, 1.0))
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
  self.drawText(font, rCol.x + 14.0, aa.y - 8.0, fmt"CIVIC ADVANCEMENTS (Scroll • 1/Turn • 1st: 3:+{FirstTo3AdvVp}, 5:+{FirstTo5AdvVp}, 8:+{FirstTo8AdvVp}, 10:+{FirstTo10AdvVp} & End)", 11, color(0.20, 0.10, 0.03, 1.0))

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
