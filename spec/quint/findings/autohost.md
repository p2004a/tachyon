# Autohost + battle: findings

## Scope

`autohost.qnt` models the server<->autohost protocol together with the two
server->user battle messages. In this group the **server is the requester and
the autohost the responder**, so both sides are modelled:

- **Server**: battles (`PStarting | PRunning | PEnded | PFailed | PLost`), a kill
  obligation per battle (`mayRun`: the autohost may still run an engine for it),
  the start timer, start attempts, per-battle idempotency time (`lastTime`),
  per-player finished reports and the result. For each autohost it also keeps
  the connection state (`Down | Handshaking | Up`), the subscription, the last
  `autohost/status` (maxBattles, currentBattles, availableEngines) and `acked`,
  the greatest update time applied.
- **Autohost**: running engines, installed and installing engines, a clock,
  the buffered update log (never trimmed), the subscription and the delivery
  cursor (`since`).
- **Channel**: requests and responses in flight on the one connection. All of
  them are lost on disconnect.

Requests (server->autohost): `autohost/start`, `kill`, `addPlayer`, `kickPlayer`,
`mutePlayer`, `specPlayers`, `sendCommand`, `sendMessage`, `installEngine`,
`subscribeUpdates`. Each one has a server "send" step (`env/requestBattle`,
`env/retryStart`, `env/sendKill`, `env/sendAddPlayer`, `env/sendSimple`,
`env/sendInstall`, `env/connect`), an autohost handling step (`env/ahHandle`)
and a server receive step whose `lastCmd` is the command id and whose
`lastReply` is the autohost's reply. When a request is valid, the autohost's
answer is a nondeterministic choice among `ok`, `internal_error` and
`command_unimplemented`. The specific reasons are forced by its state:
`battle_already_exists`, `engine_version_not_available`, and `invalid_request`
for a battle it does not run. Events (autohost->server): `autohost/status`, and
`autohost/update` with the kinds start, finished, player_left, engine_quit and
engine_crash. Server->user: `battle/start` (a request; the user's answer is
`battle/start`) and `battle/ended`.

Environment steps: connect/disconnect, start timeout, grace expiry, engine
events, engine installed.

Abstracted away: start-script contents (only the players, spectators and
engine are kept), ips/port/passwords, chat, luamsg, engine_message and
engine_warning (no server effect), player_joined/defeated, autohost process
restarts (its engines dying with it), message ids, durations.

Instances:
- `autohost_test`: 3 users, 1 autohost, battle ids {1, 2}, engines {e1, e2}
  (e1 installed), teams {0, 1}, MAX_BATTLES = 1, starts disconnected. It holds
  the 13 transcripts and the subscribeUpdates witnesses.
- `autohost_up`: the same, but starts connected and subscribed. Most witnesses
  run here.
- `autohost_two`: 2 autohosts, 3 battle ids.
- `autohost_small`: for Apalache.

`CHURN = 3` makes a disconnect 1 pick in 4, so simulation goes deep.
Simulation takes only steps that have an effect (`go`). Late and no-op fires
are covered by the transcripts.

Checked: `./check.sh autohost.qnt` gives 59 result lines, all `ok` (60 with `VERIFY=1`): typecheck,
1 test module with 13 transcripts, `safety` on 3 instances (20000/20000/10000
samples × 30 steps), and 54 witnesses. It takes about 8 min, because each
witness needs about 1–10 s of deep random search. Extra runs: 2 × 60000
samples × 40 steps on `autohost_up` found no violation. Apalache: see the end
of this file.

## Findings

### AH-01: The autohost session dies with its connection; no grace, the battle is dropped after 100 ms with no kill and no battle/ended
- Kind: Divergence-teiserver
- Evidence:
  - teiserver lib/teiserver/autohost/session.ex:2-5 "a process tied to a autohost connection in such a way that it survives if the connection goes away". But :120-121 `Process.link(conn_pid)` / `Process.flag(:trap_exit, true)` and :266-272 `{:EXIT, from, reason}` -> `{:stop, reason}`: the session stops with the connection. The `data.conn_pid == nil` guards (:150, :170, :189, :203) are dead code.
  - lib/teiserver/tachyon_battle/battle.ex:155-159 "the timeout is absurdly short because there is no real recovery if the autohost goes away", `autohost_timeout: Map.get(args, :autohost_timeout, 100)`. :311-320: on DOWN, a timer, then `{:stop, :normal, state}`. No `end_tachyon_match`, no `notify_battle_ended`, no kill.
  - Design default: battles survive an autohost disconnect for a grace period, and the server kills dropped battles on reconnect.
