// Session lifecycle + system/* + user/*: system/disconnect, system/serverStats,
// user/self, user/info, user/report, user/subscribeUpdates,
// user/unsubscribeUpdates, user/updated; environment steps env/connect,
// env/reconnect, env/takeover, env/disconnect (socket drop),
// env/sessionExpired (grace over), env/activityChanged; and the generic
// request/response rules of docs/commands.md as a "pending requests"
// abstraction (env/clientSends + serving a pending request).
// Sources: tachyon docs/connection.md, docs/authorization.md, docs/commands.md,
// docs/schema/system.md, docs/schema/user.md, schema/{system,user}/*.
// Findings: findings/session.md (SESSION-nn ids below).
//
// @test main=session_test
// @inv main=session_test inv=safety steps=30 samples=50000
// @witness main=session_test inv=not(w_connectFresh)
// @witness main=session_test inv=not(w_connectRefused)
// @witness main=session_test inv=not(w_reconnectResend)
// @witness main=session_test inv=not(w_replaceDropsPending)
// @witness main=session_test inv=not(w_socketDrop)
// @witness main=session_test inv=not(w_graceEndNotifies)
// @witness main=session_test inv=not(w_graceKeptWhilePlaying)
// @witness main=session_test inv=not(w_activityNotifies)
// @witness main=session_test inv=not(w_servedFromQueue)
// @witness main=session_test inv=not(w_disconnectNotifies)
// @witness main=session_test inv=not(w_statsTwo)
// @witness main=session_test inv=not(w_infoLobby)
// @witness main=session_test inv=not(hit("user/info",Failed("unknown_user")))
// @witness main=session_test inv=not(hit("user/report",Ok))
// @witness main=session_test inv=not(hit("user/report",Failed("unknown_user")))
// @witness main=session_test inv=not(hit("user/report",Failed("unauthorized")))
// @witness main=session_test inv=not(hit("user/report",Failed("invalid_request")))
// @witness main=session_test inv=not(hit("user/subscribeUpdates",Ok))
// @witness main=session_test inv=not(hit("user/subscribeUpdates",Failed("subscription_limit_reached")))
// @witness main=session_test inv=not(hit("user/subscribeUpdates",Failed("invalid_request")))
// @witness main=session_test inv=not(hit("user/unsubscribeUpdates",Ok))
// @verify main=session_test inv=safety steps=2
//
// Unreachable by design (see findings "Coverage"):
//  - "unauthorized" for lack of scope: every command requires only
//    tachyon.lobby, which the WebSocket handshake already demanded.
//  - internal_error, command_unimplemented: server faults, not modelled.
//  - invalid_request for schema mismatch: requests are schema-valid by
//    construction; invalid_request is reachable only where the module uses it
//    as a stand-in reason (subscribeUpdates unknown id, report self).
//  - any failure of user/unsubscribeUpdates ("This should always succeed").
module session {
  import common.* from "./common"
  import schema.* from "./schema"

  type ConnId = int
  type MsgId = int

  // What the other groups (lobby, battle) report about a user. Owned by those
  // modules; here it only changes through env/activityChanged.
  type Activity = Menu | InLobby | Playing

  // "One live session per user; a new connection replaces the old one."
  // conn = -1: the socket is gone and the session waits out its grace period.
  // subs: the userIds this session receives user/updated for.
  type Session = { conn: ConnId, subs: Set[UserId] }

  // A request the client has sent and the server has not answered yet.
  // target / targets are the command's data (userId / userIds).
  type Req = { conn: ConnId, mid: MsgId, caller: UserId, cmd: str,
               target: UserId, targets: Set[UserId] }

  type State = {
    sessions: UserId -> Session,
    activity: UserId -> Activity,
    pending: Set[Req],
    answered: Set[MsgId],
    reports: Set[(UserId, UserId)],
    nextConn: ConnId,
    nextMid: MsgId,
  }

  // user/self carries the caller's own status, user/updated one user's status.
  // Only `status` of the user objects is modelled.
  type UserView = { user: UserId, status: str }
  type Event = Self(str) | Updated(UserView)

