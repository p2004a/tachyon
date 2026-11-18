// Autohost + battle: the server<->autohost protocol (autohost/*) and the
// server->user battle messages (battle/start, battle/ended).
// Source: tachyon docs/schema/autohost.md, docs/schema/battle.md,
// schema/autohost/*, schema/battle/*, docs/commands.md, and
// docs/schema/matchmaking.md steps 8-9. Findings: findings/autohost.md (AH-nn).
//
// Here the SERVER is the requester and the AUTOHOST the responder. Both sides
// are modelled: the server's battles and its view of each autohost, the
// autohost's running engines and its buffered update log, and the messages in
// flight on the (single) connection between them. The autohost's answers are
// nondeterministic choices restricted to what the schema allows.
//
// @test main=autohost_test
// @inv main=autohost_test inv=safety steps=30 samples=20000
// @inv main=autohost_up inv=safety steps=30 samples=20000
// @inv main=autohost_two inv=safety steps=30 samples=10000
//
// Witnesses (check.sh expects each invariant to be VIOLATED = reachable).
// autohost/start: success and the four reachable failure reasons.
// @witness main=autohost_up inv=not(hit("autohost/start",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/start",Failed("battle_already_exists"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/start",Failed("engine_version_not_available"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/start",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/start",Failed("command_unimplemented"))) steps=30 samples=20000
// autohost/kill
// @witness main=autohost_up inv=not(hit("autohost/kill",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/kill",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/kill",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/kill",Failed("command_unimplemented"))) steps=30 samples=20000
// autohost/addPlayer
// @witness main=autohost_up inv=not(hit("autohost/addPlayer",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/addPlayer",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/addPlayer",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/addPlayer",Failed("command_unimplemented"))) steps=30 samples=20000
// autohost/kickPlayer, mutePlayer, specPlayers, sendCommand, sendMessage (same shape)
// @witness main=autohost_up inv=not(hit("autohost/kickPlayer",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/kickPlayer",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/kickPlayer",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/kickPlayer",Failed("command_unimplemented"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/mutePlayer",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/mutePlayer",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/mutePlayer",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/mutePlayer",Failed("command_unimplemented"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/specPlayers",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/specPlayers",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/specPlayers",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/specPlayers",Failed("command_unimplemented"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendCommand",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendCommand",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendCommand",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendCommand",Failed("command_unimplemented"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendMessage",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendMessage",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendMessage",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/sendMessage",Failed("command_unimplemented"))) steps=30 samples=20000
// autohost/installEngine, autohost/subscribeUpdates
// @witness main=autohost_up inv=not(hit("autohost/installEngine",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/installEngine",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("autohost/installEngine",Failed("command_unimplemented"))) steps=30 samples=20000
// @witness main=autohost_test inv=not(hit("autohost/subscribeUpdates",Ok)) steps=30 samples=20000
// @witness main=autohost_test inv=not(hit("autohost/subscribeUpdates",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_test inv=not(hit("autohost/subscribeUpdates",Failed("command_unimplemented"))) steps=30 samples=20000
// battle/start (user's answer)
// @witness main=autohost_up inv=not(hit("battle/start",Ok)) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("battle/start",Failed("internal_error"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("battle/start",Failed("invalid_request"))) steps=30 samples=20000
// @witness main=autohost_up inv=not(hit("battle/start",Failed("command_unimplemented"))) steps=30 samples=20000
// autohost/update kinds and their effects; battle/ended; status
// @witness main=autohost_up inv=not(updateSeen("start")) steps=30 samples=20000
// @witness main=autohost_up inv=not(updateSeen("finished")) steps=30 samples=20000
// @witness main=autohost_up inv=not(updateSeen("player_left")) steps=30 samples=20000
// @witness main=autohost_up inv=not(updateSeen("engine_quit")) steps=30 samples=20000
// @witness main=autohost_up inv=not(updateSeen("engine_crash")) steps=30 samples=20000
// @witness main=autohost_up inv=not(resentUpdateIgnored) steps=30 samples=20000
// @witness main=autohost_up inv=not(endedWithWinner) steps=30 samples=20000
// @witness main=autohost_up inv=not(battleLost) steps=30 samples=20000
// @witness main=autohost_up inv=not(lateStartKilled) steps=30 samples=20000
// @witness main=autohost_up inv=not(statusDraining) steps=30 samples=20000
// @witness main=autohost_two inv=not(twoHostsBusy) steps=30 samples=10000
//
// @verify main=autohost_small inv=safety steps=2
module autohost {
  import common.* from "./common"
  import schema.* from "./schema"

  type HostId = str
  type BattleId = int

  // Server-side battle phases (design doc): PStarting = autohost/start sent, no
  // success yet; PRunning = autohost/start succeeded; PEnded = engine_quit/crash
  // received; Failed = the start was given up; PLost = the autohost stayed
  // away longer than the grace period.
  type Phase = PStarting | PRunning | PEnded | PFailed | PLost
  // Server's view of the autohost connection. Handshaking = connected, no
  // autohost/status yet.
  type Conn = Down | Handshaking | Up

  type Battle = {
    host: HostId, players: Set[UserId], spectators: Set[UserId], added: Set[UserId],
    engine: str, phase: Phase,
    mayRun: bool,       // the autohost may be running an engine for it (kill obligation)
    startTimer: bool,   // the start timeout is armed
    attempts: int,      // autohost/start requests sent for this battle
    lastTime: int,      // greatest update time applied (idempotency)
    reports: UserId -> int,   // finished reports: player -> winning ally team
    result: int,        // winning ally team, -1 = none
    started: int,       // ghost: times the match was recorded as started
    recorded: int,      // ghost: times a result was recorded
  }
  type Host = {
    conn: Conn, subscribed: bool, maxBattles: int, current: int,
    engines: Set[str], acked: int,
  }
  // One autohost/update; `user`/`team` only meaningful for some kinds.
  type Update = { time: int, battle: BattleId, kind: str, user: UserId, team: int }
  // The autohost's own state.
  type AH = {
    running: Set[BattleId], engines: Set[str], installing: Set[str],
    clock: int, log: Set[Update], subscribed: bool, cursor: int,
  }
  // Server -> autohost request, and the autohost's response.
  type Req = { cmd: str, battle: BattleId, user: UserId, engine: str, since: int }
  type Resp = { cmd: str, battle: BattleId, user: UserId, reply: Reply }

