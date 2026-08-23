# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      allSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems = fn:
        nixpkgs.lib.genAttrs allSystems
          (system: fn {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ self.overlays.odin ];
            };
            inherit system;
          });
    in
    {
      overlays.odin = final: prev: {
        odin = prev.odin.overrideAttrs (finalAttrs: prevAttrs: {
          version = "dev-2026-06";
          src = prev.fetchFromGitHub {
            owner = "odin-lang";
            repo = "Odin";
            tag = finalAttrs.version;
            hash = "sha256-Z2497J80j5OLiyhTumrsofNANnNrnDE6Z3UB1b/TVGg=";
          };
          patches = [
            ./nix.patches/darwin-remove-impure-links.patch
            ./nix.patches/system-raylib.patch
          ];
        });

        ols = prev.ols.overrideAttrs (finalAttrs: prevAttrs: {
          version = "0-unstable-2026-06-21";
          src = prev.fetchFromGitHub {
            owner = "DanielGavin";
            repo = "ols";
            rev = "8b1c17f78a89936f248a0dd0c12d56bfa004cae6";
            hash = "sha256-zmaqPBcv/a5EhB4EbtpYdOGWbO/eLMcby630hbSEh+M=";
          };
        });
      };

      devShells = forAllSystems ({ pkgs, ... }: {

        default = pkgs.mkShell {
          name = "odin-dev";

          packages = with pkgs; [
            odin
            ols
            sqlite # the `sqlite3` CLI; the lib + headers are wired up below

            gcc
            gnumake

            gdb
          ];

          # Odin itself reads NO library search env vars (LIBRARY_DIRS,
          # C_INCLUDE_DIRS, etc.). It just shells out to clang, which links the
          # system lib you declare with `foreign import lib "system:sqlite3"`
          # as `-lsqlite3`. So we expose sqlite's lib dir to the linker Odin
          # invokes, and to the dynamic loader at run time.
          #
          # LIBRARY_PATH   -> clang's link-time search path (additive)
          # LD_LIBRARY_PATH-> dynamic loader search path at run time
          # C_INCLUDE_PATH -> sqlite's public headers (useful for C bindings)
          LIBRARY_PATH     = pkgs.lib.makeLibraryPath [ pkgs.sqlite ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.sqlite ];
          C_INCLUDE_PATH   = "${pkgs.lib.getDev pkgs.sqlite}/include";

          shellHook = ''
            echo "Odin:  $(odin version)"
          '';
        };
      });
    };
}
