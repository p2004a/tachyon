# Findings: system composition (`system.qnt`)

## Scope

`system.qnt` composes the group modules at the level of each group's abstract state. It does not import
them, because their product explodes. Each step cites the group definitions it refines (for example
`party.qnt removeMember` + `matchmaking.qnt partyLeave`), so the composition is a refinement by
convention.

**Abstract state per group:**
- **session:** presence `Online | Detached | Offline`, plus a socket generation.
- **messaging:** the socket the user subscribed on.
- **friend:** friends and pending requests.
- **party:** members, invitees, and `queued` (the party lock).
- **lobby:** members, and the battle as none, starting(b) or running(b).
- **matchmaking:** searching tickets, and found matches in ReadyCheck or Starting(b).
- **autohost/battle:** battles with origin (lobby or match), participants and phase (starting/running).

**Steps (cross-boundary only):**
- **session:** env/connect, env/disconnect, env/reconnect, env/takeover, env/sessionExpired, system/disconnect.
- **party:** party/create, invite, acceptInvite, leave, kickMember.
- **matchmaking:** matchmaking/queue, cancel, ready; env/match, env/readyTimeout, env/startGaveUp.
- **lobby:** lobby/create, join, leave, startBattle, joinBattle; env/lobbyCrashed.
- **autohost/battle:** env/autohostStarted, env/autohostFailed, env/battleEnded, each for both lobby- and match-originated battles.
- **messaging:** messaging/subscribeReceived; messaging/send to a party or lobby.
- **friend:** friend/sendRequest.

**Abstracted away:**
- Queue ids, versions, assets and team shapes. A match is ≥2 searching tickets with `MATCH_SIZE` members.
- Votes, bosses, ally teams and bots.
- Invite timers, and autohost connections and engines.
- Message bodies and buffers.

**Instances:**
- `system_test`: 4 users, `MATCH_SIZE=3`, `MAX_PARTY=2`. Five reviewed transcripts and most witnesses.
- `system_three`: 3 users, so every match takes all of them. Used for the deep matchmaking/battle witnesses.
- `system_party`: 3 users as `system_three`, with `ALL_GROUPS = false`, so only the party, matchmaking and battle step groups run (a test knob like lobby.qnt `ENABLED`). Used for the deepest party paths.
- `system_party4`: the same knob with 4 users, so a fourth user can invite someone in a found match.
- `system_small`: 3 users, matches of 2, parties of 1. Used for Apalache.

**Results** (`./check.sh`, `SEED=1`, at commit `eb48d7d`; later commits change only Markdown):
- `system.qnt`: 83 of 83 ok in one run: 1 typecheck, 1 test (5 runs), 5 invariant runs, 76 witnesses. See "Check run".
- `quint verify --main=system_small --invariant=safety --max-steps=2`: no violation, on an earlier version of `step`. This is a shallow sanity check only; see "Apalache".

## Composition decisions

### INT-D1: One session vocabulary: connect, disconnect, reconnect, takeover, sessionExpired; presence Online | Detached | Offline
- Kind: Decision (composition)
- Evidence:
  - findings/session.md (before integration): party used `env/sessionExpired`, lobby and matchmaking used `env/sessionEnded`.
  - findings/lobby.md (old :375) said the session ends when the connection is "replaced". session.qnt `takeover` and messaging.qnt `takeover` keep the session (SESSION-01, MSG-07).
  - teiserver session.ex:558-581 `handle_call({:replace, ...})` keeps the session state and swaps `conn_pid`.
- Spec choice:
  - lobby.qnt and matchmaking.qnt renamed their step to `env/sessionExpired`.
  - party.qnt and friend.qnt gained `env/takeover` (Online → Online, user/self resets the view).
  - lobby.md was corrected.
  - In system.qnt, `takeover` changes only the socket and the socket-bound messaging subscription (invariant `takeoverKeepsSession`).
- To verify: Tachyon should name the replacement behaviour (SESSION-01).

### INT-D2: A user in a running battle keeps the session past the grace period
- Kind: Assumption (composition decision; Tachyon is silent)
- Evidence:
  - teiserver session.ex:1569-1571 `if is_nil(state.battle) do {:ok, _tref} = :timer.send_after(@connection_timeout, ...)`.
  - session.ex:1695-1696 `if is_nil(state.conn_pid) and is_nil(state.battle) do ... {:stop, :normal, state}`.
  - session.qnt SESSION-07. matchmaking.qnt `sessionExpired` already had `if (s.inBattle.contains(u)) noop`.
