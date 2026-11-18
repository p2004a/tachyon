// Lobby: every lobby/* command and event, plus the environment steps that
// drive them (vote timer, autohost answer, battle end, session end, lobby
// crash, ban expiry, other activities). Source: tachyon docs/schema/lobby.md
// (generated from src/schema/lobby/README.md) and the schema descriptions in
// src/schema/lobby/*.ts. Findings: findings/lobby.md (LOBBY-nn).
//
// @test main=lobby_test
// @inv main=lobby_test inv=safety steps=30 samples=20000
// @inv main=lobby_votes inv=safety steps=30 samples=10000
// @inv main=lobby_queue inv=safety steps=30 samples=10000
//
// Witnesses: each must be reachable (check.sh expects the invariant to fail).
// @witness main=lobby_test inv=not(hit("lobby/create",Ok))
// @witness main=lobby_test inv=not(hit("lobby/create",Failed("invalid_request")))
// @witness main=lobby_test inv=not(hit("lobby/join",Ok))
// @witness main=lobby_test inv=not(hit("lobby/join",Failed("invalid_lobby_id")))
// @witness main=lobby_test inv=not(hit("lobby/join",Failed("invalid_request")))
// @witness main=lobby_votes inv=not(hit("lobby/join",Failed("banned")))
// @witness main=lobby_test inv=not(hit("lobby/join",Failed("lobby_full")))
// @witness main=lobby_test inv=not(hit("lobby/leave",Ok))
// @witness main=lobby_test inv=not(hit("lobby/leave",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/joinAllyTeam",Ok))
// @witness main=lobby_test inv=not(hit("lobby/joinAllyTeam",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/joinAllyTeam",Failed("invalid_request")))
// @witness main=lobby_test inv=not(hit("lobby/joinAllyTeam",Failed("ally_team_full")))
// @witness main=lobby_test inv=not(hit("lobby/spectate",Ok))
// @witness main=lobby_test inv=not(hit("lobby/spectate",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/joinQueue",Ok))
// @witness main=lobby_test inv=not(hit("lobby/joinQueue",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/updateClientStatus",Ok))
// @witness main=lobby_test inv=not(hit("lobby/updateClientStatus",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/updateClientStatus",Failed("not_a_player")))
// @witness main=lobby_test inv=not(hit("lobby/addBot",Ok))
// @witness main=lobby_test inv=not(hit("lobby/addBot",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/addBot",Failed("invalid_request")))
// @witness main=lobby_test inv=not(hit("lobby/addBot",Failed("ally_team_full")))
// @witness main=lobby_test inv=not(hit("lobby/removeBot",Ok))
// @witness main=lobby_test inv=not(hit("lobby/removeBot",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/removeBot",Failed("invalid_bot")))
// @witness main=lobby_test inv=not(hit("lobby/updateBot",Ok))
// @witness main=lobby_test inv=not(hit("lobby/updateBot",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/updateBot",Failed("invalid_bot")))
// @witness main=lobby_test inv=not(hit("lobby/update",Ok))
// @witness main=lobby_test inv=not(hit("lobby/update",Failed("invalid_request")))
// @witness main=lobby_test inv=not(hit("lobby/appointBoss",Ok))
// @witness main=lobby_test inv=not(hit("lobby/appointBoss",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/appointBoss",Failed("invalid_request")))
// @witness main=lobby_test inv=not(hit("lobby/appointBoss",Failed("bosses_not_allowed")))
// @witness main=lobby_test inv=not(hit("lobby/unboss",Ok))
// @witness main=lobby_test inv=not(hit("lobby/unboss",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/unboss",Failed("invalid_request")))
// @witness main=lobby_test inv=not(hit("lobby/unboss",Failed("not_a_boss")))
// @witness main=lobby_test inv=not(hit("lobby/kickban",Ok))
// @witness main=lobby_test inv=not(hit("lobby/kickban",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/kickban",Failed("invalid_request")))
// @witness main=lobby_votes inv=not(hit("lobby/voteSubmit",Ok))
// @witness main=lobby_votes inv=not(hit("lobby/voteSubmit",Failed("not_in_lobby")))
// @witness main=lobby_votes inv=not(hit("lobby/voteSubmit",Failed("invalid_vote_id")))
// @witness main=lobby_votes inv=not(hit("lobby/voteSubmit",Failed("invalid_request")))
// @witness main=lobby_votes inv=not(hit("lobby/voteCancel",Ok))
// @witness main=lobby_votes inv=not(hit("lobby/voteCancel",Failed("not_in_lobby")))
// @witness main=lobby_votes inv=not(hit("lobby/voteCancel",Failed("invalid_vote_id")))
// @witness main=lobby_votes inv=not(hit("lobby/voteCancel",Failed("invalid_request")))
// @witness main=lobby_test inv=not(hit("lobby/startBattle",Ok))
// @witness main=lobby_test inv=not(hit("lobby/startBattle",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/startBattle",Failed("invalid_request")))
// @witness main=lobby_votes inv=not(hit("lobby/joinBattle",Ok))
// @witness main=lobby_test inv=not(hit("lobby/joinBattle",Failed("not_in_lobby")))
// @witness main=lobby_test inv=not(hit("lobby/joinBattle",Failed("no_battle")))
// @witness main=lobby_votes inv=not(hit("lobby/joinBattle",Failed("battle_full")))
// @witness main=lobby_test inv=not(hit("lobby/subscribeList",Ok))
// @witness main=lobby_test inv=not(hit("lobby/unsubscribeList",Ok))
// Events and environment outcomes:
// @witness main=lobby_test inv=not(sawUpdated)
// @witness main=lobby_test inv=not(sawLeft("kicked"))
// @witness main=lobby_votes inv=not(sawLeft("banned"))
// @witness main=lobby_test inv=not(sawLeft("crashed"))
// @witness main=lobby_votes inv=not(sawVoteEnded("passed"))
// @witness main=lobby_votes inv=not(sawVoteEnded("failed"))
// @witness main=lobby_votes inv=not(sawVoteEnded("cancelled"))
// @witness main=lobby_votes inv=not(sawVoteEnded("timeout"))
// @witness main=lobby_votes inv=not(votedKickPassed)
// @witness main=lobby_test inv=not(sawListUpdated)
// @witness main=lobby_test inv=not(sawListRemoved)
// @witness main=lobby_test inv=not(sawListReset)
// @witness main=lobby_test inv=not(sawBattleStart)
// @witness main=lobby_votes inv=not(battleStartFailed)
// @witness main=lobby_votes inv=not(sawBattleEnded)
// @witness main=lobby_queue inv=not(queuePromoted)
// @witness main=lobby_queue inv=not(evictedToQueue)
// @witness main=lobby_votes inv=not(sawBanExpired)
module lobby {
  import common.* from "./common"

  // ---------------------------------------------------------------- types
  type LobbyId = int
  type BotId = int
  // A player occupies one slot of an ally team. `slot` is the position inside
  // the ally team (teiserver's team index); slots are kept packed 0..n-1.
  type Player = { ally: int, slot: int, ready: bool }
  // "hostUserId: which player will run the bot. It is the same as the player
  // that added the bot." `config` abstracts name/shortName/version/options.
  type Bot = { host: UserId, ally: int, slot: int, config: int }
  type KickArgs = { target: UserId, ban: bool }
  // voteActions: start | changeMap | appointBoss | kickban
  type VoteAction = VStart | VChangeMap(int) | VAppointBoss(UserId) | VKickban(KickArgs)
  // currentVote.voters: "indexed by the userId. The initiator is also included".
  // Ballot values: "pending" | "yes" | "no" | "abstain".
  type Vote = { id: int, act: VoteAction, initiator: UserId, ballots: UserId -> str }
  type CurrentVote = NoVote | AVote(Vote)
  // Starting = startBattle accepted, autohost not answered yet (not visible
  // to clients: the protocol has no such lobby state, LOBBY-21).
  type Battle = NoBattle | Starting | Running(int)
  type Lobby = {
    name: int, map: int,          // abstract lobby properties (lobby/update)
    caps: int -> int,             // ally team -> max occupants (humans + bots), LOBBY-08
    players: UserId -> Player,
    spectators: Set[UserId],
    queue: UserId -> int,         // joinQueuePosition of queued spectators
    bots: BotId -> Bot, nextBot: int,
    bossesEnabled: bool, bosses: Set[UserId],
    bans: Set[UserId],            // ban duration abstracted; env/banExpired lifts it
    vote: CurrentVote, nextVote: int, history: int -> str,   // voteHistory: id -> outcome
    battle: Battle, inBattle: Set[UserId],
  }
  type State = {
    lobbies: LobbyId -> Lobby, nextLobby: int, nextBattle: int,
    subscribers: Set[UserId],     // lobby/subscribeList
    elsewhere: Set[UserId],       // in matchmaking or a non-lobby battle (other modules)
  }
  type LeftData = { lobby: LobbyId, reason: str }
  type VoteEndedData = { lobby: LobbyId, vote: int, outcome: str }
  // Updated/ListUpdated carry the lobby state after the step (a patch of it).
  // ListUpdated(id) for an id that no longer exists is the `id: null` entry.
  // BattleStart is the server->user battle/start request.
  type Event =
    | Updated(LobbyId) | Left(LeftData) | VoteEnded(VoteEndedData)
    | ListUpdated(LobbyId) | ListReset | BattleStart(LobbyId)
  type Outcome = { state: State, reply: Reply, events: Set[(UserId, Event)] }
  // lobby/update carries several optional properties; one per request here.
  type Change = UName(int) | UMap(int) | UCaps(int -> int)
  type Overview = { exists: bool, count: int, maxCount: int, name: int, map: int,
                    running: bool, bossesEnabled: bool }

