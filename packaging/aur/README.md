# AUR packages

| Package | Builds from | Notes |
|---|---|---|
| [`zenkai-bin`](zenkai-bin/PKGBUILD) | the release's `zenkai-vX-linux-x64.tar.gz` | No build tools needed; installs in seconds. |
| [`zenkai`](zenkai/PKGBUILD) | the release tag's source, with Zig | Fetches the pinned Zig dependencies in `prepare()`, runs the tests in `check()`. Needs `assets/zenkai.png`, so it starts at v1.6. |

Both install the same files (binary, desktop entry, icon, plugins and translations under
`/usr/share/zenkai`) and conflict with each other. KDE Plasma window switching (kwinctl) is
compiled into both. The `kwinctl` command-line tool is packaged separately from
[its own repository](https://github.com/dayvster/kwinctl) and is an optional dependency here.

## Publishing a package for the first time

1. Add your SSH public key on the AUR: My Account, SSH Public Key.
2. Clone the empty AUR repository, add the files and push:

   ```sh
   git clone ssh://aur@aur.archlinux.org/zenkai-bin.git /tmp/aur-zenkai-bin
   cp packaging/aur/zenkai-bin/PKGBUILD packaging/aur/zenkai-bin/.SRCINFO /tmp/aur-zenkai-bin/
   cd /tmp/aur-zenkai-bin
   git add PKGBUILD .SRCINFO
   git commit -m "Initial import: zenkai-bin 1.5"
   git push
   ```

## Releasing a new version

After tagging `vX.Y` and publishing its release:

```sh
cd packaging/aur/zenkai-bin        # and the same in packaging/aur/zenkai
sed -i 's/^pkgver=.*/pkgver=X.Y/; s/^pkgrel=.*/pkgrel=1/' PKGBUILD
updpkgsums                          # from pacman-contrib: refreshes sha256sums
makepkg -f                          # builds it, which also checks the new checksum
makepkg --printsrcinfo > .SRCINFO
```

Commit the change here, then copy `PKGBUILD` and `.SRCINFO` into the AUR clone and push as
above. `.SRCINFO` must always be regenerated after editing `PKGBUILD`; the AUR shows package
details from it.

For `zenkai`, `sha256sums=('SKIP')` is only a placeholder until v1.6 is tagged; `updpkgsums`
replaces it with the real checksum. Building it in a clean chroot (`pkgctl build` or
`extra-x86_64-build` from `devtools`) is the closest match to what AUR users get.
