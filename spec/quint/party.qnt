// Party: party/create, party/invite, party/acceptInvite, party/declineInvite,
// party/cancelInvite, party/kickMember, party/leave and the events
// party/invited, party/updated, party/removed; plus environment steps for the
// invite timer, session presence (socket drop, reconnect, session grace
// expiry, fresh connect), the party crashing, and the matchmaking module
// putting a party in / taking it out of a queue.
// Source: tachyon docs/schema/party.md (generated from src/schema/party/*.ts).
// Grown from party_invites.qnt (the reference slice, kept unchanged).
// Findings: findings/party.md (PARTY-nn ids below).
//
// @test main=party3
// @inv main=party3 inv=safety steps=30 samples=20000
// @witness main=party3 inv=not(hit("party/create","created"))
// @witness main=party3 inv=not(hit("party/create","already_in_party"))
// @witness main=party3 inv=not(hit("party/invite","invited"))
// @witness main=party3 inv=not(hit("party/invite","not_in_party"))
// @witness main=party3 inv=not(hit("party/invite","target_not_connected"))
// @witness main=party3 inv=not(hit("party/invite","already_member_or_invited"))
// @witness main=party3 inv=not(hit("party/invite","party_in_matchmaking"))
// @witness main=party3 inv=not(hit("party/invite","party_full"))
// @witness main=party3 inv=not(hit("party/acceptInvite","joined"))
// @witness main=party3 inv=not(hit("party/acceptInvite","switched"))
// @witness main=party3 inv=not(hit("party/acceptInvite","not_invited"))
// @witness main=party3 inv=not(hit("party/declineInvite","declined"))
// @witness main=party3 inv=not(hit("party/declineInvite","not_invited"))
// @witness main=party3 inv=not(hit("party/cancelInvite","cancelled"))
// @witness main=party3 inv=not(hit("party/cancelInvite","not_in_party"))
// @witness main=party3 inv=not(hit("party/cancelInvite","not_invited"))
// @witness main=party3 inv=not(hit("party/kickMember","kicked"))
// @witness main=party3 inv=not(hit("party/kickMember","not_in_party"))
// @witness main=party3 inv=not(hit("party/kickMember","kick_self"))
// @witness main=party3 inv=not(hit("party/kickMember","target_not_member"))
// @witness main=party3 inv=not(hit("party/leave","left"))
// @witness main=party3 inv=not(hit("party/leave","disbanded"))
// @witness main=party3 inv=not(hit("party/leave","not_in_party_noop"))
// @witness main=party3 inv=not(hit("env/inviteTimeout","expired"))
// @witness main=party3 inv=not(hit("env/inviteTimeout","stale_timer_reinvited"))
// @witness main=party3 inv=not(hit("env/disconnect","detached"))
// @witness main=party3 inv=not(hit("env/reconnect","reattached"))
// @witness main=party3 inv=not(hit("env/sessionExpired","expired_session"))
// @witness main=party3 inv=not(hit("env/connect","connected"))
// @witness main=party3 inv=not(hit("env/partyQueued","queued"))
// @witness main=party3 inv=not(hit("env/partyUnqueued","unqueued"))
// @witness main=party3 inv=not(hit("env/partyCrashed","crashed"))
// @witness main=party3 inv=not(fullParty)
// @witness main=party3 inv=not(multiInvites)
// @witness main=party3 inv=not(memberAndInvited)
// @witness main=party3 inv=not(detachedViewStale)
// @witness main=party3 inv=not(queuedMemberLeft)
// @verify main=party2 inv=safety steps=3
module party {
  import common.* from "./common"

  // ---------------------------------------------------------------- vocabulary
  type PartyId = int

  // Session presence (owned by the user/system groups; modelled here because
  // the party rules depend on it). Detached = socket dropped, session still in
  // its grace period. ASSUMPTION PARTY-A1 (design default): party membership
  // and invites belong to the session, not the socket.
  type Presence = Online | Detached | Offline

  // `invited` maps each invitee to the generation of its invite, i.e. the
  // identity of that invite's timer (PARTY-05). `queued` is the party's
  // matchmaking status as told by the matchmaking module (PARTY-14).
  type Party = { members: Set[UserId], invited: UserId -> int, queued: bool }
  type State = {
    parties: PartyId -> Party,
    presence: UserId -> Presence,
    nextId: PartyId,
    nextInvite: int,
  }

  // PartyState as carried by party/updated, party/invited and the
  // party/create reply: id, members, invited (maxMembers is the constant
  // MAX_MEMBERS; joinedAt/invitedAt timestamps are abstracted away).
  type PartyView = { id: PartyId, members: Set[UserId], invited: Set[UserId] }

  // MatchmakingCancelled stands for matchmaking/cancelled{reason: party_user_left}
  // (matchmaking group): emitted here only to state the cross-module rule.
  type Event =
    | Invited(PartyView)     // party/invited
    | Updated(PartyView)     // party/updated
    | Removed(PartyId)       // party/removed
    | MatchmakingCancelled   // matchmaking/cancelled, reason party_user_left

