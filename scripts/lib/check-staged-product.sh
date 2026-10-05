#!/bin/bash
# check_staged_product — accept a freshly built single-architecture product only if it
# is the binary this run was supposed to build (#238).
#
# Under the swiftbuild build system both `swift build --arch` runs write to one shared
# directory, so a product can be stale (left by an earlier build) without any error.
# Each staged product is therefore checked right after its own build:
#   1. the file exists;
#   2. it contains exactly the requested architecture (`lipo -archs`);
#   3. run under that architecture, `--version` exits 0 and its first line is exactly
#      "<binary name> <version>".
# Step 3 needs a host that can execute the architecture (x86_64 on Apple Silicon needs
# Rosetta). When it cannot, the check says so and passes on steps 1-2 only — it never
# skips silently. Step 3 checks the version string, not the content: a product built
# from older code under the same version string still passes.
#
# Messages go to stderr; returns non-zero on any failure.

# host_can_execute_arch <arch> — 0 when this host can run code of that architecture.
host_can_execute_arch() {
    arch -"$1" /usr/bin/true >/dev/null 2>&1
}

# check_staged_product <product> <arch> <binary name> <expected version>
check_staged_product() {
    local product="$1" arch="$2" name="$3" version="$4" archs out rc first
    if [[ ! -f "$product" ]]; then
        echo "Error: no $arch product at $product (#238)" >&2
        return 1
    fi
    if ! archs=$(lipo -archs "$product" 2>&1); then
        echo "Error: cannot read the architectures of $product: $archs (#238)" >&2
        return 1
    fi
    if [[ "$archs" != "$arch" ]]; then
        echo "Error: $product contains '$archs', expected '$arch' (#238)" >&2
        return 1
    fi
    if ! host_can_execute_arch "$arch"; then
        echo "Note: this host cannot execute $arch code, so the $arch product's version not checked (architecture checked only)." >&2
        return 0
    fi
    out=$(arch -"$arch" "$product" --version 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "Error: the $arch product could not be run (exit $rc): $out (#238)" >&2
        return 1
    fi
    first=${out%%$'\n'*}
    if [[ "$first" != "$name $version" ]]; then
        echo "Error: the $arch product reports '$first', but the sources are at $version — stale build product (#238)" >&2
        return 1
    fi
    echo "  ✓ $arch product reports $name $version"
}
