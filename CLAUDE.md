# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

scrcpy mobile is a HarmonyOS remote control application for Android devices, inspired by scrcpy and EasyControl. It allows HarmonyOS devices (phones/tablets) to remotely control Android devices over ADB via network connection.

**Bundle Name:** com.lambdayh.scrcpyHmos
**Target SDK:** HarmonyOS API 9+ (6.0.0)
**Language:** ArkTS (HarmonyOS TypeScript) with native C++ for video decoding

## Build and Development Commands

### Building the Application

```bash
# Build HAP (HarmonyOS Application Package) in DevEco Studio
# Use the GUI: Build > Build Hap(s)/APP(s)

# Or use hvigor command line (if configured)
hvigorw assembleHap
```

### Building Android Server

The Android server component must be built separately:

```bash
cd easycontrol/server
gradlew.bat assembleRelease
```

### Installing to Device

```bash
# Install HAP to HarmonyOS device
hdc install app/build/default/outputs/default/app-default-signed.hap

# Push Android server to target device
adb push easycontrol/server/build/outputs/apk/release/server.jar /data/local/tmp/easycontrol-server.jar
adb shell chmod 755 /data/local/tmp/easycontrol-server.jar
```

### Testing Setup

```bash
# Enable wireless ADB on Android device
adb tcpip 5555
adb connect <device-ip>:5555

# Check server deployment
adb shell ls -l /data/local/tmp/easycontrol-server.jar
```

## Architecture

### Core Components

**ADB Communication Layer** (`app/src/main/ets/adb/`)
- `Adb.ets` - Complete ADB protocol implementation (AUTH, CNXN, OPEN, WRTE, CLSE, OKAY)
- `TcpChannel.ets` - TCP socket wrapper for network communication
- `AdbKeyManager.ets` - RSA key management for ADB authentication (per-device key persistence using file system)

**Client Layer** (`app/src/main/ets/client/`)
- `Client.ets` - Main client orchestrator managing lifecycle and video config preloading
- `ClientStream.ets` - Handles bi-directional streaming (video, audio, clipboard, control events)
- `VideoDecoder.ets` - ArkTS wrapper for native C++ decoder (H.264/H.265)
- `AudioDecoder.ets` - Audio stream handling (AAC/Opus)
- `ControlPacket.ets` - Touch and keyboard event serialization for remote control

**Helper Layer** (`app/src/main/ets/helper/`)
- `ServerManager.ets` - Manages Android server deployment (sync protocol + shell fallback)
- `PreferencesHelper.ets` - Device configuration persistence
- `AdbKeyManager.ets` - Cryptographic key storage and RSA signature generation

**UI Layer** (`app/src/main/ets/pages/`)
- `Index.ets` - Device list management
- `DeviceDetail.ets` - Device configuration editor
- `ControlPage.ets` - Remote control interface with XComponent for video rendering

**Native Layer** (`app/src/main/cpp/`)
- `video_decoder_native.cpp` - Hardware video decoder using OH_VideoDecoder APIs
- `napi_init.cpp` - N-API bridge for ArkTS ↔ C++ communication
- CMake build system targeting arm64-v8a and x86_64

### Data Flow

1. **Connection**: ADB TCP → RSA Auth → Shell Stream → Server Deployment Check
2. **Server Launch**: Execute `/data/local/tmp/easycontrol-server.jar` via ADB shell
3. **Stream Initialization**: Open control socket → Read video config (SPS/PPS/VPS)
4. **Video Pipeline**: Video packets → ClientStream → VideoDecoder (ArkTS) → Native decoder → XComponent Surface
5. **Control Events**: Touch/Key input → ControlPacket → ClientStream → Android server

### Key Technical Details

**ADB Protocol**
- Custom implementation matching EasyControl's AdbProtocol.java
- Supports RSA 2048-bit authentication with PKCS#1 signatures
- Per-device key persistence prevents re-authorization on reconnect
- Max payload: 15KB (CONNECT_MAXDATA)

**Video Decoding**
- Native C++ decoder for performance (libnative_media_vdec.so)
- Supports H.264 (AVC) and H.265 (HEVC) codecs
- CSD (Codec Specific Data) preloading prevents server timeout
- Direct rendering to OHNativeWindow surface

**Server Management**
- Primary: ADB sync protocol for binary transfer
- Fallback: Shell-based push via `dd` command with base64 encoding
- Server path: `/data/local/tmp/easycontrol-server.jar`
- Validation via shell command: `ls <path> && echo FILE_EXISTS`

**Touch Coordination**
- Multi-touch support with pointer ID tracking
- Coordinate mapping from XComponent space to Android screen dimensions
- Touch actions: DOWN (0), UP (1), MOVE (2)

## Common Development Workflows

### Adding Device Configuration Options

1. Modify `Device.ets` entity with new field
2. Update `DeviceDetail.ets` UI with corresponding input
3. Update `PreferencesHelper.ets` serialization/deserialization
4. Pass configuration to `ClientStream` or relevant component

### Extending Control Capabilities

1. Define new control type in `ControlPacket.ets`
2. Add serialization method (e.g., `generateNewControl()`)
3. Wire up UI event in `ControlPage.ets`
4. Ensure Android server supports the control type

### Debugging Connection Issues

- Check `Adb.ets` for protocol-level errors (message parsing, checksums)
- Verify `AdbKeyManager.ets` key persistence (filesDir + device address)
- Monitor `ServerManager.ets` for deployment failures
- Use `hilog` filtering: `hdc shell hilog | grep 'scrcpyHmos'`

### Native Decoder Issues

- Check surface ID validity in `VideoDecoder.ets`
- Verify CSD-0/CSD-1 data in decoder init
- Native logs: Look for `[VideoDecoderNative]` tag in hilog
- Ensure XComponent surface is created before decoder init

## Configuration Files

- `build-profile.json5` - Product configuration (signingConfigs, targets, SDK versions)
- `app/build-profile.json5` - Module-level build options (arkOptions, native build paths)
- `app/src/main/module.json5` - App metadata (abilities, permissions, device types)
- `AppScope/app.json5` - Bundle information (bundleName, version, icon)

## Important Constraints

- **ADB Authorization**: First connection requires manual approval on Android device (RSA public key acceptance)
- **Network Requirement**: Both devices must be on same local network
- **Android Compatibility**: Target Android 5.0+, full audio support requires Android 12+
- **Native ABIs**: Only arm64-v8a and x86_64 architectures supported
- **Server Dependency**: Android server JAR must be pre-deployed before connection

## Permissions Required

- `ohos.permission.INTERNET` - Network communication
- `ohos.permission.GET_NETWORK_INFO` - Network state detection
- `ohos.permission.MICROPHONE` - Audio streaming (if enabled)
