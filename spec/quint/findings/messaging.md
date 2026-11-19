# Messaging: findings

## Scope

`messaging.qnt` models the whole messaging group: the requests `messaging/send` (targets `player`,
`party` and `lobby`) and `messaging/subscribeReceived` (`since` = `latest` | `from_start` |
`marker`), and the event `messaging/received`. The event carries `source` (player / party(partyId) /
lobby(lobbyId) plus the sender's userId) and a `marker`. The model also has the session steps that
decide whether a recipient gets a message live, later from its buffer, or never. They use the
session.qnt vocabulary: `env/connect` (fresh session), `env/disconnect` (socket drop, session in
grace), `env/reconnect` (socket back while in grace), `env/takeover` (a second connection replaces
the attached one) and `env/sessionExpired`. A last step, `env/membership`, lets other modules move
any online user into or out of any lobby or party.

Each session has a bounded per-session buffer (cap `BUF_CAP`, drop-oldest), a `connected` flag and a
`subscribed` flag. Markers are unique, increasing message ids. Two kinds of ghost state are kept:
- `addressed`: the (recipient, message) pairs fixed at send time.
- A client view per user, the way bar-lobby keeps it: the last marker, the ids delivered since the
  last subscribe, all ids ever seen, and whether this socket has subscribed.

`Outcome` has two extra fields: `replay` (the ordered history sent "straight after the response")
and `missed` (the reply field `hasMissedMessages`).

Abstracted away:
- Message bodies become small ints, and only the abstract predicate `tooLong(body) = body > MAX_BODY`
  (schema `maxLength: 512`) is kept.
- Timestamps.
- Persistence to the database (moderation logs).
- `unauthorized`, `internal_error` and `command_unimplemented`.
- Durations.

Constants in `messaging_test`: users a, b, c; lobbies {1, 2}; parties {1, 2} (0 = none);
bodies {0, 1, 2} with `MAX_BODY = 1`; `BUF_CAP = 2` (teiserver: 200).

Checks (`./check.sh messaging.qnt`) give 20 ok and 0 FAIL:
- typecheck;
- 6 transcripts;
- `safety`, 30 steps × 20000 samples;
- 17 witnesses.

`VERIFY=1` additionally runs `quint verify --max-steps=3` on `safety`. It passed with
`JVM_ARGS=-Xmx6G` in about 68 s. Steps 2 took 24 s; 4 steps were not attempted.

`safety` = `reasonsInSchema`, `bufferBounded`, `bufferSound`, `eventsOnlyToAddressed`,
`sendRecipientsExact`, `noEchoToSender`, `replayOnlyToCaller`, `deliveryOrdered`,
`noDuplicateAfterMarker`, `noDuplicateLive`, `nothingBeforeSubscribe`, `denialsInert`.

`// ASSUMPTION MSG-An` tags in the .qnt map to findings as follows:
- A1 → MSG-06
- A2 → MSG-01
- A3 → MSG-04 (A3a → MSG-03)
- A4, A5 → MSG-09
- A6 → MSG-11
- A7 → MSG-10
- A8 → MSG-16
- A9 → MSG-07, MSG-08

## Protocol (Tachyon)

### MSG-01: `message_too_long` cannot be returned by a schema-validating server; order against `invalid_target` unstated
- Kind: Contradiction + Assumption (A2). Not a divergence: both implementations do what the schema forces
- Review: Partial, Low
- Evidence:
  - tachyon `src/schema/messaging/send.ts:57-58` `// somewhat arbitrary maxLength, but we need one`
    `message: Type.String({ maxLength: 512 })`. The same file lists the failure
    `{ status: "failed", reason: "message_too_long" }` (`:63`).
  - A message of more than 512 characters is therefore schema-invalid. teiserver validates every
    request against the schema first and answers `invalid_request`: `tachyon/transport.ex:224-228`
    `{:error, %JSV.ValidationError{} = err} -> ... :invalid_request`.
  - `message_too_long` appears nowhere in teiserver lib/ or test/, and `Messaging.Message.new` says
    "the content maximum length is enforced at the protocol layer" (`messaging/message.ex:21-22`).
  - bar-lobby validates the request before sending (`main/tachyon/tachyon-client.ts:196`
    `validateMessage(request, "command")`). An overlong message throws locally. The UI then shows only
    "Error with request messaging/send" (`renderer/store/chat.store.ts:84`). The chat inputs have no
    `maxlength`.
- Spec choice: `sendMessage` checks the abstract `tooLong(body)` first and answers
  `message_too_long`, then checks the target (ASSUMPTION A2). Witness
  `sentDenied("player","message_too_long")`.
- To verify: either drop `maxLength` from the request schema and keep `message_too_long` as the
  server's answer (the limit then becomes a server setting), or drop the reason. Also say whether
  the length is counted in code points or bytes, and which check comes first.

### MSG-02: "only supported source is `player`" and "subscribe to a given source" contradict the schema
- Kind: Contradiction
- Evidence:
  - `docs/schema/messaging.md:21-23`: "To receive messages, a client first has to subsribe to a given
    source. For now the only supported source is `player`".
  - The `subscribeReceived` request has no `source` field (only `since`). The send and received
    schemas have offered `party` and `lobby` since #111 ("Added a "lobby" messaging type").
  - teiserver has one subscription and one buffer for all sources
    (`player/types/messaging_state.ex:15-19` "only hold one buffer for everything").
  - bar-lobby subscribes once "(all sources)" (`chat.store.ts:51-52`).
- Spec choice: one subscription covers player, party and lobby messages, and all of them share one
  buffer and one marker sequence (`subscribeReceived`, `history`).
- To verify: rewrite the README paragraph (src/schema/messaging/README.md). Either add a `source`
  filter to the request, or state that the subscription and the markers cover all sources.

### MSG-03: DM to an offline or unknown user succeeds in teiserver; "online" during grace is unstated
- Kind: Divergence-teiserver + Gap + Assumption (A3a)
- Review: Confirmed, Medium
- Evidence:
  - messaging.md:13: "A message can only be sent to online players." `invalid_target` is the only
    reason that fits.
  - teiserver `messaging.ex:20-21` `send(message, {:player, to_id}), do: Session.send_dm(to_id, message)`
    → `session.ex:250-256` `GenServer.cast(via_tuple(...))`, documented "If there is no session for
    this player the message is lost". `GenServer.cast` to a `:via` name with no registered process
    is swallowed and returns `:ok`. So `Messaging.send` never returns `{:error, :invalid_recipient}`
    for a player.
  - `tachyon_handler.ex:418-455` then answers `success` and persists the DM anyway (`:432`
    `Messaging.persist_direct_message(msg, user_id)`, which also runs for a nonexistent `to_id`).
  - `invalid_target` comes only from an unparsable userId (`:1189-1191`).
  - The teiserver tests cover only an online, unsubscribed receiver (`test/teiserver_web/tachyon/messaging_test.exs:26-31`).
- Implementation part (Divergence-teiserver): a DM to an offline or unknown user is answered `success` and persisted.
- Spec choice: `online(s, v)` = v has a session, attached or in grace. A DM to a user with no
  session is `invalid_target`. A DM to a detached user is accepted and buffered (ASSUMPTION A3a). This
  matches the marker text, "typically used by clients when they reconnect after a crash to make sure
  they are not missing any messages". Transcripts `dmTest` and `expiryTest`; witness
  `sentDenied("player","invalid_target")`.
- To verify: teiserver test: DM to a user id with no session → expect `invalid_target`. Protocol: say
  "online" includes a session in its grace period.

### MSG-04: Party/lobby message without being a member: teiserver answers `invalid_request`, and the party path crashes the session
- Kind: Divergence-teiserver + Assumption (A3)
- Review: Confirmed, High
- Evidence:
  - The schema has `invalid_target` for this command. Tachyon does not say what "not in a party" gives.
  - teiserver maps every party/lobby error to `invalid_request` (`tachyon_handler.ex:440-449`
    `{:error, reason} -> {:error_response, :invalid_request, inspect(reason), state}`). The test pins
    this (`messaging_test.exs:214-217` "messaging in lobby must be in lobby" expects `invalid_request`).
  - Party path bug: `session.ex:698-704` `when state.party.current_party == nil, do: {:reply,
    {:error, "not in party"}}` has no state element. That is an invalid `handle_call` return, so the
    session GenServer crashes. Its party, lobby, matchmaking state and message buffer are lost, and the
    caller's `GenServer.call` exits, which also takes down the connection (compare SESSION-21). No test
    sends a party message outside a party.
- Implementation part (Divergence-teiserver): the `invalid_request` mapping (pinned by the test) and the session
  crash at `session.ex:704` (= PARTY-18).
- Spec choice: `sendMessage` answers `invalid_target` when `partyOf(u) == 0` / `lobbyOf(u) == 0`
  (ASSUMPTION A3). Witnesses `sentDenied("party"|"lobby","invalid_target")`; `groupTest`.
- To verify: fix `session.ex:704` (`{:reply, {:error, "not in party"}, state}`) and add the
  missing test. Protocol owners: decide whether "not a member" is `invalid_target` (our choice) or
  `invalid_request`.

### MSG-06: Who receives: party/lobby members other than the sender; a DM goes to the named user, self included
- Kind: Assumption (A1) + Gap
- Evidence:
  - Tachyon only says "send it to the recipient(s)" (messaging.md:9).
  - teiserver sends to party members excluding the sender (`party/server.ex:429` `for id <-
    Map.keys(data.members), id != from_id`). Invited users are not members, and the test checks this
    (`messaging_test.exs:203`).
  - Lobby: players plus spectators, excluding the sender (`tachyon_lobby/lobby.ex:842-845`).
  - DM: the target's session, even when the target is the sender.
  - bar-lobby relies on exactly this. It inserts its own lobby/party/DM messages locally "because the
    server will not provide it back to us" (`chat.store.ts:171-172`, `:78`). For a self-DM it skips
    the local copy "b/c we will receive it from the server" (`:75`).
- Spec choice: `recipients`; invariants `sendRecipientsExact` (the recipients are exactly the
  target's other online members at send time; events go exactly to the live ones among them) and
  `noEchoToSender`. Transcripts `groupTest` and `selfDmTest`.
- To verify: state in messaging.md: "the sender does not receive its own party/lobby message; a
  message to oneself is delivered".

### MSG-08: Lifetime of the messaging subscription is unspecified, and it differs from user/subscribeUpdates
- Kind: Gap + Assumption (A9)
- Evidence:
  - messaging.md says nothing about when a subscription ends. teiserver binds it to the socket (MSG-07).
  - User-presence subscriptions survive in the session (findings/session.md SESSION-05). So after a
    reconnect a client must re-send `messaging/subscribeReceived` but not `user/subscribeUpdates`.
  - bar-lobby happens to do the right thing for messaging (`chat.store.ts:52`, resubscribe on every
    connect).
- Spec choice: `disconnect`, `reconnect` and `takeover` clear `subscribed`. Messages that arrive in
  between are buffered, and `subscribeReceived` with the client's own marker returns them
  (`resumeTest`, witness `honestResumeAfterReconnect`).
- To verify: add to messaging.md: "the subscription ends with the connection; re-subscribe after
  every user/self, with the last marker".

### MSG-09: "No support to store messages" vs a replay buffer; buffering before subscribing; capacity
- Kind: Contradiction (wording) + Gap + Assumption (A4, A5)
- Evidence:
  - messaging.md:14 "There is no support to store messages to be then delivered later". But
    `from_start` "will send its entire buffer", and `latest` "will not send any potentially stored
    messages".
  - Not stated:
    - whether messages are buffered before the first subscription;
    - how large the buffer is;
    - what is dropped on overflow;
    - that the buffer dies with the session.
  - teiserver buffers always (`messaging_state.ex:25` `store_messages?: true`). The buffer holds 200
    entries (`:29` `BQ.new(200)`, "TODO: would be better to have that as a db setting") and drops the
    oldest (`helpers/bounded_queue.ex:79-89`). It is lost when the session stops.
  - The teiserver test `messaging_test.exs:72-99` relies on buffering while unsubscribed.
- Spec choice: every accepted message goes into each recipient session's buffer, subscribed or not
  (A5). The buffer is bounded by `BUF_CAP` with drop-oldest (A4). `sessionExpired` discards it.
  Invariants `bufferBounded`, `bufferSound`; witnesses `bufferOverflowed`,
  `subscribedWith("from_start")and(lastReplay.length()>1)`.
- To verify: replace the sentence with "messages are kept in a bounded per-session buffer (size: server
  setting) and are lost when the session ends".

### MSG-10: `hasMissedMessages` for `from_start`/`latest`: description covers markers only; teiserver reports a sticky overflow flag
- Kind: Gap + Divergence-teiserver + Assumption (A7)
- Review: Confirmed-minor, Low
- Evidence:
  - The response description says only "set to true when the marker sent doesn't match any message
    stored by the server".
  - teiserver answers `BQ.dropped?(buffer)` for `from_start` (`session.ex:679-680`). That flag is set
    on the first overflow and never cleared, because `put` does not reset it
    (`bounded_queue.ex:83-85`, cleared only by `out`).
  - bar-lobby knows this and ignores the flag for non-marker requests (`chat.store.ts:127-132`: "the
    flag stays set for the rest of the session once its buffer has overflowed even once").
- Implementation part (Divergence-teiserver, minor): the sticky `dropped?` flag, a reasonable extension of an
  under-specified flag.
- Spec choice: `false` for `latest` and `from_start`, as the description literally says (`history`).
- To verify: decide whether `from_start` should report "the buffer has lost messages", and if so
  whether that means "since the last subscription" or "ever".

### MSG-11: Unknown marker: what is replayed is unspecified
- Kind: Gap + Assumption (A6)
- Evidence:
  - messaging.md:30-33 covers only a matching marker.
  - teiserver replays the whole buffer and sets `hasMissedMessages` (`session.ex:682-692`). The test
    pins this (`messaging_test.exs:135-158` "the whole buffer is sent again").
  - The same happens for a non-integer marker (`tachyon_handler.ex:1218-1223`), and for a marker from
    a previous session or one that fell out of the buffer.
- Spec choice: `history(Marker(m))` with m not in the buffer gives the whole buffer and
  `missed = true`. This keeps `noDuplicateAfterMarker`: if the client's last marker has been dropped,
  every message still in the buffer was sent after it (`resumeTest`, last step; `missedTest`).
- To verify: add "if the marker is unknown, the whole buffer is sent and hasMissedMessages is true".

### MSG-13: Ordering guarantees are not stated
- Kind: Gap + Assumption
- Evidence:
  - Tachyon says nothing about order. teiserver gives per-target FIFO only: all messages of one target
    leave one process (sender connection for DMs, party process, lobby process), and Erlang orders
    messages per process pair. The buffer keeps arrival order, and the replay is a buffer suffix
    (`session.ex:685-692`).
  - Across targets, the order is the arrival order at the recipient's session.
  - bar-lobby assumes the replay is in order and takes the last event's marker as the latest
    (`chat.store.ts:164-166`).
  - "after the message designated by the marker" is positional in the recipient's buffer in teiserver,
    not by timestamp.
- Spec choice: one global send order, so the model is stricter than teiserver. `deliveryOrdered`: the
  ids a client gets within one subscription are strictly increasing. This implies per-recipient order
  equals send order for each target. Live sends and history replays cannot interleave, because a step
  is atomic. In teiserver this holds because the session builds the replay and sets `subscribed?` in
  one `handle_call`, and the replay is written before any later live message.
- To verify: state "per recipient, messages from one target arrive in send order; a replay is in buffer
  order and precedes later live messages".

### MSG-16: Re-subscribing, and the absence of unsubscribe
- Kind: Gap + Assumption (A8)
- Evidence:
  - There is no `messaging/unsubscribeReceived`, and nothing says what a second `subscribeReceived`
    does.
  - teiserver accepts it and replays again (`session.ex:663-696`). The `invalid_request` it could
    return is never used.
  - bar-lobby re-subscribes after failures (`chat.store.ts:138-148`).
- Spec choice: always `Ok` with a fresh replay; the client's log restarts (`dmTest`, `missedTest`).
- To verify: state that subscribing again is allowed and idempotent apart from the replay.

## Implementation (teiserver b36429f, bar-lobby ee58acd)

Entries under Protocol that also carry an implementation part (marked in the entry): MSG-03, MSG-04, MSG-10.

### MSG-05: Lobby message racing a lobby shutdown crashes the session
- Kind: Divergence-teiserver
- Review: Confirmed, Medium
- Evidence: `tachyon_lobby/lobby.ex:1199-1201` `call_lobby` returns `{:error, :invalid_lobby}` (a
  2-tuple) on `:noproc`/`:shutdown`. `session.ex:721-725` matches only `:ok` and
  `{:error, :invalid_request, reason}`, so the result is a `CaseClauseError` in the session.
  `Party.send_message` catches `:noproc` and returns a 3-tuple (`party/server.ex:164-165`), so party
  is fine here.
- Spec choice: not modelled (no lobby crash step). The spec answer would be `invalid_target`.
- To verify: teiserver test: kill the lobby process, then `messaging/send {type: lobby}` → expect a
  failed response, with the session alive.

### MSG-07: teiserver keeps the messaging subscription when a new connection replaces the old one
- Kind: Divergence-teiserver (+ Divergence-bar-lobby: no de-duplication)
- Review: Confirmed, Medium
- Evidence:
  - The subscription is bound to the socket on abrupt disconnect (`session.ex:1563-1567` puts
    `subscribed?` to false). The test says the same: `messaging_test.exs:48` "subscription is bound to
    ws connection".
  - But `handle_call({:replace, new_conn_pid}, ...)` (`session.ex:558-581`) demonitors the old
    socket with `:flush`, so that DOWN never runs, and it keeps `messaging_state` unchanged. The
    replacing socket therefore receives `messaging/received` before it has subscribed
    (`session.ex:1419-1421`).
  - bar-lobby subscribes on every connect with its last marker (`chat.store.ts:52`, `:92-95`). A live
    message that reaches the new socket after the client sent `subscribeReceived` with marker M, but
    before the server handled it, is sent again in the marker replay. bar-lobby does not de-duplicate
    (`insertMessage`, `chat.store.ts:198-207`, pushes unconditionally), so the user sees the message
    twice.
- Spec choice: `takeover` (and `reconnect`) start the socket unsubscribed (ASSUMPTION A9).
  `nothingBeforeSubscribe` also checks the client's own `sub` flag. Seeded mutation M5 (takeover keeps
  `subscribed`) is caught by that invariant and by `resumeTest`.
- To verify: teiserver test: subscribe, connect a second socket with the same token, DM → the new
  socket must get nothing until it subscribes. Fix: reset `subscribed?` in the `:replace` handler.

### MSG-12: teiserver markers are not unique, so marker resume can re-deliver
- Kind: Divergence-teiserver
- Review: Confirmed, Low
- Evidence:
  - The marker is `:erlang.monotonic_time(:micro_seconds)`, read independently in the sender's
    connection process (`tachyon_handler.ex:427`), in the party process (`party/server.ex:424`) and in
    the lobby process (`tachyon_lobby/lobby.ex:835`).
  - Erlang monotonic time is not strictly increasing between calls. It can repeat within one
    microsecond, across processes, and across nodes, where it also has a different offset. So two
    messages in one recipient's buffer can carry the same marker.
  - `BQ.split_when(buffer, &(&1.marker == marker))` (`session.ex:686`, `bounded_queue.ex:127-150`)
    cuts at the first equal marker. Resuming from the later of two equal markers therefore re-sends it.
- Spec choice: markers are unique message ids (`nextId`). With equal markers, `noDuplicateAfterMarker`
  would fail (compare mutation M2, which re-sends the marker's own message).
- To verify: use `:erlang.unique_integer([:monotonic, :positive])` (or a per-session counter). The
  protocol could state "markers are unique per recipient".

### MSG-14: bar-lobby resumes with `latest` whenever it holds any chat but no marker, which skips missed messages
- Kind: Divergence-bar-lobby
- Review: Confirmed, Medium
- Evidence:
  - `chat.store.ts:92-104`: with no `lastMarker`, `resumePoint` picks `latest` if `hasStoredMessages()`.
  - That check counts chats that contain only the user's own locally inserted messages (`marker: ""`,
    `:175-190`). It also counts empty lobby/party chat entries (`lobbyChats.size > 0`).
  - So a user who has only sent messages, then loses the socket and reconnects within grace, skips the
    messages buffered meanwhile.
  - It also sends a stale marker after a silent grace expiry (the marker is cleared only on a deliberate
    go-offline, `:273-278`). That gets `hasMissedMessages` and the new session's whole buffer, which is
    harmless.
- Spec choice: the model's honest client resumes with its last marker. `from_start` is the safe choice
  when it has none.
- To verify: bar-lobby test: connect, send a DM (no reception), drop the socket, receive a DM while
  detached, reconnect → the DM must appear.

### MSG-15: Lobby fan-out uses a node-local session registry (multi-node only)
- Kind: Divergence-teiserver (only for a multi-node deployment)
- Review: Unverifiable, Low
- Evidence:
  - Lobby calls run on the lobby's primary node (`tachyon_lobby/lobby.ex:1190-1196`,
    `Cluster.primary_apply`).
  - The fan-out `Messaging.send(msg, {:player, id})` → `GenServer.cast(SessionRegistry.via_tuple(id))`
    uses a node-local `Registry` (`player/session_registry.ex:8-18`). Recipients whose session lives on
    another node are therefore silently skipped, and the sender still gets `success`.
