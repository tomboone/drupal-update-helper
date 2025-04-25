#!/bin/bash

# -----------------------------------------------------------------------------
# Drupal Interactive Update Helper v2
#
# Description:
#   Checks for outdated Composer dependencies in a Drupal project.
#   1. Reports all available updates (grouped, respecting ignore file).
#   2. Creates a dated update branch.
#   3. Interactively asks the user whether to update each *direct* dependency.
#   4. If an update doesn't result in file changes, runs 'composer why-not'.
#   5. Commits each successful update individually (including code changes).
#   6. Reports successfully updated packages and packages not updated (with reasons).
#   7. Asks whether to push the update branch.
#
# Prerequisites:
#   - bash (v4+ recommended)
#   - git
#   - composer (v1 or v2)
#   - jq (command-line JSON processor)
#   - Must be run from the project root directory.
#   - Requires an interactive terminal (TTY).
#
# Configuration File:
#   Create a file named '.drupal-updater-ignore' in the project root.
#   List vendor/package names to skip, one per line.
#   Lines starting with # and empty lines are ignored.
#
# Usage:
#   From project root: vendor/bin/update_modules.sh
# -----------------------------------------------------------------------------

# --- Configuration ---
readonly CONFIG_FILE=".drupal-updater-ignore"
readonly BRANCH_PREFIX="update"
readonly REMOTE_NAME="origin"
# --- End Configuration ---

# --- Global Variables ---
PINNED_PACKAGES=()
CURRENT_BRANCH=""
UPDATES_PERFORMED=0
update_branch=""

# Arrays for final reporting
declare -a UPDATED_drupal=()
declare -a UPDATED_other=()
declare -a NOT_UPDATED_drupal=()
declare -a NOT_UPDATED_other=()

# --- Helper Functions ---

check_command() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it." >&2
        exit 1
    fi
}

