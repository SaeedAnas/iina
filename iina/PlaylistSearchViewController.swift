//
//  PlaylistSearchViewController.swift
//  iina
//
//  Created by Anas Saeed on 5/22/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation
import Cocoa
import AVFoundation

fileprivate let WindowWidth = 600
fileprivate let InputFieldHeight = 46
fileprivate let TableCellHeight = 40
fileprivate let MaxTableViewHeight = TableCellHeight * 10
fileprivate let BottomMargin = 6

fileprivate let TableCellFontSize = 13

fileprivate let MinScore = 5 // Minimum matching score to be rendered on search results table

fileprivate let MenuItemFileName = 1
fileprivate let MenuItemTitle = 2
fileprivate let MenuItemArtist = 3
fileprivate let MenuItemRecents = 4
fileprivate let MenuItemThumbnail = 5
fileprivate let MenuItemRecentSearch = 101

typealias Metadata = (title: String?, album: String?, artist: String?, duration: Double?)

class PlaylistSearchViewController: NSWindowController {
  
  override var windowNibName: NSNib.Name {
    return NSNib.Name("PlaylistSearchViewController")
  }
  
  weak var playlistViewController: PlaylistViewController! {
    didSet {
      self.player = playlistViewController.player
    }
  }
  
  weak var player: PlayerCore!
  
  // Click Monitor for detecting if a click occured on the main window, if so, then the search window will close
  private var clickMonitor: Any?
  private var isOpen = false
  
  // MARK: Menu Preferences
  var searchOptions: [SearchOption] = [.filename, .artist, .title]
  var searchHistory: [String] = []
  var useThumbnail = true
  
  // MARK: Search Results
  var searchResults: [SearchItem] = []
  var thumbnails: [String: NSImage] = [:]
  var thumbnailWorkQueue: DispatchQueue = DispatchQueue(label: "IINAPlaylistThumbnailTask", qos: .userInitiated)
  var thumbnailSemaphore = DispatchSemaphore(value: 1)
  // Run the fuzzy matching in a different thread so we don't pause the inputField
  var searchWorkQueue: DispatchQueue = DispatchQueue(label: "IINAPlaylistSearchTask", qos: .userInitiated)
  // Make the searching cancellable so we aren't searching for a pattern when the pattern has changed
  var searchWorkItem: DispatchWorkItem? = nil
  
  // Make updating the ui cancellable so we aren't rendering old search results
  var updateTableWorkItem: DispatchWorkItem? = nil
  
  // Fixes bug where table would render search results if user clears input before searchWorkItem is finished
  var isInputEmpty = true
  
  // MARK: Observed Values
  internal var observedPrefKeys: [Preference.Key] = [
    .themeMaterial
  ]
  
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath, let change = change else { return }
    