  // Response data for the commands that have some.
  type ReplyData = NoData | Info(str) | Stats(int)

  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)], data: ReplyData }

  const ACCOUNTS: Set[UserId]          // existing accounts
  const IDS: Set[UserId]               // ACCOUNTS plus ids that name no account
  const MAX_SUBS: int                  // "A maximum of 100 userIds can be subscribed to at any given time."
  const TOKEN_SCOPES: UserId -> Set[str]  // scopes granted to each account's access token
  const REPORT_RESTRICTED: Set[UserId] // accounts a moderator barred from reporting (SESSION-12)

  pure val LOBBY_SCOPE = "tachyon.lobby"
  // Every schema in schema/system and schema/user has
  // "tachyon": { ..., "scopes": ["tachyon.lobby"] }.
  pure val REQUIRED_SCOPES: str -> Set[str] = Map(
    "system/disconnect" -> Set(LOBBY_SCOPE),
    "system/serverStats" -> Set(LOBBY_SCOPE),
    "user/info" -> Set(LOBBY_SCOPE),
    "user/report" -> Set(LOBBY_SCOPE),
    "user/subscribeUpdates" -> Set(LOBBY_SCOPE),
    "user/unsubscribeUpdates" -> Set(LOBBY_SCOPE),
  )
  pure val USER_CMDS = REQUIRED_SCOPES.keys()

  pure val OPEN_STEPS = Set("env/connect", "env/reconnect", "env/takeover")
  pure val noReq: Req = { conn: -1, mid: -1, caller: "", cmd: "", target: "", targets: Set() }

  // ---- helpers ----
  pure def online(s: State, u: UserId): bool = s.sessions.keys().contains(u)
  pure def attached(s: State, u: UserId): bool = online(s, u) and s.sessions.get(u).conn >= 0
  pure def subsOf(s: State, u: UserId): Set[UserId] =
    if (online(s, u)) s.sessions.get(u).subs else Set()
  pure def connLive(s: State, c: ConnId): bool =
    s.sessions.keys().exists(u => s.sessions.get(u).conn == c)

  // user.json: "status": { "enum": ["offline", "menu", "playing", "lobby"] }.
  // ASSUMPTION SESSION-04: a user is "offline" exactly when they have no
  // session; a session in its grace period keeps its status.
  pure def statusOf(s: State, u: UserId): str =
    if (not(online(s, u))) "offline"
    else match s.activity.get(u) {
      | Menu => "menu"
      | InLobby => "lobby"
      | Playing => "playing"
    }

  // Sessions that can receive user/updated about t now (socket attached).
  pure def subscribersOf(s: State, t: UserId): Set[UserId] =
    s.sessions.keys().filter(u => attached(s, u) and t.in(s.sessions.get(u).subs))

  pure def updatedEv(s: State, t: UserId): Event = Updated({ user: t, status: statusOf(s, t) })

  // "Sent by the server to inform the client of user state changes."
  // Every step that changes a user's status tells that user's attached subscribers.
  pure def notifyChanges(pre: State, post: State): Set[(UserId, Event)] =
    ACCOUNTS.filter(t => statusOf(pre, t) != statusOf(post, t))
      .fold(Set(), (acc, t) => acc.union(send(subscribersOf(post, t), updatedEv(post, t))))

  // A closed socket takes its unanswered requests with it.
  pure def dropConnReqs(s: State, c: ConnId): Set[Req] = s.pending.filter(r => r.conn != c)

  pure def deny(s: State, reason: str): Outcome =
    { state: s, reply: Failed(reason), events: Set(), data: NoData }
  pure def noop(s: State): Outcome = { state: s, reply: NoReply, events: Set(), data: NoData }
  pure def okWith(s: State, evs: Set[(UserId, Event)]): Outcome =
    { state: s, reply: Ok, events: evs, data: NoData }

  // A session ends (system/disconnect or grace expiry). Its subscriptions go
  // with it (they belong to the session).
  // ASSUMPTION SESSION-08 / cross-module: the user leaves lobby, battle,
  // queue and party when the session ends, so their activity resets to Menu.
  pure def endSession(s: State, u: UserId): State =
    { ...s,
      sessions: mapRemove(s.sessions, u),
      activity: s.activity.set(u, Menu),
      pending: if (attached(s, u)) dropConnReqs(s, s.sessions.get(u).conn) else s.pending }

  // ---- environment: connection lifecycle ----

  // connection.md: "The WebSocket connection requires authorization."
  // authorization.md: "To access the Tachyon WebSocket endpoint, the client has
  // to acquire the access token for the custom scope `tachyon.lobby`."
  // user.md (self): "This event should be sent to a user when they login."
  // Design default: one live session per user, a new connection replaces the
  // old one (ASSUMPTION SESSION-01); after reconnect the server sends full
  // state following user/self (ASSUMPTION SESSION-05: for this group, that is
  // a full user/updated for every subscribed user).
  // One function for the three ways a socket opens; the env steps below pick
  // the case, so each is a no-op outside it (as party.qnt's presence steps).
  pure def openSocket(s: State, u: UserId): Outcome =
    if (not(TOKEN_SCOPES.get(u).contains(LOBBY_SCOPE))) noop(s)   // handshake rejected, no session
    else {
      val c = s.nextConn
      val resumed = online(s, u)
      val subs = subsOf(s, u)
      val pending1 = if (attached(s, u)) dropConnReqs(s, s.sessions.get(u).conn) else s.pending
      val s1 = { ...s,
                 sessions: s.sessions.put(u, { conn: c, subs: subs }),
                 activity: if (resumed) s.activity else s.activity.set(u, Menu),
                 pending: pending1,
                 nextConn: c + 1 }
      { state: s1, reply: NoReply, data: NoData,
        events: Set((u, Self(statusOf(s1, u))))
                  .union(subs.map(t => (u, updatedEv(s1, t))))
                  .union(notifyChanges(s, s1)) }
    }

  // env/connect: no session yet -> a fresh session (party.qnt `connect`).
  pure def connect(s: State, u: UserId): Outcome =
    if (online(s, u)) noop(s) else openSocket(s, u)
  // env/reconnect: the session is in its grace period -> reattached
  // (party.qnt `reconnect`).
  pure def reconnect(s: State, u: UserId): Outcome =
    if (not(online(s, u)) or attached(s, u)) noop(s) else openSocket(s, u)
  // env/takeover: a second connection while the first is up. The old socket
  // is closed by the server and the session moves (ASSUMPTION SESSION-01).
  // party.qnt has no such step: presence stays Online, nothing changes there.
  pure def takeover(s: State, u: UserId): Outcome =
    if (not(attached(s, u))) noop(s) else openSocket(s, u)

  // The socket closes without system/disconnect (network loss, crash, server
  // closing it with 1008). Design default: the session lasts through a grace
  // period. ASSUMPTION SESSION-04: no status change, so no user/updated.
  // Same step as party.qnt `disconnect` (Online -> Detached).
  pure def socketDrop(s: State, u: UserId): Outcome =
    if (not(attached(s, u))) noop(s)
    else {
      val sess = s.sessions.get(u)
      val s1 = { ...s, sessions: s.sessions.set(u, { ...sess, conn: -1 }),
                       pending: dropConnReqs(s, sess.conn) }
      { state: s1, reply: NoReply, events: notifyChanges(s, s1), data: NoData }
    }

  // Grace timer fires (party.qnt, lobby.qnt, matchmaking.qnt, messaging.qnt
  // and friend.qnt `sessionExpired`: one vocabulary, INT-D1).
  // Late or repeated fires (user reconnected, session
  // already gone) change nothing.
  // ASSUMPTION SESSION-07: a user who is playing keeps the session (as teiserver).
  pure def sessionExpired(s: State, u: UserId): Outcome =
    if (not(online(s, u)) or attached(s, u) or s.activity.get(u) == Playing) noop(s)
    else {
      val s1 = endSession(s, u)
      { state: s1, reply: NoReply, events: notifyChanges(s, s1), data: NoData }
    }

  // Another group moved the user (lobby/join, battle start, battle ended...).
  // Only users with a session can be anywhere.
  pure def activityChanged(s: State, u: UserId, a: Activity): Outcome =
    if (not(online(s, u))) noop(s)
    else {
      val s1 = { ...s, activity: s.activity.set(u, a) }
      { state: s1, reply: NoReply, events: notifyChanges(s, s1), data: NoData }
    }

  // ---- requests ----

  // commands.md: messageId is "A unique identifier for a pair of
  // request/response commands which links them together".
  // ASSUMPTION SESSION-15: the client never reuses a pending messageId.
  pure def newReq(s: State, u: UserId, cmd: str, t: UserId, ts: Set[UserId]): Req =
    { conn: s.sessions.get(u).conn, mid: s.nextMid, caller: u, cmd: cmd, target: t, targets: ts }
  pure def enqueue(s: State, r: Req): State =
    { ...s, pending: s.pending.union(Set(r)), nextMid: s.nextMid + 1 }

  // system.md: "Ask the server to terminate the connection."
  // ASSUMPTION SESSION-09: it also ends the session at once (no grace), the
  // response is sent before the socket closes.
  pure def disconnect(s: State, u: UserId): Outcome = {
    val s1 = endSession(s, u)
    okWith(s1, notifyChanges(s, s1))
  }

  // system.md: "Get server stats such as user count."
  // ASSUMPTION SESSION-10: userCount = users that are not offline.
  pure def serverStats(s: State): Outcome =
    { state: s, reply: Ok, events: Set(),
      data: Stats(ACCOUNTS.filter(u => online(s, u)).size()) }

  // user.md: "Fetch user info from the server." Fails with unknown_user.
  pure def info(s: State, t: UserId): Outcome =
    if (not(t.in(ACCOUNTS))) deny(s, "unknown_user")
    else { state: s, reply: Ok, events: Set(), data: Info(statusOf(s, t)) }

  // user.md: "Issue a single moderation report on one or more users."
  // Order of checks as teiserver: restriction, unknown target, self.
  // ASSUMPTION SESSION-12: a reporting restriction answers "unauthorized".
  // ASSUMPTION SESSION-13: reporting yourself is invalid_request.
  pure def report(s: State, u: UserId, ts: Set[UserId]): Outcome =
    if (u.in(REPORT_RESTRICTED)) deny(s, "unauthorized")
    else if (not(ts.subseteq(ACCOUNTS))) deny(s, "unknown_user")
    else if (u.in(ts)) deny(s, "invalid_request")
    else okWith({ ...s, reports: s.reports.union(ts.map(t => (u, t))) }, Set())

  // user.md: "Ask the server to send updates about theses users. A maximum of
  // 100 userIds can be subscribed to at any given time."
  // updated: "User objects should be full when first sent, then only updates
  // gets sent." -> a full user/updated for each requested id, to the caller only.
  // ASSUMPTION SESSION-11: an id that names no account is invalid_request
  // (the schema has no unknown_user here); re-subscribing resends the full object.
  pure def subscribe(s: State, u: UserId, ts: Set[UserId]): Outcome =
    if (not(ts.subseteq(ACCOUNTS))) deny(s, "invalid_request")
    else {
      val sess = s.sessions.get(u)
      val subs = sess.subs.union(ts)
      if (subs.size() > MAX_SUBS) deny(s, "subscription_limit_reached")
      else okWith({ ...s, sessions: s.sessions.set(u, { ...sess, subs: subs }) },
                  ts.map(t => (u, updatedEv(s, t))))
    }

  // user.md: "Ask the server to stop sending user updates for the given set of
  // userId. This should always succeed."
  pure def unsubscribe(s: State, u: UserId, ts: Set[UserId]): Outcome = {
    val sess = s.sessions.get(u)
    okWith({ ...s, sessions: s.sessions.set(u, { ...sess, subs: sess.subs.exclude(ts) }) }, Set())
  }

  // commands.md: unauthorized "When a client sends a request command of which
  // they do not have the `role` required to use". The schemas only name scopes.
  pure def handle(s: State, r: Req): Outcome =
    if (not(REQUIRED_SCOPES.get(r.cmd).subseteq(TOKEN_SCOPES.get(r.caller)))) deny(s, "unauthorized")
    else if (r.cmd == "system/disconnect") disconnect(s, r.caller)
    else if (r.cmd == "system/serverStats") serverStats(s)
    else if (r.cmd == "user/info") info(s, r.target)
    else if (r.cmd == "user/report") report(s, r.caller, r.targets)
    else if (r.cmd == "user/subscribeUpdates") subscribe(s, r.caller, r.targets)
    else unsubscribe(s, r.caller, r.targets)

  // commands.md: requests "expect the other side to send a correlating
  // response command". Serving a pending request: exactly one response, with
  // its messageId, then the command's effect.
  pure def serve(s: State, r: Req): Outcome = {
    val s0 = { ...s, pending: s.pending.exclude(Set(r)), answered: s.answered.union(Set(r.mid)) }
    handle(s0, r)
  }

  // ---- client view (what a client knows from the events it received) ----
  // On user/self the client starts over; user/updated overwrites one entry.
  pure def updateViews(v: UserId -> (UserId -> str), evs: Set[(UserId, Event)]): UserId -> (UserId -> str) =
    v.keys().mapBy(u => {
      val mine = evs.filter(e => e._1 == u)
      val reset = mine.exists(e => match e._2 { | Self(_) => true | Updated(_) => false })
      val base: UserId -> str = if (reset) Map() else v.get(u)
      mine.fold(base, (acc, e) => match e._2 {
        | Self(_) => acc
        | Updated(x) => acc.put(x.user, x.status)
      })
    })

  // ---- state machine ----
  var s: State
  var pre: State                 // state before the last step
  var lastCmd: str
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]
  var lastData: ReplyData
  var lastReq: Req               // request served last step; caller only, for env steps
  var views: UserId -> (UserId -> str)

  action applyFrom(p: State, cmd: str, o: Outcome, r: Req): bool = all {
    pre' = p, s' = o.state, lastCmd' = cmd, lastReply' = o.reply, lastEvents' = o.events,
    lastData' = o.data, lastReq' = r, views' = updateViews(views, o.events),
  }
  action applyEnv(cmd: str, u: UserId, o: Outcome): bool =
    applyFrom(s, cmd, o, { ...noReq, caller: u })

  // The client sends a request; it waits in `pending`.
  action clientSends(u: UserId, cmd: str, t: UserId, ts: Set[UserId]): bool = all {
    attached(s, u),
    val r = newReq(s, u, cmd, t, ts)
    applyFrom(s, "env/clientSends", { state: enqueue(s, r), reply: NoReply, events: Set(), data: NoData }, r)
  }
  // The server answers one pending request.
  action serveOne(r: Req): bool = all {
    r.in(s.pending),
    applyFrom(s, r.cmd, serve(s, r), r)
  }
  // Send and answer in one step (transcripts). `pre` is the state with the
  // request pending, so the pending-request properties apply unchanged.
  action request(u: UserId, cmd: str, t: UserId, ts: Set[UserId]): bool = all {
    attached(s, u),
    val r = newReq(s, u, cmd, t, ts)
    val s1 = enqueue(s, r)
    applyFrom(s1, cmd, serve(s1, r), r)
  }

  val initState: State = {
    sessions: Map(), activity: ACCOUNTS.mapBy(_ => Menu), pending: Set(), answered: Set(),
    reports: Set(), nextConn: 0, nextMid: 0 }

  action init = all {
    s' = initState, pre' = initState, lastCmd' = "init", lastReply' = NoReply,
    lastEvents' = Set(), lastData' = NoData, lastReq' = noReq,
    views' = ACCOUNTS.mapBy(_ => Map()),
  }

  pure val TARGET_SETS = IDS.powerset().filter(x => x.size() >= 1 and x.size() <= 2)  // minItems 1

  action step = {
    nondet u = ACCOUNTS.oneOf()
    nondet t = IDS.oneOf()
    nondet ts = TARGET_SETS.oneOf()
    nondet a = Set(Menu, InLobby, Playing).oneOf()
    nondet cmd = USER_CMDS.oneOf()
    nondet r = (if (s.pending == Set()) Set(noReq) else s.pending).oneOf()
    any {
      applyEnv("env/connect", u, connect(s, u)),
      applyEnv("env/reconnect", u, reconnect(s, u)),
      applyEnv("env/takeover", u, takeover(s, u)),
      applyEnv("env/disconnect", u, socketDrop(s, u)),
      applyEnv("env/sessionExpired", u, sessionExpired(s, u)),
      applyEnv("env/activityChanged", u, activityChanged(s, u, a)),
      clientSends(u, cmd, t, ts),
      serveOne(r),
      request(u, cmd, t, ts),
    }
  }

  // ---- properties ----

  // One live session per user, each on its own connection.
  val sessionsWellFormed = s.sessions.keys().forall(u => {
    val c = s.sessions.get(u).conn
    and { c < s.nextConn,
          TOKEN_SCOPES.get(u).contains(LOBBY_SCOPE),
          c >= 0 implies s.sessions.keys().forall(v => v != u implies s.sessions.get(v).conn != c) }
  })

  // "A maximum of 100 userIds can be subscribed to at any given time."
  val subsCapped = s.sessions.keys().forall(u =>
    s.sessions.get(u).subs.size() <= MAX_SUBS and s.sessions.get(u).subs.subseteq(ACCOUNTS))

  // Offline users are nowhere (cross-module: no lobby, battle, queue).
  val offlineIsIdle = ACCOUNTS.forall(u => not(online(s, u)) implies s.activity.get(u) == Menu)

  // -- commands.md: every request gets exactly one correlated response --
  // A pending request sits on its caller's current socket and is unanswered.
  val pendingOnLiveSocket = s.pending.forall(r =>
    attached(s, r.caller) and s.sessions.get(r.caller).conn == r.conn and not(r.mid.in(s.answered)))
  val pendingMidsUnique = s.pending.forall(r1 => s.pending.forall(r2 => r1.mid == r2.mid implies r1 == r2))
  // A response answers a request that was pending, once, with its messageId.
  val responseCorrelated =
    if (lastReply == NoReply) s.answered == pre.answered
    else and { lastReq.in(pre.pending), not(lastReq.mid.in(pre.answered)),
               not(lastReq.in(s.pending)), s.answered == pre.answered.union(Set(lastReq.mid)) }
  // A request leaves `pending` only by its response or because its socket closed.
  val requestResolved = pre.pending.forall(r =>
    r.in(s.pending) or (r == lastReq and lastReply != NoReply) or not(connLive(s, r.conn)))

  // -- events --
  val eventsToAttachedOnly = lastEvents.forall(e => attached(s, e._1))
  // user/updated reaches only sessions subscribed to that user.
  val updatedToSubscribersOnly = lastEvents.forall(e => match e._2 {
    | Updated(x) => x.user.in(subsOf(s, e._1))
    | Self(_) => true
  })
  // user/self: "sent to a user when they login" (and only then).
  val selfOnlyOnLogin = lastEvents.forall(e => match e._2 {
    | Self(_) => OPEN_STEPS.contains(lastCmd) and e._1 == lastReq.caller
    | Updated(_) => true
  })
  // Events carry the state after the step.
  val eventsCurrent = lastEvents.forall(e => match e._2 {
    | Self(st) => st == statusOf(s, e._1)
    | Updated(x) => x.status == statusOf(s, x.user)
  })
  // The point of subscriptions: an attached client knows the current status of
  // every user it is subscribed to.
  val viewsFresh = s.sessions.keys().forall(u =>
    attached(s, u) implies s.sessions.get(u).subs.forall(t =>
      views.get(u).keys().contains(t) and views.get(u).get(t) == statusOf(s, t)))

  val replyDataCorrect = match lastData {
    | Info(st) => st == statusOf(s, lastReq.target)
    | Stats(n) => n == ACCOUNTS.filter(u => online(s, u)).size()
    | NoData => true
  }
  // Denials: no events, no domain change.
  val denialsInert = match lastReply {
    | Failed(_) => and { lastEvents == Set(), s.sessions == pre.sessions,
                         s.activity == pre.activity, s.reports == pre.reports }
    | Ok => true
    | NoReply => true
  }
  // The only "unauthorized" is the reporting restriction (scope is checked at
  // the handshake).
  val unauthorizedOnlyRole =
    lastReply == Failed("unauthorized") implies (lastCmd == "user/report" and lastReq.caller.in(REPORT_RESTRICTED))

  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  val safety = and {
    sessionsWellFormed, subsCapped, offlineIsIdle,
    pendingOnLiveSocket, pendingMidsUnique, responseCorrelated, requestResolved,
    eventsToAttachedOnly, updatedToSubscribersOnly, selfOnlyOnLogin, eventsCurrent, viewsFresh,
    replyDataCorrect, denialsInert, unauthorizedOnlyRole, reasonsInSchema,
  }

  // ---- reachability witnesses ----
  def hit(cmd: str, r: Reply): bool = lastCmd == cmd and lastReply == r
  val w_connectFresh = lastCmd == "env/connect" and not(online(pre, lastReq.caller)) and online(s, lastReq.caller)
  val w_connectRefused = lastCmd == "env/connect" and not(online(s, lastReq.caller))
  val w_reconnectResend = lastCmd == "env/reconnect" and online(pre, lastReq.caller)
    and not(attached(pre, lastReq.caller))
    and lastEvents.exists(e => match e._2 { | Updated(_) => true | Self(_) => false })
  val w_replaceDropsPending = lastCmd == "env/takeover" and attached(pre, lastReq.caller)
    and pre.pending.exists(r => r.caller == lastReq.caller)
  val w_socketDrop = lastCmd == "env/disconnect" and attached(pre, lastReq.caller)
    and pre.pending.exists(r => r.caller == lastReq.caller)
  val w_graceEndNotifies = lastCmd == "env/sessionExpired" and online(pre, lastReq.caller)
    and not(online(s, lastReq.caller)) and lastEvents != Set()
  val w_graceKeptWhilePlaying = lastCmd == "env/sessionExpired" and online(s, lastReq.caller)
    and not(attached(s, lastReq.caller))
  val w_activityNotifies = lastCmd == "env/activityChanged" and lastEvents != Set()
  val w_servedFromQueue = lastReply != NoReply and pre.pending.size() >= 2
  val w_disconnectNotifies = hit("system/disconnect", Ok) and lastEvents != Set()
  val w_statsTwo = lastData == Stats(2)
  val w_infoLobby = lastData == Info("lobby")
}

