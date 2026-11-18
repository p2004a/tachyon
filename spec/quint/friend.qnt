// Friends: friend/list, friend/sendRequest, friend/acceptRequest,
// friend/rejectRequest, friend/cancelRequest, friend/remove and the events
// friend/removed, friend/requestAccepted, friend/requestCancelled,
// friend/requestReceived, friend/requestRejected; plus the environment steps
// the session steps env/connect, env/disconnect, env/reconnect, env/sessionExpired
// (vocabulary of session.qnt; friend events only reach Online users).
// Source: tachyon docs/schema/friend.md (generated from src/schema/friend/*.ts).
// Findings: findings/friend.md (FRIEND-nn ids below).
//
// @test main=friend4
// @inv main=friend4 inv=safety steps=30 samples=50000
// @witness main=friend4 inv=not(hit("friend/list",Ok)) steps=30 samples=200000
// @witness main=friend4 inv=not(newRequestSent) steps=30 samples=200000
// @witness main=friend4 inv=not(autoAccepted) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/sendRequest",Failed("invalid_user"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/sendRequest",Failed("already_in_friendlist"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/sendRequest",Failed("invalid_request"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/sendRequest",Failed("outgoing_capacity_reached"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/sendRequest",Failed("incoming_capacity_reached"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/acceptRequest",Ok)) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/acceptRequest",Failed("invalid_user"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/acceptRequest",Failed("no_pending_request"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/rejectRequest",Ok)) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/rejectRequest",Failed("invalid_user"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/rejectRequest",Failed("no_pending_request"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/cancelRequest",Ok)) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/cancelRequest",Failed("invalid_user"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/cancelRequest",Failed("invalid_request"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/remove",Ok)) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/remove",Failed("invalid_user"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("friend/remove",Failed("not_in_friendlist"))) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("env/disconnect",NoReply)) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("env/connect",NoReply)) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("env/reconnect",NoReply)) steps=30 samples=200000
// @witness main=friend4 inv=not(hit("env/sessionExpired",NoReply)) steps=30 samples=200000
// @witness main=friend4 inv=not(eventLostInGrace) steps=30 samples=200000
// @witness main=friend4 inv=not(eventDropped) steps=30 samples=200000
// @witness main=friend4 inv=not(multipleFriends) steps=30 samples=200000
// @verify main=friend3 inv=safety steps=2
module friend {
  import common.* from "./common"
  import schema.* from "./schema"

  // ---- vocabulary ----
  // Every friend event carries `from`: the other user of the relation.
  type Event =
    | Removed(UserId)            // friend/removed
    | RequestAccepted(UserId)    // friend/requestAccepted
    | RequestCancelled(UserId)   // friend/requestCancelled
    | RequestReceived(UserId)    // friend/requestReceived
    | RequestRejected(UserId)    // friend/requestRejected

  // What friend/list returns (and user/self carries): friends,
  // outgoingPendingRequests, incomingPendingRequests. Timestamps (addedAt,
  // sentAt) are abstracted away.
  type View = { friends: Set[UserId], outgoing: Set[UserId], incoming: Set[UserId] }

