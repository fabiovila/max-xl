#!/bin/sh
# Install the Max XL "workspace" file association and template for the
# current user.
#
# After running this:
#   1. right-click a folder in your file manager;
#   2. choose "New Document" -> "Max XL Workspace";
#   3. double-click the created *.maxxl file.
#
# Max XL opens with that folder as the current project (its files are shown
# in the filetree).
set -eu

src_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
templates="${XDG_TEMPLATES_DIR:-$(xdg-user-dir TEMPLATES 2>/dev/null || echo "$HOME/Templates")}"

install -d "$data_home/mime/packages" "$data_home/applications" "$templates"

install -m 644 "$src_dir/resources/linux/com.max_xl.MaxXL.workspace.xml" \
  "$data_home/mime/packages/com.max_xl.MaxXL.workspace.xml"
install -m 644 "$src_dir/resources/linux/com.max_xl.MaxXL.workspace.desktop" \
  "$data_home/applications/com.max_xl.MaxXL.workspace.desktop"
install -m 644 "$src_dir/resources/linux/workspace.maxxl" \
  "$templates/Max XL Workspace.maxxl"

update-mime-database "$data_home/mime" 2>/dev/null || true
update-desktop-database "$data_home/applications" 2>/dev/null || true
xdg-mime default com.max_xl.MaxXL.workspace.desktop \
  application/x-max-xl-workspace 2>/dev/null || true

echo "Installed the Max XL workspace handler and template:"
echo "  handler:   $data_home/applications/com.max_xl.MaxXL.workspace.desktop"
echo "  MIME type: application/x-max-xl-workspace (*.maxxl)"
echo "  template:  $templates/Max XL Workspace.maxxl"
echo
echo 'Right-click a folder -> "New Document" -> "Max XL Workspace".'
