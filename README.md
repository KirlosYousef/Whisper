# Whisper - iOS Audio Recording & Transcription App

A production-quality iOS application for recording, transcribing, and managing audio files. Built with SwiftUI, SwiftData, and MVVM architecture.

## Features

### 🎙️ Core Audio Recording
- High-quality audio recording using AVAudioEngine
- Real-time audio level visualization with responsive ring animation
- Background recording support
- Audio interruption handling (phone calls, headphone disconnections)
- Automatic pause/resume functionality

### 🔄 Advanced Transcription
- Integration with OpenAI Whisper API for accurate transcription
- Automatic audio segmentation (30-second chunks)
- Offline queuing system for network interruptions
- Fallback to on-device SFSpeechRecognizer when API fails
- Exponential backoff retry logic for failed requests

### 📱 Modern UI/UX
- Beautiful, intuitive interface with smooth animations
- Real-time waveform visualization during recording
- Search functionality across transcriptions
- Pull-to-refresh for recordings list
- Network status indicators
- Graceful error handling with user-friendly messages

### 🛡️ Robust Error Handling
- Disk space monitoring before recording
- Network connectivity detection
- Comprehensive error recovery mechanisms
- Offline mode support with automatic queue processing

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+
- OpenAI API Key (for transcription service)

## Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd Whisper
   ```

2. **Open in Xcode**
   ```bash
   open Whisper.xcodeproj
   ```

3. **Configure API Key**
   - See `API_SETUP.md` for detailed instructions
   - Open `Whisper/Config.plist`
   - Replace `YOUR_API_KEY_HERE` with your OpenAI API key
   - The API key is now stored securely and won't be committed to version control

4. **Build and Run**
   - Select your target device or simulator
   - Press `Cmd+R` to build and run

## Usage

### Recording Audio
1. Launch the app and grant microphone permissions
2. Tap the record button to start recording
3. The ring animation will respond to your voice level
4. Tap again to stop recording
5. Recordings are automatically segmented and sent for transcription

### Managing Recordings
- View all recordings in the main list, grouped by date
- Use the search bar to find recordings by transcription content
- Pull down to refresh and process queued transcriptions
- Tap on a recording to view details (coming in future update)

### Offline Mode
- When offline, transcriptions are automatically queued
- Queued transcriptions will process when network becomes available
- The app shows clear offline status indicators

## Architecture

The app follows the **MVVM (Model-View-ViewModel)** architecture pattern:

### Models (`Models/AudioModels.swift`)
- `Recording`: Core data model for audio recordings
- `TranscriptionSegment`: Individual transcription segments

### Views (`Views/`)
- `RecordingView`: Main recording interface
- SwiftUI components with modern design

### ViewModels (`ViewModels/`)
- `RecordingViewModel`: Manages recording state and business logic
- Handles data persistence and UI updates

### Services
- `AudioService`: Manages AVAudioEngine and recording functionality
- `TranscriptionService`: Handles API communication and transcription

## Data Flow

1. **Recording Flow**
   ```
   User Action → RecordingViewModel → AudioService → AVAudioEngine
   ```

2. **Transcription Flow**
   ```
   Audio Segment → TranscriptionService → OpenAI API → SwiftData
   ```

3. **UI Updates**
   ```
   Data Changes → @Published Properties → SwiftUI Views
   ```

## Key Technologies

- **SwiftUI**: Modern declarative UI framework
- **SwiftData**: Persistent data storage
- **AVAudioEngine**: High-performance audio recording
- **SFSpeechRecognizer**: On-device speech recognition fallback
- **Combine**: Reactive programming for data binding

## Error Handling

The app implements comprehensive error handling:

- **Network Errors**: Automatic retry with exponential backoff
- **API Failures**: Fallback to local speech recognition
- **Storage Issues**: Disk space monitoring and alerts
- **Audio Interruptions**: Automatic pause/resume handling

## Performance Optimizations

- Efficient SwiftData queries with proper indexing
- Lazy loading for large datasets
- Background processing for transcriptions
- Memory management for audio buffers

## Privacy & Permissions

The app requires the following permissions:
- **Microphone**: For audio recording
- **Speech Recognition**: For fallback transcription
- **Background Audio**: For continuous recording

All permissions are requested with clear explanations and handled gracefully.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For issues and questions:
1. Check the existing issues
2. Create a new issue with detailed information
3. Include device model, iOS version, and steps to reproduce

## Roadmap

- [ ] Session detail view with transcription segments
- [ ] Export functionality for recordings and transcriptions
- [ ] Advanced audio editing features
- [ ] Cloud sync capabilities
- [ ] Voice commands and shortcuts
- [ ] Enhanced accessibility features 