  // ---------------------------------------------------------------- constants
  const USERS: Set[UserId]
  const ALLY_TEAMS: Set[int]     // indices of allyTeamConfig
  const CAPS: Set[int]           // capacities a client may configure (>= 1)
  const MAX_MEMBERS: int         // design: 256 members (players + spectators)
  const ENABLED: Set[str]        // which steps the environment may take (test knob)

  pure val NO_ID = 99            // an id that never names anything

  // ---------------------------------------------------------------- helpers
  pure def members(l: Lobby): Set[UserId] = l.players.keys().union(l.spectators)
  pure def lobbiesOf(s: State, u: UserId): Set[LobbyId] =
    s.lobbies.keys().filter(id => u.in(members(s.lobbies.get(id))))
  pure def inLobby(s: State, u: UserId): bool = lobbiesOf(s, u) != Set()
  pure def lobbyOf(s: State, u: UserId): LobbyId = theOne(lobbiesOf(s, u), -1)
  pure def myLobby(s: State, u: UserId): Lobby = s.lobbies.get(lobbyOf(s, u))
  pure def deny(s: State, reason: str): Outcome = { state: s, reply: Failed(reason), events: Set() }
  pure def okNoop(s: State): Outcome = { state: s, reply: Ok, events: Set() }
  pure def envNoop(s: State): Outcome = { state: s, reply: NoReply, events: Set() }
  pure def withLobby(s: State, id: LobbyId, l: Lobby): State = { ...s, lobbies: s.lobbies.put(id, l) }
  pure def isRunning(b: Battle): bool = match b { | Running(_) => true | _ => false }

  pure def capOf(l: Lobby, a: int): int = if (a.in(l.caps.keys())) l.caps.get(a) else 0
  pure def humansIn(l: Lobby, a: int): Set[UserId] = l.players.keys().filter(u => l.players.get(u).ally == a)
  pure def botsIn(l: Lobby, a: int): Set[BotId] = l.bots.keys().filter(b => l.bots.get(b).ally == a)
  pure def occupants(l: Lobby, a: int): int = humansIn(l, a).size() + botsIn(l, a).size()
  pure def free(l: Lobby, a: int): int = capOf(l, a) - occupants(l, a)
  pure def slotsIn(l: Lobby, a: int): Set[int] =
    humansIn(l, a).map(u => l.players.get(u).slot).union(botsIn(l, a).map(b => l.bots.get(b).slot))
  pure def rank(l: Lobby, a: int, k: int): int = slotsIn(l, a).filter(x => x < k).size()

  // Keep slots of each ally team consecutive from 0 (teiserver RepackPlayers).
  pure def repack(l: Lobby): Lobby = {
    ...l,
    players: l.players.keys().mapBy(u => { val p = l.players.get(u)
                                           { ...p, slot: rank(l, p.ally, p.slot) } }),
    bots: l.bots.keys().mapBy(b => { val x = l.bots.get(b)
                                     { ...x, slot: rank(l, x.ally, x.slot) } }),
  }

  pure def maxPos(l: Lobby): int =
    l.queue.keys().fold(0, (m, v) => if (l.queue.get(v) > m) l.queue.get(v) else m)
  pure def minPos(l: Lobby): int =
    l.queue.keys().fold(maxPos(l), (m, v) => if (l.queue.get(v) < m) l.queue.get(v) else m)
  pure def firstQueued(l: Lobby): UserId =
    theOne(l.queue.keys().filter(u => l.queue.keys().forall(v => l.queue.get(u) <= l.queue.get(v))), "")
  // "the server will automatically put the user in the first suitable ally team":
  // the ally team with most free room, lowest index first (teiserver find_team).
  pure def bestAlly(l: Lobby): int = {
    val open = ALLY_TEAMS.filter(a => free(l, a) > 0)
    theOne(open.filter(a => open.forall(b => free(l, a) > free(l, b) or (free(l, a) == free(l, b) and a <= b))), -1)
  }
  // "When a suitable ally team has a free spot for a waiting player, the server
  // will automatically put them in that spot". Smallest position goes first.
  pure def fillOne(l: Lobby): Lobby =
    if (l.queue.keys() == Set() or bestAlly(l) == -1) l
    else {
      val u = firstQueued(l)
      val a = bestAlly(l)
      { ...l, spectators: l.spectators.exclude(Set(u)), queue: mapRemove(l.queue, u),
        // "When a user becomes a player ... default status {isReady: false, ...}"
        players: l.players.put(u, { ally: a, slot: occupants(l, a), ready: false }) }
    }
  pure def fill(l: Lobby): Lobby = USERS.fold(l, (acc, _x) => fillOne(acc))
  pure def normalize(l: Lobby): Lobby = fill(repack(l))

  // Remove a user and the bots they host (ASSUMPTION LOBBY-A06).
  pure def dropMember(l: Lobby, u: UserId): Lobby = {
    ...l,
    players: mapRemove(l.players, u),
    spectators: l.spectators.exclude(Set(u)),
    queue: mapRemove(l.queue, u),
    bosses: l.bosses.exclude(Set(u)),
    bots: l.bots.keys().filter(b => l.bots.get(b).host != u).mapBy(b => l.bots.get(b)),
  }

  // ---------------------------------------------------------------- votes
  // "The protocol does not define who is eligible to vote". ASSUMPTION LOBBY-A08:
  // the players plus the initiator; a vote is needed iff there are no bosses
  // and more than one eligible voter (teiserver new_vote / kickban).
  pure def voters(l: Lobby, u: UserId): Set[UserId] = l.players.keys().union(Set(u))
  pure def needsVote(l: Lobby, u: UserId): bool = l.bosses == Set() and voters(l, u).size() > 1
  pure def hasVote(l: Lobby): bool = l.vote != NoVote
  pure def voteId(l: Lobby): int = match l.vote { | NoVote => NO_ID | AVote(v) => v.id }
  // "When one or more boss are present in a lobby, some commands may be disabled
  // for non-boss players." ASSUMPTION LOBBY-A09: update/kickban/appointBoss/startBattle.
  pure def canAct(l: Lobby, u: UserId): bool = l.bosses == Set() or u.in(l.bosses)

  pure def count(v: Vote, b: str): int = v.ballots.keys().filter(u => v.ballots.get(u) == b).size()
  pure def majority(yes: int, no: int): str = if (yes + no > 0 and 2 * yes > yes + no) "passed" else "failed"
  // ASSUMPTION LOBBY-A10: teiserver's vote_result with quorum = floor(n/2)+1 and
  // majority > 1/2 of non-abstaining votes. "" = undecided.
  pure def decide(v: Vote, timedOut: bool): str = {
    val n = v.ballots.keys().size()
    val yes = count(v, "yes")
    val no = count(v, "no")
    val pend = count(v, "pending")
    val voted = n - pend
    val q = n / 2 + 1
    val t = yes + no + pend
    if (voted >= q and t > 0 and 2 * yes > t) "passed"
    else if (voted >= q and t > 0 and 2 * (yes + pend) <= t) "failed"
    else if (pend == 0) majority(yes, no)
    else if (timedOut and voted >= q) majority(yes, no)
    else if (timedOut) "timeout"
    else ""
  }

