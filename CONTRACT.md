Contract version: 1

# The AgentCtl contract

AgentCtl lets a small script drive an app's state machine — headlessly, with no UI, or against a
running app through some in-app bridge — and prints back what changed after every command. This
document specifies the part of that behaviour that any implementation, in any host language, must
reproduce so that the same script produces the same steps everywhere. A Swift implementation and a
Kotlin implementation are two ports of this contract, not two designs.

**Scope.** This contract defines the *engine*: how a script is parsed, how a line is dispatched to
whatever commands the host app declares, how the three runtime commands (`expect`, `advance`,
`mock`) behave, how one step is rendered as text, and the exit codes and determinism guarantees
that make a script's output reproducible. It does **not** define which screens, commands, summary
keys or mock methods any particular app has — that vocabulary belongs to the app that embeds
AgentCtl (declared however the host language expresses it: `AgentScreen`/`AgentCommand` in Swift, a
Kotlin equivalent in a future port). Examples below use the vocabulary of AgentShop, the app this
implementation was extracted from (`auth/login`, `orders.fetchOrders`, …), only to show the
mechanism, never as something a port must literally have.

Where this document and the prose documentation of that app disagree (its `appctl-guide.md`,
`appctl-internals.md` and generated `agent-commands.md` — none of them part of this repository),
this document follows the **source code** (`ScriptParser.swift`, `Expectation.swift`,
`StepRecord.swift`, `ScriptRunner.swift`), which is authoritative. Three such gaps are called out
inline.

## 1. Script language

### 1.1 Lines, separators, comments

- A script is plain text. Commands are separated by `;` **or** a newline — either is equivalent as a
  separator.
- `#` starts a comment that runs to the end of the physical line. A comment resets at each newline,
  so a line that starts with more script after a `;` is not "still commented."
- Blank lines, and segments that are empty or all whitespace after trimming, produce no command —
  they are silently skipped, not an error.
- A command's name is the leading run of non-whitespace characters; its argument, if any, is
  whatever follows, trimmed of leading/trailing whitespace. A command with nothing after its name
  has no argument (not an empty string).

  ```
  login-as alice; open 1003; cancel
  ```
  parses to three commands: `login-as` (argument `alice`), `open` (argument `1003`), `cancel` (no
  argument).

### 1.2 Quoting and escapes

- A double-quoted span protects `;` and `#` from being treated as a separator or a comment start,
  so an argument can itself contain them: `password "a;b#c"`.
- Inside a quoted span, `\` escapes the character that follows it (at minimum, implementations must
  support `\"` for a literal quote and `\\` for a literal backslash — the reference implementation
  escapes *any* following character generically; see Open Questions).
- **Parsing is quote-preserving, not quote-stripping.** The line-splitting pass keeps the quote
  characters (and any backslash escapes) in the argument text verbatim; it only uses them to decide
  where a `;` or `#` is literal versus a separator. A *separate* step resolves quotes depending on
  how the argument is consumed:
  - A command that takes its argument as one opaque value (e.g. `email alice@example.com`, or a
    free-text field) unquotes the *whole* argument only when it is wrapped end-to-end in a single
    pair of quotes; otherwise it is used as-is. `name Carol Smith` and `name "Carol Smith"` are both
    valid ways to write the same value; quoting is only required when the value would otherwise be
    mistaken for something else (see `expect`, next).
  - A command whose argument is itself a list of tokens (`expect k=v [k=v …]`, `mock <method>
    <error>`) is split on *unquoted* whitespace first, and quotes/escapes are then resolved inside
    each token. This is why `expect` needs quoting for a value with a space —
    `expect name="Carol Smith"` — while `email Carol Smith` (a single free-text field) does not.

  This two-phase design exists so that a single parser can serve every command shape without each
  command re-implementing tokenizing: the line splitter only needs to know where statements end,
  and only the command that receives the argument needs to know its own shape.

### 1.3 Command resolution

- A command name is looked up on the screen that is currently active, then on the containers around
  it (outer navigation/tab structure), then on the app root — **leaf first**. The first match by
  name wins; a screen's own command shadows a container's or root's command of the same name (e.g.
  a screen can offer its own `back` with a screen-specific failure reason instead of the root's
  generic one).
- A screen may expose different commands depending on which of its own paths is currently active
  (e.g. one reducer backing several screen paths, each with a different subset of the reducer's
  commands available); resolution still starts at whatever the current path currently offers.