- Spec choice: not modelled (no nodes). `sendRecipientsExact` states the intended recipient set.
- To verify: confirm whether sessions and lobbies can live on different nodes in production. Test: a 2-node cluster
  where a lobby member's session lives on the non-primary node, then `messaging/send {type: lobby}`; the member
  must receive the message.

## Model notes

### Open points

- A composed client must re-send `messaging/subscribeReceived` after every `user/self`: `env/reconnect` and
  `env/takeover` drop the messaging subscription (MSG-07, MSG-08, system.md INT-11).

### Coverage

| Command | Outcome | Status |
|---|---|---|
| messaging/send | success, player target | witnessed `sentOk("player")`; `dmTest`, `selfDmTest` |
| messaging/send | success, party target | witnessed `sentOk("party")`; `groupTest` |
| messaging/send | success, lobby target | witnessed `sentOk("lobby")`; `groupTest` |
| messaging/send | live delivery (event emitted) | witnessed `liveDelivery` |
| messaging/send | invalid_target (player offline) | witnessed `sentDenied("player","invalid_target")` |
| messaging/send | invalid_target (not in party) | witnessed `sentDenied("party","invalid_target")` |
| messaging/send | invalid_target (not in lobby) | witnessed `sentDenied("lobby","invalid_target")` |
| messaging/send | message_too_long | witnessed `sentDenied("player","message_too_long")` |
| messaging/send | invalid_request | unreachable: requests are schema-valid by construction; teiserver's uses are MSG-01/MSG-04 |
| messaging/send | unauthorized, internal_error, command_unimplemented | not modelled (scopes, crashes) |
| messaging/subscribeReceived | success, latest | witnessed `subscribedWith("latest")` |
| messaging/subscribeReceived | success, from_start (≥2 replayed) | witnessed |
| messaging/subscribeReceived | success, marker found, non-empty replay | witnessed |
| messaging/subscribeReceived | success, hasMissedMessages = true | witnessed `subscribedWith("marker")and(lastMissed)`; `missedTest` |
| messaging/subscribeReceived | client resumes with its own marker after reconnect | witnessed `honestResumeAfterReconnect`; `resumeTest` |
| messaging/subscribeReceived | invalid_request, unauthorized, internal_error, command_unimplemented | unreachable: the model has no failing case (MSG-16); scopes/crashes not modelled |
| messaging/received | event | covered by the send/subscribe rows |
| env/connect, env/disconnect, env/membership | – | exercised in every transcript |
| env/reconnect, env/takeover, env/sessionExpired | – | witnessed (`lastCmd==...`) |
| buffer overflow | – | witnessed `bufferOverflowed`; `missedTest` |

