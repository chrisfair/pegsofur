## Pure-Nim email-linked profile, 5/day online quota, tasteful Linux support hook,
## Global Standings, and turn-based Online Room client for Pegs of Ur.

import std/[json, os, strutils, times, uri]
when not defined(js):
  import std/httpclient

const
  DefaultApiBase* = "https://bughouse-online.com/pegsofur-api"
  FreeDailyOnlineLimit* = 5
  SupportPromptMinGames* = 3
  StripeLink1Usd* = "https://buy.stripe.com/14A7sEgae18A5Mi3P2efC00"
  StripeLink5Usd* = "https://buy.stripe.com/cNidR2e262cEeiOdpCefC01"

type
  HttpResponseData* = object
    statusCode*: int
    body*: string
    ok*: bool

  HttpTransport* = proc(httpMethod, url, body: string): HttpResponseData {.closure.}

  PegsProfile* = object
    email*: string
    displayName*: string
    gamesCompleted*: int
    dailyDate*: string
    dailyOnlineGamesUsed*: int
    supported*: bool
    supportTier*: string
    supportPromptDismissed*: bool
    isMicrosoftStore*: bool

  StandingEntry* = object
    rank*: int
    displayName*: string
    mode*: string
    score*: int
    rounds*: int
    worksBuilt*: int
    advancements*: int
    won*: bool

  OnlineSeatInfo* = object
    seat*: int
    displayName*: string

  OnlineMoveRecord* = object
    seqNum*: int
    seat*: int
    action*: string
    p1*: int
    p2*: int

  OnlineRoomState* = object
    code*: string
    hostName*: string
    maxPlayers*: int
    status*: string
    seed*: int
    seat*: int
    seatToken*: string
    turnSeq*: int
    players*: seq[OnlineSeatInfo]
    moves*: seq[OnlineMoveRecord]
    lastError*: string

proc todayDateKey*(): string =
  now().utc().format("yyyy-MM-dd")

proc defaultProfilePath*(): string =
  let base =
    when defined(windows):
      getEnv("APPDATA", getHomeDir())
    else:
      getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  base / "pegsofur" / "profile.json"

proc initDefaultProfile*(): PegsProfile =
  PegsProfile(
    email: "",
    displayName: "Ur",
    gamesCompleted: 0,
    dailyDate: todayDateKey(),
    dailyOnlineGamesUsed: 0,
    supported: false,
    supportTier: "",
    supportPromptDismissed: false,
    isMicrosoftStore: false,
  )

proc isValidEmail*(email: string): bool =
  let s = email.strip()
  if s.len < 5 or s.len > 160:
    return false
  let atPos = s.find('@')
  if atPos <= 0 or atPos >= s.len - 3:
    return false
  let domain = s[atPos + 1 .. ^1]
  let dotPos = domain.find('.')
  dotPos > 0 and dotPos < domain.len - 1 and not s.contains(' ')

proc normalizeDailyQuota*(p: var PegsProfile; today: string = todayDateKey()) =
  if p.dailyDate != today:
    p.dailyDate = today
    p.dailyOnlineGamesUsed = 0

proc isUnlimitedOnline*(p: PegsProfile): bool =
  p.supported or p.isMicrosoftStore

proc remainingOnlineGamesToday*(p: PegsProfile; today: string = todayDateKey()): int =
  if p.isUnlimitedOnline():
    return -1
  let used = if p.dailyDate == today: p.dailyOnlineGamesUsed else: 0
  max(0, FreeDailyOnlineLimit - used)

proc canStartOnlineGame*(p: PegsProfile; today: string = todayDateKey()): bool =
  p.isUnlimitedOnline() or remainingOnlineGamesToday(p, today) > 0

proc recordOnlineGameStarted*(p: var PegsProfile; today: string = todayDateKey()): bool =
  p.normalizeDailyQuota(today)
  if p.isUnlimitedOnline():
    return true
  if p.dailyOnlineGamesUsed >= FreeDailyOnlineLimit:
    return false
  inc p.dailyOnlineGamesUsed
  true

