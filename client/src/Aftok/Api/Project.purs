module Aftok.Api.Project where

import Prelude
import Control.Monad.Except.Trans (ExceptT, runExceptT)
-- import Control.Monad.Except.Trans (ExceptT, runExceptT, except, withExceptT)
-- import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core (Json, fromString, jsonEmptyObject)
import Data.Argonaut.Decode (class DecodeJson, JsonDecodeError(..), decodeJson, (.:), (.:?))
import Data.Argonaut.Encode (encodeJson, (:=), (~>))
import Data.DateTime (DateTime)
import Data.DateTime.Instant (Instant, toDateTime)
import Data.Either (Either(..))
import Data.Foldable (class Foldable, foldr, foldl, foldMapDefaultR)
import Data.Functor.Compose (Compose(..))
import Data.Map as M
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap)
import Data.Ratio (Ratio, (%))
import Data.Time.Duration (Hours(..), Days(..))
import Data.Tuple (Tuple(..))
import Data.Traversable (class Traversable, traverse)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class as EC
import Foreign.Object (Object)
import Affjax (get, post)
import Affjax.ResponseFormat as RF
import Affjax.RequestBody as RB
import Aftok.Types
  ( UserId
  , ProjectId
  , pidStr
  )
import Aftok.Api.Types
  ( APIError
  , CommsAddress(..)
  , Zip321Request(..)
  )
import Aftok.Api.Json
  ( Decode
  , decompose
  , parseResponse
  , parseDatedResponse
  , parseDatedResponseMay
  )

data DepreciationFn = LinearDepreciation { undep :: Days, dep :: Days }

instance decodeDepreciationFn :: DecodeJson DepreciationFn where
  decodeJson json = do
    x <- decodeJson json
    dtype <- x .: "type"
    args <- x .: "arguments"
    case dtype of
      "LinearDepreciation" -> do
        undep <- Days <$> args .: "undep"
        dep <- Days <$> args .: "dep"
        pure $ LinearDepreciation { undep, dep }
      other -> Left $ UnexpectedValue (fromString dtype)

newtype Project' date = Project'
  { projectId :: ProjectId
  , projectName :: String
  , inceptionDate :: date
  , initiator :: UserId
  , depf :: DepreciationFn
  }

