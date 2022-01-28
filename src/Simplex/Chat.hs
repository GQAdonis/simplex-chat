{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Chat where

import Control.Applicative (optional, (<|>))
import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random (drgNew)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isSpace)
import Data.Foldable (for_)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone)
import Data.Word (Word32)
import Simplex.Chat.Controller
import Simplex.Chat.Messages
import Simplex.Chat.Options (ChatOpts (..))
import Simplex.Chat.Protocol
import Simplex.Chat.Store
import Simplex.Chat.Types
import Simplex.Chat.Util (ifM, safeDecodeUtf8, unlessM)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), defaultAgentConfig)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (MsgBody)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util (tryError)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (combine, splitExtensions, takeFileName)
import System.IO (Handle, IOMode (..), SeekMode (..), hFlush, openFile, stdout)
import Text.Read (readMaybe)
import UnliftIO.Async (race_)
import UnliftIO.Concurrent (forkIO, threadDelay)
import UnliftIO.Directory (doesDirectoryExist, doesFileExist, getFileSize, getHomeDirectory, getTemporaryDirectory)
import qualified UnliftIO.Exception as E
import UnliftIO.IO (hClose, hSeek, hTell)
import UnliftIO.STM

defaultChatConfig :: ChatConfig
defaultChatConfig =
  ChatConfig
    { agentConfig =
        defaultAgentConfig
          { tcpPort = undefined, -- agent does not listen to TCP
            smpServers = undefined, -- filled in from options
            dbFile = undefined, -- filled in from options
            dbPoolSize = 1
          },
      dbPoolSize = 1,
      tbqSize = 16,
      fileChunkSize = 15780
    }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

newChatController :: SQLiteStore -> User -> ChatConfig -> ChatOpts -> (Notification -> IO ()) -> IO ChatController
newChatController chatStore user config@ChatConfig {agentConfig = cfg, tbqSize} ChatOpts {dbFilePrefix, smpServers} sendNotification = do
  let f = chatStoreFile dbFilePrefix
  activeTo <- newTVarIO ActiveNone
  firstTime <- not <$> doesFileExist f
  currentUser <- newTVarIO user
  smpAgent <- getSMPAgentClient cfg {dbFile = dbFilePrefix <> "_agent.db", smpServers}
  idsDrg <- newTVarIO =<< drgNew
  inputQ <- newTBQueueIO tbqSize
  outputQ <- newTBQueueIO tbqSize
  notifyQ <- newTBQueueIO tbqSize
  chatLock <- newTMVarIO ()
  sndFiles <- newTVarIO M.empty
  rcvFiles <- newTVarIO M.empty
  pure ChatController {activeTo, firstTime, currentUser, smpAgent, chatStore, idsDrg, inputQ, outputQ, notifyQ, chatLock, sndFiles, rcvFiles, config, sendNotification}

runChatController :: (MonadUnliftIO m, MonadReader ChatController m) => m ()
runChatController = race_ agentSubscriber notificationSubscriber

withLock :: MonadUnliftIO m => TMVar () -> m a -> m a
withLock lock =
  E.bracket_
    (void . atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())

execChatCommand :: (MonadUnliftIO m, MonadReader ChatController m) => String -> m ChatResponse
execChatCommand s = case parseAll chatCommandP . B.dropWhileEnd isSpace . encodeUtf8 $ T.pack s of
  Left e -> pure . CRChatError . ChatError $ CECommandError e
  Right cmd -> do
    ChatController {chatLock = l, smpAgent = a, currentUser} <- ask
    user <- readTVarIO currentUser
    withAgentLock a . withLock l $ either CRChatCmdError id <$> runExceptT (processChatCommand user cmd)

toView :: ChatMonad m => ChatResponse -> m ()
toView event = do
  q <- asks outputQ
  atomically $ writeTBQueue q (Nothing, event)