proc recordLocalGameCompleted*(p: var PegsProfile) =
  inc p.gamesCompleted

proc shouldShowSupportPrompt*(p: PegsProfile): bool =
  not p.isMicrosoftStore and not p.supported and not p.supportPromptDismissed and
    p.gamesCompleted >= SupportPromptMinGames

proc buildSupportCheckoutUrl*(email: string; amountUsd: int = 5): string =
  let base = if amountUsd <= 1: StripeLink1Usd else: StripeLink5Usd
  let cleanEmail = email.strip().toLowerAscii()
  let refId =
    if cleanEmail.len > 0: "pegsofur_" & cleanEmail
    else: "pegsofur_linux"
  base & "?client_reference_id=" & encodeUrl(refId)

proc loadProfile*(path: string = defaultProfilePath()): PegsProfile =
  result = initDefaultProfile()
  if not fileExists(path):
    return
  try:
    let node = parseJson(readFile(path))
    result.email = node.getOrDefault("email").getStr("")
    result.displayName = node.getOrDefault("displayName").getStr("Ur")
    result.gamesCompleted = node.getOrDefault("gamesCompleted").getInt(0)
    result.dailyDate = node.getOrDefault("dailyDate").getStr(todayDateKey())
    result.dailyOnlineGamesUsed = node.getOrDefault("dailyOnlineGamesUsed").getInt(0)
    result.supported = node.getOrDefault("supported").getBool(false)
    result.supportTier = node.getOrDefault("supportTier").getStr("")
    result.supportPromptDismissed = node.getOrDefault("supportPromptDismissed").getBool(false)
    result.isMicrosoftStore = node.getOrDefault("isMicrosoftStore").getBool(false)
  except CatchableError:
    discard
  result.normalizeDailyQuota()

proc saveProfile*(p: PegsProfile; path: string = defaultProfilePath()): bool =
  try:
    createDir(parentDir(path))
    let node = %*{
      "email": p.email,
      "displayName": p.displayName,
      "gamesCompleted": p.gamesCompleted,
      "dailyDate": p.dailyDate,
      "dailyOnlineGamesUsed": p.dailyOnlineGamesUsed,
      "supported": p.supported,
      "supportTier": p.supportTier,
      "supportPromptDismissed": p.supportPromptDismissed,
      "isMicrosoftStore": p.isMicrosoftStore,
    }
    writeFile(path, node.pretty())
    true
  except CatchableError:
    false

proc defaultHttpTransport*(httpMethod, url, body: string): HttpResponseData =
  when not defined(js):
    var client = newHttpClient(timeout = 3000)
    defer: client.close()
    client.headers = newHttpHeaders({
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": "PegsOfUr/1.0",
    })
    try:
      let resp =
        if httpMethod == "POST":
          client.request(url, httpMethod = HttpPost, body = body)
        else:
          client.request(url, httpMethod = HttpGet)
      let code = resp.code.int
      return HttpResponseData(statusCode: code, body: resp.body, ok: code >= 200 and code < 300)
    except CatchableError:
      return HttpResponseData(statusCode: 0, body: "", ok: false)
  else:
    HttpResponseData(statusCode: 0, body: "", ok: false)

proc syncAccountStatus*(
    p: var PegsProfile;
    apiBase: string = DefaultApiBase;
    transport: HttpTransport = defaultHttpTransport;
): bool =
  let base = apiBase.strip(chars = {'/'})
  let storeFlag = if p.isMicrosoftStore: "1" else: "0"
  let url = base & "/v1/account?email=" & encodeUrl(p.email.strip()) & "&store=" & storeFlag
  let resp = transport("GET", url, "")
  if not resp.ok:
    return false
  try:
    let j = parseJson(resp.body)
    p.supported = j.getOrDefault("supported").getBool(p.supported)
    p.supportTier = j.getOrDefault("tierLabel").getStr(p.supportTier)
    p.dailyDate = j.getOrDefault("date").getStr(todayDateKey())
    p.dailyOnlineGamesUsed = j.getOrDefault("dailyUsed").getInt(p.dailyOnlineGamesUsed)
    true
  except CatchableError:
    false

