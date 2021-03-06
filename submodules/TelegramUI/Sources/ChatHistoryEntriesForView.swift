import Foundation
import Postbox
import TelegramCore
import SyncCore
import TemporaryCachedPeerDataManager
import Emoji
import AccountContext
import TelegramPresentationData


func chatHistoryEntriesForView(location: ChatLocation, view: MessageHistoryView, includeUnreadEntry: Bool, includeEmptyEntry: Bool, includeChatInfoEntry: Bool, includeSearchEntry: Bool, reverse: Bool, groupMessages: Bool, selectedMessages: Set<MessageId>?, presentationData: ChatPresentationData, historyAppearsCleared: Bool, pendingUnpinnedAllMessages: Bool, pendingRemovedMessages: Set<MessageId>, associatedData: ChatMessageItemAssociatedData, updatingMedia: [MessageId: ChatUpdatingMessageMedia], customChannelDiscussionReadState: MessageId?, customThreadOutgoingReadState: MessageId?) -> [ChatHistoryEntry] {
    if historyAppearsCleared {
        return []
    }
    var entries: [ChatHistoryEntry] = []
    var adminRanks: [PeerId: CachedChannelAdminRank] = [:]
    var stickersEnabled = true
    if case let .peer(peerId) = location, peerId.namespace == Namespaces.Peer.CloudChannel {
        for additionalEntry in view.additionalData {
            if case let .cacheEntry(id, data) = additionalEntry {
                if id == cachedChannelAdminRanksEntryId(peerId: peerId), let data = data as? CachedChannelAdminRanks {
                    adminRanks = data.ranks
                }
            } else if case let .peer(_, peer) = additionalEntry, let channel = peer as? TelegramChannel {
                if let defaultBannedRights = channel.defaultBannedRights, defaultBannedRights.flags.contains(.banSendStickers) {
                    stickersEnabled = false
                }
            }
        }
    }

    var groupBucket: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes)] = []
    loop: for entry in view.entries {
        var message = entry.message
        var isRead = entry.isRead
        
        if pendingRemovedMessages.contains(message.id) {
            continue
        }
        
        if let customThreadOutgoingReadState = customThreadOutgoingReadState {
            isRead = customThreadOutgoingReadState >= message.id
        }
        
        if let customChannelDiscussionReadState = customChannelDiscussionReadState {
            attibuteLoop: for i in 0 ..< message.attributes.count {
                if let attribute = message.attributes[i] as? ReplyThreadMessageAttribute {
                    if let maxReadMessageId = attribute.maxReadMessageId {
                        if maxReadMessageId < customChannelDiscussionReadState.id {
                            var attributes = message.attributes
                            attributes[i] = ReplyThreadMessageAttribute(count: attribute.count, latestUsers: attribute.latestUsers, commentsPeerId: attribute.commentsPeerId, maxMessageId: attribute.maxMessageId, maxReadMessageId: customChannelDiscussionReadState.id)
                            message = message.withUpdatedAttributes(attributes)
                        }
                    }
                    break attibuteLoop
                }
            }
        }
        
        var contentTypeHint: ChatMessageEntryContentType = .generic
        
        for media in message.media {
            if media is TelegramMediaDice {
                contentTypeHint = .animatedEmoji
            }
            if let action = media as? TelegramMediaAction {
                switch action.action {
                    case .channelMigratedFromGroup, .groupMigratedToChannel, .historyCleared:
                        continue loop
                    default:
                        break
                }
            }
        }
    
        var adminRank: CachedChannelAdminRank?
        if let author = message.author {
            adminRank = adminRanks[author.id]
        }
        
        
        if presentationData.largeEmoji, message.media.isEmpty {
            if stickersEnabled && message.text.count == 1, let _ = associatedData.animatedEmojiStickers[message.text.basicEmoji.0] {
                contentTypeHint = .animatedEmoji
            } else if message.text.count < 10 && messageIsElligibleForLargeEmoji(message) {
                contentTypeHint = .largeEmoji
            }
        }
    
        if groupMessages {
            if !groupBucket.isEmpty && message.groupInfo != groupBucket[0].0.groupInfo {
                entries.append(.MessageGroupEntry(groupBucket[0].0.groupInfo!, groupBucket, presentationData))
                groupBucket.removeAll()
            }
            if let _ = message.groupInfo {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id))
                } else {
                    selection = .none
                }
                groupBucket.append((message, isRead, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id])))
            } else {
                let selection: ChatHistoryMessageSelection
                if let selectedMessages = selectedMessages {
                    selection = .selectable(selected: selectedMessages.contains(message.id))
                } else {
                    selection = .none
                }
                entries.append(.MessageEntry(message, presentationData, isRead, entry.monthLocation, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id])))
            }
        } else {
            let selection: ChatHistoryMessageSelection
            if let selectedMessages = selectedMessages {
                selection = .selectable(selected: selectedMessages.contains(message.id))
            } else {
                selection = .none
            }
            entries.append(.MessageEntry(message, presentationData, isRead, entry.monthLocation, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: entry.attributes.authorIsContact, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id])))
        }
    }
    
    if !groupBucket.isEmpty {
        assert(groupMessages)
        entries.append(.MessageGroupEntry(groupBucket[0].0.groupInfo!, groupBucket, presentationData))
    }
    
    if let maxReadIndex = view.maxReadIndex, includeUnreadEntry {
        var i = 0
        let unreadEntry: ChatHistoryEntry = .UnreadEntry(maxReadIndex, presentationData)
        for entry in entries {
            if entry > unreadEntry {
                if i != 0 {
                    entries.insert(unreadEntry, at: i)
                }
                break
            }
            i += 1
        }
    }
    
    var addedThreadHead = false
    if case let .replyThread(replyThreadMessage) = location, view.earlierId == nil, !view.holeEarlier, !view.isLoading {
        loop: for entry in view.additionalData {
            switch entry {
            case let .message(id, messages) where id == replyThreadMessage.effectiveTopId:
                if !messages.isEmpty {
                    let selection: ChatHistoryMessageSelection = .none
                    
                    let topMessage = messages[0]
                    
                    var adminRank: CachedChannelAdminRank?
                    if let author = topMessage.author {
                        adminRank = adminRanks[author.id]
                    }
                    
                    var contentTypeHint: ChatMessageEntryContentType = .generic
                    if presentationData.largeEmoji, topMessage.media.isEmpty {
                        if stickersEnabled && topMessage.text.count == 1, let _ = associatedData.animatedEmojiStickers[topMessage.text.basicEmoji.0] {
                            contentTypeHint = .animatedEmoji
                        } else if topMessage.text.count < 10 && messageIsElligibleForLargeEmoji(topMessage) {
                            contentTypeHint = .largeEmoji
                        }
                    }
                    
                    addedThreadHead = true
                    if messages.count > 1, let groupInfo = messages[0].groupInfo {
                        var groupMessages: [(Message, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes)] = []
                        for message in messages {
                            groupMessages.append((message, false, .none, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[message.id])))
                        }
                        entries.insert(.MessageGroupEntry(groupInfo, groupMessages, presentationData), at: 0)
                    } else {
                        entries.insert(.MessageEntry(messages[0], presentationData, false, nil, selection, ChatMessageEntryAttributes(rank: adminRank, isContact: false, contentTypeHint: contentTypeHint, updatingMedia: updatingMedia[messages[0].id])), at: 0)
                    }
                    
                    let replyCount = view.entries.isEmpty ? 0 : 1
                    
                    entries.insert(.ReplyCountEntry(messages[0].index, replyThreadMessage.isChannelPost, replyCount, presentationData), at: 1)
                }
                break loop
            default:
                break
            }
        }
    }
    
    if includeChatInfoEntry {
        if view.earlierId == nil, !view.isLoading {
            var cachedPeerData: CachedPeerData?
            for entry in view.additionalData {
                if case let .cachedPeerData(_, data) = entry {
                    cachedPeerData = data
                    break
                }
            }
            if case let .peer(peerId) = location, peerId.isReplies {
                entries.insert(.ChatInfoEntry("", presentationData.strings.RepliesChat_DescriptionText, presentationData), at: 0)
            } else if let cachedPeerData = cachedPeerData as? CachedUserData, let botInfo = cachedPeerData.botInfo, !botInfo.description.isEmpty {
                entries.insert(.ChatInfoEntry(presentationData.strings.Bot_DescriptionTitle, botInfo.description, presentationData), at: 0)
            } else {
                var isEmpty = true
                if entries.count <= 3 {
                    loop: for entry in view.entries {
                        var isEmptyMedia = false
                        for media in entry.message.media {
                            if let action = media as? TelegramMediaAction {
                                switch action.action {
                                    case .groupCreated, .photoUpdated, .channelMigratedFromGroup, .groupMigratedToChannel:
                                        isEmptyMedia = true
                                    default:
                                        break
                                }
                            }
                        }
                        var isCreator = false
                        if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramGroup, case .creator = peer.role {
                            isCreator = true
                        } else if let peer = entry.message.peers[entry.message.id.peerId] as? TelegramChannel, case .group = peer.info, peer.flags.contains(.isCreator) {
                            isCreator = true
                        }
                        if isEmptyMedia && isCreator {
                        } else {
                            isEmpty = false
                            break loop
                        }
                    }
                } else {
                    isEmpty = false
                }
                if addedThreadHead {
                    isEmpty = false
                }
                if isEmpty {
                    entries.removeAll()
                }
            }
        }
    } else if includeSearchEntry {
        if view.laterId == nil {
            if !view.entries.isEmpty {
                entries.append(.SearchEntry(presentationData.theme.theme, presentationData.strings))
            }
        }
    }
    
    if reverse {
        return entries.reversed()
    } else {
        return entries
    }
}
