#! /usr/bin/env bash
# vim: set ts=3 sw=3 noet ft=sh : bash

# Miyoo Mini cross-build wrapper
# NOTES:
# - Target platform is ARMv7 32-bit without OpenGL/GLES support.
# - GL/GLES cores are explicitly disabled to avoid incompatible builds.

SCRIPT="${0#./}"
BASE_DIR="${SCRIPT%/*}"
WORKDIR="$PWD"

if [ "$BASE_DIR" = "$SCRIPT" ]; then
        BASE_DIR="$WORKDIR"
else
        if [[ "$0" != /* ]]; then
                # Make the path absolute
                BASE_DIR="$WORKDIR/$BASE_DIR"
        fi
fi

# Toolchain bootstrap (download if missing)
MIYOO_TOOLCHAIN_URL=${MIYOO_TOOLCHAIN_URL:-"https://github.com/Ninoh-FOX/toolchain_miyoo/releases/download/miyoomini/miyoomini-toolchain.tar.xz"}
MIYOO_TOOLCHAIN_DIR=/opt/miyoomini-toolchain

if [ ! -x "${MIYOO_TOOLCHAIN_DIR}/usr/bin/arm-linux-gnueabihf-gcc" ]; then
        echo "Descargando toolchain de Miyoo Mini desde ${MIYOO_TOOLCHAIN_URL}..." >&2
        tmp_pkg=$(mktemp -t miyoo-toolchain.XXXXXX.tar.xz)

        if ! curl -fL --retry 5 --retry-delay 5 --retry-connrefused "${MIYOO_TOOLCHAIN_URL}" -o "${tmp_pkg}"; then
                echo "No se pudo descargar el toolchain de Miyoo Mini." >&2
                rm -f "${tmp_pkg}"
                exit 1
        fi

        mkdir -p /opt
        if ! tar -xf "${tmp_pkg}" -C /opt; then
                echo "Fallo al descomprimir el toolchain de Miyoo Mini." >&2
                rm -f "${tmp_pkg}"
                exit 1
        fi

        rm -f "${tmp_pkg}"
fi

# Toolchain and platform setup
export SYSROOT=${MIYOO_TOOLCHAIN_DIR}/usr/arm-linux-gnueabihf/sysroot
export PATH="${MIYOO_TOOLCHAIN_DIR}/usr/bin:${PATH}:${SYSROOT}/bin"
export CROSS_COMPILE=${MIYOO_TOOLCHAIN_DIR}/usr/bin/arm-linux-gnueabihf-
export PREFIX=${SYSROOT}/usr
export CC="${CROSS_COMPILE}gcc"
export CXX="${CROSS_COMPILE}g++"
export AR="${CROSS_COMPILE}ar"
export RANLIB="${CROSS_COMPILE}ranlib"
export STRIP="${CROSS_COMPILE}strip"
export READELF="${CROSS_COMPILE}readelf"
export OBJDUMP="${CROSS_COMPILE}objdump"
export NM="${CROSS_COMPILE}nm"

# Generic ARMv7-A hard-float tuning to satisfy makefiles/CMake projects lacking a miyoomini target
ARMV7A_FLAGS="-march=armv7-a -mtune=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard"
export CFLAGS="${ARMV7A_FLAGS} -fPIC -fno-lto ${CFLAGS}"
export CXXFLAGS="${ARMV7A_FLAGS} -fPIC -fno-lto ${CXXFLAGS}"
export ASFLAGS="${ARMV7A_FLAGS} ${ASFLAGS}"
export LDFLAGS="${ARMV7A_FLAGS} -fno-lto ${LDFLAGS}"
export MAKEFLAGS="HAVE_DYNAREC=0 CPU_ARCH=arm USE_LTO=0 NO_LTO=1 LTO=0${MAKEFLAGS:+ ${MAKEFLAGS}}"

# Tell cmake-style build systems to cross-compile for ARMv7
export CMAKE_SYSTEM_NAME=Linux
export CMAKE_SYSTEM_PROCESSOR=armv7-a
export CMAKE_C_COMPILER="${CC}"
export CMAKE_CXX_COMPILER="${CXX}"
export CMAKE_FIND_ROOT_PATH="${SYSROOT}"
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"

# Use the most portable profile recognized by core makefiles without pulling
# device-specific tweaks: fall back to the plain unix target so builds rely on
# the Miyoo toolchain and generic ARMv7 flags instead of Broadcom/RPi extras.
MIYOO_PLATFORM=${MIYOO_PLATFORM:-unix}

# Allow disabling the platform hint if a core builds with a plain make
# (set MIYOO_NO_PLATFORM=1); otherwise default to the ARMv7 hard-float hint.
if [ "${MIYOO_NO_PLATFORM:-0}" != "1" ]; then
platform=$MIYOO_PLATFORM
PLATFORM=$MIYOO_PLATFORM
export platform PLATFORM
else
unset platform
unset PLATFORM
fi

export ARCH=${ARCH:-armv7l}
export DIST_DIR=${DIST_DIR:-miyoomini}

# Pre-configure libretro defaults before fetching/building
. "${BASE_DIR}/libretro-config.sh"

# Re-apply the platform hint only when not explicitly disabled.
if [ "${MIYOO_NO_PLATFORM:-0}" != "1" ]; then
platform=$MIYOO_PLATFORM
PLATFORM=$MIYOO_PLATFORM
export platform PLATFORM
fi

# Keep a consistent platform hint to avoid Makefiles assuming x86 while
# cross-compiling.
export FORMAT_COMPILER_TARGET=$MIYOO_PLATFORM
export FORMAT_COMPILER_TARGET_ALT=${FORMAT_COMPILER_TARGET_ALT:-$FORMAT_COMPILER_TARGET}
export libretro_gpsp_build_platform=$MIYOO_PLATFORM
export DIST_DIR=${DIST_DIR:-miyoomini}
export RARCH_DIR=${RARCH_DIR:-${BASE_DIR}/dist}
export RARCH_DIST_DIR=${RARCH_DIST_DIR:-${RARCH_DIR}/${DIST_DIR}}

# Disable OpenGL/GLES-only cores for this target and reassert distribution dir
export BUILD_LIBRETRO_GL=0
unset ENABLE_GLES
export DIST_DIR=${DIST_DIR:-miyoomini}

# Build a filtered list (core names only) excluding GL/GLES-only cores and known-unsupported cores
build_miyoo_fetch_list() {
        local platform=${PLATFORM}
        local filtered_core_list=""

	# Bootstrap the module registry just like libretro-fetch.sh
	. "${BASE_DIR}/script-modules/log.sh"
	. "${BASE_DIR}/script-modules/util.sh"
	. "${BASE_DIR}/script-modules/fetch-rules.sh"
	. "${BASE_DIR}/script-modules/module_base.sh"
	. "${BASE_DIR}/rules.d/core-rules.sh"
	. "${BASE_DIR}/rules.d/player-rules.sh"
	. "${BASE_DIR}/rules.d/devkit-rules.sh"
	. "${BASE_DIR}/rules.d/lutro-rules.sh"
	. "${BASE_DIR}/build-config.sh"

        for entry in $libretro_cores; do
                local core_name="${entry%%:*}"
                local core_build_opengl=""

		eval "core_build_opengl=\$libretro_${core_name}_build_opengl"

                # Skip cores that require OpenGL/GLES
                if [[ "$core_build_opengl" = "yes" ]]; then
                        continue
                fi

		# Skip explicitly unsupported cores
                case "$core_name" in
                        # Require GL/GLES or a 3D GPU
                        flycast|flycast2021|flycast_naomi|reicast| \
                                dolphin|dolphin2015|citra|citra2018|play| \
                                melonDS|melonds|melondsds| \
                                mupen64plus|mupen64plus-next|mupen64plus_next|parallel_n64|parallext| \
                                duckstation|duckstation-pgxp| \
                                pcsx2|pcsx1|pcsx_rearmed|mednafen_psx|mednafen_psx_hw|beetle_psx|beetle_psx_hw| \
                                swanstation|rustation| \
                                mednafen_saturn|yabause|yabasanshiro|kronos|beetle_supersystem| \
                                mednafen_supergrafx_hw|beetle_vb_hw|openlara|ppsspp|vita*| \
                                remotejoy|ffmpeg|gme| \
                        desmume|desmume2015)
                                continue
                                ;;
                        # _hw cores generally assume GL/GLES acceleration
                        *_hw)
                                continue
                                ;;
                        esac

                filtered_core_list+="${filtered_core_list:+ }${core_name}"
        done

        echo "$filtered_core_list"
}

# Fetch all libretro cores unless explicitly skipped, but avoid GL/GLES and unsupported ones
if [ -z "$SKIP_FETCH" ]; then
	if [ $# -gt 0 ]; then
		miyoo_core_list="$*"
	else
		miyoo_core_list="$(build_miyoo_fetch_list)"
	fi

	if [ -n "$miyoo_core_list" ]; then
		${BASE_DIR}/libretro-fetch.sh ${miyoo_core_list}
	fi
fi

# Ensure submodules are present for the cores we are about to build.
update_submodules_for_cores() {
	for core in "$@"; do
		local core_dir="${BASE_DIR}/libretro-${core}"
		if [ -d "${core_dir}" ] && [ -f "${core_dir}/.gitmodules" ]; then
			git -C "${core_dir}" submodule update --init --recursive
		fi
	done
}

# If no explicit core list is provided on the command line, default to the
# filtered Miyoo list; otherwise respect the user-supplied targets.
if [ $# -eq 0 ]; then
        miyoo_core_list="${miyoo_core_list:-$(build_miyoo_fetch_list)}"
        if [ -n "$miyoo_core_list" ]; then
                set -- $miyoo_core_list
        fi
fi

# Initialize submodules for the selected core list.
if [ $# -gt 0 ]; then
        update_submodules_for_cores "$@"
fi

build_core_with_platform() {
	local core="$1"
	local core_platform="$MIYOO_PLATFORM"

	local cmd=(
		env
		PLATFORM="$core_platform"
		platform="$core_platform"
		FORMAT_COMPILER_TARGET="$core_platform"
		FORMAT_COMPILER_TARGET_ALT="$core_platform"
		libretro_gpsp_build_platform="$core_platform"
		MAKEFLAGS="$MAKEFLAGS"
		HAVE_DYNAREC=0
		CPU_ARCH=arm
		USE_LTO=0
		NO_LTO=1
		LTO=0
	)

	cmd+=( "${BASE_DIR}/libretro-build.sh" "$core" )

	( "${cmd[@]}" )
}


status=0
declare -a build_ok build_failed

if [ $# -gt 0 ]; then
        for core in "$@"; do
                if build_core_with_platform "$core"; then
                        build_ok+=("$core")
                else
                        build_failed+=("$core")
                        status=1
                fi
        done
fi

echo "\nResumen de compilación (Miyoo Mini):"
if [ ${#build_ok[@]} -gt 0 ]; then
        printf '  Éxito: %s\n' "${build_ok[*]}"
else
        echo "  Éxito: ninguno"
fi

if [ ${#build_failed[@]} -gt 0 ]; then
        printf '  Fallo: %s\n' "${build_failed[*]}"
else
        echo "  Fallo: ninguno"
fi

exit $status
