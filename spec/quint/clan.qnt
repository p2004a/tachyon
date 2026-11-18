// Clans: clan/create, update, delete, invite, cancel, accept, decline, kick,
// leave, setRole, view, viewList and the events updated, deleted, invited,
// kicked, roleChanged.
// Source: tachyon docs/schema/clan.md (prose generated from src/schema/clan/README.md),
// schema/clan/*, schema/definitions/clan*.json, user.json, privateUser.json.
// Not implemented by teiserver or bar-lobby (findings/clan.md CLAN-01): every
// request there replies command_unimplemented. This model is the protocol only.
//
// @test main=clan_test
// @inv main=clan_test inv=safety steps=30 samples=20000
// @inv main=clan_grow inv=safety steps=30 samples=20000
// @witness main=clan_test inv=not(wCreateOk)
// @witness main=clan_test inv=not(wCreateInvalid)
// @witness main=clan_test inv=not(wUpdateOk)
// @witness main=clan_test inv=not(wUpdateInvalid)
// @witness main=clan_test inv=not(wUpdateUnauthorized)
// @witness main=clan_test inv=not(wDeleteOk)
// @witness main=clan_test inv=not(wDeleteInvalid)
// @witness main=clan_test inv=not(wDeleteUnauthorized)
// @witness main=clan_test inv=not(wInviteOk)
// @witness main=clan_grow inv=not(wInviteByCoLeader) steps=30 samples=400000
// @witness main=clan_test inv=not(wInviteInvalid)
// @witness main=clan_test inv=not(wInviteUnauthorized)
// @witness main=clan_test inv=not(wCancelOk)
// @witness main=clan_test inv=not(wCancelInvalid)
// @witness main=clan_test inv=not(wCancelUnauthorized)
// @witness main=clan_test inv=not(wAcceptOk)
// @witness main=clan_test inv=not(wAcceptInvalid)
// @witness main=clan_test inv=not(wAcceptWhileInClan)
// @witness main=clan_test inv=not(wDeclineOk)
// @witness main=clan_test inv=not(wDeclineInvalid)
// @witness main=clan_test inv=not(wKickOk)
// @witness main=clan_test inv=not(wKickInvalid)
// @witness main=clan_test inv=not(wKickUnauthorized)
// @witness main=clan_test inv=not(wLeaveOk)
// @witness main=clan_test inv=not(wLeaveInvalid)
// @witness main=clan_grow inv=not(wLeaveHeirCoLeader) steps=30 samples=400000
// @witness main=clan_test inv=not(wLeaveHeirMember)
// @witness main=clan_test inv=not(wLeaveDissolves)
// @witness main=clan_grow inv=not(wSetRolePromote) steps=30 samples=400000
// @witness main=clan_grow inv=not(wSetRoleDemote) steps=30 samples=400000
// @witness main=clan_grow inv=not(wSetRoleTransfer) steps=30 samples=400000
// @witness main=clan_test inv=not(wSetRoleInvalid)
// @witness main=clan_test inv=not(wSetRoleUnauthorized)
// @witness main=clan_test inv=not(wViewOk)
// @witness main=clan_test inv=not(wViewInvalid)
// @witness main=clan_test inv=not(wViewListOk)
// @witness main=clan_test inv=not(wTwoClans)
// @verify main=clan_test inv=safety steps=3
// (verify: passed in ~260 s with JVM_ARGS=-Xmx6G, before successionFollowsRule was added)
module clan {
  import common.* from "./common"

  // "ClanRole": enum ["member", "coLeader", "leader"] (schema/definitions/clanRole.json)
  pure val ROLES: Set[str] = Set("member", "coLeader", "leader")
  pure val MANAGERS: Set[str] = Set("leader", "coLeader")

  type ClanId = int
  // "ClanMember": { userId, role, joinedAt } (schema/definitions/clanMember.json).
  // joinedAt is a logical clock value here (unique, increasing).
  type Member = { role: str, joinedAt: int }
  // The profile (name, tag, language, description) is abstracted to one value.
  type Clan = { profile: str, members: UserId -> Member, invited: Set[UserId] }
  type State = { clans: ClanId -> Clan, nextId: ClanId, clock: int }

  // On the wire clan/invited carries only clanUpdateableBaseData (no clanId,
  // CLAN-03) and clan/updated carries clanUpdateableData (no clanId, CLAN-03).
  // The model keeps the clan id on every event so recipients can be checked.
  type Event =
    | Updated(ClanId)
    | Invited(ClanId)
    | Kicked(ClanId)
    | Deleted(ClanId)
    | RoleChanged({ clan: ClanId, user: UserId, role: str })

