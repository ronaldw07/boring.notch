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
WORK="$(mktemp -d)"
fail() { echo "error: $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes — commit first"
git fetch -q fork
[ "$(git rev-parse HEAD)" = "$(git rev-parse fork/main)" ] || fail "HEAD isn't pushed to fork/main"
grep -q "^## $VERSION " CHANGELOG.md || fail "CHANGELOG.md has no '## $VERSION' section"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && fail "$TAG already exists"

# Chora's Google sign-in client (GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET). Kept
# out of the repo; the build puts it into the app's Info.plist.
GOOGLE_ENV="$HOME/.config/chora/google-oauth.env"
[ -f "$GOOGLE_ENV" ] || fail "missing $GOOGLE_ENV"
source "$GOOGLE_ENV"
[ -n "${GOOGLE_CLIENT_ID:-}" ] && [ -n "${GOOGLE_CLIENT_SECRET:-}" ] || fail "$GOOGLE_ENV needs GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET"

# Sparkle's signing tools, at the version the app links, cached between releases.
SPARKLE_VERSION=$(python3 - <<'PY'
import json
pins = json.load(open("boringNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))["pins"]
print(next(p["state"]["version"] for p in pins if p["identity"] == "sparkle"))
PY
)
# Downloaded fresh into the temp dir and checked against a pinned SHA-256 every
# time, rather than reused from a cache any process could have swapped: these
# tools sign the update every installed copy trusts. Upgrading Sparkle means
# updating the checksum (gh api repos/sparkle-project/Sparkle/releases/tags/<v>).
SPARKLE_SHA256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
[ "$SPARKLE_VERSION" = 2.9.6 ] || fail "Sparkle is $SPARKLE_VERSION; update SPARKLE_SHA256 in this script"
curl -sfL -o "$WORK/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
  || fail "couldn't download Sparkle's tools"
echo "$SPARKLE_SHA256  $WORK/sparkle.tar.xz" | shasum -a 256 -c --status || fail "Sparkle's tools don't match the pinned checksum"
mkdir -p "$WORK/sparkle"
tar -xJf "$WORK/sparkle.tar.xz" -C "$WORK/sparkle"
TOOLS="$WORK/sparkle/bin"

# Sparkle only offers a build whose number is higher than the installed one.
# The commit count only ever goes up, so no counter file to keep in sync.
BUILD=$(git rev-list --count HEAD)
echo "Building $VERSION (build $BUILD)…"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$WORK/build" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build >"$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; fail "build failed"; }

APP="$WORK/build/Build/Products/Release/Chora.app"
# Sign with a real identity, not ad-hoc: macOS ties permissions (system audio,
# calendar, camera) to the signature, and an ad-hoc one changes every build,
# so each update would ask everyone for them all over again.
SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
[ -n "$SIGN_IDENTITY" ] || fail "no Apple Development signing identity in the Keychain"
# Hardened runtime everywhere, so no other process can inject code into Chora
# and borrow its permissions. Nested code first, then the app itself again
# with the entitlements it needs to keep camera, audio, calendar, location
# and Apple Events working under the runtime. Not sandboxed (never has been).
codesign --deep --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --force --options runtime --entitlements scripts/release.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" || fail "signature check failed"

mkdir -p "$WORK/stage" "$WORK/feed"
cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -quiet -volname "Chora" -srcfolder "$WORK/stage" -ov -format UDZO "$WORK/feed/Chora.dmg"

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
open(f"{work}/feed/Chora.html", "w").write("\n".join(out_html) + "\n")
PY

"$TOOLS/generate_appcast" \
  --embed-release-notes \
  --link "https://github.com/$REPO/releases" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$WORK/feed/appcast.xml" "$WORK/feed" >/dev/null
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$WORK/feed/appcast.xml" || fail "appcast doesn't list build $BUILD"
grep -q "sparkle:edSignature" "$WORK/feed/appcast.xml" || fail "appcast isn't signed"

# Release first, feed second — so the feed never points at a missing file.
{ cat "$WORK/notes.md"; printf '\n---\n\nInstall: open Chora.dmg and drag Chora into Applications, then open it. When macOS says it can'"'"'t check it, click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Already installed? It updates itself.\n'; } > "$WORK/release-notes.md"
gh release create "$TAG" "$WORK/feed/Chora.dmg" --repo "$REPO" --title "$TAG" --notes-file "$WORK/release-notes.md"

cp "$WORK/feed/appcast.xml" updater/appcast.xml
git add updater/appcast.xml
git commit -q -m "chore: release $TAG"
# Works from any branch whose tip is fork/main: the release commit goes to
# main, and to the branch too so it stays level.
git push -q fork HEAD:main
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = main ] || [ "$BRANCH" = HEAD ] || git push -q fork "$BRANCH"

echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