    switch keyPath {
    case PK.themeMaterial.rawValue:
      if let newValue = change[.newKey] as? Int {
        setMaterial(Preference.Theme(rawValue: newValue))
      }
    default:
      return
    }
  }
  
  internal func setMaterial(_ theme: Preference.Theme?) {
    guard let window = window, let theme = theme else { return }
    
    if #available(macOS 10.14, *) {
      window.appearance = NSAppearance(iinaTheme: theme)
    }
  }
  
  // MARK: Click Events
  /**
   Creates a monitor for outside clicks. If user clicks outside the search window, the window will be hidden
   */
  func addClickMonitor() {
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.leftMouseDown) {
      (event) -> NSEvent? in
      if !(self.window?.windowNumber == event.windowNumber) {
        self.hideSearchWindow()
      }
      return event
    }
  }
  
  func removeClickMonitor() {
    if clickMonitor != nil {
      NSEvent.removeMonitor(clickMonitor!)
      clickMonitor = nil
    }
  }
  
  deinit {
    ObjcUtils.silenced {
      for key in self.observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
    removeClickMonitor()
  }
  
  // MARK: Outlets
  @IBOutlet weak var inputField: NSTextField!
  @IBOutlet weak var clearBtn: NSButton!
  @IBOutlet weak var searchResultsTableView: NSTableView!
  @IBOutlet weak var inputBorderBottom: NSBox!
  @IBOutlet weak var searchPopUp: NSPopUpButton!
  
  @IBAction func useFileName(_ sender: Any) {
    toggleOption(.filename)
  }
  
  @IBAction func useTitle(_ sender: Any) {
    toggleOption(.title)
  }
  @IBAction func useArtist(_ sender: Any) {
    toggleOption(.artist)
  }
  
  @IBAction func useThumbnail(_ sender: Any) {
    useThumbnail = !useThumbnail
    if !useThumbnail {
      thumbnails.removeAll()
      searchResultsTableView.tableColumns[0].isHidden = true
    } else {
      searchResultsTableView.tableColumns[0].isHidden = false
    }
    reloadTable()
  }
  
  func toggleOption(_ option: SearchOption) {
    if searchOptions.contains(option) {
      searchOptions.removeAll {
        item in item == option
      }
    } else {
      searchOptions.append(option)
    }
    search(input: inputField.stringValue)
  }
  
  override func windowDidLoad() {
    super.windowDidLoad()
    
    // Reset Input
    hideClearBtn()
    hideTable()
    
    // Remove window titlebar and buttons
    window?.isMovableByWindowBackground = true
    window?.titlebarAppearsTransparent = true
    window?.titleVisibility = .hidden
    ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).forEach {
      window?.standardWindowButton($0)?.isHidden = true
    }
    
    // Observe theme changes
    setMaterial(Preference.enum(for: .themeMaterial))
    
    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }
    
    // Delegates
    inputField.delegate = self
    searchPopUp.menu?.delegate = self
    searchPopUp.menu?.items.forEach{( $0.target = self )}
    
    searchResultsTableView.delegate = self
    searchResultsTableView.dataSource = self
    
    searchResultsTableView.doubleAction = #selector(handleSubmit)
    searchResultsTableView.action = #selector(handleSubmit)
    
    metadataWorkQueue.async {
      self.indexPlaylist(playlist: self.player.info.playlist)
    }
  }
  
  // MARK: Showing and Hiding Window and Elements
  func openSearchWindow() {
    if isOpen {
      return
    }
    isOpen = true
    
    addClickMonitor()
    showWindow(nil)
    focusInput()
  }
  
  func hideSearchWindow() {
    if !isOpen {
      return
    }
    isOpen = false
    
    window?.close()
    removeClickMonitor()
  }
  
  @objc func cancel(_ sender: Any?) {
    hideSearchWindow()
  }
  
  func hideClearBtn() {
    clearBtn.isHidden = true
  }
  
  func showClearBtn() {
    clearBtn.isHidden = false
  }
  
  func hideTable() {
    searchResultsTableView.isHidden = true
    inputBorderBottom.isHidden = true
    
    let size = NSMakeSize(CGFloat(WindowWidth), CGFloat(InputFieldHeight))
    window?.setContentSize(size)
  }
  
  func showTable() {
    searchResultsTableView.isHidden = false
    inputBorderBottom.isHidden = false
    
    resizeTable()
    // Make the first item selected
    changeSelection(by: 1)
  }
  
  func resizeTable() {
    let maxHeight = InputFieldHeight + MaxTableViewHeight + BottomMargin
    
    let neededHeight = InputFieldHeight + (searchResults.count * TableCellHeight) + BottomMargin
    
    let height = (neededHeight < maxHeight) ? neededHeight : maxHeight
    
    let size = NSMakeSize(CGFloat(WindowWidth), CGFloat(height))
    window?.setContentSize(size)
  }
  
  func focusInput() {
    window?.makeFirstResponder(inputField)
  }
  
  // MARK: IBActions
  @IBAction func clearBtnAction(_ sender: Any) {
    clearInput()
  }
  
  // MARK: Input and SearchResults utilities
  
  func clearInput() {
    searchWorkItem?.cancel()
    inputField.stringValue = ""
    isInputEmpty = true
    hideClearBtn()
    clearSearchResults()
    focusInput()
    thumbnails.removeAll()
  }
  
  func clearSearchResults() {
    searchResults.removeAll()
    reloadTable()
  }
  
  func reloadTable() {
    updateTableWorkItem?.cancel()
    updateTableWorkItem = DispatchWorkItem {
      self.searchResultsTableView.reloadData()
      
      if self.searchResults.isEmpty {
        self.hideTable()
      } else {
        self.showTable()
      }
    }
    DispatchQueue.main.async(execute: updateTableWorkItem!)
  }
  
  func changeSelection(by: Int) {
    let length = searchResultsTableView.numberOfRows
    
    let selected = searchResultsTableView.selectedRow
    
    var updated = selected + by
    
    if updated >= length {
      updated = 0
    } else if updated < 0 {
      updated = length - 1
    }
    
    let indexSet = NSIndexSet(index: updated)
    searchResultsTableView.selectRowIndexes(indexSet as IndexSet, byExtendingSelection: false)
    searchResultsTableView.scrollRowToVisible(updated)
  }
  
  func getPlaylistIndex(searchItem: SearchItem) -> Int? {
    let playlist = player.info.playlist
    guard let item = playlist[at: searchItem.playlistIndex] else { return nil }
    
    if item.filename == searchItem.item.filename {
      return searchItem.playlistIndex
    }
    
    else {
      return player.info.playlist.firstIndex { i in
        i.filename == searchItem.item.filename
      }
    }
    
  }
  
  func addSearchHistory(input: String) {
    searchHistory.removeAll { item in
      item == input
    }
    
    searchHistory.insert(input, at: 0)
    
    if searchHistory.count > 10 {
      searchHistory.removeLast()
    }
  }
  
  func clearHistory() {
    searchHistory.removeAll()
  }
  
  @objc func handleSubmit() {
    guard let item = searchResults[at: searchResultsTableView.selectedRow] ?? searchResults.first else { return }
    guard let index = getPlaylistIndex(searchItem: item) else { return }
    
    addSearchHistory(input: inputField.stringValue)
    
    player.playFileInPlaylist(index)
    
    playlistViewController.playlistTableView.scrollRowToVisible(index)
    
    hideSearchWindow()
  }
  
  func search(input: String) {
    // Removes spaces from pattern
    // If your input was "hello world", the fuzzy match wouldn't match "helloworld" as a favorable option because of the space in between the two words
    let input = input.filter {!$0.isWhitespace}
    
    searchWorkItem?.cancel()
    
    if input.isEmpty {
      searchWorkItem = nil
      
      clearInput()
      return
    }
    
    showClearBtn()
    
    isInputEmpty = false
    
    let playlist = player.info.playlist
    
    searchWorkItem = DispatchWorkItem {
      //      let results = searchPlaylist(playlist: playlist, pattern: input)
      let results = self.searchMetadata(playlist: playlist, pattern: input)
      
      if self.isInputEmpty {
        return
      }
      
      self.searchResults = results
      
      self.reloadTable()
    }
    
    searchWorkQueue.async(execute: searchWorkItem!)
    
  }
  
  var metadataCache: [String : (title: String?, album: String?, artist: String?, duration: Double?)] = [:]
  var metadataWorkQueue: DispatchQueue = DispatchQueue(label: "IINAPlaylistMetadataTask", qos: .userInitiated)
  let metadataSemaphore = DispatchSemaphore(value: 1)
  
  func indexImage(file: String) {
    let url = URL(fileURLWithPath: file)
    let asset = AVAsset(url: url) as AVAsset
    for data in asset.commonMetadata {
      if data.commonKey == .commonKeyArtwork {
        let imageData = data.value as! Data
        let image = NSImage(data: imageData)
        thumbnailSemaphore.wait()
        self.thumbnails[file] = image
        thumbnailSemaphore.signal()
        return
      }
      if url.pathExtension != "mp3" {
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        var time: Int64 = 10
        for data in asset.commonMetadata {
          if data.commonKey == .id3MetadataKeyLength {
            let length = (data.value as! Int64)/1000
            if length < 10 {
              time = length
            }
            break
          }
        }
        do {
          let cgImage = try imgGenerator.copyCGImage(at: CMTimeMake(value: time, timescale: 1), actualTime: nil)
          let image = NSImage(cgImage: cgImage, size: NSMakeSize(CGFloat(cgImage.width), CGFloat(cgImage.height)))
          thumbnailSemaphore.wait()
          self.thumbnails[file] = image
          thumbnailSemaphore.signal()
          return
        }
        catch let error {
          Logger.log("*** Error generating thumbnail: \(error.localizedDescription)")
        }
      }
    }
  }
  
  func getMetadata(file: String) -> (title: String?, album: String?, artist: String?, duration: Double?) {
    let url = URL(fileURLWithPath: file)
    let asset = AVAsset(url: url) as AVAsset
    var metadata: (title: String?, album: String?, artist: String?, duration: Double?) = (nil, nil, nil, nil)
    for data in asset.commonMetadata {
      if data.commonKey == .commonKeyTitle {
        metadata.title = data.value as? String
      }
      else if data.commonKey ==  .commonKeyArtist {
        metadata.artist = data.value as? String
      }
      else if data.commonKey ==  .commonKeyAlbumName {
        metadata.album = data.value as? String
      }
    }
    metadata.duration = asset.duration.seconds
    
    return metadata
    
  }
  
  func iinaMetadata(file: String) -> (title: String?, album: String?, artist: String?, duration: Double?) {
    var metadata: (title: String?, album: String?, artist: String?, duration: Double?) = (nil, nil, nil, nil)
    player.refreshCachedVideoInfo(forVideoPath: file)
    if let cache = player.info.getCachedMetadata(file) {
      metadata.title = cache.title
      metadata.artist = cache.artist
      metadata.album = cache.album
    }
    
    if let data = player.info.getCachedVideoDurationAndProgress(file), let duration = data.duration {
      metadata.duration = duration
    }
    
    return metadata
  }
  
  func syncIndexPlaylist(playlist: [MPVPlaylistItem]) {
    for item in playlist {
      let file = item.filename
      if self.metadataCache[file] == nil {
        //        let metadata = self.getMetadata(file: file)
        let metadata = self.iinaMetadata(file: file)
        metadataSemaphore.wait()
        metadataCache[file] = metadata
        metadataSemaphore.signal()
      }
    }
  }
  
  func indexFile(file: String) {
    let metadata = getMetadata(file: file)
    metadataSemaphore.wait()
    metadataCache[file] = metadata
    metadataSemaphore.signal()
  }
  
  func iinaIndexFile(file: String) {
    let metadata = iinaMetadata(file: file)
    metadataSemaphore.wait()
    metadataCache[file] = metadata
    metadataSemaphore.signal()
  }
  
  func indexPlaylist(playlist: [MPVPlaylistItem]) {
    let size = playlist.count < 10 ? 1 : playlist.count / 10
    let group = DispatchGroup()
    for i in stride(from: 0, to: playlist.count, by: size) {
      metadataWorkQueue.async {
        group.enter()
        let chunk = playlist[i..<min(i+size, playlist.count)]
        for item in chunk {
          if self.metadataCache[item.filename] == nil {
            if !item.isNetworkResource {
              self.iinaIndexFile(file: item.filename)
              //            self.indexFile(file: item.filename)
            }
          }
        }
        group.leave()
      }
    }
    group.wait()
  }
  
  func searchMetadata(playlist: [MPVPlaylistItem], pattern: String) -> [SearchItem] {
    
    if searchOptions.count == 1 && searchOptions.contains(.filename) {
      return searchPlaylist(playlist: playlist, pattern: pattern)
    }
    
    indexPlaylist(playlist: playlist)
    //    syncIndexPlaylist(playlist: playlist)
    
    var results: [SearchItem] = []
    
    for (index, item) in playlist.enumerated() {
      if item.isNetworkResource {
        let result = fuzzyMatch(text: item.filenameForDisplay, pattern: pattern)
        if result.score < MinScore {
          continue
        }
        let searchItem = SearchItem(item: item, result: result, playlistIndex: index, option: .filename, text: item.filenameForDisplay)
        results.append(searchItem)
        continue
      }
      metadataSemaphore.wait()
      let metadata = metadataCache[item.filename]
      metadataSemaphore.signal()
      var options: [(result: Result, option: SearchOption, text: String)] = []
      for option in searchOptions {
        switch option {
        case .filename:
          let text = item.filenameForDisplay
          options.append((fuzzyMatch(text: text, pattern: pattern), .filename, text))
        case .artist:
          guard let text = metadata?.artist else { continue }
          options.append((fuzzyMatch(text: text, pattern: pattern), .artist, text))
        case .title:
          guard let text = metadata?.title else { continue }
          options.append((fuzzyMatch(text: text, pattern: pattern), .title, text))
        }
      }
      
      if options.count == 0 {
        continue
      }
      
      options.sort { item1, item2 in item1.result.score > item2.result.score }
      let result = options[0].result
      let option = options[0].option
      let text = options[0].text
      
      
      if result.score < MinScore {
        continue
      }
      
      let searchItem = SearchItem(item: item, result: result, playlistIndex: index, option: option, text: text)
      
      results.append(searchItem)
      
    }
    
    results.sort(by: >)
    
    return results
  }
  
}