  // `why` names the branch taken (for transcripts and coverage witnesses only;
  // it is not on the wire).
  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)], why: str }

  // What a client knows: the party it is in (at most one entry) and the
  // parties it is invited to -- i.e. user/self's `party` and `invitedToParties`.
  type View = { party: PartyId -> PartyView, invites: PartyId -> PartyView }

  // An intermediate effect: new state and events, composed by the commands.
  type Eff = { st: State, ev: Set[(UserId, Event)] }

  const USERS: Set[UserId]
  // "Parties have a maximum player count of `maxMembers`, defined by the Tachyon server."
  const MAX_MEMBERS: int

  // ------------------------------------------------------------------ helpers
  pure def online(s: State, us: Set[UserId]): Set[UserId] =
    us.filter(u => s.presence.get(u) == Online)
  // "... propagated with a party/updated event sent to all connected members
  // and invited players": events only reach users whose socket is up.
  pure def sendOn(s: State, us: Set[UserId], e: Event): Set[(UserId, Event)] =
    send(online(s, us), e)
  pure def partiesOf(s: State, u: UserId): Set[PartyId] =
    s.parties.keys().filter(id => u.in(s.parties.get(id).members))
  pure def invitesOf(s: State, u: UserId): Set[PartyId] =
    s.parties.keys().filter(id => u.in(s.parties.get(id).invited.keys()))
  pure def theParty(s: State, u: UserId): PartyId = theOne(partiesOf(s, u), -1)
  pure def audience(p: Party): Set[UserId] = p.members.union(p.invited.keys())
  pure def view(s: State, id: PartyId): PartyView = {
    val p = s.parties.get(id)
    { id: id, members: p.members, invited: p.invited.keys() }
  }
  // The server's truth projected for one user (what user/self would carry).
  pure def serverView(s: State, u: UserId): View = {
    party: partiesOf(s, u).mapBy(id => view(s, id)),
    invites: invitesOf(s, u).mapBy(id => view(s, id)),
  }
  pure val emptyView: View = { party: Map(), invites: Map() }
  pure def withParty(s: State, id: PartyId, p: Party): State =
    { ...s, parties: s.parties.set(id, p) }

  pure def deny(s: State, reason: str, why: str): Outcome =
    { state: s, reply: Failed(reason), events: Set(), why: why }
  pure def okWith(e: Eff, why: str): Outcome =
    { state: e.st, reply: Ok, events: e.ev, why: why }
  pure def envWith(e: Eff, why: str): Outcome =
    { state: e.st, reply: NoReply, events: e.ev, why: why }
  pure def noop(s: State, why: str): Outcome =
    { state: s, reply: NoReply, events: Set(), why: why }

  // party/updated with the state after the step, to every connected member
  // and invitee of party `id` except `except`.
  pure def notify(s: State, id: PartyId, except: Set[UserId]): Set[(UserId, Event)] =
    sendOn(s, audience(s.parties.get(id)).exclude(except), Updated(view(s, id)))

  // Member `u` stops being a member of party `id` (leave, kick, switching
  // party on accept, session end).
  // "When the last member of a party leaves, the party is disbanded."
  // "[party/removed] can happen ... when the party dies (crash or last member leaves)"
  //   -> on disband the remaining invitees get party/removed.
  // matchmaking: "It can happen for example when a party member leaves";
  // party_user_left: "a member of the player's party left matchmaking, thus
  // forcing the entire party to withdraw" -> a queued party is unqueued and
  // every connected member (old membership) gets matchmaking/cancelled.
  // `removedToU`: whether `u` itself is told with party/removed (only on kick:
  // "when the player is kicked out from the party"; PARTY-04).
  pure def removeMember(s: State, id: PartyId, u: UserId, removedToU: bool): Eff = {
    val p = s.parties.get(id)
    val rest = p.members.exclude(Set(u))
    val mm = if (p.queued) sendOn(s, p.members, MatchmakingCancelled) else Set()
    val toU = if (removedToU) sendOn(s, Set(u), Removed(id)) else Set()
    if (rest == Set()) {
      val s2 = { ...s, parties: mapRemove(s.parties, id) }
      { st: s2, ev: sendOn(s, p.invited.keys(), Removed(id)).union(mm).union(toU) }
    } else {
      val s2 = withParty(s, id, { ...p, members: rest, queued: false })
      { st: s2, ev: notify(s2, id, Set()).union(mm).union(toU) }
    }
  }

  // Invite of `t` to party `id` disappears (decline, cancel, timeout, session
  // end). "Any change to the party member or the pending invites is
  // propagated with a party/updated event sent to all connected members and
  // invited players." `removedToT`: "[party/removed] can happen when the
  // invite is cancelled or times out".
  pure def dropInvite(s: State, id: PartyId, t: UserId, removedToT: bool): Eff = {
    val p = s.parties.get(id)
    val s2 = withParty(s, id, { ...p, invited: mapRemove(p.invited, t) })
    val toT = if (removedToT) sendOn(s2, Set(t), Removed(id)) else Set()
    { st: s2, ev: notify(s2, id, Set()).union(toT) }
  }

  // ------------------------------------------------------------ requests
  // Requests can only come from a connected user (guarded in `step`).

  // party/create: "Create a party." Reply data `party: PartyState`.
  // "A player can only be in at most one party at any given time."
  // ASSUMPTION PARTY-A3: pending invites the creator holds are kept.
  pure def create(s: State, u: UserId): Outcome =
    if (partiesOf(s, u) != Set()) deny(s, "invalid_request", "already_in_party")   // PARTY-01
    else okWith({
      st: { ...s, parties: s.parties.put(s.nextId, { members: Set(u), invited: Map(), queued: false }),
                  nextId: s.nextId + 1 },
      ev: Set() }, "created")

  // party/invite: "invite the target player to your current party"
  // "Any player in a party can invite any other connected player with
  // party/invite. If the party is at capacity, sending an invite will fail."
  // "All current members and pending invitations count towards the limit."
  // party/invited: "Sent to the invited player and all party members."
  //   CONTRADICTION PARTY-02 with "Any change to ... the pending invites is
  //   propagated with a party/updated event sent to all connected members and
  //   invited players": the model sends party/invited to the target and
  //   party/updated to the others (as teiserver does).
  // ASSUMPTION PARTY-A2: "connected" = socket up (Online); teiserver also
  // accepts a target whose session is in grace (PARTY-07).
  // ASSUMPTION PARTY-14: no invite while the party is queued (teiserver).
  pure def invite(s: State, u: UserId, t: UserId): Outcome =
    if (partiesOf(s, u) == Set()) deny(s, "invalid_request", "not_in_party")      // PARTY-01
    else {
      val id = theParty(s, u)
      val p = s.parties.get(id)
      if (s.presence.get(t) != Online) deny(s, "invalid_request", "target_not_connected")
      else if (t.in(audience(p))) deny(s, "invalid_request", "already_member_or_invited")
      else if (p.queued) deny(s, "invalid_request", "party_in_matchmaking")
      else if (p.members.size() + p.invited.keys().size() >= MAX_MEMBERS)
        deny(s, "invalid_request", "party_full")
      else {
        val s2 = { ...withParty(s, id, { ...p, invited: p.invited.put(t, s.nextInvite) }),
                   nextInvite: s.nextInvite + 1 }
        okWith({ st: s2,
                 ev: sendOn(s2, Set(t), Invited(view(s2, id))).union(notify(s2, id, Set(t))) },
               "invited")
      }
    }

  // party/acceptInvite: "Accept the invite to the party"
  // ASSUMPTION PARTY-03: accepting while in another party first leaves that
  // party (as teiserver does; the reference slice denied). The old party's
  // audience is told (party/updated, or party/removed to its invitees if it
  // disbands); the accepter learns it from the Ok reply (no party/removed).
  // Other pending invites of the accepter are kept (PARTY-09).
  pure def accept(s: State, u: UserId, id: PartyId): Outcome =
    if (not(id.in(s.parties.keys())) or not(u.in(s.parties.get(id).invited.keys())))
      deny(s, "invalid_request", "not_invited")                                   // PARTY-01
    else {
      val wasIn = partiesOf(s, u) != Set()
      val left: Eff = if (wasIn) removeMember(s, theParty(s, u), u, false) else { st: s, ev: Set() }
      val p = left.st.parties.get(id)
      val s2 = withParty(left.st, id,
                 { ...p, members: p.members.union(Set(u)), invited: mapRemove(p.invited, u) })
      okWith({ st: s2, ev: left.ev.union(notify(s2, id, Set())) },
             if (wasIn) "switched" else "joined")
    }

  // party/declineInvite: "Decline the invite to a party". The decliner learns
  // from the reply; the others get party/updated.
  pure def decline(s: State, u: UserId, id: PartyId): Outcome =
    if (not(id.in(s.parties.keys())) or not(u.in(s.parties.get(id).invited.keys())))
      deny(s, "invalid_request", "not_invited")
    else okWith(dropInvite(s, id, u, false), "declined")

  // party/cancelInvite: "cancel a pending invite for the given player"
  // "Any pending invite can be cancelled by any member in the party"
  // Reasons not_in_party / invalid_invite are in the schema (teiserver sends
  // invalid_request for both: PARTY-06).
  pure def cancel(s: State, u: UserId, t: UserId): Outcome =
    if (partiesOf(s, u) == Set()) deny(s, "not_in_party", "not_in_party")
    else {
      val id = theParty(s, u)
      if (not(t.in(s.parties.get(id).invited.keys()))) deny(s, "invalid_invite", "not_invited")
      else okWith(dropInvite(s, id, t, true), "cancelled")
    }

  // party/kickMember: "Kick the target player from the party"
  // "Any member in a party can kick any other member" -- ASSUMPTION PARTY-08:
  // self-kick is denied (teiserver accepts it and can leave a zombie party);
  // an invitee is not a valid target (teiserver test "invited player is not
  // valid target").
  pure def kick(s: State, u: UserId, t: UserId): Outcome =
    if (partiesOf(s, u) == Set()) deny(s, "invalid_request", "not_in_party")
    else if (t == u) deny(s, "invalid_request", "kick_self")
    else {
      val id = theParty(s, u)
      if (not(t.in(s.parties.get(id).members))) deny(s, "invalid_request", "target_not_member")
      else okWith(removeMember(s, id, t, true), "kicked")
    }

  // party/leave: "Leave the party"
  // src/schema/party/leave.ts: "no failed/not_in_party status. Calling this
  // request while not in a party is a no-op" -> Ok, nothing changes (PARTY-10).
  // party/removed is not sent to the leaver (PARTY-04).
  pure def leave(s: State, u: UserId): Outcome =
    if (partiesOf(s, u) == Set()) { state: s, reply: Ok, events: Set(), why: "not_in_party_noop" }
    else {
      val id = theParty(s, u)
      val e = removeMember(s, id, u, false)
      okWith(e, if (id.in(e.st.parties.keys())) "left" else "disbanded")
    }

  // ------------------------------------------------------- environment steps
  // "Invites will time out after a while." The timer of invite generation
  // `gen` fires. A late fire (invite already gone) or a fire of an older
  // invite's timer after a re-invite is a no-op (PARTY-05).
  pure def inviteTimeout(s: State, id: PartyId, t: UserId, gen: int): Outcome =
    if (not(id.in(s.parties.keys())) or not(t.in(s.parties.get(id).invited.keys())))
      noop(s, "late_timer")
    else if (s.parties.get(id).invited.get(t) != gen) noop(s, "stale_timer_reinvited")
    else envWith(dropInvite(s, id, t, true), "expired")

  // Socket drops; the session (and its party/invites) survives (PARTY-A1).
  // Nobody is told by the party module.
  pure def disconnect(s: State, u: UserId): Outcome =
    if (s.presence.get(u) != Online) noop(s, "not_online")
    else envWith({ st: { ...s, presence: s.presence.set(u, Detached) }, ev: Set() }, "detached")

  // A new connection reattaches the session. "After reconnect the server
  // sends full state following user/self" (user group): the client view is
  // reset from user/self's `party` and `invitedToParties`.
  pure def reconnect(s: State, u: UserId): Outcome =
    if (s.presence.get(u) != Detached) noop(s, "not_detached")
    else envWith({ st: { ...s, presence: s.presence.set(u, Online) }, ev: Set() }, "reattached")

  // The session grace period expires (or system/disconnect ends the session):
  // the user leaves its party and all its invites disappear.
  pure def sessionExpired(s: State, u: UserId): Outcome =
    if (s.presence.get(u) != Detached) noop(s, "not_detached")
    else {
      val s0 = { ...s, presence: s.presence.set(u, Offline) }
      val e = s0.parties.keys().fold({ st: s0, ev: Set() }, (acc, id) =>
        if (not(id.in(acc.st.parties.keys()))) acc
        else if (u.in(acc.st.parties.get(id).members)) {
          val r = removeMember(acc.st, id, u, false)
          { st: r.st, ev: acc.ev.union(r.ev) }
        } else if (u.in(acc.st.parties.get(id).invited.keys())) {
          val r = dropInvite(acc.st, id, u, false)
          { st: r.st, ev: acc.ev.union(r.ev) }
        } else acc)
      envWith(e, "expired_session")
    }

  // A fresh session starts (user/self: party null, no invites).
  pure def connect(s: State, u: UserId): Outcome =
    if (s.presence.get(u) != Offline) noop(s, "has_session")
    else envWith({ st: { ...s, presence: s.presence.set(u, Online) }, ev: Set() }, "connected")

  // The matchmaking module put the party in a queue (a member's
  // matchmaking/queue succeeded). ASSUMPTION PARTY-14 (teiserver): pending
  // invites are cancelled (party/removed to invitees, party/updated to members).
  pure def partyQueued(s: State, id: PartyId): Outcome =
    if (not(id.in(s.parties.keys())) or s.parties.get(id).queued) noop(s, "not_applicable")
    else {
      val p = s.parties.get(id)
      val s2 = withParty(s, id, { ...p, invited: Map(), queued: true })
      val upd = if (p.invited.keys() == Set()) Set() else notify(s2, id, Set())
      envWith({ st: s2, ev: sendOn(s, p.invited.keys(), Removed(id)).union(upd) }, "queued")
    }

  // The matchmaking module says the party is no longer queued (cancel, match
  // found, ready timeout...). The matchmaking events are that module's.
  pure def partyUnqueued(s: State, id: PartyId): Outcome =
    if (not(id.in(s.parties.keys())) or not(s.parties.get(id).queued)) noop(s, "not_applicable")
    else envWith({ st: withParty(s, id, { ...s.parties.get(id), queued: false }), ev: Set() }, "unqueued")

  // "[party/removed can happen] when the party dies (crash ...)": every
  // connected member and invitee gets party/removed.
  pure def partyCrashed(s: State, id: PartyId): Outcome =
    if (not(id.in(s.parties.keys()))) noop(s, "not_applicable")
    else envWith({ st: { ...s, parties: mapRemove(s.parties, id) },
                   ev: sendOn(s, audience(s.parties.get(id)), Removed(id)) }, "crashed")

  // ----------------------------------------------------------- client model
  // How a client following Tachyon updates its view from an event.
  pure def onEvent(u: UserId, v: View, e: Event): View = match e {
    | Invited(pv) => { ...v, invites: v.invites.put(pv.id, pv) }
    | Updated(pv) =>
        if (u.in(pv.members)) { party: Map(pv.id -> pv), invites: mapRemove(v.invites, pv.id) }
        else if (u.in(pv.invited)) { ...v, invites: v.invites.put(pv.id, pv) }
        else v
    | Removed(id) => { party: mapRemove(v.party, id), invites: mapRemove(v.invites, id) }
    | MatchmakingCancelled => v
  }
  // ... and from the reply to its own request (applied before the events).
  pure def onReply(u: UserId, cmd: str, pid: PartyId, r: Reply, s2: State, v: View): View =
    if (r != Ok) v
    else if (cmd == "party/create") { ...v, party: partiesOf(s2, u).mapBy(id => view(s2, id)) }
    else if (cmd == "party/leave" or cmd == "party/acceptInvite") { ...v, party: Map() }
    else if (cmd == "party/declineInvite") { ...v, invites: mapRemove(v.invites, pid) }
    else v
  pure def deliver(u: UserId, v: View, evs: Set[(UserId, Event)]): View =
    evs.filter(m => m._1 == u).fold(v, (acc, m) => onEvent(u, acc, m._2))

  // ---------------------------------------------------------- state machine
  var s: State
  var prev: State
  var lastCmd: str
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]
  var lastWhy: str
  var views: UserId -> View

  // `caller` is the requesting user, or the user an env step is about.
  action apply(cmd: str, caller: UserId, pid: PartyId, o: Outcome): bool = all {
    prev' = s, s' = o.state, lastCmd' = cmd, lastReply' = o.reply,
    lastEvents' = o.events, lastWhy' = o.why,
    views' = USERS.mapBy(u =>
      if (u == caller and o.why == "reattached") serverView(o.state, u)        // user/self
      else if (u == caller and o.why == "connected") serverView(o.state, u)    // user/self
      else if (u == caller and o.why == "expired_session") emptyView
      else {
        val v0 = if (u == caller) onReply(u, cmd, pid, o.reply, o.state, views.get(u)) else views.get(u)
        deliver(u, v0, o.events)
      }),
  }

  pure def initState: State =
    { parties: Map(), presence: USERS.mapBy(_ => Online), nextId: 0, nextInvite: 0 }
  action init = all {
    s' = initState, prev' = initState,
    lastCmd' = "init", lastReply' = NoReply, lastEvents' = Set(), lastWhy' = "init",
    views' = USERS.mapBy(_ => emptyView),
  }
  def isOnline(u: UserId): bool = s.presence.get(u) == Online
  action step = {
    nondet u = USERS.oneOf()
    nondet t = USERS.oneOf()
    nondet id = s.parties.keys().union(Set(s.nextId)).oneOf()
    nondet gen = 0.to(s.nextInvite).oneOf()
    any {
      all { isOnline(u), apply("party/create", u, id, create(s, u)) },
      all { isOnline(u), apply("party/invite", u, id, invite(s, u, t)) },
      all { isOnline(u), apply("party/acceptInvite", u, id, accept(s, u, id)) },
      all { isOnline(u), apply("party/declineInvite", u, id, decline(s, u, id)) },
      all { isOnline(u), apply("party/cancelInvite", u, id, cancel(s, u, t)) },
      all { isOnline(u), apply("party/kickMember", u, id, kick(s, u, t)) },
      all { isOnline(u), apply("party/leave", u, id, leave(s, u)) },
      apply("env/inviteTimeout", t, id, inviteTimeout(s, id, t, gen)),
      apply("env/disconnect", u, id, disconnect(s, u)),
      apply("env/reconnect", u, id, reconnect(s, u)),
      apply("env/sessionExpired", u, id, sessionExpired(s, u)),
      apply("env/connect", u, id, connect(s, u)),
      apply("env/partyQueued", u, id, partyQueued(s, id)),
      apply("env/partyUnqueued", u, id, partyUnqueued(s, id)),
      apply("env/partyCrashed", u, id, partyCrashed(s, id)),
    }
  }

  // --------------------------------------------------------------- properties
  // "A player can only be in at most one party at any given time."
  val atMostOneParty = USERS.forall(u => partiesOf(s, u).size() <= 1)

  // Members non-empty (disband), members and invitees disjoint, the limit
  // counts both, a queued party has no invites, invite timers are known.
  val wellFormed = s.parties.keys().forall(id => {
    val p = s.parties.get(id)
    and {
      p.members != Set(),
      p.members.intersect(p.invited.keys()) == Set(),
      p.members.size() + p.invited.keys().size() <= MAX_MEMBERS,
      p.queued implies p.invited.keys() == Set(),
      p.invited.keys().forall(t => p.invited.get(t) < s.nextInvite),
    }
  })

  // Membership and invites belong to a live session (PARTY-A1).
  val sessionsOwnParties = s.parties.keys().forall(id =>
    audience(s.parties.get(id)).forall(u => s.presence.get(u) != Offline))

  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  // Denials change nothing and send nothing.
  val deniedIsInert = match lastReply {
    | Failed(_) => lastEvents == Set() and s == prev
    | _ => true
  }

  // "sent to all connected members and invited players": no event to a
  // detached or offline user.
  val eventsReachConnectedOnly = lastEvents.forall(m => s.presence.get(m._1) == Online)

  // party/updated and party/invited carry the party state after the step and
  // reach only its members/invitees; party/removed reaches only users no
  // longer in that party's audience.
  val eventPayloadsAreCurrent = lastEvents.forall(m => match m._2 {
    | Updated(pv) => and { pv.id.in(s.parties.keys()), m._1.in(audience(s.parties.get(pv.id))),
                           pv == view(s, pv.id) }
    | Invited(pv) => and { pv.id.in(s.parties.keys()), m._1.in(s.parties.get(pv.id).invited.keys()),
                           pv == view(s, pv.id) }
    | Removed(id) => not(id.in(s.parties.keys())) or not(m._1.in(audience(s.parties.get(id))))
    | MatchmakingCancelled => true
  })

  // At most one party event per (recipient, party) per step, so the order in
  // which a client applies a step's events does not matter.
  pure def partyOfEvent(e: Event): PartyId = match e {
    | Invited(pv) => pv.id
    | Updated(pv) => pv.id
    | Removed(id) => id
    | MatchmakingCancelled => -1
  }
  val oneEventPerPartyAndRecipient = lastEvents.forall(m1 => lastEvents.forall(m2 =>
    (m1._1 == m2._1 and partyOfEvent(m1._2) == partyOfEvent(m2._2)) implies m1 == m2))

  // Client view property: every connected user's view (built from replies,
  // party events, and user/self on (re)connect) equals the server state.
  // In particular, each member's view after its last party/updated equals the
  // party's server state.
  val clientViewsAgree = USERS.forall(u => isOnline(u) implies views.get(u) == serverView(s, u))

  // Cross-module (matchmaking): a queued party's membership never changes
  // while it stays queued; when a queued party's membership changes, every
  // connected old member gets matchmaking/cancelled (party_user_left).
  val queuedMembershipStable = s.parties.keys().forall(id =>
    s.parties.get(id).queued implies
      (id.in(prev.parties.keys()) and prev.parties.get(id).members == s.parties.get(id).members))
  val queuedChangeCancels = prev.parties.keys().forall(id => {
    val p = prev.parties.get(id)
    val changed = not(id.in(s.parties.keys())) or s.parties.get(id).members != p.members
    val cancelled = online(s, p.members).forall(m => (m, MatchmakingCancelled).in(lastEvents))
    (p.queued and changed and lastCmd != "env/partyCrashed") implies cancelled
  })

  val safety = and {
    atMostOneParty, wellFormed, sessionsOwnParties, reasonsInSchema, deniedIsInert,
    eventsReachConnectedOnly, eventPayloadsAreCurrent, oneEventPerPartyAndRecipient,
    clientViewsAgree, queuedMembershipStable, queuedChangeCancels,
  }

  // ------------------------------------------------------ witnesses (@witness)
  def hit(cmd: str, why: str): bool = lastCmd == cmd and lastWhy == why
  val fullParty = s.parties.keys().exists(id => s.parties.get(id).members.size() == MAX_MEMBERS)
  // PARTY-09: a user may hold invites to several parties at once ...
  val multiInvites = USERS.exists(u => invitesOf(s, u).size() >= 2)
  // ... and be invited while being a member of another party.
  val memberAndInvited = USERS.exists(u => partiesOf(s, u) != Set() and invitesOf(s, u) != Set())
  // A detached user's view goes stale (repaired by user/self on reconnect).
  val detachedViewStale = USERS.exists(u => s.presence.get(u) == Detached and views.get(u) != serverView(s, u))
  val queuedMemberLeft = lastEvents.exists(m => m._2 == MatchmakingCancelled)
}