  type State = {
    battles: BattleId -> Battle,
    hosts: HostId -> Host,
    ah: HostId -> AH,
    reqs: Set[(HostId, Req)],
    resps: Set[(HostId, Resp)],
    userStarts: Set[(UserId, BattleId)],   // battle/start requests awaiting the user's answer
    dupIgnored: int,                        // ghost: resent updates dropped by idempotency
  }
  // battle/start is a server->user request; battle/ended carries the winner (-1 none).
  type Event = BattleStart(BattleId) | BattleEnded((BattleId, int))
  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)] }

  const USERS: Set[UserId]
  const HOSTS: Set[HostId]
  const BATTLE_IDS: Set[BattleId]
  const ENGINES: Set[str]
  const INITIAL_ENGINES: Set[str]
  const TEAMS: Set[int]
  const MAX_BATTLES: int        // what an autohost can really run
  const INIT_UP: bool          // start with every autohost connected, subscribed, status sent
  const CHURN: int              // simulation bias: a disconnect is 1 in CHURN+1 picks

  pure val NOU: UserId = ""
  pure val NOB: BattleId = -1
  pure val START = "autohost/start"
  pure val KILL = "autohost/kill"
  pure val ADD = "autohost/addPlayer"
  pure val INSTALL = "autohost/installEngine"
  pure val SUB = "autohost/subscribeUpdates"
  // Battle-scoped requests with no effect on server state.
  pure val SIMPLE_CMDS = Set("autohost/kickPlayer", "autohost/mutePlayer", "autohost/specPlayers",
                             "autohost/sendCommand", "autohost/sendMessage")
  // The autohost's free choice when a request is valid. docs/commands.md:
  // "All failed responses ... can return one of the following reasons".
  // `unauthorized` is unreachable: the server holds every role. `invalid_request`
  // is reserved for requests the autohost cannot apply (AH-A04).
  pure val CHOICES = Set("ok", "internal_error", "command_unimplemented")
  // engine-generated update kinds that matter to the server (others: AH-06)
  pure val KINDS = Set("start", "finished", "player_left", "engine_quit", "engine_crash")

  pure def req(cmd: str, b: BattleId, u: UserId, e: str, since: int): Req =
    { cmd: cmd, battle: b, user: u, engine: e, since: since }
  pure def noop(s: State): Outcome = { state: s, reply: NoReply, events: Set() }
  pure def max2(a: int, b: int): int = if (a > b) a else b

  pure def participants(b: Battle): Set[UserId] = b.players.union(b.spectators).union(b.added)
  pure def active(b: Battle): bool = b.phase == PStarting or b.phase == PRunning
  pure def dropped(b: Battle): bool = b.phase == PFailed or b.phase == PLost
  // Activity slot (design): a user is in at most one battle at a time.
  pure def activeUsers(s: State): Set[UserId] =
    s.battles.keys().filter(id => active(s.battles.get(id)))
      .fold(Set(), (acc, id) => acc.union(participants(s.battles.get(id))))
  pure def withBattle(s: State, id: BattleId, b: Battle): State =
    { ...s, battles: s.battles.set(id, b) }
  pure def withHost(s: State, h: HostId, x: Host): State = { ...s, hosts: s.hosts.set(h, x) }
  pure def withAH(s: State, h: HostId, a: AH): State = { ...s, ah: s.ah.set(h, a) }

  pure def inFlight(s: State, cmd: str, id: BattleId): bool =
    s.reqs.exists(m => m._2.cmd == cmd and m._2.battle == id)
      or s.resps.exists(m => m._2.cmd == cmd and m._2.battle == id)

  // Server's load estimate for a host: every battle it may still occupy.
  // ASSUMPTION AH-A07: own bookkeeping, not only the last reported currentBattles.
  pure def serverLoad(s: State, h: HostId): int =
    s.battles.keys().filter(id => {
      val b = s.battles.get(id)
      b.host == h and (active(b) or b.mayRun)
    }).size()

  // "This update is generated once per every single player reporting who won."
  // Design: one result by majority of the battle's players, else none.
  pure def majority(b: Battle, teams: Set[int]): int =
    teams.fold(-1, (acc, t) =>
      if (b.players.filter(p => p.in(b.reports.keys()) and b.reports.get(p) == t).size() * 2
          > b.players.size()) t else acc)

  // ======================= server-initiated steps =========================

  // A lobby or the matchmaker needs a battle (lobby/startBattle, matchmaking
  // step 8: "the server should send a autohost/battleStart request to a
  // suitable autohost client"). "suitable": connected, status received, and
  // load below the reported maxBattles (AH-A07).
  pure def canRequest(s: State, id: BattleId, h: HostId, players: Set[UserId],
                      specs: Set[UserId]): bool = and {
    not(id.in(s.battles.keys())),
    s.hosts.get(h).conn == Up,
    players != Set(),
    players.intersect(specs) == Set(),
    players.union(specs).intersect(activeUsers(s)) == Set(),
    max2(serverLoad(s, h), s.hosts.get(h).current) < s.hosts.get(h).maxBattles,
  }
  pure def requestBattle(s: State, id: BattleId, h: HostId, players: Set[UserId],
                         specs: Set[UserId], e: str): Outcome =
    if (not(canRequest(s, id, h, players, specs))) noop(s)
    else {
      val b = { host: h, players: players, spectators: specs, added: Set(), engine: e,
                phase: PStarting, mayRun: true, startTimer: true, attempts: 1, lastTime: 0,
                reports: Map(), result: -1, started: 0, recorded: 0 }
      { state: { ...s, battles: s.battles.put(id, b),
                 reqs: s.reqs.union(Set((h, req(START, id, NOU, e, 0)))) },
        reply: NoReply, events: Set() }
    }

  // matchmaking.md step 8: "If the autohost doesn't respond quickly, or if it
  // sends a failed response, the server should repeat this step."
  // Here: the start timer fires. The battle id is given up (Failed); a retry
  // is a new battle (requestBattle), possibly on another autohost.
  // ASSUMPTION AH-A02: mayRun stays set: a late success must be killed.
  pure def startTimeout(s: State, id: BattleId): Outcome =
    if (not(id.in(s.battles.keys()))) noop(s)
    else {
      val b = s.battles.get(id)
      if (b.phase != PStarting or not(b.startTimer)) noop(s)
      else { state: withBattle(s, id, { ...b, phase: PFailed, startTimer: false }),
             reply: NoReply, events: Set() }
    }

  // Design: a retried autohost/start for the same battle (e.g. after a
  // reconnect lost the answer). The autohost answers battle_already_exists if
  // the first one got through (handled in onResponse: kill-and-fail).
  pure def retryStart(s: State, id: BattleId): Outcome =
    if (not(id.in(s.battles.keys()))) noop(s)
    else {
      val b = s.battles.get(id)
      if (b.phase != PStarting or s.hosts.get(b.host).conn != Up or inFlight(s, START, id)) noop(s)
      else { state: { ...withBattle(s, id, { ...b, attempts: b.attempts + 1, mayRun: true }),
                      reqs: s.reqs.union(Set((b.host, req(START, id, NOU, b.engine, 0)))) },
             reply: NoReply, events: Set() }
    }

  // "Request to kill a battle." The server owes a kill for every dropped
  // battle the autohost may still run (design: kill-on-reconnect), and may kill
  // a running one (e.g. "!stop").
  pure def canSendKill(s: State, id: BattleId): bool =
    id.in(s.battles.keys()) and {
      val b = s.battles.get(id)
      and { b.phase != PStarting, b.mayRun, s.hosts.get(b.host).conn == Up,
            not(inFlight(s, START, id)), not(inFlight(s, KILL, id)) }
    }
  pure def sendKill(s: State, id: BattleId): Outcome =
    if (not(canSendKill(s, id))) noop(s)
    else { state: { ...s, reqs: s.reqs.union(Set((s.battles.get(id).host, req(KILL, id, NOU, "", 0)))) },
           reply: NoReply, events: Set() }

  // "Request to add a new player to the battle." (lobby/joinBattle)
  pure def sendAddPlayer(s: State, id: BattleId, u: UserId): Outcome =
    if (not(id.in(s.battles.keys()))) noop(s)
    else {
      val b = s.battles.get(id)
      if (b.phase != PRunning or s.hosts.get(b.host).conn != Up or u.in(activeUsers(s))
          or inFlight(s, ADD, id)) noop(s)
      else { state: { ...s, reqs: s.reqs.union(Set((b.host, req(ADD, id, u, "", 0)))) },
             reply: NoReply, events: Set() }
    }

  // kickPlayer "Kick a player from a battle." mutePlayer "Mute a player in a
  // battle." specPlayers "Force players to become spectators in a battle."
  // sendCommand "Send a custom command for the autohost to execute."
  // sendMessage "Send a message for the autohost to display to players."
  pure def sendSimple(s: State, cmd: str, id: BattleId, u: UserId): Outcome =
    if (not(id.in(s.battles.keys())) or not(cmd.in(SIMPLE_CMDS))) noop(s)
    else {
      val b = s.battles.get(id)
      if (b.phase != PRunning or s.hosts.get(b.host).conn != Up or not(u.in(participants(b)))
          or inFlight(s, cmd, id)) noop(s)
      else { state: { ...s, reqs: s.reqs.union(Set((b.host, req(cmd, id, u, "", 0)))) },
             reply: NoReply, events: Set() }
    }

  // "Ask the autohost to install specified engine version. ... It's fine to
  // call this method repeatedly"
  pure def sendInstall(s: State, h: HostId, e: str): Outcome =
    if (s.hosts.get(h).conn != Up or e.in(s.hosts.get(h).engines)
        or s.reqs.exists(m => m._1 == h and m._2.cmd == INSTALL and m._2.engine == e)) noop(s)
    else { state: { ...s, reqs: s.reqs.union(Set((h, req(INSTALL, NOB, NOU, e, 0)))) },
           reply: NoReply, events: Set() }

  // ====================== connection environment ==========================

  // The autohost (re)connects. The server asks for updates:
  // subscribeUpdates "Autohost will send all updates with time > since".
  // ASSUMPTION AH-A05: any since <= the greatest time applied (acked); the
  // server must then drop resent updates (idempotency by time).
  pure def connect(s: State, h: HostId, since: int): Outcome = {
    val x = s.hosts.get(h)
    if (x.conn != Down or since < 0 or since > x.acked) noop(s)
    else { state: { ...withHost(s, h, { ...x, conn: Handshaking, subscribed: false }),
                    reqs: s.reqs.union(Set((h, req(SUB, NOB, NOU, "", since)))) },
           reply: NoReply, events: Set() }
  }

  // The connection drops: whatever is in flight on it is lost. Engines keep
  // running and the autohost keeps logging updates (AH-A06).
  pure def disconnect(s: State, h: HostId): Outcome =
    if (s.hosts.get(h).conn == Down) noop(s)
    else {
      val s1 = withHost(s, h, { ...s.hosts.get(h), conn: Down, subscribed: false })
      val s2 = withAH(s1, h, { ...s.ah.get(h), subscribed: false })
      { state: { ...s2, reqs: s.reqs.filter(m => m._1 != h), resps: s.resps.filter(m => m._1 != h) },
        reply: NoReply, events: Set() }
    }

  // Design: PRunning battles survive an autohost disconnect for a grace period;
  // when it expires the battle is PLost and its participants get battle/ended
  // ("Sent to all players and spectators involved in a battle when it ends").
  // ASSUMPTION AH-A03: battle/ended with the majority result so far.
  pure def graceExpired(s: State, id: BattleId): Outcome =
    if (not(id.in(s.battles.keys()))) noop(s)
    else {
      val b = s.battles.get(id)
      if (b.phase != PRunning or s.hosts.get(b.host).conn != Down) noop(s)
      else {
        val w = majority(b, TEAMS)
        { state: withBattle(s, id, { ...b, phase: PLost, result: w, recorded: b.recorded + 1 }),
          reply: NoReply, events: send(participants(b), BattleEnded((id, w))) }
      }
    }

  // ======================== autohost-side steps ===========================

  pure def logUpdate(a: AH, id: BattleId, kind: str, u: UserId, t: int): AH =
    { ...a, clock: a.clock + 1,
      log: a.log.union(Set({ time: a.clock + 1, battle: id, kind: kind, user: u, team: t })) }

  // The autohost handles one request and queues its response.
  // `choice` is its free choice when the request is valid (CHOICES).
  pure def ahHandle(s: State, h: HostId, r: Req, choice: str): Outcome =
    if (not((h, r).in(s.reqs)) or not(choice.in(CHOICES))) noop(s)
    else {
      val a = s.ah.get(h)
      val freeFail = Failed(choice)
      // (new autohost state, reply)
      val res: (AH, Reply) =
        if (r.cmd == START) {
          // battle_already_exists / engine_version_not_available: schema reasons.
          if (r.battle.in(a.running)) (a, Failed("battle_already_exists"))
          else if (not(r.engine.in(a.engines))) (a, Failed("engine_version_not_available"))
          else if (choice == "ok") ({ ...a, running: a.running.union(Set(r.battle)) }, Ok)
          else (a, freeFail)
        } else if (r.cmd == SUB) {
          if (choice == "ok") ({ ...a, subscribed: true, cursor: r.since }, Ok)
          else (a, freeFail)
        } else if (r.cmd == INSTALL) {
          // "Return success instantly and autohost triggers the installation
          // of the engine in background."
          if (choice == "ok") ({ ...a, installing: a.installing.union(Set(r.engine)) }, Ok)
          else (a, freeFail)
        } else {
          // battle-scoped: kill, addPlayer, kick, mute, spec, sendCommand, sendMessage
          // ASSUMPTION AH-A04: a battle the autohost does not run -> invalid_request.
          if (not(r.battle.in(a.running))) (a, Failed("invalid_request"))
          else if (choice != "ok") (a, freeFail)
          else if (r.cmd == KILL)
            // ASSUMPTION AH-A08: a killed engine reports engine_quit.
            (logUpdate({ ...a, running: a.running.exclude(Set(r.battle)) }, r.battle, "engine_quit", NOU, -1), Ok)
          else if (r.cmd == "autohost/kickPlayer")
            (logUpdate(a, r.battle, "player_left", r.user, -1), Ok)
          else (a, Ok)
        }
      val s1 = withAH(s, h, res._1)
      { state: { ...s1, reqs: s.reqs.exclude(Set((h, r))),
                 resps: s.resps.union(Set((h, { cmd: r.cmd, battle: r.battle, user: r.user, reply: res._2 }))) },
        reply: NoReply, events: Set() }
    }

  // The engine produces an update. engine_quit: "The engine process for
  // battle has quit cleanly, no more updates will be sent for this battle."
  // engine_crash: "has crashed, no more updates will be sent".
  pure def engineEvent(s: State, h: HostId, id: BattleId, kind: str, u: UserId, t: int): Outcome = {
    val a = s.ah.get(h)
    if (not(id.in(a.running)) or not(kind.in(KINDS))) noop(s)
    else {
      val a1 = if (kind == "engine_quit" or kind == "engine_crash")
                 { ...a, running: a.running.exclude(Set(id)) } else a
      { state: withAH(s, h, logUpdate(a1, id, kind, u, t)), reply: NoReply, events: Set() }
    }
  }

  // installEngine: "When new engine is installed autohost send a status event
  // with the new available engine versions." (the status step below)
  pure def engineInstalled(s: State, h: HostId, e: str): Outcome = {
    val a = s.ah.get(h)
    if (not(e.in(a.installing))) noop(s)
    else { state: withAH(s, h, { ...a, installing: a.installing.exclude(Set(e)),
                                       engines: a.engines.union(Set(e)) }),
           reply: NoReply, events: Set() }
  }

  // autohost/status: "This event should be sent to the server on connection
  // and whenever any of the status properties change." "The maxBattles might
  // be reported lower (e.g. 0) then currentBattles."
  pure def status(s: State, h: HostId, maxB: int): Outcome = {
    val x = s.hosts.get(h)
    val a = s.ah.get(h)
    if (x.conn == Down or maxB < 0 or maxB > MAX_BATTLES) noop(s)
    else { state: withHost(s, h, { ...x, conn: Up, maxBattles: maxB, current: a.running.size(),
                                   engines: a.engines }),
           reply: NoReply, events: Set() }
  }

  // ======================== server receives ===============================

  // The next update the autohost would send on this connection (smallest time
  // > cursor), or a dummy with time -1.
  pure def nextUpdate(a: AH): Update =
    a.log.filter(x => x.time > a.cursor)
      .fold({ time: -1, battle: NOB, kind: "", user: NOU, team: -1 },
            (acc, x) => if (acc.time < 0 or x.time < acc.time) x else acc)

  // autohost/update: "Inform the server of battle updates. Each timestamp is
  // guaranteed to be unique for a given autohost."
  // One FIFO socket: an update cannot overtake the start response of its battle.
  pure def canDeliver(s: State, h: HostId): bool = {
    val a = s.ah.get(h)
    val n = nextUpdate(a)
    and { s.hosts.get(h).conn == Up, a.subscribed, n.time > 0,
          not(s.resps.exists(m => m._1 == h and m._2.cmd == START and m._2.battle == n.battle)) }
  }
  pure def deliverUpdate(s: State, h: HostId): Outcome =
    if (not(canDeliver(s, h))) noop(s)
    else {
      val a = s.ah.get(h)
      val n = nextUpdate(a)
      val s1 = withAH(withHost(s, h, { ...s.hosts.get(h), acked: max2(s.hosts.get(h).acked, n.time) }),
                      h, { ...a, cursor: n.time })
      if (not(n.battle.in(s.battles.keys()))) noop(s1)
      else {
        val b = s.battles.get(n.battle)
        val ends = n.kind == "engine_quit" or n.kind == "engine_crash"
        // ASSUMPTION AH-A05: idempotency by update time per battle.
        if (n.time <= b.lastTime) noop({ ...s1, dupIgnored: s1.dupIgnored + 1 })
        else if (b.phase == PRunning) {
          val b1 = { ...b, lastTime: n.time }
          if (n.kind == "start")
            noop(withBattle(s1, n.battle, { ...b1, started: if (b.started == 0) 1 else b.started }))
          else if (n.kind == "finished" and n.user.in(b.players))
            noop(withBattle(s1, n.battle, { ...b1, reports: b.reports.put(n.user, n.team) }))
          else if (ends) {
            val w = majority(b, TEAMS)
            // AH-12: with several start attempts this may be an earlier
            // engine's quit; keep the kill obligation (kill confirms).
            { state: withBattle(s1, n.battle, { ...b1, phase: PEnded, mayRun: b.attempts > 1, result: w,
                                                recorded: b.recorded + 1 }),
              reply: NoReply, events: send(participants(b), BattleEnded((n.battle, w))) }
          }
          else noop(withBattle(s1, n.battle, b1))
        } else {
          // Not running on the server side (PStarting, Failed, PLost, PEnded):
          // only engine_quit/crash matter: nothing runs any more (unless a
          // start request is still in flight).
          // AH-12: only unambiguous if a single start was ever sent.
          val clear = ends and b.attempts == 1 and not(inFlight(s, START, n.battle))
          noop(withBattle(s1, n.battle, { ...b, lastTime: n.time,
                                          mayRun: if (clear) false else b.mayRun }))
        }
      }
    }

  // The server receives the autohost's response to one of its requests.
  // lastCmd is that request's command id, lastReply the autohost's reply.
  pure def onResponse(s: State, h: HostId, r: Resp): Outcome =
    if (not((h, r).in(s.resps))) noop(s)
    else {
      val s0 = { ...s, resps: s.resps.exclude(Set((h, r))) }
      val known = r.battle.in(s.battles.keys())
      val b = if (known) s.battles.get(r.battle) else s.battles.get(theOne(s.battles.keys(), 0))
      if (r.cmd == START and known) {
        if (r.reply == Ok and b.phase == PStarting) {
          // battle/start: "When a user client receives this [request] it should
          // launch the game". matchmaking.md 9: "Once the autohost has
          // successfully started the battle, the server should then send
          // battle/battleStart requests to the users."
          val us = participants(b)
          { state: { ...withBattle(s0, r.battle, { ...b, phase: PRunning, startTimer: false }),
                     userStarts: s.userStarts.union(us.map(u => (u, r.battle))) },
            reply: r.reply, events: send(us, BattleStart(r.battle)) }
        } else if (r.reply == Ok) {
          // Late success after the battle was given up: mayRun stays set -> kill.
          { state: s0, reply: r.reply, events: Set() }
        } else {
          // Design: battle_already_exists on a retry -> kill-and-fail.
          // Any other failure: nothing started, unless an earlier attempt did.
          val keep = r.reply == Failed("battle_already_exists") or b.attempts > 1
          val b1 = { ...b, mayRun: if (keep) b.mayRun else false }
          val b2 = if (b.phase == PStarting) { ...b1, phase: PFailed, startTimer: false } else b1
          { state: withBattle(s0, r.battle, b2), reply: r.reply, events: Set() }
        }
      } else if (r.cmd == KILL and known) {
        // Ok: killed. invalid_request: it was not running (AH-A04).
        val gone = r.reply == Ok or r.reply == Failed("invalid_request")
        { state: if (gone) withBattle(s0, r.battle, { ...b, mayRun: false }) else s0,
          reply: r.reply, events: Set() }
      } else if (r.cmd == ADD and known) {
        if (r.reply == Ok and b.phase == PRunning and not(r.user.in(activeUsers(s)))) {
          // The added user gets battle/start (lobby/joinBattle: "the client
          // should receive shortly after a battle/start").
          { state: { ...withBattle(s0, r.battle, { ...b, added: b.added.union(Set(r.user)) }),
                     userStarts: s.userStarts.union(Set((r.user, r.battle))) },
            reply: r.reply, events: Set((r.user, BattleStart(r.battle))) }
        } else { state: s0, reply: r.reply, events: Set() }
      } else if (r.cmd == SUB) {
        if (r.reply == Ok)
          { state: withHost(s0, h, { ...s.hosts.get(h), subscribed: true }), reply: r.reply, events: Set() }
        else {
          // ASSUMPTION AH-A09 (teiserver): no subscription -> drop the connection.
          val d = disconnect(s0, h)
          { ...d, reply: r.reply }
        }
      } else { state: s0, reply: r.reply, events: Set() }
    }

  // The user answers battle/start. ASSUMPTION AH-A10: the server ignores the
  // answer (the protocol says nothing; teiserver has no handler).
  pure def userStartReply(s: State, u: UserId, id: BattleId, r: Reply): Outcome =
    if (not((u, id).in(s.userStarts))) noop(s)
    else { state: { ...s, userStarts: s.userStarts.exclude(Set((u, id))) }, reply: r, events: Set() }

  // ============================ state machine =============================
  var s: State
  var lastCmd: str
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]
  var lastUpdate: str      // kind of the update applied by the last autohost/update step

  pure val s0: State = {
    battles: Map(),
    hosts: HOSTS.mapBy(_ => { conn: if (INIT_UP) Up else Down, subscribed: INIT_UP,
                              maxBattles: if (INIT_UP) MAX_BATTLES else 0, current: 0,
                              engines: if (INIT_UP) INITIAL_ENGINES else Set(), acked: 0 }),
    ah: HOSTS.mapBy(_ => { running: Set(), engines: INITIAL_ENGINES, installing: Set(),
                           clock: 0, log: Set(), subscribed: INIT_UP, cursor: 0 }),
    reqs: Set(), resps: Set(), userStarts: Set(), dupIgnored: 0,
  }

  action apply(cmd: str, o: Outcome): bool = all {
    s' = o.state, lastCmd' = cmd, lastReply' = o.reply, lastEvents' = o.events, lastUpdate' = "",
  }
  action init = all {
    s' = s0, lastCmd' = "init", lastReply' = NoReply, lastEvents' = Set(), lastUpdate' = "",
  }

  // Simulation only takes steps with an effect (late/no-op fires are covered
  // by the transcripts), so random runs go deep.
  action go(cmd: str, o: Outcome): bool = all {
    o.state != s or o.events != Set() or o.reply != NoReply,
    apply(cmd, o),
  }

  action doHandle = {
    nondet m = s.reqs.oneOf()
    nondet c = CHOICES.oneOf()
    apply("env/ahHandle", ahHandle(s, m._1, m._2, c))
  }
  action doRespond = {
    nondet m = s.resps.oneOf()
    apply(m._2.cmd, onResponse(s, m._1, m._2))
  }
  action doUserReply = {
    nondet m = s.userStarts.oneOf()
    nondet r = Set(Ok, Failed("internal_error"), Failed("invalid_request"),
                   Failed("command_unimplemented")).oneOf()
    apply("battle/start", userStartReply(s, m._1, m._2, r))
  }
  action doDeliver(h: HostId): bool = all {
    canDeliver(s, h),
    s' = deliverUpdate(s, h).state, lastCmd' = "autohost/update", lastReply' = NoReply,
    lastEvents' = deliverUpdate(s, h).events, lastUpdate' = nextUpdate(s.ah.get(h)).kind,
  }

  action step = {
    nondet h = HOSTS.oneOf()
    nondet id = BATTLE_IDS.oneOf()
    nondet u = USERS.oneOf()
    nondet players = USERS.powerset().oneOf()
    nondet specs = USERS.powerset().oneOf()
    nondet e = ENGINES.oneOf()
    nondet kind = KINDS.oneOf()
    nondet t = TEAMS.oneOf()
    nondet cmd = SIMPLE_CMDS.oneOf()
    nondet since = 0.to(s.hosts.get(h).acked).oneOf()
    nondet maxB = Set(0, MAX_BATTLES).oneOf()
    nondet coin = 0.to(CHURN).oneOf()
    any {
      all { canRequest(s, id, h, players, specs), go("env/requestBattle", requestBattle(s, id, h, players, specs, e)) },
      go("env/startTimeout", startTimeout(s, id)),
      go("env/retryStart", retryStart(s, id)),
      all { canSendKill(s, id), go("env/sendKill", sendKill(s, id)) },
      go("env/sendAddPlayer", sendAddPlayer(s, id, u)),
      go("env/sendSimple", sendSimple(s, cmd, id, u)),
      go("env/sendInstall", sendInstall(s, h, e)),
      go("env/connect", connect(s, h, since)),
      all { coin == 0, go("env/disconnect", disconnect(s, h)) },
      go("env/graceExpired", graceExpired(s, id)),
      all { s.reqs != Set(), doHandle },
      go("env/engine", engineEvent(s, h, id, kind, u, t)),
      go("env/engineInstalled", engineInstalled(s, h, e)),
      go("autohost/status", status(s, h, maxB)),
      doDeliver(h),
      all { s.resps != Set(), doRespond },
      all { s.userStarts != Set(), doUserReply },
    }
  }

  // ============================== properties ==============================

  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  // Design: "no autohost keeps a battle the server has dropped": the server
  // never forgets an engine the autohost runs, so it can still kill it.
  val noForgottenBattles = HOSTS.forall(h => s.ah.get(h).running.forall(id =>
    id.in(s.battles.keys()) and s.battles.get(id).host == h and s.battles.get(id).mayRun))

  // A dropped battle the autohost may run always has a kill path while connected.
  val droppedKillable = s.battles.keys().forall(id => {
    val b = s.battles.get(id)
    (b.phase != PStarting and b.phase != PRunning and b.mayRun and s.hosts.get(b.host).conn == Up) implies
      (canSendKill(s, id) or inFlight(s, KILL, id) or inFlight(s, START, id))
  })

  // "No battle stays in starting forever": a PStarting battle always has its
  // timeout step enabled.
  val startingResolvable = s.battles.keys().forall(id => {
    val b = s.battles.get(id)
    b.phase == PStarting implies b.startTimer
  })

  // Each battle's start and result are recorded at most once, even with resends.
  val recordedOnce = s.battles.keys().forall(id =>
    s.battles.get(id).recorded <= 1 and s.battles.get(id).started <= 1)
  val resultIffOver = s.battles.keys().forall(id => {
    val b = s.battles.get(id)
    (b.recorded == 1) iff (b.phase == PEnded or b.phase == PLost)
  })

  // Load never exceeds what an autohost can run.
  val withinCapacity = HOSTS.forall(h => s.ah.get(h).running.size() <= MAX_BATTLES)

  // Activity slot: a user is in at most one active battle.
  val oneBattlePerUser = USERS.forall(u =>
    s.battles.keys().filter(id => active(s.battles.get(id)) and u.in(participants(s.battles.get(id)))).size() <= 1)

  // battle/start goes to exactly the battle's start-script users after
  // autohost/start success, or to the one added user after addPlayer success.
  val battleStartRecipients = and {
    lastEvents.forall(m => match m._2 {
      | BattleStart(id) => and { lastCmd == START or lastCmd == ADD,
                                 id.in(s.battles.keys()), s.battles.get(id).phase == PRunning,
                                 m._1.in(participants(s.battles.get(id))) }
      | BattleEnded(_) => true
    }),
    (lastCmd == START and lastReply == Ok and lastEvents != Set()) implies
      s.battles.keys().exists(id => {
        val b = s.battles.get(id)
        lastEvents == b.players.union(b.spectators).map(x => (x, BattleStart(id)))
      }),
  }

  // battle/ended: "Sent to all players and spectators involved in a battle
  // when it ends" - exactly those, once the battle is over.
  val battleEndedRecipients = lastEvents.forall(m => match m._2 {
    | BattleEnded(p) => and {
        p._1.in(s.battles.keys()),
        s.battles.get(p._1).phase == PEnded or s.battles.get(p._1).phase == PLost,
        p._2 == s.battles.get(p._1).result,
        lastEvents.filter(x => x._2 == m._2).map(x => x._1) == participants(s.battles.get(p._1)) }
    | BattleStart(_) => true
  })

  val wellFormed = s.battles.keys().forall(id => {
    val b = s.battles.get(id)
    and { (b.phase == PEnded and b.attempts == 1) implies not(b.mayRun),
          b.phase == PRunning implies not(b.startTimer),
          b.players.intersect(b.spectators) == Set() }
  })

  val safety = and {
    reasonsInSchema, noForgottenBattles, droppedKillable, startingResolvable, recordedOnce,
    resultIffOver, withinCapacity, oneBattlePerUser, battleStartRecipients,
    battleEndedRecipients, wellFormed,
  }

  // ---- witness helpers ----
  def hit(cmd: str, r: Reply): bool = lastCmd == cmd and lastReply == r
  val resentUpdateIgnored = s.dupIgnored > 0
  def updateSeen(kind: str): bool = lastCmd == "autohost/update" and lastUpdate == kind
  val endedWithWinner = s.battles.keys().exists(id =>
    s.battles.get(id).phase == PEnded and s.battles.get(id).result >= 0)
  val battleLost = s.battles.keys().exists(id => s.battles.get(id).phase == PLost)
  // A battle that timed out, then started late, then was killed.
  val lateStartKilled = lastCmd == KILL and lastReply == Ok and s.battles.keys().exists(id =>
    s.battles.get(id).phase == PFailed and not(s.battles.get(id).mayRun))
  val statusDraining = HOSTS.exists(h => s.hosts.get(h).conn == Up and s.hosts.get(h).maxBattles == 0
                                          and s.hosts.get(h).current > 0)
  val twoHostsBusy = HOSTS.forall(h => s.ah.get(h).running != Set())
}