- Spec choice: `disconnect` keeps PRunning battles and `graceExpired` makes them PLost with battle/ended. `noForgottenBattles` is in `safety`: every engine an autohost runs is a battle the server still tracks with `mayRun`. teiserver breaks it: after the 100 ms the engine keeps running and nothing tracks it.
- To verify: a teiserver test that disconnects the autohost for longer than `autohost_timeout`, reconnects it, and expects `autohost/kill`.

### AH-02: On (re)connect teiserver subscribes from "now", so updates buffered during a disconnect (finished, engine_quit) are never requested
- Kind: Divergence-teiserver
- Evidence:
  - tachyon docs/schema/autohost.md:2176 "Autohost will send all updates with time > since (not >= but >)".
  - teiserver session.ex:125-127: a fresh `SessionData` (empty `active_battles`) then `:subscribe_updates`. :362-380 `get_subscription_start` takes the min over `active_battles`, which is always empty at that point, so `Enum.min(fn -> DateTime.utc_now() end)`. test/teiserver/autohost/autohost_test.exs:65 "default subscribe messages from now".
  - The `since` is the **server's** clock, while the update times are the autohost's ("Each timestamp is guaranteed to be unique for a given autohost", autohost.md:2322). Clock skew skips updates or resends them.
- Spec choice: `connect(s, h, since)` with `since ≤ acked(h)`, the greatest autohost time applied (AH-A05). Transcript `resendTest`.
- To verify: persist `acked` per autohost across connections, or say in the protocol that `since` is an autohost time the server has seen.

### AH-03: Updates for battles the session does not know are dropped, and kill is refused for them
- Kind: Divergence-teiserver
- Evidence:
  - session.ex:296-307 "TODO: will need to "resurrect" a battle ... But for now, just drop the message".
  - session.ex:192-194 `kill_battle` returns `{:error, :invalid_battle}` when the battle is not in `active_battles`. The same check is at :179-180 (send_message) and :206-208 (add_player).
  - So after AH-01 or AH-04 the server can neither see nor kill an orphaned engine.
- Spec choice: the server keeps the kill obligation (`mayRun`) for every dropped battle. `canSendKill` is enabled for it while the autohost is connected (`droppedKillable`). An engine_quit/crash for a dropped battle clears the obligation (`deliverUpdate`, non-running branch).
- To verify: protocol owners: should an update for an unknown battleId trigger `autohost/kill`? (`autohost/status` has no battle ids, AH-13.)

### AH-04: A late autohost/start success after the server's 5 s call timeout leaves a zombie engine
- Kind: Divergence-teiserver
- Evidence:
  - session.ex:41-52 `:gen_statem.call(..., @default_call_timeout)` (5000 ms). It catches only `{:noproc, _}`, so a timeout exit crashes `Battle.init` (battle.ex:170-186).
  - The transport keeps the request pending with `timeout = Keyword.get(opts, :timeout, :timer.seconds(10_000))` (lib/teiserver/tachyon/transport.ex:390). That is 10 000 **seconds**, probably meant to be 10 s.
  - When the response arrives, `battle_started` (session.ex:382-401) puts the battle into `active_battles` and replies to a caller that is gone. The DOWN of the dead battle process (session.ex:247-264) may already have been handled, so the entry is never removed. No kill is sent, and `find_autohost` load accounting is off.
- Spec choice: `startTimeout` -> PFailed with `mayRun` kept (AH-A02). A late `Ok` emits nothing, and the server kills (transcript `lateSuccessTest`, witness `lateStartKilled`).
- To verify: a test where the autohost answers `autohost/start` after 5 s and the server is expected to send `autohost/kill`.

