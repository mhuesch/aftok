{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Aftok.Database.PostgreSQL (QDBM(), runQDBM) where

import           ClassyPrelude
import           Control.Lens
import           Control.Monad.Trans.Either
import           Data.Aeson                           (toJSON)
import qualified Data.ByteString.Char8                as B
import           Data.Hourglass
import           Data.List                            as L
import           Data.Thyme.Clock                     as C
import           Data.Thyme.Time
import           Data.UUID                            (UUID)
import           Database.PostgreSQL.Simple
import           Database.PostgreSQL.Simple.FromField
import           Database.PostgreSQL.Simple.FromRow
import           Database.PostgreSQL.Simple.Types     (Null)

import           Aftok
import           Aftok.Auction                        as A
import           Aftok.Database
import           Aftok.Interval
import           Aftok.Project                        as P
import           Aftok.TimeLog
import           Aftok.Types

newtype QDBM a = QDBM (ReaderT Connection (EitherT DBError IO) a)
  deriving (Functor, Applicative, Monad)

instance MonadIO QDBM where
  liftIO = QDBM . lift . lift

runQDBM :: Connection -> QDBM a -> EitherT DBError IO a
runQDBM conn (QDBM r) = runReaderT r conn

uidParser :: FieldParser UserId
uidParser f v = UserId <$> fromField f v

pidParser :: FieldParser ProjectId
pidParser f v = ProjectId <$> fromField f v

secondsParser :: FieldParser Seconds
secondsParser f v = Seconds <$> fromField f v

usernameParser :: FieldParser UserName
usernameParser f v = UserName <$> fromField f v

emailParser :: FieldParser Email
emailParser f v = Email <$> fromField f v

btcAddrParser :: FieldParser BtcAddr
btcAddrParser f v = BtcAddr <$> fromField f v

btcParser :: FieldParser Satoshi
btcParser f v = (Satoshi . fromInteger) <$> fromField f v

utcParser :: FieldParser C.UTCTime
utcParser f v = toThyme <$> fromField f v

nullField :: RowParser Null
nullField = field

eventTypeParser :: FieldParser (C.UTCTime -> LogEvent)
eventTypeParser f v = do
  tn <- typename f
  case tn of
    "event_t" ->
      let err = UnexpectedNull (B.unpack tn)
                               (tableOid f)
                               (maybe "" B.unpack (name f))
                               "UTCTime -> LogEvent"
                               "columns of type event_t should not contain null values"
      in  maybe (conversionError err) (nameEvent . decodeUtf8) v
    _ ->
      let err = Incompatible (B.unpack tn)
                             (tableOid f)
                             (maybe "" B.unpack (name f))
                             "UTCTime -> LogEvent"
                             "column was not of type event_t"
      in conversionError err

creditToParser :: FieldParser (RowParser CreditTo)
creditToParser f v = do
  tn <- typename f
  let parser :: Text -> Conversion (RowParser CreditTo)
      parser tname = pure $ case tname of
        "credit_to_btc_addr" -> CreditToAddress <$> (fieldWith btcAddrParser <* nullField <* nullField)
        "credit_to_user"     -> CreditToUser    <$> (nullField *> fieldWith uidParser <* nullField)
        "credit_to_project"  -> CreditToProject <$> (nullField *> nullField *> fieldWith pidParser)
        _ -> empty

  case tn of
    "credit_to_t" -> maybe empty (parser . decodeUtf8) v
    _ -> conversionError $
      Incompatible
        (B.unpack tn)
        (tableOid f)
        (maybe "" B.unpack (name f))
        "RowParser CreditTo"
        "column was not of type event_t"



logEntryParser :: RowParser LogEntry
logEntryParser =
  LogEntry <$> join (fieldWith creditToParser)
           <*> (fieldWith eventTypeParser <*> fieldWith utcParser)
           <*> field

qdbLogEntryParser :: RowParser KeyedLogEntry
qdbLogEntryParser =
  (,,) <$> fieldWith pidParser
       <*> fieldWith uidParser
       <*> logEntryParser

auctionParser :: RowParser Auction
auctionParser =
  Auction <$> fieldWith pidParser
          <*> fieldWith uidParser
          <*> fieldWith utcParser
          <*> fieldWith btcParser
          <*> fieldWith utcParser
          <*> fieldWith utcParser

bidParser :: RowParser Bid
bidParser =
  Bid <$> fieldWith uidParser
      <*> fieldWith secondsParser
      <*> fieldWith btcParser
      <*> fieldWith utcParser

userParser :: RowParser User
userParser =
  User <$> fieldWith usernameParser
       <*> fieldWith btcAddrParser
       <*> (Email <$> field)

qdbUserParser :: RowParser KeyedUser
qdbUserParser =
  (,) <$> fieldWith uidParser
      <*> userParser

projectParser :: RowParser Project
projectParser =
  Project <$> field
          <*> fieldWith utcParser
          <*> fieldWith uidParser
          <*> fieldWith fromJSONField

invitationParser :: RowParser Invitation
invitationParser =
  Invitation <$> fieldWith pidParser
             <*> fieldWith uidParser
             <*> fieldWith emailParser
             <*> fieldWith utcParser
             <*> fmap (fmap toThyme) field

qdbProjectParser :: RowParser KeyedProject
qdbProjectParser =
  (,) <$> fieldWith pidParser
      <*> projectParser

pexec :: (ToRow d) => Query -> d -> QDBM Int64
pexec q d = QDBM $ do
  conn <- ask
  lift . lift $ execute conn q d

pinsert :: (ToRow d) => (UUID -> r) -> Query -> d -> QDBM r
pinsert f q d = QDBM $ do
  conn <- ask
  ids  <- lift . lift $ query conn q d
  pure . f . fromOnly $ L.head ids

pquery :: (ToRow d) => RowParser r -> Query -> d -> QDBM [r]
pquery p q d = QDBM $ do
  conn <- ask
  lift . lift $ queryWith p conn q d

transactQDBM :: QDBM a -> QDBM a
transactQDBM (QDBM rt) = QDBM $ do
  conn <- ask
  lift . EitherT $ withTransaction conn (runEitherT $ runReaderT rt conn)

instance DBEval QDBM where
  dbEval (CreateEvent (ProjectId pid) (UserId uid) (LogEntry c e m)) =
    case c of
      CreditToAddress addr ->
        pinsert EventId
          "INSERT INTO work_events \
          \(project_id, user_id, credit_to_type, credit_to_btc_addr, event_type, event_time, event_metadata) \
          \VALUES (?, ?, ?, ?, ?, ?, ?) \
          \RETURNING id"
          ( pid, uid, creditToName c, addr ^. _BtcAddr, eventName e, fromThyme $ e ^. eventTime, m)

      CreditToProject pid' ->
        pinsert EventId
          "INSERT INTO work_events \
          \(project_id, user_id, credit_to_type, credit_to_project_id, event_type, event_time, event_metadata) \
          \VALUES (?, ?, ?, ?, ?, ?, ?) \
          \RETURNING id"
          ( pid, uid, creditToName c, pid' ^. _ProjectId, eventName e, fromThyme $ e ^. eventTime, m)

      CreditToUser uid' ->
        pinsert EventId
          "INSERT INTO work_events \
          \(project_id, user_id, credit_to_type, credit_to_user_id, event_type, event_time, event_metadata) \
          \VALUES (?, ?, ?, ?, ?, ?, ?) \
          \RETURNING id"
          ( pid, uid, creditToName c, uid' ^. _UserId, eventName e, fromThyme $ e ^. eventTime, m)

  dbEval (FindEvent (EventId eid)) =
    headMay <$> pquery qdbLogEntryParser
      "SELECT project_id, user_id, \
      \credit_to_type, credit_to_btc_addr, credit_to_user_id, credit_to_project_id, \
      \event_type, event_time, event_metadata FROM work_events \
      \WHERE id = ?"
      (Only eid)

  dbEval (FindEvents (ProjectId pid) (UserId uid) ival) =
    let q (Before e) = pquery logEntryParser
          "SELECT btc_addr, event_type, event_time, event_metadata FROM work_events \
          \WHERE project_id = ? AND user_id = ? AND event_time <= ?"
          (pid, uid, fromThyme e)
        q (During s e) = pquery logEntryParser
          "SELECT btc_addr, event_type, event_time, event_metadata FROM work_events \
          \WHERE project_id = ? AND user_id = ? \
          \AND event_time >= ? AND event_time <= ?"
          (pid, uid, fromThyme s, fromThyme e)
        q (After s) = pquery logEntryParser
          "SELECT btc_addr, event_type, event_time, event_metadata FROM work_events \
          \WHERE project_id = ? AND user_id = ? AND event_time >= ?"
          (pid, uid, fromThyme s)
    in  q ival

  dbEval (AmendEvent (EventId eid) (TimeChange mt t)) =
    pinsert AmendmentId
      "INSERT INTO event_time_amendments \
      \(event_id, amended_at, event_time) \
      \VALUES (?, ?, ?) RETURNING id"
      ( eid, fromThyme $ mt ^. _ModTime, fromThyme t )

  dbEval (AmendEvent (EventId eid) (CreditToChange mt c)) =
    case c of
      CreditToAddress addr ->
        pinsert AmendmentId
          "INSERT INTO event_credit_to_amendments \
          \(event_id, amended_at, credit_to_type, credit_to_btc_addr) \
          \VALUES (?, ?, ?, ?) RETURNING id"
          ( eid, fromThyme $ mt ^. _ModTime, creditToName c, addr ^. _BtcAddr )

      CreditToProject pid ->
        pinsert AmendmentId
          "INSERT INTO event_credit_to_amendments \
          \(event_id, amended_at, credit_to_type, credit_to_project_id) \
          \VALUES (?, ?, ?, ?) RETURNING id"
          ( eid, fromThyme $ mt ^. _ModTime, creditToName c, pid ^. _ProjectId )

      CreditToUser uid ->
        pinsert AmendmentId
          "INSERT INTO event_credit_to_amendments \
          \(event_id, amended_at, credit_to_type, credit_to_user_id) \
          \VALUES (?, ?, ?, ?) RETURNING id"
          ( eid, fromThyme $ mt ^. _ModTime, creditToName c, uid ^. _UserId )

  dbEval (AmendEvent (EventId eid) (MetadataChange mt v)) =
    pinsert AmendmentId
      "INSERT INTO event_metadata_amendments \
      \(event_id, amended_at, event_metadata) \
      \VALUES (?, ?, ?) RETURNING id"
      ( eid, fromThyme $ mt ^. _ModTime, v)

  dbEval (ReadWorkIndex (ProjectId pid)) = do
    logEntries <- pquery logEntryParser
      "SELECT btc_addr, event_type, event_time, event_metadata FROM work_events WHERE project_id = ?"
      (Only pid)
    pure $ workIndex logEntries

  dbEval (CreateAuction auc) =
    pinsert AuctionId
      "INSERT INTO auctions (project_id, user_id, raise_amount, end_time) \
      \VALUES (?, ?, ?, ?) RETURNING id"
      ( auc ^. (A.projectId . _ProjectId)
      , auc ^. (A.initiator . _UserId)
      , auc ^. (raiseAmount.to fromSatoshi)
      , auc ^. (auctionEnd.to fromThyme)
      )

  dbEval (FindAuction aucId) =
    headMay <$> pquery auctionParser
      "SELECT project_id, initiator_id, created_at, raise_amount, start_time, end_time FROM auctions WHERE id = ?"
      (Only (aucId ^. _AuctionId))

  dbEval (CreateBid (AuctionId aucId) bid) =
    pinsert BidId
      "INSERT INTO bids (auction_id, bidder_id, bid_seconds, bid_amount, bid_time) \
      \VALUES (?, ?, ?, ?, ?) RETURNING id"
      ( aucId
      , bid ^. (bidUser._UserId)
      , case bid ^. bidSeconds of (Seconds i) -> i
      , bid ^. (bidAmount.to fromSatoshi)
      , bid ^. (bidTime.to fromThyme)
      )

  dbEval (ReadBids aucId) =
    pquery bidParser
      "SELECT user_id, bid_seconds, bid_amount, bid_time FROM bids WHERE auction_id = ?"
      (Only (aucId ^. _AuctionId))

  dbEval (CreateUser user') =
    pinsert UserId
      "INSERT INTO users (handle, btc_addr, email) VALUES (?, ?, ?) RETURNING id"
      (user' ^. (username._UserName), user' ^. (userAddress._BtcAddr), user' ^. userEmail._Email)

  dbEval (FindUser (UserId uid)) =
    headMay <$> pquery userParser
      "SELECT handle, btc_addr, email FROM users WHERE id = ?"
      (Only uid)

  dbEval (FindUserByName (UserName h)) =
    headMay <$> pquery qdbUserParser
      "SELECT id, handle, btc_addr, email FROM users WHERE handle = ?"
      (Only h)

  dbEval (CreateInvitation (ProjectId pid) (UserId uid) (Email e) t) = do
    invCode <- liftIO randomInvCode
    void $ pexec
      "INSERT INTO invitations (project_id, invitor_id, invitee_email, invitation_key, invitation_time) \
      \VALUES (?, ?, ?, ?, ?)"
      (pid, uid, e, renderInvCode invCode, fromThyme t)
    pure invCode

  dbEval (FindInvitation ic) =
    headMay <$> pquery invitationParser
      "SELECT project_id, invitor_id, invitee_email, invitation_time, acceptance_time \
      \FROM invitations WHERE invitation_key = ?"
      (Only $ renderInvCode ic)

  dbEval (AcceptInvitation (UserId uid) ic t) = transactQDBM $ do
    void $ pexec
      "UPDATE invitations SET acceptance_time = ? WHERE invitation_key = ?"
      (fromThyme t, renderInvCode ic)
    void $ pexec
      "INSERT INTO project_companions (project_id, user_id, invited_by, joined_at) \
      \SELECT i.project_id, ?, i.invitor_id, ? \
      \FROM invitations i \
      \WHERE i.invitation_key = ?"
      (uid, fromThyme t, renderInvCode ic)

  dbEval (CreateProject p) =
    pinsert ProjectId
      "INSERT INTO projects (project_name, inception_date, initiator_id, depreciation_fn) \
      \VALUES (?, ?, ?, ?) RETURNING id"
      (p ^. projectName, p ^. (inceptionDate.to fromThyme), p ^. (P.initiator . _UserId), toJSON $ p ^. depf)

  dbEval (FindProject (ProjectId pid)) =
    headMay <$> pquery projectParser
      "SELECT project_name, inception_date, initiator_id, depreciation_fn FROM projects WHERE id = ?"
      (Only pid)

  dbEval (FindUserProjects (UserId uid)) =
    pquery qdbProjectParser
      "SELECT p.id, p.project_name, p.inception_date, p.initiator_id, p.depreciation_fn \
      \FROM projects p LEFT OUTER JOIN project_companions pc ON pc.project_id = p.id \
      \WHERE pc.user_id = ? \
      \OR p.initiator_id = ?"
      (uid, uid)

  dbEval (AddUserToProject pid current new) = void $
    pexec
      "INSERT INTO project_companions (project_id, user_id, invited_by) VALUES (?, ?, ?)"
      (pid ^. _ProjectId, new ^. _UserId, current ^. _UserId)

  dbEval (RaiseDBError err _) = QDBM . lift $ left err
