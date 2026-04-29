## Summary

Explain the motivation and the changes. Link issues (e.g., Closes #123).

## Changes

- [ ] Behavior change
- [ ] UI change (screenshots below)
- [ ] Refactor / chore
- [ ] Tests
- [ ] Docs

## Test Plan

Steps to verify locally (commands, screenshots, recordings). Include model used.

Required before marking ready:

- [ ] Local targeted verification passed for the files touched
- [ ] GitHub checks are attached to this PR
- [ ] `test-core`, `test-cli`, `swiftlint`, `shellcheck`, and `pr-clean-gate` are green
- [ ] I ran `scripts/ci/check-pr-clean.sh osaurus-ai/osaurus <PR number>`

## Screenshots

If UI updated, add before/after.

## Checklist

- [ ] I have read `docs/CONTRIBUTING.md`
- [ ] I added/updated tests where reasonable
- [ ] I updated docs/README as needed
- [ ] I verified build on macOS with a Swift 6.2-capable Xcode toolchain
- [ ] This PR is draft/blocked if any GitHub check is missing, pending, cancelled, or failing