### AH-05: No retry of autohost/start, and no kill-and-fail on battle_already_exists
- Kind: Divergence-teiserver
- Evidence:
  - tachyon docs/schema/matchmaking.md:14 "If the autohost doesn't respond quickly, or if it sends a failed response, the server should repeat this step."
  - session.ex:40 "TODO: there should be some kind of retry here". matchmaking/pairing_room.ex:143-157: on `{:error, reason}` it disbands and sends `matchmaking/lost`, with no other autohost tried. tachyon_lobby/lobby.ex:1078-1081: the error goes back to the lobby caller.
  - `battle_already_exists` and `engine_version_not_available` are only passed on as strings (autohost/tachyon_handler.ex:238-244). No test sends `battle_already_exists`.
  - Design: a retried start answered `battle_already_exists` -> kill-and-fail; matchmaking retries on another autohost.
- Spec choice: `retryStart` (same battle id, same autohost) and `onResponse`: `battle_already_exists` -> PFailed with the kill obligation kept. A retry on another autohost is a new battle (`requestBattle`) and is the matchmaking/lobby module's choice. Transcript `retryAlreadyExistsTest`.
- To verify: protocol: does "repeat this step" reuse the battleId? That decides whether `battle_already_exists` can happen at all; with fresh UUIDs per attempt (teiserver tachyon_battle.ex:47) it cannot.

### AH-06: teiserver chooses an autohost only from the last status, with no load accounting between status events
- Kind: Divergence-teiserver
- Evidence: lib/teiserver/autohost.ex:54-61 `Enum.find(fn %AT.Overview{max_battles: m, current_battles: c} -> m > c end)`. Two starts before the next `autohost/status` both pass. Nothing counts pending starts (`pending_battles` in types/session_data.ex is never used).
- Spec choice: `canRequest` requires `max(serverLoad, reported currentBattles) < reported maxBattles`, where `serverLoad` counts Starting/Running battles and battles with a kill obligation (AH-A07). `withinCapacity` (an autohost never runs more than MAX_BATTLES) is in `safety`; mutation M3 shows that the status-only rule breaks it.
- To verify: protocol: may the autohost refuse a start when full, and with which reason? The schema only allows `internal_error` (AH-13).

### AH-07: availableEngines is ignored, and installEngine, kickPlayer, mutePlayer, specPlayers and sendCommand are never sent
- Kind: Divergence-teiserver
- Evidence:
  - autohost/tachyon_handler.ex:174-186 reads only `maxBattles`/`currentBattles` from `autohost/status`. autohost.ex:50-55 "search params (none for now)".
  - `grep -rn "installEngine\|kickPlayer\|mutePlayer\|specPlayers\|sendCommand" lib` finds nothing. `handle_response` handles only start/sendMessage/kill/addPlayer (tachyon_handler.ex:231-232).
  - The result is `engine_version_not_available` -> `matchmaking/cancelled(server_error)` (test/teiserver_web/tachyon/matchmaking_test.exs:959-990).
- Spec choice: the server may pick any engine (that is why `engine_version_not_available` exists) and may call `installEngine`. A later `status` reports the new engine (transcript `engineMissingTest`).
- To verify: should the server pick only autohosts whose `availableEngines` contain the engine? Tachyon is silent (Gap).

### AH-08: The battle result is a majority of the reporters, not of the players
- Kind: Divergence-teiserver
- Evidence:
  - schema/autohost/update/event.json:32 "The battle finished, generated once per every single player reporting who won."
  - teiserver battle.ex:379-393: `min_required_votes = (finished_reports |> Map.keys() |> Enum.count()) / 2`. A single report out of 8 players decides the result. battle.ex:48 "this majority voting won't work for 1v1s".
  - Design: per-player reports -> one result by majority, else none.
- Spec choice: `majority(b, TEAMS)` takes a strict majority over `b.players`; otherwise there is no result (-1). Transcript `noMajorityTest`.
- To verify: protocol owners: the majority of which set? 1v1: two disagreeing reports -> none.

