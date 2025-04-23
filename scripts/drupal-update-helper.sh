#!/bin/bash

# -----------------------------------------------------------------------------
# Drupal Interactive Update Helper
#
# Description:
#   Checks for outdated direct Composer dependencies in a Drupal project,
#   creates a dated update branch, then interactively asks the user whether
#   to update each package one by one. Skips packages listed in a ignore file.
#   Commits each successful update individually. Finally, asks whether to push
#   the update branch.
#
# Prerequisites:
#   - bash (v4+ recommended for process substitution behavior)
#   - git
#   - composer (v1 or v2)
#   - jq (command-line JSON processor)
#
# Configuration File:
#   Create a file named '.drupal-updater-ignore' in the project root.
#   List vendor/package names to skip, one per line.
#   Lines starting with # and empty lines are ignored.
#
# Usage:
#   Place this script somewhere accessible. Make it executable (chmod +x).
#   Run it from the root directory of your Drupal project.
#   Example: ./drupal-update-helper.sh
#
#   If packaged via Composer `bin`: vendor/bin/drupal-update-helper.sh
# -----------------------------------------------------------------------------

# --- Configuration ---
# Name of the file in the project root containing packages to ignore
readonly CONFIG_FILE=".drupal-updater-ignore"
# Prefix for the update branch name
readonly BRANCH_PREFIX="update"
# Git remote name to push to
readonly REMOTE_NAME="origin"
# --- End Configuration ---

# --- Global Variables ---
# Populated by load_pinned_packages()
PINNED_PACKAGES=()
# Populated after checking git status
CURRENT_BRANCH=""
# Counter for successful updates - modified within main logic
UPDATES_PERFORMED=0
# Populated within main logic - needed by helper functions
update_branch=""

# --- Helper Functions ---

# Check if a command exists
check_command() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it." >&2
        exit 1
    fi
}

