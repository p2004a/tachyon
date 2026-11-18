# Findings: session lifecycle, system/*, user/*

Module: `spec/quint/session.qnt` (`module session`, tests in `module session_test`).

## Scope

Commands modelled: `system/disconnect`, `system/serverStats`, `user/info`, `user/report`,
`user/subscribeUpdates`, `user/unsubscribeUpdates` (requests) and `user/self`, `user/updated` (events).
Environment steps: `env/connect` (fresh session), `env/reconnect` (socket back during grace),
`env/takeover` (second connection while the first is up), `env/disconnect` (socket drop, session in
grace), `env/sessionExpired` (grace over), `env/activityChanged` (another group moves the user between
menu / lobby / playing), `env/clientSends` (a request goes into the pending set). Serving a pending
request is a step whose `lastCmd` is the command id. `request` does send+serve in one step (transcripts).
The generic rules of `docs/commands.md` are modelled as a pending-requests abstraction: a request has
`(conn, messageId)`; it is answered once or dropped when its socket closes (`pendingOnLiveSocket`,
`responseCorrelated`, `requestResolved`, `pendingMidsUnique`). A client view (`views`) is rebuilt from the
events (reset on `user/self`, overwritten by `user/updated`); `viewsFresh` says that an attached client
knows the current status of everyone it subscribed to.
Abstracted away: user objects except `status`; OAuth flows, token refresh, version negotiation, pings
(only "the handshake needs `tachyon.lobby`" is kept); durations (a timer is an enabled step); schema
validation (requests are schema-valid by construction); `internal_error`/`command_unimplemented`.
Constants in `session_test`: accounts a, b, c, d plus the non-account id x; `MAX_SUBS = 2` (protocol: 100);
d's token has no `tachyon.lobby`; c is restricted from reporting.

## Findings

### SESSION-01: Second connection replaces the first — Tachyon says nothing; teiserver closes the old socket silently
- Kind: Assumption (design default) + Divergence-teiserver (close without reason)
- Evidence: `docs/connection.md` has no section on sessions or multiple connections. teiserver
  `player/tachyon_handler.ex:1141-1171` (`setup_session` → `Session.replace_connection` →
  `force_disconnect(old_conn_pid)`) and `player/registry.ex:33-44` (`register_and_kill_existing`). The old
  socket gets `{:stop, :normal, state}` (`tachyon_handler.ex:295-298`, `tachyon/transport.ex:128-131`:
  "TODO: send a proper tachyon message to inform the client it is getting disconnected"): no close code or
  reason, while `connection.md:40-42` asks for code `1008` plus a description when a peer terminates.
  bar-lobby treats any close as a fault and reconnects every 10 s (`logic/connection.ts:200-218`,
  `:77-93`), so two running clients on one account take the session from each other in a loop.
- Spec choice: `takeover` (= `openSocket` on an attached session): old socket's pending requests dropped,
  session (subscriptions, activity) kept, `user/self` + full `user/updated` to the new socket.
- To verify: add to connection.md: "a new connection for the same user replaces the old one; the server
  closes the old one with code 1008 and reason `replaced`" (and clients must not auto-reconnect on it).