### AH-09: The battle process has no idempotency by update time; the session's ack handler corrupts its state on an unexpected ack
- Kind: Divergence-teiserver
- Evidence:
  - battle.ex:257-307 applies every update. A resent `start` calls `Battle.start_tachyon_match` again (:263-265). This is latent while AH-02 prevents resends.
  - session.ex:337-349: in the `{:empty, _queue}` branch the `update_in` callback returns `data` (the whole `SessionData`) as the battle's `BattleData`. The next ack for that battle then fails the `%AT.BattleData{}` match. An ack that is not the head of the queue raises `CaseClauseError` and crashes the session (and the linked connection).
- Spec choice: `deliverUpdate` drops `n.time <= b.lastTime` (witness `resentUpdateIgnored`). `recordedOnce` (start and result each recorded at most once) is in `safety`.
- To verify: a unit test: ack with an empty queue, then another ack.

### AH-10: On Lost or timeout teiserver sends a placeholder battle/ended with empty players and spectators, and never closes the match
- Kind: Divergence-teiserver
- Evidence:
  - tachyon docs/schema/battle.md:11 "Sent to all players and spectators involved in a battle when it ends." The schema requires `players`, `spectators` and `winningAllyTeamIds`.
  - teiserver player/session.ex:1661-1674: on the battle DOWN, "TODO We don't have the battle state at this point so sending just sending a placeholder event", with `players: [], spectators: []`.
  - battle.ex:317-325 (`:autohost_timeout`, `:battle_timeout`) stops without `Battle.end_tachyon_match`. On the normal end (:278-290) it sends to `state.participants` (players, spectators and added users), which matches.
- Spec choice: `graceExpired` sends battle/ended to all participants with the majority result so far (AH-A03). `battleEndedRecipients` is in `safety`.
- To verify: send the real roster from the battle process before it stops.

### AH-11: The user's battle/start answer is ignored, and bar-lobby answers internal_error when assets are missing
- Kind: Gap / Divergence-bar-lobby
- Evidence:
  - battle.md:216-217: the response allows `internal_error`, `unauthorized`, `invalid_request` and `command_unimplemented`. Nothing says what the server does with a failure.
  - teiserver player/tachyon_handler.ex:176-179 `{:request, "battle/start", data, [], state}` has no cb_state, and the player handler has no `handle_response`, so transport.ex:257-264 returns `{:ok, state}`.
  - bar-lobby src/main/tachyon/tachyon.handlers.ts:52-63: when game, map or engine is missing it returns `{ status: "failed", reason: "internal_error" }` after an alert.
- Spec choice: `userStartReply` removes the pending request and changes nothing (AH-A10). The user stays a participant and gets battle/ended.
- To verify: protocol: is a failed battle/start a "left" (player_left), or should the server addPlayer/kick? A specific reason (e.g. `missing_assets`) would help.

### AH-12: Updates do not identify the engine instance, so after a retried start an engine_quit is ambiguous (found by the model)
- Kind: Gap
- Evidence:
  - schema/autohost/update/event.json: an update carries `battleId`, `time` and `update` only. The `autohost/start` success carries `ips` and `port`, with no time or instance id.
  - Simulation found this trace: start 1 runs, the connection drops before the answer, reconnect, engine 1 quits (its engine_quit is buffered), the server retries the start, it times out, the autohost starts engine 2 and the late Ok arrives. Then engine 1's engine_quit is delivered, and the server cleared its kill obligation while engine 2 runs. With an Ok retry the server ends a PRunning battle that is still running.
- Spec choice: an engine_quit/crash clears the kill obligation only if exactly one start was ever sent (`b.attempts == 1`). Otherwise the server keeps it and a kill confirms (`Ok` or `invalid_request`). See `deliverUpdate` and the `wellFormed` relaxation. Mutation M7 restores the bug.
- To verify: protocol: add the autohost time to the `autohost/start` success response, or require a fresh battleId per attempt.

