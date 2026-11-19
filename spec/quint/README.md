# Tachyon protocol model (Quint)

Executable semantics of the Tachyon protocol: one Quint module per command
group. Each command is a pure function `(state, caller, args) -> Outcome`
with the new state, the reply to the caller and the events per recipient.
Storage, gateways, retries, authentication and timing are out of scope.

Toolchain: Quint 0.33.1 (`npm i -g @informalsystems/quint@0.33.1`), Rust
evaluator v0.7.1, Apalache 0.62.4 for `quint verify`.

```
./check.sh                # typecheck, transcripts, invariants, witnesses for all files
./check.sh lobby.qnt      # one file
SEED=7 ./check.sh x.qnt   # another simulation seed (default 1)
VERIFY=1 ./check.sh x.qnt # also bounded model checking (slow, shallow; see below)
python3 tools/gen_schema_reasons.py > schema.qnt   # regenerate from ../../schema/
```

## Files

| File | Content |
|---|---|
| `schema.qnt` | GENERATED from `schema/`: failure reasons, request/event sets, direction per command |
| `common.qnt` | `UserId`, `Reply`, `send`, `theOne`, `mapRemove`, `replyInSchema` |
| `<group>.qnt` | one per command group: party, lobby, matchmaking, autohost, session, messaging, friend, clan |
| `system.qnt` | composition of all groups except clan over shared users |
| `findings/<group>.md` | gaps, contradictions, divergences and assumptions found while writing the module |
| `findings/system.md` | cross-group decisions (INT-D1..D5) and findings (INT-01..11) |
| `findings/REVIEW.md` | independent review of every implementation-divergence entry |

## What the checks cover

- `@test`: `quint test` transcripts, hand-written sequences with exact expected replies and events.
- `@inv`: `quint run` random simulation, up to 30 steps and 20000 samples per instance, seeded with
  `SEED` (default 1) so runs are reproducible. This is the main safety coverage.
- `@witness`: the same simulation must *violate* `not(X)`, proving that state X is reachable, so the
  invariants are not vacuous.
- `@verify` (`VERIFY=1` only): Apalache bounded model checking. It is a shallow sanity check, not the
  safety argument. Only small instances fit in memory, at `steps=2` (lobby does not fit at all). In
  particular `system_small` has `MAX_PARTY=1`, so it cannot reach two-player parties, found matches or
  running battles. Coverage of those states comes from the transcripts and the simulation above.

Implementation behaviour (teiserver, bar-lobby) is not executed. Divergences are read from the code at
teiserver `b36429f` and bar-lobby `ee58acd`.

## Proposed protocol defaults (not yet in Tachyon)

Where Tachyon is silent the models need some rule. The rules below are proposals; none of them is stated in
`docs/` or `schema/`. Findings that compare an implementation against one of them are recorded as `Gap` /
`Proposed default`, not as a divergence. Each needs a decision from the protocol owners.

| ID | Proposed default | Used by |
|---|---|---|
| PD-01 | One live session per user. A new connection replaces the old one (takeover); the session survives. | session, messaging, system (INT-D1) |
| PD-02 | Session grace period. A dropped socket leaves the session detached; party and queue membership last until grace expires; a detached member fails the ready check; presence turns `offline` only at expiry. | session, party, matchmaking, system |
| PD-03 | Activity slot. A user is in at most one of lobby, matchmaking ticket, matchmaking battle. Queueing from a lobby fails with `invalid_request`. | lobby, matchmaking, system (INT-D4) |
| PD-04 | A lobby holds at most 256 members, players and spectators together (a small constant in the model). | lobby |
| PD-05 | `matchmaking/queue` from a searching user replaces the ticket; after a match is found it fails with `already_queued`. Resolves MM-01. | matchmaking |
| PD-06 | Mutual friend requests: the second request accepts the first. | friend |
| PD-07 | Party invite timeout, party `maxMembers` and friend capacities are server settings. | party, friend |
| PD-08 | After a reconnect the server sends full state following `user/self`. | session, lobby, friend |
| PD-09 | A retried `autohost/start` answered with `battle_already_exists` is treated as unknown: kill the battle and fail the start; matchmaking retries on another autohost. | autohost, system |
| PD-10 | Battles survive an autohost disconnect for an autohost grace period, then are closed as lost and the players' activity slots are freed. | autohost, system |
| PD-11 | Battle result: one result by majority of per-player finished reports, else no result. | autohost |

