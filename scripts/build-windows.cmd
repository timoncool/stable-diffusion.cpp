@echo off
rem Windows x64 builds of the library for Dungeon Ultimate (fork timoncool/stable-diffusion.cpp, branch studio): one
rem stable-diffusion.dll with ggml linked in and not exported (another ggml in the process, Qwen3-TTS, cannot take it
rem for its own), no native CPU flags, the AVX2 floor, no AVX-512, no NCCL, machine code only (no PTX).
rem   cuda12 (default): CUDA 12.9 (D:\Projects\_tools\cuda-12.9, MSVC 14.44), sm 52/61/70/75/80/86/89/90/120a; the CUDA
rem                     runtime linked in, cuBLAS 12 from the game's CUDA 12.9 runtime (models\cuda12-runtime).
rem   vulkan:           Vulkan and the CPU, for AMD and Intel cards (LunarG Vulkan SDK; the system's vulkan-1.dll).
rem   scripts\build-windows.cmd <output folder> <build folder> [cuda12|vulkan]
rem Each backend is set up by its own label: inside an if-block cmd expands %PATH% before vcvars runs.
setlocal
set "OUT=%~1"
set "BUILD=%~2"
set "BACKEND=%~3"
if "%BACKEND%"=="" set "BACKEND=cuda12"
if "%OUT%"=="" (echo [ERROR] output folder & exit /b 1)
if "%BUILD%"=="" (echo [ERROR] build folder & exit /b 1)
set VSLANG=1033
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if /i not "%BACKEND%"=="cuda12" if /i not "%BACKEND%"=="vulkan" (
  echo [ERROR] backend %BACKEND%: cuda12 or vulkan
  exit /b 1
)
goto :setup_%BACKEND%

:setup_cuda12
set "CUDA_PATH=D:\Projects\_tools\cuda-12.9"
call "%VCVARS%" -vcvars_ver=14.44 >nul
set "PATH=D:\Projects\_tools\cuda-12.9\bin;%PATH%"
set "FLAGS=-DSD_CUDA=ON -DGGML_CUDA_NCCL=OFF -DCMAKE_CUDA_RUNTIME_LIBRARY=Static -DCUDAToolkit_ROOT=D:/Projects/_tools/cuda-12.9 -DCMAKE_CUDA_COMPILER=D:/Projects/_tools/cuda-12.9/bin/nvcc.exe -DCMAKE_CUDA_FLAGS=-Wno-deprecated-gpu-targets -DCMAKE_CUDA_ARCHITECTURES=52-real;61-real;70-real;75-real;80-real;86-real;89-real;90-real;120a-real"
goto :configure

:setup_vulkan
set "VULKAN_SDK=C:\VulkanSDK\1.4.357.0"
call "%VCVARS%" >nul
set "FLAGS=-DSD_VULKAN=ON"
goto :configure

:configure
where cl >nul 2>&1 || (echo [ERROR] MSVC is not set up for %BACKEND% & exit /b 1)
cd /d "%~dp0.."
for /f %%c in ('git rev-parse --short^=7 HEAD') do set "COMMIT=%%c"
echo [..] source %COMMIT%, %BACKEND%
rem settings come from this script alone, not from a cache an earlier run left
cmake --fresh -S . -B "%BUILD%" -G Ninja -DCMAKE_BUILD_TYPE=Release -DSD_BUILD_SHARED_LIBS=ON -DSD_BUILD_SHARED_GGML_LIB=OFF ^
  -DGGML_BACKEND_DL=OFF -DGGML_CPU_ALL_VARIANTS=OFF -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl ^
  -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX512=OFF ^
  %FLAGS% > "%OUT%-cmake.log" 2>&1 || (echo [ERROR] configure, see %OUT%-cmake.log & exit /b 1)
echo [..] build (log %OUT%-build.log)
start "" /b /belownormal /wait cmake --build "%BUILD%" --target stable-diffusion -j 8 > "%OUT%-build.log" 2>&1 || (echo [ERROR] build, see %OUT%-build.log & exit /b 1)
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%" || exit /b 1
for /r "%BUILD%" %%f in (stable-diffusion.dll) do if exist "%%f" copy /y "%%f" "%OUT%\" >nul
if not exist "%OUT%\stable-diffusion.dll" (echo [ERROR] no stable-diffusion.dll in %BUILD% & exit /b 1)
set "ZIP=%OUT%\..\sd-%COMMIT%-win-%BACKEND%-x64.zip"
powershell -NoProfile -Command "Compress-Archive -Force -Path '%OUT%\*' -DestinationPath '%ZIP%'" || exit /b 1
powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 '%ZIP%').Hash.ToLower() + '  ' + (Get-Item '%ZIP%').Length"
echo [OK] %ZIP%
