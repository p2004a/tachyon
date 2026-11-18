// Matchmaking: matchmaking/list, matchmaking/queue, matchmaking/cancel,
// matchmaking/ready (user->server); the events matchmaking/queuesJoined,
// queueUpdate, found, foundUpdate, lost, cancelled; the server->user request
// matchmaking/checkAssets (sent to the other party members on a party queue);
// and the environment steps around them: the matcher, the ready-check timeout,
// battle start / start failure, a queue's asset list changing, and the
// party / lobby / battle / session changes owned by other groups (abstracted).
// Source: tachyon src/schema/matchmaking/README.md (rendered in
// docs/schema/matchmaking.md) and src/schema/matchmaking/*.ts descriptions.
// Findings: findings/matchmaking.md (MM-nn ids below).
//
// @test main=matchmaking_test
// @inv main=matchmaking_test inv=safety steps=30 samples=20000
// @witness main=matchmaking_test inv=not(hit("matchmaking/list","listed"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","queued"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","replaced"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","party_queued"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","already_in_battle")) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","in_lobby"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","invalid_queue_specified"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","version_mismatch"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","already_queued"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","party_too_big"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/queue","party_missing_asset"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/cancel","left_queue"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/cancel","declined")) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(hit("matchmaking/cancel","not_queued"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/ready","readied"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/ready","all_ready"))
// @witness main=matchmaking_test inv=not(hit("matchmaking/ready","already_ready")) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(hit("matchmaking/ready","no_match"))
// @witness main=matchmaking_test inv=not(hit("env/match","found"))
// @witness main=matchmaking_test inv=not(hit("env/readyTimeout","lost"))
// @witness main=matchmaking_test inv=not(hit("env/battleStarted","started")) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(hit("env/startGaveUp","gave_up")) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(hit("env/queueUpdate","sent"))
// @witness main=matchmaking_test inv=not(hit("env/versionChanged","bumped"))
// @witness main=matchmaking_test inv=not(hit("env/partyLeave","party_unqueued"))
// @witness main=matchmaking_test inv=not(hit("env/partyJoin","solo_cancelled"))
// @witness main=matchmaking_test inv=not(hit("env/sessionExpired","withdrawn"))
// @witness main=matchmaking_test inv=not(found2v2WithParty) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(requeuedAfterLost)
// @witness main=matchmaking_test inv=not(staleRequeueCancelled) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(cancelledWith("intentional"))
// @witness main=matchmaking_test inv=not(cancelledWith("server_error")) steps=40 samples=40000
// @witness main=matchmaking_test inv=not(cancelledWith("party_user_left"))
// @witness main=matchmaking_test inv=not(cancelledWith("ready_timeout"))
// @witness main=matchmaking_test inv=not(cancelledWith("version_changed"))
// @verify main=matchmaking_test inv=safety steps=2
// (verify: no violation at 2 steps in ~190 s with JVM_ARGS=-Xmx6G; 3 steps not attempted, see findings)
module matchmaking {
  import common.* from "./common"

  type QueueId = str
  // A queue reference as sent in matchmaking/queue: id + version.
  // Versions are opaque strings in Tachyon; here a counter per queue.
  type QRef = (QueueId, int)
  type QueueSpec = { teamSize: int, numTeams: int }
  // A ticket: the unit that is queued. A solo user, or a whole party (MM-05).
  type Ticket = { members: Set[UserId], queues: Set[QRef] }
  type Phase = ReadyCheck | Starting
  // A found match. `tickets` keep all the queues they were in: user/self
  // "found" carries `otherQueues`, so a found ticket remembers them (MM-11).
  type Match = { queue: QueueId, tickets: Set[Ticket], ready: Set[UserId], phase: Phase }
  type State = {
    searching: Set[Ticket],
    matches: Set[Match],
    version: QueueId -> int,
    // Abstract views of other groups' state (see findings "Cross-module interface").
    parties: Set[Set[UserId]],            // party module: parties with >= 2 members
    inLobby: Set[UserId],                 // lobby module
    inBattle: Set[UserId],                // battle module
    missing: Set[(UserId, QueueId)]       // client-side assets (what checkAssets answers)
  }
  type Event =
    | QueuesJoined(Set[QueueId])
    | QueueUpdate(int)
    | Found(QueueId)
    | FoundUpdate(int)
    | Lost
    | Cancelled(str)
  // Server->user requests sent in a step (kept apart from events so that a
  // denial still has no events: party_missing_asset is decided after checkAssets).
  type ServerRequest = CheckAssets(QueueId) | BattleStart
  type Outcome = {
    state: State, reply: Reply, events: Set[(UserId, Event)],
    requests: Set[(UserId, ServerRequest)], why: str
  }

  const USERS: Set[UserId]
  const QUEUES: QueueId -> QueueSpec
  const MAX_VERSION: int
  const MAX_PARTY: int

  pure val CANCELLED_REASONS =
    Set("intentional", "server_error", "party_user_left", "ready_timeout", "version_changed")
  pure val NO_TICKET: Ticket = { members: Set(), queues: Set() }
  pure val NO_MATCH: Match = { queue: "", tickets: Set(), ready: Set(), phase: ReadyCheck }

