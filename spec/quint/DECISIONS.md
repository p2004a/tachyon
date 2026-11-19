# Open protocol decisions

Where Tachyon (`docs/`, `schema/`) contradicts itself or is silent, the model had to pick a rule. Each
row is one decision for the protocol owners. "Model now" is what the `.qnt` files implement today; a
different answer changes the definitions and findings entries listed in the last column.

`PD-nn` ids are proposed protocol defaults: rules not yet in Tachyon. Findings files cite them as
`Proposed default (PD-nn)`. An implementation that differs from a PD is noted, not counted as a bug.

Lower-priority modelling choices are the `Kind: Assumption` entries in `findings/*.md`.

## A. Contradictions in Tachyon text

These need a text fix whichever way they are decided.

| # | Decision | Model now | Alternatives | Entries |
|---|---|---|---|---|
| 1 | **PD-05** `matchmaking/queue` while already queued. The description says it "should cancel the previous queue"; the schema also has `already_queued`. | Replaces the ticket while searching; `already_queued` once a match is found (ready check or starting). | Always replace; always refuse. | MM-01, MM-16, MM-29 |
| 2 | Ready-check timeout. `ready.ts:8` says the queue "should be cancelled"; matchmaking README says "the queueing phase should resume". | Everyone gets `lost`; non-ready players get `cancelled(ready_timeout)`; their ready party mates get `cancelled(party_user_left)`; fully ready tickets resume searching. | Cancel everyone; resume everyone; `ready_timeout` for the whole party. | MM-08 |
| 3 | `message_too_long` vs the request schema's `maxLength`: a schema-validating server can never return the reason. | Returns `message_too_long`, checked before the target. | Drop `maxLength` (the limit becomes a server setting); drop the reason. Also: code points or bytes; check order. | MSG-01 |
| 4 | `system/disconnect` while playing. Session semantics end the session; lobby and matchmaking treat it as a no-op in a battle. | Session ends; battle participation is kept on the autohost side, so an offline user can be in a battle. | Refuse while playing; end battle participation; restore `currentBattle` on next login. | INT-07 |
| 5 | A failed autohost start. Lobby: silent and final. Matchmaking: "the server should repeat this step", with no bound. | Lobby: silent failure. Match: retry with a fresh battle id; on give-up, `lost` + `cancelled(server_error)`. | One rule for both: N retries, then a user-visible failure. | INT-09, MM-13, LOBBY-21 |

## B. Session lifecycle (Tachyon is silent)

| # | Decision | Model now | Alternatives | Entries |
|---|---|---|---|---|
| 6 | **PD-01** A second connection for the same user. | Takeover: the new connection replaces the old; the session and its memberships survive. | Refuse the new connection; start a fresh session. | SESSION-01 |
| 7 | **PD-02** Session grace period after a socket drop. | The session goes Detached; party, invites and queue ticket survive until expiry; a Detached player fails the ready check; presence turns `offline` only at expiry. Duration not modelled. | No grace (socket = session); grace that drops queue/party at once. Also: the duration and the client liveness bound. | SESSION-02, PARTY-19, INT-04 |
| 8 | **INT-D2** A Detached player in a running battle. | Keeps the session past grace; grace restarts when the battle ends. | Expire anyway (battle continues server-side); resume the old timer. | INT-D2, INT-02 |
| 9 | **PD-08** What the server resends after a reconnect. | `user/self`, then a full `user/updated` for every subscription; the client resets its view on `user/self`. | Client re-subscribes and re-requests; deltas only. Also: how a client tells a resumed session from a fresh one. | SESSION-05, LOBBY-25, PARTY-19 |

## C. Activities and matchmaking

| # | Decision | Model now | Alternatives | Entries |
|---|---|---|---|---|
| 10 | **PD-03** Can a user be in a lobby, a matchmaking ticket and a matchmaking battle at once? | At most one ("activity slot"). Queueing from a lobby and lobby create/join while queued fail with `invalid_request`; queueing in a battle fails with `already_in_battle`. | Allow overlap and define what a match start does to a lobby seat. | LOBBY-03, MM-04, MM-17, INT-01, INT-03 |
| 11 | Reasons for activity-slot refusals (follows #10). | `invalid_request`. | Add `in_matchmaking` / `already_in_battle` to lobby/create and lobby/join, `in_lobby` to matchmaking/queue. | INT-10 |
| 12 | **INT-D3** How long a queued party is locked (no membership changes or invites). | From queue until battle start, or until the party withdraws (cancel, decline, leave, kick, session end, ready timeout, start give-up). | Unlock at match found; no lock at all. | INT-D3, PARTY-14 |

## D. Battles and autohost

| # | Decision | Model now | Alternatives | Entries |
|---|---|---|---|---|
| 13 | **PD-09** A retried `autohost/start` answered with `battle_already_exists`. | Treated as unknown: kill the battle and fail the start; matchmaking retries on another autohost. | Treat as success; adopt the existing battle. | AH-05, MM-13, MM-23 |
| 14 | **PD-10** Battles when their autohost disconnects. | Survive for an autohost grace period, then are closed as lost and the players' slots freed. | End at once (teiserver drops them after 100 ms). | AH-01 |
| 15 | **PD-11** Battle result from per-player finished reports. | Strict majority over all battle players, else no result (a 1v1 with two disagreeing reports has none). | Majority of the players who reported; autohost-reported result only. | AH-08 |

## E. Limits and settings

| # | Decision | Model now | Alternatives | Entries |
|---|---|---|---|---|
| 16 | **PD-04** Lobby size limit. | At most 256 members, players and spectators together (small constant in the model). | teiserver's 251 including bots (engine limit); a server setting. | LOBBY-10 |
| 17 | **PD-06** Mutual friend requests. | The second request accepts the first; both users get `requestAccepted`. | Refuse the second as a duplicate. | FRIEND-07 |
| 18 | **PD-07** Party invite timeout, party `maxMembers`, friend capacities. | Server settings (model constants). | Fixed values in Tachyon. | FRIEND-03 |
