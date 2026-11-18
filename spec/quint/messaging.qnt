// Messaging: messaging/send, messaging/subscribeReceived, the messaging/received
// event, and the session lifecycle steps that decide whether a recipient gets a
// message live, later from the buffer, or never.
// Source: tachyon docs/schema/messaging.md, schema/messaging/*, src/schema/messaging/*.ts
// Findings: findings/messaging.md (MSG-nn ids below).
//
// @test main=messaging_test
// @inv main=messaging_test inv=safety steps=30 samples=20000
// @witness main=messaging_test inv=not(sentOk("player"))
// @witness main=messaging_test inv=not(sentOk("party"))
// @witness main=messaging_test inv=not(sentOk("lobby"))
// @witness main=messaging_test inv=not(sentDenied("player","invalid_target"))
// @witness main=messaging_test inv=not(sentDenied("party","invalid_target"))
// @witness main=messaging_test inv=not(sentDenied("lobby","invalid_target"))
// @witness main=messaging_test inv=not(sentDenied("player","message_too_long"))
// @witness main=messaging_test inv=not(liveDelivery)
// @witness main=messaging_test inv=not(subscribedWith("latest"))
// @witness main=messaging_test inv=not(subscribedWith("from_start")and(lastReplay.length()>1))
// @witness main=messaging_test inv=not(subscribedWith("marker")and(lastReplay.length()>0)and(not(lastMissed)))
// @witness main=messaging_test inv=not(subscribedWith("marker")and(lastMissed))
// @witness main=messaging_test inv=not(honestResumeAfterReconnect)
// @witness main=messaging_test inv=not(bufferOverflowed)
// @witness main=messaging_test inv=not(lastCmd=="env/sessionExpired")
// @witness main=messaging_test inv=not(lastCmd=="env/reconnect")
// @verify main=messaging_test inv=safety steps=3
module messaging {
  import common.* from "./common"

  // ---- vocabulary ----
  type LobbyId = int   // 0 = not in a lobby
  type PartyId = int   // 0 = not in a party
  type MsgId = int     // also the history marker (opaque to clients)

  // Request data.target: { type: "player", userId } | { type: "party" } | { type: "lobby" }
  type Target = ToPlayer(UserId) | ToParty | ToLobby
  // Event data.source: player{userId} | party{partyId, userId} | lobby{lobbyId, userId};
  // userId is the sender in all three (MSG-05).
  type Source = SrcPlayer | SrcParty(PartyId) | SrcLobby(LobbyId)
  // subscribeReceived data.since, "default": { "type": "latest" }
  type Since = Latest | FromStart | Marker(MsgId)

  // Message bodies are abstracted to small ints; only their length matters.
  type Msg = { id: MsgId, src: Source, from: UserId, body: int }
  type Event = Received(Msg)

  // A session outlives its socket for a grace period (design default).
  // dropped: the buffer has overflowed at least once (ghost, for witnesses).
  type Session = { connected: bool, subscribed: bool, buffer: List[MsgId], dropped: bool }

  type State = {
    sessions: UserId -> Session,      // key present = user is online (MSG-03)
    lobbyOf: UserId -> LobbyId,       // environment-owned (lobby module)
    partyOf: UserId -> PartyId,       // environment-owned (party module)
    msgs: MsgId -> Msg,               // every accepted message (for replay content)
    nextId: MsgId,
    // ghost: (recipient, message) pairs the server accepted at send time
    addressed: Set[(UserId, MsgId)],
  }

