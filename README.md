<p align="center">
  <a href="https://twofold.fi">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://twofold.fi/brand/wordmark-light.png">
      <img src="https://twofold.fi/brand/wordmark-dark.png" alt="Twofold" width="360">
    </picture>
  </a>
</p>

<p align="center">
  <b>twofold-contracts</b> is the on-chain half of
  <a href="https://twofold.fi">Twofold</a>, the dual-yield liquidity protocol on
  Robinhood Chain: liquidity that earns swap fees and vault yield at the same
  time, on the same dollar.
</p>

<p align="center">
  <a href="https://twofold.fi/docs.html">docs</a> ·
  <a href="https://twofold.fi/app.html">app</a> ·
  <a href="https://github.com/twofoldfi/twofold-mcp">mcp server</a>
</p>

<p align="center">
  <img alt="Solidity" src="https://img.shields.io/badge/solidity-0.8.26-363636?logo=solidity&logoColor=white">
  <img alt="Foundry" src="https://img.shields.io/badge/built%20with-foundry-black">
  <img alt="EVM" src="https://img.shields.io/badge/evm-cancun-627EEA?logo=ethereum&logoColor=white">
  <img alt="Chain" src="https://img.shields.io/badge/chain-Robinhood%204663-00C805">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## Dual yield

A normal AMM position earns swap fees and nothing else. Idle inventory sits
still between trades.

Twofold pools sit behind a Uniswap v4 hook that keeps the quote leg in a
Morpho-curated vault and pulls it back just in time to fill a swap. The same
dollar earns twice: **swap fees plus vault yield**. Deposits are two-sided,
shares are ERC-1155, and any holder can burn their shares to take both legs
back out.

```
   deposit ---->  +---------------+                          +------------------+
                  |               |   ---- idle quote --->   |  Steakhouse USDG |
                  |    DualPool   |                          |  vault   (yield) |
      swap ---->  |      Hook     |   <--- just in time --   |                  |
                  +---------------+                          +------------------+
                          |
                          |  swap fees
                          v
                  OperatorControllerV2 ----> StakingVaultV2 ----> TWO stakers
```

## Contracts

| contract | role |
|---|---|
| `TwofoldToken` | TWO, the protocol token |
| `Registry` | canonical list of pools, hooks and vaults |
| `VaultAllowlist` | which ERC-4626 vaults a hook may route idle inventory into |
| `OperatorControllerV2` | owns the hook: initializes pools, bootstraps, harvests fees |
| `StakingVaultV2` | streams harvested fees to TWO stakers over a 1h cooldown cycle |
| `PoolZapper` | one-transaction entry from a single asset into a two-sided position |

