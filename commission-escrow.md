# Learnings: Commission Escrow (Foundry + Scaffold-ETH 2)

Context: built a factory-of-clones escrow contract (collector ↔ artisan, arbiter-resolved disputes)
end to end — design, implementation, tests, README, then three rounds of review feedback, then a
broken CI pipeline. Below are the transferable lessons, organized by category, each with the
concrete moment that produced it.

## Solidity / smart contract design

- **A minimal-proxy implementation must lock itself in its constructor.** `CommissionEscrowFactory`
  deploys one `CommissionEscrow` "implementation" and clones it (EIP-1167) per commission. The
  implementation's constructor calls `_disableInitializers()` so nobody can call `initialize()` on
  the implementation directly and make it masquerade as a live commission. Clones are unaffected —
  each gets its own fresh storage and its own `initializer` slot.

- **OpenZeppelin's storage-based `ReentrancyGuard` is safe on a clone that never ran a
  constructor.** The guard's constructor sets a flag to `NOT_ENTERED` (a nonzero sentinel), but the
  modifier only ever checks equality against `ENTERED` (a *different* nonzero sentinel). A clone's
  storage starts at `0`, which is neither sentinel but behaves identically to `NOT_ENTERED` for the
  check that matters. Verified this by reading the actual OZ v5 source rather than assuming — worth
  doing before relying on any "this pattern is fine on proxies" claim.

- **Never trust a caller-supplied "amount" — derive it from the actual value transferred.**
  `amount = msg.value` inside `initialize()`, with zero separate "amount" parameter anywhere in the
  call chain (factory → clone). This closes an entire class of bug where stored accounting drifts
  from the ETH actually held by the contract.

- **Custom errors over `require(cond, "string")`**: cheaper to deploy (no string bytes embedded)
  and cheaper to call (revert with a 4-byte selector instead of ABI-encoded string). Dedupe
  aggressively — one `InvalidStatus()` error reused across a dozen different state-guard call sites
  is both cheaper and simpler than a bespoke error per guard.

- **CEI ordering is the real defense; `nonReentrant` is belt-and-braces.** Every fund-moving
  function flips `status` to its terminal value *before* the external call. This alone makes
  double-spend impossible even without the reentrancy guard — the guard just adds a second
  independent layer.

- **Match the access-control primitive to the actual relationship shape.** `ARBITER_ROLE`
  (OpenZeppelin `AccessControl`) fits because it's a shared, admin-managed roster that applies
  across every commission clone. `collector`/`artisan` do **not** fit that pattern — they're exactly
  one fixed address each, set once at `initialize()` per clone, never granted/revoked at runtime.
  Forcing `AccessControl` onto that relationship "for consistency" would have added real gas/storage
  overhead for what a single `if (msg.sender != x) revert` already does correctly. Asked the human
  before converting; the answer confirmed the simpler primitive was right.

- **When a decision genuinely requires human/off-chain judgment, don't pretend it can be made
  trustless — document the trust boundary instead of trying to erase it.** `resolveDispute(bool
  releaseToArtisan)` takes the verdict as a parameter because there is no on-chain fact that could
  answer "did delivery really happen" — if there were, there'd be nothing to dispute. The real
  mitigations for a corrupt arbiter aren't cryptographic; they're procedural: every verdict is
  permanently logged with the arbiter's address (no anonymous/deniable action), and the role is
  revocable by the admin. Wrote this reasoning directly into the contract's NatSpec so it isn't lost
  the next time someone asks "why is this a parameter."

- **Design so a security property falls out of existing mechanics instead of needing new code.**
  The "collector must confirm delivery or lose their deposit" punishment required *zero* new logic
  in `resolveDispute()` — it already splits the *entire* locked balance between the arbiter's fee
  and whichever party wins. Structuring the deposit as part of the same locked `amount` (rather than
  a separate escrow bucket) meant the punishment was a consequence of the split, not a special case
  bolted on top.

- **A state machine gets *more* correct, not more complex, when you separate concepts that were
  conflated.** The original `confirmDelivery()` conflated "artisan says it's done" with "delivery is
  confirmed," and letting the artisan call it was the actual vulnerability (self-confirm and drain
  the escrow). Splitting into `acknowledgeCommission()` (artisan accepts the job) → `orderShipped()`
  (artisan ships) → `confirmDelivery()` (collector-only, the one party who can truthfully attest
  arrival) both fixed the bug and made the lifecycle easier to reason about.

## Foundry testing gotchas

- **`vm.prank` / `vm.expectRevert` are single-shot — they apply to the *literal next* external
  call.** Evaluating a view function inline as a call argument fires that view call *first* and
  silently consumes the prank/expectRevert:
  ```solidity
  // BUG: factory.ARBITER_ROLE() fires as its own call first, consuming the prank.
  // The grantRole call below then runs as the wrong sender.
  vm.prank(admin);
  factory.grantRole(factory.ARBITER_ROLE(), arbiter);
  ```
  Fix: read the value into a local variable on its own line *before* pranking. This bug produced
  three failing tests with a confusing "unauthorized account" error that pointed at the wrong root
  cause until traced carefully.