module autohost_test {
  import common.* from "./common"
  import autohost(USERS = Set("a", "b", "c"), HOSTS = Set("h1"), BATTLE_IDS = Set(1, 2),
                  ENGINES = Set("e1", "e2"), INITIAL_ENGINES = Set("e1"), TEAMS = Set(0, 1),
                  MAX_BATTLES = 1, INIT_UP = false, CHURN = 3).*

  pure def sub(since: int): Req = req(SUB, NOB, NOU, "", since)
  pure def startReq(id: BattleId, e: str): Req = req(START, id, NOU, e, 0)
  pure def resp(cmd: str, id: BattleId, u: UserId, r: Reply): Resp =
    { cmd: cmd, battle: id, user: u, reply: r }

  // Connect h1, subscribe from `since`, report status (maxBattles 1).
  action up(since: int): bool =
    apply("env/connect", connect(s, "h1", since))
      .then(apply("env/ahHandle", ahHandle(s, "h1", sub(since), "ok")))
      .then(apply(SUB, onResponse(s, "h1", resp(SUB, NOB, NOU, Ok))))
      .then(apply("autohost/status", status(s, "h1", 1)))

  // Battle 1: players a,b, spectator c on h1 with engine e1, started.
  action running1: bool =
    up(0)
      .then(apply("env/requestBattle", requestBattle(s, 1, "h1", Set("a", "b"), Set("c"), "e1")))
      .then(apply("env/ahHandle", ahHandle(s, "h1", startReq(1, "e1"), "ok")))
      .then(apply(START, onResponse(s, "h1", resp(START, 1, NOU, Ok))))