- Spec choice:
  - system.qnt `sessionExpired`: a no-op while `playing(s,u)` (invariant `keptWhilePlaying`, witness `w_keptWhilePlaying`).
  - lobby.qnt `sessionExpired` gained the same guard for its own battle.
  - party, messaging and friend have no battle notion, so the composition guards the step for them.
- To verify (protocol owners): state the rule in Tachyon. Also state what happens when the battle ends while the user is still Detached (INT-02).

### INT-D3: The party matchmaking lock lasts from queue until battle start or withdrawal
- Kind: Decision (composition); Tachyon is silent, so matchmaking.md C3 stands
- Evidence:
  - Tachyon never says when the lock ends. Searched text:
    - docs/schema/party.md:7-8 "Parties ... are used to join matchmaking together".
    - docs/schema/matchmaking.md:23-24 "`party_user_left`: a member of the player's party left matchmaking, thus forcing the entire party to withdraw".
    - matchmaking.md:28 (checkAssets/queuesJoined for parties).
    - schema.qnt:65 `party/invite` has no matchmaking reason at all, so the lock itself is teiserver's (PARTY-14).
  - Before integration, party.md I2 cleared `queued` on "match found"; matchmaking.md C3 kept the party locked through the ready check and Starting.
- Spec choice:
  - party.md I2 was rewritten to C3. system.qnt sets `queued` in `mmQueue` and clears it in:
    - `withdraw` (cancel, decline, leave, kick, session end);
    - `readyTimeout` (failed tickets only);
    - `startGaveUp`;
    - `autohostStarted` (match origin).
  - Invariant `partyLockMatchesTickets`: `queued(p) ⇔ members(p)` is a searching or matched ticket, and a locked party has no invites.
  - Witnesses: `w_lostPartyStaysLocked`, `w_partyBattleUnlocks`. Seeded mutations M3 and M5.
- To verify: Tachyon should say that a queued party cannot change membership or invite, and when that ends.

### INT-D4: Activity slot: at most one of {lobby, matchmaking ticket, matchmaking battle}
- Kind: Decision (composition); proposed default PD-03 (DECISIONS.md)
- Evidence:
  - Proposed default PD-03 (DECISIONS.md): a user is in at most one of lobby, matchmaking ticket, matchmaking battle, and queueing from a lobby fails with `invalid_request`. Tachyon has no such rule.
  - LOBBY-03, MM-04, MM-17. teiserver enforces none of it (INT-01, noted against PD-03).
- Spec choice:
  - A battle started from a lobby counts as the lobby's slot while the user is a member of that lobby (`ownLobbyBattle`). Any other running battle is its own slot (`slotBattle`; see INT-03 for lobby battles a user left).
  - `mmQueue`:
    - `already_in_battle` if any unit member plays any battle;
    - `invalid_request` if any member is in a lobby;
    - `already_queued` in a found match.
  - `lobbyCreate` / `lobbyJoin`: `invalid_request` while queued, in a found match, or in a battle other than the lobby's own (INT-10).
  - Invariants `activitySlot` and `mmBattleSlot`. Seeded mutation M4.
- To verify: see INT-10 for the missing reasons.

### INT-D5: common.qnt is unchanged; the composition defines its own types
- Kind: Decision (composition)
- Evidence: the party and matchmaking models each extend `Outcome` (`why`, `requests`) and party has a presence type;
  sharing them in common.qnt was considered.
- Spec choice: system.qnt defines `Presence`, `Outcome` (with `why`), `Eff` and a union `Event` locally. It uses only `Reply`, `send`, `theOne`, `mapRemove` and `replyInSchema` from common.qnt.
- To verify: none.

## Protocol (Tachyon)

