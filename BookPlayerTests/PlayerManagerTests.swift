//
//  PlayerManagerTests.swift
//  BookPlayerTests
//
//  Created by gianni.carlo on 18/5/22.
//  Copyright © 2022 BookPlayer LLC. All rights reserved.
//

import Foundation
import MediaPlayer

@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

class PlayerManagerTests: XCTestCase {
  var playbackServiceMock: PlaybackServiceProtocolMock!
  var libraryServiceMock: LibraryServiceProtocolMock!
  var syncServiceMock: SyncServiceProtocolMock!
  var sut: PlayerManager!

  override func setUp() {
    // Clean up stored configs
    UserDefaults.sharedDefaults.removeObject(forKey: Constants.UserDefaults.chapterContextEnabled)
    UserDefaults.sharedDefaults.removeObject(forKey: Constants.UserDefaults.remainingTimeEnabled)

    self.playbackServiceMock = PlaybackServiceProtocolMock()
    self.libraryServiceMock = LibraryServiceProtocolMock()
    self.syncServiceMock = SyncServiceProtocolMock()
    self.syncServiceMock.isActive = false
    self.sut = PlayerManager(
      libraryService: libraryServiceMock,
      playbackService: playbackServiceMock,
      syncService: syncServiceMock,
      speedService: SpeedServiceProtocolMock(),
      shakeMotionService: ShakeMotionServiceProtocolMock(),
      widgetReloadService: WidgetReloadService()
    )
  }

  private func generatePlayableItem() -> PlayableItem {
    let testChapter = PlayableChapter(
      title: "test chapter 1",
      author: "test author chapter",
      start: 0,
      duration: 50,
      relativePath: "",
      remoteURL: nil,
      index: 0
    )
    let testChapter2 = PlayableChapter(
      title: "test chapter 2",
      author: "test author chapter 2",
      start: 51,
      duration: 100,
      relativePath: "",
      remoteURL: nil,
      index: 1
    )
    return PlayableItem(
      title: "test book",
      author: "test author",
      chapters: [testChapter, testChapter2],
      currentTime: 0,
      duration: 100,
      relativePath: "",
      parentFolder: nil,
      percentCompleted: 10,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )
  }

