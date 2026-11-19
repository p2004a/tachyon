# Independent review of the Divergence findings

Reviewer: one independent pass over every `Kind: Divergence-teiserver` / `Divergence-bar-lobby` entry in
`findings/{party,lobby,matchmaking,autohost,session,messaging,friend,clan}.md` (91 entries plus the two
"Divergence check" summaries PARTY-21 and MM-29, which were read but are not scored). For each entry I read
the cited code and its callers: `tachyon_handler.ex` error mapping, GenServer/gen_statem state and timers, and
the tests under `teiserver/test/` that pin the behaviour. I also read the cited Tachyon text (`docs/`, `schema/`,
`src/schema/`). Nothing was run: no Elixir tests, no bar-lobby. Snapshot: teiserver `b36429f`, bar-lobby `ee58acd`.

Verdicts:
- **C**: CONFIRMED.
- **CM**: CONFIRMED-MINOR (true, but cosmetic, unobservable, or allowed by a "may/can").
- **P**: PARTIAL (the core is true, but a detail is wrong, or the "protocol" side is only a
  proposed default (README.md, PD-nn) and not Tachyon text).
- **R**: REFUTED.
- **U**: UNVERIFIABLE.

Severity is given for confirmed and partial entries:
- **High**: stuck state, lost data, crash, security, or client and server disagree on state.
- **Medium**: wrong reason or event, recoverable.
- **Low**: everything else.

**A systematic caveat.** Several entries measure teiserver against *proposed defaults* (DECISIONS.md): the
activity slot (PD-03), the 256-member limit (PD-04), battles that survive an autohost disconnect (PD-10), full-state
resend after reconnect (PD-08), and majority-of-players results (PD-11). These are **not** in Tachyon (`grep` over `docs/` and `src/schema/`
finds none of them). Those entries are marked P (or R when nothing else is left). They should go to protocol owners
as proposals ("Gap"), not as implementation divergences.

## Summary table