  // ---- helpers ----
  pure def membersOf(ts: Set[Ticket]): Set[UserId] = ts.map(t => t.members).flatten()
  pure def matchMembers(m: Match): Set[UserId] = membersOf(m.tickets)
  pure def searchingUsers(s: State): Set[UserId] = membersOf(s.searching)
  pure def matchedUsers(s: State): Set[UserId] = s.matches.map(m => matchMembers(m)).flatten()
  pure def inMM(s: State, u: UserId): bool =
    searchingUsers(s).contains(u) or matchedUsers(s).contains(u)
  pure def partyOf(s: State, u: UserId): Set[Set[UserId]] = s.parties.filter(p => p.contains(u))
  // The queueing unit of u: its party, or u alone.
  pure def groupOf(s: State, u: UserId): Set[UserId] = theOne(partyOf(s, u), Set(u))
  pure def qids(t: Ticket): Set[QueueId] = t.queues.map(r => r._1)
  pure def verOf(s: State, q: QueueId): int = if (QUEUES.keys().contains(q)) s.version.get(q) else 0
  pure def current(s: State, t: Ticket): bool = t.queues.forall(r => s.version.get(r._1) == r._2)
  pure def slots(q: QueueId): int = QUEUES.get(q).teamSize * QUEUES.get(q).numTeams
  pure def sizeSum(ts: Set[Ticket]): int = ts.fold(0, (acc, t) => acc + t.members.size())
  pure def matchOf(s: State, u: UserId): Match =
    theOne(s.matches.filter(m => matchMembers(m).contains(u)), NO_MATCH)
  pure def withMatch(s: State, old: Match, m: Match): State =
    { ...s, matches: s.matches.exclude(Set(old)).union(Set(m)) }

  pure def out(st: State, r: Reply, evs: Set[(UserId, Event)], why: str): Outcome =
    { state: st, reply: r, events: evs, requests: Set(), why: why }
  pure def deny(s: State, reason: str, why: str): Outcome = out(s, Failed(reason), Set(), why)
  pure def noop(s: State, why: str): Outcome = out(s, NoReply, Set(), why)

  // "Server should send [found] when there are enough queued players to form a
  // valid battle that meets their criteria." The criteria (rating, wait time)
  // are abstracted: any set of tickets that fills the teams exactly may match.
  // Tickets never split across teams. Exact for two teams (one team is a subset
  // of the tickets; the size sum gives the other). For more teams it checks only
  // ticket size <= teamSize, which is exact when teamSize <= 2. Written without
  // setOfMaps so that Apalache can check it.
  pure def teamsFormable(q: QueueId, ts: Set[Ticket]): bool = {
    val spec = QUEUES.get(q)
    and {
      ts.forall(t => t.members.size() <= spec.teamSize),
      spec.numTeams != 2 or ts.powerset().exists(a => sizeSum(a) == spec.teamSize),
    }
  }
  pure def matchable(s: State, q: QueueId, ts: Set[Ticket]): bool = and {
    ts != Set(),
    ts.subseteq(s.searching),
    ts.forall(t => qids(t).contains(q)),
    sizeSum(ts) == slots(q),
    teamsFormable(q, ts),
  }

  // A found match is disbanded. The tickets in `withdrawn` leave matchmaking
  // (the caller adds their events); every other ticket gets `lost` and goes
  // back to searching in all its queues: "the queueing phase should resume".
  // A ticket whose queue version changed meanwhile cannot resume (MM-12).
  pure def disband(s: State, m: Match, withdrawn: Set[Ticket]): (State, Set[(UserId, Event)]) = {
    val back = m.tickets.exclude(withdrawn)
    val fresh = back.filter(t => current(s, t))
    val stale = back.exclude(fresh)
    ({ ...s, matches: s.matches.exclude(Set(m)), searching: s.searching.union(fresh) },
     send(membersOf(back), Lost).union(send(membersOf(stale), Cancelled("version_changed"))))
  }

  // u's ticket leaves matchmaking. u gets cancelled(selfReason) if notifySelf;
  // party_user_left: "a member of the player's party left matchmaking, thus
  // forcing the entire party to withdraw" goes to u's ticket mates.
  // In a ready check this is a decline: "to decline a found match, clients
  // should send a cancel request"; the other tickets resume queueing (MM-09).
  pure def withdraw(s: State, u: UserId, selfReason: str, notifySelf: bool): (State, Set[(UserId, Event)]) = {
    val mine = s.searching.filter(t => t.members.contains(u))
    val m = matchOf(s, u)
    val t = theOne(mine.union(m.tickets.filter(x => x.members.contains(u))), NO_TICKET)
    val selfEv = if (notifySelf) send(Set(u), Cancelled(selfReason)) else Set()
    val ev = selfEv.union(send(t.members.exclude(Set(u)), Cancelled("party_user_left")))
    if (mine != Set()) ({ ...s, searching: s.searching.exclude(mine) }, ev)
    else if (m != NO_MATCH) {
      val d = disband(s, m, Set(t))
      (d._1, d._2.union(ev))
    } else (s, Set())
  }

  // ---- user -> server ----

  // "Returns all available matchmaking playlists." The reply data is listData(s).
  pure def listData(s: State): QueueId -> (QueueSpec, int) =
    QUEUES.keys().mapBy(q => (QUEUES.get(q), s.version.get(q)))
  pure def list(s: State, u: UserId): Outcome = out(s, Ok, Set(), "listed")

