// System: the composition of the group modules at the level of their abstract
// state, with the commands and environment steps that cross group boundaries.
// It does not import the group modules (their product explodes); each step
// here is a refinement-by-convention of the definitions it cites as
// `<module>.<definition>`, and system.md (INT-nn) lists every place where the
// composition had to choose because the modules or Tachyon disagree or are
// silent. Decisions INT-D1..D5 are the orchestrator's (findings/system.md).
//
// Abstract state per group:
//  - session (session.qnt): presence Online | Detached | Offline (INT-D1), a
//    socket generation per user (session.qnt `nextConn`);
//  - messaging (messaging.qnt): the socket the user subscribed on;
//  - friend (friend.qnt): friends and pending requests;
//  - party (party.qnt): members, invitees, `queued` (= the party lock, INT-D3);
//  - lobby (lobby.qnt): members and the lobby's battle (none/starting/running);
//  - matchmaking (matchmaking.qnt): searching tickets and found matches
//    (queue ids, versions, assets and team shapes abstracted: a match is >= 2
//    tickets with MATCH_SIZE members);
//  - autohost/battle (autohost.qnt): battles with their origin (lobby or
//    match), participants and phase (starting/running).
//
// @test main=system_test
// @inv main=system_test inv=safety steps=30 samples=20000
// @inv main=system_three inv=safety steps=30 samples=20000
// @inv main=system_small inv=safety steps=20 samples=10000
//
// Witnesses: every cross-module path (check.sh expects each to be reachable).
// -- session lifecycle (INT-D1, INT-D2)
// @witness main=system_test inv=not(hitWhy("env/connect","connected"))
// @witness main=system_test inv=not(hitWhy("env/disconnect","detached"))
// @witness main=system_test inv=not(hitWhy("env/reconnect","reattached"))
// @witness main=system_test inv=not(hitWhy("env/takeover","taken_over"))
// @witness main=system_test inv=not(hitWhy("env/sessionExpired","expired"))
// @witness main=system_test inv=not(hitWhy("system/disconnect","disconnected"))
// @witness main=system_three inv=not(w_keptWhilePlaying) steps=30 samples=20000
// @witness main=system_three inv=not(w_expiryWithdrawsParty) steps=30 samples=20000
// @witness main=system_test inv=not(w_expiryDisbandsMatch) steps=40 samples=20000
// @witness main=system_test inv=not(w_expiryLeavesLobby)
// @witness main=system_test inv=not(w_expiryDropsInvite)
// @witness main=system_test inv=not(w_takeoverMidReadyCheck) steps=30 samples=20000
// @witness main=system_test inv=not(w_takeoverDropsMsgSub)
// @witness main=system_test inv=not(w_disconnectDropsMsgSub)
// @witness main=system_test inv=not(w_systemDisconnectWhilePlaying) steps=40 samples=20000
// @witness main=system_test inv=not(w_offlineInBattle) steps=40 samples=20000
// -- party x matchmaking (INT-D3, PARTY-14/15/16/20, MM-18/19)
// @witness main=system_test inv=not(hitWhy("party/create","created"))
// @witness main=system_test inv=not(hitWhy("party/create","solo_cancelled"))
// @witness main=system_test inv=not(hitWhy("party/create","in_found_match")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("party/invite","invited"))
// @witness main=system_test inv=not(hitWhy("party/invite","party_in_matchmaking"))
// @witness main=system_test inv=not(hitWhy("party/acceptInvite","joined"))
// @witness main=system_test inv=not(hitWhy("party/acceptInvite","in_found_match")) steps=30 samples=60000
// @witness main=system_test inv=not(w_acceptLeavesQueuedParty) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("party/leave","left"))
// @witness main=system_test inv=not(hitWhy("party/leave","left_unqueued"))
// @witness main=system_three inv=not(hitWhy("party/leave","left_declined")) steps=30 samples=20000
// @witness main=system_three inv=not(hitWhy("party/kickMember","kicked_unqueued")) steps=30 samples=20000
// @witness main=system_three inv=not(hitWhy("party/kickMember","kicked_declined")) steps=30 samples=20000
// @witness main=system_three inv=not(w_lostPartyStaysLocked) steps=30 samples=20000
// @witness main=system_three inv=not(w_partyBattleUnlocks) steps=30 samples=20000
// -- matchmaking x lobby x battle (INT-D4)
// @witness main=system_test inv=not(hitWhy("matchmaking/queue","queued"))
// @witness main=system_test inv=not(hitWhy("matchmaking/queue","party_queued"))
// @witness main=system_test inv=not(hitWhy("matchmaking/queue","replaced"))
// @witness main=system_test inv=not(hitWhy("matchmaking/queue","already_in_battle")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("matchmaking/queue","in_lobby"))
// @witness main=system_test inv=not(hitWhy("matchmaking/queue","already_queued"))
// @witness main=system_three inv=not(hitWhy("matchmaking/queue","member_detached")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("matchmaking/cancel","left_queue"))
// @witness main=system_test inv=not(hitWhy("matchmaking/cancel","declined"))
// @witness main=system_test inv=not(hitWhy("matchmaking/cancel","not_queued"))
// @witness main=system_test inv=not(hitWhy("matchmaking/ready","readied"))
// @witness main=system_three inv=not(hitWhy("matchmaking/ready","all_ready")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("matchmaking/ready","no_match"))
// @witness main=system_test inv=not(hitWhy("env/match","found"))
// @witness main=system_test inv=not(hitWhy("env/readyTimeout","lost"))
// @witness main=system_test inv=not(hitWhy("lobby/create","created"))
// @witness main=system_test inv=not(hitWhy("lobby/create","queued"))
// @witness main=system_test inv=not(hitWhy("lobby/create","in_battle")) steps=40 samples=20000
// @witness main=system_test inv=not(hitWhy("lobby/join","joined"))
// @witness main=system_test inv=not(hitWhy("lobby/join","queued"))
// @witness main=system_test inv=not(hitWhy("lobby/join","in_battle")) steps=40 samples=20000
// @witness main=system_test inv=not(hitWhy("lobby/join","invalid_lobby_id"))
// @witness main=system_test inv=not(hitWhy("lobby/leave","left"))
// @witness main=system_test inv=not(hitWhy("lobby/startBattle","accepted"))
// @witness main=system_test inv=not(hitWhy("lobby/joinBattle","joined_battle")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("lobby/joinBattle","no_battle"))
// -- autohost start / failure / end, lobby- and matchmaking-originated
// @witness main=system_test inv=not(hitWhy("env/autohostStarted","lobby_started"))
// @witness main=system_three inv=not(hitWhy("env/autohostStarted","match_started")) steps=30 samples=20000
// @witness main=system_three inv=not(hitWhy("env/autohostStarted","killed")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("env/autohostFailed","lobby_failed"))
// @witness main=system_three inv=not(hitWhy("env/autohostFailed","retried")) steps=30 samples=20000
// @witness main=system_three inv=not(hitWhy("env/startGaveUp","gave_up")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("env/battleEnded","ended_lobby")) steps=30 samples=20000
// @witness main=system_three inv=not(hitWhy("env/battleEnded","ended_match")) steps=30 samples=20000
// @witness main=system_test inv=not(hitWhy("env/lobbyCrashed","crashed"))
// @witness main=system_three inv=not(w_startingDisbanded) steps=30 samples=20000
// @witness main=system_test inv=not(w_orphanBattle) steps=30 samples=20000
// @witness main=system_test inv=not(w_crashOrphansBattle) steps=30 samples=20000
// -- messaging and friend across sessions
// @witness main=system_test inv=not(hitWhy("messaging/subscribeReceived","subscribed"))
// @witness main=system_test inv=not(w_msgDelivered)
// @witness main=system_test inv=not(w_msgNotToDetached)
// @witness main=system_test inv=not(hitWhy("messaging/send","invalid_target"))
// @witness main=system_test inv=not(hitWhy("friend/sendRequest","requested"))
// @witness main=system_test inv=not(hitWhy("friend/sendRequest","auto_accepted"))
// @witness main=system_test inv=not(w_friendEventLost)
//
// @verify main=system_small inv=safety steps=2
module system {
  import common.* from "./common"