  pure def applyAction(l: Lobby, a: VoteAction): Lobby = match a {
    | VStart => if (l.battle == NoBattle) { ...l, battle: Starting } else l
    | VChangeMap(m) => { ...l, map: m }
    // a passed appointBoss vote only takes effect if the appointee is still there (LOBBY-26)
    | VAppointBoss(t) => if (t.in(members(l)) and l.bossesEnabled) { ...l, bosses: l.bosses.union(Set(t)) } else l
    | VKickban(k) => {
        val l2 = if (k.ban) { ...l, bans: l.bans.union(Set(k.target)) } else l
        if (k.target.in(members(l2))) normalize(dropMember(l2, k.target)) else l2
      }
  }
  // "when the vote ends, a lobby/voteEnded event is sent to all lobby members"
  pure def endVote(l: Lobby, v: Vote, outcome: str): Lobby = {
    val l2 = { ...l, vote: NoVote, history: l.history.put(v.id, outcome) }
    if (outcome == "passed") applyAction(l2, v.act) else l2
  }
  pure def settle(l: Lobby, timedOut: bool): Lobby = match l.vote {
    | NoVote => l
    | AVote(v) => { val o = decide(v, timedOut)
                    if (o == "") l else endVote(l, v, o) }
  }
  pure def startVote(l: Lobby, u: UserId, a: VoteAction): Lobby = settle({
    ...l,
    vote: AVote({ id: l.nextVote, act: a, initiator: u,
                  ballots: voters(l, u).mapBy(x => if (x == u) "yes" else "pending") }),
    nextVote: l.nextVote + 1,
  }, false)
  // A member leaving: a pure kick vote against them is cancelled, otherwise
  // their ballot becomes abstain (teiserver CancelKickVote / CastVote abstain).
  pure def voteOnRemoval(l: Lobby, u: UserId): Lobby = match l.vote {
    | NoVote => l
    | AVote(v) =>
        if (v.act == VKickban({ target: u, ban: false })) endVote(l, v, "cancelled")
        else if (u.in(v.ballots.keys())) settle({ ...l, vote: AVote({ ...v, ballots: v.ballots.set(u, "abstain") }) }, false)
        else l
  }
  pure def removeMember(l: Lobby, u: UserId): Lobby = voteOnRemoval(normalize(dropMember(l, u)), u)

  // ---------------------------------------------------------------- notifications
  // lobby/listUpdated carries a lobbyOverview patch: these are its fields.
  // ASSUMPTION LOBBY-A12: playerCount counts every occupied player slot (humans + bots).
  pure def ovOf(s: State, id: LobbyId): Overview =
    if (id.in(s.lobbies.keys())) {
      val l = s.lobbies.get(id)
      { exists: true, count: l.players.keys().size() + l.bots.keys().size(),
        maxCount: ALLY_TEAMS.fold(0, (acc, a) => acc + capOf(l, a)),
        name: l.name, map: l.map, running: isRunning(l.battle), bossesEnabled: l.bossesEnabled }
    } else { exists: false, count: 0, maxCount: 0, name: 0, map: 0, running: false, bossesEnabled: false }
  // What lobbyDetails shows. Bans, counters, battle membership and a pending
  // start are not part of it.
  pure def view(l: Lobby): Lobby =
    { ...l, bans: Set(), nextBot: 0, nextVote: 0, inBattle: Set(),
      battle: if (l.battle == Starting) NoBattle else l.battle }

  // Every step ends here: dispose empty lobbies and derive the events.
  // - "When a lobby is empty, it is automatically disposed off."
  // - lobby/updated: "The result of the updates is then transmitted to all members";
  //   a joiner gets the full state in the response instead (ASSUMPTION LOBBY-A03).
  // - lobby/listUpdated: to subscribers, whenever a lobby is added, removed or modified.
  // - lobby/voteEnded: "sent to all lobby members" when a vote ends.
  // - lobby/left: "only sent to the player that was removed. It will not be sent
  //   when the client leave using lobby/leave." `voluntary` = those who left.
  pure def finish(prev: State, nxt0: State, reply: Reply, voluntary: Set[UserId],
                  extra: Set[(UserId, Event)]): Outcome = {
    val nxt = { ...nxt0, lobbies: nxt0.lobbies.keys().filter(id => members(nxt0.lobbies.get(id)) != Set())
                                                     .mapBy(id => nxt0.lobbies.get(id)) }
    val both = prev.lobbies.keys().intersect(nxt.lobbies.keys())
    val upd = both.filter(id => view(prev.lobbies.get(id)) != view(nxt.lobbies.get(id)))
                  .map(id => send(members(prev.lobbies.get(id)).intersect(members(nxt.lobbies.get(id))), Updated(id)))
                  .flatten()
    val lst = prev.lobbies.keys().union(nxt0.lobbies.keys())
                  .filter(id => ovOf(prev, id) != ovOf(nxt, id))
                  .map(id => send(nxt.subscribers, ListUpdated(id))).flatten()
    val ended = nxt.lobbies.keys().map(id => {
                  val l = nxt.lobbies.get(id)
                  val old = if (id.in(prev.lobbies.keys())) prev.lobbies.get(id).history.keys() else Set()
                  l.history.keys().exclude(old)
                   .map(v => send(members(l), VoteEnded({ lobby: id, vote: v, outcome: l.history.get(v) })))
                   .flatten()
                }).flatten()
    val left = prev.lobbies.keys().map(id => {
                  val stay = if (id.in(nxt.lobbies.keys())) members(nxt.lobbies.get(id)) else Set()
                  val bans = if (id.in(nxt0.lobbies.keys())) nxt0.lobbies.get(id).bans else Set()
                  val crashed = not(id.in(nxt0.lobbies.keys()))
                  members(prev.lobbies.get(id)).exclude(stay).exclude(voluntary)
                    .map(u => (u, Left({ lobby: id,
                                         reason: if (crashed) "crashed" else if (u.in(bans)) "banned" else "kicked" })))
                }).flatten()
    { state: nxt, reply: reply, events: upd.union(lst).union(ended).union(left).union(extra) }
  }
  pure def done(s: State, id: LobbyId, l: Lobby): Outcome = finish(s, withLobby(s, id, l), Ok, Set(), Set())

  // An operation that needs a vote when there is no boss (voteActions).
  // ASSUMPTION LOBBY-A11: only one vote at a time; a second one is refused.
  pure def gated(s: State, id: LobbyId, u: UserId, a: VoteAction, direct: Lobby): Outcome = {
    val l = s.lobbies.get(id)
    if (needsVote(l, u)) { if (hasVote(l)) deny(s, "invalid_request") else done(s, id, startVote(l, u, a)) }
    else done(s, id, direct)
  }

  // ================================================================ commands
  // "When you create a lobby you also automatically becomes the first player in
  // the first allyTeam." "The creator of a lobby can choose to forbid bosses".
  // ASSUMPTION LOBBY-A01: the creator is the first boss when bosses are allowed.
  // Activity slot (design): not while in a lobby, matchmaking or a battle.
  pure def create(s: State, u: UserId, bossesEnabled: bool, caps: int -> int): Outcome =
    if (inLobby(s, u) or u.in(s.elsewhere)) deny(s, "invalid_request")
    else {
      val l = { name: 0, map: 0, caps: caps,
                players: Map(u -> { ally: 0, slot: 0, ready: false }),
                spectators: Set(), queue: Map(), bots: Map(), nextBot: 0,
                bossesEnabled: bossesEnabled, bosses: if (bossesEnabled) Set(u) else Set(),
                bans: Set(), vote: NoVote, nextVote: 0, history: Map(),
                battle: NoBattle, inBattle: Set() }
      finish(s, { ...withLobby(s, s.nextLobby, l), nextLobby: s.nextLobby + 1 }, Ok, Set(), Set())
    }

  // "Joining a lobby puts the user as a spectator." "this operation is idempotent.
  // Attempting to join a different lobby while being in a lobby will fail with
  // invalid_request." Reasons: invalid_lobby_id, lobby_full, banned.
  pure def join(s: State, u: UserId, id: LobbyId): Outcome =
    if (not(id.in(s.lobbies.keys()))) deny(s, "invalid_lobby_id")
    else {
      val l = s.lobbies.get(id)
      if (u.in(members(l))) okNoop(s)
      else if (inLobby(s, u) or u.in(s.elsewhere)) deny(s, "invalid_request")
      else if (u.in(l.bans)) deny(s, "banned")
      else if (members(l).size() >= MAX_MEMBERS) deny(s, "lobby_full")
      else done(s, id, { ...l, spectators: l.spectators.union(Set(u)) })
    }