`DualPoolHook` and `AllowlistedFactory` are stock upstream code from
[Uniswap/v4-hooks-public](https://github.com/Uniswap/v4-hooks-public), vendored
as a submodule and deployed byte-for-byte identical to the audited source.
The recorded mainnet runtime in `reference/` is what that identity is asserted
against — all 1158 bytes, CBOR trailer included.

### Hook source

The hook deployed by Twofold is [`uniswap/DualPoolHook.sol`](uniswap/DualPoolHook.sol),
a verbatim copy of `lib/v4-hooks-public/src/alf/DualPoolHook.sol` at the pinned
submodule commit
[`f2aa843`](https://github.com/Uniswap/v4-hooks-public/blob/f2aa843e266f8f9b34fdaf94ffb72eda5d9204f9/src/alf/DualPoolHook.sol)
(checksums in [`uniswap/SOURCE.txt`](uniswap/SOURCE.txt)), compiled with solc
0.8.26, via-IR, 200 optimizer runs, and deployed through the stock
`AllowlistedFactory` with CREATE2. No line of it is changed. Audit:
[OpenZeppelin, DualPool](https://github.com/Uniswap/v4-hooks-public/blob/main/docs/audit/openzeppelin-dualpool.pdf).

| Hook | Source verified | Notes |
|---|---|---|
| `0xd1BcbCCa41f3bdb6b4812652959c6dF725ea2Ac0` | [Blockscout, full match](https://robinhoodchain.blockscout.com/address/0xd1BcbCCa41f3bdb6b4812652959c6dF725ea2Ac0?tab=contract) · [Sourcify, exact match](https://repo.sourcify.dev/contracts/full_match/4663/0xd1BcbCCa41f3bdb6b4812652959c6dF725ea2Ac0/) | current stack, fee 500 pools |
| `0x127B3f3b7769f659C5eDBfF8b4005443f19FAAc0` | [Blockscout](https://robinhoodchain.blockscout.com/address/0x127B3f3b7769f659C5eDBfF8b4005443f19FAAc0?tab=contract) | first stack, fee 3000 pools, still live |

## Deployed — Robinhood Chain, id 4663

Current stack (2026-09-05):

| | address |
|---|---|
| DualPoolHook | `0xd1BcbCCa41f3bdb6b4812652959c6dF725ea2Ac0` |
| AllowlistedFactory | `0xa9ab194FB74dFD9991047839aE23A576c8403d95` |
| Registry | `0xdF1a23B1A7507Cc3B270DfA78FDD9ddA7bC36325` |
| VaultAllowlist | `0x3B1B0f1812a9a09664D82238E94c604D30Bb8134` |
| OperatorControllerV2 | `0x705F4f94344feD3f7BA98300F8bC04fdAE570340` |
| PoolZapper | `0x8934A298d3E59a632994ac254Dee19112127f2B7` |

First stack (2026-08), still live and withdrawable:

| | address |
|---|---|
| DualPoolHook | `0x127B3f3b7769f659C5eDBfF8b4005443f19FAAc0` |
| Registry | `0x1b66DD14C9281A18E696dbdb40cFB5070842c0C2` |
| VaultAllowlist | `0xe44c0d41a1afbf7234492bb7a3f745246c351c42` |
| OperatorControllerV2 | `0xc7295643EC5414DE243e3F9810Eb28F85e5d9ABb` |
| StakingVaultV2 | `0x06E463fDa4BEb4aA096142E673240aB9719fB3A9` |
| PoolZapper V2 | `0x2eF1C576797a51FB60B25d9f946D2562d2d2F9Fc` |
| TWO (TwofoldToken, [Blockscout](https://robinhoodchain.blockscout.com/token/0x2A4a33A2163D005d8E7f1D9aC08d14c98db288d5)) | `0x2A4a33A2163D005d8E7f1D9aC08d14c98db288d5` |

Underlying v4 infrastructure: PoolManager
`0x8366a39CC670B4001A1121B8F6A443A643e40951`, UniversalRouter
`0x8876789976dEcBfCbBbe364623C63652db8C0904`, Permit2
`0x000000000022D473030F116dDEE9F6B43aC78BA3`.

## Build

```sh
git clone --recurse-submodules https://github.com/twofoldfi/twofold-contracts
cd twofold-contracts
forge build
forge test
```

Requires [Foundry](https://getfoundry.sh). Fork tests expect a local Robinhood
Chain fork; point them at one with `FORK_RPC_8547` and friends, or skip them
with `forge test --no-match-contract Fork`.

Deployment and operations scripting is not part of this repo.

`foundry.toml` pins every contract to `via_ir = true, optimizer_runs = 200`.
That is not a style choice: it is the profile the audited upstream factory was
verified under, and the only setting the mixed compilation graph accepts.

## Security

Every contract change runs the full battery, and findings are triaged in
writing rather than dismissed by category:

| | |
|---|---|
| [Slither](https://github.com/crytic/slither) | `slither . --exclude-dependencies` |
| [Aderyn](https://github.com/Cyfrin/aderyn) | `aderyn .` |
| [Halmos](https://github.com/a16z/halmos) | symbolic proofs in `test/halmos/` |
| [Mythril](https://github.com/Consensys/mythril) | against `deployedBytecode`, canary-verified |

The test suite is mutation-tested: guards in `src/` are broken one at a time to
confirm a test actually dies. A passing suite that has never been seen to fail
measures nothing.

Found something? Open an issue, or reach us at
[twofold.fi](https://twofold.fi).

## License

MIT. See [LICENSE](LICENSE).