  // Server-side protocol nouns. `friends` is an adjacency map (so that its
  // symmetry is a checked property, not a representation guarantee);
  // `requests` holds pending requests as (from, to); `presence` is owned by the
  // session group (session.qnt): Online = session with a live socket
  // (attached), Detached = session in its grace period, Offline = no session.
  type State = {
    friends: UserId -> Set[UserId],
    requests: Set[(UserId, UserId)],
    presence: UserId -> Presence,
  }
  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)] }
  type Presence = Online | Detached | Offline

  const USERS: Set[UserId]      // registered users
  const GHOST: UserId           // a well-formed id of no registered user
  // ASSUMPTION FRIEND-03: "outgoing_capacity_reached" / "incoming_capacity_reached"
  // bound the caller's pending outgoing requests and the target's pending
  // incoming requests (server settings). No friend-list cap (FRIEND-04).
  const MAX_OUTGOING: int
  const MAX_INCOMING: int

  // ---- helpers ----
  pure def friendsOf(s: State, u: UserId): Set[UserId] = s.friends.get(u)
  pure def isOnline(s: State, u: UserId): bool = s.presence.get(u) == Online
  pure def outgoingOf(s: State, u: UserId): Set[UserId] =
    s.requests.filter(r => r._1 == u).map(r => r._2)
  pure def incomingOf(s: State, u: UserId): Set[UserId] =
    s.requests.filter(r => r._2 == u).map(r => r._1)
  pure def serverView(s: State, u: UserId): View =
    { friends: friendsOf(s, u), outgoing: outgoingOf(s, u), incoming: incomingOf(s, u) }

  pure def deny(s: State, reason: str): Outcome = { state: s, reply: Failed(reason), events: Set() }
  pure def ok(s: State, events: Set[(UserId, Event)]): Outcome = { state: s, reply: Ok, events: events }

  // README: "These events are automatically sent to the clients if they are
  // connected. To catch up at connection, a client should request friend/list
  // to get a full state." Only Online users get the event; for Detached and
  // Offline users it is dropped (FRIEND-08), as in teiserver send_to_player.
  pure def deliver(s: State, rcpt: UserId, e: Event): Set[(UserId, Event)] =
    if (isOnline(s, rcpt)) Set((rcpt, e)) else Set()

  // invalid_user: the id names no registered user, or names the caller.
  // ASSUMPTION FRIEND-05: self-targeting is invalid_user for every command
  // (teiserver does this for sendRequest only).
  pure def invalidTarget(u: UserId, t: UserId): bool = not(USERS.contains(t)) or t == u

  pure def befriend(s: State, a: UserId, b: UserId): State =
    { ...s, friends: s.friends.set(a, friendsOf(s, a).union(Set(b)))
                              .set(b, friendsOf(s, b).union(Set(a))) }
  pure def unfriend(s: State, a: UserId, b: UserId): State =
    { ...s, friends: s.friends.set(a, friendsOf(s, a).exclude(Set(b)))
                              .set(b, friendsOf(s, b).exclude(Set(a))) }
  pure def dropRequest(s: State, src: UserId, dst: UserId): State =
    { ...s, requests: s.requests.exclude(Set((src, dst))) }

  // ---- commands ----

  // friend/list: "Retrieve the status of your friendlist". The response data is
  // listData(s, u); the reply itself is Ok (see common.Reply).
  pure def list(s: State, u: UserId): Outcome = ok(s, Set())
  pure def listData(s: State, u: UserId): View = serverView(s, u)

  // friend/sendRequest: "Send a friend request to the target player".
  // requestReceived: "Notify the player that someone sent them a friend request".
  pure def sendRequest(s: State, u: UserId, t: UserId): Outcome =
    if (invalidTarget(u, t)) deny(s, "invalid_user")
    else if (friendsOf(s, u).contains(t)) deny(s, "already_in_friendlist")
    // ASSUMPTION FRIEND-06: a repeated request has no schema reason -> invalid_request.
    else if (s.requests.contains((u, t))) deny(s, "invalid_request")
    // ASSUMPTION FRIEND-07 (design default): "the second request accepts the
    // first". Both users get requestAccepted, because the caller's Ok alone
    // does not say that a friendship (not a request) was created. No capacity
    // check: the step removes a pending request and adds no new one.
    else if (s.requests.contains((t, u)))
      ok(befriend(dropRequest(s, t, u), u, t),
         deliver(s, t, RequestAccepted(u)).union(deliver(s, u, RequestAccepted(t))))
    // ASSUMPTION FRIEND-03: outgoing is checked before incoming.
    else if (outgoingOf(s, u).size() >= MAX_OUTGOING) deny(s, "outgoing_capacity_reached")
    else if (incomingOf(s, t).size() >= MAX_INCOMING) deny(s, "incoming_capacity_reached")
    else ok({ ...s, requests: s.requests.union(Set((u, t))) },
            deliver(s, t, RequestReceived(u)))

  // friend/acceptRequest: "Accept an incoming friend request".
  // requestAccepted: "Notify the player that their friend request has been accepted".
  pure def acceptRequest(s: State, u: UserId, from: UserId): Outcome =
    if (invalidTarget(u, from)) deny(s, "invalid_user")
    else if (not(s.requests.contains((from, u)))) deny(s, "no_pending_request")
    else ok(befriend(dropRequest(s, from, u), from, u), deliver(s, from, RequestAccepted(u)))

  // friend/rejectRequest: "Reject a friend request".
  // requestRejected: "Notify the player that their friend request has been rejected".
  pure def rejectRequest(s: State, u: UserId, from: UserId): Outcome =
    if (invalidTarget(u, from)) deny(s, "invalid_user")
    else if (not(s.requests.contains((from, u)))) deny(s, "no_pending_request")
    else ok(dropRequest(s, from, u), deliver(s, from, RequestRejected(u)))

  // friend/cancelRequest: "Cancel an invite sent to someone".
  // requestCancelled: "Notify the player that a friend request they received is
  // no longer valid".
  pure def cancelRequest(s: State, u: UserId, t: UserId): Outcome =
    if (invalidTarget(u, t)) deny(s, "invalid_user")
    // ASSUMPTION FRIEND-09: the schema has no no_pending_request here -> invalid_request.
    else if (not(s.requests.contains((u, t)))) deny(s, "invalid_request")
    else ok(dropRequest(s, u, t), deliver(s, t, RequestCancelled(u)))

  // friend/remove: "Remove a player from your friendlist".
  // removed: "Notify the player that they are no longer friend with a player.
  // Typically, that player removed them from their friendlist".
  pure def remove(s: State, u: UserId, t: UserId): Outcome =
    if (invalidTarget(u, t)) deny(s, "invalid_user")
    else if (not(friendsOf(s, u).contains(t))) deny(s, "not_in_friendlist")
    else ok(unfriend(s, u, t), deliver(s, t, Removed(u)))

  // ---- environment ----
  // Session steps, same names and pre-conditions as session.qnt / party.qnt.
  // Friend state is persistent: no session step changes friends or requests.
  // On env/connect and env/reconnect the client gets user/self (privateUser:
  // friendIds, outgoingFriendRequest, incomingFriendRequest) and rebuilds its
  // view from it (design default: "after reconnect the server sends full state
  // following user/self"; teiserver tachyon_handler.ex:101).
  pure def setPresence(s: State, u: UserId, from: Presence, p: Presence): Outcome =
    if (s.presence.get(u) != from) { state: s, reply: NoReply, events: Set() }   // late/repeated: no-op
    else { state: { ...s, presence: s.presence.set(u, p) }, reply: NoReply, events: Set() }
  pure def connect(s: State, u: UserId): Outcome = setPresence(s, u, Offline, Online)
  pure def disconnect(s: State, u: UserId): Outcome = setPresence(s, u, Online, Detached)
  pure def reconnect(s: State, u: UserId): Outcome = setPresence(s, u, Detached, Online)
  pure def sessionExpired(s: State, u: UserId): Outcome = setPresence(s, u, Detached, Offline)

  // ---- reference client ----
  // A client that keeps its View from replies and events only. viewsInSync
  // checks that the protocol's replies + events are enough for this. A reply
  // and an event of the same step may arrive in either order (FRIEND-10).
  pure def clientOnEvent(v: View, e: Event): View = match e {
    | RequestReceived(f) => { ...v, incoming: v.incoming.union(Set(f)) }
    | RequestCancelled(f) => { ...v, incoming: v.incoming.exclude(Set(f)) }
    | RequestAccepted(f) => { friends: v.friends.union(Set(f)),
                              outgoing: v.outgoing.exclude(Set(f)),
                              incoming: v.incoming.exclude(Set(f)) }
    | RequestRejected(f) => { ...v, outgoing: v.outgoing.exclude(Set(f)) }
    | Removed(f) => { ...v, friends: v.friends.exclude(Set(f)) }
  }
  pure def befriendView(v: View, t: UserId): View =
    { friends: v.friends.union(Set(t)), outgoing: v.outgoing.exclude(Set(t)),
      incoming: v.incoming.exclude(Set(t)) }
  // Effect of an Ok reply on the caller's view. sendRequest: if t already sent
  // us a request, the Ok means the request was auto-accepted.
  pure def clientOnOk(v: View, cmd: str, t: UserId, s: State, u: UserId): View =
    if (cmd == "friend/sendRequest")
      if (v.friends.contains(t)) v
      else if (v.incoming.contains(t)) befriendView(v, t)
      else { ...v, outgoing: v.outgoing.union(Set(t)) }
    else if (cmd == "friend/acceptRequest") befriendView(v, t)
    else if (cmd == "friend/rejectRequest") { ...v, incoming: v.incoming.exclude(Set(t)) }
    else if (cmd == "friend/cancelRequest") { ...v, outgoing: v.outgoing.exclude(Set(t)) }
    else if (cmd == "friend/remove") { ...v, friends: v.friends.exclude(Set(t)) }
    else if (cmd == "friend/list") listData(s, u)
    else v

  pure def clientEvents(v: View, x: UserId, evs: Set[(UserId, Event)]): View =
    evs.filter(m => m._1 == x).fold(v, (acc, m) => clientOnEvent(acc, m._2))
  pure def clientReply(v: View, x: UserId, cmd: str, u: UserId, t: UserId, o: Outcome): View =
    if (x == u and o.reply == Ok) clientOnOk(v, cmd, t, o.state, x) else v
  pure def clientStep(v: View, x: UserId, cmd: str, u: UserId, t: UserId,
                      o: Outcome, replyFirst: bool): View =
    if ((cmd == "env/connect" or cmd == "env/reconnect") and x == u and isOnline(o.state, x))
      serverView(o.state, x)   // user/self
    else if (replyFirst) clientEvents(clientReply(v, x, cmd, u, t, o), x, o.events)
    else clientReply(clientEvents(v, x, o.events), x, cmd, u, t, o)

  // ---- state machine ----
  var s: State
  var prevS: State
  var lastCmd: str
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]
  var lastCaller: UserId
  var lastTarget: UserId
  var views: UserId -> View        // each client's belief (meaningful while Online)

  action applyOrdered(cmd: str, u: UserId, t: UserId, o: Outcome, replyFirst: bool): bool = all {
    s' = o.state, prevS' = s, lastCmd' = cmd, lastReply' = o.reply, lastEvents' = o.events,
    lastCaller' = u, lastTarget' = t,
    views' = USERS.mapBy(x => clientStep(views.get(x), x, cmd, u, t, o, replyFirst)),
  }
  action apply(cmd: str, u: UserId, t: UserId, o: Outcome): bool = applyOrdered(cmd, u, t, o, true)

  pure val emptyView: View = { friends: Set(), outgoing: Set(), incoming: Set() }
  pure val initState: State =
    { friends: USERS.mapBy(_ => Set()), requests: Set(), presence: USERS.mapBy(_ => Online) }
  action init = all {
    s' = initState, prevS' = initState,
    lastCmd' = "init", lastReply' = NoReply, lastEvents' = Set(),
    lastCaller' = GHOST, lastTarget' = GHOST,
    views' = USERS.mapBy(_ => emptyView),
  }

  action step = {
    nondet u = USERS.oneOf()
    nondet t = USERS.union(Set(GHOST)).oneOf()
    nondet replyFirst = Set(true, false).oneOf()
    any {
      all { isOnline(s, u), any {
        applyOrdered("friend/list", u, u, list(s, u), replyFirst),
        applyOrdered("friend/sendRequest", u, t, sendRequest(s, u, t), replyFirst),
        applyOrdered("friend/acceptRequest", u, t, acceptRequest(s, u, t), replyFirst),
        applyOrdered("friend/rejectRequest", u, t, rejectRequest(s, u, t), replyFirst),
        applyOrdered("friend/cancelRequest", u, t, cancelRequest(s, u, t), replyFirst),
        applyOrdered("friend/remove", u, t, remove(s, u, t), replyFirst),
      }},
      applyOrdered("env/connect", u, u, connect(s, u), replyFirst),
      applyOrdered("env/disconnect", u, u, disconnect(s, u), replyFirst),
      applyOrdered("env/reconnect", u, u, reconnect(s, u), replyFirst),
      applyOrdered("env/sessionExpired", u, u, sessionExpired(s, u), replyFirst),
    }
  }

  // ---- properties ----
  // Friendship is symmetric.
  val symmetric = USERS.forall(a => friendsOf(s, a).forall(b => friendsOf(s, b).contains(a)))
  // No self-relations, nothing with unknown ids.
  val noSelfRelations = and {
    USERS.forall(u => not(friendsOf(s, u).contains(u))),
    s.requests.forall(r => r._1 != r._2),
  }
  val onlyKnownUsers = and {
    s.friends.keys() == USERS,
    USERS.forall(u => friendsOf(s, u).subseteq(USERS)),
    s.requests.forall(r => USERS.contains(r._1) and USERS.contains(r._2)),
  }
  // No pending request between friends, and never two crossing requests.
  val noRequestBetweenFriends = s.requests.forall(r => not(friendsOf(s, r._1).contains(r._2)))
  val noCrossingRequests = s.requests.forall(r => not(s.requests.contains((r._2, r._1))))
  // Request sets stay within the server's capacities.
  val withinCapacity = USERS.forall(u => and {
    outgoingOf(s, u).size() <= MAX_OUTGOING,
    incomingOf(s, u).size() <= MAX_INCOMING,
  })

  pure def evFrom(e: Event): UserId = match e {
    | Removed(f) => f | RequestAccepted(f) => f | RequestCancelled(f) => f
    | RequestReceived(f) => f | RequestRejected(f) => f
  }
  // Events go only to the two users involved, name the other one, and only to
  // Online users.
  val eventsToInvolvedOnly = lastEvents.forall(m => and {
    Set(lastCaller, lastTarget).contains(m._1),
    Set(lastCaller, lastTarget).contains(evFrom(m._2)),
    evFrom(m._2) != m._1,
  })
  val eventsOnlyToOnline = lastEvents.forall(m => isOnline(s, m._1))
  // Each event kind comes from exactly one command (requestAccepted: accept or
  // the auto-accepting sendRequest).
  pure def eventCmd(e: Event): Set[str] = match e {
    | Removed(_) => Set("friend/remove")
    | RequestAccepted(_) => Set("friend/acceptRequest", "friend/sendRequest")
    | RequestCancelled(_) => Set("friend/cancelRequest")
    | RequestReceived(_) => Set("friend/sendRequest")
    | RequestRejected(_) => Set("friend/rejectRequest")
  }
  val eventsMatchCommand = lastEvents.forall(m => eventCmd(m._2).contains(lastCmd))
  // A denial changes nothing and sends nothing.
  val denialIsNoop = match lastReply {
    | Failed(_) => s == prevS and lastEvents == Set()
    | Ok => true
    | NoReply => true
  }
  // friend/list changes nothing.
  val listIsReadOnly = lastCmd == "friend/list" implies s == prevS
  // Every connected client that tracked replies and events agrees with the server.
  val viewsInSync = USERS.forall(u => isOnline(s, u) implies views.get(u) == serverView(s, u))
  // Session steps never touch friend state.
  val sessionStepsKeepFriends = lastCmd.in(Set("env/connect", "env/disconnect", "env/reconnect",
    "env/sessionExpired")) implies (s.friends == prevS.friends and s.requests == prevS.requests)

  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  val safety = and {
    symmetric, noSelfRelations, onlyKnownUsers, noRequestBetweenFriends,
    noCrossingRequests, withinCapacity, eventsToInvolvedOnly, eventsOnlyToOnline,
    eventsMatchCommand, denialIsNoop, listIsReadOnly, viewsInSync, sessionStepsKeepFriends,
    reasonsInSchema,
  }

  // ---- witnesses (check.sh expects not(...) of these to be violated) ----
  def hit(cmd: str, r: Reply): bool = lastCmd == cmd and lastReply == r
  // sendRequest that created a pending request vs. one that auto-accepted.
  val newRequestSent = hit("friend/sendRequest", Ok) and s.requests.contains((lastCaller, lastTarget))
  val autoAccepted = hit("friend/sendRequest", Ok) and friendsOf(s, lastCaller).contains(lastTarget)
  // A successful command whose event was dropped because the peer is offline.
  val eventDropped = and {
    lastReply == Ok, lastEvents == Set(), USERS.contains(lastTarget), lastCaller != lastTarget,
    not(isOnline(s, lastTarget)),
  }
  // ... and specifically because the peer was in its grace period (SESSION-05).
  val eventLostInGrace = and {
    eventDropped, s.presence.get(lastTarget) == Detached,
  }
  // Somebody has several friends (more than MAX_INCOMING). A full circle
  // (friends with everybody, more than MAX_OUTGOING) is too rare for random
  // simulation; noFriendCapTest shows it.
  val multipleFriends = USERS.exists(u => friendsOf(s, u).size() > MAX_INCOMING)
  val fullFriendCircle = USERS.exists(u => friendsOf(s, u).size() == USERS.size() - 1)
  // Unreachable in this model: unauthorized, internal_error,
  // command_unimplemented (scopes, storage and dispatch are not modelled) and
  // friend/list invalid_request (the request has no data).
}