module session_test {
  import common.* from "./common"
  import session(
    ACCOUNTS = Set("a", "b", "c", "d"),
    IDS = Set("a", "b", "c", "d", "x"),
    MAX_SUBS = 2,
    TOKEN_SCOPES = Map("a" -> Set("tachyon.lobby"), "b" -> Set("tachyon.lobby"),
                       "c" -> Set("tachyon.lobby"), "d" -> Set()),
    REPORT_RESTRICTED = Set("c"),
  ).*

  pure val none: Set[UserId] = Set()
  def up(u: UserId, t: UserId, st: str): (UserId, Event) = (u, Updated({ user: t, status: st }))

  // a logs in, b logs in, a watches b; b's status changes reach a.
  run presenceTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .expect(lastEvents == Set(("a", Self("menu"))))
      .then(applyEnv("env/connect", "b", connect(s, "b")))
      .expect(lastEvents == Set(("b", Self("menu"))))          // nobody watches b yet
      .then(request("a", "user/subscribeUpdates", "", Set("b")))
      .expect(lastReply == Ok and lastEvents == Set(up("a", "b", "menu")))
      .then(applyEnv("env/activityChanged", "b", activityChanged(s, "b", InLobby)))
      .expect(lastEvents == Set(up("a", "b", "lobby")))
      .then(request("a", "user/info", "b", none))
      .expect(lastReply == Ok and lastData == Info("lobby"))
      .then(request("a", "system/serverStats", "", none))
      .expect(lastReply == Ok and lastData == Stats(2))
      .then(applyEnv("env/activityChanged", "a", activityChanged(s, "a", Playing)))
      .expect(lastEvents == Set())                              // b does not watch a
      .then(request("a", "user/info", "x", none))
      .expect(lastReply == Failed("unknown_user"))

