# Preparing the Mac public preview

Candidate: **Mac 0.19.1** (build 2), a pre-1.0 preview. Linux releases are prepared separately in the
Linux development environment; they are not a gate for this Mac release.

The Mac helper builds local artifacts. CI uploads test artifacts to Actions; it does not publish releases,
change repository visibility, create tags or send builds to Apple.

## Checks before publication

- Commit and review the intended Mac release source, including LICENSE, NOTICE.md and CHANGELOG.md.
  Check `git diff --check`, version strings and release notes. Build every release artifact from that commit.
- Run the Mac release checks with OpenTodo v0.22.0 fixtures. No protocol vector tests should skip.
- Run `python3 packaging/macos/audit-dependencies.py`; review any changed vendored hashes or new imports.
  The package build also audits the linked libraries. See [apple/DEPENDENCIES.md](apple/DEPENDENCIES.md).
- Build with [packaging/macos/README.md](packaging/macos/README.md). Public downloads require Developer ID
  signing, Accepted notarization, stapling and Gatekeeper validation. Ad-hoc `local` zips are test artifacts.
- On a clean Mac profile, check standalone startup, quick add, editing, completion/Undo, recurrence, reminders,
  notifications, calendar scheduling, sync after offline edits, account switching, and upgrade with existing data.
  Check open at login and uninstall without deleting tasks. Use the final downloaded artifact for these trials.
  Check that welcome completion persists, existing profiles skip it, and reminders continue with the main window closed.
- Verify the app version, checksums, license notices, matching Apple source archive and stated limitations.
  Use sample tasks for screenshots; keep credentials, databases and backups out of public artifacts.
- If making the repository public, review its history and screenshots and enable private vulnerability reporting.
  The corresponding Apple source archive is allowlisted and does not include repository history or development data.

## Publication

After the gates pass, prepare a GitHub **prerelease** using the Mac notes in CHANGELOG.md and the tag
`mac-v0.19.1`. Attach the notarized universal Mac zip, matching Apple source and SHA256SUMS.
Update the README with the actual Mac download link. Make any repository visibility change explicitly
and separately. Preserve the independent Linux release process and version history.

## Local preparation status

The universal Mac build, corresponding source and local test artifacts are prepared. Developer ID
signing/notarization, hosted Mac CI results and final clean-profile trials remain publication gates.
Record evidence from each final run rather than carrying forward results from earlier development builds.
