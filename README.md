# Drupal Update Helper Suite

(STILL DEBUGGING. DO NOT USE YET.)

 This repository contains a suite of helper scripts designed to assist with common update and maintenance tasks for Composer-managed Drupal projects, particularly focusing on dependency updates and multisite installations.

 ---

 ## Interactive Dependency Updater (`vendor/bin/composer-update-helper`)

 This script provides an interactive way to update your Drupal project's direct Composer dependencies one package at a time, creating a separate Git commit for each successful update.

 ### Overview / Purpose

 Use this script when you want granular control over the update process, allowing you to test and review changes incrementally, rather than applying all available updates at once.

 * Identifies outdated direct dependencies using `composer outdated`.
 * Creates a dated Git branch (`update/YYYY-MM-DD`, using the current date) for the updates.
 * Loops through each available update, skipping packages listed in `.drupal-updater-ignore`.
 * Prompts (`y/N`) for confirmation before attempting to update each package.
 * Runs `composer update [package-name] --with-dependencies` for confirmed packages.
 * Detects common Composer failures (like authentication issues or issues related to vendored `.git` directories) and provides guidance.
 * Determines the installation path of the updated package using `composer show --path`.
 * Stages `composer.json`, `composer.lock`, and the updated package code directory.
 * Skips the commit step gracefully if Composer didn't actually make changes (e.g., due to version constraints).
 * Commits each successful update individually.
 * Prompts whether to push the completed branch to your Git remote (`origin`).

 ### Prerequisites

 Executing this script requires the following tools to be available in your environment (native or inside Docker):

 * **bash** (v4+ recommended)
 * **git**
 * **composer** (v1 or v2)
 * **jq** (command-line JSON processor)

 ### Usage

 1.  **Navigate** to your Drupal **project root directory** in your terminal (the one containing the main `composer.json`).
 2.  **Ensure** your Git working directory is clean (`git status` should show no uncommitted changes).
 3.  **Execute** the script. If running within Docker, you **must** use flags to allocate an interactive terminal (`-it`):
     ```bash
     # Native environment:
     vendor/bin/composer-update-helper.sh

     # Inside Docker (example):
     docker exec -it [-e COMPOSER_AUTH='...'] your_container_name vendor/bin/composer-update-helper.sh
     ```
     *(Note: Pass `COMPOSER_AUTH` environment variable if GitHub authentication is needed).*
 4.  **Follow Prompts:** The script will guide you through creating a branch and confirming (`y/N`) updates for each detected package not listed in your ignore file.
 5.  **Review Output:** Pay attention to messages indicating success, skipped commits (e.g., due to constraints), or Composer failures.
 6.  **Push (Optional):** Decide whether to push the update branch when prompted at the end.

 ### Configuration (`.drupal-updater-ignore`)

 To prevent the script from offering updates for certain packages, create a file named `.drupal-updater-ignore` in your project root directory.

 * List one `vendor/package` name per line.
 * Lines starting with `#` and blank lines are ignored.

 **Example:**

 ```
 # .drupal-updater-ignore
 # Core stuff if managed separately
 drupal/core-recommended
 drupal/core-composer-scaffold

 # Modules/Themes to skip
 drupal/module_with_patches
 drupal/custom_theme_dependency
 some-vendor/some-library
 ```

 ### Special Error Handling

 This script includes specific detection for a common Composer error (`The .git directory is missing...`) that can occur in workflows where vendored dependencies have their `.git` folders renamed (e.g., to `.git_`). If this specific error is detected, the script will provide tailored instructions guiding you on how to manually fix the affected package's state (usually involving `rm -rf` and `composer install` for that package) before you can proceed.

 ### Important Notes

 * **Run from Project Root:** Essential for Composer and Git commands to function correctly.
 * **Clean Git Status Required:** Prevents accidental inclusion of unrelated changes.
 * **Interactive Terminal Required:** The script relies on `read` prompts and needs a TTY (use `-it` in Docker).
 * **DB Updates / Cache Clear:** This script **does not** run `drush updb` or `drush cr`. You must handle database updates and cache clearing separately after deploying the code changes.
 * **Testing:** Always test updates thoroughly, preferably in a staging environment.
 * **Backups:** Ensure you have reliable backups before running any update process.

 ---

 ## Multisite Module Status Check (`vendor/bin/check_modules`)

 This script provides a command-line utility to assess the status of contributed modules within a Drupal multisite installation managed by Composer, focusing on available updates and potentially unused modules.

 ### Overview / Purpose

 * Checks the shared codebase for available **security updates** using `drush pm:security`.
 * Checks the shared codebase for available **general updates** (minor/major) using `drush pm:update:status`.
 * Identifies installed **Composer modules** (type `drupal-module`, excluding dev requirements) that are **not enabled** on *any* of the Drupal sites defined within a specific Drush alias group.
 * Uses the project's local Drush instance (`vendor/bin/drush`) for consistency.

 ### Prerequisites

 The script relies on the following tools being available in the execution environment:

 * `bash`
 * `drush/drush` (via `vendor/bin/drush`)
 * `composer`
 * `jq` (command-line JSON processor, e.g., `sudo apt install jq` or `brew install jq`)
 * Standard core utilities: `comm`, `sort`, `uniq`, `mktemp`, `wc`, `date`

 ### Usage

 Ensure you are in your Drupal **project's root directory**.

 ```bash
 # Run using the default alias group '@updates'
 vendor/bin/check_modules

 # Run using a specific alias group '@my_multisite_group'
 DRUSH_MULTISITE_GROUP_ALIAS='@my_multisite_group' vendor/bin/check_modules
 ```

 ### Configuration (Drush Aliases)

 This script **requires** a properly configured Drush alias group that lists the aliases for all the sites in your multisite installation that you want to check for enabled modules.

 * By default, the script uses the alias group named `@updates`.
 * You can override this default by setting the environment variable `DRUSH_MULTISITE_GROUP_ALIAS` when running the script.
 * Define your site aliases and the group alias in a Drush alias file (e.g., `[project-root]/drush/sites/updates.site.yml` or another location Drush searches).
 * **Important:** The aliases listed within the group must correspond to the environment where you are running the script (e.g., your local development environment aliases).

 **Example (`drush/sites/updates.site.yml`):**

 ```yaml
 # Example: drush/sites/updates.site.yml

 # Define aliases for individual sites (local environment example)
 site1.local:
   root: /var/www/html/my-project/web # Adjust path to your Drupal web root
   uri: site1.dev.local               # URI used locally for site1

 site2.local:
   root: /var/www/html/my-project/web # Adjust path to your Drupal web root
   uri: site2.dev.local               # URI used locally for site2

 # Define the alias group the script uses (defaulting to 'updates')
 updates:
   site-list:
     # List the FULL alias names, including the file stem ('updates')
     - '@updates.site1.local'
     - '@updates.site2.local'
 ```

 ### Output

 The script outputs the following sections:

 1.  **Timestamp:** Indicates when the check was run.
 2.  **Security Updates:** A table listing modules/themes with available security updates (from `drush pm:security`).
 3.  **Minor/Major Updates:** A table listing modules/themes with any available updates (from `drush pm:update:status`). Note: You may need to interpret the version numbers in this table to strictly distinguish between minor and major updates.
 4.  **Unused Composer Modules:** A list of module machine names that are:
     * Required in your `composer.json` (with type `drupal-module`, excluding `require-dev`).
     * *Not* found to be enabled on *any* of the sites targeted by the specified Drush alias group (`@updates` or `$DRUSH_MULTISITE_GROUP_ALIAS`).

 ### Important Notes

 * **Drush Alias Group:** Correct configuration of the Drush alias group is essential for the "Unused Composer Modules" check to function accurately.
 * **Environment:** Ensure the Drush aliases used correspond to the environment (local, staging, etc.) where the script is being executed.

 ---

 ## License

 This script suite is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.