# Load pinned packages from the config file
load_pinned_packages() {
    # Ensure array is empty before loading
    PINNED_PACKAGES=()
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Loading pinned packages from '$CONFIG_FILE'..."
        # Read lines, ignore comments (#) and empty/whitespace-only lines
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Remove comments from end of line
            local pkg_line="${line%%#*}"
            # Remove leading/trailing whitespace (using parameter expansion)
            pkg_line="${pkg_line#"${pkg_line%%[![:space:]]*}"}"
            pkg_line="${pkg_line%"${pkg_line##*[![:space:]]}"}"

            if [[ -n "$pkg_line" ]]; then # If line is not empty after stripping
                PINNED_PACKAGES+=("$pkg_line")
            fi
        done < "$CONFIG_FILE"
        # Use * within quotes for safe echo of array contents
        if (( ${#PINNED_PACKAGES[@]} > 0 )); then
             echo "Pinned: ${PINNED_PACKAGES[*]}"
        else
             echo "Info: '$CONFIG_FILE' exists but contains no valid package names."
        fi
    else
        echo "Info: Config file '$CONFIG_FILE' not found. No packages will be automatically pinned."
    fi
}

# Check if a given package name is in the pinned list
is_pinned() {
    local package_name=$1
    local pinned # loop variable
    for pinned in "${PINNED_PACKAGES[@]}"; do
        if [[ "$pinned" == "$package_name" ]]; then
            return 0 # 0 means true (is pinned)
        fi
    done
    return 1 # 1 means false (is not pinned)
}

# --- Function to handle prompting for push after updates ---
handle_push_prompt() {
    # Assumes UPDATES_PERFORMED, update_branch, REMOTE_NAME are accessible from main scope
    echo "$UPDATES_PERFORMED update(s) committed to branch '$update_branch'."
    local push_confirm
    read -r -p "Do you want to push the branch '$update_branch' to remote '$REMOTE_NAME'? (y/N): " push_confirm
    if [[ "$push_confirm" =~ ^[Yy]$ ]]; then
        echo "Pushing branch..."
        if ! git push -u "$REMOTE_NAME" "$update_branch"; then
            echo "Error: 'git push' failed." >&2
        else
            echo "Branch pushed successfully."
        fi
    else
        echo "Branch not pushed."
    fi
}

# --- Function to handle the case where no updates were done ---
handle_no_updates() {
    # Assumes CURRENT_BRANCH is accessible from main scope
     echo "No updates were performed or committed."
     local switch_back_confirm
     read -r -p "Switch back to the original branch '$CURRENT_BRANCH'? (Y/n): " switch_back_confirm
     # Default to Yes (switch back) if user just hits Enter or enters 'y'/'Y'
     if [[ ! "$switch_back_confirm" =~ ^[Nn]$ ]]; then
        if ! git checkout "$CURRENT_BRANCH"; then
             echo "Warning: Failed to switch back to branch '$CURRENT_BRANCH'." >&2
        else
             echo "Switched back to branch '$CURRENT_BRANCH'."
        fi
     # else: User entered 'n' or 'N', do nothing.
     fi
}


# --- Main Script Logic ---
main() {
    # --- Sanity Checks ---
    check_command "git"
    check_command "composer"
    check_command "jq"

    # Check for uncommitted changes directly
    if ! git diff --quiet HEAD --; then
        echo "Error: Your working directory has uncommitted changes." >&2
        echo "Please commit or stash them before running this script." >&2
        exit 1
    fi

    # Get current branch name
    # Need CURRENT_BRANCH available for handle_no_updates function later
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [[ -z "$CURRENT_BRANCH" ]]; then
       echo "Error: Could not determine current git branch." >&2
       exit 1
    fi
    echo "Current branch is: $CURRENT_BRANCH"

    # --- Load Config ---
    load_pinned_packages

    # --- Get Outdated Direct Dependencies ---
    echo "Checking for outdated direct dependencies..."
    local outdated_json
    # Use process substitution <() to check command and capture output safely
    if ! outdated_json=$(composer outdated -D --no-dev --format=json); then
        echo "Error: 'composer outdated' command failed." >&2
        exit 1
    fi

    # Use jq to parse the JSON and filter for installed packages
    local outdated_packages
    if ! outdated_packages=$(echo "$outdated_json" | jq -c '.installed[] | select(.name)'); then
         echo "Error: Failed to parse composer output with jq." >&2
         exit 1
    fi

    if [[ -z "$outdated_packages" ]]; then
        echo "No outdated direct dependencies found. Exiting."
        exit 0
    fi

    echo "Found outdated packages."

    # --- Create Update Branch ---
    local date_stamp
    # Set date for branch name - using current system date when script runs
    date_stamp=$(date '+%Y-%m-%d')
    # Need update_branch available for handle_push_prompt function later
    update_branch="${BRANCH_PREFIX}/${date_stamp}"

    # Check if branch exists using rev-parse
    if git rev-parse --verify "$update_branch" &> /dev/null; then
        echo "Branch '$update_branch' already exists."
        local switch_branch_confirm
        read -r -p "Do you want to switch to it and continue? (y/N): " switch_branch_confirm
        if [[ ! "$switch_branch_confirm" =~ ^[Yy]$ ]]; then
            echo "Aborting."
            exit 1
        fi
        # Check switch success directly
        if ! git checkout "$update_branch"; then
           echo "Error switching to branch '$update_branch'. Aborting." >&2
           exit 1
        fi
    else
        echo "Creating and switching to branch '$update_branch'..."
        # Check checkout -b success directly
        if ! git checkout -b "$update_branch"; then
           echo "Error creating branch '$update_branch'. Aborting." >&2
           # Attempt to switch back to the original branch
           git checkout "$CURRENT_BRANCH" &> /dev/null
           exit 1
        fi
    fi

    echo "Switched to branch '$update_branch'."

    # --- Loop Through Updates (Using Process Substitution) ---
    echo # Blank line
    echo "----- Processing Updates -----"
    # UPDATES_PERFORMED is initialized to 0 globally
    while IFS= read -r line; do
        # Extract package details safely using jq within the loop
        local package_name current_version latest_version
        package_name=$(echo "$line" | jq -r '.name // empty')
        current_version=$(echo "$line" | jq -r '.version // empty')
        latest_version=$(echo "$line" | jq -r '.latest // empty')

        # Basic validation
        if [[ -z "$package_name" || -z "$latest_version" ]]; then
             echo "Warning: Skipping malformed line from composer output: $line" >&2
             continue
        fi

        echo # Blank line for spacing
        echo "Package:         ${package_name}"
        echo "Current version: ${current_version}"
        echo "Available:       ${latest_version}"

        # --- ADD DEBUG for is_pinned ---
        echo -n "DEBUG: Checking if '$package_name' is pinned... "
        if is_pinned "$package_name"; then
            # This branch means is_pinned returned 0 (true)
            echo "Yes (is_pinned returned true, skipping before prompt)" # Debug message
            echo "Status:          Pinned (ignored)."
            continue
        else
            # This branch means is_pinned returned non-zero (false)
            echo "No (is_pinned returned false, proceeding to prompt)" # Debug message
        fi
        # --- END DEBUG for is_pinned ---

        # Confirm update
        local confirm_update
        # Explicitly read from the terminal device, bypassing loop's stdin redirection
        # ADD "< /dev/tty" to the end of this line:
        read -r -p "Do you want to update this package? (y/N): " confirm_update < /dev/tty

        # Optional Debug line (can be kept or removed)
        # echo "DEBUG: Input read was: ->${confirm_update}<-"

        # Check if the input does NOT match exactly 'y' or 'Y'
        if [[ ! "$confirm_update" =~ ^[Yy]$ ]]; then
            echo "Status:          Skipped by user."
            continue
        fi

        # --- Perform Update ---
        echo "Attempting update..."
        if ! composer update "$package_name" --with-dependencies --no-scripts --no-dev; then
            local update_exit_code=$?
            echo "Error: Composer update failed for ${package_name} (Exit code: ${update_exit_code})." >&2
            echo "Attempting to revert changes to composer.json and composer.lock..."
            if ! git checkout -- composer.json composer.lock; then
                 echo "Warning: Failed to automatically revert composer configuration files." >&2
            else
                 echo "Reverted composer.json and composer.lock."
            fi
            echo "Skipping commit for this package."
            continue # Move to the next package
        fi

        # --- If we reached here, composer update succeeded ---
        echo "Update successful for ${package_name}."

        # Stage changes
        if ! git add composer.json composer.lock; then
            echo "Error: 'git add' failed for composer files. Manual intervention needed." >&2
            echo "Skipping commit for this package due to staging issues."
            continue
        fi

        # Commit changes, checking failure directly
        local commit_msg="Update ${package_name} to ${latest_version}"
        if ! git commit -m "$commit_msg"; then
            echo "Error: 'git commit' failed. Manual intervention may be needed." >&2
            echo "Attempting to unstage changes..."
            git reset HEAD -- composer.json composer.lock &> /dev/null
            continue # Skip to next package
        else
            echo "Committed: ${commit_msg}"
            # This increment now correctly affects the global counter
            UPDATES_PERFORMED=$((UPDATES_PERFORMED + 1))
        fi
        echo "-----------------------------"

    # Feed the while loop using Process Substitution to avoid subshell issues with UPDATES_PERFORMED
    done < <(echo "$outdated_packages")

    echo # Blank line
    echo "----- Update Summary -----"

    # --- Push Branch or Handle No Updates ---
    # Call helper functions based on whether updates were committed
    if [[ $UPDATES_PERFORMED -gt 0 ]]; then
        handle_push_prompt
    else
        handle_no_updates
    fi

    echo # Blank line
    echo "Script finished."
    echo "Remember to run database updates (drush updb) and clear caches (drush cr) on your server after deploying."

    # Exit with success
    exit 0
}

# --- Run the main function ---
# Pass any script arguments to main (though none are currently used)
main "$@"