module friend4 {
  import common.* from "./common"
  import friend(USERS = Set("a", "b", "c", "d"), GHOST = "x",
                MAX_OUTGOING = 2, MAX_INCOMING = 1).*

  // Reviewed transcript: request, accept, list, remove.
  run sendAcceptRemoveTest =
    init
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .expect(lastReply == Ok and lastEvents == Set(("b", RequestReceived("a"))))
      .expect(views.get("a").outgoing == Set("b") and views.get("b").incoming == Set("a"))
      .then(apply("friend/acceptRequest", "b", "a", acceptRequest(s, "b", "a")))
      .expect(lastReply == Ok and lastEvents == Set(("a", RequestAccepted("b"))))
      .expect(s.requests == Set() and friendsOf(s, "a") == Set("b") and friendsOf(s, "b") == Set("a"))
      .then(apply("friend/list", "a", "a", list(s, "a")))
      .expect(listData(s, "a") == { friends: Set("b"), outgoing: Set(), incoming: Set() })
      .then(apply("friend/acceptRequest", "b", "a", acceptRequest(s, "b", "a")))
      .expect(lastReply == Failed("no_pending_request"))
      .then(apply("friend/remove", "a", "b", remove(s, "a", "b")))
      .expect(lastReply == Ok and lastEvents == Set(("b", Removed("a"))))
      .expect(friendsOf(s, "a") == Set() and friendsOf(s, "b") == Set())
      .then(apply("friend/remove", "b", "a", remove(s, "b", "a")))
      .expect(lastReply == Failed("not_in_friendlist") and lastEvents == Set())
      .expect(viewsInSync)