### INT-01: teiserver enforces no activity slot across groups: a queued user can sit in a lobby, and a matchmaking battle start keeps them there
- Kind: Proposed default (PD-03) (cross-group; extends LOBBY-03 / MM-17)
- Evidence:
  - teiserver player/session.ex:952-954 (`lobby/create`) and :999-1001 (`lobby/join`) guard only `state.lobby != nil`.
  - :611-640 (`matchmaking/queue`) checks only `state.matchmaking` and the party. A searching or pairing user can join a lobby, and a lobby member can queue.
  - When the match starts, `handle_cast({:battle, {:start, ...}})` session.ex:1350-1358 takes the `matchmaking: {:pairing, ...readied?: true}` branch first and leaves `state.lobby` untouched. The user is then a lobby member and a matchmaking-battle player at the same time.
  - A lobby battle start for a user who is already in a battle overwrites `state.battle` (:1357, :1382 `state = %{state | battle: battle_state}`). The monitor of the first battle stays.
- Note: teiserver's behaviour is measured against PD-03 and is noted, not counted as a divergence (Tachyon has no
  activity slot). The `already_in_battle` part is MM-17's implementation part.
- Spec choice:
  - INT-D4 guards (`activitySlot`, `mmBattleSlot`).
  - Two situations raised during composition cannot happen in the spec, because `activitySlot` holds on every reachable state:
    - "a party member's lobby seat when the party's match is found";
    - "a lobby crash while its players are queued".
  - Both can happen in teiserver. In the first, the member keeps the lobby seat and gets the matchmaking battle/start. In the second, the crash only clears `state.lobby` (:1653) and matchmaking continues.
- To verify: a teiserver test: queue, then `lobby/join` → expect `invalid_request`; and the reverse.

### INT-02: After a battle ends, a Detached player's grace period never restarts in teiserver
- Kind: Gap + Proposed default (PD-02) (Tachyon has no grace period, SESSION-02); teiserver behaviour noted against PD-02 / INT-D2
- Evidence:
  - teiserver session.ex:1569-1571 starts the connection timeout only if `is_nil(state.battle)` at the moment of the drop.
  - The battle-ended handlers set `battle: nil` without arming a timer: :1395-1404 `{:noreply, %{state | battle: nil, monitors: monitors}}`, and the `{:battle, id}` DOWN branch at :1661-1676.
  - `:connection_timeout` (:1695-1696) fires only once.
  - So a user whose socket dropped during a battle keeps the session indefinitely after the battle. Their lobby seat, party membership, invites and friend presence stay too.
  - Their party cannot queue in the spec (party_missing_asset, INT-04). teiserver queues them anyway, and they then fail every ready check.
- Spec choice: once `battleEnded` removes the battle, `sessionExpired` is enabled again for a Detached participant. This assumes the grace period restarts at battle end (`partyMatchTest`: kept while playing, expired after `env/battleEnded`).
- To verify (protocol owners + teiserver): restart the timer in the battle-ended handlers. Tachyon should say whether the grace period restarts or resumes.

### INT-03: A lobby battle outlives lobby membership (leave, crash, disposal), and no group owns that user's slot
- Kind: Gap (teiserver behaviour noted; Tachyon is silent, and the activity slot is PD-03)
- Evidence:
  - lobby.md:2125 "Leave the lobby, also unsubscribe from any update" says nothing about the battle.
  - "can also be forcibly removed from a lobby ... if the lobby crashed" (lobby.qnt `lobbyCrashed`).
  - battle/ended is the battle module's (autohost.qnt).
  - teiserver lobby leave (session.ex:1128-1141) and the lobby-crash DOWN branch (:1645-1654) clear only `state.lobby`. `state.battle` stays and the engine keeps the player.
  - teiserver then lets that user create or join another lobby (INT-01). If that lobby starts a battle, `state.battle` is overwritten (:1382) while the first engine still has the player.
- Spec choice:
  - The battle becomes its own slot (`slotBattle`). `matchmaking/queue` → `already_in_battle`; `lobby/create` / joining another lobby → `invalid_request`.
  - Rejoining the battle's own lobby is allowed, and the slots merge again (`lobbyBattleTest`).
  - Witnesses: `w_orphanBattle`, `w_crashOrphansBattle`, `hitWhy("lobby/create","in_battle")`, `hitWhy("lobby/join","in_battle")`.
  - `battleEnded` for a lobby that is gone sends only battle/ended.
- To verify: does leaving a lobby leave its battle (and should the server send `autohost/kickPlayer`), or does the battle keep the slot?