  // Success data of clan/view and clan/viewList.
  type Data =
    | NoData
    | ClanView({ clan: ClanId, profile: str, members: UserId -> Member })
    | ClanList(Set[ClanId])

  type Outcome = { state: State, reply: Reply, data: Data, events: Set[(UserId, Event)] }

  const USERS: Set[UserId]
  const PROFILES: Set[str]
  // Simulation knob, not protocol: false restricts `step` to create, invite, accept,
  // setRole and the leader's leave, so that random runs grow clans deep enough to
  // reach the co-leader witnesses. Every check also runs with CHURN = true.
  const CHURN: bool

  // ---- helpers ----
  pure def clansOf(s: State, u: UserId): Set[ClanId] =
    s.clans.keys().filter(c => s.clans.get(c).members.keys().contains(u))
  pure def clanOf(s: State, u: UserId): ClanId = theOne(clansOf(s, u), -1)
  // "none" when u is in no clan.
  pure def roleOf(s: State, u: UserId): str =
    if (clansOf(s, u) == Set()) "none"
    else s.clans.get(clanOf(s, u)).members.get(u).role
  pure def membersOf(s: State, c: ClanId): Set[UserId] =
    if (c.in(s.clans.keys())) s.clans.get(c).members.keys() else Set()
  pure def deny(s: State, reason: str): Outcome =
    { state: s, reply: Failed(reason), data: NoData, events: Set() }
  pure def ok(s: State, ev: Set[(UserId, Event)]): Outcome =
    { state: s, reply: Ok, data: NoData, events: ev }
  pure def withClan(s: State, c: ClanId, cl: Clan): State =
    { ...s, clans: s.clans.set(c, cl) }
  // The member of `pool` with the smallest joinedAt.
  pure def oldest(ms: UserId -> Member, pool: Set[UserId]): UserId =
    pool.fold(("", -1), (acc, x) =>
      if (acc._1 == "" or ms.get(x).joinedAt < acc._2) (x, ms.get(x).joinedAt) else acc)._1

  // ---- commands ----

  // "Every user is allowed to create a clan with clan/create. Then he is the clan leader."
  // ASSUMPTION CLAN-A1: a user is in at most one clan (user.clanBaseData is a
  // single value), so creating while in a clan is invalid_request.
  // ASSUMPTION CLAN-A2: no clan event on create; the response has no clanId (CLAN-03).
  // ASSUMPTION CLAN-A3: name/tag uniqueness is not checked (protocol silent).
  pure def create(s: State, u: UserId, p: str): Outcome =
    if (roleOf(s, u) != "none") deny(s, "invalid_request")
    else ok({ clans: s.clans.put(s.nextId,
                { profile: p, members: Map(u -> { role: "leader", joinedAt: s.clock }), invited: Set() }),
              nextId: s.nextId + 1, clock: s.clock + 1 }, Set())

  // "Clan leader and clan co-leaders are able to update the profile clan/update."
  // clan/updated: "One ore more clan properties were updated. Sent to all clan members."
  // ASSUMPTION CLAN-A4: insufficient clan role -> unauthorized; not in a clan -> invalid_request.
  pure def update(s: State, u: UserId, p: str): Outcome =
    if (roleOf(s, u) == "none") deny(s, "invalid_request")
    else if (not(roleOf(s, u).in(MANAGERS))) deny(s, "unauthorized")
    else {
      val c = clanOf(s, u)
      val cl = s.clans.get(c)
      ok(withClan(s, c, { ...cl, profile: p }), send(cl.members.keys(), Updated(c)))
    }

  // "The clan leader is the only one who is allowed to delete the clan with the request clan/delete."
  // clan/deleted: "A clan was deleted. Sent to all clan members." (the caller included)
  // ASSUMPTION CLAN-A5: pending invites vanish; invitees get no event (CLAN-08).
  pure def delete(s: State, u: UserId): Outcome =
    if (roleOf(s, u) == "none") deny(s, "invalid_request")
    else if (roleOf(s, u) != "leader") deny(s, "unauthorized")
    else {
      val c = clanOf(s, u)
      ok({ ...s, clans: mapRemove(s.clans, c) }, send(membersOf(s, c), Deleted(c)))
    }