processChatCommand :: forall m. ChatMonad m => User -> ChatCommand -> m ChatResponse
processChatCommand user@User {userId, profile} = \case
  APIGetChats -> CRApiChats <$> withStore (`getChatPreviews` user)
  APIGetChat cType cId -> case cType of
    CTDirect -> CRApiDirectChat <$> withStore (\st -> getDirectChat st user cId)
    CTGroup -> pure $ CRChatError ChatErrorNotImplemented
  APIGetChatItems _count -> pure $ CRChatError ChatErrorNotImplemented
  ChatHelp section -> pure $ CRChatHelp section
  Welcome -> pure $ CRWelcome user
  AddContact -> procCmd $ do
    (connId, cReq) <- withAgent (`createConnection` SCMInvitation)
    withStore $ \st -> createDirectConnection st userId connId
    pure $ CRInvitation cReq
  Connect (Just (ACR SCMInvitation cReq)) -> procCmd $ do
    connect cReq $ XInfo profile
    pure CRSentConfirmation
  Connect (Just (ACR SCMContact cReq)) -> procCmd $ do
    connect cReq $ XContact profile Nothing
    pure CRSentInvitation
  Connect Nothing -> throwChatError CEInvalidConnReq
  ConnectAdmin -> procCmd $ do
    connect adminContactReq $ XContact profile Nothing
    pure CRSentInvitation
  DeleteContact cName ->
    withStore (\st -> getContactGroupNames st userId cName) >>= \case
      [] -> do
        conns <- withStore $ \st -> getContactConnections st userId cName
        procCmd $ do
          withAgent $ \a -> forM_ conns $ \conn ->
            deleteConnection a (aConnId conn) `catchError` \(_ :: AgentErrorType) -> pure ()
          withStore $ \st -> deleteContact st userId cName
          unsetActive $ ActiveC cName
          pure $ CRContactDeleted cName
      gs -> throwChatError $ CEContactGroups cName gs
  ListContacts -> CRContactsList <$> withStore (`getUserContacts` user)
  CreateMyAddress -> procCmd $ do
    (connId, cReq) <- withAgent (`createConnection` SCMContact)
    withStore $ \st -> createUserContactLink st userId connId cReq
    pure $ CRUserContactLinkCreated cReq
  DeleteMyAddress -> do
    conns <- withStore $ \st -> getUserContactLinkConnections st userId
    procCmd $ do
      withAgent $ \a -> forM_ conns $ \conn ->
        deleteConnection a (aConnId conn) `catchError` \(_ :: AgentErrorType) -> pure ()
      withStore $ \st -> deleteUserContactLink st userId
      pure CRUserContactLinkDeleted
  ShowMyAddress -> CRUserContactLink <$> withStore (`getUserContactLink` userId)
  AcceptContact cName -> do
    UserContactRequest {agentInvitationId, profileId} <- withStore $ \st ->
      getContactRequest st userId cName
    procCmd $ do
      connId <- withAgent $ \a -> acceptContact a agentInvitationId . directMessage $ XInfo profile
      withStore $ \st -> createAcceptedContact st userId connId cName profileId
      pure $ CRAcceptingContactRequest cName
  RejectContact cName -> do
    UserContactRequest {agentContactConnId, agentInvitationId} <- withStore $ \st ->
      getContactRequest st userId cName
        `E.finally` deleteContactRequest st userId cName
    withAgent $ \a -> rejectContact a agentContactConnId agentInvitationId
    pure $ CRContactRequestRejected cName
  SendMessage cName msg -> do
    contact <- withStore $ \st -> getContact st userId cName
    let mc = MCText $ safeDecodeUtf8 msg
    ci <- sendDirectChatItem userId contact (XMsgNew mc) (CISndMsgContent mc)
    setActive $ ActiveC cName
    pure . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat contact) ci
  NewGroup gProfile -> do
    gVar <- asks idsDrg
    CRGroupCreated <$> withStore (\st -> createNewGroup st gVar user gProfile)
  AddMember gName cName memRole -> do
    -- TODO for large groups: no need to load all members to determine if contact is a member
    (group, contact) <- withStore $ \st -> (,) <$> getGroup st user gName <*> getContact st userId cName
    let Group gInfo@GroupInfo {groupId, groupProfile, membership} members = group
        GroupMember {memberRole = userRole, memberId = userMemberId} = membership
    when (userRole < GRAdmin || userRole < memRole) $ throwChatError CEGroupUserRole
    when (memberStatus membership == GSMemInvited) $ throwChatError (CEGroupNotJoined gInfo)
    unless (memberActive membership) $ throwChatError CEGroupMemberNotActive
    let sendInvitation memberId cReq = do
          void . sendDirectMessage (contactConn contact) $
            XGrpInv $ GroupInvitation (MemberIdRole userMemberId userRole) (MemberIdRole memberId memRole) cReq groupProfile
          setActive $ ActiveG gName
          pure $ CRSentGroupInvitation gInfo contact
    case contactMember contact members of
      Nothing -> do
        gVar <- asks idsDrg
        (agentConnId, cReq) <- withAgent (`createConnection` SCMInvitation)
        GroupMember {memberId} <- withStore $ \st -> createContactMember st gVar user groupId contact memRole agentConnId cReq
        sendInvitation memberId cReq
      Just GroupMember {groupMemberId, memberId, memberStatus}
        | memberStatus == GSMemInvited ->
          withStore (\st -> getMemberInvitation st user groupMemberId) >>= \case
            Just cReq -> sendInvitation memberId cReq
            Nothing -> throwChatError $ CEGroupCantResendInvitation gInfo cName
        | otherwise -> throwChatError $ CEGroupDuplicateMember cName
  JoinGroup gName -> do
    ReceivedGroupInvitation {fromMember, connRequest, groupInfo = g} <- withStore $ \st -> getGroupInvitation st user gName
    procCmd $ do
      agentConnId <- withAgent $ \a -> joinConnection a connRequest . directMessage . XGrpAcpt $ memberId (membership g :: GroupMember)
      withStore $ \st -> do
        createMemberConnection st userId fromMember agentConnId
        updateGroupMemberStatus st userId fromMember GSMemAccepted
        updateGroupMemberStatus st userId (membership g) GSMemAccepted
      pure $ CRUserAcceptedGroupSent g
  MemberRole _gName _cName _mRole -> throwChatError $ CECommandError "unsupported"
  RemoveMember gName cName -> do
    Group gInfo@GroupInfo {membership} members <- withStore $ \st -> getGroup st user gName
    case find ((== cName) . (localDisplayName :: GroupMember -> ContactName)) members of
      Nothing -> throwChatError $ CEGroupMemberNotFound cName
      Just m@GroupMember {memberId = mId, memberRole = mRole, memberStatus = mStatus} -> do
        let userRole = memberRole (membership :: GroupMember)
        when (userRole < GRAdmin || userRole < mRole) $ throwChatError CEGroupUserRole
        procCmd $ do
          when (mStatus /= GSMemInvited) . void . sendGroupMessage members $ XGrpMemDel mId
          deleteMemberConnection m
          withStore $ \st -> updateGroupMemberStatus st userId m GSMemRemoved
          pure $ CRUserDeletedMember gInfo m
  LeaveGroup gName -> do
    Group gInfo@GroupInfo {membership} members <- withStore $ \st -> getGroup st user gName
    procCmd $ do
      void $ sendGroupMessage members XGrpLeave
      mapM_ deleteMemberConnection members
      withStore $ \st -> updateGroupMemberStatus st userId membership GSMemLeft
      pure $ CRLeftMemberUser gInfo
  DeleteGroup gName -> do
    g@(Group gInfo@GroupInfo {membership} members) <- withStore $ \st -> getGroup st user gName
    let s = memberStatus membership
        canDelete =
          memberRole (membership :: GroupMember) == GROwner
            || (s == GSMemRemoved || s == GSMemLeft || s == GSMemGroupDeleted || s == GSMemInvited)
    unless canDelete $ throwChatError CEGroupUserRole
    procCmd $ do
      when (memberActive membership) . void $ sendGroupMessage members XGrpDel
      mapM_ deleteMemberConnection members
      withStore $ \st -> deleteGroup st user g
      pure $ CRGroupDeletedUser gInfo
  ListMembers gName -> CRGroupMembers <$> withStore (\st -> getGroup st user gName)
  ListGroups -> CRGroupsList <$> withStore (`getUserGroupDetails` user)
  SendGroupMessage gName msg -> do
    group@(Group gInfo@GroupInfo {membership} _) <- withStore $ \st -> getGroup st user gName
    unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
    let mc = MCText $ safeDecodeUtf8 msg
    ci <- sendGroupChatItem userId group (XMsgNew mc) (CISndMsgContent mc)
    setActive $ ActiveG gName
    pure . CRNewChatItem $ AChatItem SCTGroup SMDSnd (GroupChat gInfo) ci
  SendFile cName f -> do
    (fileSize, chSize) <- checkSndFile f
    contact <- withStore $ \st -> getContact st userId cName
    (agentConnId, fileConnReq) <- withAgent (`createConnection` SCMInvitation)
    let fileInv = FileInvitation {fileName = takeFileName f, fileSize, fileConnReq}
    SndFileTransfer {fileId} <- withStore $ \st ->
      createSndFileTransfer st userId contact f fileInv agentConnId chSize
    ci <- sendDirectChatItem userId contact (XFile fileInv) (CISndFileInvitation fileId f)
    withStore $ \st -> updateFileTransferChatItemId st fileId $ chatItemId ci
    setActive $ ActiveC cName
    pure . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat contact) ci
  SendGroupFile gName f -> do
    (fileSize, chSize) <- checkSndFile f
    Group gInfo@GroupInfo {membership} members <- withStore $ \st -> getGroup st user gName
    unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
    let fileName = takeFileName f
    ms <- forM (filter memberActive members) $ \m -> do
      (connId, fileConnReq) <- withAgent (`createConnection` SCMInvitation)
      pure (m, connId, FileInvitation {fileName, fileSize, fileConnReq})
    fileId <- withStore $ \st -> createSndGroupFileTransfer st userId gInfo ms f fileSize chSize
    -- TODO sendGroupChatItem - same file invitation to all
    forM_ ms $ \(m, _, fileInv) ->
      traverse (`sendDirectMessage` XFile fileInv) $ memberConn m
    setActive $ ActiveG gName
    -- this is a hack as we have multiple direct messages instead of one per group
    let ciContent = CISndFileInvitation fileId f
    createdAt <- liftIO getCurrentTime
    let ci = mkNewChatItem ciContent 0 createdAt createdAt
    ciMeta@CIMeta {itemId} <- saveChatItem userId (CDGroupSnd gInfo) ci
    withStore $ \st -> updateFileTransferChatItemId st fileId itemId
    pure . CRNewChatItem $ AChatItem SCTGroup SMDSnd (GroupChat gInfo) $ ChatItem CIGroupSnd ciMeta ciContent
  ReceiveFile fileId filePath_ -> do
    ft@RcvFileTransfer {fileInvitation = FileInvitation {fileName, fileConnReq}, fileStatus} <- withStore $ \st -> getRcvFileTransfer st userId fileId
    unless (fileStatus == RFSNew) . throwChatError $ CEFileAlreadyReceiving fileName
    procCmd $ do
      tryError (withAgent $ \a -> joinConnection a fileConnReq . directMessage $ XFileAcpt fileName) >>= \case
        Right agentConnId -> do
          filePath <- getRcvFilePath fileId filePath_ fileName
          withStore $ \st -> acceptRcvFileTransfer st userId fileId agentConnId filePath
          pure $ CRRcvFileAccepted ft filePath
        Left (ChatErrorAgent (SMP SMP.AUTH)) -> pure $ CRRcvFileAcceptedSndCancelled ft
        Left (ChatErrorAgent (CONN DUPLICATE)) -> pure $ CRRcvFileAcceptedSndCancelled ft
        Left e -> throwError e
  CancelFile fileId -> do
    ft' <- withStore (\st -> getFileTransfer st userId fileId)
    procCmd $ case ft' of
      FTSnd fts -> do
        forM_ fts $ \ft -> cancelSndFileTransfer ft
        pure $ CRSndGroupFileCancelled fts
      FTRcv ft -> do
        cancelRcvFileTransfer ft
        pure $ CRRcvFileCancelled ft
  FileStatus fileId ->
    CRFileTransferStatus <$> withStore (\st -> getFileTransferProgress st userId fileId)
  ShowProfile -> pure $ CRUserProfile profile
  UpdateProfile p@Profile {displayName}
    | p == profile -> pure CRUserProfileNoChange
    | otherwise -> do
      withStore $ \st -> updateUserProfile st user p
      let user' = (user :: User) {localDisplayName = displayName, profile = p}
      asks currentUser >>= atomically . (`writeTVar` user')
      contacts <- withStore (`getUserContacts` user)
      procCmd $ do
        forM_ contacts $ \ct -> sendDirectMessage (contactConn ct) $ XInfo p
        pure $ CRUserProfileUpdated profile p
  QuitChat -> liftIO exitSuccess
  ShowVersion -> pure CRVersionInfo
  where
    procCmd :: m ChatResponse -> m ChatResponse
    procCmd a = do
      a
    -- ! below code would make command responses asynchronous where they can be slow
    -- ! in View.hs `r'` should be defined as `id` in this case
    -- gVar <- asks idsDrg
    -- corrId <- liftIO $ CorrId <$> randomBytes gVar 8
    -- q <- asks outputQ
    -- void . forkIO $ atomically . writeTBQueue q =<<
    --   (Just corrId,) <$> (a `catchError` (pure . CRChatError))
    -- pure $ CRCmdAccepted corrId
    -- a corrId
    connect :: ConnectionRequestUri c -> ChatMsgEvent -> m ()
    connect cReq msg = do
      connId <- withAgent $ \a -> joinConnection a cReq $ directMessage msg
      withStore $ \st -> createDirectConnection st userId connId
    contactMember :: Contact -> [GroupMember] -> Maybe GroupMember
    contactMember Contact {contactId} =
      find $ \GroupMember {memberContactId = cId, memberStatus = s} ->
        cId == Just contactId && s /= GSMemRemoved && s /= GSMemLeft
    checkSndFile :: FilePath -> m (Integer, Integer)
    checkSndFile f = do
      unlessM (doesFileExist f) . throwChatError $ CEFileNotFound f
      (,) <$> getFileSize f <*> asks (fileChunkSize . config)
    getRcvFilePath :: Int64 -> Maybe FilePath -> String -> m FilePath
    getRcvFilePath fileId filePath fileName = case filePath of
      Nothing -> do
        dir <- (`combine` "Downloads") <$> getHomeDirectory
        ifM (doesDirectoryExist dir) (pure dir) getTemporaryDirectory
          >>= (`uniqueCombine` fileName)
          >>= createEmptyFile
      Just fPath ->
        ifM
          (doesDirectoryExist fPath)
          (fPath `uniqueCombine` fileName >>= createEmptyFile)
          $ ifM
            (doesFileExist fPath)
            (throwChatError $ CEFileAlreadyExists fPath)
            (createEmptyFile fPath)
      where
        createEmptyFile :: FilePath -> m FilePath
        createEmptyFile fPath = emptyFile fPath `E.catch` (throwChatError . CEFileWrite fPath . (show :: E.SomeException -> String))
        emptyFile :: FilePath -> m FilePath
        emptyFile fPath = do
          h <- getFileHandle fileId fPath rcvFiles AppendMode
          liftIO $ B.hPut h "" >> hFlush h
          pure fPath
    uniqueCombine :: FilePath -> String -> m FilePath
    uniqueCombine filePath fileName = tryCombine (0 :: Int)
      where
        tryCombine n =
          let (name, ext) = splitExtensions fileName
              suffix = if n == 0 then "" else "_" <> show n
              f = filePath `combine` (name <> suffix <> ext)
           in ifM (doesFileExist f) (tryCombine $ n + 1) (pure f)

agentSubscriber :: (MonadUnliftIO m, MonadReader ChatController m) => m ()
agentSubscriber = do
  q <- asks $ subQ . smpAgent
  l <- asks chatLock
  subscribeUserConnections
  forever $ do
    (_, connId, msg) <- atomically $ readTBQueue q
    user <- readTVarIO =<< asks currentUser
    withLock l . void . runExceptT $
      processAgentMessage user connId msg `catchError` (toView . CRChatError)

subscribeUserConnections :: forall m. (MonadUnliftIO m, MonadReader ChatController m) => m ()
subscribeUserConnections = void . runExceptT $ do
  user <- readTVarIO =<< asks currentUser
  subscribeContacts user
  subscribeGroups user
  subscribeFiles user
  subscribePendingConnections user
  subscribeUserContactLink user
  where
    subscribeContacts user = do
      contacts <- withStore (`getUserContacts` user)
      forM_ contacts $ \ct ->
        (subscribe (contactConnId ct) >> toView (CRContactSubscribed ct)) `catchError` (toView . CRContactSubError ct)
    subscribeGroups user = do
      groups <- withStore (`getUserGroups` user)
      forM_ groups $ \(Group g@GroupInfo {membership} members) -> do
        let connectedMembers = mapMaybe (\m -> (m,) <$> memberConnId m) members
        if memberStatus membership == GSMemInvited
          then toView $ CRGroupInvitation g
          else
            if null connectedMembers
              then
                if memberActive membership
                  then toView $ CRGroupEmpty g
                  else toView $ CRGroupRemoved g
              else do
                forM_ connectedMembers $ \(GroupMember {localDisplayName = c}, cId) ->
                  subscribe cId `catchError` (toView . CRMemberSubError g c)
                toView $ CRGroupSubscribed g
    subscribeFiles user = do
      withStore (`getLiveSndFileTransfers` user) >>= mapM_ subscribeSndFile
      withStore (`getLiveRcvFileTransfers` user) >>= mapM_ subscribeRcvFile
      where
        subscribeSndFile ft@SndFileTransfer {fileId, fileStatus, agentConnId = AgentConnId cId} = do
          subscribe cId `catchError` (toView . CRSndFileSubError ft)
          void . forkIO $ do
            threadDelay 1000000
            l <- asks chatLock
            a <- asks smpAgent
            unless (fileStatus == FSNew) . unlessM (isFileActive fileId sndFiles) $
              withAgentLock a . withLock l $
                sendFileChunk ft
        subscribeRcvFile ft@RcvFileTransfer {fileStatus} =
          case fileStatus of
            RFSAccepted fInfo -> resume fInfo
            RFSConnected fInfo -> resume fInfo
            _ -> pure ()
          where
            resume RcvFileInfo {agentConnId = AgentConnId cId} =
              subscribe cId `catchError` (toView . CRRcvFileSubError ft)
    subscribePendingConnections user = do
      cs <- withStore (`getPendingConnections` user)
      subscribeConns cs `catchError` \_ -> pure ()
    subscribeUserContactLink User {userId} = do
      cs <- withStore (`getUserContactLinkConnections` userId)
      (subscribeConns cs >> toView CRUserContactLinkSubscribed)
        `catchError` (toView . CRUserContactLinkSubError)
    subscribe cId = withAgent (`subscribeConnection` cId)
    subscribeConns conns =
      withAgent $ \a ->
        forM_ conns $ subscribeConnection a . aConnId

processAgentMessage :: forall m. ChatMonad m => User -> ConnId -> ACommand 'Agent -> m ()
processAgentMessage user@User {userId, profile} agentConnId agentMessage = do
  acEntity <- withStore $ \st -> getConnectionEntity st user agentConnId
  forM_ (agentMsgConnStatus agentMessage) $ \status ->
    withStore $ \st -> updateConnectionStatus st (fromConnection acEntity) status
  case acEntity of
    RcvDirectMsgConnection conn contact_ ->
      processDirectMessage agentMessage conn contact_
    RcvGroupMsgConnection conn gInfo m ->
      processGroupMessage agentMessage conn gInfo m
    RcvFileConnection conn ft ->
      processRcvFileConn agentMessage conn ft
    SndFileConnection conn ft ->
      processSndFileConn agentMessage conn ft
    UserContactConnection conn uc ->
      processUserContactRequest agentMessage conn uc
  where
    isMember :: MemberId -> GroupInfo -> [GroupMember] -> Bool
    isMember memId GroupInfo {membership} members =
      sameMemberId memId membership || isJust (find (sameMemberId memId) members)

    contactIsReady :: Contact -> Bool
    contactIsReady Contact {activeConn} = connStatus activeConn == ConnReady

    memberIsReady :: GroupMember -> Bool
    memberIsReady GroupMember {activeConn} = maybe False ((== ConnReady) . connStatus) activeConn

    agentMsgConnStatus :: ACommand 'Agent -> Maybe ConnStatus
    agentMsgConnStatus = \case
      CONF {} -> Just ConnRequested
      INFO _ -> Just ConnSndReady
      CON -> Just ConnReady
      _ -> Nothing

    processDirectMessage :: ACommand 'Agent -> Connection -> Maybe Contact -> m ()
    processDirectMessage agentMsg conn = \case
      Nothing -> case agentMsg of
        CONF confId connInfo -> do
          saveConnInfo conn connInfo
          allowAgentConnection conn confId $ XInfo profile
        INFO connInfo ->
          saveConnInfo conn connInfo
        MSG meta msgBody -> do
          _ <- saveRcvMSG conn meta msgBody
          withAckMessage agentConnId meta $ pure ()
          ackMsgDeliveryEvent conn meta
        SENT msgId ->
          sentMsgDeliveryEvent conn msgId
        -- TODO print errors
        MERR _ _ -> pure ()
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()
      Just ct@Contact {localDisplayName = c} -> case agentMsg of
        MSG msgMeta msgBody -> do
          (msgId, chatMsgEvent) <- saveRcvMSG conn msgMeta msgBody
          withAckMessage agentConnId msgMeta $
            case chatMsgEvent of
              XMsgNew mc -> newContentMessage ct mc msgId msgMeta
              XFile fInv -> processFileInvitation ct fInv msgId msgMeta
              XInfo p -> xInfo ct p
              XGrpInv gInv -> processGroupInvitation ct gInv
              XInfoProbe probe -> xInfoProbe ct probe
              XInfoProbeCheck probeHash -> xInfoProbeCheck ct probeHash
              XInfoProbeOk probe -> xInfoProbeOk ct probe
              _ -> pure ()
          ackMsgDeliveryEvent conn msgMeta
        CONF confId connInfo -> do
          -- confirming direct connection with a member
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XGrpMemInfo _memId _memProfile -> do
              -- TODO check member ID
              -- TODO update member profile
              allowAgentConnection conn confId XOk
            _ -> messageError "CONF from member must have x.grp.mem.info"
        INFO connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XGrpMemInfo _memId _memProfile -> do
              -- TODO check member ID
              -- TODO update member profile
              pure ()
            XInfo _profile -> do
              -- TODO update contact profile
              pure ()
            XOk -> pure ()
            _ -> messageError "INFO for existing contact must have x.grp.mem.info, x.info or x.ok"
        CON ->
          withStore (\st -> getViaGroupMember st user ct) >>= \case
            Nothing -> do
              toView $ CRContactConnected ct
              setActive $ ActiveC c
              showToast (c <> "> ") "connected"
            Just (gInfo, m) -> do
              when (memberIsReady m) $ do
                notifyMemberConnected gInfo m
                when (memberCategory m == GCPreMember) $ probeMatchingContacts ct
        SENT msgId ->
          sentMsgDeliveryEvent conn msgId
        END -> do
          toView $ CRContactAnotherClient ct
          showToast (c <> "> ") "connected to another client"
          unsetActive $ ActiveC c
        DOWN -> do
          toView $ CRContactDisconnected ct
          showToast (c <> "> ") "disconnected"
        UP -> do
          toView $ CRContactSubscribed ct
          showToast (c <> "> ") "is active"
          setActive $ ActiveC c
        -- TODO print errors
        MERR _ _ -> pure ()
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()

    processGroupMessage :: ACommand 'Agent -> Connection -> GroupInfo -> GroupMember -> m ()
    processGroupMessage agentMsg conn gInfo@GroupInfo {localDisplayName = gName, membership} m = case agentMsg of
      CONF confId connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case memberCategory m of
          GCInviteeMember ->
            case chatMsgEvent of
              XGrpAcpt memId
                | sameMemberId memId m -> do
                  withStore $ \st -> updateGroupMemberStatus st userId m GSMemAccepted
                  allowAgentConnection conn confId XOk
                | otherwise -> messageError "x.grp.acpt: memberId is different from expected"
              _ -> messageError "CONF from invited member must have x.grp.acpt"
          _ ->
            case chatMsgEvent of
              XGrpMemInfo memId _memProfile
                | sameMemberId memId m -> do
                  -- TODO update member profile
                  allowAgentConnection conn confId $ XGrpMemInfo (memberId (membership :: GroupMember)) profile
                | otherwise -> messageError "x.grp.mem.info: memberId is different from expected"
              _ -> messageError "CONF from member must have x.grp.mem.info"
      INFO connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case chatMsgEvent of
          XGrpMemInfo memId _memProfile
            | sameMemberId memId m -> do
              -- TODO update member profile
              pure ()
            | otherwise -> messageError "x.grp.mem.info: memberId is different from expected"
          XOk -> pure ()
          _ -> messageError "INFO from member must have x.grp.mem.info"
        pure ()
      CON -> do
        members <- withStore $ \st -> getGroupMembers st user gInfo
        withStore $ \st -> do
          updateGroupMemberStatus st userId m GSMemConnected
          unless (memberActive membership) $
            updateGroupMemberStatus st userId membership GSMemConnected
        sendPendingGroupMessages m conn
        case memberCategory m of
          GCHostMember -> do
            toView $ CRUserJoinedGroup gInfo
            setActive $ ActiveG gName
            showToast ("#" <> gName) "you are connected to group"
          GCInviteeMember -> do
            toView $ CRJoinedGroupMember gInfo m
            setActive $ ActiveG gName
            showToast ("#" <> gName) $ "member " <> localDisplayName (m :: GroupMember) <> " is connected"
            intros <- withStore $ \st -> createIntroductions st members m
            void . sendGroupMessage members . XGrpMemNew $ memberInfo m
            forM_ intros $ \intro@GroupMemberIntro {introId} -> do
              void . sendDirectMessage conn . XGrpMemIntro . memberInfo $ reMember intro
              withStore $ \st -> updateIntroStatus st introId GMIntroSent
          _ -> do
            -- TODO send probe and decide whether to use existing contact connection or the new contact connection
            -- TODO notify member who forwarded introduction - question - where it is stored? There is via_contact but probably there should be via_member in group_members table
            withStore (\st -> getViaGroupContact st user m) >>= \case
              Nothing -> do
                notifyMemberConnected gInfo m
                messageError "implementation error: connected member does not have contact"
              Just ct ->
                when (contactIsReady ct) $ do
                  notifyMemberConnected gInfo m
                  when (memberCategory m == GCPreMember) $ probeMatchingContacts ct
      MSG msgMeta msgBody -> do
        (msgId, chatMsgEvent) <- saveRcvMSG conn msgMeta msgBody
        withAckMessage agentConnId msgMeta $
          case chatMsgEvent of
            XMsgNew mc -> newGroupContentMessage gInfo m mc msgId msgMeta
            XFile fInv -> processGroupFileInvitation gInfo m fInv msgId msgMeta
            XGrpMemNew memInfo -> xGrpMemNew gInfo m memInfo
            XGrpMemIntro memInfo -> xGrpMemIntro conn gInfo m memInfo
            XGrpMemInv memId introInv -> xGrpMemInv gInfo m memId introInv
            XGrpMemFwd memInfo introInv -> xGrpMemFwd gInfo m memInfo introInv
            XGrpMemDel memId -> xGrpMemDel gInfo m memId
            XGrpLeave -> xGrpLeave gInfo m
            XGrpDel -> xGrpDel gInfo m
            _ -> messageError $ "unsupported message: " <> T.pack (show chatMsgEvent)
        ackMsgDeliveryEvent conn msgMeta
      SENT msgId ->
        sentMsgDeliveryEvent conn msgId
      -- TODO print errors
      MERR _ _ -> pure ()
      ERR _ -> pure ()
      -- TODO add debugging output
      _ -> pure ()

    processSndFileConn :: ACommand 'Agent -> Connection -> SndFileTransfer -> m ()
    processSndFileConn agentMsg conn ft@SndFileTransfer {fileId, fileName, fileStatus} =
      case agentMsg of
        CONF confId connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            -- TODO save XFileAcpt message
            XFileAcpt name
              | name == fileName -> do
                withStore $ \st -> updateSndFileStatus st ft FSAccepted
                allowAgentConnection conn confId XOk
              | otherwise -> messageError "x.file.acpt: fileName is different from expected"
            _ -> messageError "CONF from file connection must have x.file.acpt"
        CON -> do
          withStore $ \st -> updateSndFileStatus st ft FSConnected
          toView $ CRSndFileStart ft
          sendFileChunk ft
        SENT msgId -> do
          withStore $ \st -> updateSndFileChunkSent st ft msgId
          unless (fileStatus == FSCancelled) $ sendFileChunk ft
        MERR _ err -> do
          cancelSndFileTransfer ft
          case err of
            SMP SMP.AUTH -> unless (fileStatus == FSCancelled) $ toView $ CRSndFileRcvCancelled ft
            _ -> throwChatError $ CEFileSend fileId err
        MSG meta _ ->
          withAckMessage agentConnId meta $ pure ()
        -- TODO print errors
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()

    processRcvFileConn :: ACommand 'Agent -> Connection -> RcvFileTransfer -> m ()
    processRcvFileConn agentMsg _conn ft@RcvFileTransfer {fileId, chunkSize} =
      case agentMsg of
        CON -> do
          withStore $ \st -> updateRcvFileStatus st ft FSConnected
          toView $ CRRcvFileStart ft
        MSG meta@MsgMeta {recipient = (msgId, _), integrity} msgBody -> withAckMessage agentConnId meta $ do
          parseFileChunk msgBody >>= \case
            FileChunkCancel -> do
              cancelRcvFileTransfer ft
              toView $ CRRcvFileSndCancelled ft
            FileChunk {chunkNo, chunkBytes = chunk} -> do
              case integrity of
                MsgOk -> pure ()
                MsgError MsgDuplicate -> pure () -- TODO remove once agent removes duplicates
                MsgError e ->
                  badRcvFileChunk ft $ "invalid file chunk number " <> show chunkNo <> ": " <> show e
              withStore (\st -> createRcvFileChunk st ft chunkNo msgId) >>= \case
                RcvChunkOk ->
                  if B.length chunk /= fromInteger chunkSize
                    then badRcvFileChunk ft "incorrect chunk size"
                    else appendFileChunk ft chunkNo chunk
                RcvChunkFinal ->
                  if B.length chunk > fromInteger chunkSize
                    then badRcvFileChunk ft "incorrect chunk size"
                    else do
                      appendFileChunk ft chunkNo chunk
                      withStore $ \st -> do
                        updateRcvFileStatus st ft FSComplete
                        deleteRcvFileChunks st ft
                      toView $ CRRcvFileComplete ft
                      closeFileHandle fileId rcvFiles
                      withAgent (`deleteConnection` agentConnId)
                RcvChunkDuplicate -> pure ()
                RcvChunkError -> badRcvFileChunk ft $ "incorrect chunk number " <> show chunkNo
        -- TODO print errors
        MERR _ _ -> pure ()
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()

    processUserContactRequest :: ACommand 'Agent -> Connection -> UserContact -> m ()
    processUserContactRequest agentMsg _conn UserContact {userContactLinkId} = case agentMsg of
      REQ invId connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case chatMsgEvent of
          XContact p _ -> profileContactRequest invId p
          XInfo p -> profileContactRequest invId p
          -- TODO show/log error, other events in contact request
          _ -> pure ()
      -- TODO print errors
      MERR _ _ -> pure ()
      ERR _ -> pure ()
      -- TODO add debugging output
      _ -> pure ()
      where
        profileContactRequest :: InvitationId -> Profile -> m ()
        profileContactRequest invId p = do
          cName <- withStore $ \st -> createContactRequest st userId userContactLinkId invId p
          toView $ CRReceivedContactRequest cName p
          showToast (cName <> "> ") "wants to connect to you"

    withAckMessage :: ConnId -> MsgMeta -> m () -> m ()
    withAckMessage cId MsgMeta {recipient = (msgId, _)} action =
      action `E.finally` withAgent (\a -> ackMessage a cId msgId `catchError` \_ -> pure ())

    ackMsgDeliveryEvent :: Connection -> MsgMeta -> m ()
    ackMsgDeliveryEvent Connection {connId} MsgMeta {recipient = (msgId, _)} =
      withStore $ \st -> createRcvMsgDeliveryEvent st connId msgId MDSRcvAcknowledged

    sentMsgDeliveryEvent :: Connection -> AgentMsgId -> m ()
    sentMsgDeliveryEvent Connection {connId} msgId =
      withStore $ \st -> createSndMsgDeliveryEvent st connId msgId MDSSndSent

    badRcvFileChunk :: RcvFileTransfer -> String -> m ()
    badRcvFileChunk ft@RcvFileTransfer {fileStatus} err =
      case fileStatus of
        RFSCancelled _ -> pure ()
        _ -> do
          cancelRcvFileTransfer ft
          throwChatError $ CEFileRcvChunk err

    notifyMemberConnected :: GroupInfo -> GroupMember -> m ()
    notifyMemberConnected gInfo m@GroupMember {localDisplayName = c} = do
      toView $ CRConnectedToGroupMember gInfo m
      let g = groupName' gInfo
      setActive $ ActiveG g
      showToast ("#" <> g) $ "member " <> c <> " is connected"

    probeMatchingContacts :: Contact -> m ()
    probeMatchingContacts ct = do
      gVar <- asks idsDrg
      (probe, probeId) <- withStore $ \st -> createSentProbe st gVar userId ct
      void . sendDirectMessage (contactConn ct) $ XInfoProbe probe
      cs <- withStore (\st -> getMatchingContacts st userId ct)
      let probeHash = ProbeHash $ C.sha256Hash (unProbe probe)
      forM_ cs $ \c -> sendProbeHash c probeHash probeId `catchError` const (pure ())
      where
        sendProbeHash :: Contact -> ProbeHash -> Int64 -> m ()
        sendProbeHash c probeHash probeId = do
          void . sendDirectMessage (contactConn c) $ XInfoProbeCheck probeHash
          withStore $ \st -> createSentProbeHash st userId probeId c

    messageWarning :: Text -> m ()
    messageWarning = toView . CRMessageError "warning"

    messageError :: Text -> m ()
    messageError = toView . CRMessageError "error"

    newContentMessage :: Contact -> MsgContent -> MessageId -> MsgMeta -> m ()
    newContentMessage ct@Contact {localDisplayName = c} mc msgId msgMeta = do
      ci <- saveRcvDirectChatItem userId ct msgId msgMeta (CIRcvMsgContent mc)
      toView . CRNewChatItem $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
      showToast (c <> "> ") $ msgContentText mc
      setActive $ ActiveC c

    newGroupContentMessage :: GroupInfo -> GroupMember -> MsgContent -> MessageId -> MsgMeta -> m ()
    newGroupContentMessage gInfo m@GroupMember {localDisplayName = c} mc msgId msgMeta = do
      ci <- saveRcvGroupChatItem userId gInfo m msgId msgMeta (CIRcvMsgContent mc)
      toView . CRNewChatItem $ AChatItem SCTGroup SMDRcv (GroupChat gInfo) ci
      let g = groupName' gInfo
      showToast ("#" <> g <> " " <> c <> "> ") $ msgContentText mc
      setActive $ ActiveG g

    processFileInvitation :: Contact -> FileInvitation -> MessageId -> MsgMeta -> m ()
    processFileInvitation ct@Contact {localDisplayName = c} fInv msgId msgMeta = do
      -- TODO chunk size has to be sent as part of invitation
      chSize <- asks $ fileChunkSize . config
      ft@RcvFileTransfer {fileId} <- withStore $ \st -> createRcvFileTransfer st userId ct fInv chSize
      ci <- saveRcvDirectChatItem userId ct msgId msgMeta (CIRcvFileInvitation ft)
      withStore $ \st -> updateFileTransferChatItemId st fileId $ chatItemId ci
      toView . CRNewChatItem $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
      showToast (c <> "> ") "wants to send a file"
      setActive $ ActiveC c

    processGroupFileInvitation :: GroupInfo -> GroupMember -> FileInvitation -> MessageId -> MsgMeta -> m ()
    processGroupFileInvitation gInfo m@GroupMember {localDisplayName = c} fInv msgId msgMeta = do
      chSize <- asks $ fileChunkSize . config
      ft@RcvFileTransfer {fileId} <- withStore $ \st -> createRcvGroupFileTransfer st userId m fInv chSize
      ci <- saveRcvGroupChatItem userId gInfo m msgId msgMeta (CIRcvFileInvitation ft)
      withStore $ \st -> updateFileTransferChatItemId st fileId $ chatItemId ci
      toView . CRNewChatItem $ AChatItem SCTGroup SMDRcv (GroupChat gInfo) ci
      let g = groupName' gInfo
      showToast ("#" <> g <> " " <> c <> "> ") "wants to send a file"
      setActive $ ActiveG g

    processGroupInvitation :: Contact -> GroupInvitation -> m ()
    processGroupInvitation ct@Contact {localDisplayName = c} inv@(GroupInvitation (MemberIdRole fromMemId fromRole) (MemberIdRole memId memRole) _ _) = do
      when (fromRole < GRAdmin || fromRole < memRole) $ throwChatError (CEGroupContactRole c)
      when (fromMemId == memId) $ throwChatError CEGroupDuplicateMemberId
      gInfo@GroupInfo {localDisplayName = gName} <- withStore $ \st -> createGroupInvitation st user ct inv
      toView $ CRReceivedGroupInvitation gInfo ct memRole
      showToast ("#" <> gName <> " " <> c <> "> ") "invited you to join the group"

    xInfo :: Contact -> Profile -> m ()
    xInfo c@Contact {profile = p} p' = unless (p == p') $ do
      c' <- withStore $ \st -> updateContactProfile st userId c p'
      toView $ CRContactUpdated c c'

    xInfoProbe :: Contact -> Probe -> m ()
    xInfoProbe c2 probe = do
      r <- withStore $ \st -> matchReceivedProbe st userId c2 probe
      forM_ r $ \c1 -> probeMatch c1 c2 probe

    xInfoProbeCheck :: Contact -> ProbeHash -> m ()
    xInfoProbeCheck c1 probeHash = do
      r <- withStore $ \st -> matchReceivedProbeHash st userId c1 probeHash
      forM_ r . uncurry $ probeMatch c1

    probeMatch :: Contact -> Contact -> Probe -> m ()
    probeMatch c1@Contact {profile = p1} c2@Contact {profile = p2} probe =
      when (p1 == p2) $ do
        void . sendDirectMessage (contactConn c1) $ XInfoProbeOk probe
        mergeContacts c1 c2

    xInfoProbeOk :: Contact -> Probe -> m ()
    xInfoProbeOk c1 probe = do
      r <- withStore $ \st -> matchSentProbe st userId c1 probe
      forM_ r $ \c2 -> mergeContacts c1 c2

    mergeContacts :: Contact -> Contact -> m ()
    mergeContacts to from = do
      withStore $ \st -> mergeContactRecords st userId to from
      toView $ CRContactsMerged to from

    saveConnInfo :: Connection -> ConnInfo -> m ()
    saveConnInfo activeConn connInfo = do
      ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
      case chatMsgEvent of
        XInfo p ->
          withStore $ \st -> createDirectContact st userId activeConn p
        -- TODO show/log error, other events in SMP confirmation
        _ -> pure ()

    xGrpMemNew :: GroupInfo -> GroupMember -> MemberInfo -> m ()
    xGrpMemNew gInfo m memInfo@(MemberInfo memId _ _) = do
      members <- withStore $ \st -> getGroupMembers st user gInfo
      unless (sameMemberId memId $ membership gInfo) $
        if isMember memId gInfo members
          then messageError "x.grp.mem.new error: member already exists"
          else do
            newMember <- withStore $ \st -> createNewGroupMember st user gInfo memInfo GCPostMember GSMemAnnounced
            toView $ CRJoinedGroupMemberConnecting gInfo m newMember

    xGrpMemIntro :: Connection -> GroupInfo -> GroupMember -> MemberInfo -> m ()
    xGrpMemIntro conn gInfo m memInfo@(MemberInfo memId _ _) = do
      case memberCategory m of
        GCHostMember -> do
          members <- withStore $ \st -> getGroupMembers st user gInfo
          if isMember memId gInfo members
            then messageWarning "x.grp.mem.intro ignored: member already exists"
            else do
              (groupConnId, groupConnReq) <- withAgent (`createConnection` SCMInvitation)
              (directConnId, directConnReq) <- withAgent (`createConnection` SCMInvitation)
              newMember <- withStore $ \st -> createIntroReMember st user gInfo m memInfo groupConnId directConnId
              let msg = XGrpMemInv memId IntroInvitation {groupConnReq, directConnReq}
              void $ sendDirectMessage conn msg
              withStore $ \st -> updateGroupMemberStatus st userId newMember GSMemIntroInvited
        _ -> messageError "x.grp.mem.intro can be only sent by host member"

    xGrpMemInv :: GroupInfo -> GroupMember -> MemberId -> IntroInvitation -> m ()
    xGrpMemInv gInfo m memId introInv = do
      case memberCategory m of
        GCInviteeMember -> do
          members <- withStore $ \st -> getGroupMembers st user gInfo
          case find (sameMemberId memId) members of
            Nothing -> messageError "x.grp.mem.inv error: referenced member does not exists"
            Just reMember -> do
              GroupMemberIntro {introId} <- withStore $ \st -> saveIntroInvitation st reMember m introInv
              void $ sendXGrpMemInv reMember (XGrpMemFwd (memberInfo m) introInv) introId
        _ -> messageError "x.grp.mem.inv can be only sent by invitee member"

    xGrpMemFwd :: GroupInfo -> GroupMember -> MemberInfo -> IntroInvitation -> m ()
    xGrpMemFwd gInfo@GroupInfo {membership} m memInfo@(MemberInfo memId _ _) introInv@IntroInvitation {groupConnReq, directConnReq} = do
      members <- withStore $ \st -> getGroupMembers st user gInfo
      toMember <- case find (sameMemberId memId) members of
        -- TODO if the missed messages are correctly sent as soon as there is connection before anything else is sent
        -- the situation when member does not exist is an error
        -- member receiving x.grp.mem.fwd should have also received x.grp.mem.new prior to that.
        -- For now, this branch compensates for the lack of delayed message delivery.
        Nothing -> withStore $ \st -> createNewGroupMember st user gInfo memInfo GCPostMember GSMemAnnounced
        Just m' -> pure m'
      withStore $ \st -> saveMemberInvitation st toMember introInv
      let msg = XGrpMemInfo (memberId (membership :: GroupMember)) profile
      groupConnId <- withAgent $ \a -> joinConnection a groupConnReq $ directMessage msg
      directConnId <- withAgent $ \a -> joinConnection a directConnReq $ directMessage msg
      withStore $ \st -> createIntroToMemberContact st userId m toMember groupConnId directConnId

    xGrpMemDel :: GroupInfo -> GroupMember -> MemberId -> m ()
    xGrpMemDel gInfo@GroupInfo {membership} m memId = do
      members <- withStore $ \st -> getGroupMembers st user gInfo
      if memberId (membership :: GroupMember) == memId
        then do
          mapM_ deleteMemberConnection members
          withStore $ \st -> updateGroupMemberStatus st userId membership GSMemRemoved
          toView $ CRDeletedMemberUser gInfo m
        else case find (sameMemberId memId) members of
          Nothing -> messageError "x.grp.mem.del with unknown member ID"
          Just member -> do
            let mRole = memberRole (m :: GroupMember)
            if mRole < GRAdmin || mRole < memberRole (member :: GroupMember)
              then messageError "x.grp.mem.del with insufficient member permissions"
              else do
                deleteMemberConnection member
                withStore $ \st -> updateGroupMemberStatus st userId member GSMemRemoved
                toView $ CRDeletedMember gInfo m member

    sameMemberId :: MemberId -> GroupMember -> Bool
    sameMemberId memId GroupMember {memberId} = memId == memberId

    xGrpLeave :: GroupInfo -> GroupMember -> m ()
    xGrpLeave gInfo m = do
      deleteMemberConnection m
      withStore $ \st -> updateGroupMemberStatus st userId m GSMemLeft
      toView $ CRLeftMember gInfo m

    xGrpDel :: GroupInfo -> GroupMember -> m ()
    xGrpDel gInfo m@GroupMember {memberRole} = do
      when (memberRole /= GROwner) $ throwChatError CEGroupUserRole
      ms <- withStore $ \st -> do
        members <- getGroupMembers st user gInfo
        updateGroupMemberStatus st userId (membership gInfo) GSMemGroupDeleted
        pure members
      mapM_ deleteMemberConnection ms
      toView $ CRGroupDeleted gInfo m