### INT-04: Queueing a party with a Detached member: the only applicable reason is `party_missing_asset`
- Kind: Gap + Assumption (+ Divergence-teiserver)
- Evidence:
  - matchmaking.md:28: "If any client's `assetStatus` response is `missing`, `downloading`, or if it times out without sending a response, the matchmaking `queue` request will fail."
  - A Detached member cannot answer checkAssets. Proposed default PD-02 (DECISIONS.md): party membership survives a socket drop (party.qnt `sessionsOwnParties`).
  - teiserver sends no checkAssets (MM-20). party/server.ex:361-406 queues every member id without looking at their session. A Detached member is put in the queue (session.ex:1498-1512, `send_to_player` drops the queuesJoined), and later fails the ready check, which removes the whole party.
- Implementation part (Divergence-teiserver): no checkAssets (MM-20); a Detached member is queued and later fails
  the ready check.
- Spec choice: `mmQueue` → `Failed("party_missing_asset")` when another unit member is not Online (`member_detached` witness, `partyMatchTest`). The reason misnames the cause. A party member in a lobby gets a bare `invalid_request` (MM-04).
- To verify: add a reason such as `party_member_unavailable` (covering detached, in a lobby, or in a battle), or require every member to be connected.

### INT-05: A found match that is disbanded while its autohost/start is in flight
- Kind: Gap (+ Divergence-teiserver)
- Evidence:
  - matchmaking.md:12 "to decline a found match, clients should send a cancel request". :14 "Once all players are ready, the server should send a autohost/battleStart request ... If the autohost doesn't respond quickly, or if it sends a failed response, the server should repeat this step."
  - Nothing says whether cancel, party leave/kick or session expiry are still possible after the last ready. matchmaking.qnt allows all of them in the `Starting` phase.
  - Lobbies have the same gap: an empty lobby is disposed, and a crashed lobby is removed, while `Starting`.
  - teiserver pairing_room.ex:121-180 runs `start_match` inside `handle_continue`, so a cancel cast (:221-242) is handled only after `Player.battle_start` went out, against a stopped room.
  - A player whose session expired during the start gets `Player.battle_start` (session.ex:192-196) cast to a dead process. The battle starts one player short.
- Implementation part (Divergence-teiserver): a cancel during the start is handled only after `Player.battle_start`
  went out, and an expired player's start goes to a dead process, so the battle starts one player short.
- Spec choice:
  - `disband` keeps the in-flight battle with a dead origin. `autohostStarted` kills a late success (`killed`), and `autohostFailed` just drops it.
  - The other tickets get `lost` and resume searching.
  - Witnesses: `w_startingDisbanded`, `hitWhy("env/autohostStarted","killed")`, `partyChangeTest`.
- To verify: either forbid leaving between "all ready" and battle start (queue the cancel), or say that the server kills the started battle and what the remaining players see.

### INT-06: party/create and party/acceptInvite while in a found match have no defined outcome
- Kind: Gap
- Evidence:
  - party/create and party/acceptInvite reasons are generic only (schema.qnt:61, :63).
  - matchmaking.md C4 assumes refusal. teiserver treats it as a decline (session.ex:884-890 → `leave_matchmaking`, per findings/matchmaking.md).
  - PARTY-20 (solo searching ticket cancelled with `intentional`) covers only searching.
- Spec choice: `invalid_request` (`in_found_match` witnesses for both commands); the solo searching ticket is cancelled with `intentional` (`solo_cancelled`). Accepting while in a locked party withdraws that party with `party_user_left` (`w_acceptLeavesQueuedParty`).
- To verify: pick refusal or decline, and document it in party.md.

### INT-07: system/disconnect while playing: the modules disagree
- Kind: Contradiction (between modules) + Gap
- Evidence:
  - system.md:11 "Ask the server to terminate the connection."
  - session.qnt `disconnect` ends the session even while Playing (SESSION-09). lobby.qnt and matchmaking.qnt treat their session end as a no-op while the user is in a battle.
  - teiserver session.ex:588-604 stops the session regardless of `state.battle`. Lobby and party drop the user through their monitors, and the engine keeps the player.
  - On the next login a fresh session has `battle: nil`, so `user/self.currentBattle` is absent (privateUser.json:49) while the user still has a slot in a running engine.