  // "Clan leader and clan co-leaders are allowed to invite different players with
  //  clan/invite. (There are no limitations of the count of members.)"
  // clan/invited: "A player has been invited to a clan. Sent to the invited player."
  // ASSUMPTION CLAN-A6: inviting a member or an already-invited player is invalid_request;
  // inviting a member of another clan is allowed (accept then fails until they leave).
  pure def invite(s: State, u: UserId, t: UserId): Outcome =
    if (roleOf(s, u) == "none") deny(s, "invalid_request")
    else if (not(roleOf(s, u).in(MANAGERS))) deny(s, "unauthorized")
    else {
      val c = clanOf(s, u)
      val cl = s.clans.get(c)
      if (cl.members.keys().contains(t) or cl.invited.contains(t)) deny(s, "invalid_request")
      else ok(withClan(s, c, { ...cl, invited: cl.invited.union(Set(t)) }), send(Set(t), Invited(c)))
    }

  // "The invitation can be cancelled by clan/cancelInvite." / "Cancel an invite to your clan."
  // ASSUMPTION CLAN-A7: only leader and co-leaders may cancel (the inviters); no event (CLAN-07).
  pure def cancel(s: State, u: UserId, t: UserId): Outcome =
    if (roleOf(s, u) == "none") deny(s, "invalid_request")
    else if (not(roleOf(s, u).in(MANAGERS))) deny(s, "unauthorized")
    else {
      val c = clanOf(s, u)
      val cl = s.clans.get(c)
      if (not(cl.invited.contains(t))) deny(s, "invalid_request")
      else ok(withClan(s, c, { ...cl, invited: cl.invited.exclude(Set(t)) }), Set())
    }

  // "Invited players can accept invitiation by clan/acceptInvite"
  // ASSUMPTION CLAN-A1 again: accepting while in a clan is invalid_request.
  // ASSUMPTION CLAN-A8: the joiner becomes "member"; other invites of the joiner stay;
  // no clan event to anyone (CLAN-07).
  pure def accept(s: State, u: UserId, c: ClanId): Outcome =
    if (not(c.in(s.clans.keys()))) deny(s, "invalid_request")
    else if (not(s.clans.get(c).invited.contains(u))) deny(s, "invalid_request")
    else if (roleOf(s, u) != "none") deny(s, "invalid_request")
    else {
      val cl = s.clans.get(c)
      ok({ ...withClan(s, c, { ...cl,
             members: cl.members.put(u, { role: "member", joinedAt: s.clock }),
             invited: cl.invited.exclude(Set(u)) }),
           clock: s.clock + 1 }, Set())
    }

  // "... and decline by clan/declineInvite."  No event (CLAN-07).
  pure def decline(s: State, u: UserId, c: ClanId): Outcome =
    if (not(c.in(s.clans.keys())) or not(s.clans.get(c).invited.contains(u))) deny(s, "invalid_request")
    else {
      val cl = s.clans.get(c)
      ok(withClan(s, c, { ...cl, invited: cl.invited.exclude(Set(u)) }), Set())
    }

  // "Only the clan-leader is able to kick members by clan/kickMember."
  // clan/kicked: "A player was kicked from a clan. Sent to the kicked player."
  // ASSUMPTION CLAN-A9: the leader cannot kick himself (that would leave the clan
  // leaderless; clan/leave is the way out); co-leaders can be kicked.
  pure def kick(s: State, u: UserId, t: UserId): Outcome =
    if (roleOf(s, u) == "none") deny(s, "invalid_request")
    else if (roleOf(s, u) != "leader") deny(s, "unauthorized")
    else {
      val c = clanOf(s, u)
      val cl = s.clans.get(c)
      if (t == u or not(cl.members.keys().contains(t))) deny(s, "invalid_request")
      else ok(withClan(s, c, { ...cl, members: mapRemove(cl.members, t) }), send(Set(t), Kicked(c)))
    }

  // "any member can leave the clan they are currently in with clan/leave."
  // "If the clan-leader leaves the clan by clan/leave the oldest co-leader is set as
  //  new clan leader. If no co-leader exist the oldest member is set as new clan leader."
  // "If the clan-leader leaves the clan and he is the last member the clan will be removed."
  // ASSUMPTION CLAN-A10: "oldest" = smallest joinedAt; the heir gets clan/roleChanged
  // ("Sent to affected clan member"); removal by last leave sends nothing.
  pure def leave(s: State, u: UserId): Outcome =
    if (roleOf(s, u) == "none") deny(s, "invalid_request")
    else {
      val c = clanOf(s, u)
      val cl = s.clans.get(c)
      val rest = mapRemove(cl.members, u)
      if (rest.keys() == Set()) ok({ ...s, clans: mapRemove(s.clans, c) }, Set())
      else if (cl.members.get(u).role != "leader") ok(withClan(s, c, { ...cl, members: rest }), Set())
      else {
        val cos = rest.keys().filter(x => rest.get(x).role == "coLeader")
        val heir = oldest(rest, if (cos != Set()) cos else rest.keys())
        ok(withClan(s, c, { ...cl, members: rest.set(heir, { ...rest.get(heir), role: "leader" }) }),
           Set((heir, RoleChanged({ clan: c, user: heir, role: "leader" }))))
      }
    }

