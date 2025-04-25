#!/bin/bash

################################################################################
# Drupal Multisite Module Status Check (Updated for Modern Drush/Composer)
#
# Checks for security vulnerabilities, general updates, and lists
# Composer-managed Drupal modules that are not enabled on any site matching
# a specific alias environment pattern (.local or .prod).
#
# Requirements:
# 1. Run from the Drupal project root directory (where composer.json is).
# 2. Drush aliases must be configured (e.g., in `drush/sites/self.site.yml`).
#    This script will find aliases ending in the specified environment suffix.
# 3. `jq` command-line JSON processor is no longer strictly needed by this script.
#
# Usage:
# ./check_modules.sh.sh -e local
# ./check_modules.sh.sh --environment=prod
#
# Options:
#   -e, --environment <env>  Specify the environment suffix ('local' or 'prod'). Required.
#   -h, --help               Display this help message.
#
# Note: This script now uses 'composer audit' for security checks and
# 'composer outdated' for update checks, reflecting modern Drupal practices.
# It dynamically discovers target aliases based on the specified environment.
#
################################################################################

# --- Function to display usage ---
usage() {
  echo "Usage: $0 -e <environment>"
  echo "Options:"
  echo "  -e, --environment <env>  Specify the environment suffix ('local' or 'prod'). Required."
  echo "  -h, --help               Display this help message."
  exit 1
}

# --- Argument Parsing ---
TARGET_ENV=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -e|--environment) TARGET_ENV="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate required argument
if [ -z "$TARGET_ENV" ]; then
    echo "Error: Missing required argument -e or --environment."
    usage
fi

# Validate environment value
if [[ "$TARGET_ENV" != "local" && "$TARGET_ENV" != "prod" ]]; then
    echo "Error: Invalid environment specified. Use 'local' or 'prod'."
    usage
fi

echo "############################################"
echo "### Drupal Module Status Check ###"
echo "############################################"
CURRENT_DATE=$(date +"%Y-%m-%d %H:%M:%S")
echo "Check run on: $CURRENT_DATE"
echo "Targeting environment: .$TARGET_ENV"
echo

# --- Configuration ---
# Use project's Drush binary explicitly
DRUSH_CMD="vendor/bin/drush"
# Patterns for alias discovery based on argument
ALIAS_PATTERN="\.${TARGET_ENV}$" # Construct pattern like \.local$ or \.prod$

# Check if Drush command exists
if [ ! -x "$DRUSH_CMD" ]; then
  echo "Error: Drush command not found or not executable at $DRUSH_CMD"
  echo "Ensure you are in the Drupal project root and ran 'composer install'."
  exit 1
fi

echo "Using Drush command: $DRUSH_CMD"

# --- Determine Target Aliases ---
echo "Discovering target Drush aliases (ending with .$TARGET_ENV)..."
# Get all aliases, filter by pattern, join with commas
all_aliases_output=$("$DRUSH_CMD" site:alias --format=list 2>&1)
drush_alias_exit_code=$?

if [ $drush_alias_exit_code -ne 0 ]; then
    echo "Error: Failed to list Drush site aliases (Exit code: $drush_alias_exit_code)."
    echo "$all_aliases_output"
    TARGET_ALIASES="" # Ensure variable is empty on error
else
    # Filter and format the aliases using the dynamic pattern
    TARGET_ALIASES=$(echo "$all_aliases_output" | grep -E "$ALIAS_PATTERN" | paste -sd,)
fi

if [ -z "$TARGET_ALIASES" ]; then
    echo "Warning: No Drush aliases found matching the pattern '$ALIAS_PATTERN'."
    echo "         Skipping check for unused modules across sites."
else
    echo "Targeting dynamically discovered aliases: $TARGET_ALIASES"
fi
echo


# --- Security Audit ---
echo "--- Checking Security Vulnerabilities (composer audit) ---"
# composer audit returns non-zero exit code if vulnerabilities are found.
audit_output=$(composer audit 2>&1)
audit_exit_code=$?
echo "$audit_output"
if [ $audit_exit_code -ne 0 ]; then
 echo "Warning: 'composer audit' reported vulnerabilities or an error (exit code $audit_exit_code)."
fi
echo

# --- Available Updates (Minor/Major) ---
echo "--- Checking Available Updates (composer outdated 'drupal/*') ---"
echo "(Review versions below to identify Minor vs Major updates)"
if ! composer outdated 'drupal/*'; then
  outdated_exit_code=$?
  if [ $outdated_exit_code -gt 1 ]; then
    echo "Warning: Error occurred while checking for outdated Drupal packages (exit code $outdated_exit_code)."
  fi
