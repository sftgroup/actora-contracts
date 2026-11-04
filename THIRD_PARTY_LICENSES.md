# Third-Party Licenses

Direct dependencies of this repository and the license each declares.
Transitive dependencies are not enumerated; run the commands below before a release.

```bash
npx license-checker --summary --production
npx license-checker --onlyAllow "MIT;ISC;Apache-2.0;BSD-2-Clause;BSD-3-Clause;0BSD;MPL-2.0"
```

## Contracts (`contracts/`)

Solidity sources carry `SPDX-License-Identifier: MIT`. Upstream dependencies are
kept as git submodules and are not copied into this repository:

| Component | Source | License |
|---|---|---|
| OpenZeppelin Contracts | `contracts/lib/openzeppelin-contracts` | MIT |
| OpenZeppelin Contracts Upgradeable | `contracts/lib/openzeppelin-contracts-upgradeable` | MIT |
| forge-std | `contracts/lib/forge-std` | MIT |