  // Happy path: start, two finished reports, engine_quit -> battle/ended once.
  run happyPathTest =
    init
      .then(running1)
      .expect(lastEvents == Set(("a", BattleStart(1)), ("b", BattleStart(1)), ("c", BattleStart(1))))
      .expect(s.battles.get(1).phase == PRunning)
      .then(apply("battle/start", userStartReply(s, "a", 1, Ok)))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "start", NOU, -1)))
      .then(doDeliver("h1"))
      .expect(s.battles.get(1).started == 1)
      .then(apply("env/engine", engineEvent(s, "h1", 1, "finished", "a", 0)))
      .then(doDeliver("h1"))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "finished", "b", 0)))
      .then(doDeliver("h1"))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "engine_quit", NOU, -1)))
      .then(doDeliver("h1"))
      .expect(lastEvents == Set(("a", BattleEnded((1, 0))), ("b", BattleEnded((1, 0))), ("c", BattleEnded((1, 0)))))
      .expect(s.battles.get(1).phase == PEnded and s.battles.get(1).recorded == 1 and not(s.battles.get(1).mayRun))

  // Split finished reports: no majority -> result none.
  run noMajorityTest =
    init
      .then(running1)
      .then(apply("env/engine", engineEvent(s, "h1", 1, "finished", "a", 0)))
      .then(doDeliver("h1"))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "finished", "b", 1)))
      .then(doDeliver("h1"))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "engine_crash", NOU, -1)))
      .then(doDeliver("h1"))
      .expect(s.battles.get(1).result == -1)
      .expect(lastEvents.map(m => m._2) == Set(BattleEnded((1, -1))))

  // Missing engine: engine_version_not_available -> Failed, nothing to kill;
  // installEngine then a status with the new engine.
  run engineMissingTest =
    init
      .then(up(0))
      .then(apply("env/requestBattle", requestBattle(s, 1, "h1", Set("a"), Set(), "e2")))
      .then(apply("env/ahHandle", ahHandle(s, "h1", startReq(1, "e2"), "ok")))
      .then(apply(START, onResponse(s, "h1", resp(START, 1, NOU, Failed("engine_version_not_available")))))
      .expect(s.battles.get(1).phase == PFailed and not(s.battles.get(1).mayRun))
      .expect(not(canSendKill(s, 1)))
      .then(apply("env/sendInstall", sendInstall(s, "h1", "e2")))
      .then(apply("env/ahHandle", ahHandle(s, "h1", req(INSTALL, NOB, NOU, "e2", 0), "ok")))
      .then(apply(INSTALL, onResponse(s, "h1", resp(INSTALL, NOB, NOU, Ok))))
      .then(apply("env/engineInstalled", engineInstalled(s, "h1", "e2")))
      .then(apply("autohost/status", status(s, "h1", 1)))
      .expect(s.hosts.get("h1").engines == Set("e1", "e2"))

  // Capacity: maxBattles 1 and one battle running -> no second start.
  run capacityTest =
    init
      .then(running1)
      .expect(not(canRequest(s, 2, "h1", Set("a"), Set())))   // a is busy, and h1 full
      .then(apply("env/disconnect", disconnect(s, "h1")))
      .expect(not(canRequest(s, 2, "h1", Set("a"), Set())))

  // Disconnect while engine_quit is buffered; reconnect with an earlier
  // `since`: the resent updates are dropped by time, the result is recorded once.
  run resendTest =
    init
      .then(running1)
      .then(apply("env/engine", engineEvent(s, "h1", 1, "finished", "a", 1)))
      .then(doDeliver("h1"))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "finished", "b", 1)))
      .then(doDeliver("h1"))
      .then(apply("env/disconnect", disconnect(s, "h1")))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "engine_quit", NOU, -1)))
      .then(up(0))                       // since 0 < acked 2: updates 1, 2 resent
      .then(doDeliver("h1"))
      .expect(s.dupIgnored == 1 and lastEvents == Set())
      .then(doDeliver("h1"))
      .expect(s.dupIgnored == 2)
      .then(doDeliver("h1"))
      .expect(s.battles.get(1).phase == PEnded and s.battles.get(1).result == 1 and s.battles.get(1).recorded == 1)

  // Grace expires: PLost + battle/ended; on reconnect the server kills it.
  run graceLostKillTest =
    init
      .then(running1)
      .then(apply("env/disconnect", disconnect(s, "h1")))
      .then(apply("env/graceExpired", graceExpired(s, 1)))
      .expect(s.battles.get(1).phase == PLost)
      .expect(lastEvents == Set(("a", BattleEnded((1, -1))), ("b", BattleEnded((1, -1))), ("c", BattleEnded((1, -1)))))
      .then(apply("env/graceExpired", graceExpired(s, 1)))          // late fire: no-op
      .expect(lastEvents == Set())
      .then(up(0))
      .expect(canSendKill(s, 1))
      .then(apply("env/sendKill", sendKill(s, 1)))
      .then(apply("env/ahHandle", ahHandle(s, "h1", req(KILL, 1, NOU, "", 0), "ok")))
      .then(apply(KILL, onResponse(s, "h1", resp(KILL, 1, NOU, Ok))))
      .expect(not(s.battles.get(1).mayRun) and s.ah.get("h1").running == Set())
      .then(doDeliver("h1"))                                        // engine_quit of the kill
      .expect(s.battles.get(1).recorded == 1 and lastEvents == Set())

  // Start answer lost with the connection; the retry gets
  // battle_already_exists -> kill-and-fail.
  run retryAlreadyExistsTest =
    init
      .then(up(0))
      .then(apply("env/requestBattle", requestBattle(s, 1, "h1", Set("a"), Set(), "e1")))
      .then(apply("env/ahHandle", ahHandle(s, "h1", startReq(1, "e1"), "ok")))
      .then(apply("env/disconnect", disconnect(s, "h1")))
      .then(up(0))
      .then(apply("env/retryStart", retryStart(s, 1)))
      .then(apply("env/ahHandle", ahHandle(s, "h1", startReq(1, "e1"), "ok")))
      .then(apply(START, onResponse(s, "h1", resp(START, 1, NOU, Failed("battle_already_exists")))))
      .expect(s.battles.get(1).phase == PFailed and s.battles.get(1).mayRun and lastEvents == Set())
      .then(apply("env/sendKill", sendKill(s, 1)))
      .then(apply("env/ahHandle", ahHandle(s, "h1", req(KILL, 1, NOU, "", 0), "ok")))
      .then(apply(KILL, onResponse(s, "h1", resp(KILL, 1, NOU, Ok))))
      .expect(not(s.battles.get(1).mayRun))

  // Start times out, then succeeds late: no battle/start, the server kills it.
  run lateSuccessTest =
    init
      .then(up(0))
      .then(apply("env/requestBattle", requestBattle(s, 1, "h1", Set("a"), Set(), "e1")))
      .then(apply("env/startTimeout", startTimeout(s, 1)))
      .expect(s.battles.get(1).phase == PFailed)
      .then(apply("env/ahHandle", ahHandle(s, "h1", startReq(1, "e1"), "ok")))
      .then(apply(START, onResponse(s, "h1", resp(START, 1, NOU, Ok))))
      .expect(lastEvents == Set() and s.battles.get(1).phase == PFailed)
      .then(apply("env/sendKill", sendKill(s, 1)))
      .then(apply("env/ahHandle", ahHandle(s, "h1", req(KILL, 1, NOU, "", 0), "ok")))
      .then(apply(KILL, onResponse(s, "h1", resp(KILL, 1, NOU, Ok))))
      .expect(lateStartKilled)

  // Request lost with the connection, start timed out: kill of an unknown
  // battle -> invalid_request, and the obligation is cleared.
  run killUnknownTest =
    init
      .then(up(0))
      .then(apply("env/requestBattle", requestBattle(s, 1, "h1", Set("a"), Set(), "e1")))
      .then(apply("env/disconnect", disconnect(s, "h1")))
      .then(apply("env/startTimeout", startTimeout(s, 1)))
      .then(up(0))
      .then(apply("env/sendKill", sendKill(s, 1)))
      .then(apply("env/ahHandle", ahHandle(s, "h1", req(KILL, 1, NOU, "", 0), "ok")))
      .then(apply(KILL, onResponse(s, "h1", resp(KILL, 1, NOU, Failed("invalid_request")))))
      .expect(not(s.battles.get(1).mayRun) and serverLoad(s, "h1") == 0)

  // addPlayer success -> battle/start to the new user only; kickPlayer of a
  // battle whose engine already quit -> invalid_request.
  run addKickTest =
    init
      .then(up(0))
      .then(apply("env/requestBattle", requestBattle(s, 1, "h1", Set("a"), Set(), "e1")))
      .then(apply("env/ahHandle", ahHandle(s, "h1", startReq(1, "e1"), "ok")))
      .then(apply(START, onResponse(s, "h1", resp(START, 1, NOU, Ok))))
      .then(apply("env/sendAddPlayer", sendAddPlayer(s, 1, "b")))
      .then(apply("env/ahHandle", ahHandle(s, "h1", req(ADD, 1, "b", "", 0), "ok")))
      .then(apply(ADD, onResponse(s, "h1", resp(ADD, 1, "b", Ok))))
      .expect(lastEvents == Set(("b", BattleStart(1))))
      .then(apply("env/sendSimple", sendSimple(s, "autohost/kickPlayer", 1, "b")))
      .then(apply("env/engine", engineEvent(s, "h1", 1, "engine_quit", NOU, -1)))
      .then(apply("env/ahHandle", ahHandle(s, "h1", req("autohost/kickPlayer", 1, "b", "", 0), "ok")))
      .then(apply("autohost/kickPlayer", onResponse(s, "h1", resp("autohost/kickPlayer", 1, "b", Failed("invalid_request")))))
      .then(doDeliver("h1"))
      .expect(lastEvents == Set(("a", BattleEnded((1, -1))), ("b", BattleEnded((1, -1)))))

  // subscribeUpdates failure: the server drops the connection (AH-A09).
  run subscribeFailTest =
    init
      .then(apply("env/connect", connect(s, "h1", 0)))
      .then(apply("env/ahHandle", ahHandle(s, "h1", sub(0), "internal_error")))
      .then(apply(SUB, onResponse(s, "h1", resp(SUB, NOB, NOU, Failed("internal_error")))))
      .expect(lastReply == Failed("internal_error") and s.hosts.get("h1").conn == Down)

  // The user's battle/start failure (bar-lobby: missing assets) changes nothing.
  run userStartFailTest =
    init
      .then(running1)
      .then(apply("battle/start", userStartReply(s, "c", 1, Failed("internal_error"))))
      .expect(s.battles.get(1).phase == PRunning and s.battles.get(1).spectators == Set("c"))
}

