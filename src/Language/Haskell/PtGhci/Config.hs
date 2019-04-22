{-# LANGUAGE TemplateHaskell #-}

module Language.Haskell.PtGhci.Config where
  
import Language.Haskell.PtGhci.Prelude
import Lens.Micro.TH
import Text.Printf
import Data.Aeson
import System.Directory
import System.FilePath
import Data.Yaml (decodeFileEither, prettyPrintParseException)
import qualified Data.Aeson.Types    as A (Options (..), Parser)
import Language.Haskell.PtGhci.Exception

data Verbosity = Critical | Error | Warn | Info | Debug | Trace
  deriving (Enum, Eq, Ord, Show, Generic)
instance FromJSON Verbosity

data Config = Config
  { _verbosity :: Maybe Verbosity
  , _logFile :: Maybe FilePath
  , _webBrowser :: Maybe Text
  , _ghciCommand :: Maybe Text
  } deriving (Show, Generic)
makeLenses ''Config

instance FromJSON Config where
    parseJSON = dropOneAndParse

-- | Drop the first character (leading underscore) from the field names
dropOneAndParse :: (Generic a, GFromJSON Zero (Rep a)) => Value -> A.Parser a
dropOneAndParse = genericParseJSON opts
  where
    opts = defaultOptions {A.fieldLabelModifier = drop 1}

defaultConfig = Config (Just Debug) (Just "log.txt") Nothing Nothing

loadConfig :: FilePath -> IO Config
loadConfig path = do
  eitherConfig <- decodeFileEither path
  case eitherConfig of
    Left ex -> throwIO $ ConfigurationError $ toS
      (printf "Error parsing configuration file %s: %s"
             path (prettyPrintParseException ex) :: String)
    Right c -> return c

findConfigLocation :: IO (Maybe FilePath)
findConfigLocation = do
  homeDir <- getHomeDirectory
  p1 <- checkPath "ptghci.yaml"
  p2 <- checkPath ".ptghci.yaml"
  p3 <- checkPath $ homeDir </> ".ptghci.yaml"
  return $ p1 <|> p2 <|> p3
  where
    checkPath :: FilePath -> IO (Maybe FilePath)
    checkPath p = do
      b <- doesFileExist p
      return $ if b then Just p else Nothing

