# PositionLocker battery triage — 2026-09-01

Contract: `src/PositionLocker.sol` (permanent locker for v4 PositionManager
NFTs). Two batteries ran today because the contract changed mid-session:

- **v1**: owner-gated `claim(tokenId, recipient)`, open registration.
- **v2 (final)**: PERMISSIONLESS `claim(tokenId)`/`claimAll()` paying only the
  stored owner-set `feeRecipient` (so bots can trigger claims for us),
  registration accepted only for NFTs sent BY the locker owner
  (anti-griefing: v1 let anyone lock a junk 0-liquidity position, which would
  have bricked `claimAll` with `CannotUpdateEmptyPosition` — found in review,
  proven on the fork), and `claimAll` skips 0-liquidity ids as belt-and-braces.
  Final review pass added `SelfRecipient`: feeRecipient can never be the
  locker itself (fees paid into the locker would be unrecoverable — it has no
  sweep by design). Constructor and setter both enforce it; halmos proves
  feeRecipient is never zero and never self, for all inputs. A second
  review pass (full-ABI walk, inherited surface included) added
  `RenounceDisabled`: `renounceOwnership` reverts, because a zeroed owner
  would turn the `from == owner()` registration gate into an open door for
  direct-to-locker mints (ERC721 mints arrive with from == address(0)).

Everything below is the v2 battery; the v1 battery also passed fully (its
only survivor was the equivalent `claimAll`-modifier mutant, an artifact of a
design v2 removed).

## What ran (v2)

| Tool | Result |
|---|---|
| forge unit tests (`PositionLockerTest`) | 17/17 pass, incl. byte-level checks of the claim encoding, the anti-griefing gate, both SelfRecipient guards and the renounce override |
| fork tests (`ForkPositionLockerTest`, anvil fork of 4663, real genesis NFT 1076283) | 4/4: locked the live NFT, a RANDO triggered claim and claimAll, real fees landed only on feeRecipient (caller got nothing), liquidity unchanged, NFT untransferable by anyone |
| halmos (`PositionLockerAuthTest`) | 5/5 proven for all inputs: non-owner can't set feeRecipient; feeRecipient never zero or self; non-posm can't register; posm can't register from a non-owner sender; owner() never becomes zero through any ownership function (the state property the renounce guard exists for) |
| mutation (15 mutants, harness `mutate2.sh`, session scratchpad) | **15/15 KILLED** — every gate (both zero-checks, both SelfRecipient checks, the RenounceDisabled override, posm gate, from-owner gate, onlyOwner), the zero-liquidity skip and its inversion, recipient theft, nonzero decrease, wrong action byte, dropped registration, loop off-by-one. (One harness artifact along the way: the setter zero-check mutant first reported SURVIVED because its two-line match string no longer existed contiguously and it mutated NOTHING — re-run with a valid match, it is KILLED (proven again on the final source after the renounce guard landed). A no-op mutant "surviving" is the mutation-layer version of a tool that never ran reporting clean.) |
| slither 0.11.6 | full run 129 contracts / 58 results; PositionLocker findings triaged below (`audit/2026-09-01-slither-v2.log`) |
| aderyn 0.6.8 | 2 finding classes, triaged below |
| mythril 0.24.8 | canary-validated session; 7 findings, all triaged below (`audit/2026-09-01-mythril-positionlocker.log`) |

## Slither findings on PositionLocker (each triaged)

- unused-return: `claim` ignores the second return of
  `getPoolAndPositionInfo` — FALSE POSITIVE, only the PoolKey is needed.
- calls-in-loop x3 (`getPositionLiquidity`, `getPoolAndPositionInfo`,
  `modifyLiquidities` reached from `claimAll`) — ACCEPTED BY DESIGN: the loop
  is bounded by owner-registered ids only (the from-owner gate makes the list
  unspammable), and single-position `claim` is the fallback.
- reentrancy-events: `FeesClaimed` after the external call — FALSE POSITIVE
  for harm: no state written after the call; callee is the immutable
  canonical PositionManager.
- `solc-0.8.26` version informational — house-pinned compiler, policy FP.

## Aderyn findings

- Centralization / `onlyOwner` — BY DESIGN, and narrower than v1: the owner
  can only choose the fee destination; claiming itself is permissionless and
  nobody, owner included, can move liquidity or the NFT.
- L-5 loop contains revert (`claimAll`) — MITIGATED: the one revert case a
  third party could once inject (0-liquidity position) is now both
  unregistrable (from-owner gate) and skipped (liquidity check). A remaining
  revert would require the PositionManager itself to revert, and per-id
  `claim` remains the fallback.

## Mythril (canary first, per the hard rule)

`MythrilCanary` FLAGGED SWC-107 (the planted pay-before-zeroing bug) earlier
this same session, so results are live, not void. Locker v2 runtime
(`deployedBytecode --evm-version shanghai`, `-t 3 --execution-timeout 2100`):
7 findings, all FALSE POSITIVES —

- SWC-123 requirement violation in `fallback` — the dispatcher reverting on
  unknown/invalid calldata, which is correct behavior, not a defect.
- SWC-101 integer overflow x6 on `owner()`, `pendingOwner()`,
  `positionManager()`, `feeRecipient()`, `claimAll()` and one internal
  dispatch label — the known viaIR ABI-pointer-arithmetic pattern on view
  getters, plus `claimAll`'s solc-0.8 CHECKED loop arithmetic (an overflow
  reverts; it cannot corrupt state).

## Verdict

Nothing real found by any tool; every finding triaged individually, none
dismissed wholesale. Not run: echidna (state space is one append-only
owner-curated array plus auth gates, covered symbolically by halmos).

## Known non-goals, stated plainly

- The lock is PERMANENT. No rescue, no timelock, no exit — that is the
  deliverable.
- Locking requires the NFT to be sent from the locker owner's address
  (`safeTransferFrom`); a plain `transferFrom` from anyone else parks the NFT
  unregistered but claim-able via `claim(tokenId)` (the PositionManager's own
  owner check is the real gate), just absent from `claimAll`'s list.
- All fees from all locked positions pay one `feeRecipient`; per-position
  routing does not exist by design (it is what makes permissionless claiming
  safe).

