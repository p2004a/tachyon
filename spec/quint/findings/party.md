# Party: findings

## Scope

`party.qnt` models the whole party group: requests `party/create`, `party/invite`,
`party/acceptInvite`, `party/declineInvite`, `party/cancelInvite`, `party/kickMember`,
`party/leave`; events `party/invited`, `party/updated`, `party/removed` (each carrying
what the schema says: `PartyState` = id, members, invited, or `partyId`); and
environment steps `env/inviteTimeout` (per-invite timer, identified by an invite
generation), `env/disconnect` (socket drops, session in grace), `env/reconnect`
(session reattached; `user/self` resyncs the client), `env/sessionExpired` (grace
over, or `system/disconnect`), `env/connect` (fresh session), `env/partyQueued` /
`env/partyUnqueued` (the matchmaking module's view of the party) and
`env/partyCrashed`. It grows the reference slice `party_invites.qnt` (left unchanged).
It also models a **client view** per user (current party + parties invited to,
i.e. `user/self`'s `party`/`invitedToParties`), updated only from replies, party
events and `user/self` on (re)connect. The invariant `clientViewsAgree` says every
connected user's view equals the server state. So each member's view after its
last `party/updated` equals the party's server state.
Abstracted: timestamps (`joinedAt`, `invitedAt`), `maxMembers` (constant
`MAX_MEMBERS`), timer durations, party chat, matchmaking internals (assets
check, `queuesJoined`), lobby interplay. Constants: `party3` = 4 users,
`MAX_MEMBERS = 3` (transcripts, simulation, witnesses); `party2` = 2 users,
`MAX_MEMBERS = 2` (Apalache). `Outcome` has an extra `why` field naming the
branch taken. It is only used by transcripts and coverage witnesses.

Checked: `./check.sh party.qnt`: typecheck, 12 transcripts, `safety` over 20000
samples × 30 steps (about 10 s), and 37 witnesses: 40 result lines, all `ok`, in about 3 min. `VERIFY=1`: `quint verify
--main=party2 --invariant=safety --max-steps=2` passes in 5.6 min (with `JVM_ARGS=-Xmx10G`; see the end of this file).

## Findings

### PARTY-01: Party requests can only fail with generic reasons (reference-slice finding 1)
- Kind: Gap
- Evidence: tachyon `schema/party/{create,invite,acceptInvite,declineInvite,kickMember,leave}/response.json`:
  the reason enums are only `internal_error, unauthorized, invalid_request, command_unimplemented`. So
  "already in a party", "not in a party", "target not connected", "already invited", "party full",
  "party in matchmaking", "not invited", "target not a member" all become `invalid_request`.
  Only `cancelInvite` has specific reasons (`not_in_party`, `invalid_invite`).
  teiserver confirms this: `tachyon_handler.ex:695-696` (`"Already in a party"`), `:708-712`, `:726-731`
  (`"User with id … isn't valid or connected"`, everything else `inspect(reason)`), `:742`, `:754`, `:764`,
  `:774`. All of them are `:invalid_request`, with the cause only in `details`.
- Spec choice: every such denial is `Failed("invalid_request")`. The model's `why` tells them apart
  (`already_in_party`, `not_in_party`, `target_not_connected`, `already_member_or_invited`,
  `party_in_matchmaking`, `party_full`, `not_invited`, `kick_self`, `target_not_member`).
- To verify: should the schema add `party_full`, `not_in_party`, `already_in_party`,
  `invalid_target`/`not_connected`, `not_invited`, `party_in_matchmaking`, as cancelInvite already does?
  bar-lobby can only show a generic error (`alertRequestFailure(error, "party/invite")`,
  `usePartyInviteState.ts:30`). To work around this it re-implements the capacity rule client-side
  (`usePartyInviteState.ts:13-16`).

### PARTY-02: On invite, members get party/invited (event text) or party/updated (README)? (reference-slice finding 2)
- Kind: Contradiction (+ Divergence-teiserver from the event text)
- Evidence: `docs/schema/party.md:825` / `src/schema/party/invited.ts:9`: "A player has been invited to the party.
  Sent to the invited player and all party members." But `docs/schema/party.md:15`: "Any change to the party
  member or the pending invites is propagated with a party/updated event sent to all connected members and
  invited players." In addition, `src/schema/party/updated.ts:8` describes party/updated as "New player joined the party
  (accepted an invite)", which is narrower than the README.
  teiserver `party/server.ex:264-267`: "# don't send the updated event to the newly invited player" → `party_notify_updated`
  to existing invitees and members. `session.ex:847` sends `party/invited` only to the target. Test
  `party_test.exs:83-110` asserts the target gets `party/invited` and the members and earlier invitees get `party/updated`.
  The reference slice sent `Invited` to members + target and nothing to the earlier invitees.
- Spec choice: `invite`: the target gets `party/invited`. The other connected members and invitees get `party/updated`
  (the same PartyState). This is the reading that keeps `clientViewsAgree`.
- To verify: fix the `party/invited` description to "Sent to the invited player", and the `party/updated`
  description to "the party state changed (members or pending invites)".

### PARTY-03: Accepting an invite while in another party (reference-slice finding 3)
- Kind: Gap (+ Divergence-teiserver for failed accepts)
- Evidence: Tachyon only says "A player can only be in at most one party at any given time." (`party.md:10`). It does
  not say whether acceptInvite fails or switches parties. teiserver switches: `session.ex:855-868` calls
  `do_leave_party` first, then `Party.accept_invite`. Test `party_test.exs:182` "accepting invite makes user leave other
  party". bar-lobby relies on this: `logic/party.ts:55-67` "if the user is currently in a party, this will also remove them
  from that first party", "teiserver leaves the old party on accept but sends us no party/removed for it, so it goes
  here". The reference slice denied (`partiesOf(s, u) != Set()` → `invalid_request`).
  **Bug:** teiserver leaves the old party *before* checking the invite (`session.ex:856-870`). So a failed accept
  (invite expired, cancelled or raced) still removes the user from its party (and cancels its matchmaking
  with `party_user_left`, `session.ex:1932-1937`), even though the reply is `failed`. bar-lobby
  (`logic/party.ts:61-67`) throws before `removeParty(previousParty)`, so it keeps showing the old party. The client
  is out of sync until the next `user/self`.
- Spec choice: ASSUMPTION. `accept` leaves the current party first (`why = "switched"`). The old party's audience
  gets `party/updated`, or its invitees get `party/removed` if it disbands. The accepter gets no `party/removed`
  and drops its old party on the Ok reply (`onReply`). A denial changes nothing (`deniedIsInert`).
- To verify: confirm the switch semantics in party.md. teiserver test: invite X to P, cancel it, X (member of Q)
  accepts P → expect `failed` and X still a member of Q.

### PARTY-04: party/leave is not a party/removed trigger; the leaver learns from the reply (reference-slice finding 4)
- Kind: Gap (resolved by teiserver and bar-lobby agreeing)
- Evidence: `src/schema/party/removed.ts:9`: "Client has been removed from the party. Either kicked, the invite was
  cancelled or the party disapeared." `party.md:26-29` adds "times out" and "when the party dies (crash or last member
  leaves)". Leaving is not listed. teiserver sends nothing to the leaver (`events/leave.ex:21-37`, `session.ex:1923-1931`
  demonitors `:current_party` before the party stops). bar-lobby clears the party itself after the reply
  (`logic/party.ts:132-137`). The reference slice sent `Removed` to the leaver.
- Spec choice: `leave` sends no `party/removed` to the leaver (`removeMember(…, removedToU = false)`). The same holds
  for the accept-switch and for session expiry. Kick sends it (`removedToU = true`). "party dies (… last member
  leaves)" means the *invitees* get `party/removed` (teiserver test `party_test.exs:463`).
