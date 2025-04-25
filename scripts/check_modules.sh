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

# --- Unused Composer Modules & Themes ---
echo # Blank line
echo "--- Checking for Composer Modules/Themes Not Enabled Anywhere on discovered .$TARGET_ENV aliases ---"

# Define temp files
composer_extensions_file=$(mktemp)
all_installed_types_json=$(mktemp)
installed_module_names_file=$(mktemp)
installed_theme_names_file=$(mktemp)
composer_modules_file=$(mktemp)
composer_themes_file=$(mktemp)
enabled_modules_temp_file=$(mktemp)
enabled_themes_temp_file=$(mktemp)
sorted_enabled_modules_file=$(mktemp)
sorted_enabled_themes_file=$(mktemp)

# Ensure cleanup on exit
trap 'rm -f "$composer_extensions_file" "$all_installed_types_json" "$installed_module_names_file" "$installed_theme_names_file" "$composer_modules_file" "$composer_themes_file" "$enabled_modules_temp_file" "$enabled_themes_temp_file" "$sorted_enabled_modules_file" "$sorted_enabled_themes_file"' EXIT

# Initialize status flags
composer_list_ok=false
type_list_ok=false
drush_enabled_list_ok=false

# 1. Get Composer extensions (installed, non-dev, drupal/*, excluding drupal/core*)
echo "Getting installed Drupal extensions from composer (excluding core)..."
if ! composer show --no-dev --name-only | grep '^drupal/' | grep -v '^drupal/core' | sed 's/^drupal\///' | sort > "$composer_extensions_file"; then
    echo "Error: Failed to get installed Drupal extensions via composer."
else
    extension_count=$(wc -l < "$composer_extensions_file" | tr -d ' ')
    if [ "$extension_count" -gt 0 ]; then
        echo "Found $extension_count installed non-dev contrib/custom extensions via composer (excluding core)."
        composer_list_ok=true
    else
        echo "Result: No installed non-dev Drupal extensions found via composer (excluding core) to check."
        # No need to proceed further in this section
        exit 0 # Or continue if other script sections follow
    fi
fi

# 2. Get Extension Types locally using Drush + jq
if [ "$composer_list_ok" = true ]; then
    echo "Getting extension types locally via Drush..."
    # Run drush pm:list locally to get types. Assumes local env reflects installed code.
    if ! drush pm:list --no-core --format=json > "$all_installed_types_json"; then
        echo "Error: Failed to get local extension types via 'drush pm:list --format=json'."
    else
        # Use jq to extract module names
        if jq -r 'to_entries[] | select(.value.type == "module") | .key' "$all_installed_types_json" | sort > "$installed_module_names_file"; then
            # Use jq to extract theme names
            if jq -r 'to_entries[] | select(.value.type == "theme") | .key' "$all_installed_types_json" | sort > "$installed_theme_names_file"; then
                type_list_ok=true
                echo "Successfully parsed local module and theme types."
            else
                echo "Error: Failed to parse theme names using jq."
            fi
        else
            echo "Error: Failed to parse module names using jq."
        fi
    fi
fi

# 3. Filter Composer List into Modules and Themes
if [ "$composer_list_ok" = true ] && [ "$type_list_ok" = true ]; then
    echo "Categorizing composer extensions into modules and themes..."
    # Find composer extensions that are modules
    comm -12 "$composer_extensions_file" "$installed_module_names_file" > "$composer_modules_file"
    # Find composer extensions that are themes
    comm -12 "$composer_extensions_file" "$installed_theme_names_file" > "$composer_themes_file"

    module_count=$(wc -l < "$composer_modules_file" | tr -d ' ')
    theme_count=$(wc -l < "$composer_themes_file" | tr -d ' ')
    echo "Identified $module_count potential modules and $theme_count potential themes from composer list."
fi

# 4. Get Enabled Extensions from Aliases
# Get the list of target aliases
echo "Discovering target Drush aliases (ending with .$TARGET_ENV)..."
all_aliases_output=$("$DRUSH_CMD" site:alias --format=list 2>&1)
drush_alias_exit_code=$?
TARGET_ALIAS_LIST=() # Initialize as an array

if [ $drush_alias_exit_code -ne 0 ]; then
    echo "Error: Failed to list Drush site aliases (Exit code: $drush_alias_exit_code)."
    echo "$all_aliases_output"
else
    while IFS= read -r line; do
        TARGET_ALIAS_LIST+=("$line")
    done < <(echo "$all_aliases_output" | grep -E "$ALIAS_PATTERN")
fi

