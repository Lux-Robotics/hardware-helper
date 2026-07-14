# macOS installer wrappers (future)

CI ships a flat install-layout zip (two binaries + `loader_binaries/`), not a
`.app` bundle. That matches `paths::companion_dir` for a non-bundled binary.

Optional later:

- Wrap the same payload next to a `.app` (companions live **beside** the `.app`)
- Or build a `.dmg` that contains the folder from `package-installer.sh`
