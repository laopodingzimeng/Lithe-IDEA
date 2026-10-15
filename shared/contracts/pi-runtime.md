# Pi runtime package v1

Compatible worker updates are imported independently of the desktop installer.
The first host containing this manager must still be installed. New native UI,
host tools, OS permissions or wire protocol versions require a new host build.
This format is separate from declarative Lithe plugin packages: it contains the
complete executable Pi SDK subsystem, not an official plugin identity.

## Package identity

`lithe-pi-runtime.json` contains `schemaVersion: 1`, `protocolVersion: 1`, semantic
`version`, `sdkVersion`, `nodeVersion`, `platform` (`darwin` or `win32`),
`architecture` (`arm64` or `x64`), and `files`. Each file has `sha256` and `bytes`.
The identity of an imported version is the SHA-256 of the exact manifest bytes.
Version labels alone never choose or overwrite an installed copy.

The host validates platform, architecture, protocol, Node 24 compatibility and
the actual SDK package version. It rejects extra/missing/altered files, symlinks,
special files, traversal and ambiguous path separators. Limits are 20,000 tree
entries, 512 MiB total and 4 MiB for the manifest. Required files include the
worker entry, lockfile, package metadata, SDK package metadata, Node executable,
and macOS sandbox profile. The host's signed sandbox policy takes precedence over
the package's profile; runtime updates cannot change the host's OS write policy.

This is **explicit local import**, not an authenticated automatic updater.
Integrity hashes detect corruption and pin accepted bytes; they do not establish
publisher authenticity. The UI labels imports as local and asks users to use a
trusted source. No existing official-plugin signing identity is asserted. Bundled
packages participate in the app's code signature. Automated remote installation
requires a separate publisher trust mechanism before it can be enabled.

## Storage and lifecycle

macOS stores imported immutable copies at platform Application Support under
`Lithe/Pi/Runtime/Versions/<manifest-sha256>/`. `active.json` is an atomically
replaced pointer. `install-<UUID>` is private staging, validated before publish
and removed on cancellation/failure. Repair temporarily moves an unleased corrupt
copy to `replaced-<UUID>`, restores it on publish failure and removes it on success.
Copies remain until explicit removal, with a maximum of eight imported versions.

Each model request acquires a lease before launching. Switching versions waits
for all leases to end; cleanup drains even on cancellation. New requests while
work is active retain the old version. The final release revalidates and commits
the queued selection. Failed revalidation preserves the old selection and clears
the queue with an actionable message. A queued selection is memory-only: after a
crash the last committed `active.json` remains authoritative. Explicit rollback
uses the same selection path; `bundled` always names the read-only host baseline.

Used, selected and queued versions cannot be removed. Damaged versions stay
visible, cannot run, and may be repaired by reimport when no lease uses them.
Corrupt preferences leave the baseline available and can be repaired by selecting
a valid version. No operation writes into the installed app or Windows resources.
Runtime state and leases must never be shared between worktrees or app processes.
All project windows share one manager. A nonblocking kernel lock prevents a second
application process from selecting/removing a package while any request uses it;
the process releases ownership when its final lease and pending switch finish.
The first lock acquisition cleans abandoned `install-<UUID>` and corrupt backup
`replaced-<UUID>` directories. Process death releases the lock automatically.

## Build and verification

`integrations/pi-bridge/runtime.json` pins official Node archives and SHA-256s;
`package-lock.json` pins the full dependency tree. The builder verifies the
archive before extraction and uses `npm ci --ignore-scripts`. File ordering,
modes and timestamps are normalized before sealing. The archive builder sorts
entries, omits host extra fields and includes the manifest digest in its name.

macOS copies variants into `Contents/Resources/PiRuntime/darwin-<architecture>/`
during packaging. Nested code signing happens before the final runtime seal;
the app is then signed without re-signing nested binaries. Resealing is a build
operation only. At runtime the baseline is read-only, preserving code signatures
and the Sparkle differential-update baseline.

`scripts/test-pi-bridge.mjs` accepts the test-only `LITHE_PI_TEST_RUNTIME` path to
exercise the real packaged Node/SDK under isolation and compare all payload hashes
and manifest bytes before/after a typical request. Native runtime tests cover
lease ordering, repair, persisted rollback, incompatible packages, cancellation
and source/bundle immutability. Platform matrix verification remains pending until
native host and full desktop acceptance pass; package generation is not that proof.