### AH-13: autohost/status has no battle ids, and autohost/start has no "full" reason
- Kind: Gap
- Evidence: schema/autohost/status/event.json requires only `maxBattles`, `currentBattles` and `availableEngines` (known gap, design). The autohost/start reasons are `battle_already_exists`, `engine_version_not_available` and the generic ones (autohost.md "Possible Failed Reasons").
- Spec choice: reconciliation after a reconnect uses resent updates plus kills of every battle with an obligation. A full autohost would have to answer `internal_error`; the model's autohost never needs to, because the server respects capacity (AH-A07).
- To verify: add the running battle ids to status, and a `capacity_reached` reason.

### AH-14: What a successful autohost/kill means is unspecified
- Kind: Gap
- Evidence: autohost.md:527 "Request to kill a battle." teiserver battle.ex:216-219 "I believe it should happen when, after closing the engine, autohost should send :engine_quit message (or something similar)".
- Spec choice: kill Ok = the engine is gone, and the autohost logs `engine_quit` (AH-A08). A kill of an unknown battle -> `invalid_request` (AH-A04). Both clear the obligation.
- To verify: protocol: is engine_quit (or engine_crash) guaranteed after a kill? A kill of a battle that already ended: success or invalid_request?

### AH-15: The update stream: timestamps are unique but not monotone; retention and pre-subscription behaviour are unspecified
- Kind: Gap
- Evidence: autohost.md:2322 "Each timestamp is guaranteed to be unique for a given autohost". The `> since` semantics (:2176) only works if times increase. The protocol does not say how long updates are buffered, or whether updates flow before `subscribeUpdates`.
- Spec choice: strictly increasing per autohost, never trimmed, delivered only after a successful subscribe on the current connection and after `status`, in order, never ahead of their battle's start response (one FIFO socket) (AH-A05, AH-A06, AH-A11).
- To verify: protocol text.

### AH-16: battle-scoped requests for a battle the autohost does not run
- Kind: Assumption (AH-A04)
- Evidence: kill, addPlayer, kickPlayer, mutePlayer, specPlayers, sendCommand and sendMessage allow only the generic reasons (schema.qnt). teiserver decides this locally with `{:error, :invalid_battle}` (session.ex:179-180, 193-194, 207-208) and never asks the autohost.
- Spec choice: `invalid_request` (witnessed for all 7 commands).
- To verify: protocol owners.

### AH-17: Wording: battle/start is called a response; matchmaking names commands that do not exist
- Kind: Contradiction
- Evidence: battle.md:221 "When a user client receives this response it should launch the game", but it is a Request. matchmaking.md:14-15 "[autohost/battleStart]" and "[battle/battleStart]"; the ids are `autohost/start` and `battle/start`.
- Spec choice: `battle/start` is a server->user request whose answer the server ignores.
- To verify: fix the docs.

### AH-18: The ally team id types differ between autohost/update and battle/ended
- Kind: Contradiction
- Evidence: schema/autohost/update/event.json `finished.winningAllyTeams`: `"items": {"type": "integer"}`, `minItems: 1`. battle/ended `winningAllyTeamIds`: `"items": {"type": "string"}`. `allyTeam`/`team`/`player` are strings, while autohost/start's `allyTeams` is a positional array. teiserver converts with `to_string` (player/tachyon_handler.ex:1343-1361) and uses array indices as ids (battle.ex:328-331).
- Spec choice: teams are ints in the model.
- To verify: protocol: one id type, and the explicit ids in the start script.

### AH-19: battle/start is not always delivered to all the battle's users
- Kind: Divergence-teiserver
- Evidence:
  - player/session.ex:1337-1366: the session ignores `{:battle, {:start, ...}}` unless the user is readied in a matchmaking pairing or in a lobby ("the request is ignored").
  - session.ex:1910-1918 `send_to_player`: "TODO tachyon_mvp: what should server do if the connection is down at that time?" If the user is disconnected, the request is not sent or stored. It is recovered only through `user/self` `currentBattle` (bar-lobby tachyon.store.ts:68).
  - Recipients match the spec: matchmaking sends to the start-script players (matchmaking/pairing_room.ex:172-176; there are no spectators); the lobby sends to its players and spectators (tachyon_lobby/lobby.ex:1051-1053, start script :1603-1606).
