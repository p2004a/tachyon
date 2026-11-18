# Matchmaking findings

## Scope

`matchmaking.qnt` models the user->server requests `matchmaking/list`, `queue`, `cancel` and `ready`. It models the
events `queuesJoined`, `queueUpdate`, `found`, `foundUpdate`, `lost` and `cancelled` (all five reasons). It models the
server->user request `checkAssets`, sent to the other party members on a party queue, and `battle/start` as a
server->user request at battle start. Server-side environment steps: the matcher (`env/match` picks any set of searching
tickets that fills the teams of one queue), the ready-check timeout, battle started / start failed (retry, a no-op) /
start given up, `queueUpdate`, a queue's asset list changing (`env/versionChanged`), and a client finishing a download.
Steps owned by other groups are abstract: party join/create, party leave/kick, session end, lobby enter/exit, battle end.
The state is the searching tickets, the found matches (`ReadyCheck` or `Starting`), the queue versions, and the abstract
views `parties`, `inLobby`, `inBattle` and `missing` (assets a client lacks).

Abstracted away: rating and other match criteria (the matcher is nondeterministic), durations (`timeoutMs`, the 10 s,
the checkAssets timeout), the autohost (`autohost/start` and its retries are one `Starting` phase), the reply data of
`list` (computed by `listData`, not stored), detached sockets (a detached user just never sends `ready`), and the
generic reasons `internal_error`, `unauthorized` and `command_unimplemented`. The checkAssets round trip is collapsed
into the `queue` step (MM-06).

