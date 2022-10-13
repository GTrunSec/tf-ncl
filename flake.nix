{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    utils.url = github:numtide/flake-utils;
    nickel.url = github:tweag/nickel/pretty/add_optional;
    import-cargo.url = github:edolstra/import-cargo;
    rust-overlay = {
      url = github:oxalica/rust-overlay;
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "utils";
    };

    pre-commit-hooks = {
      url = github:cachix/pre-commit-hooks.nix;
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "utils";
    };
  };
  outputs = { self, utils, ... }@inputs: utils.lib.eachDefaultSystem (system:
    let
      pkgs = import inputs.nixpkgs {
        localSystem = { inherit system; };
        config = { };
        overlays = [
          (import inputs.rust-overlay)
        ];
      };

      inherit (pkgs) lib;

      mkRust =
        { rustProfile ? "minimal"
        , rustExtensions ? [
            "rust-src"
            "rust-analysis"
            "rustfmt-preview"
            "clippy-preview"
          ]
        , channel ? "stable"
        , target ? pkgs.rust.toRustTarget pkgs.stdenv.hostPlatform
        }:
        let
          _rust =
            if channel == "nightly" then
              pkgs.rust-bin.selectLatestNightlyWith
                (toolchain: toolchain.${rustProfile}.override {
                  extensions = rustExtensions;
                  targets = [ target ];
                })
            else
              pkgs.rust-bin.${channel}.latest.${rustProfile}.override {
                extensions = rustExtensions;
                targets = [ target ];
              };
        in
        pkgs.buildEnv {
          name = _rust.name;
          inherit (_rust) meta;
          buildInputs = [ pkgs.makeWrapper ];
          paths = [ _rust ];
          pathsToLink = [ "/" "/bin" ];
          # https://github.com/cachix/pre-commit-hooks.nix/issues/126
          postBuild = ''
            for i in $out/bin/*; do
              wrapProgram "$i" --prefix PATH : "$out/bin"
            done
          '';
        };

      cargoHome = (inputs.import-cargo.builders.importCargo {
        lockFile = ./Cargo.lock;
        inherit pkgs;
      }).cargoHome;

      tf-ncl = { channel ? "stable", isDevShell ? false, target ? pkgs.rust.toRustTarget pkgs.stdenv.hostPlatform }:
        let
          rustProfile = if isDevShell then "default" else "minimal";
          rust = mkRust { inherit rustProfile channel target; };

          pre-commit = inputs.pre-commit-hooks.lib.${system}.run {
            src = self;
            hooks = {
              nixpkgs-fmt = {
                enable = true;
              };
              rustfmt = {
                enable = true;
                entry = pkgs.lib.mkForce "${rust}/bin/cargo-fmt fmt -p tf-ncl -- --check --color always";
              };
            };
          };
        in
        pkgs.stdenv.mkDerivation {
          name = "tf-ncl";
          buildInputs = [ rust ] ++ (if !isDevShell then [ cargoHome ] else [ ]);
          src = if isDevShell then null else self;

          buildPhase = ''
            cargo build -p tf-ncl --release --frozen --offline
          '';
          doCheck = true;
          checkPhase = ''
            cargo test -p tf-ncl --release --frozen --offline
          '' + (pkgs.lib.optionalString (channel == "stable") ''
            cargo fmt -p tf-ncl -- --check
          '');

          installPhase = ''
            mkdir -p $out
            cargo install --frozen --offline --path tf-ncl --root $out
          '';

          shellHook = pre-commit.shellHook;

          passthru = { inherit rust pre-commit; };
          RUST_SRC_PATH = "${rust}/lib/rustlib/src/rust/library";
        };

      terraform-providers = removeAttrs pkgs.terraform-providers [
        "actualProviders"
        "override"
        "overrideDerivation"
        "recurseForDerivations"
      ];
    in
    rec {
      packages = {
        default = packages.tf-ncl;
        tf-ncl = tf-ncl { };
        terraform = pkgs.terraform;
      };

      terraformProviders = terraform-providers;
      generateJsonSchema = providers: pkgs.callPackage (import "${self}/nix/terraform_schema.nix" providers) { };

      jsonSchemas = lib.mapAttrs
        (name: p: generateJsonSchema { ${name} = p; })
        terraform-providers;

      schemas = lib.mapAttrs
        (_: s: pkgs.callPackage "${self}/nix/nickel_schema.nix" { jsonSchema = s; inherit (packages) tf-ncl; })
        jsonSchemas;

      devShell = pkgs.mkShell {
        inputsFrom = [
          (tf-ncl { isDevShell = true; })
        ];
        buildInputs = with pkgs; [
          terraform
          inputs.nickel.packages.${system}.default
          rust-analyzer
          nixpkgs-fmt
        ];
      };
    });
}