- A command may be **gated**: disabled in some states, mirroring a disabled button. A gated command
  that is currently disabled is looked up successfully (it exists) but fails when invoked, with a
  hint describing the condition (see below).
- Unrecognized command names, and disabled or malformed invocations, are not script syntax errors —
  they are resolved and reported at the same point the app itself would refuse them (see §5 for
  which exit code each case gets):
  - **Unknown name** — not offered by the active screen or any of its containers:
    ```
    unknown command 'submit' on home/orders. Valid here: open <id>, refresh, retry, tab <orders|profile>, login-as <alice|bob>, reset, back, expect, advance, mock
    ```
    The listed commands are exactly what would currently resolve on that screen, in the same
    leaf-first order, with the three runtime commands (`expect`, `advance`, `mock`) always appended
    last.
  - **Disabled (gated)**:
    ```
    submit is disabled here (canSubmit=false)
    ```
  - **Bad argument** — the command exists and is enabled, but its argument is missing, unexpected,
    invalid, or the command doesn't apply right now. The message is the command's usage followed by
    a colon and a reason:
    ```
    login-as <alice|bob>: invalid argument: expected alice|bob
    ```
    The reason is one of: `missing argument: expected <placeholder>` (a required argument was
    omitted), `unexpected argument '<value>': this command takes none`, `invalid argument: <reason>`
    (a value was supplied but rejected), or an app-supplied sentence for "this command doesn't apply
    right now" (e.g. `back` with nothing to go back to fails with exactly `nothing to go back to`,
    with no added prefix beyond its usage).

  > **Doc/code gap:** `appctl-internals.md` shows `login-as carol` failing with just
  > `invalid argument: expected alice|bob`, omitting the `login-as <alice|bob>: ` usage prefix that
  > the reference implementation actually prepends. The prefixed form above is what the code
  > produces and is what this contract requires.

### 1.4 Parse errors

The only failure that the line-splitting pass itself raises is an **unterminated quote**: a quoted
span still open at the end of a line (when the separator is a newline) or at the end of the whole
script. It is reported with the line and column where the quote *opened*, e.g. `line 3, column 12:
unterminated quote`, and maps to exit code 2 (§5). Every other problem — an unknown command, a bad
argument, an out-of-range value — is a resolution-time failure once a well-formed line has been
handed to the app, not a parse error.

## 2. Runtime commands

Three commands work identically on every screen; the app never sees them as its own actions.

### 2.1 `expect k=v [k=v …]`

Asserts on the result of the step that just ran (see §4). At least one `key=value` pair is
required; `expect` with no argument, or a token without an unquoted `=` after its first character,
is a syntax error (exit 2), not a failed assertion. Quote a value that contains whitespace:
`expect name="Carol Smith"`.

### 2.2 `advance <duration>`

Moves a virtual clock forward by the given amount, releasing every timer whose deadline falls
within the advanced window, in deadline order — for example, `advance 30s` against a 1-second
countdown fires all 30 ticks in that one step, then the runtime waits for the app to settle again.

**Accepted forms:** an unsigned integer immediately followed by one unit suffix — `ms`
(milliseconds), `s` (seconds), `m` (minutes, i.e. ×60 seconds), or `h` (hours, i.e. ×3600 seconds).
`500ms`, `30s`, `5m`, `1h` are all valid; a missing/malformed duration (no digits, unknown suffix, a
compound value like `1h30m`, a negative or fractional number) is a usage error (exit 2), not a
failed assertion.

**Headless only.** Issuing `advance` against a running app with no virtual clock — i.e. one driven
by a real, wall-clock timer — is rejected with a usage error (exit 2):
`advance is only available headlessly, not in the running app`. This is deliberate rather than a
missing feature: a live run's timers are real, so "advancing" them can't be done deterministically
or instantaneously, and silently ignoring the command (or turning it into a real sleep) would make
the same script behave differently in the two modes without warning. A conforming implementation
must reject `advance` outright wherever it has no virtual clock to move.

### 2.3 `mock <client.method> <error>`

Arms a **one-shot** failure: the *next* call the app makes to `<client.method>` throws the given
error instead of running normally; the registration is then cleared, so a second call to the same
method succeeds unless `mock` is issued again. The argument must be exactly two whitespace-separated
tokens (`mock orders.fetchOrders network`); any other count is a usage error (exit 2). `<client.method>`
must name a method the app has actually declared as mockable, and `<error>` must be one of that
method's declared error codes — both are app vocabulary, not part of this contract, but an unknown
name or an error code invalid for that name is a failure (exit 1), because the *shape* of the
command was fine and only the referenced identifier was wrong (the same class of error as an
unknown screen command, §1.3).

