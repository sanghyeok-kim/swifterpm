# End-to-end resolver tests against real-world Package.swift fixtures and
# SwiftPM's dependency-resolution graph fixtures.
#
# Each scenario pins an upstream repository to a specific commit, downloads the
# manifest file via raw.githubusercontent.com, resolves it with swifterpm, and
# verifies that the resulting Package.resolved is accepted by SwiftPM with
# `--force-resolved-versions`. Every scenario runs inside its own temp tree
# scoped through a RETURN trap so nothing leaks into the host filesystem or
# the user's caches.

# Pinned upstream sources.
POCKET_CASTS_REPO="Automattic/pocket-casts-ios"
POCKET_CASTS_SHA="43552c30d4121ea6bd8d2ea5cb53ee46c76f267e"
POCKET_CASTS_MANIFEST_PATH="Modules/Package.swift"

FIREFOX_IOS_REPO="mozilla-mobile/firefox-ios"
FIREFOX_IOS_SHA="d97982a167c3e15393607e027eca7f92b53dcad8"
FIREFOX_IOS_MANIFEST_PATH="Package.swift"

SWIFTPM_FIXTURES="${PWD}/e2e/fixtures/swiftpm/DependencyResolution/External"

prepare_isolated_state() {
  local tmp="$1"

  mkdir -p \
    "${tmp}/home" \
    "${tmp}/tmp" \
    "${tmp}/xdg-cache" \
    "${tmp}/xdg-config" \
    "${tmp}/xdg-data"
}

scoped_env() {
  local tmp="$1"
  shift

  env \
    HOME="${tmp}/home" \
    USERPROFILE="${tmp}/home" \
    TMPDIR="${tmp}/tmp" \
    XDG_CACHE_HOME="${tmp}/xdg-cache" \
    XDG_CONFIG_HOME="${tmp}/xdg-config" \
    XDG_DATA_HOME="${tmp}/xdg-data" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    "$@"
}

isolated_workspace() {
  # Stand up a temp tree with the manifest copied in. Returns the package
  # directory on stdout. Caller is responsible for the RETURN trap that
  # cleans `${tmp}` up.
  local repo="$1"
  local sha="$2"
  local manifest_relative_path="$3"
  local tmp="$4"

  local package_dir="${tmp}/package"
  mkdir -p "${package_dir}"

  local manifest_url="https://raw.githubusercontent.com/${repo}/${sha}/${manifest_relative_path}"
  if ! curl --fail --silent --show-error --location --retry 3 \
      --output "${package_dir}/Package.swift" "${manifest_url}"; then
    echo "failed to download ${manifest_url}" >&2
    return 1
  fi

  echo "${package_dir}"
}

copy_swiftpm_fixture() {
  local name="$1"
  local tmp="$2"
  local fixture_dir="${tmp}/${name}"

  cp -R "${SWIFTPM_FIXTURES}/${name}" "${fixture_dir}"
  echo "${fixture_dir}"
}

init_git_package() {
  local tmp="$1"
  local package_dir="$2"

  scoped_env "${tmp}" git -C "${package_dir}" -c init.defaultBranch=main init >/dev/null
  scoped_env "${tmp}" git -C "${package_dir}" checkout -B main >/dev/null 2>&1
  scoped_env "${tmp}" git -C "${package_dir}" config user.email "swifterpm-e2e@example.com"
  scoped_env "${tmp}" git -C "${package_dir}" config user.name "swifterpm e2e"
  scoped_env "${tmp}" git -C "${package_dir}" add .
  scoped_env "${tmp}" git -C "${package_dir}" commit -m "Initial import" >/dev/null
}

tag_git_package() {
  local tmp="$1"
  local package_dir="$2"
  shift 2

  local tag
  for tag in "$@"; do
    scoped_env "${tmp}" git -C "${package_dir}" tag "${tag}"
  done
}

resolve_package() {
  local tmp="$1"
  local package_dir="$2"
  local cache_dir="$3"
  scoped_env "${tmp}" "${SWIFTERPM_BIN}" \
    --package-path "${package_dir}" \
    --scratch-path "${package_dir}/.build" \
    --cache-path "${cache_dir}" \
    --disable-package-info-cache \
    --quiet \
    resolve
}

canonical_path() {
  local path="$1"
  mkdir -p "${path}"
  (cd "${path}" && pwd -P)
}

