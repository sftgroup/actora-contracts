# Contributing

Thanks for your interest in Actora.

## Workflow

1. Fork the repository and create a topic branch.
2. Run the checks below before opening a pull request.
3. Sign off every commit with `git commit -s`.

## Checks

```bash
forge build
forge test
./tools/frozen-abi.sh
```

Contract changes must ship with tests under `test/`. The frozen-ABI gate
must be updated deliberately, never to silence a failure.

## Developer Certificate of Origin

All commits must include a `Signed-off-by` line, certifying the
Developer Certificate of Origin 1.1 (<https://developercertificate.org/>).

## License

By contributing you agree that your contributions are licensed under the MIT
License. The "Actora" name and logo are not licensed — see [TRADEMARK.md](./TRADEMARK.md).
