# Presence regression suite

Mirrored from `slsteam-presence/tests/` alongside the 0.3.2-dev.2 payload. Only
plugin paths change to target `addons/presence/plugin/`; assertions remain the
same. `bash scripts/test-all.sh` runs these Node suites and the isolated Lua
backend smoke test, without depending on a sibling checkout or live Steam.

This development payload comes from the uncommitted
`fix/presence-session-cleanup` worktree based on
`0490b34c9430436764602698237b6f8492971f0b`, not that committed revision itself.
`vendor/MANIFEST.json` records `uncommitted-worktree` and the exact payload
hashes. Do not mistake passing mocks for desktop/Gaming Mode live validation,
or publish this snapshot as a released source revision.
