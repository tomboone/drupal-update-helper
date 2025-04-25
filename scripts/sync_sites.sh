#!/bin/bash

# --- Configuration ---
DRUSH_CMD="vendor/bin/drush"
SITES_DIR="drush/sites"

# --- Helper Function ---
function process_site {
  local alias_file=$1
  local base_name # Declare variable
  base_name=$(basename "$alias_file" .site.yml) # Assign value separately
  local local_alias="@$base_name.local"
  local prod_alias="@$base_name.prod"

  echo "--------------------------------------------------"
  echo "Processing site: $base_name ($local_alias, $prod_alias)"
  echo "Alias file: $alias_file"
  echo "--------------------------------------------------"

  # --- 1. Sync Database ---
  echo "Syncing database from $prod_alias to $local_alias..."
  # Added -y flag
  db_sync_cmd="$DRUSH_CMD -y sql:sync $prod_alias $local_alias --extra-dump=\" | sed '1d'\""
  echo "Running: $db_sync_cmd"
  if ! eval "$db_sync_cmd"; then
      echo "Error: Database sync failed for $base_name."
      exit 1 # Exit if DB sync fails
  fi
  echo "Database sync complete for $base_name."
  echo ""

  # --- 2. Import Config Split ---
  # Extract config_split_name using Python yq (-r for raw output)
  config_split_name=$(yq -r .local.config_split_name "$alias_file")

  # Check if the value is non-empty AND not the literal string "null"
  if [ -n "$config_split_name" ] && [ "$config_split_name" != "null" ]; then
    echo "Importing config split '$config_split_name' for $local_alias..."
    # Added -y flag
    split_import_cmd="$DRUSH_CMD -y $local_alias config-split:import $config_split_name"
    echo "Running: $split_import_cmd"
    if ! eval "$split_import_cmd"; then
        echo "Warning: config-split:import failed for $base_name. Continuing..."
        # Decide if you want to 'continue' or just warn
    fi
    echo "Config split import complete for $base_name."
  else
    # Updated message to reflect the check
    echo "No 'config_split_name' found or value is null in $alias_file for the local alias. Skipping config split import."
  fi
  echo ""

  # --- 3. Sync Private Files (Conditional) ---
  # Check if the site uses private files
  uses_private_files=$(yq -r .local.uses_private_files "$alias_file")

  # Check if the value is explicitly 'true' (case-insensitive)
  if [[ "${uses_private_files,,}" == "true" ]]; then
    echo "Site uses private files. Syncing private files from $prod_alias to $local_alias..."
    # --- ACTUAL FILE SYNC COMMAND ---
    # Added -y flag
    files_sync_cmd="$DRUSH_CMD -y rsync $prod_alias:%private $local_alias:%private -- --delete"
    echo "Running: $files_sync_cmd"
    if ! eval "$files_sync_cmd"; then
        echo "Error: Private file sync failed for $base_name."
        exit 1 # Or handle error as needed
    fi
    echo "Private file sync complete for $base_name."
    # --- END OF FILE SYNC COMMAND ---
  else
    echo "Site does not use private files (uses_private_files is not 'true' or missing/null in $alias_file). Skipping private file sync."
  fi
  echo ""

  # --- 4. Clear Cache ---
  echo "Clearing cache for $local_alias..."
  # Added -y flag (though often not needed for cache:rebuild, it's safe)
  cache_clear_cmd="$DRUSH_CMD -y $local_alias cache:rebuild"
  echo "Running: $cache_clear_cmd"
  if ! eval "$cache_clear_cmd"; then
      echo "Warning: Cache rebuild failed for $base_name."
  fi
  echo "Cache clear complete for $base_name."
  echo ""

  echo "--------------------------------------------------"
  echo "Finished processing site: $base_name"
  echo "--------------------------------------------------"
  echo ""
}

# --- Main Script Logic ---
# Find all *.site.yml files in the specified directory
shopt -s nullglob # Prevent errors if no files match
alias_files=("$SITES_DIR"/*.site.yml)
shopt -u nullglob # Turn off nullglob

if [ ${#alias_files[@]} -eq 0 ]; then
  echo "No site alias files (*.site.yml) found in $SITES_DIR"
  exit 1
fi

# Loop through each alias file and process it
for file in "${alias_files[@]}"; do
  process_site "$file"
done

echo "All sites processed."
exit 0