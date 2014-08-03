-- |
-- Module      :  Control.Concurrent.Actor
-- Copyright   :  (c) 2014 Alex Constandache & Forkk
-- License     :  BSD3
-- Maintainer  :  forkk@forkk.net
-- Stability   :  experimental
-- Portability :  GHC only (requires throwTo)
--
-- This module implements Erlang-style actors
-- (what Erlang calls processes). It does not implement
-- network distribution (yet?). Here is an example:
--
-- @
--act1 :: Actor
--act1 = do
--    me <- self
--    liftIO $ print "act1 started"
--    forever $ receive
--      [ Case $ \((n, a) :: (Int, Address)) ->
--            if n > 10000
--                then do
--                    liftIO . throwIO $ NonTermination
--                else do
--                    liftIO . putStrLn $ "act1 got " ++ (show n) ++ " from " ++ (show a)
--                    send a (n+1, me)
--      , Case $ \(e :: RemoteException) ->
--            liftIO . print $ "act1 received a remote exception"
--      , Default $ liftIO . print $ "act1: received a malformed message"
--      ]
--
--act2 :: Address -> Actor
--act2 addr = do
--    monitor addr
--    -- setFlag TrapRemoteExceptions
--    me <- self
--    send addr (0 :: Int, me)
--    forever $ receive
--      [ Case $ \((n, a) :: (Int, Address)) -> do
--                    liftIO . putStrLn $ "act2 got " ++ (show n) ++ " from " ++ (show a)
--                    send a (n+1, me)
--      , Case $ \(e :: RemoteException) ->
--            liftIO . print $ "act2 received a remote exception: " ++ (show e)
--      ]
--
--act3 :: Address -> Actor
--act3 addr = do
--    monitor addr
--    setFlag TrapRemoteExceptions
--    forever $ receive
--      [ Case $ \(e :: RemoteException) ->
--            liftIO . print $ "act3 received a remote exception: " ++ (show e)
--      ]
--
--main = do
--    addr1 <- spawn act1
--    addr2 <- spawn (act2 addr1)
--    spawn (act3 addr2)
--    threadDelay 20000000
-- @
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
module Control.Concurrent.Actor (
  -- * Types
    Address
  , Handler(..)
  , ActorM
  , Actor
  , ActorException
  , ActorExit
  , Flag(..)
  -- * Actor actions
  , send
  , self
  , receive
  , receiveWithTimeout
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
  ( forkIO
  , killThread
  , myThreadId
  , ThreadId
  )
import Control.Exception
  ( Exception(..)
  , SomeException
  , catches
  , throwTo
  , throwIO
  , PatternMatchFail(..)
  )
import qualified Control.Exception as E (Handler(..))
import Control.Concurrent.Chan
  ( Chan
  , newChan
  , readChan
  , writeChan
  )
import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , modifyMVar_
  , withMVar
  , readMVar
  )
import GHC.Conc (ThreadStatus, threadStatus)
import Control.Monad.Reader
  ( ReaderT
  , runReaderT
  , asks
  , ask
  , liftIO
  )
import System.Timeout (timeout)
import Data.Dynamic
import Data.Set
  ( Set
  , empty
  , insert
  , delete
  , elems
  )
import Data.Word (Word64)
import Data.Bits (
    setBit
  , clearBit
  , complementBit
  , testBit
  )

-- | Exception raised by an actor on exit
data ActorExit = ActorExit deriving (Typeable, Show)

instance Exception ActorExit

data ActorException = ActorException Address SomeException
  deriving (Typeable, Show)

instance Exception ActorException

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

data Context = Context
  { ctxMonitors :: MVar (Set Address)
  , ctxChan     :: Chan Message
  , ctxFlags    :: MVar Flags
  } deriving (Typeable)

newtype Message = Msg { unMsg :: Dynamic }
    deriving (Typeable)

instance Show Message where
    show = show . unMsg

toMsg :: Typeable a => a -> Message
toMsg = Msg . toDyn

fromMsg :: Typeable a => Message -> Maybe a
fromMsg = fromDynamic . unMsg

-- | The address of an actor, used to send messages
data Address = Address
  { addrThread  :: ThreadId
  , addrContext :: Context
  } deriving (Typeable)

instance Show Address where
    show (Address ti _) = "Address(" ++ (show ti) ++ ")"

instance Eq Address where
    addr1 == addr2 = (addrThread addr1) == (addrThread addr2)

instance Ord Address where
    addr1 `compare` addr2 = (addrThread addr1) `compare` (addrThread addr2)

-- | The actor monad, just a reader monad on top of 'IO'.
type ActorM = ReaderT Context IO

-- | The type of an actor. It is just a monadic action
-- in the 'ActorM' monad, returning ()
type Actor = ActorM ()

data Handler = forall m . (Typeable m)
             => Case (m -> ActorM ())
             |  Default (ActorM ())

-- | Used to obtain an actor's own address inside the actor
self :: ActorM Address
self = do
    c <- ask
    i <- liftIO myThreadId
    return $ Address i c

-- | Try to handle a message using a list of handlers.
-- The first handler matching the type of the message
-- is used.
receive :: [Handler] -> ActorM ()
receive hs = do
    ch  <- asks ctxChan
    msg <- liftIO . readChan $ ch
    rec msg hs

