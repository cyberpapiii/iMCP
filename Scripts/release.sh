#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="${APP_BUNDLE:-}"
if [[ -n "${APP_BUNDLE}" && "${APP_BUNDLE}" != /* ]]; then
  APP_BUNDLE="${PWD}/${APP_BUNDLE}"
fi
cd "${SCRIPT_DIR}/.."

APP_NAME="iMCP"
SCHEME="iMCP"
CONFIGURATION="Release"
DESTINATION="platform=macOS"
PROJECT_FILE="iMCP.xcodeproj/project.pbxproj"
DIST_DIR="dist"
ARCHIVE_PATH="${DIST_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${DIST_DIR}/export"
EXPORT_OPTIONS_PLIST="${DIST_DIR}/export-options.plist"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
TEAM_ID="${TEAM_ID:-}"
SIGNING_CERTIFICATE="${SIGNING_CERTIFICATE:-Developer ID Application}"
PROVISIONING_PROFILE_NAME="${PROVISIONING_PROFILE_NAME:-}"
PROVISIONING_PROFILE_UUID="${PROVISIONING_PROFILE_UUID:-}"
BUILD_SETTINGS=""
BUNDLE_ID=""

NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-notarize.zip"
RELEASE_REMOTE="${RELEASE_REMOTE:-origin}"
RELEASE_REPO=""

print_usage() {
  cat <<'EOF'
Usage: Scripts/release.sh [command]

Commands:
  publish     Build, notarize, tag, create release, upload. HEAD must be the
              remote's main; safe to re-run after a failure
  check       Quick release build check
  bump        Bump version/build numbers
  archive     Create an Xcode archive for direct distribution
  export      Export a Developer ID signed app from the archive
  profiles    List installed provisioning profiles
  package     Create the release zip from the app bundle
  notarize    Submit the app bundle for notarization
  staple      Staple the notarization ticket to the app bundle
  push-tags   Push the release tag (prompts unless CONFIRM_PUSH_TAGS=1)
  release     Create a GitHub release (no assets)
  upload      Upload the release asset to GitHub
  repo        Print the GitHub owner/name that tags and releases go to
  preflight   Run clean-tree, bundle-id, and release-remote guards only
  help        Show this help

Artifacts go to dist/ in the repository root, wherever this is run from.

Environment:
  VERSION           Required for bumping, commit, release, and upload
  BUILD_NUMBER      Optional; used when bumping build number
  KEYCHAIN_PROFILE  Required for notarize
  RELEASE_REMOTE    Git remote for tags and releases (default: origin; upstream mattt/iMCP is refused)
  CONFIRM_PUSH_TAGS Set to 1 to skip push-tags interactive prompt
  APP_BUNDLE        App bundle for a step run on its own (default: the exported app)
  TEAM_ID           Team ID for Developer ID signing (optional)
  SIGNING_CERTIFICATE Signing certificate (default: Developer ID Application)
  PROVISIONING_PROFILE_NAME Provisioning profile name for export (optional)
  PROVISIONING_PROFILE_UUID Provisioning profile UUID for export (optional)
EOF
}

# Call as a plain command, not inside $(...), so the settings are read once.
load_build_settings() {
  if [[ -z "${BUILD_SETTINGS}" ]]; then
    BUILD_SETTINGS="$(xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" -showBuildSettings)"
  fi
}

# Prints one Release build setting of the app target. The scheme also builds
# the CLI and the watchdog, whose settings follow the app's in the output.
app_build_setting() {
  printf '%s\n' "${BUILD_SETTINGS}" | awk -v name="$1" -v target="${APP_NAME}" '
    /^Build settings for / { in_app = ($0 ~ ("target " target ":$")) }
    in_app && $1 == name && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }
  '
}

resolve_built_app() {
  load_build_settings
  APP_BUNDLE="$(app_build_setting BUILT_PRODUCTS_DIR)/$(app_build_setting FULL_PRODUCT_NAME)"
}

# An explicit or already-resolved APP_BUNDLE wins; a step run on its own
# (notarize, staple, package) falls back to the exported app.
require_app_bundle() {
  if [[ ! -d "${APP_BUNDLE}" ]] && ! resolve_exported_app; then
    echo "Missing app bundle: ${APP_BUNDLE} (run export, or set APP_BUNDLE)" >&2
    exit 1
  fi
}

verify_app_signing() {
  require_app_bundle
  "${SCRIPT_DIR}/verify-app-signing.sh" "${APP_BUNDLE}"
}

require_keychain_profile() {
  if [[ -z "${KEYCHAIN_PROFILE}" ]]; then
    echo "Missing keychain profile. Set KEYCHAIN_PROFILE." >&2
    exit 1
  fi
}

require_version() {
  if [[ -z "${VERSION}" ]]; then
    echo "VERSION is required for releases." >&2
    exit 1
  fi
}

require_clean_tree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree is dirty. Commit or stash changes first." >&2
    exit 1
  fi
  if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "Working tree has untracked files. Commit, stash, or remove them first." >&2
    exit 1
  fi
}

ensure_dist_dir() {
  mkdir -p "${DIST_DIR}"
}

resolve_bundle_id() {
  if [[ -z "${BUNDLE_ID}" ]]; then
    load_build_settings
    BUNDLE_ID="$(app_build_setting PRODUCT_BUNDLE_IDENTIFIER)"
  fi
  [[ -n "${BUNDLE_ID}" ]]
}

list_profiles() {
  local profiles_dir
  local found_dir="0"
  local profile tmp_plist name uuid team weatherkit app_id
  local profiles_dirs=(
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  )
  resolve_bundle_id || true

  for profiles_dir in "${profiles_dirs[@]}"; do
    if [[ ! -d "${profiles_dir}" ]]; then
      continue
    fi
    found_dir="1"
    for profile in "${profiles_dir}"/*.mobileprovision "${profiles_dir}"/*.provisionprofile; do
      if [[ ! -f "${profile}" ]]; then
        continue
      fi
      tmp_plist="$(mktemp)"
      if ! security cms -D -i "${profile}" > "${tmp_plist}" 2>/dev/null; then
        rm -f "${tmp_plist}"
        continue
      fi
      name="$("/usr/libexec/PlistBuddy" -c "Print Name" "${tmp_plist}" 2>/dev/null || true)"
      uuid="$("/usr/libexec/PlistBuddy" -c "Print UUID" "${tmp_plist}" 2>/dev/null || true)"
      team="$("/usr/libexec/PlistBuddy" -c "Print TeamIdentifier:0" "${tmp_plist}" 2>/dev/null || true)"
      weatherkit="$("/usr/libexec/PlistBuddy" -c "Print Entitlements:com.apple.developer.weatherkit" "${tmp_plist}" 2>/dev/null || true)"
      app_id="$("/usr/libexec/PlistBuddy" -c "Print Entitlements:com.apple.application-identifier" "${tmp_plist}" 2>/dev/null || true)"
      rm -f "${tmp_plist}"
      if [[ -n "${BUNDLE_ID}" && -n "${app_id}" ]]; then
        if [[ "${app_id}" != *".${BUNDLE_ID}" && "${app_id}" != "${BUNDLE_ID}" ]]; then
          continue
        fi
      fi
      printf '%s\n' "Name: ${name}"
      printf '%s\n' "UUID: ${uuid}"
      printf '%s\n' "Team: ${team}"
      if [[ -n "${app_id}" ]]; then
        printf '%s\n' "App ID: ${app_id}"
      fi
      if [[ -n "${weatherkit}" ]]; then
        printf '%s\n' "WeatherKit: ${weatherkit}"
      fi
      printf '%s\n\n' "File: ${profile}"
    done
  done

  if [[ "${found_dir}" != "1" ]]; then
    echo "No provisioning profiles directory found at expected locations:" >&2
    echo "  ${profiles_dirs[0]}" >&2
    echo "  ${profiles_dirs[1]}" >&2
    exit 1
  fi
}

resolve_exported_app() {
  local candidate
  for candidate in "${EXPORT_DIR}"/*.app "${EXPORT_DIR}"/Applications/*.app "${EXPORT_DIR}"/Products/Applications/*.app; do
    if [[ -d "${candidate}" ]]; then
      APP_BUNDLE="${candidate}"
      return 0
    fi
  done
  return 1
}

release_zip() {
  require_version
  printf '%s/%s-%s.zip' "${DIST_DIR}" "${APP_NAME}" "${VERSION}"
}

cleanup() {
  rm -f "${NOTARY_ZIP}"
}

trap cleanup EXIT

bump_version() {
  require_version
  if [[ ! -f "${PROJECT_FILE}" ]]; then
    echo "Missing project file: ${PROJECT_FILE}" >&2
    exit 1
  fi
  local resolved_build_number="${BUILD_NUMBER}"
  if [[ -z "${resolved_build_number}" ]]; then
    resolved_build_number="0"
    while IFS= read -r line; do
      if [[ "${line}" =~ CURRENT_PROJECT_VERSION\ =\ ([0-9]+)\; ]]; then
        resolved_build_number="${BASH_REMATCH[1]}"
        break
      fi
    done < "${PROJECT_FILE}"
    resolved_build_number="$((resolved_build_number + 1))"
  fi

  echo "Setting MARKETING_VERSION to ${VERSION}"
  echo "Setting CURRENT_PROJECT_VERSION to ${resolved_build_number}"
  local tmp_file
  tmp_file="$(mktemp)"
  while IFS= read -r line; do
    if [[ "${line}" == *"MARKETING_VERSION ="* ]]; then
      printf '%s\n' "${line%%MARKETING_VERSION = *}MARKETING_VERSION = ${VERSION};" >> "${tmp_file}"
    elif [[ "${line}" == *"CURRENT_PROJECT_VERSION ="* ]]; then
      printf '%s\n' "${line%%CURRENT_PROJECT_VERSION = *}CURRENT_PROJECT_VERSION = ${resolved_build_number};" >> "${tmp_file}"
    else
      printf '%s\n' "${line}" >> "${tmp_file}"
    fi
  done < "${PROJECT_FILE}"
  mv "${tmp_file}" "${PROJECT_FILE}"
}

build_zip() {
  local source_bundle="$1"
  local output_zip="$2"
  ensure_dist_dir
  echo "Creating zip: ${output_zip}"
  ditto -c -k --keepParent "${source_bundle}" "${output_zip}"
}

build_check() {
  echo "Checking release build (scheme: ${SCHEME}, configuration: ${CONFIGURATION})"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" build
  resolve_built_app
  verify_app_signing
}

archive_app() {
  ensure_dist_dir
  echo "Archiving app to ${ARCHIVE_PATH}"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "generic/platform=macOS" archive -archivePath "${ARCHIVE_PATH}"
}

write_export_options() {
  ensure_dist_dir
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>${SIGNING_CERTIFICATE}</string>
EOF
  local profile_value=""
  if [[ -n "${PROVISIONING_PROFILE_UUID}" ]]; then
    profile_value="${PROVISIONING_PROFILE_UUID}"
  elif [[ -n "${PROVISIONING_PROFILE_NAME}" ]]; then
    profile_value="${PROVISIONING_PROFILE_NAME}"
  fi
  if [[ -n "${profile_value}" ]]; then
    if ! resolve_bundle_id; then
      echo "error: could not read the app's PRODUCT_BUNDLE_IDENTIFIER for the provisioning profile" >&2
      exit 1
    fi
    cat >> "${tmp_file}" <<EOF
  <key>provisioningProfiles</key>
  <dict>
    <key>${BUNDLE_ID}</key>
    <string>${profile_value}</string>
  </dict>
EOF
  fi
  if [[ -n "${TEAM_ID}" ]]; then
    cat >> "${tmp_file}" <<EOF
  <key>teamID</key>
  <string>${TEAM_ID}</string>
EOF
  fi
  cat >> "${tmp_file}" <<'EOF'
</dict>
</plist>
EOF
  mv "${tmp_file}" "${EXPORT_OPTIONS_PLIST}"
}

export_app() {
  write_export_options
  echo "Exporting Developer ID app to ${EXPORT_DIR}"
  xcodebuild -quiet -exportArchive -archivePath "${ARCHIVE_PATH}" -exportPath "${EXPORT_DIR}" -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"
  if ! resolve_exported_app; then
    echo "error: export produced no app in ${EXPORT_DIR}" >&2
    exit 1
  fi
  verify_app_signing
}

notarize() {
  require_app_bundle
  require_keychain_profile
  ensure_dist_dir
  echo "Zipping for notarization: ${NOTARY_ZIP}"
  ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"
  echo "Submitting to notarization"
  xcrun notarytool submit "${NOTARY_ZIP}" --wait --keychain-profile="${KEYCHAIN_PROFILE}"
}

staple() {
  require_app_bundle
  echo "Stapling notarization ticket"
  xcrun stapler staple "${APP_BUNDLE}"
}

package_release() {
  require_app_bundle
  verify_app_signing
  local release_zip_path
  release_zip_path="$(release_zip)"
  build_zip "${APP_BUNDLE}" "${release_zip_path}"
  echo "Done: ${release_zip_path}"
}

validate_staple() {
  require_app_bundle
  echo "Validating stapled ticket"
  xcrun stapler validate "${APP_BUNDLE}"
}

# A tag already at HEAD is an earlier publish of this same commit, to resume.
require_tag_free_or_at_head() {
  local tagged
  tagged="$(git rev-parse --verify --quiet "refs/tags/${VERSION}^{commit}" || true)"
  if [[ -n "${tagged}" && "${tagged}" != "$(git rev-parse HEAD)" ]]; then
    echo "error: tag ${VERSION} already exists on another commit (${tagged})" >&2
    exit 1
  fi
}

tag_current_commit() {
  require_version
  require_clean_tree
  local release_zip_path
  release_zip_path="$(release_zip)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  validate_staple
  require_tag_free_or_at_head
  if git rev-parse --verify --quiet "refs/tags/${VERSION}" >/dev/null; then
    echo "Tag ${VERSION} already points at HEAD; resuming"
    return 0
  fi
  echo "Tagging current commit as ${VERSION}"
  git tag -a "${VERSION}" -m "Release ${VERSION}"
}

push_tags() {
  require_version
  resolve_release_repo
  if ! git rev-parse --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then
    echo "Missing tag: ${VERSION}" >&2
    exit 1
  fi
  if [[ "${CONFIRM_PUSH_TAGS:-}" != "1" ]]; then
    local response=""
    read -r -p "Push tag ${VERSION} to ${RELEASE_REPO}? [y/N] " response
    if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
      echo "Tag push cancelled."
      exit 1
    fi
  fi
  git push "${RELEASE_REMOTE}" "refs/tags/${VERSION}"
}

# Sets RELEASE_REPO to the owner/name behind RELEASE_REMOTE. Call it as a plain
# command, never inside $(...): `exit` in a command substitution ends only the
# subshell, which is how an upstream origin once printed an error and published
# anyway.
resolve_release_repo() {
  local url
  url="$(git remote get-url "${RELEASE_REMOTE}")"
  if [[ "${url}" != *github.com[:/]* ]]; then
    echo "error: ${RELEASE_REMOTE} is not a GitHub remote: ${url}" >&2
    exit 1
  fi
  RELEASE_REPO="${url#*github.com[:/]}"
  RELEASE_REPO="${RELEASE_REPO%.git}"
  if [[ "$(printf '%s' "${RELEASE_REPO}" | tr '[:upper:]' '[:lower:]')" == "mattt/imcp" ]]; then
    echo "error: ${RELEASE_REMOTE} is upstream mattt/iMCP, which never receives tags or releases; set RELEASE_REMOTE to your fork's remote" >&2
    exit 1
  fi
}

print_release_repo() {
  resolve_release_repo
  printf '%s\n' "${RELEASE_REPO}"
}

create_release() {
  require_version
  resolve_release_repo
  if gh release view "${VERSION}" -R "${RELEASE_REPO}" >/dev/null 2>&1; then
    echo "GitHub release ${VERSION} already exists; resuming"
    return 0
  fi
  echo "Creating GitHub release ${VERSION} on ${RELEASE_REPO}"
  gh release create "${VERSION}" -R "${RELEASE_REPO}" --verify-tag --generate-notes
}

upload_asset() {
  require_version
  resolve_release_repo
  local release_zip_path
  release_zip_path="$(release_zip)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  local upload_path="${DIST_DIR}/${APP_NAME}.zip"
  if [[ "${release_zip_path}" != "${upload_path}" ]]; then
    cp -f "${release_zip_path}" "${upload_path}"
  fi
  echo "Uploading release asset ${upload_path}"
  # --clobber so a resumed publish can replace a partial upload.
  gh release upload "${VERSION}" "${upload_path}" -R "${RELEASE_REPO}" --clobber
}

publish() {
  # Version bump must already be merged. This keeps public releases attached to
  # reviewed main instead of a local release-only commit.
  require_version
  require_clean_tree
  resolve_release_repo
  git fetch "${RELEASE_REMOTE}" main
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]]; then
    echo "error: HEAD is not ${RELEASE_REMOTE}/main; publish only the merged commit" >&2
    exit 1
  fi
  require_tag_free_or_at_head
  build_check
  archive_app
  export_app
  notarize
  staple
  package_release
  tag_current_commit
  CONFIRM_PUSH_TAGS=1 push_tags
  create_release
  upload_asset
}

preflight() {
  require_clean_tree
  if ! resolve_bundle_id; then
    echo "error: could not read the app's PRODUCT_BUNDLE_IDENTIFIER" >&2
    exit 1
  fi
  echo "BUNDLE_ID=${BUNDLE_ID}"
  resolve_release_repo
  echo "RELEASE_REPO=${RELEASE_REPO}"
  echo "preflight ok"
}

COMMAND="${1:-help}"
case "${COMMAND}" in
  publish)
    publish
    ;;
  check)
    build_check
    ;;
  bump)
    bump_version
    ;;
  archive)
    archive_app
    ;;
  export)
    export_app
    ;;
  profiles)
    list_profiles
    ;;
  package)
    package_release
    ;;
  notarize)
    notarize
    ;;
  staple)
    staple
    ;;
  push-tags)
    push_tags
    ;;
  release)
    create_release
    ;;
  upload)
    upload_asset
    ;;
  repo)
    print_release_repo
    ;;
  preflight)
    preflight
    ;;
  help|-h|--help)
    print_usage
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    print_usage >&2
    exit 1
    ;;
esac
