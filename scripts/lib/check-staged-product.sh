#!/bin/bash
# check_staged_product — accept a freshly built single-architecture product only if it
# is the binary this run was supposed to build (#238).
#
# Under the swiftbuild build system both `swift build --arch` runs write to one shared
# directory, so a product can be stale (left by an earlier build) without any error.
# build-mcpb.sh copies each product into its stage directory right after the product's
# own build and runs this check on the staged copy, the file that is then packaged:
#   1. the file exists;
#   2. it contains exactly the requested architecture (`lipo -archs`);
#   3. run under that architecture, `--version` exits 0 and the first line of its
#      stdout is exactly "<binary name> <version>" (stderr is not compared).
# Step 3 needs a host that can execute the architecture (x86_64 on Apple Silicon needs
# Rosetta; arm64 cannot run on Intel). When it cannot: with CHECK_STAGED_STRICT=1 (set
# by build-mcpb.sh when csp_release_build says the build will be signed or must be) the
# check fails; otherwise it prints a note and passes on steps 1-2 only — it never skips
# silently. Step 3 checks the version string, not the content: a product built from
# older code under the same version string still passes.
#
# Also here: csp_decide_signing (the one signing decision build-mcpb.sh uses both to sign
# and to choose strict checking), check_packaged_slices (the universal binary holds
# exactly arm64 and x86_64, byte-identical to the checked products), check_final_binary
# (the signed file still holds exactly those two slices and each reports the version), and
# csp_clear_release_artifacts (a failed run leaves no file that looks shippable).
#
# The checks of a binary call arch, lipo and cmp by absolute path and count slices in
# bash, so a PATH shim cannot change those verdicts; /usr/bin/lipo is an xcrun shim, so
# DEVELOPER_DIR can still select a different toolchain. head and tr (message cleaning) and
# the keychain lookup (security, grep) are taken from PATH. Messages go to stderr;
# non-zero on any failure.

CSP_ARCH=/usr/bin/arch
CSP_LIPO=/usr/bin/lipo
CSP_CMP=/usr/bin/cmp

# csp_decide_signing — sets SHOULD_SIGN (true/false) and SKIP_REASON. build-mcpb.sh makes
# this decision once, before building, and uses it both to sign and to choose strict
# checking, so the two cannot disagree. SKIP_CODESIGN 1/true skips; otherwise signing
# needs DEVELOPER_ID and that identity in the keychain.
csp_decide_signing() {
    SHOULD_SIGN=true
    SKIP_REASON=""
    if [[ "${SKIP_CODESIGN:-}" == "1" || "${SKIP_CODESIGN:-}" == "true" ]]; then
        SHOULD_SIGN=false
        SKIP_REASON="SKIP_CODESIGN=$SKIP_CODESIGN"
    elif [[ -z "${DEVELOPER_ID:-}" ]]; then
        SHOULD_SIGN=false
        SKIP_REASON="DEVELOPER_ID env not set"
    elif ! _csp_codesigning_identities | grep -qF -- "$DEVELOPER_ID"; then
        SHOULD_SIGN=false
        SKIP_REASON="codesigning identity '$DEVELOPER_ID' not in keychain"
    fi
}

_csp_codesigning_identities() {
    security find-identity -p codesigning -v 2>/dev/null
}

# csp_release_build — 0 when the staged checks must be strict: csp_decide_signing chose to
# sign, or REQUIRE_CODESIGN is 1/true (a build that must be signed; build-mcpb.sh refuses
# it at signing when it cannot sign). Call csp_decide_signing first.
csp_release_build() {
    case "${REQUIRE_CODESIGN:-}" in 1|true) return 0 ;; esac
    [[ "${SHOULD_SIGN:-false}" == true ]]
}

# host_can_execute_arch <arch> — 0 when this host can run code of that architecture.
# Probes a system binary that ships with both architectures.
host_can_execute_arch() {
    "$CSP_ARCH" -"$1" /usr/bin/true >/dev/null 2>&1
}

# _csp_clean <text> — first 300 bytes, printable characters only (for error messages).
_csp_clean() {
    printf '%s' "$1" | head -c 300 | LC_ALL=C tr -cd '[:print:]\n'
}

# check_staged_product <product> <arch> <binary name> <expected version>
check_staged_product() {
    local product="$1" arch="$2" name="$3" version="$4"
    local archs out err rc first errfile
    if [[ ! -f "$product" ]]; then
        echo "Error: no $arch product at $product (#238)" >&2
        return 1
    fi
    if ! archs=$("$CSP_LIPO" -archs "$product" 2>&1); then
        echo "Error: cannot read the architectures of $product: $(_csp_clean "$archs") (#238)" >&2
        return 1
    fi
    if [[ "$archs" != "$arch" ]]; then
        echo "Error: $product contains '$(_csp_clean "$archs")', expected '$arch' (#238)" >&2
        return 1
    fi
    _csp_run_version "$product" "$arch" "$name" "$version" "$arch product"
}

