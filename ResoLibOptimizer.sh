#!/bin/bash

ResoDir="$HOME/.steam/steam/steamapps/common/Resonite"

# Setup work dir and remove if existing
rm -rf /tmp/ResoLibOptimizer
mkdir /tmp/ResoLibOptimizer
cd /tmp/ResoLibOptimizer

# Clone and compile optimized Brotli
git clone --depth=1 https://github.com/Yellow-Dog-Man/brotli
cd brotli
mkdir out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=./installed .. -DCMAKE_C_FLAGS="-O3 -march=native" 
cmake --build . --config Release

# Replace Resonite's Brotli files
rm "${ResoDir}/brolib_x64.so"
rm "${ResoDir}/runtimes/linux/native/brolib_x64.so"
cp "/tmp/ResoLibOptimizer/brotli/out/libbrolib.so" "${ResoDir}/brolib_x64.so"
cp "/tmp/ResoLibOptimizer/brotli/out/libbrolib.so" "${ResoDir}/runtimes/linux/native/brolib_x64.so"
