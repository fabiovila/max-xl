# Max XL

A lightweight text editor written in Lua, forked from [Lite XL], with a
Visual Studio Code-style workflow: an activity bar, sidebar panels (search,
Git, problems, file explorer) and an embedded interactive terminal.

## Fork and acknowledgements

Max XL is a **fork of [Lite XL]**, which in turn derives from [lite] by rxi.
This project would not exist without the work of the Lite XL team and its
contributors, and the rxi/lite authors before them. Many thanks to all of them.

The upstream copyright notices and the MIT license are preserved — see
[LICENSE]. The fork-specific code is released under the same MIT license.

- Upstream project: <https://github.com/lite-xl/lite-xl>
- Original editor: <https://github.com/rxi/lite>

## Features

Max XL keeps the fast, small and hackable core of Lite XL and adds a
VS Code-style workflow:

- **Activity bar** with buttons for the explorer, search, source control and
  problems views.
- **Search panel** (project-wide find & replace).
- **Git panel** (status, stage, commit) backed by the system `git`.
- **Problems panel** (`Ctrl+Shift+M`).
- **Integrated console** (`Ctrl+Alt+T`).
- **Custom action buttons** in the status bar, configured from `actions.lua`
  (user-wide or per project); clicking one runs a shell command and streams its
  output into the console — handy for `make` targets.
- **Embedded interactive terminal** in a bottom split, running your real shell
  (`fish`, `bash`, …) through a built-in PTY.
- **Tab context menu**: close (left / right / others / all), duplicate to the
  right or below, move, save, copy path / relative path and reveal.
- Empty panes are pruned automatically, and the layout can be reset from the
  command palette.

The editor also inherits Lite XL's features: multi-cursor editing, a command
palette, a project-aware file tree, configurable fonts (including grayscale
antialiasing), and the Lua plugin/theme ecosystem.

## Customization

Additional functionality can be added through plugins and color themes. Max XL
is compatible with the Lite XL ecosystem:

- Plugins: <https://github.com/lite-xl/lite-xl-plugins>
- Color themes: <https://github.com/lite-xl/lite-xl-colors>

Plugins can also be bundled locally in `data/plugins/`.

User configuration lives in `~/.config/max-xl/` (or `$LITE_USERDIR`), and
per-project configuration can be placed in a `.max-xl/init.lua` file inside the
project directory.

### Action buttons

The status bar can show buttons that run commands for you. Define them in a
Lua file at either location (project entries are merged over the user ones):

- `~/.config/max-xl/actions.lua` — user-wide.
- `<project>/.max-xl/actions.lua` — per project.

```lua
-- ~/.config/max-xl/actions.lua
return {
  { label = "build", command = "make -j$(nproc)" },
  { label = "run",   command = "make run", tooltip = "run the app" },
  { label = "test",  command = "make test" },
  { label = "clean", command = "make clean", align = "right" },
}
```

Clicking a button runs the command in the project directory and streams its
stdout, stderr and exit status into the console. Reload the buttons with
`Ctrl+Alt+A` (or the `actions:reload` command). A `command` can also be a Lua
function, and each button accepts `name`, `tooltip`, `cwd` and `align`.

### Workspace files

A `*.maxxl` file marks its directory as a Max XL workspace. Opening it (double
click) launches Max XL with that directory as the current project, so its files
show up in the filetree — handy for turning any folder into a workspace without
a terminal.

`scripts/install-workspace.sh` registers the file association and drops a
"Max XL Workspace" template into your templates folder (localized, e.g.
`~/Modelos`). Then right-click a folder in your file manager, pick
**New Document → Max XL Workspace**, and open the created file.

## Quick Build Guide

To compile Max XL yourself, you must have the following dependencies installed
via your desired package manager, or manually.

### Prerequisites

- Meson (>=0.63)
- Ninja
- SDL2
- PCRE2
- FreeType2
- Lua 5.4
- A working C compiler (GCC / Clang / MSVC)

SDL2, PCRE2, FreeType2 and Lua will be downloaded by Meson
if `--wrap-mode=forcefallback` or `--wrap-mode=default` is specified.

On Linux, you may install the following dependencies for the SDL2 X11 and/or
Wayland backend to work properly:

- `libX11-devel`
- `libXi-devel`
- `libXcursor-devel`
- `libxkbcommon-devel`
- `libXrandr-devel`
- `wayland-devel`
- `wayland-protocols-devel`
- `dbus-devel`
- `ibus-devel`

The following command can be used to install the dependencies in Ubuntu:

```sh
apt-get install python3.8 python3-pip build-essential git cmake wayland-protocols libsdl2-dev
pip3 install meson ninja
```

On macOS, you must install bash via Brew, as the default bash version on macOS
is antiquated and may not run the build script correctly.

### Building

You can use `scripts/build.sh` to set up Max XL and build it.

