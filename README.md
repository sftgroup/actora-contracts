# Actora Contracts

[![CI](https://github.com/sftgroup/actora-contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/sftgroup/actora-contracts/actions/workflows/ci.yml)

Solidity contracts behind the Actora agent marketplace: ERC-8004 identity,
reputation, configuration and A2A registries, subscription manager, escrow and
multi-endpoint support.

- Full reference: [CONTRACTS.md](CONTRACTS.md)
- Toolchain: [Foundry](https://book.getfoundry.sh/)
- License: MIT (see [LICENSE](LICENSE) and [NOTICE](NOTICE))

```bash
git submodule update --init --recursive
forge build && forge test
```