parseChatMessage :: ByteString -> Either ChatError ChatMessage
parseChatMessage = first ChatErrorMessage . strDecode

sendFileChunk :: ChatMonad m => SndFileTransfer -> m ()
sendFileChunk ft@SndFileTransfer {fileId, fileStatus, agentConnId = AgentConnId acId} =
  unless (fileStatus == FSComplete || fileStatus == FSCancelled) $
    withStore (`createSndFileChunk` ft) >>= \case
      Just chunkNo -> sendFileChunkNo ft chunkNo
      Nothing -> do
        withStore $ \st -> do
          updateSndFileStatus st ft FSComplete
          deleteSndFileChunks st ft
        toView $ CRSndFileComplete ft
        closeFileHandle fileId sndFiles
        withAgent (`deleteConnection` acId)

sendFileChunkNo :: ChatMonad m => SndFileTransfer -> Integer -> m ()
sendFileChunkNo ft@SndFileTransfer {agentConnId = AgentConnId acId} chunkNo = do
  chunkBytes <- readFileChunk ft chunkNo
  msgId <- withAgent $ \a -> sendMessage a acId $ smpEncode FileChunk {chunkNo, chunkBytes}
  withStore $ \st -> updateSndFileChunkMsg st ft chunkNo msgId

readFileChunk :: ChatMonad m => SndFileTransfer -> Integer -> m ByteString
readFileChunk SndFileTransfer {fileId, filePath, chunkSize} chunkNo =
  read_ `E.catch` (throwChatError . CEFileRead filePath . (show :: E.SomeException -> String))
  where
    read_ = do
      h <- getFileHandle fileId filePath sndFiles ReadMode
      pos <- hTell h
      let pos' = (chunkNo - 1) * chunkSize
      when (pos /= pos') $ hSeek h AbsoluteSeek pos'
      liftIO . B.hGet h $ fromInteger chunkSize

data FileChunk = FileChunk {chunkNo :: Integer, chunkBytes :: ByteString} | FileChunkCancel

instance Encoding FileChunk where
  smpEncode = \case
    FileChunk {chunkNo, chunkBytes} -> smpEncode ('F', fromIntegral chunkNo :: Word32, Tail chunkBytes)
    FileChunkCancel -> smpEncode 'C'
  smpP =
    smpP >>= \case
      'F' -> do
        chunkNo <- fromIntegral <$> smpP @Word32
        Tail chunkBytes <- smpP
        pure FileChunk {chunkNo, chunkBytes}
      'C' -> pure FileChunkCancel
      _ -> fail "bad FileChunk"

parseFileChunk :: ChatMonad m => ByteString -> m FileChunk
parseFileChunk msg =
  liftEither . first (ChatError . CEFileRcvChunk) $ parseAll smpP msg

appendFileChunk :: ChatMonad m => RcvFileTransfer -> Integer -> ByteString -> m ()
appendFileChunk ft@RcvFileTransfer {fileId, fileStatus} chunkNo chunk =
  case fileStatus of
    RFSConnected RcvFileInfo {filePath} -> append_ filePath
    RFSCancelled _ -> pure ()
    _ -> throwChatError $ CEFileInternal "receiving file transfer not in progress"
  where
    append_ fPath = do
      h <- getFileHandle fileId fPath rcvFiles AppendMode
      E.try (liftIO $ B.hPut h chunk >> hFlush h) >>= \case
        Left (e :: E.SomeException) -> throwChatError . CEFileWrite fPath $ show e
        Right () -> withStore $ \st -> updatedRcvFileChunkStored st ft chunkNo

getFileHandle :: ChatMonad m => Int64 -> FilePath -> (ChatController -> TVar (Map Int64 Handle)) -> IOMode -> m Handle
getFileHandle fileId filePath files ioMode = do
  fs <- asks files
  h_ <- M.lookup fileId <$> readTVarIO fs
  maybe (newHandle fs) pure h_
  where
    newHandle fs = do
      -- TODO handle errors
      h <- liftIO (openFile filePath ioMode)
      atomically . modifyTVar fs $ M.insert fileId h
      pure h

isFileActive :: ChatMonad m => Int64 -> (ChatController -> TVar (Map Int64 Handle)) -> m Bool
isFileActive fileId files = do
  fs <- asks files
  isJust . M.lookup fileId <$> readTVarIO fs

cancelRcvFileTransfer :: ChatMonad m => RcvFileTransfer -> m ()
cancelRcvFileTransfer ft@RcvFileTransfer {fileId, fileStatus} = do
  closeFileHandle fileId rcvFiles
  withStore $ \st -> do
    updateRcvFileStatus st ft FSCancelled
    deleteRcvFileChunks st ft
  case fileStatus of
    RFSAccepted RcvFileInfo {agentConnId = AgentConnId acId} -> withAgent (`suspendConnection` acId)
    RFSConnected RcvFileInfo {agentConnId = AgentConnId acId} -> withAgent (`suspendConnection` acId)
    _ -> pure ()

cancelSndFileTransfer :: ChatMonad m => SndFileTransfer -> m ()
cancelSndFileTransfer ft@SndFileTransfer {agentConnId = AgentConnId acId, fileStatus} =
  unless (fileStatus == FSCancelled || fileStatus == FSComplete) $ do
    withStore $ \st -> do
      updateSndFileStatus st ft FSCancelled
      deleteSndFileChunks st ft
    withAgent $ \a -> do
      void (sendMessage a acId $ smpEncode FileChunkCancel) `catchError` \_ -> pure ()
      suspendConnection a acId

closeFileHandle :: ChatMonad m => Int64 -> (ChatController -> TVar (Map Int64 Handle)) -> m ()
closeFileHandle fileId files = do
  fs <- asks files
  h_ <- atomically . stateTVar fs $ \m -> (M.lookup fileId m, M.delete fileId m)
  mapM_ hClose h_ `E.catch` \(_ :: E.SomeException) -> pure ()

throwChatError :: ChatMonad m => ChatErrorType -> m a
throwChatError = throwError . ChatError

deleteMemberConnection :: ChatMonad m => GroupMember -> m ()
deleteMemberConnection m@GroupMember {activeConn} = do
  -- User {userId} <- asks currentUser
  withAgent $ forM_ (memberConnId m) . suspendConnection
  -- withStore $ \st -> deleteGroupMemberConnection st userId m
  forM_ activeConn $ \conn -> withStore $ \st -> updateConnectionStatus st conn ConnDeleted

sendDirectMessage :: ChatMonad m => Connection -> ChatMsgEvent -> m MessageId
sendDirectMessage conn chatMsgEvent = do
  (msgId, msgBody) <- createSndMessage chatMsgEvent
  deliverMessage conn msgBody msgId
  pure msgId

createSndMessage :: ChatMonad m => ChatMsgEvent -> m (MessageId, MsgBody)
createSndMessage chatMsgEvent = do
  let msgBody = directMessage chatMsgEvent
      newMsg = NewMessage {direction = MDSnd, cmEventTag = toCMEventTag chatMsgEvent, msgBody}
  msgId <- withStore $ \st -> createNewMessage st newMsg
  pure (msgId, msgBody)

directMessage :: ChatMsgEvent -> ByteString
directMessage chatMsgEvent = strEncode ChatMessage {chatMsgEvent}

deliverMessage :: ChatMonad m => Connection -> MsgBody -> MessageId -> m ()
deliverMessage conn@Connection {connId} msgBody msgId = do
  agentMsgId <- withAgent $ \a -> sendMessage a (aConnId conn) msgBody
  let sndMsgDelivery = SndMsgDelivery {connId, agentMsgId}
  withStore $ \st -> createSndMsgDelivery st sndMsgDelivery msgId

sendGroupMessage :: ChatMonad m => [GroupMember] -> ChatMsgEvent -> m MessageId
sendGroupMessage members chatMsgEvent =
  sendGroupMessage' members chatMsgEvent Nothing $ pure ()

sendXGrpMemInv :: ChatMonad m => GroupMember -> ChatMsgEvent -> Int64 -> m MessageId
sendXGrpMemInv reMember chatMsgEvent introId =
  sendGroupMessage' [reMember] chatMsgEvent (Just introId) $
    withStore (\st -> updateIntroStatus st introId GMIntroInvForwarded)

sendGroupMessage' :: ChatMonad m => [GroupMember] -> ChatMsgEvent -> Maybe Int64 -> m () -> m MessageId
sendGroupMessage' members chatMsgEvent introId_ postDeliver = do
  (msgId, msgBody) <- createSndMessage chatMsgEvent
  for_ (filter memberCurrent members) $ \m@GroupMember {groupMemberId} ->
    case memberConn m of
      Nothing -> withStore $ \st -> createPendingGroupMessage st groupMemberId msgId introId_
      Just conn -> deliverMessage conn msgBody msgId >> postDeliver
  pure msgId

sendPendingGroupMessages :: ChatMonad m => GroupMember -> Connection -> m ()
sendPendingGroupMessages GroupMember {groupMemberId, localDisplayName} conn = do
  pendingMessages <- withStore $ \st -> getPendingGroupMessages st groupMemberId
  -- TODO ensure order - pending messages interleave with user input messages
  for_ pendingMessages $ \PendingGroupMessage {msgId, cmEventTag, msgBody, introId_} -> do
    deliverMessage conn msgBody msgId
    withStore (\st -> deletePendingGroupMessage st groupMemberId msgId)
    when (cmEventTag == XGrpMemFwd_) $ case introId_ of
      Nothing -> throwChatError $ CEGroupMemberIntroNotFound localDisplayName
      Just introId -> withStore (\st -> updateIntroStatus st introId GMIntroInvForwarded)

saveRcvMSG :: ChatMonad m => Connection -> MsgMeta -> MsgBody -> m (MessageId, ChatMsgEvent)
saveRcvMSG Connection {connId} agentMsgMeta msgBody = do
  ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage msgBody
  let agentMsgId = fst $ recipient agentMsgMeta
      cmEventTag = toCMEventTag chatMsgEvent
      newMsg = NewMessage {direction = MDRcv, cmEventTag, msgBody}
      rcvMsgDelivery = RcvMsgDelivery {connId, agentMsgId, agentMsgMeta}
  msgId <- withStore $ \st -> createNewMessageAndRcvMsgDelivery st newMsg rcvMsgDelivery
  pure (msgId, chatMsgEvent)

sendDirectChatItem :: ChatMonad m => UserId -> Contact -> ChatMsgEvent -> CIContent 'MDSnd -> m (ChatItem 'CTDirect 'MDSnd)
sendDirectChatItem userId contact@Contact {activeConn} chatMsgEvent ciContent = do
  msgId <- sendDirectMessage activeConn chatMsgEvent
  createdAt <- liftIO getCurrentTime
  ciMeta <- saveChatItem userId (CDDirectSnd contact) $ mkNewChatItem ciContent msgId createdAt createdAt
  pure $ ChatItem CIDirectSnd ciMeta ciContent

sendGroupChatItem :: ChatMonad m => UserId -> Group -> ChatMsgEvent -> CIContent 'MDSnd -> m (ChatItem 'CTGroup 'MDSnd)
sendGroupChatItem userId (Group g ms) chatMsgEvent ciContent = do
  msgId <- sendGroupMessage ms chatMsgEvent
  createdAt <- liftIO getCurrentTime
  ciMeta <- saveChatItem userId (CDGroupSnd g) $ mkNewChatItem ciContent msgId createdAt createdAt
  pure $ ChatItem CIGroupSnd ciMeta ciContent

saveRcvDirectChatItem :: ChatMonad m => UserId -> Contact -> MessageId -> MsgMeta -> CIContent 'MDRcv -> m (ChatItem 'CTDirect 'MDRcv)
saveRcvDirectChatItem userId ct msgId MsgMeta {broker = (_, brokerTs)} ciContent = do
  createdAt <- liftIO getCurrentTime
  ciMeta <- saveChatItem userId (CDDirectRcv ct) $ mkNewChatItem ciContent msgId brokerTs createdAt
  pure $ ChatItem CIDirectRcv ciMeta ciContent

saveRcvGroupChatItem :: ChatMonad m => UserId -> GroupInfo -> GroupMember -> MessageId -> MsgMeta -> CIContent 'MDRcv -> m (ChatItem 'CTGroup 'MDRcv)
saveRcvGroupChatItem userId g m msgId MsgMeta {broker = (_, brokerTs)} ciContent = do
  createdAt <- liftIO getCurrentTime
  ciMeta <- saveChatItem userId (CDGroupRcv g m) $ mkNewChatItem ciContent msgId brokerTs createdAt
  pure $ ChatItem (CIGroupRcv m) ciMeta ciContent

saveChatItem :: ChatMonad m => UserId -> ChatDirection c d -> NewChatItem d -> m CIMeta
saveChatItem userId cd ci@NewChatItem {itemTs, itemText, createdAt} = do
  tz <- liftIO getCurrentTimeZone
  ciId <- withStore $ \st -> createNewChatItem st userId cd ci
  pure $ mkCIMeta ciId itemText tz itemTs createdAt

mkNewChatItem :: forall d. MsgDirectionI d => CIContent d -> MessageId -> UTCTime -> UTCTime -> NewChatItem d
mkNewChatItem itemContent msgId itemTs createdAt =
  NewChatItem
    { createdByMsgId = if msgId == 0 then Nothing else Just msgId,
      itemSent = msgDirection @d,
      itemTs,
      itemContent,
      itemText = ciContentToText itemContent,
      createdAt
    }

allowAgentConnection :: ChatMonad m => Connection -> ConfirmationId -> ChatMsgEvent -> m ()
allowAgentConnection conn confId msg = do
  withAgent $ \a -> allowConnection a (aConnId conn) confId $ directMessage msg
  withStore $ \st -> updateConnectionStatus st conn ConnAccepted

getCreateActiveUser :: SQLiteStore -> IO User
getCreateActiveUser st = do
  user <-
    getUsers st >>= \case
      [] -> newUser
      users -> maybe (selectUser users) pure (find activeUser users)
  putStrLn $ "Current user: " <> userStr user
  pure user
  where
    newUser :: IO User
    newUser = do
      putStrLn
        "No user profiles found, it will be created now.\n\
        \Please choose your display name and your full name.\n\
        \They will be sent to your contacts when you connect.\n\
        \They are only stored on your device and you can change them later."
      loop
      where
        loop = do
          displayName <- getContactName
          fullName <- T.pack <$> getWithPrompt "full name (optional)"
          liftIO (runExceptT $ createUser st Profile {displayName, fullName} True) >>= \case
            Left SEDuplicateName -> do
              putStrLn "chosen display name is already used by another profile on this device, choose another one"
              loop
            Left e -> putStrLn ("database error " <> show e) >> exitFailure
            Right user -> pure user
    selectUser :: [User] -> IO User
    selectUser [user] = do
      liftIO $ setActiveUser st (userId user)
      pure user
    selectUser users = do
      putStrLn "Select user profile:"
      forM_ (zip [1 ..] users) $ \(n :: Int, user) -> putStrLn $ show n <> " - " <> userStr user
      loop
      where
        loop = do
          nStr <- getWithPrompt $ "user profile number (1 .. " <> show (length users) <> ")"
          case readMaybe nStr :: Maybe Int of
            Nothing -> putStrLn "invalid user number" >> loop
            Just n
              | n <= 0 || n > length users -> putStrLn "invalid user number" >> loop
              | otherwise -> do
                let user = users !! (n - 1)
                liftIO $ setActiveUser st (userId user)
                pure user
    userStr :: User -> String
    userStr User {localDisplayName, profile = Profile {fullName}} =
      T.unpack $ localDisplayName <> if T.null fullName || localDisplayName == fullName then "" else " (" <> fullName <> ")"
    getContactName :: IO ContactName
    getContactName = do
      displayName <- getWithPrompt "display name (no spaces)"
      if null displayName || isJust (find (== ' ') displayName)
        then putStrLn "display name has space(s), choose another one" >> getContactName
        else pure $ T.pack displayName
    getWithPrompt :: String -> IO String
    getWithPrompt s = putStr (s <> ": ") >> hFlush stdout >> getLine

showToast :: (MonadUnliftIO m, MonadReader ChatController m) => Text -> Text -> m ()
showToast title text = atomically . (`writeTBQueue` Notification {title, text}) =<< asks notifyQ

notificationSubscriber :: (MonadUnliftIO m, MonadReader ChatController m) => m ()
notificationSubscriber = do
  ChatController {notifyQ, sendNotification} <- ask
  forever $ atomically (readTBQueue notifyQ) >>= liftIO . sendNotification

withAgent :: ChatMonad m => (AgentClient -> ExceptT AgentErrorType m a) -> m a
withAgent action =
  asks smpAgent
    >>= runExceptT . action
    >>= liftEither . first ChatErrorAgent

withStore ::
  ChatMonad m =>
  (forall m'. (MonadUnliftIO m', MonadError StoreError m') => SQLiteStore -> m' a) ->
  m a
withStore action =
  asks chatStore
    >>= runExceptT . action
    >>= liftEither . first ChatErrorStore

chatCommandP :: Parser ChatCommand
chatCommandP =
  "/api/v1/chats" $> APIGetChats
    <|> "/api/v1/chat/" *> (APIGetChat <$> ("direct/" $> CTDirect <|> "group/" $> CTGroup) <*> A.decimal)
    <|> "/api/v1/chat/items?count=" *> (APIGetChatItems <$> A.decimal)
    <|> ("/help files" <|> "/help file" <|> "/hf") $> ChatHelp HSFiles
    <|> ("/help groups" <|> "/help group" <|> "/hg") $> ChatHelp HSGroups
    <|> ("/help address" <|> "/ha") $> ChatHelp HSMyAddress
    <|> ("/help" <|> "/h") $> ChatHelp HSMain
    <|> ("/group #" <|> "/group " <|> "/g #" <|> "/g ") *> (NewGroup <$> groupProfile)
    <|> ("/add #" <|> "/add " <|> "/a #" <|> "/a ") *> (AddMember <$> displayName <* A.space <*> displayName <*> memberRole)
    <|> ("/join #" <|> "/join " <|> "/j #" <|> "/j ") *> (JoinGroup <$> displayName)
    <|> ("/remove #" <|> "/remove " <|> "/rm #" <|> "/rm ") *> (RemoveMember <$> displayName <* A.space <*> displayName)
    <|> ("/leave #" <|> "/leave " <|> "/l #" <|> "/l ") *> (LeaveGroup <$> displayName)
    <|> ("/delete #" <|> "/d #") *> (DeleteGroup <$> displayName)
    <|> ("/members #" <|> "/members " <|> "/ms #" <|> "/ms ") *> (ListMembers <$> displayName)
    <|> ("/groups" <|> "/gs") $> ListGroups
    <|> A.char '#' *> (SendGroupMessage <$> displayName <* A.space <*> A.takeByteString)
    <|> ("/contacts" <|> "/cs") $> ListContacts
    <|> ("/connect " <|> "/c ") *> (Connect <$> ((Just <$> strP) <|> A.takeByteString $> Nothing))
    <|> ("/connect" <|> "/c") $> AddContact
    <|> ("/delete @" <|> "/delete " <|> "/d @" <|> "/d ") *> (DeleteContact <$> displayName)
    <|> A.char '@' *> (SendMessage <$> displayName <*> (A.space *> A.takeByteString))
    <|> ("/file #" <|> "/f #") *> (SendGroupFile <$> displayName <* A.space <*> filePath)
    <|> ("/file @" <|> "/file " <|> "/f @" <|> "/f ") *> (SendFile <$> displayName <* A.space <*> filePath)
    <|> ("/freceive " <|> "/fr ") *> (ReceiveFile <$> A.decimal <*> optional (A.space *> filePath))
    <|> ("/fcancel " <|> "/fc ") *> (CancelFile <$> A.decimal)
    <|> ("/fstatus " <|> "/fs ") *> (FileStatus <$> A.decimal)
    <|> "/simplex" $> ConnectAdmin
    <|> ("/address" <|> "/ad") $> CreateMyAddress
    <|> ("/delete_address" <|> "/da") $> DeleteMyAddress
    <|> ("/show_address" <|> "/sa") $> ShowMyAddress
    <|> ("/accept @" <|> "/accept " <|> "/ac @" <|> "/ac ") *> (AcceptContact <$> displayName)
    <|> ("/reject @" <|> "/reject " <|> "/rc @" <|> "/rc ") *> (RejectContact <$> displayName)
    <|> ("/markdown" <|> "/m") $> ChatHelp HSMarkdown
    <|> ("/welcome" <|> "/w") $> Welcome
    <|> ("/profile " <|> "/p ") *> (UpdateProfile <$> userProfile)
    <|> ("/profile" <|> "/p") $> ShowProfile
    <|> ("/quit" <|> "/q" <|> "/exit") $> QuitChat
    <|> ("/version" <|> "/v") $> ShowVersion
  where
    displayName = safeDecodeUtf8 <$> (B.cons <$> A.satisfy refChar <*> A.takeTill (== ' '))
    refChar c = c > ' ' && c /= '#' && c /= '@'
    userProfile = do
      cName <- displayName
      fullName <- fullNameP cName
      pure Profile {displayName = cName, fullName}
    groupProfile = do
      gName <- displayName
      fullName <- fullNameP gName
      pure GroupProfile {displayName = gName, fullName}
    fullNameP name = do
      n <- (A.space *> A.takeByteString) <|> pure ""
      pure $ if B.null n then name else safeDecodeUtf8 n
    filePath = T.unpack . safeDecodeUtf8 <$> A.takeByteString
    memberRole =
      (" owner" $> GROwner)
        <|> (" admin" $> GRAdmin)
        <|> (" member" $> GRMember)
        <|> pure GRAdmin

adminContactReq :: ConnReqContact
adminContactReq =
  either error id $ strDecode "https://simplex.chat/contact#/?v=1&smp=smp%3A%2F%2FPQUV2eL0t7OStZOoAsPEV2QYWt4-xilbakvGUGOItUo%3D%40smp6.simplex.im%2FK1rslx-m5bpXVIdMZg9NLUZ_8JBm8xTt%23MCowBQYDK2VuAyEALDeVe-sG8mRY22LsXlPgiwTNs9dbiLrNuA7f3ZMAJ2w%3D"
