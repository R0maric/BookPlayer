//
//  AudioMetadataService.swift
//  BookPlayer
//
//  Created by Jeremy Grenier on 7/3/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import AVFoundation
import CoreMedia

public struct ChapterMetadata {
  public let title: String
  public let start: TimeInterval
  public let duration: TimeInterval
  public let index: Int
  
  public init(
    title: String,
    start: TimeInterval,
    duration: TimeInterval,
    index: Int
  ) {
    self.title = title
    self.start = start
    self.duration = duration
    self.index = index
  }
}

public struct AudioMetadata {
  public let title: String
  public let artist: String
  public let duration: TimeInterval
  public let artwork: Data?
  public let chapters: [ChapterMetadata]?
  
  public init(
    title: String,
    artist: String = "",
    duration: TimeInterval = 0,
    artwork: Data? = nil,
    chapters: [ChapterMetadata]? = nil
  ) {
    self.title = title
    self.artist = artist
    self.duration = duration
    self.artwork = artwork
    self.chapters = chapters
  }
}

public protocol AudioMetadataServiceProtocol {
  /// Extract metadata from an audio file
  /// - Parameter fileURL: URL to the audio file
  /// - Returns: AudioMetadata if extraction succeeds, nil otherwise
  func extractMetadata(from fileURL: URL) async -> AudioMetadata?

  /// Extract metadata from an AVAsset
  /// - Parameter asset: The AVAsset to extract metadata from
  /// - Returns: AudioMetadata if extraction succeeds, nil otherwise
  func extractMetadata(from asset: AVAsset) async -> AudioMetadata?
}

public class AudioMetadataService: BPLogger, AudioMetadataServiceProtocol {
  
  public init() {}
  
  public func extractMetadata(from fileURL: URL) async -> AudioMetadata? {
    let asset = AVURLAsset(url: fileURL)
    return await extractMetadata(from: asset)
  }
  
  public func extractMetadata(from asset: AVAsset) async -> AudioMetadata? {
    do {
      let metadata = try await asset.load(.metadata)
      let duration = try await asset.load(.duration)
      let durationSeconds = CMTimeGetSeconds(duration)

      let title = await extractTitle(from: metadata)
      let artist = await extractArtist(from: metadata)
      let artwork = await extractArtwork(from: metadata)
      var chapters = await extractChapters(from: asset, metadata: metadata, duration: durationSeconds)
      chapters = resolveMP3FallbackChaptersIfNeeded(
        from: asset,
        duration: durationSeconds,
        existingChapters: chapters
      )

      return AudioMetadata(
        title: title,
        artist: artist,
        duration: durationSeconds,
        artwork: artwork,
        chapters: chapters
      )

    } catch {
      Self.logger.error("Failed to extract metadata from audio asset: \(error)")
      return nil
    }
  }

  private func resolveMP3FallbackChaptersIfNeeded(
    from asset: AVAsset,
    duration: TimeInterval,
    existingChapters: [ChapterMetadata]?
  ) -> [ChapterMetadata]? {
    guard existingChapters == nil else { return existingChapters }
    guard let urlAsset = asset as? AVURLAsset else { return nil }
    guard urlAsset.url.pathExtension.lowercased() == "mp3" else { return nil }
    guard urlAsset.url.isFileURL else {
      Self.logger.info("MP3 CHAP fallback skipped: non-local URL asset")
      return nil
    }

    guard let chapters = ID3ChapterParser.parseChapters(
      fromMP3File: urlAsset.url,
      duration: duration
    ),
    !chapters.isEmpty
    else {
      Self.logger.info("MP3 CHAP fallback skipped: no usable ID3 chapter data")
      return nil
    }

    Self.logger.info("MP3 CHAP fallback applied from ID3 tag data")
    return chapters
  }
  
  private func extractTitle(from metadata: [AVMetadataItem]) async -> String {
    let titleKeys: [AVMetadataKey] = [
      .commonKeyTitle,              // Actual title - should be first
      .commonKeyAlbumName,          // Album name (fallback for audiobooks)
      .id3MetadataKeyAlbumTitle,
      .iTunesMetadataKeyAlbum,
      .id3MetadataKeyOriginalAlbumTitle,
    ]
    
    for key in titleKeys {
      if let metadataItem = metadata.first(where: { $0.commonKey == key }),
         let titleValue = try? await metadataItem.load(.stringValue),
         !titleValue.isEmpty {
        return titleValue
      }
    }
    
    return ""
  }
  