## Conventions (all modules)

1. **Shape.** `module <group>` is parametrised by `const`s (user set, limits,
   server settings). `module <group>_test` (or several) instantiates it with
   small values and holds the transcripts as `run` definitions.
2. **Commands.** One `pure def` per client->server request and per
   server-side environment step, returning
   `{ state, reply: Reply, events: Set[(UserId, Event)] }`. Each definition
   quotes the Tachyon sentence it implements (`docs/schema/<group>.md` or the
   schema `description`), or is tagged `// ASSUMPTION <ID>` pointing to a
   findings entry or a `PD-nn` above.
3. **Denials** are ordinary outcomes: state unchanged, no events,
   `Failed(reason)`. The reason must be in that command's schema enum;
   every module states `val reasonsInSchema = replyInSchema(lastCmd, lastReply)`
   and includes it in `safety`. Where the schema lacks a specific reason, use
   `invalid_request` and record a finding.
4. **Environment** steps (timers, disconnects, autohost messages, the
   matchmaker finding a match) have the same shape and `reply: NoReply`.
   Durations are not modelled; a timer is an enabled step. Late or repeated
   fires must be no-ops.
5. **Nondeterminism** where the protocol leaves freedom (which autohost, who
   becomes boss, which match) is a `nondet` in `step`; the implementation's
   choice must be one of the allowed picks.
6. **State machine.** Vars `s`, `lastCmd: str`, `lastReply: Reply`,
   `lastEvents`, plus any module-specific ones. `action apply(cmd, o)`.
   `lastCmd` uses the Tachyon command id (`lobby/join`) for requests and
   `env/<name>` for environment steps.
7. **Properties.** `val safety = and { ... }` with every invariant, and at
   least one reachability witness per command success and per denial reason
   that can happen (`// @witness`), or a comment saying why it is
   unreachable. Event-recipient properties ("X/updated reaches only members")
   are invariants over `lastEvents`.
8. **Check directives** in the file header, read by `check.sh`. Expressions
   contain no spaces:
   ```
   // @test main=lobby_test
   // @inv main=lobby_test inv=safety steps=30 samples=20000
   // @witness main=lobby_test inv=not(lobbyFull)
   // @verify main=lobby_test inv=safety steps=4
   ```
9. **Seeded spec bugs.** For each module, at least three single-line
   mutations that `check.sh` must catch, listed in the findings file with what
   caught them. Do not leave mutations in the file.
10. `schema.qnt` is generated; change `schema/` and regenerate instead of
    editing it.

## Findings format (`findings/<group>.md`)

Each file has two parts: **Protocol (Tachyon)** findings and **Implementation** findings
(teiserver `b36429f`, bar-lobby `ee58acd`).

```
### <GROUP>-<nn>: <one-line title>
- Kind: Gap | Contradiction | Proposed default | Assumption | Divergence-teiserver | Divergence-bar-lobby
- Evidence: path:line references with short verbatim quotes (tachyon docs/schema,
  teiserver lib/, bar-lobby src/)
- Spec choice: what the model does, and the definition name
- To verify: the question for the protocol owners, or the test that would settle it
```

Gap = the protocol is silent. Contradiction = two parts of Tachyon disagree.
Proposed default = the protocol is silent and the model uses a `PD-nn` rule above; an implementation that
differs from it is noted, not counted as a divergence. Assumption = a modelling choice not stated anywhere.
Divergence = an implementation behaves differently from Tachyon text (cite code). Entries refuted by
`REVIEW.md` stay, marked `Refuted`, with the reason.
