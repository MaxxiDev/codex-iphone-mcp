#!/bin/zsh
# Build a tested universal archive; publish only when --publish is explicit.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh vMAJOR.MINOR.PATCH[-prerelease] [--publish]

Runs tests, builds an Apple Silicon + Intel app, checks MCP and the signature,
then writes the ZIP and SHA256SUMS.txt to build/releases/<tag>/.

  --publish  Upload and publish on GitHub using an existing, pushed tag.
             Requires gh authentication and a clean checkout at that tag.

Environment:
  CODESIGN_IDENTITY   Signing identity; default '-' (ad hoc, no notarization).
  APP_BUILD          Positive bundle build number; defaults to GITHUB_RUN_NUMBER or 1.
  GH_TOKEN           GitHub token, or authenticate locally with gh auth login.
  GITHUB_REPOSITORY  OWNER/REPO; otherwise inferred by gh from this checkout.

Prerelease tags such as v0.2.0-beta.1 are published as GitHub prereleases.
This script does not create or push Git tags.
EOF
}

die() { print -u2 -- "$*"; exit 1; }
if (( $# == 0 )); then usage >&2; exit 1; fi
if [[ "$1" == --help || "$1" == -h ]]; then usage; exit 0; fi
release_tag="$1"
shift
publish=0
while (( $# )); do
  case "$1" in
    --publish) publish=1 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
[[ "$release_tag" =~ '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' ]] \
  || die "Expected a version such as v0.2.0 or v0.2.0-beta.1."
[[ "$(uname -s)" == Darwin ]] || die "Building iPhone Use requires macOS."
for required in swift python3 codesign ditto lipo shasum; do
  command -v "$required" >/dev/null || die "Missing required tool: $required"
done
release_version="${release_tag#v}"
bundle_version="${release_version%%-*}"
prerelease=false
[[ "$release_version" != *-* ]] || prerelease=true
release_state=""
repo=""
if (( publish )); then
  command -v gh >/dev/null || die "Install GitHub CLI and run gh auth login first."
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] \
    || die "Publishing requires a clean checkout. Commit or isolate your changes first."
  tag_commit="$(git rev-parse --verify "refs/tags/${release_tag}^{commit}")" \
    || die "Create and push $release_tag before publishing."
  [[ "$(git rev-parse HEAD)" == "$tag_commit" ]] || die "Check out $release_tag before publishing."
  repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
  remote_commit="$(gh api "repos/$repo/commits/$release_tag" --jq .sha)"
  [[ "$remote_commit" == "$tag_commit" ]] || die "The remote tag does not match this checkout."
  release_state="$(gh api --paginate "repos/$repo/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$release_tag\") | .draft")"
  [[ -z "$release_state" || "$release_state" == true ]] \
    || die "$release_tag is already published; use a new version instead of replacing its assets."
fi

swift test
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
CONFIG=release BUILD_ARCH=universal APP_VERSION="$bundle_version" \
  APP_BUILD="${APP_BUILD:-${GITHUB_RUN_NUMBER:-1}}" CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}" \
  ./scripts/build-app.sh

app="build/iPhoneUseReviewed.app"
binary="$app/Contents/MacOS/iphone-use"
lipo "$binary" -verify_arch arm64 x86_64
codesign --verify --strict "$app"
python3 -B scripts/check-mcp.py -- "$binary" mcp

output_dir="$PWD/build/releases/$release_tag"
archive_name="iPhoneUseReviewed-${release_tag}-macOS-universal.zip"
mkdir -p "$output_dir"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/$archive_name"
(
  cd "$output_dir"
  LC_ALL=C shasum -a 256 "$archive_name" > SHA256SUMS.txt
  LC_ALL=C shasum -a 256 -c SHA256SUMS.txt
)
print -- "Release package: $output_dir/$archive_name"
(( publish )) || exit 0

cat > "$output_dir/RELEASE_NOTES.md" <<'EOF'
## 下载与安装 / Download and install

- 下载 Universal ZIP，支持 Apple Silicon 与 Intel Mac，要求 macOS 14 或更高版本。
- Download the Universal ZIP for Apple Silicon and Intel Macs running macOS 14 or later.
- 解压后将 iPhoneUseReviewed.app 移到“应用程序”并打开，无需 Xcode 或 Swift 工具链。
- Unzip, move iPhoneUseReviewed.app to Applications, and open it. Xcode and Swift are not required.
- 首次使用需授予相机、蓝牙权限，并在 iPhone 完成 USB 信任和辅助触控蓝牙配对。
- Allow camera/Bluetooth access, trust the Mac over USB, and pair through iPhone AssistiveTouch.
- 默认构建使用临时签名，未经过 Apple 公证。如 macOS 阻止打开，请在确认来源后按系统“隐私与安全性”提示允许。
- Default builds are ad-hoc signed and are not notarized. If macOS blocks the app, follow its Privacy & Security prompts after verifying the source.
- SHA256SUMS.txt 提供下载文件校验。MCP 使用应用内的 Contents/MacOS/iphone-use 可执行文件并传入 mcp 参数。
- SHA256SUMS.txt contains download checksums. For MCP, run the app's Contents/MacOS/iphone-use executable with the mcp argument.
EOF
if [[ -z "$release_state" ]]; then
  gh release create "$release_tag" --repo "$repo" --verify-tag --draft \
    --title "iPhone Use $release_tag" --generate-notes --notes-file "$output_dir/RELEASE_NOTES.md"
fi
# Only unfinished drafts may be resumed; public release assets are never replaced.
[[ "$(gh release view "$release_tag" --repo "$repo" --json isDraft --jq .isDraft)" == true ]] \
  || die "$release_tag is no longer a draft; its assets were left unchanged."
gh release upload "$release_tag" "$output_dir/$archive_name" "$output_dir/SHA256SUMS.txt" \
  --repo "$repo" --clobber
gh release edit "$release_tag" --repo "$repo" --draft=false --prerelease="$prerelease"
gh release view "$release_tag" --repo "$repo" --json url --jq .url