// Small instance for transcripts, simulation and witnesses.
module party3 {
  import common.* from "./common"
  import party(USERS = Set("a", "b", "c"), MAX_MEMBERS = 2).*

  pure def pv(id: PartyId, ms: Set[UserId], inv: Set[UserId]): PartyView =
    { id: id, members: ms, invited: inv }

  // Reviewed transcript (from the reference slice, adapted): invite, the
  // limit, accept, leave, disband.
  run inviteAcceptLeaveTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .expect(lastReply == Ok and views.get("a").party == Map(0 -> pv(0, Set("a"), Set())))
      .then(apply("party/create", "a", 0, create(s, "a")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "already_in_party")
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      // b gets party/invited, a (member) gets party/updated  (PARTY-02)
      .expect(lastEvents == Set(("b", Invited(pv(0, Set("a"), Set("b")))),
                                ("a", Updated(pv(0, Set("a"), Set("b"))))))
      .then(apply("party/invite", "a", 0, invite(s, "a", "c")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "party_full")   // 1 member + 1 invite = limit
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .expect(lastWhy == "already_member_or_invited")
      .then(apply("party/invite", "c", 0, invite(s, "c", "a")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "not_in_party")
      .then(apply("party/acceptInvite", "b", 0, accept(s, "b", 0)))
      .expect(lastEvents == Set(("a", Updated(pv(0, Set("a", "b"), Set()))),
                                ("b", Updated(pv(0, Set("a", "b"), Set())))))
      .then(apply("party/acceptInvite", "b", 0, accept(s, "b", 0)))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "not_invited")
      .then(apply("party/leave", "a", 0, leave(s, "a")))
      // no party/removed to the leaver (PARTY-04)
      .expect(lastReply == Ok and lastEvents == Set(("b", Updated(pv(0, Set("b"), Set())))))
      .then(apply("party/leave", "b", 0, leave(s, "b")))
      .expect(lastWhy == "disbanded" and s.parties.keys() == Set() and lastEvents == Set())
      .then(apply("party/leave", "b", 0, leave(s, "b")))
      .expect(lastReply == Ok and lastWhy == "not_in_party_noop")                  // PARTY-10
      .expect(clientViewsAgree)

  // Disbanding with pending invites: invitees get party/removed.
  run disbandNotifiesInviteesTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/leave", "a", 0, leave(s, "a")))
      .expect(lastWhy == "disbanded" and lastEvents == Set(("b", Removed(0))))
      .expect(views.get("b") == emptyView and clientViewsAgree)

  // Invite timer: fires once; a late fire is a no-op; the timer of an older
  // invite does not expire a newer invite of the same user (PARTY-05).
  run lateTimerTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))                 // invite gen 0
      .then(apply("env/inviteTimeout", "b", 0, inviteTimeout(s, 0, "b", 0)))
      .expect(lastEvents == Set(("b", Removed(0)), ("a", Updated(pv(0, Set("a"), Set())))))
      .then(apply("env/inviteTimeout", "b", 0, inviteTimeout(s, 0, "b", 0)))
      .expect(lastEvents == Set() and lastWhy == "late_timer")
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))                 // invite gen 1
      .then(apply("party/declineInvite", "b", 0, decline(s, "b", 0)))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))                 // invite gen 2
      .then(apply("env/inviteTimeout", "b", 0, inviteTimeout(s, 0, "b", 1)))   // old timer
      .expect(lastWhy == "stale_timer_reinvited" and s.parties.get(0).invited.keys() == Set("b"))
      .then(apply("env/inviteTimeout", "b", 0, inviteTimeout(s, 0, "b", 2)))
      .expect(lastWhy == "expired" and clientViewsAgree)

  // Timeout reaches the other invitees too (party/updated to invitees).
  run timeoutUpdatesOtherInviteesTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "c")))
      .expect(lastReply == Failed("invalid_request"))                           // MAX_MEMBERS = 2
      .then(apply("party/cancelInvite", "a", 0, cancel(s, "a", "b")))
      .expect(lastEvents == Set(("b", Removed(0)), ("a", Updated(pv(0, Set("a"), Set())))))
      .expect(clientViewsAgree)

  run declineTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/declineInvite", "b", 0, decline(s, "b", 0)))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "not_invited")
      .then(apply("party/declineInvite", "b", 7, decline(s, "b", 7)))           // no such party
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/declineInvite", "b", 0, decline(s, "b", 0)))
      // decliner learns from the reply; no party/removed to it
      .expect(lastReply == Ok and lastEvents == Set(("a", Updated(pv(0, Set("a"), Set())))))
      .expect(views.get("b") == emptyView and clientViewsAgree)

  run cancelInviteTest =
    init
      .then(apply("party/cancelInvite", "a", 0, cancel(s, "a", "b")))
      .expect(lastReply == Failed("not_in_party"))
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/cancelInvite", "a", 0, cancel(s, "a", "b")))
      .expect(lastReply == Failed("invalid_invite"))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      // the invitee itself is not a member: cannot cancel
      .then(apply("party/cancelInvite", "b", 0, cancel(s, "b", "b")))
      .expect(lastReply == Failed("not_in_party"))
      .then(apply("party/cancelInvite", "a", 0, cancel(s, "a", "b")))
      .expect(lastReply == Ok and lastEvents == Set(("b", Removed(0)), ("a", Updated(pv(0, Set("a"), Set())))))
      .then(apply("party/acceptInvite", "b", 0, accept(s, "b", 0)))
      .expect(lastReply == Failed("invalid_request"))
      .expect(clientViewsAgree)

  run kickTest =
    init
      .then(apply("party/kickMember", "a", 0, kick(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "not_in_party")
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/kickMember", "a", 0, kick(s, "a", "a")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "kick_self")   // PARTY-08
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/kickMember", "a", 0, kick(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "target_not_member")
      .then(apply("party/acceptInvite", "b", 0, accept(s, "b", 0)))
      // the newest member may kick the founder: no leader (PARTY-11)
      .then(apply("party/kickMember", "b", 0, kick(s, "b", "a")))
      .expect(lastReply == Ok and lastEvents == Set(("a", Removed(0)), ("b", Updated(pv(0, Set("b"), Set())))))
      .expect(clientViewsAgree)

  // Accepting while in another party: leave it first (PARTY-03); other
  // invites are kept (PARTY-09).
  run acceptSwitchesPartyTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/create", "b", 1, create(s, "b")))
      .then(apply("party/invite", "b", 1, invite(s, "b", "c")))
      .then(apply("party/create", "c", 2, create(s, "c")))                    // c: member of 2, invited to 1
      .then(apply("party/invite", "a", 0, invite(s, "a", "c")))               // c: invited to 0 and 1
      .expect(invitesOf(s, "c") == Set(0, 1) and multiInvites and memberAndInvited)
      .then(apply("party/acceptInvite", "c", 0, accept(s, "c", 0)))
      // party 2 disbands silently (no invitees); party 0 gets c
      .expect(lastWhy == "switched" and not(2.in(s.parties.keys())))
      .expect(lastEvents == Set(("a", Updated(pv(0, Set("a", "c"), Set()))),
                                ("c", Updated(pv(0, Set("a", "c"), Set())))))
      .expect(invitesOf(s, "c") == Set(1) and clientViewsAgree)
      .then(apply("party/acceptInvite", "c", 1, accept(s, "c", 1)))
      .expect(lastEvents == Set(("a", Updated(pv(0, Set("a"), Set()))),
                                ("b", Updated(pv(1, Set("b", "c"), Set()))),
                                ("c", Updated(pv(1, Set("b", "c"), Set())))))
      .expect(clientViewsAgree)

  // Session presence: invite needs a connected target; a detached member
  // keeps its membership, misses events, and is resynced by user/self; grace
  // expiry removes it.
  run presenceTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("env/disconnect", "b", 0, disconnect(s, "b")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "target_not_connected")  // PARTY-07
      .then(apply("env/reconnect", "b", 0, reconnect(s, "b")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/acceptInvite", "b", 0, accept(s, "b", 0)))
      .then(apply("env/disconnect", "b", 0, disconnect(s, "b")))
      .expect(partiesOf(s, "b") == Set(0))                                     // membership survives
      .then(apply("party/kickMember", "a", 0, kick(s, "a", "b")))
      .expect(lastEvents == Set(("a", Updated(pv(0, Set("a"), Set())))))       // b missed party/removed
      .expect(detachedViewStale)
      .then(apply("env/reconnect", "b", 0, reconnect(s, "b")))
      .expect(views.get("b") == emptyView and clientViewsAgree)               // user/self repairs it
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/acceptInvite", "b", 0, accept(s, "b", 0)))
      .then(apply("env/disconnect", "b", 0, disconnect(s, "b")))
      .then(apply("env/sessionExpired", "b", 0, sessionExpired(s, "b")))
      .expect(lastEvents == Set(("a", Updated(pv(0, Set("a"), Set())))))
      .then(apply("env/connect", "b", 0, connect(s, "b")))
      .expect(views.get("b") == emptyView and clientViewsAgree)

  // Session expiry of an invitee drops the invite; expiry of the last
  // member disbands and tells the invitees.
  run sessionExpiryTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("env/disconnect", "b", 0, disconnect(s, "b")))
      .then(apply("env/sessionExpired", "b", 0, sessionExpired(s, "b")))
      .expect(lastEvents == Set(("a", Updated(pv(0, Set("a"), Set())))))
      .then(apply("env/connect", "b", 0, connect(s, "b")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("env/disconnect", "a", 0, disconnect(s, "a")))
      .then(apply("env/sessionExpired", "a", 0, sessionExpired(s, "a")))
      .expect(s.parties.keys() == Set() and lastEvents == Set(("b", Removed(0))))
      .expect(clientViewsAgree)

  // Matchmaking interface: queueing cancels invites and locks the party; a
  // membership change unqueues it and cancels matchmaking for all members.
  run matchmakingTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("env/partyQueued", "a", 0, partyQueued(s, 0)))
      .expect(lastEvents == Set(("b", Removed(0)), ("a", Updated(pv(0, Set("a"), Set())))))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "party_in_matchmaking")
      .then(apply("env/partyUnqueued", "a", 0, partyUnqueued(s, 0)))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/acceptInvite", "b", 0, accept(s, "b", 0)))
      .then(apply("env/partyQueued", "a", 0, partyQueued(s, 0)))
      .expect(lastEvents == Set())                                             // no invites to cancel
      .then(apply("party/leave", "b", 0, leave(s, "b")))
      .expect(lastEvents == Set(("a", Updated(pv(0, Set("a"), Set()))),
                                ("a", MatchmakingCancelled), ("b", MatchmakingCancelled)))
      .expect(not(s.parties.get(0).queued) and queuedChangeCancels)

  run crashTest =
    init
      .then(apply("party/create", "a", 0, create(s, "a")))
      .then(apply("party/invite", "a", 0, invite(s, "a", "b")))
      .then(apply("party/create", "b", 1, create(s, "b")))
      .then(apply("env/partyCrashed", "a", 0, partyCrashed(s, 0)))
      .expect(lastEvents == Set(("a", Removed(0)), ("b", Removed(0))))
      .expect(partiesOf(s, "b") == Set(1) and clientViewsAgree)
}

// Smaller instance for bounded model checking.
module party2 {
  import common.* from "./common"
  import party(USERS = Set("a", "b"), MAX_MEMBERS = 2).*
}
