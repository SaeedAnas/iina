//
//  PlaylistSearchViewController.swift
//  iina
//
//  Created by Anas Saeed on 10/8/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Cocoa
import Foundation

class PlaylistSearchViewController: NSViewController {
  override var nibName: NSNib.Name {
    return NSNib.Name("PlaylistSearchViewController")
  }
  
  weak var playlistViewController: PlaylistViewController! {
    didSet {
      self.player = playlistViewController.player
    }
  }
  
  weak var player: PlayerCore!
  
  // Search Input
  @IBOutlet weak var inputField: NSTextField!
  @IBOutlet weak var searchPopUp: NSPopUpButton!
  @IBOutlet weak var clearBtn: NSButton!
  
  override func viewDidLoad() {
    super.viewDidLoad()
  }
  
}
