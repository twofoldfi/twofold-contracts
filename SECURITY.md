# Security

## Reporting a vulnerability

Email **security@twofold.fi**. You will get a reply within three business
days. If it bounces, use contact@twofold.fi with "security" in the subject.

Do not open a public issue for a vulnerability. Issues are for reproducible
bugs and integration questions, and everything posted there is visible to
everyone immediately.

The same contact is published at
`https://twofold.fi/.well-known/security.txt`.

## Scope

The contracts this repository deploys on Robinhood Chain (chain id 4663), at
the addresses listed in the README. Verified source on Blockscout is the
reference; this repository mirrors it.

Out of scope:

- `DualPoolHook` and `AllowlistedFactory` are stock Uniswap contracts, deployed
  byte for byte from the pinned upstream commit. Report findings in those to
  Uniswap through their published process; tell us too so we can respond.
- Third-party contracts the protocol reads or calls (the Uniswap v4 PoolManager
  and periphery, the USDG token, the Steakhouse vaults).
- The website, API and MCP server are not in this repository. Report issues
  in them to the same address.

## What we ask

- Give us a reasonable window to fix before any public disclosure. Ninety days
  is the default; tell us if you need a different one.
- Do not exploit a finding against live pools or user funds. A proof of
  concept on a fork is enough.
- Do not run denial-of-service, spam or social engineering against the team,
  the chain or the RPC endpoints.

## What you can expect

- Acknowledgement, a fix timeline, and credit in the fix notes if you want it.
- There is no paid bounty program at this time. If that changes, this file is
  where it will be announced.

## Vendors

Unsolicited offers of audits, marketing or other services posted as issues or
pull requests are closed without reply. Audits are commissioned by the team on
its own schedule.
