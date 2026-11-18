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
VERIFY=1 ./check.sh x.qnt # also bounded model checking (slow)
python3 tools/gen_schema_reasons.py > schema.qnt   # from repo root's spec/quint/.. paths; see script
```

## Files

| File | Content |
|---|---|
| `schema.qnt` | GENERATED from `schema/`: failure reasons, request/event sets, direction per command |
| `common.qnt` | `UserId`, `Reply`, `send`, `theOne`, `mapRemove`, `replyInSchema` |
| `party_invites.qnt` | original 166-line example (kept unchanged as the reference slice) |
| `<group>.qnt` | one per command group |
| `findings/<group>.md` | gaps, contradictions, divergences and assumptions found while writing the module |

## Conventions (all modules)

1. **Shape.** `module <group>` is parametrised by `const`s (user set, limits,
   server settings). `module <group>_test` (or several) instantiates it with
   small values and holds the transcripts as `run` definitions.
2. **Commands.** One `pure def` per client->server request and per
   server-side environment step, returning
   `{ state, reply: Reply, events: Set[(UserId, Event)] }`. Each definition
   quotes the Tachyon sentence it implements (`docs/schema/<group>.md` or the
   schema `description`), or is tagged `// ASSUMPTION <ID>` pointing to a
   findings entry.
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
   `lastEvents`, plus any module-specific ones. `action apply(cmd, o)` as in
   the example. `lastCmd` uses the Tachyon command id (`lobby/join`) for
   requests and `env/<name>` for environment steps.
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
10. Do not edit `schema.qnt`, `common.qnt`, `check.sh` or another group's
    files. Needs there go in your findings file under "Requests to the
    orchestrator".

## Findings format (`findings/<group>.md`)

```
### <GROUP>-<nn>: <one-line title>
- Kind: Gap | Contradiction | Divergence-teiserver | Divergence-bar-lobby | Assumption
- Evidence: path:line references with short verbatim quotes (tachyon docs/schema,
  teiserver lib/, bar-lobby src/)
- Spec choice: what the model does, and the definition name
- To verify: the question for the protocol owners, or the test that would settle it
```

Gap = the protocol is silent. Contradiction = two parts of Tachyon disagree.
Divergence = an implementation behaves differently from the spec (cite
code). Assumption = a choice made in the spec that is not stated anywhere and
should be confirmed.
