{-# LANGUAGE FlexibleContexts #-}

{-|
Module      : AWS.Lambda.Runtime.Value
Description : Runtime methods useful when constructing Haskell handlers for the AWS Lambda Custom Runtime.
Copyright   : (c) Nike, Inc., 2018
License     : BSD3
Maintainer  : nathan.fairhurst@nike.com, fernando.freire@nike.com
Stability   : stable

These are runtimes designed for AWS Lambda, which accept a handler and return
an application that will retreive and execute events as long as a container
continues to exist.

These runtimes expect handlers that accept a parsed JSON AST
('Data.Aeson.Types.Value') as the input, instead some particular type with a FromJSON
instance.  Handlers using these runtimes must take care of the conversion and
handle errors explicitly.  Handlers that should throw an exception or never
expect to be invoked with an invalid payload, should simply use the runtimes in
the "AWS.Lambda.Runtime" module.

Each example shows the conversion from the Value type to the target FromJSON
type.

Many of these runtimes use "AWS.Lambda.Combinators" under the hood.
For those interested in peeking below the abstractions provided here,
please refer to that module.
-}

module AWS.Lambda.Runtime.Value (
  pureRuntime,
  pureRuntimeWithContext,
  fallibleRuntime,
  fallibleRuntimeWithContext,
  ioRuntime,
  ioRuntimeWithContext,
  readerTRuntime,
  mRuntimeWithContext
) where

import           AWS.Lambda.RuntimeClient (getBaseRuntimeRequest, getNextEvent,
                                           sendEventError, sendEventSuccess, sendInitError)
import           AWS.Lambda.Combinators   (withIOInterface,
                                           withFallibleInterface,
                                           withPureInterface,
                                           withoutContext)
import           AWS.Lambda.Context       (LambdaContext(..), HasLambdaContext(..), runReaderTLambdaContext)
import           AWS.Lambda.Internal      (StaticContext, DynamicContext(DynamicContext),
                                           mkContext)
import           Control.Applicative      ((<*>))
import           Control.Exception        (SomeException, displayException)
import           Control.Monad            (forever)
import           Control.Monad.Catch      (MonadCatch, try)
import           Control.Monad.IO.Class   (MonadIO, liftIO)
import           Control.Monad.Reader     (MonadReader, ReaderT, local)
import           Data.Aeson               (FromJSON, FromJSON, ToJSON, decode, Value)
import           Data.Bifunctor           (first)
import qualified Data.ByteString.Char8    as BSC
import qualified Data.ByteString.Lazy     as BSW
import qualified Data.ByteString.Internal as BSI
import           Data.Text                (unpack)
import           Data.Text.Encoding       (decodeUtf8)
import           Data.Time.Clock.POSIX    (posixSecondsToUTCTime)
import           Network.HTTP.Simple      (Request, getResponseBody,
                                           getResponseHeader)
import           System.Environment       (setEnv)
import           System.Envy              (decodeEnv)

exactlyOneHeader :: [a] -> Maybe a
exactlyOneHeader [a] = Just a
exactlyOneHeader _ = Nothing

maybeToEither :: b -> Maybe a -> Either b a
maybeToEither b ma = case ma of
  Nothing -> Left b
  Just a -> Right a

-- Note: Does not allow whitespace
readMaybe :: (Read a) => String -> Maybe a
readMaybe s = case reads s of
  [(x,"")] -> Just x
  _ -> Nothing

-- TODO: There must be a better way to do this
decodeHeaderValue :: FromJSON a => BSC.ByteString -> Maybe a
decodeHeaderValue = decode . BSW.pack . fmap BSI.c2w . BSC.unpack

-- An empty array means we successfully decoded, but nothing was there
-- If we have exactly one element, our outer maybe signals successful decode,
--   and our inner maybe signals that there was content sent
-- If we had more than one header value, the event was invalid
decodeOptionalHeader :: FromJSON a => [BSC.ByteString] -> Maybe (Maybe a)
decodeOptionalHeader header =
  case header of
    [] -> Just Nothing
    [x] -> fmap Just $ decodeHeaderValue x
    _ -> Nothing


runtimeLoop :: (HasLambdaContext r, MonadReader r m, MonadCatch m, MonadIO m, ToJSON result) => Request -> StaticContext ->
  (Value -> m result) -> m ()
runtimeLoop baseRuntimeRequest staticContext fn = do
  -- Get an event
  nextRes <- liftIO $ getNextEvent baseRuntimeRequest

  -- If we got an event but our requestId is invalid/missing, there's no hope of meaningful recovery
  let reqIdBS = head $ getResponseHeader "Lambda-Runtime-Aws-Request-Id" nextRes

  let mTraceId = fmap decodeUtf8 $ exactlyOneHeader $ getResponseHeader "Lambda-Runtime-Trace-Id" nextRes
  let mFunctionArn = fmap decodeUtf8 $ exactlyOneHeader $ getResponseHeader "Lambda-Runtime-Invoked-Function-Arn" nextRes
  let mDeadline = do
        header <- exactlyOneHeader (getResponseHeader "Lambda-Runtime-Deadline-Ms" nextRes)
        milliseconds :: Double <- readMaybe $ BSC.unpack header
        return $ posixSecondsToUTCTime $ realToFrac $ milliseconds / 1000

  let mClientContext = decodeOptionalHeader $ getResponseHeader "Lambda-Runtime-Client-Context" nextRes
  let mIdentity = decodeOptionalHeader $ getResponseHeader "Lambda-Runtime-Cognito-Identity" nextRes

  -- Populate the context with values from headers
  let eCtx =
        -- combine our StaticContext and possible DynamicContext into a LambdaContext
        fmap (mkContext staticContext)
        -- convert the Maybe DynamicContext into an Either String DynamicContext
        $ maybeToEither "Runtime Error: Unable to decode Context from event response."
        -- Build the Dynamic Context, collapsing individual Maybes into a single Maybe
        $ DynamicContext (decodeUtf8 reqIdBS)
        <$> mTraceId
        <*> mFunctionArn
        <*> mDeadline
        <*> mClientContext
        <*> mIdentity

  let event = getResponseBody nextRes

  result <- case eCtx of
    Left e -> return $ Left e
    Right ctx ->
      local (withContext ctx) $ do
        -- Propagate the tracing header (Exception safe for this env var name)
        liftIO $ setEnv "_X_AMZN_TRACE_ID" $ unpack $ xRayTraceId ctx

        {- Catching like this is _usually_ considered bad practice, but this is a true
             case where we want to both catch all errors and propogate information about them.
             See: http://hackage.haskell.org/package/base-4.12.0.0/docs/Control-Exception.html#g:4
        -}
        -- Put any exceptions in an Either
        caughtResult <- try (fn event)
        -- Map the Either (via first) so it is an `Either String a`
        return $ first (displayException :: SomeException -> String) caughtResult

  liftIO $ case result of
    Right r -> sendEventSuccess baseRuntimeRequest reqIdBS r
    Left e  -> sendEventError baseRuntimeRequest reqIdBS e


-- | For any monad that supports IO/catch/Reader LambdaContext.
--
-- Use this if you need caching behavours or are comfortable manipulating monad
-- transformers and want full control over your monadic interface.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Context (LambdaContext(..), runReaderTLambdaContext)
--     import AWS.Lambda.Runtime (mRuntimeWithContext)
--     import Control.Monad.Reader (ReaderT, ask)
--     import Control.Monad.State.Lazy (StateT, evalStateT, get, put)
--     import Control.Monad.Trans (liftIO)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import Data.Text (unpack)
--     import System.Environment (getEnv)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: Value -> StateT Int (ReaderT LambdaContext IO) String
--     myHandler jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> return $ "My name is HAL, what's yours?"
--         Just Named { name } -> do
--           LambdaContext { functionName } <- ask
--           greeting <- liftIO $ getEnv \"GREETING\"
--
--           greetingCount <- get
--           put $ greetingCount + 1
--
--           return $ greeting ++ name ++ " (" ++ show greetingCount ++ ") from " ++ unpack functionName ++ "!"
--
--     main :: IO ()
--     main = runReaderTLambdaContext (evalStateT (mRuntimeWithContext myHandler) 0)
-- @
mRuntimeWithContext :: (HasLambdaContext r, MonadCatch m, MonadReader r m, MonadIO m, ToJSON result) =>
  (Value -> m result) -> m ()
mRuntimeWithContext fn = do
  -- TODO: Hide the implementation details of Request and StaticContext.
  -- If we instead have a method that returns an opaque RuntimeClientConfig
  -- that encapsulates these details, and then all clientMethods accept
  -- the RuntimeClientConfig instead of a baseRuntimeRequest.
  baseRuntimeRequest <- liftIO getBaseRuntimeRequest

  possibleStaticCtx <- liftIO $ (decodeEnv :: IO (Either String StaticContext))

  case possibleStaticCtx of
    Left err -> liftIO $ sendInitError baseRuntimeRequest err
    Right staticContext -> forever $ runtimeLoop baseRuntimeRequest staticContext fn

-- | For functions that can read the lambda context and use IO within the same monad.
--
-- Use this for handlers that need any form of side-effect such as reading
-- environment variables or making network requests, and prefer to access the
-- AWS Lambda Context in the same monad.
-- However, do not use this runtime if you need stateful (caching) behaviors.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Context (LambdaContext(..))
--     import AWS.Lambda.Runtime (readerTRuntime)
--     import Control.Monad.Reader (ReaderT, ask)
--     import Control.Monad.Trans (liftIO)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import Data.Text (unpack)
--     import System.Environment (getEnv)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: Value -> ReaderT LambdaContext IO String
--     myHandler jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> return $ "My name is HAL, what's yours?"
--         Just Named { name } -> do
--           LambdaContext { functionName } <- ask
--           greeting <- liftIO $ getEnv \"GREETING\"
--           return $ greeting ++ name ++ " from " ++ unpack functionName ++ "!"
--
--     main :: IO ()
--     main = readerTRuntime myHandler
-- @
readerTRuntime :: ToJSON result =>
  (Value -> ReaderT LambdaContext IO result) -> IO ()
readerTRuntime = runReaderTLambdaContext .  mRuntimeWithContext

-- | For functions with IO that can fail in a pure way (or via throw).
--
-- Use this for handlers that need any form of side-effect such as reading
-- environment variables or making network requests, and also need the
-- AWS Lambda Context as input.
-- However, do not use this runtime if you need stateful (caching) behaviors.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Context (LambdaContext(..))
--     import AWS.Lambda.Runtime (ioRuntimeWithContext)
--     import Control.Monad.Trans (liftIO)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import Data.Text (unpack)
--     import System.Environment (getEnv)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: LambdaContext -> Value -> IO (Either String String)
--     myHandler (LambdaContext { functionName }) jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> return $ pure "My name is HAL, what's yours?"
--         Just Named { name } -> do
--           greeting <- liftIO $ getEnv \"GREETING\"
--           return $ pure $ greeting ++ name ++ " from " ++ unpack functionName ++ "!"
--
--     main :: IO ()
--     main = ioRuntimeWithContext myHandler
-- @
ioRuntimeWithContext :: ToJSON result =>
  (LambdaContext -> Value -> IO (Either String result)) -> IO ()
ioRuntimeWithContext = readerTRuntime . withIOInterface

-- | For functions with IO that can fail in a pure way (or via throw).
--
-- Use this for handlers that need any form of side-effect such as reading
-- environment variables or making network requests.
-- However, do not use this runtime if you need stateful (caching) behaviors.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Runtime (ioRuntime)
--     import Control.Monad.Trans (liftIO)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import System.Environment (getEnv)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: Value -> IO (Either String String)
--     myHandler jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> return $ pure "My name is HAL, what's yours?"
--         Just Named { name } -> do
--           greeting <- liftIO $ getEnv \"GREETING\"
--           return $ pure $ greeting ++ name
--
--     main :: IO ()
--     main = ioRuntime myHandler
-- @
ioRuntime :: ToJSON result =>
  (Value -> IO (Either String result)) -> IO ()
ioRuntime = readerTRuntime . withIOInterface . withoutContext

-- | For pure functions that can still fail.
--
-- Use this for simple handlers that just translate input to output without side-effects,
-- but can fail and need the AWS Lambda Context as input.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Context (LambdaContext(..))
--     import AWS.Lambda.Runtime (fallibleRuntimeWithContext)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import Data.Text (unpack)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: LambdaContext -> Value -> Either String String
--     myHandler (LambdaContext { functionName }) jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> Right "My name is HAL, what's yours?"
--         Just Named { name } ->
--           if name == \"World\" then
--             Right $ "Hello, World from " ++ unpack functionName ++ "!"
--           else
--             Left "Can only greet the world."
--
--     main :: IO ()
--     main = fallibleRuntimeWithContext myHandler
-- @
fallibleRuntimeWithContext :: ToJSON result =>
  (LambdaContext -> Value -> Either String result) -> IO ()
fallibleRuntimeWithContext = readerTRuntime . withFallibleInterface

-- | For pure functions that can still fail.
--
-- Use this for simple handlers that just translate input to output without side-effects,
-- but can fail.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Runtime (fallibleRuntime)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: Value -> Either String String
--     myHandler jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> Right "My name is HAL, what's yours?"
--         Just Named { name } ->
--           if name == \"World\" then
--             Right "Hello, World!"
--           else
--             Left "Can only greet the world."
--
--     main :: IO ()
--     main = fallibleRuntime myHandler
-- @
fallibleRuntime :: ToJSON result =>
  (Value -> Either String result) -> IO ()
fallibleRuntime = readerTRuntime . withFallibleInterface . withoutContext

-- | For pure functions that can never fail that also need access to the context.
--
-- Use this for simple handlers that just translate input to output without side-effects,
-- but that need the AWS Lambda Context as input.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Context (LambdaContext(..))
--     import AWS.Lambda.Runtime (pureRuntimeWithContext)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import Data.Text (unpack)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: LambdaContext -> Value -> Either String String
--     myHandler (LambdaContext { functionName }) jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> Right "My name is HAL, what's yours?"
--         Just Named { name } ->
--           Right $ "Hello, " ++ name ++ " from " ++ unpack functionName ++ "!"
--
--     main :: IO ()
--     main = pureRuntimeWithContext myHandler
-- @
pureRuntimeWithContext :: ToJSON result =>
  (LambdaContext -> Value -> result) -> IO ()
pureRuntimeWithContext = readerTRuntime . withPureInterface

-- | For pure functions that can never fail.
--
-- Use this for simple handlers that just translate input to output without side-effects.
--
-- @
--     {-\# LANGUAGE NamedFieldPuns, DeriveGeneric \#-}
--
--     module Main where
--
--     import AWS.Lambda.Runtime (pureRuntime)
--     import Data.Aeson (Value, FromJSON, parseJSON)
--     import Data.Aeson.Types (parseMaybe)
--     import GHC.Generics (Generic)
--
--     data Named = Named {
--       name :: String
--     } deriving Generic
--     instance FromJSON Named
--
--     myHandler :: Value -> String
--     myHandler jsonAst =
--       case parseMaybe parseJSON jsonAst of
--         Nothing -> "My name is HAL, what's yours?"
--         Just Named { name } ->
--           "Hello, " ++ name ++ "!"
--
--     main :: IO ()
--     main = pureRuntime myHandler
-- @
pureRuntime :: ToJSON result => (Value -> result) -> IO ()
pureRuntime = readerTRuntime . withPureInterface . withoutContext
