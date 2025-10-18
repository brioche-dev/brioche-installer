#!/usr/bin/env sh

# Wrap the installation in a function so it only runs once the
# entire script is downloaded
install_brioche() {
    set -eu

    # Validate $HOME is set to a valid directory
    if [ -z "$HOME" ]; then
        echo '$HOME environment variable is not set!'
        exit 1
    fi
    if [ ! -d "$HOME" ]; then
        echo '$HOME does not exist!'
        exit 1
    fi

    # The directory where Brioche gets installed (using a symlink)
    install_dir="${BRIOCHE_INSTALL_DIR:-$HOME/.local/bin}"

    # The directory where to unpack the installation
    unpack_dir="${BRIOCHE_INSTALL_UNPACK_DIR:-$HOME/.local/share/brioche-install/brioche}"

    channel="${BRIOCHE_CHANNEL:-stable}"

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
            ;;
        nightly)
            brioche_version="$channel"
            brioche_url="https://development-content.brioche.dev/github.com/brioche-dev/brioche/branches/main/$brioche_filename"
            ;;
        *)
            echo "Unsupported channel: $channel" >&2
            exit 1
            ;;
    esac

    # Create a temporary directory
    brioche_temp="$(mktemp -d -t brioche-XXXXXX)"
    trap 'rm -rf -- "$brioche_temp"' EXIT

    echo "Downloading Brioche..."
    echo "  URL: $brioche_url"
    echo

    # Download the file to a temporary path
    temp_download="$brioche_temp/$brioche_filename"
    echo "Downloading to \`$temp_download\`..."
    curl --proto '=https' --tlsv1.2 -fL "$brioche_url" -o "$temp_download"
    echo

    # Unpack tarfile
    echo "Unpacking to \`$unpack_dir/$brioche_version\`..."
    rm -rf "${unpack_dir:?}/${brioche_version:?}"
    mkdir -p "$unpack_dir/$brioche_version"
    tar -xJf "$brioche_temp/$brioche_filename" --strip-components=1 -C "$unpack_dir/$brioche_version"

    # Add a symlink to the current version
    echo "Adding symlink \`$unpack_dir/current\` -> \`$brioche_version\`..."
    ln -sf "$brioche_version" "$unpack_dir/current"

    # Add a relative symlink in the install directory to the binary
    # within the current version
    symlink_target="$unpack_dir/current/bin/brioche"
    echo "Adding symlink \`$install_dir/brioche\` -> \`$symlink_target\`..."
    mkdir -p "$install_dir"
    ln -sfr "$symlink_target" "$install_dir/brioche"

    echo "Installation complete!"

    # Check if the install directory is in the $PATH
    case ":$PATH:" in
        *:$install_dir:*)
            # Already in $PATH
            ;;
        *)
            echo
            echo "\`$install_dir\` isn't in your shell \$PATH! Add it to your shell profile to finish setting up Brioche"
    esac
}

"install_brioche"
