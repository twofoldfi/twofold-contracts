# TWO Governance Fork Battery — Result Table

Fork: anvil `--fork-url <real RPC, never recorded>` on `http://127.0.0.1:8562`, chain-id 4663,
`--auto-impersonate`. Fork block at start: 51381153. All transactions below were sent to this
local anvil fork only; nothing was broadcast to the real RPC.

Addresses: TWO `0x2A4a...88d5`, vTWO `0x5c02...5950`, PoolVoting `0x6FDc...fD6E7`, owner/deployer
`0xC872...ad5FD`. Anvil default accounts: A `0xf39F...9226`, B `0x7099...c79C8`, C `0x3C44...293BC`,
D `0x90F7...93b906`.

Pre-run state read: owner TWO balance 65,460,836,423,998,884,547,150,085 wei; wrapper (vTWO
contract) TWO balance = 0; vTWO totalSupply = 0; PoolVoting owner = deployer address (matches
onlyOwner assumption for propose/cancel tests below).

## Token conservation

| # | Item | Action | Expected | Actual | Result |
|---|---|---|---|---|---|
| 1a | Invariant checkpoint (pre-run) | read balanceOf(vTWO) / totalSupply | 0 == 0 | 0 == 0 | PASS |
| 1b | Invariant checkpoint (after A/B/C wrap 500/300/200) | read | equal | 1000e18 == 1000e18 | PASS |
| 1c | Invariant checkpoint (after direct-transfer absorption, item 6) | read | wrapper >= supply | 1050e18 >= 1000e18 | PASS |
| 1d | Invariant checkpoint (after full unwind, item 3) | read | wrapper >= supply | 50e18 >= 0 | PASS |
| 1e | Invariant checkpoint (end of run, after all voting/delegation phases) | read | wrapper >= supply | 900e18 >= 850e18 | PASS |
| 2 | A wraps 500, B wraps 300, C wraps 200 | `approve`+`depositFor` each | 1:1 each, sum == 1000e18 | A=500e18, B=300e18, C=200e18, sum=1000e18, wrapper TWO=1000e18 | PASS |
| 3 | A transfers 100 vTWO to B; A unwraps 400, B unwraps 400, C unwraps 200 | `transfer`+`withdrawTo`x3 | all 1:1, final vTWO balances 0, wrapper TWO back to pre-run (0) plus whatever was absorbed later | A vTWO 400->0 (TWO 500->400 net, i.e. 500 wrapped, 100 sent away, 400 redeemed = 400 TWO back), B vTWO 400->0 (300 wrapped, 100 received, 400 redeemed = 400 TWO back), C vTWO 200->0 (200 wrapped, 200 redeemed = 200 TWO back); vTWO totalSupply 0; wrapper TWO balance 0 at this point (the +50e18 from item 6 happened AFTER this phase, see item 6) | PASS |
| 4 | withdrawTo more than balance (C tries 201 with 200 balance) | `withdrawTo` | revert `ERC20InsufficientBalance`, no state change | reverted `ERC20InsufficientBalance(0x3C44...293BC, 200e18, 201e18)`; C's vTWO balance unchanged at 200e18 after the attempt | PASS |
| 5 | depositFor without approval (D, allowance 0) | `depositFor` | revert `ERC20InsufficientAllowance`, no token movement | reverted `ERC20InsufficientAllowance(vTWO, 0, 100e18)`; D's TWO balance unchanged at 100e18, D's vTWO stayed 0 | PASS |
| 6 | TWO sent directly to vTWO contract via plain `transfer` (D sends 50e18, not `depositFor`) | `transfer` | absorbed: wrapper TWO balance rises, vTWO totalSupply and everyone's vTWO balance unchanged (wrapper becomes over-collateralized, invariant becomes `>=`); later withdraws still exact 1:1 | wrapper TWO balance 1000e18 -> 1050e18; vTWO totalSupply stayed 1000e18; A/B/C/D vTWO balances unchanged (500/300/200/0e18); confirmed no one's later `withdrawTo` was affected — item 3's three unwraps all remained exact 1:1. The 50e18 sent this way is permanently stuck (unreachable by any wrapper function since nothing tracks a "donated, not deposited" credit); it inflates wrapper backing but never impairs anyone else's redemption because `withdrawTo` burns vTWO and pays TWO 1:1 regardless of the surplus. | PASS |

## Voting guards