  // "Queue up for matchmaking. Should cancel the previous queue if already in one."
  // Party: "When a player is in a party and a member of the party sends a
  // matchmaking/queue request ..., all other members of the party will receive
  // a matchmaking/checkAssets request. ... If any client's assetStatus response
  // is missing, downloading, or if it times out without sending a response, the
  // matchmaking queue request will fail. If all other party members reply with
  // assetStatus: complete ..., all other members of the party will receive a
  // matchmaking/queuesJoined event. The initiating client will not receive the
  // matchmaking/queuesJoined event."
  // The checkAssets round trip is collapsed into this step (MM-06). Guard order
  // is an ASSUMPTION MM-03.
  pure def queue(s: State, u: UserId, req: Set[QRef]): Outcome = {
    val g = groupOf(s, u)
    val others = g.exclude(Set(u))
    val ids = req.map(r => r._1)
    if (req == Set()) deny(s, "invalid_request", "empty")   // schema minItems: 1
    // "already_in_battle" (no description). Any member of the unit in a battle.
    else if (g.exists(x => s.inBattle.contains(x))) deny(s, "already_in_battle", "already_in_battle")
    // ASSUMPTION MM-04 (design: queueing while in a lobby -> invalid_request)
    else if (g.exists(x => s.inLobby.contains(x))) deny(s, "invalid_request", "in_lobby")
    else if (not(ids.subseteq(QUEUES.keys()))) deny(s, "invalid_queue_specified", "invalid_queue_specified")
    // list: version "uniquely identifies the properties of the queue with this id"
    else if (req.exists(r => s.version.get(r._1) != r._2)) deny(s, "version_mismatch", "version_mismatch")
    // ASSUMPTION MM-01 (design: already_queued once a match is found)
    else if (g.exists(x => matchedUsers(s).contains(x))) deny(s, "already_queued", "already_queued")
    // Gap MM-07: no reason for a party larger than the team size
    else if (ids.exists(q => g.size() > QUEUES.get(q).teamSize)) deny(s, "invalid_request", "party_too_big")
    else {
      val checks = tuples(others, ids).map(p => (p._1, CheckAssets(p._2)))
      if (tuples(others, ids).exists(p => s.missing.contains(p)))
        { state: s, reply: Failed("party_missing_asset"), events: Set(), requests: checks,
          why: "party_missing_asset" }
      else {
        // "Should cancel the previous queue": the unit's searching ticket is replaced
        // (no cancelled event: ASSUMPTION MM-02).
        val replaced = s.searching.filter(t => t.members.intersect(g) != Set())
        { state: { ...s, searching: s.searching.exclude(replaced).union(Set({ members: g, queues: req })) },
          reply: Ok, events: send(others, QueuesJoined(ids)), requests: checks,
          why: if (replaced != Set()) "replaced" else if (others != Set()) "party_queued" else "queued" }
      }
    }
  }

  // "Cancel queueing for matchmaking." / "To cancel queueing, or to decline a
  // found match, clients should send a cancel request. After a successful cancel
  // response, the server will also send a cancelled event."
  pure def cancel(s: State, u: UserId): Outcome =
    if (not(inMM(s, u))) deny(s, "not_queued", "not_queued")
    else {
      val w = withdraw(s, u, "intentional", true)
      out(w._1, Ok, w._2, if (matchedUsers(s).contains(u)) "declined" else "left_queue")
    }

  // "Clients should send this when they are ready to proceed with the found
  // match." / "The number of readied players should be sent to clients via the
  // foundUpdate event." / foundUpdate: "Server should send this when players
  // ready up using ready."
  pure def ready(s: State, u: UserId): Outcome = {
    val m = matchOf(s, u)
    if (m == NO_MATCH) deny(s, "no_match", "no_match")
    // ASSUMPTION MM-10: a repeated ready succeeds and changes nothing
    else if (m.ready.contains(u)) out(s, Ok, Set(), "already_ready")
    else {
      val r = m.ready.union(Set(u))
      // "Once all players are ready, the server should send a autohost/battleStart
      // request to a suitable autohost" -> phase Starting.
      val allReady = r == matchMembers(m)
      val m2 = { ...m, ready: r, phase: if (allReady) Starting else ReadyCheck }
      out(withMatch(s, m, m2), Ok, send(matchMembers(m), FoundUpdate(r.size())),
          if (allReady) "all_ready" else "readied")
    }
  }

  // ---- environment ----

  // The matcher. "When a match is found, the server should send a found event
  // along with the id of the queue of the found match."
  pure def matchFound(s: State, q: QueueId, ts: Set[Ticket]): Outcome =
    if (ts == Set()) noop(s, "none")
    else if (not(matchable(s, q, ts))) noop(s, "none")
    else {
      val m = { queue: q, tickets: ts, ready: Set(), phase: ReadyCheck }
      out({ ...s, searching: s.searching.exclude(ts), matches: s.matches.union(Set(m)) },
          NoReply, send(membersOf(ts), Found(q)), "found")
    }

