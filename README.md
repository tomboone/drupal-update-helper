# Drupal Interactive Update Helper

**DO NOT USE THIS TOOL. This is a work-in-progress and not yet ready for production use.**

A command-line tool to interactively update Composer dependencies for a Drupal project one by one, committing each update separately.

This script helps bridge the gap between manually updating every single package and blindly running `composer update`. It streamlines the process while maintaining a granular commit history suitable for review and safe deployment.

## Features

* Identifies outdated direct Composer dependencies.
* Creates a dated Git branch (`update/YYYY-MM-DD`) for the updates.
* Loops through each outdated package (respecting an ignore list).
* Prompts for confirmation before updating each package.
* Updates the selected package and its dependencies (`composer update vendor/package --with-dependencies`).
* Commits each successful update individually with a standard message.
* Reverts `composer.json`/`composer.lock` changes if an update fails for a single package.
* Prompts to push the completed update branch to your remote repository.

## Prerequisites

This script requires the following command-line tools to be installed on your system **before** use:

* **bash** (v4+ recommended for reliable variable scope handling)
* **git**
* **composer** (v1 or v2)
* **jq** (command-line JSON processor)

## Installation

You can add this script as a development dependency to your Drupal project using Composer.

**1. Using Packagist (if published):**

```bash
composer require --dev tomboone/drupal-update-helper
```

## Usage

1. Navigate to the root directory of your Drupal project in your terminal.
2. Ensure your Git working directory is clean (no uncommitted changes).
3. Run the script:
    ```bash
    vendor/bin/drupal-update-helper
    ```
4. Follow the prompts:
   * The script will detect outdated packages.
   * It will create/switch to an `update/YYYY-MM-DD` branch.
   * It will loop through outdated, non-ignored packages.
   * For each package, it will ask for confirmation (`y/N`) to update.
   * If confirmed 'y' and the `composer update` succeeds, it will create a Git commit.
   * If the update fails, it will attempt to revert config changes and skip the commit.
   *After the loop, if updates were committed, it will ask (`y/N`) whether to push the branch to `origin` (or your configured remote).

## Configuration: Skipping Packages
To prevent the script from offering updates for specific packages (e.g., core patches, packages with known issues, themes you manage manually), create a file named `.drupal-updater-ignore` in the root directory of your Drupal project.

* List one package `vendor/package` name per line.
* Lines starting with `#` are treated as comments and ignored.
* Blank lines are ignored.

**Example `.drupal-updater-ignore` file:**

```sh
# Ignore core patches or recommendations if managed separately
drupal/core-recommended
drupal/core-composer-scaffold

# Ignore specific contrib modules/themes
drupal/some_module_with_issues
drupal/my_custom_theme_dependency

# vendor/some-library
```
The script will print the list of pinned/ignored packages it detects when it starts.

## Important Notes

* Run from Project Root: Always execute the script from the main directory of your Drupal project where the root `composer.json` resides.
* Clean Git Status: The script requires a clean working directory to avoid conflicts.
* Database Updates / Cache Clear: This script does not run `drush updb` or `drush cr`. You must run these commands on your server environment after deploying the code updates.
* Testing: Thoroughly test your site(s) after applying updates, especially on a staging environment before deploying to production.
* Backups: Always ensure you have working backups (code, database, files, VM snapshots) before performing updates.

## License

* This script is licensed under the MIT . See the [LICENSE](LICENSE) file for details.