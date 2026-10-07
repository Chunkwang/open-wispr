#!/bin/bash
set -euo pipefail

BINARY="${1:-.build/release/open-wispr}"
APP_DIR="${2:-Dictation-WIP.app}"
VERSION="${3:-0.3.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BINARY" "$APP_DIR/Contents/MacOS/open-wispr"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Task: embed Sparkle.framework. open-wispr links @rpath/Sparkle.framework/...
# (see `import Sparkle` in UpdaterController.swift + Package.swift dependency)
# but nothing was copying the framework into the bundle, so the binary would
# fail to launch at all once Sparkle is wired in:
#   dyld: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
# SwiftPM resolves Sparkle as a prebuilt binary xcframework; find the slice
# for this platform rather than assuming a fixed path (checkout dir name and
# xcframework internals can change between Sparkle releases).
SPARKLE_FRAMEWORK="$(find "$REPO_DIR/.build" -type d -path '*Sparkle.xcframework/*/Sparkle.framework' -print -quit 2>/dev/null || true)"

if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "✗ Error: Sparkle.framework not found under $REPO_DIR/.build" >&2
    echo "  Run 'swift build' (or 'swift build -c release') first so SwiftPM" >&2
    echo "  resolves the Sparkle.xcframework binary dependency." >&2
    exit 1
fi

# Use ditto, not cp -R: it preserves the framework's own code signature,
# resource forks and the Versions/Current symlink structure exactly.
# Sparkle ships each nested component (the framework itself, Autoupdate,
# Updater.app, and the Downloader/Installer XPC services under XPCServices/)
# already signed with the hardened runtime as its own independent code
# object — verified with `codesign -dvvv` on each. Do NOT re-sign or --deep
# sign over these; that would strip valid nested signatures. Only the outer
# .app gets signed below, non-deep, per release-engineer convention.
ditto "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
echo "✓ Embedded Sparkle.framework from $SPARKLE_FRAMEWORK"

# The binary's rpath list (@loader_path, /usr/lib/swift, the toolchain path)
# does not include the standard app-bundle location for embedded frameworks.
# @loader_path for Contents/MacOS/open-wispr resolves to Contents/MacOS, not
# Contents/Frameworks, so @rpath/Sparkle.framework/... would still fail to
# resolve without this.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/open-wispr"
cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# MIT requires the licence and notices to travel with binary distributions.
cp "$REPO_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cp "$REPO_DIR/NOTICE" "$APP_DIR/Contents/Resources/NOTICE"

# Task 8.2 & 8.3: Bundle whisper-cli and default ggml model into the app bundle
mkdir -p "$APP_DIR/Contents/Resources/whisper"
mkdir -p "$APP_DIR/Contents/Resources/models"

# Copy whisper-cli binary if available
WHISPER_SRC=""
if [ -f "/opt/homebrew/bin/whisper-cli" ]; then
    WHISPER_SRC="/opt/homebrew/bin/whisper-cli"
elif command -v whisper-cli &>/dev/null; then
    WHISPER_SRC="$(which whisper-cli)"
fi