  // "The clan leader is allowed to appoint members as clan co-leader with clan/setRole.
  //  The clan leader has also the possibility to transfer his leadership role to a
  //  different member with the same command. (ATTENTION: By executing this command the
  //  clan leader loses his permissions!)"
  // clan/roleChanged: "A clan member's role was changed. Sent to affected clan member."
  // ASSUMPTION CLAN-A11: on transfer the old leader becomes "member" and both affected
  // members get roleChanged; demoting a co-leader to member is allowed; setting the
  // current role is an Ok no-op; the leader cannot target himself; a caller that is
  // not a member of data.clanId gets invalid_request.
  pure def setRole(s: State, u: UserId, t: UserId, c: ClanId, r: str): Outcome =
    if (not(c.in(s.clans.keys())) or not(membersOf(s, c).contains(u))) deny(s, "invalid_request")
    else if (roleOf(s, u) != "leader") deny(s, "unauthorized")
    else if (t == u or not(membersOf(s, c).contains(t)) or not(r.in(ROLES))) deny(s, "invalid_request")
    else {
      val cl = s.clans.get(c)
      val cur = cl.members.get(t)
      if (cur.role == r) ok(s, Set())
      else if (r == "leader")
        ok(withClan(s, c, { ...cl, members: cl.members
                                 .set(t, { ...cur, role: "leader" })
                                 .set(u, { ...cl.members.get(u), role: "member" }) }),
           Set((t, RoleChanged({ clan: c, user: t, role: "leader" })),
               (u, RoleChanged({ clan: c, user: u, role: "member" }))))
      else
        ok(withClan(s, c, { ...cl, members: cl.members.set(t, { ...cur, role: r }) }),
           Set((t, RoleChanged({ clan: c, user: t, role: r }))))
    }

  // "Get detailed information about a clan."  ASSUMPTION CLAN-A12: anyone may view any clan.
  pure def view(s: State, u: UserId, c: ClanId): Outcome =
    if (not(c.in(s.clans.keys()))) deny(s, "invalid_request")
    else { state: s, reply: Ok, events: Set(),
           data: ClanView({ clan: c, profile: s.clans.get(c).profile, members: s.clans.get(c).members }) }

  // "Get the list of clans"
  pure def viewList(s: State, u: UserId): Outcome =
    { state: s, reply: Ok, events: Set(), data: ClanList(s.clans.keys()) }

  // ---- state machine ----
  var s: State
  var prev: State
  var lastCmd: str
  var lastCaller: UserId
  var lastReply: Reply
  var lastData: Data
  var lastEvents: Set[(UserId, Event)]

  action apply(cmd: str, caller: UserId, o: Outcome): bool = all {
    prev' = s, s' = o.state, lastCmd' = cmd, lastCaller' = caller,
    lastReply' = o.reply, lastData' = o.data, lastEvents' = o.events,
  }
  pure val EMPTY: State = { clans: Map(), nextId: 0, clock: 0 }
  action init = all {
    s' = EMPTY, prev' = EMPTY, lastCmd' = "init", lastCaller' = "",
    lastReply' = NoReply, lastData' = NoData, lastEvents' = Set(),
  }
  action step = {
    nondet u = USERS.oneOf()
    nondet t = USERS.oneOf()
    // existing clans plus one id that names no clan (deleted ids behave alike)
    nondet c = s.clans.keys().union(Set(s.nextId)).oneOf()
    nondet p = PROFILES.oneOf()
    nondet r = ROLES.oneOf()
    any {
      apply("clan/create", u, create(s, u, p)),
      all { CHURN, apply("clan/update", u, update(s, u, p)) },
      all { CHURN, apply("clan/delete", u, delete(s, u)) },
      apply("clan/invite", u, invite(s, u, t)),
      all { CHURN, apply("clan/cancel", u, cancel(s, u, t)) },
      apply("clan/accept", u, accept(s, u, c)),
      all { CHURN, apply("clan/decline", u, decline(s, u, c)) },
      all { CHURN, apply("clan/kick", u, kick(s, u, t)) },
      all { CHURN or roleOf(s, u) == "leader", apply("clan/leave", u, leave(s, u)) },
      apply("clan/setRole", u, setRole(s, u, t, c, r)),
      all { CHURN, apply("clan/view", u, view(s, u, c)) },
      all { CHURN, apply("clan/viewList", u, viewList(s, u)) },
    }
  }