# _csp_run_version <file> <arch> <name> <version> <label> — run <file> as <arch> and
# require the first stdout line of --version to be exactly "<name> <version>". Applies
# the unexecutable-architecture rule (note, or failure in strict mode).
_csp_run_version() {
    local file="$1" arch="$2" name="$3" version="$4" label="$5"
    local out err rc first errfile
    if ! host_can_execute_arch "$arch"; then
        if [[ "${CHECK_STAGED_STRICT:-0}" == 1 ]]; then
            echo "Error: this host cannot execute $arch code, so the $label's version cannot be checked on this host; strict mode (release build) refuses to package it unchecked. On Apple Silicon install Rosetta (softwareupdate --install-rosetta); an Intel host cannot run arm64 at all (#238)" >&2
            return 1
        fi
        echo "Note: this host cannot execute $arch code, so the $label's version is not checked (architecture checked only)." >&2
        return 0
    fi
    errfile=$(mktemp "${TMPDIR:-/tmp}/csp-stderr.XXXXXX") || { echo "Error: cannot create a temp file (#238)" >&2; return 1; }
    out=$("$CSP_ARCH" -"$arch" "$file" --version 2>"$errfile" </dev/null) && rc=0 || rc=$?
    err=$(cat "$errfile"); rm -f "$errfile"
    if [[ $rc -ne 0 ]]; then
        echo "Error: the $label could not be run (exit $rc): $(_csp_clean "$out$err") (#238)" >&2
        return 1
    fi
    first=${out%%$'\n'*}
    if [[ "$first" != "$name $version" ]]; then
        echo "Error: the $label reports '$(_csp_clean "$first")', but the sources are at $version — stale build product (#238)" >&2
        return 1
    fi
    echo "  ✓ $label reports $name $version"
}

# _csp_two_slices <file> — the file must hold exactly arm64 and x86_64. Counted in bash
# (no external tool), so nothing on PATH can change the verdict.
_csp_two_slices() {
    local file="$1" archs slices=()
    if ! archs=$("$CSP_LIPO" -archs "$file" 2>&1); then
        echo "Error: cannot read the architectures of $file: $(_csp_clean "$archs") (#238)" >&2
        return 1
    fi
    read -ra slices <<< "${archs//$'\n'/ }"
    if [[ ${#slices[@]} -ne 2 || " ${slices[*]} " != *" arm64 "* || " ${slices[*]} " != *" x86_64 "* ]]; then
        echo "Error: $file has slices '$(_csp_clean "$archs")', expected exactly arm64 and x86_64 (#238)" >&2
        return 1
    fi
}

# check_packaged_slices <universal> <stage dir> <name> — the universal binary must hold
# exactly arm64 and x86_64, each byte-identical to <stage dir>/<name>-<arch>.
check_packaged_slices() {
    local universal="$1" stage="$2" name="$3" arch thin
    _csp_two_slices "$universal" || return 1
    for arch in arm64 x86_64; do
        thin="$stage/packaged-$arch"
        "$CSP_LIPO" -thin "$arch" "$universal" -output "$thin" || { echo "Error: cannot extract the $arch slice of $universal (#238)" >&2; return 1; }
        if ! "$CSP_CMP" -s "$thin" "$stage/$name-$arch"; then
            echo "Error: the $arch slice in $universal differs from the checked product (#238)" >&2
            return 1
        fi
    done
    echo "  ✓ packaged slices match the checked products"
}

# check_final_binary <binary> <name> <version> — after signing rewrote the file: it must
# still hold exactly arm64 and x86_64 (signing must not drop or add a slice), and each
# slice this host can execute must report the version (strict rules for the others).
check_final_binary() {
    local binary="$1" name="$2" version="$3" arch
    _csp_two_slices "$binary" || return 1
    for arch in arm64 x86_64; do
        _csp_run_version "$binary" "$arch" "$name" "$version" "final binary ($arch)" || return 1
    done
}

# csp_clear_release_artifacts <packed .mcpb> <universal binary> — remove this version's
# release files and their .sha256 companions. build-mcpb.sh runs it before building and
# when a run fails, so a failed run leaves nothing that looks shippable (#238: a stale
# .mcpb that reported 1.18.0 sat where a v1.19.0 release would pick it up).
csp_clear_release_artifacts() {
    local f
    for f in "$1" "$1.sha256" "$2" "$2.sha256"; do
        /bin/rm -f -- "$f"
    done
}
