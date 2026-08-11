# Hush

A macOS menu bar app that gives every running app its own volume slider — something
macOS itself doesn't offer. It uses CoreAudio process taps to mute an app's direct
output and replay it at your chosen level, so it needs no kernel driver, no virtual
audio device, and no admin install.

Requires **macOS 15 or later**.

## Install

### From source

```sh
git clone https://github.com/cryonayes/Hush.git
cd Hush
./build.sh --install
```

That builds, copies to `/Applications/Hush.app`, and launches it. Xcode command line
tools are the only prerequisite (`xcode-select --install`).

### From Releases

Download `Hush.zip` from the [latest release](https://github.com/cryonayes/Hush/releases),
then:

```sh
unzip Hush.zip
xattr -dr com.apple.quarantine Hush.app
mv Hush.app /Applications/
open /Applications/Hush.app
```

## Uninstall

```sh
# turn off Launch at Login in the right-click menu first, then:
rm -rf /Applications/Hush.app
defaults delete com.cryonayes.hush
```
