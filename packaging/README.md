# Linux / AUR release preparation

These scripts prepare and verify a Linux release locally. None of them uploads, installs on the host,
changes repository visibility, creates tags or pushes to AUR.

## Prepare and build

Requirements: the Arch `base-devel`, `desktop-file-utils` and `namcap` packages, plus the runtime
dependencies listed in `aur/PKGBUILD.in`. The sibling OpenTodo clone must contain tag `v0.22.0`.
Only the pinned tag's allowlisted test fixtures are read; the server is not run or bundled.

From the repository root:

```sh
python3 packaging/prepare-linux-release.py --output dist/releases/0.12.6 \
  --source-url https://chipdust.au/dustpan/downloads/v0.12.6/dustpan-0.12.6.tar.gz \
  --homepage https://chipdust.au/dustpan/ --maintainer 'Chizzler <hello@chipdust.au>'
makepkg --check --dir dist/releases/0.12.6
python3 packaging/verify-linux-release.py dist/releases/0.12.6
```

No `sudo` is needed for these steps. The last command uses fakeroot and a disposable pacman root to
test installation, reinstallation and removal with dependency checks disabled there. The regular
makepkg build checks dependencies against this machine. This is not a clean-chroot dependency test.

For a fresh Arch environment, with Docker available:

```sh
bash packaging/check-clean-build.sh dist/releases/0.12.6 > dist/releases/0.12.6/clean-build.log 2>&1
```

This downloads the official `archlinux:base-devel` image, resolves dependencies through makepkg, runs
the tests, builds and installs the package, checks its actual launcher/imports/icon, then removes it.
The container is discarded afterward. The release folder is mounted read-only, and the host's package
installation and user files are untouched.

Outputs in the ignored `dist/releases/0.12.6/` directory:

- `dustpan-0.12.6.tar.gz`: Linux source and public docs, including upstream test fixtures and licenses.
- `dustpan-0.12.6-1-any.pkg.tar.zst`: the locally built Arch package.
- `PKGBUILD` and `.SRCINFO`: generated AUR metadata, using a local source file in offline-draft mode.
- `SHA256SUMS` and `CONTENTS.txt`: the source archive checksum and explicit file list.
- `pacman-test.log`: disposable-root transaction output, including expected non-root ownership warnings.

The archive excludes Apple sources, Git history, project notes, the dev diary, dev/server databases,
config and credentials. The exporter uses an allowlist rather than archiving the repository.
Source tarball ordering, ownership, permissions, gzip header and timestamps are deterministic.
`SOURCE_DATE_EPOCH` overrides the default timestamp of the latest commit.

`namcap` may warn that `python-cairo` is unnecessary. Keep it: the calendar's
`Gtk.Snapshot.append_cairo` needs Pycairo's foreign-type conversion, which static import analysis misses.

## Installed layout

`/usr/bin/dustpan` runs the private Python modules under `/usr/lib/dustpan`. The package also installs
the desktop launcher, shared icon, setup docs and licenses. The icon path used by the existing app is
provided by a symlink into the icon theme directory. The quick-add vocabulary stays beside its module.
All user config and task data remain outside the package.

Autostart is opt-in via a template under `/usr/share/doc/dustpan`. Existing checkout installs must have
their per-user launcher and autostart entry removed with the old `desktop/install.sh --remove` before
switching; otherwise those entries can shadow the packaged version. That command preserves task data.

## Before publication

Regenerate an existing release only from its tag:
later commits, including documentation updates, can change the archive bytes and default timestamp.

- Commit/tag the finished source, regenerate the release from it and verify its deterministic checksum.
- Upload only the public archive/package, setup guide, release notes and checksums to the chosen versioned
  URL. Verify downloaded bytes and build in an empty folder from the public source URL.
- Update only Dustpan's ChipDust page and downloads; do not deploy unrelated work in the blog checkout.
- Create/register the AUR account and dedicated public SSH key, then push the prepared recipe and `.SRCINFO`.
  Recheck `dustpan` before submission; both AUR and official repositories had no match on 2026-11-15.

To regenerate the chosen public recipe locally:

```sh
python3 packaging/prepare-linux-release.py --output dist/releases/0.12.6 \
  --source-url https://chipdust.au/dustpan/downloads/v0.12.6/dustpan-0.12.6.tar.gz \
  --homepage https://chipdust.au/dustpan/ \
  --maintainer 'Chizzler <hello@chipdust.au>'
```

The source archive's content is independent of these recipe settings, so
the checksum stays the same. Keep the generated archive beside the recipe for local builds.
After uploading, verify the public download matches `SHA256SUMS` and build
from an empty directory to prove the public URL works.

The eventual AUR repository contains `PKGBUILD` and `.SRCINFO`, not the application archive or Arch
binary package. AUR submission requires an AUR account with a registered public SSH key.

References: [PKGBUILD manual](https://man.archlinux.org/man/PKGBUILD.5.en),
[makepkg manual](https://man.archlinux.org/man/makepkg.8.en),
[AUR submission guidelines](https://wiki.archlinux.org/title/AUR_submission_guidelines).