| ID | Verdict | Sev | One-line reason |
|---|---|---|---|
| PARTY-02 | CM | Low | teiserver follows party.md:15 (README). The `party/invited` event description is what is wrong |
| PARTY-03 | C | High | `session.ex:856-868` leaves the old party (and matchmaking) before `Party.accept_invite`. A failed accept still removes the user. bar-lobby throws before `removeParty` |
| PARTY-05 | C | Medium | Timer keyed by user (`party/server.ex:249`). Not cancelled on accept (`:279-291`) or on invitee DOWN (`:471-473`). A stale timer kills a re-invite |
| PARTY-06 | C | Low | `tachyon_handler.ex:759-767` maps every cancelInvite error to `invalid_request`. The schema has `not_in_party`/`invalid_invite` |
| PARTY-07 | P | Low | Code true (the session process answers even while detached or in battle). Whether this violates "connected" depends on an undefined term |
| PARTY-08 | C | Medium | No self check in kick (`party/server.ex:328-349`) and no empty check. A lone self-kick leaves a member-less party process alive |
| PARTY-10 | C | Low | `src/schema/party/leave.ts:8-9` says no-op. teiserver answers `invalid_request "Not in a party"` |
| PARTY-13 | C | Medium | The `{:removed}` cast (`session.ex:1469-1476`) never demonitors `:current_party`. A later DOWN sends `party/removed {partyId: nil}` (see also PARTY-22, was NEW-01) |
| PARTY-15 | C | High | `matchmaking_notify_cancel` is never called from `remove_member` or from the `start_match` success or failure paths. The party stays locked until the queue process dies (the only test that unlocks is "queue crash reset party matchmaking state") |
| PARTY-16 | C | High | Kick touches neither the party's `matchmaking` nor the kicked session's queue state. The kicked user stays inside the party's queue ticket |
| PARTY-17 | CM | Low | `events/leave.ex:33` demonitors `leaver_id`, not `{:member, id}`. The later DOWN re-sends an unchanged `party/updated` (the session's `<=` version check lets it through) |
| PARTY-18 | C | High | `session.ex:704` and `:827` return `{:reply, x}` with no state, so the session crashes. `:704` is reachable by any user (= MSG-04) |
| LOBBY-01 | C | Low | Current schema default is `true`. teiserver uses `|| false`, and its vendored v0 schema has no default (drift). bar-lobby always sends the field |
| LOBBY-02 | C | Medium | Confirmed for every listed command (`tachyon_handler.ex:833,843,980-1055,1087`) |
| LOBBY-03 | P | Medium | Code true. The "activity slot" is proposed default PD-03, not Tachyon. Only `matchmaking/queue`'s `already_in_battle` reason implies part of it |
| LOBBY-04 | C | Medium | No `lobby/voteCancel` clause, so the catch-all returns `command_unimplemented`. bar-lobby sends it (`lobby.store.ts:567`) |
| LOBBY-05 | C | Medium | `lobby.ex:756` requires a boss whenever `boss_enabled?`, even with no boss present, against lobby.md:118 |
| LOBBY-06 | P | Low | Code true. lobby.md only says boss presence "may" disable commands, and nothing says startBattle is vote-gated |
| LOBBY-07 | C | Medium | kickban/appointBoss never check `current_vote`. `start_vote.ex:21` overwrites it, and the old vote gets no voteEnded |
| LOBBY-08 | C | Medium | Three capacity notions: `max_teams` (`lobby.ex:524,683`), sum of `max_players` (`:1399`), and both (`update_ally_team_config.ex:33`) |
| LOBBY-10 | R | – | No 256 limit exists in Tachyon. 251 (bots included) is a defensible engine limit. Mismatch with proposed default PD-04 only |
| LOBBY-11 | C | Medium | `move_player.ex:33` keeps `ready?`. `:42` broadcasts `ready?: false`. Server and clients disagree |
| LOBBY-14 | C | Low | `lobby.ex:1705-1708` voters = non-bot players only. A spectator initiator is not included (contradicts `currentVote.ts:18`) |
| LOBBY-17 | C | Low | `lobby.ex:1211` and the events count bots. `:1337` does not. 5 s batching confirmed (allowed) |
| LOBBY-20 | CM | Low | `battle_already_started` and `no_autohost` become `invalid_request`. The schema offers nothing better except `internal_error` |
| LOBBY-22 | CM | Low | True, but lobby.md says voteEnded exists "if they want to show a notification", which is optional for clients |
| LOBBY-23 | P | Low | Code true. `playerCount` is undefined in Tachyon, so this is a teiserver vs bar-lobby disagreement, not a protocol divergence |
| LOBBY-25 | P | Medium | Code true. "Full state after user/self" is proposed default PD-08, and Tachyon is silent |
| LOBBY-26 | C | High | `vote_ended.ex:80-81` adds the boss with no membership check. Only kick votes are cancelled on leave. The ghost boss locks update, kickban and appointBoss, and the ghost cannot be unbossed (`unboss` needs a member target) |
| MM-10 | P | Low | Code true. Tachyon is silent on a repeated `ready`, so this diverges from the model's assumption only |
| MM-16 | P | Low | Code true. `queue.ts` itself is contradictory (MM-01), and teiserver implements the `already_queued` reading. bar-lobby part true |
| MM-17 | P | Medium | "Queue while in battle succeeds" contradicts the `already_in_battle` reason (C). The lobby part is proposed default PD-03 |
| MM-18 | C | High | After `lost`, a party member's rejoin hits `queue_server.ex:327-368` with no pending slot, gets `invalid_party`, then `cancelled(server_error)` |
| MM-19 | C | High | Same root as PARTY-15. `pairing_room.ex:121-182` never unlocks. `already_queued` reaches the client via `tachyon_handler.ex:394-395` |
| MM-20 | C | Medium | No checkAssets anywhere. README says members "will receive" it |
| MM-21 | C | Medium | `{:shutdown, :asset_changed}` → DOWN → `cancelled(server_error)`. `version_changed` is never emitted. bar-lobby only refreshes on version_changed |
| MM-22 | CM | Low | README step 3 says "can". Only an admin PubSub broadcast exists |
| MM-23 | C | Medium | README step 8 "should repeat this step". The pairing room gives up at once (= AH-05) |
| MM-24 | CM | Low | `ready.ts:7` "10s" vs `pairing_timeout: 20_000`. `timeoutMs` carries the truth |
| MM-25 | R | – | The session's `{:stop, :normal, ...}` after `system/disconnect` fires the queue's `{:player, id}` monitor (kept until `disband_pairing`). `remove_member` → `PairingRoom.cancel`: the room is cancelled at once |
| MM-26 | C | High | All four bullets true. Bullet 3 is worse than stated: the party crash propagates into the caller's session (`Party.join_queues` only catches `:noproc`) |
| MM-27 | CM | Low | `lost` then `cancelled` order confirmed (`session.ex:1288-1289`). Transient UI state only |
| AH-01 | P | High | Session dies with the connection, and the battle stops 100 ms after DOWN with no kill and no `end_tachyon_match`: true. "No battle/ended" is wrong: players get the placeholder from their session's battle monitor (AH-10). The survival requirement is proposed default PD-10 |
| AH-02 | P | Medium | True and pinned by `autohost_test.exs:65`. Tachyon does not say which `since` the server must use. Impact exists only because of AH-01 |
| AH-03 | P | Medium | True (`autohost/session.ex:296-307`, `:192-194`). Tachyon is silent on unknown battle ids |
| AH-04 | P | High | Zombie engine path true. "find_autohost load accounting is off" is wrong: `find_autohost` uses the autohost-reported `currentBattles`, which includes the zombie |
| AH-05 | C | Medium | No retry (`autohost/session.ex:40` TODO). Same as MM-23 |
| AH-06 | P | Low | True (`autohost.ex:54-61`). Tachyon says nothing about admission or capacity accounting |
| AH-07 | CM | Low | Never sent and `availableEngines` ignored: true. Nothing in Tachyon obliges the server to send them |
| AH-08 | P | Medium | Majority of reporters: true (`battle.ex:379-393`). Tachyon defines no aggregation rule (proposed default PD-11) |
| AH-09 | CM | Low | Both ack-handler bugs are real (`autohost/session.ex:337-349`) but latent: in-order acks, no resends while AH-02 holds |
| AH-10 | C | High | Placeholder `battle/ended` (`player/session.ex:1661-1674`). `:autohost_timeout`/`:battle_timeout` stop without `end_tachyon_match`, so the match result is lost |
| AH-11 | P | Low | Answer ignored: true. bar-lobby's `internal_error` is in the schema enum (there is no better reason), so this is a Gap |
| AH-19 | C | Low | Ignore branch true (`session.ex:1360-1365`). Missing while detached is repaired by `user/self.currentBattle` |
| AH-21 | CM | Low | bar-lobby facts true (dedup `battleHistory.store.ts:18`, `ips[0]`) |
| SESSION-01 | CM | Low | `:force_disconnect` → `{:stop, :normal}` with no 1008 or reason. connection.md:40 is a "should", for errors |
| SESSION-03 | C | High | `:connection_timeout` → stop with no `:offline` broadcast. Only `system/disconnect` broadcasts offline |
| SESSION-05 | P | High | teiserver half true but measured against proposed default PD-08. bar-lobby half true for friends. "party presence silently stops" is wrong: `logic/party.ts:176` clears and re-attaches on every user/self |
| SESSION-06 | C | Medium | `:lobby` status is never broadcast. user/self is hardcoded `:menu` (`tachyon_handler.ex:1110`) |
| SESSION-09 | P | Low | teiserver sends no response: true (`tachyon_handler.ex:328-332`). The "Divergence-bar-lobby" half is wrong: awaiting the response is what the protocol asks |
| SESSION-11 | P | Low | The duplicate-id bug is real (`session.ex:731`). Unknown id → `invalid_request` is the only fitting reason, so it is no divergence |
| SESSION-14 | C | Low | No cap and no `subscription_limit_reached` (user.md:684). bar-lobby half true |
| SESSION-16 | C | Medium | `get_subscribe_state` broadcasts `:menu` to every subscriber of the target (`session.ex:1441-1443`) |
| SESSION-17 | C | Low | user.md:871 "should always succeed". Unparsable ids → `invalid_request` (test pins it) |
| SESSION-18 | C | Medium | `country` instead of `countryCode` in user/updated, even against teiserver's own v0 schema. `clanId` vs `clanBaseData` is schema drift |
| SESSION-19 | P | Low | Code true. Tachyon is silent on requests before user/self: a Gap, no divergence |
| SESSION-20 | C | Low | The catch-all and schema-error paths answer events (commands.md:45) |
| SESSION-21 | C | Medium | `transport.ex:272-280`: `handle_command` runs outside the `try` |
| SESSION-22 | R | – | user.md:387 "should be sent ... when they login" does not forbid other sends. Gap only |
| MSG-01 | P | Low | The real issue is the schema contradiction (`maxLength 512` + `message_too_long`). Both implementations do what the schema forces |
| MSG-03 | C | Medium | `GenServer.cast` to an unregistered `:via` returns `:ok`. A DM to an offline or unknown user is "success" and persisted |
| MSG-04 | C | High | `session.ex:704` crash (= PARTY-18) plus `invalid_request` mapping (test pins it) |
| MSG-05 | C | Medium | `call_lobby` → `{:error, :invalid_lobby}` does not match `session.ex:722-725`, so CaseClauseError. Narrow race |
| MSG-07 | C | Medium | `:replace` (`session.ex:558-581`) flushes the old DOWN and keeps `subscribed?: true` |
| MSG-10 | CM | Low | Sticky `dropped?` confirmed (`bounded_queue.ex:83-85`). It is a reasonable extension of an under-specified flag |
| MSG-12 | C | Low | `monotonic_time(:micro_seconds)` is not strictly monotonic and is read in 3 different processes. `split_when` cuts at the first equal marker. Rare |
| MSG-14 | C | Medium | `resumePoint` → `latest` when any local chat exists (self-inserted or empty lobby/party maps) skips messages buffered during grace |
| MSG-15 | U | Low | Code true (node-local `Registry`, lobby on the primary node). Impact depends on whether production runs multi-node |
| FRIEND-01 | C | Low | `tachyon_handler.ex:641` `nil -> {:response, state}`. `not_in_friendlist` is never produced |
| FRIEND-02 | P | Low | Code true. Tachyon never defines `invalid_user` ("no such user" vs "malformed") |
| FRIEND-03 | P | Low | Code true (`relationship_lib.ex:189-193`). Tachyon defines nothing, so it is a Gap. The real mismatch is bar-lobby's wording vs teiserver's meaning |
| FRIEND-05 | P | Low | Code true. Tachyon is silent on self-targeting |
| FRIEND-06 | C | Low | A pending request gives `already_in_friendlist`. bar-lobby says "Already friends" |
| FRIEND-09 | R | – | cancelRequest has no "no request" reason in Tachyon, so idempotent success is as valid as the model's `invalid_request`. Gap only |
| FRIEND-11 | C | Low | `account.ex:1986` checks capacity before the auto-accept branch |
| FRIEND-12 | C | Medium | Web and Spring paths only broadcast on `account_user_relationships:*`. No `player/` process subscribes |
| FRIEND-13 | P | Low | Code true. Tachyon is silent on ignore/avoid, so `invalid_user` is a choice, not a divergence |
| FRIEND-14 | C | Low | `with ... else` in acceptRequest has no catch-all (`tachyon_handler.ex:592-597`). It crashes the connection (SESSION-21) |
| FRIEND-16 | C | Medium | `me.store.ts:100-103` never deletes from incoming. `:127-131` adds outgoing unconditionally. Removes on any error |
| CLAN-01 | CM | Low | `command_unimplemented` is a sanctioned reason in every clan response |
| CLAN-02 | C | Low | Same drift as SESSION-18 (vendored v0 has `clanId`) |

**Counts (91 scored).** C 49, CM 13, P 24, R 4, U 1.

**Also found by this review:** NEW-01 (High), now PARTY-22 in findings/party.md. A member who joined through
`acceptInvite` is not monitored as `:current_party`. Details are below. The `pending_parties` membership test noted
under MM-26 is now MM-30 in findings/matchmaking.md.

## Notes: High items, PARTIAL, REFUTED, UNVERIFIABLE

### High (confirmed)

- **PARTY-03.** `player/session.ex:855-868`: `do_leave_party(state)` runs first. On success it calls
  `leave_matchmaking` and sends `cancelled{party_user_left}` (`:1931-1937`). Only then does `:870`
  `Party.accept_invite` run. On `{:error, _}`, the reply is `err` with the *already-modified* `state` (`:893-894`).
  bar-lobby `logic/party.ts:61-67` awaits a throwing `tachyonRequest` (`api/tachyon.ts:57`) before `removeParty`, so
  the client keeps showing the party. It is repaired only by the next `user/self`.
- **PARTY-15 / MM-19.** `party/server.ex:437-448` is the only reset of `data.matchmaking` (plus the queue DOWN at
  `:479-480`). Its callers are `queue_server.ex:651` (pending party), `pairing_room.ex:227` (cancel) and `:252`
  (timeout). They are *not* `remove_member` (`queue_server.ex:613-644`, the path for matchmaking/cancel, party leave
  and session DOWN), and *not* `start_battle` success or failure (`pairing_room.ex:121-182`). The guard
  `party/server.ex:352-359` then answers `already_queued`, and `:221-228` answers `party_in_matchmaking`. The test
  `party_matchmaking_test.exs:190` "queue crash reset party matchmaking state" shows that a queue crash is the only
  tested unlock. Workaround for users: disband and recreate the party.
- **PARTY-16.** `party/server.ex:328-349` (kick) does not read `data.matchmaking`. The kicked session's
  `handle_cast({:party, {:removed, ...}})` (`session.ex:1469-1476`) does not call `leave_matchmaking`. The queue's
  `Member.player_ids` still holds the kicked user. Both the kicker's party and the kicked user stay `:searching`
  as one ticket.
- **PARTY-18 / MSG-04.** `session.ex:698-704`:
  `when state.party.current_party == nil, do: {:reply, {:error, "not in party"}}`. That is a 2-tuple, which is an
  invalid `handle_call` return, so the session exits. Any user can trigger it with
  `messaging/send {target: {type: "party"}}` while not in a party. The caller's `GenServer.call` exits too, and the
  connection monitor closes the socket with 1008 (`tachyon_handler.ex:129-136`). Party, lobby and matchmaking
  membership and the message buffer are lost. `:827` (`{:error, :timeout}`) has the same defect, but only on the
  invite-deadlock path.
- **LOBBY-26.** `tachyon_lobby/events/vote_ended.ex:80-81` applies `UpdateBoss{:add}` unconditionally.
  `cancel_kick_vote.ex:23` cancels only `{:kickban, uid, nil}` votes. The vote ran because `bosses` was empty
  (`lobby.ex:981`), so afterwards the ghost is the only boss. Then:
  - `update_properties` refuses everyone (`:756`);
  - `appoint_boss` gives `not_a_boss` (`:978`);
  - `unboss` needs a member target (`:1003-1005`).
  The lobby stays locked until the ghost rejoins.
- **MM-18.** `session.ex:1301-1310` → `join_matchmaking` → `QueueServer.join_queue(..., party_id)`
  (`queue_server.ex:183-191`) → `{:join_queue, _, _, party_id}` (`:327-368`) needs `pending_parties[party_id]`,
  which only `Party.join_queues` creates. So `{:error, :invalid_party}` → `cancelled(server_error)`. The test
  `matchmaking_test.exs:511` covers only solo players.
- **MM-26.** These defects are user-triggerable:
  - Bullet 1: `remove_from_pending_parties` (`queue_server.ex:646-655`) returns a map, while both callers
    (`:388-396`, `:484-487`) match `:not_queued | {:ok, _}`. The result is a CaseClauseError, and every user in the
    queue gets `cancelled(server_error)`.
  - Bullet 3: `QueueServer.party_join_queue` returns `{:no, :invalid_queue}` on `:noproc` (`queue_server.ex:211`).
    The `case` in `party/server.ex:366-372` raises. The party gen_statem dies, and the session's `:gen_statem.call`
    exits with a non-`:noproc` reason (`party/server.ex:142-143` catches only `:noproc`), so **the session dies
    too**. This needs only a `matchmaking/queue` with an unknown queue id while in a party (the schema accepts any
    string).
  - Bullet 4: the test is `@tag :skip` at `party_matchmaking_test.exs:31-32`.
  - Additional (not in the finding, now MM-30): `party_id in state.pending_parties` (`queue_server.ex:427`) tests
    `{key, value}` membership of a map, so it is always false.
- **AH-10.** This is the path behind AH-01 (autohost loss) and the 8 h timeout. The battle stops with no
  `Battle.end_tachyon_match` (`tachyon_battle/battle.ex:317-325`), so the DB match is never closed and reported
  results are discarded. Each player's session sends `players: [], spectators: [], winning_ally_team_ids: []`
  (`player/session.ex:1664-1674`). That is schema-valid but empty.
- **SESSION-03.** `player/session.ex:1695-1702` stops with `:normal` and has no `terminate/2`. The only `:offline`
  broadcasts are `:601` (system/disconnect) and `:1975` (subscribing to an offline user). Existing subscribers keep
  "menu"/"playing" for good.

### High (partial)

- **AH-01 (P).** The code facts hold:
  - `autohost/session.ex:120-121,266-272`: link plus trap_exit, then stop on EXIT. The moduledoc at `:2-5` says the
    opposite.
  - `tachyon_battle/battle.ex:311-320`: 100 ms, then stop.
  - No kill and no `end_tachyon_match`.

  Two corrections:
  1. Users *do* get a `battle/ended`. It is AH-10's placeholder, sent by their own session's `{:battle, id}`
     monitor.
  2. Tachyon (`docs/schema/autohost.md`) says nothing about autohost disconnects. "Battles survive with a grace
     period" is proposed default PD-10.

  Severity stays High: engines keep running untracked, and no kill is possible (AH-03).
- **AH-04 (P).** Confirmed:
  - `autohost/session.ex:43-52` catches only `:noproc`, so a 5 s timeout exits `Battle.init` (`battle.ex:170`).
  - The late `{:ok, ...}` is put into `active_battles` by `battle_started` (`:382-401`) after the battle's DOWN was
    already processed (`:247-264`), and nothing removes it.
  - `transport.ex:390` `:timer.seconds(10_000)` is about 2.8 h.

  Wrong detail: "`find_autohost` load accounting is off". `autohost.ex:54-61` uses the autohost's own
  `currentBattles`, which counts the zombie. What actually leaks is the `active_battles` entry and its
  never-acked `pending_acks`.
- **SESSION-05 (P).** teiserver drops events while detached (`send_to_player`, `session.ex:1910-1918`) and sends
  only `user/self` on `:replace`: true. But Tachyon (user.md:387) promises no resend, so this is a Gap.
  bar-lobby, friends:
  - after a grace *expiry*, the new session has no subscriptions;
  - `processFriendData` → `subsManager.attach` (`me.store.ts:47-50`) dispatches only for ids not already attached,
    so friends are never re-subscribed;
  - the friend list is cleared only by `clearOnlineState` on go-offline (`:121-123`).

  bar-lobby, party: wrong. `logic/party.ts:171-178` clears `partySymbol` and re-attaches on every `user/self`. There
  is a smaller residual: a party member who is also a friend stays attached through `friendsSymbol`, so no new
  dispatch fires. Lobby members were not checked.

### NEW-01 (found by this review, now PARTY-22): members who joined via acceptInvite are not monitored as `:current_party`

- Evidence: `player/session.ex:782` is the only `MC.monitor(..., :current_party)`, on create. The accept path
  (`:870-882`) sets `current_party` but adds no monitor. The `{:invited_to_party, id}` monitor from `:844` is left
  in place. On a party crash, that DOWN finds no entry in `invited_to` and is a no-op (`:1631-1647`). The test
  "handle party server going down" (`party_test.exs:479-496`) checks only the creator and a pending invitee, not an
  accepted member.
- Effect 1 (party crash): the accepted member gets no `party/removed`, and the session keeps a dead
  `current_party`. Then:
  - `party/leave` gives `invalid_request "Invalid party"`;
  - `party/create` gives `already_in_party`;
  - `party/acceptInvite` raises at `:867`, which crashes the session;
  - a party `matchmaking/queue` returns reason `invalid_party`, which is not in the schema enum
    (`tachyon_handler.ex:394-395`).

  It is fixed only by a reconnect (`:replace` recomputes via `get_party_states`).
- Effect 2 (combined with PARTY-13): B is kicked from P1 (stale `:current_party` monitor on P1), then accepts into
  P2. When P1 ends, B's session sends `party/removed {partyId: P2}` and clears `current_party`, while P2 still lists
  B as a member. The result is a ghost member that the others see, while B sees no party.
- Severity: High. Fix: monitor `:current_party` on accept, and demonitor it in the `{:removed}` handler.

### PARTIAL (not High)

- **PARTY-07.** The target's session answers `{:party, {:invite, ...}}` regardless of `conn_pid` (`session.ex:834-853`).
  "Connected player" (party.md:18) is undefined, so this is an ambiguity, not a clear divergence.
- **LOBBY-03 / MM-17.** No Tachyon text says "a user is in at most one of lobby, queue, battle". The only hook is
  `already_in_battle` in `src/schema/matchmaking/queue.ts:38`, so the MM-17 battle half is a real divergence. The
  lobby halves and the "lobby battles contradict it" point compare against proposed default PD-03.
- **LOBBY-06.** lobby.md:110: "some commands **may** be disabled for non-boss players". `voteActions` includes
  `start`, but no text gates startBattle on a vote. This is a Gap.
- **LOBBY-23.** `lobbyOverview.playerCount` has no description. The disagreement is bar-lobby vs teiserver's
  overview, which LOBBY-17 already covers.
- **LOBBY-25.** The lobby lifetime across a disconnect is undefined in Tachyon. "Full state after user/self" is
  proposed default PD-08. Code facts are right (`tachyon_handler.ex:1121` only `currentLobby`).
- **MM-10.** `pairing_room.ex:188-190` → `no_match` on a repeated ready: true. Tachyon has no rule.
- **MM-16.** `queue.ts:7` "Should cancel the previous queue" and `:36` `already_queued` cannot both hold (MM-01).
  teiserver's choice is one consistent reading, and the test pins it (`matchmaking_test.exs:189-194`).
- **AH-02.** True, and intentional per `autohost_test.exs:65`. autohost.md:2176 constrains only the autohost
  (`> since`). Clock skew is a valid point, but it matters only if battles outlive the connection (AH-01).
- **AH-03, AH-06, AH-08.** Code is right in each. Tachyon is silent on:
  - unknown battle ids in updates;
  - admission between status events;
  - how `finished` reports combine (`battle.ex:382` `count/2`, strict `>`, so 1 report out of N decides).

  These are protocol Gaps. AH-08 deserves owner attention.
- **AH-11.** `battle/start` failure reasons are only the generic four. bar-lobby's `internal_error` is the only
  choice it has.
- **SESSION-09.** teiserver has no response: true. bar-lobby awaiting it (`tachyon-client.ts:358-371`) is correct
  protocol behaviour, so it is not a bar-lobby divergence.
- **SESSION-11.** The duplicate-id bug is real: `Account.query_users` dedupes, while `Enum.count(user_ids)` does not.
  The result is `invalid_request "invalid user ids: "`. Unknown-id → `invalid_request` is the only fitting reason,
  so that half is no divergence.
- **SESSION-19.** The `LoginQueue` `invalid_request "waiting for login"` is true (`tachyon_handler.ex:318-326`).
  Tachyon is silent.
- **MSG-01.** The schema forces `invalid_request` for more than 512 characters (JSV validates before the handler),
  and bar-lobby validates locally. Fix the schema, not the implementations.
- **FRIEND-02, FRIEND-03, FRIEND-05, FRIEND-13.** The code is as described. In each case Tachyon defines nothing
  (meaning of `invalid_user`, what the capacities count, self-targeting, blocks). FRIEND-03's concrete defect is
  bar-lobby's text "Too many outgoing friend requests" for teiserver's "friends + in + out ≥ 300".

### REFUTED

- **LOBBY-10.** "256 members" (proposed default PD-04) is not in Tachyon (no 256/251 in `docs/schema/lobby.md` or
  `src/schema/lobby`). teiserver's 251 (`lobby.ex:440-451`, bots counted) is a documented engine constraint. The
  question is only whether to adopt PD-04.
- **MM-25.** The claim "in `{:pairing, ...}` it does nothing, so the room waits for the full timeout" overlooks this
  chain:
  1. `handle_call(:disconnect)` returns `{:stop, :normal, :ok, ...}` (`session.ex:604`).
  2. The queue monitors every player's session pid as `{:player, id}` from `add_member_to_queue`
     (`queue_server.ex:694-704`), and keeps the monitor through pairing: it is removed only by `disband_pairing`
     (`:404-416`).
  3. The DOWN reaches `remove_player` → `remove_member` → the pairing branch → `PairingRoom.cancel` (`:639-642`).

  The room is cancelled immediately, the same as the session-timeout case the entry itself describes.
- **SESSION-22.** user.md:387 says user/self "should be sent ... when they login". It sets a minimum and does not
  forbid other sends. Sending it on a role change is not a divergence (the Gap stands).
- **FRIEND-09.** `cancelRequest` has no "not found" reason in Tachyon (`invalid_user` plus the generic ones).
  teiserver's idempotent success is as valid as the model's `invalid_request`. Only the Gap stands, as a question
  for the owners.

### UNVERIFIABLE

- **MSG-15.** `Player.SessionRegistry` is a local `Registry` (`player/session_registry.ex:8-18`). Lobby calls run on
  the primary node via `:erpc` (`cluster.ex:24-31`). Whether any recipient is lost depends on production running
  more than one node. To settle it: a 2-node cluster test where a lobby member's session lives on the non-primary
  node, then `messaging/send {type: lobby}` and assert that the member receives the message.

## Gap / Contradiction spot-checks (13 entries, all upheld)

| ID | Check | Result |
|---|---|---|
| MM-01 | `src/schema/matchmaking/queue.ts:7` vs `:36` | Contradictory, as stated |
| MM-08 | `ready.ts:7` "queue should be cancelled" vs `docs/schema/matchmaking.md` step 7 "queueing phase should resume" | Contradictory |
| MM-12 | README lists 4 cancelled reasons, `cancelled.ts:17` has `version_changed` | Upheld |
| MM-28 / AH-17 | matchmaking.md steps 8-9 link `autohost/battleStart` and `battle/battleStart`. battle.md:221 calls a request "this response" | Upheld |
| PARTY-01 | create/invite/acceptInvite/declineInvite/kickMember/leave responses have only the generic four reasons | Upheld |
| LOBBY-09 / LOBBY-12 | joinAllyTeam: `not_in_lobby`, `ally_team_full` only. update: no specific reason | Upheld |
| LOBBY-21 | lobby.md:2867 "If this request succeed players will receive a battle/start request" | Upheld |
| MSG-02 | messaging.md:21-23 "subscribe to a given source ... only supported source is `player`". The request has no source | Upheld |
| SESSION-15 | commands.md:9 `messsageId`. :20 and :30 "A object containing data" used for `status` | Upheld |
| AH-18 | `autohost/update` `winningAllyTeams` items `integer`. `battle/ended` `winningAllyTeamIds` items `string` | Upheld |
| FRIEND-15 | friend README "should request friend/list" while `privateUser.ts:42-53` carries `friendIds`, `outgoingFriendRequest`, ... | Upheld |

## Root-cause groups

1. **The party's matchmaking lock and the queue ticket are not kept consistent** (teiserver). Members:
   - PARTY-15 / MM-19: lock never released;
   - PARTY-16: kick leaves the ticket intact;
   - MM-18: a party cannot rejoin after `lost`, because rejoin needs a pending slot;
   - MM-26 bullets 1, 3, 4: pending-party crashes;
   - PARTY-03: a failed accept still cancels matchmaking;
   - PARTY-14 (gap).

   One owner should define who owns the party ticket. The current split across party server, queue server, pairing
   room and session is what produces these.
2. **Session or connection crashes on error paths** (teiserver). Members:
   - PARTY-18 / MSG-04: 2-tuple reply;
   - MSG-05: unmatched `{:error, :invalid_lobby}`;
   - MM-26 bullet 3: party crash propagates to the session;
   - PARTY-22 (NEW-01) effect 1: raise at `session.ex:867`;
   - FRIEND-14: `WithClauseError`;
   - AH-09: CaseClauseError in the ack handler;
   - SESSION-21: the transport does not catch handler exceptions, so none of the above gets an `internal_error`
     response.
3. **Party monitor and timer bookkeeping in the session and the party server** (teiserver). Members:
   - PARTY-22 (NEW-01): no `:current_party` monitor on accept;
   - PARTY-13: no demonitor on kick;
   - PARTY-17: wrong demonitor key;
   - PARTY-05: timer keyed by user, not by invite.
4. **Reconnect, takeover and grace semantics are unspecified** (protocol gap plus both implementations). Members:
   - SESSION-01: silent close;
   - SESSION-03: no offline on expiry;
   - SESSION-05: no resend, and bar-lobby does not re-subscribe friends;
   - MSG-07: messaging subscription survives a takeover;
   - MSG-14: bar-lobby resumes with `latest`;
   - FRIEND-08: events dropped while detached;
   - LOBBY-25, AH-19: state only via user/self.

   One protocol paragraph (what survives a socket loss and a takeover, what is resent, what the client must redo)
   would settle all of them.
5. **The activity slot is proposed default PD-03, not Tachyon.** Members: LOBBY-03, MM-17, MM-04 (gap), LOBBY-10 (size).
   The protocol owners must decide first. Only `already_in_battle` exists today.
6. **Specific reasons collapsed to `invalid_request`, or never produced** (teiserver `tachyon_handler.ex`).
   Members:
   - LOBBY-02, PARTY-06, LOBBY-20, MSG-04 (reason half);
   - FRIEND-01 and MM-21: `not_in_friendlist` and `version_changed` are never sent.

   The fix is mechanical: map the internal atoms that already exist.
7. **The autohost link is not resilient** (teiserver, plus a protocol gap). Members:
   - AH-01: session dies with the socket, battle dropped after 100 ms;
   - AH-02: `since` = now;
   - AH-03: unknown battles dropped and cannot be killed;
   - AH-04: late start becomes a zombie;
   - AH-10: placeholder battle/ended, match not closed;
   - AH-05 / MM-23 / MM-13: no retry.

   The code's own comments call this an MVP ("no real recovery").
8. **teiserver's vendored schema has drifted from Tachyon while both say `v0`.** Members:
   - LOBBY-01: the `areBossesEnabled` default is missing;
   - SESSION-18 / CLAN-02: `clanId` vs `clanBaseData` (`country` vs `countryCode` is a plain bug even against v0);
   - SESSION-13 (report request fields).
9. **The lobby vote and boss lifecycle are incomplete.** Members:
   - LOBBY-26: ghost boss;
   - LOBBY-07: a vote silently replaced;
   - LOBBY-05: no-boss lockout;
   - LOBBY-14: spectator initiator;
   - LOBBY-04: voteCancel missing.
10. **Presence status is wrong.** Members: SESSION-03 (never offline after a drop), SESSION-06 (never "lobby",
    user/self always "menu"), SESSION-16 (a subscribe broadcasts "menu" to all).

## Top 10 for the protocol owners / teiserver maintainers

1. **[teiserver] Party matchmaking lock and ticket (group 1).** PARTY-15/MM-19, PARTY-16 and MM-18 leave parties
   unable to queue or invite, keep kicked users in the party's ticket, and turn every opponent decline into
   `server_error` for parties. All High.
2. **[teiserver] User-triggerable crashes.** MSG-04/PARTY-18 (`messaging/send` party while not in a party kills the
   session). MM-26 (an unknown queue id while in a party kills the party and the session; a member leaving during
   the 5 s pending window crashes the whole queue). Add a `rescue` around `handle_command` (SESSION-21).
3. **[teiserver] PARTY-22 (NEW-01) + PARTY-13: party membership monitors.** Accepted members are not told when their party
   dies, then get stuck (cannot leave or create; accepting crashes). A kicked user's stale monitor can later remove
   them from a *different* party on the client only.
4. **[teiserver] PARTY-03.** A failed `acceptInvite` still removes the user from the current party and cancels
   their matchmaking. bar-lobby keeps showing the old party.
5. **[teiserver] SESSION-03 (+ SESSION-06, SESSION-16).** Grace expiry never broadcasts `offline`, so friends
   appear online forever. The status is never "lobby", and subscribing pushes "menu" to every subscriber.
6. **[teiserver] LOBBY-26 (+ LOBBY-07, LOBBY-05).** A passed appointBoss vote for a departed user locks the lobby.
   A second vote silently replaces the first. Bosses-enabled lobbies with no boss cannot be updated.
7. **[teiserver] Autohost and battle loss (AH-01, AH-04, AH-10).** Engines that keep running untracked after an
   autohost reconnect or a late start reply. Matches that are never closed in the DB. A placeholder `battle/ended`
   with empty rosters.
8. **[protocol] Reconnect and takeover semantics (group 4).** Specify what survives a socket loss and a takeover
   (subscriptions, the messaging subscription, lobby/party/queue membership), what is resent after `user/self`,
   the grace period, and the close code for a replaced connection. Today SESSION-05/MSG-07/MSG-14 and bar-lobby's
   friend re-subscription depend on unwritten behaviour.
9. **[protocol] Decide the activity slot and the queue contradiction.** Decide whether lobby, queue and battle are
   mutually exclusive (LOBBY-03, MM-17, MM-04). Settle MM-01 (`queue` "should cancel the previous queue" vs
   `already_queued`) and MM-08 (ready timeout cancels vs resumes). These are the largest protocol ambiguities the
   models had to guess.
10. **[both] Reasons that exist but are never produced, or are missing.** teiserver should map the internal atoms
    (LOBBY-02, PARTY-06, FRIEND-01, MM-21 `version_changed`, MM-20 checkAssets/`party_missing_asset`). The protocol
    should add the missing ones (PARTY-01 party reasons, LOBBY-09/12/20, MM-07 party too large) and fix the
    `message_too_long` vs `maxLength` contradiction (MSG-01).
