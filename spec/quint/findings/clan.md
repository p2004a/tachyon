# Clan: findings

## Scope

`clan.qnt` models the whole clan group from the protocol alone. Requests: `clan/create`,
`clan/update`, `clan/delete`, `clan/invite`, `clan/cancel`, `clan/accept`, `clan/decline`,
`clan/kick`, `clan/leave`, `clan/setRole`, `clan/view`, `clan/viewList`. Events: `clan/updated`,
`clan/deleted`, `clan/invited`, `clan/kicked`, `clan/roleChanged`. There are no environment steps:
clans are permanent, and the protocol defines no invite timeout (CLAN-09). State: clans by id, each
with a profile, a member map `userId -> {role, joinedAt}` and a set of invited users. `joinedAt` is a
logical clock, so "oldest" is well defined. `view`/`viewList` reply data is kept in `lastData`.
Abstracted away: the profile fields (name, tag, language, description) are one opaque value from
`PROFILES`, so length limits and uniqueness are not modelled (CLAN-A3). Presence is not modelled either:
events are addressed by audience, not by session (CLAN-12). Neither is `internal_error`/`command_unimplemented`.
Constants: `USERS = {a,b,c}`, `PROFILES = {p1,p2}`. A simulation-only knob `CHURN` is `true` in `clan_test`.
In `clan_grow` it is `false`: `step` is limited to create/invite/accept/setRole/leader-leave there, so
random runs reach the deep co-leader states. Every safety check runs in both instances.

Invariants in `safety`:
- `atMostOneClan`: a user is in at most one clan.
- `oneLeader`: every clan has members and exactly one `leader`. The protocol does **not** allow leaderless
  clans: every exit from the leader role either hands it on or removes the clan.
- `wellFormed`: invited ∩ members = ∅, roles in the enum, `joinedAt` unique.
- `reasonsInSchema`.
- `denialsInert`: a denial changes nothing and sends nothing.
- `permissionsRespected`: every success was allowed by the caller's role before the step.
- `eventsAudience`: each event reaches only the audience its schema description names.
- `eventsComplete`: updated/deleted reach all members, the kicked member is told, and no role changes silently.
- `successionFollowsRule`.
- `viewsAccurate`.

**Implementation status (CLAN-01): nothing of this group is implemented in teiserver or bar-lobby.**
Every clan request gets `command_unimplemented` from teiserver. bar-lobby sends no clan command and
handles no clan event. So the per-command "Divergence" entries below are all the same divergence
(CLAN-01). The rest of this file holds protocol gaps and assumptions to settle before anyone implements clans.

## Findings

### CLAN-01: Clans are unimplemented in teiserver and bar-lobby; every clan request replies command_unimplemented
- Kind: Divergence-teiserver, Divergence-bar-lobby
- Evidence: `grep -rn '"clan/'` finds nothing in teiserver `lib/`, `test/` or bar-lobby `src/`.
  teiserver's vendored schema `priv/tachyon/v0/schema/` has no `clan/` directory. So
  `Schema.parse_message` returns `{:missing_schema, ...}` and `lib/teiserver/tachyon/transport.ex:218-220`
  replies `Schema.error_response(command_id, message_id, :command_unimplemented)`. If the schema were
  vendored, the catch-all `lib/teiserver/player/tachyon_handler.ex:1096-1097`
  (`def handle_command(_command_id, ...) do {:error_response, :command_unimplemented, state}`) would answer
  the same. No clan event is ever sent. bar-lobby only carries a `clanId` field
  (`src/main/model/user.ts:20` `clanId: string | null;`, `src/renderer/store/db.ts:72`,
  `src/renderer/views/profile/[userId].vue:21` shows `user.clanId`).
- Per command, the reply on teiserver today is `Failed(command_unimplemented)` (allowed by every clan response schema):
  create, update, delete, invite, cancel, accept, decline, kick, leave, setRole, view, viewList.
  Events updated/deleted/invited/kicked/roleChanged are never sent. bar-lobby never sends any of the requests.
- Spec choice: the model is the protocol only. An implementation at its present state satisfies
  `reasonsInSchema` trivially and nothing else.
- To verify: none. Keep this file as the acceptance spec when clans are implemented.

