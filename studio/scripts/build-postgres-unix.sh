#!/usr/bin/env bash
# Builds Postgres + pgvector for a single platform.
# Requires env vars: PG_VERSION, PGVECTOR_VERSION, PLATFORM (darwin|linux), ARCH (x64|arm64).
# Emits a tarball at $GITHUB_WORKSPACE/postgres-${PG_VERSION}-${PLATFORM}-${ARCH}.tar.gz.
set -euo pipefail

WORK=$(mktemp -d)
PREFIX="${WORK}/postgres"
mkdir -p "${PREFIX}"

# --- 1. Build Postgres ----------------------------------------------
curl -fSL "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz" \
  | tar -xz -C "${WORK}"
cd "${WORK}/postgresql-${PG_VERSION}"

# --without-icu skips a fat ICU dep (PG falls back to libc collation).
# --without-readline avoids a non-portable libreadline link.
# --without-zlib trades pg_dump compression for a smaller surface.
./configure \
  --prefix="${PREFIX}" \
  --without-icu \
  --without-readline \
  --without-zlib \
  --with-openssl=no \
  --disable-rpath
make -j"$(getconf _NPROCESSORS_ONLN)" world-bin
make install-world-bin

# --- 2. Build pgvector against the just-installed PG ----------------
curl -fSL "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
  | tar -xz -C "${WORK}"
cd "${WORK}/pgvector-${PGVECTOR_VERSION}"
PG_CONFIG="${PREFIX}/bin/pg_config" make -j"$(getconf _NPROCESSORS_ONLN)"
PG_CONFIG="${PREFIX}/bin/pg_config" make install

# --- 3. Strip + relocatable install_names + tarball -----------------
# `strip` without flags removes the dynamic symbol table on macOS, which
# breaks dlopen of PG's own extensions (dict_snowball, vector, etc.)
# with "Symbol not found: _CurrentMemoryContext". Use `-x` to drop only
# locals + debug; keep exported symbols intact so extensions can resolve
# postgres internals. Linux `strip` is less aggressive by default but
# `-S` (strip debug only) gives the same guarantee.
if [ "${PLATFORM}" = "darwin" ]; then
  find "${PREFIX}/bin" -type f -perm -u+x -exec strip -x {} + 2>/dev/null || true
  find "${PREFIX}/lib" -type f -name '*.dylib' -exec strip -x {} + 2>/dev/null || true
else
  find "${PREFIX}/bin" -type f -perm -u+x -exec strip -S {} + 2>/dev/null || true
  find "${PREFIX}/lib" -type f -name '*.so' -exec strip -S {} + 2>/dev/null || true
fi

# Make dylib references relocatable. The build's --prefix is a
# /var/folders/.../postgres temp dir that doesn't exist on the user's
# machine; binaries link with that absolute path in their LC_LOAD_DYLIB
# / DT_NEEDED entries. On macOS we rewrite every reference + every
# install_name to @rpath/<basename> and set @loader_path/../lib as the
# rpath on each binary. On Linux we use patchelf to set RUNPATH to
# $ORIGIN/../lib (lib siblings of bin).
if [ "${PLATFORM}" = "darwin" ]; then
  # First pass: rewrite each dylib's own install_name to @rpath/<base>.
  find "${PREFIX}/lib" -type f -name '*.dylib' | while read -r dylib; do
    install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib" 2>/dev/null || true
  done
  # Second pass: rewrite cross-dylib references + binary references
  # from the absolute prefix path to @rpath/<basename>.
  rewrite_refs() {
    local target="$1"
    otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}' | while read -r ref; do
      case "$ref" in
        "${PREFIX}"/*)
          install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$target" 2>/dev/null || true
          ;;
      esac
    done
  }
  find "${PREFIX}/bin" -type f -perm -u+x | while read -r bin; do
    rewrite_refs "$bin"
    install_name_tool -add_rpath "@loader_path/../lib" "$bin" 2>/dev/null || true
  done
  find "${PREFIX}/lib" -type f -name '*.dylib' | while read -r dylib; do
    rewrite_refs "$dylib"
  done
else
  # Linux: patchelf may not be installed (it isn't on ubuntu-22.04 by
  # default) — only attempt if available, otherwise skip and rely on
  # the runtime LD_LIBRARY_PATH overlay in postgres.ts.
  if command -v patchelf >/dev/null 2>&1; then
    find "${PREFIX}/bin" -type f -perm -u+x | while read -r bin; do
      patchelf --set-rpath '$ORIGIN/../lib' "$bin" 2>/dev/null || true
    done
    find "${PREFIX}/lib" -type f -name '*.so*' | while read -r so; do
      patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
    done
  fi
fi

cd "${WORK}"
OUT="${GITHUB_WORKSPACE}/postgres-${PG_VERSION}-${PLATFORM}-${ARCH}.tar.gz"
tar -czf "${OUT}" postgres
echo "Built ${OUT} ($(du -h "${OUT}" | cut -f1))"
