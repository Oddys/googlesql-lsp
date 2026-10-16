# GoogleSQL Language Server (WIP)
A minimalistic language server for [GoogleSQL](https://github.com/google/googlesql). Its only target capability is to report syntax errors.

Under the hood it uses the [googlesql-ffi library](https://github.com/Oddys/googlesql-ffi) that exposes the GoogleSQL parser's functionality via C ABI.

To update dependencies:
1. Fetch the new version:
```sh
v="v0.2.0-2026.9.1"
zig fetch --save=googlesql_ffi_linux_aarch64 "https://github.com/Oddys/googlesql-ffi/releases/download/$v/googlesql_ffi_linux_aarch64.tar.gz"
zig fetch --save=googlesql_ffi_linux_x86_64 "https://github.com/Oddys/googlesql-ffi/releases/download/$v/googlesql_ffi_linux_x86_64.tar.gz"
zig fetch --save=googlesql_ffi_macos_arm64 "https://github.com/Oddys/googlesql-ffi/releases/download/$v/googlesql_ffi_macos_arm64.tar.gz"
zig fetch --save=googlesql_ffi_macos_x86_64 "https://github.com/Oddys/googlesql-ffi/releases/download/$v/googlesql_ffi_macos_x86_64.tar.gz"
```
2. If needed (e.g. the dependency name was changed): add `.lazy = true` and remove stale records

To prepare fresh build:
```sh
rm -r ~/.cache/zig/
rm -rf .zig-cache zig-out zig-pkg src/c.zig 2>/dev/null
```

To try test script:
```sh
./client.sh | ./zig-out/bin/googlesql_lsp_<platform>
```

## Coverage
To compute test coverage with kcov:
```sh
kcov --clean --include-path=src --exclude-region=KCOV_EXCL_START:KCOV_EXCL_END zig-out/coverage zig-out/bin/test
```
