// Party invites: party/create, party/invite, party/acceptInvite, party/leave
// @test main=party3
// @inv main=party3 inv=safety steps=30 samples=20000
// @witness main=party3 inv=not(fullParty)
// @verify main=party3 inv=safety steps=4
// and the invite timeout. Source: tachyon docs/schema/party.md
module party {
  type UserId = str
  type PartyId = int
  type Party = { members: Set[UserId], invited: Set[UserId] }
  type State = { parties: PartyId -> Party, nextId: PartyId }
  type Reply = Ok | Failed(str) | NoReply
  // Updated and Invited carry the party state after the step.
  type Event = Updated(PartyId) | Invited(PartyId) | Removed(PartyId)
  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)] }

  const USERS: Set[UserId]
  const MAX_MEMBERS: int

  pure def partiesOf(s: State, u: UserId): Set[PartyId] =
    s.parties.keys().filter(id => u.in(s.parties.get(id).members))
  pure def deny(s: State, reason: str): Outcome =
    { state: s, reply: Failed(reason), events: Set() }
  pure def send(us: Set[UserId], e: Event): Set[(UserId, Event)] = us.map(u => (u, e))
  pure def withParty(s: State, id: PartyId, p: Party): State =
    { ...s, parties: s.parties.set(id, p) }

  // "A player can only be in at most one party at any given time."
  pure def create(s: State, u: UserId): Outcome =
    if (partiesOf(s, u) != Set()) deny(s, "invalid_request")
    else {
      state: { parties: s.parties.put(s.nextId, { members: Set(u), invited: Set() }),
               nextId: s.nextId + 1 },
      reply: Ok, events: Set() }

  // "All current members and pending invitations count towards the limit."
  // party/invited is "sent to the invited player and all party members".
  pure def invite(s: State, u: UserId, target: UserId): Outcome =
    if (partiesOf(s, u) == Set()) deny(s, "invalid_request")
    else {
      val id = partiesOf(s, u).fold(-1, (_, x) => x)
      val p = s.parties.get(id)
      if (target.in(p.members.union(p.invited))) deny(s, "invalid_request")
      else if (p.members.size() + p.invited.size() >= MAX_MEMBERS) deny(s, "invalid_request")
      else { state: withParty(s, id, { ...p, invited: p.invited.union(Set(target)) }),
             reply: Ok, events: send(p.members.union(Set(target)), Invited(id)) }
    }

  pure def accept(s: State, u: UserId, id: PartyId): Outcome =
    if (not(id.in(s.parties.keys()))) deny(s, "invalid_request")
    else {
      val p = s.parties.get(id)
      if (not(u.in(p.invited)) or partiesOf(s, u) != Set()) deny(s, "invalid_request")
      else {
        val q = { members: p.members.union(Set(u)), invited: p.invited.exclude(Set(u)) }
        { state: withParty(s, id, q), reply: Ok, events: send(q.members, Updated(id)) }
      }
    }

  // "When the last member of a party leaves, the party is disbanded."
  pure def leave(s: State, u: UserId): Outcome =
    if (partiesOf(s, u) == Set()) deny(s, "invalid_request")
    else {
      val id = partiesOf(s, u).fold(-1, (_, x) => x)
      val p = s.parties.get(id)
      val rest = p.members.exclude(Set(u))
      if (rest == Set())
        { state: { ...s, parties: s.parties.keys().exclude(Set(id)).mapBy(k => s.parties.get(k)) },
          reply: Ok, events: send(p.invited.union(Set(u)), Removed(id)) }
      else
        { state: withParty(s, id, { ...p, members: rest }),
          reply: Ok, events: send(Set(u), Removed(id)).union(send(rest, Updated(id))) }
    }

  // Environment: the invite timer fires. A late or repeated fire changes nothing.
  pure def inviteTimedOut(s: State, id: PartyId, target: UserId): Outcome =
    if (not(id.in(s.parties.keys())) or not(target.in(s.parties.get(id).invited)))
      { state: s, reply: NoReply, events: Set() }
    else {
      val p = s.parties.get(id)
      { state: withParty(s, id, { ...p, invited: p.invited.exclude(Set(target)) }),
        reply: NoReply,
        events: send(Set(target), Removed(id)).union(send(p.members, Updated(id))) }
    }

  // ---- state machine ----
  var s: State
  var lastCmd: str
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]

  action apply(cmd: str, o: Outcome): bool = all {
    s' = o.state, lastCmd' = cmd, lastReply' = o.reply, lastEvents' = o.events,
  }
  action init = all {
    s' = { parties: Map(), nextId: 0 },
    lastCmd' = "init", lastReply' = NoReply, lastEvents' = Set(),
  }
  action step = {
    nondet u = USERS.oneOf()
    nondet t = USERS.oneOf()
    nondet id = 0.to(s.nextId).oneOf()
    any {
      apply("party/create", create(s, u)),
      apply("party/invite", invite(s, u, t)),
      apply("party/acceptInvite", accept(s, u, id)),
      apply("party/leave", leave(s, u)),
      apply("timer/partyInvite", inviteTimedOut(s, id, t)),
    }
  }

  // ---- properties ----
  val atMostOneParty = USERS.forall(u => partiesOf(s, u).size() <= 1)

  val wellFormed = s.parties.keys().forall(id => {
    val p = s.parties.get(id)
    and { p.members != Set(),
          p.members.intersect(p.invited) == Set(),
          p.members.size() + p.invited.size() <= MAX_MEMBERS }
  })

  // Failure reasons the JSON Schema allows; the same set for these four commands.
  pure val schemaReasons =
    Set("internal_error", "unauthorized", "invalid_request", "command_unimplemented")
  val reasonsInSchema = match lastReply {
    | Failed(r) => r.in(schemaReasons)
    | Ok => true
    | NoReply => true
  }

  // party/updated reaches only current members of that party.
  val updatesReachMembersOnly = lastEvents.forall(m => match m._2 {
    | Updated(id) => id.in(s.parties.keys()) and m._1.in(s.parties.get(id).members)
    | Invited(_) => true
    | Removed(_) => true
  })

  val safety = and { atMostOneParty, wellFormed, reasonsInSchema, updatesReachMembersOnly }

  // Reachability witness: checking not(fullParty) must fail.
  val fullParty = s.parties.keys().exists(id => s.parties.get(id).members.size() == MAX_MEMBERS)
}

