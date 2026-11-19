## Pure-Nim 2D+height wooden dice tray physics and pegboard peg animation.

import std/[math, random]
import data, entropy

const
  MaxDieSize* = 82.0
  TrayGravity* = 1520.0

type
  DieBody* = object
    posX*, posY*: float
    homeX*, homeY*: float
    velX*, velY*: float
    z*, vz*: float
    angle*, angVel*: float
    displayFace*: DieFace
    targetFace*: DieFace
    delay*: float
    flipTimer*: float
    settled*: bool
    wasRolled*: bool

  DiceTraySim* = ref object
    rng*: Rand
    rect*: UiRect
    dice*: seq[DieBody]
    hoveredDie*: int

  PegboardSim* = ref object
    rect*: UiRect
    trackedPlayerIdx*: int
    grainQty*: int
    waresQty*: array[WareType, int]
    grainPosX*, grainPosY*: float
    warePosX*: array[WareType, float]
    warePosY*: array[WareType, float]
    initialized*: bool
    hoveredWareRow*: int

proc newDiceTraySim*(seed: int64 = -1; tpmPath: string = DefaultTpmDevice): DiceTraySim =
  let actualSeed = if seed >= 0: seed else: hardwareOrTimerSeed64(tpmPath)
  DiceTraySim(
    rng: initRand(actualSeed),
    rect: uiRect(480.0, 68.0, 620.0, 246.0),
    hoveredDie: -1,
  )

proc innerBedRect*(tray: DiceTraySim): UiRect =
  let padX = max(26.0, tray.rect.w * 0.055)
  let padTop = 38.0
  let padBot = 34.0
  uiRect(
    tray.rect.x + padX,
    tray.rect.y + padTop,
    max(120.0, tray.rect.w - padX * 2.0),
    max(90.0, tray.rect.h - padTop - padBot),
  )

proc effectiveDieSize*(tray: DiceTraySim): float =
  let n = max(3, tray.dice.len)
  let innerW = max(220.0, tray.rect.w - 68.0)
  clamp((innerW - float(n - 1) * 10.0) / float(n), 56.0, MaxDieSize)

proc recomputeHomeSlots*(tray: DiceTraySim; snapImmediately: bool) =
  let n = tray.dice.len
  if n == 0 or tray.rect.w < 40.0:
    return
  let inner = tray.innerBedRect()
  let dieW = tray.effectiveDieSize()
  let gap = clamp((inner.w - float(n) * dieW) / float(max(1, n + 1)), 6.0, 22.0)
  let totalW = float(n) * dieW + float(n - 1) * gap
  let startX = inner.x + (inner.w - totalW) * 0.5 + dieW * 0.5
  let centerY = inner.y + inner.h * 0.50

  for i in 0 ..< n:
    let sx = startX + float(i) * (dieW + gap)
    tray.dice[i].homeX = sx
    tray.dice[i].homeY = centerY
    if snapImmediately and tray.dice[i].settled:
      tray.dice[i].posX = sx
      tray.dice[i].posY = centerY
      tray.dice[i].angle = 0.0

proc syncDiceTargets*(tray: DiceTraySim; faces: openArray[DieFace]) =
  if tray.dice.len != faces.len:
    tray.dice.setLen(faces.len)
    for i, f in faces:
      tray.dice[i] = DieBody(
        displayFace: f,
        targetFace: f,
        settled: true,
      )
    tray.recomputeHomeSlots(snapImmediately = true)
  else:
    for i, f in faces:
      tray.dice[i].targetFace = f
      if tray.dice[i].settled:
        tray.dice[i].displayFace = f
    tray.recomputeHomeSlots(snapImmediately = false)

proc triggerRoll*(tray: DiceTraySim; rolledIndices: openArray[int]; faces: openArray[DieFace]) =
  tray.syncDiceTargets(faces)
  let inner = tray.innerBedRect()

  for orderIdx, idx in rolledIndices:
    if idx < 0 or idx >= tray.dice.len:
      continue
    var d = tray.dice[idx]
    d.targetFace = faces[idx]
    d.displayFace = DieFace(tray.rng.rand(0 .. 5))
    d.settled = false
    d.wasRolled = true
    d.delay = float(orderIdx) * 0.030 + tray.rng.rand(0.0 .. 0.025)
    let startX = inner.x + inner.w - 24.0 + tray.rng.rand(-12.0 .. 8.0)
    let startY = inner.y + inner.h * tray.rng.rand(0.28 .. 0.72)
    d.posX = startX
    d.posY = startY
    let aimX = d.homeX + tray.rng.rand(-40.0 .. 40.0)
    let aimY = d.homeY + tray.rng.rand(-26.0 .. 26.0)
    let flightT = tray.rng.rand(0.45 .. 0.62)
    d.velX = (aimX - startX) / flightT
    d.velY = (aimY - startY) / flightT
    d.z = tray.rng.rand(58.0 .. 94.0)
    d.vz = tray.rng.rand(65.0 .. 160.0)
    d.angle = tray.rng.rand(-PI .. PI)
    d.angVel = tray.rng.rand(-13.0 .. 13.0)
    d.flipTimer = 0.0
    tray.dice[idx] = d

