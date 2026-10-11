# no-ai-mac

Turn off Apple Intelligence on a Mac and get its disk space back, with nothing running in the background.

It has two parts:

- **`no-ai-profile.mobileconfig`**: a configuration profile that switches off the Apple Intelligence features and stops macOS downloading the models again.
- **`remove-ai-models`**: a small command-line tool that asks Apple's asset service to release the models already on disk.

You can use either part on its own. Neither one disables System Integrity Protection or modifies anything under `/System`, and both are fully reversible.

## Requirements

- macOS 27 on Apple silicon
- Xcode or the Command Line Tools (`xcode-select --install`) to build the tool

## 1. Install the profile

Double-click `no-ai-profile.mobileconfig`, then approve it in **System Settings → General → Device Management**.

The profile is unsigned, so macOS labels it unverified. To sign it with your own Apple developer certificate, see [Signing](#signing).

### What it turns off

| Feature | How |
|---|---|
| Writing Tools | `allowWritingTools` restriction |
| Genmoji, Image Playground, Image Wand | `allowGenmoji`, `allowImagePlayground`, `allowImageWand` restrictions |
| Mail summaries and smart replies | Restrictions plus forced `group.com.apple.mail` settings |
| Safari summaries | `allowSafariSummary` restriction |
| Notes transcription summaries | `allowNotesTranscriptionSummary` restriction |
| Notification summaries | Forced `group.com.apple.usernoted` setting |
| Messages summaries | Forced `com.apple.MobileSMS` setting |
| Inline text predictions | Forced `NSAutomaticInlinePredictionEnabled` |
| Spatial Photos | Forced `com.apple.spatialphotosrelive` setting |
| ChatGPT and other external AI extensions | `allowExternalIntelligenceIntegrations` and its sign-in restriction |
| Apple Intelligence Report | `allowAppleIntelligenceReport` restriction |
| Personalized handwriting (iPad) | `allowPersonalizedHandwritingResults` restriction |

### Model download block

For each model set, the profile points macOS's asset downloads at a closed local port (`127.0.0.1:9`). If macOS tries to fetch the models again, the download fails. This covers:

- the foundation models
- the image and Genmoji models
- the Xcode code completion models
- the Photos Clean Up models
- the Spatial Photos models

### What it leaves alone

**Siri** stays on. Basic Siri keeps working, but its Apple Intelligence features don't, because their models are blocked.

**Dictation** is a separate setting and isn't touched.

### Does it work without MDM?

Apple documents several of these restrictions as requiring a supervised or MDM-enrolled device. A profile you install yourself may be partly ignored, depending on your macOS version. To check what took effect:

```sh
plutil -p "/Library/Managed Preferences/com.apple.applicationaccess.plist"
```

Then try the features themselves. For example, select some text and right-click to see whether Writing Tools appears.

For a fleet, deploy the profile through your MDM instead.

## 2. Remove the models already on disk

```sh
make
./remove-ai-models            # shows what's on disk, changes nothing
./remove-ai-models --remove   # releases the models
```

Without arguments, the tool lists each model set and its size. With `--remove`, it asks Apple's asset service to release each set that's present, then shows the before and after totals. It doesn't need `sudo`.

Install the profile first. Without the download block, macOS may download the models again.

macOS deletes released files on its own schedule, so free space can take a little while to update. **Storage** in System Settings lags even further behind.

The tool uses private Apple interfaces. Before touching a model set, it checks that macOS still reports the asset type it expects. If a macOS update renames a set, the tool skips it rather than guessing.

## Undo

1. Remove the profile in **System Settings → General → Device Management**, or run:

   ```sh
   sudo profiles remove -identifier no-ai-profile
   ```

2. Turn Apple Intelligence back on in System Settings. macOS downloads the models again.

## Signing

List your signing identities, then sign both the tool and the profile:

```sh
security find-identity -v -p codesigning
make sign SIGN_ID="Apple Development: Your Name (TEAMID)"
```

This writes `no-ai-profile-signed.mobileconfig` next to the unsigned profile.

## Customizing

`no-ai-profile.mobileconfig` is a plain XML property list:

- To keep a feature, delete its key or its forced-settings payload.
- If you publish your own fork, change `PayloadIdentifier` to a reverse-DNS name you own.

## Credits

The asset-service calls, model sets and several settings keys were mapped by [pared](https://github.com/4evy/pared) by 4evy and used in [RemoveMacAI](https://github.com/omlahore/RemoveMacAI) by Om Lahore. Both are MIT-licensed. See [LICENSE](LICENSE).

If you want a full app with more privacy and cleanup options, use RemoveMacAI. This project is the minimal version: one profile and one small tool.