// MARK: Input Text Field Delegate
extension PlaylistSearchViewController: NSTextFieldDelegate, NSControlTextEditingDelegate {
  func controlTextDidChange(_ obj: Notification) {
    search(input: inputField.stringValue)
  }
  
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    // Esc: clear input or hide window
    if commandSelector == #selector(cancel(_:)) {
      if inputField.stringValue == "" {
        return false
      }
      clearInput()
      return true
    }
    // Up or Shift+Tab: Move table selection up by 1
    else if commandSelector == #selector(moveUp(_:)) || commandSelector == #selector(insertBacktab(_:)) {
      changeSelection(by: -1)
      return true
    }
    // Down or Tab: Move table selection down by 1
    else if commandSelector == #selector(moveDown(_:)) || commandSelector == #selector(insertTab(_:)) {
      changeSelection(by: 1)
      return true
    }
    // Enter: play selected file
    else if commandSelector == #selector(insertNewline(_:)) {
      handleSubmit()
      return false
    }
    return false
  }
  
}

// MARK: Menu Delegate
extension PlaylistSearchViewController: NSMenuDelegate, NSMenuItemValidation {
  @IBAction func changeSearch(_ sender: NSMenuItem) {
    inputField.stringValue = sender.title
    search(input: inputField.stringValue)
  }
  
