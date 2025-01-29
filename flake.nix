{

  # This flake performs a few steps to produce the final derivation:
  #   1) Fetching the prebuilt `mill` version and wrapping it to make it executable.
  #   2) Fetching all `mill` dependencies by running 'mill __.prepareOffline --all'
  #      and placing them in a custom folder. It uses a Fixed-Output derivation,
  #      so it has network access, but the output must always match the provided
  #      hash. Because of this, it performs a few extra 'clean up' steps,
  #      like stripping dates.
  #   3) Ask mill to publish locally mill libs and copying those for next step
  #   4) Building `mill` from source using the provided dependencies and libs (without network access).
  #   5) creating mill wrapper with custom ivy repository in configration
  #
  # To build:
  #   nix build .#default
  # To partially rebuild (only works if it already was build):
  #   nix build .#default --rebuild
  # To fully rebuild with all inputs for testing:
  #   nix build .#default --store <absolute path>/tmpstore --substituters ""

  description = "Mill Build Tool From Src";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
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
      millPrebuiltVersion = "0.12.4-23-2ff492"; # version of prebuilt mill artifact (for 0.12.5)
      version = self.shortRev or "dirty"; # target version
      cacheDir = "cs_cache"; # custom coursier cache folder name
      depsTmpDir = "/tmp/${cacheDir}"; # this is inside derivation sandbox (nix sandboxing build env by default)
      localDefaultIvyPattern = "[organisation]/[module]/(scala_[scalaVersion]/)(sbt_[sbtVersion]/)[revision]/[type]s/[artifact](-[classifier]).[ext]";
      millVersionPatch = ''
        sed -i "s/else \"SNAPSHOT\"/\"${version}\"/g" "./build.mill"
        sed -i "s/if (Task.env.contains(\"MILL_STABLE_VERSION\")) VcsVersion.calcVcsState(Task.log).format()/ /g" "./build.mill"
      ''; # patch needed to inline version value because during build can't get it from git

      packagesList = with pkgs; [
        bashInteractive
        curl
        git
        openjdk21
        coursier
      ];

       millPrebuilt = pkgs.fetchurl {
        url = "https://repo1.maven.org/maven2/com/lihaoyi/mill-dist/${millPrebuiltVersion}/mill-dist-${millPrebuiltVersion}-assembly.jar";
        hash = "sha256-zfQ03mU/Qg3KXqbRdYRcXCABhCoI0uY2rHqpwRyKKxw=";
      };

      millWrapper = pkgs.stdenv.mkDerivation {
         name = "mill-${millPrebuiltVersion}";
         buildInputs = packagesList;
         nativeBuildInputs = packagesList ++ [ pkgs.makeWrapper ];
         dontUnpack = true;
         installPhase = ''
           runHook preInstall
           install -Dm555 ${millPrebuilt} "$out/bin/.mill-wrapped"
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
         name = "mill-dependencies-${version}";
         doCheck = false;
         buildInputs = packagesList;
         nativeBuildInputs = packagesList ++ [millWrapper];
         src = ./.;

         patchPhase = millVersionPatch;

         buildPhase = ''
          runHook preBuild

          rm -rf ${depsTmpDir}
          rm -rf out
          mkdir -p ${depsTmpDir}
          COURSIER_CACHE='${depsTmpDir}/' ${millWrapper}/bin/mill clean
          COURSIER_CACHE='${depsTmpDir}/' ${millWrapper}/bin/mill __.prepareOffline --all
          echo content of cache is: $(ls -la ${depsTmpDir})

          # these dependencies should be fetched via __.prepareOffline but they aren't
          # TODO: worth to reserch reason and report to upstream
          COURSIER_CACHE='${depsTmpDir}/' cs fetch org.slf4j:jcl-over-slf4j:1.7.30
          COURSIER_CACHE='${depsTmpDir}/' cs fetch org.slf4j:slf4j-api:1.7.30
          COURSIER_CACHE='${depsTmpDir}/' cs fetch io.get-coursier:interface:0.0.17

          echo "stripping out comments containing dates"
          find ${depsTmpDir} -name '*.properties' -type f -exec sed -i '/^#/d' {} \;
          echo "removing non-reproducible accessory files"
          find ${depsTmpDir} -name '*.lock' -type f -print0 | xargs -r0 rm -rfv
          find ${depsTmpDir} -name '*.log' -type f -print0 | xargs -r0 rm -rfv
          echo "removing runtime jar"
          find ${depsTmpDir} -name rt.jar -delete
          echo "removing empty directories"
          find ${depsTmpDir} -type d -empty -delete

          runHook postBuild
         '';

         installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r ${depsTmpDir} $out
          runHook postInstall
         '';

         outputHashAlgo = "sha256";
         outputHashMode = "recursive";
         outputHash = "sha256-SUu5aKWvD7V1dX/d75qUnjeWRZRgrp5+tgH84vf2jGs=";
         #outputHash = pkgs.lib.fakeHash;
      };

      millLibraries  = pkgs.stdenv.mkDerivation {
        name = "mill-libs-${version}";
        buildInputs = packagesList;
        nativeBuildInputs = packagesList ++ [millWrapper millDependencies];
        src = ./.;
        doCheck = false;

        patchPhase = millVersionPatch;

        buildPhase = ''
          runHook preBuild

          mkdir -p /tmp/home/
          cp -r '${millDependencies}/${cacheDir}/' /tmp/home
          HOME='/tmp/home' _JAVA_OPTIONS=-Duser.home='/tmp/home' COURSIER_CACHE='/tmp/home/${cacheDir}/' mill dist.publishLocal

          runHook postBuild
        '';

        installPhase = ''
           runHook preInstall
           cp -r /tmp/home/ $out/
           runHook postInstall
         '';
      };

      millBuild = pkgs.stdenv.mkDerivation {
         name = "mill-${version}";
         buildInputs = packagesList;
         nativeBuildInputs = packagesList ++ [millWrapper millLibraries millDependencies pkgs.makeWrapper];
         src = ./.;
         doCheck = false;

         patchPhase = millVersionPatch;

         buildPhase = ''
           runHook preBuild

           COURSIER_CACHE='${millDependencies}/${cacheDir}/' mill dist.assembly

           runHook postBuild
         '';

         installPhase = ''
           runHook preInstall

           mkdir -p $out/bin
           install -Dm555 out/dist/assembly.dest/mill "$out/bin/.mill"

           makeWrapper $out/bin/.mill $out/bin/mill \
             --set COURSIER_REPOSITORIES "ivy:file://${millLibraries}/.ivy2/local/${localDefaultIvyPattern}|ivy2Local|central|sonatype:releases"
           runHook postInstall
         '';
      };

    in {
      # shell providing pre-build version of mill for experimentation
      devShells.default = pkgs.mkShell { 
        buildInputs = packagesList ++ [millWrapper millDependencies];
        shellHook = ''
          echo prebuild mill path: ${millPrebuilt}
          echo mill wrapper: ${millWrapper}
          echo git mill dependencies path: ${millDependencies}
          echo git mill libraries path: ${millLibraries}
          echo final mill path: ${millBuild}
        '';
      };

      packages = { inherit millPrebuilt millWrapper millDependencies millLibraries millBuild; };
      packages.mill = millBuild;
      packages.default = millBuild;

    }
  );
}
