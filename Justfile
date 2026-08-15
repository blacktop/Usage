set shell := ["bash", "-euo", "pipefail", "-c"]

project := "Usage.xcodeproj"
scheme := "Usage"
destination := "platform=macOS,arch=arm64e"
derived := "build/DerivedData"

# Source roots for every formatter/linter invocation. OPC/ is a read-only reference
# clone and must never be traversed.
fmt_roots := "App AppTests Core/Sources Core/Tests"

default:
    @just --list

# Regenerate Usage.xcodeproj from project.yml
gen:
    xcodegen generate --spec project.yml

# Build Core using only the tracked Package.resolved
deps-check:
    swift build --package-path Core --only-use-versions-from-resolved-file

# Build the CLI and sign it with the same stable identity the app bundle uses.
#
# The CLI is a second Keychain asker with its own code identity, independent of Usage.app. SwiftPM
# signs ad-hoc, which mints a fresh cdhash on every rebuild — a new principal the item's ACL has
# never seen, so every rebuild re-prompts and leaves another dead grant behind. Signing it with the
# machine-local identity from Config/Local.xcconfig is what makes an approval survive a rebuild.
build-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f Config/Local.xcconfig ]; then
        echo "error: Config/Local.xcconfig is missing." >&2
        echo "  Without it the CLI is ad-hoc signed and re-prompts for Keychain access on" >&2
        echo "  every rebuild. Set DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY there." >&2
        exit 1
    fi
    identity=$(sed -n 's/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=[[:space:]]*//p' Config/Local.xcconfig | tail -1)
    if [ -z "${identity}" ] || [ "${identity}" = "-" ]; then
        echo "error: Config/Local.xcconfig sets no usable CODE_SIGN_IDENTITY (got '${identity}')" >&2
        exit 1
    fi
    swift build --package-path Core --only-use-versions-from-resolved-file
    bin="$(swift build --package-path Core --show-bin-path)/usage"
    codesign --force --sign "${identity}" --options runtime --timestamp=none "${bin}"
    echo "signed ${bin} as '${identity}'"

# Fail when a built binary is ad-hoc signed, which silently costs durable Keychain access.
check-signing:
    #!/usr/bin/env bash
    set -euo pipefail
    status=0
    for target in "build/DerivedData/Build/Products/Debug/Usage.app" "$(swift build --package-path Core --show-bin-path)/usage"; do
        if [ ! -e "${target}" ]; then
            echo "skip (not built): ${target}"
            continue
        fi
        if ! signature="$(codesign -dvvv "${target}" 2>&1)"; then
            echo "error: ${target} has no inspectable signature" >&2
            status=1
        elif grep -q '^Signature=adhoc' <<<"${signature}"; then
            echo "error: ${target} is ad-hoc signed; Keychain grants will not survive a rebuild" >&2
            status=1
        else
            echo "ok: ${target}"
        fi
    done
    exit "${status}"

# Debug build of the app
build: gen
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug \
        -destination '{{destination}}' -derivedDataPath {{derived}} ARCHS=arm64e -quiet build

# Core (SwiftPM) test suite
test-core:
    swift test --package-path Core --only-use-versions-from-resolved-file

# The app is the test host, and LSMultipleInstancesProhibited makes LaunchServices refuse to
# start it while a copy is already running, so any live instance is retired first. Deliberately
# not -quiet: the executed-test count has to stay visible, otherwise a suite that silently
# discovered zero tests would still report success.
#
# App (XCTest bundle running Swift Testing) suite
test-app: gen
    -pkill -x Usage
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug \
        -destination '{{destination}}' -derivedDataPath {{derived}} ARCHS=arm64e test

# Both test suites
test: test-core test-app

# Build and relaunch the Debug app bundle
run: build
    -pkill -x Usage
    open {{derived}}/Build/Products/Debug/Usage.app

# Format every source root in place
fmt:
    xcrun swift-format format --in-place --parallel --recursive {{fmt_roots}}

# Lint every source root, treating findings as errors.
#
# swift-format's lineLength is a pretty-printer setting, not a lint rule, and the formatter will
# not break a long interpolated string literal — so a 137-column line passes `lint --strict` and
# survives `format` unchanged. The explicit column check is what actually enforces the limit.
lint:
    xcrun swift-format lint --strict --parallel --recursive {{fmt_roots}}
    @just line-length

