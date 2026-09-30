import SwiftUI
import AppKit

/// Displays the currently playing track with album art, title, artist,
/// transport controls, and volume slider.
struct NowPlayingView: View {
    @EnvironmentObject var appState: AppState
    /// Whether per-speaker volume sliders are expanded (grouped zones only).
    @State private var showSpeakerVolumes = false

    private var nowPlaying: NowPlayingState {
        appState.nowPlaying
    }

    private var isGrouped: Bool {
        appState.activeZone?.members.isEmpty == false
    }

    var body: some View {
        if let track = nowPlaying.track {
            VStack(spacing: 0) {
                trackView(track)
                if !track.isTVAudio {
                    PlaybackProgressBar(
                        position: appState.playbackPosition,
                        duration: appState.playbackDuration,
                        showTimestamps: false
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
                transportControls
                volumeSlider
                if isGrouped && showSpeakerVolumes {
                    speakerVolumesSection
                }
            }
        } else {
            emptyView
        }
    }

    // MARK: - Track View

    @ViewBuilder
    private func trackView(_ track: TrackInfo) -> some View {
        HStack(spacing: 10) {
            // Album art / TV icon
            if track.isTVAudio {
                Image("TVIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .frame(width: 64, height: 64)
            } else {
                CachedAsyncImage(url: track.albumArtURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color(.controlBackgroundColor)
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    if let url = track.albumArtURL {
                        appState.albumArtWindow.show(url: url)
                    }
                }
                .help("Click to enlarge")
                .contextMenu { albumArtContextMenu(track: track) }
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    Text(track.title)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(2)

                    if !track.isTVAudio, !track.isDJSegment {
                        Spacer(minLength: 2)
                        heartButton
                            .padding(.top, 1)
                    }
                }

                Text(track.isTVAudio ? (nowPlaying.zoneName ?? "") : track.artist)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if track.isTVAudio {
                    if let zone = appState.activeZone, !zone.members.isEmpty {
                        Text("\(zone.members.count + 1) speakers")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 4) {
                        if let album = track.album {
                            Text(album)
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }

                        if appState.scrobbleTracker.isScrobbled(track.id) && appState.scrobblerClient.config != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                                .fixedSize()
                                .help("Scrobbled")
                        }
                    }

                    if let station = nowPlaying.mediaTitle {
                        Text(station)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            if !track.isTVAudio, !track.title.isEmpty {
                Button("Copy Track Details") { copyTrackDetails(track) }
                Button("Copy Title") { copyToClipboard(track.title) }
                if !track.artist.isEmpty {
                    Button("Copy Artist") { copyToClipboard(track.artist) }
                }
                if let album = track.album, !album.isEmpty {
                    Button("Copy Album") { copyToClipboard(album) }
                }
            }
        }
    }

    // MARK: - Album Art Menu

    /// Right-click menu shown on the album art tile. Refresh re-queries
    /// iTunes, Ignore marks the current URL so iTunes won't surface it
    /// again, Search Alternative opens a picker over the dropdown.
    @ViewBuilder
    private func albumArtContextMenu(track: TrackInfo) -> some View {
        if !track.artist.isEmpty, !track.title.isEmpty {
            Button("Refresh Art") { appState.refreshAlbumArt() }
            Button("Search Alternative Art\u{2026}") {
                appState.altArtPickerWindow.show(appState: appState)
            }
            if track.albumArtURL != nil {
                Button("Ignore This Art") { appState.ignoreCurrentAlbumArt() }
            }
        }
    }

    // MARK: - Clipboard

    /// Format the playing track as `Artist / Album / Track` and place it on
    /// the pasteboard. Album line is omitted when the source has no album
    /// (radio streams, station IDs).
    private func copyTrackDetails(_ track: TrackInfo) {
        var lines: [String] = []
        if !track.artist.isEmpty { lines.append("Artist: \(track.artist)") }
        if let album = track.album, !album.isEmpty { lines.append("Album: \(album)") }
        lines.append("Track: \(track.title)")
        copyToClipboard(lines.joined(separator: "\n"))
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        let isTV = nowPlaying.track?.isTVAudio == true

        return HStack(spacing: 20) {
            if !isTV {
                Button {
                    appState.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.body)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Previous")
            }

            Button {
                appState.togglePlayPause()
            } label: {
                let isPlaying = isTV
                    ? !appState.isTVMuted
                    : nowPlaying.transportState == .playing
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(HoverButtonStyle())
            .help(isTV
                  ? (appState.isTVMuted ? "Unmute" : "Mute")
                  : (nowPlaying.transportState == .playing ? "Pause" : "Play"))

            if !isTV {
                Button {
                    appState.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Next")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Heart Button

    @ViewBuilder
    private var heartButton: some View {
        let trackId = nowPlaying.track?.id
        let isSaved = trackId.map { appState.savedTrackIds.contains($0) } ?? false
        let isLoved = trackId.map { appState.lovedTrackIds.contains($0) } ?? false
        let isSaving = trackId != nil && appState.savingTrackId == trackId
        let canSave = appState.canSaveToLibrary
        let autoAddOn = appState.autoAddToAppleMusic

        if isLoved {
            // Loved — filled red heart, no action.
            Image(systemName: "heart.fill")
                .font(.body)
                .foregroundColor(.red)
                .help("Loved")
        } else if isSaved {
            // In library but not loved (auto-added or pre-existing). Click to love.
            Button {
                appState.saveToLibrary()
            } label: {
                Image(systemName: isSaving ? "heart.fill" : "bookmark.fill")
                    .font(.body)
                    .foregroundColor(isSaving ? .red.opacity(0.4) : .secondary)
            }
            .buttonStyle(HoverButtonStyle())
            .help("In your library — click to love")
            .disabled(isSaving)
        } else if autoAddOn {
            // Auto-add is handling library saves for this session — heart is redundant.
            // Show a dimmed outline so the layout doesn't shift.
            Image(systemName: isSaving ? "heart.fill" : "heart")
                .font(.body)
                .foregroundColor(isSaving ? .red.opacity(0.4) : .secondary.opacity(0.3))
                .help("Auto-add is on")
        } else {
            VStack(spacing: 2) {
                Button {
                    appState.saveToLibrary()
                } label: {
                    Image(systemName: isSaving ? "heart.fill" : "heart")
                        .font(.body)
                        .foregroundColor(
                            isSaving ? .red.opacity(0.4) :
                            canSave ? .secondary : .secondary.opacity(0.3)
                        )
                }
                .buttonStyle(HoverButtonStyle())
                .help(canSave ? "Save to library" : "No music service connected")
                .disabled(isSaving)

                if let warning = appState.saveWarningMessage {
                    Text(warning)
                        .font(.system(size: 9))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 120)
                        .transition(.opacity)
                        .animation(.easeInOut, value: appState.saveWarningMessage)
                }
            }
        }
    }

    // MARK: - Volume Slider

    private var volumeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundColor(.secondary)

            dropdownVolumeSlider

            EditableVolumeLabel(value: appState.volume) { newLevel in
                appState.setVolume(newLevel)
            }

            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundColor(.secondary)

            if isGrouped {
                Button {
                    showSpeakerVolumes.toggle()
                } label: {
                    Image(systemName: showSpeakerVolumes ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showSpeakerVolumes ? "Hide speaker volumes" : "Show speaker volumes")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear {
            appState.refreshVolume()
        }
    }

    // MARK: - Custom Volume Slider

    /// Custom single-track volume slider matching the mini player style.
    private var dropdownVolumeSlider: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let ratio = CGFloat(appState.volume) / 100.0
            let trackHeight: CGFloat = 4
            let thumbSize: CGFloat = 12

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor)
                    .frame(width: ratio * width, height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: ratio * (width - thumbSize))
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newRatio = max(0, min(value.location.x / width, 1.0))
                        appState.setVolume(Int(newRatio * 100))
                    }
            )
        }
        .frame(height: 12)
    }

    // MARK: - Group Volume

    /// Expandable per-speaker volume sliders for grouped zones.
    private var speakerVolumesSection: some View {
        VStack(spacing: 2) {
            if let zone = appState.activeZone {
                let allSpeakers = [zone.coordinator] + zone.members

                ForEach(allSpeakers, id: \.uuid) { speaker in
                    speakerVolumeRow(for: speaker)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .onChange(of: appState.selectedZone) { _ in
            showSpeakerVolumes = false
        }
    }

    private func speakerVolumeRow(for speaker: SonosDevice) -> some View {
        HStack(spacing: 6) {
            Text(speaker.roomName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
                .lineLimit(1)

            speakerSlider(for: speaker)

            EditableVolumeLabel(
                value: appState.groupSpeakerVolumes[speaker.uuid] ?? 0
            ) { newLevel in
                appState.groupSpeakerVolumes[speaker.uuid] = newLevel
                appState.setVolumeForSpeaker(speaker.uuid, level: newLevel)
            }
        }
    }

    private func speakerSlider(for speaker: SonosDevice) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let level = appState.groupSpeakerVolumes[speaker.uuid] ?? 0
            let ratio = CGFloat(level) / 100.0
            let trackHeight: CGFloat = 3
            let thumbSize: CGFloat = 10

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: ratio * width, height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    .offset(x: ratio * (width - thumbSize))
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newRatio = max(0, min(value.location.x / width, 1.0))
                        let newLevel = Int(newRatio * 100)
                        appState.groupSpeakerVolumes[speaker.uuid] = newLevel
                        appState.setVolumeForSpeaker(speaker.uuid, level: newLevel)
                    }
            )
        }
        .frame(height: 10)
    }

    // MARK: - Editable Volume Label

    /// Read-only volume readout that becomes an inline text field on click.
    /// Enter (or focus loss) commits a clamped 0–100 value; Escape cancels.
    /// Useful when you want to dial in a specific level instead of finding
    /// it by drag.
    fileprivate struct EditableVolumeLabel: View {
        let value: Int
        let onCommit: (Int) -> Void

        @State private var isEditing = false
        @State private var text = ""
        @FocusState private var isFocused: Bool

        var body: some View {
            Group {
                if isEditing {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .font(.system(size: 10, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commit() }
                        .onExitCommand { isEditing = false }
                        .onChange(of: isFocused) { focused in
                            if !focused && isEditing { commit() }
                        }
                } else {
                    Text("\(value)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .onTapGesture {
                            text = "\(value)"
                            isEditing = true
                            isFocused = true
                        }
                        .help("Click to set volume")
                }
            }
            .frame(width: 26, alignment: .trailing)
        }

        private func commit() {
            defer { isEditing = false }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let n = Int(trimmed) {
                onCommit(max(0, min(100, n)))
            }
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 4) {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Nothing playing")
                .font(.caption)
                .foregroundColor(.secondary)
            if let zone = nowPlaying.zoneName {
                Text(zone)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            volumeSlider
            if isGrouped && showSpeakerVolumes {
                speakerVolumesSection
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }
}