  // Cap, unknown ids, and unsubscribe always succeeding.
  run subscriptionLimitTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(request("a", "user/subscribeUpdates", "", Set("b", "c")))
      .expect(lastReply == Ok and lastEvents == Set(up("a", "b", "offline"), up("a", "c", "offline")))
      .then(request("a", "user/subscribeUpdates", "", Set("d")))
      .expect(lastReply == Failed("subscription_limit_reached") and lastEvents == Set())
      .then(request("a", "user/subscribeUpdates", "", Set("b")))
      .expect(lastReply == Ok and lastEvents == Set(up("a", "b", "offline")))  // already counted
      .then(request("a", "user/subscribeUpdates", "", Set("x")))
      .expect(lastReply == Failed("invalid_request"))
      .then(request("a", "user/unsubscribeUpdates", "", Set("x", "b")))
      .expect(lastReply == Ok and s.sessions.get("a").subs == Set("c"))
      .then(request("a", "user/subscribeUpdates", "", Set("d")))
      .expect(lastReply == Ok and s.sessions.get("a").subs == Set("c", "d"))
      .then(applyEnv("env/connect", "c", connect(s, "c")))
      .expect(lastEvents == Set(("c", Self("menu")), up("a", "c", "menu")))

  // Socket drop: the session waits; missed updates come back after user/self.
  run graceReconnectTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(applyEnv("env/connect", "b", connect(s, "b")))
      .then(request("a", "user/subscribeUpdates", "", Set("b")))
      .then(applyEnv("env/disconnect", "a", socketDrop(s, "a")))
      .expect(lastEvents == Set() and online(s, "a") and not(attached(s, "a")))
      .then(applyEnv("env/activityChanged", "b", activityChanged(s, "b", InLobby)))
      .expect(lastEvents == Set())                              // a has no socket
      .then(request("b", "user/info", "a", none))
      .expect(lastData == Info("menu"))                         // still online during grace
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .expect(lastEvents == Set() and not(attached(s, "a")))  // env/connect needs no session
      .then(applyEnv("env/reconnect", "a", reconnect(s, "a")))
      .expect(lastEvents == Set(("a", Self("menu")), up("a", "b", "lobby")))
      .expect(views.get("a").get("b") == "lobby")
      .then(applyEnv("env/sessionExpired", "a", sessionExpired(s, "a")))
      .expect(lastEvents == Set() and attached(s, "a"))        // late timer: no-op

