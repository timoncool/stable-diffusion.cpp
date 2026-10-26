#!/bin/bash
# Linux x86-64 builds of the library for Dungeon Ultimate (fork timoncool/stable-diffusion.cpp, branch studio):
# Ubuntu 22.04 (glibc 2.35), one shared libstable-diffusion.so with ggml linked in and not exported, the CPU code on
# the AVX2 floor (no GGML_NATIVE), CUDA 12.9 with SASS for every architecture and no PTX; libgomp, which the CPU
# backend needs, is copied beside it (RUNPATH $ORIGIN).
#   scripts/build-linux-docker.sh <output folder> <cache folder> <cuda12|vulkan|cpu>
set -euo pipefail

if [ "${1:-}" = "--inside" ]; then
  build="$2"
  export DEBIAN_FRONTEND=noninteractive
  echo "[..] packages ($build)"
  apt-get update -q >/dev/null
  apt-get install -y -q --no-install-recommends build-essential cmake git ca-certificates file >/dev/null
  case "$build" in
    cuda12)
      # NCCL is not on a user's machine: with it on libggml-cuda needs libnccl.so.2. cudart and cuBLAS 12 come from the
      # game's CUDA 12.9 runtime, models/cuda12-runtime, two folders up from models/runtime/sd
      flags=(-DSD_CUDA=ON -DGGML_CUDA_NCCL=OFF "-DCMAKE_CUDA_ARCHITECTURES=52-real;61-real;70-real;75-real;80-real;86-real;89-real;90-real;120a-real"
        "-DCMAKE_INSTALL_RPATH=\$ORIGIN;\$ORIGIN/../../cuda12-runtime")
      ;;
    vulkan)
      # Ubuntu 22.04 has no glslc and older Vulkan and SPIR-V headers than ggml wants: LunarG's SDK has all three,
      # the loader linked against stays the system libvulkan.so.1
      apt-get install -y -q --no-install-recommends libvulkan-dev curl xz-utils >/dev/null
      vulkan=1.4.363.0
      sdk=/cache/vulkansdk-$vulkan
      if [ ! -x "$sdk/x86_64/bin/glslc" ]; then
        echo "[..] Vulkan SDK $vulkan"
        mkdir -p "$sdk"
        curl -sSfL "https://sdk.lunarg.com/sdk/download/$vulkan/linux/vulkansdk-linux-x86_64-$vulkan.tar.xz" | tar -xJ -C "$sdk" --strip-components=1
      fi
      export VULKAN_SDK="$sdk/x86_64" PATH="$sdk/x86_64/bin:$PATH"
      flags=(-DSD_VULKAN=ON "-DCMAKE_PREFIX_PATH=$VULKAN_SDK")
      ;;
    cpu)
      flags=()
      ;;
    *) echo "[ERROR] unknown build $build"; exit 1 ;;
  esac
  rm -rf /cache/src-$build && mkdir -p /cache/src-$build
  cp -a /src/. /cache/src-$build/
  cd /cache/src-$build
  echo "[..] source $(git -c safe.directory='*' rev-parse --short HEAD)"
  # one library: ggml linked in and kept to itself (hidden, --exclude-libs), so another ggml in the process (Qwen3-TTS)
  # cannot bind to it; the CPU code on the AVX2, FMA, F16C and BMI2 floor without runtime variants
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSD_BUILD_SHARED_LIBS=ON -DSD_BUILD_SHARED_GGML_LIB=OFF \
    -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=OFF -DGGML_CPU_ALL_VARIANTS=OFF \
    -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX512=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_VISIBILITY_PRESET=hidden -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
    "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--exclude-libs,ALL" \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON "-DCMAKE_INSTALL_RPATH=\$ORIGIN" "${flags[@]}" > /out/cmake-$build.log 2>&1 \
    || { echo "[ERROR] cmake"; tail -30 /out/cmake-$build.log; exit 1; }
  cmake --build build --config Release -j 8 > /out/build-$build.log 2>&1 || { echo "[ERROR] build"; tail -40 /out/build-$build.log; exit 1; }
  stage=/cache/stage-$build && rm -rf "$stage" && mkdir -p "$stage"
  find build -name '*.so*' \( -type f -o -type l \) -exec cp -a {} "$stage/" \;
  cp "$(gcc -print-file-name=libgomp.so.1)" "$stage/"
  ls -la "$stage"
  commit="$(git -c safe.directory='*' rev-parse --short=7 HEAD)"
  name="sd-${commit}-linux-${build}-x64.tar.gz"
  tar -czf "/out/$name" -C "$stage" .
  sha256sum "/out/$name"
  echo "[OK] $name"
  exit 0
fi

out="${1:?output folder}"
cache="${2:?cache folder}"
build="${3:?cuda12|vulkan|cpu}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out" "$cache"
image=ubuntu:22.04
[ "$build" = cuda12 ] && image=nvidia/cuda:12.9.1-devel-ubuntu22.04
cp "$repo/scripts/build-linux-docker.sh" "$out/.build-linux-docker.sh"
docker run --rm -v "$repo:/src:ro" -v "$(cd "$out" && pwd):/out" -v "$(cd "$cache" && pwd):/cache" "$image" \
  bash /out/.build-linux-docker.sh --inside "$build"