```sh
$ bash build.sh --help
# Usage: scripts/build.sh <OPTIONS>
#
# Available options:
#
# -b --builddir DIRNAME         Sets the name of the build directory (not path).
#                               Default: 'build-x86_64-linux'.
#    --debug                    Debug this script.
# -f --forcefallback            Force to build dependencies statically.
# -h --help                     Show this help and exit.
# -d --debug-build              Builds a debug build.
# -p --prefix PREFIX            Install directory prefix. Default: '/'.
# -B --bundle                   Create an App bundle (macOS only)
# -A --addons                   Add in addons
# -P --portable                 Create a portable binary package.
# -r --reconfigure              Tries to reuse the meson build directory, if possible.
#                               Default: Deletes the build directory and recreates it.
# -O --pgo                      Use profile guided optimizations (pgo).
#                               macOS: disabled when used with --bundle,
#                               Windows: Implicit being the only option.
#    --cross-platform PLATFORM  Cross compile for this platform.
#                               The script will find the appropriate
#                               cross file in 'resources/cross'.
#    --cross-arch ARCH          Cross compile for this architecture.
#                               The script will find the appropriate
#                               cross file in 'resources/cross'.
#    --cross-file CROSS_FILE    Cross compile with the given cross file.
```

Alternatively, you can use the following commands to customize the build:

```sh
meson setup --buildtype=release --prefix <prefix> build
meson compile -C build
DESTDIR="$(pwd)/max-xl" meson install --skip-subprojects -C build
```

where `<prefix>` might be one of `/`, `/usr` or `/opt`, the default is `/`.
To build a bundle application on macOS:

```sh
meson setup --buildtype=release --Dbundle=true --prefix / build
meson compile -C build
DESTDIR="$(pwd)/Max XL.app" meson install --skip-subprojects -C build
```

Please note that the package is relocatable to any prefix and the option prefix
affects only the place where the application is actually installed.

## Installing Prebuilt

Head over to [releases](https://github.com/fabiovila/max-xl/releases) and download
the version for your operating system.

### Windows

Max XL comes with installers on Windows for typical installations.
Alternatively, we provide ZIP archives that you can download and extract
anywhere and run directly.

To make Max XL portable (e.g. running Max XL from a thumb drive),
simply create a `user` folder where `max-xl.exe` is located.
Max XL will load and store all your configurations and plugins in the folder.

### macOS

We provide DMG files for macOS. Simply drag the program into your Applications
folder.

> **Important**
> Newer versions may be signed with a self-signed certificate, so you'll have to
> follow these steps when running Max XL for the first time:
>
> 1. Find Max XL in Finder (do not open it in Launchpad).
> 2. Control-click Max XL, then choose `Open` from the shortcut menu.
> 3. Click `Open` in the popup menu.
>
> If macOS reports the application as damaged, clear the quarantine attributes:
>
> ```sh
> xattr -cr /Applications/Max\ XL.app
> ```

### Linux

Unzip the file and `cd` into the `max-xl` directory:

```sh
tar -xzf <file>
cd max-xl
```

To run max-xl without installing:

```sh
./max-xl
```

To install max-xl copy files over into appropriate directories:

```sh
rm -rf  $HOME/.local/share/max-xl $HOME/.local/bin/max-xl
mkdir -p $HOME/.local/bin && cp max-xl $HOME/.local/bin/
mkdir -p $HOME/.local/share/max-xl && cp -r data/* $HOME/.local/share/max-xl/
```

#### Add Max XL to PATH

To run Max XL from the command line, you must add it to PATH.
If `$HOME/.local/bin` is not in PATH:

```sh
echo -e 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
```

Alternatively on recent versions of GNOME and KDE Plasma, you can add
`$HOME/.local/bin` to PATH via `~/.config/environment.d/envvars.conf`:

```ini
PATH=$HOME/.local/bin:$PATH
```

#### Add Max XL to application launchers

To get the icon to show up in the app launcher, create a desktop entry in
`~/.local/share/applications/com.max_xl.MaxXL.desktop`, assuming Max XL is in
PATH:

```ini
[Desktop Entry]
Type=Application
Name=Max XL
Comment=A lightweight text editor written in Lua
Exec=max-xl %F
Icon=max-xl
Terminal=false
StartupWMClass=com.max_xl.MaxXL
Categories=Development;IDE;
MimeType=text/plain;inode/directory;
```

To get the icon to show up in the app launcher immediately, run:

```sh
xdg-desktop-menu forceupdate
```

#### Uninstall

To uninstall Max XL, run:

```sh
rm -f $HOME/.local/bin/max-xl
rm -rf $HOME/.local/share/icons/hicolor/scalable/apps/max-xl.svg \
          $HOME/.local/share/applications/com.max_xl.MaxXL.desktop \
          $HOME/.local/share/metainfo/com.max_xl.MaxXL.metainfo.xml \
          $HOME/.local/share/max-xl
```

## Contributing

Pull requests and issues are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for details. Remember that Max XL is a fork of Lite XL, so improvements often
make sense upstream too.

## Licenses

This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license. See [LICENSE] for details.

Max XL is a fork of [Lite XL]; the original copyright notices are preserved.

See the [licenses] file for details on licenses used by the required
dependencies.


[Lite XL]:        https://github.com/lite-xl/lite-xl
[lite]:           https://github.com/rxi/lite
[LICENSE]:        LICENSE
[licenses]:       licenses/licenses.md