  // Commands also return the ordered history sent "straight after the
  // response" and the hasMissedMessages reply field; Reply carries no data.
  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)],
                   replay: List[MsgId], missed: bool }

  const USERS: Set[UserId]
  const LOBBIES: Set[LobbyId]
  const PARTIES: Set[PartyId]
  const BODIES: Set[int]
  // Abstract length predicate: request schema "message": { maxLength: 512 }.
  const MAX_BODY: int
  // ASSUMPTION MSG-A4: the per-session buffer is bounded (teiserver: 200).
  const BUF_CAP: int

  pure def tooLong(body: int): bool = body > MAX_BODY

  pure def online(s: State, u: UserId): bool = s.sessions.keys().contains(u)
  pure def sess(s: State, u: UserId): Session = s.sessions.get(u)
  pure def live(s: State, u: UserId): bool =
    online(s, u) and sess(s, u).connected and sess(s, u).subscribed

  pure def none(s: State): Outcome =
    { state: s, reply: NoReply, events: Set(), replay: [], missed: false }
  pure def deny(s: State, reason: str): Outcome =
    { state: s, reply: Failed(reason), events: Set(), replay: [], missed: false }

  // ASSUMPTION MSG-A4: a full buffer drops its oldest message.
  pure def bufPut(b: List[MsgId], id: MsgId): List[MsgId] =
    if (b.length() >= BUF_CAP) b.slice(1, b.length()).append(id) else b.append(id)

  // ---- messaging/send ----

  // Recipients by target kind. "A message can only be sent to online players."
  // ASSUMPTION MSG-A1: party/lobby messages go to the other members (no echo to
  // the sender); a DM goes to the named user, which may be the sender itself.
  pure def recipients(s: State, u: UserId, t: Target): Set[UserId] = match t {
    | ToPlayer(v) => Set(v)
    | ToParty => USERS.filter(v => v != u and s.partyOf.get(v) == s.partyOf.get(u) and online(s, v))
    | ToLobby => USERS.filter(v => v != u and s.lobbyOf.get(v) == s.lobbyOf.get(u) and online(s, v))
  }

  pure def sourceOf(s: State, u: UserId, t: Target): Source = match t {
    | ToPlayer(_) => SrcPlayer
    | ToParty => SrcParty(s.partyOf.get(u))
    | ToLobby => SrcLobby(s.lobbyOf.get(u))
  }

  // "When the sender gets a successful response that means the message has been
  // acked by the server and it'll do its best to send it to the recipient(s)."
  // "A message can only be sent to online players. There is no support to store
  // messages to be then delivered later."
  // ASSUMPTION MSG-A2: message_too_long is checked before the target.
  // ASSUMPTION MSG-A3: party/lobby target while not in one -> invalid_target.
  // ASSUMPTION MSG-A5: every accepted message is buffered in each recipient's
  // session, subscribed or not ("latest ... will not send any potentially stored
  // messages"); it is sent as an event only to a connected, subscribed client.
  pure def sendMessage(s: State, u: UserId, t: Target, body: int): Outcome =
    if (tooLong(body)) deny(s, "message_too_long")
    else {
      val targetOk = match t {
        | ToPlayer(v) => online(s, v)
        | ToParty => s.partyOf.get(u) != 0
        | ToLobby => s.lobbyOf.get(u) != 0
      }
      if (not(targetOk)) deny(s, "invalid_target")
      else {
        val m = { id: s.nextId, src: sourceOf(s, u, t), from: u, body: body }
        val rs = recipients(s, u, t)
        val sessions2 = s.sessions.keys().mapBy(v =>
          if (rs.contains(v)) { ...sess(s, v), buffer: bufPut(sess(s, v).buffer, m.id),
                                dropped: sess(s, v).dropped or sess(s, v).buffer.length() >= BUF_CAP }
          else sess(s, v))
        { state: { ...s, sessions: sessions2, msgs: s.msgs.put(m.id, m), nextId: s.nextId + 1,
                   addressed: s.addressed.union(rs.map(v => (v, m.id))) },
          reply: Ok,
          events: send(rs.filter(v => live(s, v)), Received(m)),
          replay: [], missed: false }
      }
    }

  // ---- messaging/subscribeReceived ----

  // "The argument `since` is there as an option to ask the server some historical
  // events. There will be sent as regular `messaging/received` event straight
  // after the response. If `since` is not provided, the default is `latest`.
  // * `from_start` means the server will send its entire buffer.
  // * `latest` means the server will not send any potentially stored messages,
  //   only messages delivered after the subscription will be sent.
  // * `marker` ... will deliver all stored messages that have been sent *after*
  //   the message designated by the marker."
  // hasMissedMessages: "set to true when the marker sent doesn't match any
  // message stored by the server."
  // ASSUMPTION MSG-A6: an unknown marker replays the whole buffer (teiserver).
  // ASSUMPTION MSG-A7: from_start/latest report hasMissedMessages=false (literal).
  // ASSUMPTION MSG-A8: re-subscribing is allowed and replays again.
  // The subscription covers all sources (MSG-02).
  pure def history(b: List[MsgId], since: Since): (List[MsgId], bool) = match since {
    | Latest => ([], false)
    | FromStart => (b, false)
    | Marker(m) => {
        val at = b.indices().filter(i => b[i] == m)
        if (at == Set()) (b, true)
        else (b.slice(theOne(at, 0) + 1, b.length()), false)
      }
  }

  pure def subscribeReceived(s: State, u: UserId, since: Since): Outcome = {
    val h = history(sess(s, u).buffer, since)
    { state: { ...s, sessions: s.sessions.set(u, { ...sess(s, u), subscribed: true }) },
      reply: Ok,
      events: h._1.foldl(Set(), (acc, id) => acc.union(Set((u, Received(s.msgs.get(id)))))),
      replay: h._1, missed: h._2 }
  }

  // ---- environment ----

  // Login with no live session: a fresh session with an empty buffer.
  pure def connect(s: State, u: UserId): Outcome =
    if (online(s, u)) none(s)
    else { ...none(s), state: { ...s, sessions: s.sessions.put(u,
             { connected: true, subscribed: false, buffer: [], dropped: false }) } }

  // Socket drop. ASSUMPTION MSG-A9: the subscription is bound to the connection.
  pure def disconnect(s: State, u: UserId): Outcome =
    if (not(online(s, u)) or not(sess(s, u).connected)) none(s)
    else { ...none(s), state: { ...s, sessions: s.sessions.set(u,
             { ...sess(s, u), connected: false, subscribed: false }) } }

  // A new connection attaches to the live session (after a drop, or replacing
  // the current socket: "a new connection replaces the old one"). The buffer
  // survives; the subscription does not (MSG-A9; teiserver diverges, MSG-07).
  pure def reconnect(s: State, u: UserId): Outcome =
    if (not(online(s, u))) none(s)
    else { ...none(s), state: { ...s, sessions: s.sessions.set(u,
             { ...sess(s, u), connected: true, subscribed: false }) } }

  // Grace period ends while detached: the session and its buffer are gone, and
  // the lobby/party modules drop the user (cross-module).
  pure def sessionExpired(s: State, u: UserId): Outcome =
    if (not(online(s, u)) or sess(s, u).connected) none(s)
    else { ...none(s), state: { ...s, sessions: mapRemove(s.sessions, u),
             lobbyOf: s.lobbyOf.set(u, 0), partyOf: s.partyOf.set(u, 0) } }

  // Lobby/party membership is owned by other modules: any online user may be
  // moved into or out of any lobby/party at any time.
  pure def setMembership(s: State, u: UserId, l: LobbyId, p: PartyId): Outcome =
    if (not(online(s, u))) none(s)
    else { ...none(s), state: { ...s, lobbyOf: s.lobbyOf.set(u, l), partyOf: s.partyOf.set(u, p) } }

  // ---- state machine ----
  // Client ghost (what a bar-lobby-like client holds): last marker it saw, the
  // ids delivered since its last subscribe, and every id it ever saw.
  type Client = { lastMarker: MsgId, log: List[MsgId], seen: Set[MsgId] }

  var s: State
  var lastCmd: str
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]
  var lastReplay: List[MsgId]
  var lastMissed: bool
  var lastCaller: UserId
  var lastTarget: Target
  var lastSince: Since
  var clients: UserId -> Client
  var lastHonest: bool   // subscribe used the client's own last marker
  var lastDup: bool      // the replay re-sent something the client had seen

  pure def evId(e: Event): MsgId = match e { | Received(m) => m.id }

  action apply(cmd: str, u: UserId, o: Outcome): bool = all {
    s' = o.state, lastCmd' = cmd, lastReply' = o.reply, lastEvents' = o.events,
    lastReplay' = o.replay, lastMissed' = o.missed, lastCaller' = u,
    lastDup' = o.replay.foldl(false, (acc, id) => acc or clients.get(u).seen.contains(id)),
    clients' = USERS.mapBy(v => {
      val c = clients.get(v)
      if (cmd == "messaging/subscribeReceived" and v == u and o.reply == Ok)
        { lastMarker: if (o.replay.length() > 0) o.replay[o.replay.length() - 1] else c.lastMarker,
          log: o.replay,
          seen: o.replay.foldl(c.seen, (acc, id) => acc.union(Set(id))) }
      else {
        val ids = o.events.filter(e => e._1 == v).map(e => evId(e._2))
        if (ids == Set()) c
        else { lastMarker: theOne(ids, -1), log: c.log.append(theOne(ids, -1)),
               seen: c.seen.union(ids) }
      }
    }),
  }

  action doSend(u: UserId, t: Target, body: int): bool = all {
    apply("messaging/send", u, sendMessage(s, u, t, body)),
    lastTarget' = t, lastSince' = lastSince, lastHonest' = false,
  }
  action doSubscribe(u: UserId, since: Since): bool = all {
    apply("messaging/subscribeReceived", u, subscribeReceived(s, u, since)),
    lastTarget' = lastTarget, lastSince' = since,
    lastHonest' = (clients.get(u).lastMarker >= 0 and since == Marker(clients.get(u).lastMarker)),
  }
  action doEnv(cmd: str, u: UserId, o: Outcome): bool = all {
    apply(cmd, u, o), lastTarget' = lastTarget, lastSince' = lastSince, lastHonest' = false,
  }

  action init = all {
    s' = { sessions: Map(), lobbyOf: USERS.mapBy(_ => 0), partyOf: USERS.mapBy(_ => 0),
           msgs: Map(), nextId: 0, addressed: Set() },
    lastCmd' = "init", lastReply' = NoReply, lastEvents' = Set(), lastReplay' = [],
    lastMissed' = false, lastCaller' = "", lastTarget' = ToLobby, lastSince' = Latest,
    clients' = USERS.mapBy(_ => { lastMarker: -1, log: [], seen: Set() }),
    lastHonest' = false, lastDup' = false,
  }

  action step = {
    nondet u = USERS.oneOf()
    nondet v = USERS.oneOf()
    nondet body = BODIES.oneOf()
    nondet l = LOBBIES.union(Set(0)).oneOf()
    nondet p = PARTIES.union(Set(0)).oneOf()
    nondet m = (-2).to(s.nextId).oneOf()   // -2: a marker that never existed
    nondet t = Set(ToPlayer(v), ToParty, ToLobby).oneOf()
    nondet since = Set(Latest, FromStart, Marker(m), Marker(clients.get(u).lastMarker)).oneOf()
    // Requests come only from a connected client.
    val canRequest = online(s, u) and sess(s, u).connected
    any {
      all { canRequest, doSend(u, t, body) },
      all { canRequest, doSubscribe(u, since) },
      // Environment steps are guarded to where they change something (the
      // functions are no-ops elsewhere), so simulation does not idle.
      all { not(online(s, u)), doEnv("env/connect", u, connect(s, u)) },
      all { canRequest, doEnv("env/disconnect", u, disconnect(s, u)) },
      all { online(s, u), doEnv("env/reconnect", u, reconnect(s, u)) },
      all { online(s, u), not(sess(s, u).connected), doEnv("env/sessionExpired", u, sessionExpired(s, u)) },
      all { online(s, u), doEnv("env/membership", u, setMembership(s, u, l, p)) },
    }
  }

  // ---- properties ----
  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  val bufferBounded = s.sessions.keys().forall(u => sess(s, u).buffer.length() <= BUF_CAP)

  // Buffers hold only messages addressed to their owner, in send order.
  val bufferSound = s.sessions.keys().forall(u => {
    val b = sess(s, u).buffer
    and { b.indices().forall(i => s.addressed.contains((u, b[i]))),
          b.indices().forall(i => i == 0 or b[i - 1] < b[i]) }
  })

  // A messaging/received event reaches only a recipient the message was
  // addressed to at send time (live or replayed later).
  val eventsOnlyToAddressed = lastEvents.forall(e => s.addressed.contains((e._1, evId(e._2))))

  // At send time the recipients are exactly the target's other online members
  // (DM: the named online user); events go to exactly the live ones among them.
  val sendRecipientsExact =
    (lastCmd == "messaging/send" and lastReply == Ok) implies {
      val m = s.msgs.get(s.nextId - 1)
      val rs = s.addressed.filter(x => x._2 == m.id).map(x => x._1)
      val expected = match m.src {
        | SrcPlayer => match lastTarget { | ToPlayer(v) => Set(v) | ToParty => Set() | ToLobby => Set() }
        | SrcParty(p) => USERS.filter(v => v != m.from and p != 0 and s.partyOf.get(v) == p and online(s, v))
        | SrcLobby(l) => USERS.filter(v => v != m.from and l != 0 and s.lobbyOf.get(v) == l and online(s, v))
      }
      and { rs == expected,
            lastEvents.map(e => e._1) == rs.filter(v => live(s, v)) }
    }

  // No echo: a party/lobby sender never gets its own message as an event.
  val noEchoToSender = lastEvents.forall(e => match e._2 {
    | Received(m) => match m.src { | SrcPlayer => true | SrcParty(_) => e._1 != m.from | SrcLobby(_) => e._1 != m.from }
  })

  // Replayed history goes only to the subscriber.
  val replayOnlyToCaller =
    (lastCmd == "messaging/subscribeReceived") implies lastEvents.forall(e => e._1 == lastCaller)

  // Per-recipient order equals send order (within one subscription).
  val deliveryOrdered = USERS.forall(u => {
    val lg = clients.get(u).log
    lg.indices().forall(i => i == 0 or lg[i - 1] < lg[i])
  })

  // Resuming with the marker of the last message received never re-delivers.
  val noDuplicateAfterMarker =
    (lastCmd == "messaging/subscribeReceived" and lastHonest) implies not(lastDup)
  // Live delivery and latest never re-deliver either.
  val noDuplicateLive =
    (lastCmd == "messaging/send" or lastSince == Latest) implies not(lastDup)

  // Nothing is delivered to a client that is not connected and subscribed
  // (before subscribing, messages are only buffered).
  val nothingBeforeSubscribe = lastEvents.forall(e => live(s, e._1))

  val denialsInert = (lastReply != Ok and lastReply != NoReply) implies lastEvents == Set()

  val safety = and {
    reasonsInSchema, bufferBounded, bufferSound, eventsOnlyToAddressed,
    sendRecipientsExact, noEchoToSender, replayOnlyToCaller, deliveryOrdered,
    noDuplicateAfterMarker, noDuplicateLive, nothingBeforeSubscribe, denialsInert,
  }

  // ---- witnesses (checking not(X) must fail) ----
  pure def kind(t: Target): str = match t { | ToPlayer(_) => "player" | ToParty => "party" | ToLobby => "lobby" }
  pure def sinceKind(x: Since): str = match x { | Latest => "latest" | FromStart => "from_start" | Marker(_) => "marker" }
  def sentOk(k: str): bool = lastCmd == "messaging/send" and lastReply == Ok and kind(lastTarget) == k
  def sentDenied(k: str, r: str): bool =
    lastCmd == "messaging/send" and lastReply == Failed(r) and kind(lastTarget) == k
  def subscribedWith(k: str): bool =
    lastCmd == "messaging/subscribeReceived" and lastReply == Ok and sinceKind(lastSince) == k
  val liveDelivery = lastCmd == "messaging/send" and lastEvents != Set()
  // A client resumed with its own marker and got the messages it missed.
  val honestResumeAfterReconnect = subscribedWith("marker") and lastHonest and lastReplay.length() > 0
  val bufferOverflowed = s.sessions.keys().exists(u => sess(s, u).dropped)
}