  // ---- properties ----
  // user.clanBaseData is a single value: a user is in at most one clan.
  val atMostOneClan = USERS.forall(u => clansOf(s, u).size() <= 1)

  // "the clan leader" is singular, and every way out of the leader role hands it on
  // or removes the clan: every clan has members and exactly one leader.
  val oneLeader = s.clans.keys().forall(c => {
    val ms = s.clans.get(c).members
    ms.keys().filter(x => ms.get(x).role == "leader").size() == 1
  })

  val wellFormed = s.clans.keys().forall(c => {
    val cl = s.clans.get(c)
    and {
      c < s.nextId,
      cl.members.keys().intersect(cl.invited) == Set(),
      cl.members.keys().forall(x => cl.members.get(x).role.in(ROLES)
                                    and cl.members.get(x).joinedAt < s.clock),
      cl.members.keys().forall(x => cl.members.keys().forall(y =>
        x == y or cl.members.get(x).joinedAt != cl.members.get(y).joinedAt)),
    }
  })

  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  // A denial changes nothing and tells nobody.
  val denialsInert = match lastReply {
    | Failed(_) => s == prev and lastEvents == Set() and lastData == NoData
    | Ok => true
    | NoReply => s == prev
  }

  // Every success is permitted by the caller's role before the step.
  val permissionsRespected = lastReply != Ok or {
    val r = roleOf(prev, lastCaller)
    if (lastCmd.in(Set("clan/create", "clan/accept"))) r == "none"
    else if (lastCmd.in(Set("clan/update", "clan/invite", "clan/cancel"))) r.in(MANAGERS)
    else if (lastCmd.in(Set("clan/delete", "clan/kick", "clan/setRole"))) r == "leader"
    else if (lastCmd == "clan/leave") r != "none"
    else true
  }

  // Each event reaches only the audience its schema description names.
  val eventsAudience = lastEvents.forall(m => {
    val rcpt = m._1
    match m._2 {
      // "Sent to all clan members."
      | Updated(c) => membersOf(s, c).contains(rcpt)
      // "Sent to the invited player."
      | Invited(c) => c.in(s.clans.keys()) and s.clans.get(c).invited.contains(rcpt)
                      and not(prev.clans.get(c).invited.contains(rcpt))
      // "Sent to the kicked player."
      | Kicked(c) => membersOf(prev, c).contains(rcpt) and not(membersOf(s, c).contains(rcpt))
      // "Sent to all clan members." (of the clan before deletion)
      | Deleted(c) => membersOf(prev, c).contains(rcpt) and not(c.in(s.clans.keys()))
      // "Sent to affected clan member."
      | RoleChanged(x) => rcpt == x.user and membersOf(s, x.clan).contains(rcpt)
                          and s.clans.get(x.clan).members.get(rcpt).role == x.role
    }
  })

  // ... and reaches all of it.
  val eventsComplete = and {
    // every member of an updated clan is told
    lastCmd != "clan/update" or lastReply != Ok
      or membersOf(s, clanOf(s, lastCaller)).forall(x => lastEvents.contains((x, Updated(clanOf(s, lastCaller))))),
    // every member of a deleted clan is told
    prev.clans.keys().forall(c => c.in(s.clans.keys()) or lastCmd != "clan/delete"
      or membersOf(prev, c).forall(x => lastEvents.contains((x, Deleted(c))))),
    // a kicked member is told
    lastCmd != "clan/kick" or prev.clans.keys().forall(c =>
      membersOf(prev, c).forall(x => membersOf(s, c).contains(x) or lastEvents.contains((x, Kicked(c))))),
    // nobody's role changes silently (setRole and leader succession)
    s.clans.keys().forall(c => membersOf(s, c).intersect(membersOf(prev, c)).forall(x => {
      val nr = s.clans.get(c).members.get(x).role
      nr == prev.clans.get(c).members.get(x).role
        or lastEvents.contains((x, RoleChanged({ clan: c, user: x, role: nr })))
    })),
  }