`mock` is available in every mode, headless or live — the fault registry it writes to lives
alongside whatever mock backends the app itself runs in that process, so there is no clock
dependency to fail on.

## 3. Step output format

After every command the runtime waits for the app to settle (§6) and prints exactly one step: an
echo of the command as run, then one line describing the resulting state.

```
> login-as alice
  screen=home/orders orders=3 loading=false statuses=delivered,shipped,pending calls=session.save,orders.fetchOrders
```

### 3.1 Field order

The state line's fields appear in this exact order, space-separated:

1. `screen=<path>` — always present, always first. The active screen's path (an app-defined string
   such as `auth/login` or `home/orders/1003`).
2. The screen's own summary pairs, **in the screen's declaration order** — the fixed order in which
   that screen lists its own keys, not alphabetical and not insertion order of some other kind. All
   of a screen's summary keys are printed every time it is the active screen; a key is never omitted
   to signal something — an app that needs to say "no issues" prints an empty or sentinel value for
   that key instead of leaving it out. This is what makes the set of keys for a given screen
   path documentable once and relied on afterwards.
3. `calls=<c1>,<c2>,…` — present **only if** at least one call to a mocked method happened during
   this step; a comma-joined list of `<client>.<method>` names in the order they were made
   (duplicates included if a method was called twice). **Omitted entirely** when no call was made —
   there is no `calls=` with an empty value.
