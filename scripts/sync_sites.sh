#!/bin/bash

# Define the path to the Drush alias files relative to the script's execution directory (project root)
DRUSH_SITES_DIR="drush/sites"
DRUSH_CMD="vendor/bin/drush"

# Check if the sites directory exists
if [ ! -d "$DRUSH_SITES_DIR" ]; then
  echo "Error: Drush sites directory not found at '$DRUSH_SITES_DIR'"
  exit 1
fi

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo "Error: 'yq' command not found. Please install yq (e.g., 'brew install yq')."
    exit 1
fi

# Iterate over each .site.yml file
for alias_file in "$DRUSH_SITES_DIR"/*.site.yml; do
  if [ -f "$alias_file" ]; then
    # Extract the base name (e.g., 'expertise' from 'expertise.site.yml')
    base_name=$(basename "$alias_file" .site.yml)
    local_alias="@$base_name.local"
    prod_alias="@$base_name.prod"

    echo "--------------------------------------------------"
    echo "Processing site: $base_name ($local_alias, $prod_alias)"
    echo "Alias file: $alias_file"
    echo "--------------------------------------------------"

    # --- 1. Sync Database ---
    echo "Syncing database from $prod_alias to $local_alias..."
    sync_cmd="$DRUSH_CMD sql:sync $prod_alias $local_alias --extra-dump=\" | sed '1d'\""
    echo "Running: $sync_cmd"
    # Execute the command allowing interaction and check exit status directly
    if ! eval "$sync_cmd"; then
        echo "Error during sql:sync for $base_name. Skipping remaining steps for this site."
        continue # Skip to the next site
    fi
    echo "Database sync complete for $base_name."
    echo ""

    # --- 2. Import Config Split ---
    # Extract config_split_name using yq
    config_split_name=$(yq e '.local.config_split_name // ""' "$alias_file") # Use // "" to default to empty string if not found

    if [ -n "$config_split_name" ]; then
      echo "Importing config split '$config_split_name' for $local_alias..."
      split_import_cmd="$DRUSH_CMD $local_alias config-split:import $config_split_name"
      echo "Running: $split_import_cmd"
      if ! eval "$split_import_cmd"; then
          echo "Warning: config-split:import failed for $base_name. Continuing..."
          # Decide if you want to 'continue' or just warn
      fi
      echo "Config split import complete for $base_name."
    else
      echo "No 'config_split_name' found in $alias_file for the local alias. Skipping config split import."
    fi
    echo ""

    # --- 3. Sync Public Files ---
    echo "Syncing public files (%files) from $prod_alias to $local_alias..."
    files_sync_cmd="$DRUSH_CMD core:rsync $prod_alias:%files $local_alias:%files"
    echo "Running: $files_sync_cmd"
    if ! eval "$files_sync_cmd"; then
        echo "Warning: core:rsync for public files failed for $base_name. Continuing..."
        # Decide if you want to 'continue' or just warn
    fi
    echo "Public file sync complete for $base_name."
    echo ""

    # --- 4. Sync Private Files (Gracefully handle errors) ---
    echo "Syncing private files (%private) from $prod_alias to $local_alias..."
    private_sync_cmd="$DRUSH_CMD core:rsync $prod_alias:%private $local_alias:%private"
    echo "Running: $private_sync_cmd"
    # Run the command and check its status directly, but don't stop the script on failure
    if ! eval "$private_sync_cmd"; then
        echo "Note: core:rsync for private files failed or skipped (this might be expected if the site has no private files)."
    else
        echo "Private file sync complete for $base_name."
    fi
    echo ""

    echo "Finished processing site: $base_name"
    echo "--------------------------------------------------"
    echo ""

  fi
done

echo "All sites processed."