derive instance projectNewtype :: Newtype (Project' a) _

derive instance projectFunctor :: Functor Project'

instance projectFoldable :: Foldable Project' where
  foldr f b (Project' p) = f (p.inceptionDate) b
  foldl f b (Project' p) = f b (p.inceptionDate)
  foldMap = foldMapDefaultR

instance projectTraversable :: Traversable Project' where
  traverse f (Project' p) = Project' <<< (\b -> p { inceptionDate = b }) <$> f (p.inceptionDate)
  sequence = traverse identity

type Project = Project' DateTime

parseProject :: ProjectId -> Object Json -> Either JsonDecodeError (Project' String)
parseProject projectId pjson = do
  projectName <- pjson .: "projectName"
  inceptionDate <- pjson .: "inceptionDate"
  initiator <- pjson .: "initiator"
  depf <- pjson .: "depf"
  pure $ Project' { projectId, projectName, inceptionDate, initiator, depf }

instance decodeJsonProject :: DecodeJson (Project' String) where
  decodeJson json = do
    x <- decodeJson json
    pjson <- x .: "project"
    projectId <- x .: "projectId"
    parseProject projectId pjson

newtype Contributor' date = Contributor'
  { userId :: UserId
  , handle :: String
  , joinedOn :: date
  , loggedHours :: Hours
  , depreciatedHours :: Hours
  , revShare :: Ratio Number
  }

derive instance contributorNewtype :: Newtype (Contributor' a) _

derive instance contributorFunctor :: Functor Contributor'

instance contributorFoldable :: Foldable Contributor' where
  foldr f b (Contributor' p) = f (p.joinedOn) b
  foldl f b (Contributor' p) = f b (p.joinedOn)
  foldMap = foldMapDefaultR

instance contributorTraversable :: Traversable Contributor' where
  traverse f (Contributor' p) = Contributor' <<< (\b -> p { joinedOn = b }) <$> f (p.joinedOn)
  sequence = traverse identity

instance decodeJsonContributor :: DecodeJson (Contributor' String) where
  decodeJson json = do
    x <- decodeJson json
    userId <- x .: "userId"
    handle <- x .: "username"
    joinedOn <- x .: "joinedOn"
    loggedHours <- Hours <$> x .: "loggedHours"
    depreciatedHours <- Hours <$> x .: "depreciatedHours"
    revShareObj <- x .: "revenureShare"
    num <- revShareObj .: "numerator"
    den <- revShareObj .: "denominator"
    let
      revShare = num % den
    pure $ Contributor' { userId, handle, joinedOn, loggedHours, depreciatedHours, revShare }

newtype ProjectDetail' date = ProjectDetail'
  { project :: Project' date
  , contributors :: M.Map UserId (Contributor' date)
  }

projectDetail
  :: forall date
   . Project' date
  -> M.Map UserId (Contributor' date)
  -> ProjectDetail' date
projectDetail project contributors = ProjectDetail' { project, contributors }

type ProjectDetail = ProjectDetail' DateTime

derive instance projectDetailNewtype :: Newtype (ProjectDetail' a) _

derive instance projectDetailFunctor :: Functor ProjectDetail'

instance projectDetailFoldable :: Foldable ProjectDetail' where
  foldr f b (ProjectDetail' p) = foldr f (foldr f b (p.project)) (Compose p.contributors)
  foldl f b (ProjectDetail' p) = foldl f (foldl f b (p.project)) (Compose p.contributors)
  foldMap = foldMapDefaultR

instance projectDetailTraversable :: Traversable ProjectDetail' where
  traverse f (ProjectDetail' p) =
    projectDetail <$> traverse f p.project
      <*> (map unwrap $ traverse f (Compose p.contributors))
  sequence = traverse identity

parseProjectDetail :: ProjectId -> Decode (ProjectDetail' String)
parseProjectDetail pid json = do
  x <- decodeJson json
  project <- parseProject pid =<< x .: "project"
  (contribList :: Array (Contributor' String)) <- x .: "contributors"
  let
    contributors = M.fromFoldable $ map (\c@(Contributor' xs) -> Tuple xs.userId c) contribList
  pure $ ProjectDetail' { project, contributors }

listProjects :: Aff (Either APIError (Array Project))
listProjects = do
  response <- get RF.json "/api/projects"
  EC.liftEffect
    <<< runExceptT
    <<< map decompose
    <<< map (map toDateTime)
    $ parseDatedResponse decodeJson response

getProjectDetail :: ProjectId -> Aff (Either APIError (Maybe ProjectDetail))
getProjectDetail pid = do
  response <- get RF.json ("/api/projects/" <> pidStr pid <> "/detail")
  let
    parsed :: ExceptT APIError Effect (Maybe (ProjectDetail' Instant))
    parsed = parseDatedResponseMay (parseProjectDetail pid) response
  EC.liftEffect
    <<< runExceptT
    <<< map (map (map toDateTime))
    $ parsed

encodeInviteBy :: CommsAddress -> Json
encodeInviteBy = case _ of
  EmailCommsAddr email -> encodeJson ({ email: email })
  ZcashCommsAddr zaddr -> encodeJson ({ zaddr: zaddr })

type Invitation' by =
  { greetName :: String
  , message :: Maybe String
  , inviteBy :: by
  }

type Invitation = Invitation' CommsAddress

encodeInvitation :: Invitation' Json -> Json
encodeInvitation = encodeJson

type InvResult =
  { zip321_request :: Maybe String
  }

decodeInvResult :: Json -> Either JsonDecodeError InvResult
decodeInvResult json = do
  x <- decodeJson json
  zip321_request <- x .:? "zip321_request"
  pure $ { zip321_request: zip321_request }

invite :: ProjectId -> Invitation -> Aff (Either APIError (Maybe Zip321Request))
invite pid inv = do
  let inv' = inv { inviteBy = encodeInviteBy inv.inviteBy }
  let body = RB.json $ encodeInvitation inv'
  response <- post RF.json ("/api/projects/" <> pidStr pid <> "/invite") (Just body)
  map (\r -> Zip321Request <$> r.zip321_request) <$> parseResponse decodeInvResult response

type ProjectCreateRequest =
  { projectName :: String
  , depf :: DepreciationFn
  }

encodeProjectCreateRequest :: ProjectCreateRequest -> Json
encodeProjectCreateRequest pc =
  "projectName" := pc.projectName
    ~> "depf" :=
      ( case pc.depf of
          LinearDepreciation vs ->
            encodeJson
              { "type": "LinearDepreciation"
              , "arguments": { "undep": unwrap vs.undep, dep: unwrap vs.dep }
              }
      )
    ~> jsonEmptyObject

decodeProjectId :: Json -> Either JsonDecodeError ProjectId
decodeProjectId json = (_ .: "projectId") =<< decodeJson json

createProject :: ProjectCreateRequest -> Aff (Either APIError ProjectId)
createProject pc = do
  let body = RB.json $ encodeProjectCreateRequest pc
  response <- post RF.json "/api/projects/" (Just body)
  parseResponse decodeProjectId response