  // ready: "If not sent within 10s of the found response then queue should be
  // cancelled." / README 7: "If a client fails to ready up for a found match,
  // the server should send a lost event, and the queueing phase should resume."
  // / ready_timeout: "The player failed to accept a match within the given time
  // window and is thus removed from the matchmaking system."
  // Contradiction MM-08: all members get lost; tickets with a non-ready member
  // are removed (ready_timeout to the non-ready, party_user_left to their ready
  // party mates: ASSUMPTION MM-08); the other tickets resume queueing.
  pure def readyTimeout(s: State, u: UserId): Outcome = {
    val m = matchOf(s, u)
    if (m == NO_MATCH or m.phase != ReadyCheck) noop(s, "none")   // late fire
    else {
      val failed = m.tickets.filter(t => not(t.members.subseteq(m.ready)))
      val d = disband(s, m, failed)
      val f = membersOf(failed)
      out(d._1, NoReply,
          d._2.union(send(f, Lost))
              .union(send(f.exclude(m.ready), Cancelled("ready_timeout")))
              .union(send(f.intersect(m.ready), Cancelled("party_user_left"))),
          "lost")
    }
  }

  // README 9: "Once the autohost has successfully started the battle, the server
  // should then send battle/battleStart requests to the users." (battle/start).
  pure def battleStarted(s: State, u: UserId): Outcome = {
    val m = matchOf(s, u)
    if (m == NO_MATCH or m.phase != Starting) noop(s, "none")
    else {
      val st = { ...s, matches: s.matches.exclude(Set(m)), inBattle: s.inBattle.union(matchMembers(m)) }
      { state: st, reply: NoReply, events: Set(),
        requests: send(matchMembers(m), BattleStart), why: "started" }
    }
  }

  // README 8: "If the autohost doesn't respond quickly, or if it sends a failed
  // response, the server should repeat this step." A failed start is a no-op:
  // the match stays Starting and the server retries (design: on another autohost).
  pure def startFailed(s: State, u: UserId): Outcome = noop(s, "retry")

  // Gap MM-13: the protocol never gives up. ASSUMPTION: after retries the server
  // may abandon the match: lost + cancelled(server_error) to all its members.
  pure def startGaveUp(s: State, u: UserId): Outcome = {
    val m = matchOf(s, u)
    if (m == NO_MATCH or m.phase != Starting) noop(s, "none")
    else out({ ...s, matches: s.matches.exclude(Set(m)) }, NoReply,
             send(matchMembers(m), Lost).union(send(matchMembers(m), Cancelled("server_error"))),
             "gave_up")
  }

  // "The server can send periodic updates about the status of the search as a
  // queueUpdate event." / "Contains some info about the state of the current
  // queue." playersQueued = users searching in q (Gap MM-14).
  pure def queueUpdate(s: State, q: QueueId): Outcome = {
    val us = membersOf(s.searching.filter(t => qids(t).contains(q)))
    if (us == Set()) noop(s, "none")
    else out(s, NoReply, send(us, QueueUpdate(us.size())), "sent")
  }

  // README: cancelled "can happen ... if list of required assets changed".
  // Reason version_changed (enum only). The queue gets a new version and every
  // client lacks the new assets. Searching tickets in q are cancelled; found
  // matches proceed (ASSUMPTION MM-12).
  pure def versionChanged(s: State, q: QueueId): Outcome =
    if (s.version.get(q) >= MAX_VERSION) noop(s, "none")
    else {
      val hit = s.searching.filter(t => qids(t).contains(q))
      out({ ...s, version: s.version.set(q, s.version.get(q) + 1),
                  searching: s.searching.exclude(hit),
                  missing: s.missing.union(tuples(USERS, Set(q))) },
          NoReply, send(membersOf(hit), Cancelled("version_changed")), "bumped")
    }

  pure def assetsDownloaded(s: State, u: UserId, q: QueueId): Outcome =
    out({ ...s, missing: s.missing.exclude(Set((u, q))) }, NoReply, Set(), "downloaded")

  // Party module (abstract): u accepts v's invite / v creates a party with u.
  // Consistent with findings/party.md I3, PARTY-14, PARTY-20: a party in
  // matchmaking (searching or found) cannot change members; joining or creating
  // a party ends the user's solo matchmaking with cancelled(intentional).
  pure def partyJoin(s: State, u: UserId, v: UserId): Outcome = {
    val pv = groupOf(s, v)
    val np = pv.union(Set(u))
    if (u == v or partyOf(s, u) != Set() or np.size() > MAX_PARTY
        or matchedUsers(s).contains(u) or matchedUsers(s).contains(v)
        or (pv.size() > 1 and searchingUsers(s).contains(v)))
      noop(s, "none")
    else {
      val solo = s.searching.filter(t => t.members.intersect(np) != Set())
      out({ ...s, parties: s.parties.exclude(Set(pv)).union(Set(np)),
                  searching: s.searching.exclude(solo) },
          NoReply, send(membersOf(solo), Cancelled("intentional")),
          if (solo != Set()) "solo_cancelled" else "joined")
    }
  }

  pure def removeFromParty(s: State, u: UserId): State = {
    val p = theOne(partyOf(s, u), Set())
    val rest = p.exclude(Set(u))
    if (p == Set()) s
    else { ...s, parties: s.parties.exclude(Set(p)).union(if (rest.size() >= 2) Set(rest) else Set()) }
  }