- Spec choice: battle/start goes to exactly the start-script users (players ∪ spectators) on `autohost/start` Ok, and to the added user on `autohost/addPlayer` Ok (`battleStartRecipients`, AH-A01).
- To verify: protocol: should the battle drop users whose session refused or missed battle/start?

### AH-20: Interface with lobby.qnt: joinBattle answers before or after autohost/addPlayer
- Kind: Contradiction (between spec modules) / Assumption
- Evidence:
  - lobby.qnt:594-602 `joinBattle(s, u, full)`: Ok and `BattleStart` to the joiner in one step, where `full` is "the battle's answer (autohost side)".
  - teiserver lobby.ex:597-626 calls `TachyonBattle.add_player` synchronously (5 s call through the battle and autohost session) and replies Ok only after it succeeds. `capacity_reached` is decided locally at 254 participants (battle.ex:233-236), and autohost/addPlayer has no "full" reason.
  - lobby.qnt `autohostStarted`/`autohostFailed`/`battleEnded` match this module's `autohost/start` Ok, PFailed, and PEnded/PLost; battle/start goes to `members(l)` = players ∪ spectators, the same as AH-A01.
- Spec choice: they compose if lobby `joinBattle` Ok (full = false) ⇔ `autohost/addPlayer` Ok here. `battle_full` is a server-side (lobby or battle) check before addPlayer, not an autohost answer. An addPlayer failure (internal_error, …) has no lobby/joinBattle reason other than `internal_error`.
- To verify: orchestrator: map lobby `joinBattle(full=false)` to `sendAddPlayer` + `autohost/addPlayer` Ok.

### AH-21: bar-lobby consumption of battle/start and battle/ended
- Kind: Divergence-bar-lobby (minor)
- Evidence:
  - src/main/tachyon/tachyon.handlers.ts:42-50 uses only `ips[0]`, and accepts a legacy `data.ip` ("backward server compatibility").
  - src/renderer/store/battleHistory.store.ts:18-19 deduplicates battle/ended by `battleId` (robust to resends). The AH-10 placeholder is stored as a history entry with no players.
  - src/renderer/store/lobby.store.ts:282 "there's a chance that the client could have the connection details but no longer be a player/spectator and not receive the event": it clears the state on `currentBattle == undefined`.
- Spec choice: none (client side). These are consistent with at-most-once battle/ended per battle.
- To verify: bar-lobby test with an empty-roster battle/ended.

### Assumptions (referenced from the model)
- **AH-A01** (`onResponse`, start): battle/start goes to the start-script players ∪ spectators, plus users added with addPlayer.
- **AH-A02** (`startTimeout`): a timed-out start fails the battle id but keeps the kill obligation.
- **AH-A03** (`graceExpired`): a Lost battle sends battle/ended with the majority result so far (usually none).
- **AH-A04** (`ahHandle`): a battle-scoped request for a battle the autohost does not run -> `invalid_request`. `unauthorized` is never answered (the server has every role), and `invalid_request` is not used for schema-valid start/installEngine/subscribeUpdates.
- **AH-A05** (`connect`, `deliverUpdate`): the server may subscribe with any `since ≤ acked`, and drops updates with `time ≤ lastTime` of their battle.
- **AH-A06** (`disconnect`): engines keep running and keep logging while the autohost is disconnected from the server.
- **AH-A07** (`canRequest`): admission uses the server's own count, as well as the reported currentBattles.
- **AH-A08** (`ahHandle`, kill): a killed engine logs `engine_quit`.
- **AH-A09** (`onResponse`, subscribeUpdates): a failed subscribe drops the connection (teiserver session.ex:134-137).
- **AH-A10** (`userStartReply`): the server ignores the user's battle/start answer.
- **AH-A11** (`canDeliver`): updates flow only when the connection is Up (status received) and subscribed, in time order, and never ahead of their battle's start response.
- **AH-A12** (`disconnect`/`graceExpired`): a PRunning battle on a disconnected autohost stays PRunning until grace expiry; a PStarting one stays PStarting until its timer or a retry.
- **AH-A13** (`onResponse`): a failed start sends no battle/ended (users never got battle/start). The requester (lobby/matchmaking) learns from the phase.