  // Grace expiry ends the session: subscribers see "offline"; the next login
  // is a fresh session without subscriptions.
  run graceExpiryTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(applyEnv("env/connect", "b", connect(s, "b")))
      .then(request("a", "user/subscribeUpdates", "", Set("b")))
      .then(request("b", "user/subscribeUpdates", "", Set("a")))
      .then(applyEnv("env/disconnect", "b", socketDrop(s, "b")))
      .then(applyEnv("env/sessionExpired", "b", sessionExpired(s, "b")))
      .expect(lastEvents == Set(up("a", "b", "offline")) and not(online(s, "b")))
      .then(applyEnv("env/connect", "b", connect(s, "b")))
      .expect(lastEvents == Set(("b", Self("menu")), up("a", "b", "menu")))
      .expect(s.sessions.get("b").subs == Set())

  // Playing users keep their session through a socket drop.
  run playingGraceTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(applyEnv("env/activityChanged", "a", activityChanged(s, "a", Playing)))
      .then(applyEnv("env/disconnect", "a", socketDrop(s, "a")))
      .then(applyEnv("env/sessionExpired", "a", sessionExpired(s, "a")))
      .expect(online(s, "a"))
      .then(applyEnv("env/reconnect", "a", reconnect(s, "a")))
      .expect(lastEvents == Set(("a", Self("playing"))))       // user/self has the real status
      .then(applyEnv("env/disconnect", "a", socketDrop(s, "a")))
      .then(applyEnv("env/activityChanged", "a", activityChanged(s, "a", Menu)))
      .then(applyEnv("env/sessionExpired", "a", sessionExpired(s, "a")))
      .expect(not(online(s, "a")))

