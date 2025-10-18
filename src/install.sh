#!/usr/bin/env sh

# Wrap the installation in a function so it only runs once the
# entire script is downloaded
install_brioche() {
    set -eu

    brioche_release_public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN62i+zbHQzRA0qSCULi9Skk8DxfYANdd73WfdyF6D48"

    # Validate $HOME is set to a valid directory
    if [ -z "$HOME" ]; then
        echo '$HOME environment variable is not set!'
        exit 1
    fi
    if [ ! -d "$HOME" ]; then
        echo '$HOME does not exist!'
        exit 1
    fi

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
            echo "Sorry, Brioche isn't currently supported on your platform"
            echo "  Detected kernel: $(uname -s)"
            echo "  Detected architecture: $(uname -m)"
            exit 1
            ;;
    esac

    brioche_filename="brioche-$brioche_platform.tar.xz"

    # Resolve current version and URL from channel
    case "$channel" in
        stable)
            brioche_version="$(curl --proto '=https' --tlsv1.2 -fL "https://releases.brioche.dev/channels/$channel/latest-version.txt")"
            echo "Latest version for $channel: $brioche_version"

            brioche_url="https://releases.brioche.dev/$brioche_version/$brioche_filename"
            brioche_release_signing_namespace=release@brioche.dev
            ;;
        nightly)
            brioche_version="$channel"
            brioche_url="https://development-content.brioche.dev/github.com/brioche-dev/brioche/branches/main/$brioche_filename"
            brioche_release_signing_namespace=nightly@brioche.dev
            ;;
        v*)
            # Install a specific version number directly
            brioche_version="$channel"
            brioche_url="https://releases.brioche.dev/$brioche_version/$brioche_filename"
            brioche_release_signing_namespace=release@brioche.dev
            ;;
        *)
            echo "Unsupported channel: $channel" >&2
            exit 1
            ;;
    esac

    # Create a temporary directory
    brioche_temp="$(mktemp -d -t brioche-XXXXXX)"
    trap 'rm -rf -- "$brioche_temp"' EXIT

    temp_download="$brioche_temp/$brioche_filename"
    echo "Downloading Brioche..."
    echo "  Download URL: $brioche_url"
    echo "  Signature URL: $brioche_url.sig"
    echo "  Signing key: $brioche_release_public_key"
    echo "  Signing namespace: $brioche_release_signing_namespace"
    echo

    # Download the signature
    echo "Downloading signature to \`$temp_download.sig\`..."
    curl --proto '=https' --tlsv1.2 -fL "$brioche_url.sig" -o "$temp_download.sig"
    echo

    # Download the file to a temporary path
    echo "Downloading to \`$temp_download\`..."
    curl --proto '=https' --tlsv1.2 -fL "$brioche_url" -o "$temp_download"
    echo

    # Write an "authorized signers" file with the public key to a temporary
    # file. Unfortunately, POSIX sh doesn't support process substitution, so
    # we create a temporary read-only file with the public key for validation
    brioche_release_signers_file="$brioche_temp/authorized-signers"
    (umask 377 && echo "release@brioche.dev $brioche_release_public_key" > "$brioche_release_signers_file")

    # Validate the file signature
    echo "Validating signature..."
    if ssh-keygen -Y verify \
        -s "$temp_download.sig" \
        -n "$brioche_release_signing_namespace" \
        -f "$brioche_release_signers_file" \
        -I "release@brioche.dev" \
        < "$temp_download"; then
        echo "Signature matches"
    else
        echo "Signature does not match!"
        exit 1
    fi


    # Unpack tarfile
    unpack_dir="$brioche_install_root/brioche/$brioche_version"
    echo "Unpacking to \`$unpack_dir\`..."
    rm -rf "$unpack_dir"
    mkdir -p "$unpack_dir"
    tar -xJf "$brioche_temp/$brioche_filename" --strip-components=1 -C "$unpack_dir"

    # Add a symlink to the current version
    echo "Adding symlink \`$brioche_install_root/brioche/current\` -> \`$brioche_version\`..."
    ln -sf "$brioche_version" "$brioche_install_root/brioche/current"

    # Add a relative symlink in the install directory to the binary
    # within the current version
    symlink_target="$brioche_install_root/brioche/current/bin/brioche"
    echo "Adding symlink \`$bin_dir/brioche\` -> \`$symlink_target\`..."
    mkdir -p "$bin_dir"
    ln -sfr "$symlink_target" "$bin_dir/brioche"

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

"install_brioche"