  private func extractArtist(from metadata: [AVMetadataItem]) async -> String {
    let artistKeys: [AVMetadataKey] = [
      .commonKeyAuthor,
      .commonKeyArtist,
      .metadata3GPUserDataKeyAuthor,
      .iTunesMetadataKeyArtist,
      .iTunesMetadataKeyAlbumArtist,
      .id3MetadataKeyOriginalArtist
    ]
    
    for key in artistKeys {
      if let metadataItem = metadata.first(where: { $0.commonKey == key }),
         let artistValue = try? await metadataItem.load(.stringValue),
         !artistValue.isEmpty {
        return artistValue
      }
    }
    
    return ""
  }
  
  private func extractArtwork(from metadata: [AVMetadataItem]) async -> Data? {
    guard let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork }) else {
      return nil
    }
    
    return try? await artworkItem.load(.dataValue)
  }
  
  // MARK: - Chapter Extraction
  
  private func extractChapters(from asset: AVAsset, metadata: [AVMetadataItem], duration: TimeInterval) async -> [ChapterMetadata]? {
    do {
      let availableChapterLocales = try await asset.load(.availableChapterLocales)

      // First try: Native chapter support (works for M4B, some M4A, properly tagged files)
      if !availableChapterLocales.isEmpty {
        return await extractStandardChapters(from: asset, locales: availableChapterLocales)
      }

      // Second try: Check what metadata identifiers exist
      let identifiers = metadata.compactMap { $0.identifier?.rawValue }

      // FLAC/Vorbis chapters (CHAPTER tags)
      if identifiers.contains(where: { $0.contains("CHAPTER") && !$0.contains("NAME") }) {
        return await extractVorbisChapters(from: metadata, duration: duration)
      }

      // MP3 Overdrive chapters (ID3 TXXX tag)
      if identifiers.contains("id3/TXXX") {
        return await extractOverdriveChapters(from: metadata, duration: duration)
      }

      // MP3 standard chapters (ID3v2.3+ CHAP frames)
      // Note: Currently AVFoundation doesn't fully expose CHAP frame data,
      // but this may be supported in future iOS releases.
      if identifiers.contains(where: { $0.hasPrefix("id3/CHAP") }) {
        return await extractID3Chapters(from: metadata, duration: duration)
      }

      return nil
    } catch {
      Self.logger.error("Failed to extract chapters: \(error)")
      return nil
    }
  }
  
  private func extractStandardChapters(from asset: AVAsset, locales: [Locale]) async -> [ChapterMetadata]? {
    var allChapters: [ChapterMetadata] = []

    for locale in locales {
      do {
        let chaptersMetadata = try await asset.loadChapterMetadataGroups(
          withTitleLocale: locale,
          containingItemsWithCommonKeys: [AVMetadataKey.commonKeyArtwork]
        )

        for (index, chapterMetadata) in chaptersMetadata.enumerated() {
          let chapterIndex = index + 1

          // Get title using async load API
          let titleItem = AVMetadataItem.metadataItems(
            from: chapterMetadata.items,
            withKey: AVMetadataKey.commonKeyTitle,
            keySpace: AVMetadataKeySpace.common
          ).first
          let title = (try? await titleItem?.load(.stringValue)) ?? ""

          let start = CMTimeGetSeconds(chapterMetadata.timeRange.start)
          let duration = CMTimeGetSeconds(chapterMetadata.timeRange.duration)

          let chapter = ChapterMetadata(
            title: title,
            start: start,
            duration: duration,
            index: chapterIndex
          )

          allChapters.append(chapter)
        }
      } catch {
        Self.logger.error("Failed to load chapter metadata for locale \(locale): \(error)")
      }
    }

    return allChapters.isEmpty ? nil : allChapters
  }
  
  private func extractVorbisChapters(from metadata: [AVMetadataItem], duration: TimeInterval) async -> [ChapterMetadata]? {
    var chapterMap: [Int: (time: String?, name: String?)] = [:]

    for item in metadata {
      guard let identifier = item.identifier?.rawValue else { continue }

      // Match CHAPTER001, CHAPTER002, etc. (without NAME suffix)
      if let range = identifier.range(of: #"CHAPTER(\d+)$"#, options: .regularExpression) {
        let matched = identifier[range]
        let numberStr = matched.dropFirst(7) // Remove "CHAPTER" prefix
        if let number = Int(numberStr) {
          let time = try? await item.load(.stringValue)
          chapterMap[number, default: (nil, nil)].time = time
        }
      }

      // Match CHAPTER001NAME, CHAPTER002NAME, etc.
      if let range = identifier.range(of: #"CHAPTER(\d+)NAME$"#, options: .regularExpression) {
        let matched = identifier[range]
        let numberStr = String(matched.dropFirst(7).dropLast(4)) // Remove "CHAPTER" and "NAME"
        if let number = Int(numberStr) {
          let name = try? await item.load(.stringValue)
          chapterMap[number, default: (nil, nil)].name = name
        }
      }
    }

    // Sort by chapter number and create ChapterMetadata objects
    let sortedChapters = chapterMap.sorted { $0.key < $1.key }
    var chapters: [ChapterMetadata] = []

    for (index, (_, data)) in sortedChapters.enumerated() {
      guard let timeString = data.time else { continue }

      let start = TimeParser.getDuration(from: timeString)
      let chapterDuration: TimeInterval

      // Calculate duration from next chapter or file duration
      if index < sortedChapters.count - 1,
         let nextTimeString = sortedChapters[index + 1].value.time {
        chapterDuration = TimeParser.getDuration(from: nextTimeString) - start
      } else {
        chapterDuration = duration - start
      }

      let chapter = ChapterMetadata(
        title: data.name ?? "",
        start: start,
        duration: chapterDuration,
        index: index + 1
      )

      chapters.append(chapter)
    }

    return chapters.isEmpty ? nil : chapters
  }

  private func extractID3Chapters(from metadata: [AVMetadataItem], duration: TimeInterval) async -> [ChapterMetadata]? {
    var chapterFramePayloads: [Data] = []

    for item in metadata {
      guard let identifier = item.identifier?.rawValue,
            identifier.hasPrefix("id3/CHAP") else { continue }

      if let frameData = try? await item.load(.dataValue) {
        chapterFramePayloads.append(frameData)
      }
    }

    if let parsedChapters = ID3ChapterParser.parseChapters(from: chapterFramePayloads, duration: duration),
       !parsedChapters.isEmpty {
      return parsedChapters
    }

    if !chapterFramePayloads.isEmpty {
      Self.logger.info("ID3 CHAP frames detected but parser did not return usable chapters")
    }

    // Compatibility fallback: if AVFoundation exposes numeric chapter positions directly.
    var fallbackChapterData: [(start: TimeInterval, title: String?)] = []
    for item in metadata {
      guard let identifier = item.identifier?.rawValue,
            identifier.hasPrefix("id3/CHAP") else { continue }

      if let numberValue = try? await item.load(.numberValue),
         numberValue.doubleValue >= 0 {
        fallbackChapterData.append((
          start: numberValue.doubleValue,
          title: try? await item.load(.stringValue)
        ))
      }
    }

    return ID3ChapterParser.buildChapterMetadata(from: fallbackChapterData, duration: duration)
  }

  private func extractOverdriveChapters(from metadata: [AVMetadataItem], duration: TimeInterval) async -> [ChapterMetadata]? {
    guard let txxxItem = metadata.first(where: { $0.identifier?.rawValue == "id3/TXXX" }),
          let overdriveMetadata = try? await txxxItem.load(.stringValue)
    else { return nil }

    let matches = overdriveMetadata.matches(of: /<Marker>(.+?)<\/Marker>/)
    var chapters: [ChapterMetadata] = []

    for (index, match) in matches.enumerated() {
      let (_, marker) = match.output

      guard let (_, timeMatch) = marker.matches(of: /<Time>(.+?)<\/Time>/).first?.output else {
        continue
      }

      let start = TimeParser.getDuration(from: String(timeMatch))
      let title: String
      
      if let (_, nameMatch) = marker.matches(of: /<Name>(.+?)<\/Name>/).first?.output {
        title = String(nameMatch)
      } else {
        title = ""
      }
      
      let chapter = ChapterMetadata(
        title: title,
        start: start,
        duration: 0, // Will be calculated below
        index: index + 1
      )

      chapters.append(chapter)
    }

    // Overdrive markers do not include the duration, we have to parse it from the next chapter over
    var finalChapters: [ChapterMetadata] = []
    for (index, chapter) in chapters.enumerated() {
      let chapterDuration: TimeInterval
      
      if index == chapters.endIndex - 1 {
        chapterDuration = duration - chapter.start
      } else {
        chapterDuration = chapters[index + 1].start - chapter.start
      }
      
      let updatedChapter = ChapterMetadata(
        title: chapter.title,
        start: chapter.start,
        duration: chapterDuration,
        index: chapter.index
      )

      finalChapters.append(updatedChapter)
    }

    return finalChapters.isEmpty ? nil : finalChapters
  }
}

