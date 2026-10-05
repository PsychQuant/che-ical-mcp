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
# Rosetta; arm64 cannot run on Intel). When it cannot: with CHECK_STAGED_STRICT=1 (the
# release path, REQUIRE_CODESIGN=1) the check fails; otherwise it prints a note and
# passes on steps 1-2 only — it never skips silently. Step 3 checks the version string,
# not the content: a product built from older code under the same version string
# still passes.
#
# Tools are called by absolute path so a PATH shim cannot change the result.
# Messages go to stderr; returns non-zero on any failure.

CSP_ARCH=/usr/bin/arch
CSP_LIPO=/usr/bin/lipo

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
    if ! host_can_execute_arch "$arch"; then
        if [[ "${CHECK_STAGED_STRICT:-0}" == 1 ]]; then
            echo "Error: this host cannot execute $arch code, so the $arch product's version cannot be checked on this host; strict mode (release build) refuses to package it unchecked. Install Rosetta (softwareupdate --install-rosetta) or build on a host that can run $arch (#238)" >&2
            return 1
        fi
        echo "Note: this host cannot execute $arch code, so the $arch product's version is not checked (architecture checked only)." >&2
        return 0
    fi
    errfile=$(mktemp "${TMPDIR:-/tmp}/csp-stderr.XXXXXX") || { echo "Error: cannot create a temp file (#238)" >&2; return 1; }
    out=$("$CSP_ARCH" -"$arch" "$product" --version 2>"$errfile") && rc=0 || rc=$?
    err=$(cat "$errfile"); rm -f "$errfile"
    if [[ $rc -ne 0 ]]; then
        echo "Error: the $arch product could not be run (exit $rc): $(_csp_clean "$out$err") (#238)" >&2
        return 1
    fi
    first=${out%%$'\n'*}
    if [[ "$first" != "$name $version" ]]; then
        echo "Error: the $arch product reports '$(_csp_clean "$first")', but the sources are at $version — stale build product (#238)" >&2
        return 1
    fi
    echo "  ✓ $arch product reports $name $version"
}