### Seeded mutations

All were run against the file and then reverted (the file was compared against a saved copy).

| # | Mutation (one line) | Caught by |
|---|---|---|
| M1 | party recipients include the sender (`v != u` → `true`) | `noEchoToSender`, `sendRecipientsExact` (safety run); `groupTest` |
| M2 | marker replay includes the marker message (`slice(i + 1, …)` → `slice(i, …)`) | `noDuplicateAfterMarker`; `resumeTest`, `missedTest` |
| M3 | buffer never drops (`>= BUF_CAP` → `>= BUF_CAP + 10`) | `bufferBounded`; `resumeTest`, `missedTest` |
| M4 | live events also to connected but unsubscribed recipients | `nothingBeforeSubscribe`, `sendRecipientsExact`; `dmTest`, `resumeTest` |
| M5 | `takeover` keeps `subscribed` (teiserver's behaviour, MSG-07) | `nothingBeforeSubscribe` (client-side `sub` flag); `resumeTest` |

M5 was not caught by the first draft, whose invariant used only the server's flag. The client-side
`sub` ghost was added to catch it.

### Cross-module interface

Predicates over this module's state `s` for a user `u`:

- Session (session.qnt). This module uses the same names and preconditions as session.qnt:
  - `online(s,u)` ⇔ session.qnt `online(u)` (attached or detached).
  - `sess(s,u).connected` ⇔ `attached(u)`.
  - Steps: `env/connect` (¬online → attached), `env/disconnect` (attached → detached),
    `env/reconnect` (detached → attached), `env/takeover` (attached → attached with a new socket),
    `env/sessionExpired` (detached → offline). session.qnt's `system/disconnect` corresponds to
    `disconnect` followed by `sessionExpired` here.
  - Requests are issued only while attached.
  - Assumed: the messaging buffer and subscription belong to the session, the buffer survives
    reconnect and takeover, and the subscription does not (MSG-08). Unlike user subscriptions
    (SESSION-05), messaging needs an explicit resubscribe after every `user/self`.
- Lobby (lobby.qnt). `lobbyOf(s,u) = l ≠ 0` ⇔ lobby.qnt `inLobby(u) ∧ lobbyOf(u) = l`, where the
  members are players plus spectators (bots excluded). `env/membership` is this module's view of
  every lobby join, leave or kick. Assumed: `inLobby(u) ⇒ online(u)` (lobby.qnt `env/sessionExpired`
  removes the user), and at most one lobby per user.
- Party (party.qnt I5). `partyOf(s,u) = p ≠ 0` ⇔ `u ∈ members(p)`, with invitees excluded. Assumed:
  `u ∈ members(p) ⇒ presence(u) ≠ Offline`, and at most one party per user. Detached members keep
  their membership and receive party messages into their buffer.
- Guaranteed to others: `messaging/send` and `subscribeReceived` change no lobby, party or session
  state apart from the messaging buffer and subscription flag.

### Integration changes

Made by the integration step (findings/system.md, decisions INT-D1..D5):

- No model change: this module already uses the INT-D1 vocabulary (`env/takeover` keeps the session).
- The subscription rule (dropped on disconnect, reconnect and takeover, ASSUMPTION MSG-A9) is kept by
  system.qnt (`msgSubSocketBound`). Tachyon does not say it (MSG-08), so system.md lists it as an
  assumption the composition depends on (INT-D1 note), not as protocol.
- Interface text updated for the lobby step rename.