-- | Same as receive, but times out after a specified
-- amount of time and runs a default action
receiveWithTimeout :: Int -> [Handler] -> ActorM () -> ActorM ()
receiveWithTimeout n hs act = do
    ch <- asks ctxChan
    msg <- liftIO . timeout n . readChan $ ch
    case msg of
        Just m  -> rec m hs
        Nothing -> act

rec :: Message -> [Handler] -> ActorM ()
rec msg [] = liftIO . throwIO $ PatternMatchFail err where
    err = "no handler for messages of type " ++ (show msg)
rec msg ((Case hdl):hs) = case fromMsg msg of
    Just m  -> hdl m
    Nothing -> rec msg hs
rec _ ((Default act):_) = act


-- | Sends a message from inside the 'ActorM' monad
send :: Typeable m => Address -> m -> ActorM ()
send addr msg = do
    let ch = ctxChan . addrContext $ addr
    liftIO . writeChan ch . toMsg $ msg

-- FIXME: This is a big and complicated function. It would be a good idea to
-- break it up into smaller parts.
-- | Prepares the given actor monad to be run as an actor. Returns a tuple
-- containing the actor's context and an IO action to run the actor.
mkActor :: Actor -> [Flag] -> IO (IO (), Context)
mkActor actor flagList = do
    chan <- liftIO newChan
    linkedActors <- newMVar empty
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
        linkedHandler :: ActorException -> IO ()
        linkedHandler ex@(ActorException addr iex) = do
            -- Remove the linked actor from our list.
            modifyMVar_ linkedActors (return . delete addr)
            me <- myThreadId
            forward $ ActorException (Address me context) iex
            throwIO ex
    -- Exception handler. Catches all exceptions and forwards them to
    -- monitoring actors.
        exceptionHandler :: SomeException -> IO ()
        exceptionHandler ex = do
            me <- myThreadId
            forward $ ActorException (Address me context) ex
            throwIO ex
    -- Exception forwarding function.
    -- Takes an `ActorException` and forwards it to all actors monitoring the
    -- current actor.
        forward :: ActorException -> IO ()
        forward ex = do
            linkedSet <- readMVar linkedActors
            mapM_ (forwardTo ex) $ elems linkedSet
    -- Forwards the given exception to the given actor.
        forwardTo :: ActorException -> Address -> IO ()
        forwardTo ex addr = do
            let remoteFlags = ctxFlags . addrContext $ addr
                remoteChan  = ctxChan  . addrContext $ addr
            trap <- withMVar remoteFlags (return . isSetF TrapActorExceptions)
            -- If the remote actor is trapping actor exceptions, send our
            -- exception to it as a message. Otherwise, throw it to the actor's
            -- thread.
            if trap
               then writeChan remoteChan $ toMsg ex
               else throwTo (addrThread addr) ex
    -- Return the context and the IO action.
    return (actorFunc, context)


-- | Spawn a new actor with default flags on a separate thread.
spawn :: Actor -> IO Address
spawn actor = do
    (actorFunc, context) <- mkActor actor defaultFlags
    -- Start the actor's thread.
    threadId <- forkIO actorFunc
    -- Return a handle.
    return $ Address threadId context

-- | Run the given actor with default flags on the current thread.
-- This can be useful for your program's "main actor".
runActor :: Actor -> IO ()
runActor actor = do
    -- Create the actor.
    (actorFunc, _) <- mkActor actor defaultFlags
    actorFunc


-- | Monitors the actor at the specified address.
-- If an exception is raised in the monitored actor's
-- thread, it is wrapped in an 'ActorException' and
-- forwarded to the monitoring actor. If the monitored
-- actor terminates, an 'ActorException' is raised in
-- the monitoring Actor
monitor :: Address -> ActorM ()
monitor addr = do
    me <- self
    let mons = ctxMonitors . addrContext $ addr
    liftIO $ modifyMVar_ mons (return . insert me)

-- | Like `monitor`, but bi-directional
link :: Address -> ActorM ()
link addr = do
    monitor addr
    mons <- asks ctxMonitors
    liftIO $ modifyMVar_ mons (return . insert addr)

-- | Kill the actor at the specified address
kill :: Address -> ActorM ()
kill = liftIO . killThread . addrThread

-- | The current status of an actor
status :: Address -> ActorM ThreadStatus
status = liftIO . threadStatus . addrThread

-- | Sets the specified flag in the actor's environment
setFlag :: Flag -> ActorM ()
setFlag flag = do
    fs <- asks ctxFlags
    liftIO $ modifyMVar_ fs (return . setF flag)

-- | Clears the specified flag in the actor's environment
clearFlag :: Flag -> ActorM ()
clearFlag flag = do
    fs <- asks ctxFlags
    liftIO $ modifyMVar_ fs (return . clearF flag)

-- | Toggles the specified flag in the actor's environment
toggleFlag :: Flag -> ActorM ()
toggleFlag flag = do
    fs <- asks ctxFlags
    liftIO $ modifyMVar_ fs (return . toggleF flag)

-- | Checks if the specified flag is set in the actor's environment
testFlag :: Flag -> ActorM Bool
testFlag flag = do
    fs <- asks ctxFlags
    liftIO $ withMVar fs (return . isSetF flag)