- **Prefer `vm.expectRevert(Contract.CustomError.selector)` over string-based reverts.** It's
  compiler-checked (renaming an error breaks the test at compile time, not silently at runtime) and
  matches the gas-optimized contract style described above.

- **Don't assert exact ratios on integer-divided splits.** Splitting `amount` into a 100%/20% pair
  via floor division always leaves a remainder that lands on one side. Asserting `deposit * 5 ==
  price` fails on ordinary values (e.g. `2 ether`); use `assertApproxEqAbs` with a small tolerance
  instead of an exact equality on a derived multiplicative check.

- **A reentrancy test should assert the attack was *attempted and failed*, not just that the outer
  call didn't revert.** A minimal malicious mock with `receive()` doing one bounded re-entrant call
  in a `try/catch`, exposing `attempted`/`succeeded` flags, lets the test assert both halves
  explicitly rather than weakly inferring safety from "nothing exploded."

## Scaffold-eth-2 / tooling

- `create-eth`'s own boilerplate files can carry pre-existing lint/prettier violations that stay
  invisible until CI actually reaches the lint step — "it came from the official scaffolder" is not
  evidence it's clean. Don't skip verifying stock files just because you didn't author them.
- For a clone factory, call `Clones.clone(implementation)` (no value) and then
  `clone.initialize{value: msg.value}(...)` separately, rather than `Clones.clone(implementation,
  value)`. This lets the clone's own `initialize` record `msg.value` as `amount`, keeping the
  "amount always equals actual value transferred" invariant intact all the way from the factory
  entry point to clone storage.
- Pin Foundry to `stable` explicitly, both locally (`foundryup`) and in CI
  (`foundry-toolchain@v1` with `version: stable`) — a nightly build produces noisy warnings and is a
  source of environment drift between machines that's easy to overlook.

## CI/CD debugging discipline

- **Never treat the first visible warning as "the failure."** The user's reported symptom was a
  Foundry nightly-build warning; the actual failing step had nothing to do with it. Always pull the
  real job logs (`gh run view --log-failed`) and find the actual non-zero-exit line.
- **CI failures often stack — fixing one exposes the next.** This pipeline failed for three
  independent reasons that only became visible one at a time as each was fixed in turn:
  1. `yarn chain & yarn deploy` raced anvil's startup (`Connection refused`) — fixed with a polling
     loop that waits for a real RPC response before deploying, rather than a fixed `sleep`.
  2. `actions/checkout` does **not** check out git submodules by default. A repo with real git
     submodules (`.gitmodules`, not just vendored copies) needs `submodules: recursive` explicitly,
     or every import from a submodule silently fails to resolve in CI while working fine locally
     (where the submodules were already initialized).
  3. Ten stock scaffold files failed `next:lint --max-warnings=0` — pre-existing, unrelated to any
     of the contract work, just never previously reached because CI never got past steps 1–2.
  Fix-verify-repeat against the real CI run beat trying to read every log for every possible failure
  up front.
- Background-and-immediately-use race conditions (`process-A & command-that-depends-on-A`) need an
  explicit readiness check in CI even if the equivalent sequence "just works" locally — CI runners
  are frequently slower/more resource-constrained, so timing that happens to work on a dev machine
  is not evidence it will work in CI.

## Process / collaboration

- **Faithful commit-history reconstruction is possible after the fact, if you were writing full
  file snapshots along the way.** Asked to "commit with logical and meaningful messages" after
  several rounds of direct edits (no incremental commits), it was possible to reconstruct honest,
  bisectable checkpoints — not a fabricated history — by writing back each round's known-final file
  content from the conversation record, committing, running the full test suite to confirm that
  checkpoint actually passed on its own, then restoring the final content and committing again. Real
  intermediate states, not invented ones.
- **Design questions that look stylistic are sometimes security-load-bearing.** "Should
  `confirmDelivery` be artisan- or collector-callable?" reads like a naming/API question, but the
  answer was the actual vulnerability fix. Treat any access-control fork as a security question
  first, a style question second.
- **Expect review feedback to arrive in causally-linked layers, not a flat list.** Fixing "artisan
  can fake their own delivery" immediately exposed "then what stops the collector from just never
  confirming" — the second gap only became visible once the first was closed. Design one layer at a
  time and expect the next question rather than trying to preempt every future round.
- **`AskUserQuestion` earns its keep on irreversible-ish forks with real tradeoffs** (access-control
  primitive choice, deposit funding mechanism, whether a function should keep a parameter vs. read
  from storage) — each answer changed the actual implementation, not just cosmetic details.
