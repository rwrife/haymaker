# AGENTS.md — working on Haymaker

Instructions for AI coding agents (and humans) working in this repository. Read `README.md` for the game design and `PLAN.md` for architecture and milestones before starting non-trivial work.

## Project at a glance

- Godot-only boss-rush arcade boxing game. Local-first, no accounts, no network. Windows and Android exports exist; iPhone and iPad will use Godot's iOS export.
- `godot/` — the authoritative Godot 4.7.2 project for every platform.
- `godot/scripts/engine/` — deterministic GDScript match engine. Keep gameplay truth here, not in presentation code.
- `godot/scripts/game/` — menus, career progression, settings and local records in `user://`.
- `godot/scripts/arena/` — 3D arena, fighter animation, choreography and crowd.
- `godot/tests/` — headless engine regression tests and input/UI journeys.
- `scripts/` — CI gates and asset tooling; `ArtDirection/` — asset provenance.
- Legacy source, asset staging directories and Apple build configuration remain in the repository. They are not maintained game targets; do not mirror changes into them or treat them as the reference implementation.

## Hard constraints

- Godot is the only game implementation, including the planned iOS version. Do not add or maintain a separate platform-specific game.
- Package/bundle id stays `com.infinityball.haymaker`.
- Zero network: no runtime networking code or network permissions in export presets.
- Signing material (`.p8`, `.p12`, `.mobileprovision`, `.cer`) must never be committed.
- Original characters and assets only; keep provenance current in `ArtDirection/README.md`.

## Git workflow

`main` is always releasable. Use a branch and pull request unless the user explicitly requests a direct commit/push to `main`.

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

Run the checks relevant to your changes and say in the PR what you ran. Use Godot 4.7.2:

```sh
godot --headless --path godot --script res://tests/run_tests.gd
godot --headless --path godot --script res://tests/input_test.gd -- --isolated-store
python3 scripts/test_rig_fighters.py                  # when touching fighter assets or rigs
python3 scripts/test_fighter_clips.py                 # when touching fighter.clips or the clip extractor
python3 scripts/test_crowd.py                         # when touching crowd assets or scripts/build_crowd.py
```

Verify runtime and export changes in Godot on the affected platforms. The iOS export is planned, not yet configured or verified; do not claim device or store compatibility without evidence.

Engine changes need tests in `godot/tests/run_tests.gd`. Keep the engine deterministic — no wall-clock time, unseeded randomness, or I/O in it. Preserve golden-seed and replay fixtures without requiring a second implementation. Rebuild fighter assets with `python3 scripts/rig_fighters.py` rather than editing generated models by hand, and copy generated runtime assets into `godot/assets/models/`. Existing tooling still stages its output in `Haymaker/Models/`; that path is not an instruction to maintain the legacy app. Never commit Mixamo `.fbx` downloads; only the derived `.skin` sidecars and `fighter.clips` belong in the repo.

## Pull request review and auto-merge

The existing `.github/workflows/ci.yml` still checks legacy targets and has not yet been migrated to Godot. Its presence does not require maintaining a second game implementation. Report legacy CI blockers honestly; do not bypass or weaken checks to merge.

A PR is **clean** when all of the following hold:

- All required CI checks are green on the PR's latest commit, and the relevant Godot checks pass.
- The branch is up to date with `main` and has no merge conflicts.
- No unresolved review comments or requested changes.
- The diff only contains what the PR description says, with no secrets, signing material, or stray build output (`DerivedData/`, `*.xcresult`).

**If the PR is clean, merge it automatically — don't wait for further human approval.** Prefer squash merge and delete the branch:

```sh
gh pr merge <number> --auto --squash --delete-branch
```

`--auto` lets GitHub merge as soon as required checks pass. If auto-merge isn't enabled for the repo, wait for green checks (`gh pr checks <number> --watch`) and then run the same command without `--auto`.

**If the PR is not clean**, do not merge. Fix failures on the same branch and push (CI re-runs), or rebase onto `main` if it is behind. If a failure is a CI environment problem rather than your change, say so on the PR and leave it for a human. Never bypass, skip, or weaken a CI gate to get a PR through, and never force-push to `main`.

After merge, sync: `git checkout main && git pull --ff-only`, then remove the worktree as above.

## Docs

- Update `README.md` when player-visible behavior, validation numbers, or setup steps change.
- Update `PLAN.md` when architecture or milestones change.
- Update this file when the workflow changes.
