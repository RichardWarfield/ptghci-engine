{-# LANGUAGE QuasiQuotes #-}

module Language.Haskell.PtGhci.Engine where

import Language.Haskell.PtGhci.Prelude hiding (Rep)

import Control.Monad
import Control.Exception (try, AsyncException(..))
import Text.Printf
import GHC.Base as Base 
import Data.IORef
import Data.Maybe
import System.ZMQ4
import System.Environment (getArgs)
import Data.Aeson
import Control.Concurrent.MVar
import qualified Debug.Trace as Debug
import GHC.Generics hiding (Rep)
import Control.Concurrent.Async
import Language.Haskell.PtGhci.Ghci-- hiding (Error)
import Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
-- import System.Posix.Process (joinProcessGroup)
import System.Process
import System.Directory (findExecutable)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import Text.Regex.PCRE.Heavy
import System.Console.CmdArgs.Verbosity
import Language.Haskell.PtGhci.PtgRequest as PtgRequest
import Language.Haskell.PtGhci.PtgResponse as PtgResponse
import Language.Haskell.PtGhci.Doc
import Language.Haskell.PtGhci.Exception
import Language.Haskell.PtGhci.Env
import Language.Haskell.PtGhci.Log


data Sockets = Sockets 
  { requestSock :: Socket Rep
  , controlSock :: Socket Pair
  , stdoutSock :: Socket Pub
  , stderrSock :: Socket Pub 
  }

setupSockets :: IO Sockets
setupSockets = do
  ctx <- context
  requester <- socket ctx Rep
  controlSock <- socket ctx Pair
  stdoutSock <- socket ctx Pub
  stderrSock <- socket ctx Pub
  bind requester "tcp://127.0.0.1:*"
  bind controlSock "tcp://127.0.0.1:*"
  bind stdoutSock "tcp://127.0.0.1:*"
  bind stderrSock "tcp://127.0.0.1:*"
  return $ Sockets requester controlSock stdoutSock stderrSock

socketEndpoints :: Sockets -> IO (String, String, String, String)
socketEndpoints Sockets{..} = (,,,) <$> lastEndpoint requestSock
                                    <*> lastEndpoint controlSock
                                    <*> lastEndpoint stdoutSock
                                    <*> lastEndpoint stderrSock

-- | Main entry point for the Haskell end of ptGHCi.  Returns a thread in which
-- the main loop runs, and an IO action that will cause the loop to terminate.
runApp :: Sockets -> IO (Async (), IO ())
runApp sockets = do
  configPath <- findConfigLocation
  config <- case configPath of
               Just p -> loadConfig p
               Nothing -> return defaultConfig
  when (config ^. verbosity >= Just Trace) $ setVerbosity Loud

  -- This keeps interrupt signal from the parent (python) process from messing
  -- up our executions. TODO this won't work on Windows -- do I need it?
  -- joinProcessGroup 0

  promptFlag <- newEmptyMVar :: IO (MVar ())
  let sendOutput stream val =
        case stream of
          -- TODO -- double conversion inefficient
          Stdout ->
            send (stdoutSock sockets) [] $ toS (stripInternalGhcid $ toS val)
          Stderr -> send (stderrSock sockets) [] $ toS (stripInternalGhcid $ toS val)

  ghciCommand <- case _ghciCommand config of
                   Just cmd -> return $ unpack cmd
                   Nothing -> findExecutable "stack" >>= \case
                       Nothing -> return "ghci"
                       Just _ -> return "stack ghci"

  cmdline <- unwords <$> getArgs
  (ghci, loadMsgs) <- startGhci (ghciCommand++" "++cmdline) Nothing sendOutput
  env <- mkEnv config ghci
  -- info env $ format ("Request/control sockets: "%string%", "%string
  --                    %", "%string%", "%string)
  --                    reqPort controlPort stdoutPort stderrPort
  execCapture ghci ":set -fdiagnostics-color=always"
  execCapture ghci ":set prompt-cont \"\""
  intThread <- async $ awaitInterrupt env (controlSock sockets) ghci
  thread <- async $ race_ (loop env sockets loadMsgs)
                          (waitForProcess (process ghci) >> debug env "GHCi finished, exiting")
  return (thread, stopGhci (_ghci env))
  where
    loop env sockets@Sockets{..} loadMsgs = handle (handleExc $ _ghci env) $ do
      request <- receive requestSock
      let req = decode (BSL.fromStrict request) :: Maybe PtgRequest
      debug env ("Got request " <> show req :: Text)
   
      case req of
        Nothing -> sendResponse env requestSock 
                    $ ExecCaptureResponse False
                    $ "Request not understood" <> decodeUtf8 request
        Just msg ->
          case msg of
            -- Capture all stdout between the command and next prompt
            RequestExecCapture code ->
              withAsync (runMultiline env code)
                        $ \a2 -> do
                          (outRes, errRes) <- wait a2
                          let response = if checkForError outRes errRes
                                            then ExecCaptureResponse False (T.unlines errRes)
                                            -- Inlcude errRes b/c sometimes there are both errors
                                            -- and output
                                            else ExecCaptureResponse True (T.unlines (outRes ++ errRes))
                          sendResponse env requestSock response

            -- Don't capture result, just echo over the stdout/stderr sockets
            RequestExecStream code -> do
              seq <- runMultilineStream env sockets code
              let response = ExecStreamResponse True Nothing seq
              sendResponse env requestSock response

            RequestLoadMessages ->
              let response = LoadMessagesResponse True loadMsgs
               in sendResponse env requestSock response

            RequestType identifier showHoleFits -> do
              -- This request is used for the bottom toolbar, and so needs to
              -- complete quickly.  Showing hole fits greatly slows things down
              -- when an identifier begins with underscore.  So we turn it off
              -- then re-enable it.  TODO: figure out how to respect the
              -- initial state of the show-valid-hole-fits flag.
              when (T.take 1 identifier == "_" && not showHoleFits)
                $ void $ runLine env ":set -fno-show-valid-hole-fits"

              debug env $ "about to type " ++ show identifier
              (outRes, errRes) <- runLine env $ ":t " <> identifier
              debug env $ "finished typing:" <> T.unlines outRes
              when (T.take 1 identifier == "_" && not showHoleFits)
                $ void $ runLine env ":set -fshow-valid-hole-fits"
              debug env $ "type req stdout: " <> stripAnsi (T.unlines outRes)
              debug env $ "type req stderr: " <> stripAnsi (T.unlines errRes)
              let prepare = T.strip . T.unlines . dropBlankLines
                  response = if checkForError outRes errRes
                                then ExecCaptureResponse False (prepare errRes)
                                else ExecCaptureResponse True (prepare outRes)

              sendResponse env requestSock response

            RequestCompletion lineBeforeCursor -> do
              response <- runCompletion env lineBeforeCursor
              sendResponse env requestSock response

            RequestOpenDoc identifier -> do
              result <- try $ findDocForIdentifier env identifier
              let response = 
                    case result of
                      Right path -> ExecCaptureResponse True $ pack path
                      Left (ex :: DocException) ->
                        ExecCaptureResponse False $ showDocException ex
              sendResponse env requestSock response

            RequestOpenSource identifier -> do
              result <- try $ findDocSourceForIdentifier env identifier
              let response = 
                    case result of
                      Right path -> ExecCaptureResponse True $ pack path
                      Left (ex :: DocException) ->
                        ExecCaptureResponse False $ showDocException ex
              sendResponse env requestSock response
      loop env sockets loadMsgs

    handleExc ghci (e :: SomeException) = do
      -- putErrText $ show e
      stop ghci


sendResponse :: Sender a => Env -> Socket a -> PtgResponse -> IO ()
sendResponse env sock msg = do
  debug env ("Sending response: " <> show msg :: Text)
  send sock [] $ BSL.toStrict $ encode msg

-- ghcid imports several modules under the name "INTERNAL_GHCID".  Showing
-- this import name will just be confusing to the end user, so strip it out
-- whenever it appears in a message.
stripInternalGhcid :: Text -> Text
stripInternalGhcid = T.replace "INTERNAL_GHCID." ""

runLine :: Env -> Text -> IO ([Text], [Text])
runLine env cmd = do
  results <- execCapture (_ghci env) (T.unpack cmd)
  return $ both (fmap $ stripInternalGhcid . T.pack) results
  where
    both f = bimap f f

runMultiline :: Env -> Text -> IO ([Text], [Text])
runMultiline env cmd = runLine env (":{\n"<>cmd<>"\n:}\n")

runMultilineStream :: Env -> Sockets -> Text -> IO Int
runMultilineStream env Sockets{..} cmd =
  execStream (_ghci env) (":{\n"++T.unpack cmd++"\n:}\n")

runCompletion :: Env -> Text -> IO PtgResponse
runCompletion env lineBeforeCursor = do
  (outRes, errRes) <- runLine env $ ":complete repl " <> escaped
  if checkForError outRes errRes
     then return $ CompletionResponse False "" []
     else case parseCompletionResult outRes of
            Just (startChars, candidates) ->
              return $ CompletionResponse True startChars candidates
            Nothing -> return $ CompletionResponse False "" []
  where
    escaped = show lineBeforeCursor :: Text

-- | Parse the result of ":complete repl" into a string that goes before each
-- completion candidate, and the completion candidates themselves
parseCompletionResult :: [Text] -> Maybe (Text, [Text])
parseCompletionResult lines = do
  firstLine <- headMay lines'
  match <- headMay $ scan metaRe firstLine
  startChars <- extractStartChars match
  candidates <- tail lines' >>= traverse unescape 
  return (startChars, candidates)


  where
    lines' = dropBlankLines lines
    metaRe = [re|(\d+) (\d+) (.*)$|]
    extractStartChars (_, [_,_,s]) = unescape s
    extractStartChars _ = Nothing
    unescape :: Text -> Maybe Text
    unescape s = fst <$> headMay (reads $ unpack s)


checkForError :: [Text]-> [Text] -> Bool
checkForError stdout stderr = isBlank stdout && not (isBlank stderr)
--   where
--     checkForError' (l:ls) = stripAnsi l =~ [re|^<(\w|\s)+>:(\d+:\d+:)? error:.*|]
--     checkForError' _ = False

isBlank :: [Text] -> Bool
isBlank = T.null . T.strip . T.unlines

-- Monster regex attack!!  This comes from https://github.com/chalk/ansi-regex
ansiRe :: Regex
ansiRe = [re|[\e\x9B][[\]()#;?]*(?:(?:(?:[a-zA-Z\d]*(?:;[a-zA-Z\d]*)*)?\x07)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-ntqry=><~]))|]

stripAnsi :: Text -> Text
stripAnsi t = gsub ansiRe (""::Text) (T.strip t)

dropBlankLines :: [Text] -> [Text]
dropBlankLines = filter ((not . T.null) . T.strip)

-- | Remove leading lines like "it :: ()".  This happens when +t is on because
-- of the inner workings of ptghci.
eatIt :: [Text] -> [Text]
eatIt = dropWhile (== "it :: ()")


awaitInterrupt :: Receiver a => Env -> Socket a -> Ghci -> IO ()
awaitInterrupt env sock ghci = forever $ do
  request <- receive sock
  info env ("Handling interrupt" :: Text)
  let reqStr = unpack $ decodeUtf8 request
  when (reqStr == "Interrupt") (interrupt ghci)

stop ghci = do
  stopGhci ghci
  putText "**Engine stopping**"
