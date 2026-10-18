# AGENTS.md — working on Haymaker

Instructions for AI coding agents (and humans) working in this repository. Read `README.md` for the game design and `PLAN.md` for architecture and milestones before starting non-trivial work.

## Project at a glance

- Native iPhone-only boss-rush arcade boxing game: Swift 6, SwiftUI shell, Metal/SceneKit arena. Local-first, no accounts, no network.
- `Packages/HaymakerKit` — pure-Swift deterministic match engine. The engine is authoritative; keep gameplay logic here, not in views.
- `Packages/HaymakerStore` — local persistence (SQLite via GRDB).
- `Haymaker/` — the app target; `HaymakerUITests/` — simulator UI journeys.
- `scripts/` — CI gates and asset tooling; `ArtDirection/` — asset provenance.
- Toolchain is pinned in `toolchain.json` (Xcode 26.0.1, iOS SDK 26.0). Never substitute another toolchain.

## Hard constraints (CI enforces these)

- iPhone only: `TARGETED_DEVICE_FAMILY = 1`. Do not add iPad support.
- Bundle id stays `com.infinityball.haymaker`; the privacy manifest must stay embedded.
- Zero network: no networking code or entitlements (`scripts/check_zero_network.sh`).
- Native only: no Flutter, React Native, Unity, etc. (`scripts/check_native_only.sh`).
- Signing material (`.p8`, `.p12`, `.mobileprovision`, `.cer`) must never be committed.
- Original characters and assets only; keep provenance current in `ArtDirection/README.md`.

## Git workflow

`main` is always releasable. **Never commit feature or fix work directly to `main`** — all new work goes through a branch and a pull request.

1. **Start from fresh main.** `git fetch origin && git checkout main && git pull --ff-only`.
2. **Use a branch per piece of work**, named by type: `feat/<short-topic>`, `fix/<short-topic>`, `chore/<short-topic>`, `docs/<short-topic>`.
3. **Use a git worktree for each branch** so parallel tasks never share a working directory:
   ```sh
   git worktree add ../haymaker-<short-topic> -b feat/<short-topic> origin/main
   cd ../haymaker-<short-topic>
   ```
   Do the work, commit, and push from that worktree. When the PR has merged, clean up:
   ```sh
   git worktree remove ../haymaker-<short-topic>
   git branch -D feat/<short-topic>
   git fetch --prune
   ```
   Do not reuse one worktree for unrelated tasks, and do not leave stale worktrees behind.
4. **Commit small and often** with Conventional-Commit-style messages (`feat:`, `fix:`, `chore:`, `docs:`, `test:`), matching the existing history, e.g. `fix: keep versus controls addressable in landscape (#24)`.
5. **Push the branch and open a PR** against `main` with `gh pr create`. The description should say what changed, why, and how it was verified (which tests or gates were run).
6. Keep PRs focused. Unrelated cleanup goes in its own branch and PR.

## Verify before opening a PR

Run what you can locally and say in the PR what you ran. Matches the CI jobs in `.github/workflows/ci.yml`:

```sh
swift test --package-path Packages/HaymakerKit
swift test --package-path Packages/HaymakerStore     # on Linux add: -Xswiftc -DGRDBCUSTOMSQLITE
bash scripts/test_host_sessions.sh
bash scripts/check_zero_network.sh
bash scripts/check_native_only.sh
python3 scripts/test_rig_fighters.py                  # when touching fighter assets or rigs
python3 scripts/test_fighter_clips.py                 # when touching fighter.clips or the clip extractor
```

The iOS build and simulator UI journey need macOS with Xcode and only run in CI on the pinned toolchain. If you can't run them locally, rely on the PR build.

Engine changes need tests in `Packages/HaymakerKit/Tests`. Keep the engine deterministic — no wall-clock time, unseeded randomness, or I/O in it. Rebuild fighter assets with `python3 scripts/rig_fighters.py` rather than editing generated models by hand. Never commit Mixamo `.fbx` downloads; only the derived `.skin` sidecars and `fighter.clips` belong in the repo.

## Pull request review and auto-merge

CI runs on every PR with two jobs that must both pass:

- `Linux package tests (swift test)`
- `iOS build + iPhone-only + toolchain pin`

A PR is **clean** when all of the following hold:

- Both CI jobs above are green on the PR's latest commit.
- The branch is up to date with `main` and has no merge conflicts.
- No unresolved review comments or requested changes.
- The diff only contains what the PR description says, with no secrets, signing material, or stray build output (`DerivedData/`, `*.xcresult`).

**If the PR is clean, merge it automatically — don't wait for further human approval.** Prefer squash merge and delete the branch:

```sh
gh pr merge <number> --auto --squash --delete-branch
```

`--auto` lets GitHub merge as soon as required checks pass. If auto-merge isn't enabled for the repo, wait for green checks (`gh pr checks <number> --watch`) and then run the same command without `--auto`.

**If the PR is not clean**, do not merge. Fix failures on the same branch and push (CI re-runs), or rebase onto `main` if it is behind. If a failure looks like a CI environment problem rather than your change (for example the pinned Xcode or simulator runtime missing on the runner), say so on the PR and leave it for a human. Never bypass, skip, or weaken a CI gate to get a PR through, and never force-push to `main`.

After merge, sync: `git checkout main && git pull --ff-only`, then remove the worktree as above.

## Docs

- Update `README.md` when player-visible behavior, validation numbers, or setup steps change.
- Update `PLAN.md` when architecture or milestones change.
- Update this file when the workflow changes.
