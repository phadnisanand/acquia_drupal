#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE_DIR="${FIXTURE_DIR:-${TMPDIR:-/tmp}/emulsify-tools-generation-smoke}"
DRUPAL_VERSION="${DRUPAL_VERSION:-11.3.*}"
EMULSIFY_VERSION="${EMULSIFY_VERSION:-^6}"
TOOLS_VERSION="${TOOLS_VERSION:-1.0.99}"
DRUSH_VERSION="${DRUSH_VERSION:-^13}"
THEME_NAME="${THEME_NAME:-watson}"
DB_URL="${DB_URL:-sqlite://sites/default/files/.ht.sqlite}"
LOCAL_PACKAGE_DIR="${FIXTURE_DIR}/local/emulsify_tools"

cleanup_fixture() {
  if [[ -d "$FIXTURE_DIR" ]]; then
    chmod -R u+w "$FIXTURE_DIR" 2>/dev/null || true
    rm -rf "$FIXTURE_DIR"
  fi
}

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

assert_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || fail "Expected directory missing: ${dir}"
}

assert_file() {
  local file="$1"

  [[ -f "$file" ]] || fail "Expected file missing: ${file}"
}

assert_not_exists() {
  local path="$1"

  [[ ! -e "$path" ]] || fail "Unexpected path exists: ${path}"
}

assert_contains() {
  local file="$1"
  local expected="$2"

  grep -Fq "$expected" "$file" || fail "Expected ${file} to contain: ${expected}"
}

assert_matches() {
  local file="$1"
  local pattern="$2"

  grep -Eq "$pattern" "$file" || fail "Expected ${file} to match: ${pattern}"
}

assert_command_fails_with() {
  local expected="$1"
  shift
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "Expected command to fail: $*"
  grep -Fq "$expected" <<<"$output" || fail "Expected failed command output to contain: ${expected}"
}