- To verify: say in party.md that the leaver is not sent party/removed.

### PARTY-05: Late and stale invite timers; teiserver keys timers by user, so an old timer can expire a new invite (reference-slice finding 5)
- Kind: Divergence-teiserver
- Evidence: Tachyon: "Invites will time out after a while." (`party.md:21`). teiserver arms
  `:timer.send_after(…, {:invite_timeout, user_id})` (`party/server.ex:249`). The handler only looks up by user:
  `case Map.get(data.invited, user_id)` → `cancel_invite_internal` (`:450-459`). The timer is cancelled on decline
  (`:301`) and cancel/timeout (`:580`), but **not** on accept (`:279-291`, the invite is popped without
  `:timer.cancel`) and not when the invitee's session dies (`:471-473`). Then: B accepts, leaves, and is re-invited
  within the window. The *old* timer fires and cancels the *new* invite early (party/removed to B).
  A truly late fire (no invite) is a no-op, as the slice required.
- Spec choice: each invite has a generation (`Party.invited: UserId -> int`). `inviteTimeout(s, id, t, gen)` only
  acts on the matching generation. Otherwise it is a no-op (`late_timer`, `stale_timer_reinvited`). Transcript
  `lateTimerTest`. Mutation M5 (teiserver's keying) is caught only by the transcript, because an early expiry does not
  break any state invariant.
- To verify: teiserver test: invite B, B accepts, B leaves, re-invite B, send the first `{:invite_timeout, B}`. The
  invite must survive. Fix: cancel the timer on accept and on invitee DOWN, or put the timer ref in the message.

### PARTY-06: cancelInvite: teiserver never uses the schema's specific reasons
- Kind: Divergence-teiserver
- Evidence: schema `cancelInvite/response.json` lists `not_in_party`, `invalid_invite`. teiserver
  `tachyon_handler.ex:759-767` maps every error to `:invalid_request` (`session.ex:914-916` returns `:not_in_party`,
  `party/server.ex:320` returns `:not_invited`). Tests `party_test.exs:257-272` assert `invalid_request`.
- Spec choice: `cancel`: the caller is in no party → `not_in_party`. The target has no pending invite to the caller's
  party → `invalid_invite`.
- To verify: change the handler to map `:not_in_party` → `not_in_party` and `:not_invited` → `invalid_invite`, and update
  the tests.

### PARTY-07: "connected" invite target: teiserver accepts users whose socket dropped (session in grace)
- Kind: Divergence-teiserver (and Assumption on the meaning of "connected")
- Evidence: `party.md:18` "Any player in a party can invite any other connected player". teiserver checks that the
  target's *session process* exists (`session.ex:813-831`, `:noproc` → `:invalid_player`). A session in its 30 s grace
  (`session.ex:47`, `:1563-1571`) or in a battle (no timeout at all, `:1569`) accepts the invite. The
  `party/invited` event is then dropped (`send_to_player!`, `session.ex:1950-1959`: "doesn't persist the message
  if there's no connection"). The user only sees it in `user/self.invitedToParties` after reconnecting.
  Test `party_test.exs:57` "must be online" only covers a user with no session.
- Spec choice: ASSUMPTION PARTY-A2. Connected = socket up (`Online`). Inviting a `Detached` user is denied
  (`target_not_connected`, transcript `presenceTest`).
- To verify: does "connected" mean "has a session" or "socket up"? If "has a session", then party.md should say the
  invite is delivered via user/self after reconnect.

### PARTY-08: Self-kick allowed by teiserver; kicking yourself as the last member leaves an empty, undying party
- Kind: Divergence-teiserver
- Evidence: `party.md:23` "Any member in a party can kick any other member". teiserver `party/server.ex:328-349` has
  no `actor_id != target_id` check and, unlike leave (`:515-516` `:empty` → stop), no empty-party check after a kick.
  A lone member kicking itself gets `party/removed` (via `session.ex:1469-1476`). The party process stays alive with
  `members == %{}` and its invitees can still accept and become members of it. With no invitees, it leaks forever
  (no member monitor left). bar-lobby hides the kick button for oneself (`components/party/PartyMember.vue:63`
  `showKickButton = me.userId !== props.userId`).
- Spec choice: ASSUMPTION. `kick` denies `t == u` (`kick_self`, `invalid_request`). `wellFormed` requires `members != {}`.
- To verify: teiserver test: create a party, kick yourself → expect `failed`, or treat it as a leave.

### PARTY-09: A user may hold invites to several parties at once, also while a member
- Kind: Gap (answered by schema shape and teiserver)
- Evidence: `schema/definitions/privateUser.json:15-18` `invitedToParties: PartyState[]`. teiserver
  `session.ex:839-841` keeps a list. Test `party_test.exs:154` "accepting invite doesn't revoke other invites".
  bar-lobby `store/party.store.ts:18` "All parties (all invited, and up to one joined)", `PlayersPartyState.JoinedAndInvited`.
  party.md says nothing about it.
- Spec choice: allowed. Accepting one invite keeps the others. Witnesses `multiInvites`, `memberAndInvited`.
  Transcript `acceptSwitchesPartyTest`.
- To verify: state it in party.md.

### PARTY-10: party/leave while not in a party: a no-op (schema source) vs invalid_request (teiserver)
- Kind: Contradiction (source comment not in the generated docs) + Divergence-teiserver
- Evidence: `src/schema/party/leave.ts:8-10`: "// no failed/not_in_party status. Calling this request while not in a
  party is a no-op". This comment is not in `docs/schema/party.md` or the JSON Schema. teiserver
  `tachyon_handler.ex:708-709` → `invalid_request "Not in a party"`. Test `party_test.exs:38` "must be in party". The
  reference slice also denied.
- Spec choice: `leave` while in no party → `Ok`, no change (`not_in_party_noop`).
- To verify: pick one. If no-op, fix teiserver and the test. If an error, delete the comment and say so in party.md.

### PARTY-11: Who may kick or cancel: any member, with no leader
- Kind: Gap (consistent everywhere)
- Evidence: `party.md:19` "Any pending invite can be cancelled by any member in the party". `:23` "Any member in a party
  can kick any other member". `:33` "this spec doesn't have any concept of leader, any party member can do all actions".
  teiserver: an invitee cannot cancel (`session.ex:914`, test `party_test.exs:262`) and an invitee cannot be kicked
  (`party/server.ex:336`, test `:372`). bar-lobby shows kick and cancel buttons to every member
  (`PartyMember.vue:10`, `PartyInvitee.vue:10`).
- Spec choice: any member may cancel any pending invite of its party and kick any other member (even the founder:
  `kickTest`). Invitees may do neither.
- To verify: nothing, unless leaders are introduced.

### PARTY-12: Disbanding: what happens to pending invites
- Kind: Gap (answered by README + teiserver)
- Evidence: `party.md:26-29` (party/removed "when the party dies (crash or last member leaves)"). teiserver: the party
  stops (`party/server.ex:488-490`). Each invitee's session gets `DOWN {:invited_to_party, id}` and sends `party/removed`
  (`session.ex:1631-1643`). Tests `party_test.exs:463` and `:479` (crash: members and invitees get party/removed).
- Spec choice: `removeMember` on the last member deletes the party and sends `party/removed` to the connected invitees.
  `partyCrashed` sends it to all connected members and invitees. Invites to a dead party cannot be accepted
  (`not_invited`).
- To verify: nothing.

### PARTY-13: A kicked member's session keeps monitoring the old party: if that party later dies, party/removed with partyId null
- Kind: Divergence-teiserver
- Evidence: `session.ex:1469-1476`, on `{:removed, …}` for the current party: sets `current_party: nil` but does not
  demonitor `:current_party` (compare `do_leave_party`, `:1929`). If the old party later terminates while the user is in
  no party, `session.ex:1615-1624` matches `%PT.PartyState{current_party: party_id}` with `party_id = nil` and sends
  `party/removed {partyId: nil}`. That breaks the schema (`partyId` is a string). The monitor is only replaced if the user
  creates or joins another party (Bimap re-keying, `helpers/bimap.ex:22-60`).
- Spec choice: `party/removed` only goes to users who were in that party's audience (`eventPayloadsAreCurrent`).
- To verify: teiserver test: A and B in a party, A kicks B, then A leaves. B must receive nothing.

### PARTY-14: Party in matchmaking: invites are cancelled and refused; a membership change cancels matchmaking for all
- Kind: Gap (Tachyon party.md is silent; matchmaking README covers only "a member leaves") + Assumption
- Evidence: matchmaking README (`src/schema/matchmaking/README.md:13,19-20`): cancelled "can happen for example when a
  party member leaves", `party_user_left`: "a member of the player's party left matchmaking, thus forcing the entire
  party to withdraw". teiserver `party/server.ex:128-133`: "Once the party is in matchmaking, it is "locked", all
  invites are cancelled and no new invites can be sent". `:227-228` (`:party_in_matchmaking` → `invalid_request`),
  `:395-399`. Tests `party_matchmaking_test.exs:129,145`. Leave: `session.ex:1932-1937` (the leaver gets
  `cancelled{party_user_left}`, test `:106`). bar-lobby `usePartyInviteState.ts:22-28` does not hide "invite" while
  queued.
- Spec choice: ASSUMPTION. `partyQueued` cancels pending invites (party/removed to invitees, party/updated to members).
  `invite` is denied while queued (`party_in_matchmaking`). Any membership change (leave, kick, switch, session expiry)
  unqueues the party and sends `MatchmakingCancelled` (= matchmaking/cancelled party_user_left) to every connected old
  member (`queuedChangeCancels`, `queuedMembershipStable`).
- To verify: add the "locked while queued" rule to party.md, and say whether `kickMember` counts as "leaves".

### PARTY-15: teiserver never unlocks the party after a member leaves the queue or a match is found
- Kind: Divergence-teiserver (from reading code. No test covers it)
- Evidence: the party's `matchmaking` field is reset only by `Party.matchmaking_notify_cancel` (`party/server.ex:437-448`)
  or a queue-process DOWN (`:479-480`). `matchmaking_notify_cancel` is called only from pending-party removal
  (`queue_server.ex:651`) and pairing-room cancel/timeout (`pairing_room.ex:227,252`). It is not called from
  `remove_member` (`queue_server.ex:613-640`). That function is the path for `matchmaking/cancel`, `party/leave`
  (`session.ex:1932`) and member session death (`queue_server.ex:484`). It is also not called when a match succeeds. Then
  the party stays "in matchmaking": further `party/invite` fail (`party_in_matchmaking`) and `matchmaking/queue` fails
  `already_queued` (`party/server.ex:352-359`) until the queue process dies. Test `party_matchmaking_test.exs:90`
  ("one member leaving matchmaking …") stops before trying to invite or queue again.
- Spec choice: `partyUnqueued` and every membership change clear `queued`.
- To verify: teiserver test: a 2-member party queues, m1 sends `matchmaking/cancel`, then m1 sends `party/invite` → expect
  `success`.

### PARTY-16: kickMember of a queued party member: teiserver leaves the kicked user in the queue
- Kind: Divergence-teiserver
- Evidence: `party/server.ex:328-349`: kick does not touch `data.matchmaking`. The kicked session's
  `handle_cast({:party, {:removed, …}})` (`session.ex:1469-1476`) does not call `leave_matchmaking`. So the queue's
  `Member{player_ids, party_id}` still includes the kicked user, who is matched with a party it is no longer in.
  Leave does cancel (`session.ex:1932-1937`).
- Spec choice: `kick` goes through `removeMember`, the same as leave: unqueue and `MatchmakingCancelled` to all old members
  (`queuedChangeCancels`).
- To verify: teiserver test: a 2-member party queues, m1 kicks m2 → both get `matchmaking/cancelled`.

### PARTY-17: Leave event demonitors the wrong key → spurious party/updated later
- Kind: Divergence-teiserver (minor)
- Evidence: `party/events/leave.ex:33` `MC.demonitor_by_val(&1, ev.leaver_id)`. The member monitors are stored under
  `{:member, user_id}` (`party/server.ex:569`), so the monitor survives the leave. When the ex-member's session later ends,
  `DOWN {:member, id}` runs `Map.delete` (no-op) and `notify_updated()` (`:475-477`). That sends an unchanged
  party/updated to everyone, without a version bump.
- Spec choice: no such event (`oneEventPerPartyAndRecipient`, `clientViewsAgree` are insensitive to a duplicate, but
  the model has no step that emits it).
- To verify: change it to `demonitor_by_val(&1, {:member, ev.leaver_id})`.

### PARTY-18: Session handlers reply with a 2-tuple on error paths
- Kind: Divergence-teiserver (crash, minor)
- Evidence: `session.ex:827` `:exit, {:timeout, _details} -> {:reply, {:error, :timeout}}` (the invite deadlock path)
  and `:704` `{:reply, {:error, "not in party"}}`. Both lack the state element, so the session GenServer crashes with a
  bad return instead of replying. A session crash drops the user from its party and from matchmaking.
- Spec choice: n/a (no internal_error modelled).
- To verify: add the `state` element.

### PARTY-19: Events to detached members are dropped; user/self on reconnect is the repair
- Kind: Assumption (consistent with design default and both implementations)
- Evidence: `party.md:15` "sent to all connected members and invited players". teiserver `send_to_player!`
  (`session.ex:1950-1959`): "player get full party state upon connection, so party events can be not persisted". On
  reconnect: `build_self_state` (`session.ex:1816-1826`) puts `party`/`invitedToParties` in `user/self`
  (`tachyon_handler.ex:1111-1112`). Test `party_test.exs:518`. bar-lobby keeps its store across a socket drop
  (`logic/connection.ts:112-114`) and replaces it on `user/self` (`logic/party.ts:172-178` `replaceAll`).
- Spec choice: ASSUMPTION PARTY-A1. Membership survives `env/disconnect`. Events go only to `Online` users
  (`eventsReachConnectedOnly`). `env/reconnect` resets the view from server state. `clientViewsAgree` is required only
  for connected users. Witness `detachedViewStale` shows a detached view really goes stale.
- To verify: nothing, as long as user/self keeps carrying the full party state (user group).

### PARTY-20: Creating a party / accepting an invite cancels the user's solo matchmaking
- Kind: Gap (cross-module, teiserver behaviour)
- Evidence: `session.ex:784-791` (create) and `:883-890` (accept) call `leave_matchmaking` and send
  `matchmaking/cancelled {reason: intentional}`. Tests `party_matchmaking_test.exs:158,170`. Neither party.md nor the
  matchmaking README mentions it, and the reason `intentional` ("the player left matchmaking") is a stretch.
- Spec choice: not modelled here (solo queue state belongs to matchmaking). Stated as interface predicate I3 below.
- To verify: document it in matchmaking README. Should it be `party_user_left` or a new reason?

### PARTY-21: Implementations otherwise match the model (per command)
- Kind: Divergence check (no divergence beyond the above)
- create: teiserver `session.ex:772-795` (already in party → invalid_request). The reply has `party: PartyState`
  (`tachyon_handler.ex:691-693`). bar-lobby `setParty(response.data.party)` (`logic/party.ts:82-87`). Matches.
- invite: guards in `party/server.ex:239-244` (member/invited → `:already_invited`; `invited + members >= max_members`
  → `:party_at_capacity`). Matches `invite` apart from PARTY-07 and PARTY-14. bar-lobby: success only means "pending
  invite created" (`logic/party.ts:117`).
- acceptInvite: apart from PARTY-03, the members and remaining invitees get party/updated including the new member
  (`party/server.ex:290`). bar-lobby `setParty` on party/updated works because `settle` (`party.store.ts:29-49`) derives
  joined/invited from the payload.
- declineInvite: `party/server.ex:295-314` cancels the timer and notifies the members and remaining invitees. No event to
  the decliner. bar-lobby removes it itself (`logic/party.ts:106-107`). Matches.
- cancelInvite: party/removed to the target, party/updated to the rest (`party/server.ex:579-590`). Matches apart from
  PARTY-06.
- kickMember: party/removed to the target, party/updated to the rest (`:346-347`). Matches apart from PARTY-08/16.
- leave: matches apart from PARTY-10/17. bar-lobby `removeParty(activeParty)` after Ok.
- timer: matches apart from PARTY-05. Test `party_test.exs:311` (party/updated to the members, party/removed to the target).
- session end: `DOWN {:member}` / `{:invite}` → party/updated (`party/server.ex:462-486`). The last member → stop → the
  invitees get party/removed. Grace is 30 s and never runs while in battle (`session.ex:1569-1571`, `:1695-1702`).
  Matches `sessionExpired`.
- bar-lobby has no version or ordering check on party/updated (Tachyon PartyState has no version, and teiserver drops
  stale versions server-side, `session.ex:1452-1466`). A single ordered socket makes this safe.

## Coverage

All rows below are witnessed (`// @witness`, `hit(cmd, why)`) unless marked otherwise. "Reason" is the wire reason.

| Command | Outcome (`why`) | Reason | Status |
|---|---|---|---|
| party/create | created | Ok | witnessed |
| party/create | already_in_party | invalid_request | witnessed |
| party/invite | invited | Ok | witnessed |
| party/invite | not_in_party | invalid_request | witnessed |
| party/invite | target_not_connected | invalid_request | witnessed |
| party/invite | already_member_or_invited (incl. self) | invalid_request | witnessed |
| party/invite | party_in_matchmaking | invalid_request | witnessed |
| party/invite | party_full | invalid_request | witnessed |
| party/acceptInvite | joined | Ok | witnessed |
| party/acceptInvite | switched (left another party) | Ok | witnessed |
| party/acceptInvite | not_invited (incl. unknown party) | invalid_request | witnessed |
| party/declineInvite | declined | Ok | witnessed |
| party/declineInvite | not_invited | invalid_request | witnessed |
| party/cancelInvite | cancelled | Ok | witnessed |
| party/cancelInvite | not_in_party | not_in_party | witnessed |
| party/cancelInvite | not_invited | invalid_invite | witnessed |
| party/kickMember | kicked | Ok | witnessed |
| party/kickMember | not_in_party | invalid_request | witnessed |
| party/kickMember | kick_self | invalid_request | witnessed |
| party/kickMember | target_not_member | invalid_request | witnessed |
| party/leave | left | Ok | witnessed |
| party/leave | disbanded | Ok | witnessed |
| party/leave | not_in_party_noop | Ok | witnessed |
| env/inviteTimeout | expired | — | witnessed |
| env/inviteTimeout | stale_timer_reinvited | — | witnessed |
| env/inviteTimeout | late_timer | — | transcript `lateTimerTest` (trivially reachable) |
| env/disconnect / reconnect / sessionExpired / connect | detached / reattached / expired_session / connected | — | witnessed |
| env/partyQueued / partyUnqueued / partyCrashed | queued / unqueued / crashed | — | witnessed |
| (state) | fullParty, multiInvites, memberAndInvited, detachedViewStale, queuedMemberLeft | — | witnessed |
| any party request | internal_error, unauthorized, command_unimplemented | — | unreachable: no crashes, scopes or unimplemented commands are modelled |

## Seeded mutations

Each mutation is a single-line change, run with `quint test` plus `quint run --invariant=safety` (20000 × 30) on a
scratch copy, and then reverted (the script is in the session scratchpad).

| # | Mutation | Caught by |
|---|---|---|
| M1 | `dropInvite` sends party/updated to members only (the reference slice's timeout behaviour) | transcript `timeoutUpdatesOtherInviteesTest`; simulation: `clientViewsAgree` (the other invitee's view goes stale) |
| M2 | `removeMember` keeps `queued` | transcript `matchmakingTest`; simulation: `queuedMembershipStable` |
| M3 | capacity check `>=` → `>` | transcript `inviteAcceptLeaveTest`; simulation: `wellFormed` |
| M4 | `accept` does not leave the old party | transcript `acceptSwitchesPartyTest`; simulation: `atMostOneParty`, `clientViewsAgree` |
| M5 | invite timer keyed by user only (teiserver, PARTY-05) | transcript `lateTimerTest` only. `safety` still holds, because an early expiry is a legal-looking state (this is why PARTY-05 needs a teiserver test) |
| M6 | events also delivered to detached users (`sendOn` ignores presence) | transcript `presenceTest`; simulation: `eventsReachConnectedOnly` |
| M7 | kicked member not sent party/removed | transcript `kickTest`; simulation: `clientViewsAgree` (the kicked user still shows the party) |

## Cross-module interface

Predicates this module assumes about, or guarantees to, other groups' state (names as in `party.qnt`):

- I1 (session/user/system → party): `presence(u) ∈ {Online, Detached, Offline}`. Only `Online` users send requests and
  receive events. `Detached` users keep membership and invites (`sessionsOwnParties`: every member and invitee
  has `presence != Offline`). On reconnect, `user/self.party == serverView(s,u).party` and
  `user/self.invitedToParties == serverView(s,u).invites`. A new connection that replaces an old one behaves as
  disconnect followed by reconnect. `system/disconnect` behaves as `sessionExpired` immediately.
- I2 (matchmaking → party): `queued(p)` is set by the matchmaking module (`env/partyQueued`) only for an existing
  party with `not queued(p)`. That module should only do so when every member is `Online` and passed checkAssets
  (`matchmaking/queue` precondition, not checked here). It is cleared by `env/partyUnqueued` on cancel / match found / ready
  timeout.
- I3 (party → matchmaking): for every party `p`,
  `queued(p) ⇒ invited(p) = ∅` and `queued(p) ⇒ members(p) unchanged since queueing` (`queuedMembershipStable`).
  Any membership change of a queued party unqueues it and sends `matchmaking/cancelled{party_user_left}` to every
  connected old member (`queuedChangeCancels`). Each matchmaking ticket of a party member equals the party's ticket:
  `∀u. inQueue(u) ∧ partyOf(u) = p ⇒ queued(p)`. Creating a party or accepting an invite ends the user's *solo*
  matchmaking (`∀u. partyOf'(u) ≠ partyOf(u) ⇒ ¬soloQueued'(u)`, PARTY-20).
- I4 (lobby): the party module puts no constraint on lobby membership (party members may be in different lobbies or none).
  "used ... during lobby balancing" (party.md:7) is not modelled.
- I5 (messaging): party chat (`messaging/send` type party) is allowed for `u ∈ members(p)` only (teiserver
  `party/server.ex:415-417`).

## Requests to the orchestrator

- R1: `common.qnt` could export an `Outcome` with an optional `why`/cause field (several modules add one) and a
  presence type (`Online | Detached | Offline`) shared with friend/user/matchmaking, so that modules compose on one presence variable.
- R2: The matchmaking module should expose `partyQueued/partyUnqueued` effects consistent with I2/I3, and own the
  check that kicking a queued member cancels the queue (PARTY-16).
- R3: `VERIFY=1 ./check.sh party.qnt` needs a larger Apalache heap (`JVM_ARGS=-Xmx10G`), and should not run concurrently with
  other verify runs (they share one Apalache server).

## Bounded model checking note

`quint verify --main=party2 --invariant=safety --max-steps=2` → `[ok] No violation found (332650ms)` (run with
`JVM_ARGS=-Xmx10G`. With the default heap, one run died with "Ran out of heap memory", and another lost its connection to
the shared Apalache server while other agents were verifying). `--max-steps=3` did not finish in 10 min: Apalache was
still checking states at depth 3, and all invariants held so far. The costly conjuncts are `clientViewsAgree` (maps of
records) and `sessionExpired`'s fold. Depth ≥ 3 is covered only by simulation (20000 × 30 on `party3`).

