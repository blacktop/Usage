set shell := ["bash", "-euo", "pipefail", "-c"]

project := "Usage.xcodeproj"
scheme := "Usage"
destination := "platform=macOS,arch=arm64"
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

# Debug build of the app
build: gen
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug \
        -destination '{{destination}}' -derivedDataPath {{derived}} -quiet build

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
        -destination '{{destination}}' -derivedDataPath {{derived}} test

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
        -destination '{{destination}}' -derivedDataPath {{derived}} -quiet build
    if [ -d build/Usage.app ]; then trash build/Usage.app; fi
    ditto {{derived}}/Build/Products/Release/Usage.app build/Usage.app

# Handoff gate: locked deps, regenerate, lint, both test suites, warning-clean Debug build
check: deps-check gen lint test-core test-app build
