# Header-pass bytecode diff summary

Ran `forge inspect <C> deployedBytecode` before and after the house-header +
comment-trim edit, for each of the 5 deployable contracts under `src/`
(`src/interfaces/IDualPoolHookMinimal.sol` is an interface, not deployed —
no bytecode to compare, header/comment-trim applied for consistency only).

`foundry.toml` sets `bytecode_hash = "none"`, so there is no CBOR metadata
trailer at all in the deployed bytecode — comment/whitespace-only source
changes cannot move a trailer that doesn't exist. Result: byte-for-byte
IDENTICAL deployedBytecode for all 5 contracts, not merely "only the trailer
moved".

| Contract | before.hex vs after.hex | Verdict |
|---|---|---|
| VaultAllowlist | `diff -q` reports no differences | IDENTICAL |
| Registry | `diff -q` reports no differences | IDENTICAL |
| PlatformToken | `diff -q` reports no differences | IDENTICAL |
| StakingVault | `diff -q` reports no differences | IDENTICAL |
| OperatorController | `diff -q` reports no differences | IDENTICAL |

Raw hex captured in this directory: `<Contract>.before.hex` / `<Contract>.after.hex`.
Command used:

```
forge inspect <Contract> deployedBytecode > audit/header-pass/<Contract>.before.hex   # pre-edit
# ... house-header + comment-trim edit ...
forge inspect <Contract> deployedBytecode > audit/header-pass/<Contract>.after.hex    # post-edit
diff -q <Contract>.before.hex <Contract>.after.hex
```

