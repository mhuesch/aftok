{-# LANGUAGE TemplateHaskell #-}

module Aftok.Project
  ( Project (..),
    ProjectName,
    projectName,
    inceptionDate,
    initiator,
    depRules,
    EventSource (..),
    eventSource,
    InvitationCode,
    randomInvCode,
    parseInvCode,
    renderInvCode,
    Invitation (..),
    projectId,
    invitingUser,
    invitedEmail,
    invitationTime,
    acceptanceTime,
  )
where

import qualified Aftok.Currency.Zcash as Z
import Aftok.Types
import Control.Lens
  ( makeLenses,
    makePrisms,
  )
import Crypto.Random.Types
  ( MonadRandom,
    getRandomBytes,
  )
import qualified Data.ByteString.Base64.URL as B64
import qualified Data.Thyme.Clock as C

type ProjectName = Text

data EventSource
  = UI
  | ZcashMemo Z.IVK
  deriving (Eq, Show)

data Project = Project
  { _projectName :: ProjectName,
    _inceptionDate :: C.UTCTime,
    _initiator :: UserId,
    _depRules :: DepreciationRules,
    _eventSource :: EventSource
  }

makeLenses ''Project

newtype InvitationCode = InvitationCode ByteString deriving (Eq)

makePrisms ''InvitationCode

randomInvCode :: (MonadRandom m) => m InvitationCode
randomInvCode = InvitationCode <$> getRandomBytes 12

parseInvCode :: Text -> Either Text InvitationCode
parseInvCode t =
  InvitationCode <$> (B64.decodeBase64 . encodeUtf8 $ t)

renderInvCode :: InvitationCode -> Text
renderInvCode (InvitationCode bs) = B64.encodeBase64Unpadded bs

data Invitation = Invitation
  { _projectId :: ProjectId,
    _invitingUser :: UserId,
    _invitedEmail :: Email,
    _invitationTime :: C.UTCTime,
    _acceptanceTime :: Maybe C.UTCTime
  }

makeLenses ''Invitation
