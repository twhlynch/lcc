FROM ubuntu:24.04

# install requirements
RUN apt-get update && apt-get install -y \
    curl xz-utils llvm-dev clang git \
    && rm -rf /var/lib/apt/lists/*

# install zig 0.16
RUN curl -L https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz | tar -xJ -C /usr/local && \
    ln -s /usr/local/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig

WORKDIR /src
COPY . .
RUN rm -rf .zig-cache zig-cache zig-out

CMD ["zig", "build", "test", "--summary", "all"]