  // A second connection replaces the first; requests in flight on the old
  // socket are never answered (the client sees the socket close instead).
  run replaceConnectionTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(request("a", "user/subscribeUpdates", "", Set("b")))
      .then(clientSends("a", "system/serverStats", "", none))
      .expect(s.pending.size() == 1)
      .then(applyEnv("env/takeover", "a", takeover(s, "a")))
      .expect(s.pending == Set() and s.sessions.get("a").conn == 1)
      .expect(lastEvents == Set(("a", Self("menu")), up("a", "b", "offline")))
      .then(request("a", "system/serverStats", "", none))
      .expect(lastData == Stats(1) and lastReq.conn == 1)

  // Two requests in flight are answered one each, in any order.
  run pendingTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(clientSends("a", "user/info", "b", none))
      .then(clientSends("a", "system/serverStats", "", none))
      .expect(s.pending.size() == 2)
      .then(serveOne({ conn: 0, mid: 1, caller: "a", cmd: "system/serverStats", target: "", targets: none }))
      .expect(lastData == Stats(1) and s.answered == Set(1))
      .then(serveOne({ conn: 0, mid: 0, caller: "a", cmd: "user/info", target: "b", targets: none }))
      .expect(lastData == Info("offline") and s.pending == Set() and s.answered == Set(0, 1))