fi
echo

# --- Unused Composer Modules ---
echo "--- Checking for Composer Modules Not Enabled Anywhere on discovered .$TARGET_ENV aliases ---"

# Define temp files
composer_modules_file=$(mktemp)
enabled_modules_file=$(mktemp)
# Ensure cleanup on exit
trap 'rm -f "$composer_modules_file" "$enabled_modules_file"' EXIT

# Initialize status flags
module_list_ok=false # Initialize here
drush_list_ok=false  # Initialize here too for consistency

# Get Composer modules (installed, non-dev, drupal/*)
echo "Getting installed Drupal modules from composer..."
if ! composer show --no-dev --name-only | grep '^drupal/' | sed 's/^drupal\///' | sort > "$composer_modules_file"; then
    echo "Error: Failed to get installed Drupal modules via composer."
    # module_list_ok remains false
else
    module_count=$(wc -l < "$composer_modules_file" | tr -d ' ')
    echo "Found $module_count installed non-dev contrib/custom modules via composer."
    module_list_ok=true # Set to true only on success
fi

# Proceed only if target aliases were found and composer list is ok
if [ -n "$TARGET_ALIASES" ] && [ "$module_list_ok" = true ]; then
    # Get Enabled modules across all discovered sites
    echo "Getting enabled modules from discovered aliases ($TARGET_ALIASES) via Drush..."
    # Pass the alias list BEFORE the pm:list command
    if ! "$DRUSH_CMD" "$TARGET_ALIASES" pm:list --status=enabled --type=module --no-core --fields=name --format=list | sort | uniq > "$enabled_modules_file"; then
        echo "Warning: Failed to get enabled modules via Drush for discovered aliases."
        echo "         Output of failed command:"
        # Attempt to run again capturing stderr to show the error
        "$DRUSH_CMD" "$TARGET_ALIASES" pm:list --status=enabled --type=module --no-core --fields=name --format=list > /dev/null 2>&1
        drush_list_error_code=$?
        echo "         (Drush exit code: $drush_list_error_code)"
        echo "         Check Drush alias configuration, site status, and Drush version compatibility."
        # drush_list_ok remains false
    else
       enabled_count=$(wc -l < "$enabled_modules_file" | tr -d ' ')
       echo "Found $enabled_count unique enabled contrib/custom modules across discovered aliases."
       drush_list_ok=true # Set to true only on success
    fi

    # Compare lists if both files were created successfully and composer file is not empty
    if [ "$drush_list_ok" = true ] && [ -f "$composer_modules_file" ] && [ -s "$composer_modules_file" ] && [ -f "$enabled_modules_file" ]; then
      echo "Comparing lists..."
      if [ ! -s "$enabled_modules_file" ]; then
          echo "Result: No enabled contrib/custom modules found via Drush on the targeted .$TARGET_ENV aliases."
          echo "        Assuming all composer modules are potentially unused on these sites:"
          echo "---"
          cat "$composer_modules_file"
          echo "---"
      else
          unused_modules=$(comm -23 "$composer_modules_file" "$enabled_modules_file")
          if [ -z "$unused_modules" ]; then
              echo "Result: All detected composer drupal-modules (non-dev) appear to be enabled on at least one targeted .$TARGET_ENV site."
          else
              echo "Result: Modules installed via composer (non-dev) but NOT enabled on any targeted .$TARGET_ENV site:"
              echo "---"
              echo "$unused_modules"
              echo "---"
          fi
      fi
    elif [ "$drush_list_ok" = false ]; then
        echo "Warning: Could not perform comparison because fetching enabled modules via Drush failed."
    elif [ -f "$composer_modules_file" ] && [ ! -s "$composer_modules_file" ]; then
        echo "Result: No installed non-dev Drupal modules found via composer to compare."
    else
      echo "Warning: Could not perform comparison due to other errors fetching module lists."
    fi
else
    if [ -z "$TARGET_ALIASES" ]; then
        echo "Skipping comparison: No target aliases ending in .$TARGET_ENV were discovered."
    elif [ "$module_list_ok" = false ]; then
        echo "Skipping comparison: Failed to get module list from composer."
    fi
fi

echo
echo "############################################"
echo "### Check Complete ###"
echo "############################################"

exit 0