  // "Leave the lobby, also unsubscribe from any update". No lobby/left.
  pure def leave(s: State, u: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else finish(s, withLobby(s, lobbyOf(s, u), removeMember(myLobby(s, u), u)), Ok, Set(u), Set())

  // "If the target ally team is full, the request fails and nothing happen.
  // joinAllyTeam can also be used to change team."
  pure def joinAllyTeam(s: State, u: UserId, a: int): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(a.in(ALLY_TEAMS))) deny(s, "invalid_request")              // LOBBY-09
      else if (u.in(l.players.keys()) and l.players.get(u).ally == a) okNoop(s)
      else if (free(l, a) <= 0) deny(s, "ally_team_full")
      else {
        val l1 = { ...l, players: mapRemove(l.players, u), spectators: l.spectators.exclude(Set(u)),
                   queue: mapRemove(l.queue, u) }
        done(s, lobbyOf(s, u),
             normalize({ ...l1, players: l1.players.put(u, { ally: a, slot: occupants(l1, a), ready: false }) }))
      }
    }

  // "To leave an ally team or the join queue and become a spectator ... If already
  // in spectator queue, has no effect (but still succeed)."
  pure def spectate(s: State, u: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (u.in(l.players.keys()))
        done(s, lobbyOf(s, u), normalize({ ...l, players: mapRemove(l.players, u), spectators: l.spectators.union(Set(u)) }))
      else done(s, lobbyOf(s, u), { ...l, queue: mapRemove(l.queue, u) })
    }

  // "Joins the waiting queue to play. The server will automatically put the user in
  // the first suitable ally team when the time comes." New entries go last.
  // ASSUMPTION LOBBY-A04: already queued -> no-op; a player with an empty queue ->
  // no-op; a player with a non-empty queue swaps with the first waiting member.
  pure def joinQueue(s: State, u: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      val id = lobbyOf(s, u)
      if (u.in(l.queue.keys())) okNoop(s)
      else if (u.in(l.players.keys())) {
        if (l.queue.keys() == Set()) okNoop(s)
        else {
          val f = firstQueued(l)
          val p = l.players.get(u)
          done(s, id, { ...l, players: mapRemove(l.players, u).put(f, { ...p, ready: false }),
                        spectators: l.spectators.exclude(Set(f)).union(Set(u)),
                        queue: mapRemove(l.queue, f).put(u, maxPos(l) + 1) })
        }
      }
      else done(s, id, normalize({ ...l, queue: l.queue.put(u, maxPos(l) + 1) }))
    }

  // "notify others if they are ready". Reasons: not_in_lobby, not_a_player.
  pure def updateClientStatus(s: State, u: UserId, ready: bool): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(u.in(l.players.keys()))) deny(s, "not_a_player")
      else done(s, lobbyOf(s, u), { ...l, players: l.players.set(u, { ...l.players.get(u), ready: ready }) })
    }

  // "Add a bot to the specified ally team". Reasons: not_in_lobby, ally_team_full.
  // ASSUMPTION LOBBY-A05: any member may add, remove and update any bot.
  pure def addBot(s: State, u: UserId, a: int): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(a.in(ALLY_TEAMS))) deny(s, "invalid_request")
      else if (free(l, a) <= 0) deny(s, "ally_team_full")
      else done(s, lobbyOf(s, u),
                { ...l, bots: l.bots.put(l.nextBot, { host: u, ally: a, slot: occupants(l, a), config: 0 }),
                        nextBot: l.nextBot + 1 })
    }

  // "Remove the specified bot from the lobby". Reasons: not_in_lobby, invalid_bot.
  pure def removeBot(s: State, u: UserId, b: BotId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(b.in(l.bots.keys()))) deny(s, "invalid_bot")
      else done(s, lobbyOf(s, u), normalize({ ...l, bots: mapRemove(l.bots, b) }))
    }

  // "Change a bot properties. Some properties like ID and allyTeam can't be changed."
  pure def updateBot(s: State, u: UserId, b: BotId, config: int): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(b.in(l.bots.keys()))) deny(s, "invalid_bot")
      else done(s, lobbyOf(s, u), { ...l, bots: l.bots.set(b, { ...l.bots.get(b), config: config }) })
    }

  // Players that no longer fit a new allyTeamConfig go to the front of the join
  // queue in (ally team, slot) order; bots that no longer fit are removed
  // (ASSUMPTION LOBBY-A07, as teiserver UpdateAllyTeamConfig).
  pure def before(p: Player, q: Player): bool = p.ally < q.ally or (p.ally == q.ally and p.slot < q.slot)
  pure def reconfigure(l: Lobby, caps: int -> int): Lobby = {
    val l1 = { ...l, caps: caps }
    val outH = l.players.keys().filter(u => l.players.get(u).slot >= capOf(l1, l.players.get(u).ally))
    val outB = l.bots.keys().filter(b => l.bots.get(b).slot >= capOf(l1, l.bots.get(b).ally))
    val base = (if (l.queue.keys() == Set()) 1 else minPos(l)) - outH.size()
    normalize({ ...l1,
      players: l.players.keys().exclude(outH).mapBy(u => l.players.get(u)),
      spectators: l.spectators.union(outH),
      queue: l.queue.keys().union(outH).mapBy(u =>
               if (u.in(outH)) base + outH.filter(v => before(l.players.get(v), l.players.get(u))).size()
               else l.queue.get(u)),
      bots: l.bots.keys().exclude(outB).mapBy(b => l.bots.get(b)) })
  }

  // "Any member can update most (any?) property of the lobby unless bosses are
  // present. Updates are all or nothing". The schema has no not_in_lobby (LOBBY-12).
  // A map change is a vote action (voteActions changeMap).
  pure def update(s: State, u: UserId, ch: Change): Outcome =
    if (not(inLobby(s, u))) deny(s, "invalid_request")
    else {
      val l = myLobby(s, u)
      val id = lobbyOf(s, u)
      if (not(canAct(l, u))) deny(s, "invalid_request")
      else match ch {
        | UName(n) => done(s, id, { ...l, name: n })
        | UMap(m) => gated(s, id, u, VChangeMap(m), { ...l, map: m })
        | UCaps(c) => done(s, id, reconfigure(l, c))
      }
    }

  // "Ban a user from a lobby (and kick them out)"; "omit this field (or set it in
  // the past) to merely kick the player". The kicked user gets lobby/left.
  pure def kickban(s: State, u: UserId, t: UserId, ban: bool): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(t.in(members(l)))) deny(s, "invalid_request")           // LOBBY-15
      else if (not(canAct(l, u))) deny(s, "invalid_request")
      else gated(s, lobbyOf(s, u), u, VKickban({ target: t, ban: ban }),
                 removeMember(if (ban) { ...l, bans: l.bans.union(Set(t)) } else l, t))
    }

  // "Make the designated player a boss". Reasons: not_in_lobby, bosses_not_allowed.
  pure def appointBoss(s: State, u: UserId, t: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(t.in(members(l)))) deny(s, "invalid_request")
      else if (not(l.bossesEnabled)) deny(s, "bosses_not_allowed")
      else if (not(canAct(l, u))) deny(s, "invalid_request")
      else if (t.in(l.bosses)) okNoop(s)
      else gated(s, lobbyOf(s, u), u, VAppointBoss(t), { ...l, bosses: l.bosses.union(Set(t)) })
    }

  // "Unboss the given user"; "if userId isn't provided, defaults to the current user".
  // ASSUMPTION LOBBY-A13: only a boss may unboss; unbossing a non-boss is a no-op.
  pure def unboss(s: State, u: UserId, t: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (not(t.in(members(l)))) deny(s, "invalid_request")
      else if (not(u.in(l.bosses))) deny(s, "not_a_boss")
      else if (not(t.in(l.bosses))) okNoop(s)
      else done(s, lobbyOf(s, u), { ...l, bosses: l.bosses.exclude(Set(t)) })
    }

  // "Eligible members may use the lobby/voteSubmit request to send their vote".
  pure def voteSubmit(s: State, u: UserId, vid: int, ballot: str): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      match l.vote {
        | NoVote => deny(s, "invalid_vote_id")
        | AVote(v) =>
            if (v.id != vid) deny(s, "invalid_vote_id")
            else if (not(u.in(v.ballots.keys()))) deny(s, "invalid_request")   // LOBBY-18
            else done(s, lobbyOf(s, u), settle({ ...l, vote: AVote({ ...v, ballots: v.ballots.set(u, ballot) }) }, false))
      }
    }

  // "Some members (vote initiators or bosses, for example) may be eligible to use
  // the lobby/voteCancel request ... voteEnded will arrive with outcome: cancelled".
  pure def voteCancel(s: State, u: UserId, vid: int): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      match l.vote {
        | NoVote => deny(s, "invalid_vote_id")
        | AVote(v) =>
            if (v.id != vid) deny(s, "invalid_vote_id")
            else if (u != v.initiator and not(u.in(l.bosses))) deny(s, "invalid_request")
            else done(s, lobbyOf(s, u), endVote(l, v, "cancelled"))
      }
    }

  // "Start the battle for the lobby. If this request succeed players will receive a
  // battle/start request." Starting is a vote action (voteActions start).
  // ASSUMPTION LOBBY-A14: success = accepted (vote opened or autohost asked).
  pure def startBattle(s: State, u: UserId): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      if (l.battle != NoBattle) deny(s, "invalid_request")               // LOBBY-20
      else if (not(canAct(l, u))) deny(s, "invalid_request")
      else gated(s, lobbyOf(s, u), u, VStart, { ...l, battle: Starting })
    }

  // "Join the battle this lobby is currently playing (as a spectator). If the
  // request success, the client should receive shortly after a battle/start".
  // `full` is the battle's answer (autohost side).
  pure def joinBattle(s: State, u: UserId, full: bool): Outcome =
    if (not(inLobby(s, u))) deny(s, "not_in_lobby")
    else {
      val l = myLobby(s, u)
      val id = lobbyOf(s, u)
      if (not(isRunning(l.battle))) deny(s, "no_battle")
      else if (full) deny(s, "battle_full")
      else finish(s, withLobby(s, id, { ...l, inBattle: l.inBattle.union(Set(u)) }), Ok, Set(),
                  Set((u, BattleStart(id))))
    }

  // "Idempotent, subscribing multiple time has no effect." "The event
  // lobby/listReset holds the full list of lobbies." ASSUMPTION LOBBY-A02: each
  // subscribeList is followed by a listReset to the caller.
  pure def subscribeList(s: State, u: UserId): Outcome =
    finish(s, { ...s, subscribers: s.subscribers.union(Set(u)) }, Ok, Set(), Set((u, ListReset)))

  // "Idempotent, if not subscribed, will still succeed."
  pure def unsubscribeList(s: State, u: UserId): Outcome =
    finish(s, { ...s, subscribers: s.subscribers.exclude(Set(u)) }, Ok, Set(), Set())

  // ================================================================ environment
  // The vote timer fires (currentVote.until). Late or repeated fires do nothing.
  pure def voteTimeout(s: State, id: LobbyId, vid: int): Outcome =
    if (not(id.in(s.lobbies.keys())) or voteId(s.lobbies.get(id)) != vid) envNoop(s)
    else { val o = done(s, id, settle(s.lobbies.get(id), true))
           { ...o, reply: NoReply } }

  // The autohost answers the start request: started -> battle/start to members.
  pure def autohostStarted(s: State, id: LobbyId): Outcome =
    if (not(id.in(s.lobbies.keys())) or s.lobbies.get(id).battle != Starting) envNoop(s)
    else {
      val l = s.lobbies.get(id)
      finish(s, { ...withLobby(s, id, { ...l, battle: Running(s.nextBattle), inBattle: members(l) }),
                  nextBattle: s.nextBattle + 1 },
             NoReply, Set(), send(members(l), BattleStart(id)))
    }
  // ... or fails. Nothing tells the clients (LOBBY-21).
  pure def autohostFailed(s: State, id: LobbyId): Outcome =
    if (not(id.in(s.lobbies.keys())) or s.lobbies.get(id).battle != Starting) envNoop(s)
    else finish(s, withLobby(s, id, { ...s.lobbies.get(id), battle: NoBattle }), NoReply, Set(), Set())

  // The battle ends: currentBattle becomes null.
  pure def battleEnded(s: State, id: LobbyId): Outcome =
    if (not(id.in(s.lobbies.keys())) or not(isRunning(s.lobbies.get(id).battle))) envNoop(s)
    else finish(s, withLobby(s, id, { ...s.lobbies.get(id), battle: NoBattle, inBattle: Set() }), NoReply, Set(), Set())

  // The session ends (grace period over). The user is gone: no lobby/left
  // (ASSUMPTION LOBBY-A15); the list subscription dies with the session.
  pure def sessionEnded(s: State, u: UserId): Outcome = {
    val s1 = { ...s, subscribers: s.subscribers.exclude(Set(u)) }
    val s2 = if (inLobby(s, u)) withLobby(s1, lobbyOf(s, u), removeMember(myLobby(s, u), u)) else s1
    finish(s, s2, NoReply, Set(u), Set())
  }

  // "can also be forcibly removed from a lobby ... if the lobby crashed".
  pure def lobbyCrashed(s: State, id: LobbyId): Outcome =
    if (not(id.in(s.lobbies.keys()))) envNoop(s)
    else finish(s, { ...s, lobbies: mapRemove(s.lobbies, id) }, NoReply, Set(), Set())

  // "banned from this lobby until that timestamp": the ban runs out.
  pure def banExpired(s: State, id: LobbyId, u: UserId): Outcome =
    if (not(id.in(s.lobbies.keys())) or not(u.in(s.lobbies.get(id).bans))) envNoop(s)
    else finish(s, withLobby(s, id, { ...s.lobbies.get(id), bans: s.lobbies.get(id).bans.exclude(Set(u)) }),
                NoReply, Set(), Set())

  // Other modules: the user enters/leaves matchmaking or a non-lobby battle.
  // Design: "Queueing while in a lobby is not allowed" -> refused while in a lobby.
  pure def otherActivity(s: State, u: UserId, on: bool): Outcome =
    if (on and inLobby(s, u)) envNoop(s)
    else finish(s, { ...s, elsewhere: if (on) s.elsewhere.union(Set(u)) else s.elsewhere.exclude(Set(u)) },
                NoReply, Set(), Set())

  // ================================================================ state machine
  var s: State
  var prev: State
  var lastCmd: str
  var lastReply: Reply
  var lastEvents: Set[(UserId, Event)]

  pure val s0: State = { lobbies: Map(), nextLobby: 0, nextBattle: 0, subscribers: Set(), elsewhere: Set() }

  action apply(cmd: str, o: Outcome): bool = all {
    prev' = s, s' = o.state, lastCmd' = cmd, lastReply' = o.reply, lastEvents' = o.events,
  }
  action init = all {
    s' = s0, prev' = s0, lastCmd' = "init", lastReply' = NoReply, lastEvents' = Set(),
  }
  action on(cmd: str, o: Outcome): bool = all { cmd.in(ENABLED), apply(cmd, o) }

  pure def botCands(s: State, u: UserId): Set[BotId] =
    (if (inLobby(s, u)) myLobby(s, u).bots.keys() else Set()).union(Set(NO_ID))
  pure def voteCands(s: State, id: LobbyId): Set[int] =
    (if (id.in(s.lobbies.keys())) Set(voteId(s.lobbies.get(id))) else Set()).union(Set(NO_ID))

  action step = {
    nondet u = USERS.oneOf()
    nondet t = USERS.oneOf()
    nondet id = s.lobbies.keys().union(Set(s.nextLobby)).oneOf()
    nondet a = ALLY_TEAMS.union(Set(NO_ID)).oneOf()
    nondet flag = Bool.oneOf()
    nondet caps = ALLY_TEAMS.setOfMaps(CAPS).oneOf()
    nondet b = botCands(s, u).oneOf()
    nondet vid = voteCands(s, lobbyOf(s, u)).oneOf()
    nondet tvid = voteCands(s, id).oneOf()
    nondet ballot = Set("yes", "no", "abstain").oneOf()
    nondet v = Set(0, 1).oneOf()
    nondet ch = Set(UName(v), UMap(v), UCaps(caps)).oneOf()
    any {
      on("lobby/create", create(s, u, flag, caps)),
      on("lobby/join", join(s, u, id)),
      on("lobby/leave", leave(s, u)),
      on("lobby/joinAllyTeam", joinAllyTeam(s, u, a)),
      on("lobby/spectate", spectate(s, u)),
      on("lobby/joinQueue", joinQueue(s, u)),
      on("lobby/updateClientStatus", updateClientStatus(s, u, flag)),
      on("lobby/addBot", addBot(s, u, a)),
      on("lobby/removeBot", removeBot(s, u, b)),
      on("lobby/updateBot", updateBot(s, u, b, v)),
      on("lobby/update", update(s, u, ch)),
      on("lobby/appointBoss", appointBoss(s, u, t)),
      on("lobby/unboss", unboss(s, u, t)),
      on("lobby/kickban", kickban(s, u, t, flag)),
      on("lobby/voteSubmit", voteSubmit(s, u, vid, ballot)),
      on("lobby/voteCancel", voteCancel(s, u, vid)),
      on("lobby/startBattle", startBattle(s, u)),
      on("lobby/joinBattle", joinBattle(s, u, flag)),
      on("lobby/subscribeList", subscribeList(s, u)),
      on("lobby/unsubscribeList", unsubscribeList(s, u)),
      on("env/voteTimeout", voteTimeout(s, id, tvid)),
      on("env/autohostStarted", autohostStarted(s, id)),
      on("env/autohostFailed", autohostFailed(s, id)),
      on("env/battleEnded", battleEnded(s, id)),
      on("env/sessionEnded", sessionEnded(s, u)),
      on("env/lobbyCrashed", lobbyCrashed(s, id)),
      on("env/banExpired", banExpired(s, id, t)),
      on("env/otherActivity", otherActivity(s, u, flag)),
    }
  }

  // ================================================================ properties
  // "A player can only be in at most one lobby at a time."
  val atMostOneLobby = USERS.forall(u => lobbiesOf(s, u).size() <= 1)
  // Design: a user is in at most one of lobby / matchmaking / battle (LOBBY-03).
  val activitySlot = s.elsewhere.forall(u => not(inLobby(s, u)))

  pure def voteOk(l: Lobby): bool = match l.vote {
    | NoVote => true
    | AVote(v) => and { v.initiator.in(v.ballots.keys()), v.id < l.nextVote,
                        not(v.id.in(l.history.keys())), decide(v, false) == "" }
  }
  pure def lobbyOk(l: Lobby): bool = and {
    members(l) != Set(),                                         // empty lobbies are disposed
    members(l).size() <= MAX_MEMBERS,
    l.players.keys().intersect(l.spectators) == Set(),
    l.queue.keys().subseteq(l.spectators),                      // queued = spectator with a position
    l.queue.keys().forall(x => l.queue.keys().forall(y => x == y or l.queue.get(x) != l.queue.get(y))),
    l.caps.keys() == ALLY_TEAMS,
    l.players.keys().forall(u => l.players.get(u).ally.in(ALLY_TEAMS)),
    l.bots.keys().forall(b => l.bots.get(b).ally.in(ALLY_TEAMS)),
    ALLY_TEAMS.forall(a => occupants(l, a) <= capOf(l, a)),     // ally team <= capacity
    ALLY_TEAMS.forall(a => slotsIn(l, a).size() == occupants(l, a)
                           and slotsIn(l, a).forall(x => 0 <= x and x < occupants(l, a))),
    l.queue.keys() != Set() implies ALLY_TEAMS.forall(a => free(l, a) == 0),   // promotion is eager
    l.bosses.subseteq(members(l)),                              // boss ⊆ members
    not(l.bossesEnabled) implies l.bosses == Set(),             // bosses_not_allowed setting
    l.bans.intersect(members(l)) == Set(),                      // banned users are not members
    l.bots.keys().forall(b => l.bots.get(b).host.in(members(l))),
    l.inBattle != Set() implies isRunning(l.battle),
    voteOk(l),
  }
  val wellFormed = s.lobbies.keys().forall(id => lobbyOk(s.lobbies.get(id)))

  val reasonsInSchema = replyInSchema(lastCmd, lastReply)
  val denialsChangeNothing = match lastReply {
    | Failed(_) => s == prev and lastEvents == Set()
    | _ => true
  }
  // lobby/updated reaches only members of that lobby.
  val updatedOnlyToMembers = lastEvents.forall(e => match e._2 {
    | Updated(id) => id.in(s.lobbies.keys()) and e._1.in(members(s.lobbies.get(id)))
    | VoteEnded(d) => d.lobby.in(s.lobbies.keys()) and e._1.in(members(s.lobbies.get(d.lobby)))
    | BattleStart(id) => id.in(s.lobbies.keys()) and e._1.in(members(s.lobbies.get(id)))
                         and isRunning(s.lobbies.get(id).battle)
    | _ => true
  })
  // lobby/left only to a removed member, and never on lobby/leave by... the leaver.
  val leftOnlyToRemoved = lastEvents.forall(e => match e._2 {
    | Left(d) => and { not(inLobby(s, e._1)), d.lobby.in(prev.lobbies.keys()),
                       e._1.in(members(prev.lobbies.get(d.lobby))) }
    | _ => true
  })
  // listUpdated / listReset only to subscribers.
  val listOnlyToSubscribers = lastEvents.forall(e => match e._2 {
    | ListUpdated(_) => e._1.in(s.subscribers)
    | ListReset => e._1.in(s.subscribers)
    | _ => true
  })
  // Completeness: a visible change reaches every member who stays.
  val updatedComplete = s.lobbies.keys().intersect(prev.lobbies.keys()).forall(id =>
    view(prev.lobbies.get(id)) != view(s.lobbies.get(id)) implies
      members(prev.lobbies.get(id)).intersect(members(s.lobbies.get(id))).forall(u => (u, Updated(id)).in(lastEvents)))
  val listComplete = prev.lobbies.keys().union(s.lobbies.keys()).forall(id =>
    ovOf(prev, id) != ovOf(s, id) implies s.subscribers.forall(u => (u, ListUpdated(id)).in(lastEvents)))
  def gotLeft(u: UserId): bool = lastEvents.exists(e => e._1 == u and match e._2 { | Left(_) => true | _ => false })
  // A member removed by anything but their own leave or the end of their session gets lobby/left.
  val leftComplete = (lastCmd != "lobby/leave" and lastCmd != "env/sessionEnded") implies
    prev.lobbies.keys().forall(id => members(prev.lobbies.get(id)).forall(u => inLobby(s, u) or gotLeft(u)))

  val safety = and {
    atMostOneLobby, activitySlot, wellFormed, reasonsInSchema, denialsChangeNothing,
    updatedOnlyToMembers, leftOnlyToRemoved, listOnlyToSubscribers,
    updatedComplete, listComplete, leftComplete,
  }

  // ---------------------------------------------------------------- witnesses
  def hit(cmd: str, r: Reply): bool = lastCmd == cmd and lastReply == r
  val sawUpdated = lastEvents.exists(e => match e._2 { | Updated(_) => true | _ => false })
  def sawLeft(r: str): bool = lastEvents.exists(e => match e._2 { | Left(d) => d.reason == r | _ => false })
  def sawVoteEnded(o: str): bool = lastEvents.exists(e => match e._2 { | VoteEnded(d) => d.outcome == o | _ => false })
  val votedKickPassed = lastCmd == "lobby/voteSubmit" and sawLeft("kicked")
  val sawListUpdated = lastEvents.exists(e => match e._2 { | ListUpdated(id) => id.in(s.lobbies.keys()) | _ => false })
  val sawListRemoved = lastEvents.exists(e => match e._2 { | ListUpdated(id) => not(id.in(s.lobbies.keys())) | _ => false })
  val sawListReset = lastEvents.exists(e => e._2 == ListReset)
  val sawBattleStart = lastCmd == "env/autohostStarted" and lastEvents.exists(e => match e._2 { | BattleStart(_) => true | _ => false })
  val battleStartFailed = lastCmd == "env/autohostFailed" and s != prev
  val sawBattleEnded = lastCmd == "env/battleEnded" and s != prev
  val sawBanExpired = lastCmd == "env/banExpired" and s != prev
  // someone left the queue for an ally team without asking for a specific one
  val queuePromoted = s.lobbies.keys().intersect(prev.lobbies.keys()).exists(id =>
    prev.lobbies.get(id).queue.keys().exists(u => u.in(s.lobbies.get(id).players.keys())))
  val evictedToQueue = lastCmd == "lobby/update" and s.lobbies.keys().intersect(prev.lobbies.keys()).exists(id =>
    prev.lobbies.get(id).players.keys().exists(u => u.in(s.lobbies.get(id).queue.keys())))
}