  // system/disconnect: response, then the session ends without grace.
  run disconnectTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(applyEnv("env/connect", "b", connect(s, "b")))
      .then(request("a", "user/subscribeUpdates", "", Set("b")))
      .then(clientSends("b", "user/info", "a", none))
      .then(request("b", "system/disconnect", "", none))
      .expect(lastReply == Ok and lastEvents == Set(up("a", "b", "offline")))
      .expect(not(online(s, "b")) and s.pending == Set())     // b's other request is dropped
      .then(applyEnv("env/sessionExpired", "b", sessionExpired(s, "b")))
      .expect(lastEvents == Set())

  // user/report denials; d's token lacks tachyon.lobby so d never connects.
  run reportTest =
    init
      .then(applyEnv("env/connect", "a", connect(s, "a")))
      .then(applyEnv("env/connect", "c", connect(s, "c")))
      .then(request("a", "user/report", "", Set("b", "c")))
      .expect(lastReply == Ok and s.reports == Set(("a", "b"), ("a", "c")))
      .then(request("a", "user/report", "", Set("a", "b")))
      .expect(lastReply == Failed("invalid_request"))
      .then(request("a", "user/report", "", Set("x")))
      .expect(lastReply == Failed("unknown_user"))
      .then(request("c", "user/report", "", Set("a")))
      .expect(lastReply == Failed("unauthorized"))
      .then(applyEnv("env/connect", "d", connect(s, "d")))
      .expect(not(online(s, "d")) and lastEvents == Set())
}
