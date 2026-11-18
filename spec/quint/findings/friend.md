# Findings: friend

Module: `spec/quint/friend.qnt` (`module friend`; transcripts in `module friend4`; `module friend3` for Apalache).

## Scope

Commands modelled: `friend/list`, `friend/sendRequest`, `friend/acceptRequest`, `friend/rejectRequest`,
`friend/cancelRequest`, `friend/remove`, and the events `friend/removed`, `friend/requestAccepted`,
`friend/requestCancelled`, `friend/requestReceived`, `friend/requestRejected`. Session steps (same names and
pre-conditions as `session.qnt` / `party.qnt`): `env/connect` (Offline -> Online), `env/disconnect`
(Online -> Detached), `env/reconnect` (Detached -> Online), `env/sessionExpired` (Detached -> Offline). Friend
events reach Online users only; on connect/reconnect the client gets `user/self` (full friend state).
State: a friend adjacency map (so symmetry is a checked property), pending requests as `(from, to)` pairs, and
presence. A reference client (`views`, `clientOnOk`, `clientOnEvent`) keeps its friend list from replies and
events only; `viewsInSync` checks that the protocol gives an Online client enough to stay correct, with the
reply and the event of the same step delivered in either order (`replyFirst` nondet).
Abstracted away: `addedAt`/`sentAt` timestamps, user objects, ignore/avoid relations, scopes (`unauthorized`),
storage errors (`internal_error`), dispatch (`command_unimplemented`), takeover (`env/takeover` of session.qnt
does not change friend state and resets the view like `env/reconnect`).
Constants (`friend4`): users a, b, c, d; `GHOST = "x"` (well-formed id of no user); `MAX_OUTGOING = 2`,
`MAX_INCOMING = 1` (different, so a swap is detectable). `friend3`: a, b, c, both caps 1.

Check results: `./check.sh friend.qnt` 30/30 ok (typecheck, 1 test module with 7 transcripts, `safety` 30
steps x 50000 samples, 27 witnesses at 30 steps x up to 200000 samples), about 2 min. `VERIFY=1`:
`quint verify --main=friend3 --invariant=safety --max-steps=2` passes in 208 s (JVM_ARGS=-Xmx6G, with another
Apalache run in parallel); 3 steps was not attempted within the time budget.

## Findings

### FRIEND-01: friend/remove of a non-friend succeeds in teiserver; the schema has `not_in_friendlist`
- Kind: Divergence-teiserver
- Evidence: schema `friend/remove/response.json` reasons include `"not_in_friendlist"`
  (src/schema/friend/remove.ts:17). teiserver `player/tachyon_handler.ex:634-641`:
  `%Account.Friend{} = friend <- Account.get_friend(...)` ... `else nil -> {:response, state}`; test
  `test/teiserver_web/tachyon/friend_test.exs` "is no-op if not friend" asserts `"status" => "success"`.
  `not_in_friendlist` is never produced anywhere in teiserver.
- Spec choice: `remove` denies with `not_in_friendlist` (witness `hit("friend/remove",Failed("not_in_friendlist"))`).
- To verify: either teiserver returns `not_in_friendlist`, or Tachyon drops the reason and documents remove as
  idempotent.

### FRIEND-02: `invalid_user` only for unparsable ids in accept/reject/cancel/remove (teiserver)
- Kind: Divergence-teiserver
- Evidence: sendRequest uses `get_user/1` (`tachyon_handler.ex:1236-1243`: parse **and** `Account.get_user`),
  but acceptRequest/rejectRequest/cancelRequest/remove only `TachyonParser.parse_user_id`
  (`:588, :602, :621, :635`; `helpers/tachyon_parser.ex:27-31`: `Integer.parse`). A well-formed id of no user
  gives `no_pending_request` (accept/reject), `success` (cancel, `:625-626` `{:error, "no request"} ->
  {:response, state}`), `success` (remove). cancelRequest maps **any** other error to `invalid_user`
  (`:628-629` `_other -> {:error_response, :invalid_user, state}`).