# Fail on any source line wider than the documented 100-column limit.
#
# Columns are counted in characters, not bytes: an em dash is one column and three bytes, and a
# byte-counting check would reject prose that is inside the limit.
line-length:
    #!/usr/bin/env python3
    import pathlib
    import sys

    over = []
    for root in "{{fmt_roots}}".split():
        for path in sorted(pathlib.Path(root).rglob("*.swift")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if len(line) > 100:
                    over.append(f"{path}:{number}: {len(line)} columns")
    if over:
        print("\n".join(over), file=sys.stderr)
        print("error: lines above the 100-column limit", file=sys.stderr)
        sys.exit(1)

# Release build into build/Usage.app
app: gen
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        -destination '{{destination}}' -derivedDataPath {{derived}} ARCHS=arm64e -quiet build
    if [ -d build/Usage.app ]; then trash build/Usage.app; fi
    ditto {{derived}}/Build/Products/Release/Usage.app build/Usage.app

# Verify the Icon Composer bundle and that the built app actually carries the icon rendition.
# Value-insensitive beyond asset name, dimensions, and alpha; the artwork itself is judged by a
# one-time visual inspection, which compilation cannot replace.
check-icon: build
    #!/usr/bin/env bash
    set -euo pipefail
    python3 -c 'import json; json.load(open("Resources/Usage.icon/icon.json"))'
    png="Resources/Usage.icon/Assets/logo.png"
    read -r width height alpha < <(sips -g pixelWidth -g pixelHeight -g hasAlpha "${png}" \
        | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} /hasAlpha/{a=$2} END{print w, h, a}')
    if [ "${width}" != "1024" ] || [ "${height}" != "1024" ] || [ "${alpha}" != "yes" ]; then
        echo "error: ${png} must be 1024x1024 with alpha (got ${width}x${height} alpha=${alpha})" >&2
        exit 1
    fi
    car="{{derived}}/Build/Products/Debug/Usage.app/Contents/Resources/Assets.car"
    if [ ! -f "${car}" ]; then
        echo "error: ${car} is missing; the icon bundle did not compile into the app" >&2
        exit 1
    fi
    asset_info="$(xcrun assetutil --info "${car}")"
    if ! grep -q '"Name" : "Usage"' <<<"${asset_info}"; then
        echo "error: Assets.car carries no 'Usage' app-icon rendition" >&2
        exit 1
    fi
    plist="{{derived}}/Build/Products/Debug/Usage.app/Contents/Info.plist"
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "${plist}")" != "Usage" ]; then
        echo "error: CFBundleIconName was not injected into the built Info.plist" >&2
        exit 1
    fi
    echo "ok: icon bundle lints, artwork is 1024x1024+alpha, rendition and CFBundleIconName present"

# Audit the security properties embedded in the staged Release app.
verify-security: app
    @just _verify-security-path build/Usage.app

# The audited posture: Hardened Runtime, arm64e, and the Enhanced Security hard-mode suite —
# everything Shared.xcconfig and Config/Usage.entitlements claim, proven on the built product.
# The sandbox is deliberately absent (Usage reads other agents' files and keychain items), so
# unlike PBnJ's audit there is no app-sandbox requirement.
[private]
_verify-security-path app:
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{app}}"
    binary="${app}/Contents/MacOS/{{scheme}}"
    audit_dir="$(mktemp -d -t usage-security)"
    entitlements="${audit_dir}/entitlements.plist"
    signature="${audit_dir}/signature.txt"
    trap 'rm -f "${entitlements}" "${signature}"; rmdir "${audit_dir}" 2>/dev/null || true' EXIT

    codesign --verify --deep --strict "${app}"
    codesign --display --entitlements - --xml "${app}" >"${entitlements}" 2>/dev/null
    codesign --display --verbose=2 "${app}" >"${signature}" 2>&1

    require_entitlement() {
        local key="$1" expected="$2" actual
        actual="$(/usr/libexec/PlistBuddy -c "Print :${key}" "${entitlements}" 2>/dev/null || true)"
        if [[ "${actual}" != "${expected}" ]]; then
            printf 'Security verification failed: %s is not %s.\n' "${key}" "${expected}" >&2
            exit 1
        fi
    }
    reject_entitlement() {
        local key="$1"
        if /usr/libexec/PlistBuddy -c "Print :${key}" "${entitlements}" >/dev/null 2>&1; then
            printf 'Security verification failed: forbidden entitlement %s is present.\n' "${key}" >&2
            exit 1
        fi
    }

    require_entitlement com.apple.security.hardened-process true
    require_entitlement com.apple.security.hardened-process.checked-allocations true
    require_entitlement com.apple.security.hardened-process.checked-allocations.enable-pure-data true
    require_entitlement com.apple.security.hardened-process.enhanced-security-version-string 2
    require_entitlement com.apple.security.hardened-process.hardened-heap true
    require_entitlement com.apple.security.hardened-process.dyld-ro true
    require_entitlement com.apple.security.hardened-process.platform-restrictions-string 2

    reject_entitlement com.apple.security.hardened-process.checked-allocations.soft-mode
    reject_entitlement com.apple.security.cs.allow-jit
    reject_entitlement com.apple.security.cs.allow-unsigned-executable-memory
    reject_entitlement com.apple.security.cs.disable-executable-page-protection
    reject_entitlement com.apple.security.cs.disable-library-validation
    reject_entitlement com.apple.security.cs.allow-dyld-environment-variables
    reject_entitlement com.apple.security.get-task-allow

    if ! grep -q 'flags=.*runtime' "${signature}"; then
        printf 'Security verification failed: Hardened Runtime is not present.\n' >&2
        exit 1
    fi
    if [[ " $(lipo -archs "${binary}") " != *' arm64e '* ]]; then
        printf 'Security verification failed: the app does not contain an arm64e slice.\n' >&2
        exit 1
    fi

    printf 'Verified Hardened Runtime, arm64e, Enhanced Security v2, and hard-mode MIE entitlements.\n'