// The main instance: 4 users, 2 ally teams of capacity 1 or 2, 3 members max.
module lobby_test {
  import common.* from "./common"
  import lobby(USERS = Set("a", "b", "c", "d"), ALLY_TEAMS = Set(0, 1), CAPS = Set(1, 2),
               MAX_MEMBERS = 3, ENABLED = ALL_STEPS).*

  pure val ALL_STEPS = Set(
    "lobby/create", "lobby/join", "lobby/leave", "lobby/joinAllyTeam", "lobby/spectate",
    "lobby/joinQueue", "lobby/updateClientStatus", "lobby/addBot", "lobby/removeBot",
    "lobby/updateBot", "lobby/update", "lobby/appointBoss", "lobby/unboss", "lobby/kickban",
    "lobby/voteSubmit", "lobby/voteCancel", "lobby/startBattle", "lobby/joinBattle",
    "lobby/subscribeList", "lobby/unsubscribeList", "env/voteTimeout", "env/autohostStarted",
    "env/autohostFailed", "env/battleEnded", "env/sessionEnded", "env/lobbyCrashed",
    "env/banExpired", "env/otherActivity")

  pure val c11 = Map(0 -> 1, 1 -> 1)
  pure val c22 = Map(0 -> 2, 1 -> 2)

  // a creates (bosses allowed, 1+1 slots); b, c join as spectators; b takes the free
  // ally team; c queues; a goes spectating -> c is promoted into a's spot.
  run membershipQueueTest =
    init
      .then(apply("lobby/subscribeList", subscribeList(s, "d")))
      .expect(lastEvents == Set(("d", ListReset)))
      .then(apply("lobby/create", create(s, "a", true, c11)))
      .expect(and { lastReply == Ok, s.lobbies.get(0).bosses == Set("a"),
                    s.lobbies.get(0).players.get("a") == { ally: 0, slot: 0, ready: false },
                    lastEvents == Set(("d", ListUpdated(0))) })
      .then(apply("lobby/create", create(s, "a", true, c11)))
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("lobby/join", join(s, "b", 0)))
      .expect(and { lastReply == Ok, lastEvents == Set(("a", Updated(0))) })   // no listUpdated: spectators not counted
      .then(apply("lobby/join", join(s, "b", 0)))                               // idempotent
      .expect(and { lastReply == Ok, lastEvents == Set() })
      .then(apply("lobby/join", join(s, "c", 7)))
      .expect(lastReply == Failed("invalid_lobby_id"))
      .then(apply("lobby/joinAllyTeam", joinAllyTeam(s, "b", 0)))
      .expect(lastReply == Failed("ally_team_full"))
      .then(apply("lobby/joinAllyTeam", joinAllyTeam(s, "b", 1)))
      .expect(and { lastReply == Ok, lastEvents == Set(("a", Updated(0)), ("b", Updated(0)), ("d", ListUpdated(0))) })
      .then(apply("lobby/join", join(s, "c", 0)))
      .then(apply("lobby/join", join(s, "d", 0)))
      .expect(lastReply == Failed("lobby_full"))
      .then(apply("lobby/joinQueue", joinQueue(s, "c")))
      .expect(and { lastReply == Ok, s.lobbies.get(0).queue == Map("c" -> 1) })
      .then(apply("lobby/updateClientStatus", updateClientStatus(s, "c", true)))
      .expect(lastReply == Failed("not_a_player"))
      .then(apply("lobby/updateClientStatus", updateClientStatus(s, "a", true)))
      .expect(lastEvents == Set(("a", Updated(0)), ("b", Updated(0)), ("c", Updated(0))))
      .then(apply("lobby/spectate", spectate(s, "a")))
      .expect(and { s.lobbies.get(0).players.get("c") == { ally: 0, slot: 0, ready: false },
                    s.lobbies.get(0).queue == Map(), "a".in(s.lobbies.get(0).spectators) })
      .then(apply("lobby/spectate", spectate(s, "a")))                         // already spectating
      .expect(and { lastReply == Ok, lastEvents == Set() })
      .then(apply("lobby/leave", leave(s, "c")))                               // a was spectating, not queued
      .expect(and { lastReply == Ok, lastEvents == Set(("a", Updated(0)), ("b", Updated(0)), ("d", ListUpdated(0))) })
      .then(apply("lobby/leave", leave(s, "c")))
      .expect(lastReply == Failed("not_in_lobby"))
      .then(apply("lobby/leave", leave(s, "a")))                               // boss leaves: bosses empty
      .expect(s.lobbies.get(0).bosses == Set())
      .then(apply("lobby/leave", leave(s, "b")))                               // last member: disposed
      .expect(and { s.lobbies.keys() == Set(), lastEvents == Set(("d", ListUpdated(0))) })

  // Player joinQueue swaps with the first waiting member; allyTeamConfig shrink
  // puts the player that no longer fits at the front of the queue.
  run queueSwapAndReconfigureTest =
    init
      .then(apply("lobby/create", create(s, "a", true, c11)))
      .then(apply("lobby/join", join(s, "b", 0)))
      .then(apply("lobby/joinAllyTeam", joinAllyTeam(s, "b", 1)))
      .then(apply("lobby/join", join(s, "c", 0)))
      .then(apply("lobby/joinQueue", joinQueue(s, "c")))
      .then(apply("lobby/joinQueue", joinQueue(s, "a")))
      .expect(and { lastReply == Ok, s.lobbies.get(0).players.get("c").ally == 0,
                    s.lobbies.get(0).queue == Map("a" -> 2) })   // positions need not be consecutive
      .then(apply("lobby/update", update(s, "b", UName(1))))
      .expect(lastReply == Failed("invalid_request"))                            // a is the boss
      .then(apply("lobby/update", update(s, "a", UCaps(c22))))                  // grow: a promoted
      .expect(and { s.lobbies.get(0).players.get("a") == { ally: 0, slot: 1, ready: false },
                    s.lobbies.get(0).queue == Map() })
      .then(apply("lobby/update", update(s, "a", UCaps(c11))))                  // shrink: a evicted to the queue
      .expect(and { s.lobbies.get(0).queue == Map("a" -> 0),
                    s.lobbies.get(0).players.keys() == Set("b", "c") })

  // Bots take slots, are freed by removeBot, and leave with their host.
  run botsTest =
    init
      .then(apply("lobby/create", create(s, "a", false, c11)))
      .then(apply("lobby/addBot", addBot(s, "a", 0)))
      .expect(lastReply == Failed("ally_team_full"))
      .then(apply("lobby/addBot", addBot(s, "a", 5)))
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("lobby/addBot", addBot(s, "b", 1)))
      .expect(lastReply == Failed("not_in_lobby"))
      .then(apply("lobby/addBot", addBot(s, "a", 1)))
      .expect(and { lastReply == Ok, s.lobbies.get(0).bots.get(0) == { host: "a", ally: 1, slot: 0, config: 0 } })
      .then(apply("lobby/updateBot", updateBot(s, "a", 0, 1)))
      .expect(lastEvents == Set(("a", Updated(0))))                             // config not in the overview
      .then(apply("lobby/updateBot", updateBot(s, "a", 3, 1)))
      .expect(lastReply == Failed("invalid_bot"))
      .then(apply("lobby/join", join(s, "b", 0)))
      .then(apply("lobby/joinQueue", joinQueue(s, "b")))
      .expect(s.lobbies.get(0).queue == Map("b" -> 1))                          // no room
      .then(apply("lobby/removeBot", removeBot(s, "b", 0)))
      .expect(and { lastReply == Ok, s.lobbies.get(0).players.get("b").ally == 1 })   // promoted
      .then(apply("lobby/removeBot", removeBot(s, "b", 0)))
      .expect(lastReply == Failed("invalid_bot"))
      .then(apply("lobby/spectate", spectate(s, "b")))
      .then(apply("lobby/addBot", addBot(s, "b", 1)))                           // a spectator adds a bot
      .then(apply("lobby/leave", leave(s, "b")))
      .expect(s.lobbies.get(0).bots == Map())                                   // bots leave with their host

  // Bosses: appoint, unboss, bosses_not_allowed, kick and ban.
  run bossesKickbanTest =
    init
      .then(apply("lobby/subscribeList", subscribeList(s, "d")))
      .then(apply("lobby/create", create(s, "a", true, c22)))
      .then(apply("lobby/join", join(s, "b", 0)))
      .then(apply("lobby/join", join(s, "c", 0)))
      .then(apply("lobby/appointBoss", appointBoss(s, "b", "c")))
      .expect(lastReply == Failed("invalid_request"))                          // b is not a boss
      .then(apply("lobby/appointBoss", appointBoss(s, "a", "d")))
      .expect(lastReply == Failed("invalid_request"))                          // d not a member
      .then(apply("lobby/appointBoss", appointBoss(s, "a", "b")))
      .expect(and { lastReply == Ok, s.lobbies.get(0).bosses == Set("a", "b"),
                    lastEvents == Set(("a", Updated(0)), ("b", Updated(0)), ("c", Updated(0))) })
      .then(apply("lobby/unboss", unboss(s, "c", "a")))
      .expect(lastReply == Failed("not_a_boss"))
      .then(apply("lobby/unboss", unboss(s, "b", "b")))
      .expect(s.lobbies.get(0).bosses == Set("a"))
      .then(apply("lobby/kickban", kickban(s, "b", "c", false)))
      .expect(lastReply == Failed("invalid_request"))                          // not a boss
      .then(apply("lobby/kickban", kickban(s, "a", "c", true)))
      .expect(and { lastReply == Ok, s.lobbies.get(0).bans == Set("c"),
                    lastEvents == Set(("c", Left({ lobby: 0, reason: "banned" })),
                                      ("a", Updated(0)), ("b", Updated(0))) })
      .then(apply("lobby/join", join(s, "c", 0)))
      .expect(lastReply == Failed("banned"))
      .then(apply("env/banExpired", banExpired(s, 0, "c")))
      .expect(lastEvents == Set())
      .then(apply("lobby/join", join(s, "c", 0)))
      .expect(lastReply == Ok)
      .then(apply("lobby/kickban", kickban(s, "a", "c", false)))
      .expect(and { lastEvents.contains(("c", Left({ lobby: 0, reason: "kicked" }))),
                    s.lobbies.get(0).bans == Set() })
      .then(apply("lobby/create", create(s, "c", false, c22)))
      .then(apply("lobby/appointBoss", appointBoss(s, "c", "c")))
      .expect(lastReply == Failed("bosses_not_allowed"))
      .then(apply("env/lobbyCrashed", lobbyCrashed(s, 1)))
      .expect(lastEvents == Set(("c", Left({ lobby: 1, reason: "crashed" })), ("d", ListUpdated(1))))

  // Votes without bosses: a kick vote passes; a map vote fails; a cancel; a timeout.
  run votesTest =
    init
      .then(apply("lobby/create", create(s, "a", false, c22)))
      .then(apply("lobby/join", join(s, "b", 0)))
      .then(apply("lobby/joinAllyTeam", joinAllyTeam(s, "b", 1)))
      .then(apply("lobby/join", join(s, "c", 0)))
      .then(apply("lobby/joinAllyTeam", joinAllyTeam(s, "c", 1)))
      .then(apply("lobby/kickban", kickban(s, "a", "c", false)))               // 3 voters -> vote 0
      .expect(and { lastReply == Ok, s.lobbies.get(0).vote != NoVote, "c".in(members(s.lobbies.get(0))) })
      .then(apply("lobby/update", update(s, "b", UMap(1))))
      .expect(lastReply == Failed("invalid_request"))                          // one vote at a time
      .then(apply("lobby/voteSubmit", voteSubmit(s, "b", 5, "yes")))
      .expect(lastReply == Failed("invalid_vote_id"))
      .then(apply("lobby/voteSubmit", voteSubmit(s, "b", 0, "yes")))           // 2 of 3 yes: passed
      .expect(and { lastReply == Ok, s.lobbies.get(0).history == Map(0 -> "passed"),
                    lastEvents == Set(("c", Left({ lobby: 0, reason: "kicked" })),
                                      ("a", Updated(0)), ("b", Updated(0)),
                                      ("a", VoteEnded({ lobby: 0, vote: 0, outcome: "passed" })),
                                      ("b", VoteEnded({ lobby: 0, vote: 0, outcome: "passed" }))) })
      .then(apply("lobby/update", update(s, "b", UMap(1))))                    // 2 voters -> vote 1
      .then(apply("lobby/voteSubmit", voteSubmit(s, "a", 1, "no")))
      .expect(and { s.lobbies.get(0).history.get(1) == "failed", s.lobbies.get(0).map == 0 })
      .then(apply("lobby/startBattle", startBattle(s, "a")))                    // vote 2
      .then(apply("lobby/voteCancel", voteCancel(s, "b", 2)))
      .expect(lastReply == Failed("invalid_request"))                          // not initiator, no bosses
      .then(apply("lobby/voteCancel", voteCancel(s, "a", 2)))
      .expect(s.lobbies.get(0).history.get(2) == "cancelled")
      .then(apply("lobby/startBattle", startBattle(s, "a")))                    // vote 3
      .then(apply("env/voteTimeout", voteTimeout(s, 0, 3)))                     // 1 of 2 voted: no quorum
      .expect(and { s.lobbies.get(0).history.get(3) == "timeout",
                    lastEvents.contains(("b", VoteEnded({ lobby: 0, vote: 3, outcome: "timeout" }))) })
      .then(apply("env/voteTimeout", voteTimeout(s, 0, 3)))                     // late fire
      .expect(lastEvents == Set())

  // Battle: start without bosses alone, autohost answers, joinBattle, end.
  run battleTest =
    init
      .then(apply("lobby/subscribeList", subscribeList(s, "d")))
      .then(apply("lobby/create", create(s, "a", true, c22)))
      .then(apply("lobby/join", join(s, "b", 0)))
      .then(apply("lobby/joinBattle", joinBattle(s, "b", false)))
      .expect(lastReply == Failed("no_battle"))
      .then(apply("lobby/startBattle", startBattle(s, "b")))
      .expect(lastReply == Failed("invalid_request"))                          // a is the boss
      .then(apply("lobby/startBattle", startBattle(s, "a")))
      .expect(and { lastReply == Ok, lastEvents == Set() })                    // accepted, nothing visible yet
      .then(apply("lobby/startBattle", startBattle(s, "a")))
      .expect(lastReply == Failed("invalid_request"))                          // already starting
      .then(apply("env/autohostFailed", autohostFailed(s, 0)))
      .expect(and { s.lobbies.get(0).battle == NoBattle, lastEvents == Set() })   // LOBBY-21: silent
      .then(apply("lobby/startBattle", startBattle(s, "a")))
      .then(apply("env/autohostStarted", autohostStarted(s, 0)))
      .expect(lastEvents == Set(("a", BattleStart(0)), ("b", BattleStart(0)),
                                ("a", Updated(0)), ("b", Updated(0)), ("d", ListUpdated(0))))
      .then(apply("lobby/join", join(s, "c", 0)))
      .then(apply("lobby/joinBattle", joinBattle(s, "c", true)))
      .expect(lastReply == Failed("battle_full"))
      .then(apply("lobby/joinBattle", joinBattle(s, "c", false)))
      .expect(and { lastReply == Ok, lastEvents == Set(("c", BattleStart(0))) })
      .then(apply("env/battleEnded", battleEnded(s, 0)))
      .expect(lastEvents == Set(("a", Updated(0)), ("b", Updated(0)), ("c", Updated(0)), ("d", ListUpdated(0))))

  // Sessions, list subscriptions, activity slot.
  run sessionAndListTest =
    init
      .then(apply("lobby/subscribeList", subscribeList(s, "d")))
      .then(apply("lobby/subscribeList", subscribeList(s, "d")))               // idempotent, resent listReset
      .expect(and { s.subscribers == Set("d"), lastEvents == Set(("d", ListReset)) })
      .then(apply("env/otherActivity", otherActivity(s, "b", true)))           // b queues for matchmaking
      .then(apply("lobby/create", create(s, "a", true, c11)))
      .then(apply("lobby/join", join(s, "b", 0)))
      .expect(lastReply == Failed("invalid_request"))
      .then(apply("lobby/join", join(s, "c", 0)))
      .then(apply("env/otherActivity", otherActivity(s, "c", true)))           // refused: c is in a lobby
      .expect(s.elsewhere == Set("b"))
      .then(apply("env/sessionEnded", sessionEnded(s, "a")))                   // no lobby/left for a
      .expect(lastEvents == Set(("c", Updated(0)), ("d", ListUpdated(0))))
      .then(apply("lobby/unsubscribeList", unsubscribeList(s, "d")))
      .then(apply("lobby/leave", leave(s, "c")))
      .expect(and { s.lobbies == Map(), lastEvents == Set() })
      .then(apply("lobby/unsubscribeList", unsubscribeList(s, "d")))
      .expect(lastReply == Ok)
}

