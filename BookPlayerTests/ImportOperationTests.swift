//
//  ImportOperationTests.swift
//  BookPlayerTests
//
//  Created by Gianni Carlo on 9/13/18.
//  Copyright © 2018 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

// MARK: - processFiles()

class ImportOperationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    // Put setup code here. This method is called before the invocation of each test method in the class.
    let documentsFolder = DataManager.getDocumentsFolderURL()
    DataTestUtils.clearFolderContents(url: documentsFolder)
  }

  func testProcessOneFile() {
    let filename = "file.txt"
    let bookContents = "bookcontents".data(using: .utf8)!
    let documentsFolder = DataManager.getDocumentsFolderURL()

    // Add test file to Documents folder
    let fileUrl = DataTestUtils.generateTestFile(name: filename, contents: bookContents, destinationFolder: documentsFolder)

    let promise = XCTestExpectation(description: "Process file")
    let promiseFile = expectation(forNotification: .processingFile, object: nil)
    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    let audioMetadataService = AudioMetadataService()
    let libraryService = LibraryService()
    libraryService.setup(dataManager: dataManager, audioMetadataService: audioMetadataService)
    let operation = ImportOperation(files: [fileUrl],
                                    libraryService: libraryService)

    operation.completionBlock = {
      // Test file should no longer be in the Documents folder,
      // but when testing on simulator, the security scope is resolved
      XCTAssert(!FileManager.default.fileExists(atPath: fileUrl.path))

      XCTAssertNotNil(operation.files.first)
      XCTAssertNotNil(operation.processedFiles.first)

      let processedFile = operation.processedFiles.first!

      // Test file exists in new location
      XCTAssert(FileManager.default.fileExists(atPath: processedFile.path))

      let content = FileManager.default.contents(atPath: processedFile.path)!
      XCTAssert(content == bookContents)

      promise.fulfill()
    }

    operation.start()

    wait(for: [promise, promiseFile], timeout: 15)
  }
}

final class AudioMetadataServiceID3ChapterParserTests: XCTestCase {
  func testID3ChapterParserParsesThreeChaptersWithTitlesAndDurations() {
    let duration: TimeInterval = 1718.695
    let frames: [Data] = [
      makeCHAPFrame(startMilliseconds: 0, title: "Chapter 1", elementId: "ch1"),
      makeCHAPFrame(startMilliseconds: 17_879, title: "Chapter 2", elementId: "ch2"),
      makeCHAPFrame(startMilliseconds: 1_012_483, title: "Chapter 3", elementId: "ch3")
    ]

    let chapters = ID3ChapterParser.parseChapters(from: frames, duration: duration)

    XCTAssertNotNil(chapters)
    XCTAssertEqual(chapters?.count, 3)

    XCTAssertEqual(chapters?[0].title, "Chapter 1")
    XCTAssertEqual(chapters?[1].title, "Chapter 2")
    XCTAssertEqual(chapters?[2].title, "Chapter 3")

    XCTAssertEqual(chapters?[0].start ?? -1, 0, accuracy: 0.000_1)
    XCTAssertEqual(chapters?[1].start ?? -1, 17.879, accuracy: 0.000_1)
    XCTAssertEqual(chapters?[2].start ?? -1, 1012.483, accuracy: 0.000_1)

    XCTAssertEqual(chapters?[0].duration ?? -1, 17.879, accuracy: 0.000_1)
    XCTAssertEqual(chapters?[1].duration ?? -1, 994.604, accuracy: 0.000_1)
    XCTAssertEqual(chapters?[2].duration ?? -1, 706.212, accuracy: 0.000_1)
  }

  func testID3ChapterParserUsesFallbackTitlesWhenMissing() {
    let duration: TimeInterval = 120
    let frames: [Data] = [
      makeCHAPFrame(startMilliseconds: 0, title: nil, elementId: "ch1"),
      makeCHAPFrame(startMilliseconds: 30_000, title: nil, elementId: "ch2"),
      makeCHAPFrame(startMilliseconds: 60_000, title: nil, elementId: "ch3")
    ]

    let chapters = ID3ChapterParser.parseChapters(from: frames, duration: duration)

    XCTAssertEqual(chapters?.count, 3)
    XCTAssertEqual(chapters?[0].title, "Chapter 1")
    XCTAssertEqual(chapters?[1].title, "Chapter 2")
    XCTAssertEqual(chapters?[2].title, "Chapter 3")
  }

  func testID3ChapterParserIgnoresInvalidAndNonIncreasingEntries() {
    let duration: TimeInterval = 80
    let validFrame = makeCHAPFrame(startMilliseconds: 10_000, title: "Valid", elementId: "valid")
    let duplicateStartFrame = makeCHAPFrame(startMilliseconds: 10_000, title: "Duplicate", elementId: "dup")
    let outOfBoundsFrame = makeCHAPFrame(startMilliseconds: 120_000, title: "Out", elementId: "out")

    let chapters = ID3ChapterParser.parseChapters(from: [validFrame, duplicateStartFrame, outOfBoundsFrame], duration: duration)

    XCTAssertEqual(chapters?.count, 1)
    XCTAssertEqual(chapters?.first?.title, "Valid")
    XCTAssertEqual(chapters?.first?.start ?? -1, 10, accuracy: 0.000_1)
    XCTAssertEqual(chapters?.first?.duration ?? -1, 70, accuracy: 0.000_1)
  }

  func testID3ChapterParserReturnsNilForCorruptedFrames() {
    let corruptedData = Data([0x43, 0x48, 0x41]) // Incomplete "CHA"

    let chapters = ID3ChapterParser.parseChapters(from: [corruptedData], duration: 100)

    XCTAssertNil(chapters)
  }

  private func makeCHAPFrame(startMilliseconds: UInt32, title: String?, elementId: String) -> Data {
    var payload = Data(elementId.utf8)
    payload.append(0x00)
    payload.append(contentsOf: startMilliseconds.id3BigEndianBytes)
    payload.append(contentsOf: UInt32(0).id3BigEndianBytes)
    payload.append(contentsOf: UInt32(0).id3BigEndianBytes)
    payload.append(contentsOf: UInt32(0).id3BigEndianBytes)

    if let title {
      payload.append(makeTextFrame(frameId: "TIT2", text: title))
    }

    var frame = Data("CHAP".utf8)
    frame.append(contentsOf: UInt32(payload.count).id3BigEndianBytes)
    frame.append(0x00)
    frame.append(0x00)
    frame.append(payload)

    return frame
  }

  private func makeTextFrame(frameId: String, text: String) -> Data {
    var payload = Data([0x03]) // UTF-8
    payload.append(Data(text.utf8))

    var frame = Data(frameId.utf8)
    frame.append(contentsOf: UInt32(payload.count).id3BigEndianBytes)
    frame.append(0x00)
    frame.append(0x00)
    frame.append(payload)

    return frame
  }
}

private extension UInt32 {
  var id3BigEndianBytes: [UInt8] {
    [
      UInt8((self >> 24) & 0xFF),
      UInt8((self >> 16) & 0xFF),
      UInt8((self >> 8) & 0xFF),
      UInt8(self & 0xFF)
    ]
  }
}