- Spec choice: session.qnt wins.
  - `systemDisconnect` ends the session: lobby seat, party, invites, ticket and subscription go.
  - Battle participation is kept (autohost-side), so an Offline user can be a battle participant (`w_offlineInBattle`).
  - `offlineIdle` does not cover battles for this reason.
- To verify: should `system/disconnect` while playing be refused, or end the battle participation, or should `currentBattle` be recovered from the battle on the next login?

### INT-08: Takeover in the middle of a ready check
- Kind: Gap (+ Divergence-bar-lobby)
- Evidence:
  - INT-D1: the session survives, so the match and the user's ready flag survive (`takeoverKeepsSession`).
  - The new socket learns the match only from user/self: `matchmaking: {state: "found", queue: {id, version, timeoutAt, hasAlreadyReadied}, otherQueues}` (privateUser.json:62-110). There is no readyCount, and no state for "all ready, battle starting".
  - A `matchmaking/ready` in flight on the replaced socket is dropped without a response (session.qnt `pendingOnLiveSocket`), so the client must trust `hasAlreadyReadied`.
  - bar-lobby logic/matchmaking.ts:249-263 restores MatchAccepted/MatchFound from user/self but never sets `playersReady`, so the UI shows 0 ready until the next foundUpdate.
- Implementation part (Divergence-bar-lobby): after a takeover the UI shows 0 ready until the next foundUpdate.
- Spec choice: `takeover` changes only the socket. Witness `w_takeoverMidReadyCheck`; `partyMatchTest` readies, takes over, and gets `already_ready`.
- To verify: add `readyCount` (and a "starting" state) to user/self matchmaking.

### INT-09: Autohost start failure means different things for lobby and matchmaking battles
- Kind: Contradiction (lobby vs matchmaking semantics) + Divergence-teiserver
- Evidence:
  - Lobby: the start failure is silent and final (lobby.qnt `autohostFailed`, LOBBY-21). The lobby returns to "no battle" and the members are never told.
  - Matchmaking: "the server should repeat this step" (matchmaking.md:14) with no bound (MM-13). The party stays locked and every player keeps the ticket slot for as long as the retries last. user/self shows only "found, hasAlreadyReadied".
  - In both cases the players are not "playing", so INT-D2 does not protect a Detached player: their grace expiry disbands the match (INT-05).
  - Autohost loss in a running battle (autohost.qnt PLost, AH-10) ends both kinds alike with battle/ended.
  - teiserver does the opposite of Tachyon for matchmaking: it gives up on the first failure with `lost` (pairing_room.ex:143-156, MM-23). For lobbies the failure reaches the client as `invalid_request` to startBattle (LOBBY-20).
- Implementation part (Divergence-teiserver): matchmaking gives up on the first failure (MM-23); lobby failures
  reach the client as `invalid_request` (LOBBY-20).
- Spec choice:
  - `autohostFailed`: lobby → `lobby_failed` (silent); match → `retried` with a fresh battle id (AH-05 recommendation).
  - `startGaveUp`: `lost` + `cancelled(server_error)`, unlocking the parties.
  - All are witnessed in both origins.
- To verify: one rule for both origins (retry count, then a user-visible failure).

### INT-10: No specific reasons for activity-slot refusals
- Kind: Gap
- Evidence:
  - lobby/create reasons: only the generic four (schema.qnt:36). lobby/join adds only `banned`, `invalid_lobby_id` and `lobby_full` (:37).
  - matchmaking/queue has `already_in_battle` but nothing for "in a lobby" or "a party member is busy" (:57).
  - Under INT-D4 a client cannot tell "you are queued" or "you are in a battle" from a malformed request.
- Spec choice: `invalid_request` (`hitWhy` witnesses `lobby/create` queued / in_battle, `lobby/join` queued / in_battle, `matchmaking/queue` in_lobby).
- To verify: add `in_matchmaking` / `already_in_battle` to lobby/create and lobby/join, and `in_lobby` (or the reason proposed in INT-04) to matchmaking/queue.

### INT-11: Messaging and user subscriptions have opposite lifetimes across the same session steps
- Kind: Assumption (carried from MSG-A9) + Gap
- Evidence:
  - MSG-08: messaging.md does not say when `subscribeReceived` ends. messaging.qnt chose "socket-bound" (dropped on disconnect, reconnect and takeover).
  - user/subscribeUpdates subscriptions belong to the session and survive all three (SESSION-05).
  - teiserver drops the messaging flag on an abrupt disconnect (session.ex:1563-1567) but keeps it on replace (:558-581, MSG-07).
  - Across groups: a party or lobby member who was taken over gets no chat until they resubscribe. The messages are buffered (messaging.qnt), not lost.