4. `error=<code>` — present **only if** the screen currently reports an error. **Omitted entirely**
   when there is none (there is no printed `error=none`; that spelling exists only as something you
   can `expect`, see §4 — do not treat a missing `error=` field as ambiguous with an explicit "no
   error" you can pattern-match against in the text output).
5. `pending=<n>` — present **only if** `n` is nonzero: the number of timers currently suspended
   (e.g. a resend countdown), not a general count of in-flight work. Counting only clock waits (and
   not, say, an in-progress navigation effect) is what lets `pending` mean "advance would still do
   something here."
6. `settled=false` — present **only if** the runtime hit its real-time ceiling waiting for the app
   to go quiet before the fields above were read (§6). A step carrying `settled=false` is also a
   failed step (§5): the printed state may not be final, so it must not be trusted or asserted on.

   > **Doc gap:** none of `appctl-guide.md`, `appctl-internals.md` or `agent-commands.md` document
   > this field at all. It exists in the reference implementation's formatter and its JSON output,
   > and is required by this contract.

### 3.2 Quoting of summary values

A summary value is printed bare (`orders=3`) unless it contains whitespace or is the empty string,
in which case it is wrapped in a plain pair of double quotes with no internal escaping
(`name="Carol Smith"`, `note=""`). A value that itself contains a `"` character is not specified by
the reference implementation (see Open Questions) — do not rely on round-tripping such a value
through the text format.

### 3.3 Failure lines

When a step fails, the state line is still printed in full (the screen's current state is always
knowable, even when the command that produced it was rejected), followed by one `  FAIL <text>`
line per line of the failure message:

```
> submit
  screen=home/orders orders=3 loading=false statuses=delivered,shipped,pending
  FAIL unknown command 'submit' on home/orders. Valid here: open <id>, refresh, retry, tab <orders|profile>, login-as <alice|bob>, reset, back, expect, advance, mock
```

> **Doc gap:** `appctl-guide.md`'s example of this same failure omits the `screen=` state line for
> brevity, showing only the command echo and the `FAIL` line. The reference implementation always
> emits the state line first; a conforming implementation must too.

### 3.4 `(launch)`

Before any command in the script runs, the runtime performs its own initial step: it settles the
app from a cold start into its first screen (e.g. loading a saved session, landing on `auth/login`)
and prints it exactly like any other step, except the command echo is the literal token `(launch)`
rather than anything the script author wrote:

```
> (launch)
  screen=auth/login email="" keepSignedIn=true revealed=none canSubmit=false loading=false calls=session.current
```

This step is not something a script can invoke or skip; it is how a script's own first line is
always evaluated against a known starting state.

### 3.5 Other machine-readable forms

A tool built on this contract may offer other serializations of the same steps (the reference CLI
has a JSON array form). Only the text form specified above is normative for this contract; see §7.

## 4. `expect` semantics

`expect k=v [k=v …]` checks each pair against the snapshot produced by the step that just ran: the
active screen's path, its full summary, the calls made during that step, its error code, and its
pending count. Every pair must match for the `expect` to pass; on failure, one message per unmet
pair is printed (as `FAIL` lines, §3.3), and the pairs that *did* match produce no output of their
own.

| Key | What it checks | Match rule |
|---|---|---|
| `screen` | the active screen's path | exact string equality |
| any summary key | that key's current value | exact string equality against the printed (unquoted) value; asserting a key the current screen doesn't have is itself a failure, not a "no match": `unknown key 'foo' on auth/login; available: screen, call, error, pending, email, keepSignedIn, revealed, canSubmit, loading` |
| `call` | whether a method was called during the step just run | membership, not equality — `expect call=orders.fetchOrders` passes if that name appears anywhere in the step's call list; repeat the key to require several: `expect call=auth.login call=session.save` |
| `error` | the screen's current error code | exact string equality; the literal value `none` means "no error is set" — this is the only place `none` is meaningful; it is never printed on the state line itself (§3.1) |
| `pending` | the number of timers currently suspended | exact equality against the integer, compared as text, e.g. `pending=0` |

A failed match prints `expected <key>=<value>, got <key>=<actual>`, except for `call`, which prints
`expected call=<value>, got calls=<c1>,<c2>,…` (or `got calls=none` when nothing was called).

**What "the previous step" means for `call` and the summary.** `expect` does not run the command
again or advance anything; it reads the same call list and summary that would have been printed
had a state line been shown at that point. Consecutive `expect` lines (or an `expect` right after a
`mock`, which clears the call list without making a call) all see the same, unadvanced snapshot —
only an actual command, or `advance`, updates it.

```
mock orders.fetchOrders network
login-as alice
expect screen=home/orders orders=0 error=network call=orders.fetchOrders
retry
expect orders=3 error=none statuses=delivered,shipped,pending call=orders.fetchOrders
```

## 5. Exit codes

| Code | Meaning |
|---|---|
| 0 | Every line in the script ran and every `expect` passed. |
| 1 | A command or an `expect` failed. This covers: an unmet `expect` pair (including an unknown key); an unresolvable command name; a gated command that is currently disabled; a command argument that is missing, unexpected, invalid, or inapplicable right now; a `mock` naming an unknown method or an error code not valid for that method; and a step that did not settle within its time limit (`settled=false`). |
| 2 | A usage or parse error: an unterminated quote (§1.4); `expect` with no argument or a malformed `key=value` token; `advance` with a missing/unparseable duration, or issued where there is no virtual clock to move; `mock` with a wrong number of tokens. In every case here, the *shape* of the line itself was wrong, before anything was resolved against the app's current state. |
| 3 | An internal or build error: a failure outside the script engine itself (the host process couldn't be built or started, a required file was missing, and similar environment problems). Not something a script or its commands can trigger. |

A script stops at its first failing line; exit code 0 requires every line to have run.

## 6. Determinism requirements

A conforming headless implementation must guarantee: **the same script, run from the same fresh
starting state, always produces byte-identical step output.** Concretely:

- **A virtual clock**, not a real one. Nothing that measures time (a resend cooldown, a code expiry)
  progresses except through `advance`; the implementation must be able to enumerate and fire every
  pending timer up to a given point, in deadline order.
- **A fixed notion of "now."** Whatever the app reads as the current date/time returns one constant
  value for the whole run (the reference implementation uses 2026-01-01 09:00 UTC). The exact value
  is an application choice; that it never varies between runs is the requirement.
- **Deterministic identifiers.** Anything the app generates that would otherwise be random (record
  IDs, session identifiers) must instead be produced by a deterministic, incrementing sequence, so
  two runs of the same script generate the same IDs in the same order.
- **Zero artificial latency** in headless/test runs: a mocked call may still be recorded and may
  still be faulted (§2.3), but it must not itself wait on real time. (A live run driving a real,
  running app is explicitly exempt from this — it is allowed, even expected, to have real latency;
  determinism is a headless-mode guarantee, not a live-mode one.)
- **Deterministic scheduling.** Concurrent work (effects, coroutines, whatever the host language
  calls its concurrency unit) must resolve in a fixed order for a given script, so that interleaving
  differences never change which call happens before which state update.
- **A clean starting state per run.** Any storage the app's mocks use starts empty (or at a fixed
  seed) at the beginning of a headless run; nothing carries over from a previous run in the same
  process unless the script itself asks for it.
- **Settling never reports a half-finished state.** The runtime must wait until the app has gone
  quiet — by whatever definition of "quiet" fits the host (e.g. several consecutive checks seeing no
  change) — before reading the fields for a step, rather than printing state mid-effect. A run that
  cannot reach quiet within a bounded ceiling reports `settled=false` (§3.1) and fails the step,
  rather than guessing.

**Why this matters for a port.** These guarantees are what let a script's output be captured once
as a fixture and compared byte-for-byte later — both to catch an accidental behaviour change while
refactoring the same implementation (the reference repo already does this for its own extraction),
and, prospectively, to check a from-scratch port in another language against the same fixtures. A
nondeterministic engine cannot be verified this way at all: every comparison would need a human to
judge whether a difference is "just timing" or a real regression, which defeats the purpose of
having a shared, scriptable contract in the first place.

## 7. What is NOT part of the contract

- **The host language and its idioms.** How screens and commands are declared (Swift protocols and
  builder functions in the reference implementation, whatever reads naturally in Kotlin for a port)
  is free to differ completely. Only the *runtime behaviour* they produce — resolution order,
  argument handling, gating, the exact failure text shapes in §1.3 — is specified here.
- **The UI framework**, if any. This contract describes driving an app's state and reading it back;
  it has nothing to say about how (or whether) that state is rendered.
- **The transport used by an in-app bridge**, including whether one exists, what protocol it speaks,
  what port or address it listens on, its request/response framing, or any headers it sends. A
  bridge is one way to deliver a script to a running app; the contract only covers what happens once
  the script reaches the engine.
- **The CLI's own command names, subcommands and flags** (e.g. `run`, `test`, `--json`, `--diff`,
  `--session`). These are one tool's presentation choices; a port may organize its own tool however
  it likes as long as running a script produces the output this document specifies.