normalize_json_file() {
  local source="$1"
  local swiftpm_scratch="$2"
  local swifterpm_scratch="$3"
  local swiftpm_cache="$4"
  local swifterpm_cache="$5"

  jq --sort-keys \
    --arg swiftpm_scratch "${swiftpm_scratch}" \
    --arg swifterpm_scratch "${swifterpm_scratch}" \
    --arg swiftpm_cache "${swiftpm_cache}" \
    --arg swifterpm_cache "${swifterpm_cache}" \
    '
      def replace_path($from; $to): split($from) | join($to);
      walk(
        if type == "string" then
          replace_path($swiftpm_scratch; "$SCRATCH")
          | replace_path($swifterpm_scratch; "$SCRATCH")
          | replace_path($swiftpm_cache; "$CACHE")
          | replace_path($swifterpm_cache; "$CACHE")
        else
          .
        end
      )
    ' "${source}"
}

normalize_package_resolved_file() {
  local source="$1"

  jq --sort-keys '
    def compact_state:
      with_entries(select(.value != null));

    def location_identity($location):
      ($location | split("/")[-1] | sub("\\.git$"; "") | ascii_downcase);

    def pin_location:
      .location // .repositoryURL // "";

    def pin_identity:
      if has("identity") then
        .identity
      elif has("location") then
        location_identity(.location)
      elif has("repositoryURL") then
        location_identity(.repositoryURL)
      elif has("package") then
        (.package | ascii_downcase)
      else
        ""
      end;

    def pin_kind:
      .kind // (if (pin_location | startswith("/")) then "localSourceControl" else "remoteSourceControl" end);

    def normalize_pin:
      {
        identity: pin_identity,
        kind: pin_kind,
        location: pin_location,
        state: (.state | compact_state)
      };

    {
      pins: (
        (if has("object") then .object.pins else .pins end)
        | map(normalize_pin)
        | sort_by(.identity, .location)
      )
    }
  ' "${source}"
}

compare_json_file() {
  local label="$1"
  local tmp="$2"
  local expected="$3"
  local actual="$4"
  local swiftpm_scratch="$5"
  local swifterpm_scratch="$6"
  local swiftpm_cache="$7"
  local swifterpm_cache="$8"

  local normalized_dir="${tmp}/normalized-state"
  mkdir -p "${normalized_dir}"

  local expected_normalized="${normalized_dir}/${label}.swiftpm.json"
  local actual_normalized="${normalized_dir}/${label}.swifterpm.json"
  normalize_json_file "${expected}" "${swiftpm_scratch}" "${swifterpm_scratch}" "${swiftpm_cache}" "${swifterpm_cache}" >"${expected_normalized}"
  normalize_json_file "${actual}" "${swiftpm_scratch}" "${swifterpm_scratch}" "${swiftpm_cache}" "${swifterpm_cache}" >"${actual_normalized}"

  if ! diff -u "${expected_normalized}" "${actual_normalized}"; then
    return 1
  fi

  echo "${label}=match"
}

compare_package_resolved_file() {
  local label="$1"
  local tmp="$2"
  local expected="$3"
  local actual="$4"

  local normalized_dir="${tmp}/normalized-state"
  mkdir -p "${normalized_dir}"

  local expected_normalized="${normalized_dir}/${label}.swiftpm.json"
  local actual_normalized="${normalized_dir}/${label}.swifterpm.json"
  normalize_package_resolved_file "${expected}" >"${expected_normalized}"
  normalize_package_resolved_file "${actual}" >"${actual_normalized}"

  if ! diff -u "${expected_normalized}" "${actual_normalized}"; then
    return 1
  fi

  echo "${label}=match"
}

compare_optional_json_file() {
  local label="$1"
  local tmp="$2"
  local expected="$3"
  local actual="$4"
  local swiftpm_scratch="$5"
  local swifterpm_scratch="$6"
  local swiftpm_cache="$7"
  local swifterpm_cache="$8"

  if [[ -f "${expected}" && -f "${actual}" ]]; then
    compare_package_resolved_file "${label}" "${tmp}" "${expected}" "${actual}"
  elif [[ ! -f "${expected}" && ! -f "${actual}" ]]; then
    echo "${label}=both-absent"
  else
    echo "${label}=presence-mismatch"
    return 1
  fi
}