module messaging_test {
  import common.* from "./common"
  import messaging(USERS = Set("a", "b", "c"), LOBBIES = Set(1, 2), PARTIES = Set(1, 2),
                   BODIES = Set(0, 1, 2), MAX_BODY = 1, BUF_CAP = 2).*

  run online3 = init.then(doEnv("env/connect", "a", connect(s, "a")))
    .then(doEnv("env/connect", "b", connect(s, "b")))
    .then(doEnv("env/connect", "c", connect(s, "c")))

  // DM: before subscribing, b only buffers; after subscribing, b gets it live.
  // The sender gets no echo. An offline target is invalid; so is a long body.
  run dmTest =
    init
      .then(doEnv("env/connect", "a", connect(s, "a")))
      .then(doSend("a", ToPlayer("b"), 0))
      .expect(lastReply == Failed("invalid_target"))          // b offline
      .then(doEnv("env/connect", "b", connect(s, "b")))
      .then(doSend("a", ToPlayer("b"), 2))
      .expect(lastReply == Failed("message_too_long"))
      .then(doSend("a", ToPlayer("b"), 0))
      .expect(lastReply == Ok and lastEvents == Set())         // not subscribed yet
      .then(doSubscribe("b", Latest))
      .expect(lastReply == Ok and lastReplay == [] and not(lastMissed))
      .then(doSend("a", ToPlayer("b"), 1))
      .expect(lastEvents == Set(("b", Received({ id: 1, src: SrcPlayer, from: "a", body: 1 }))))
      .then(doSubscribe("b", FromStart))                      // whole buffer, in order
      .expect(lastReplay == [0, 1] and not(lastMissed))