if [ -n "$WHISPER_SRC" ]; then
    # Preflight: fail the bundle build (not just at runtime) if the whisper-cli
    # being bundled doesn't support a flag Transcriber.swift passes unconditionally.
    # Transcriber currently treats an unknown-flag run as a SILENT SUCCESS (whisper-cli
    # exits 0 with empty stdout on "error: unknown argument" — verified against the
    # installed whisper.cpp 1.9.4), so a stale Homebrew whisper-cpp would ship a build
    # that produces empty transcriptions with no error surfaced anywhere.
    # Stopgap until Task 8.2 builds whisper.cpp from a pinned source revision instead
    # of copying whatever's on PATH.
    REQUIRED_WHISPER_FLAGS=("--suppress-nst")
    WHISPER_HELP="$("$WHISPER_SRC" --help 2>&1 || true)"
    for flag in "${REQUIRED_WHISPER_FLAGS[@]}"; do
        if ! grep -qF -- "$flag" <<< "$WHISPER_HELP"; then
            echo "✗ Error: bundled whisper-cli ($WHISPER_SRC) does not support required flag $flag" >&2
            echo "  Transcriber.swift passes this flag unconditionally; an older whisper-cpp" >&2
            echo "  will silently produce empty transcriptions (see Transcriber.arguments())." >&2
            echo "  Upgrade whisper-cpp (brew upgrade whisper-cpp) before bundling." >&2
            exit 1
        fi
    done
    echo "✓ whisper-cli supports required flags: ${REQUIRED_WHISPER_FLAGS[*]}"

    cp "$WHISPER_SRC" "$APP_DIR/Contents/Resources/whisper/whisper-cli"
    chmod +x "$APP_DIR/Contents/Resources/whisper/whisper-cli"

    # Task 8.2 follow-up (found by two independent reviewers): whisper-cli as
    # shipped by Homebrew is dynamically linked against libwhisper/ggml/libomp
    # under /opt/homebrew/..., e.g.:
    #   @rpath/libwhisper.1.dylib
    #   /opt/homebrew/opt/ggml/lib/libggml.0.dylib
    #   /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib
    # None of that was embedded, so on a Mac without Homebrew's whisper-cpp/ggml
    # installed, the bundled whisper-cli would fail to dyld-load at runtime --
    # the entire free-tier v1 promise. Fix: walk the FULL transitive dependency
    # closure (don't trust any fixed list -- Homebrew bumps these versions, and
    # verification on this machine found a 4th dependency, libomp.dylib, that
    # isn't referenced directly by whisper-cli at all, only by libggml-base),
    # embed each real dylib into Contents/Frameworks (same directory Sparkle.framework
    # already uses above), then install_name_tool -change every reference --
    # in whisper-cli AND in the embedded dylibs' own internal references to each
    # other -- to point inside the bundle instead of at Homebrew.
    WHISPER_FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
    WHISPER_BIN="$APP_DIR/Contents/Resources/whisper/whisper-cli"

    # $1 = dependency reference exactly as otool -L prints it; $2 = directory
    # containing the binary that referenced it. Prints the resolved, symlink-free
    # real path, or nothing if it can't be resolved.
    resolve_whisper_dep_ref() {
        local ref="$1" loader_dir="$2" resolved=""
        case "$ref" in
            @rpath/*)
                # Every whisper.cpp/ggml dylib here carries the same LC_RPATH
                # (@loader_path/../lib) -- resolve @rpath against that.
                resolved="$loader_dir/../lib/${ref#@rpath/}" ;;
            @loader_path/*)
                resolved="$loader_dir/${ref#@loader_path/}" ;;
            @executable_path/*)
                resolved="$loader_dir/${ref#@executable_path/}" ;;
            /*)
                resolved="$ref" ;;
            *)
                resolved="" ;;
        esac
        [ -n "$resolved" ] && realpath "$resolved" 2>/dev/null
    }

    # Walk the closure breadth-first starting from whisper-cli itself.
    WHISPER_REAL="$(realpath "$WHISPER_SRC")"
    whisper_to_scan=("$WHISPER_REAL")
    whisper_closure_paths=()
    whisper_closure_names=()

    while [ "${#whisper_to_scan[@]}" -gt 0 ]; do
        cur="${whisper_to_scan[0]}"
        whisper_to_scan=("${whisper_to_scan[@]:1}")
        cur_dir="$(dirname "$cur")"
        # A dylib's otool -L repeats its own install name as the first entry
        # (LC_ID_DYLIB) -- skip that; an executable has no such line.
        self_id="$(otool -D "$cur" 2>/dev/null | sed -n '2p' | awk '{print $1}')"
        while IFS= read -r ref; do
            [ -z "$ref" ] && continue
            [ "$ref" = "$self_id" ] && continue
            case "$ref" in
                /usr/lib/*|/System/*) continue ;;
            esac
            real="$(resolve_whisper_dep_ref "$ref" "$cur_dir")"
            if [ -z "$real" ] || [ ! -f "$real" ]; then
                echo "✗ Error: whisper-cli dependency '$ref' (referenced by $cur) did not resolve to a real file" >&2
                exit 1
            fi
            already=0
            for p in ${whisper_closure_paths[@]+"${whisper_closure_paths[@]}"}; do
                [ "$p" = "$real" ] && already=1 && break
            done
            if [ "$already" -eq 0 ]; then
                whisper_closure_paths+=("$real")
                whisper_closure_names+=("$(basename "$(otool -D "$real" | sed -n '2p' | awk '{print $1}')")")
                whisper_to_scan+=("$real")
            fi
        done < <(otool -L "$cur" | tail -n +2 | awk '{print $1}')
    done

    echo "  Resolved whisper-cli dependency closure: ${whisper_closure_names[*]}"

    # Embed each real dylib into Contents/Frameworks under its stable
    # (SOVERSION) name, not the fully-versioned Cellar filename.
    for i in "${!whisper_closure_paths[@]}"; do
        cp "${whisper_closure_paths[$i]}" "$WHISPER_FRAMEWORKS_DIR/${whisper_closure_names[$i]}"
        chmod +w "$WHISPER_FRAMEWORKS_DIR/${whisper_closure_names[$i]}"
    done

    # Rewrite dependency references in a copied file: for each non-system
    # dependency the ORIGINAL (pre-copy) file had, find which embedded name it
    # resolves to and repoint the COPY at it with $new_prefix.
    rewrite_whisper_deps() {
        # NOTE: every local here (including the inner loop index) must be
        # declared `local` -- this function is called from inside a `for i in
        # ...` loop over whisper_closure_paths, and a bare (non-local) `i`,
        # `real`, `target` or `self_id` would silently clobber the caller's
        # loop variable once this function returns. (Caught in testing: it
        # made install_name_tool -id below run on the wrong index -- libwhisper
        # ended up with libggml-base's name as its own self-ID.)
        local orig="$1" copied="$2" new_prefix="$3" orig_dir self_id ref real target j
        orig_dir="$(dirname "$orig")"
        self_id="$(otool -D "$orig" 2>/dev/null | sed -n '2p' | awk '{print $1}')"
        while IFS= read -r ref; do
            [ -z "$ref" ] && continue
            [ "$ref" = "$self_id" ] && continue
            case "$ref" in
                /usr/lib/*|/System/*) continue ;;
            esac
            real="$(resolve_whisper_dep_ref "$ref" "$orig_dir")"
            target=""
            for j in "${!whisper_closure_paths[@]}"; do
                if [ "${whisper_closure_paths[$j]}" = "$real" ]; then
                    target="${whisper_closure_names[$j]}"
                    break
                fi
            done
            if [ -z "$target" ]; then
                echo "✗ Error: dependency '$ref' of $orig is not in the embedded whisper closure" >&2
                exit 1
            fi
            install_name_tool -change "$ref" "$new_prefix/$target" "$copied"
        done < <(otool -L "$orig" | tail -n +2 | awk '{print $1}')
    }

    # whisper-cli lives at Contents/Resources/whisper/whisper-cli. When the app
    # runs it as a subprocess, @executable_path resolves to whisper-cli's own
    # directory (it becomes the main executable of that process) -- two levels
    # up from there is Contents, then into Frameworks.
    rewrite_whisper_deps "$WHISPER_REAL" "$WHISPER_BIN" "@executable_path/../../Frameworks"
    install_name_tool -delete_rpath "@loader_path/../lib" "$WHISPER_BIN" 2>/dev/null || true

    # The embedded dylibs reference each other too (e.g. libwhisper -> libggml,
    # libggml -> libggml-base, libggml-base -> libomp) -- rewrite those as well,
    # using @loader_path since they're all siblings in the same Frameworks dir.
    for i in "${!whisper_closure_paths[@]}"; do
        copied="$WHISPER_FRAMEWORKS_DIR/${whisper_closure_names[$i]}"
        rewrite_whisper_deps "${whisper_closure_paths[$i]}" "$copied" "@loader_path"
        install_name_tool -delete_rpath "@loader_path/../lib" "$copied" 2>/dev/null || true
        install_name_tool -id "@loader_path/${whisper_closure_names[$i]}" "$copied"
    done

    # install_name_tool invalidates whatever signature Homebrew's build put on
    # these (ad-hoc) -- re-sign each one before the outer app gets signed,
    # inside-out, same convention as the rest of this script.
    #
    # Hardened runtime (--options runtime) is deliberately NOT applied under
    # ad-hoc signing (SIGN_IDENTITY="-", the default until Day 17 -- no
    # Developer ID yet per the schedule). Verified by testing: with hardened
    # runtime forced on, each ad-hoc-signed file gets its own anonymous
    # identity with no Team ID, and dyld's Library Validation then refuses to
    # load the embedded dylibs into whisper-cli at all ("different Team IDs"),
    # which would make it impossible to test actual execution before a real
    # signing identity exists. Same convention as scripts/create-dmg.sh (extra
    # signing options only kick in for a real identity).
    WHISPER_SIGN_EXTRA_ARGS=()
    if [ "$SIGN_IDENTITY" != "-" ]; then
        WHISPER_SIGN_EXTRA_ARGS+=(--options runtime --timestamp)
    fi
    for i in "${!whisper_closure_paths[@]}"; do
        copied="$WHISPER_FRAMEWORKS_DIR/${whisper_closure_names[$i]}"
        codesign --force --sign "$SIGN_IDENTITY" ${WHISPER_SIGN_EXTRA_ARGS[@]+"${WHISPER_SIGN_EXTRA_ARGS[@]}"} "$copied"
        codesign --verify --strict "$copied"
    done
    codesign --force --sign "$SIGN_IDENTITY" ${WHISPER_SIGN_EXTRA_ARGS[@]+"${WHISPER_SIGN_EXTRA_ARGS[@]}"} "$WHISPER_BIN"
    codesign --verify --strict "$WHISPER_BIN"
    echo "✓ Embedded and re-signed whisper-cli's dylib closure: ${whisper_closure_names[*]}"

    # Deeper problem, found only by actually EXECUTING the bundled whisper-cli
    # with /opt/homebrew sandboxed away (otool -L alone did not catch this):
    # this ggml build does not statically link a compute backend into
    # libggml-base at all. CPU/BLAS/Metal are separate Mach-O *bundles*
    # (MH_BUNDLE, not MH_DYLIB -- no LC_ID_DYLIB, otool -L on whisper-cli never
    # lists them) that libggml.0.dylib dlopen()s at runtime from a directory
    # read from getenv("GGML_BACKEND_PATH"), falling back to a path baked in
    # at Homebrew's build time (verified via `strings`: both the env var name
    # and the literal fallback "/opt/homebrew/Cellar/ggml/<ver>/libexec" are
    # in libggml.0.dylib). With neither reachable, whisper_init_from_file
    # crashes with `GGML_ASSERT(device) failed` -- no backend, not even CPU --
    # confirmed by running the embedded whisper-cli against the bundled model
    # with /opt/homebrew denied via a sandbox-exec profile (see report).
    # Embed every backend plugin next to the core libs; GGML_BACKEND_PATH still
    # has to be set by whoever launches whisper-cli (see note below) because
    # only the launching process knows the app's own install location at
    # runtime -- a path baked into the dylib at bundle-build time would break
    # the moment a user moved the .app.
    ggml_base_idx=""
    for i in "${!whisper_closure_names[@]}"; do
        if [ "${whisper_closure_names[$i]}" = "libggml-base.0.dylib" ]; then
            ggml_base_idx="$i"
            break
        fi
    done
    whisper_backend_copied=()
    if [ -n "$ggml_base_idx" ]; then
        GGML_LIB_DIR="$(dirname "${whisper_closure_paths[$ggml_base_idx]}")"
        GGML_LIBEXEC_DIR="$(realpath "$GGML_LIB_DIR/../libexec" 2>/dev/null || true)"
        if [ -n "$GGML_LIBEXEC_DIR" ] && [ -d "$GGML_LIBEXEC_DIR" ]; then
            WHISPER_BACKENDS_DIR="$WHISPER_FRAMEWORKS_DIR/ggml-backends"
            mkdir -p "$WHISPER_BACKENDS_DIR"
            for plugin in "$GGML_LIBEXEC_DIR"/*.so; do
                [ -f "$plugin" ] || continue
                pname="$(basename "$plugin")"
                copied="$WHISPER_BACKENDS_DIR/$pname"
                cp "$plugin" "$copied"
                chmod +w "$copied"
                # Plugin lives one directory deeper than the core libs
                # (Contents/Frameworks/ggml-backends vs Contents/Frameworks),
                # so its references to them are @loader_path/.. not @loader_path.
                rewrite_whisper_deps "$plugin" "$copied" "@loader_path/.."
                install_name_tool -delete_rpath "@loader_path/../lib" "$copied" 2>/dev/null || true
                codesign --force --sign "$SIGN_IDENTITY" ${WHISPER_SIGN_EXTRA_ARGS[@]+"${WHISPER_SIGN_EXTRA_ARGS[@]}"} "$copied"
                codesign --verify --strict "$copied"
                whisper_backend_copied+=("$copied")
            done
            if [ "${#whisper_backend_copied[@]}" -eq 0 ]; then
                echo "✗ Error: no ggml backend plugins (*.so) found in $GGML_LIBEXEC_DIR -- bundled" >&2
                echo "  whisper-cli would have no compute backend and crash on launch" >&2
                echo "  (GGML_ASSERT(device) failed). Do not ship this build." >&2
                exit 1
            fi
            echo "✓ Embedded ${#whisper_backend_copied[@]} ggml backend plugin(s) into $WHISPER_BACKENDS_DIR"
            echo "  >>> ACTION NEEDED (app side, not this script): confirmed by actually running" >&2
            echo "      the bundled whisper-cli with /opt/homebrew sandboxed away --" >&2
            echo "      GGML_BACKEND_PATH must be set to a SPECIFIC backend FILE, not this" >&2
            echo "      directory (ggml's loader dlopen()s the env var's value directly; it does" >&2
            echo "      not scan it for candidates the way it scans its own baked-in libexec" >&2
            echo "      default). Whoever spawns whisper-cli (Transcriber.swift) must set:" >&2
            echo "        GGML_BACKEND_PATH = <app bundle>/Contents/Frameworks/ggml-backends/libggml-cpu-apple_m1.so" >&2
            echo "      computed from Bundle.main at launch time, on the Process/NSTask" >&2
            echo "      environment. Verified: the apple_m1 plugin runs correctly on a newer" >&2
            echo "      (M2) Mac too, so it's a safe single default -- no per-chip detection" >&2
            echo "      needed for correctness (speech-ml-engineer may want to pick a newer" >&2
            echo "      variant per-chip later purely for performance). Without this env var," >&2
            echo "      whisper-cli falls back to the Homebrew build path and crashes with no" >&2
            echo "      backend (GGML_ASSERT(device) failed) on a clean Mac." >&2
        else
            echo "! Warning: could not find ggml's backend-plugin (libexec) directory next to" >&2
            echo "  the embedded libggml-base.0.dylib. If this ggml version still dlopen()s" >&2
            echo "  compute backends at runtime (check: strings <libggml.0.dylib> | grep" >&2
            echo "  GGML_BACKEND_PATH), the bundled whisper-cli will crash with no backend on a" >&2
            echo "  clean Mac. Verify with an actual transcription test, not just otool -L." >&2
        fi
    fi

    # Enforcement, not just a one-time fix (Task 8.2 done-when): fail the
    # bundle build loudly if the COPIED whisper-cli, or any dylib it pulls in,
    # still resolves a dependency outside the bundle. This is what catches it
    # the next time someone runs `brew upgrade whisper-cpp` and the formula
    # grows a new dependency, instead of only catching it once here.
    FRAMEWORKS_DIR_REAL="$(realpath "$WHISPER_FRAMEWORKS_DIR")"

    verify_whisper_bundle_closure() {
        local f="$1" exe_dir="$2" bad=0
        while IFS= read -r ref; do
            [ -z "$ref" ] && continue
            case "$ref" in
                /usr/lib/*|/System/*) continue ;;
            esac
            local resolved=""
            case "$ref" in
                @executable_path/*) resolved="$exe_dir/${ref#@executable_path/}" ;;
                @loader_path/*)     resolved="$(dirname "$f")/${ref#@loader_path/}" ;;
                *)                  resolved="$ref" ;;
            esac
            resolved="$(realpath "$resolved" 2>/dev/null || echo "$resolved")"
            case "$resolved" in
                "$FRAMEWORKS_DIR_REAL"/*) : ;;
                *)
                    echo "✗ Error: $f depends on '$ref' (resolves to '$resolved'), outside $WHISPER_FRAMEWORKS_DIR" >&2
                    bad=1
                    ;;
            esac
        done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
        return "$bad"
    }

    whisper_bundle_ok=1
    verify_whisper_bundle_closure "$WHISPER_BIN" "$(dirname "$WHISPER_BIN")" || whisper_bundle_ok=0
    for i in "${!whisper_closure_paths[@]}"; do
        verify_whisper_bundle_closure "$WHISPER_FRAMEWORKS_DIR/${whisper_closure_names[$i]}" "" || whisper_bundle_ok=0
    done
    for copied in ${whisper_backend_copied[@]+"${whisper_backend_copied[@]}"}; do
        verify_whisper_bundle_closure "$copied" "" || whisper_bundle_ok=0
    done
    if [ "$whisper_bundle_ok" -ne 1 ]; then
        echo "✗ Error: bundled whisper-cli (or one of its embedded dylibs) still references something outside the app bundle." >&2
        echo "  otool -L the files above to see what leaked in -- do not ship this build." >&2
        exit 1
    fi
    echo "✓ Verified: bundled whisper-cli and its embedded dylibs resolve only to system libraries or $WHISPER_FRAMEWORKS_DIR"
    echo "✓ Bundled whisper-cli binary"
fi

# Copy default model if available
MODEL_SRC="$HOME/.config/open-wispr/models/ggml-base.en.bin"
if [ -f "$MODEL_SRC" ]; then
    cp "$MODEL_SRC" "$APP_DIR/Contents/Resources/models/ggml-base.en.bin"
    echo "✓ Bundled default model ggml-base.en.bin"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>open-wispr</string>
    <key>CFBundleIdentifier</key>
    <string>com.murmur.app</string>
    <key>CFBundleName</key>
    <string>Dictation-WIP</string>
    <key>CFBundleDisplayName</key>
    <string>Dictation (WIP)</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Dictation needs microphone access to record speech for transcription.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" --identifier com.murmur.app "$APP_DIR"



echo "Built $APP_DIR"