proc fetchGlobalStandings*(
    mode: string = "solo";
    limit: int = 15;
    apiBase: string = DefaultApiBase;
    transport: HttpTransport = defaultHttpTransport;
): seq[StandingEntry] =
  let base = apiBase.strip(chars = {'/'})
  let url = base & "/v1/standings?mode=" & encodeUrl(mode) & "&limit=" & $limit
  let resp = transport("GET", url, "")
  if not resp.ok:
    return @[]
  try:
    let j = parseJson(resp.body)
    let arr = j.getOrDefault("entries")
    if arr.isNil or arr.kind != JArray:
      return @[]
    for item in arr:
      result.add(StandingEntry(
        rank: item.getOrDefault("rank").getInt(0),
        displayName: item.getOrDefault("displayName").getStr(""),
        mode: item.getOrDefault("mode").getStr(mode),
        score: item.getOrDefault("score").getInt(0),
        rounds: item.getOrDefault("rounds").getInt(10),
        worksBuilt: item.getOrDefault("worksBuilt").getInt(0),
        advancements: item.getOrDefault("advancements").getInt(0),
        won: item.getOrDefault("won").getBool(false),
      ))
  except CatchableError:
    result = @[]

proc submitGlobalStanding*(
    p: PegsProfile;
    mode: string;
    score, rounds, worksBuilt, advancements: int;
    won: bool;
    apiBase: string = DefaultApiBase;
    transport: HttpTransport = defaultHttpTransport;
): bool =
  let base = apiBase.strip(chars = {'/'})
  let payload = %*{
    "displayName": if p.displayName.strip().len >= 2: p.displayName.strip() else: "Ur",
    "email": p.email.strip().toLowerAscii(),
    "mode": mode,
    "score": score,
    "rounds": rounds,
    "worksBuilt": worksBuilt,
    "advancements": advancements,
    "won": won,
  }
  let resp = transport("POST", base & "/v1/standings", $payload)
  resp.ok

proc createOnlineRoom*(
    p: var PegsProfile;
    maxPlayers: int = 2;
    apiBase: string = DefaultApiBase;
    transport: HttpTransport = defaultHttpTransport;
): OnlineRoomState =
  result.maxPlayers = clamp(maxPlayers, 2, 4)
  if not p.canStartOnlineGame():
    result.lastError = "Daily free online limit (5/day) reached. Support Pegs of Ur for unlimited online play."
    return
  let base = apiBase.strip(chars = {'/'})
  let payload = %*{
    "displayName": if p.displayName.strip().len >= 2: p.displayName.strip() else: "Ur",
    "email": p.email.strip().toLowerAscii(),
    "maxPlayers": result.maxPlayers,
    "isStorePurchase": p.isMicrosoftStore,
  }
  let resp = transport("POST", base & "/v1/rooms", $payload)
  if not resp.ok:
    try:
      result.lastError = parseJson(resp.body).getOrDefault("error").getStr("Could not create room")
    except CatchableError:
      result.lastError = "Could not reach Pegs of Ur online server"
    return
  try:
    let j = parseJson(resp.body)
    result.code = j.getOrDefault("code").getStr("")
    result.hostName = p.displayName
    result.seat = j.getOrDefault("seat").getInt(0)
    result.seatToken = j.getOrDefault("seatToken").getStr("")
    result.seed = j.getOrDefault("seed").getInt(0)
    result.status = "waiting"
    result.players = @[OnlineSeatInfo(seat: 0, displayName: p.displayName)]
    p.dailyOnlineGamesUsed = j.getOrDefault("dailyUsed").getInt(p.dailyOnlineGamesUsed + 1)
  except CatchableError:
    result.lastError = "Malformed room response"