- Spec choice: `invalidTarget` (unknown id or self) -> `invalid_user`, checked first, for every command.
- To verify: does `invalid_user` mean "no such user" (spec) or "malformed id" (teiserver)? State it once in
  friend README.

### FRIEND-03: What the two capacities count is not defined; teiserver counts friends + requests, both ways
- Kind: Gap + Divergence-teiserver (bar-lobby agrees with the spec)
- Evidence: Tachyon only has the reason names `outgoing_capacity_reached`, `incoming_capacity_reached`
  (src/schema/friend/sendRequest.ts:18-19), no description. teiserver
  `account/libs/friend_request_lib.ex:71-75`: `check_relationship_limit(from_id, :friend)` ->
  `:outgoing_capacity_reached`, `check_relationship_limit(to_id, :friend)` -> `:incoming_capacity_reached`;
  `relationship_lib.ex:189-193` counts `existing_friends + outgoing_requests + incoming_requests` against one
  site setting "relationships.Maximum relationships per user" (`libs/teiserver_configs.ex:677-682`, default
  300, "Maximum number of friends, ignores, avoids, or blocks"). Its own user text (`friend_request_lib.ex:25-28`)
  says "You have reached the maximum number of friends". bar-lobby `assets/languages/en.json:2424-2425`:
  "Too many outgoing friend requests" / "User has too many incoming requests" (per-direction pending
  requests). teiserver test "request when outgoing capacity reached" reaches the limit with 2 **friends** and
  0 requests.
- Spec choice: ASSUMPTION — `MAX_OUTGOING` bounds the caller's pending outgoing requests, `MAX_INCOMING` the
  target's pending incoming requests (server settings); outgoing checked first (`sendRequest`,
  invariant `withinCapacity`).
- To verify: protocol owners pick one definition and write it in the sendRequest description; bar-lobby's
  message is wrong for teiserver's definition (a user with 300 friends is told "too many outgoing requests").

### FRIEND-04: No friend-list cap in the protocol
- Kind: Assumption
- Evidence: acceptRequest's reasons are `invalid_user`, `no_pending_request` only; no "friendlist full".
  teiserver bounds friends indirectly (FRIEND-03: friends+in+out <= 300 is preserved, since accept turns one
  incoming request into one friend).
- Spec choice: friend lists are unbounded; `noFriendCapTest` gives a 3 friends with `MAX_OUTGOING = 2`
  (witness `multipleFriends`).
- To verify: if a cap is intended, add a reason (e.g. `friendlist_full`) to acceptRequest and sendRequest.

### FRIEND-05: Self-targeting
- Kind: Assumption + Divergence-teiserver
- Evidence: Tachyon is silent. teiserver: sendRequest to self -> `invalid_user` (`friend_request_lib.ex:54`;
  test "request to self"); accept/reject from self -> `no_pending_request`, cancel to self -> success, remove
  self -> success (only parse checks, FRIEND-02).
- Spec choice: `invalidTarget` makes self `invalid_user` for all five commands (`invalidUserTest`); invariant
  `noSelfRelations`.
- To verify: protocol owners; one-line teiserver fix (reuse `get_user` + self check).

### FRIEND-06: Repeated request to the same user has no reason; teiserver says `already_in_friendlist`
- Kind: Gap + Divergence-teiserver + Divergence-bar-lobby (message)
- Evidence: sendRequest reasons have nothing for "request already pending". teiserver
  `friend_request_lib.ex:60-63`: "Check for existing outgoing request" -> `{false, :already_in_friendlist}`.
  bar-lobby shows `already_in_friendlist` as "Already friends with this user" (`en.json:2423`,
  `components/navbar/Friends.vue:204`), which is false for a pending request.
- Spec choice: ASSUMPTION — `invalid_request`, per README convention (no specific reason)
  (`sendRequest`, witness `hit("friend/sendRequest",Failed("invalid_request"))`). Idempotent success would also
  be reasonable.
- To verify: add `already_requested` to sendRequest, or document success-no-op.

