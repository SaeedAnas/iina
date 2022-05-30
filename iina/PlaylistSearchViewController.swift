//
//  PlaylistSearchViewController.swift
//  iina
//
//  Created by Anas Saeed on 5/22/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation
import Cocoa

fileprivate let WindowWidth = 600
fileprivate let InputFieldHeight = 46
fileprivate let TableCellHeight = 32
fileprivate let MaxTableViewHeight = TableCellHeight * 10
fileprivate let BottomMargin = 6

fileprivate let TableCellFontSize = 13

fileprivate let MinScore = 5 // Minimum matching score to be rendered on search results table

fileprivate let MenuItemFileName = 1
fileprivate let MenuItemTitle = 2
fileprivate let MenuItemArtist = 3
fileprivate let MenuItemRecents = 4
fileprivate let MenuItemRecentSearch = 101


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
  var searchOptions: [SearchOption] = [.filename]
  var searchHistory: [String] = []
  
  // MARK: Search Results
  var searchResults: [SearchItem] = []
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
  
  func toggleOption(_ option: SearchOption) {
    if searchOptions.contains(option) {
      searchOptions.removeAll {
        item in item == option
      }
    } else {
      searchOptions.append(option)
    }
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
  
  struct Indexed {
    let item: MPVPlaylistItem, metadata: (title: String?, album: String?, artist: String?)?
  }
  
  func index(playlist: [MPVPlaylistItem]) -> [Indexed] {
    var indexed: [Indexed] = []
    
    for item in playlist {
      func getMetadata() -> (title: String?, album: String?, artist: String?)? {
        if let metadata = player.info.getCachedMetadata(item.filename) {
          return metadata
        } else {
          player.info.player.refreshCachedVideoInfo(forVideoPath: item.filename)
          if let metadata = player.info.getCachedMetadata(item.filename) {
            return metadata
          } else {
            return nil
          }
        }
      }
      indexed.append(Indexed(item: item, metadata: getMetadata()))
    }
    
    return indexed

  }
  
  func searchMetadata(playlist: [MPVPlaylistItem], pattern: String) -> [SearchItem] {
    
    if searchOptions.count == 1 && searchOptions.contains(.filename) {
      return searchPlaylist(playlist: playlist, pattern: pattern)
    }
    
    let indexed = index(playlist: playlist)
    
    var results: [SearchItem] = []
    
    for (index, item) in indexed.enumerated() {
      var options: [(result: Result, option: SearchOption, text: String)] = []
      for option in searchOptions {
        switch option {
        case .filename:
          let text = item.item.filenameForDisplay
          options.append((fuzzyMatch(text: text, pattern: pattern), .filename, text))
        case .artist:
          guard let text = item.metadata?.artist else { continue }
          options.append((fuzzyMatch(text: text, pattern: pattern), .artist, text))
        case .title:
          guard let text = item.metadata?.title else { continue }
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
      let searchItem = SearchItem(item: item.item, result: result, playlistIndex: index, option: option, text: text)
      
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
  
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    
    if searchResults.isEmpty {
      return nil
    }
    
    let searchItem = searchResults[row]
    let render = NSMutableAttributedString(string: searchItem.text)
    
    if searchItem.option == .artist {
      var durationLabel: String = ""
      if let cached = self.player.info.getCachedVideoDurationAndProgress(searchItem.item.filename), let duration = cached.duration {
        if duration > 0 {
          durationLabel = VideoTime(duration).stringRepresentation
        }
      } else { return nil }
      
//         Add bold for matching letters
        for index in searchItem.result.pos {
          let range = NSMakeRange(index , 1)
          render.addAttribute(NSAttributedString.Key.font, value: NSFont.boldSystemFont(ofSize: CGFloat(TableCellFontSize)), range: range)
        }
      
    return [
      "name": searchItem.item.filenameForDisplay,
      "artist": render,
      "duration": durationLabel,
      "image": NSWorkspace.shared.icon(forFile: searchItem.item.filename)
    ]

    }
    
    var artistLabel = "" , durationLabel = ""
    
    let item = searchItem.item
    
    func getCachedMetadata() -> (artist: String, title: String)? {
      guard Preference.bool(for: .playlistShowMetadata) else { return nil }
      if Preference.bool(for: .playlistShowMetadataInMusicMode) && !player.isInMiniPlayer {
        return nil
      }
      guard let metadata = player.info.getCachedMetadata(item.filename) else { return nil }
      guard let artist = metadata.artist, let title = metadata.title else { return nil }
      return (artist, title)
    }
    
    if let (artist, title) = getCachedMetadata() {
      artistLabel = artist
    }
    if let cached = self.player.info.getCachedVideoDurationAndProgress(item.filename), let duration = cached.duration {
      if duration > 0 {
        durationLabel = VideoTime(duration).stringRepresentation
      }
    } else {
      
      searchWorkQueue.async {
        
        self.player.refreshCachedVideoInfo(forVideoPath: item.filename)
        
        if let cached = self.player.info.getCachedVideoDurationAndProgress(item.filename), let duration = cached.duration, duration > 0 {
          DispatchQueue.main.async {
            self.searchResultsTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
          }
        }
      }
      
    }
    
    //     Add bold for matching letters
    for index in searchItem.result.pos {
      let range = NSMakeRange(index , 1)
      render.addAttribute(NSAttributedString.Key.font, value: NSFont.boldSystemFont(ofSize: CGFloat(TableCellFontSize)), range: range)
      render.addAttribute(NSAttributedString.Key.foregroundColor, value: NSColor.textColor, range: range)
    }
    
    return [
      "name": render,
      "artist": artistLabel,
      "duration": durationLabel,
      "image": NSWorkspace.shared.icon(forFile: item.filename)
    ]
    
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
