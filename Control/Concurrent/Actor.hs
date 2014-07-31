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
  , MonitoringException
  , ActorExit
  , Flag(..)
  -- * Actor actions
  , send
  , (◁)
  , (▷)
  , self
  , receive
  , receiveWithTimeout
  , spawn
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

data MonitoringException = MonitoringException Address
  deriving (Typeable, Show)

instance Exception RemoteException

type Flags = Word64

data Flag = TrapMonitoringExceptions
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

data Context = Ctxt 
  { lSet  :: MVar (Set Address)
  , chan  :: Chan Message
  , flags :: MVar Flags
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
data Address = Addr 
  { thId  :: ThreadId
  , ctxt  :: Context
  } deriving (Typeable)

instance Show Address where
    show (Addr ti _) = "Address(" ++ (show ti) ++ ")"

instance Eq Address where
    addr1 == addr2 = (thId addr1) == (thId addr2)

instance Ord Address where
    addr1 `compare` addr2 = (thId addr1) `compare` (thId addr2)

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
    return $ Addr i c

-- | Try to handle a message using a list of handlers.
-- The first handler matching the type of the message 
-- is used.
receive :: [Handler] -> ActorM ()
receive hs = do
    ch  <- asks chan
    msg <- liftIO . readChan $ ch 
    rec msg hs

-- | Same as receive, but times out after a specified 
-- amount of time and runs a default action
receiveWithTimeout :: Int -> [Handler] -> ActorM () -> ActorM ()
receiveWithTimeout n hs act = do 
    ch <- asks chan 
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
rec msg ((Default act):_) = act


-- | Sends a message from inside the 'ActorM' monad
send :: Typeable m => Address -> m -> ActorM ()
send addr msg = do
    let ch = chan . ctxt $ addr
    liftIO . writeChan ch . toMsg $ msg

-- | Infix form of 'send'
(◁) :: Typeable m => Address -> m -> ActorM ()
(◁) = send
    
-- | Infix form of 'send' with the arguments flipped
(▷) :: Typeable m => m -> Address -> ActorM ()
(▷) = flip send

-- | Spawns a new actor, with the given flags set
spawn' :: [Flag] -> Actor -> IO Address
spawn' fs act = do
    ch <- liftIO newChan
    ls <- newMVar empty
    fl <- newMVar $ foldl (flip setF) 0x00 fs
    let cx = Ctxt ls ch fl
    let orig = runReaderT act cx >> throwIO ActorExit
        wrap = orig `catches` [E.Handler monitorExH, E.Handler someExH]
        monitorExH :: MonitoringException -> IO ()
        monitorExH e@(MonitoringException a) = do
            modifyMVar_ ls (return . delete a)
            me  <- myThreadId 
            forward (MonitorException (Addr me cx))
            throwIO e
        someExH :: SomeException -> IO ()
        someExH e = do
            me  <- myThreadId
            forward (MonitoringException (Addr me cx))
            throwIO e
        forward :: MonitoringException -> IO ()
        forward ex = do
            lset <- withMVar ls return
            mapM_ (fwdaux ex) $ elems lset
        fwdaux :: MonitoringException -> Address -> IO ()
        fwdaux ex addr = do
            let rfs = flags . ctxt $ addr
                rch = chan  . ctxt $ addr
            trap <- withMVar rfs (return . isSetF TrapMonitoringExceptions)
            if trap
                then
                    writeChan rch (toMsg ex)
                else
                    throwTo (thId addr) ex
    ti <- forkIO wrap
    return $ Addr ti cx

-- | Spawn a new actor with default flags
spawn :: Actor -> IO Address
spawn = spawn' defaultFlags 

-- | Monitors the actor at the specified address.
-- If an exception is raised in the monitored actor's 
-- thread, it is wrapped in an 'ActorException' and 
-- forwarded to the monitoring actor. If the monitored
-- actor terminates, an 'ActorException' is raised in
-- the monitoring Actor
monitor :: Address -> ActorM ()
monitor addr = do
    me <- self
    let ls = lSet . ctxt $ addr
    liftIO $ modifyMVar_ ls (return . insert me)

-- | Like `monitor`, but bi-directional
link :: Address -> ActorM ()
link addr = do
    monitor addr
    ls <- asks lSet
    liftIO $ modifyMVar_ ls (return . insert addr)

-- | Kill the actor at the specified address
kill :: Address -> ActorM ()
kill = liftIO . killThread . thId

-- | The current status of an actor
status :: Address -> ActorM ThreadStatus
status = liftIO . threadStatus . thId

-- | Sets the specified flag in the actor's environment
setFlag :: Flag -> ActorM ()
setFlag flag = do
    fs <- asks flags
    liftIO $ modifyMVar_ fs (return . setF flag)

-- | Clears the specified flag in the actor's environment
clearFlag :: Flag -> ActorM ()
clearFlag flag = do
    fs <- asks flags
    liftIO $ modifyMVar_ fs (return . clearF flag)

-- | Toggles the specified flag in the actor's environment
toggleFlag :: Flag -> ActorM ()
toggleFlag flag = do
    fs <- asks flags
    liftIO $ modifyMVar_ fs (return . toggleF flag)

-- | Checks if the specified flag is set in the actor's environment
testFlag :: Flag -> ActorM Bool
testFlag flag = do 
    fs <- asks flags
    liftIO $ withMVar fs (return . isSetF flag)