### FRIEND-07: Mutual requests: the second request accepts the first — protocol silent; reply can't tell
- Kind: Gap + Assumption (design default; teiserver matches)
- Evidence: Tachyon says nothing. Design default "the second request accepts the first". teiserver
  `account.ex:1985-2053` (`create_friend_request`: `case get_friend_request(to_user_id, from_user_id)` ->
  `accept_friend_request(existing_request)` -> `{:ok, :auto_accepted}`) and `tachyon_handler.ex:562-564`:
  `requestAccepted` to the target (from = caller) **and** to the caller (from = target). Test
  "mutual requests" in friend_test.exs. The sendRequest Ok reply is identical in both cases.
- Spec choice: `sendRequest` auto-accept branch, events `RequestAccepted` to both (only when Online). The
  reference client treats Ok to `sendRequest(t)` with `t` in its incoming set as a friendship
  (`clientOnOk`). Invariants `noCrossingRequests`, `noRequestBetweenFriends`. Mutation M2.
- To verify: document the auto-accept and the double `requestAccepted` in sendRequest's description; or
  return data `{ autoAccepted: true }` in the reply. Note M10: with a careful client the event to the caller
  is redundant, but bar-lobby needs it (FRIEND-16).

### FRIEND-08: Events for users that are not Online are lost; catch-up is by full state
- Kind: Gap (protocol says so but only for "connected") + cross-ref SESSION-05
- Evidence: friend README (`src/schema/friend/README.md:7-9`): "These events are automatically sent to the
  clients if they are connected. To catch up at connection, a client should request friend/list to get a full
  state." teiserver `player/session.ex:268-272` ("If the player isn't connected it's a no-op. They'll get the
  friend request as part of the friend/list response next time they connect") and `:1910-1918`
  `send_to_player` drops while `conn_pid == nil`, i.e. during the grace period too ("TODO tachyon_mvp: what
  should server do if the connection is down at that time?"). user/self carries friend state
  (`tachyon_handler.ex:1100-1116`), sent on (re)connect. bar-lobby re-fetches `friend/list` on every
  `onConnected` (`store/me.store.ts:223-229`) and also rebuilds from user/self (`:62-93`).
- Spec choice: `deliver` sends only to `Online`; `env/connect`/`env/reconnect` reset the client view from
  server state (`clientStep`). Witnesses `eventDropped`, `eventLostInGrace`; transcript `presenceTest`.
  Friend state persists across all session steps (`sessionStepsKeepFriends`).
- To verify: README should say "connected (socket up)"; a client must resync after **every** reconnect, also
  a grace-period reconnect (no notification is queued). Consistent with SESSION-05.

### FRIEND-09: cancelRequest has no `no_pending_request`; teiserver answers success
- Kind: Gap + Divergence-teiserver
- Evidence: cancelRequest reasons: `invalid_user` + generic (src/schema/friend/cancelRequest.ts:14), while
  accept/reject list `no_pending_request`. teiserver `tachyon_handler.ex:625-626` `{:error, "no request"} ->
  {:response, state}`; test "cancel non existant request" ("it's a no-op").
- Spec choice: ASSUMPTION — `invalid_request` (README convention; sibling commands deny on a missing target)
  (`cancelRequest`, witness `hit("friend/cancelRequest",Failed("invalid_request"))`).
- To verify: add `no_pending_request` to cancelRequest, or declare cancel idempotent (then remove should be
  too, FRIEND-01).

### FRIEND-10: Order of a reply and an event of the same command is unspecified
- Kind: Gap
- Evidence: Only the auto-accept sends an event to the caller. teiserver casts to the caller's own session
  (`tachyon_handler.ex:564`), which forwards to the socket after the handler has returned the response
  (in practice reply first, not guaranteed by any text).
- Spec choice: nondet `replyFirst`; the reference client is correct in both orders (`clientOnOk` ignores
  sendRequest Ok for an existing friend). `mutualRequestTest` uses event-first.
- To verify: docs/commands.md could say whether events caused by a request may precede its response.

### FRIEND-11: teiserver checks capacities before auto-accept: a mutual request can fail spuriously
- Kind: Divergence-teiserver
- Evidence: `account.ex:1986` `can_send_friend_request_with_reason?` (with the limit checks at
  `friend_request_lib.ex:71-75`) runs before the auto-accept branch (`account.ex:1990`). Auto-accept turns one
  pending request into one friendship for each user, so teiserver's count (FRIEND-03) is unchanged, yet a user
  at the limit gets `outgoing_capacity_reached` for `sendRequest` to someone who already asked them (while
  `acceptRequest` would succeed).
- Spec choice: no capacity check on the auto-accept branch (`capacityTest`: c's request to a, whose outgoing
  set is full, auto-accepts).
- To verify: teiserver test: limit 1, b -> a pending, a sends to b -> expect success.

### FRIEND-12: Friend changes made outside Tachyon produce no Tachyon events
- Kind: Divergence-teiserver
- Evidence: Tachyon events are emitted only from `tachyon_handler.ex:560-564, 590, 604, 623, 638`. The same
  data is changed by the web UI (`teiserver_web/live/account/profile/overview.ex:125, 255, 317`,
  `live/account/relationship/index.ex:97, 311`) and the Spring protocol (`protocols/spring/spring_user_in.ex:22,
  42, 52`); those paths broadcast only on PubSub `account_user_relationships:<id>`, which only the Spring
  server subscribes to (`protocols/spring/spring_out.ex:768`); no file in `lib/teiserver/player/` subscribes.
  An Online Tachyon client stays stale until reconnect.
- Spec choice: the model has only Tachyon commands, so every change emits its events.
- To verify: teiserver test: Tachyon client A, web/Spring user B sends A a request -> expect
  `friend/requestReceived` at A.

### FRIEND-13: Ignore/avoid makes sendRequest fail with `invalid_user`; protocol silent
- Kind: Gap + Divergence-teiserver
- Evidence: `friend_request_lib.ex:65-69` `does_a_ignore_b?(to_id, from_id)` / `does_a_avoid_b?` ->
  `:invalid_user`; tests "request to user who ignores sender/avoids sender". privateUser has `ignoreIds` but
  no friend text mentions ignoring; teiserver also sends `ignoreIds: []` in user/self
  (`tachyon_handler.ex:1116`).
- Spec choice: not modelled (no ignore relation in Tachyon commands).
- To verify: decide whether a block is reported as `invalid_user` (hides the block, as teiserver) and write it.

### FRIEND-14: teiserver error handling gaps in acceptRequest/rejectRequest/cancelRequest
- Kind: Divergence-teiserver
- Evidence: acceptRequest's `with ... else` (`tachyon_handler.ex:592-597`) matches only `{:error, :invalid_id}`
  and `{:error, "no request"}`; `accept_friend_request/1` can return `{:error, "Failed to create friendship:
  ..."}` (`friend_request_lib.ex:112-113`) -> `WithClauseError` crash instead of `internal_error`.
  cancelRequest turns every unexpected error into `invalid_user` (`:628-629`).
- Spec choice: n/a (storage errors not modelled).
- To verify: add catch-all `err -> internal_error` like rejectRequest (`:612-615`).

### FRIEND-15: user/self duplicates friend/list (without timestamps for friends); README says to call friend/list
- Kind: Contradiction (minor)
- Evidence: friend README: "To catch up at connection, a client should request friend/list". privateUser
  (`src/schema/definitions/privateUser.ts:42-53`) has `friendIds` (no `addedAt`), `outgoingFriendRequest`,
  `incomingFriendRequest` (with `sentAt`), sent on every connection. bar-lobby uses both
  (`me.store.ts:62-93, 190-214, 223-229`). Field names differ from friend/list (`outgoingPendingRequests` vs
  `outgoingFriendRequest`, singular).
- Spec choice: both give `serverView`; `listData` = view at the step; connect/reconnect reset the view.
- To verify: say user/self is sufficient (and drop the README sentence) or drop the fields from privateUser.

### FRIEND-16: bar-lobby keeps a stale incoming entry after an auto-accept, and drops entries on any error
- Kind: Divergence-bar-lobby
- Evidence: `store/me.store.ts:127-131` `sendRequest`: on success always
  `me.outgoingFriendRequestUserIds.add(to)`; `:100-103` `onFriendRequestAcceptedEvent` deletes from outgoing
  and adds the friend but never deletes from `incomingFriendRequestUserIds`. After b's request to a was
  auto-accepted (FRIEND-07), b's client shows a as friend **and** as pending incoming request (and, if the
  event comes before the reply, also as outgoing). `acceptRequest`/`rejectRequest`/`cancelRequest`
  (`:140-143, :153-157, :167-171`) remove the entry from the UI on **any** error ("Remove from UI even on
  error since request is invalid"), also on `internal_error`/`invalid_user` — the view then disagrees with
  the server until the next list. `LobbyParticipant.vue:120` calls `friends.sendRequest` without await/catch.
- Spec choice: reference client `clientOnEvent(RequestAccepted)` removes from incoming; `clientOnOk`
  handles auto-accept. Mutations M6 (bar-lobby's event handler) and M8 (bar-lobby's reply handler) violate
  `viewsInSync`.
- To verify: bar-lobby: in `onFriendRequestAcceptedEvent` also `incomingFriendRequestUserIds.delete(from)`;
  in `sendRequest` skip the add if `to` is already a friend or was in incoming.

### FRIEND-17: `requestCancelled` is described more broadly than cancel
- Kind: Gap
- Evidence: friend/requestCancelled: "Notify the player that a friend request they received is no longer
  valid" (not "was cancelled"). Only cancelRequest sends it in teiserver (`tachyon_handler.ex:623`); a request
  also disappears when the sender is deleted/anonymised (`account/tasks/delete_user_task.ex`,
  `gdpr_pseudo_anonymise_task.ex`) without any event.
- Spec choice: sent only by `cancelRequest` (`eventsMatchCommand`).
- To verify: list the causes (cancel, sender deleted, sender blocked by target...).

## Implementation check per command

| Command | teiserver (tachyon_handler.ex) | bar-lobby (store/me.store.ts) |
|---|---|---|
| list | `:543-553` matches; no failure path | `:190-214` replaces sets; called on every connect |
| sendRequest | `:555-585`; reasons all four specific ones; dup -> `already_in_friendlist` (06); ignore -> `invalid_user` (13); cap meaning (03, 11); auto-accept + 2 events (07) matches | `:127-131` + `Friends.vue:201-212` maps all reasons; stale state after auto-accept (16) |
| acceptRequest | `:587-599`; event `requestAccepted` to originator only (matches); unknown id -> `no_pending_request` (02); crash path (14) | `:134-145`; removes on any error (16) |
| rejectRequest | `:601-618`; event to originator (matches); (02) | `:147-159`; removes on any error (16) |
| cancelRequest | `:620-632`; event to target (matches); no request -> success (09); (02) | `:161-173`; removes on any error (16) |
| remove | `:634-652`; event `removed` to the other only (matches); non-friend -> success (01); (02) | `:175-188` alert on error |
| events | `:190-208`, `session.ex:268-312, 1429-1438`; dropped unless socket up (08); none for web/Spring changes (12) | `:95-118, 232-236`; requestAccepted keeps incoming (16) |

## Coverage

| Command | Outcome | Status |
|---|---|---|
| friend/list | Ok | witnessed |
| friend/list | invalid_request | unreachable (request has no data) |
| friend/sendRequest | Ok (new request) | witnessed `newRequestSent` |
| friend/sendRequest | Ok (auto-accept) | witnessed `autoAccepted` |
| friend/sendRequest | invalid_user, already_in_friendlist, invalid_request, outgoing_capacity_reached, incoming_capacity_reached | witnessed |
| friend/acceptRequest | Ok, invalid_user, no_pending_request | witnessed |
| friend/rejectRequest | Ok, invalid_user, no_pending_request | witnessed |
| friend/cancelRequest | Ok, invalid_user, invalid_request | witnessed |
| friend/remove | Ok, invalid_user, not_in_friendlist | witnessed |
| all | unauthorized, internal_error, command_unimplemented | unreachable: scopes, storage, dispatch not modelled |
| acceptRequest/rejectRequest/remove | invalid_request | unreachable: no rule needs it |
| env/connect, env/disconnect, env/reconnect, env/sessionExpired | NoReply | witnessed |
| event lost | to Detached / to Offline | witnessed `eventLostInGrace`, `eventDropped` |
| friend list beyond caps | 3 friends | `noFriendCapTest` (witness `multipleFriends`; full circle too rare for simulation) |

## Seeded mutations

All run with `quint test --main=friend4` and `quint run --invariant=safety --max-steps=30 --max-samples=50000`,
then reverted (file byte-identical to the checked one before the final samples tweak).

| # | Mutation (one line) | Caught by |
|---|---|---|
| M1 | acceptRequest sends no `requestAccepted` (`deliver(...)` -> `Set()`) | `viewsInSync`; sendAcceptRemoveTest, noFriendCapTest |
| M2 | no auto-accept (`else if (s.requests.contains((t, u)))` -> `else if (false)`) | `noCrossingRequests`, `noRequestBetweenFriends`, `viewsInSync`; mutualRequestTest, capacityTest |
| M3 | remove unfriends only the caller's side | `symmetric`, `viewsInSync`; sendAcceptRemoveTest, noFriendCapTest |
| M4 | outgoing capacity `>=` -> `>` | `withinCapacity`; capacityTest |
| M5 | `deliver` ignores presence | `eventsOnlyToOnline`; presenceTest |
| M6 | client: `RequestAccepted` keeps incoming (bar-lobby `me.store.ts:100-103`) | `viewsInSync`; mutualRequestTest |
| M7 | client: drop the "t in incoming -> friend" rule of sendRequest Ok | not caught: equivalent, the `requestAccepted` to the caller repairs it |
| M8 | client: sendRequest Ok always adds outgoing (bar-lobby `me.store.ts:129`) | `viewsInSync` (event-first order); mutualRequestTest |
| M10 | auto-accept sends no `requestAccepted` to the caller | only mutualRequestTest (a careful client does not need it; FRIEND-07) |

## Cross-module interface

- Presence is session.qnt's: `Online(u) ⇔ attached(s,u)`, `Detached(u) ⇔ online(s,u) ∧ ¬attached(s,u)`,
  `Offline(u) ⇔ ¬online(s,u)`. Steps `env/connect`, `env/disconnect`, `env/reconnect`, `env/sessionExpired`
  have session.qnt's names and pre-conditions; `env/takeover` acts like `env/reconnect` here (view reset by
  user/self, no state change). No session step changes friend state (`sessionStepsKeepFriends`); in
  particular `sessionEnded(u)` does not touch friends or pending requests.
- Friend commands are served only while the caller is Online (`step` guard).
- Friend events go only to Online users (`eventsOnlyToOnline`, as session.qnt `eventsToAttachedOnly`), only to
  the caller or the target, naming the other one (`eventsToInvolvedOnly`).
- user/self (session group) must carry `friendIds`, `outgoingFriendRequest`, `incomingFriendRequest` equal to
  `serverView(s,u)` at the moment it is sent; this module assumes it is sent on every Offline/Detached -> Online
  transition (session.qnt `openSocket`).
- Assumed of other groups: nothing about lobby/party/matchmaking; friend relations do not depend on activity.
  `USERS` = session.qnt `ACCOUNTS`; `GHOST` = its non-account id.

## Requests to the orchestrator

- session.qnt: confirm that `user/self` is sent on `env/connect`, `env/reconnect` and `env/takeover` (this
  module relies on it for FRIEND-08).
- If the orchestrator composes a "client view" across modules, this module's `views` is a friend-only view
  reset on user/self, like session.qnt's `views`.
