# brioche-installer

This repo contains the script used to install [Brioche](https://brioche.dev). The recommended way to run the installer is like this:

```sh
curl --proto '=https' --tlsv1.2 -sSfL 'https://brioche.dev/install.sh' | sh
```

## Dependencies

The installer requires a few pre-installed tools. Currently:

- coreutils (`mkdir`, `ln`, etc.)
- `curl`
- `tar`
- `xz`
- `ssh-keygen` (required unless `BRIOCHE_INSTALL_VERIFY_SIGNATURE` is set to `auto` or `false`)

## Options

The installer has some extra options. Each of these options can be changed using environment variables, meaning they can be set like this:

```bash
export BRIOCHE_INSTALL_VERSION=stable
curl --proto '=https' --tlsv1.2 -sSfL 'https://brioche.dev/install.sh' | sh

# ... or ...

curl --proto '=https' --tlsv1.2 -sSfL 'https://brioche.dev/install.sh' | BRIOCHE_INSTALL_VERSION=stable sh
```

The following options are supported:

- `BRIOCHE_INSTALL_ROOT`: The root directory where the installer will put the Brioche installation. Defaults to `$HOME/.local/share/brioche-install`
- `BRIOCHE_INSTALL_BIN_DIR`: The path where a symlink to the installed Brioche binary will be placed. Defaults to `$HOME/.local/bin`
- `BRIOCHE_INSTALL_VERSION`: The version (e.g. `v0.1.6`) or channel (`stable` / `nightly`) of Brioche to install. Defaults to `stable`
- `BRIOCHE_INSTALL_VERIFY_SIGNATURE`: Set to `auto` to skip signature verification if signatures cannot be verified (e.g. due to missing commands), or `false` to always skip signature verification. Defaults to `true`, meaning the installer always verifies signatures.

### Weird options

The installer supports some special options not indended for most end-users. These might be particularly volatile, so take caution if you use them!

(These might be useful if you're calling the install script in a CI pipeline. See also our [`setup-brioche`](https://github.com/brioche-dev/setup-brioche) GitHub Action, which uses these options)

- `BRIOCHE_INSTALL_CONTEXT`: Specify the context for the installer, which applies specific tweaks. Valid values are:
    - `standard`: Nothing special. (Default)
    - `github-actions`: Use GitHub Actions-specific features during installation. Uses the `::group` command to group the output, and additionally writes `$GITHUB_PATH` with the value of `$BRIOCHE_INSTALL_BIN_DIR` so subsequent workflow steps will find the installed Brioche version automatically.
- `BRIOCHE_INSTALL_APPARMOR_CONFIG`: Try to install an AppArmor profile for Brioche's sandbox. See [this Ubuntu blog post](https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces) for background details. Requires the commands `aa-enabled`, `apparmor_parser`, and `sudo` (To elevate privileges). Valid values are:
    - `false`: Don't try to install an AppArmor profile. (Default)
    - `true`: Install an AppArmor profile for the installed version of Brioche.
    - `auto`: Try to determine if the current system needs an AppArmor profile for Brioche sandboxing, and install one if so.

## Releases

Each release of the `brioche-installer` script itself is signed and hosted under the URL `https://installer.brioche.dev`.

If you're installing Brioche unattended or as part of an automated pipeline, you may want to download the install script and validate its signature before running it. Or not. I'm not you're dad.

Here's a reference script to validate the installer itself:

```sh
set -euo pipefail # Exit early if a step fails

# Get the current version number of the installer
installer_version=$(curl --proto '=https' --tlsv1.2 -fL 'https://installer.brioche.dev/channels/stable/latest-version.txt')

# Download the install script
curl --proto '=https' --tlsv1.2 -fL "https://installer.brioche.dev/${installer_version}/install.sh" -o install.sh

# Download the signature for the install script
curl --proto '=https' --tlsv1.2 -fL "https://installer.brioche.dev/${installer_version}/install.sh.sig" -o install.sh.sig

# Validate the signature
ssh-keygen -Y verify \
    -s install.sh.sig \
    -n installer@brioche.dev \
    -f <(echo 'installer@brioche.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPrPgnmFyVoPP+tLPmF9lkth3BwVQx9rqlyyxkUDWkqe') \
    -I installer@brioche.dev \
    < install.sh

# Installer has been validated, now run it, e.g.:
# sh install.sh
```

Also, each release includes a [GitHub artifact attestation](https://docs.github.com/en/actions/concepts/security/artifact-attestations) generated during the release CI pipeline. The attestation is available under `https://installer.brioche.dev/${installer_version}/attestation.json`. We don't currently recommend using the attestation for validation though!

## License

Licensed under the terms of the [Unlicense](https://unlicense.org/)

(it's a shell script that unpacks a tarball, it seems silly to assert any sort of copyright over it anyway)
