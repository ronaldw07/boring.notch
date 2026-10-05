#!/bin/bash
# Publish a build: scripts/release.sh 0.5.1
#
# Builds the app, packages a .dmg, signs the update feed with the key in this
# Mac's Keychain, publishes a GitHub release, then pushes the feed so apps
# already installed offer the update. Needs a "## <version>" section in
# CHANGELOG.md, a clean tree, and HEAD pushed to the fork's main.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."

REPO=ronaldw07/boring.notch
TAG="v$VERSION"
CACHE="$HOME/.cache/boringnotch-release"
WORK="$(mktemp -d)"
fail() { echo "error: $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes — commit first"
git fetch -q fork
[ "$(git rev-parse HEAD)" = "$(git rev-parse fork/main)" ] || fail "HEAD isn't pushed to fork/main"
grep -q "^## $VERSION " CHANGELOG.md || fail "CHANGELOG.md has no '## $VERSION' section"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && fail "$TAG already exists"

# Sparkle's signing tools, at the version the app links, cached between releases.
SPARKLE_VERSION=$(python3 - <<'PY'
import json
pins = json.load(open("boringNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))["pins"]
print(next(p["state"]["version"] for p in pins if p["identity"] == "sparkle"))
PY
)
TOOLS="$CACHE/sparkle-$SPARKLE_VERSION/bin"
if [ ! -x "$TOOLS/generate_appcast" ]; then
  mkdir -p "$CACHE/sparkle-$SPARKLE_VERSION"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$CACHE/sparkle-$SPARKLE_VERSION"
fi

# Sparkle only offers a build whose number is higher than the installed one.
# The commit count only ever goes up, so no counter file to keep in sync.
BUILD=$(git rev-list --count HEAD)
echo "Building $VERSION (build $BUILD)…"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$WORK/build" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build >"$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; fail "build failed"; }

APP="$WORK/build/Build/Products/Release/boringNotch.app"
codesign --deep --force --sign - "$APP"

mkdir -p "$WORK/stage" "$WORK/feed"
cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -quiet -volname "Boring Notch" -srcfolder "$WORK/stage" -ov -format UDZO "$WORK/feed/boringNotch.dmg"

# This version's changelog section: markdown for the release page, html for
# the update dialog.
python3 - "$VERSION" "$WORK" <<'PY'
import re, sys, html
version, work = sys.argv[1:]
text = open("CHANGELOG.md").read()
section = re.search(r"^## %s .*?\n(.*?)(?=^---|^## |\Z)" % re.escape(version), text, re.M | re.S).group(1).strip()
open(f"{work}/notes.md", "w").write(section + "\n")
out, in_list = [], False
def close():
    global in_list
    if in_list: out.append("</ul>"); in_list = False
for line in section.splitlines():
    if line.startswith("### "):
        close(); out.append("<h3>%s</h3>" % html.escape(line[4:]))
    elif line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>%s" % html.escape(line[2:]))
    elif line.strip() and in_list:
        out[-1] += " " + html.escape(line.strip())
    elif not line.strip():
        continue
close()
out_html = []
for l in out:
    l = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", l)
    l = re.sub(r"`(.+?)`", r"<code>\1</code>", l)
    out_html.append(l + ("</li>" if l.startswith("<li>") else ""))
open(f"{work}/feed/boringNotch.html", "w").write("\n".join(out_html) + "\n")
PY

"$TOOLS/generate_appcast" \
  --embed-release-notes \
  --link "https://github.com/$REPO/releases" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$WORK/feed/appcast.xml" "$WORK/feed" >/dev/null
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$WORK/feed/appcast.xml" || fail "appcast doesn't list build $BUILD"
grep -q "sparkle:edSignature" "$WORK/feed/appcast.xml" || fail "appcast isn't signed"

# Release first, feed second — so the feed never points at a missing file.
{ cat "$WORK/notes.md"; printf '\n---\n\nInstall: drag Boring Notch to Applications, then run\n`xattr -dr com.apple.quarantine /Applications/boringNotch.app`\nbefore opening it (the build is unsigned). Already installed? It updates itself.\n'; } > "$WORK/release-notes.md"
gh release create "$TAG" "$WORK/feed/boringNotch.dmg" --repo "$REPO" --title "$TAG" --notes-file "$WORK/release-notes.md"

cp "$WORK/feed/appcast.xml" updater/appcast.xml
git add updater/appcast.xml
git commit -q -m "chore: release $TAG"
git push -q fork live-audio-visualizer
git push -q fork live-audio-visualizer:main

echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