  // ------------------------------------------------------------- vocabulary
  // INT-D1: session.qnt presence. INT-D5: this module defines its own types.
  type Presence = Online | Detached | Offline
  type Origin = FromLobby(int) | FromMatch(int)
  type BPhase = BStarting | BRunning
  // autohost.qnt `Battle` abstracted: PStarting -> BStarting, PRunning ->
  // BRunning; PEnded/PLost/PFailed battles are removed. `users` is
  // `participants` (set when the battle runs).
  type Battle = { origin: Origin, users: Set[UserId], phase: BPhase }
  // lobby.qnt `Battle` (NoBattle | Starting | Running) with the battle id.
  type LBattle = LNone | LStarting(int) | LRunning(int)
  type Lobby = { members: Set[UserId], battle: LBattle }
  // party.qnt `Party` (invite generations abstracted).
  type Party = { members: Set[UserId], invited: Set[UserId], queued: bool }
  // matchmaking.qnt `Match`: Starting carries the battle id being started.
  type MPhase = ReadyCheck | Starting(int)
  type Match = { tickets: Set[Set[UserId]], ready: Set[UserId], phase: MPhase }
  type State = {
    presence: UserId -> Presence,
    sock: UserId -> int,               // socket generation (session.qnt conn ids)
    msgSub: UserId -> int,             // socket messaging is subscribed on; -1 none
    friends: Set[(UserId, UserId)],    // symmetric
    requests: Set[(UserId, UserId)],   // (from, to)
    parties: int -> Party,
    lobbies: int -> Lobby,
    searching: Set[Set[UserId]],       // matchmaking.qnt `searching` (ticket = members)
    matches: int -> Match,
    battles: int -> Battle,
    nextId: int,                       // ids for parties, lobbies, matches, battles
  }
  // The union of the groups' server->user messages that cross boundaries.
  type Event =
    | Self                                                    // user/self (full state)
    | PartyInvited(int) | PartyUpdated(int) | PartyRemoved(int)
    | QueuesJoined | Found | FoundUpdate(int) | Lost | Cancelled(str)
    | LobbyUpdated(int) | LobbyLeft(str)
    | BattleStart(int) | BattleEnded(int)                     // battle/start request, battle/ended
    | MsgReceived(str)                                        // messaging/received, source kind
    | FriendRequestReceived(UserId) | FriendRequestAccepted(UserId)
  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)], why: str }
  type Eff = { st: State, ev: Set[(UserId, Event)] }

  const USERS: Set[UserId]
  const MATCH_SIZE: int     // members of a found match (all queues alike)
  const MAX_PARTY: int      // party.qnt MAX_MEMBERS; < MATCH_SIZE (no party_too_big)

  pure val SESSION_STEPS = Set("env/connect", "env/disconnect", "env/reconnect", "env/takeover",
                               "env/sessionExpired", "system/disconnect")
  pure val CANCELLED_REASONS =
    Set("intentional", "server_error", "party_user_left", "ready_timeout", "version_changed")

  // ------------------------------------------------------------- helpers
  pure def isOnline(s: State, u: UserId): bool = s.presence.get(u) == Online
  // party
  pure def partyIdsOf(s: State, u: UserId): Set[int] =
    s.parties.keys().filter(p => s.parties.get(p).members.contains(u))
  pure def partyIdOf(s: State, u: UserId): int = theOne(partyIdsOf(s, u), -1)
  pure def invitesOf(s: State, u: UserId): Set[int] =
    s.parties.keys().filter(p => s.parties.get(p).invited.contains(u))
  // matchmaking.qnt `groupOf`: the queueing unit of u
  pure def groupOf(s: State, u: UserId): Set[UserId] =
    if (partyIdOf(s, u) < 0) Set(u) else s.parties.get(partyIdOf(s, u)).members
  // matchmaking
  pure def matchMembers(m: Match): Set[UserId] = m.tickets.flatten()
  pure def searchingOf(s: State, u: UserId): Set[Set[UserId]] = s.searching.filter(t => t.contains(u))
  pure def matchIdsOf(s: State, u: UserId): Set[int] =
    s.matches.keys().filter(m => matchMembers(s.matches.get(m)).contains(u))
  pure def matchIdOf(s: State, u: UserId): int = theOne(matchIdsOf(s, u), -1)
  pure def inMatch(s: State, u: UserId): bool = matchIdsOf(s, u) != Set()
  // matchmaking.qnt `inMM`
  pure def inTicket(s: State, u: UserId): bool = searchingOf(s, u) != Set() or inMatch(s, u)
  pure def allTickets(s: State): Set[Set[UserId]] =
    s.searching.union(s.matches.keys().map(m => s.matches.get(m).tickets).flatten())
  // lobby
  pure def lobbyIdsOf(s: State, u: UserId): Set[int] =
    s.lobbies.keys().filter(l => s.lobbies.get(l).members.contains(u))
  pure def lobbyIdOf(s: State, u: UserId): int = theOne(lobbyIdsOf(s, u), -1)
  pure def inLobby(s: State, u: UserId): bool = lobbyIdsOf(s, u) != Set()
  // battle
  pure def runningOf(s: State, u: UserId): Set[int] =
    s.battles.keys().filter(b => s.battles.get(b).phase == BRunning and s.battles.get(b).users.contains(u))
  // session.qnt `Playing`
  pure def playing(s: State, u: UserId): bool = runningOf(s, u) != Set()
  pure def isMatchOrigin(o: Origin): bool = match o { | FromMatch(_) => true | FromLobby(_) => false }
  pure def ownLobbyBattle(s: State, u: UserId, b: int): bool = match s.battles.get(b).origin {
    | FromLobby(l) => lobbyIdsOf(s, u).contains(l)
    | FromMatch(_) => false
  }
  // INT-D4: a battle started from a lobby belongs to the lobby activity while
  // the user is in that lobby; otherwise (matchmaking battle, or a lobby
  // battle the user's lobby no longer holds: INT-03) it is its own slot.
  pure def slotBattle(s: State, u: UserId): bool = runningOf(s, u).exists(b => not(ownLobbyBattle(s, u, b)))
  pure def slotCount(s: State, u: UserId): int =
    (if (inLobby(s, u)) 1 else 0) + (if (inTicket(s, u)) 1 else 0) + (if (slotBattle(s, u)) 1 else 0)

  // Events reach Online users only (session.qnt `eventsToAttachedOnly`,
  // party.qnt `sendOn`, friend.qnt `deliver`); the others recover via user/self.
  pure def deliver(st: State, evs: Set[(UserId, Event)]): Set[(UserId, Event)] =
    evs.filter(e => st.presence.get(e._1) == Online)
  pure def ok(e: Eff, why: str): Outcome = { state: e.st, reply: Ok, events: deliver(e.st, e.ev), why: why }
  pure def envOut(e: Eff, why: str): Outcome = { state: e.st, reply: NoReply, events: deliver(e.st, e.ev), why: why }
  pure def deny(s: State, reason: str, why: str): Outcome = { state: s, reply: Failed(reason), events: Set(), why: why }
  pure def noop(s: State, why: str): Outcome = { state: s, reply: NoReply, events: Set(), why: why }
  pure def none(s: State): Eff = { st: s, ev: Set() }

  // ------------------------------------------------------------- shared effects
  // party.qnt `partyUnqueued` for every party whose ticket is in `ts` (INT-D3).
  pure def unqueue(s: State, ts: Set[Set[UserId]]): State =
    { ...s, parties: s.parties.keys().mapBy(p => {
        val x = s.parties.get(p)
        if (ts.contains(x.members)) { ...x, queued: false } else x }) }

  // matchmaking.qnt `disband`: the withdrawn tickets leave; the others get
  // `lost` and resume searching. A battle being started for the match stays
  // in flight with a dead origin; a late success is killed (INT-05).
  pure def disband(s: State, mid: int, withdrawn: Set[Set[UserId]]): Eff = {
    val back = s.matches.get(mid).tickets.exclude(withdrawn)
    { st: { ...s, matches: mapRemove(s.matches, mid), searching: s.searching.union(back) },
      ev: send(back.flatten(), Lost) }
  }

  // matchmaking.qnt `withdraw` + party.qnt `partyUnqueued` (INT-D3: the lock
  // ends on withdrawal).
  pure def withdraw(s: State, u: UserId, selfReason: str, notifySelf: bool): Eff = {
    val mine = searchingOf(s, u)
    val mid = matchIdOf(s, u)
    val t = if (mine != Set()) theOne(mine, Set())
            else if (mid >= 0) theOne(s.matches.get(mid).tickets.filter(x => x.contains(u)), Set())
            else Set()
    val selfEv = if (notifySelf) Set((u, Cancelled(selfReason))) else Set()
    val ev = selfEv.union(send(t.exclude(Set(u)), Cancelled("party_user_left")))
    if (mine != Set()) { st: unqueue({ ...s, searching: s.searching.exclude(mine) }, Set(t)), ev: ev }
    else if (mid >= 0) {
      val d = disband(s, mid, Set(t))
      { st: unqueue(d.st, Set(t)), ev: d.ev.union(ev) }
    } else none(s)
  }

  // party.qnt `removeMember` composed with matchmaking.qnt `partyLeave`
  // (PARTY-14/15/16, MM-15): any membership change withdraws the party's
  // ticket with party_user_left to every member (the leaver too if notifySelf).
  pure def dropFromParty(s: State, u: UserId, removedToU: bool, notifySelf: bool): Eff = {
    val p = partyIdOf(s, u)
    if (p < 0) none(s)
    else {
      val w = withdraw(s, u, "party_user_left", notifySelf)
      val x = w.st.parties.get(p)
      val rest = x.members.exclude(Set(u))
      val toU = if (removedToU) Set((u, PartyRemoved(p))) else Set()
      if (rest == Set())
        { st: { ...w.st, parties: mapRemove(w.st.parties, p) },
          ev: w.ev.union(send(x.invited, PartyRemoved(p))).union(toU) }
      else
        { st: { ...w.st, parties: w.st.parties.set(p, { ...x, members: rest, queued: false }) },
          ev: w.ev.union(send(rest.union(x.invited), PartyUpdated(p))).union(toU) }
    }
  }

  // party.qnt `sessionExpired` (invite part): the user's invites disappear.
  pure def dropInvites(s: State, u: UserId): Eff =
    { st: { ...s, parties: s.parties.keys().mapBy(p => {
                    val x = s.parties.get(p)
                    { ...x, invited: x.invited.exclude(Set(u)) } }) },
      ev: invitesOf(s, u).map(p => send(s.parties.get(p).members, PartyUpdated(p))).flatten() }

  // lobby.qnt `removeMember` + `finish` (empty lobbies are disposed). The
  // lobby's battle is not touched: it runs on the autohost (INT-03).
  pure def dropFromLobby(s: State, u: UserId): Eff = {
    val l = lobbyIdOf(s, u)
    if (l < 0) none(s)
    else {
      val x = s.lobbies.get(l)
      val rest = x.members.exclude(Set(u))
      if (rest == Set()) none({ ...s, lobbies: mapRemove(s.lobbies, l) })
      else { st: { ...s, lobbies: s.lobbies.set(l, { ...x, members: rest }) }, ev: send(rest, LobbyUpdated(l)) }
    }
  }

  // The session ends. session.qnt `endSession`; matchmaking.qnt
  // `sessionExpired` (withdraw, no event to u); party.qnt `sessionExpired`;
  // lobby.qnt `sessionExpired` (no lobby/left); messaging.qnt
  // `sessionExpired`; friend.qnt `sessionExpired` (friends unchanged).
  // Battle participation is not touched (autohost-side).
  pure def endSession(s: State, u: UserId): Eff = {
    val w = withdraw(s, u, "", false)
    val a = dropFromParty(w.st, u, false, false)
    val b = dropInvites(a.st, u)
    val c = dropFromLobby(b.st, u)
    { st: { ...c.st, presence: c.st.presence.set(u, Offline), msgSub: c.st.msgSub.set(u, -1) },
      ev: w.ev.union(a.ev).union(b.ev).union(c.ev) }
  }

  // ------------------------------------------------------------- session (INT-D1/D2)
  // session.qnt `openSocket`: a new socket, user/self, messaging unsubscribed
  // (messaging.qnt `connect`/`reconnect`/`takeover`, ASSUMPTION MSG-A9).
  pure def openSocket(s: State, u: UserId): Eff =
    { st: { ...s, presence: s.presence.set(u, Online), sock: s.sock.set(u, s.sock.get(u) + 1),
                  msgSub: s.msgSub.set(u, -1) },
      ev: Set((u, Self)) }
  // session.qnt `connect`; party/messaging/friend `connect`.
  pure def connect(s: State, u: UserId): Outcome =
    if (s.presence.get(u) != Offline) noop(s, "has_session") else envOut(openSocket(s, u), "connected")
  // session.qnt `socketDrop`; party/messaging/friend `disconnect`; no lobby or
  // matchmaking step (a detached member fails the ready check by not readying).
  pure def socketDrop(s: State, u: UserId): Outcome =
    if (not(isOnline(s, u))) noop(s, "not_online")
    else envOut(none({ ...s, presence: s.presence.set(u, Detached), msgSub: s.msgSub.set(u, -1) }), "detached")
  // session.qnt `reconnect`; party/messaging/friend `reconnect`.
  pure def reconnect(s: State, u: UserId): Outcome =
    if (s.presence.get(u) != Detached) noop(s, "not_detached") else envOut(openSocket(s, u), "reattached")
  // INT-D1: session.qnt `takeover`; party/messaging/friend `takeover`. The
  // session and everything it holds survive; only the socket changes.
  pure def takeover(s: State, u: UserId): Outcome =
    if (not(isOnline(s, u))) noop(s, "not_online") else envOut(openSocket(s, u), "taken_over")
  // session.qnt `sessionExpired` (+ every module's `sessionExpired`).
  // INT-D2 (ASSUMPTION, teiserver): a user in a running battle keeps the session.
  pure def sessionExpired(s: State, u: UserId): Outcome =
    if (s.presence.get(u) != Detached) noop(s, "not_detached")
    else if (playing(s, u)) noop(s, "kept_while_playing")
    else envOut(endSession(s, u), "expired")
  // session.qnt `disconnect` (SESSION-09: ends the session at once, also
  // while playing; INT-07). The caller is Online.
  pure def systemDisconnect(s: State, u: UserId): Outcome = ok(endSession(s, u), "disconnected")

  // ------------------------------------------------------------- party
  // party.qnt `create`; matchmaking.qnt `partyJoin` (PARTY-20: a solo ticket is
  // cancelled with `intentional`; C4: refused in a found match, INT-06).
  pure def partyCreate(s: State, u: UserId): Outcome =
    if (partyIdOf(s, u) >= 0) deny(s, "invalid_request", "already_in_party")
    else if (inMatch(s, u)) deny(s, "invalid_request", "in_found_match")
    else {
      val solo = searchingOf(s, u)
      ok({ st: { ...s, searching: s.searching.exclude(solo),
                       parties: s.parties.put(s.nextId, { members: Set(u), invited: Set(), queued: false }),
                       nextId: s.nextId + 1 },
           ev: send(solo.flatten(), Cancelled("intentional")) },
         if (solo != Set()) "solo_cancelled" else "created")
    }

  // party.qnt `invite` (PARTY-A2 connected = Online; PARTY-14: refused while
  // the party is locked). Party membership is independent of lobbies (I4).
  pure def partyInvite(s: State, u: UserId, t: UserId): Outcome = {
    val p = partyIdOf(s, u)
    if (p < 0) deny(s, "invalid_request", "not_in_party")
    else {
      val x = s.parties.get(p)
      if (not(isOnline(s, t))) deny(s, "invalid_request", "target_not_connected")
      else if (x.members.union(x.invited).contains(t)) deny(s, "invalid_request", "already_member_or_invited")
      else if (x.queued) deny(s, "invalid_request", "party_in_matchmaking")
      else if (x.members.size() + x.invited.size() >= MAX_PARTY) deny(s, "invalid_request", "party_full")
      else ok({ st: { ...s, parties: s.parties.set(p, { ...x, invited: x.invited.union(Set(t)) }) },
                ev: Set((t, PartyInvited(p))).union(send(x.members, PartyUpdated(p))) }, "invited")
    }
  }

  // party.qnt `accept` (switching parties leaves the old one: a locked old
  // party withdraws, PARTY-14); matchmaking.qnt `partyJoin` (PARTY-20, C4).
  pure def partyAccept(s: State, u: UserId, p: int): Outcome =
    if (not(s.parties.keys().contains(p)) or not(s.parties.get(p).invited.contains(u)))
      deny(s, "invalid_request", "not_invited")
    else if (inMatch(s, u)) deny(s, "invalid_request", "in_found_match")
    else {
      val wasQueued = partyIdOf(s, u) >= 0 and s.parties.get(partyIdOf(s, u)).queued
      val a = dropFromParty(s, u, false, true)
      val solo = searchingOf(a.st, u)
      val x = a.st.parties.get(p)
      val x2 = { ...x, members: x.members.union(Set(u)), invited: x.invited.exclude(Set(u)) }
      ok({ st: { ...a.st, searching: a.st.searching.exclude(solo), parties: a.st.parties.set(p, x2) },
           ev: a.ev.union(send(solo.flatten(), Cancelled("intentional")))
                   .union(send(x2.members.union(x2.invited), PartyUpdated(p))) },
         if (wasQueued) "left_queued_party" else if (solo != Set()) "solo_cancelled" else "joined")
    }

  pure def leaveWhy(s: State, u: UserId, plain: str, unqueued: str, declined: str): str =
    if (inMatch(s, u)) declined else if (searchingOf(s, u) != Set()) unqueued else plain

  // party.qnt `leave` + matchmaking.qnt `partyLeave` (PARTY-15, MM-19).
  pure def partyLeave(s: State, u: UserId): Outcome =
    if (partyIdOf(s, u) < 0) ok(none(s), "not_in_party_noop")          // PARTY-10
    else ok(dropFromParty(s, u, false, true), leaveWhy(s, u, "left", "left_unqueued", "left_declined"))

  // party.qnt `kick` + matchmaking.qnt `partyLeave` (PARTY-16: the kicked
  // member's ticket is withdrawn too; MM-18/19).
  pure def partyKick(s: State, u: UserId, t: UserId): Outcome = {
    val p = partyIdOf(s, u)
    if (p < 0) deny(s, "invalid_request", "not_in_party")
    else if (t == u) deny(s, "invalid_request", "kick_self")
    else if (not(s.parties.get(p).members.contains(t))) deny(s, "invalid_request", "target_not_member")
    else ok(dropFromParty(s, t, true, true), leaveWhy(s, t, "kicked", "kicked_unqueued", "kicked_declined"))
  }

  // ------------------------------------------------------------- matchmaking
  // matchmaking.qnt `queue` (guard order MM-03; INT-D4: already_in_battle for
  // any battle, invalid_request for a lobby). A party member who is not
  // Online cannot answer checkAssets: "if it times out without sending a
  // response, the matchmaking queue request will fail" -> party_missing_asset
  // (INT-04). party.qnt `partyQueued` locks the party and drops its invites.
  pure def mmQueue(s: State, u: UserId): Outcome = {
    val g = groupOf(s, u)
    val others = g.exclude(Set(u))
    if (g.exists(x => playing(s, x))) deny(s, "already_in_battle", "already_in_battle")
    else if (g.exists(x => inLobby(s, x))) deny(s, "invalid_request", "in_lobby")
    else if (g.exists(x => inMatch(s, x))) deny(s, "already_queued", "already_queued")
    else if (others.exists(x => not(isOnline(s, x)))) deny(s, "party_missing_asset", "member_detached")
    else {
      val replaced = s.searching.filter(t => t.intersect(g) != Set())
      val p = partyIdOf(s, u)
      val s1 = { ...s, searching: s.searching.exclude(replaced).union(Set(g)) }
      val why = if (replaced != Set()) "replaced" else if (others != Set()) "party_queued" else "queued"
      if (p < 0) ok(none(s1), why)
      else {
        val x = s.parties.get(p)
        ok({ st: { ...s1, parties: s1.parties.set(p, { ...x, invited: Set(), queued: true }) },
             ev: send(others, QueuesJoined).union(send(x.invited, PartyRemoved(p)))
                   .union(if (x.invited != Set()) send(x.members, PartyUpdated(p)) else Set()) }, why)
      }
    }
  }

  // matchmaking.qnt `cancel`.
  pure def mmCancel(s: State, u: UserId): Outcome =
    if (not(inTicket(s, u))) deny(s, "not_queued", "not_queued")
    else ok(withdraw(s, u, "intentional", true), if (inMatch(s, u)) "declined" else "left_queue")

  // matchmaking.qnt `ready`; all ready -> autohost.qnt `requestBattle`.
  pure def mmReady(s: State, u: UserId): Outcome = {
    val mid = matchIdOf(s, u)
    if (mid < 0) deny(s, "no_match", "no_match")
    else {
      val m = s.matches.get(mid)
      if (m.ready.contains(u)) ok(none(s), "already_ready")
      else {
        val r = m.ready.union(Set(u))
        val allReady = r == matchMembers(m)
        val b = s.nextId
        val s1 = { ...s, matches: s.matches.set(mid, { ...m, ready: r, phase: if (allReady) Starting(b) else ReadyCheck }) }
        val s2 = if (allReady) { ...s1, battles: s1.battles.put(b, { origin: FromMatch(mid), users: Set(), phase: BStarting }),
                                        nextId: b + 1 }
                 else s1
        ok({ st: s2, ev: send(matchMembers(m), FoundUpdate(r.size())) }, if (allReady) "all_ready" else "readied")
      }
    }
  }

  // matchmaking.qnt `matchable` (team shapes abstracted) and `matchFound`.
  // INT-D3: the parties stay locked.
  pure def matchable(s: State, ts: Set[Set[UserId]]): bool =
    ts.size() >= 2 and ts.subseteq(s.searching) and ts.flatten().size() == MATCH_SIZE
  pure def matchFound(s: State, ts: Set[Set[UserId]]): Outcome =
    if (not(matchable(s, ts))) noop(s, "none")
    else envOut({ st: { ...s, searching: s.searching.exclude(ts),
                              matches: s.matches.put(s.nextId, { tickets: ts, ready: Set(), phase: ReadyCheck }),
                              nextId: s.nextId + 1 },
                  ev: send(ts.flatten(), Found) }, "found")

  // matchmaking.qnt `readyTimeout` (MM-08); the failed parties are unlocked,
  // the resumed ones stay locked (INT-D3, MM-18).
  pure def readyTimeout(s: State, mid: int): Outcome =
    if (not(s.matches.keys().contains(mid)) or s.matches.get(mid).phase != ReadyCheck) noop(s, "none")
    else {
      val m = s.matches.get(mid)
      val failed = m.tickets.filter(t => not(t.subseteq(m.ready)))
      val d = disband(s, mid, failed)
      val f = failed.flatten()
      envOut({ st: unqueue(d.st, failed),
               ev: d.ev.union(send(f, Lost)).union(send(f.exclude(m.ready), Cancelled("ready_timeout")))
                       .union(send(f.intersect(m.ready), Cancelled("party_user_left"))) }, "lost")
    }

  // matchmaking.qnt `startGaveUp` (MM-13); the in-flight start is abandoned.
  pure def startGaveUp(s: State, mid: int): Outcome =
    if (not(s.matches.keys().contains(mid))) noop(s, "none")
    else {
      val m = s.matches.get(mid)
      match m.phase {
        | ReadyCheck => noop(s, "none")
        | Starting(b) =>
            envOut({ st: unqueue({ ...s, matches: mapRemove(s.matches, mid), battles: mapRemove(s.battles, b) }, m.tickets),
                     ev: send(matchMembers(m), Lost).union(send(matchMembers(m), Cancelled("server_error"))) },
                   "gave_up")
      }
    }

  // ------------------------------------------------------------- autohost / battle
  // autohost/start Ok (autohost.qnt `onResponse` -> PRunning). Lobby origin:
  // lobby.qnt `autohostStarted` (battle/start to the members). Match origin:
  // matchmaking.qnt `battleStarted` (battle/start to the match; INT-D3: the
  // party lock ends). Origin gone (lobby disposed or crashed, match
  // disbanded): the late success is killed (autohost/kill; INT-05).
  pure def autohostStarted(s: State, b: int): Outcome =
    if (not(s.battles.keys().contains(b)) or s.battles.get(b).phase != BStarting) noop(s, "none")
    else {
      val x = s.battles.get(b)
      val killed = envOut(none({ ...s, battles: mapRemove(s.battles, b) }), "killed")
      match x.origin {
        | FromLobby(l) =>
            if (s.lobbies.keys().contains(l) and s.lobbies.get(l).battle == LStarting(b)) {
              val ms = s.lobbies.get(l).members
              envOut({ st: { ...s, lobbies: s.lobbies.set(l, { ...s.lobbies.get(l), battle: LRunning(b) }),
                                   battles: s.battles.set(b, { ...x, users: ms, phase: BRunning }) },
                       ev: send(ms, BattleStart(b)).union(send(ms, LobbyUpdated(l))) }, "lobby_started")
            } else killed
        | FromMatch(mid) =>
            if (s.matches.keys().contains(mid) and s.matches.get(mid).phase == Starting(b)) {
              val m = s.matches.get(mid)
              val ms = matchMembers(m)
              envOut({ st: unqueue({ ...s, matches: mapRemove(s.matches, mid),
                                           battles: s.battles.set(b, { ...x, users: ms, phase: BRunning }) }, m.tickets),
                       ev: send(ms, BattleStart(b)) }, "match_started")
            } else killed
      }
    }

  // autohost/start failed or timed out (autohost.qnt PFailed). Lobby origin:
  // lobby.qnt `autohostFailed` (silent, LOBBY-21). Match origin:
  // matchmaking.qnt `startFailed` -- "repeat this step", with a fresh battle id
  // (AH-05/AH-12 recommendation).
  pure def autohostFailed(s: State, b: int): Outcome =
    if (not(s.battles.keys().contains(b)) or s.battles.get(b).phase != BStarting) noop(s, "none")
    else {
      val x = s.battles.get(b)
      val s0 = { ...s, battles: mapRemove(s.battles, b) }
      match x.origin {
        | FromLobby(l) =>
            if (s.lobbies.keys().contains(l) and s.lobbies.get(l).battle == LStarting(b))
              envOut(none({ ...s0, lobbies: s0.lobbies.set(l, { ...s0.lobbies.get(l), battle: LNone }) }), "lobby_failed")
            else envOut(none(s0), "dropped")
        | FromMatch(mid) =>
            if (s.matches.keys().contains(mid) and s.matches.get(mid).phase == Starting(b)) {
              val nb = s.nextId
              envOut(none({ ...s0, matches: s0.matches.set(mid, { ...s0.matches.get(mid), phase: Starting(nb) }),
                                   battles: s0.battles.put(nb, { ...x, users: Set() }), nextId: nb + 1 }), "retried")
            } else envOut(none(s0), "dropped")
      }
    }

  // battle/ended (autohost.qnt PEnded via engine_quit, or PLost via the
  // autohost's grace expiry). Lobby origin: lobby.qnt `battleEnded` if the
  // lobby still holds it. Match origin: matchmaking.qnt `battleEnded`.
  // INT-D2: from now on a Detached participant's grace runs again (INT-02).
  pure def battleEnded(s: State, b: int): Outcome =
    if (not(s.battles.keys().contains(b)) or s.battles.get(b).phase != BRunning) noop(s, "none")
    else {
      val x = s.battles.get(b)
      val s0 = { ...s, battles: mapRemove(s.battles, b) }
      val ev = send(x.users, BattleEnded(b))
      match x.origin {
        | FromLobby(l) =>
            if (s.lobbies.keys().contains(l) and s.lobbies.get(l).battle == LRunning(b))
              envOut({ st: { ...s0, lobbies: s0.lobbies.set(l, { ...s0.lobbies.get(l), battle: LNone }) },
                       ev: ev.union(send(s.lobbies.get(l).members, LobbyUpdated(l))) }, "ended_lobby")
            else envOut({ st: s0, ev: ev }, "ended_lobby")
        | FromMatch(_) => envOut({ st: s0, ev: ev }, "ended_match")
      }
    }

  // ------------------------------------------------------------- lobby
  // lobby.qnt `create` (INT-D4: invalid_request while in a lobby, queued, or
  // in a battle outside a lobby).
  pure def lobbyCreate(s: State, u: UserId): Outcome =
    if (inLobby(s, u)) deny(s, "invalid_request", "in_lobby")
    else if (inTicket(s, u)) deny(s, "invalid_request", "queued")
    else if (playing(s, u)) deny(s, "invalid_request", "in_battle")
    else ok(none({ ...s, lobbies: s.lobbies.put(s.nextId, { members: Set(u), battle: LNone }), nextId: s.nextId + 1 }),
            "created")

  // lobby.qnt `join` (INT-D4). A user still in the battle of lobby l may come
  // back to l (the slots merge again); any other battle refuses.
  pure def lobbyJoin(s: State, u: UserId, l: int): Outcome =
    if (not(s.lobbies.keys().contains(l))) deny(s, "invalid_lobby_id", "invalid_lobby_id")
    else if (s.lobbies.get(l).members.contains(u)) ok(none(s), "already_member")
    else if (inLobby(s, u)) deny(s, "invalid_request", "in_other_lobby")
    else if (inTicket(s, u)) deny(s, "invalid_request", "queued")
    else if (runningOf(s, u).exists(b => s.battles.get(b).origin != FromLobby(l))) deny(s, "invalid_request", "in_battle")
    else {
      val x = s.lobbies.get(l)
      ok({ st: { ...s, lobbies: s.lobbies.set(l, { ...x, members: x.members.union(Set(u)) }) },
           ev: send(x.members, LobbyUpdated(l)) }, "joined")
    }

  // lobby.qnt `leave`. The user stays in a running battle (INT-03).
  pure def lobbyLeave(s: State, u: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby", "not_in_lobby") else ok(dropFromLobby(s, u), "left")

  // lobby.qnt `startBattle` (votes and bosses abstracted: accepted) +
  // autohost.qnt `requestBattle`.
  pure def lobbyStartBattle(s: State, u: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby", "not_in_lobby")
    else {
      val l = lobbyIdOf(s, u)
      val b = s.nextId
      if (s.lobbies.get(l).battle != LNone) deny(s, "invalid_request", "battle_exists")
      else ok(none({ ...s, lobbies: s.lobbies.set(l, { ...s.lobbies.get(l), battle: LStarting(b) }),
                           battles: s.battles.put(b, { origin: FromLobby(l), users: Set(), phase: BStarting }),
                           nextId: b + 1 }), "accepted")
    }

  // lobby.qnt `joinBattle` + autohost.qnt `sendAddPlayer` (assumed Ok, AH-20).
  pure def lobbyJoinBattle(s: State, u: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby", "not_in_lobby")
    else match s.lobbies.get(lobbyIdOf(s, u)).battle {
      | LRunning(b) =>
          ok({ st: { ...s, battles: s.battles.set(b, { ...s.battles.get(b), users: s.battles.get(b).users.union(Set(u)) }) },
               ev: Set((u, BattleStart(b))) }, "joined_battle")
      | _ => deny(s, "no_battle", "no_battle")
    }

  // lobby.qnt `lobbyCrashed`: lobby/left "crashed" to the members. A running
  // battle survives on the autohost (teiserver session.ex:1648-1652; INT-03).
  pure def lobbyCrashed(s: State, l: int): Outcome =
    if (not(s.lobbies.keys().contains(l))) noop(s, "none")
    else envOut({ st: { ...s, lobbies: mapRemove(s.lobbies, l) },
                  ev: send(s.lobbies.get(l).members, LobbyLeft("crashed")) }, "crashed")

  // ------------------------------------------------------------- messaging
  // messaging.qnt `subscribeReceived`: bound to the current socket (MSG-A9).
  pure def msgSubscribe(s: State, u: UserId): Outcome =
    ok(none({ ...s, msgSub: s.msgSub.set(u, s.sock.get(u)) }), "subscribed")
  pure def subscribedNow(s: State, u: UserId): bool = isOnline(s, u) and s.msgSub.get(u) == s.sock.get(u)
  // messaging.qnt `sendMessage` to a party or lobby: recipients are the other
  // members; delivered now to the subscribed ones, buffered for the others.
  pure def msgSend(s: State, u: UserId, kind: str): Outcome = {
    val p = partyIdOf(s, u)
    val l = lobbyIdOf(s, u)
    val rs = if (kind == "party") (if (p < 0) Set() else s.parties.get(p).members)
             else (if (l < 0) Set() else s.lobbies.get(l).members)
    if (rs == Set()) deny(s, "invalid_target", "invalid_target")
    else ok({ st: s, ev: rs.exclude(Set(u)).filter(x => subscribedNow(s, x)).map(x => (x, MsgReceived(kind))) }, "sent")
  }

  // ------------------------------------------------------------- friend
  // friend.qnt `sendRequest` (mutual request auto-accepts). Independent of
  // every other group; events only to Online users.
  pure def friendSend(s: State, u: UserId, t: UserId): Outcome =
    if (t == u) deny(s, "invalid_user", "invalid_user")
    else if (s.friends.contains((u, t))) deny(s, "already_in_friendlist", "already_in_friendlist")
    else if (s.requests.contains((u, t))) deny(s, "invalid_request", "repeated")
    else if (s.requests.contains((t, u)))
      ok({ st: { ...s, friends: s.friends.union(Set((u, t), (t, u))), requests: s.requests.exclude(Set((t, u))) },
           ev: Set((t, FriendRequestAccepted(u))) }, "auto_accepted")
    else ok({ st: { ...s, requests: s.requests.union(Set((u, t))) }, ev: Set((t, FriendRequestReceived(u))) }, "requested")

  // ------------------------------------------------------------- state machine
  var s: State
  var prev: State
  var lastCmd: str
  var lastActor: UserId
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]
  var lastWhy: str

  pure val INIT: State = {
    presence: USERS.mapBy(_ => Online), sock: USERS.mapBy(_ => 0), msgSub: USERS.mapBy(_ => -1),
    friends: Set(), requests: Set(), parties: Map(), lobbies: Map(), searching: Set(),
    matches: Map(), battles: Map(), nextId: 0,
  }

  action apply(cmd: str, actor: UserId, o: Outcome): bool = all {
    prev' = s, s' = o.state, lastCmd' = cmd, lastActor' = actor, lastReply' = o.reply,
    lastEvents' = o.events, lastWhy' = o.why,
  }
  action init = all {
    s' = INIT, prev' = INIT, lastCmd' = "init", lastActor' = "", lastReply' = NoReply,
    lastEvents' = Set(), lastWhy' = "init",
  }
  // A request is served only on a live socket (session.qnt `pendingOnLiveSocket`).
  pure def orNone(xs: Set[int]): Set[int] = if (xs == Set()) Set(-1) else xs
  action req(cmd: str, u: UserId, o: Outcome): bool = all { isOnline(s, u), apply(cmd, u, o) }

  pure def pick(xs: Set[UserId], d: UserId): Set[UserId] = if (xs == Set()) Set(d) else xs
  pure def battlesIn(s: State, ph: BPhase): Set[int] = s.battles.keys().filter(b => s.battles.get(b).phase == ph)

  action step = {
    nondet u = USERS.oneOf()
    nondet t = USERS.oneOf()
    // Arguments are drawn from what exists (or a non-existing id when nothing
    // does), and some branches pick a user for whom the step does something,
    // so that simulation reaches deep cross-module states. The random-user
    // branches keep every denial reachable.
    nondet p = orNone(invitesOf(s, u)).oneOf()
    nondet l = s.lobbies.keys().union(Set(s.nextId)).oneOf()
    nondet cl = orNone(s.lobbies.keys()).oneOf()
    nondet rmid = orNone(s.matches.keys().filter(m => s.matches.get(m).phase == ReadyCheck)).oneOf()
    nondet smid = orNone(s.matches.keys().filter(m => s.matches.get(m).phase != ReadyCheck)).oneOf()
    nondet sb = orNone(battlesIn(s, BStarting)).oneOf()
    nondet rb = orNone(battlesIn(s, BRunning)).oneOf()
    nondet ts = s.searching.powerset().filter(x => matchable(s, x)).union(Set(Set())).oneOf()
    nondet kind = Set("party", "lobby").oneOf()
    nondet qu = pick(USERS.filter(x => isOnline(s, x) and not(inTicket(s, x))), u).oneOf()
    nondet ru = pick(USERS.filter(x => inMatch(s, x) and not(s.matches.get(matchIdOf(s, x)).ready.contains(x))), u).oneOf()
    nondet du = pick(USERS.filter(x => s.presence.get(x) == Detached), u).oneOf()
    nondet kt = pick(groupOf(s, u).exclude(Set(u)), t).oneOf()
    // Branches are grouped; the simulator picks a group g, then a step in it.
    // The weights serve exploration only.
    nondet g = 0.to(6).oneOf()
    if (g == 0) any {
      req("party/create", u, partyCreate(s, u)),
      req("party/invite", u, partyInvite(s, u, t)),
      req("party/acceptInvite", u, partyAccept(s, u, p)),
      req("party/leave", u, partyLeave(s, u)),
      req("party/kickMember", u, partyKick(s, u, t)),
      req("party/kickMember", u, partyKick(s, u, kt)),
    }
    else if (g <= 2) any {
      req("matchmaking/queue", u, mmQueue(s, u)),
      req("matchmaking/queue", qu, mmQueue(s, qu)),
      req("matchmaking/cancel", u, mmCancel(s, u)),
      req("matchmaking/ready", u, mmReady(s, u)),
      req("matchmaking/queue", qu, mmQueue(s, qu)),
      req("matchmaking/ready", ru, mmReady(s, ru)),
      req("matchmaking/ready", ru, mmReady(s, ru)),
      req("matchmaking/ready", ru, mmReady(s, ru)),
      apply("env/match", "", matchFound(s, ts)),
      apply("env/match", "", matchFound(s, ts)),
    }
    else if (g == 3) any {
      req("lobby/create", u, lobbyCreate(s, u)),
      req("lobby/join", u, lobbyJoin(s, u, l)),
      req("lobby/leave", u, lobbyLeave(s, u)),
      req("lobby/startBattle", u, lobbyStartBattle(s, u)),
      req("lobby/joinBattle", u, lobbyJoinBattle(s, u)),
      apply("env/lobbyCrashed", "", lobbyCrashed(s, cl)),
    }
    else if (g == 4) any {
      apply("env/autohostStarted", "", autohostStarted(s, sb)),
      apply("env/autohostStarted", "", autohostStarted(s, sb)),
      apply("env/autohostFailed", "", autohostFailed(s, sb)),
      apply("env/startGaveUp", "", startGaveUp(s, smid)),
      apply("env/battleEnded", "", battleEnded(s, rb)),
      apply("env/readyTimeout", "", readyTimeout(s, rmid)),
    }
    else if (g == 5) any {
      apply("env/connect", u, connect(s, u)),
      apply("env/disconnect", u, socketDrop(s, u)),
      apply("env/reconnect", du, reconnect(s, du)),
      apply("env/takeover", u, takeover(s, u)),
      apply("env/sessionExpired", du, sessionExpired(s, du)),
      req("system/disconnect", u, systemDisconnect(s, u)),
    }
    else any {
      req("messaging/subscribeReceived", u, msgSubscribe(s, u)),
      req("messaging/send", u, msgSend(s, u, kind)),
      req("friend/sendRequest", u, friendSend(s, u, t)),
    }
  }

  // ------------------------------------------------------------- invariants
  val atMostOneParty = USERS.forall(u => partyIdsOf(s, u).size() <= 1)
  val atMostOneLobby = USERS.forall(u => lobbyIdsOf(s, u).size() <= 1)
  val atMostOneTicket = USERS.forall(u => searchingOf(s, u).size() + matchIdsOf(s, u).size() <= 1)
  val atMostOneBattle = USERS.forall(u => runningOf(s, u).size() <= 1)
  // INT-D4: at most one of lobby (with its battle), matchmaking ticket, battle.
  val activitySlot = USERS.forall(u => slotCount(s, u) <= 1)
  // matchmaking.qnt `ticketsArePartyUnits`: a party member's ticket is the
  // party's; a ticket of several users is a party.
  val ticketsArePartyUnits = allTickets(s).forall(t =>
    t.forall(u => if (partyIdOf(s, u) >= 0) t == s.parties.get(partyIdOf(s, u)).members else t == Set(u)))
  // INT-D3 (matchmaking.md C3 = party.md I2): queued(p) <=> the party has a
  // ticket (searching or in a found match); a locked party has no invites.
  val partyLockMatchesTickets = s.parties.keys().forall(p => {
    val x = s.parties.get(p)
    and { x.queued == allTickets(s).contains(x.members), x.queued implies x.invited == Set() }
  })
  // A matchmaking battle's players all hold the battle slot and nothing else.
  val mmBattleSlot = s.battles.keys().forall(b => {
    val x = s.battles.get(b)
    (x.phase == BRunning and isMatchOrigin(x.origin)) implies
      x.users.forall(u => and { slotBattle(s, u), not(inLobby(s, u)), not(inTicket(s, u)) })
  })
  // Links between lobby/match state and the battles being started or run.
  val battlesLinked = and {
    s.lobbies.keys().forall(l => match s.lobbies.get(l).battle {
      | LNone => true
      | LStarting(b) => s.battles.keys().contains(b) and s.battles.get(b) == { origin: FromLobby(l), users: Set(), phase: BStarting }
      | LRunning(b) => s.battles.keys().contains(b) and s.battles.get(b).phase == BRunning and s.battles.get(b).origin == FromLobby(l)
    }),
    s.matches.keys().forall(m => match s.matches.get(m).phase {
      | ReadyCheck => true
      | Starting(b) => s.battles.keys().contains(b) and s.battles.get(b) == { origin: FromMatch(m), users: Set(), phase: BStarting }
    }),
  }
  // No session-less user holds a lobby seat, party membership or invite,
  // ticket or messaging subscription (SESSION-08). Battle participation may
  // outlive the session only through system/disconnect (INT-07); grace expiry
  // never ends a playing user's session (INT-D2, `keptWhilePlaying`).
  val offlineIdle = USERS.forall(u => s.presence.get(u) == Offline implies and {
    not(inLobby(s, u)), partyIdsOf(s, u) == Set(), invitesOf(s, u) == Set(), not(inTicket(s, u)),
    s.msgSub.get(u) == -1,
  })
  val keptWhilePlaying = (lastCmd == "env/sessionExpired" and playing(prev, lastActor)) implies s == prev
  // INT-D1: a takeover changes only the socket (and the socket-bound
  // messaging subscription); the session and all group state survive.
  val takeoverKeepsSession = lastCmd == "env/takeover" implies
    { ...s, sock: prev.sock, msgSub: prev.msgSub } == prev
  // MSG-A9 (Tachyon silent, MSG-08): the subscription belongs to the socket.
  val msgSubSocketBound = USERS.forall(u =>
    s.msgSub.get(u) >= 0 implies (isOnline(s, u) and s.msgSub.get(u) == s.sock.get(u)))
  val msgOnlyToSubscribed = lastEvents.forall(e => match e._2 {
    | MsgReceived(_) => subscribedNow(s, e._1) and e._1 != lastActor
    | _ => true })
  val eventsOnlyToOnline = lastEvents.forall(e => isOnline(s, e._1))
  val battleStartToParticipants = lastEvents.forall(e => match e._2 {
    | BattleStart(b) => s.battles.keys().contains(b) and s.battles.get(b).users.contains(e._1)
    | _ => true })
  val foundToMatched = lastEvents.forall(e => match e._2 {
    | Found => inMatch(s, e._1) | FoundUpdate(_) => inMatch(s, e._1) | _ => true })
  val cancelledReasonsInSchema = lastEvents.forall(e => match e._2 {
    | Cancelled(r) => CANCELLED_REASONS.contains(r) | _ => true })
  val sessionStepsKeepFriends = lastCmd.in(SESSION_STEPS) implies
    (s.friends == prev.friends and s.requests == prev.requests)
  val denialsChangeNothing = match lastReply {
    | Failed(_) => s == prev and lastEvents == Set()
    | _ => true }
  val reasonsInSchema = replyInSchema(lastCmd, lastReply)

  val safety = and {
    atMostOneParty, atMostOneLobby, atMostOneTicket, atMostOneBattle, activitySlot,
    ticketsArePartyUnits, partyLockMatchesTickets, mmBattleSlot, battlesLinked, offlineIdle,
    keptWhilePlaying, takeoverKeepsSession, msgSubSocketBound, msgOnlyToSubscribed,
    eventsOnlyToOnline, battleStartToParticipants, foundToMatched, cancelledReasonsInSchema,
    sessionStepsKeepFriends, denialsChangeNothing, reasonsInSchema,
  }

  // ------------------------------------------------------------- witnesses
  def hitWhy(cmd: str, why: str): bool = lastCmd == cmd and lastWhy == why
  def sawCancelled(r: str): bool = lastEvents.exists(e => e._2 == Cancelled(r))
  val sawLost = lastEvents.exists(e => e._2 == Lost)
  val w_keptWhilePlaying = hitWhy("env/sessionExpired", "kept_while_playing")
  val w_expiryWithdrawsParty = hitWhy("env/sessionExpired", "expired") and partyIdOf(prev, lastActor) >= 0 and {
    val x = prev.parties.get(partyIdOf(prev, lastActor))
    x.queued and x.members.size() >= 2 }
  val w_expiryDisbandsMatch = hitWhy("env/sessionExpired", "expired") and sawLost
  val w_expiryLeavesLobby = hitWhy("env/sessionExpired", "expired") and inLobby(prev, lastActor)
  val w_expiryDropsInvite = hitWhy("env/sessionExpired", "expired") and invitesOf(prev, lastActor) != Set()
  val w_takeoverMidReadyCheck = hitWhy("env/takeover", "taken_over") and inMatch(s, lastActor)
    and s.matches.get(matchIdOf(s, lastActor)).phase == ReadyCheck
  val w_takeoverDropsMsgSub = hitWhy("env/takeover", "taken_over") and prev.msgSub.get(lastActor) >= 0
  val w_disconnectDropsMsgSub = hitWhy("env/disconnect", "detached") and prev.msgSub.get(lastActor) >= 0
  val w_systemDisconnectWhilePlaying = hitWhy("system/disconnect", "disconnected") and playing(s, lastActor)
  val w_offlineInBattle = USERS.exists(u => s.presence.get(u) == Offline and playing(s, u))
  val w_acceptLeavesQueuedParty = hitWhy("party/acceptInvite", "left_queued_party")
  // A party ticket goes back to searching after `lost` (ready timeout or
  // another ticket's decline/withdrawal) and stays locked (INT-D3, MM-18).
  val w_lostPartyStaysLocked = sawLost and s.parties.keys().exists(p => {
    val x = s.parties.get(p)
    and { x.members.size() >= 2, x.queued, s.searching.contains(x.members), x.members.exists(u => inMatch(prev, u)) } })
  val w_partyBattleUnlocks = hitWhy("env/autohostStarted", "match_started") and
    prev.parties.keys().exists(p => prev.parties.get(p).queued and not(s.parties.get(p).queued))
  // A match in the Starting phase (autohost/start in flight) is disbanded by a
  // user or session step (INT-05).
  val w_startingDisbanded = prev.matches.keys().exists(m =>
    prev.matches.get(m).phase != ReadyCheck and not(s.matches.keys().contains(m))) and
    not(lastCmd.in(Set("env/autohostStarted", "env/startGaveUp")))
  // A lobby battle whose player is no longer in that lobby (INT-03).
  val w_orphanBattle = USERS.exists(u => playing(s, u) and slotBattle(s, u) and
    runningOf(s, u).forall(b => not(isMatchOrigin(s.battles.get(b).origin))))
  val w_crashOrphansBattle = hitWhy("env/lobbyCrashed", "crashed") and
    s.battles.keys().exists(b => s.battles.get(b).phase == BRunning and not(isMatchOrigin(s.battles.get(b).origin)))
  val w_msgDelivered = hitWhy("messaging/send", "sent") and lastEvents != Set()
  val w_msgNotToDetached = hitWhy("messaging/send", "sent") and USERS.exists(u =>
    s.presence.get(u) == Detached and (partyIdOf(s, u) == partyIdOf(s, lastActor) and partyIdOf(s, u) >= 0
                                        or lobbyIdOf(s, u) == lobbyIdOf(s, lastActor) and lobbyIdOf(s, u) >= 0))
  val w_friendEventLost = hitWhy("friend/sendRequest", "requested") and lastEvents == Set()
}

// Main instance: 4 users, a match needs 3 players, parties of up to 2.
module system_test {
  import common.* from "./common"
  import system(USERS = Set("a", "b", "c", "d"), MATCH_SIZE = 3, MAX_PARTY = 2).*

  // Session lifecycle across party, lobby and matchmaking (INT-D1, SESSION-08).
  run sessionLifecycleTest =
    init
      .then(apply("party/create", "a", partyCreate(s, "a")))
      .then(apply("party/invite", "a", partyInvite(s, "a", "b")))
      .expect(lastEvents == Set(("b", PartyInvited(0)), ("a", PartyUpdated(0))))
      .then(apply("lobby/create", "c", lobbyCreate(s, "c")))
      .then(apply("lobby/join", "b", lobbyJoin(s, "b", 1)))
      .expect(lastWhy == "joined" and lastEvents == Set(("c", LobbyUpdated(1))))
      .then(apply("messaging/subscribeReceived", "c", msgSubscribe(s, "c")))
      // takeover: the session and everything in it survive, the messaging subscription does not
      .then(apply("env/takeover", "b", takeover(s, "b")))
      .expect(and { lastWhy == "taken_over", inLobby(s, "b"), invitesOf(s, "b") == Set(0),
                    lastEvents == Set(("b", Self)), takeoverKeepsSession })
      .then(apply("env/takeover", "c", takeover(s, "c")))
      .expect(s.msgSub.get("c") == -1)
      // socket drop: kept through the grace period; events to b are lost
      .then(apply("env/disconnect", "b", socketDrop(s, "b")))
      .then(apply("lobby/join", "d", lobbyJoin(s, "d", 1)))
      .expect(lastEvents == Set(("c", LobbyUpdated(1))))
      .then(apply("env/reconnect", "b", reconnect(s, "b")))
      .expect(lastEvents == Set(("b", Self)) and inLobby(s, "b"))
      // grace expiry: lobby seat and invite go, no lobby/left
      .then(apply("env/disconnect", "b", socketDrop(s, "b")))
      .then(apply("env/sessionExpired", "b", sessionExpired(s, "b")))
      .expect(and { lastWhy == "expired", not(inLobby(s, "b")), invitesOf(s, "b") == Set(),
                    lastEvents == Set(("a", PartyUpdated(0)), ("c", LobbyUpdated(1)), ("d", LobbyUpdated(1))) })
      .then(apply("env/sessionExpired", "b", sessionExpired(s, "b")))     // late timer
      .expect(lastWhy == "not_detached" and s == prev)
      .then(apply("env/connect", "b", connect(s, "b")))
      .expect(lastEvents == Set(("b", Self)) and offlineIdle)

  // Party in matchmaking: lock from queue to battle start (INT-D3), takeover
  // mid ready-check (INT-08), D4 denials, D2 during the battle.
  run partyMatchTest =
    init
      .then(apply("party/create", "a", partyCreate(s, "a")))
      .then(apply("party/invite", "a", partyInvite(s, "a", "b")))
      .then(apply("party/acceptInvite", "b", partyAccept(s, "b", 0)))
      .then(apply("party/invite", "b", partyInvite(s, "b", "c")))
      .expect(lastWhy == "party_full")
      .then(apply("lobby/create", "c", lobbyCreate(s, "c")))
      .then(apply("lobby/join", "b", lobbyJoin(s, "b", 1)))
      .then(apply("matchmaking/queue", "a", mmQueue(s, "a")))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "in_lobby")   // b is in a lobby (MM-04)
      .then(apply("lobby/leave", "b", lobbyLeave(s, "b")))
      .then(apply("env/disconnect", "b", socketDrop(s, "b")))
      .then(apply("matchmaking/queue", "a", mmQueue(s, "a")))
      .expect(lastReply == Failed("party_missing_asset"))                         // INT-04
      .then(apply("env/reconnect", "b", reconnect(s, "b")))
      .then(apply("matchmaking/queue", "a", mmQueue(s, "a")))
      .expect(and { lastWhy == "party_queued", s.parties.get(0).queued, lastEvents == Set(("b", QueuesJoined)) })
      .then(apply("lobby/join", "a", lobbyJoin(s, "a", 1)))
      .expect(lastReply == Failed("invalid_request") and lastWhy == "queued")      // INT-D4
      .then(apply("lobby/leave", "c", lobbyLeave(s, "c")))
      .then(apply("matchmaking/queue", "c", mmQueue(s, "c")))
      .then(apply("env/match", "", matchFound(s, Set(Set("a", "b"), Set("c")))))
      .expect(and { lastWhy == "found", s.parties.get(0).queued })                // still locked
      .then(apply("matchmaking/ready", "a", mmReady(s, "a")))
      .then(apply("env/takeover", "a", takeover(s, "a")))                         // INT-08
      .expect(s.matches.get(2).ready == Set("a"))
      .then(apply("matchmaking/ready", "a", mmReady(s, "a")))
      .expect(lastWhy == "already_ready")
      .then(apply("matchmaking/ready", "b", mmReady(s, "b")))
      .then(apply("matchmaking/ready", "c", mmReady(s, "c")))
      .expect(and { lastWhy == "all_ready", s.matches.get(2).phase == Starting(3) })
      .then(apply("env/autohostFailed", "", autohostFailed(s, 3)))
      .expect(and { lastWhy == "retried", s.matches.get(2).phase == Starting(4), not(3.in(s.battles.keys())) })
      .then(apply("env/autohostStarted", "", autohostStarted(s, 4)))
      .expect(and { lastWhy == "match_started", not(s.parties.get(0).queued),
                    lastEvents == Set(("a", BattleStart(4)), ("b", BattleStart(4)), ("c", BattleStart(4))) })
      .then(apply("lobby/create", "c", lobbyCreate(s, "c")))
      .expect(lastWhy == "in_battle")                                              // INT-D4
      .then(apply("matchmaking/queue", "a", mmQueue(s, "a")))
      .expect(lastReply == Failed("already_in_battle"))
      .then(apply("env/disconnect", "c", socketDrop(s, "c")))
      .then(apply("env/sessionExpired", "c", sessionExpired(s, "c")))
      .expect(lastWhy == "kept_while_playing" and s == prev)                     // INT-D2
      .then(apply("env/battleEnded", "", battleEnded(s, 4)))
      .expect(lastEvents == Set(("a", BattleEnded(4)), ("b", BattleEnded(4))))
      .then(apply("env/sessionExpired", "c", sessionExpired(s, "c")))            // INT-02: grace runs again
      .expect(lastWhy == "expired")

  // Membership changes of a locked party (PARTY-15/16, MM-18/19) and a
  // disband while the autohost start is in flight (INT-05).
  run partyChangeTest =
    init
      .then(apply("party/create", "a", partyCreate(s, "a")))
      .then(apply("party/invite", "a", partyInvite(s, "a", "b")))
      .then(apply("party/acceptInvite", "b", partyAccept(s, "b", 0)))
      .then(apply("matchmaking/queue", "b", mmQueue(s, "b")))
      .then(apply("party/kickMember", "a", partyKick(s, "a", "b")))
      .expect(and { lastWhy == "kicked_unqueued", not(s.parties.get(0).queued), s.searching == Set(),
                    lastEvents == Set(("a", Cancelled("party_user_left")), ("b", Cancelled("party_user_left")),
                                      ("a", PartyUpdated(0)), ("b", PartyRemoved(0))) })
      .then(apply("party/invite", "a", partyInvite(s, "a", "b")))
      .then(apply("party/acceptInvite", "b", partyAccept(s, "b", 0)))
      .then(apply("matchmaking/queue", "a", mmQueue(s, "a")))
      .then(apply("matchmaking/queue", "c", mmQueue(s, "c")))
      .then(apply("matchmaking/queue", "d", mmQueue(s, "d")))
      .then(apply("env/match", "", matchFound(s, Set(Set("a", "b"), Set("c")))))
      .then(apply("matchmaking/ready", "c", mmReady(s, "c")))
      .then(apply("env/readyTimeout", "", readyTimeout(s, 1)))
      .expect(and { lastWhy == "lost", not(s.parties.get(0).queued), s.searching == Set(Set("c"), Set("d")) })
      .then(apply("matchmaking/queue", "a", mmQueue(s, "a")))
      .then(apply("env/match", "", matchFound(s, Set(Set("a", "b"), Set("d")))))
      .then(apply("matchmaking/ready", "d", mmReady(s, "d")))
      .then(apply("env/readyTimeout", "", readyTimeout(s, 2)))                  // d's party... a,b failed
      .then(apply("matchmaking/queue", "a", mmQueue(s, "a")))
      .then(apply("env/match", "", matchFound(s, Set(Set("a", "b"), Set("c")))))
      .then(apply("matchmaking/ready", "a", mmReady(s, "a")))
      .then(apply("matchmaking/ready", "b", mmReady(s, "b")))
      .then(apply("env/readyTimeout", "", readyTimeout(s, 3)))                  // c failed; the party resumes
      .expect(and { s.parties.get(0).queued, s.searching.contains(Set("a", "b")), w_lostPartyStaysLocked })
      .then(apply("env/match", "", matchFound(s, Set(Set("a", "b"), Set("d")))))
      .then(apply("matchmaking/ready", "a", mmReady(s, "a")))
      .then(apply("matchmaking/ready", "b", mmReady(s, "b")))
      .then(apply("matchmaking/ready", "d", mmReady(s, "d")))
      .expect(s.matches.get(4).phase == Starting(5))
      .then(apply("party/leave", "b", partyLeave(s, "b")))                       // during Starting
      .expect(and { lastWhy == "left_declined", w_startingDisbanded, s.searching.contains(Set("d")),
                    lastEvents.contains(("d", Lost)) })
      .then(apply("env/autohostStarted", "", autohostStarted(s, 5)))
      .expect(lastWhy == "killed" and s.battles == Map())                       // late success killed

  // Lobby battles: autohost failure, start, leaving or crashing while it runs
  // (INT-03), joinBattle, system/disconnect while playing (INT-07).
  run lobbyBattleTest =
    init
      .then(apply("lobby/create", "a", lobbyCreate(s, "a")))
      .then(apply("lobby/join", "b", lobbyJoin(s, "b", 0)))
      .then(apply("lobby/startBattle", "a", lobbyStartBattle(s, "a")))
      .then(apply("env/autohostFailed", "", autohostFailed(s, 1)))
      .expect(lastWhy == "lobby_failed" and s.lobbies.get(0).battle == LNone and lastEvents == Set())
      .then(apply("lobby/startBattle", "b", lobbyStartBattle(s, "b")))
      .then(apply("env/autohostStarted", "", autohostStarted(s, 2)))
      .expect(lastEvents.contains(("a", BattleStart(2))) and lastEvents.contains(("b", BattleStart(2))))
      .then(apply("lobby/join", "c", lobbyJoin(s, "c", 0)))
      .then(apply("lobby/joinBattle", "c", lobbyJoinBattle(s, "c")))
      .expect(lastEvents == Set(("c", BattleStart(2))))
      .then(apply("matchmaking/queue", "c", mmQueue(s, "c")))
      .expect(lastReply == Failed("already_in_battle"))                         // INT-D4: the battle reason
      .then(apply("lobby/leave", "c", lobbyLeave(s, "c")))                        // c keeps playing
      .expect(and { slotBattle(s, "c"), w_orphanBattle })
      .then(apply("lobby/create", "c", lobbyCreate(s, "c")))
      .expect(lastWhy == "in_battle")
      .then(apply("lobby/join", "c", lobbyJoin(s, "c", 0)))                       // back into the battle's lobby
      .expect(lastWhy == "joined" and not(slotBattle(s, "c")))
      .then(apply("system/disconnect", "b", systemDisconnect(s, "b")))          // INT-07
      .expect(and { lastReply == Ok, not(inLobby(s, "b")), playing(s, "b"), w_offlineInBattle })
      .then(apply("env/lobbyCrashed", "", lobbyCrashed(s, 0)))
      .expect(and { lastEvents == Set(("a", LobbyLeft("crashed")), ("c", LobbyLeft("crashed"))),
                    playing(s, "a"), w_crashOrphansBattle })
      .then(apply("lobby/join", "a", lobbyJoin(s, "a", 0)))
      .expect(lastReply == Failed("invalid_lobby_id"))
      .then(apply("env/battleEnded", "", battleEnded(s, 2)))
      .expect(lastWhy == "ended_lobby" and lastEvents == Set(("a", BattleEnded(2)), ("c", BattleEnded(2))))

  // Messaging subscription and party/lobby chat across sockets (MSG-07/08).
  run messagingTest =
    init
      .then(apply("party/create", "a", partyCreate(s, "a")))
      .then(apply("party/invite", "a", partyInvite(s, "a", "b")))
      .then(apply("party/acceptInvite", "b", partyAccept(s, "b", 0)))
      .then(apply("messaging/send", "a", msgSend(s, "a", "party")))
      .expect(lastReply == Ok and lastEvents == Set())                           // b not subscribed
      .then(apply("messaging/subscribeReceived", "b", msgSubscribe(s, "b")))
      .then(apply("messaging/send", "a", msgSend(s, "a", "party")))
      .expect(lastEvents == Set(("b", MsgReceived("party"))))
      .then(apply("env/takeover", "b", takeover(s, "b")))
      .then(apply("messaging/send", "a", msgSend(s, "a", "party")))
      .expect(lastEvents == Set())                                               // MSG-A9
      .then(apply("messaging/send", "a", msgSend(s, "a", "lobby")))
      .expect(lastReply == Failed("invalid_target"))
      .then(apply("friend/sendRequest", "a", friendSend(s, "a", "b")))
      .then(apply("env/disconnect", "a", socketDrop(s, "a")))
      .then(apply("friend/sendRequest", "b", friendSend(s, "b", "a")))
      .expect(lastWhy == "auto_accepted" and lastEvents == Set())               // a is Detached
      .then(apply("env/disconnect", "a", socketDrop(s, "a")))
      .then(apply("env/sessionExpired", "a", sessionExpired(s, "a")))
      .expect(s.friends.contains(("a", "b")) and sessionStepsKeepFriends)
}

// Small instance for bounded model checking: 3 users, matches of 2.
module system_small {
  import common.* from "./common"
  import system(USERS = Set("a", "b", "c"), MATCH_SIZE = 2, MAX_PARTY = 1).*
}

// Deep matchmaking paths: 3 users, so every match takes all of them.
module system_three {
  import common.* from "./common"
  import system(USERS = Set("a", "b", "c"), MATCH_SIZE = 3, MAX_PARTY = 2).*
}