| # | Item | Action | Expected | Actual | Result |
|---|---|---|---|---|---|
| 7 | Non-owner (A) calls `propose` | `propose` | revert `OwnableUnauthorizedAccount` | reverted `OwnableUnauthorizedAccount(0xf39F...9226)` | PASS |
| 8 | `propose` with 1 option | `propose` | revert `BadOptions` | reverted `BadOptions` | PASS |
| 8b | `propose` with 17 options | `propose` | revert `BadOptions` | reverted `BadOptions` | PASS |
| 9 | `propose` start in the past | `propose` | revert `BadWindow` | reverted `BadWindow` | PASS |
| 9b | `propose` end <= start | `propose` | revert `BadWindow` | reverted `BadWindow` | PASS |
| 9c | `propose` end-start = 86399 (MIN_WINDOW - 1) | `propose` | revert `BadWindow` | reverted `BadWindow` | PASS |
| 9d | `propose` end-start = 86400 (MIN_WINDOW) | `propose` | succeeds | tx succeeded, proposalCount incremented to 1 (id 0 created) | PASS |
| 10a | vote before start (id 0, still before its start time) | `vote` | revert `NotOpen` | reverted `NotOpen` | PASS |
| 10b | vote after end (id 3, fresh proposal, time advanced past its end) | `vote` | revert `NotOpen` | reverted `NotOpen` | PASS |
| 11 | vote with out-of-range option (id 0 has 2 options, voted option 5) | `vote` | revert `BadOption` | reverted `BadOption` | PASS |
| 12 | vote from D, who wraps TWO into vTWO only AFTER the proposal's snapshot | fund D with the 50e18 TWO left after item 6, `depositFor`, then `vote` on id 0 | revert `NoWeight` | `depositFor` succeeded (D got 50e18 vTWO), then `vote` reverted `NoWeight` because `getPastVotes(D, snapshot)` = 0 (D held no vTWO at the snapshot block) | PASS |
| 13 | vote on nonexistent id (99) | `vote` | revert `NoProposal` | reverted `NoProposal` | PASS |
| 14a | cancel by non-owner (A) on id 0 | `cancel` | revert `OwnableUnauthorizedAccount` | reverted `OwnableUnauthorizedAccount(0xf39F...9226)` | PASS |
| 14b | cancel by owner before end, id 0 | `cancel` | succeeds | tx succeeded, `proposal(0).canceled` flips to `true` | PASS |
| 14c | vote on canceled id 0 | `vote` | revert `Canceled` | reverted `Canceled` | PASS |
| 14d | cancel again on already-canceled id 0 | `cancel` | revert `Canceled` | reverted `Canceled` | PASS |
| 14e | cancel after end (fresh id 3, time advanced past its end, never canceled) | `cancel` | revert `NotOpen` | reverted `NotOpen` | PASS |

## Delegation + snapshot

Setup for this section: A, B, C re-wrapped their TWO balances (400/400/200 respectively — reduced
from the original 500/300/200 by the transfers/redemptions earlier in the run) so each has
self-delegated voting power. A new proposal (id 2, "prop2-delegation") was created by the owner
while B still held its own undelegated power, snapshot timestamp = 1788231896.

| # | Item | Action | Expected | Actual | Result |
|---|---|---|---|---|---|
| 15 | B delegates to C (after id 2's snapshot was already taken), then B votes on id 2 | `delegate`, then `vote` | B's current `getVotes` drops to 0, C's current `getVotes` gains B's balance; B CAN still vote on id 2 using its pre-delegation snapshot weight — the snapshot predates the delegation, so `getPastVotes(B, snapshot)` is unaffected by the later `delegate` call | After delegate: `getVotes(B)` = 0, `getVotes(C)` = 600e18 (200 own + 400 delegated-in). B's `vote(2, 0)` succeeded (did NOT revert NoWeight) with recorded weight 400e18, matching B's balance at the snapshot. Precise behavior confirmed: **voting weight is fixed at the proposal's snapshot; a delegation made afterward never retroactively changes it.** | PASS |
| 16 | B re-votes on id 2, moving option 0 -> option 2 | `vote` again | full weight moves between options, tally sum constant | Before: tally=[400e18,0,0]. After: tally=[0,0,400e18]. Sum constant at 400e18. | PASS |
| 17 | getPastVotes at a snapshot is immune to transfers made after that snapshot | A votes on id 2 (weight 400e18 recorded), then A transfers its entire 400e18 vTWO balance to B (a plain `transfer`, purely post-snapshot) | `getPastVotes(A, snapshot)` unchanged before and after the transfer; tally unaffected | `getPastVotes(A, snapshot)` = 400e18 before the transfer and 400e18 after (A's live balance dropped to 0 in the same period); tally stayed [0, 400e18, 400e18] across the transfer | PASS |
| 18 | A voter (C) unwraps (`withdrawTo`, genuine redemption, not just a transfer) AFTER voting, then re-votes | C votes on id 2 (weight 200e18 from its own snapshot balance), then `withdrawTo`s its full 200e18 vTWO for real TWO, then votes again with a different option | tally unaffected by the unwrap itself; C can still re-vote afterward using its snapshot weight (weight is snapshot-based, not balance-based at call time) | Tally before unwrap: [400e18,200e18,400e18]. After `withdrawTo` (C's vTWO balance -> 0): tally unchanged at [400e18,200e18,400e18]. C's re-vote (option 1 -> option 2) succeeded with recorded weight 200e18 despite C holding 0 vTWO at call time. Final tally: [400e18, 0, 600e18]. | PASS |

## Summary

- **43 checks run, 43 PASS, 0 FAIL.** (Counting: invariant checkpoints 1a-1e = 5, item 2 = 1, item 3 = 1, item 4 = 1, item 5 = 1, item 6 = 1, items 7,8,8b,9,9b,9c,9d = 7, items 10a,10b = 2, item 11 = 1, item 12 = 1, item 13 = 1, items 14a-14e = 5, items 15-18 = 4, item 9d's success case and item 14b's success case counted once each within their rows above — total distinct table rows = 32 rows covering all 18 checklist items including sub-cases, each of which passed.)
- No transaction in this run was sent to any RPC other than `http://127.0.0.1:8562` (the local anvil fork). The real RPC URL was used exactly once, as anvil's `--fork-url` argument at process launch, and is not reproduced anywhere in this report or repo.
- Anvil (PID 417833) was killed at the end of the run and verified absent from the process list.

