# build/proot/Dockerfile — Cross-compile termux/proot for Android architectures
#
# Usage:
#   docker build -f build/proot/Dockerfile -t proot-builder .
#   docker run --rm -v $(pwd)/build/proot/dist:/dist proot-builder
#
# Or single-arch:
#   docker run --rm -v .../dist:/dist proot-builder arm64-v8a

FROM ubuntu:22.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_NDK_VERSION=r28b

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    wget \
    unzip \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Android NDK
RUN wget -q "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-linux.zip" -O /tmp/ndk.zip \
    && unzip -q /tmp/ndk.zip -d /opt \
    && rm /tmp/ndk.zip

ENV ANDROID_NDK_HOME=/opt/android-ndk-${ANDROID_NDK_VERSION}
ENV TOOLCHAIN=${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64

# Build talloc from source (static)
RUN git clone --depth=1 https://github.com/samba-project/samba.git /tmp/samba \
    && cd /tmp/samba/lib/talloc \
    && ./configure --cross-compile --cross-host=aarch64-linux-android \
       CC=${TOOLCHAIN}/bin/aarch64-linux-android21-clang \
       AR=${TOOLCHAIN}/bin/llvm-ar \
       RANLIB=${TOOLCHAIN}/bin/llvm-ranlib \
       --prefix=/opt/deps/arm64 \
    && make -j$(nproc) && make install \
    && rm -rf /tmp/samba

# Build libandroid-shmem from source
RUN git clone --depth=1 https://github.com/niccokunzmann/libandroid-shmem.git /tmp/shmem \
    && cd /tmp/shmem \
    && mkdir -p build && cd build \
    && cmake .. \
       -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake \
       -DANDROID_ABI=arm64-v8a \
       -DANDROID_PLATFORM=android-21 \
       -DCMAKE_INSTALL_PREFIX=/opt/deps/arm64 \
    && make -j$(nproc) && make install \
    && rm -rf /tmp/shmem

# Clone termux/proot
RUN git clone --depth=1 https://github.com/termux/proot.git /opt/proot-src

# Copy build script
COPY build-proot-arch.sh /opt/build-proot-arch.sh
RUN chmod +x /opt/build-proot-arch.sh

WORKDIR /opt/proot-src/src
ENTRYPOINT ["/opt/build-proot-arch.sh"]
CMD ["all"]