### Per-command implementation check

| command | teiserver | bar-lobby |
|---|---|---|
| autohost/start | sent from lobby/matchmaking via `TachyonBattle.start_battle` with a fresh UUID. Errors are passed on and there is no retry (05). 5 s vs 10 000 s timeouts (04). Capacity from status only (06) | — |
| autohost/kill | only for battles in `active_battles` (03). The server does not change the battle on Ok and waits for engine_quit (battle.ex:216-219, 14). Sent on chat `!stop` (battle.ex:299-301) | — |
| autohost/addPlayer | synchronous from lobby/joinBattle. 254 cap decided locally. An existing participant gets Ok without a request (battle.ex:227-231) (20) | — |
| kickPlayer / mutePlayer / specPlayers / sendCommand | never sent (07) | — |
| sendMessage | sent; `invalid_battle` decided locally (16) | — |
| installEngine | never sent (07) | — |
| subscribeUpdates | sent at session start with since = now (02). Failure stops the session (A09 ✓) | — |
| autohost/status | must be the first message, or the connection is closed (tachyon_handler.ex:188-206 ✓). Only max/current are used (07) | — |
| autohost/update | all kinds parsed (tachyon_handler.ex:288-395). Unknown battle dropped (03). No dedup (09). Majority over reporters (08) | — |
| battle/start | to start-script users ✓ (19). Answer ignored (11). Not buffered while disconnected (19) | launches the game. internal_error on missing assets (11). ips[0] only (21) |
| battle/ended | participants on engine_quit/crash ✓. Placeholder on Lost/timeout (10) | dedup by battleId ✓. Clears rejoin (21) |

## Coverage

Witnesses run on `autohost_up` unless noted. "witnessed" = a `// @witness` line passes in check.sh.

