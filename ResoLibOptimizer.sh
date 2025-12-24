#!/bin/bash

set -exuo pipefail

# Reso-Lib-Optimizer - Linux only script to optimize Resonite libraries
# This script compiles optimized versions of native libraries used by Resonite
# and replaces the original libraries in your Resonite installation.

# Default Resonite installation directory
# You can override this by setting the RESONITE_DIR environment variable
# Example: RESONITE_DIR="/path/to/Resonite" ./ResoLibOptimizer.sh
ResoDir="${RESONITE_DIR:-$HOME/.local/share/Steam/steamapps/common/Resonite}"

# Optimization flags for compilation
OptimizedFlags="-march=native -O3 -pipe -fno-semantic-interposition -flto -ffat-lto-objects"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print error messages
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

# Function to print warning messages
warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Function to print success messages
success() {
    echo -e "${GREEN}$1${NC}"
}

# Check if running on Linux
if [[ "$OSTYPE" != "linux-gnu"* ]]; then
    error "This script is Linux-only. Current OS: $OSTYPE"
    exit 1
fi

# Check for required dependencies
echo "Checking for required build tools..."
missing_deps=()

command -v git >/dev/null 2>&1 || missing_deps+=("git")
command -v cmake >/dev/null 2>&1 || missing_deps+=("cmake")
command -v gcc >/dev/null 2>&1 || missing_deps+=("gcc")
command -v g++ >/dev/null 2>&1 || missing_deps+=("g++")
command -v make >/dev/null 2>&1 || missing_deps+=("make")

