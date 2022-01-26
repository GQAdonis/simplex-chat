{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Chat.Messages where

import Data.Aeson (FromJSON, ToJSON, (.=))
import qualified Data.Aeson as J
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (ZonedTime)
import Data.Type.Equality
import Data.Typeable (Typeable)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import GHC.Generics
import Simplex.Chat.Protocol
import Simplex.Chat.Types
import Simplex.Messaging.Agent.Protocol (AgentMsgId, MsgIntegrity, MsgMeta (..), serializeMsgIntegrity)
import Simplex.Messaging.Agent.Store.SQLite (fromTextField_)
import Simplex.Messaging.Protocol (MsgBody)

data ChatType = CTDirect | CTGroup
  deriving (Show)

data ChatInfo (c :: ChatType) where
  DirectChat :: Contact -> ChatInfo 'CTDirect
  GroupChat :: GroupInfo -> ChatInfo 'CTGroup

deriving instance Show (ChatInfo c)

type ChatItemData d = (CIMeta d, CIContent d)

data ChatItem (c :: ChatType) (d :: MsgDirection) where
  DirectChatItem :: CIMeta d -> CIContent d -> ChatItem 'CTDirect d
  SndGroupChatItem :: CIMeta 'MDSnd -> CIContent 'MDSnd -> ChatItem 'CTGroup 'MDSnd
  RcvGroupChatItem :: GroupMember -> CIMeta 'MDRcv -> CIContent 'MDRcv -> ChatItem 'CTGroup 'MDRcv

deriving instance Show (ChatItem c d)

data CChatItem c = forall d. CChatItem (SMsgDirection d) (ChatItem c d)

deriving instance Show (CChatItem c)

chatItemId :: ChatItem c d -> ChatItemId
chatItemId = \case
  DirectChatItem (CISndMeta CIMetaProps {itemId}) _ -> itemId
  DirectChatItem (CIRcvMeta CIMetaProps {itemId} _) _ -> itemId
  SndGroupChatItem (CISndMeta CIMetaProps {itemId}) _ -> itemId
  RcvGroupChatItem _ (CIRcvMeta CIMetaProps {itemId} _) _ -> itemId

data ChatDirection (c :: ChatType) (d :: MsgDirection) where
  CDDirect :: Contact -> ChatDirection 'CTDirect d
  CDSndGroup :: GroupInfo -> ChatDirection 'CTGroup 'MDSnd
  CDRcvGroup :: GroupInfo -> GroupMember -> ChatDirection 'CTGroup 'MDRcv

data NewChatItem d = NewChatItem
  { createdByMsgId_ :: Maybe MessageId,
    itemSent :: MsgDirection,
    itemTs :: ChatItemTs,
    itemContent :: CIContent d,
    itemText :: Text,
    createdAt :: UTCTime
  }
  deriving (Show)

-- | type to show one chat with messages
data Chat c = Chat (ChatInfo c) [CChatItem c]
  deriving (Show)

-- | type to show the list of chats, with one last message in each
data AChatPreview = forall c. AChatPreview (SChatType c) (ChatInfo c) (Maybe (CChatItem c))

deriving instance Show AChatPreview

-- | type to show a mix of messages from multiple chats
data AChatItem = forall c d. AChatItem (SChatType c) (SMsgDirection d) (ChatInfo c) (ChatItem c d)

deriving instance Show AChatItem

data CIMeta (d :: MsgDirection) where
  CISndMeta :: CIMetaProps -> CIMeta 'MDSnd
  CIRcvMeta :: CIMetaProps -> MsgIntegrity -> CIMeta 'MDRcv

deriving instance Show (CIMeta d)

data CIMetaProps = CIMetaProps
  { itemId :: ChatItemId,
    itemTs :: ChatItemTs,
    localItemTs :: ZonedTime,
    createdAt :: UTCTime
  }
  deriving (Show)

type ChatItemId = Int64

type ChatItemTs = UTCTime

data CIContent (d :: MsgDirection) where
  CIMsgContent :: MsgContent -> CIContent d
  CISndFileInvitation :: FileTransferId -> FilePath -> CIContent 'MDSnd
  CIRcvFileInvitation :: RcvFileTransfer -> CIContent 'MDRcv

deriving instance Show (CIContent d)

instance ToField (CIContent d) where toField = toField . decodeLatin1 . LB.toStrict . J.encode

instance ToJSON (CIContent d) where
  toJSON = J.toJSON . ciContentToJSON
  toEncoding = J.toEncoding . ciContentToJSON

data CIContentJSON = CIContentJSON
  { tag :: Text,
    subTag :: Maybe Text,
    args :: J.Value
  }
  deriving (Generic, FromJSON)

instance ToJSON CIContentJSON where toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

ciContentToJSON :: CIContent d -> CIContentJSON
ciContentToJSON = \case
  CIMsgContent mc -> o "content" "" $ J.object ["content" .= mc]
  CISndFileInvitation fId fPath -> o "sndFile" "invitation" $ J.object ["fileId" .= fId, "filePath" .= fPath]
  CIRcvFileInvitation ft -> o "rcvFile" "invitation" $ J.object ["fileTransfer" .= ft]
  where
    o tag "" args = CIContentJSON {tag, subTag = Nothing, args}
    o tag st args = CIContentJSON {tag, subTag = Just st, args}

ciContentToText :: CIContent d -> Text
ciContentToText = \case
  CIMsgContent mc -> msgContentText mc
  CISndFileInvitation fId fPath -> "you sent file #" <> T.pack (show fId) <> ": " <> T.pack fPath
  CIRcvFileInvitation RcvFileTransfer {fileInvitation = FileInvitation {fileName}} -> "file " <> T.pack fileName

data SChatType (c :: ChatType) where
  SCTDirect :: SChatType 'CTDirect
  SCTGroup :: SChatType 'CTGroup

deriving instance Show (SChatType c)

instance TestEquality SChatType where
  testEquality SCTDirect SCTDirect = Just Refl
  testEquality SCTGroup SCTGroup = Just Refl
  testEquality _ _ = Nothing

class ChatTypeI (c :: ChatType) where
  chatType :: SChatType c

instance ChatTypeI 'CTDirect where chatType = SCTDirect

instance ChatTypeI 'CTGroup where chatType = SCTGroup

data NewMessage = NewMessage
  { direction :: MsgDirection,
    cmEventTag :: CMEventTag,
    msgBody :: MsgBody
  }
  deriving (Show)

data PendingGroupMessage = PendingGroupMessage
  { msgId :: MessageId,
    cmEventTag :: CMEventTag,
    msgBody :: MsgBody,
    introId_ :: Maybe Int64
  }

type MessageId = Int64

data MsgDirection = MDRcv | MDSnd
  deriving (Show)

data SMsgDirection (d :: MsgDirection) where
  SMDRcv :: SMsgDirection 'MDRcv
  SMDSnd :: SMsgDirection 'MDSnd

deriving instance Show (SMsgDirection d)

instance TestEquality SMsgDirection where
  testEquality SMDRcv SMDRcv = Just Refl
  testEquality SMDSnd SMDSnd = Just Refl
  testEquality _ _ = Nothing

class MsgDirectionI (d :: MsgDirection) where
  msgDirection :: SMsgDirection d

instance MsgDirectionI 'MDRcv where msgDirection = SMDRcv

instance MsgDirectionI 'MDSnd where msgDirection = SMDSnd

instance ToField MsgDirection where toField = toField . msgDirectionInt

msgDirectionInt :: MsgDirection -> Int
msgDirectionInt = \case
  MDRcv -> 0
  MDSnd -> 1

msgDirectionIntP :: Int -> Maybe MsgDirection
msgDirectionIntP = \case
  0 -> Just MDRcv
  1 -> Just MDSnd
  _ -> Nothing

data SndMsgDelivery = SndMsgDelivery
  { connId :: Int64,
    agentMsgId :: AgentMsgId
  }

data RcvMsgDelivery = RcvMsgDelivery
  { connId :: Int64,
    agentMsgId :: AgentMsgId,
    agentMsgMeta :: MsgMeta
  }

data MsgMetaJSON = MsgMetaJSON
  { integrity :: Text,
    rcvId :: Int64,
    rcvTs :: UTCTime,
    serverId :: Text,
    serverTs :: UTCTime,
    sndId :: Int64
  }
  deriving (Eq, Show, FromJSON, Generic)

instance ToJSON MsgMetaJSON where toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

msgMetaToJson :: MsgMeta -> MsgMetaJSON
msgMetaToJson MsgMeta {integrity, recipient = (rcvId, rcvTs), broker = (serverId, serverTs), sndMsgId = sndId} =
  MsgMetaJSON
    { integrity = (decodeLatin1 . serializeMsgIntegrity) integrity,
      rcvId,
      rcvTs,
      serverId = (decodeLatin1 . B64.encode) serverId,
      serverTs,
      sndId
    }

msgMetaJson :: MsgMeta -> Text
msgMetaJson = decodeLatin1 . LB.toStrict . J.encode . msgMetaToJson

data MsgDeliveryStatus (d :: MsgDirection) where
  MDSRcvAgent :: MsgDeliveryStatus 'MDRcv
  MDSRcvAcknowledged :: MsgDeliveryStatus 'MDRcv
  MDSSndPending :: MsgDeliveryStatus 'MDSnd
  MDSSndAgent :: MsgDeliveryStatus 'MDSnd
  MDSSndSent :: MsgDeliveryStatus 'MDSnd
  MDSSndReceived :: MsgDeliveryStatus 'MDSnd
  MDSSndRead :: MsgDeliveryStatus 'MDSnd

data AMsgDeliveryStatus = forall d. AMDS (SMsgDirection d) (MsgDeliveryStatus d)

instance (Typeable d, MsgDirectionI d) => FromField (MsgDeliveryStatus d) where
  fromField = fromTextField_ msgDeliveryStatusT'

instance ToField (MsgDeliveryStatus d) where toField = toField . serializeMsgDeliveryStatus

serializeMsgDeliveryStatus :: MsgDeliveryStatus d -> Text
serializeMsgDeliveryStatus = \case
  MDSRcvAgent -> "rcv_agent"
  MDSRcvAcknowledged -> "rcv_acknowledged"
  MDSSndPending -> "snd_pending"
  MDSSndAgent -> "snd_agent"
  MDSSndSent -> "snd_sent"
  MDSSndReceived -> "snd_received"
  MDSSndRead -> "snd_read"

msgDeliveryStatusT :: Text -> Maybe AMsgDeliveryStatus
msgDeliveryStatusT = \case
  "rcv_agent" -> Just $ AMDS SMDRcv MDSRcvAgent
  "rcv_acknowledged" -> Just $ AMDS SMDRcv MDSRcvAcknowledged
  "snd_pending" -> Just $ AMDS SMDSnd MDSSndPending
  "snd_agent" -> Just $ AMDS SMDSnd MDSSndAgent
  "snd_sent" -> Just $ AMDS SMDSnd MDSSndSent
  "snd_received" -> Just $ AMDS SMDSnd MDSSndReceived
  "snd_read" -> Just $ AMDS SMDSnd MDSSndRead
  _ -> Nothing

msgDeliveryStatusT' :: forall d. MsgDirectionI d => Text -> Maybe (MsgDeliveryStatus d)
msgDeliveryStatusT' s =
  msgDeliveryStatusT s >>= \(AMDS d st) ->
    case testEquality d (msgDirection @d) of
      Just Refl -> Just st
      _ -> Nothing