  // Party and lobby: other members only, no echo; not a member -> invalid_target.
  run groupTest =
    online3
      .then(doSend("a", ToParty, 0))
      .expect(lastReply == Failed("invalid_target"))
      .then(doSend("a", ToLobby, 0))
      .expect(lastReply == Failed("invalid_target"))
      .then(doEnv("env/membership", "a", setMembership(s, "a", 1, 1)))
      .then(doEnv("env/membership", "b", setMembership(s, "b", 1, 2)))
      .then(doEnv("env/membership", "c", setMembership(s, "c", 2, 1)))
      .then(doSubscribe("a", Latest)).then(doSubscribe("b", Latest)).then(doSubscribe("c", Latest))
      .then(doSend("a", ToLobby, 0))
      .expect(lastReply == Ok and lastEvents == Set(("b", Received({ id: 0, src: SrcLobby(1), from: "a", body: 0 }))))
      .then(doSend("a", ToParty, 1))
      .expect(lastEvents == Set(("c", Received({ id: 1, src: SrcParty(1), from: "a", body: 1 }))))
      .then(doSend("b", ToParty, 0))                          // b alone in party 2
      .expect(lastReply == Ok and lastEvents == Set())

  // Reconnect after a crash: messages sent while detached are buffered; the
  // new socket must re-subscribe; the client's own marker yields exactly the gap.
  run resumeTest =
    online3
      .then(doSubscribe("b", Latest))
      .then(doSend("a", ToPlayer("b"), 0))
      .expect(clients.get("b").lastMarker == 0)
      .then(doEnv("env/disconnect", "b", disconnect(s, "b")))
      .then(doSend("a", ToPlayer("b"), 1))
      .expect(lastReply == Ok and lastEvents == Set())          // detached session is online
      .then(doEnv("env/reconnect", "b", reconnect(s, "b")))
      .then(doSend("c", ToPlayer("b"), 0))
      .expect(lastEvents == Set())                            // new socket not subscribed
      .then(doSubscribe("b", Marker(1)))
      .expect(lastReplay == [2] and not(lastMissed))
      .then(doEnv("env/reconnect", "b", reconnect(s, "b")))   // socket replaced again
      .then(doSubscribe("b", Marker(clients.get("b").lastMarker)))
      .expect(lastReplay == [] and not(lastMissed) and lastHonest and not(lastDup))
      .then(doEnv("env/disconnect", "b", disconnect(s, "b")))
      .then(doSend("a", ToPlayer("b"), 0))
      .then(doSend("a", ToPlayer("b"), 0))                     // cap 2: b's marker 2 dropped
      .then(doEnv("env/reconnect", "b", reconnect(s, "b")))
      .then(doSubscribe("b", Marker(clients.get("b").lastMarker)))
      .expect(lastReplay == [3, 4] and lastMissed and lastHonest and not(lastDup))