### CLAN-02: teiserver and bar-lobby use `clanId` in user objects; the protocol has `clanBaseData`
- Kind: Divergence-teiserver, Divergence-bar-lobby (touches the user group)
- Evidence: tachyon `schema/definitions/user.json:9-26`: `"clanBaseData": { "anyOf": [ {clanId + name, tag,
  language}, { "type": "null" } ] }`, required. teiserver's vendored `priv/tachyon/v0/schema/definitions/user.json:9`
  `"clanId": { "anyOf": [{ "type": "string" }, { "type": "null" }] }`, and it sends `clanId: nil` in
  `user/updated` (`tachyon_handler.ex:217`), `user/info` (`:486`) and `user/self` (`:1108`).
  `clanInvites: []` carries the comment "TODO. For now it's just there so clients don't break on missing
  required property" (`:1118-1120`). bar-lobby `src/main/model/user.ts:20` `clanId: string | null`.
- Spec choice: `atMostOneClan` follows from `clanBaseData` being a single value (CLAN-A1).
- To verify: bump teiserver's vendored schema; bar-lobby should read `clanBaseData` (null-safe).

### CLAN-03: Several replies and events lack the clanId their consumers need
- Kind: Gap
- Evidence:
  - `clan/create` success has no data (`src/schema/clan/create.ts`: `response: [{ status: "success" }]`). The creator
    learns its clan id only through a `user/updated`/`user/self` carrying `clanBaseData`, and the clan group does not require that.
  - `clan/invited` data is `clanUpdateableBaseData` (`schema/clan/invited/event.json`: name, tag, language), with **no
    clanId**. `clan/accept` and `clan/decline` require `clanId`. So an invitee cannot answer the invite it was just
    told about. It can only guess from `privateUser.clanInvites` (`schema/definitions/privateUser.json:58-61`),
    which is only sent in `user/self` (on connect).
  - `clan/updated` data is `clanUpdateableData` without clanId (`schema/clan/updated/event.json`).
- Spec choice: model events carry the clan id (`Invited(c)`, `Updated(c)`) so that audiences can be checked.
  A comment on `type Event` records that the wire payloads lack it.
- To verify: add `clanId` to `clan/invited` (blocking: the invite flow cannot work without it), `clan/updated`
  and the `clan/create` response, and say whether `user/updated` is sent to the creator/joiner/leaver.

### CLAN-04: Prose names commands that do not exist (cancelInvite, acceptInvite, declineInvite, kickMember)
- Kind: Contradiction
- Evidence: `docs/schema/clan.md:15` "cancelled by [clan/cancelInvite] ... accept invitiation by
  [aclan/cceptInvite] ... decline by [clan/declineInvite]". `:17` "[clan/kickMember]". The schema ids are
  `clan/cancel`, `clan/accept`, `clan/decline`, `clan/kick`, so the anchors are dead links. The party group uses the
  long names (`party/cancelInvite`, ...).
- Spec choice: schema ids.
- To verify: fix `src/schema/clan/README.md`, or rename the commands to match party.

### CLAN-05: Who may cancel an invite is unstated
- Kind: Gap
- Evidence: `clan.md:15` "The invitation can be cancelled by clan/cancelInvite." `src/schema/clan/cancel.ts`
  "Cancel an invite to your clan."
- Spec choice (ASSUMPTION CLAN-A7, `cancel`): leader and co-leaders. A plain member gets `unauthorized`, and a
  caller in no clan gets `invalid_request`.
- To verify: state it, e.g. "the leader and co-leaders can cancel any pending invite".

### CLAN-06: Unauthorized vs invalid_request is not specified for clan-role checks
- Kind: Assumption (CLAN-A4)
- Evidence: `docs/commands.md:38` `unauthorized`: "When a client sends a request command of which they do not have the
  `role` required to use". That means the account role. `invalid_request`: "When the request command doesn't match
  the schema". The clan schemas list only the four generic reasons.
- Spec choice: an insufficient *clan* role gives `unauthorized` (update/invite/cancel for members; delete/kick/setRole for
  non-leaders). Every state-based denial gives `invalid_request`: not in a clan, unknown clan, not invited, target not a
  member, already a member, already invited, already in a clan.