struct ID3ChapterParser {
  struct ParsedChapter {
    let start: TimeInterval
    let title: String?
  }

  static func parseChapters(from framePayloads: [Data], duration: TimeInterval) -> [ChapterMetadata]? {
    let chapterData = framePayloads.compactMap(parseChapterFrame)
    return buildChapterMetadata(from: chapterData.map { ($0.start, $0.title) }, duration: duration)
  }

  static func parseChapters(fromMP3File fileURL: URL, duration: TimeInterval) -> [ChapterMetadata]? {
    guard fileURL.isFileURL else { return nil }
    guard let fileData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
          fileData.count >= 10
    else { return nil }

    guard fileData.starts(with: Data("ID3".utf8)) else { return nil }
    let majorVersion = Int(fileData[3])
    guard majorVersion == 3 || majorVersion == 4 else { return nil }

    let flags = fileData[5]
    let tagSize = Int(UInt32(syncSafeData: fileData.subdata(in: 6..<10)))
    let tagEnd = min(fileData.count, 10 + tagSize)
    guard tagEnd > 10 else { return nil }

    let tagData = fileData.subdata(in: 10..<tagEnd)
    guard let framePayloads = extractCHAPFrames(fromID3TagData: tagData, majorVersion: majorVersion, flags: flags),
          !framePayloads.isEmpty
    else {
      return nil
    }

    return parseChapters(from: framePayloads, duration: duration)
  }