proc joinOnlineRoom*(
    p: var PegsProfile;
    code: string;
    apiBase: string = DefaultApiBase;
    transport: HttpTransport = defaultHttpTransport;
): OnlineRoomState =
  let cleanCode = code.strip().toUpperAscii()
  if cleanCode.len != 6:
    result.lastError = "Room code must be 6 characters"
    return
  if not p.canStartOnlineGame():
    result.lastError = "Daily free online limit (5/day) reached. Support Pegs of Ur for unlimited online play."
    return
  let base = apiBase.strip(chars = {'/'})
  let payload = %*{
    "code": cleanCode,
    "displayName": if p.displayName.strip().len >= 2: p.displayName.strip() else: "Byblos",
    "email": p.email.strip().toLowerAscii(),
    "isStorePurchase": p.isMicrosoftStore,
  }
  let resp = transport("POST", base & "/v1/rooms/join", $payload)
  if not resp.ok:
    try:
      result.lastError = parseJson(resp.body).getOrDefault("error").getStr("Could not join room")
    except CatchableError:
      result.lastError = "Could not reach Pegs of Ur online server"
    return
  try:
    let j = parseJson(resp.body)
    result.code = j.getOrDefault("code").getStr(cleanCode)
    result.seat = j.getOrDefault("seat").getInt(1)
    result.seatToken = j.getOrDefault("seatToken").getStr("")
    result.seed = j.getOrDefault("seed").getInt(0)
    result.status = j.getOrDefault("status").getStr("active")
    p.dailyOnlineGamesUsed = j.getOrDefault("dailyUsed").getInt(p.dailyOnlineGamesUsed + 1)
  except CatchableError:
    result.lastError = "Malformed join response"

proc pollOnlineRoom*(
    room: var OnlineRoomState;
    apiBase: string = DefaultApiBase;
    transport: HttpTransport = defaultHttpTransport;
): bool =
  if room.code.len != 6:
    return false
  let base = apiBase.strip(chars = {'/'})
  let resp = transport("GET", base & "/v1/rooms?code=" & encodeUrl(room.code), "")
  if not resp.ok:
    return false
  try:
    let j = parseJson(resp.body)
    room.hostName = j.getOrDefault("hostName").getStr(room.hostName)
    room.maxPlayers = j.getOrDefault("maxPlayers").getInt(room.maxPlayers)
    room.status = j.getOrDefault("status").getStr(room.status)
    room.turnSeq = j.getOrDefault("turnSeq").getInt(room.turnSeq)
    let parr = j.getOrDefault("players")
    if not parr.isNil and parr.kind == JArray:
      room.players.setLen(0)
      for item in parr:
        room.players.add(OnlineSeatInfo(
          seat: item.getOrDefault("seat").getInt(0),
          displayName: item.getOrDefault("displayName").getStr(""),
        ))
    let marr = j.getOrDefault("moves")
    if not marr.isNil and marr.kind == JArray:
      room.moves.setLen(0)
      for m in marr:
        let pl = m.getOrDefault("payload")
        var p1 = 0
        var p2 = 0
        if not pl.isNil and pl.kind == JObject:
          p1 = pl.getOrDefault("p1").getInt(0)
          p2 = pl.getOrDefault("p2").getInt(0)
        room.moves.add(OnlineMoveRecord(
          seqNum: m.getOrDefault("seq").getInt(0),
          seat: m.getOrDefault("seat").getInt(0),
          action: m.getOrDefault("action").getStr(""),
          p1: p1,
          p2: p2,
        ))
    true
  except CatchableError:
    false

proc submitOnlineMove*(
    room: var OnlineRoomState;
    action: string;
    payload: JsonNode = newJObject();
    apiBase: string = DefaultApiBase;
    transport: HttpTransport = defaultHttpTransport;
): bool =
  if room.code.len != 6 or room.seatToken.len == 0:
    return false
  let base = apiBase.strip(chars = {'/'})
  let body = %*{
    "code": room.code,
    "seatToken": room.seatToken,
    "action": action,
    "payload": payload,
  }
  let resp = transport("POST", base & "/v1/rooms/move", $body)
  if not resp.ok:
    return false
  try:
    let j = parseJson(resp.body)
    room.turnSeq = j.getOrDefault("turnSeq").getInt(room.turnSeq + 1)
    true
  except CatchableError:
    false