proc isAnimating*(tray: DiceTraySim): bool =
  for d in tray.dice:
    if not d.settled:
      return true
  false

proc dieAt*(tray: DiceTraySim; px, py: float): int =
  let half = tray.effectiveDieSize() * 0.52
  for i in countdown(tray.dice.len - 1, 0):
    let d = tray.dice[i]
    let cy = d.posY - d.z * 0.55
    let rc = uiRect(d.posX - half, cy - half - 14.0, half * 2.0, half * 2.0 + 28.0)
    if rc.contains(px, py):
      return i
  -1

proc stepTray*(tray: DiceTraySim; delta: float; audioOut: var seq[AudioEvent]) =
  if tray.dice.len == 0:
    return
  let dt = clamp(delta, 0.0, 0.033)
  let inner = tray.innerBedRect()
  let radius = tray.effectiveDieSize() * 0.46

  for i in 0 ..< tray.dice.len:
    var d = tray.dice[i]
    if not d.settled:
      if d.delay > 0.0:
        d.delay = max(0.0, d.delay - dt)
        tray.dice[i] = d
        continue

      d.vz -= TrayGravity * dt
      d.posX += d.velX * dt
      d.posY += d.velY * dt
      d.z += d.vz * dt
      d.angle += d.angVel * dt

      let minX = inner.x + radius
      let maxX = inner.x + inner.w - radius
      let minY = inner.y + radius
      let maxY = inner.y + inner.h - radius
      var hitWall = false

      if d.posX < minX:
        d.posX = minX
        d.velX = abs(d.velX) * 0.58
        hitWall = true
      elif d.posX > maxX:
        d.posX = maxX
        d.velX = -abs(d.velX) * 0.58
        hitWall = true

      if d.posY < minY:
        d.posY = minY
        d.velY = abs(d.velY) * 0.58
        hitWall = true
      elif d.posY > maxY:
        d.posY = maxY
        d.velY = -abs(d.velY) * 0.58
        hitWall = true

      let speed2D = hypot(d.velX, d.velY)
      if hitWall and speed2D > 55.0:
        audioOut.add(AudioEvent(kind: akWoodBounce, energy: clamp(speed2D / 560.0, 0.14, 0.82), pitch: 1.0))

      if d.z > 10.0 or speed2D > 130.0:
        d.flipTimer += dt
        if d.flipTimer >= 0.065:
          d.flipTimer = 0.0
          d.displayFace = DieFace((ord(d.displayFace) + tray.rng.rand(1 .. 5)) mod 6)
      else:
        d.displayFace = d.targetFace

      if d.z <= 0.0:
        d.z = 0.0
        let impactSpeed = abs(d.vz)
        if impactSpeed > 58.0:
          audioOut.add(AudioEvent(kind: akWoodBounce, energy: clamp(impactSpeed / 500.0, 0.10, 1.0), pitch: 1.0))
          d.vz = impactSpeed * tray.rng.rand(0.41 .. 0.51)
          d.velX *= 0.68
          d.velY *= 0.68
          d.angVel = d.angVel * 0.64 + tray.rng.rand(-2.2 .. 2.2)
        else:
          d.vz = 0.0
          d.velX = 0.0
          d.velY = 0.0
          d.angVel = 0.0
          d.displayFace = d.targetFace
          d.settled = true
          if d.targetFace == dfOmenWares2 and d.wasRolled:
            audioOut.add(AudioEvent(kind: akOmenThud, energy: 0.9, pitch: 1.0))
          else:
            audioOut.add(AudioEvent(kind: akWoodBounce, energy: 0.16, pitch: 1.06))
          d.wasRolled = false
    else:
      let s = clamp(dt * 12.5, 0.0, 1.0)
      d.posX += (d.homeX - d.posX) * s
      d.posY += (d.homeY - d.posY) * s
      d.angle += (0.0 - d.angle) * s

    tray.dice[i] = d

  let minDist = radius * 1.88
  for i in 0 ..< tray.dice.len:
    if tray.dice[i].settled or tray.dice[i].delay > 0.0:
      continue
    for j in (i + 1) ..< tray.dice.len:
      if tray.dice[j].settled or tray.dice[j].delay > 0.0:
        continue
      if abs(tray.dice[i].z - tray.dice[j].z) > 26.0:
        continue
      let dx = tray.dice[j].posX - tray.dice[i].posX
      let dy = tray.dice[j].posY - tray.dice[i].posY
      let dist = hypot(dx, dy)
      if dist > 0.001 and dist < minDist:
        let nx = dx / dist
        let ny = dy / dist
        let overlap = (minDist - dist) * 0.5
        tray.dice[i].posX -= nx * overlap
        tray.dice[i].posY -= ny * overlap
        tray.dice[j].posX += nx * overlap
        tray.dice[j].posY += ny * overlap
        let rvx = tray.dice[j].velX - tray.dice[i].velX
        let rvy = tray.dice[j].velY - tray.dice[i].velY
        let relN = rvx * nx + rvy * ny
        if relN < 0.0:
          let imp = relN * 0.82
          tray.dice[i].velX += nx * imp
          tray.dice[i].velY += ny * imp
          tray.dice[j].velX -= nx * imp
          tray.dice[j].velY -= ny * imp
          if abs(relN) > 75.0:
            audioOut.add(AudioEvent(kind: akWoodBounce, energy: clamp(abs(relN) / 520.0, 0.15, 0.78), pitch: 1.02))