- To verify: add specific reasons (`not_in_clan`, `already_in_clan`, `not_invited`, `insufficient_role`, ...). Clients
  cannot otherwise tell the cases apart.

### CLAN-07: No event tells anyone about join, leave, decline, cancel, kick or create, besides the actor or target
- Kind: Gap
- Evidence: the clan group has only five events. `clan/kicked` is "Sent to the kicked player". `clan/roleChanged`
  is "Sent to affected clan member". Nothing is sent on accept (new member), leave, decline, cancel, or create. Compare the
  party group, where `party/updated` goes to all members on every change.
- Spec choice: `accept`, `decline`, `cancel`, `leave` (non-leader), `create` send no events. `kick` sends `Kicked(c)`
  to the target only, and `setRole`/succession send `RoleChanged` only to the affected members. Remaining members
  see changes only by polling `clan/view`. `eventsAudience` pins this down.
- To verify: should remaining members (and the inviter) get something like `clan/updated` with members on
  join/leave/kick/role change? Does a cancelled invitee get an event to drop the invite from its UI?

### CLAN-08: Delete and last-member leave leave invitees with stale invites; deleted event audience
- Kind: Gap / Assumption (CLAN-A5)
- Evidence: `clan/deleted` "A clan was deleted. Sent to all clan members." `clan.md:25` "If the clan-leader leaves the
  clan and he is the last member the clan will be removed." Nothing covers pending invites, and nothing says whether
  the deleter is in "all clan members".
- Spec choice: `delete` sends `Deleted(c)` to every member including the caller (`eventsComplete`). Pending invites are
  dropped silently. Last-member `leave` removes the clan and sends nothing (the leaver gets `Ok`; there are no other members).
- To verify: send `clan/deleted` to invitees too, or define an invite-revoked event.

### CLAN-09: Clan invites never expire, and one user can hold invites from many clans
- Kind: Gap
- Evidence: party invites have a timeout (party.md). The clan docs say nothing. `privateUser.clanInvites` is an
  array, so many pending invites are allowed.
- Spec choice: no invite timer. Invites stay until accept/decline/cancel/delete. After joining a clan the user's other
  invites stay (CLAN-A8), and accepting them fails with `invalid_request` while the user is in a clan.
- To verify: set a timeout or a cap, or clear other invites on join.

### CLAN-10: One clan per user is implied, not stated
- Kind: Assumption (CLAN-A1)
- Evidence: `user.json` `clanBaseData` is one object or null. `clan.md` never says "a user can be in only one clan".
  `clan/update`, `clan/delete`, `clan/invite`, `clan/kick`, `clan/cancel`, `clan/leave` carry no clanId ("your clan").
- Spec choice: `create` and `accept` fail with `invalid_request` while the caller is in a clan (`atMostOneClan`).
  Inviting a member of another clan is allowed (CLAN-A6, witnessed `wAcceptWhileInClan`).
- To verify: state the rule. Also say whether inviting someone who is already in a clan should be refused upfront.

### CLAN-11: setRole semantics: what the old leader becomes, demotion, self-target, and a redundant clanId
- Kind: Gap / Assumption (CLAN-A11)
- Evidence: `clan.md:19` "appoint members as clan co-leader ... transfer his leadership role to a different member
  with the same command. (ATTENTION: By executing this command the clan leader loses his permissions!)".
  `clan/setRole` carries `clanId`, while kick/invite/cancel do not.
- Spec choice (`setRole`): only the leader may call it. Target must be another member of `data.clanId`, which must be
  the caller's clan (otherwise `invalid_request`). Promoting/demoting between member and coLeader is allowed.
  `targetRole = leader` transfers: target → leader, old leader → **member** ("loses his permissions" read literally),
  and both get `clan/roleChanged`. Setting the current role is an `Ok` no-op with no event.
  Targeting oneself → `invalid_request`.
- To verify: does the old leader become coLeader or member? Can a leader demote a co-leader? What does the protocol do
  with `clanId` ≠ caller's clan? Can co-leaders change roles of plain members?