  // "If the clan-leader leaves the clan by clan/leave the oldest co-leader is set as
  //  new clan leader. If no co-leader exist the oldest member is set as new clan leader."
  val successionFollowsRule = lastCmd != "clan/leave" or lastReply != Ok
    or roleOf(prev, lastCaller) != "leader" or {
      val c = clanOf(prev, lastCaller)
      val ms = prev.clans.get(c).members
      val rest = ms.keys().exclude(Set(lastCaller))
      val cos = rest.filter(x => ms.get(x).role == "coLeader")
      val pool = if (cos != Set()) cos else rest
      rest == Set() or pool.forall(x => roleOf(s, x) == "leader"
        or pool.exists(y => roleOf(s, y) == "leader" and ms.get(y).joinedAt < ms.get(x).joinedAt))
    }

  // clan/view and clan/viewList report the current state.
  val viewsAccurate = match lastData {
    | NoData => true
    | ClanView(v) => v.clan.in(s.clans.keys()) and v.members == s.clans.get(v.clan).members
                     and v.profile == s.clans.get(v.clan).profile
    | ClanList(ids) => ids == s.clans.keys()
  }

  val safety = and {
    atMostOneClan, oneLeader, wellFormed, reasonsInSchema, denialsInert,
    permissionsRespected, eventsAudience, eventsComplete, viewsAccurate,
    successionFollowsRule,
  }

  // ---- reachability witnesses (each `not(w...)` must be violated) ----
  def hit(cmd: str, r: Reply): bool = lastCmd == cmd and lastReply == r
  val wCreateOk = hit("clan/create", Ok)
  val wCreateInvalid = hit("clan/create", Failed("invalid_request"))
  val wUpdateOk = hit("clan/update", Ok)
  val wUpdateInvalid = hit("clan/update", Failed("invalid_request"))
  val wUpdateUnauthorized = hit("clan/update", Failed("unauthorized"))
  val wDeleteOk = hit("clan/delete", Ok) and lastEvents.size() >= 2
  val wDeleteInvalid = hit("clan/delete", Failed("invalid_request"))
  val wDeleteUnauthorized = hit("clan/delete", Failed("unauthorized"))
  val wInviteOk = hit("clan/invite", Ok)
  val wInviteByCoLeader = hit("clan/invite", Ok) and roleOf(prev, lastCaller) == "coLeader"
  val wInviteInvalid = hit("clan/invite", Failed("invalid_request"))
  val wInviteUnauthorized = hit("clan/invite", Failed("unauthorized"))
  val wCancelOk = hit("clan/cancel", Ok)
  val wCancelInvalid = hit("clan/cancel", Failed("invalid_request"))
  val wCancelUnauthorized = hit("clan/cancel", Failed("unauthorized"))
  val wAcceptOk = hit("clan/accept", Ok)
  val wAcceptInvalid = hit("clan/accept", Failed("invalid_request"))
  // invited, but already in another clan
  val wAcceptWhileInClan = hit("clan/accept", Failed("invalid_request"))
    and prev.clans.keys().exists(c => prev.clans.get(c).invited.contains(lastCaller))
    and roleOf(prev, lastCaller) != "none"
  val wDeclineOk = hit("clan/decline", Ok)
  val wDeclineInvalid = hit("clan/decline", Failed("invalid_request"))
  val wKickOk = hit("clan/kick", Ok)
  val wKickInvalid = hit("clan/kick", Failed("invalid_request"))
  val wKickUnauthorized = hit("clan/kick", Failed("unauthorized"))
  val wLeaveOk = hit("clan/leave", Ok)
  val wLeaveInvalid = hit("clan/leave", Failed("invalid_request"))
  // leader leaves; the heir was a co-leader / a plain member
  pure def heirWas(o: str, pr: State, evs: Set[(UserId, Event)]): bool =
    evs.exists(m => match m._2 {
      | RoleChanged(x) => roleOf(pr, x.user) == o
      | _ => false
    })
  val wLeaveHeirCoLeader = hit("clan/leave", Ok) and heirWas("coLeader", prev, lastEvents)
                           and USERS.exists(x => roleOf(prev, x) == "member")
  val wLeaveHeirMember = hit("clan/leave", Ok) and heirWas("member", prev, lastEvents)
  val wLeaveDissolves = hit("clan/leave", Ok) and s.clans.keys().size() < prev.clans.keys().size()
  val wSetRolePromote = hit("clan/setRole", Ok) and lastEvents.exists(m => match m._2 {
    | RoleChanged(x) => x.role == "coLeader" | _ => false })
  val wSetRoleDemote = hit("clan/setRole", Ok) and lastEvents.size() == 1 and lastEvents.exists(m => match m._2 {
    | RoleChanged(x) => x.role == "member" | _ => false })
  val wSetRoleTransfer = hit("clan/setRole", Ok) and lastEvents.size() == 2
  val wSetRoleInvalid = hit("clan/setRole", Failed("invalid_request"))
  val wSetRoleUnauthorized = hit("clan/setRole", Failed("unauthorized"))
  val wViewOk = hit("clan/view", Ok)
  val wViewInvalid = hit("clan/view", Failed("invalid_request"))
  val wViewListOk = hit("clan/viewList", Ok) and lastData != ClanList(Set())
  val wTwoClans = s.clans.keys().size() >= 2
  // Unreachable in this model: internal_error and command_unimplemented for every
  // command (server faults / implementation status), and every clan/viewList denial.
}