command -v composer >/dev/null || fail "composer is required."
command -v php >/dev/null || fail "php is required."
if [[ "$DB_URL" == sqlite://* ]]; then
  php -r 'exit(extension_loaded("pdo_sqlite") ? 0 : 1);' || fail "The pdo_sqlite PHP extension is required for DB_URL=${DB_URL}."
fi

if [[ -x "$REPO_ROOT/vendor/bin/yaml-lint" ]]; then
  log "Linting module YAML files"
  "$REPO_ROOT/vendor/bin/yaml-lint" \
    "$REPO_ROOT/emulsify_tools.info.yml" \
    "$REPO_ROOT/emulsify_tools.services.yml" \
    "$REPO_ROOT/drush.services.yml"
fi

if [[ "${KEEP_FIXTURE:-0}" != "1" ]]; then
  trap cleanup_fixture EXIT
fi

log "Creating disposable Drupal fixture at ${FIXTURE_DIR}"
cleanup_fixture
composer create-project "drupal/recommended-project:${DRUPAL_VERSION}" "$FIXTURE_DIR" \
  --no-interaction \
  --no-progress

log "Copying this checkout as Drupal.org package drupal/emulsify_tools ${TOOLS_VERSION}"
mkdir -p "$LOCAL_PACKAGE_DIR"
tar \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='vendor' \
  --exclude='.DS_Store' \
  -C "$REPO_ROOT" \
  -cf - . | tar -C "$LOCAL_PACKAGE_DIR" -xf -

php -r '
$file = $argv[1];
$json = json_decode(file_get_contents($file), true);
$json["name"] = "drupal/emulsify_tools";
file_put_contents($file, json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
' "$LOCAL_PACKAGE_DIR/composer.json"

cd "$FIXTURE_DIR"

repository_json="$(php -r '
echo json_encode([
  "type" => "path",
  "url" => $argv[1],
  "options" => [
    "symlink" => false,
    "versions" => [
      "drupal/emulsify_tools" => $argv[2],
    ],
  ],
], JSON_UNESCAPED_SLASHES);
' "$LOCAL_PACKAGE_DIR" "$TOOLS_VERSION")"

composer config --json repositories.local_emulsify_tools "$repository_json"
composer config prefer-stable true
# This disposable compatibility fixture should test generation, not audit policy.
composer config audit.block-insecure false

log "Installing Emulsify Drupal ${EMULSIFY_VERSION}, Emulsify Tools ${TOOLS_VERSION}, and Drush"
composer require \
  "drupal/emulsify:${EMULSIFY_VERSION}" \
  "drupal/emulsify_tools:${TOOLS_VERSION}" \
  "drush/drush:${DRUSH_VERSION}" \
  --with-all-dependencies \
  --no-interaction \
  --no-progress

log "Installing Drupal fixture"
mkdir -p web/sites/default/files
vendor/bin/drush site:install minimal \
  --db-url="$DB_URL" \
  --site-name='Emulsify Tools generation smoke' \
  --account-name=admin \
  --account-pass=admin \
  -y

log "Enabling Emulsify Tools, Components, and the Emulsify parent theme"
vendor/bin/drush pm:enable components emulsify_tools -y
vendor/bin/drush theme:enable emulsify -y
vendor/bin/drush cr -y

log "Checking that bem() preserves utility class tokens"
bem_classes="$(vendor/bin/drush php:eval '
$attributes = (new \Drupal\emulsify_tools\BemTwigExtension())->bem(
  [],
  "card",
  [],
  "",
  ["hover:bg-blue-500", "md:hover:text-white", "w-1/2", "grid-cols-[1fr_2fr]", "[&>*]:p-4"],
);
echo json_encode($attributes->toArray()["class"], JSON_UNESCAPED_SLASHES);
')"
expected_bem_classes='["card","hover:bg-blue-500","md:hover:text-white","w-1/2","grid-cols-[1fr_2fr]","[&>*]:p-4"]'
[[ "$bem_classes" == "$expected_bem_classes" ]] || fail "bem() changed utility class tokens: ${bem_classes}"

log "Checking that bem() class output remains HTML escaped"
bem_rendered="$(vendor/bin/drush php:eval '
$attributes = (new \Drupal\emulsify_tools\BemTwigExtension())->bem(
  [],
  "card",
  [],
  "",
  ["x\" onmouseover=\"alert(1)"],
);
echo (string) $attributes;
')"
expected_bem_rendered=' class="card x&quot; onmouseover=&quot;alert(1)"'
[[ "$bem_rendered" == "$expected_bem_rendered" ]] || fail "bem() class output was not escaped: ${bem_rendered}"

log "Checking that the public Drush command is discoverable"
vendor/bin/drush list | grep -Fq 'emulsify_tools:bake' || fail "Drush command emulsify_tools:bake was not discovered."
vendor/bin/drush help emulsify >/dev/null || fail "Drush help for emulsify failed."
vendor/bin/drush help emulsify_tools:bake >/dev/null || fail "Drush help for emulsify_tools:bake failed."

log "Generating ${THEME_NAME} with drush emulsify"
vendor/bin/drush emulsify "$THEME_NAME"

theme_dir="web/themes/custom/${THEME_NAME}"
info_file="${theme_dir}/${THEME_NAME}.info.yml"

log "Validating generated child theme files"
assert_dir "$theme_dir"
assert_file "$info_file"
assert_matches "$info_file" '^[[:space:]]*base theme:[[:space:]]*emulsify[[:space:]]*$'
assert_contains "$info_file" 'drupal:emulsify_tools (^1.0)'
assert_file "${theme_dir}/config/install/${THEME_NAME}.settings.yml"
assert_file "${theme_dir}/config/schema/${THEME_NAME}.schema.yml"
assert_not_exists "${theme_dir}/whisk.info.emulsify.yml"
assert_not_exists "${theme_dir}/config/install/whisk.settings.yml"
assert_not_exists "${theme_dir}/config/schema/whisk.schema.yml"
assert_not_exists "${theme_dir}/project.emulsify.json"

log "Confirming existing destination fails safely through drush emulsify_tools:bake"
guard_checksum_before="$(cksum "$info_file")"
assert_command_fails_with \
  "The destination theme already exists: themes/custom/${THEME_NAME}" \
  vendor/bin/drush emulsify_tools:bake "$THEME_NAME"
guard_checksum_after="$(cksum "$info_file")"
[[ "$guard_checksum_before" == "$guard_checksum_after" ]] || fail "Existing destination was modified: ${info_file}"

log "Confirming missing Whisk source fails clearly"
emulsify_theme_path="$(vendor/bin/drush php:eval 'echo DRUPAL_ROOT . "/" . \Drupal::service("extension.list.theme")->getPath("emulsify");')"
whisk_dir="${emulsify_theme_path}/whisk"
missing_whisk_dir="${whisk_dir}.generation-smoke-missing"
assert_dir "$whisk_dir"
mv "$whisk_dir" "$missing_whisk_dir"
assert_command_fails_with \
  "The Emulsify Whisk source directory was not found:" \
  vendor/bin/drush emulsify_tools:bake missing_source_theme
mv "$missing_whisk_dir" "$whisk_dir"
assert_not_exists "web/themes/custom/missing_source_theme"

log "Enabling generated child theme"
vendor/bin/drush theme:enable "$THEME_NAME" -y
vendor/bin/drush config:set system.theme default "$THEME_NAME" -y
vendor/bin/drush cr -y

log "Emulsify Tools generation smoke test passed"
