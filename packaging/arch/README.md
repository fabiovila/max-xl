# Arch Linux packaging

`PKGBUILD` builds the rolling **`max-xl-git`** package straight from
`https://github.com/fabiovila/max-xl`.

## Build and install

```sh
cd packaging/arch
makepkg -si
```

This pulls `master`, builds with meson (using the system Lua 5.4) and installs:

| Path | Contents |
| --- | --- |
| `/usr/bin/max-xl` | the editor |
| `/usr/share/max-xl/` | Lua core, plugins, fonts, colors |
| `/usr/share/doc/max-xl/` | docs and third-party notices |
| `/usr/share/applications/com.max_xl.MaxXL.desktop` | launcher entry |
| `/usr/share/metainfo/com.max_xl.MaxXL.metainfo.xml` | AppStream metadata |
| `/usr/share/icons/hicolor/scalable/apps/max-xl.svg` | icon |
| `/usr/share/licenses/max-xl-git/` | project LICENSE |

Runtime dependencies: `sdl3`, `freetype2`, `pcre2`, `lua54`.
Build dependencies: `git`, `meson`, `ninja`, `pkgconf` (plus `base-devel`).

## Pinned (non-git) package

There are no tagged releases yet. To package a specific commit instead, drop
the `-git` suffix and point `source` at a tarball, e.g.:

```sh
pkgname=max-xl
pkgver=2.1.7
_commit=1782e696fe833d58f1c6bb92a5088c9cb9490c36
source=("$pkgname-$pkgver.tar.gz::https://github.com/fabiovila/max-xl/archive/$_commit.tar.gz")
```

and drop the `pkgver()` function (remember to fill `sha256sums`).

## Building against a local checkout

To install the working tree (including uncommitted changes) without pushing,
run makepkg with the source overridden to your local clone:

```sh
cd packaging/arch
makepkg -si --noextract \
  --setenv GIT_DIR=/path/to/max-xl/.git
```

or simply build in-tree and install the resulting binary:

```sh
meson setup build --prefix=/usr --buildtype=plain -Duse_system_lua=true && meson compile -C build
sudo meson install -C build
```