module clan_test {
  import common.* from "./common"
  import clan(USERS = Set("a", "b", "c"), PROFILES = Set("p1", "p2"), CHURN = true).*

  // Reviewed transcript: create, invite, accept, promote, update, transfer, delete.
  run lifecycleTest =
    init
      .then(apply("clan/create", "a", create(s, "a", "p1")))
      .expect(lastReply == Ok and roleOf(s, "a") == "leader" and lastEvents == Set())
      .then(apply("clan/create", "a", create(s, "a", "p2")))
      .expect(lastReply == Failed("invalid_request"))              // already in a clan
      .then(apply("clan/invite", "a", invite(s, "a", "b")))
      .expect(lastEvents == Set(("b", Invited(0))))                // only the invitee
      .then(apply("clan/invite", "a", invite(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request"))              // already invited
      .then(apply("clan/accept", "b", accept(s, "b", 0)))
      .expect(lastReply == Ok and roleOf(s, "b") == "member" and lastEvents == Set())
      .then(apply("clan/update", "b", update(s, "b", "p2")))
      .expect(lastReply == Failed("unauthorized"))                 // members cannot update
      .then(apply("clan/invite", "b", invite(s, "b", "c")))
      .expect(lastReply == Failed("unauthorized"))
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 0, "coLeader")))
      .expect(lastEvents == Set(("b", RoleChanged({ clan: 0, user: "b", role: "coLeader" }))))
      .then(apply("clan/update", "b", update(s, "b", "p2")))
      .expect(lastEvents == Set(("a", Updated(0)), ("b", Updated(0))))
      .then(apply("clan/delete", "b", delete(s, "b")))
      .expect(lastReply == Failed("unauthorized"))                 // only the leader deletes
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 0, "leader")))
      .expect(lastEvents == Set(("b", RoleChanged({ clan: 0, user: "b", role: "leader" })),
                                ("a", RoleChanged({ clan: 0, user: "a", role: "member" }))))
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 0, "member")))
      .expect(lastReply == Failed("unauthorized"))                 // the old leader lost his permissions
      .then(apply("clan/delete", "b", delete(s, "b")))
      .expect(lastEvents == Set(("a", Deleted(0)), ("b", Deleted(0))) and s.clans.keys() == Set())
      .then(apply("clan/view", "c", view(s, "c", 0)))
      .expect(lastReply == Failed("invalid_request"))

  // Leader succession on clan/leave: oldest co-leader first, else oldest member;
  // the last member's leave removes the clan.
  run successionTest =
    init
      .then(apply("clan/create", "a", create(s, "a", "p1")))
      .then(apply("clan/invite", "a", invite(s, "a", "b")))
      .then(apply("clan/accept", "b", accept(s, "b", 0)))
      .then(apply("clan/invite", "a", invite(s, "a", "c")))
      .then(apply("clan/accept", "c", accept(s, "c", 0)))
      .then(apply("clan/setRole", "a", setRole(s, "a", "c", 0, "coLeader")))
      .then(apply("clan/leave", "a", leave(s, "a")))               // c is the only co-leader
      .expect(lastEvents == Set(("c", RoleChanged({ clan: 0, user: "c", role: "leader" }))))
      .expect(roleOf(s, "b") == "member" and roleOf(s, "a") == "none")
      .then(apply("clan/leave", "c", leave(s, "c")))               // no co-leader: oldest member b
      .expect(lastEvents == Set(("b", RoleChanged({ clan: 0, user: "b", role: "leader" }))))
      .then(apply("clan/leave", "b", leave(s, "b")))               // last member
      .expect(lastReply == Ok and lastEvents == Set() and s.clans.keys() == Set())
      .then(apply("clan/leave", "b", leave(s, "b")))
      .expect(lastReply == Failed("invalid_request"))

  // Invites: cancel, decline, accept while in another clan, kick.
  run invitesAndKickTest =
    init
      .then(apply("clan/create", "a", create(s, "a", "p1")))
      .then(apply("clan/create", "c", create(s, "c", "p2")))
      .then(apply("clan/invite", "a", invite(s, "a", "c")))        // c is in clan 1: allowed
      .expect(lastReply == Ok)
      .then(apply("clan/accept", "c", accept(s, "c", 0)))
      .expect(lastReply == Failed("invalid_request"))              // one clan per user
      .then(apply("clan/decline", "c", decline(s, "c", 0)))
      .expect(lastReply == Ok and s.clans.get(0).invited == Set())
      .then(apply("clan/decline", "c", decline(s, "c", 0)))
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("clan/invite", "a", invite(s, "a", "b")))
      .then(apply("clan/cancel", "a", cancel(s, "a", "b")))
      .expect(lastReply == Ok and lastEvents == Set())             // invitee is not told (CLAN-07)
      .then(apply("clan/cancel", "a", cancel(s, "a", "b")))
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("clan/accept", "b", accept(s, "b", 0)))
      .expect(lastReply == Failed("invalid_request"))              // invite was cancelled
      .then(apply("clan/cancel", "b", cancel(s, "b", "a")))
      .expect(lastReply == Failed("invalid_request"))              // b is in no clan
      .then(apply("clan/invite", "a", invite(s, "a", "b")))
      .then(apply("clan/accept", "b", accept(s, "b", 0)))
      .then(apply("clan/cancel", "b", cancel(s, "b", "c")))
      .expect(lastReply == Failed("unauthorized"))
      .then(apply("clan/kick", "b", kick(s, "b", "a")))
      .expect(lastReply == Failed("unauthorized"))
      .then(apply("clan/kick", "a", kick(s, "a", "a")))
      .expect(lastReply == Failed("invalid_request"))              // CLAN-A9
      .then(apply("clan/kick", "a", kick(s, "a", "c")))
      .expect(lastReply == Failed("invalid_request"))              // c is not a member
      .then(apply("clan/kick", "a", kick(s, "a", "b")))
      .expect(lastEvents == Set(("b", Kicked(0))) and roleOf(s, "b") == "none")
      .then(apply("clan/kick", "c", kick(s, "c", "b")))
      .expect(lastReply == Failed("invalid_request"))              // b is not in c's clan

  // Views and setRole argument checks.
  run viewAndSetRoleTest =
    init
      .then(apply("clan/viewList", "a", viewList(s, "a")))
      .expect(lastData == ClanList(Set()))
      .then(apply("clan/create", "a", create(s, "a", "p1")))
      .then(apply("clan/view", "b", view(s, "b", 0)))
      .expect(lastData == ClanView({ clan: 0, profile: "p1",
                                     members: Map("a" -> { role: "leader", joinedAt: 0 }) }))
      .then(apply("clan/viewList", "b", viewList(s, "b")))
      .expect(lastData == ClanList(Set(0)))
      .then(apply("clan/update", "c", update(s, "c", "p2")))
      .expect(lastReply == Failed("invalid_request"))              // not in a clan
      .then(apply("clan/delete", "c", delete(s, "c")))
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("clan/invite", "c", invite(s, "c", "a")))
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("clan/setRole", "a", setRole(s, "a", "a", 0, "member")))
      .expect(lastReply == Failed("invalid_request"))              // cannot target self
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 0, "coLeader")))
      .expect(lastReply == Failed("invalid_request"))              // b is not a member
      .then(apply("clan/setRole", "b", setRole(s, "b", "a", 0, "member")))
      .expect(lastReply == Failed("invalid_request"))              // caller not in clan 0
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 5, "coLeader")))
      .expect(lastReply == Failed("invalid_request"))              // no such clan
      .then(apply("clan/invite", "a", invite(s, "a", "b")))
      .then(apply("clan/accept", "b", accept(s, "b", 0)))
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 0, "member")))
      .expect(lastReply == Ok and lastEvents == Set())             // already member: no-op
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 0, "coLeader")))
      .then(apply("clan/setRole", "a", setRole(s, "a", "b", 0, "member")))
      .expect(lastEvents == Set(("b", RoleChanged({ clan: 0, user: "b", role: "member" }))))
}

// Same constants with CHURN = false: used only by the deep reachability witnesses.
module clan_grow {
  import common.* from "./common"
  import clan(USERS = Set("a", "b", "c"), PROFILES = Set("p1", "p2"), CHURN = false).*
}