# ==============================================================================
# PEGBOARD GEOMETRY & SMOOTH PEG TRANSITIONS
# ==============================================================================
proc newPegboardSim*(): PegboardSim =
  PegboardSim(
    rect: uiRect(14.0, 114.0, 456.0, 580.0),
    trackedPlayerIdx: -1,
    grainQty: InitialGrain,
    hoveredWareRow: -1,
  )

proc wareRowY*(pb: PegboardSim; wt: WareType): float =
  let displayOrder = 4 - ord(wt)
  let topY = pb.rect.y + 54.0
  let rowH = (pb.rect.h - 166.0) / 5.0
  topY + (float(displayOrder) + 0.5) * rowH

proc wareRowRect*(pb: PegboardSim; wt: WareType): UiRect =
  let cy = pb.wareRowY(wt)
  let rowH = (pb.rect.h - 166.0) / 5.0
  uiRect(pb.rect.x + 12.0, cy - rowH * 0.46, pb.rect.w - 24.0, rowH * 0.92)

proc wareHoleCenter*(pb: PegboardSim; wt: WareType; qty: int): tuple[x, y: float] =
  let leftX = pb.rect.x + 122.0
  let rightX = pb.rect.x + pb.rect.w - 26.0
  let spacing = (rightX - leftX) / 8.0
  (leftX + float(qty) * spacing, pb.wareRowY(wt))

proc grainHoleCenter*(pb: PegboardSim; qty: int): tuple[x, y: float] =
  let leftX = pb.rect.x + 104.0
  let rightX = pb.rect.x + pb.rect.w - 26.0
  let spacing = (rightX - leftX) / 7.0
  let rowIdx = if qty < 8: 0 else: 1
  let colIdx = if qty < 8: qty else: qty - 8
  let baseY = pb.rect.y + pb.rect.h - 72.0 + float(rowIdx) * 38.0
  (leftX + float(colIdx) * spacing, baseY)

proc wareRowAt*(pb: PegboardSim; px, py: float): int =
  if not pb.rect.contains(px, py):
    return -1
  for wt in WareType:
    if pb.wareRowRect(wt).contains(px, py):
      return ord(wt)
  -1

proc syncPegboard*(
  pb: PegboardSim;
  pIdx, grain: int;
  wares: array[WareType, int];
  audioOut: var seq[AudioEvent]
) =
  let switched = (pIdx != pb.trackedPlayerIdx)
  var movedCount = 0
  if not switched and pb.initialized:
    if grain != pb.grainQty:
      inc movedCount
    for wt in WareType:
      if wares[wt] != pb.waresQty[wt]:
        inc movedCount

  pb.trackedPlayerIdx = pIdx
  pb.grainQty = clamp(grain, 0, MaxGrain)
  for wt in WareType:
    pb.waresQty[wt] = clamp(wares[wt], 0, wareMaxQty(wt))

  if switched:
    pb.initialized = false
  elif movedCount > 0:
    audioOut.add(AudioEvent(kind: akPegTap, energy: 0.85, pitch: 1.0 + float(min(movedCount, 4)) * 0.04))

proc stepPegboard*(pb: PegboardSim; delta: float) =
  let (tgx, tgy) = pb.grainHoleCenter(pb.grainQty)
  if not pb.initialized:
    pb.grainPosX = tgx
    pb.grainPosY = tgy
    for wt in WareType:
      let (wx, wy) = pb.wareHoleCenter(wt, pb.waresQty[wt])
      pb.warePosX[wt] = wx
      pb.warePosY[wt] = wy
    pb.initialized = true
    return

  let s = clamp(delta * 15.0, 0.0, 1.0)
  pb.grainPosX += (tgx - pb.grainPosX) * s
  pb.grainPosY += (tgy - pb.grainPosY) * s
  for wt in WareType:
    let (wx, wy) = pb.wareHoleCenter(wt, pb.waresQty[wt])
    pb.warePosX[wt] += (wx - pb.warePosX[wt]) * s
    pb.warePosY[wt] += (wy - pb.warePosY[wt]) * s
