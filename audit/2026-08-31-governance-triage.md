# Governance battery triage — VoteToken + PoolVoting

Scope: `src/VoteToken.sol` (OZ ERC20Wrapper + ERC20Votes subclass) and
`src/PoolVoting.sol` (voting registry), plus their unit suites
`test/VoteToken.t.sol` (8 tests) and `test/PoolVoting.t.sol` (11 tests, now
12 after this pass). All other contracts in the repo are noted only where
a tool's output mentions them; they are **not in scope, not triaged** here.

## What ran, and proof each tool actually executed

| Tool | Command | Evidence it really ran |
|---|---|---|
| slither 0.11.6-class | `slither . --exclude-dependencies` | Full run: "analyzed (127 contracts with 102 detectors), 53 result(s) found". Log: scratch `audit/slither.log` (session-local, not committed). |
| aderyn | `aderyn .` | Compiled 12 files, ran 88 detectors, wrote `report.md` (19,954 bytes, 380+ lines) at repo root. |
| halmos | `halmos --contract PoolVotingSymbolicTest --function check_` | `test/halmos/PoolVotingSymbolic.t.sol` (new). Output: `Symbolic test result: 3 passed; 0 failed; time: 6.19s`, with individual path counts `check_cancel_neverModifiesTally` (paths: 7, 0.46s), `check_firstVote_movesSumByExactlyWeight` (paths: 8, 0.57s), `check_revote_conservesSum` (paths: 12, 5.08s). Non-trivial path counts and per-property timing are the proof this was a real symbolic run, not a vacuous pass. |
| mythril canary | `myth analyze -f Canary.hex --bin-runtime -t 3 --execution-timeout 2100` on a throwaway contract with an open `rug()` and pay-before-zeroing `withdraw()` | **Canary FLAGGED as required.** 4 findings: SWC-123 (requirement violation, fallback), SWC-107 x3 ("External Call To User-Supplied Address" and two "State access after external call" — one read, one **write** to `balances` after the `.call{value:}` in `withdraw()`, which is exactly the planted bug). Ran ~35 minutes wall clock (started 14:19:58, log finalized ~14:55). Because the canary was flagged, the mythril results below are treated as live, not void. |
| mythril — VoteToken | `forge inspect VoteToken deployedBytecode > VoteToken.hex` (evm_version left at the project default, `cancun` — `--evm-version shanghai` was tried first per the brief and failed to compile: the project uses Cancun `mcopy`, so Shanghai cannot represent this bytecode; deployedBytecode was still used, never creation bytecode) then `myth analyze -f VoteToken.hex --bin-runtime -t 3 --execution-timeout 2100` | Ran ~35 minutes wall clock (14:55:41 → 15:30:45), 24 findings across nearly every public function (`approve`, `transfer`, `transferFrom`, `permit`, `delegate`, `delegateBySig`, `getPastVotes`, `balanceOf`, `allowance`, `clock`, `nonces`, `underlying`, `numCheckpoints`, `DOMAIN_SEPARATOR`...). Broad function coverage plus multi-minute duration is the proof of a real run. |
| mythril — PoolVoting | same recipe on `PoolVoting.hex` | Finished in **32 seconds wall clock** (14:55:41 → 14:56:13) with only 7 findings, none touching `propose`, `vote`, or `cancel` — the only three functions that carry a guard. **This looks like the "fast run = failed run" pattern, and is called out explicitly below rather than quoted as a clean result.** |

### Why the PoolVoting mythril run legitimately stopped short (not a silent-failure canary miss)