  static func parseChapters(fromID3TagData tagData: Data, majorVersion: Int, flags: UInt8, duration: TimeInterval) -> [ChapterMetadata]? {
    guard let framePayloads = extractCHAPFrames(fromID3TagData: tagData, majorVersion: majorVersion, flags: flags),
          !framePayloads.isEmpty
    else {
      return nil
    }
    return parseChapters(from: framePayloads, duration: duration)
  }

  static func buildChapterMetadata(
    from chapters: [(start: TimeInterval, title: String?)],
    duration: TimeInterval
  ) -> [ChapterMetadata]? {
    guard duration.isFinite, duration > 0 else { return nil }

    let sortedChapters = chapters
      .filter { $0.start.isFinite && $0.start >= 0 && $0.start < duration }
      .sorted { $0.start < $1.start }

    var normalizedChapters: [(start: TimeInterval, title: String?)] = []
    var previousStart: TimeInterval = -1

    for chapter in sortedChapters {
      guard chapter.start > previousStart else { continue }
      normalizedChapters.append(chapter)
      previousStart = chapter.start
    }

    guard !normalizedChapters.isEmpty else { return nil }

    var result: [ChapterMetadata] = []
    for (index, chapter) in normalizedChapters.enumerated() {
      let nextStart = index < normalizedChapters.count - 1 ? normalizedChapters[index + 1].start : duration
      let chapterDuration = nextStart - chapter.start
      guard chapterDuration > 0 else { continue }

      let trimmedTitle = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let finalTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle! : "Chapter \(index + 1)"

      result.append(
        ChapterMetadata(
          title: finalTitle,
          start: chapter.start,
          duration: chapterDuration,
          index: index + 1
        )
      )
    }

    return result.isEmpty ? nil : result
  }

  static func parseChapterFrame(from rawFrameData: Data) -> ParsedChapter? {
    let payload = stripCHAPFrameHeaderIfNeeded(from: rawFrameData)

    guard let elementIdEnd = payload.firstIndex(of: 0) else { return nil }
    let minimumLengthAfterElementId = 16
    guard payload.count >= elementIdEnd + 1 + minimumLengthAfterElementId else { return nil }

    let startOffset = elementIdEnd + 1
    let startMilliseconds = UInt32(bigEndianData: payload.subdata(in: startOffset..<(startOffset + 4)))
    let startSeconds = TimeInterval(startMilliseconds) / 1000

    let subFramesOffset = startOffset + minimumLengthAfterElementId
    let title = payload.count > subFramesOffset
      ? parseChapterTitle(from: payload.subdata(in: subFramesOffset..<payload.count))
      : nil

    return ParsedChapter(start: startSeconds, title: title)
  }

  private static func stripCHAPFrameHeaderIfNeeded(from data: Data) -> Data {
    guard data.count > 10 else { return data }

    let frameIdentifier = String(data: data.subdata(in: 0..<4), encoding: .ascii)
    guard frameIdentifier == "CHAP" else { return data }

    let sizeBytes = data.subdata(in: 4..<8)
    let standardSize = Int(UInt32(bigEndianData: sizeBytes))
    let syncSafeSize = Int(UInt32(syncSafeData: sizeBytes))

    if standardSize > 0, 10 + standardSize <= data.count {
      return data.subdata(in: 10..<(10 + standardSize))
    }

    if syncSafeSize > 0, 10 + syncSafeSize <= data.count {
      return data.subdata(in: 10..<(10 + syncSafeSize))
    }

    return data.subdata(in: 10..<data.count)
  }

