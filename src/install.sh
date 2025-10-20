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

    # The channel or version number to install
    channel="${BRIOCHE_INSTALL_VERSION:-stable}"

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
    _download_to "$brioche_url.sig" "$temp_download.sig"

    # Download the file to a temporary path
    _download_to "$brioche_url" "$temp_download"

    _endgroup

    _startgroup "Validating signature..."

    echo "- Public key: $brioche_release_public_key"
    echo "- Signing namespace: $brioche_release_signing_namespace"
    echo

    # Write an "authorized signers" file with the public key to a temporary
    # file. Unfortunately, POSIX sh doesn't support process substitution, so
    # we create a temporary read-only file with the public key for validation
    brioche_release_signers_file="$brioche_temp/authorized-signers"
    (umask 377 && echo "release@brioche.dev $brioche_release_public_key" > "$brioche_release_signers_file")

    # Validate the file signature
    if ! ssh-keygen -Y verify \
        -s "$temp_download.sig" \
        -n "$brioche_release_signing_namespace" \
        -f "$brioche_release_signers_file" \
        -I "release@brioche.dev" \
        < "$temp_download"; then
        echo
        echo "> Signature is invalid!"
        exit 1
    fi

    _endgroup

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

    # Run post-install step. This will also print a message like:
    # "Brioche <version> is now installed"
    BRIOCHE_SELF_POST_INSTALL_SOURCE=brioche-install \
        "$bin_dir/brioche" self-post-install

    # Check if the install directory is in the $PATH
    case ":$PATH:" in
        *:$bin_dir:*)
            # Already in $PATH
            ;;
        *)
            echo
            echo "\`$bin_dir\` isn't in your shell \$PATH! Add it to your shell profile to finish setting up Brioche"
    esac
}

"_brioche_install"
