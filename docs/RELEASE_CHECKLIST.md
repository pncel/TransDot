<!-- SPDX-License-Identifier: SHL-0.51 -->
# Release Checklist

## 1. Pre-Release Validation

1. Ensure `develop` is green in CI (`.github/workflows/transdot-ci.yml`).
2. Run canonical regression locally:
   - `SKIP_GEN=1 ./tb/sv_tb_new/run_regression.sh`
3. Confirm `refactor.md` phase tracking and `docs/CHANGELOG.md` are up to date.
4. Confirm manifests are consistent with active sources:
   - `Bender.yml`
   - `src_files.yml`

## 2. Version + Changelog

1. Create/refresh release notes under `docs/CHANGELOG.md`.
2. Freeze version references in downstream integrations as needed.

## 3. Tag Procedure

1. Merge release PR into `master`.
2. Create an annotated tag from `master`:
   - `git tag -a vX.Y.Z -m "TransDot vX.Y.Z"`
3. Push the tag:
   - `git push origin vX.Y.Z`
4. Create a GitHub release from the tag and copy release notes from `docs/CHANGELOG.md`.

## 4. Post-Release

1. Back-merge release commits from `master` into `develop`.
2. Re-open `docs/CHANGELOG.md` with an `[Unreleased]` section for next cycle.