  private static func extractCHAPFrames(fromID3TagData tagData: Data, majorVersion: Int, flags: UInt8) -> [Data]? {
    var framesOffset = 0

    // ID3 extended header
    if (flags & 0x40) != 0 {
      guard tagData.count >= 4 else { return nil }
      let extHeaderSize: Int
      if majorVersion == 4 {
        extHeaderSize = Int(UInt32(syncSafeData: tagData.subdata(in: 0..<4)))
      } else {
        extHeaderSize = Int(UInt32(bigEndianData: tagData.subdata(in: 0..<4)))
      }
      guard extHeaderSize > 0, extHeaderSize <= tagData.count else { return nil }
      framesOffset = extHeaderSize
    }

    var chapterFrames: [Data] = []
    var offset = framesOffset

    while offset + 10 <= tagData.count {
      let frameHeader = tagData.subdata(in: offset..<(offset + 10))
      let frameIdData = frameHeader.subdata(in: 0..<4)

      if frameIdData.allSatisfy({ $0 == 0 }) {
        break
      }

      guard let frameId = String(data: frameIdData, encoding: .ascii),
            frameId.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
        break
      }

      let sizeBytes = frameHeader.subdata(in: 4..<8)
      let standardSize = Int(UInt32(bigEndianData: sizeBytes))
      let syncSafeSize = Int(UInt32(syncSafeData: sizeBytes))
      let frameSize: Int
      if majorVersion == 4 {
        frameSize = syncSafeSize
      } else {
        frameSize = standardSize
      }

      guard frameSize > 0 else { break }
      let nextOffset = offset + 10 + frameSize
      guard nextOffset <= tagData.count else { break }

      if frameId == "CHAP" {
        chapterFrames.append(tagData.subdata(in: offset..<nextOffset))
      }

      offset = nextOffset
    }

    return chapterFrames.isEmpty ? nil : chapterFrames
  }

  private static func parseChapterTitle(from subFramesData: Data) -> String? {
    var offset = 0

    while offset + 10 <= subFramesData.count {
      let frameIdData = subFramesData.subdata(in: offset..<(offset + 4))
      guard let frameId = String(data: frameIdData, encoding: .ascii),
            frameId.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
        break
      }

      let frameSizeData = subFramesData.subdata(in: (offset + 4)..<(offset + 8))
      let standardSize = Int(UInt32(bigEndianData: frameSizeData))
      let syncSafeSize = Int(UInt32(syncSafeData: frameSizeData))

      let frameSize: Int
      if standardSize > 0, offset + 10 + standardSize <= subFramesData.count {
        frameSize = standardSize
      } else if syncSafeSize > 0, offset + 10 + syncSafeSize <= subFramesData.count {
        frameSize = syncSafeSize
      } else {
        break
      }

      let payloadStart = offset + 10
      let payloadEnd = payloadStart + frameSize
      let payload = subFramesData.subdata(in: payloadStart..<payloadEnd)

      if frameId == "TIT2" || frameId == "TIT3",
         let title = decodeTextFramePayload(payload),
         !title.isEmpty {
        return title
      }

      offset = payloadEnd
    }

    return nil
  }

  private static func decodeTextFramePayload(_ payload: Data) -> String? {
    guard !payload.isEmpty else { return nil }

    let encodingByte = payload[payload.startIndex]
    let textData = payload.dropFirst()

    let decodedText: String?
    switch encodingByte {
    case 0:
      decodedText = String(data: Data(textData), encoding: .isoLatin1)
    case 1:
      decodedText = String(data: Data(textData), encoding: .utf16)
    case 2:
      decodedText = String(data: Data(textData), encoding: .utf16BigEndian)
    case 3:
      decodedText = String(data: Data(textData), encoding: .utf8)
    default:
      decodedText = String(data: Data(textData), encoding: .utf8)
    }

    return decodedText?
      .replacingOccurrences(of: "\u{0000}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private extension UInt32 {
  init(bigEndianData data: Data) {
    precondition(data.count == 4)
    self = data.reduce(UInt32(0)) { partialResult, byte in
      (partialResult << 8) | UInt32(byte)
    }
  }

  init(syncSafeData data: Data) {
    precondition(data.count == 4)
    self = data.reduce(UInt32(0)) { partialResult, byte in
      (partialResult << 7) | UInt32(byte & 0x7F)
    }
  }
}
