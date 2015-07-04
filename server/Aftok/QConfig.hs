module Aftok.QConfig where

import ClassyPrelude 

import qualified Data.ByteString.Char8 as C
import qualified Data.Configurator as C
import qualified Data.Configurator.Types as CT
import qualified Network.Sendgrid.Api as Sendgrid
import System.Environment
import System.IO (FilePath)

import Snap.Core
import Snap.Snaplet.PostgresqlSimple
import qualified Snap.Http.Server.Config as SC

data QConfig = QConfig
  { hostname :: ByteString
  , port :: Int
  , authSiteKey :: System.IO.FilePath
  , cookieTimeout :: Maybe Int
  , pgsConfig :: PGSConfig
  , sendgridAuth :: Sendgrid.Authentication
  , templatePath :: System.IO.FilePath
  } 

loadQConfig :: System.IO.FilePath -> IO QConfig
loadQConfig cfgFile = do 
  env <- getEnvironment
  cfg <- C.load [C.Required cfgFile] 
  let dbEnvCfg = pgsDefaultConfig . C.pack <$> lookup "DATABASE_URL" env
  readQConfig cfg dbEnvCfg

readQConfig :: CT.Config -> Maybe PGSConfig -> IO QConfig
readQConfig cfg pc = 
  QConfig <$> C.lookupDefault "localhost" cfg "hostname"
          <*> C.lookupDefault 8000 cfg "port" 
          <*> C.require cfg "siteKey"
          <*> C.lookup cfg "cookieTimeout" 
          <*> maybe (mkPGSConfig $ C.subconfig "db" cfg) pure pc
          <*> readSendgridAuth cfg
          <*> C.lookupDefault "/opt/aftok/server/templates/" cfg "templatePath"

readSendgridAuth :: CT.Config -> IO Sendgrid.Authentication
readSendgridAuth cfg = 
  Sendgrid.Authentication <$> C.require cfg "sendgridUser"
                          <*> C.require cfg "sendgridKey"

baseSnapConfig :: MonadSnap m => QConfig -> SC.Config m a -> SC.Config m a
baseSnapConfig qc = 
  SC.setHostname (hostname qc) . 
  SC.setPort (port qc) 

-- configuration specific to Snap, commandLineConfig arguments override
-- config file.
snapConfig :: QConfig -> IO (SC.Config Snap a)
snapConfig qc = SC.commandLineConfig $ baseSnapConfig qc SC.emptyConfig

