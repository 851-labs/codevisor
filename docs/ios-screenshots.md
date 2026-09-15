# iOS screenshots

Start `bun run ios-simulator --device="iPhone 13 Pro Max"` in a separate terminal, wait for `Simulator ready`, then run `bun run screenshots:ios` to capture the four iPhone scenes in both light and dark mode. See [Marketing screenshots](screenshots.md) for the shared iOS/macOS workflow, output files, options, and fixture sources.

The iPhone 13 Pro Max captures are 1284 × 2778 pixels. `--device iphone` and `--device all` both select iPhone; iPad capture remains disabled.

```sh
bun run screenshots:ios --runtime 'iOS 27.0'
bun run screenshots:ios --appearance dark --output tmp/my-screenshots
```
