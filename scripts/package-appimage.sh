#!/usr/bin/env bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Max XL."
  exit 1
fi

source scripts/common.sh

ARCH="$(uname -m)"
BUILD_DIR="$(get_default_build_dir)"
ADDONS=false

show_help(){
  echo
  echo "Usage: $0 <OPTIONS>"
  echo
  echo "Available options:"
  echo
  echo "-h --help                 Show this help and exits."
  echo "-b --builddir DIRNAME     Sets the name of the build dir (no path)."
  echo "                          Default: '${BUILD_DIR}'."
  echo "   --debug                Debug this script."
  echo "-n --nobuild              Skips the build step, use existing files."
  echo "-v --version VERSION      Specify a version, non whitespace separated string."
  echo
}

for i in "$@"; do
  case $i in
    -h|--help)
      show_help
      exit 0
      ;;
    -b|--builddir)
      BUILD_DIR="$2"
      shift
      shift
      ;;
    --debug)
      set -x
      shift
      ;;
    -v|--version)
      VERSION="$2"
      shift
      shift
      ;;
    *)
      # unknown option
      ;;
  esac
done

setup_appimagetool() {
  if [ ! -e appimagetool ]; then
    if ! wget -O appimagetool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage" ; then
      echo "Could not download the appimagetool for the arch '${ARCH}'."
      exit 1
    else
      chmod 0755 appimagetool
    fi
  fi
}

generate_appimage() {
  [[ ! -e $BUILD_DIR ]] && scripts/build.sh $@

  if [ -e MaxXL.AppDir ]; then
    rm -rf MaxXL.AppDir
  fi

  echo "Creating MaxXL.AppDir..."

  DESTDIR="$(realpath MaxXL.AppDir)" meson install -C ${BUILD_DIR}

  cp resources/icons/max-xl.svg MaxXL.AppDir/
  cp resources/linux/com.max_xl.MaxXL.desktop MaxXL.AppDir/

  # work around the AppImage layout: keep the binary out of usr/share
  mkdir -p ./MaxXL.AppDir/usr/share/../bin
  mv ./MaxXL.AppDir/max-xl ./MaxXL.AppDir/usr/bin
  mv ./MaxXL.AppDir/data ./MaxXL.AppDir/usr/share/max-xl
  rm -rf ./MaxXL.AppDir/lib64 ./MaxXL.AppDir/include

  echo "Creating AppRun..."
	cat >> MaxXL.AppDir/AppRun <<- 'EOF'
	#!/bin/sh
	CURRENTDIR="$(dirname "$(readlink -f "$0")")"
	exec "$CURRENTDIR/usr/bin/max-xl" "$@"
	EOF
  chmod +x MaxXL.AppDir/AppRun

  echo "Generating AppImage..."
  local version=""
  if [ -n "$VERSION" ]; then
    version="-$VERSION"
  fi

  APPIMAGE_EXTRACT_AND_RUN=1 ./appimagetool MaxXL.AppDir MaxXL${version}-${ARCH}-linux.AppImage
  rm -rf MaxXL.AppDir
}

setup_appimagetool
generate_appimage