// Simulation instance starting connected (the connect handshake is covered by
// autohost_test): most witnesses run here so random runs reach deep states.
module autohost_up {
  import common.* from "./common"
  import autohost(USERS = Set("a", "b", "c"), HOSTS = Set("h1"), BATTLE_IDS = Set(1, 2),
                  ENGINES = Set("e1", "e2"), INITIAL_ENGINES = Set("e1"), TEAMS = Set(0, 1),
                  MAX_BATTLES = 1, INIT_UP = true, CHURN = 3).*
}

// Two autohosts: battles on both, independent connections.
module autohost_two {
  import common.* from "./common"
  import autohost(USERS = Set("a", "b", "c"), HOSTS = Set("h1", "h2"), BATTLE_IDS = Set(1, 2, 3),
                  ENGINES = Set("e1", "e2"), INITIAL_ENGINES = Set("e1"), TEAMS = Set(0, 1),
                  MAX_BATTLES = 1, INIT_UP = false, CHURN = 3).*
}

// Smallest instance for Apalache.
module autohost_small {
  import common.* from "./common"
  import autohost(USERS = Set("a", "b"), HOSTS = Set("h1"), BATTLE_IDS = Set(1),
                  ENGINES = Set("e1"), INITIAL_ENGINES = Set("e1"), TEAMS = Set(0),
                  MAX_BATTLES = 1, INIT_UP = true, CHURN = 0).*
}