compare_swiftpm_state_files() {
  local tmp="$1"
  local package_dir="$2"

  local swiftpm_scratch="${tmp}/swiftpm-scratch"
  local swifterpm_scratch="${tmp}/swifterpm-scratch"
  local swiftpm_cache="${tmp}/swiftpm-cache"
  local swifterpm_cache="${tmp}/swifterpm-cache"
  local swiftpm_resolved="${tmp}/Package.swiftpm.resolved"
  local swifterpm_resolved="${tmp}/Package.swifterpm.resolved"

  rm -f "${package_dir}/Package.resolved"
  scoped_env "${tmp}" swift package \
    --package-path "${package_dir}" \
    --scratch-path "${swiftpm_scratch}" \
    --cache-path "${swiftpm_cache}" \
    --disable-scm-to-registry-transformation \
    resolve >/dev/null 2>"${tmp}/swiftpm-resolve.stderr" || {
      cat "${tmp}/swiftpm-resolve.stderr" >&2
      return 1
    }
  if [[ -f "${package_dir}/Package.resolved" ]]; then
    cp "${package_dir}/Package.resolved" "${swiftpm_resolved}"
  fi

  rm -f "${package_dir}/Package.resolved"
  scoped_env "${tmp}" "${SWIFTERPM_BIN}" \
    --package-path "${package_dir}" \
    --scratch-path "${swifterpm_scratch}" \
    --cache-path "${swifterpm_cache}" \
    --disable-package-info-cache \
    --quiet \
    resolve >/dev/null
  if [[ -f "${package_dir}/Package.resolved" ]]; then
    cp "${package_dir}/Package.resolved" "${swifterpm_resolved}"
  fi

  swiftpm_scratch="$(canonical_path "${swiftpm_scratch}")"
  swifterpm_scratch="$(canonical_path "${swifterpm_scratch}")"
  swiftpm_cache="$(canonical_path "${swiftpm_cache}")"
  swifterpm_cache="$(canonical_path "${swifterpm_cache}")"

  compare_optional_json_file \
    "package-resolved" \
    "${tmp}" \
    "${swiftpm_resolved}" \
    "${swifterpm_resolved}" \
    "${swiftpm_scratch}" \
    "${swifterpm_scratch}" \
    "${swiftpm_cache}" \
    "${swifterpm_cache}" || return 1

  compare_json_file \
    "workspace-state" \
    "${tmp}" \
    "${swiftpm_scratch}/workspace-state.json" \
    "${swifterpm_scratch}/workspace-state.json" \
    "${swiftpm_scratch}" \
    "${swifterpm_scratch}" \
    "${swiftpm_cache}" \
    "${swifterpm_cache}"
}

swiftpm_accepts_lockfile() {
  local tmp="$1"
  local package_dir="$2"
  local cache_dir="$3"

  if [[ ! -f "${package_dir}/Package.resolved" ]]; then
    scoped_env "${tmp}" swift package \
      --package-path "${package_dir}" \
      --scratch-path "${cache_dir}/scratch" \
      --cache-path "${cache_dir}" \
      --disable-scm-to-registry-transformation \
      resolve >/dev/null 2>&1
    return
  fi

  scoped_env "${tmp}" swift package \
    --package-path "${package_dir}" \
    --scratch-path "${cache_dir}/scratch" \
    --cache-path "${cache_dir}" \
    --disable-scm-to-registry-transformation \
    --force-resolved-versions \
    resolve >/dev/null 2>&1
}

pin_count() {
  local package_dir="$1"
  if [[ ! -f "${package_dir}/Package.resolved" ]]; then
    echo "0"
    return
  fi
  jq '.pins | length' "${package_dir}/Package.resolved"
}

pin_state_value() {
  local package_dir="$1"
  local identity="$2"
  local field="$3"
  jq -r --arg identity "${identity}" --arg field "${field}" \
    '.pins[] | select(.identity == $identity) | .state[$field] // ""' \
    "${package_dir}/Package.resolved"
}

resolved_identities() {
  local package_dir="$1"
  jq -r '.pins[].identity' "${package_dir}/Package.resolved" | sort | tr '\n' ' ' | sed 's/ $//'
}

scenario_resolves_firefox_ios() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  prepare_isolated_state "${tmp}"

  local package_dir
  package_dir="$(isolated_workspace \
    "${FIREFOX_IOS_REPO}" \
    "${FIREFOX_IOS_SHA}" \
    "${FIREFOX_IOS_MANIFEST_PATH}" \
    "${tmp}")" || return 1

  resolve_package "${tmp}" "${package_dir}" "${tmp}/cache" || return 1
  swiftpm_accepts_lockfile "${tmp}" "${package_dir}" "${tmp}/swift-cache" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "force-resolve=ok"
}

scenario_resolves_pocket_casts_ios() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  prepare_isolated_state "${tmp}"

  local package_dir
  package_dir="$(isolated_workspace \
    "${POCKET_CASTS_REPO}" \
    "${POCKET_CASTS_SHA}" \
    "${POCKET_CASTS_MANIFEST_PATH}" \
    "${tmp}")" || return 1

  resolve_package "${tmp}" "${package_dir}" "${tmp}/cache" || return 1
  swiftpm_accepts_lockfile "${tmp}" "${package_dir}" "${tmp}/swift-cache" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "force-resolve=ok"
}

