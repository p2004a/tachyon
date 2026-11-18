# Findings: lobby (`lobby.qnt`)

## Scope

`lobby.qnt` models all 25 lobby commands and events. The 20 requests are create, join, leave, joinAllyTeam, spectate, joinQueue, updateClientStatus, addBot, removeBot, updateBot, update, appointBoss, unboss, kickban, voteSubmit, voteCancel, startBattle, joinBattle, subscribeList and unsubscribeList. The 5 events are updated, left, voteEnded, listUpdated and listReset. It also models eight environment steps:

- `env/voteTimeout`: the vote timer fires.
- `env/autohostStarted` and `env/autohostFailed`: the autohost answers a start request.
- `env/battleEnded`
- `env/sessionExpired` (was `env/sessionEnded`): the session grace period runs out (no-op while the user plays in the lobby's battle, INT-D2).
- `env/lobbyCrashed`
- `env/banExpired`
- `env/otherActivity`: another module puts the user into, or takes them out of, matchmaking or a non-lobby battle.

The server->user `battle/start` request is the event `BattleStart`.

**What the model covers:**
- **Membership.** Players sit in ally teams with packed slots. Spectators are listed separately. The join queue is the set of spectators with a position.
- **Bots.** Each bot has a host and takes a slot.
- **Bosses.** The `areBossesEnabled` setting is modelled.
- **Bans.** A ban lasts until `env/banExpired`.
- **Votes.** The four voteActions are modelled: start, changeMap, appointBoss and kickban. Each vote has ballots and a `voteHistory`.
- **Battle state.** A battle is NoBattle, Starting (invisible to clients) or Running.
- **List subscriptions.**

**How events are produced.** All events are derived in one place, `finish`, from the before and after states:
- lobby/updated goes to every member who stays, whenever the visible lobby changed.
- listUpdated goes to subscribers whenever the overview changed.
- voteEnded is sent when a new entry appears in the vote history.
- lobby/left goes to members who were removed and did not leave by themselves.

**What is abstracted away.** Names, maps, options and tags are small ints. Bot properties are one `config` int. lobby/update carries one property per request. Timestamps and durations are not modelled. JSON merge-patch contents are not modelled: an event only names the lobby whose state it carries. Start scripts and passwords are not modelled.

**Constants and instances.**
- `lobby_test` is the main instance: 4 users, ally teams {0,1}, capacities {1,2}, MAX_MEMBERS=3, all steps enabled.
- `lobby_votes` has 3 users, one ally team of 3 and a restricted step set, so that simulation reaches deep vote, ban and battle outcomes.
- `lobby_queue` has 3 users, one ally team of capacity 1 or 2 and MAX_MEMBERS=2, for queue promotion, reconfiguration and `lobby_full`.
- `lobby_kick` has 3 users and only create, join, joinAllyTeam, kickban and voteSubmit, for kicks decided by vote and voteSubmit from a non-voter.
- `ENABLED` limits only which steps the environment takes. The semantics are the same in every instance.

**Bounded model checking.** It is not included. Apalache (`quint verify`) ran out of its 4 GB heap at `--max-steps=3`. It ran out again at `--max-steps=2` on a 2-user instance after about 8 minutes. With `-Xmx10g` and a reduced invariant, it had not finished after 6.5 minutes. The main cost is the generic `finish` / `normalize` set comprehensions, so I left out the `@verify` directive (see Requests to the orchestrator).

## Findings

### LOBBY-01: `areBossesEnabled` defaults to false in teiserver, but the schema default is true
- Kind: Divergence-teiserver
- Evidence: tachyon docs/schema/lobby.md:549 `"areBossesEnabled": { "type": "boolean", "default": true }`. teiserver lib/teiserver/player/tachyon_handler.ex:801 `boss_enabled?: msg["data"]["areBossesEnabled"]` (this is nil when the field is omitted). lib/teiserver/player/session.ex:969 `boss_enabled?: start_params.boss_enabled? || false`. The JSV validation result is discarded (lib/teiserver/tachyon/schema.ex:73 `{:ok, _data} <- JSV.validate(json, root)`), so the default is never applied.
- Spec choice: `create(s, u, bossesEnabled, caps)` receives the effective value.
- To verify: create a lobby without `areBossesEnabled`. Under the schema, the details should show `areBossesEnabled: true` and the creator as a boss. teiserver gives false.

### LOBBY-02: teiserver collapses most schema reasons into `invalid_request`
- Kind: Divergence-teiserver
- Evidence: tachyon_handler.ex sends these to `{:error_response, :invalid_request, ...}`:
  - lobby/join `invalid_lobby_id`: the lobby returns `:invalid_lobby` (tachyon_lobby/lobby.ex:1200 `:exit, {:noproc, _reason} -> {:error, :invalid_lobby}`), and the handler maps it to invalid_request at tachyon_handler.ex:833-834.
  - lobby/leave `not_in_lobby`: tachyon_handler.ex:843-844 `{:error, reason} -> {:error_response, :invalid_request, ...}`.
  - appointBoss `not_in_lobby` / `bosses_not_allowed`: lobby.ex returns `:no_boss_allowed`, and tachyon_handler.ex:1007 maps every error to invalid_request.
  - unboss `not_in_lobby` / `not_a_boss`: tachyon_handler.ex:1022.
  - voteSubmit `not_in_lobby` / `invalid_vote_id`: tachyon_handler.ex:985-998 (all errors).
  - updateClientStatus `not_in_lobby` / `not_a_player`: tachyon_handler.ex:1034-1035.
  - startBattle `not_in_lobby`: tachyon_handler.ex:1044-1045.
  - joinBattle `not_in_lobby` / `no_battle` / `battle_full`: tachyon_handler.ex:1054-1055. The lobby returns `:invalid_battle` (lobby.ex:594).
  - kickban `not_in_lobby`: tachyon_handler.ex:1087-1088.
  - Only join (`lobby_full`, `banned`), joinAllyTeam, spectate, joinQueue, addBot, removeBot and updateBot pass the specific reasons through.
  - bar-lobby works around the leave case. src/renderer/store/lobby.store.ts:361 `if (error.reason === "not_in_lobby" || error.reason === "invalid_request") removedFromLobby = true`.
- Spec choice: every command returns the schema's specific reason (`reasonsInSchema` holds, and the witnesses show each reason is reachable).
- To verify: teiserver tests that assert the specific reasons.

### LOBBY-03: The activity slot is not enforced, and lobby battles contradict it
- Kind: Divergence-teiserver + Contradiction (design vs lobby semantics)
- Evidence:
  - The design says a user is in at most one of lobby, matchmaking queue or battle. "Queueing while in a lobby is not allowed (reply invalid_request)."
  - teiserver session.ex:952-1001 lobby create/join only check `state.lobby`, not `state.matchmaking` or `state.battle`.
  - session.ex:611 `handle_call({:matchmaking, {:join_queues, queues}}, ...)` does not check `state.lobby`.
  - Lobby semantics require a lobby member to also be in the lobby's battle. joinBattle says "Join the battle this lobby is currently playing". teiserver session.ex:1357 `%{lobby: %{id: _lobby_id}} -> ... {:joined, ...}` keeps the lobby while the user is in the battle.
- Spec choice: create/join return `invalid_request` while the user is in `elsewhere` (matchmaking or a non-lobby battle). `env/otherActivity` refuses while the user is in a lobby. Battles started from the lobby (`inBattle`) do not count as "elsewhere". Invariant `activitySlot`.
- To verify: does the activity slot exclude only matchmaking and matchmaking battles, or every battle? And should lobby/join fail while the user is queued?

### LOBBY-04: lobby/voteCancel is not implemented in teiserver
- Kind: Divergence-teiserver
- Evidence: tachyon_handler.ex has no `handle_command("lobby/voteCancel", ...)`, so the fallback at tachyon_handler.ex:1096 returns `command_unimplemented`. bar-lobby sends it: lobby.store.ts:567 `tachyonRequest("lobby/voteCancel", { id: ... })`.
- Spec choice: `voteCancel`. The initiator or a boss may cancel. Others get `invalid_request` (LOBBY-18). The vote ends with `cancelled` and voteEnded goes to all members.
- To verify: implement it in teiserver, or document it as optional.

### LOBBY-05: In a bosses-enabled lobby with no boss, nobody can lobby/update
- Kind: Divergence-teiserver
- Evidence: docs/schema/lobby.md:118 "Any member can update most (any?) property of the lobby unless bosses are present." teiserver lobby.ex:756 `is_allowed? = not fsm_data.boss_enabled? or MapSet.member?(fsm_data.bosses, user_id)`. After the last boss leaves or unbosses, every update returns "you are not a boss".
- Spec choice: `canAct(l,u) = bosses == {} or u in bosses`, so with no boss present anyone may update. Map changes go through a vote.
- To verify: a teiserver test where the creator unbosses themselves, then a member renames the lobby.

### LOBBY-06: startBattle has no boss check or vote in teiserver
- Kind: Divergence-teiserver
- Evidence: voteActions includes `{type: "start"}` (src/schema/definitions/voteActions.ts). teiserver lobby.ex:1031-1035 start_battle only checks membership and `current_battle`. Any member can start, including a spectator and including a non-boss while bosses are present. events/vote_ended.ex:122 says "`:start isn't yet supported`".
- Spec choice: `startBattle` is boss-gated and vote-gated (`gated(..., VStart, ...)`) like the other voteActions (ASSUMPTION LOBBY-A09).
- To verify: should startBattle require a boss or a vote?

### LOBBY-07: A new vote silently replaces the running vote
- Kind: Divergence-teiserver
- Evidence:
  - teiserver lobby.ex:938 (kickban) and lobby.ex:987 (appointBoss) start a vote without checking `current_vote`.
  - events/start_vote.ex:21 `data = %{agg.data | current_vote: ev.vote_state, ...}` overwrites it. The replaced vote never gets a voteEnded and never enters voteHistory.
  - Only the map change checks (lobby.ex update_property `:vote_in_progress`).
- Spec choice: one vote at a time. A request that needs a vote while one is running returns `invalid_request` (ASSUMPTION LOBBY-A11). Transcript `votesTest`.
- To verify: is a vote queue, replacement (then voteEnded with which outcome?) or refusal intended?

### LOBBY-08: The capacity of an ally team is undefined, and teiserver uses three different notions
- Kind: Gap + Divergence-teiserver (internal inconsistency)
- Evidence:
  - allyTeamConfig has `maxTeams` and `teams[].maxPlayers` (src/schema/definitions/allyTeamConfig.ts). The protocol never says how many players an ally team holds.
  - teiserver joinAllyTeam and addBot use `max_teams` (lobby.ex:524, lobby.ex:683 `ally_team_capacity = Enum.at(...).max_teams`).
  - Queue promotion uses the sum of `max_players` (lobby.ex:1399 `total_capacity = Enum.sum_by(at.teams, fn t -> t.max_players end)`).
  - UpdateAllyTeamConfig keeps a player iff `y < max_teams && z < max_players`.
  - So the queue can fill an ally team past the point where joinAllyTeam reports `ally_team_full`, or the other way round.
- Spec choice: one capacity per ally team (`caps`), shared by humans and bots. The invariant says `occupants <= cap`, and the join queue is non-empty only when every ally team is full.
- To verify: define the capacity (for example sum(teams[].maxPlayers), with maxTeams as the number of teams).

### LOBBY-09: No reason for an unknown ally team index
- Kind: Gap
- Evidence: joinAllyTeam and addBot list only `not_in_lobby` and `ally_team_full`. teiserver returns `:invalid_ally_team`, which becomes `invalid_request` (tachyon_handler.ex:859).
- Spec choice: `invalid_request`.
- To verify: add `invalid_ally_team`?

### LOBBY-10: The lobby size limit counts bots and is 251, but the design says 256 members
- Kind: Divergence-teiserver
- Evidence: the design says "A lobby holds at most 256 members (players + spectators)". teiserver lobby.ex:450 `when map_size(data.spectators) + map_size(data.players) >= 251`, where `data.players` includes bots.
- Spec choice: `MAX_MEMBERS` bounds human members (players + spectators). Bots are bounded by ally team capacity.
- To verify: decide whether bots count. 251 is the engine limit on specs + players + bots.

### LOBBY-11: Changing ally team: teiserver tells clients `isReady: false` but keeps the old server value
- Kind: Divergence-teiserver
- Evidence: docs/schema/lobby.md:104 "When a user becomes a player (at lobby creation, through `joinAllyTeam` or with the join queue), the server will automatically assign them a default status". teiserver events/move_player.ex:33 only updates `:team`, while move_player.ex:42 broadcasts `Map.merge(%{team: ev.team, ready?: false, asset_status: :complete}, p)`. A ready player who moves ally team is ready on the server but not ready on every client.
- Spec choice: `joinAllyTeam` always resets `ready` to false.
- To verify: a teiserver test with updateClientStatus(isReady=true), then joinAllyTeam to another team, then get_details.

### LOBBY-12: lobby/update has no `not_in_lobby` reason
- Kind: Contradiction (within the schema)
- Evidence: schema.qnt `"lobby/update" -> Set("command_unimplemented","internal_error","invalid_request","unauthorized")`. Every other lobby request lists `not_in_lobby`. teiserver returns `:not_in_lobby` from lobby.ex and the handler maps it to invalid_request (tachyon_handler.ex:980).
- Spec choice: `invalid_request`.
- To verify: add `not_in_lobby` to update's response schema.

### LOBBY-13: Is the creator a boss?
- Kind: Gap
- Evidence: docs/schema/lobby.md:112 "The creator of a lobby can choose to forbid bosses". Nothing says whether the creator starts as a boss. teiserver lobby.ex init `bosses = if start_params.boss_enabled?, do: MapSet.new([creator_id])`.
- Spec choice: the creator is the first boss iff bosses are enabled (ASSUMPTION LOBBY-A01).
- To verify: state it in lobby.md.

### LOBBY-14: Voters do not include a spectator initiator, contradicting "The initiator is also included"
- Kind: Contradiction (schema vs teiserver) / Divergence-teiserver
- Evidence: src/schema/definitions/currentVote.ts:18 "indexed by the userId. The initiator is also included in this object". teiserver lobby.ex:1705-1708 builds `voters` only from players. A spectator can start a kick vote (kickban has no player check), but is then not a voter.
- Spec choice: voters = players ∪ {initiator}, and the initiator's ballot is `yes` (ASSUMPTION LOBBY-A08). Invariant `voteOk`.
- To verify: may spectators start votes, and do they vote?

### LOBBY-15: kickban of a non-member is unspecified
- Kind: Gap
- Evidence: kickban only lists `not_in_lobby`, and "Ban a user from a lobby (and kick them out)". Pre-emptive bans of absent users are not covered. teiserver lobby.ex kickban returns `:invalid_request` when the target is not a member, but a *passed vote* with `ban_until` still bans a target who has left (events/vote_ended.ex `ban_until != nil ->`).
- Spec choice: a direct kickban of a non-member returns `invalid_request`. A passed ban vote still records the ban for a departed target. A passed plain-kick vote is cancelled when its target leaves.
- To verify: decide whether pre-emptive bans are allowed.

### LOBBY-16: When listReset is sent is unspecified, and subscribeList is "idempotent"
- Kind: Gap (+ bar-lobby relies on teiserver behaviour)
- Evidence: docs/schema/lobby.md:142 "In practice, this event should rarely be seen." docs/schema/lobby.md:2999 "Idempotent, subscribing multiple time has no effect." subscribeList's response has no data, so the client can only learn the initial list from an event.
  - teiserver tachyon_handler.ex:1059-1072 sends a listReset after *every* subscribeList, including repeats (session.ex:1192 `list = TachyonLobby.list()`).
  - bar-lobby lobby.store.ts:119 "this subscribes us, but does not return an updated list, that happens in the ListUpdated or ListReset events".
  - bar-lobby lobby.store.ts:71 "The server drops the list subscription when the socket dies" is inaccurate. The subscription lives in the session (session.ex:93) and survives the reconnect grace period. bar-lobby resubscribes and receives a fresh listReset only because teiserver resends it.
- Spec choice: every subscribeList answers Ok and sends a listReset to the caller (ASSUMPTION LOBBY-A02). A subscription ends with unsubscribeList or `env/sessionExpired`.
- To verify: state "subscribeList is always followed by lobby/listReset", and say whether reconnecting keeps the subscription.

### LOBBY-17: listUpdated is batched and its playerCount is inconsistent
- Kind: Divergence-teiserver
- Evidence:
  - session.ex:1187 `:timer.seconds(5) |> :timer.send_interval(:flush_lobby_list_updates)`: changes reach subscribers up to 5 seconds late, coalesced. This is allowed but not stated.
  - lobby.ex:1211 `player_count: map_size(state.players)` counts bots.
  - lobby.ex:1337 `Enum.count(data.players, fn {_id, p} -> not LBot.bot_id?(p.id) end)` does not count bots.
  - The two paths report different playerCount for the same lobby.
- Spec choice: playerCount = occupied slots, humans plus bots (ASSUMPTION LOBBY-A12). The model sends listUpdated in the same step (`listComplete` invariant), and batching is a refinement.
- To verify: define playerCount, and document that listUpdated may be delayed or coalesced.

### LOBBY-18: No reason for "not eligible" (voteSubmit by a non-voter, voteCancel by a non-initiator)
- Kind: Gap
- Evidence: voteSubmit and voteCancel list only `invalid_vote_id` and `not_in_lobby`. docs/schema/lobby.md:127 "The protocol does not define who is eligible to vote". teiserver returns `:invalid_vote` (→ invalid_request) for a non-voter.
- Spec choice: `invalid_request` for both.
- To verify: add `not_eligible`?

### LOBBY-19: Which operations need a vote is unspecified
- Kind: Gap
- Evidence: docs/schema/lobby.md:112 "to ensure all changes go through votes"; voteActions = start | changeMap | appointBoss | kickban. Nothing says when a vote is required rather than the action being applied directly.
- Spec choice: one of the four voteActions needs a vote iff there is no boss and there is more than one eligible voter (ASSUMPTION LOBBY-A08, as in teiserver lobby.ex:938/987). Otherwise it applies at once, provided `canAct`.
- To verify: list the vote-gated commands in lobby.md.

### LOBBY-20: startBattle while a battle is running or starting has no reason; teiserver's autohost failures become invalid_request
- Kind: Gap + Divergence-teiserver
- Evidence: startBattle lists only `not_in_lobby`. teiserver lobby.ex:1033 `{:error, :battle_already_started}` and lobby.ex:1079 `{:error, :no_autohost}` both become `invalid_request` (tachyon_handler.ex:1044). An unavailable autohost is a server condition (`internal_error` at least).
- Spec choice: `invalid_request` when a battle is running or starting. An autohost failure is `env/autohostFailed` (LOBBY-21).
- To verify: add `battle_already_started` and `no_autohost` (or use internal_error).

### LOBBY-21: "If this request succeed players will receive a battle/start" cannot hold with votes or asynchronous autohost failure
- Kind: Contradiction / Gap
- Evidence:
  - docs/schema/lobby.md:2867 "Start the battle for the lobby. If this request succeed players will receive a battle/start request."
  - With voteActions `start`, success can only mean "a vote was opened".
  - If the start is asynchronous (autohost), it can fail after Ok, and no event tells the lobby, because lobbyDetails has no "starting" state.
  - teiserver avoids this only by answering after a synchronous autohost round-trip (lobby.ex:1035-1083, session.ex `the update of the state wrt to current battle is done by the lobby`) and by not supporting start votes.
- Spec choice: success = accepted (ASSUMPTION LOBBY-A14). Starting is invisible. `env/autohostFailed` returns to NoBattle with no event (transcript `battleTest`).
- To verify: add a lobby/updated field or an event for a failed start, or say that startBattle replies only after the battle started.

### LOBBY-22: bar-lobby ignores voteEnded and every specific failure reason except ally_team_full and leave
- Kind: Divergence-bar-lobby
- Evidence:
  - lobby.store.ts:107 `onLobbyVoteEndedEvent` only logs, with a TODO.
  - lobby.store.ts:187 join shows a generic "Error with request lobby/join" for `banned` and `lobby_full`.
  - lobby.store.ts:480 lobby/left ignores `reason` and `bannedUntil`.
- Spec choice: n/a (consumer). The model's events and reasons are what a client must be able to handle.
- To verify: bar-lobby UX issues.

### LOBBY-23: bar-lobby computes playerCount without bots
- Kind: Divergence-bar-lobby
- Evidence: lobby.store.ts:328 `playerCount = Object.keys(lobbyStore.activeLobby.players).length` (bots are in `bots`). teiserver's list overview counts bots (LOBBY-17), so the list and the lobby view can disagree.
- Spec choice: LOBBY-A12.
- To verify: follows from LOBBY-17.

### LOBBY-24: lobby/left reason values are free strings
- Kind: Gap
- Evidence: left.ts `reason: Type.String()`. teiserver tachyon_handler.ex `handle_info({:lobby, lobby_id, {:left, reason}}...)` sends "kicked", "banned" (with bannedUntil) or the error message "lobby crashed" (session.ex:1653).
- Spec choice: reasons are "kicked", "banned" and "crashed". "banned" iff the user is in the lobby's bans after the step.
- To verify: make `reason` an enum.

### LOBBY-25: Disconnect, session end and reconnect are unspecified for lobbies
- Kind: Gap + Divergence-teiserver (vs design default)
- Evidence:
  - The protocol never says what happens to a member whose connection drops. teiserver keeps them in the lobby for the session lifetime: the lobby monitors the session pid (lobby.ex `{:DOWN, ...} {:user, user_id}`).
  - lobby/updated events sent while the user is disconnected are lost.
  - On reconnect, user/self carries only `currentLobby` (tachyon_handler.ex:1121), and bar-lobby re-issues lobby/join to fetch the state (lobby.store.ts:85 `requestJoinLobby({ id: lobbyId, pushLobbyView: false })`).
  - The design says "After reconnect the server sends full state following user/self". teiserver sends no lobby details.
  - When the session ends, the user is removed with no lobby/left (they are gone).
- Spec choice: `env/sessionExpired` removes the user with no lobby/left and drops their list subscription (ASSUMPTION LOBBY-A15), except while the user is in the lobby's running battle (INT-D2). Socket drop, reconnect and takeover are not lobby steps: lobby state belongs to the session, which survives them (INT-D1).
- To verify: document the disconnect lifetime, and whether full lobby state follows user/self.

### LOBBY-26: A passed appointBoss vote makes a departed user a boss
- Kind: Divergence-teiserver
- Evidence: teiserver events/vote_ended.ex:80-81 `apply_outcome(agg, :passed, {:appoint_boss, boss_id}), do: Event.apply_event(%Events.UpdateBoss{action: :add, appointee_id: boss_id}, agg)` has no membership check. events/cancel_kick_vote.ex:23 cancels only `{:kickban, user_id, nil}` votes when the target leaves. If the appointee leaves during the vote and it then passes, `bosses` contains a non-member. From then on, nobody else can update or kick until that "ghost" boss is removed, which can only happen if they rejoin and are unbossed.
- Spec choice: `applyAction(VAppointBoss(t))` applies only if `t` is still a member. Invariant `bosses ⊆ members`.
- To verify: teiserver test: a appoints c by vote, c leaves, b votes yes, then check `bosses`.

### LOBBY-27: Bot ownership and permissions are unspecified
- Kind: Gap
- Evidence: lobbyDetails `hostUserId`: "which player will run the bot. It is the same as the player that added the bot." It is silent on:
  - spectators hosting bots (teiserver allows it; lobby.ex add_bot only checks membership);
  - removing or updating another member's bot (teiserver: anyone);
  - boss restrictions;
  - what happens when the host leaves (teiserver removes the host's bots, events/remove_spec_from_lobby.ex:40).
- Spec choice: any member may add, remove or update any bot (LOBBY-A05). Bots leave with their host (LOBBY-A06). Invariant: every bot host is a member.
- To verify: state these rules.

### LOBBY-28: joinQueue for a player and repeated joinQueue
- Kind: Gap
- Evidence: docs/schema/lobby.md:86-99 describe the queue but not joinQueue by a member who is already queued or already a player. teiserver (lobby.ex join_queue):
  - already queued → no-op, "This avoid someone losing their position";
  - player with an empty queue → no-op;
  - player with a non-empty queue → swaps with the first waiting member, and the player goes to the back.
- Spec choice: as teiserver (ASSUMPTION LOBBY-A04). Players who no longer fit after an allyTeamConfig shrink go to the *front* of the queue (LOBBY-A07). Positions may be ≤ 0 (lobby.md:86 allows non-consecutive positions).
- To verify: confirm in lobby.md.

### LOBBY-29: `not_a_boss` on unboss is ambiguous
- Kind: Gap
- Evidence: unboss lists `not_a_boss` without saying whether it is about the caller or the target. teiserver returns `:not_a_boss` when the *caller* is not a boss, and `:ok` when the target is not a boss (lobby.ex unboss).
- Spec choice: as teiserver (ASSUMPTION LOBBY-A13). A target who is not a member gives `invalid_request`.
- To verify: clarify the description.

### Assumptions (referenced from the model)
- **LOBBY-A01** (`create`): the creator is the first boss when bosses are allowed. See LOBBY-13.
- **LOBBY-A02** (`subscribeList`): listReset to the caller after every subscribeList. See LOBBY-16.
- **LOBBY-A03** (`finish`): a joiner gets no lobby/updated for their own join, because the response carries the full state. All other members do (teiserver `sender_id`).
- **LOBBY-A04** (`joinQueue`): see LOBBY-28.
- **LOBBY-A05 / A06** (`addBot`, `dropMember`): see LOBBY-27.
- **LOBBY-A07** (`reconfigure`): when allyTeamConfig shrinks, players who no longer fit go to the front of the queue in (ally team, slot) order, and bots who no longer fit are removed. Then the queue refills.
- **LOBBY-A08** (`voters`, `needsVote`): see LOBBY-14 and LOBBY-19.
- **LOBBY-A09** (`canAct`): when bosses are present, only bosses may update, kickban, appointBoss or startBattle. Everything else is open to all members.
- **LOBBY-A10** (`decide`): teiserver's rule, with quorum ⌊n/2⌋+1 and strict majority of non-abstaining ballots. A vote is decided as soon as the result can no longer change. On timeout without quorum the outcome is `timeout`. A leaving voter counts as abstaining.
- **LOBBY-A11** (`gated`): see LOBBY-07.
- **LOBBY-A12** (`ovOf`): see LOBBY-17.
- **LOBBY-A13** (`unboss`): see LOBBY-29.
- **LOBBY-A14** (`startBattle`): see LOBBY-21.
- **LOBBY-A15** (`sessionExpired`): see LOBBY-25.
- Also: queue promotion chooses the ally team with the most free room, lowest index first. The protocol leaves this free ("a suitable ally team"), and this is teiserver's `find_team`.

### Per-command implementation check (summary)

| command | teiserver | bar-lobby |
|---|---|---|
| create | matches. Default bosses differ (01). Creator is boss (13). Not checked against matchmaking (03) | parses details, generic error |
| join | idempotent ✓, banned ✓, lobby_full ✓ (limit 251 counting bots, 10). invalid_lobby_id → invalid_request (02). No matchmaking check (03). Other members get updated, the joiner does not ✓ | generic error. Rejoins on user/self (25) |
| leave | ✓ events. not_in_lobby → invalid_request (02). Bots and boss role removed ✓. Queue filled ✓ | treats invalid_request as left |
| left | kicked / banned+bannedUntil / "lobby crashed" ✓. Not on leave ✓ | ignores reason (22) |
| joinAllyTeam | reasons ✓. Capacity = maxTeams (08). Ready not reset server-side (11) | generic error |
| spectate / joinQueue | ✓ (queue semantics = LOBBY-A04) | ✓, builds the queue from positions |
| updateClientStatus | logic ✓, reasons collapsed (02) | generic |
| addBot / removeBot / updateBot | reasons ✓. No ownership or boss checks (27) | addBot handles ally_team_full |
| update | boss gate wrong when bosses are enabled but absent (05). Map change via vote ✓. not_in_lobby missing in schema (12) | generic |
| appointBoss / unboss | logic ✓, reasons collapsed (02). Ghost boss via vote (26) | generic |
| kickban | boss gate ✓, vote when no boss ✓. Overwrites a running vote (07). not_boss → invalid_request | generic |
| voteSubmit | ✓ logic, all errors → invalid_request (02) | generic |
| voteCancel | **unimplemented** (04) | sent |
| voteEnded | sent to members after the step ✓ | ignored (22) |
| startBattle | no boss check or vote (06). Synchronous autohost. Errors → invalid_request (20) | generic |
| joinBattle | logic ✓, reasons collapsed (02) | not wired to the UI (TODO) |
| updated | members only ✓. Suppressed when nothing changed ✓ | merge-patch, resets the vote on a new id |
| subscribeList / unsubscribeList / listReset / listUpdated | listReset on every subscribe (16). 5 s batching. playerCount inconsistent (17) | resubscribes on reconnect, replaces the list on reset |

## Coverage

Witness = a `@witness` directive in lobby.qnt (check.sh confirms that each one is reached).

| command | Ok | denial reasons witnessed | unreachable |
|---|---|---|---|
| create | ✓ | invalid_request | internal_error, unauthorized, command_unimplemented: these are infrastructure, role and implementation outcomes, which are not modelled (same for every command below) |
| join | ✓ | invalid_lobby_id, invalid_request, banned (lobby_votes), lobby_full (lobby_queue) | — |
| leave | ✓ | not_in_lobby | — |
| joinAllyTeam | ✓ | not_in_lobby, invalid_request, ally_team_full | — |
| spectate | ✓ | not_in_lobby | — |
| joinQueue | ✓ | not_in_lobby | — |
| updateClientStatus | ✓ | not_in_lobby, not_a_player | — |
| addBot | ✓ | not_in_lobby, invalid_request, ally_team_full | — |
| removeBot | ✓ | not_in_lobby, invalid_bot | — |
| updateBot | ✓ | not_in_lobby, invalid_bot | — |
| update | ✓ | invalid_request | — |
| appointBoss | ✓ | not_in_lobby, invalid_request, bosses_not_allowed | — |
| unboss | ✓ | not_in_lobby, invalid_request, not_a_boss | — |
| kickban | ✓ | not_in_lobby, invalid_request | — |
| voteSubmit | ✓ (lobby_votes) | not_in_lobby, invalid_vote_id (lobby_votes), invalid_request (lobby_kick) | — |
| voteCancel | ✓ (lobby_votes) | not_in_lobby, invalid_vote_id, invalid_request | — |
| startBattle | ✓ | not_in_lobby, invalid_request | — |
| joinBattle | ✓ (lobby_votes) | not_in_lobby, no_battle, battle_full (lobby_votes) | — |
| subscribeList / unsubscribeList | ✓ / ✓ | — (the schema has only generic reasons) | — |
| updated | `sawUpdated` | | |
| left | kicked, banned (lobby_votes), crashed | | |
| voteEnded | passed, failed, cancelled, timeout (lobby_votes). A kick that passes by vote: `votedKickPassed` (lobby_kick) | | |
| listUpdated | lobby added/changed `sawListUpdated`, removed `sawListRemoved` | | |
| listReset | `sawListReset` | | |
| battle/start | `sawBattleStart` (autohost started), plus the joinBattle Ok | | |
| env steps | autohostFailed `battleStartFailed`, battleEnded `sawBattleEnded`, banExpired `sawBanExpired`, queue promotion `queuePromoted` and eviction to the queue `evictedToQueue` (lobby_queue), crash = left crashed, session end (transcript `sessionAndListTest`), otherActivity (transcript) | | |

The 7 transcripts in `lobby_test` (`membershipQueueTest`, `queueSwapAndReconfigureTest`, `botsTest`, `bossesKickbanTest`, `votesTest`, `battleTest`, `sessionAndListTest`) cover every command and pin exact reply, state and event sets.

## Seeded mutations

Each mutation was applied to a copy (scratchpad `mut/lobby.qnt`, harness `mut/mutate.sh`), then checked with `quint test --main=lobby_test` and `safety` on lobby_test, lobby_votes and lobby_queue (30 steps, 10000 samples). These runs came before `lobby_kick` was added, and before `lobby_queue` changed to MAX_MEMBERS=2. The original file was not changed.

| id | mutation (one line) | caught by |
|---|---|---|
| M1 | `join`: `else if (u.in(l.bans)) deny(s,"banned")` → `else if (false) ...` | test `bossesKickbanTest`. `safety` on lobby_votes and lobby_queue (`bans ∩ members = ∅`). The `join banned` witness would also fail |
| M2 | `joinAllyTeam`: `free(l, a) <= 0` → `free(l, a) < 0` | test `membershipQueueTest`. `safety` on lobby_test and lobby_queue (`occupants <= cap`) |
| M3 | `finish`: Updated recipients `members(prev) ∩ members(nxt)` → `∪` (the leaver or kicked user gets updated) | 4 tests. `safety` on all 3 instances (`updatedOnlyToMembers`) |
| M4 | `fill` = identity (no queue promotion) | 3 tests. `safety` on lobby_test and lobby_queue (queue non-empty ⇒ every ally team full) |
| M5 | `subscribeList` sends listReset to all USERS instead of the caller | 2 tests. `safety` on lobby_test (`listOnlyToSubscribers`) |

## Cross-module interface

These predicates are over this module's state `s`, for a user `u`:

- **Provided to other modules:**
  - `inLobby(s, u)` / `lobbyOf(s, u)`: the user's lobby.
  - `members(s.lobbies.get(id))`
  - `s.lobbies.get(id).inBattle`: the users the lobby put into its battle via battle/start.
  - `isRunning(s.lobbies.get(id).battle)`
  - `s.subscribers`: lobby-list subscriptions, owned by the session.
- **Assumed about matchmaking and battle (`s.elsewhere`, driven by `env/otherActivity`):**
  - matchmaking/queue and a matchmaking battle require `not(inLobby(s, u))`. This is the design rule "Queueing while in a lobby is not allowed (invalid_request)".
  - In return, lobby/create and lobby/join require `not(u in elsewhere)`.
  - Composition invariant: `∀u. inLobby(u) ⇒ ¬inMatchmaking(u) ∧ ¬inMatchmakingBattle(u)`.
  - Lobby battles are excluded from the activity slot (LOBBY-03).
- **Battle module:**
  - `env/autohostStarted(id)` corresponds to a successful autohost/start for the lobby's start script. It makes `battle/start` go to `members(lobby)`.
  - `env/battleEnded(id)` corresponds to the battle ending (battle/ended is that module's event). Afterwards `currentBattle = null`.
  - joinBattle's `battle_full` is the battle's answer to adding a player.
- **Session / system:**
  - `env/sessionExpired(u)` happens when the session ends (grace period expired, or system/disconnect). A replaced connection (`env/takeover`) does NOT end the session (INT-D1; the earlier text "or replaced" was wrong). Afterwards `¬inLobby(u) ∧ u ∉ subscribers`, and no lobby/left is sent. While `u ∈ inBattle` of its lobby the step is a no-op (INT-D2).
  - Users are identified by session, one live session per user.
- **Party:** no interaction is modelled. Tachyon says nothing about parties and lobbies.

## Requests to the orchestrator

1. **Apalache.** `quint verify` cannot handle this module at 2-3 steps within the 4 GB default heap (about 8-9 min, then OOM), and with 10 GB it had not finished in 6.5 min. There is no `@verify` directive. If bounded checking is required for lobby, a hand-reduced Apalache-friendly variant would be needed: without the generic `finish` event derivation and without the `USERS.fold` queue refill. Decide whether it is worth it.
2. **Composition.** The matchmaking module should guard `matchmaking/queue` with `not(inLobby(u))`, using the predicate above. The battle module should agree that lobby battles do not occupy the activity slot (LOBBY-03).
3. **check.sh runtime.** `./check.sh lobby.qnt` takes about 8.7 minutes: 1 typecheck, 1 test, 4 invariant runs and 78 witness runs, 84 ok lines. Every witness was timed. All are reached within about 3,100 traces, out of the 10,000 samples allowed.

## Integration changes

Made by the integration step (findings/system.md, decisions INT-D1..D5):

- `env/sessionEnded` / `sessionEnded` renamed `env/sessionExpired` / `sessionExpired` (INT-D1), in the step, `leftComplete`, `ALL_STEPS` and `sessionAndListTest`.
- `sessionExpired` is a no-op while the user is in its lobby's running battle (`u ∈ inBattle`), INT-D2 (teiserver session.ex:1569-1571 starts no timeout while `state.battle` is set). New expectation in `battleTest`.
- Cross-module interface text: a replaced connection does not end the session (INT-D1). Disconnect, reconnect and takeover are not lobby steps.
- Unchanged and confirmed by INT-D4: `lobby/create` and `lobby/join` answer `invalid_request` while the user is in `elsewhere` (queued, in a found match, or in a matchmaking battle); lobby battles do not take a second slot.