  // Party module (abstract): u leaves or is kicked from its party (PARTY-14/16:
  // any membership change). party_user_left to every member, the leaver too
  // (ASSUMPTION MM-15, as teiserver and party.qnt).
  pure def partyLeave(s: State, u: UserId): Outcome =
    if (partyOf(s, u) == Set()) noop(s, "none")
    else {
      val w = withdraw(s, u, "party_user_left", true)
      out(removeFromParty(w._1, u), NoReply, w._2,
          if (inMM(s, u)) "party_unqueued" else "left_party")
    }

  // Session module (abstract): env/sessionExpired, the session ends (grace
  // period expired; session.qnt `sessionExpired`, INT-D1). A dropped socket
  // (env/disconnect) and a replaced connection (env/takeover) change nothing
  // here: "a detached member fails the ready check" by not sending ready.
  // INT-D2 (ASSUMPTION): the session stays while the user is in a battle.
  // u gets no events (offline).
  pure def sessionExpired(s: State, u: UserId): Outcome =
    if (s.inBattle.contains(u)) noop(s, "none")
    else {
      val w = withdraw(s, u, "", false)
      out({ ...removeFromParty(w._1, u), inLobby: s.inLobby.exclude(Set(u)) }, NoReply, w._2,
          if (inMM(s, u)) "withdrawn" else "ended")
    }

  // Lobby / battle modules (abstract). Lobby join is refused while in matchmaking.
  pure def lobbyEnter(s: State, u: UserId): Outcome =
    if (inMM(s, u) or s.inBattle.contains(u)) noop(s, "none")
    else out({ ...s, inLobby: s.inLobby.union(Set(u)) }, NoReply, Set(), "entered")
  pure def lobbyExit(s: State, u: UserId): Outcome =
    out({ ...s, inLobby: s.inLobby.exclude(Set(u)) }, NoReply, Set(), "exited")
  pure def battleEnded(s: State, u: UserId): Outcome =
    out({ ...s, inBattle: s.inBattle.exclude(Set(u)) }, NoReply, Set(), "ended")