scenario_resolves_swiftpm_external_simple() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  prepare_isolated_state "${tmp}"

  local fixture_dir
  fixture_dir="$(copy_swiftpm_fixture "Simple" "${tmp}")" || return 1

  init_git_package "${tmp}" "${fixture_dir}/Foo" || return 1
  tag_git_package "${tmp}" "${fixture_dir}/Foo" "1.0.0" "1.1.0" "1.2.0" "1.2.3" || return 1

  local package_dir="${fixture_dir}/Bar"
  compare_swiftpm_state_files "${tmp}" "${package_dir}" || return 1
  swiftpm_accepts_lockfile "${tmp}" "${package_dir}" "${tmp}/swift-cache" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "foo-version=$(pin_state_value "${package_dir}" "foo" "version")"
  echo "force-resolve=ok"
}

scenario_resolves_swiftpm_external_complex() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  prepare_isolated_state "${tmp}"

  local fixture_dir
  fixture_dir="$(copy_swiftpm_fixture "Complex" "${tmp}")" || return 1

  local package
  for package in "FisherYates" "PlayingCard" "deck-of-playing-cards"; do
    init_git_package "${tmp}" "${fixture_dir}/${package}" || return 1
    tag_git_package "${tmp}" "${fixture_dir}/${package}" "1.0.0" || return 1
  done

  local package_dir="${fixture_dir}/app"
  compare_swiftpm_state_files "${tmp}" "${package_dir}" || return 1
  swiftpm_accepts_lockfile "${tmp}" "${package_dir}" "${tmp}/swift-cache" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "identities=$(resolved_identities "${package_dir}")"
  echo "force-resolve=ok"
}

scenario_resolves_swiftpm_branch_dependency() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  prepare_isolated_state "${tmp}"

  local fixture_dir
  fixture_dir="$(copy_swiftpm_fixture "Branch" "${tmp}")" || return 1

  init_git_package "${tmp}" "${fixture_dir}/Foo" || return 1

  local package_dir="${fixture_dir}/Bar"
  compare_swiftpm_state_files "${tmp}" "${package_dir}" || return 1
  swiftpm_accepts_lockfile "${tmp}" "${package_dir}" "${tmp}/swift-cache" || return 1

  local revision
  revision="$(pin_state_value "${package_dir}" "foo" "revision")"
  test -n "${revision}" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "foo-branch=$(pin_state_value "${package_dir}" "foo" "branch")"
  echo "foo-revision=present"
  echo "force-resolve=ok"
}

scenario_resolves_swiftpm_local_case_insensitive_dependency() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  prepare_isolated_state "${tmp}"

  local fixture_dir
  fixture_dir="$(copy_swiftpm_fixture "PackageLookupCaseInsensitive" "${tmp}")" || return 1

  local package_dir="${fixture_dir}/pkg"
  compare_swiftpm_state_files "${tmp}" "${package_dir}" || return 1
  swiftpm_accepts_lockfile "${tmp}" "${package_dir}" "${tmp}/swift-cache" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "force-resolve=ok"
}

Describe "swifterpm resolve against real-world manifests"
  It "resolves Firefox iOS root Package.swift and emits a SwiftPM-acceptable lockfile"
    When call scenario_resolves_firefox_ios
    The status should be success
    The output should match pattern "pins=*"
    The output should include "force-resolve=ok"
  End

  It "resolves Pocket Casts iOS Modules/Package.swift and emits a SwiftPM-acceptable lockfile"
    When call scenario_resolves_pocket_casts_ios
    The status should be success
    The output should match pattern "pins=*"
    The output should include "force-resolve=ok"
  End
End

Describe "swifterpm resolve against SwiftPM dependency graph fixtures"
  It "matches SwiftPM's external simple version-selection scenario"
    When call scenario_resolves_swiftpm_external_simple
    The status should be success
    The output should include "pins=1"
    The output should include "foo-version=1.2.3"
    The output should include "package-resolved=match"
    The output should include "workspace-state=match"
    The output should include "force-resolve=ok"
  End

  It "matches SwiftPM's external complex transitive graph scenario"
    When call scenario_resolves_swiftpm_external_complex
    The status should be success
    The output should include "pins=3"
    The output should include "identities=deck-of-playing-cards fisheryates playingcard"
    The output should include "package-resolved=match"
    The output should include "workspace-state=match"
    The output should include "force-resolve=ok"
  End

  It "matches SwiftPM's branch dependency scenario"
    When call scenario_resolves_swiftpm_branch_dependency
    The status should be success
    The output should include "pins=1"
    The output should include "foo-branch=main"
    The output should include "foo-revision=present"
    The output should include "package-resolved=match"
    The output should include "workspace-state=match"
    The output should include "force-resolve=ok"
  End

  It "matches SwiftPM's local case-insensitive package lookup scenario"
    When call scenario_resolves_swiftpm_local_case_insensitive_dependency
    The status should be success
    The output should include "pins=0"
    The output should include "package-resolved=both-absent"
    The output should include "workspace-state=match"
    The output should include "force-resolve=ok"
  End
End
