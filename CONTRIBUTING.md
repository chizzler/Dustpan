# Contributing

Use GitHub issues for bugs and feature proposals. Include the client version, operating system,
steps to reproduce, expected behavior and actual behavior. Reproduce with sample tasks when possible;
omit API tokens, server credentials, database files and personal task content.

Linux development needs the dependencies in [desktop/README.md](desktop/README.md). Mac development
needs macOS 26+ and Xcode 27. No PyPI or third-party Swift dependencies are required.

Protocol vectors come from a separate OpenTodo checkout pinned to v0.22.0:

```sh
git clone --branch v0.22.0 --depth 1 https://github.com/OpenTodoApp/OpenTodo.git ../opentodo
python3 -m unittest discover -s desktop/tests -t desktop
swift test --package-path apple/DustpanCore
```

Run the Python tests on Linux with GTK installed and a display (or Xvfb) to include window tests.
Without the upstream clone, vector tests may skip; a release check must supply it.
Use `dev/server.sh`, `dev/client.sh` and `dev/mac.sh` for isolated development. These use `dev/data`
and development credentials rather than a real account. Use sample tasks for screenshots and tests.

Keep protocol changes consistent between Python and Swift and add regression cases where behavior changes.
Preserve fields the client does not edit, transaction boundaries, and the sync operation ordering rules.
Describe what changed and how you verified it in each pull request. Contributions use the project's
AGPL-3.0-only license. See [NOTICE.md](NOTICE.md) for upstream attribution.