`PoolVoting.token` is `immutable`. Analyzing `deployedBytecode` in isolation
(no constructor run) leaves every immutable zeroed, so `token` is
`address(0)`. `propose()` calls `token.clock()` and `vote()` calls
`token.getPastVotes(...)` through the `IERC5805` interface type, which the
compiler compiles as a high-level call with an implicit `EXTCODESIZE` guard
on the callee; `address(0)` has no code, so both calls revert immediately,
before any of `propose`/`vote`/`cancel`'s own guard logic executes. `cancel`
has no external call and *should* have been reachable, but 32 seconds is a
uniformly short run and mythril's per-contract path budget was clearly spent
elsewhere (the surviving 7 findings are all bare getters:
`token()`, `tally()`, `options()`, `pendingOwner()`, `owner()`, and two
unresolved selectors). This exact limitation is already documented in this
repo for the same reason on `GenesisLauncher`
(`test/halmos/GenesisLauncherAuth.t.sol`, top-of-file comment: "Mythril adds
nothing here: analyzing deployedBytecode in isolation zeroes every
immutable... the gate rejects everything before any interesting path is
reachable"). Verdict: the mythril run on PoolVoting is **not treated as
having cleared `propose`/`vote`/`cancel`** — that access-control and
tally-arithmetic surface is instead covered by the halmos symbolic test
above (which mocks the token so the real logic is reachable) and by the
mutation pass below (which proves every guard is enforced by the unit
suite). Re-running mythril with the immutable pre-set was not attempted
(would need a harness contract wrapping `PoolVoting` with a live mock
token deployed first, which is what the halmos file already does more
directly).

## slither findings — `VoteToken.sol` / `PoolVoting.sol` only

| Finding | Real / False-positive | Why |
|---|---|---|
| `PoolVoting.propose` "uses timestamp for comparisons" (`start < block.timestamp \|\| end <= start`) | **False-positive (expected)** | The contract is deliberately a time-windowed voting registry; the whole design is `block.timestamp` gating a start/end window. Miner timestamp manipulation (~seconds) cannot meaningfully move a multi-day proposal window. |
| `PoolVoting.vote` "uses timestamp for comparisons" (`block.timestamp < p.start \|\| > p.end`) | **False-positive (expected)** | Same as above — this is the vote-window check the feature exists to enforce. |
| `PoolVoting.cancel` "uses timestamp for comparisons" (`block.timestamp > p.end`) | **False-positive (expected)** | Same reasoning; prevents cancelling a proposal that has already closed. |
| `VoteToken.CLOCK_MODE()` "not in mixedCase" (naming-convention) | **False-positive (by design)** | `CLOCK_MODE` is the exact identifier mandated by ERC-6372/OZ's `IERC6372` interface; renaming it would break interface conformance for any ERC-5805 consumer (including `PoolVoting` itself, which calls `token.clock()`/relies on the ERC-6372 clock contract). |

Other slither findings in the run (low-level-calls in `GenesisLauncher`/`PoolZapper`, missing-inheritance on `DualPoolHook`, cache-array-length in `StakingVault`/`StakingVaultV2`, the many differing-pragma-directives notes from vendored libs) are on contracts outside this task's scope — **not in scope, not triaged**.

## aderyn findings — `VoteToken.sol` / `PoolVoting.sol` only

| Finding | Real / False-positive | Why |
|---|---|---|
| H-1 "Reentrancy: state change after external call" — `PoolVoting.propose` line 64 (`token.clock()` before `p.start`/`p.end` are set) | **False-positive** | `token.clock()` is a `view` call on an immutable, trusted, project-deployed `VoteToken`; it cannot reenter `propose` (no callback surface), and `propose` is `onlyOwner` besides. Aderyn's detector flags any external call followed by a state write regardless of the callee's trust level or view-ness. |
| H-1 — `PoolVoting.vote` line 76 (`token.getPastVotes(...)` before the receipt/tally state writes) | **False-positive** | Same reasoning: `token` is the immutable `VoteToken` set at construction, a `view` function with no external calls of its own (checkpoint array read only) — there is no reentrancy surface here, and CEI is otherwise followed (all writes happen after this single read, in one block). |
| L-1 "Centralization risk" — `PoolVoting is Ownable2Step`, `propose(...) onlyOwner`, `cancel(...) onlyOwner` | **False-positive (by design)** | Governance proposals are deliberately owner-gated (only the DAO/ops multisig may create or cancel a vote); this is the intended access-control model for a curated voting registry, not an oversight. Ownable2Step's two-step transfer already mitigates the classic single-step-ownership-transfer risk this detector exists for. |

Other aderyn findings (centralization on `Registry`/`OperatorControllerV2`, costly-loop/large-numeric-literal/unchecked-return findings elsewhere in `report.md`) are outside scope — **not in scope, not triaged**.

## mythril findings — `VoteToken.sol`

All 24 findings fall into three well-understood mythril false-positive classes; none indicate a real bug:

| Class | Functions hit | Real / False-positive | Why |
|---|---|---|---|
| SWC-101 "Integer Arithmetic Bugs" (18 findings: `approve`, `totalSupply`, `transferFrom`, `DOMAIN_SEPARATOR`, `getPastVotes`, `delegates`, `delegate`, `underlying`, `numCheckpoints`, `balanceOf`, `nonces`, `getPastTotalSupply`, `clock`, `allowance`, `transfer`, `permit`, `options`-adjacent getters) | **False-positive (mythril detector limitation)** | Solidity ≥0.8 inserts a compiler-generated overflow/underflow **revert** on every arithmetic op; mythril's SWC-101 detector flags the existence of that revert branch itself as "can overflow" rather than recognizing it as the language's own protection. This is a documented, systemic mythril false-positive on any 0.8.x contract and is not specific to this code. |
| SWC-123 "requirement violation in a nested call" (3 findings: `transfer`/`transferFrom` paths) | **False-positive** | These are OZ's own internal `require`/custom-error balance and allowance checks reverting on invalid symbolic input (e.g. transferring from an account with less balance than requested) — exactly the intended behavior of a `require`, not an exploitable path. |
| SWC-116 "Dependence on predictable environment variable" — `block.timestamp` (3 findings: `permit` (`0xd505accf`) deadline check, `getPastVotes` (`0x3a46b1a8`) checkpoint-lookup guard, `delegateBySig` (`0xc3cda520`) signature-expiry check) | **False-positive (expected)** | All three are the standard EIP-2612 (`permit`) / EIP-5805 (`delegateBySig`) / ERC20Votes (past-lookup "future lookup" guard) use of `block.timestamp`, inherited unmodified from OpenZeppelin. Same category the brief pre-approved for `PoolVoting`'s own timestamp comparisons — miner-level timestamp skew of a few seconds cannot forge a signature deadline or the vote-lookup boundary. |

## halmos — `PoolVoting` symbolic properties (new file)

`test/halmos/PoolVotingSymbolic.t.sol` adds a lightweight `HalmosMockVotes`
(a fully-symbolic-friendly stand-in for `IERC5805`, since real
`ERC20Votes` checkpoint traversal is already covered by `VoteToken.t.sol`'s
own concrete suite) and three properties, all proved:

- `check_firstVote_movesSumByExactlyWeight` — for any voter/option/weight, a
  first vote changes the tally sum by exactly `weight`. **PASS**, 8 paths.
- `check_revote_conservesSum` — for any voter and any two options, casting a
  second vote leaves the tally sum unchanged (the prior weight is
  subtracted before the new weight is added). **PASS**, 12 paths.
- `check_cancel_neverModifiesTally` — `cancel()` never changes any tally
  entry, even after a vote has been cast. **PASS**, 7 paths.

`Symbolic test result: 3 passed; 0 failed; time: 6.19s`. No counterexamples.

## Mutation pass

Full results: `audit/2026-08-31-governance-mutations.tsv` (13 mutations:
11 on `PoolVoting`, 2 on `VoteToken`; this is a fresh, separate battery —
`audit/mutation-results.tsv` in this repo is a prior session's battery on
other contracts and was not touched or counted). Method: back up `src/`,
apply one string-level mutation, run
`forge test --match-contract 'VoteTokenTest|PoolVotingTest'` (the full two
suites, no scoping), record KILLED/SURVIVED, restore `src/` before the next
mutation.

**12 of 13 killed on the first pass.** One survivor:

- **M11 — removing `cancel`'s `if (p.canceled) revert Canceled();` guard
  SURVIVED.** The existing suite only exercised the two guards in `cancel`
  through paths where `NotOpen` (past-end) triggers first; nothing called
  `cancel` twice on a still-open proposal to force the `Canceled` branch.
  **Fix applied**: added `test_cancelTwiceRevertsCanceled` to
  `test/PoolVoting.t.sol` (cancel once, then assert the second `cancel`
  call reverts with `PoolVoting.Canceled.selector`). Re-ran the same
  mutation afterward — now **KILLED**
  (`test_cancelTwiceRevertsCanceled` fails as expected). `src/PoolVoting.sol`
  was restored to its original content before moving on; `git diff src/`
  is empty at the end of this task.

All other 12 mutations (both `BadOptions` and `BadWindow` arms, `NotOpen`
and `Canceled` in `vote`, `BadOption`, `NoWeight`, the re-vote subtraction,
`propose`'s `onlyOwner`, `cancel`'s `NotOpen` check, and both `VoteToken`
self-delegation mutations) were killed on the first application — no other
coverage holes found.

## What was NOT run / NOT triaged

## Result

- `git diff src/` is empty (confirmed after the mutation pass and again
  before commit) — no mutation was left in place.
- `test/VoteToken.t.sol` (8) + `test/PoolVoting.t.sol` (now 12, +1 killing
  test) all pass: 20/20.
- Every slither/aderyn finding on the two new contracts is triaged above;
  all are false-positives/by-design, consistent with the brief's
  pre-approval of the timestamp-comparison category.
- Mythril's canary was flagged (proof of execution); VoteToken's real run
  is a genuine clean pass across 24 findings, all triaged as known FP
  classes; PoolVoting's real run is explicitly flagged as short-circuited
  by immutable-zeroing rather than quoted as a clean result.
- Halmos proved all three requested tally-conservation properties with
  non-trivial path counts.
- 13/13 mutations killed (1 after adding a new test), and that test is
  committed alongside the triage doc.

## Addendum 2026-08-31: on-chain minimum voting window (MIN_WINDOW)

**Change**: `PoolVoting.sol` gained `uint48 public constant MIN_WINDOW = 1 days;`
and `propose`'s guard was extended to
`if (start < block.timestamp || end <= start || end - start < MIN_WINDOW) revert BadWindow();`.
Rationale: Orbit sequencer timestamps are unreliable at minute scale, so a
short voting window is now rejected on-chain rather than relying on operator
discipline. Two tests added first (TDD): `test_windowShorterThanMinReverts`
(end - start = 1 days - 1, expects `BadWindow`) and
`test_windowExactlyMinAccepted` (end - start = 1 days exactly, succeeds).
Both were confirmed red against the pre-change contract, then green after
the one-line guard extension. `test/halmos/PoolVotingSymbolic.t.sol`'s three
`propose(...)` calls used a 99-second window (`start+1` to `start+100`),
which the new guard would now reject unconditionally; the harness was
updated to `start+1` .. `start+1+1 days` so the symbolic properties still
exercise a real vote instead of vacuously reverting on every path.

**M14 mutation**: removed the ` || end - start < MIN_WINDOW` arm from the
`BadWindow` condition, ran both suites: `test_windowShorterThanMinReverts`
failed (the only test affected) — **KILLED**. `git diff src/` confirmed
empty after restoring. Row appended to
`audit/2026-08-31-governance-mutations.tsv` as `M14`.

**New findings on `PoolVoting.sol`**: slither's `uses timestamp for
comparisons` finding on `propose` now additionally cites the new
`end - start < MIN_WINDOW` sub-expression as part of the same dangerous-
comparison line (`src/PoolVoting.sol#59`) — **false-positive (expected)**,
same triage as the pre-existing entry for that line above: this is a
multi-day/1-day window arithmetic check, not a value miners can move
meaningfully by manipulating a several-second timestamp skew. Aderyn's
report shows no new finding categories on `PoolVoting.sol` beyond the two
already triaged above (external-call-before-state-write on the trusted
`token.clock()`/`token.getPastVotes()` reads, now also citing line 65/77
timing unaffected by this change; and the `onlyOwner`/`Ownable2Step`
centralization-by-design note). No new finding required triage beyond
restating the existing categories.

Mythril was not re-run: the immutable-zeroing short-circuit documented
above makes any PoolVoting mythril run uninformative regardless of the
contract's guard logic, and nothing about this change alters that.

**Result**: `git diff src/` is empty after the mutation pass (confirmed
again before commit). 22/22 tests pass. 3/3 halmos properties still pass
with non-trivial path counts. M14 mutation KILLED. No new slither/aderyn
finding categories on `PoolVoting.sol`.