  // ---- state machine ----
  var s: State
  var prev: State
  var lastCmd: str
  var lastActor: UserId
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]
  var lastRequests: Set[(UserId, ServerRequest)]
  var lastWhy: str

  pure val INIT: State = {
    searching: Set(), matches: Set(), version: QUEUES.keys().mapBy(q => 0),
    parties: Set(), inLobby: Set(), inBattle: Set(), missing: Set()
  }

  action apply(cmd: str, actor: UserId, o: Outcome): bool = all {
    s' = o.state, prev' = s, lastCmd' = cmd, lastActor' = actor, lastReply' = o.reply,
    lastEvents' = o.events, lastRequests' = o.requests, lastWhy' = o.why,
  }
  action init = all {
    s' = INIT, prev' = INIT, lastCmd' = "init", lastActor' = "", lastReply' = NoReply,
    lastEvents' = Set(), lastRequests' = Set(), lastWhy' = "",
  }
  pure def matchChoices(s: State): Set[(QueueId, Set[Ticket])] =
    tuples(QUEUES.keys(), s.searching.powerset()).filter(p => matchable(s, p._1, p._2))
      .union(Set(("", Set())))

  action step = {
    nondet u = USERS.oneOf()
    nondet v = USERS.oneOf()
    nondet q = QUEUES.keys().oneOf()
    nondet qs = QUEUES.keys().powerset().exclude(Set(Set())).oneOf()
    nondet sq = qs.oneOf()
    // k picks a malformed request now and then: 0 = unknown queue id, 1 = stale version.
    nondet k = 0.to(5).oneOf()
    nondet mc = matchChoices(s).oneOf()
    val req = if (k == 0) qs.union(Set(sq, "ffa")).map(x => (x, verOf(s, x)))
              else qs.map(x => (x, if (k == 1 and x == sq) verOf(s, x) + 1 else verOf(s, x)))
    // Branch weights for exploration only: the core steps are listed more than once
    // (any {} picks a branch uniformly), so matches form and live long enough.
    any {
      apply("matchmaking/list", u, list(s, u)),
      apply("matchmaking/queue", u, queue(s, u, req)),
      apply("matchmaking/queue", u, queue(s, u, req)),
      apply("matchmaking/queue", u, queue(s, u, req)),
      apply("matchmaking/queue", u, queue(s, u, req)),
      apply("matchmaking/cancel", u, cancel(s, u)),
      apply("matchmaking/ready", u, ready(s, u)),
      apply("matchmaking/ready", u, ready(s, u)),
      apply("matchmaking/ready", u, ready(s, u)),
      apply("env/match", "", matchFound(s, mc._1, mc._2)),
      apply("env/match", "", matchFound(s, mc._1, mc._2)),
      apply("env/match", "", matchFound(s, mc._1, mc._2)),
      apply("env/battleStarted", u, battleStarted(s, u)),
      apply("env/readyTimeout", u, readyTimeout(s, u)),
      apply("env/battleStarted", u, battleStarted(s, u)),
      apply("env/startFailed", u, startFailed(s, u)),
      apply("env/startGaveUp", u, startGaveUp(s, u)),
      apply("env/queueUpdate", "", queueUpdate(s, q)),
      apply("env/versionChanged", "", versionChanged(s, q)),
      apply("env/assetsDownloaded", u, assetsDownloaded(s, u, q)),
      apply("env/partyJoin", u, partyJoin(s, u, v)),
      apply("env/partyLeave", u, partyLeave(s, u)),
      apply("env/sessionExpired", u, sessionExpired(s, u)),
      apply("env/lobbyEnter", u, lobbyEnter(s, u)),
      apply("env/lobbyExit", u, lobbyExit(s, u)),
      apply("env/battleEnded", u, battleEnded(s, u)),
    }
  }

  // ---- properties ----
  pure def recipients(evs: Set[(UserId, Event)], p: Event => bool): Set[UserId] =
    evs.filter(e => p(e._2)).map(e => e._1)
  pure def isFound(e: Event): bool = match e { | Found(_) => true | _ => false }
  pure def isFoundUpdate(e: Event): bool = match e { | FoundUpdate(_) => true | _ => false }
  pure def isLost(e: Event): bool = match e { | Lost => true | _ => false }
  pure def isCancelled(e: Event): bool = match e { | Cancelled(_) => true | _ => false }
  pure def isQueuesJoined(e: Event): bool = match e { | QueuesJoined(_) => true | _ => false }

  // A user is in at most one ticket (searching or in a match).
  val atMostOneTicket = USERS.forall(u => and {
    s.searching.filter(t => t.members.contains(u)).size() <= 1,
    s.matches.filter(m => matchMembers(m).contains(u)).size() <= 1,
    s.matches.forall(m => m.tickets.filter(t => t.members.contains(u)).size() <= 1),
  })
  // A found match's members are all out of the queue.
  val matchedOutOfQueue = matchedUsers(s).intersect(searchingUsers(s)) == Set()
  // Every ticket is a whole party or a party-less user (I3).
  val ticketsArePartyUnits =
    s.searching.union(s.matches.map(m => m.tickets).flatten())
      .forall(t => t.members.forall(x => groupOf(s, x) == t.members))
  val matchWellFormed = s.matches.forall(m => and {
    sizeSum(m.tickets) == slots(m.queue),
    teamsFormable(m.queue, m.tickets),
    m.tickets.forall(t => qids(t).contains(m.queue)),
    m.ready.subseteq(matchMembers(m)),
    (m.phase == Starting) == (m.ready == matchMembers(m)),
  })
  val searchingWellFormed = s.searching.forall(t => and {
    t.members != Set(), t.queues != Set(), current(s, t),
    qids(t).forall(q => t.members.size() <= QUEUES.get(q).teamSize),
  })
  // Activity slot: matchmaking excludes lobby and battle.
  val activityExclusive = USERS.forall(u =>
    inMM(s, u) implies not(s.inLobby.contains(u) or s.inBattle.contains(u)))
  val partiesWellFormed = s.parties.forall(p => p.size() >= 2 and p.size() <= MAX_PARTY) and
    USERS.forall(u => partyOf(s, u).size() <= 1)

  // found reaches exactly the members of the new match, with its queue id.
  val foundExact = and {
    recipients(lastEvents, isFound) == matchedUsers(s).exclude(matchedUsers(prev)),
    lastEvents.forall(e => match e._2 { | Found(q) => matchOf(s, e._1).queue == q | _ => true }),
  }
  // foundUpdate reaches exactly one match's members and carries its ready count.
  val foundUpdateExact = recipients(lastEvents, isFoundUpdate) == Set() or
    s.matches.exists(m => and {
      recipients(lastEvents, isFoundUpdate) == matchMembers(m),
      lastEvents.forall(e => match e._2 { | FoundUpdate(n) => n == m.ready.size() | _ => true }),
    })
  // lost reaches only members of a match that was disbanded in this step,
  // and every member of a disbanded match (not started) hears lost or cancelled,
  // except a user whose session ended.
  val disbanded = matchedUsers(prev).exclude(matchedUsers(s)).exclude(s.inBattle)
  val lostOnlyToDisbanded = recipients(lastEvents, isLost).subseteq(disbanded)
  val disbandNotifiesAll = disbanded.forall(u =>
    recipients(lastEvents, e => isLost(e) or isCancelled(e)).contains(u) or
    (lastCmd == "env/sessionExpired" and u == lastActor))
  // cancelled: the user was in matchmaking and is now out of it.
  val cancelledMeansOut = recipients(lastEvents, isCancelled).forall(u => inMM(prev, u) and not(inMM(s, u)))
  val cancelledReasonsInSchema = lastEvents.forall(e => match e._2 {
    | Cancelled(r) => CANCELLED_REASONS.contains(r) | _ => true })
  // "After a successful cancel response, the server will also send a cancelled event."
  val cancelSendsCancelled = (lastCmd == "matchmaking/cancel" and lastReply == Ok) implies
    lastEvents.contains((lastActor, Cancelled("intentional")))
  // queuesJoined: to the other members of the caller's new ticket, never the caller.
  val queuesJoinedToMates = recipients(lastEvents, isQueuesJoined).forall(x => and {
    x != lastActor, lastCmd == "matchmaking/queue",
    s.searching.exists(t => t.members.contains(x) and t.members.contains(lastActor)) })
  // ready succeeds only during a found match.
  val readyOnlyWhenFound = (lastCmd == "matchmaking/ready" and lastReply == Ok) implies
    matchedUsers(prev).contains(lastActor)
  val denialsChangeNothing = match lastReply {
    | Failed(_) => s == prev and lastEvents == Set() | _ => true }
  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  val safety = and {
    atMostOneTicket, matchedOutOfQueue, ticketsArePartyUnits, matchWellFormed,
    searchingWellFormed, activityExclusive, partiesWellFormed,
    foundExact, foundUpdateExact, lostOnlyToDisbanded, disbandNotifiesAll,
    cancelledMeansOut, cancelledReasonsInSchema, cancelSendsCancelled,
    queuesJoinedToMates, readyOnlyWhenFound, denialsChangeNothing, reasonsInSchema,
  }

  // ---- reachability witnesses (checking not(w) must fail) ----
  def hit(cmd: str, why: str): bool = lastCmd == cmd and lastWhy == why
  def cancelledWith(r: str): bool = lastEvents.exists(e => e._2 == Cancelled(r))
  val found2v2WithParty = lastCmd == "env/match" and s.matches.exists(m =>
    m.queue == "2v2" and m.tickets.exists(t => t.members.size() == 2))
  val requeuedAfterLost = recipients(lastEvents, isLost).exists(x => searchingUsers(s).contains(x))
  val staleRequeueCancelled = lastEvents.exists(e => e._2 == Lost) and cancelledWith("version_changed")
}