if [ ${#TARGET_ALIAS_LIST[@]} -eq 0 ]; then
    echo "Warning: No Drush aliases found matching the pattern '$ALIAS_PATTERN'."
    echo "         Skipping check for unused modules/themes across sites."
else
    echo "Targeting dynamically discovered aliases: ${TARGET_ALIAS_LIST[*]}"
fi
echo

# Proceed only if target aliases were found and previous steps are ok
if [ ${#TARGET_ALIAS_LIST[@]} -gt 0 ] && [ "$composer_list_ok" = true ] && [ "$type_list_ok" = true ]; then
    echo "Getting enabled modules and themes from discovered aliases via Drush..."
    # Clear/create the temp files first
    true > "$enabled_modules_temp_file"
    true > "$enabled_themes_temp_file"
    drush_list_failed_for_any=false

    for site_alias in "${TARGET_ALIAS_LIST[@]}"; do
        echo "  Checking alias: $site_alias"
        # Get enabled MODULES for this alias
        if ! "$DRUSH_CMD" "$site_alias" pm:list --status=enabled --type=module --no-core --fields=name --format=list >> "$enabled_modules_temp_file"; then
            echo "  Warning: Failed to get enabled modules via Drush for alias $site_alias."
            drush_list_failed_for_any=true
        fi
        # Get enabled THEMES for this alias
        if ! "$DRUSH_CMD" "$site_alias" pm:list --status=enabled --type=theme --no-core --fields=name --format=list >> "$enabled_themes_temp_file"; then
            echo "  Warning: Failed to get enabled themes via Drush for alias $site_alias."
            drush_list_failed_for_any=true
        fi
    done

    # 5. Process Enabled Lists
    echo "Processing combined lists of enabled modules and themes..."
    # Process Modules
    if sort "$enabled_modules_temp_file" | uniq > "$sorted_enabled_modules_file"; then
        enabled_module_count=$(wc -l < "$sorted_enabled_modules_file" | tr -d ' ')
        echo "Found $enabled_module_count unique enabled contrib/custom modules across discovered aliases."
    else
        echo "Error: Failed to sort/uniq the combined enabled modules list."
        drush_list_failed_for_any=true # Mark as failed if sort fails
    fi
    # Process Themes
    if sort "$enabled_themes_temp_file" | uniq > "$sorted_enabled_themes_file"; then
        enabled_theme_count=$(wc -l < "$sorted_enabled_themes_file" | tr -d ' ')
        echo "Found $enabled_theme_count unique enabled contrib/custom themes across discovered aliases."
    else
        echo "Error: Failed to sort/uniq the combined enabled themes list."
        drush_list_failed_for_any=true # Mark as failed if sort fails
    fi

    # Set overall success flag for Drush lists
    if [ "$drush_list_failed_for_any" = false ]; then
        drush_enabled_list_ok=true
    else
        echo "Warning: Failed to get or process enabled modules/themes for one or more aliases or steps."
    fi

    # 6. Compare Modules
    echo # Blank line
    echo "----- Unused Modules Report -----"
    if [ "$drush_enabled_list_ok" = true ] && [ -s "$composer_modules_file" ]; then
        unused_modules=$(comm -23 "$composer_modules_file" "$sorted_enabled_modules_file")
        if [ -z "$unused_modules" ]; then
            echo "Result: All detected composer modules (non-dev, excluding core) appear to be enabled on at least one targeted .$TARGET_ENV site."
        else
            echo "Result: Modules installed via composer (non-dev, excluding core) but NOT enabled on any targeted .$TARGET_ENV site:"
            echo "---"
            echo "$unused_modules"
            echo "---"
        fi
    elif [ ! -s "$composer_modules_file" ]; then
         echo "Result: No composer modules (non-dev, excluding core) found to compare."
    else
         echo "Warning: Could not perform module comparison due to errors fetching/processing enabled module lists."
    fi

    # 7. Compare Themes
    echo # Blank line
    echo "----- Unused Themes Report -----"
     if [ "$drush_enabled_list_ok" = true ] && [ -s "$composer_themes_file" ]; then
        unused_themes=$(comm -23 "$composer_themes_file" "$sorted_enabled_themes_file")
        if [ -z "$unused_themes" ]; then
            echo "Result: All detected composer themes (non-dev, excluding core) appear to be enabled on at least one targeted .$TARGET_ENV site."
        else
            echo "Result: Themes installed via composer (non-dev, excluding core) but NOT enabled on any targeted .$TARGET_ENV site:"
            echo "---"
            echo "$unused_themes"
            echo "---"
        fi
    elif [ ! -s "$composer_themes_file" ]; then
         echo "Result: No composer themes (non-dev, excluding core) found to compare."
    else
         echo "Warning: Could not perform theme comparison due to errors fetching/processing enabled theme lists."
    fi

else
    # Handle cases where comparison couldn't start
    if [ ${#TARGET_ALIAS_LIST[@]} -eq 0 ]; then
        echo "Skipping comparison: No target aliases ending in .$TARGET_ENV were discovered."
    elif [ "$composer_list_ok" = false ]; then
        echo "Skipping comparison: Failed to get initial list of composer extensions."
    elif [ "$type_list_ok" = false ]; then
        echo "Skipping comparison: Failed to determine extension types locally."
    else
        # This case shouldn't be reached if the main 'if' condition was false,
        # but included for completeness.
        echo "Skipping comparison due to an unexpected issue."
    fi
fi

echo "-------------------------------------"
echo # Blank line

# Cleanup is handled by the trap

echo
echo "############################################"
echo "### Check Complete ###"
echo "############################################"

exit 0
