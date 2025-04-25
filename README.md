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
    vendor/bin/update_modules.sh.sh

    # Inside Docker (example):
    docker exec -it [-e COMPOSER_AUTH='...'] your_container_name vendor/bin/update_modules.sh.sh
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

## Multisite Module Status Check Script (`vendor/bin/check_modules.sh`)

This script provides a command-line utility to assess the status of contributed modules within a Drupal multisite installation managed by Composer, targeting specific environment aliases.

**Purpose:**

* Checks the shared codebase for available **security vulnerabilities** using `composer audit`.
* Checks the shared codebase for available **general updates** (minor/major) using `composer outdated 'drupal/*'`.
* Identifies installed **Composer modules** (type `drupal-module`, excluding dev requirements) that are **not enabled** on *any* of the Drupal sites whose Drush aliases match the specified environment suffix (`.local` or `.prod`).
* Uses the project's local Drush instance (`vendor/bin/drush`) for consistency.
* Dynamically discovers target Drush aliases based on the provided environment argument.

**Prerequisites:**

1.  **Execution Location:** The script **must** be run from the root directory of your Drupal project (the directory containing your main `composer.json` and `vendor/` directory).
2.  **Drush Aliases:** Drush aliases **must** be configured for your multisite setup (e.g., in `[project-root]/drush/sites/self.site.yml` or similar). Aliases should follow a consistent naming convention ending in `.local` for local environments and `.prod` for production environments (e.g., `@self.site1.local`, `@self.site2.prod`).
3.  **`jq` (Optional):** The command-line JSON processor `jq` is no longer strictly required by this script but may be useful for other command-line tasks.

**Usage:**

Ensure you are in your Drupal project's root directory. You must specify the target environment using the `-e` or `--environment` flag.

```bash
# Check modules against aliases ending in .local
vendor/bin/check_modules.sh.sh -e local

# Check modules against aliases ending in .prod
vendor/bin/check_modules.sh.sh --environment=prod
```

**Configuration (Drush Alias Example):**

The script relies on your existing Drush alias configuration. Ensure your aliases are defined and follow the `.local`/`.prod` suffix convention.

```yaml
# Example: drush/sites/self.site.yml

# Define aliases for individual sites following the convention
site1.local:
  root: /var/www/html/my-project/web # Adjust path to your Drupal web root
  uri: site1.dev.local               # URI used locally for site1

site2.local:
  root: /var/www/html/my-project/web
  uri: site2.dev.local

site1.prod:
  host: prod.server.com
  user: deploy_user
  root: /var/www/html/my-project/web # Adjust path on production
  uri: [www.site1.com](https://www.site1.com)                 # Production URI for site1

site2.prod:
  host: prod.server.com
  user: deploy_user
  root: /var/www/html/my-project/web
  uri: [www.site2.com](https://www.site2.com)
```

**Output:**

The script outputs the following sections:

1.  **Timestamp & Target Env:** Indicates when the check was run and which environment (`.local` or `.prod`) was targeted.
2.  **Discovered Aliases:** Lists the specific Drush aliases found matching the target environment pattern.
3.  **Security Audit:** Output from `composer audit`, highlighting potential vulnerabilities.
4.  **Available Updates:** Output from `composer outdated 'drupal/*'`, listing Drupal packages with available updates. (Review version numbers to distinguish minor/major).
5.  **Unused Composer Modules:** A list of module machine names that are:
    * Required in your `composer.json` (with type `drupal-module`, excluding `require-dev`).
    * *Not* found to be enabled on *any* of the dynamically discovered sites matching the target environment (`.local` or `.prod`).

**Dependencies:**

The script relies on the following command-line tools:

* `bash`
* `drush/drush` (via `vendor/bin/drush`)
* `composer`
* Standard core utilities: `grep`, `sed`, `sort`, `uniq`, `mktemp`, `wc`, `date`, `paste`, `comm`

---

## Site Synchronization Script (`vendor/bin/sync_sites.sh`)

This script automates the process of synchronizing data and files from a production Drupal site to its corresponding local development site for all sites defined in the `drush/sites/` directory.

### Prerequisites

1.  **Drush Alias Files:** Each site pair (production and local) must have its aliases defined in a separate YAML file within the `drush/sites/` directory (e.g., `drush/sites/my_site.site.yml`).
    *   The file name (without `.site.yml`) is used as the base alias name (e.g., `my_site`).
    *   Aliases within the file must be named `local` and `prod` (resulting in Drush aliases like `@my_site.local` and `@my_site.prod`).
2.  **`yq` Utility (Python version):** The script uses the Python-based `yq` command-line YAML processor (which uses path syntax like `.local.key`) to read configuration from alias files. This version is installed via `apt install yq` within the project's `Dockerfile`. Ensure this version is available in the environment where the script runs (the `wrlc_drupal` container).
3.  **Config Split Name (Optional):** If the local site uses a specific configuration split that needs to be re-imported after a database sync, add a `config_split_name` key under the `local` alias definition in the corresponding `.site.yml` file.
    ```yaml
    # drush/sites/my_site.site.yml
    local:
      uri: http://my_site.local
      root: /path/to/local/web
      config_split_name: local_dev_split # Add this line if needed
      # ... other local settings
    prod:
      # ... prod config ...
    ```
4.  **Private Files Usage Flag (Optional):** To enable synchronization of private files, add a `uses_private_files` key set to `true` under the `local` alias definition in the corresponding `.site.yml` file. If this key is missing, `false`, or `null`, the private file sync step will be skipped for that site.
    ```yaml
    # drush/sites/my_site.site.yml
    local:
      uri: http://my_site.local
      root: /path/to/local/web
      config_split_name: local_dev_split
      uses_private_files: true # Add this line to sync private files
    prod:
      # ... prod config ...
    ```

### Usage

Run the script from the project root directory, typically inside the Drupal container:

```bash
docker exec -it wrlc_drupal vendor/bin/sync_sites.sh

 ## License

 This script suite is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.