module matchmaking_test {
  import common.* from "./common"
  import matchmaking(
    USERS = Set("a", "b", "c", "d"),
    QUEUES = Map("1v1" -> { teamSize: 1, numTeams: 2 }, "2v2" -> { teamSize: 2, numTeams: 2 }),
    MAX_VERSION = 1,
    MAX_PARTY = 2
  ).*

  pure val Q1: QRef = ("1v1", 0)
  pure val Q2: QRef = ("2v2", 0)

  // Solo duel: queue, found, ready, battle; queueing in a battle is refused.
  run duelTest =
    init
      .then(apply("matchmaking/list", "a", list(s, "a")))
      .expect(lastReply == Ok and listData(s).get("1v1") == ({ teamSize: 1, numTeams: 2 }, 0))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .expect(lastReply == Ok and lastEvents == Set() and lastRequests == Set())
      .then(apply("matchmaking/queue", "b", queue(s, "b", Set(Q1, Q2))))
      .then(apply("env/match", "", matchFound(s, "1v1", s.searching)))
      .expect(lastEvents == Set(("a", Found("1v1")), ("b", Found("1v1"))) and s.searching == Set())
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q2))))
      .expect(lastReply == Failed("already_queued"))
      .then(apply("matchmaking/ready", "a", ready(s, "a")))
      .expect(lastEvents == Set(("a", FoundUpdate(1)), ("b", FoundUpdate(1))))
      .then(apply("matchmaking/ready", "a", ready(s, "a")))
      .expect(lastReply == Ok and lastEvents == Set())
      .then(apply("matchmaking/ready", "b", ready(s, "b")))
      .expect(lastEvents == Set(("a", FoundUpdate(2)), ("b", FoundUpdate(2))) and lastWhy == "all_ready")
      .then(apply("env/startFailed", "a", startFailed(s, "a")))
      .expect(s == prev)
      .then(apply("env/battleStarted", "a", battleStarted(s, "a")))
      .expect(s.inBattle == Set("a", "b") and s.matches == Set() and
              lastRequests == Set(("a", BattleStart), ("b", BattleStart)))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .expect(lastReply == Failed("already_in_battle"))
      .then(apply("env/battleEnded", "a", battleEnded(s, "a")))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .expect(lastReply == Ok)

  // A second queue request replaces the searching ticket; cancel; denials.
  run replaceAndDenialsTest =
    init
      .then(apply("matchmaking/cancel", "a", cancel(s, "a")))
      .expect(lastReply == Failed("not_queued"))
      .then(apply("matchmaking/ready", "a", ready(s, "a")))
      .expect(lastReply == Failed("no_match"))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(("ffa", 0)))))
      .expect(lastReply == Failed("invalid_queue_specified"))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(("1v1", 1)))))
      .expect(lastReply == Failed("version_mismatch"))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q2))))
      .expect(lastReply == Ok and lastWhy == "replaced" and lastEvents == Set() and
              s.searching == Set({ members: Set("a"), queues: Set(Q2) }))
      .then(apply("matchmaking/cancel", "a", cancel(s, "a")))
      .expect(lastEvents == Set(("a", Cancelled("intentional"))) and s.searching == Set())
      .then(apply("env/lobbyEnter", "a", lobbyEnter(s, "a")))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "in_lobby")

  // Party queue: checkAssets to the other member, queuesJoined to it only;
  // a 2v2 match with a party; the party member declines.
  run partyDeclineTest =
    init
      .then(apply("env/partyJoin", "b", partyJoin(s, "b", "a")))
      .expect(s.parties == Set(Set("a", "b")))
      .then(apply("matchmaking/queue", "b", queue(s, "b", Set(Q1))))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "party_too_big")
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q2))))
      .expect(lastReply == Ok and lastEvents == Set(("b", QueuesJoined(Set("2v2")))) and
              lastRequests == Set(("b", CheckAssets("2v2"))))
      .then(apply("env/partyJoin", "c", partyJoin(s, "c", "a")))
      .expect(s == prev)   // party in matchmaking is locked (I3)
      .then(apply("matchmaking/queue", "c", queue(s, "c", Set(Q2, Q1))))
      .then(apply("matchmaking/queue", "d", queue(s, "d", Set(Q2))))
      .then(apply("env/match", "", matchFound(s, "2v2", s.searching)))
      .expect(recipients(lastEvents, isFound) == Set("a", "b", "c", "d"))
      .then(apply("matchmaking/ready", "c", ready(s, "c")))
      .then(apply("matchmaking/cancel", "b", cancel(s, "b")))
      .expect(lastEvents == Set(("b", Cancelled("intentional")), ("a", Cancelled("party_user_left")),
                                ("c", Lost), ("d", Lost)) and
              s.searching == Set({ members: Set("c"), queues: Set(Q2, Q1) },
                                 { members: Set("d"), queues: Set(Q2) }) and s.matches == Set())

  // Ready timeout: the readied player is requeued in all its queues, the other
  // gets lost and cancelled(ready_timeout).
  run readyTimeoutTest =
    init
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1, Q2))))
      .then(apply("matchmaking/queue", "b", queue(s, "b", Set(Q1))))
      .then(apply("env/match", "", matchFound(s, "1v1", s.searching)))
      .then(apply("matchmaking/ready", "a", ready(s, "a")))
      .then(apply("env/readyTimeout", "a", readyTimeout(s, "a")))
      .expect(lastEvents == Set(("a", Lost), ("b", Lost), ("b", Cancelled("ready_timeout"))) and
              s.searching == Set({ members: Set("a"), queues: Set(Q1, Q2) }))
      .then(apply("env/readyTimeout", "a", readyTimeout(s, "a")))
      .expect(s == prev and lastEvents == Set())   // late fire

  // Asset list change: searching tickets cancelled with version_changed; a party
  // member lacking the new assets makes the party queue fail.
  run versionTest =
    init
      .then(apply("matchmaking/queue", "c", queue(s, "c", Set(Q2))))
      .then(apply("env/partyJoin", "b", partyJoin(s, "b", "a")))
      .then(apply("env/versionChanged", "", versionChanged(s, "2v2")))
      .expect(lastEvents == Set(("c", Cancelled("version_changed"))) and s.version.get("2v2") == 1)
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q2))))
      .expect(lastReply == Failed("version_mismatch"))
      .then(apply("env/assetsDownloaded", "a", assetsDownloaded(s, "a", "2v2")))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(("2v2", 1)))))
      .expect(lastReply == Failed("party_missing_asset") and lastEvents == Set() and
              lastRequests == Set(("b", CheckAssets("2v2"))) and s == prev)
      .then(apply("env/assetsDownloaded", "b", assetsDownloaded(s, "b", "2v2")))
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(("2v2", 1)))))
      .expect(lastReply == Ok)

  // A member leaving a queued party cancels the party's ticket for everyone.
  run partyLeaveTest =
    init
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .then(apply("env/partyJoin", "b", partyJoin(s, "b", "a")))
      .expect(lastEvents == Set(("a", Cancelled("intentional"))) and s.searching == Set())
      .then(apply("matchmaking/queue", "b", queue(s, "b", Set(Q2))))
      .expect(lastEvents == Set(("a", QueuesJoined(Set("2v2")))))
      .then(apply("env/partyLeave", "b", partyLeave(s, "b")))
      .expect(lastEvents == Set(("a", Cancelled("party_user_left")), ("b", Cancelled("party_user_left"))) and
              s.searching == Set() and s.parties == Set())

  // All ready but no autohost can start it: lost + cancelled(server_error).
  run startGaveUpTest =
    init
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .then(apply("matchmaking/queue", "b", queue(s, "b", Set(Q1))))
      .then(apply("env/queueUpdate", "", queueUpdate(s, "1v1")))
      .expect(lastEvents == Set(("a", QueueUpdate(2)), ("b", QueueUpdate(2))))
      .then(apply("env/match", "", matchFound(s, "1v1", s.searching)))
      .then(apply("matchmaking/ready", "a", ready(s, "a")))
      .then(apply("matchmaking/ready", "b", ready(s, "b")))
      .then(apply("env/startGaveUp", "b", startGaveUp(s, "b")))
      .expect(lastEvents == Set(("a", Lost), ("b", Lost), ("a", Cancelled("server_error")),
                                ("b", Cancelled("server_error"))) and s.matches == Set())

  // Session end during a ready check: the others resume queueing; no event to the leaver.
  run sessionExpiredTest =
    init
      .then(apply("matchmaking/queue", "a", queue(s, "a", Set(Q1))))
      .then(apply("matchmaking/queue", "b", queue(s, "b", Set(Q1))))
      .then(apply("env/match", "", matchFound(s, "1v1", s.searching)))
      .then(apply("env/sessionExpired", "b", sessionExpired(s, "b")))
      .expect(lastEvents == Set(("a", Lost)) and s.searching == Set({ members: Set("a"), queues: Set(Q1) }))
}
