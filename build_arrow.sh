#!/usr/bin/env bash

set -e

CWD=$(cd $(dirname $0); pwd)

ARROW_VERSION=${ARROW_VERSION:-"25.0.0"}
NUM_CORES=${NUM_CORES:-1}

ARROW_URL="https://github.com/apache/arrow/archive/refs/tags/apache-arrow-$ARROW_VERSION.tar.gz"

ARROW_DIR=$CWD/deps/arrow-$ARROW_VERSION
ARROW_BUILD_DIR=$ARROW_DIR/build
ARROW_INSTALL_DIR=$ARROW_DIR/install
ARROW_TARBALL=$CWD/deps/apache-arrow-$ARROW_VERSION.tar.gz

rm -rf $ARROW_DIR
rm -f $ARROW_TARBALL
mkdir -p $ARROW_DIR
mkdir -p $ARROW_BUILD_DIR
mkdir -p $ARROW_INSTALL_DIR

if [ ! -f "$ARROW_TARBALL" ]; then
  echo "Downloading Apache Arrow $ARROW_VERSION from $ARROW_URL"
  curl -L $ARROW_URL -o "$ARROW_TARBALL"
fi

(cd $ARROW_DIR && \
  tar xf "$ARROW_TARBALL" && \
  mv arrow-apache-arrow-$ARROW_VERSION arrow-src \
)

echo "Downloading Apache Arrow dependencies"
(cd $ARROW_DIR/arrow-src/cpp/thirdparty && \
  ./download_dependencies.sh > $ARROW_DIR/arrow_exports.sh \
)

chpl_home=$(chpl --print-chpl-home)
chpl_cc=$($chpl_home/util/chplenv/chpl_compiler.py --host --cc --compiler-only)
chpl_cxx=$($chpl_home/util/chplenv/chpl_compiler.py --host --cxx --compiler-only)
chpl_cc_flags=$($chpl_home/util/chplenv/chpl_compiler.py --host --cc --additional)
chpl_cxx_flags=$($chpl_home/util/chplenv/chpl_compiler.py --host --cxx --additional)

echo "Building Apache Arrow $ARROW_VERSION"
(cd $ARROW_DIR && . ./arrow_exports.sh && \
  cmake -S $ARROW_DIR/arrow-src/cpp -B $ARROW_BUILD_DIR \
    -DCMAKE_VERBOSE_MAKEFILE=ON \
    -DCMAKE_INSTALL_PREFIX=$ARROW_INSTALL_DIR \
    -DCMAKE_INSTALL_LIBDIR=$ARROW_INSTALL_DIR/lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=$chpl_cc \
    -DCMAKE_C_FLAGS="$chpl_cc_flags" \
    -DCMAKE_CXX_COMPILER=$chpl_cxx \
    -DCMAKE_CXX_FLAGS="$chpl_cxx_flags" \
    -DARROW_PARQUET=ON \
    -DARROW_WITH_SNAPPY=ON \
    -DARROW_WITH_BROTLI=ON \
    -DARROW_WITH_BZ2=ON \
    -DARROW_WITH_LZ4=ON \
    -DARROW_WITH_ZLIB=ON \
    -DARROW_WITH_ZSTD=ON \
    -DARROW_DEPENDENCY_SOURCE=BUNDLED && \
  cmake --build $ARROW_BUILD_DIR --clean-first -j $NUM_CORES && \
  cmake --install $ARROW_BUILD_DIR
)

echo "export PKG_CONFIG_PATH=$ARROW_INSTALL_DIR/lib/pkgconfig:\$PKG_CONFIG_PATH" > arrow.sh

echo "Apache Arrow $ARROW_VERSION built and installed to $ARROW_INSTALL_DIR"
echo "To use it:"
echo ""
echo "  export PKG_CONFIG_PATH=$ARROW_INSTALL_DIR/lib/pkgconfig:\$PKG_CONFIG_PATH"
echo ""
echo "OR"
echo ""
echo "  . ./arrow.sh"
echo ""