  func testUpdatingEmptyNowPlayingBookTime() {
    self.sut.setNowPlayingBookTime()

    XCTAssertNil(self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate])
    XCTAssertNil(self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime])
    XCTAssertNil(self.sut.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration])
    XCTAssertNil(self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress])
  }

  func testUpdatingGlobalNowPlayingBookTime() {
    // playback speed shouldn't affect duration time set
    self.sut.setSpeed(2)
    // mocked playable item
    let playableItem = generatePlayableItem()
    playableItem.currentTime = 20

    self.sut.currentItem = playableItem
    self.sut.setNowPlayingBookTime()

    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 20)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? Double) == 100)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] as? Double) == 0.2)
  }

  func testUpdatingGlobalRemainingNowPlayingBookTime() {
    // playback speed should affect duration time set
    self.sut.setSpeed(2)
    UserDefaults.sharedDefaults.set(true, forKey: Constants.UserDefaults.remainingTimeEnabled)
    // mocked playable item
    let playableItem = generatePlayableItem()
    playableItem.currentTime = 20

    self.sut.currentItem = playableItem
    self.sut.setNowPlayingBookTime()

    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 20)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? Double) == 60)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] as? Double) == 0.2)
  }

  func testUpdatingChapterNowPlayingBookTime() {
    // playback speed shouldn't affect duration time set
    self.sut.setSpeed(2)
    UserDefaults.sharedDefaults.set(true, forKey: Constants.UserDefaults.chapterContextEnabled)
    // mocked playable item
    let playableItem = generatePlayableItem()
    playableItem.currentTime = 10

    self.sut.currentItem = playableItem
    self.sut.setNowPlayingBookTime()

    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 10)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? Double) == 50)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] as? Double) == 0.20)
  }

  func testUpdatingChapterRemainingNowPlayingBookTime() {
    // playback speed should affect duration time set
    self.sut.setSpeed(2)
    UserDefaults.sharedDefaults.set(true, forKey: Constants.UserDefaults.remainingTimeEnabled)
    UserDefaults.sharedDefaults.set(true, forKey: Constants.UserDefaults.chapterContextEnabled)
    // mocked playable item
    let playableItem = generatePlayableItem()
    playableItem.currentTime = 10

    self.sut.currentItem = playableItem
    self.sut.setNowPlayingBookTime()

    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 10)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? Double) == 30)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] as? Double) == 0.20)
  }

  func testUpdatingEmptyNowPlayingBookTitle() {
    let playableItem = generatePlayableItem()
    let chapter = playableItem.chapters.first!

    self.sut.setNowPlayingBookTitle(chapter: chapter)

    XCTAssertNil(self.sut.nowPlayingInfo[MPMediaItemPropertyTitle])
    XCTAssertNil(self.sut.nowPlayingInfo[MPMediaItemPropertyArtist])
    XCTAssertNil(self.sut.nowPlayingInfo[MPMediaItemPropertyAlbumTitle])
  }

  func testUpdatingNowPlayingBookTitle() {
    let playableItem = generatePlayableItem()
    let chapter = playableItem.chapters.first!

    self.sut.currentItem = playableItem
    self.sut.setNowPlayingBookTitle(chapter: chapter)

    XCTAssertTrue((self.sut.nowPlayingInfo[MPMediaItemPropertyTitle] as? String) == chapter.title)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPMediaItemPropertyArtist] as? String) == playableItem.title)
    XCTAssertTrue((self.sut.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] as? String) == playableItem.author)
  }

  func testGetNextPlayableBookSuccess() {
    playbackServiceMock.getPlayableItemAfterParentFolderAutoplayedRestartFinishedReturnValue = PlayableItem.mockWithExtension("mp3")

    let nextItem = sut.getNextPlayableBook(
      after: PlayableItem.mock,
      autoPlayed: true,
      restartFinished: true
    )

    XCTAssertNotNil(nextItem)
    XCTAssertTrue(playbackServiceMock.getPlayableItemAfterParentFolderAutoplayedRestartFinishedCallsCount == 1)
  }

  func testGetNextPlayableBookJpgFail() {
    /// Test unrecognized file
    playbackServiceMock
      .getPlayableItemAfterParentFolderAutoplayedRestartFinishedClosure = { relativePath, _, _, _ in
        return [PlayableItem.mockWithExtension("jpg")].filter({ $0.relativePath != relativePath }).first
      }

    let nextItem = sut.getNextPlayableBook(
      after: PlayableItem.mock,
      autoPlayed: true,
      restartFinished: true
    )

    XCTAssertNil(nextItem)
    XCTAssertTrue(playbackServiceMock.getPlayableItemAfterParentFolderAutoplayedRestartFinishedCallsCount == 2)
  }

  func testLoadPlayerItemLocalTriggersChapterRefresh() async throws {
    let relativePath = "local-\(UUID().uuidString).mp3"
    try createPlayableFile(relativePath: relativePath)

    let chapter = makeChapter(relativePath: relativePath, remoteURL: nil)
    sut.currentItem = makePlayableItem(for: chapter)

    try await sut.loadPlayerItem(for: chapter, forceRefreshURL: false)

    XCTAssertEqual(libraryServiceMock.loadChaptersIfNeededRelativePathAssetCallsCount, 1)
    XCTAssertEqual(libraryServiceMock.loadChaptersIfNeededRelativePathAssetReceivedArguments?.relativePath, relativePath)
  }

  func testLoadRemoteURLAssetTriggersChapterRefresh() async throws {
    let relativePath = "remote-\(UUID().uuidString).mp3"
    let remoteURL = try createPlayableFile(relativePath: relativePath)

    let chapter = makeChapter(relativePath: relativePath, remoteURL: remoteURL)
    sut.currentItem = makePlayableItem(for: chapter)

    _ = try await sut.loadRemoteURLAsset(for: chapter, forceRefresh: false)

    XCTAssertEqual(libraryServiceMock.loadChaptersIfNeededRelativePathAssetCallsCount, 1)
    XCTAssertEqual(libraryServiceMock.loadChaptersIfNeededRelativePathAssetReceivedArguments?.relativePath, relativePath)
  }

  func testLoadPlayerItemLocalReloadRuntimeItemDoesNotPostInitialChapterChange() async throws {
    let relativePath = "rebind-initial-\(UUID().uuidString).mp3"
    try createPlayableFile(relativePath: relativePath)

    let currentChapter = makeChapter(relativePath: relativePath, remoteURL: nil, start: 0, duration: 10, index: 0)
    let oldItem = makePlayableItem(for: currentChapter)
    oldItem.currentTime = 12
    sut.currentItem = oldItem

    let rebuiltChapter1 = makeChapter(relativePath: relativePath, remoteURL: nil, start: 0, duration: 10, index: 0)
    let rebuiltChapter2 = makeChapter(relativePath: relativePath, remoteURL: nil, start: 10, duration: 10, index: 1)
    let rebuiltItem = PlayableItem(
      title: "book",
      author: "author",
      chapters: [rebuiltChapter1, rebuiltChapter2],
      currentTime: 0,
      duration: 20,
      relativePath: relativePath,
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )

    libraryServiceMock.getSimpleItemWithReturnValue = makeSimpleBook(relativePath: relativePath, duration: 20)
    playbackServiceMock.getPlayableItemFromReturnValue = rebuiltItem

    var chapterChangeCount = 0
    let observer = NotificationCenter.default.addObserver(
      forName: .chapterChange,
      object: nil,
      queue: .main
    ) { _ in
      chapterChangeCount += 1
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    try await sut.loadPlayerItem(for: currentChapter, forceRefreshURL: false)

    XCTAssertEqual(chapterChangeCount, 0)
    XCTAssertEqual(sut.currentItem?.currentTime ?? -1, 12, accuracy: 0.000_1)
    XCTAssertEqual(sut.currentItem?.currentChapter.start ?? -1, 10, accuracy: 0.000_1)
  }

  func testLoadPlayerItemLocalReloadRuntimeItemRebindsChapterChangeSubscription() async throws {
    let relativePath = "rebind-change-\(UUID().uuidString).mp3"
    try createPlayableFile(relativePath: relativePath)

    let currentChapter = makeChapter(relativePath: relativePath, remoteURL: nil, start: 0, duration: 10, index: 0)
    let oldItem = makePlayableItem(for: currentChapter)
    oldItem.currentTime = 12
    sut.currentItem = oldItem

    let rebuiltChapter1 = makeChapter(relativePath: relativePath, remoteURL: nil, start: 0, duration: 10, index: 0)
    let rebuiltChapter2 = makeChapter(relativePath: relativePath, remoteURL: nil, start: 10, duration: 10, index: 1)
    let rebuiltItem = PlayableItem(
      title: "book",
      author: "author",
      chapters: [rebuiltChapter1, rebuiltChapter2],
      currentTime: 0,
      duration: 20,
      relativePath: relativePath,
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )

    libraryServiceMock.getSimpleItemWithReturnValue = makeSimpleBook(relativePath: relativePath, duration: 20)
    playbackServiceMock.getPlayableItemFromReturnValue = rebuiltItem

    var chapterChangeCount = 0
    let observer = NotificationCenter.default.addObserver(
      forName: .chapterChange,
      object: nil,
      queue: .main
    ) { _ in
      chapterChangeCount += 1
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    try await sut.loadPlayerItem(for: currentChapter, forceRefreshURL: false)
    sut.currentItem?.currentChapter = rebuiltChapter1

    XCTAssertEqual(chapterChangeCount, 1)
  }

  private func makeChapter(
    relativePath: String,
    remoteURL: URL?,
    start: TimeInterval = 0,
    duration: TimeInterval = 10,
    index: Int16 = 0
  ) -> PlayableChapter {
    PlayableChapter(
      title: "chapter",
      author: "author",
      start: start,
      duration: duration,
      relativePath: relativePath,
      remoteURL: remoteURL,
      index: index
    )
  }

  private func makeSimpleBook(relativePath: String, duration: TimeInterval) -> SimpleLibraryItem {
    SimpleLibraryItem(
      title: "book",
      details: "author",
      speed: 1.0,
      currentTime: 0,
      duration: duration,
      percentCompleted: 0,
      isFinished: false,
      relativePath: relativePath,
      remoteURL: nil,
      artworkURL: nil,
      orderRank: 0,
      parentFolder: nil,
      originalFileName: relativePath,
      lastPlayDate: nil,
      type: .book
    )
  }

  private func makePlayableItem(for chapter: PlayableChapter) -> PlayableItem {
    PlayableItem(
      title: "book",
      author: "author",
      chapters: [chapter],
      currentTime: 0,
      duration: chapter.duration,
      relativePath: chapter.relativePath,
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )
  }

  @discardableResult
  private func createPlayableFile(relativePath: String) throws -> URL {
    let fileURL = DataManager.getProcessedFolderURL().appendingPathComponent(relativePath)
    let folderURL = fileURL.deletingLastPathComponent()

    try FileManager.default.createDirectory(
      at: folderURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: Data("test".utf8))
    }

    return fileURL
  }
}
