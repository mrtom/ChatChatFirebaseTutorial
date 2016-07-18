/*
* Copyright (c) 2015 Razeware LLC
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
* THE SOFTWARE.
*/

import UIKit
import Photos
import Firebase
import JSQMessagesViewController
import SwiftGifOrigin

enum BubbleTheme: Int {
  case blueGray = 0
  case greenGray
  case redBlue
}

final class ChatViewController: JSQMessagesViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  
  // MARK: Properties
  private let imageURLNotSetKey = "NOTSET"

  var channelRef: FIRDatabaseReference?
  
  private lazy var messageRef: FIRDatabaseReference = self.channelRef!.child("messages")
  private lazy var storageRef: FIRStorageReference = self.setupStorage()
  private lazy var userIsTypingRef: FIRDatabaseReference = self.channelRef!.child("typingIndicator").child(self.senderId)
  private lazy var usersTypingQuery: FIRDatabaseQuery = self.channelRef!.child("typingIndicator").queryOrderedByValue().queryEqualToValue(true)
  private lazy var remoteConfig: FIRRemoteConfig = self.setupRemoteConfig()
  
  private var newMessageRefHandle: FIRDatabaseHandle?
  private var updatedMessageRefHandle: FIRDatabaseHandle?
  
  private var messages: [JSQMessage] = []
  private var photoMessageMap = [String: JSQPhotoMediaItem]()
  
  private var localTyping = false
  var channel: Channel? {
    didSet {
      title = channel?.name
    }
  }

  var isTyping: Bool {
    get {
      return localTyping
    }
    set {
      localTyping = newValue
      userIsTypingRef.setValue(newValue)
    }
  }
  
  lazy var outgoingBubbleImageView: JSQMessagesBubbleImage = self.setupOutgoingBubble(.blueGray)
  lazy var incomingBubbleImageView: JSQMessagesBubbleImage = self.setupIncomingBubble(.blueGray)
  
  // MARK: View Lifecycle
  
  override func viewDidLoad() {
    super.viewDidLoad()
    fetchRemoteConfig()
    observeMessages()
    
    // No avatars
    collectionView!.collectionViewLayout.incomingAvatarViewSize = CGSizeZero
    collectionView!.collectionViewLayout.outgoingAvatarViewSize = CGSizeZero
  }
  
  override func viewDidAppear(animated: Bool) {
    super.viewDidAppear(animated)
    observeTyping()
  }
  
  deinit {
    if let refHandle = newMessageRefHandle {
      messageRef.removeObserverWithHandle(refHandle)
    }
    if let refHandle = updatedMessageRefHandle {
      messageRef.removeObserverWithHandle(refHandle)
    }
  }
  
  // MARK: Collection view data source (and related) methods
  
  override func collectionView(collectionView: JSQMessagesCollectionView!, messageDataForItemAtIndexPath indexPath: NSIndexPath!) -> JSQMessageData! {
    return messages[indexPath.item]
  }
  
  override func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    return messages.count
  }
  
  override func collectionView(collectionView: JSQMessagesCollectionView!, messageBubbleImageDataForItemAtIndexPath indexPath: NSIndexPath!) -> JSQMessageBubbleImageDataSource! {
    let message = messages[indexPath.item] // 1
    if message.senderId == senderId { // 2
      return outgoingBubbleImageView
    } else { // 3
      return incomingBubbleImageView
    }
  }
  
  override func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
    let cell = super.collectionView(collectionView, cellForItemAtIndexPath: indexPath) as! JSQMessagesCollectionViewCell
    
    let message = messages[indexPath.item]
    
    if message.senderId == senderId { // 1
      cell.textView?.textColor = UIColor.whiteColor() // 2
    } else {
      cell.textView?.textColor = UIColor.blackColor() // 3
    }
    
    return cell
  }
  
  override func collectionView(collectionView: JSQMessagesCollectionView!, avatarImageDataForItemAtIndexPath indexPath: NSIndexPath!) -> JSQMessageAvatarImageDataSource! {
    return nil
  }
  
  override func collectionView(collectionView: JSQMessagesCollectionView!, layout collectionViewLayout: JSQMessagesCollectionViewFlowLayout!, heightForMessageBubbleTopLabelAtIndexPath indexPath: NSIndexPath!) -> CGFloat {
    return 15
  }
  
  override func collectionView(collectionView: JSQMessagesCollectionView?, attributedTextForMessageBubbleTopLabelAtIndexPath indexPath: NSIndexPath!) -> NSAttributedString! {
    let message = messages[indexPath.item]
    switch message.senderId {
    case senderId:
      return nil
    default:
      guard let senderDisplayName = message.senderDisplayName else {
        assertionFailure()
        return nil
      }
      return NSAttributedString(string: senderDisplayName)
    }
  }

  // MARK: Image Picking
  
  func imagePickerController(picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : AnyObject]) {
    picker.dismissViewControllerAnimated(true, completion:nil)
    
    if let photoReferenceUrl = info[UIImagePickerControllerReferenceURL] {
      // Handle picking a Photo from the Photo Library
      let assets = PHAsset.fetchAssetsWithALAssetURLs([photoReferenceUrl as! NSURL], options: nil)
      let asset = assets.firstObject
      if let key = sendPhotoMessage() {
        asset?.requestContentEditingInputWithOptions(nil, completionHandler: { (contentEditingInput, info) in
          let imageFileURL = contentEditingInput?.fullSizeImageURL
          let path = "\(FIRAuth.auth()?.currentUser?.uid)/\(Int(NSDate.timeIntervalSinceReferenceDate() * 1000))/\(photoReferenceUrl.lastPathComponent!)"
          
          self.storageRef.child(path).putFile(imageFileURL!, metadata: nil) { (metadata, error) in
            if let error = error {
              print("Error uploading photo: \(error.description)")
              return
            }
            self.setImageURL(self.storageRef.child((metadata?.path)!).description, forPhotoMessageWithKey: key)
          }
        })
      }
    } else {
      // Handle picking a Photo from the Camera
      if let key = sendPhotoMessage() {
        let image = info[UIImagePickerControllerOriginalImage] as! UIImage
        let imageData = UIImageJPEGRepresentation(image, 1.0)
        let imagePath = FIRAuth.auth()!.currentUser!.uid + "/\(Int(NSDate.timeIntervalSinceReferenceDate() * 1000)).jpg"
        let metadata = FIRStorageMetadata()
        metadata.contentType = "image/jpeg"
        storageRef.child(imagePath).putData(imageData!, metadata: metadata) { (metadata, error) in
          if let error = error {
            print("Error uploading photo: \(error)")
            return
          }
          self.setImageURL(self.storageRef.child((metadata?.path)!).description, forPhotoMessageWithKey: key)
        }
      }
    }
  }

  func imagePickerControllerDidCancel(picker: UIImagePickerController) {
    picker.dismissViewControllerAnimated(true, completion:nil)
  }
  
  // MARK: Firebase related methods
  
  private func observeMessages() {
    messageRef = channelRef!.child("messages")
    
    // We can use the observe method to listen for new
    // messages being written to the Firebase DB
    newMessageRefHandle = messageRef.observeEventType(.ChildAdded, withBlock: { (snapshot) -> Void in
      let key = snapshot.key
      let messageData = snapshot.value as! Dictionary<String, String>

      if let id = messageData["senderId"] as String!, name = messageData["senderName"] as String!, text = messageData["text"] as String! where text.characters.count > 0 {
        self.addMessage(withId: id, name: name, text: text)
        self.finishReceivingMessage()
      } else if let id = messageData["senderId"] as String!, photoURL = messageData["photoURL"] as String! {
        let mediaItem = JSQPhotoMediaItem(maskAsOutgoing: id == self.senderId)
        self.addPhotoMessage(withId: id, key: key, mediaItem: mediaItem)
        if photoURL.hasPrefix("gs://") {
          self.fetchImageDataAtURL(photoURL, forMediaItem: mediaItem, clearsPhotoMessageMapOnSuccessForKey: nil)
        }
      } else {
        print("Error! Could not decode message data")
      }
    })
    
    // We can also use the observer method to listen for
    // changes to existing messages.
    // We use this to be notified when a photo has been stored
    // to the Firebase Storage, so we can update the message data
    updatedMessageRefHandle = messageRef.observeEventType(.ChildChanged, withBlock: { (snapshot) in
      let key = snapshot.key
      let messageData = snapshot.value as! Dictionary<String, String>
      
      if let photoURL = messageData["photoURL"] as String! {
        // The photo has been updated.
        if let mediaItem = self.photoMessageMap[key] {
          self.fetchImageDataAtURL(photoURL, forMediaItem: mediaItem, clearsPhotoMessageMapOnSuccessForKey: key)
        }
      }
    })
  }
  
  func setupStorage() -> FIRStorageReference {
    // FIXME: Needs to be changed to a dummy <your value here> value in the final version
    return FIRStorage.storage().referenceForURL("gs://chatchat-rw-cf107.appspot.com")
  }
  
  func setupRemoteConfig() -> FIRRemoteConfig {
    let config = FIRRemoteConfig.remoteConfig()
    // Create Remote Config Setting to enable developer mode.
    // Fetching configs from the server is normally limited to 5 requests per hour.
    // Enabling developer mode allows many more requests to be made per hour, so developers
    // can test different config values during development.
    if let remoteConfigSettings = FIRRemoteConfigSettings(developerModeEnabled: true) {
      config.configSettings = remoteConfigSettings
    }
    return config
  }
  
  func fetchRemoteConfig() {
    var expiresAfter: Double = 3600
    // If in developer mode cacheExpiration is set to 0 so each fetch will retrieve new
    // values from the server.
    if (remoteConfig.configSettings.isDeveloperModeEnabled) {
      expiresAfter = 0
    }
    
    remoteConfig.fetchWithExpirationDuration(expiresAfter) { (status, error) in
      if (status == .Success) {
        self.remoteConfig.activateFetched()
        let bubbleTheme = self.remoteConfig["bubbleTheme"]
        if (bubbleTheme.source != .Static) {
          if let theme = BubbleTheme(rawValue: Int(bubbleTheme.numberValue!)) {
            self.outgoingBubbleImageView = self.setupOutgoingBubble(theme)
            self.incomingBubbleImageView = self.setupIncomingBubble(theme)
          } else {
            self.outgoingBubbleImageView = self.setupOutgoingBubble(.blueGray)
            self.incomingBubbleImageView = self.setupIncomingBubble(.blueGray)
          }
        }
      } else {
        print("Config not fetched")
        print("Error \(error)")
      }
    }
  }
  
  private func fetchImageDataAtURL(photoURL: String, forMediaItem mediaItem: JSQPhotoMediaItem, clearsPhotoMessageMapOnSuccessForKey key: String?) {
    let storageRef = FIRStorage.storage().referenceForURL(photoURL)
    storageRef.dataWithMaxSize(INT64_MAX){ (data, error) in
      if let error = error {
        print("Error downloading image data: \(error)")
        return
      }
      
      storageRef.metadataWithCompletion({ (metadata, metadataErr) in
        if let error = metadataErr {
          print("Error downloading metadata: \(error)")
          return
        }
        
        if (metadata?.contentType == "image/gif") {
          mediaItem.image = UIImage.gifWithData(data!)
        } else {
          mediaItem.image = UIImage.init(data: data!)
        }
        self.collectionView.reloadData()
        
        guard key != nil else {
          return
        }
        self.photoMessageMap.removeValueForKey(key!)
      })
    }
  }
  
  private func observeTyping() {
    let typingIndicatorRef = channelRef!.child("typingIndicator")
    userIsTypingRef = typingIndicatorRef.child(senderId)
    userIsTypingRef.onDisconnectRemoveValue()
    usersTypingQuery = typingIndicatorRef.queryOrderedByValue().queryEqualToValue(true)
    
    usersTypingQuery.observeEventType(.Value) { (data: FIRDataSnapshot) in
      
      // You're the only typing, don't show the indicator
      if data.childrenCount == 1 && self.isTyping {
        return
      }
      
      // Are there others typing?
      self.showTypingIndicator = data.childrenCount > 0
      self.scrollToBottomAnimated(true)
    }
  }
  
  override func didPressSendButton(button: UIButton!, withMessageText text: String!, senderId: String!, senderDisplayName: String!, date: NSDate!) {
    // 1
    let itemRef = messageRef.childByAutoId()
    
    // 2
    let messageItem = [
      "senderId": senderId,
      "senderName": senderDisplayName,
      "text": text,
    ]
    
    // 3
    itemRef.setValue(messageItem)
    
    // 4
    JSQSystemSoundPlayer.jsq_playMessageSentSound()
    
    // 5
    finishSendingMessage()
    isTyping = false
  }
  
  func sendPhotoMessage() -> String? {
    let itemRef = messageRef.childByAutoId()
    
    let messageItem = [
      "photoURL": imageURLNotSetKey,
      "senderId": senderId,
    ]
    
    itemRef.setValue(messageItem)
    
    JSQSystemSoundPlayer.jsq_playMessageSentSound()
    
    finishSendingMessage()
    
    return itemRef.key
  }
  
  func setImageURL(url: String, forPhotoMessageWithKey key: String) {
    let itemRef = messageRef.child(key)
    itemRef.updateChildValues(["photoURL": url])
  }
  
  // MARK: UI and User Interaction

  private func setupOutgoingBubble(theme: BubbleTheme) -> JSQMessagesBubbleImage {
    let bubbleImageFactory = JSQMessagesBubbleImageFactory()
    
    switch theme {
    case .blueGray:
      return bubbleImageFactory.outgoingMessagesBubbleImageWithColor(UIColor.jsq_messageBubbleBlueColor())
    case .greenGray:
      return bubbleImageFactory.outgoingMessagesBubbleImageWithColor(UIColor.jsq_messageBubbleGreenColor())
    case .redBlue:
      return bubbleImageFactory.outgoingMessagesBubbleImageWithColor(UIColor.jsq_messageBubbleRedColor())
    }
  }

  private func setupIncomingBubble(theme: BubbleTheme) -> JSQMessagesBubbleImage {
    let bubbleImageFactory = JSQMessagesBubbleImageFactory()
    
    switch theme {
    case .blueGray:
      return bubbleImageFactory.incomingMessagesBubbleImageWithColor(UIColor.jsq_messageBubbleLightGrayColor())
    case .greenGray:
      return bubbleImageFactory.incomingMessagesBubbleImageWithColor(UIColor.jsq_messageBubbleLightGrayColor())
    case .redBlue:
      return bubbleImageFactory.incomingMessagesBubbleImageWithColor(UIColor.jsq_messageBubbleBlueColor())
    }
  }
  
  override func didPressAccessoryButton(sender: UIButton) {
    let picker = UIImagePickerController()
    picker.delegate = self
    if (UIImagePickerController.isSourceTypeAvailable(UIImagePickerControllerSourceType.Camera)) {
      picker.sourceType = UIImagePickerControllerSourceType.Camera
    } else {
      picker.sourceType = UIImagePickerControllerSourceType.PhotoLibrary
    }
    
    presentViewController(picker, animated: true, completion:nil)
  }
  
  private func addMessage(withId id: String, name: String, text: String) {
    let message = JSQMessage(senderId: id, displayName: name, text: text)
    messages.append(message)
  }
  
  private func addPhotoMessage(withId id: String, key: String, mediaItem: JSQPhotoMediaItem) {
    let message = JSQMessage(senderId: id, displayName: "", media: mediaItem)
    messages.append(message)
    
    if (mediaItem.image == nil) {
      photoMessageMap[key] = mediaItem
    }
    
    collectionView.reloadData()
  }
  
  // MARK: UITextViewDelegate methods
  
  override func textViewDidChange(textView: UITextView) {
    super.textViewDidChange(textView)
    // If the text is not empty, the user is typing
    isTyping = textView.text != ""
  }
  
}
