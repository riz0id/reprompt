# Racket (full distribution) plus the vendored rash package closure and
# the cli-spec interface-specification language, installed offline into
# an immutable user-scope layer ($out/addon).
#
# Only these six packages need vendoring: every other dependency they
# declare (base, scribble-lib, scribble-doc, racket-doc, rackunit-lib,
# readline-lib, sandbox-lib) ships in installation scope of the full
# Racket distribution that nixpkgs' `racket` builds, so
# `raco pkg install --deps fail` passes with no catalog and no network.
#
# Rash resolves external commands with find-executable-path (pure PATH
# lookup, no /bin/sh), so consumers must put the binaries a #lang rash
# module invokes (e.g. coreutils for echo) on PATH themselves.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  racket,
  makeWrapper,
}:

let
  # rash, linea and shell-pipeline are subdirectory packages of one repo.
  rashRepo = fetchFromGitHub {
    owner = "willghatch";
    repo = "racket-rash";
    rev = "feb3ad16deb0b372a05f5d522f71e1746a3f96fd";
    hash = "sha256-3lsj5WwDCJukWrBQlKiu2XfO5uoNAxi3iV6lmO3mFaU=";
  };
  udelimSrc = fetchFromGitHub {
    owner = "willghatch";
    repo = "racket-udelim";
    rev = "6bdfb2af13bc27eb68d2e210b6ac7e19d2d1c826";
    hash = "sha256-b6HEgxAKzTOCzbuBHXBWrRELOwlnCB0Lg5mdaHJwkmY=";
  };
  basedirSrc = fetchFromGitHub {
    owner = "willghatch";
    repo = "racket-basedir";
    rev = "487dfc49ff3268b76dea9aa2011ddfe585da2672";
    hash = "sha256-Ia+wFnUSKMfhot0f8I8TFCPtGEdwy9gnnrnBEgNvSt0=";
  };
  # The interface-specification language the cli/ transformer library's
  # specs are written in. Collection name is cli-spec (see its info.rkt),
  # so it must be staged under that name. Depends only on base.
  cliSpecSrc = fetchFromGitHub {
    owner = "riz0id";
    repo = "cli-syntax";
    rev = "1cfed7b40f91210c3b92d676671abb5f5b47b96c";
    hash = "sha256-sTJkWSsRGGIt56PRr9hoWi+ez5CjbCUTXtamlfDrseo=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "racket-with-rash";
  version = "${racket.version}-rash-0.3";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  buildPhase = ''
    runHook preBuild

    # Stage sources under their package names (raco infers the package
    # name from the directory name; fetchFromGitHub outputs are named
    # "source") and make them writable so raco's copies are writable too.
    mkdir staging
    cp -R ${udelimSrc} staging/udelim
    cp -R ${basedirSrc} staging/basedir
    cp -R ${rashRepo}/shell-pipeline staging/shell-pipeline
    cp -R ${rashRepo}/linea staging/linea
    cp -R ${rashRepo}/rash staging/rash
    cp -R ${cliSpecSrc} staging/cli-spec
    chmod -R u+w staging

    # Install into an immutable user-scope layer under $out. Directory
    # sources install as links by default, so --copy is mandatory; one
    # invocation lets the five packages satisfy each other's deps.
    export HOME=$(mktemp -d)
    export PLTADDONDIR=$out/addon
    ${racket}/bin/raco pkg install \
      --batch --deps fail --no-docs --copy --scope user \
      --jobs "''${NIX_BUILD_CORES:-1}" \
      staging/udelim staging/basedir staging/shell-pipeline \
      staging/linea staging/rash staging/cli-spec

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    for exe in racket raco; do
      makeWrapper ${racket}/bin/$exe $out/bin/$exe \
        --set PLTADDONDIR $out/addon
    done

    runHook postInstall
  '';

  # Fail fast if the layer is broken. `echo` is an external command that
  # rash resolves via PATH (coreutils is on the stdenv build PATH).
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    printf '#lang rash\necho hi from rash\n' > t.rkt
    $out/bin/racket t.rkt | grep -q "hi from rash"
    $out/bin/racket -e '(require cli-spec) (void (cmd (quote ok)))'
    runHook postInstallCheck
  '';

  meta = {
    description = "Racket with the rash shell language pre-installed (offline layer)";
    inherit (racket.meta) platforms;
    license = with lib.licenses; [
      asl20
      mit
    ];
  };
}