if [ ${#missing_deps[@]} -ne 0 ]; then
    error "Missing required dependencies: ${missing_deps[*]}"
    echo "Please install them using your package manager:"
    echo "  Debian/Ubuntu: sudo apt-get install git cmake build-essential"
    echo "  Arch/Manjaro: sudo pacman -S git cmake base-devel"
    echo "  Fedora: sudo dnf install git cmake gcc gcc-c++ make"
    exit 1
fi

success "All required dependencies found"

# Validate Resonite directory
if [ ! -d "$ResoDir" ]; then
    error "Resonite directory not found: $ResoDir"
    echo "Please set the RESONITE_DIR environment variable to your Resonite installation path"
    echo "Example: export RESONITE_DIR=\"/path/to/Resonite\""
    exit 1
fi

if [ ! -w "$ResoDir" ]; then
    error "Resonite directory is not writable: $ResoDir"
    echo "You may need to run this script with appropriate permissions"
    exit 1
fi

success "Resonite directory found: $ResoDir"

# Check for required subdirectories
required_dirs=(
    "$ResoDir/runtimes/linux-x64/native"
    "$ResoDir/runtimes/linux/native"
)

for dir in "${required_dirs[@]}"; do
    if [ ! -d "$dir" ]; then
        error "Required directory not found: $dir"
        error "This may not be a valid Resonite installation"
        exit 1
    fi
done

success "Resonite installation structure validated"

# Setup work dir and remove if existing
WORK_DIR="/tmp/ResoLibOptimizer"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" || { error "Failed to create work directory"; exit 1; }
cd "$WORK_DIR" || { error "Failed to change to work directory"; exit 1; }

# Clone and compile an optimized assimp
echo ""
echo "=== Compiling assimp ==="
git clone --depth=1 https://github.com/Yellow-Dog-Man/assimp
cd assimp
cmake CMakeLists.txt -DASSIMP_WARNINGS_AS_ERRORS=OFF -DCMAKE_C_FLAGS="${OptimizedFlags}" -DCMAKE_CXX_FLAGS="${OptimizedFlags}" 
cmake --build . -j$(nproc)

# Replace Resonite's assimp files
rm "${ResoDir}/runtimes/linux-x64/native/libassimp.so"
cp "${WORK_DIR}/assimp/bin/libassimp.so.5.3.0" "${ResoDir}/runtimes/linux-x64/native/libassimp.so"
success "assimp compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized brotli
echo ""
echo "=== Compiling brotli ==="
git clone --depth=1 https://github.com/Yellow-Dog-Man/brotli
cd brotli
mkdir out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=./installed -DCMAKE_C_FLAGS=" ${OptimizedFlags}" ..
cmake --build . --config Release -j$(nproc)

# Replace Resonite's brotli files
rm "${ResoDir}/brolib_x64.so"
rm "${ResoDir}/runtimes/linux/native/brolib_x64.so"
cp "${WORK_DIR}/brotli/out/libbrolib.so" "${ResoDir}/runtimes/linux/native/brolib_x64.so"
ln "${ResoDir}/runtimes/linux/native/brolib_x64.so" "${ResoDir}/brolib_x64.so"
success "brotli compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized compressonator
echo ""
echo "=== Compiling compressonator ==="
# Pull fresh from upstream (upstream has hardcoded AVX512 testing that we need to handle)
echo "Cloning latest compressonator from upstream..."
git clone --depth=1 https://github.com/Yellow-Dog-Man/compressonator
cd compressonator

# Apply necessary patches
sed -i '33i\#include <cstdint>\' ./applications/_plugins/common/pluginbase.h
# Replace 'knl' with 'native' to use CPU-specific optimizations (upstream uses x86-64-v4, but native is better)
sed -i -e 's/knl/native/g' ./build/sdk/cmp_core/CMakeLists.txt 2>/dev/null || true
sed -i -e 's/knl/native/g' ./cmp_core/CMakeLists.txt 2>/dev/null || true

# Check if CPU supports AVX512
if grep -q "avx512" /proc/cpuinfo 2>/dev/null; then
    AVX512_SUPPORTED=true
    echo "CPU supports AVX512 - will build AVX512 optimizations"
else
    AVX512_SUPPORTED=false
    warning "CPU does not support AVX512 - skipping AVX512 target (upstream has hardcoded AVX512)"
fi

# Disable EXR support due to type conflict between CUDA's half typedef and compressonator's half class
# EXR would require source code patches to resolve the conflict
# Note: All BCn texture formats (BC1-BC7) still work without EXR
cmake -DOPTION_ENABLE_ALL_APPS=OFF -DOPTION_BUILD_CMP_SDK=ON -DOPTION_CMP_QT=OFF -DOPTION_BUILD_KTX2=ON -DOPTION_BUILD_EXR=OFF -DOPTION_BUILD_GUI=OFF -DBUILD_SHARED_LIBS=ON -DCMAKE_C_FLAGS="${OptimizedFlags}" -DCMAKE_CXX_FLAGS="${OptimizedFlags}" .

# Remove AVX512 target from CMakeLists.txt only if CPU doesn't support it
# Upstream has hardcoded AVX512 testing, so we need to remove it for non-AVX512 CPUs
if [ "$AVX512_SUPPORTED" = false ]; then
    # Remove AVX512 target from CMakeLists.txt files
    if [ -f "cmp_core/CMakeLists.txt" ]; then
        sed -i '/CMP_Core_AVX512/d' cmp_core/CMakeLists.txt 2>/dev/null || true
    fi
    # Also check build directory if it exists
    if [ -f "build/sdk/cmp_core/CMakeLists.txt" ]; then
        sed -i '/CMP_Core_AVX512/d' build/sdk/cmp_core/CMakeLists.txt 2>/dev/null || true
    fi
    # Re-run cmake to regenerate build files without AVX512
    cmake . >/dev/null 2>&1 || true
fi

# Build using make directly with -k flag to continue on errors
# This allows the build to complete even if some optional targets fail
if [ "$AVX512_SUPPORTED" = false ]; then
    warning "Building compressonator (AVX512 target excluded - CPU doesn't support it)..."
    CPLUS_INCLUDE_PATH=/usr/include/opencv4 make -j$(nproc) -k 2>&1 | grep -v "CMP_Core_AVX512" || true
else
    echo "Building compressonator with all optimizations (including AVX512)..."
    CPLUS_INCLUDE_PATH=/usr/include/opencv4 make -j$(nproc) -k 2>&1 || true
fi

# Check if required libraries were built
if [ ! -f "lib/libCMP_Compressonator.so" ] || [ ! -f "lib/libCMP_Framework.so" ]; then
    error "compressonator build failed - required libraries not found"
    exit 1
else
    if [ "$AVX512_SUPPORTED" = true ]; then
        success "compressonator libraries built successfully (with AVX512 optimizations)"
    else
        success "compressonator libraries built successfully (AVX512 skipped - not supported)"
    fi
fi

# Replace Resonite's compressonator files
rm "${ResoDir}/libCMP_Compressonator.so"
rm "${ResoDir}/libCMP_Framework.so"
rm "${ResoDir}/runtimes/linux-x64/native/libCMP_Compressonator.so"
rm "${ResoDir}/runtimes/linux-x64/native/libCMP_Framework.so"
cp "${WORK_DIR}/compressonator/lib/libCMP_Compressonator.so" "${ResoDir}/runtimes/linux-x64/native/libCMP_Compressonator.so"
cp "${WORK_DIR}/compressonator/lib/libCMP_Framework.so" "${ResoDir}/runtimes/linux-x64/native/libCMP_Framework.so"
ln "${ResoDir}/runtimes/linux-x64/native/libCMP_Compressonator.so" "${ResoDir}/libCMP_Compressonator.so"
ln "${ResoDir}/runtimes/linux-x64/native/libCMP_Framework.so" "${ResoDir}/libCMP_Framework.so"
success "compressonator compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized crunch
echo ""
echo "=== Compiling crunch ==="
git clone --depth=1 https://github.com/Yellow-Dog-Man/crunch
cd crunch
mkdir out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="${OptimizedFlags}" -DCMAKE_CXX_FLAGS="${OptimizedFlags}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 .. 
cmake --build . --config Release -j$(nproc)

# Replace Resonite's crunch files
rm "${ResoDir}/libcrnlib.so"
rm "${ResoDir}/runtimes/linux-x64/native/libcrnlib.so"
cp "${WORK_DIR}/crunch/out/libcrnlib.so" "${ResoDir}/runtimes/linux-x64/native/libcrnlib.so"
ln "${ResoDir}/runtimes/linux-x64/native/libcrnlib.so" "${ResoDir}/libcrnlib.so"
success "crunch compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized FreeImage
echo ""
echo "=== Compiling FreeImage ==="
git clone https://github.com/Yellow-Dog-Man/FreeImage
cd FreeImage
git fetch origin pull/21/head:EncodingTweaks
git fetch origin pull/23/head:compilation-fixes
git switch EncodingTweaks
git rebase compilation-fixes
git rebase main
make all CFLAGS="-w -fPIC -fexceptions -fvisibility=hidden -D__ANSI__ -I. -ISource -ISource/Metadata -ISource/FreeImageToolkit -ISource/LibJPEG -ISource/LibPNG -ISource/LibTIFF4 -ISource/ZLib -ISource/LibOpenJPEG -ISource/OpenEXR -ISource/OpenEXR/Half -ISource/OpenEXR/Iex -ISource/OpenEXR/IlmImf -ISource/OpenEXR/IlmThread -ISource/OpenEXR/Imath -ISource/OpenEXR/IexMath -ISource/LibRawLite -ISource/LibRawLite/dcraw -ISource/LibRawLite/internal -ISource/LibRawLite/libraw -ISource/LibRawLite/src -ISource/LibWebP -ISource/LibJXR -ISource/LibJXR/common/include -ISource/LibJXR/image/sys -ISource/LibJXR/jxrgluelib -fPIC ${OptimizedFlags}" CXXFLAGS="-w -fPIC -fexceptions -fvisibility=hidden -Wno-ctor-dtor-privacy -std=c++11 -D__ANSI__ -I. -ISource -ISource/Metadata -ISource/FreeImageToolkit -ISource/LibJPEG -ISource/LibPNG -ISource/LibTIFF4 -ISource/ZLib -ISource/LibOpenJPEG -ISource/OpenEXR -ISource/OpenEXR/Half -ISource/OpenEXR/Iex -ISource/OpenEXR/IlmImf -ISource/OpenEXR/IlmThread -ISource/OpenEXR/Imath -ISource/OpenEXR/IexMath -ISource/LibRawLite -ISource/LibRawLite/dcraw -ISource/LibRawLite/internal -ISource/LibRawLite/libraw -ISource/LibRawLite/src -ISource/LibWebP -ISource/LibJXR -ISource/LibJXR/common/include -ISource/LibJXR/image/sys -ISource/LibJXR/jxrgluelib -fPIC ${OptimizedFlags}" -j$(nproc)

# Replace Resonite's FreeImage files
rm "${ResoDir}/libFreeImage.so"
rm "${ResoDir}/runtimes/linux-x64/native/FreeImage.h"
rm "${ResoDir}/runtimes/linux-x64/native/libFreeImage.a"
rm "${ResoDir}/runtimes/linux-x64/native/libFreeImage.so"
cp -r "${WORK_DIR}/FreeImage/Dist/FreeImage.h" "${ResoDir}/runtimes/linux-x64/native/"
cp -r "${WORK_DIR}/FreeImage/Dist/libFreeImage.a" "${ResoDir}/runtimes/linux-x64/native/"
cp -r "${WORK_DIR}/FreeImage/Dist/libFreeImage.so" "${ResoDir}/runtimes/linux-x64/native/"
ln "${ResoDir}/runtimes/linux-x64/native/libFreeImage.so" "${ResoDir}/libFreeImage.so"
success "FreeImage compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized mikktspace
echo ""
echo "=== Compiling mikktspace ==="
git clone --depth=1 https://github.com/Yellow-Dog-Man/Mikktspace.NET
cd Mikktspace.NET/Native
mkdir out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="${OptimizedFlags}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 .. 
cmake --build . --config Release -j$(nproc)

# Replace Resonite's mikktspace files
rm "${ResoDir}/runtimes/linux-x64/native/libmikktspace.so"
cp "${WORK_DIR}/Mikktspace.NET/Native/out/libmikktspace.so" "${ResoDir}/runtimes/linux-x64/native/libmikktspace.so"
success "mikktspace compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized miniaudio
echo ""
echo "=== Compiling miniaudio ==="
git clone --depth=1 --recurse-submodules https://github.com/LSXPrime/SoundFlow
cd SoundFlow/Native/miniaudio-backend
mkdir out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="${OptimizedFlags}" .. 
cmake --build . --config Release -j$(nproc)

# Replace Resonite's miniaudio files
rm "${ResoDir}/runtimes/linux-x64/native/libminiaudio.so"
cp "${WORK_DIR}/SoundFlow/Native/miniaudio-backend/out/libminiaudio.so" "${ResoDir}/runtimes/linux-x64/native/libminiaudio.so"
success "miniaudio compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized msdfgen
echo ""
echo "=== Compiling msdfgen ==="
git clone --depth=1 https://github.com/Yellow-Dog-Man/msdfgen
cd msdfgen
cmake -DCMAKE_BUILD_TYPE=Release -DMSDFGEN_BUILD_STANDALONE=OFF -DMSDFGEN_BUILD_SHARED_LIBRARY=ON -DCMAKE_CXX_FLAGS="${OptimizedFlags}" .
cmake --build . --config Release -j$(nproc)

# Replace Resonite's msdfgen files
rm "${ResoDir}/libmsdfgen.so"
rm "${ResoDir}/runtimes/linux-x64/native/libmsdfgen.so"
cp "${WORK_DIR}/msdfgen/out/libmsdfgen.so" "${ResoDir}/runtimes/linux-x64/native/libmsdfgen.so"
ln "${ResoDir}/runtimes/linux-x64/native/libmsdfgen.so" "${ResoDir}/libmsdfgen.so"
success "msdfgen compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized opus
echo ""
echo "=== Compiling opus ==="
git clone --depth=1 https://github.com/Yellow-Dog-Man/opus
cd opus
./autogen.sh
mkdir out && cd out
cmake -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="${OptimizedFlags}" .. 
cmake --build . --config Release -j$(nproc)

# Replace Resonite's opus files
rm "${ResoDir}/libopus.so"
rm "${ResoDir}/runtimes/linux-x64/native/libopus.so"
cp "${WORK_DIR}/opus/out/libopus.so.0.10.1" "${ResoDir}/runtimes/linux-x64/native/libopus.so"
ln "${ResoDir}/runtimes/linux-x64/native/libopus.so" "${ResoDir}/libopus.so"
success "opus compiled and installed"

# Reset
cd "$WORK_DIR"

# Clone and compile an optimized rnnoise
echo ""
echo "=== Compiling rnnoise ==="
git clone --depth=1 https://github.com/Yellow-Dog-Man/rnnoise
cd rnnoise
mkdir out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="${OptimizedFlags}" .. 
cmake --build . --config Release -j$(nproc)

# Replace Resonite's rnnoise files
rm "${ResoDir}/librnnoise.so"
rm "${ResoDir}/runtimes/linux-x64/native/librnnoise.so"
cp "${WORK_DIR}/rnnoise/out/librnnoise.so" "${ResoDir}/runtimes/linux-x64/native/librnnoise.so"
ln "${ResoDir}/runtimes/linux-x64/native/librnnoise.so" "${ResoDir}/librnnoise.so"
success "rnnoise compiled and installed"

# Verify all installations
echo ""
echo "=== Verifying installations ==="
all_installed=true
missing_libs=()

# Check each library
libraries=(
    "${ResoDir}/runtimes/linux-x64/native/libassimp.so:assimp"
    "${ResoDir}/brolib_x64.so:brotli"
    "${ResoDir}/runtimes/linux/native/brolib_x64.so:brotli (runtime)"
    "${ResoDir}/libCMP_Compressonator.so:compressonator"
    "${ResoDir}/libCMP_Framework.so:compressonator framework"
    "${ResoDir}/runtimes/linux-x64/native/libCMP_Compressonator.so:compressonator (runtime)"
    "${ResoDir}/runtimes/linux-x64/native/libCMP_Framework.so:compressonator framework (runtime)"
    "${ResoDir}/libcrnlib.so:crunch"
    "${ResoDir}/runtimes/linux-x64/native/libcrnlib.so:crunch (runtime)"
    "${ResoDir}/libFreeImage.so:FreeImage"
    "${ResoDir}/runtimes/linux-x64/native/libFreeImage.so:FreeImage (runtime)"
    "${ResoDir}/runtimes/linux-x64/native/libFreeImage.a:FreeImage (static)"
    "${ResoDir}/runtimes/linux-x64/native/FreeImage.h:FreeImage (header)"
    "${ResoDir}/runtimes/linux-x64/native/libmikktspace.so:mikktspace"
    "${ResoDir}/runtimes/linux-x64/native/libminiaudio.so:miniaudio"
    "${ResoDir}/libmsdfgen.so:msdfgen"
    "${ResoDir}/runtimes/linux-x64/native/libmsdfgen.so:msdfgen (runtime)"
    "${ResoDir}/libopus.so:opus"
    "${ResoDir}/runtimes/linux-x64/native/libopus.so:opus (runtime)"
    "${ResoDir}/librnnoise.so:rnnoise"
    "${ResoDir}/runtimes/linux-x64/native/librnnoise.so:rnnoise (runtime)"
)

for lib_entry in "${libraries[@]}"; do
    lib_path="${lib_entry%%:*}"
    lib_name="${lib_entry##*:}"
    if [ -f "$lib_path" ]; then
        echo -e "  ${GREEN}✓${NC} $lib_name"
    else
        echo -e "  ${RED}✗${NC} $lib_name - MISSING"
        all_installed=false
        missing_libs+=("$lib_name")
    fi
done

echo ""
if [ "$all_installed" = true ]; then
    success "All libraries verified and installed correctly!"
    echo ""
    echo "Summary:"
    echo "  • 10 libraries optimized and installed"
    echo "  • All files verified in Resonite directory"
    echo "  • Ready to use!"
else
    warning "Some libraries are missing:"
    for lib in "${missing_libs[@]}"; do
        echo "    - $lib"
    done
    error "Installation incomplete. Please check the build logs above."
    exit 1
fi

# Cleanup
echo ""
echo "Cleaning up temporary files..."
rm -rf "$WORK_DIR"
success "All done! Resonite libraries have been optimized."