load_pinned_packages() {
    PINNED_PACKAGES=()
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Loading pinned packages from '$CONFIG_FILE'..."
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Remove comments and trim whitespace
            local pkg_line="${line%%#*}"
            pkg_line="${pkg_line#"${pkg_line%%[![:space:]]*}"}"
            pkg_line="${pkg_line%"${pkg_line##*[![:space:]]}"}"
            if [[ -n "$pkg_line" ]]; then
                PINNED_PACKAGES+=("$pkg_line")
            fi
        done < "$CONFIG_FILE"
        if (( ${#PINNED_PACKAGES[@]} == 0 )); then
             echo "Info: '$CONFIG_FILE' exists but contains no valid package names to ignore."
        fi
    else
        echo "Info: Config file '$CONFIG_FILE' not found. No packages will be automatically ignored."
    fi
}

is_pinned() {
    local package_name=$1
    local pinned
    for pinned in "${PINNED_PACKAGES[@]}"; do
        if [[ "$pinned" == "$package_name" ]]; then
            return 0 # True (is pinned)
        fi
    done
    return 1 # False (is not pinned)
}

# Function to add package info to the correct final report array
add_to_report() {
    local list_type=$1 # "updated" or "not_updated"
    local package_name=$2
    local reason_details=$3 # e.g., "-> 1.2.3", " (pinned)", " (skipped)", " (failed)", " (no changes/constraints)"

    local report_string="${package_name}${reason_details}"

    if [[ "$package_name" == drupal/* ]]; then
        if [[ "$list_type" == "updated" ]]; then
            UPDATED_drupal+=("$report_string")
        else
            NOT_UPDATED_drupal+=("$report_string")
        fi
    else
        if [[ "$list_type" == "updated" ]]; then
            UPDATED_other+=("$report_string")
        else
            NOT_UPDATED_other+=("$report_string")
        fi
    fi
}


handle_push_prompt() {
    echo "$UPDATES_PERFORMED update(s) committed to branch '$update_branch'."
    local push_confirm
    read -r -p "Do you want to push the branch '$update_branch' to remote '$REMOTE_NAME'? (y/N): " push_confirm < /dev/tty
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

handle_no_updates() {
     echo "No updates were performed or committed."
     local switch_back_confirm
     read -r -p "Switch back to the original branch '$CURRENT_BRANCH'? (Y/n): " switch_back_confirm < /dev/tty
     if [[ ! "$switch_back_confirm" =~ ^[Nn]$ ]]; then
        if ! git checkout "$CURRENT_BRANCH"; then
             echo "Warning: Failed to switch back to branch '$CURRENT_BRANCH'." >&2
        else
             echo "Switched back to branch '$CURRENT_BRANCH'."
             # Optionally delete the empty update branch
             local delete_branch_confirm
             read -r -p "Delete the unused update branch '$update_branch'? (y/N): " delete_branch_confirm < /dev/tty
             if [[ "$delete_branch_confirm" =~ ^[Yy]$ ]]; then
                 if git branch -D "$update_branch"; then
                     echo "Deleted branch '$update_branch'."
                 else
                     echo "Warning: Failed to delete branch '$update_branch'." >&2
                 fi
             fi
        fi
     fi
}

# --- Main Script Logic ---
main() {
    # --- Sanity Checks ---
    check_command "git"
    check_command "composer"
    check_command "jq"

    if ! git diff --quiet HEAD --; then
        echo "Error: Your working directory has uncommitted changes." >&2
        echo "Please commit or stash them before running this script." >&2
        exit 1
    fi

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [[ -z "$CURRENT_BRANCH" ]]; then
       echo "Error: Could not determine current git branch." >&2
       exit 1
    fi
    echo "Current branch is: $CURRENT_BRANCH"

    # --- Load Config ---
    load_pinned_packages

# --- Initial Report of ALL Outdated Dependencies ---
    echo # Blank line
    echo "----- Initial Report: Available Updates (Direct Dependencies Only) -----"
    echo "Checking for DIRECTLY required outdated dependencies (excluding dev)..."
    local direct_outdated_json # Renamed from all_outdated_json
    # Use --no-dev AND --direct (-D) for this report
    if ! direct_outdated_json=$(composer outdated --no-dev --direct --format=json); then
        echo "Error: 'composer outdated --direct' command failed while generating initial report." >&2
        exit 1
    fi

    local direct_outdated_packages # Renamed from all_outdated_packages
    # Select only installed packages that have a name
    if ! direct_outdated_packages=$(echo "$direct_outdated_json" | jq -c '.installed[] | select(.name)'); then
         echo "Error: Failed to parse composer output for the initial report using jq." >&2
         # Optionally print the raw JSON for debugging: echo "$direct_outdated_json"
         exit 1
    fi

    if [[ -z "$direct_outdated_packages" ]]; then
        echo "Result: No outdated *direct* dependencies found (excluding dev)."
        # No need to proceed further if nothing is outdated
        exit 0
    else
        echo "Found outdated direct dependencies (excluding dev):"
        local drupal_updates=()
        local other_updates=()
        local pinned_skipped_count=0

        # Process each package line from jq output
        while IFS= read -r pkg_json; do
            local name version latest latest_status # Removed 'direct' and 'description'
            name=$(echo "$pkg_json" | jq -r '.name')
            version=$(echo "$pkg_json" | jq -r '.version')
            latest=$(echo "$pkg_json" | jq -r '.latest')
            latest_status=$(echo "$pkg_json" | jq -r '.latestStatus // ""') # Use default empty string if null

            local report_line="$name ($version -> $latest)"
            # Only append latest_status if it's not empty
            if [[ -n "$latest_status" && "$latest_status" != "null" ]]; then
                 report_line+=" [$latest_status]"
            fi
            # Removed the check for 'direct' flag as we only fetch direct ones now

            if is_pinned "$name"; then
                report_line+=" [Pinned/Ignored]"
                ((pinned_skipped_count++))
            fi

            if [[ "$name" == drupal/* ]]; then
                drupal_updates+=("$report_line")
            else
                other_updates+=("$report_line")
            fi
        done <<< "$direct_outdated_packages" # Use <<< for here-string

        # Print grouped updates
        if (( ${#drupal_updates[@]} > 0 )); then
            echo "  Drupal Packages:"
            printf "    %s\n" "${drupal_updates[@]}"
        fi
        if (( ${#other_updates[@]} > 0 )); then
            echo "  Other Packages:"
            printf "    %s\n" "${other_updates[@]}"
        fi
        if (( pinned_skipped_count > 0 )); then
            echo "  ($pinned_skipped_count package(s) marked as pinned/ignored in '$CONFIG_FILE')"
        fi
    fi
    echo "---------------------------------------------"
    echo # Blank line


    # --- Get DIRECT Outdated Dependencies for Interactive Update ---
    echo "Checking for DIRECTLY required outdated dependencies to update..."
    local direct_outdated_json
    # Use --direct (-D) and --no-dev for the interactive part
    if ! direct_outdated_json=$(composer outdated --no-dev --direct --format=json); then
        echo "Error: 'composer outdated --direct' command failed." >&2
        exit 1
    fi

    local direct_outdated_packages
    if ! direct_outdated_packages=$(echo "$direct_outdated_json" | jq -c '.installed[] | select(.name)'); then
         echo "Error: Failed to parse composer output for direct dependencies using jq." >&2
         exit 1
    fi

    if [[ -z "$direct_outdated_packages" ]]; then
        echo "Result: No *directly required* outdated dependencies found to update interactively."
        # Even if indirect are outdated, we only interactively update direct ones.
        # The initial report already showed everything.
        exit 0
    fi

    # --- Create Update Branch ---
    local today
    today=$(date +%Y-%m-%d)
    update_branch="${BRANCH_PREFIX}/${today}"

    echo # Blank line
    echo "Creating update branch: $update_branch"
    if git rev-parse --verify "$update_branch" > /dev/null 2>&1; then
        echo "Warning: Branch '$update_branch' already exists."
        local overwrite_confirm
        read -r -p "Do you want to check it out and potentially overwrite it? (y/N): " overwrite_confirm < /dev/tty
        if [[ ! "$overwrite_confirm" =~ ^[Yy]$ ]]; then
            echo "Aborting update process."
            exit 1
        fi
        if ! git checkout "$update_branch"; then
            echo "Error: Failed to checkout existing branch '$update_branch'." >&2
            exit 1
        fi
        # Optional: Reset the branch if needed, but be careful
        # read -p "Reset '$update_branch' to match '$CURRENT_BRANCH'? (y/N): " reset_confirm < /dev/tty
        # if [[ "$reset_confirm" =~ ^[Yy]$ ]]; then
        #    git reset --hard "$CURRENT_BRANCH" || exit 1
        # fi
    else
        if ! git checkout -b "$update_branch"; then
            echo "Error: Failed to create and checkout branch '$update_branch'." >&2
            exit 1
        fi
    fi
    echo "Switched to branch '$update_branch'."

# --- Interactive Update Loop ---
    echo # Blank line
    echo "----- Interactive Update Process -----"
    echo "Processing DIRECTLY required outdated dependencies..."

    while IFS= read -r pkg_json; do
        local name version latest latest_status
        name=$(echo "$pkg_json" | jq -r '.name')
        version=$(echo "$pkg_json" | jq -r '.version')
        latest=$(echo "$pkg_json" | jq -r '.latest')
        latest_status=$(echo "$pkg_json" | jq -r '.latestStatus')

        echo # Blank line
        echo "--- Package: $name ---"
        echo "  Current Version: $version"
        echo "  Latest Version:  $latest ($latest_status)"

        # Check if pinned
        if is_pinned "$name"; then
            echo "  Status: Pinned/Ignored in '$CONFIG_FILE'. Skipping."
            add_to_report "not_updated" "$name" " (pinned)"
            continue
        fi

        # Ask user
        local update_confirm
        read -r -p "  Update '$name' to '$latest'? (Y/n/s) (Yes/No/Skip): " update_confirm < /dev/tty
        update_confirm=${update_confirm:-Y} # Default to Yes if Enter is pressed

        if [[ "$update_confirm" =~ ^[Nn]$ ]]; then
            echo "  Skipping update for '$name' based on user input."
            add_to_report "not_updated" "$name" " (skipped by user)"
            continue
        elif [[ "$update_confirm" =~ ^[Ss]$ ]]; then
             echo "  Skipping update for '$name' for this run."
             add_to_report "not_updated" "$name" " (skipped by user)"
             continue
        elif [[ ! "$update_confirm" =~ ^[Yy]$ ]]; then
            echo "  Invalid input. Skipping update for '$name'."
            add_to_report "not_updated" "$name" " (invalid input)"
            continue
        fi

        # Perform update
        echo "  Attempting update: composer update $name --with-dependencies"
        if ! composer update "$name" --with-dependencies; then
            echo "  Error: 'composer update $name' failed." >&2
            echo "  Attempting to revert changes..."
            # Simple revert: reset composer.lock and vendor
            if git checkout -- composer.lock && composer install --no-dev --no-interaction; then
                 echo "  Reverted composer.lock and ran composer install."
            else
                 echo "  Warning: Failed to automatically revert changes for $name. Manual check needed." >&2
            fi
            add_to_report "not_updated" "$name" " (update failed)"
            continue # Move to the next package
        fi

        # Check specifically for changes in composer.json or composer.lock
        if git diff --quiet HEAD -- composer.json composer.lock; then
            # No changes in composer.json or composer.lock, even if update command succeeded
            echo "  Warning: Update command succeeded but composer.json and composer.lock were not modified."
            echo "  This might indicate the package was already up-to-date due to constraints."
            echo "  Running 'composer why-not $name $latest' for more info..."
            composer why-not "$name" "$latest" # Show why the specific version might not be installable
            add_to_report "not_updated" "$name" " (no lock file changes/constraints)"

            # Reset any potential changes in vendor/ (like installed.php)
            echo "  Resetting potential changes in vendor/ directory..."
            if ! git checkout -- vendor/; then
                echo "  Warning: Failed to automatically reset changes in vendor/. Manual check might be needed." >&2
            fi
            # No commit needed if no meaningful changes
        else
            # composer.json or composer.lock WAS modified, proceed with commit
            echo "  Update successful. Staging changes..."
            git add composer.json composer.lock
            # Add other potential changes if necessary, e.g., patches applied
            # git add patches/

            echo "  Committing update for $name..."
            local commit_message="Update $name to $latest"
            # Use --no-verify to skip git hooks if they interfere after partial vendor reset
            if ! git commit --no-verify -m "$commit_message"; then
                echo "  Error: 'git commit' failed for $name." >&2
                echo "  Attempting to unstage changes..."
                git reset HEAD -- composer.json composer.lock # patches/ if added
                add_to_report "not_updated" "$name" " (commit failed)"
            else
                echo "  Commit successful for $name."
                ((UPDATES_PERFORMED++))
                add_to_report "updated" "$name" " -> $latest"
            fi
        fi

    done <<< "$direct_outdated_packages" # Use <<< for here-string

    # --- Final Report ---
    echo # Blank line
    echo "============================================="
    echo "Update Process Summary"
    echo "============================================="

    # Sort the report arrays alphabetically
    mapfile -t SORTED_UPDATED_drupal < <(printf "%s\n" "${UPDATED_drupal[@]}" | sort)
    mapfile -t SORTED_UPDATED_other < <(printf "%s\n" "${UPDATED_other[@]}" | sort)
    mapfile -t SORTED_NOT_UPDATED_drupal < <(printf "%s\n" "${NOT_UPDATED_drupal[@]}" | sort)
    mapfile -t SORTED_NOT_UPDATED_other < <(printf "%s\n" "${NOT_UPDATED_other[@]}" | sort)


    if (( ${#SORTED_UPDATED_drupal[@]} > 0 )) || (( ${#SORTED_UPDATED_other[@]} > 0 )); then
        echo "Successfully Updated Packages:"
        if (( ${#SORTED_UPDATED_drupal[@]} > 0 )); then
            echo "  Drupal:"
            printf "    - %s\n" "${SORTED_UPDATED_drupal[@]}"
        fi
         if (( ${#SORTED_UPDATED_other[@]} > 0 )); then
            echo "  Other:"
            printf "    - %s\n" "${SORTED_UPDATED_other[@]}"
        fi
    else
         echo "No packages were successfully updated and committed."
    fi

    echo # Blank line

    if (( ${#SORTED_NOT_UPDATED_drupal[@]} > 0 )) || (( ${#SORTED_NOT_UPDATED_other[@]} > 0 )); then
        echo "Packages Not Updated:"
         if (( ${#SORTED_NOT_UPDATED_drupal[@]} > 0 )); then
            echo "  Drupal:"
            printf "    - %s\n" "${SORTED_NOT_UPDATED_drupal[@]}"
        fi
         if (( ${#SORTED_NOT_UPDATED_other[@]} > 0 )); then
            echo "  Other:"
            printf "    - %s\n" "${SORTED_NOT_UPDATED_other[@]}"
        fi
    else
        echo "All attempted packages were updated." # This might be slightly inaccurate if some were skipped before attempt
    fi
    echo "============================================="
    echo # Blank line


    # --- Post-Update Actions ---
    if (( UPDATES_PERFORMED > 0 )); then
        handle_push_prompt
    else
        handle_no_updates
    fi

    echo # Blank line
    echo "Update script finished."
}

# --- Run Main ---
# Wrap in a function call to ensure variables are local unless explicitly global
main

exit 0
