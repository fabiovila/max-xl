# Contributing to Max XL

Thanks for your interest in Max XL!

Max XL is a **fork of [Lite XL](https://github.com/lite-xl/lite-xl)**, so a lot of
the editor behaviour, the Lua core and the plugin/theme ecosystem are shared with
upstream. When in doubt, changes that improve the editor generally also make sense
upstream — feel free to send them to Lite XL as well.

## Ways to help

- **Report bugs and request features** in the issue tracker of this fork
  (https://github.com/fabiovila/max-xl/issues). Please include your OS, how Max XL
  was built/installed and a short description of what you did to trigger the issue.
- **Fix bugs and implement features** via pull requests.
- **Write plugins and themes.** Most functionality should be added as a plugin
  rather than baked into the core editor.

## Plugins and themes

Max XL is compatible with the Lite XL plugin and color-theme ecosystem:

- Plugins: https://github.com/lite-xl/lite-xl-plugins
- Colors: https://github.com/lite-xl/lite-xl-colors

You can also keep plugins local to this fork by placing them in `data/plugins/`.

## Contributing code

Pull requests against `master` are welcome. Please try to:

- Keep changes focused and consistent with the surrounding code style.
- Follow the commit message conventions used in the repository.
- Add or update documentation when you change user-facing behaviour.

### Compiling the development version

Regular building instructions from [README.md](README.md#quick-build-guide) apply.
A convenient way to run a development build with its own configuration directory
(so it does not clash with your normal install) is:

```sh
meson setup --buildtype=release --prefix /max-xl-dev build-release
meson compile -C build-release

INSTALL_DIR=$HOME/.local
meson install --destdir "${INSTALL_DIR}" --skip-subprojects -C build-release

# Run the development build with a dedicated config directory
alias max-xl-dev="LITE_USERDIR=$HOME/.config/max-xl-dev ${INSTALL_DIR}/max-xl-dev/bin/max-xl"
```

## License

By contributing you agree that your contributions are licensed under the
[MIT license](LICENSE), the same license as this project.
