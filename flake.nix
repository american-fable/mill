{

  # This flake performs a few steps to produce the final derivation:
  #   1) Fetching the prebuilt `mill` version and wrapping it to make it executable.
  #   2) Fetching all `mill` dependencies by running 'mill __.prepareOffline --all'
  #      and placing them in a custom folder. It uses a Fixed-Output derivation,
  #      so it has network access, but the output must always match the provided
  #      hash. Because of this, it performs a few extra 'clean up' steps,
  #      like stripping dates.
  #   3) Building `mill` from source using the provided dependencies (without network access).
  #
  # To build:
  #   nix build .#default
  # To partially rebuild (only works if it already was build):
  #   nix build .#default --rebuild
  # To fully rebuild with all inputs for testing:
  #   nix build .#default --store <absolute path>/tmpstore --substituters ""

  description = "Mill Build Tool From Src";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { 
    self, 
    nixpkgs,
    flake-utils
  }:
  flake-utils.lib.eachDefaultSystem (
    system:
    let
      pkgs = import nixpkgs { inherit system; };
      millPrebuildVersion = "0.12.0"; # version of prebuild mill artifact
      version = "b449aaeeb6e"; # target version
      cacheDir = "cs_cache";
      depsDir = "/tmp/${cacheDir}";

      millPrebuild = pkgs.fetchurl {
        url = "https://repo1.maven.org/maven2/com/lihaoyi/mill-dist/${millPrebuildVersion}/mill-dist-${millPrebuildVersion}-assembly.jar";
        hash = "sha256-w+IYHHDI8bxHYVK3yEVL7QKHlsduAfTMuFzz1s165Bo=";
      };
      packagesList = with pkgs; [
        bashInteractive
        curl
        git
        openjdk21
        coursier
      ];
      millWrapper = pkgs.stdenv.mkDerivation {
         name = "mill-${millPrebuildVersion}";
         buildInputs = packagesList;
         nativeBuildInputs = packagesList ++ [ pkgs.makeWrapper ];
         dontUnpack = true;
         installPhase = ''
           runHook preInstall
           install -Dm555 ${millPrebuild} "$out/bin/.mill-wrapped"
           makeWrapper "$out/bin/.mill-wrapped" "$out/bin/mill" \
             --prefix PATH : "${pkgs.openjdk21}/bin" \
             --set JAVA_HOME "${pkgs.openjdk21}"
           runHook postInstall
          '';
         doInstallCheck = true;
         # The default release is a script which will do an impure download
         # just ensure that the application can run without network
         installCheckPhase = ''
           $out/bin/mill --help > /dev/null
         '';
       };
      # Fixed output derivation which has access to network connection
      # some based on https://github.com/com-lihaoyi/mill/discussions/1170#discussioncomment-3205984
      # Also, info about hooks:
      # https://github.com/jtojnar/nixpkgs-hammering/blob/6a4f88d82ab7d0a95cf21494896bce40f7a4ac22/explanations/missing-phase-hooks.md
      millDependencies = pkgs.stdenv.mkDerivation {
         name = "mill-${version}-dependencies";
         buildInputs = packagesList;
         nativeBuildInputs = packagesList ++ [millWrapper];
         src = ./.;
         buildPhase = ''
          runHook preBuild

          mkdir -p ${depsDir}
          COURSIER_CACHE='${depsDir}/' mill __.prepareOffline --all
          echo content of cache is: $(ls -la ${depsDir})

          echo "stripping out comments containing dates"
          find ${depsDir} -name '*.properties' -type f -exec sed -i '/^#/d' {} \;
          echo "removing non-reproducible accessory files"
          find ${depsDir} -name '*.lock' -type f -print0 | xargs -r0 rm -rfv
          find ${depsDir} -name '*.log' -type f -print0 | xargs -r0 rm -rfv
          echo "removing runtime jar"
          find ${depsDir} -name rt.jar -delete
          echo "removing empty directories"
          find ${depsDir} -type d -empty -delete

          runHook postBuild
         '';

         installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r ${depsDir} $out
          runHook postInstall
         '';
         outputHashAlgo = "sha256";
         outputHashMode = "recursive";
         outputHash = "sha256-pcHBXPm/Pb95WIyjbeiiyLRg3XOvXZhD3CXoyqQEZ7M=";
         #outputHash = pkgs.lib.fakeHash;
      };
      millBuild = pkgs.stdenv.mkDerivation {
         name = "mill-${version}";
         buildInputs = packagesList;
         nativeBuildInputs = packagesList ++ [millWrapper millDependencies];
         src = ./.;
         doCheck = false;
         patchPhase = ''
           sed -i "s/VcsVersion.vcsState().format()/\"${version}\"/g" "./build.mill"
         '';
         installPhase = ''
           runHook preInstall
           echo cacheDir $(ls ${millDependencies}/${cacheDir})
           COURSIER_CACHE='${millDependencies}/${cacheDir}/' mill dist.assembly
           echo resul dir: $(ls out/dist/assembly.dest/)
           mkdir -p $out/bin
           cp out/dist/assembly.dest/mill $out/bin/
           chmod +x $out/bin/mill
           runHook postInstall
         '';
      };
    in {
      # shell providing pre-build version of mill for experimentation
      devShells.default = pkgs.mkShell { 
        buildInputs = packagesList ++ [millWrapper millDependencies];
        shellHook = ''
          echo prebuild mill path: ${millPrebuild}
          echo git mill dependencies path: ${millDependencies}
          echo git mill path: ${millBuild}
        '';
      };
      packages.mill = millBuild;
      packages.default = millBuild;
    }
  );
}
