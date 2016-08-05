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
  private lazy var storageRef: FIRStorageReference = FIRStorage.storage().reference(forURL: "gs://chatchat-rw-cf107.appspot.com")
  private lazy var userIsTypingRef: FIRDatabaseReference = self.channelRef!.child("typingIndicator").child(self.senderId)
  private lazy var usersTypingQuery: FIRDatabaseQuery = self.channelRef!.child("typingIndicator").queryOrderedByValue().queryEqual(toValue: true)
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
  
  lazy var outgoingBubbleImageView: JSQMessagesBubbleImage = self.setupOutgoingBubble(theme: .blueGray)
  lazy var incomingBubbleImageView: JSQMessagesBubbleImage = self.setupIncomingBubble(theme: .blueGray)
  
  // MARK: View Lifecycle
  
  override func viewDidLoad() {
    super.viewDidLoad()
    self.senderId = FIRAuth.auth()?.currentUser?.uid
    fetchRemoteConfig()
    observeMessages()
    
    // No avatars
    collectionView!.collectionViewLayout.incomingAvatarViewSize = CGSize.zero
    collectionView!.collectionViewLayout.outgoingAvatarViewSize = CGSize.zero
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    observeTyping()
  }
  
  deinit {
    if let refHandle = newMessageRefHandle {
      messageRef.removeObserver(withHandle: refHandle)
    }
    if let refHandle = updatedMessageRefHandle {
      messageRef.removeObserver(withHandle: refHandle)
    }
  }
  
  // MARK: Collection view data source (and related) methods
  
  override func collectionView(_ collectionView: JSQMessagesCollectionView!, messageDataForItemAt indexPath: IndexPath!) -> JSQMessageData! {
    return messages[indexPath.item]
  }
  
  override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    return messages.count
  }
  
  override func collectionView(_ collectionView: JSQMessagesCollectionView!, messageBubbleImageDataForItemAt indexPath: IndexPath!) -> JSQMessageBubbleImageDataSource! {
    let message = messages[indexPath.item] // 1
    if message.senderId == senderId { // 2
      return outgoingBubbleImageView
    } else { // 3
      return incomingBubbleImageView
    }
  }
  
  override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = super.collectionView(collectionView, cellForItemAt: indexPath) as! JSQMessagesCollectionViewCell
    
    let message = messages[indexPath.item]
    
    if message.senderId == senderId { // 1
      cell.textView?.textColor = UIColor.white // 2
    } else {
      cell.textView?.textColor = UIColor.black // 3
    }
    
    return cell
  }
  
  override func collectionView(_ collectionView: JSQMessagesCollectionView!, avatarImageDataForItemAt indexPath: IndexPath!) -> JSQMessageAvatarImageDataSource! {
    return nil
  }
  
  override func collectionView(_ collectionView: JSQMessagesCollectionView!, layout collectionViewLayout: JSQMessagesCollectionViewFlowLayout!, heightForMessageBubbleTopLabelAt indexPath: IndexPath!) -> CGFloat {
    return 15
  }
  
  override func collectionView(_ collectionView: JSQMessagesCollectionView?, attributedTextForMessageBubbleTopLabelAt indexPath: IndexPath!) -> NSAttributedString? {
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
  
  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : AnyObject]) {
    picker.dismiss(animated: true, completion:nil)
    
    if let photoReferenceUrl = info[UIImagePickerControllerReferenceURL] {
      // Handle picking a Photo from the Photo Library
      let assets = PHAsset.fetchAssets(withALAssetURLs: [photoReferenceUrl as! URL], options: nil)
      let asset = assets.firstObject
      if let key = sendPhotoMessage() {
        asset?.requestContentEditingInput(with: nil, completionHandler: { (contentEditingInput, info) in
          let imageFileURL = contentEditingInput?.fullSizeImageURL
          let path = "\(FIRAuth.auth()?.currentUser?.uid)/\(Int(Date.timeIntervalSinceReferenceDate * 1000))/\(photoReferenceUrl.lastPathComponent!)"
          
          self.storageRef.child(path).putFile(imageFileURL!, metadata: nil) { (metadata, error) in
            if let error = error {
              print("Error uploading photo: \(error.localizedDescription)")
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
        let imagePath = FIRAuth.auth()!.currentUser!.uid + "/\(Int(Date.timeIntervalSinceReferenceDate * 1000)).jpg"
        let metadata = FIRStorageMetadata()
        metadata.contentType = "image/jpeg"
        storageRef.child(imagePath).put(imageData!, metadata: metadata) { (metadata, error) in
          if let error = error {
            print("Error uploading photo: \(error)")
            return
          }
          self.setImageURL(self.storageRef.child((metadata?.path)!).description, forPhotoMessageWithKey: key)
        }
      }
    }
  }
  
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true, completion:nil)
  }
  
  // MARK: Firebase related methods
  
  private func observeMessages() {
    messageRef = channelRef!.child("messages")
    let messageQuery = messageRef.queryLimited(toLast:25)
    
    // We can use the observe method to listen for new
    // messages being written to the Firebase DB
    newMessageRefHandle = messageQuery.observe(.childAdded, with: { (snapshot) -> Void in
      let key = snapshot.key
      let messageData = snapshot.value as! Dictionary<String, String>

      if let id = messageData["senderId"] as String!, let name = messageData["senderName"] as String!, let text = messageData["text"] as String!, text.characters.count > 0 {
        self.addMessage(withId: id, name: name, text: text)
        self.finishReceivingMessage()
      } else if let id = messageData["senderId"] as String!, let photoURL = messageData["photoURL"] as String! {
        if let mediaItem = JSQPhotoMediaItem(maskAsOutgoing: id == self.senderId) {
          self.addPhotoMessage(withId: id, key: key, mediaItem: mediaItem)
          
          if photoURL.hasPrefix("gs://") {
            self.fetchImageDataAtURL(photoURL, forMediaItem: mediaItem, clearsPhotoMessageMapOnSuccessForKey: nil)
          }
        }
      } else {
        print("Error! Could not decode message data")
      }
    })
    
    // We can also use the observer method to listen for
    // changes to existing messages.
    // We use this to be notified when a photo has been stored
    // to the Firebase Storage, so we can update the message data
    updatedMessageRefHandle = messageRef.observe(.childChanged, with: { (snapshot) in
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
    
    remoteConfig.fetch(withExpirationDuration: expiresAfter) { (status, error) in
      if (status == .success) {
        self.remoteConfig.activateFetched()
        let bubbleTheme = self.remoteConfig["bubbleTheme"]
        if (bubbleTheme.source != .static) {
          if let theme = BubbleTheme(rawValue: Int(bubbleTheme.numberValue!)) {
            self.outgoingBubbleImageView = self.setupOutgoingBubble(theme: theme)
            self.incomingBubbleImageView = self.setupIncomingBubble(theme: theme)
          } else {
            self.outgoingBubbleImageView = self.setupOutgoingBubble(theme: .blueGray)
            self.incomingBubbleImageView = self.setupIncomingBubble(theme: .blueGray)
          }
        }
      } else {
        print("Config not fetched")
        print("Error \(error)")
      }
    }
  }
  
  private func fetchImageDataAtURL(_ photoURL: String, forMediaItem mediaItem: JSQPhotoMediaItem, clearsPhotoMessageMapOnSuccessForKey key: String?) {
    let storageRef = FIRStorage.storage().reference(forURL: photoURL)
    storageRef.data(withMaxSize: INT64_MAX){ (data, error) in
      if let error = error {
        print("Error downloading image data: \(error)")
        return
      }
      
      storageRef.metadata(completion: { (metadata, metadataErr) in
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
        self.photoMessageMap.removeValue(forKey: key!)
      })
    }
  }
  
  private func observeTyping() {
    let typingIndicatorRef = channelRef!.child("typingIndicator")
    userIsTypingRef = typingIndicatorRef.child(senderId)
    userIsTypingRef.onDisconnectRemoveValue()
    usersTypingQuery = typingIndicatorRef.queryOrderedByValue().queryEqual(toValue: true)
    
    usersTypingQuery.observe(.value) { (data: FIRDataSnapshot) in
      
      // You're the only typing, don't show the indicator
      if data.childrenCount == 1 && self.isTyping {
        return
      }
      
      // Are there others typing?
      self.showTypingIndicator = data.childrenCount > 0
      self.scrollToBottom(animated: true)
    }
  }
  
  override func didPressSend(_ button: UIButton!, withMessageText text: String!, senderId: String!, senderDisplayName: String!, date: Date!) {
    // 1
    let itemRef = messageRef.childByAutoId()
    
    // 2
    let messageItem:AnyObject = [
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
    
    let messageItem:AnyObject = [
      "photoURL": imageURLNotSetKey,
      "senderId": senderId,
      ]
    
    itemRef.setValue(messageItem)
    
    JSQSystemSoundPlayer.jsq_playMessageSentSound()
    
    finishSendingMessage()
    return itemRef.key
  }
  
  func setImageURL(_ url: String, forPhotoMessageWithKey key: String) {
    let itemRef = messageRef.child(key)
    itemRef.updateChildValues(["photoURL": url])
  }
  
  // MARK: UI and User Interaction
  
  private func setupOutgoingBubble(theme: BubbleTheme) -> JSQMessagesBubbleImage {
    let bubbleImageFactory = JSQMessagesBubbleImageFactory()
    switch theme {
    case .blueGray:
      return bubbleImageFactory!.outgoingMessagesBubbleImage(with: UIColor.jsq_messageBubbleBlue())
    case .greenGray:
      return bubbleImageFactory!.outgoingMessagesBubbleImage(with: UIColor.jsq_messageBubbleGreen())
    case .redBlue:
      return bubbleImageFactory!.outgoingMessagesBubbleImage(with: UIColor.jsq_messageBubbleRed())
    }
  }

  private func setupIncomingBubble(theme: BubbleTheme) -> JSQMessagesBubbleImage {
    let bubbleImageFactory = JSQMessagesBubbleImageFactory()
    switch theme {
    case .blueGray:
      return bubbleImageFactory!.incomingMessagesBubbleImage(with: UIColor.jsq_messageBubbleLightGray())
    case .greenGray:
      return bubbleImageFactory!.incomingMessagesBubbleImage(with: UIColor.jsq_messageBubbleLightGray())
    case .redBlue:
      return bubbleImageFactory!.incomingMessagesBubbleImage(with: UIColor.jsq_messageBubbleBlue())
    }
  }

  override func didPressAccessoryButton(_ sender: UIButton) {
    let picker = UIImagePickerController()
    picker.delegate = self
    if (UIImagePickerController.isSourceTypeAvailable(UIImagePickerControllerSourceType.camera)) {
      picker.sourceType = UIImagePickerControllerSourceType.camera
    } else {
      picker.sourceType = UIImagePickerControllerSourceType.photoLibrary
    }
    
    present(picker, animated: true, completion:nil)
  }
  
  private func addMessage(withId id: String, name: String, text: String) {
    if let message = JSQMessage(senderId: id, displayName: name, text: text) {
      messages.append(message)      
    }
  }
  
  private func addPhotoMessage(withId id: String, key: String, mediaItem: JSQPhotoMediaItem) {
    if let message = JSQMessage(senderId: id, displayName: "", media: mediaItem) {
      messages.append(message)
      
      if (mediaItem.image == nil) {
        photoMessageMap[key] = mediaItem
      }
      
      collectionView.reloadData()
    }
  }
  
  // MARK: UITextViewDelegate methods
  
  override func textViewDidChange(_ textView: UITextView) {
    super.textViewDidChange(textView)
    // If the text is not empty, the user is typing
    isTyping = textView.text != ""
  }
  
}