  @IBAction func clearSearchHistory(_ sender: NSMenuItem) {
    searchHistory.removeAll()
  }
  
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.tag {
    case MenuItemFileName:
      menuItem.state = searchOptions.contains(.filename) ? .on : .off
    case MenuItemArtist:
      menuItem.state = searchOptions.contains(.artist) ? .on : .off
    case MenuItemTitle:
      menuItem.state = searchOptions.contains(.title) ? .on : .off
    case MenuItemThumbnail:
      menuItem.state = useThumbnail ? .on : .off
    default:
      break
    }
    
    return menuItem.isEnabled
  }
  
  func menuWillOpen(_ menu: NSMenu) {
    menu.items.forEach { item in
      if item.tag == MenuItemRecents {
        item.title = searchHistory.isEmpty ? "No Recent Searches" : "Recent Searches"
      }
      if item.tag == MenuItemRecentSearch {
        menu.removeItem(item)
      }
    }
    
    if !searchHistory.isEmpty {
      searchHistory.forEach { history in
        menu.addItem(withTitle: history, action: #selector(self.changeSearch(_:)), tag: MenuItemRecentSearch)
      }
      let separator = NSMenuItem.separator()
      separator.tag = MenuItemRecentSearch
      menu.addItem(separator)
      menu.addItem(withTitle: "Clear Searches", action: #selector(self.clearSearchHistory(_:)), tag: MenuItemRecentSearch)
      
    } else {
      let separator = NSMenuItem.separator()
      separator.tag = MenuItemRecentSearch
      menu.addItem(separator)
    }
  }
}

// MARK: Table View Delegate
extension PlaylistSearchViewController: NSTableViewDelegate, NSTableViewDataSource {
  
  func numberOfRows(in tableView: NSTableView) -> Int {
    return searchResults.count
  }
  
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    if searchResults.isEmpty {
      return nil
    }
    
    
    guard let identifier = tableColumn?.identifier else { return nil }
    let v = tableView.makeView(withIdentifier: identifier, owner: self) as! NSTableCellView
    
    let searchItem = searchResults[row]
    let item = searchItem.item
    
    if identifier == .imageColumn {
      if useThumbnail {
        let imageView = v as! SearchImageCellView
        var image = NSWorkspace.shared.icon(forFile: item.filename)
        thumbnailSemaphore.wait()
        if let thumbnail = thumbnails[item.filename] {
          image = thumbnail
        } else {
          thumbnailWorkQueue.async {
            self.indexImage(file: item.filename)
            self.thumbnailSemaphore.wait()
            if let thumbnail = self.thumbnails[item.filename] {
              DispatchQueue.main.async {
                imageView.setImage(thumbnail)
              }
            }
            self.thumbnailSemaphore.signal()
          }
        }
        thumbnailSemaphore.signal()
        imageView.setImage(image)
        
        return imageView
      }
      return nil
    }
    
    if identifier == .infoColumn {
      let infoView = v as! SearchInfoCellView
      
      if searchItem.option == .title {
        infoView.setText(searchItem.text)
      } else {
        infoView.setText(item.filenameForDisplay)
      }
      
      metadataSemaphore.wait()
      let metadata = metadataCache[item.filename]
      metadataSemaphore.signal()
      
      if metadata == nil {
        DispatchQueue.main.async {
          self.indexFile(file: item.filename)
          self.metadataSemaphore.wait()
          let metadata = self.metadataCache[item.filename]
          self.metadataSemaphore.signal()
          if metadata != nil {
            infoView.setMetadata(metadata)
          }
        }
      }
      infoView.setMetadata(metadata)
      
      return infoView
    }
    
    return nil
  }

  // Enables arrow keys to be used in tableview
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    return true
  }
  
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    return FixRowView()
  }
  
}