// Votes, bans and battles: 3 users, one ally team of 3, fewer step kinds so that
// simulation reaches deep vote outcomes.
module lobby_votes {
  import common.* from "./common"
  import lobby(USERS = Set("a", "b", "c"), ALLY_TEAMS = Set(0), CAPS = Set(3), MAX_MEMBERS = 3,
               ENABLED = Set("lobby/create", "lobby/join", "lobby/joinAllyTeam", "lobby/kickban",
                             "lobby/voteSubmit", "lobby/voteCancel", "lobby/startBattle",
                             "lobby/joinBattle", "lobby/leave", "env/voteTimeout",
                             "env/autohostStarted", "env/autohostFailed", "env/battleEnded",
                             "env/banExpired")).*
}

// Join queue and ally team reconfiguration: one ally team of capacity 1 or 2.
module lobby_queue {
  import common.* from "./common"
  import lobby(USERS = Set("a", "b", "c"), ALLY_TEAMS = Set(0), CAPS = Set(1, 2), MAX_MEMBERS = 3,
               ENABLED = Set("lobby/create", "lobby/join", "lobby/leave", "lobby/joinAllyTeam",
                             "lobby/spectate", "lobby/joinQueue", "lobby/update", "lobby/addBot",
                             "lobby/removeBot", "lobby/kickban", "lobby/unboss")).*
}