Constants (`matchmaking_test`): users a, b, c, d. Queues `1v1` (teamSize 1, 2 teams) and `2v2` (teamSize 2, 2 teams).
`MAX_VERSION = 1` (each queue's asset list can change once). `MAX_PARTY = 2`.

The `Outcome` has two fields beyond the README shape. `requests` holds the server->user requests (checkAssets,
battle/start). A `party_missing_asset` denial sends checkAssets but has no events, so convention 3 still holds. `why`
is the sub-case label used by the witnesses `hit(cmd, why)`, as in party.qnt.

Check result: `./check.sh matchmaking.qnt` reports 38 ok and 0 FAIL in two consecutive runs: typecheck, 8 transcripts,
`safety` at 20000 × 30 (about 13 s) and 35 witnesses. Eight rare witnesses (battle and ready-check paths) run at
40000 × 40; one of them failed once at the default 10000 × 25. The whole run takes about 3 min. The step lists the
core branches (queue, ready, match) several times, which weights only the random exploration. `quint verify --max-steps=2` → no violation (about 190 s,
`JVM_ARGS=-Xmx6G`).

## Findings

### MM-01: `queue` "should cancel the previous queue" contradicts the `already_queued` reason
- Kind: Contradiction
- Evidence: `src/schema/matchmaking/queue.ts:7`: "Queue up for matchmaking. Should cancel the previous queue if already
  in one." The same schema lists `{ status: "failed", reason: "already_queued" }` (`queue.ts:37`). Nothing says when
  `already_queued` applies. If a new request always replaces the old one, the reason can never occur. user/self also
  has a third state, `found` (`definitions/privateUser.ts:20-33`), which the description does not cover.
- Spec choice: the design default. A request from a searching user (or any member of a searching party) replaces the
  ticket (`queue`, why `replaced`). `already_queued` applies only once a match is found for any member of the queueing
  unit, in either the `ReadyCheck` or the `Starting` phase. ASSUMPTION MM-01.
- To verify: change the description to "Replaces the previous queue request while searching. Fails with
  `already_queued` once a match has been found (until it is lost or cancelled)."

### MM-02: Replacing a ticket sends no `cancelled`; party mates get `queuesJoined` with the new queue set
- Kind: Assumption
- Evidence: the protocol does not say whether the replaced search produces `cancelled`. `cancelled` means "booted out the
  matchmaking system" (`cancelled.ts:8`), which a replacement is not.
- Spec choice: no `cancelled`. The other party members get `queuesJoined(new queues)` (`queue`).
- To verify: protocol owners.

### MM-03: Order of the `queue` guards is unspecified
- Kind: Assumption
- Evidence: the schema lists nine reasons with no precedence.
- Spec choice: `already_in_battle` → (lobby) `invalid_request` → `invalid_queue_specified` → `version_mismatch` →
  `already_queued` → (party too big) `invalid_request` → checkAssets → `party_missing_asset`. checkAssets is sent only
  if every cheaper check passed.
- To verify: protocol owners. teiserver checks `already_queued` first (`session.ex:611-639`), then validates the queue
  per queue inside `join_all_queues`.

### MM-04: Queueing while in a lobby, or while a party member is in a lobby or battle
- Kind: Gap + Assumption
- Evidence: Tachyon does not say. The design doc says "A user is in at most one of: lobby, matchmaking queue, battle.
  Queueing while in a lobby is not allowed (reply invalid_request)."
- Spec choice: if any member of the queueing unit (the party, or the caller alone) is in a battle →
  `already_in_battle`. If any member is in a lobby → `invalid_request`. `activityExclusive` is an invariant. The lobby
  module must refuse `lobby/join` / `lobby/create` while the user is in matchmaking (interface C1). The model's
  `lobbyEnter` has this guard.
- To verify: protocol owners. Should a new reason, e.g. `in_lobby`, be added to the schema?

### MM-05: A party queues as one ticket, and any member may queue it
- Kind: Assumption (consistent with party.md)
- Evidence: README: "When a player is in a party and a member of the party sends a matchmaking/queue request ... all
  other members of the party will receive a matchmaking/checkAssets request ... the initiating client will _not_
  receive the matchmaking/queuesJoined event". party.md:34: "this spec doesn't have any concept of leader, any party
  member can do all actions. Maybe in the future ... only leader can join games/matchmaking".
- Spec choice: a ticket is always a whole party or a party-less user (`ticketsArePartyUnits`). Any member may queue.
  Any member may cancel or decline, which withdraws the whole ticket: `intentional` to the caller and `party_user_left`
  to the mates. teiserver: any member (`session.ex:624-631`, party test `party_matchmaking_test.exs:15`). bar-lobby: the
  party view shows the queue button to every member (`views/profile/party.vue:105`).
- To verify: —

### MM-06: checkAssets is modelled synchronously; the initiator's own assets are not checked
- Kind: Assumption
- Evidence: README: "If any client's `assetStatus` response is `missing`, `downloading`, or if it times out without
  sending a response, the matchmaking `queue` request will fail." README step 2: "Before joining the queue, the client
  needs to download all required assets." `checkAssets.ts:8`: "a 'success' response does _not_ mean that the assets are
  ready."
- Spec choice: `queue` sends `CheckAssets(q)` to every other member for every requested queue (`lastRequests`). It fails
  with `party_missing_asset` if any of them lacks an asset (`missing`). A failed checkAssets response or a timeout counts
  as missing. The caller is trusted. The model has no time in which a member can change state between the check and
  the reply.
- To verify: what happens if a party member's state changes (leaves the party, joins a lobby) while the server waits
  for checkAssets responses? Which `details` are given for a timeout?

### MM-07: No reason for a party larger than the queue's team size
- Kind: Gap
- Evidence: none of the nine `queue` reasons fits. teiserver replies `invalid_request` "too many player for a playlist"
  / "party too big" (`tachyon_handler.ex:379-392`, test `party_matchmaking_test.exs:80`). bar-lobby disables the button
  with a tooltip (`views/play/matchmaking.vue:45`, `partyTooLargeTooltip`).
- Spec choice: `invalid_request` (why `party_too_big`).
- To verify: add a reason such as `party_too_large`?

### MM-08: The ready timeout both "cancels the queue" and "resumes the queueing phase"
- Kind: Contradiction
- Evidence: `ready.ts:8`: "If not sent within 10s of the found response then queue should be cancelled." README 7: "If
  a client fails to ready up for a found match, the server should send a lost event, and the queueing phase should
  resume." `cancelled` reason `ready_timeout`: "The player failed to accept a match within the given time window and is
  thus removed from the matchmaking system." `lost.ts:7`: "Sent when a found match gets disbanded because a client
  failed to ready up." Nothing says who gets which event, or what happens to a ticket that readied while a party mate
  did not.
- Spec choice (`readyTimeout`): every member of the match gets `lost`. A ticket with a non-ready member is removed. Its
  non-ready members get `cancelled(ready_timeout)`. Its ready members get `cancelled(party_user_left)`: ASSUMPTION, the
  party withdraws as a unit. Fully ready tickets resume searching in all their original queues. A late or repeated timer
  fire is a no-op. teiserver agrees for solo players (`session.ex:1259-1312`: `lost` to all, `lost`+`cancelled` to the
  non-ready players, rejoin for the readied ones; test `matchmaking_test.exs:610`).
- To verify: protocol owners. State the per-recipient rule in the README. Should the readied mates of a party get
  `party_user_left`, or `ready_timeout`?

### MM-09: Declining (cancel in a ready check) sends `lost` to the others and requeues them
- Kind: Assumption
- Evidence: README 6: "To cancel queueing, or to decline a found match, clients should send a cancel request." What
  the other players get is not stated.
- Spec choice (`withdraw`/`disband`): the decliner's ticket leaves (`intentional` / `party_user_left`). Every other
  ticket gets `lost` and resumes searching. The decliner and its mates get no `lost`. The same applies to a party
  leave/kick and to a session end during a ready check. teiserver: `pairing_room.ex:221-243` (others
  `notify_lost(:cancel)` → requeue, test `matchmaking_test.exs:511` "back in queue if a player decline").
- To verify: —

### MM-10: A repeated `ready` succeeds in the spec; teiserver answers `no_match`
- Kind: Assumption + Divergence-teiserver
- Evidence: the schema only has `no_match`. teiserver `pairing_room.ex:185-190`: a user not in `awaiting` (already
  readied) → `{:error, :no_match}`. It sets `readied?: true` before asking the room (`session.ex:654`).
- Spec choice: `ready` while already ready → `Ok`, no events (why `already_ready`). `no_match` only when the user has no
  found match.
- To verify: protocol owners. bar-lobby's button is disabled after ready (`views/play/matchmaking.vue:93`), so this
  matters only for retried requests and multiple clients.

### MM-11: A found ticket remembers its other queues and resumes them
- Kind: Assumption (supported by user/self)
- Evidence: user/self `matchmaking.state = "found"` has `queue` and `otherQueues` (`definitions/privateUser.ts:20-33`).
  teiserver leaves the other queues while pairing (`session.ex:1222-1226`, `frozen_queues`) and rejoins them all after
  `lost` (`session.ex:1300-1310`).
- Spec choice: `Match.tickets` keep their `queues`. `disband` puts the fresh tickets back unchanged.
- To verify: —

### MM-12: Queue asset changes: `version_changed` is in the enum only; what happens to found matches is unspecified
- Kind: Gap + Contradiction (minor)
- Evidence: the README lists four `cancelled` reasons and omits `version_changed`, which `cancelled.ts:16` has. README:
  cancelled happens "if list of required assets changed". `list.ts:21` says version "uniquely identifies the
  properties of the queue with this id, including list of required assets versions".
- Spec choice (`versionChanged`): bump the version. Every searching ticket that includes q gets
  `cancelled(version_changed)`. Every user lacks q's assets until `env/assetsDownloaded`. Found matches proceed. A
  ticket that later resumes after `lost` with a stale queue version gets `lost` + `cancelled(version_changed)`
  (witness `staleRequeueCancelled`).
- To verify: add `version_changed` to the README list. Say whether a found match survives an asset change.

### MM-13: The autohost start is retried forever; nothing says when the server gives up
- Kind: Gap + Assumption
- Evidence: README 8: "If the autohost doesn't respond quickly, or if it sends a failed response, the server should
  repeat this step." The design says retry on another autohost.
- Spec choice: `startFailed` is a no-op (the match stays `Starting`). `startGaveUp` (ASSUMPTION) removes the match and
  sends `lost` + `cancelled(server_error)` to all its members. `cancel` stays possible in `Starting` and acts as a
  decline. The autohost-side cleanup is out of scope.
- To verify: protocol owners. Is there a retry limit, and what may clients do while waiting?

### MM-14: `queueUpdate.playersQueued` and its recipients are unspecified
- Kind: Gap
- Evidence: `queueUpdate.ts:7`: "Contains some info about the state of the current queue." The data is one integer, but
  a user may be in several queues.
- Spec choice: per queue q, it goes to every searching user in q, with the number of searching users in q.
- To verify: protocol owners. Which queue does it refer to? Does it count users or tickets?

### MM-15: Reason sent to the member who leaves a queued party
- Kind: Assumption (consistent with party.md PARTY-14)
- Evidence: `party_user_left`: "a member of the player's party left matchmaking". The leaver did not send `cancel`.
- Spec choice: every old member gets `cancelled(party_user_left)`, the leaver too (`partyLeave`). This is the same as
  teiserver (`session.ex:1932-1937`, test `party_matchmaking_test.exs:106`) and party.qnt.
- To verify: —

### MM-16: teiserver answers `already_queued` to any queue request while searching
- Kind: Divergence-teiserver
- Evidence: `session.ex:633-637`: `{:searching, _} -> {:reply, {:error, :already_queued}, state}` and the same for
  `{:pairing, _}`. Test `matchmaking_test.exs:189-194` asserts it. The schema says "Should cancel the previous queue",
  and the design says replace while searching (MM-01).
- Spec choice: replace (`queue`, why `replaced`).
- bar-lobby: never re-queues while searching (the button exists only in `Idle`, `views/play/matchmaking.vue:67,83`).
  But on any `queue` failure other than `version_mismatch` it sets `status: Idle` (`logic/matchmaking.ts:166-167`). If
  the server still has the user queued (`already_queued`, e.g. after a reconnect that missed `user/self`), the UI shows
  Idle while the server keeps the user queued.
- To verify: teiserver test: queue 1v1, then queue 2v2 → expect success and user/self queues = [2v2].

### MM-17: teiserver does not enforce the activity slot; `already_in_battle` is never returned
- Kind: Divergence-teiserver
- Evidence: `session.ex:611-639` (`join_queues`) checks only `state.matchmaking` and the party, not `state.lobby` or
  `state.battle`. `grep already_in_battle lib/` finds nothing. `lobby/join` / `lobby/create` (`session.ex:952-1021`)
  do not check `state.matchmaking`. So a user can be queued and in a lobby at once, and can queue while in a battle.
  When a match then starts, `handle_cast({:battle, {:start,...}})` (`session.ex:1342-1364`) prefers the matchmaking
  branch and keeps the lobby.
- Spec choice: MM-04 guards; `activityExclusive`.
- To verify: teiserver test: join a lobby, then `matchmaking/queue` → expect `invalid_request`. Start a battle, then
  queue → expect `already_in_battle`.

### MM-18: A party cannot resume searching after `lost`: it gets `cancelled(server_error)` instead
- Kind: Divergence-teiserver (from reading code; no test covers it)
- Evidence: after `lost` (decline by an opponent, or a ready timeout with this party fully ready), each member's session
  calls `join_matchmaking(q_refs, state)` (`session.ex:1300-1310`). That calls `QueueServer.join_queue(..., party_id)`
  with the party id set. The queue expects a `pending_parties` slot created by `Party.join_queues`. There is none, so
  it replies `{:error, :invalid_party}` (`queue_server.ex:327-368`), and the session sends `cancelled(server_error)`
  (`session.ex:1307-1310`). In addition, `pairing_room.ex:227,252` calls `Party.matchmaking_notify_cancel` for every
  party in the room, including the parties that are supposed to resume.
- Spec choice: `disband` requeues every non-withdrawn ticket, party tickets included (`partyDeclineTest`,
  `requeuedAfterLost`).
- To verify: teiserver test: party (m1,m2) + c + d in a 2v2 match. c declines → expect m1 and m2 back in the queue
  (user/self `queuing`), not `cancelled`.

### MM-19: The party is never unlocked after a cancel or after a successful match
- Kind: Divergence-teiserver (same as party.md PARTY-15, seen from matchmaking)
- Evidence: party.md PARTY-15. In addition, `pairing_room.ex:121-182` (`start_match`, both success and failure) never
  calls `Party.matchmaking_notify_cancel`. So after a party plays a matchmaking game, its next `matchmaking/queue`
  fails `already_queued` (`party/server.ex:352-359` → `tachyon_handler.ex:394-395`), and `party/invite` fails, until
  the queue process restarts.
- Spec choice: there is no separate lock. The lock is "the party has a ticket" (searching or found). It ends when the
  ticket leaves (cancel, decline, timeout, battle start).
- To verify: teiserver test: a party queues, is matched and starts a battle. After `battle/ended`, the party queues
  again → expect success.

### MM-20: teiserver never sends `checkAssets` and never returns `party_missing_asset`
- Kind: Divergence-teiserver
- Evidence: `grep -rn "checkAssets\|check_assets\|party_missing_asset" lib/` finds nothing. Party queueing
  (`party/server.ex:361-405`) asks no member about assets. bar-lobby implements the handler
  (`src/main/tachyon/tachyon.handlers.ts:78-100`: returns `missing`/`complete` and alerts "Party queue rejected, missing
  assets ..."). It also handles `party_missing_asset` (`useMatchmakingActions.ts:44-45`). Neither is ever used. A party
  member without the assets is queued, and fails later at battle start (bar-lobby `tachyon.handlers.ts` battle/start
  handler: "Unable to join match, required assets are missing" → `internal_error`).
- Spec choice: README behaviour (`queue`, MM-06).
- To verify: teiserver test: a party where m2 lacks the map; m1 queues → expect m2 to receive `matchmaking/checkAssets`
  and m1 to get `party_missing_asset`.

### MM-21: Asset change: teiserver sends `server_error`, not `version_changed`, so bar-lobby does not refresh
- Kind: Divergence-teiserver (and an interaction with bar-lobby)
- Evidence: `queue_server.ex:450-465`: a new asset version stops the queue (`{:shutdown, :asset_changed}`). The sessions'
  queue monitor fires and sends `cancelled(server_error)` (`session.ex:1576-1596`). Tests
  `matchmaking_test.exs:318-343` check only for `matchmaking/cancelled`. bar-lobby re-lists queues only on
  `version_changed` (`logic/matchmaking.ts:236-238`), so it keeps the stale version and its next queue request fails
  with `version_mismatch` (bar-lobby then refreshes, `:164-165`).
- Spec choice: `cancelled(version_changed)` (`versionChanged`).
- To verify: change teiserver to map `:asset_changed` to `version_changed`.

### MM-22: teiserver never sends `matchmaking/queueUpdate`
- Kind: Divergence-teiserver (the README says "can", so it is allowed; recorded because bar-lobby relies on it)
- Evidence: `broadcast_update` (`queue_server.ex:743-748`) only goes to the admin PubSub (`matchmaking.ex:117-125`).
  `grep queueUpdate lib/` finds nothing. bar-lobby shows `playersQueued` from it (`logic/matchmaking.ts:212-216`), which
  stays 0.
- Spec choice: `queueUpdate` env step (MM-14).
- To verify: —

### MM-23: teiserver gives up on the first autohost failure; Tachyon says to retry
- Kind: Divergence-teiserver
- Evidence: `pairing_room.ex:121-150`: no autohost, or `start_battle` error → `disband_pairing` and
  `notify_lost({:server_error, reason})` to everyone → the sessions send `lost` + `cancelled(server_error)` and leave
  all queues (`session.ex:1290-1296`). README 8 says "the server should repeat this step", and the design says retry on
  another autohost. teiserver also sends a `details` field with `server_error` (`tachyon_handler.ex:163`) that the
  `cancelled` schema does not define.
- Spec choice: `startFailed` = retry (no-op); `startGaveUp` is the teiserver behaviour, allowed as an eventual step
  (MM-13).
- To verify: —

### MM-24: Ready-check duration: the schema says 10 s, teiserver uses 20 s
- Kind: Contradiction (minor) + Divergence-teiserver
- Evidence: `ready.ts:8` "within 10s". `found.timeoutMs` carries the real value. teiserver `pairing_timeout: 20_000`
  (`queue_server.ex:111`). bar-lobby uses `timeoutMs` (`logic/matchmaking.ts:246`), so it is unaffected.
- Spec choice: durations are not modelled.
- To verify: replace "10s" with "within `timeoutMs` of found".

### MM-25: `system/disconnect` in a ready check leaves the user in the match until the timeout
- Kind: Divergence-teiserver (minor)
- Evidence: `session.ex:588-604` leaves the queues only in `{:searching, ...}`. In `{:pairing, ...}` it does nothing,
  so the room waits for the full timeout and then everyone gets `lost`. A session that times out
  (`queue_server.ex:481-485` `DOWN {:player}`) does cancel the room at once.
- Spec choice: `sessionEnded` withdraws at once: the others get `lost` and resume.
- To verify: —

### MM-26: Smaller teiserver defects found while reading the matchmaking path
- Kind: Divergence-teiserver (from reading code)
- Evidence:
  - `remove_from_pending_parties` (`queue_server.ex:646-655`) returns a bare state map, but `remove_player` callers
    match `:not_queued | {:ok, state}` (`:388-396`, `:481-485`). A member who leaves during the 5 s pending-party window
    therefore crashes the queue (CaseClauseError), and everyone in that queue gets `cancelled(server_error)`.
  - The same function sends `notify_lost(:cancel)` to the other pending members. Their sessions are in `:searching`,
    so they forward `{:matchmaking, {:notify_lost, reason}}` (`session.ex:1264-1266`). The handler only matches
    `{:matchmaking, :notify_lost}` (`tachyon_handler.ex:155`), so the message is logged and dropped (`:305-308`). The
    client gets nothing, and the session stays `:searching` for a queue it is no longer in.
  - `party_join_queue` returns `{:no, :invalid_queue}` for an unknown queue (`queue_server.ex:211`). `party/server.ex:366-372`
    matches only `{:ok, _}` / `{:error, _}`, so a party queue with an unknown id crashes the party process instead of
    replying `invalid_queue_specified`.
  - `party_join_queue` skips `member_can_join_queue?` (missing maps/engines). The members' later individual joins fail,
    and `session.ex:1515-1517` then raises "todo: cancel the matchmaking in the party". The test
    `party_matchmaking_test.exs:31-33` is `@tag :skip` ("TODO: make this test pass").
- Spec choice: n/a (these are implementation crashes; the spec has the intended outcomes).
- To verify: the listed scenarios as teiserver tests.

### MM-27: bar-lobby treats `lost` as "back to searching" even for players who get `cancelled` next
- Kind: Divergence-bar-lobby (benign)
- Evidence: `logic/matchmaking.ts:218-223`: `onLostEvent` sets `Searching`. A non-ready player receives `lost` then
  `cancelled(ready_timeout)` (teiserver `session.ex:1288-1291`), so the UI briefly shows Searching and then Idle. The
  local countdown (`:58-61`) also sets Idle at the deadline, before the server's `lost`, which then sets Searching
  again. In the spec, `lost` and `cancelled` arrive in one step. The client is right only if `cancelled` comes after
  `lost`.
- Spec choice: the events are a set, so their order is not modelled.
- To verify: the README should say that `lost` comes before `cancelled` when both are sent.

### MM-28: README step 8/9 names commands that do not exist
- Kind: Contradiction
- Evidence: README 8 "[autohost/battleStart](#autohost/battleStart)" and 9 "[battle/battleStart](#battle/battleStart)".
  The schema has `autohost/start` and `battle/start`.
- Spec choice: `battleStarted` sends `BattleStart` (= `battle/start`) to the members.
- To verify: fix the links.

### MM-29: Implementation check per command (beyond the entries above)
- Kind: Divergence check
- list: teiserver `tachyon_handler.ex:340-361` returns every queue with `version`. bar-lobby stores `playlists`, picks a
  default and checks downloads (`logic/matchmaking.ts:67-88`). Matches.
- queue: success replies, `queuesJoined` to the other members only (`session.ex:1499-1513`; the initiator's cast is
  ignored because it is already `:searching`, `:1520-1524`) match the README. bar-lobby takes `queues[0]` only
  (`logic/matchmaking.ts:288-297`, "single queue joined at a time"); its own requests always carry one queue (`:155-157`).
  Divergences: MM-16, MM-17, MM-20, MM-07.
- cancel: `not_queued` when idle (`session.ex:1877-1880`). On success, the handler returns the reply and then
  `cancelled{intentional}` (`tachyon_handler.ex:400-409`), as the README says. Party mates get `party_user_left`
  (`queue_server.ex:631-633`). bar-lobby sets Idle before the reply (`logic/matchmaking.ts:177-189`). Matches, apart
  from MM-19.
- ready: `no_match` outside pairing matches. `foundUpdate(readyCount)` goes to all room members
  (`pairing_room.ex:192-198`). Divergence MM-10. bar-lobby sets `MatchAccepted` (`logic/matchmaking.ts:194-206`).
- found: sent to every paired player with `queueId` and `timeoutMs` (`pairing_room.ex:109-116`). A session that is not
  searching (a race between two queues) declines the room (`session.ex:1246-1257`), which is the same as a cancel.
  bar-lobby ignores `queueId` (`logic/matchmaking.ts:241-247`).
- lost / cancelled: see MM-08, MM-09, MM-18, MM-21, MM-23 and MM-27. The cancelled reasons teiserver emits
  (`intentional`, `ready_timeout`, `server_error`, `party_user_left`) are in the enum. `version_changed` is never
  emitted.
- checkAssets / queueUpdate: never sent by teiserver (MM-20, MM-22). bar-lobby handles both.

## Coverage

| Command / step | Outcome | Status |
|---|---|---|
| matchmaking/list | Ok | witnessed (`hit(list,listed)`), duelTest |
| matchmaking/queue | Ok solo | witnessed `queued`, duelTest |
| | Ok replacing a searching ticket | witnessed `replaced`, replaceAndDenialsTest |
| | Ok party (checkAssets + queuesJoined) | witnessed `party_queued`, partyDeclineTest |
| | already_in_battle | witnessed, duelTest |
| | invalid_request (in lobby) | witnessed `in_lobby`, replaceAndDenialsTest |
| | invalid_request (party too big) | witnessed `party_too_big`, partyDeclineTest |
| | invalid_request (empty list) | unreachable: schema `minItems: 1`; the step never generates it |
| | invalid_queue_specified | witnessed, replaceAndDenialsTest |
| | version_mismatch | witnessed, replaceAndDenialsTest, versionTest |
| | already_queued | witnessed, duelTest |
| | party_missing_asset | witnessed, versionTest |
| | internal_error / unauthorized / command_unimplemented | not modelled (generic) |
| matchmaking/cancel | Ok while searching | witnessed `left_queue` |
| | Ok in a ready check (decline) | witnessed `declined`, partyDeclineTest |
| | not_queued | witnessed |
| matchmaking/ready | Ok (count < all) | witnessed `readied` |
| | Ok (all ready → Starting) | witnessed `all_ready`, duelTest |
| | Ok repeated (no-op) | witnessed `already_ready`, duelTest |
| | no_match | witnessed |
| matchmaking/checkAssets | sent to party mates | duelTest/partyDeclineTest/versionTest (`lastRequests`); a failure reply = `missing` (MM-06) |
| queuesJoined | to party mates only | `party_queued`, `queuesJoinedToMates` |
| queueUpdate | sent | witnessed `env/queueUpdate`, startGaveUpTest |
| found | to the new match's members | witnessed `env/match found`, `found2v2WithParty`, `foundExact` |
| foundUpdate | to the match's members | `readied`, `foundUpdateExact` |
| lost | timeout / decline / give-up | witnessed `env/readyTimeout lost`, `requeuedAfterLost`, `lostOnlyToDisbanded` |
| cancelled | intentional / server_error / party_user_left / ready_timeout / version_changed | all five witnessed (`cancelledWith`) |
| env/battleStarted | battle/start to members | witnessed `started`, duelTest |
| env/startFailed | retry, no-op | duelTest |
| env/startGaveUp | lost + server_error | witnessed `gave_up`, startGaveUpTest |
| env/versionChanged | bump + cancel searching | witnessed `bumped`; stale resume `staleRequeueCancelled` |
| env/partyJoin | solo ticket cancelled | witnessed `solo_cancelled`, partyLeaveTest |
| env/partyLeave | party ticket cancelled | witnessed `party_unqueued`, partyLeaveTest |
| env/sessionEnded | withdraw, others lost | witnessed `withdrawn`, sessionEndedTest |

## Seeded mutations

Each was run on a copy (`quint test` plus `safety` at 20000 × 30, then the single conjuncts) and then reverted.

| # | Mutation (one line) | Caught by |
|---|---|---|
| M1 | `queue` keeps the replaced ticket (`s.searching.union(...)`) | replaceAndDenialsTest; `atMostOneTicket`, `matchedOutOfQueue`, `foundExact`, `lostOnlyToDisbanded`, `cancelledMeansOut` |
| M2 | `matchFound` leaves the matched tickets searching | duelTest, partyDeclineTest, readyTimeoutTest; `matchedOutOfQueue`, `atMostOneTicket`, `ticketsArePartyUnits`, `activityExclusive`, ... |
| M3 | `ready` sends foundUpdate to the caller only | duelTest; `foundUpdateExact` |
| M4 | `disband` sends no `lost` to the resumed tickets | partyDeclineTest, readyTimeoutTest, sessionEndedTest; `disbandNotifiesAll` |
| M5 | `partyLeave` does not withdraw the party ticket (`val w = (s, Set())`) | partyLeaveTest; `ticketsArePartyUnits` |
| M6 | `cancel` denial reason `no_match` instead of `not_queued` | replaceAndDenialsTest; `reasonsInSchema` |
| M7 | `partyJoin` without the "party is searching" lock | **not caught**. The mutant is equivalent at `MAX_PARTY = 2`: a searching party already has 2 members, so the size guard refuses the join. Covering it needs an instance with `MAX_PARTY = 3`. |

## Cross-module interface

Predicates this module assumes or provides (`inMM(u)` = u is in a searching ticket or a found match):

- C1 activity slot (lobby, battle): `inMM(u) ⇒ u ∉ lobbyMembers ∧ u ∉ battlePlayers` (`activityExclusive`). The lobby
  module must refuse `lobby/create` / `lobby/join` while `inMM(u)` (reason: `invalid_request`, no specific one exists).
  Matchmaking refuses `queue` while any member of the unit is in a lobby (`invalid_request`) or battle
  (`already_in_battle`).
- C2 battle: `env/battleStarted(m)` makes `matchMembers(m)` battle players and sends them `battle/start`. Matchmaking
  needs the battle module to report the end (`env/battleEnded`) before those users can queue again.
- C3 party → matchmaking, agreeing with party.md I3 / PARTY-14 / PARTY-16:
  `partyLocked(p) := ∃ ticket t (searching or in a match) with t.members = members(p)`. While `partyLocked(p)`:
  no invite or accept into p. Every ticket of a party member is the party's ticket (`ticketsArePartyUnits`). Any
  membership change (leave, kick, session end) withdraws the ticket and sends `cancelled(party_user_left)` to every old
  member. In a ready check the other tickets get `lost` and resume.
  **Disagreement with party.md I2:** I2 says `queued(p)` is cleared on "match found". This module keeps the party
  locked through the ready check and the `Starting` phase, until battle start or withdrawal. A member joining mid-check
  would leave a ticket that no longer matches its party, and a party that resumes after `lost` must still be locked.
  Proposed I2: `queued(p) ⇔ partyLocked(p)`, cleared on cancel/decline/withdraw, battle start, and on lost only if the
  party does not resume.
- C4 party creation/acceptance (PARTY-20): `partyOf'(u) ≠ partyOf(u) ⇒ ¬soloInMM'(u)`. A solo searching ticket is
  cancelled with `intentional`. This module additionally assumes a user in a found match cannot create or accept a
  party (`partyJoin` guard). teiserver allows it and treats it as a decline (`session.ex:884-890` →
  `leave_matchmaking`).
- C5 session (party.md I1): `Detached` changes nothing here; the user fails the ready check by not sending `ready`.
  `Offline` (grace expiry or `system/disconnect`) = `sessionEnded`: withdraw with no event to u, and leave the party.
  The session stays while the user is in a battle.
- C6 assets: `missing(u, q)` is what u's client would answer to `checkAssets(q)` (`missing`/`downloading`/failure/timeout
  → missing).

## Requests to the orchestrator

- R1: `Outcome` here has `requests: Set[(UserId, ServerRequest)]` (server->user requests: checkAssets, battle/start) and
  `why`. A shared `requests` field in `common.qnt` would let the battle module own `battle/start` and let the lobby
  module reuse it.
- R2: settle C3 against party.md I2 (when the party lock ends). The two modules currently disagree on "match found".
- R3: Apalache: `--max-steps=2` passes in about 190 s with `JVM_ARGS=-Xmx6G`. 3 steps was not attempted (shared
  server, other agents running). `teamsFormable` was rewritten without `setOfMaps`, which Apalache refuses to expand.