### SESSION-02: Session grace period is not in the protocol; client and server timers do not fit together
- Kind: Gap
- Evidence: connection.md says nothing about a session outliving its socket. teiserver: 30 s
  (`player/session.ex:47` `@connection_timeout :timer.seconds(30)`, started at `:1563-1571`).
  bar-lobby only notices a dead link after 30 s of silence (`main/tachyon/tachyon-client.ts:18`
  `SERVER_SILENCE_LIMIT_MS = 30 * 1000`, `:98-106`) and then retries every 10 s (`logic/connection.ts:91`).
  For a silent network loss the client's first reconnect lands 30-40 s after the drop, after the server's
  grace (30 s, counted from the server's own detection) has likely run out.
- Spec choice: untimed `env/disconnect` / `env/reconnect` / `env/sessionExpired`.
- To verify: state the grace period (or a minimum) in connection.md, and the client-side liveness bound.

### SESSION-03: Grace expiry sends no user/updated "offline": subscribers see the user online forever
- Kind: Divergence-teiserver
- Evidence: `session.ex:1695-1702` `:connection_timeout` → `{:stop, :normal, state}`, with no
  `broadcast_user_update!(…, :offline)`. Only `system/disconnect` broadcasts offline (`session.ex:601`).
  The test `user_test.exs:264` "when target disconnects" uses `Tachyon.disconnect!` (= `system/disconnect`,
  `test/support/tachyon.ex:311-315`); no test covers a dropped socket.
- Spec choice: `sessionExpired` → `endSession` → `notifyChanges` sends `user/updated {status: offline}` to
  attached subscribers. Seeded mutation M2 (no event) violates `viewsFresh`.
- To verify: teiserver test: subscribe to B, abrupt_disconnect B, send `:connection_timeout` → expect
  `user/updated` offline.

### SESSION-04: Status during the grace period is unchanged
- Kind: Assumption
- Evidence: the status enum (`definitions/user.json`) is `offline | menu | playing | lobby`, no
  "reconnecting". teiserver keeps it (`session.ex:2005-2007` "for now(?) we don't surface the
  `reconnecting` status"); `user/info` during grace answers the session's status (`session.ex:761-770`).
- Spec choice: `statusOf` = "offline" iff no session; `socketDrop` produces no `user/updated`.
- To verify: should a detached user show as offline (they cannot answer invites, votes, ready checks)?

### SESSION-05: Reconnect full-state resend does not cover subscriptions; clients cannot tell resumed from fresh sessions
- Kind: Assumption (design default) + Gap + Divergence-teiserver + Divergence-bar-lobby
- Evidence: design default "after reconnect the server sends full state following user/self";
  user.md:387 only says user/self "should be sent to a user when they login". teiserver drops events while
  detached (`session.ex:1910-1918` `send_to_player`: "TODO tachyon_mvp: what should server do if the
  connection is down at that time? The best is likely to store it…") and on reconnect sends only
  `user/self` (`tachyon_handler.ex:91-103`); subscriptions persist in the session (`session.ex:89`) but no
  `user/updated` is resent, so updates missed during grace are lost. `user/self` (privateUser.json) has no
  subscription list and no "resumed" flag, so a client cannot know whether its subscriptions still exist.
  bar-lobby never resubscribes: `subsManager.attach` dispatches only for ids not already attached
  (`utils/subscriptions-manager.ts:18-32`); `processFriendData` on user/self re-attaches the same ids
  (`store/me.store.ts:77-93`) → no request. Lists are only cleared on a deliberate go-offline
  (`me.store.ts:121-123`, `:222`). After a grace expiry, friend/lobby/party presence silently stops.
- Spec choice: `openSocket` sends `user/self` and a full `user/updated` for every subscription; the client
  resets its view on `user/self`. M1 (no resend) violates `viewsFresh` and fails `graceReconnectTest`.
- To verify: either resend `user/updated` for all subscriptions after `user/self`, or say subscriptions end
  with the socket and clients resubscribe after every `user/self`.

### SESSION-06: Status "lobby" is never produced by teiserver; user/self status is always "menu"
- Kind: Divergence-teiserver
- Evidence: `broadcast_user_update!` is called only with `:menu`, `:playing`, `:offline`
  (`session.ex:65, 601, 1385, 1401, 1442, 1675, 1975`); joining a lobby broadcasts nothing.
  `user/info` status is `:menu` or `:playing` (`session.ex:761-770`). `user/self` hardcodes
  `status: :menu` (`tachyon_handler.ex:1110`) even when the session is in a lobby or a battle
  (`currentLobby`/`currentBattle` are set from the same state, `:1121-1127`).
- Spec choice: `statusOf` maps lobby → "lobby", playing → "playing"; `eventsCurrent` checks `Self(status)`.
  M7 (Self always "menu") violates `eventsCurrent` and fails `playingGraceTest`.
- To verify: teiserver test: join a lobby, subscriber gets `status: lobby`; reconnect during battle →
  user/self status `playing`.

### SESSION-07: A user who is playing keeps the session past the grace period
- Kind: Assumption (as teiserver) — disagrees with party.qnt
- Evidence: teiserver does not start the timer while in battle (`session.ex:1569-1571`) and ignores it
  (`:1696`); it restarts it when the battle ends with no socket (`:1678-1680`). Tachyon is silent.
  `party.qnt` `sessionExpired` fires for any Detached user (no activity guard).
- Spec choice: `sessionExpired` is a no-op while `activity = Playing` (witness `w_graceKeptWhilePlaying`).
- To verify: protocol owners; party/lobby/matchmaking should share the guard (see Cross-module interface).

### SESSION-08: When a session ends the user leaves lobby, battle, queue and party
- Kind: Assumption (cross-module)
- Evidence: party.qnt, lobby.qnt and matchmaking.qnt `env/sessionExpired` (lobby and matchmaking were
  `env/sessionEnded` before integration) all remove the user. findings/lobby.md said the session also ends
  when "replaced"; settled by INT-D1: a takeover keeps the session (SESSION-01), lobby.md corrected.
- Spec choice: `endSession` resets `activity` to Menu (`offlineIsIdle`).

### SESSION-09: system/disconnect gets no response; whether it ends the session is unstated
- Kind: Divergence-teiserver + Divergence-bar-lobby + Gap
- Evidence: system.md:11 "Ask the server to terminate the connection." The schema has a success response.
  commands.md:14 requests "expect the other side to send a correlating response command".
  teiserver `tachyon_handler.ex:328-332`: `Session.disconnect(…)` then `{:stop, :normal, state}`: no
  response. It also ends the session immediately (`session.ex:114-124` "Cleanly disconnect the user,
  clearing any state", `:588-605`), which system.md does not say. `data.reason` is ignored. bar-lobby
  awaits the response (`tachyon-client.ts:358-371`), which is then rejected with `socket_closed` when the
  socket closes (`:160-166`) and logged as "Error sending disconnect command"; bar-lobby relies on the
  session ending (`logic/connection.ts:112-115` "Choosing to go offline is what ends it").
- Spec choice: `disconnect` answers Ok, then ends the session (no grace) — ASSUMPTION SESSION-09. M4 (no
  response) violates `responseCorrelated` and fails `disconnectTest`.
- To verify: system.md: "ends the session; the server responds, then closes with 1000".

### SESSION-10: serverStats userCount counts sessions in grace
- Kind: Assumption
- Evidence: system.md:155 "Get server stats such as user count." teiserver `SessionRegistry.count()`
  (`tachyon_handler.ex:334-338`, `session_registry.ex:46-48`) counts every session, detached ones too.
- Spec choice: `serverStats` = number of users that are not offline (consistent with SESSION-04).

### SESSION-11: subscribeUpdates with an id that names no user; duplicates in one request
- Kind: Assumption + Divergence-teiserver
- Evidence: the schema's reasons are `subscription_limit_reached` plus the generic four; no `unknown_user`.
  teiserver answers `invalid_request` for unknown or non-numeric ids (`tachyon_handler.ex:653-669`,
  `session.ex:728-741`). Duplicated ids in one request (`["5","5"]`, allowed by the schema: no
  `uniqueItems`) make `Enum.count(users) != Enum.count(user_ids)` true (`session.ex:731`;
  `TachyonParser.parse_user_ids` does not dedupe), so the request fails with
  `invalid_request "invalid user ids: "` (empty list).
- Spec choice: unknown id → `invalid_request` (ASSUMPTION SESSION-11); ids are a set.
- To verify: add `unknown_user` to subscribeUpdates, or document `invalid_request`; add `uniqueItems`.

### SESSION-12: "unauthorized" is defined by roles, but no command declares a role
- Kind: Gap + Assumption
- Evidence: commands.md:38 unauthorized "When a client sends a request command of which they do not have
  the `role` required to use". The schemas only have `"scopes": ["tachyon.lobby"]` — all 168 of them,
  autohost commands included. authorization.md:42: the WebSocket needs a token with `tachyon.lobby`.
  teiserver checks the scope once at the handshake (`teiserver_web/controllers/tachyon.ex:16`) and picks
  the handler by token owner (`:73-77`), so a player sending an `autohost/*` command gets
  `command_unimplemented` (`tachyon_handler.ex:1096-1098`), not `unauthorized`. The only `unauthorized`
  in this group is a moderation restriction on reporting (`tachyon_handler.ex:526-527`).
- Spec choice: `handle` checks `REQUIRED_SCOPES` (unreachable after the handshake check); `report` returns
  `unauthorized` for `REPORT_RESTRICTED` callers (ASSUMPTION SESSION-12); `unauthorizedOnlyRole`.
- To verify: give autohost commands their own scope (e.g. `tachyon.autohost`), and define what "role" is.

### SESSION-13: user/report: reporting yourself and report types are unspecified
- Kind: Assumption + Gap
- Evidence: user.md:209 only "Issue a single moderation report on one or more users"; `reason.type` is a
  free string. teiserver: self in targets → `invalid_request "cannot report yourself"`
  (`tachyon_handler.ex:538-539`), unknown `reason.type` → `invalid_request` (`:532-533`, closed list
  `ReportLib.types()` at `:1641-1647`), unknown target → `unknown_user`, check order restriction → type →
  targets → self (`:501-503`, `:1649-1665`). teiserver's vendored request schema lacks `battleId`,
  `maxLength 255` and `minItems 1` (diff of `priv/tachyon/v0/schema/user/report/request.json`); it
  truncates long messages instead (`:1667-1672`).
- Spec choice: `report` follows teiserver's order; self → `invalid_request` (ASSUMPTION SESSION-13).
- To verify: list the report types in the schema (enum).

### SESSION-14: No subscription cap in teiserver; bar-lobby has none either
- Kind: Divergence-teiserver + Divergence-bar-lobby
- Evidence: user.md:684 "A maximum of 100 userIds can be subscribed to at any given time." teiserver
  unions without a bound (`session.ex:743`) and never returns `subscription_limit_reached`. The schema's
  `maxItems: 100` only bounds one request. bar-lobby subscribes all friends and friend requests in one
  call (`me.store.ts:85-88`), which is schema-invalid above 100; a failed subscribe (any reason) only shows
  `ui.userSubscribeFailed()` (`logic/connection.ts:242-251`) while `subsManager` keeps the ids as attached,
  so they are never retried. Attaches while disconnected are dropped the same way (`:243`).
- Spec choice: `subscribe` denies when `|subs ∪ ids| > MAX_SUBS` (`subsCapped`). M3 (no cap) violates
  `subsCapped` and fails `subscriptionLimitTest`.
- To verify: teiserver test: subscribe 101 distinct users in two requests → `subscription_limit_reached`.

### SESSION-15: messageId uniqueness and responses to unknown ids
- Kind: Assumption + Contradiction (typo)
- Evidence: commands.md:9 spells the property `messsageId` (the schemas use `messageId`) and :30 describes
  `status` as "A object containing data specific to the command". Uniqueness scope is not stated (per
  connection? per session?). teiserver does not check request ids; a client response to an id it has no
  pending request for closes the socket with 1008 (`tachyon/transport.ex:241-246`). bar-lobby uses
  `randomUUID()` (`tachyon-client.ts:186`) and logs unmatched responses (`:330-337`).
- Spec choice: fresh messageIds (`newReq`), `pendingMidsUnique`.

### SESSION-16: Subscribing broadcasts the target's state to all its subscribers, with status forced to "menu"
- Kind: Divergence-teiserver
- Evidence: `do_subscribe_updates` (`session.ex:1964-1982`) either broadcasts `:offline` on the target's
  PubSub topic itself, or casts `{:user, :get_subscribe_state}` to the target, which broadcasts
  `broadcast_user_update!(state.user, :menu)` on its topic (`session.ex:1441-1443`). Every existing
  subscriber gets a spurious `user/updated`, and if the target is playing, all of them now see "menu".
  Test `user_test.exs:312` checks only the subscriber's own messages.
- Spec choice: `subscribe` sends the full object to the caller only, with the real status
  (`updatedToSubscribersOnly`, `eventsCurrent`). M6 (broadcast to all) is caught by
  `updatedToSubscribersOnly`.
- To verify: teiserver test: C subscribed to B, B starts a battle, A subscribes to B → C must not get
  `status: menu`.

### SESSION-17: unsubscribeUpdates "should always succeed", teiserver can fail it
- Kind: Divergence-teiserver
- Evidence: user.md:871 "This should always succeed." `tachyon_handler.ex:671-687` returns
  `invalid_request` for non-numeric ids; test `user_test.exs:290` "unsubscribe invalid id" asserts it.
- Spec choice: `unsubscribe` is always Ok (unknown ids ignored; `subscriptionLimitTest`).

### SESSION-18: user/updated payload does not match the schema; teiserver ships an older "v0" schema
- Kind: Divergence-teiserver + Contradiction (same version, two schemas) + Divergence-bar-lobby
- Evidence: `tachyon_handler.ex:210-226` sends `country` (schema: `countryCode`), `clanId: nil` (schema:
  `clanBaseData`), `displayName = username`. `user/info` and `user/self` also send `clanId`
  (`:486`, `:1108`), while tachyon `definitions/user.json` *requires* `clanBaseData`. teiserver validates
  against `priv/tachyon/v0/schema/definitions/user.json` (`"required": [... "clanId" ...]`), an older
  copy; both call themselves `v0` (connection.md:30). bar-lobby merges `{...user}` into its db
  (`store/users.store.ts:33-47`), so it stores a stray `country` key and `countryCode` stays "??".
- Spec choice: not modelled (only `status`).
- To verify: bump the protocol version for breaking schema changes; teiserver: send `countryCode`.

### SESSION-19: Requests before user/self: teiserver's login queue answers invalid_request
- Kind: Gap + Divergence-teiserver + Divergence-bar-lobby
- Evidence: teiserver may admit a socket without a session (`tachyon_handler.ex:78-89`, `LoginQueue`);
  until then every message gets `invalid_request "waiting for login"` (`:318-326`), including events and
  requests the client will retry. Tachyon does not say whether a client may send before `user/self`.
  bar-lobby counts the socket as connected on `open` (`tachyon-client.ts:132-137`) and immediately sends
  `system/serverStats` and pending subscriptions (`logic/connection.ts:186-198`).
- Spec choice: the socket and `user/self` arrive in one step (`openSocket`), so there is no window.
- To verify: connection.md: "the client must not send requests before user/self", or a queued status.

### SESSION-20: teiserver answers events
- Kind: Divergence-teiserver
- Evidence: commands.md:45 "Events are commands which require no response". The fallback clause
  (`tachyon_handler.ex:1096-1098`) and the transport's schema errors (`transport.ex:211-238`) reply with
  an error *response* to any message, events included.
- Spec choice: only requests are answered (`responseCorrelated`).

### SESSION-21: A crash inside a command handler gives no response
- Kind: Divergence-teiserver
- Evidence: `transport.ex:270-313`: the `try … rescue` that sends `internal_error` wraps only
  `handle_result`; `state.handler.handle_command(...)` (`:273-280`) runs outside it, so an exception (e.g.
  a `GenServer.call` to a dead session) kills the connection without a response, breaking "every request
  gets a response". Server→client requests time out after `:timer.seconds(10_000)` (`:390`), i.e. ~2.8 h,
  probably meant 10 s.
- Spec choice: every served request has exactly one response (`responseCorrelated`, `requestResolved`).

### SESSION-22: user/self is also sent when roles change; nothing tells a client its own status
- Kind: Gap + Divergence-teiserver
- Evidence: user.md:387 user/self "should be sent to a user when they login". teiserver also sends it on
  a role change (`tachyon_handler.ex:228-231`, `session.ex:1446-1449`). A user's own status (menu → lobby
  → playing) reaches them only via user/updated if they subscribe to themselves; nothing says that is
  allowed or needed. bar-lobby takes identity from every user/self (`main/services/tachyon.service.ts:15-27`,
  `store/me.store.ts:62-74`).
- Spec choice: `selfOnlyOnLogin` (user/self only on connect/reconnect/takeover); self-subscription allowed.

## Coverage

| Command / step | Outcome | Status |
|---|---|---|
| env/connect | fresh session, user/self | witnessed `w_connectFresh`, presenceTest |
| env/connect | token without tachyon.lobby (handshake refused) | witnessed `w_connectRefused`, reportTest |
| env/reconnect | reattach + user/self + full user/updated resend | witnessed `w_reconnectResend`, graceReconnectTest |
| env/takeover | old socket closed, its pending requests dropped | witnessed `w_replaceDropsPending`, replaceConnectionTest |
| env/disconnect | detached, pending dropped | witnessed `w_socketDrop` |
| env/sessionExpired | session ends, subscribers get offline | witnessed `w_graceEndNotifies`, graceExpiryTest |
| env/sessionExpired | kept while playing | witnessed `w_graceKeptWhilePlaying`, playingGraceTest |
| env/sessionExpired | late fire no-op | graceReconnectTest, disconnectTest |
| env/activityChanged | user/updated to subscribers | witnessed `w_activityNotifies` |
| pending requests | answered out of order | witnessed `w_servedFromQueue`, pendingTest |
| system/disconnect | Ok (+ offline to subscribers) | witnessed `w_disconnectNotifies` |
| system/serverStats | Ok | witnessed `w_statsTwo` |
| user/info | Ok | witnessed `w_infoLobby` |
| user/info | unknown_user | witnessed |
| user/report | Ok / unknown_user / unauthorized (restricted) / invalid_request (self) | all witnessed |
| user/subscribeUpdates | Ok / subscription_limit_reached / invalid_request (unknown id) | all witnessed |
| user/unsubscribeUpdates | Ok | witnessed |
| all six requests | unauthorized for missing scope | unreachable: the handshake requires tachyon.lobby (SESSION-12) |
| all six requests | internal_error, command_unimplemented | not modelled (server faults) |
| all six requests | invalid_request (schema mismatch) | not modelled: requests are schema-valid by construction |
| system/disconnect, serverStats, info | invalid_request | unreachable for the same reason |
| user/unsubscribeUpdates | any failure | unreachable: "This should always succeed" |
| user/self, user/updated | (events) | checked by `selfOnlyOnLogin`, `eventsCurrent`, `updatedToSubscribersOnly`, `viewsFresh` |

`./check.sh session.qnt`: typecheck, 9 transcripts, `safety` (30 steps, 50000 samples, ~20 s), 21
witnesses: all green, ~1.5 min. `VERIFY=1`: `quint verify --max-steps=2` passes in 2 min 21 s with
`JVM_ARGS=-Xmx6G` (directive `@verify … steps=2`); 3 steps was not tried within the time budget.

## Seeded mutations

Each was applied to a scratch copy (one edit), run with `quint test` and `quint run --invariant=safety`
(30 steps, 20000 samples), then per-conjunct to name the catching invariant.

| # | Mutation | Caught by |
|---|---|---|
| M1 | `openSocket` does not resend user/updated for subscriptions (teiserver behaviour) | tests graceReconnectTest, replaceConnectionTest; `viewsFresh` |
| M2 | `sessionExpired` sends no events (teiserver behaviour, SESSION-03) | test graceExpiryTest; `viewsFresh` |
| M3 | no subscription cap (teiserver, SESSION-14) | test subscriptionLimitTest; `subsCapped` |
| M4 | system/disconnect without response (teiserver, SESSION-09) | test disconnectTest; `responseCorrelated` |
| M5 | takeover keeps the old socket's pending requests | test replaceConnectionTest; `pendingOnLiveSocket` |
| M6 | user/updated to every attached user, not only subscribers | 4 tests; `updatedToSubscribersOnly` |
| M7 | user/self status always "menu" (teiserver, SESSION-06) | test playingGraceTest; `eventsCurrent` |

## Cross-module interface

Presence, as the other modules see it: `Online(u) ⇔ attached(s,u)`, `Detached(u) ⇔ online(s,u) ∧
¬attached(s,u)`, `Offline(u) ⇔ ¬online(s,u)`.

- Step mapping to `party.qnt`: `env/connect` = party `connect` (Offline → Online); `env/reconnect` = party
  `reconnect`; `env/disconnect` = party `disconnect`; `env/sessionExpired` = party `sessionExpired`.
  Same names, same pre-conditions, except: (1) `env/takeover` (Online → Online, new socket) has no party
  counterpart — party state must be unchanged by it, and the new socket gets user/self (party view reset);
  (2) here `system/disconnect` ends the session straight from Online, party models it as
  `disconnect`+`sessionExpired` (same end state); (3) here `sessionExpired` is a no-op while playing
  (SESSION-07), party has no such guard (the composition guards it, INT-D2); party now has
  `env/takeover` too.
- The session end in lobby.qnt / matchmaking.qnt is now also named `env/sessionExpired` (INT-D1). It
  happens exactly on `env/sessionExpired` with effect and on `system/disconnect` Ok. Not on
  `env/takeover` (lobby.md corrected).
- Assumed of other groups: `¬online(u) ⇒ u ∉ lobby members ∧ u ∉ queue ∧ u ∉ party members ∧ u not
  playing` (`offlineIsIdle`); `activity(u) = InLobby ⇔ u is a lobby member`, `Playing ⇔ u is in a running
  battle`, provided by lobby/battle modules through `env/activityChanged`; each such change produces
  `user/updated` to u's attached subscribers (no other group sends user/updated).
- Requests from other groups are only served while their caller is attached
  (`pendingOnLiveSocket`); a socket close drops them without a response.
- After `env/reconnect`/`env/takeover`, every group's full state follows user/self in the same delivery
  (party/lobby/matchmaking resync from user/self fields; this group adds user/updated per subscription).

## Requests to the orchestrator

- Settle one session vocabulary across modules: party uses `env/sessionExpired`, lobby and matchmaking
  `env/sessionEnded`, and lobby treats a replaced connection as a session end; this module's mapping is
  above.
- Decide whether "playing keeps the session" (SESSION-07) applies to party/lobby/matchmaking too.

## Integration changes

Made by the integration step (findings/system.md, decisions INT-D1..D5):

- This module's vocabulary (`env/connect`, `env/disconnect`, `env/reconnect`, `env/takeover`,
  `env/sessionExpired`; presence Online | Detached | Offline) is the shared one (INT-D1). Only a comment in
  `sessionExpired` changed (it named the old lobby/matchmaking step `env/sessionEnded`).
- SESSION-07 ("playing keeps the session") is adopted for every module as INT-D2, still an Assumption.
  Lobby and matchmaking guard their `sessionExpired` with it; party, messaging and friend have no battle
  notion and system.qnt guards the composed step.
- Both requests above are settled by INT-D1/INT-D2.
