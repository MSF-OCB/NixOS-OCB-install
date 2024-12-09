#! /usr/bin/env bash
{ # Prevent execution if this script was only partially downloaded - BEGIN
  {
    echo "ERROR: This MSF-OCB's old custom NixOS installation script is not used anymore (as of 2024-12)!"
    echo "For the new NixOS installation process, please read the following documentation (private repo):"
    echo "https://github.com/MSF-OCB/NixOS-OCB/wiki/Install-NixOS-using-nixos%E2%80%90anywhere"
  } >&2
  exit 1
} # Prevent execution if this script was only partially downloaded - END
# ## EOF
