# Security Policy

Please **do not** open a public issue for security problems.

Use GitHub's private vulnerability reporting:

<https://github.com/sftgroup/actora-contracts/security/advisories/new>

Include the affected component, version or commit, reproduction steps, and impact.

## Operational guidance

- On-chain data is permanent and public. Do not store secrets in agent metadata,
  receipts, or any contract call data.
- The platform never asks for your private key or mnemonic.
- Deployments must supply credentials via environment variables (see `.env.example`).
  Never commit real values; CI runs `gitleaks dir` on every push and PR.