module party3 {
  import party(USERS = Set("a", "b", "c"), MAX_MEMBERS = 2).*

  // A reviewed transcript, written as a run.
  run inviteAcceptLeaveTest =
    init
      .then(apply("party/create", create(s, "a")))
      .then(apply("party/invite", invite(s, "a", "b")))
      .expect(lastEvents == Set(("a", Invited(0)), ("b", Invited(0))))
      .then(apply("party/invite", invite(s, "a", "c")))
      .expect(lastReply == Failed("invalid_request"))   // 1 member + 1 invite = limit
      .then(apply("party/acceptInvite", accept(s, "b", 0)))
      .expect(lastEvents == Set(("a", Updated(0)), ("b", Updated(0))))
      .then(apply("party/leave", leave(s, "a")))
      .expect(lastEvents == Set(("a", Removed(0)), ("b", Updated(0))))
      .then(apply("party/leave", leave(s, "b")))
      .expect(s.parties.keys() == Set())

  run lateTimerTest =
    init
      .then(apply("party/create", create(s, "a")))
      .then(apply("party/invite", invite(s, "a", "b")))
      .then(apply("timer/partyInvite", inviteTimedOut(s, 0, "b")))
      .expect(lastEvents == Set(("b", Removed(0)), ("a", Updated(0))))
      .then(apply("timer/partyInvite", inviteTimedOut(s, 0, "b")))
      .expect(lastEvents == Set())
}
