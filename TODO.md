Functionality:
- [x] Add sending diagnostics (didOpen, didChange, didClose)
- [x] Enable parsers
- [ ] Add debouncing / move parsing off the request thread. At that point, store the version next to the text in files.
- [ ] Implement handling of partial updates
- [x] Add other MacOS and Linux build targets
- [ ] Optimize build for Prod
- [ ] Add license

Chores:
- [ ] Unify function parameter names in Handler
- [ ] Unify imports (use aliasing for structs in lsp.types)
- [ ] Add kcov to build.zig
- [x] Make consistent naming of steps in build