### CLAN-12: Clan state for offline users: events are lost and user/self carries no role
- Kind: Gap (presence vocabulary from session.qnt: Online / Detached / Offline, `env/connect`, `env/reconnect`)
- Evidence: clans are permanent ("a permanent kind of party", `clan.md:5`), so most members are Offline
  when another member acts. teiserver drops events to users without a session (see findings/session.md). On `env/connect`,
  `user/self` carries `clanBaseData` (no role, no members) and `clanInvites` (ids only). A member who became leader by
  succession while Offline never gets `clan/roleChanged`. They learn it only through `clan/view`.
- Spec choice: the model sends events to the audience regardless of presence. Delivery is the session module's concern.
- To verify: add the caller's clan role (or the full `clan`) to `user/self`, or say that clients must `clan/view` after `user/self`.

### CLAN-13: Kick scope: co-leaders can be kicked; the leader cannot kick himself
- Kind: Assumption (CLAN-A9)
- Evidence: `clan.md:17` "Only the clan-leader is able to kick members".
- Spec choice: the leader may kick any other member, co-leaders included. Kicking oneself is `invalid_request`. Allowing it
  would leave the clan leaderless (seeded mutation M5 breaks `oneLeader`).
- To verify: state both.

### CLAN-14: Succession ordering and who is notified
- Kind: Assumption (CLAN-A10)
- Evidence: `clan.md:23` "the oldest co-leader is set as new clan leader. If no co-leader exist the oldest member".
  The only timestamp is `clanMember.joinedAt`.
- Spec choice: "oldest" = smallest `joinedAt`. Time spent as co-leader is not tracked. The heir gets `clan/roleChanged`
  (`leader`), and no one else is told that the leader left (CLAN-07). Checked by `successionFollowsRule` and `successionTest`.
- To verify: confirm `joinedAt` is the ordering key, and that the heir is notified.

### CLAN-15: Create while invited; profile uniqueness; viewing rights
- Kind: Assumption (CLAN-A2, CLAN-A3, CLAN-A12)
- Evidence: the protocol is silent. `clanUpdateableBaseData` limits only lengths (`name` ≤ 30, `tag` 3-10).
- Spec choice: create sends no clan event and keeps the creator's pending invites. Tag/name uniqueness is not checked.
  Anyone may `clan/view` any existing clan (members with roles and `joinedAt`) and `clan/viewList` all clans.
  `view` of an unknown id gives `invalid_request`.
- To verify: must tags be unique (a common clan rule)? Is the member list public?

### CLAN-16: "There are no limitations of the count of members" vs "a permanent kind of party"
- Kind: Contradiction (minor)
- Evidence: `clan.md:15` vs `clan.md:5`. Parties have `maxMembers` and invites count against it. Clans have no cap,
  and the relation to parties (is a clan also a party? does joining one affect the other?) is never defined.
- Spec choice: no cap, no interaction with parties.
- To verify: drop "kind of party", or define the relation.

## Coverage