| command | Ok | battle_already_exists | engine_version_not_available | invalid_request | internal_error | command_unimplemented | unauthorized |
|---|---|---|---|---|---|---|---|
| autohost/start | witnessed | witnessed (retry after lost answer) | witnessed | unreachable: the server sends schema-valid requests (A04) | witnessed | witnessed | unreachable: the server holds every role |
| autohost/kill | witnessed | — | — | witnessed (not running) | witnessed | witnessed | unreachable |
| autohost/addPlayer | witnessed | — | — | witnessed | witnessed | witnessed | unreachable |
| autohost/kickPlayer | witnessed | — | — | witnessed | witnessed | witnessed | unreachable |
| autohost/mutePlayer | witnessed | — | — | witnessed | witnessed | witnessed | unreachable |
| autohost/specPlayers | witnessed | — | — | witnessed | witnessed | witnessed | unreachable |
| autohost/sendCommand | witnessed | — | — | witnessed | witnessed | witnessed | unreachable |
| autohost/sendMessage | witnessed | — | — | witnessed | witnessed | witnessed | unreachable |
| autohost/installEngine | witnessed | — | — | unreachable (A04) | witnessed | witnessed | unreachable |
| autohost/subscribeUpdates (`autohost_test`) | witnessed | — | — | unreachable (A04) | witnessed | witnessed | unreachable |
| battle/start (user's answer) | witnessed | — | — | witnessed | witnessed | witnessed | unreachable: a user does not check the server's role |

Events and effects: autohost/update `start`, `finished`, `player_left`, `engine_quit` and `engine_crash` are each witnessed (`updateSeen`). A resent update dropped by idempotency is witnessed (`resentUpdateIgnored`), and so are an ended battle with a winner (`endedWithWinner`), Lost + battle/ended (`battleLost`), a late start killed (`lateStartKilled`), and autohost/status reporting maxBattles 0 below currentBattles (`statusDraining`). Both autohosts busy is witnessed on `autohost_two` (`twoHostsBusy`). battle/start and battle/ended recipients are checked by `safety` and by the transcripts `happyPathTest`, `addKickTest` and `graceLostKillTest`.

## Seeded mutations

Each mutation was applied alone, run with `./check.sh` (or the named check), then reverted.

| # | mutation (one line) | caught by |
|---|---|---|
| M1 | `canRequest`: `max2(serverLoad(s, h), s.hosts.get(h).current) <` -> `s.hosts.get(h).current <` (teiserver AH-06) | `safety` on autohost_up and autohost_two (checked: `withinCapacity` alone fails) |
| M2 | `onResponse` start failure: `keep = r.reply == Failed("battle_already_exists") or b.attempts > 1` -> `keep = false` | `safety` on autohost_up and autohost_two; transcript `retryAlreadyExistsTest` |
| M3 | battle/start only to players: `val us = participants(b)` -> `val us = b.players` | transcript `happyPathTest`; `safety` (`battleStartRecipients`) on both instances |
| M4 | `deliverUpdate`: process Lost battles as running: `else if (b.phase == PRunning)` -> `else if (b.phase == PRunning or b.phase == PLost)` | `safety` (both instances); transcript `graceLostKillTest` |
| M5 | `requestBattle`: `startTimer: true` -> `startTimer: false` | `safety` (`startingResolvable`) on both instances; transcripts `lateSuccessTest`, `killUnknownTest` |
| M6 | idempotency off: `if (n.time <= b.lastTime)` -> `if (false)` | transcript `resendTest` (`dupIgnored == 1`) and witness `resentUpdateIgnored`. `safety` alone does NOT catch it: resends are harmless today because `started` is guarded and ended battles leave the PRunning branch |
| M7 | revert AH-12: `mayRun: b.attempts > 1` -> `mayRun: false` at engine end | transcript `instanceAmbiguityTest`. Random `safety` found it once (that is how AH-12 was found), but missed it in 2 × 20000 samples, so the transcript was added |

## Cross-module interface

What this module assumes about other groups' state, as predicates:

- `requestBattle(id, h, players, specs)` is called by lobby (`lobby/startBattle` accepted) or matchmaking (all ready). Precondition: `∀u ∈ players ∪ specs: ¬inLobbyBattleElsewhere(u) ∧ ¬queued(u) ∧ u ∉ activeUsers(s)`. This module enforces only the last conjunct; the activity slot owner (session/lobby/matchmaking) must enforce the rest.
- `autohost/start` Ok for battle `id` ⇒ lobby `env/autohostStarted(lobbyOf(id))` / matchmaking `env/battleStarted`. The battle/start recipients are the same set (`players ∪ spectators` = lobby `members(l)`; matchmaking `matchMembers(m)`, no spectators).
- `phase(id) = PFailed` ⇒ lobby `env/autohostFailed` / matchmaking `env/startFailed` (which may call `requestBattle` again with a fresh id, possibly on another autohost, matchmaking.md:14).
- `phase(id) ∈ {PEnded, PLost}` (battle/ended sent) ⇒ lobby `env/battleEnded` and the users' activity slot is freed: `∀u ∈ participants(id): ¬inBattle(u)`.
- `sendAddPlayer(id, u)` is called by lobby `joinBattle` when `u ∈ members(lobby) ∧ u ∉ participants(id)`. Lobby `joinBattle` Ok ⇔ `autohost/addPlayer` Ok (AH-20).
- The user's session must be able to receive battle/start, i.e. the user is connected or recovers it through `user/self.currentBattle` (session module).
- Autohost identities: an autohost is a bot account (authorization.md "Client Credentials Grant") with exactly one connection. The user/session modules never see it.

## Requests to the orchestrator

- Lobby module: please note AH-20. `joinBattle`'s `full` flag is not an autohost answer; an addPlayer failure maps to `internal_error`.
- Matchmaking module: AH-05/AH-12. If "repeat this step" reuses the battleId, `battle_already_exists` and the engine-instance ambiguity apply. Recommend a fresh battleId per attempt.

## Apalache

`JVM_ARGS=-Xmx6G quint verify --main=autohost_small --invariant=safety --max-steps=3`
(2 users, 1 autohost, 1 battle id, 1 engine, starting connected) passes in
about 57 s (`--max-steps=2`: 51 s). The directive is `steps=3`. Three steps from
the connected state reach a running battle (request, autohost handling, Ok
response), but not the reconnect scenarios. Those are covered by simulation and the transcripts.