# Build and audit the Release app, install it into /Applications, and relaunch.
#
# The transaction itself lives in Scripts/install_app.sh so its rollback branches are testable
# under a temporary root; this recipe only supplies the production source and destination. An
# ad-hoc source is rejected before anything is staged: an ad-hoc identity mints a new code
# principal on every rebuild, so the Keychain could never durably approve the installed copy.
install: verify-security
    #!/usr/bin/env bash
    set -euo pipefail
    if ! signature="$(codesign --display --verbose=2 build/Usage.app 2>&1)"; then
        echo "error: build/Usage.app has no inspectable signature; nothing was installed" >&2
        exit 1
    fi
    if grep -q '^Signature=adhoc$' <<<"${signature}"; then
        echo "error: build/Usage.app is ad-hoc signed; set the identity in Config/Local.xcconfig" >&2
        echo "  An ad-hoc install cannot hold a durable Keychain grant. Nothing was installed." >&2
        exit 1
    fi
    Scripts/install_app.sh --source build/Usage.app --destination-root /Applications

# Prove every rollback branch of the install transaction under a temporary root.
# Never opens an app, never touches /Applications; safe to run inside `just check`.
test-install:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(mktemp -d)"
    trap '/bin/rm -rf "${root}"' EXIT
    root="$(cd "${root}" && pwd -P)"
    dest="${root}/dest"
    mkdir -p "${dest}"
    ok_tool="${root}/ok"; printf '#!/bin/sh\nexit 0\n' > "${ok_tool}"; chmod +x "${ok_tool}"
    bad_tool="${root}/bad"; printf '#!/bin/sh\nexit 1\n' > "${bad_tool}"; chmod +x "${bad_tool}"

    make_app() { # path marker
        mkdir -p "$1/Contents/MacOS"
        printf '%s\n' "$2" > "$1/Contents/MacOS/Usage"
    }
    reset_fixture() { # previous-marker
        /bin/rm -rf "${dest}" "${root}/source"; mkdir -p "${dest}"
        make_app "${root}/source/Usage.app" "new"
        if [ -n "$1" ]; then make_app "${dest}/Usage.app" "$1"; fi
    }
    run() {
        Scripts/install_app.sh --source "${root}/source/Usage.app" \
            --destination-root "${dest}" --test-root "${root}" \
            --verifier "${ok_tool}" --launcher "${ok_tool}" "$@"
    }
    expect_previous_restored() { # case-name
        [ "$(cat "${dest}/Usage.app/Contents/MacOS/Usage")" = "old" ] \
            || { echo "FAIL($1): previous app was not restored byte-identically" >&2; exit 1; }
        [ -z "$(find "${dest}" -maxdepth 1 -name '.Usage.install.*')" ] \
            || { echo "FAIL($1): staging directory left behind" >&2; exit 1; }
    }

    # Success: the new app lands, the stage is cleaned up.
    reset_fixture "old"
    run
    [ "$(cat "${dest}/Usage.app/Contents/MacOS/Usage")" = "new" ]
    [ -z "$(find "${dest}" -maxdepth 1 -name '.Usage.install.*')" ]

    # Every recoverable failure restores the byte-identical previous app.
    for seam in move-replacement after-replace verify launch; do
        reset_fixture "old"
        if run --fail-at "${seam}"; then
            echo "FAIL(${seam}): the injected failure did not fail the install" >&2; exit 1
        fi
        expect_previous_restored "${seam}"
    done

    # A failing staged-copy audit stops before the destination is touched at all.
    reset_fixture "old"
    if Scripts/install_app.sh --source "${root}/source/Usage.app" \
        --destination-root "${dest}" --test-root "${root}" \
        --verifier "${bad_tool}" --launcher "${ok_tool}"; then
        echo "FAIL(staged-audit): a failing verifier did not fail the install" >&2; exit 1
    fi
    expect_previous_restored "staged-audit"

    # With no previous app, a failure must leave no destination app behind.
    reset_fixture ""
    if run --fail-at launch; then echo "FAIL(no-previous)" >&2; exit 1; fi
    [ ! -e "${dest}/Usage.app" ] \
        || { echo "FAIL(no-previous): a failed install left a destination app" >&2; exit 1; }

    # An intentionally failed restore preserves both recovery artifacts and prints their paths.
    reset_fixture "old"
    output="$(run --fail-at restore 2>&1)" && { echo "FAIL(restore)" >&2; exit 1; }
    previous_path="$(sed -n 's/^the previous app remains recoverable at //p' <<<"${output}")"
    failed_path="$(sed -n 's/^the rejected replacement remains at //p' <<<"${output}")"
    [ -n "${previous_path}" ] && [ -d "${previous_path}" ] \
        || { echo "FAIL(restore): preserved previous app path missing" >&2; exit 1; }
    [ -n "${failed_path}" ] && [ -d "${failed_path}" ] \
        || { echo "FAIL(restore): preserved replacement path missing" >&2; exit 1; }
    [ "$(cat "${previous_path}/Contents/MacOS/Usage")" = "old" ]
    [ "$(cat "${failed_path}/Contents/MacOS/Usage")" = "new" ]

    # Production runs reject every injection surface before any mutation.
    reset_fixture "old"
    for args in "--fail-at launch" "--verifier ${ok_tool}" "--launcher ${ok_tool}"; do
        if Scripts/install_app.sh --source "${root}/source/Usage.app" \
            --destination-root "${dest}" ${args} 2>/dev/null; then
            echo "FAIL(production-guard): '${args}' was accepted without --test-root" >&2; exit 1
        fi
    done
    [ "$(cat "${dest}/Usage.app/Contents/MacOS/Usage")" = "old" ]

    # A real ad-hoc bundle is rejected even under the test root. This catches pipefail regressions
    # where grep exits after its match and makes the codesign producer's SIGPIPE hide that match.
    reset_fixture "old"
    adhoc="${root}/adhoc-source/Usage.app"
    make_app "${adhoc}" "adhoc"
    chmod +x "${adhoc}/Contents/MacOS/Usage"
    /usr/bin/plutil -create xml1 "${adhoc}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string Usage "${adhoc}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string io.blacktop.Usage.test \
        "${adhoc}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "${adhoc}/Contents/Info.plist"
    codesign --force --sign - "${adhoc}"
    if adhoc_output="$(Scripts/install_app.sh --source "${adhoc}" \
        --destination-root "${dest}" --test-root "${root}" --launcher "${ok_tool}" 2>&1)"; then
        echo "FAIL(adhoc): an ad-hoc source passed verification" >&2; exit 1
    fi
    if ! grep -q 'is ad-hoc signed' <<<"${adhoc_output}"; then
        echo "FAIL(adhoc): rejection did not identify the ad-hoc signature" >&2
        printf '%s\n' "${adhoc_output}" >&2
        exit 1
    fi
    expect_previous_restored "adhoc"

    # A test root outside the per-user temporary directory is refused.
    if Scripts/install_app.sh --source "${root}/source/Usage.app" \
        --destination-root "${dest}" --test-root "${HOME}" \
        --verifier "${ok_tool}" --launcher "${ok_tool}" 2>/dev/null; then
        echo "FAIL(tmp-guard): a test root outside TMPDIR was accepted" >&2; exit 1
    fi

    # A test root reached through a symlink is refused.
    ln -s "${root}" "${root}/alias"
    if Scripts/install_app.sh --source "${root}/source/Usage.app" \
        --destination-root "${dest}" --test-root "${root}/alias" \
        --verifier "${ok_tool}" --launcher "${ok_tool}" 2>/dev/null; then
        echo "FAIL(symlink-guard): a symlinked test root was accepted" >&2; exit 1
    fi

    echo "ok: install transaction rollback branches all hold"

# Handoff gate: locked deps, regenerate, lint, both test suites, warning-clean Debug build
check: deps-check gen lint test-core test-app build build-cli check-signing check-icon test-install
