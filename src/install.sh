#!/usr/bin/env sh

# Wrap the installation in a function so it only runs once the
# entire script is downloaded
_brioche_install() {
    set -eu

    # Customize settings and output based on where we're running the script
    install_ctx="${BRIOCHE_INSTALL_CONTEXT:-standard}"
    case "$install_ctx" in
        standard)
            _echo_error() {
                echo "$1"
            }
            _startgroup() {
                echo "[$1]"
            }
            _endgroup() {
                echo
            }

            ;;
        github-actions)
            _echo_error() {
                echo "::error::$1"
            }
            _startgroup() {
                echo "::group::$1"
            }
            _endgroup() {
                echo "::endgroup::"
            }

            if [ -z "${GITHUB_PATH:-}" ]; then
                _echo_error "Installer is running in GitHub Actions mode, but \$GITHUB_PATH is not set"
                exit 1
            fi

            ;;
        *)
            echo "Unsupported value for \$BRIOCHE_INSTALL_CONTEXT: $install_ctx"
            exit 1
    esac

    # Validate $HOME is set to a valid directory
    if [ -z "$HOME" ]; then
        _echo_error "\$HOME environment variable is not set!"
        exit 1
    fi
    if [ ! -d "$HOME" ]; then
        _echo_error "\$HOME does not exist!"
        exit 1
    fi

    # The public key to validate download signatures
    brioche_release_public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN62i+zbHQzRA0qSCULi9Skk8DxfYANdd73WfdyF6D48"

    # The root directory where the installer will put stuff
    brioche_install_root="${BRIOCHE_INSTALL_ROOT:-${XDG_DATA_DIR:-$HOME/.local/share}/brioche-install}"

    # The bin dir where the main Brioche binary will be put (as a symlink)
    bin_dir="${BRIOCHE_INSTALL_BIN_DIR:-$HOME/.local/bin}"

    # Get Brioche's data directory
    brioche_data_dir="${BRIOCHE_DATA_DIR:-${XDG_DATA_DIR:-$HOME/.local/share}/brioche}"

    # The channel or version number to install
    channel="${BRIOCHE_INSTALL_VERSION:-stable}"

    # List of commands that need to be present to run the installer
    required_commands="curl tar xz uname mkdir ln rm expr"
    hint_packages_ubuntu_debian="coreutils tar xz-utils curl"
    hint_packages_fedora="coreutils tar xz curl"

    case "${BRIOCHE_INSTALL_VERIFY_SIGNATURE:-true}" in
        true|1)
            verify_signature=true
            required_commands="$required_commands ssh-keygen"
            hint_packages_ubuntu_debian="$hint_packages_ubuntu_debian openssh-client"
            hint_packages_fedora="$hint_packages_fedora openssh-clients"
            ;;
        false|0)
            verify_signature=false
            ;;
        auto)
            if type ssh-keygen >/dev/null; then
                verify_signature=true
            else
                verify_signature=false
            fi
            ;;
        *)
            _echo_error "Invalid setting for \$BRIOCHE_INSTALL_VERIFY_SIGNATURE"
            exit 1
            ;;
    esac

    case "${BRIOCHE_INSTALL_APPARMOR_CONFIG:-false}" in
        true|1)
            install_apparmor_config=true
            ;;
        false|0)
            install_apparmor_config=false
            ;;
        auto)
            # Detect if we should install an AppArmor profile. AppArmor 4.0
            # introduced new features to restrict unprivileged user
            # namespaces, which Ubuntu 23.10 enforces by default. The
            # Brioche AppArmor policy is meant to lift this restriction
            # for sandboxed builds, which we only need to do on AppArmor 4+.
            # So, we only install the policy if AppArmor is enabled and
            # we find the config file for AppArmor abi 4.0.
            if type aa-enabled >/dev/null && aa-enabled -q && [ -e /etc/apparmor.d/abi/4.0 ]; then
                install_apparmor_config=true
            else
                install_apparmor_config=false
            fi
            ;;
        *)
            _echo_error "Invalid setting for \$BRIOCHE_INSTALL_APPARMOR_CONFIG"
            exit 1
            ;;
    esac
    if [ "$install_apparmor_config" = true ]; then
        required_commands="$required_commands realpath tee sudo apparmor_parser"
    fi

    missing_commands=""
    for command in $required_commands; do
        if ! type "$command" >/dev/null; then
            missing_commands="${missing_commands:+$missing_commands, }$command"
        fi
    done
    if [ -n "$missing_commands" ]; then
        _echo_error "Missing required command(s): $missing_commands"
        echo
        echo "Could not find a required command! You may need to install some system packages:"
        echo "- Ubuntu / Debian: \`sudo apt-get install $hint_packages_ubuntu_debian\`"
        echo "- Fedora: \`sudo dnf install $hint_packages_fedora\`"
        exit 1
    fi

    # Get the platform name based on the kernel and architecture
    case "$(uname -sm)" in
        "Linux x86_64")
            brioche_platform="x86_64-linux"
            ;;
        "Linux aarch64")
            brioche_platform="aarch64-linux"
            ;;
        *)
            _echo_error "Sorry, Brioche isn't currently supported on your platform"
            echo "  Detected kernel: $(uname -s)"
            echo "  Detected architecture: $(uname -m)"
            exit 1
            ;;
    esac

    brioche_filename="brioche-$brioche_platform.tar.xz"

    # Helpers for downloading via curl
    _download() {
        if [ "$#" -ne 1 ] || [ -z "$1" ]; then
            echo "Internal error: _download called incorrectly" >&2
            exit 1
        fi

        echo "# Downloading: $1" >&2
        curl --proto '=https' --tlsv1.2 -fL "$1"
    }
    _download_to() {
        if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
            echo "Internal error: _download_to called incorrectly" >&2
            exit 1
        fi

        echo "# Downloading: $1" >&2
        curl --proto '=https' --tlsv1.2 -fL "$1" -o "$2"
    }

    # Resolve current version and URL from channel
    case "$channel" in
        stable)
            _startgroup "Resolving latest version for $channel..."
            brioche_version="$(_download "https://releases.brioche.dev/channels/$channel/latest-version.txt")"
            echo "# Latest version for $channel: $brioche_version"
            _endgroup

            brioche_url="https://releases.brioche.dev/$brioche_version/$brioche_filename"
            brioche_release_signing_namespace=release@brioche.dev
            ;;
        nightly)
            brioche_version="$channel"
            brioche_url="https://development-content.brioche.dev/github.com/brioche-dev/brioche/branches/main/$brioche_filename"
            brioche_release_signing_namespace=nightly@brioche.dev
            ;;
        *)
            # Try to parse as a version number (e.g. "v0.1.6" or "0.1.6")
            matched_version_number="$(expr "//$channel" : '//v\{0,1\}\([[:digit:]]\{1,\}\.[[:digit:]]\{1,\}\.[[:digit:]]\{1,\}.*\)$' || true)"
            if [ -z "$matched_version_number" ]; then
                # Passed version was neither a supported channel name nor a semver-like version number
                _echo_error "Unsupported version number or channel name: $channel"
                exit 1
            fi

            brioche_version="v$matched_version_number"
            brioche_url="https://releases.brioche.dev/$brioche_version/$brioche_filename"
            brioche_release_signing_namespace=release@brioche.dev
            ;;
    esac

    # Create a temporary directory
    brioche_temp="$(mktemp -d -t brioche-XXXXXX)"
    trap 'rm -rf -- "$brioche_temp"' EXIT

    _startgroup "Downloading Brioche $brioche_version..."

    temp_download="$brioche_temp/$brioche_filename"

    # Download the signature
    if [ "$verify_signature" = true ]; then
        _download_to "$brioche_url.sig" "$temp_download.sig"
    fi

    # Download the file to a temporary path
    _download_to "$brioche_url" "$temp_download"

    _endgroup

    if [ "$verify_signature" = true ]; then
        _startgroup "Verifying signature..."

        echo "- Public key: $brioche_release_public_key"
        echo "- Signing namespace: $brioche_release_signing_namespace"
        echo

        # Write an "authorized signers" file with the public key to a temporary
        # file. Unfortunately, POSIX sh doesn't support process substitution, so
        # we create a temporary read-only file with the public key for validation
        brioche_release_signers_file="$brioche_temp/authorized-signers"
        (umask 377 && echo "release@brioche.dev $brioche_release_public_key" > "$brioche_release_signers_file")

        # Verify the file signature
        if ! ssh-keygen -Y verify \
            -s "$temp_download.sig" \
            -n "$brioche_release_signing_namespace" \
            -f "$brioche_release_signers_file" \
            -I "release@brioche.dev" \
            < "$temp_download"; then
            echo
            _echo_error "Failed to verify signature!"
            exit 1
        fi

        _endgroup
    fi

    _startgroup "Installing Brioche $brioche_version..."
    echo "- Install root: $brioche_install_root"
    echo "- Bin dir: $bin_dir"
    echo

    # Unpack tarfile
    unpack_dir="$brioche_install_root/brioche/$brioche_version"
    rm -rf "$unpack_dir"
    mkdir -p "$unpack_dir"
    tar -xJf "$brioche_temp/$brioche_filename" --strip-components=1 -C "$unpack_dir"

    # Add a symlink to the current version
    ln -sf "$brioche_version" "$brioche_install_root/brioche/current"

    # Add a relative symlink in the install directory to the binary
    # within the current version
    symlink_target="$brioche_install_root/brioche/current/bin/brioche"
    mkdir -p "$bin_dir"
    ln -sfr "$symlink_target" "$bin_dir/brioche"

    echo "# Symlink: $bin_dir/brioche -> $symlink_target"

    _endgroup

    if [ "$install_ctx" = github-actions ]; then
        _startgroup "Updating \$PATH..."

        # Add the bin dir and the dir for packages installed by Brioche
        # to $PATH
        for new_path in "$bin_dir" "$brioche_data_dir/installed/bin"; do
            echo "$new_path" >> "$GITHUB_PATH"
            echo "Added to \$PATH: $new_path"
        done

        _endgroup
    fi

    if [ "$install_apparmor_config" = true ]; then
        _startgroup "Installing AppArmor config..."

        # Get the real, final path of the Brioche binary to use for the
        # AppArmor config.
        brioche_bin_realpath="$(realpath "$unpack_dir/bin/brioche")"

        # Validate that the Brioche path doesn't have any characters we might
        # need to escape / quote in the AppArmor config
        # TODO: We should update this to support more paths!
        brioche_bin_realpath_is_safe="$(expr "//$brioche_bin_realpath" : '//[a-zA-Z0-9_/.-]*$')"
        if [ "$brioche_bin_realpath_is_safe" -eq 0 ]; then
            echo "Brioche bin realpath: $brioche_bin_realpath"
            _echo_error "The path for the Brioche binary that we'd use in the AppArmor config has special characters we don't know how to handle for now!"
            exit 1
        fi

        # Write the AppArmor config
        sudo tee /etc/apparmor.d/brioche-sandbox <<EOF
abi <abi/4.0>,
include <tunables/global>

# Enable unprivileged user namespaces for Brioche. See this Ubuntu blog post
# for more context:
# https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces
$brioche_bin_realpath flags=(default_allow) {
  userns,
}
EOF

        # Validate the AppArmor config
        sudo apparmor_parser -r /etc/apparmor.d/brioche-sandbox

        _endgroup
    fi

    # Run post-install step. This will also print a message like:
    # "Brioche <version> is now installed"
    BRIOCHE_SELF_POST_INSTALL_SOURCE=brioche-install \
        "$bin_dir/brioche" self-post-install

    if [ "$install_ctx" = standard ]; then
        # Check if the install directory is in the $PATH
        case ":$PATH:" in
            *:$bin_dir:*)
                # Already in $PATH
                ;;
            *)
                echo
                echo "\`$bin_dir\` isn't in your shell \$PATH! Add it to your shell profile to finish setting up Brioche"
        esac
    fi
}

"_brioche_install"
