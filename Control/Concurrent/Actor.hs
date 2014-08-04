-- |
-- Module      :  Control.Concurrent.Actor
-- Copyright   :  (c) 2014 Alex Constandache & Forkk
-- License     :  BSD3
-- Maintainer  :  forkk@forkk.net
-- Stability   :  experimental
-- Portability :  GHC only (requires throwTo)
--
-- This module implements Erlang-style actors
-- (what Erlang calls processes).
--
-- @
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses, AllowAmbiguousTypes, ScopedTypeVariables #-}
{-# LANGUAGE OverlappingInstances, UndecidableInstances #-}
module Control.Concurrent.Actor (
  -- * Types
    ActorHandle
  , ActorM
  , Actor
  , ActorException
  , ActorExit
  , Flag(..)
  -- * Actor actions
  , send
  , self
  , receive
  -- , receiveWithTimeout
  , spawn
  , runActor
  , monitor
  , link
  , kill
  , status
  , setFlag
  , clearFlag
  , toggleFlag
  , testFlag
  ) where

import Control.Concurrent
import Control.Exception
import qualified Control.Exception as E (Handler(..))
import GHC.Conc (ThreadStatus, threadStatus)
import Control.Monad.Reader
import qualified Data.Set as S
import Data.Typeable
import Data.Word (Word64)
import Data.Bits

-- {{{ Types

-- {{{ Exceptions

-- | Exception raised by an actor on exit
data ActorExit = ActorExit deriving (Show, Typeable)

instance Exception ActorExit

data ActorException msg = ActorException (ActorHandle msg) SomeException
  deriving (Show, Typeable)

instance (ActorMessage msg) => Exception (ActorException msg)

-- }}}

-- {{{ Flags

type Flags = Word64

data Flag = TrapActorExceptions
    deriving (Eq, Enum)

defaultFlags :: [Flag]
defaultFlags = []

setF :: Flag -> Flags -> Flags
setF = flip setBit . fromEnum

clearF :: Flag -> Flags -> Flags
clearF = flip clearBit . fromEnum

toggleF :: Flag -> Flags -> Flags
toggleF = flip complementBit . fromEnum

isSetF :: Flag -> Flags -> Bool
isSetF = flip testBit . fromEnum

-- }}}

-- {{{ Actor handle and context

-- | The actor context. This holds information such as the actor's links,
-- channels, and flags.
data (ActorMessage msg) => Context msg = Context
  { ctxLinks    :: MVar (S.Set (ActorHandle msg))
  , ctxChan     :: Chan msg
  , ctxFlags    :: MVar Flags
  }

-- | An actor handle.
-- This is used as a "reference" to an actor. It contains the actor's thread ID
-- and context.
data (ActorMessage msg) => ActorHandle msg = ActorHandle
  { ahThread  :: ThreadId
  , ahContext :: Context msg
  }

instance (ActorMessage msg) => Show (ActorHandle msg) where
    show (ActorHandle tid _) = "ActorHandle(" ++ (show tid) ++ ")"

instance (ActorMessage msg) => Eq (ActorHandle msg) where
    h1 == h2 = (ahThread h1) == (ahThread h2)

instance (ActorMessage msg) => Ord (ActorHandle msg) where
    h1 `compare` h2 = (ahThread h1) `compare` (ahThread h2)

-- }}}

-- {{{ Actor monad

-- | The actor monad, just a reader monad on top of 'IO'.
type ActorM msg = ReaderT (Context msg) IO

-- | The type of an actor taking the given type of message.
type Actor msg = ActorM msg ()

-- | Like MonadIO, but for the actor monad.
class (Monad m, ActorMessage msg) => MonadActor msg m where
    liftActor :: ActorM msg a -> m a

instance (ActorMessage msg) => MonadActor msg (ActorM msg) where
    liftActor = id

-- }}}

-- {{{ Messages

class (Show msg, Typeable msg) => ActorMessage msg where

-- }}}

-- }}}

-- {{{ Utility functions

-- | Gets the channel for the given actor handle.
ahChan :: (ActorMessage msg) => ActorHandle msg -> Chan msg
ahChan = ctxChan . ahContext

-- }}}

-- {{{ Actor functions

-- {{{ Information & management

-- | Kill the actor at the specified address
kill :: (ActorMessage msg) => ActorHandle msg -> ActorM msg ()
kill = liftIO . killThread . ahThread

-- | The current status of an actor
status :: (ActorMessage msg) => ActorHandle msg -> ActorM msg ThreadStatus
status = liftIO . threadStatus . ahThread

-- | Used to obtain an actor's own address inside the actor
self :: (ActorMessage msg) => ActorM msg (ActorHandle msg)
self = do
    c <- ask
    i <- liftIO myThreadId
    return $ ActorHandle i c

-- }}}

-- {{{ Messages

-- | Try to handle a message using a list of handlers.
-- The first handler matching the type of the message
-- is used.
receive :: (MonadIO m, MonadActor msg m, ActorMessage msg) => (msg -> m a) -> m a
receive handler =
    handler =<< (liftIO . readChan) =<< (liftActor $ asks ctxChan)

-- TODO: Re-implement receiveWithTimeout
-- Same as receive, but times out after a specified
-- amount of time and runs a default action
-- receiveWithTimeout :: Int -> [Handler] -> ActorM () -> ActorM ()
-- receiveWithTimeout n hs act = do
--     ch <- asks ctxChan
--     msg <- liftIO . timeout n . readChan $ ch
--     case msg of
--         Just m  -> rec m hs
--         Nothing -> act

-- | Sends a message to the given actor.
send :: (MonadIO m, MonadActor msg m, ActorMessage msg, ActorMessage smsg) =>
        ActorHandle smsg -> smsg -> m ()
send h = liftIO . writeChan (ahChan h)

-- }}}

-- {{{ Start actors

-- FIXME: This is a big and complicated function. It would be a good idea to
-- break it up into smaller parts.
-- | Prepares the given actor monad to be run as an actor. Returns a tuple
-- containing the actor's context and an IO action to run the actor.
mkActor :: (ActorMessage msg) => Actor msg -> [Flag] -> IO (IO (), Context msg)
mkActor actor flagList = do
    chan <- liftIO newChan
    linkedActors <- newMVar S.empty
    flags <- newMVar $ foldl (flip setF) 0x00 flagList
    let context = Context linkedActors chan flags
    -- An IO action which executes the actual actor.
    let actorFunc = actorInternal `catches` [ E.Handler linkedHandler
                                            , E.Handler exceptionHandler]
    -- The internal IO action for the actor.
    -- This will be wrapped by exception handlers.
        actorInternal = runReaderT actor context
    -- Linked exception handler. Catches exceptions from linked actors and
    -- handles them appropriately.
        linkedHandler ex@(ActorException addr iex) = do
            -- Remove the linked actor from our list.
            modifyMVar_ linkedActors (return . S.delete addr)
            me <- myThreadId
            forward $ ActorException (ActorHandle me context) iex
            throwIO ex
    -- Exception handler. Catches all exceptions and forwards them to
    -- monitoring actors.
        exceptionHandler :: SomeException -> IO ()
        exceptionHandler ex = do
            me <- myThreadId
            forward $ ActorException (ActorHandle me context) ex
            throwIO ex
    -- Exception forwarding function.
    -- Takes an `ActorException` and forwards it to all actors monitoring the
    -- current actor.
        forward ex = do
            linkedSet <- readMVar linkedActors
            mapM_ (forwardTo ex) $ S.elems linkedSet
    -- Forwards the given exception to the given actor.
        forwardTo ex addr = do
            -- let remoteFlags = ctxFlags . ahContext $ addr
            --     remoteChan  = ctxChan  . ahContext $ addr
            throwTo (ahThread addr) ex
            -- TODO: Re-implement trapping exceptions
            -- trap <- withMVar remoteFlags (return . isSetF TrapActorExceptions)
            -- If the remote actor is trapping actor exceptions, send our
            -- exception to it as a message. Otherwise, throw it to the actor's
            -- thread.
            -- if trap
            --    then writeChan remoteChan $ ex
            --    else throwTo (ahThread addr) ex
    -- Return the context and the IO action.
    return (actorFunc, context)


-- | Spawn a new actor with default flags on a separate thread.
spawn :: (ActorMessage msg) => Actor msg -> IO (ActorHandle msg)
spawn actor = do
    (actorFunc, context) <- mkActor actor defaultFlags
    -- Start the actor's thread.
    threadId <- forkIO actorFunc
    -- Return a handle.
    return $ ActorHandle threadId context

-- | Run the given actor with default flags on the current thread.
-- This can be useful for your program's "main actor".
runActor :: (ActorMessage msg) => Actor msg -> IO ()
runActor actor = do
    -- Create the actor.
    (actorFunc, _) <- mkActor actor defaultFlags
    actorFunc

-- }}}

-- {{{ Error handling

-- | Monitors the actor at the specified address.
-- If an exception is raised in the monitored actor's
-- thread, it is wrapped in an 'ActorException' and
-- forwarded to the monitoring actor. If the monitored
-- actor terminates, an 'ActorException' is raised in
-- the monitoring Actor
monitor :: (ActorMessage msg) => ActorHandle msg -> ActorM msg ()
monitor addr = do
    me <- self
    let mons = ctxLinks . ahContext $ addr
    liftIO $ modifyMVar_ mons (return . S.insert me)

-- | Like `monitor`, but bi-directional
link :: (ActorMessage msg) => ActorHandle msg -> ActorM msg ()
link addr = do
    monitor addr
    mons <- asks ctxLinks
    liftIO $ modifyMVar_ mons (return . S.insert addr)

-- }}}

-- {{{ Flags

-- | Sets the specified flag in the actor's environment
setFlag :: (ActorMessage msg) => Flag -> ActorM msg ()
setFlag flag = do
    fs <- asks ctxFlags
    liftIO $ modifyMVar_ fs (return . setF flag)

-- | Clears the specified flag in the actor's environment
clearFlag :: (ActorMessage msg) => Flag -> ActorM msg ()
clearFlag flag = do
    fs <- asks ctxFlags
    liftIO $ modifyMVar_ fs (return . clearF flag)

-- | Toggles the specified flag in the actor's environment
toggleFlag :: (ActorMessage msg) => Flag -> ActorM msg ()
toggleFlag flag = do
    fs <- asks ctxFlags
    liftIO $ modifyMVar_ fs (return . toggleF flag)

-- | Checks if the specified flag is set in the actor's environment
testFlag :: (ActorMessage msg) => Flag -> ActorM msg Bool
testFlag flag = do
    fs <- asks ctxFlags
    liftIO $ withMVar fs (return . isSetF flag)

-- }}}

-- }}}

