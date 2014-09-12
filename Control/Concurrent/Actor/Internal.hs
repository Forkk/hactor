-- |
-- Module      :  Control.Concurrent.Actor.Internal
-- Copyright   :  (c) 2014 Forkk
-- License     :  MIT
-- Maintainer  :  forkk@forkk.net
-- Stability   :  experimental
-- Portability :  GHC only (requires throwTo)
--
-- Module exposing more of hactor's internals. Use with caution.
--
module Control.Concurrent.Actor.Internal
    (
    -- * Types
      ActorHandle (..)
    , ActorMessage
    , ActorM
    -- * Sending Messages
    , send
    , sendIO
    -- * Receiving Messages
    , receive
    , receiveMaybe
    , receiveSTM
    -- * Spawning Actors
    , spawnActor
    , runActor
    -- * Getting Information
    , self
    , actorThread
    -- * Internals
    , ActorContext (..)
    , MailBox
    , getContext
    , getMailBox
    ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Reader


-- {{{ Types

-- {{{ Message

-- | The @ActorMessage@ class must be implemented by any type that will be sent
-- as a message to actors.
-- Any given type of actor will have one @ActorMessage@ type that is sent to
-- that actor. This ensures type safety.
-- Currently this is simply a dummy class with nothing in it, but things may be
-- added in the future.
class ActorMessage msg

-- Allow actors that don't take messages.
instance ActorMessage ()

-- }}}

-- {{{ Handle and context

-- | An @ActorHandle@ acts as a reference to a specific actor.
data ActorMessage msg => ActorHandle msg = ActorHandle
    { ahContext     :: ActorContext msg     -- Context for this handle's actor.
    , ahThread      :: ThreadId             -- The actor's thread ID.
    }

-- | The @ActorContext@ holds shared information about a given actor.
-- This is information such as the actor's mail box, the list of actors it's
-- linked to, etc.
data ActorMessage msg => ActorContext msg = ActorContext
    { acMailBox :: MailBox msg  -- Channel for the actor's messages.
    }

-- | The type for the actor's mail box.
type MailBox msg = TChan msg

-- }}}

-- }}}

-- | The base actor monad.
type ActorM msg = ReaderT (ActorContext msg) IO

-- {{{ Get info

-- | Gets a handle to the current actor.
self :: ActorMessage msg => ActorM msg (ActorHandle msg)
self = do
    context <- ask
    thread <- liftIO $ myThreadId
    return $ ActorHandle context thread

-- | Retrieves the mail box for the current actor.
-- This is an internal function and may be dangerous. Use with caution.
getMailBox :: ActorMessage msg => ActorM msg (MailBox msg)
getMailBox = asks acMailBox


-- | Gets the internal context object for the current actor.
-- This is an internal function and may be dangerous. Use with caution.
getContext :: ActorMessage msg => ActorM msg (ActorContext msg)
getContext = ask

-- }}}

-- {{{ Receiving

-- | Reads a message from the actor's mail box.
-- If there are no messages, blocks until one is received. If you don't want
-- this, use @receiveMaybe@ instead.
receive :: ActorMessage msg => ActorM msg (msg)
receive = do
    chan <- getMailBox
    -- Read from the channel, retrying if there is nothing to read.
    liftIO $ atomically $ readTChan chan

-- | Reads a message from the actor's mail box.
-- If there are no messages, returns @Nothing@.
receiveMaybe :: ActorMessage msg => ActorM msg (Maybe msg)
receiveMaybe = do
    chan <- getMailBox
    liftIO $ atomically $ tryReadTChan chan

-- | An @ActorM@ action which returns an @STM@ action to receive a message.
receiveSTM :: ActorMessage msg => ActorM msg (STM msg)
receiveSTM = do
    chan <- getMailBox
    return $ readTChan chan

-- }}}

-- {{{ Sending

-- | Sends a message to the given actor handle.
-- This is secretly just @sendIO@ lifted into an actor monad.
send :: (ActorMessage msg, ActorMessage msg') =>
        ActorHandle msg -> msg -> ActorM msg' ()
send hand msg = liftIO $ sendIO hand msg

-- | Sends a message to the given actor handle from within the IO monad.
sendIO :: ActorMessage msg => ActorHandle msg -> msg -> IO ()
sendIO hand msg =
    atomically $ writeTChan mailBox $ msg
  where
    mailBox = handleMailBox hand

-- }}}

-- {{{ Spawning

-- | Internal function for starting actors.
-- This takes an @ActorM@ action, makes a channel for it, wraps it in exception
-- handling stuff, and turns it into an IO monad. The function returns a tuple
-- containing the actor's context and the IO action to execute the actor.
wrapActor :: ActorMessage msg => ActorM msg () -> IO (IO (), ActorContext msg)
wrapActor actorAction = do
    -- TODO: Exception handling.
    -- First, create a channel for the actor.
    chan <- atomically newTChan
    -- Next, create the context and run the ReaderT action.
    let context = ActorContext chan
        ioAction = runReaderT actorAction context
    -- Return the information.
    return (ioAction, context)


-- | Spawns the given actor on another thread and returns a handle to it.
spawnActor :: ActorMessage msg => ActorM msg () -> IO (ActorHandle msg)
spawnActor actorAction = do
    -- Wrap the actor action.
    (ioAction, context) <- wrapActor actorAction
    -- Fork the actor's IO action to another thread.
    thread <- forkIO ioAction
    -- Return the handle.
    return $ ActorHandle context thread

-- | Runs the given actor on the current thread.
-- This function effectively turns the current thread into the actor's thread.
-- Obviously, this means that this function will block until the actor exits.
-- You probably want to use this for your "main" actor.
runActor :: ActorMessage msg => ActorM msg () -> IO ()
runActor actorAction = do
    -- Wrap the actor action. We discard the context, because we won't be
    -- returning a handle to this actor.
    (ioAction, _) <- wrapActor actorAction
    -- Execute the IO action on the current thread.
    ioAction

-- }}}

-- {{{ Utility functions

-- | Gets the mail box for the given handle.
handleMailBox :: ActorMessage msg => ActorHandle msg -> MailBox msg
handleMailBox = acMailBox . ahContext

-- | Gets the thread ID for the given actor handle.
actorThread :: ActorMessage msg => ActorHandle msg -> ThreadId
actorThread = ahThread

-- }}}