  // Overflow and unknown markers: hasMissedMessages and a full replay.
  run missedTest =
    online3
      .then(doSend("a", ToPlayer("b"), 0))
      .then(doSend("a", ToPlayer("b"), 0))
      .then(doSend("a", ToPlayer("b"), 0))                     // buffer cap 2: id 0 dropped
      .expect(s.sessions.get("b").buffer == [1, 2])
      .then(doSubscribe("b", Marker(0)))
      .expect(lastReplay == [1, 2] and lastMissed)
      .then(doSubscribe("b", Marker(-2)))
      .expect(lastReplay == [1, 2] and lastMissed)
      .then(doSubscribe("b", Marker(1)))
      .expect(lastReplay == [2] and not(lastMissed))

  // Session expiry loses the buffer; a later DM is invalid until b logs in again.
  run expiryTest =
    online3
      .then(doEnv("env/membership", "b", setMembership(s, "b", 1, 1)))
      .then(doEnv("env/disconnect", "b", disconnect(s, "b")))
      .then(doEnv("env/sessionExpired", "b", sessionExpired(s, "b")))
      .expect(not(online(s, "b")) and s.lobbyOf.get("b") == 0)
      .then(doSend("a", ToPlayer("b"), 0))
      .expect(lastReply == Failed("invalid_target"))
      .then(doEnv("env/connect", "b", connect(s, "b")))
      .then(doSubscribe("b", FromStart))
      .expect(lastReplay == [])

  // Self-DM is accepted and delivered to the sender (MSG-A1).
  run selfDmTest =
    online3
      .then(doSubscribe("a", Latest))
      .then(doSend("a", ToPlayer("a"), 0))
      .expect(lastEvents == Set(("a", Received({ id: 0, src: SrcPlayer, from: "a", body: 0 }))))
}