- Spec choice: `msgSubSocketBound`, `msgSubOnlyBySubscribe` (seeded mutation M1), `messagingTest`, witnesses `w_takeoverDropsMsgSub`, `w_disconnectDropsMsgSub`, `w_msgNotToDetached`. The composition depends on this assumption, which Tachyon does not state.
- To verify: one sentence in messaging.md (see MSG-08).

## Implementation (teiserver b36429f, bar-lobby ee58acd)

No cross-group entry is an implementation divergence on its own; the teiserver and bar-lobby parts are marked inside the Protocol entries. Entries under Protocol that also carry an implementation part (marked in the entry): INT-04, INT-05, INT-08, INT-09.

## Model notes

### Coverage

All witnesses are `@witness` directives in system.qnt. Witnesses marked "(three)" run on `system_three` or `system_party`, with the bounds in each directive. The
others run on `system_test`. Some deep witnesses need 60000-150000 samples; the directives say so.

| Step | Outcome (why) | Status |
|---|---|---|
| env/connect | connected | witnessed |
| env/disconnect | detached; subscription dropped | witnessed; `w_disconnectDropsMsgSub` |
| env/reconnect | reattached | witnessed |
| env/takeover | taken_over; mid ready-check; subscription dropped | witnessed; `w_takeoverMidReadyCheck`, `w_takeoverDropsMsgSub` |
| env/sessionExpired | expired; kept_while_playing; withdraws locked party; disbands match; leaves lobby; drops invite | all witnessed (`w_keptWhilePlaying`, `w_expiryWithdrawsParty` (three), `w_expiryDisbandsMatch`, `w_expiryLeavesLobby`, `w_expiryDropsInvite`) |
| system/disconnect | Ok; while playing; Offline in battle | witnessed; `w_systemDisconnectWhilePlaying`, `w_offlineInBattle` |
| party/create | created; solo_cancelled; in_found_match | witnessed. `already_in_party` is party-internal (party.qnt) |
| party/invite | invited; party_in_matchmaking | witnessed. not_in_party, target_not_connected, already_member_or_invited, party_full: party-internal (party.qnt); party_full in `partyMatchTest` |
| party/acceptInvite | joined; in_found_match; leaves locked party | witnessed (`w_acceptLeavesQueuedParty`; in_found_match on `system_party4`, also in `partyMatchTest`). not_invited: party-internal |
| party/leave | left; left_unqueued; left_declined (three) | witnessed |
| party/kickMember | kicked_unqueued (three); kicked_declined (three) | witnessed. plain `kicked`, kick_self, target_not_member: party-internal (party.qnt) |
| matchmaking/queue | queued; party_queued; replaced; already_in_battle; in_lobby; already_queued; member_detached (three) | witnessed |
| matchmaking/cancel | left_queue; declined; not_queued | witnessed |
| matchmaking/ready | readied; all_ready (three); no_match | witnessed; already_ready in `partyMatchTest` |
| env/match | found | witnessed |
| env/readyTimeout | lost; party stays locked after lost | witnessed; `w_lostPartyStaysLocked` (three) |
| env/startGaveUp | gave_up (three) | witnessed |
| env/autohostStarted | lobby_started; match_started (three); killed (three); party unlocked | witnessed; `w_partyBattleUnlocks` (three) |
| env/autohostFailed | lobby_failed; retried (three) | witnessed; `dropped` (origin gone) not witnessed: the same branch as `killed` |
| env/battleEnded | ended_lobby; ended_match (three) | witnessed |
| env/lobbyCrashed | crashed; orphans a running battle | witnessed; `w_crashOrphansBattle`, `w_orphanBattle` |
| lobby/create | created; queued; in_battle | witnessed. in_lobby: lobby-internal |
| lobby/join | joined; queued; in_battle; invalid_lobby_id | witnessed. in_other_lobby: lobby-internal |
| lobby/leave | left | witnessed. not_in_lobby: lobby-internal |
| lobby/startBattle | accepted | witnessed. battle_exists: lobby-internal (LOBBY-20) |
| lobby/joinBattle | joined_battle; no_battle | witnessed |
| messaging/subscribeReceived | subscribed | witnessed |
| messaging/send | delivered; not to Detached; invalid_target | witnessed (`w_msgDelivered`, `w_msgNotToDetached`) |
| friend/sendRequest | requested; auto_accepted; event lost to a non-Online peer | witnessed (`w_friendEventLost`). invalid_user / already_in_friendlist: friend-internal |