// Fixes bug when system theme is different from IINA's selected theme, the search results would use the system theme's selected row view background instead of IINA's selected theme
class FixRowView: NSTableRowView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
  }
}

class SearchInfoCellView: NSTableCellView {
  @IBOutlet weak var titleView: NSTextField!
  @IBOutlet weak var artistView: NSTextField!
  @IBOutlet weak var durationView: NSTextField!
  
  func setText(_ text: String) {
    titleView.stringValue = text
  }
  
  func setMetadata(_ metadata: Metadata?) {
    var artistText = ""
    var durationText = ""
    if let artist = metadata?.artist {
      artistText = artist
    }
    if let duration = metadata?.duration {
      durationText = VideoTime(duration).stringRepresentation
    }
    
    artistView.stringValue = artistText
    durationView.stringValue = durationText
  }
}

class SearchImageCellView: NSTableCellView {
  @IBOutlet weak var thumbnailView:
  NSImageView!
  
  func setImage(_ image: NSImage) {
    thumbnailView.image = image
  }
  
}

extension NSUserInterfaceItemIdentifier {
  static let infoColumn = NSUserInterfaceItemIdentifier("InfoColumn")
  static let imageColumn = NSUserInterfaceItemIdentifier("ImageColumn")
}


// MARK: Search Playlist

// TODO: Move to another file
enum SearchOption {
  case filename, artist, title
}

struct SearchItem {
  let item: MPVPlaylistItem
  let result: Result
  let playlistIndex: Int
  let option: SearchOption
  let text: String
}

extension SearchItem: Comparable {
  static func < (l: SearchItem, r: SearchItem) -> Bool {
    return l.result.score < r.result.score
  }
  
  static func > (l: SearchItem, r: SearchItem) -> Bool {
    return l.result.score > r.result.score
  }
  
  static func == (l: SearchItem, r: SearchItem) -> Bool {
    return l.result.score == r.result.score
  }
}

func searchPlaylist(playlist: [MPVPlaylistItem], pattern: String) -> [SearchItem] {
  var results: [SearchItem] = []
  
  for (index, item) in playlist.enumerated() {
    let result = fuzzyMatch(text: item.filenameForDisplay, pattern: pattern)
    
    if result.score < MinScore {
      continue
    }
    
    let searchItem = SearchItem(item: item, result: result, playlistIndex: index, option: .filename, text: item.filenameForDisplay)
    
    results.append(searchItem)
  }
  
  results.sort(by: >)
  
  return results
}