  // Mutual requests: the second request accepts the first; both get requestAccepted.
  // The reply/event order at b is "event first" here.
  run mutualRequestTest =
    init
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .then(applyOrdered("friend/sendRequest", "b", "a", sendRequest(s, "b", "a"), false))
      .expect(lastReply == Ok)
      .expect(lastEvents == Set(("a", RequestAccepted("b")), ("b", RequestAccepted("a"))))
      .expect(s.requests == Set() and friendsOf(s, "b") == Set("a"))
      .expect(views.get("b") == { friends: Set("a"), outgoing: Set(), incoming: Set() })
      .then(apply("friend/sendRequest", "b", "a", sendRequest(s, "b", "a")))
      .expect(lastReply == Failed("already_in_friendlist"))
      .expect(viewsInSync)

  // Reject, then cancel; repeating either is denied.
  run rejectCancelTest =
    init
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .then(apply("friend/rejectRequest", "b", "a", rejectRequest(s, "b", "a")))
      .expect(lastReply == Ok and lastEvents == Set(("a", RequestRejected("b"))))
      .expect(s.requests == Set() and friendsOf(s, "a") == Set())
      .then(apply("friend/rejectRequest", "b", "a", rejectRequest(s, "b", "a")))
      .expect(lastReply == Failed("no_pending_request"))
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .then(apply("friend/cancelRequest", "a", "b", cancelRequest(s, "a", "b")))
      .expect(lastReply == Ok and lastEvents == Set(("b", RequestCancelled("a"))))
      .then(apply("friend/cancelRequest", "a", "b", cancelRequest(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request"))     // FRIEND-09
      .expect(viewsInSync)

  // invalid_user (unknown id, self) for every command; duplicate request.
  run invalidUserTest =
    init
      .then(apply("friend/sendRequest", "a", "a", sendRequest(s, "a", "a")))
      .expect(lastReply == Failed("invalid_user"))
      .then(apply("friend/sendRequest", "a", "x", sendRequest(s, "a", "x")))
      .expect(lastReply == Failed("invalid_user"))
      .then(apply("friend/acceptRequest", "a", "x", acceptRequest(s, "a", "x")))
      .expect(lastReply == Failed("invalid_user"))
      .then(apply("friend/rejectRequest", "a", "a", rejectRequest(s, "a", "a")))
      .expect(lastReply == Failed("invalid_user"))
      .then(apply("friend/cancelRequest", "a", "x", cancelRequest(s, "a", "x")))
      .expect(lastReply == Failed("invalid_user"))
      .then(apply("friend/remove", "a", "a", remove(s, "a", "a")))
      .expect(lastReply == Failed("invalid_user"))
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request") and lastEvents == Set())   // FRIEND-06

  // Capacities (MAX_OUTGOING = 2, MAX_INCOMING = 1). A mutual request still
  // succeeds when the caller's outgoing set is full (FRIEND-07, FRIEND-11).
  run capacityTest =
    init
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .then(apply("friend/sendRequest", "a", "c", sendRequest(s, "a", "c")))
      .then(apply("friend/sendRequest", "a", "d", sendRequest(s, "a", "d")))
      .expect(lastReply == Failed("outgoing_capacity_reached"))
      .then(apply("friend/sendRequest", "d", "b", sendRequest(s, "d", "b")))
      .expect(lastReply == Failed("incoming_capacity_reached"))
      .then(apply("friend/sendRequest", "b", "c", sendRequest(s, "b", "c")))
      .expect(lastReply == Failed("incoming_capacity_reached"))   // c already has a's request
      .then(apply("friend/sendRequest", "b", "d", sendRequest(s, "b", "d")))
      .then(apply("friend/sendRequest", "d", "c", sendRequest(s, "d", "c")))
      .expect(lastReply == Failed("incoming_capacity_reached"))
      .then(apply("friend/sendRequest", "c", "b", sendRequest(s, "c", "b")))
      .expect(lastReply == Failed("incoming_capacity_reached"))   // b has a's request
      .then(apply("friend/sendRequest", "c", "a", sendRequest(s, "c", "a")))
      .expect(lastReply == Ok and friendsOf(s, "a") == Set("c"))  // auto-accept; a's outgoing was full
      .expect(outgoingOf(s, "a") == Set("b") and withinCapacity and viewsInSync)

  // No friend-list cap (FRIEND-04): a has 3 friends > MAX_OUTGOING = 2, and
  // can still receive and accept requests.
  run noFriendCapTest =
    init
      .then(apply("friend/sendRequest", "b", "a", sendRequest(s, "b", "a")))
      .then(apply("friend/acceptRequest", "a", "b", acceptRequest(s, "a", "b")))
      .then(apply("friend/sendRequest", "c", "a", sendRequest(s, "c", "a")))
      .then(apply("friend/acceptRequest", "a", "c", acceptRequest(s, "a", "c")))
      .then(apply("friend/sendRequest", "a", "d", sendRequest(s, "a", "d")))
      .then(apply("friend/acceptRequest", "d", "a", acceptRequest(s, "d", "a")))
      .expect(lastReply == Ok and fullFriendCircle and friendsOf(s, "a") == Set("b", "c", "d"))
      .then(apply("friend/remove", "d", "a", remove(s, "d", "a")))
      .expect(lastEvents == Set(("a", Removed("d"))) and viewsInSync)

  // Grace period: an event to a Detached user is dropped; the state comes
  // back with user/self at env/reconnect. Offline (session expired) users get
  // it at env/connect. Late/repeated session steps are no-ops.
  run presenceTest =
    init
      .then(apply("env/disconnect", "b", "b", disconnect(s, "b")))
      .then(apply("friend/sendRequest", "a", "b", sendRequest(s, "a", "b")))
      .expect(lastReply == Ok and lastEvents == Set() and eventLostInGrace)
      .then(apply("env/reconnect", "b", "b", reconnect(s, "b")))
      .expect(views.get("b").incoming == Set("a") and viewsInSync)   // via user/self
      .then(apply("env/disconnect", "a", "a", disconnect(s, "a")))
      .then(apply("env/sessionExpired", "a", "a", sessionExpired(s, "a")))
      .expect(s.presence.get("a") == Offline and outgoingOf(s, "a") == Set("b"))
      .then(apply("friend/acceptRequest", "b", "a", acceptRequest(s, "b", "a")))
      .expect(lastReply == Ok and lastEvents == Set() and eventDropped)
      .then(apply("env/sessionExpired", "a", "a", sessionExpired(s, "a")))  // late timer: no-op
      .expect(s == prevS)
      .then(apply("env/reconnect", "a", "a", reconnect(s, "a")))            // no session: no-op
      .expect(s == prevS)
      .then(apply("env/connect", "a", "a", connect(s, "a")))
      .expect(views.get("a") == { friends: Set("b"), outgoing: Set(), incoming: Set() })
      .then(apply("friend/list", "a", "a", list(s, "a")))
      .expect(listData(s, "a").friends == Set("b") and viewsInSync)
}

// Smaller instance for bounded model checking.
module friend3 {
  import friend(USERS = Set("a", "b", "c"), GHOST = "x",
                MAX_OUTGOING = 1, MAX_INCOMING = 1).*
}