| Command | Outcome | Status |
|---|---|---|
| clan/create | Ok | witnessed `wCreateOk`, lifecycleTest |
| clan/create | invalid_request (already in a clan) | witnessed `wCreateInvalid`, lifecycleTest |
| clan/update | Ok (+ updated to all members) | witnessed `wUpdateOk`, lifecycleTest |
| clan/update | invalid_request (no clan) | witnessed `wUpdateInvalid`, viewAndSetRoleTest |
| clan/update | unauthorized (member) | witnessed `wUpdateUnauthorized`, lifecycleTest |
| clan/delete | Ok (+ deleted to all members) | witnessed `wDeleteOk` (≥2 recipients), lifecycleTest |
| clan/delete | invalid_request / unauthorized | witnessed `wDeleteInvalid`, `wDeleteUnauthorized` |
| clan/invite | Ok by leader / by co-leader | witnessed `wInviteOk`, `wInviteByCoLeader` (clan_grow) |
| clan/invite | invalid_request (no clan, member, already invited) | witnessed `wInviteInvalid`, lifecycleTest |
| clan/invite | unauthorized (member) | witnessed `wInviteUnauthorized` |
| clan/cancel | Ok / invalid_request / unauthorized | witnessed `wCancelOk`, `wCancelInvalid`, `wCancelUnauthorized`, invitesAndKickTest |
| clan/accept | Ok | witnessed `wAcceptOk` |
| clan/accept | invalid_request (no invite / unknown clan / already in a clan) | witnessed `wAcceptInvalid`, `wAcceptWhileInClan` |
| clan/decline | Ok / invalid_request | witnessed `wDeclineOk`, `wDeclineInvalid` |
| clan/kick | Ok (+ kicked to target) / invalid_request / unauthorized | witnessed `wKickOk`, `wKickInvalid`, `wKickUnauthorized` |
| clan/leave | Ok (plain), heir co-leader, heir member, clan removed | witnessed `wLeaveOk`, `wLeaveHeirCoLeader` (clan_grow), `wLeaveHeirMember`, `wLeaveDissolves`, successionTest |
| clan/leave | invalid_request (no clan) | witnessed `wLeaveInvalid` |
| clan/setRole | promote / demote / transfer | witnessed `wSetRolePromote`, `wSetRoleDemote`, `wSetRoleTransfer` (all clan_grow), lifecycleTest |
| clan/setRole | Ok no-op (same role) | viewAndSetRoleTest only |
| clan/setRole | invalid_request / unauthorized | witnessed `wSetRoleInvalid`, `wSetRoleUnauthorized` |
| clan/view | Ok / invalid_request | witnessed `wViewOk`, `wViewInvalid` |
| clan/viewList | Ok | witnessed `wViewListOk` (non-empty list) |
| clan/viewList | any denial | unreachable: no request data and no precondition |
| all | internal_error | unreachable: server faults not modelled |
| all | command_unimplemented | unreachable in the model. **It is the only outcome on teiserver today (CLAN-01)** |

## Seeded mutations

Each was applied to a scratch copy, run with `quint test --main=clan_test` and `quint run --invariant=safety` (and each
sub-invariant), then discarded. `clan.qnt` is unchanged.

| # | Mutation (one line) | Caught by |
|---|---|---|
| M1 | `leave`: heir = `oldest(rest, rest.keys())` (ignore co-leaders) | `successionTest`; `successionFollowsRule` in `clan_grow` (clan_test's random runs rarely reach it) |
| M2 | `delete`: `send(Set(u), Deleted(c))` (only the caller) | `lifecycleTest`; `eventsComplete` |
| M3 | `update`: role check `if (false)` (members may update) | `lifecycleTest`; `permissionsRespected` |
| M4 | `setRole` transfer: old leader keeps `"leader"` | `lifecycleTest`; `oneLeader`, `eventsAudience` |
| M5 | `kick`: drop `t == u` guard (leader kicks himself) | `invitesAndKickTest`; `oneLeader` |
| M6 | `accept`: drop the already-in-a-clan check | `invitesAndKickTest`; `atMostOneClan`, `oneLeader`, `permissionsRespected` |

## Cross-module interface

What this module assumes or exports, as predicates over the composed state:
- `inClan(u) ⇔ clansOf(s,u) ≠ ∅` and `clanRole(u) = roleOf(s,u) ∈ {none, member, coLeader, leader}`. The user module's
  `user/self`/`user/updated` should carry `clanBaseData = if inClan(u) then {clanId, profile} else null`, and
  `privateUser.clanInvites = { c | u ∈ s.clans[c].invited }` (not enforced here; CLAN-02, CLAN-12).
- No guard on other groups: clan membership is independent of party, lobby, matchmaking and battle state.
  Clan commands do not read `activity(u)` or party membership (CLAN-16).
- Presence: clan commands require only that the caller has a session that can send requests (`attached(u)` in
  session.qnt). Event recipients may be Online, Detached or Offline. Delivery to non-attached recipients is the
  session module's rule (`eventsToAttachedOnly`), which then drops clan events for them (CLAN-12).
- Account existence: invite/kick/cancel targets range over `USERS`. An unknown userId would be `invalid_request` (not modelled).

## Requests to the orchestrator

- If the session/user modules model `user/self` contents, please add `clanBaseData` and `clanInvites` as functions of
  this module's state (see Cross-module interface) and flag teiserver's `clanId: nil` (CLAN-02) there too.
- `check.sh` has no per-directive `--seed`. The deep co-leader witnesses use a separate instance `clan_grow` with
  `samples=400000` caps (they usually hit within 1-20 s). A `seed=` option would make them deterministic.