- **The exact bytes of any non-text serialization** a tool happens to also offer (e.g. a JSON array
  of steps). Only the text format in §3 is normative; see the Open Questions note on the reference
  implementation's own JSON form.
- **Any application's specific vocabulary** — its screen paths, summary keys, command names and
  argument shapes, and mockable methods/error codes. These are declared by whatever app embeds
  AgentCtl and are exactly as arbitrary as that app's own design; this contract only specifies how
  scripts address *whatever* vocabulary an app declares.
- **State diffing, snapshot/UI testing, simulator or device concerns.** These are verification
  layers built on top of a driven app, not part of driving it.

## Open questions

These are genuinely unspecified in the source material — a port should make an explicit decision
rather than copying the reference implementation's incidental behaviour without noticing it was a
choice:

1. **Escape scope inside quotes.** The reference implementation treats `\` as escaping *any*
   following character, not just `\"` and `\\`; none of the prose documentation describes anything
   beyond `\"`. Should the contract require the general rule (so `\n` inside quotes yields a literal
   `n`, not a newline), or only guarantee `\"` and `\\` and leave other escapes undefined?
2. **Compound durations.** `advance` only accepts a single `<number><unit>` token (`30s`, `5m`); a
   form like `1h30m` is a usage error. Is single-unit-only a deliberate constraint of the contract,
   or just something never needed yet that a port is free to extend?
3. **Values containing a literal quote character.** Neither the summary-value quoting rule (§3.2)
   nor the argument-unquoting rule (§1.2) specifies what happens when a summary value itself
   contains `"`. Left undefined here; a port should pick a rule (e.g. escape it) and document it
   rather than relying on the reference implementation's un-exercised behaviour.
4. **Exact settling thresholds.** The reference implementation waits for a specific number of stable
   rounds and specific real-time ceilings (in both headless and live modes) before giving up and
   reporting `settled=false`. This document treats "wait until quiet, then give up after a bounded
   ceiling" as the contract and leaves the specific numbers as tuning, not a requirement — is that
   the right line, or should a port match the reference's exact thresholds for parity?
5. **JSON output ordering.** The reference implementation's JSON form serializes a step's summary as
   a key/value map rather than an ordered list, silently losing the declaration order that the text
   format (§3.1) treats as meaningful. Is that an intentional simplification for JSON consumers, or
   an oversight that a port's own machine-readable form should avoid repeating?
6. **Literal composition of the "valid here" list.** §1.3's unknown-command message always appends
   exactly `expect, advance, mock` after the screen's own commands. Is a port required to reproduce
   that exact tail, or is the actual requirement just "list the commands that would currently
   resolve, including the runtime ones," with the reference's specific wording being incidental?