Invariants (`safety`, run on `system_test` 20000×30, `system_three` 20000×30, `system_party` 20000×30, `system_party4` 10000×30, `system_small` 10000×20):
- `atMostOneParty`, `atMostOneLobby`, `atMostOneTicket`, `atMostOneBattle`.
- `activitySlot` (INT-D4).
- `ticketsArePartyUnits`.
- `partyLockMatchesTickets` (INT-D3).
- `mmBattleSlot`.
- `battlesLinked`.
- `offlineIdle` (no session-less user holds a lobby seat, party, invite, ticket or subscription).
- `keptWhilePlaying` (INT-D2).
- `takeoverKeepsSession` (INT-D1).
- `msgSubSocketBound`, `msgSubOnlyBySubscribe`, `msgOnlyToSubscribed`.
- `eventsOnlyToOnline`, `battleStartToParticipants`, `foundToMatched`, `cancelledReasonsInSchema`.
- `sessionStepsKeepFriends`, `denialsChangeNothing`, `reasonsInSchema`.

### Seeded mutations

Each mutation was a single edit, run on a scratch copy of system.qnt (`quint test` plus `quint run` of `safety` and of the named invariant, 20000×30), and then discarded. The file in the repo is unmutated.

| # | Mutation | Caught by |
|---|---|---|
| M1 | `openSocket` carries an existing messaging subscription to the new socket | `sessionLifecycleTest`, `messagingTest`; `safety` via `msgSubOnlyBySubscribe`. `msgSubSocketBound` alone did NOT catch it, which is why `msgSubOnlyBySubscribe` was added |
| M2 | `sessionExpired` without the INT-D2 `playing` guard | `partyMatchTest`; `safety` via `keptWhilePlaying` |
| M3 | `matchFound` releases the party lock (old party.md I2) | `partyMatchTest`, `partyChangeTest`; `safety` via `partyLockMatchesTickets` |
| M4 | `lobbyJoin` without the "queued" check (INT-D4) | `partyMatchTest`; `safety` via `activitySlot` |
| M5 | matchmaking battle start does not unlock the parties | `partyMatchTest`; `safety` via `partyLockMatchesTickets` |

### Apalache

`JVM_ARGS=-Xmx6G quint verify --main=system_small --invariant=safety --max-steps=2 system.qnt` gave `[ok] No violation found` on three successive versions of `step`, in 557 s, 1199 s and 2127 s (the last on a loaded machine). The final `step` was not re-verified (about 35 minutes per run); the later edits changed only the exploration weighting (`ALL_GROUPS`, `env/readyTimeout` in the matchmaking group, a lobby/join branch for a playing user), not any command, environment step or invariant.

This is a shallow sanity check, not the safety argument. At depth 2 only two steps run from the initial state, and `system_small` has `MAX_PARTY = 1`, so it cannot reach two-player parties, found matches or running battles. Depth 3 was not attempted. Safety coverage for those states comes from the `quint test` transcripts and the `quint run` simulation below.

### Check run

One full `./check.sh` over every file with the default `SEED=1` (commit `eb48d7d`, 60 min 24 s): 423 ok, 0 FAIL.

| File | ok |
|---|---|
| system | 83 |
| lobby | 84 |
| autohost | 59 |
| party | 41 |
| clan | 41 |
| matchmaking | 38 |
| friend | 31 |
| session | 24 |
| messaging | 20 |
| common, schema | 1 each (typecheck) |

Deep witnesses need tens of thousands of traces; their directives carry explicit bounds. With a fixed seed the run is reproducible. Another seed (`SEED=n ./check.sh`) can miss a witness near its bound; that is a sampling miss, not a property violation.

Integration changes in the other modules are listed under "Integration changes" (Model notes) in findings/lobby.md, party.md, matchmaking.md, session.md, messaging.md, friend.md and autohost.md.
