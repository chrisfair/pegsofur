## Hardware TPM 2.0 True Random Number Generator (/dev/tpmrm0 or /dev/tpm0)
## with rejection-sampled unbiased die rolls and System Timer PRNG fallback
## whenever the user lacks TPM read/write access or no TPM device is present.

import std/[monotimes, random, times]
import data

when defined(posix):
  import std/posix

const
  DefaultTpmDevice* = "/dev/tpmrm0"
  FallbackTpmDevice* = "/dev/tpm0"
  TpmBurstBytes = 32

type
  EntropySourceKind* = enum
    esTpm2Hardware = 0
    esSystemTimer = 1
    esDeterministicSeed = 2

  EntropyPool* = ref object
    source*: EntropySourceKind
    tpmDevicePath*: string
    buf*: array[TpmBurstBytes, uint8]
    bufPos*: int
    bufLen*: int
    detRng*: Rand

var timerSaltCounter: uint64 = 0x9E37_79B9_7F4A_7C15'u64

proc splitMix64(x: uint64): uint64 {.inline.} =
  var z = x + 0x9E37_79B9_7F4A_7C15'u64
  z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
  z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
  z xor (z shr 31)

proc systemTimerSeed64*(): int64 =
  ## Computes a 63-bit positive PRNG seed from the high-resolution monotonic
  ## clock mixed with wall-clock nanoseconds and an incrementing counter.
  inc timerSaltCounter
  let mono = cast[uint64](getMonoTime().ticks)
  let nowT = getTime()
  let wall = cast[uint64](nowT.toUnix) * 1_000_000_000'u64 + uint64(nowT.nanosecond)
  let mixed = splitMix64(mono xor splitMix64(wall) xor splitMix64(timerSaltCounter))
  result = int64(mixed and 0x7FFF_FFFF_FFFF_FFFF'u64)
  if result == 0:
    result = 1

proc tpm2QueryDevice(outBuf: var openArray[uint8]; path: string): int =
  when defined(posix):
    let reqLen = uint16(min(outBuf.len, 32))
    let fd = posix.open(path.cstring, O_RDWR)
    if fd < 0:
      return 0
    defer:
      discard posix.close(fd)

    # 12-byte big-endian TCG TPM2_GetRandom frame:
    # tag = 0x8001 (TPM_ST_NO_SESSIONS), size = 12, cc = 0x0000017B, bytesRequested = reqLen
    var cmd: array[12, uint8] = [
      0x80'u8, 0x01'u8,
      0x00'u8, 0x00'u8, 0x00'u8, 0x0C'u8,
      0x00'u8, 0x00'u8, 0x01'u8, 0x7B'u8,
      uint8((reqLen shr 8) and 0xFF'u16),
      uint8(reqLen and 0xFF'u16),
    ]
    if posix.write(fd, addr cmd[0], 12) != 12:
      return 0

    var resp: array[64, uint8]
    let nRead = posix.read(fd, addr resp[0], int(12'u16 + reqLen))
    if nRead < 12:
      return 0

    let rc = (uint32(resp[6]) shl 24) or (uint32(resp[7]) shl 16) or
             (uint32(resp[8]) shl 8) or uint32(resp[9])
    if rc != 0'u32:
      return 0

    let tpmCount = int((uint16(resp[10]) shl 8) or uint16(resp[11]))
    let avail = min(tpmCount, min(outBuf.len, nRead - 12))
    for i in 0 ..< avail:
      outBuf[i] = resp[12 + i]
    return avail
  else:
    discard path
    return 0

proc tpm2GetRandomBytes*(outBuf: var openArray[uint8]; devPath: string = DefaultTpmDevice): int =
  if outBuf.len <= 0:
    return 0
  result = tpm2QueryDevice(outBuf, devPath)
  if result <= 0 and devPath == DefaultTpmDevice:
    result = tpm2QueryDevice(outBuf, FallbackTpmDevice)

proc refillHardwareBuffer(pool: EntropyPool) =
  pool.bufPos = 0
  let got = tpm2GetRandomBytes(pool.buf, pool.tpmDevicePath)
  if got > 0:
    pool.source = esTpm2Hardware
    pool.bufLen = got
    return

  # No TPM device or user lacks read/write access -> fall back to System Timer PRNG
  pool.source = esSystemTimer
  for i in 0 ..< TpmBurstBytes:
    pool.buf[i] = uint8(pool.detRng.rand(0 .. 255))
  pool.bufLen = TpmBurstBytes

proc newEntropyPool*(seed: int64 = -1; tpmDevicePath: string = DefaultTpmDevice): EntropyPool =
  if seed >= 0:
    return EntropyPool(
      source: esDeterministicSeed,
      tpmDevicePath: tpmDevicePath,
      detRng: initRand(seed),
    )
  result = EntropyPool(
    source: esSystemTimer,
    tpmDevicePath: tpmDevicePath,
    detRng: initRand(systemTimerSeed64()),
  )
  result.refillHardwareBuffer()

proc nextByte*(pool: EntropyPool): uint8 =
  if pool.source in {esDeterministicSeed, esSystemTimer}:
    return uint8(pool.detRng.rand(0 .. 255))
  if pool.bufPos >= pool.bufLen:
    pool.refillHardwareBuffer()
    if pool.source == esSystemTimer:
      return uint8(pool.detRng.rand(0 .. 255))
  result = pool.buf[pool.bufPos]
  inc pool.bufPos

proc hardwareOrTimerSeed64*(tpmDevicePath: string = DefaultTpmDevice): int64 =
  var raw: array[8, uint8]
  if tpm2GetRandomBytes(raw, tpmDevicePath) == 8:
    var u: uint64 = 0
    for b in raw:
      u = (u shl 8) or uint64(b)
    result = int64(u and 0x7FFF_FFFF_FFFF_FFFF'u64)
    if result == 0:
      result = 1
  else:
    result = systemTimerSeed64()

proc rollDieFace*(pool: EntropyPool): DieFace =
  ## Unbiased 1-in-6 die roll: TPM hardware bytes use rejection sampling (b < 252);
  ## System Timer / Deterministic fallback uses std/random's unbiased rand(0..5).
  if pool.source in {esDeterministicSeed, esSystemTimer}:
    return DieFace(pool.detRng.rand(0 .. 5))
  while true:
    let b = pool.nextByte()
    if b < 252'u8:
      return DieFace(int(b mod 6'u8))

proc entropySourceLabel*(pool: EntropyPool): string =
  case pool.source
  of esTpm2Hardware: "TPM 2.0 Hardware TRNG"
  of esSystemTimer: "System Timer Seed"
  of esDeterministicSeed: "Deterministic Test Seed"
