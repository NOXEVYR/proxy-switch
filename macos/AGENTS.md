# macOS preview

- Native AppKit / Swift Package Manager, macOS 13+. Keep Windows sources and releases unchanged.
- Build with `swift test` and `python3 scripts/build.py --arch arm64|x86_64 --output <directory>` on macOS. `scripts/integration.py` tests the packaged executable and core without changing system settings.
- Never claim real permission dialogs, VPN conflicts, process attribution, or long-running user sessions passed from CI alone.
- No TUN, subscription import, shell interpolation, global environment writes, automatic application termination, or third-party proxy changes.
- The worker owns its child core. Before stopping it, restore only proxy dictionaries that still match the recorded managed dictionary, under the SystemConfiguration lock. Unknown endpoint state is not evidence of failure.
- Configuration / session / controller secret remain in the user's Application Support directory with private permissions. Package source and pinned upstream license/source, never user data.
