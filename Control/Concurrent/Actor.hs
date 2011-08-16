-- |
-- Module      :  Control.Concurrent.Actor
-- Copyright   :  (c) 2011 Alex Constandache
-- License     :  BSD3
-- Maintainer  :  alexander.the.average@gmail.com
-- Stability   :  alpha
-- Portability :  GHC only
--
-- This module implements Erlang-style actors 
-- (what Erlang calls processes). It does not implement 
-- network distribution (yet?).
-- An actor is parametrised by the type of messages it 
-- receives and the type of messages it sends.
--
-- Here is an example:
--
-- @
--act1 :: Actor 
--act1 = forever $ do
--    msg <- receive
--    me <- self
--    liftIO . putStrLn $ \"act1: received \" ++ (show num)
--    send addr (me, num + 1)
--
--act2 :: Int -> Address -> Actor 
--act2 n0 addr = do
--    send addr n0
--    forever $ do
--        (num, addr1) <- receive
--        liftIO . putStrLn $ \"act2: received \" ++ (show num)
--        send addr1 (num + 1)
--
--main = do
--    addr1 <- spawn act1
--    addr2 <- spawn $ act2 0 addr1
--    threadDelay 20000000
-- @
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
module Control.Concurrent.Actor (
  -- * Types
    Address
  , Message
  , Handler(..)
  , ActorM
  , Actor
  , RemoteException
  , ActorExitNormal
  -- * Actor actions
  , send
  , (◁)
  , (▷)
  , self
  , receive
  , receiveWithTimeout
  , handle
  , spawn
  , monitor
  , link
  , setFlag
  , clearFlag
  , toggleFlag
  , testFlag
  ) where

import Control.Concurrent 
  ( forkIO
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
data ActorExitNormal = ActorExitNormal deriving (Typeable, Show)

instance Exception ActorExitNormal

data RemoteException = RemoteException Address SomeException
  deriving (Typeable, Show)

instance Exception RemoteException

type Message = Dynamic

-- | The address of an actor, used to send messages 
data Address = Addr 
  { thId  :: ThreadId
  , ctxt  :: Context
  }

instance Show Address where
    show (Addr ti _) = "Address(" ++ (show ti) ++ ")"

instance Eq Address where
    addr1 == addr2 = (thId addr1) == (thId addr2)

instance Ord Address where
    addr1 `compare` addr2 = (thId addr1) `compare` (thId addr2)

type Flags = Word64

data Flag = TrapRemoteExceptions
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
  }

-- | The actor monad, just a reader monad on top of 'IO'.
type ActorM = ReaderT Context IO 

-- | The type of an actor. It is just a monadic action
-- in the 'ActorM' monad, returning ()
type Actor = ActorM ()

data Handler = forall m . (Typeable m) => Handler (m -> ActorM ())

-- | Used to obtain an actor's own address inside the actor
self :: ActorM Address
self = do
    c <- ask
    i <- liftIO myThreadId
    return $ Addr i c

-- | Receive a message inside the 'ActorM' monad. Blocks until
-- a message arrives if the mailbox is empty
receive :: ActorM Message
receive = do
    ch <- asks chan
    liftIO . readChan $ ch
    

-- | Same as receive, but times out after a specified 
-- amount of time and returns 'Nothing'
receiveWithTimeout :: Int -> ActorM (Maybe Message)
receiveWithTimeout n = do 
    ch <- asks chan 
    liftIO . timeout n . readChan $ ch

-- | Try to handle a message using a list of handlers.
-- The first handler matching the type of the message 
-- is used.
handle :: [Handler] -> Message -> ActorM ()
handle hs msg = go hs where
    go [] = liftIO . throwIO $ PatternMatchFail errmsg where
        errmsg = "no handler for messages of type " ++ (show . typeOf $ msg)
    go ((Handler h):hs') = case fromDynamic msg of
        Just m' -> h m'
        Nothing -> go hs'

-- | Sends a message from inside the 'ActorM' monad
send :: Address -> Message -> ActorM ()
send addr msg = do
    let ch = chan . ctxt $ addr
    liftIO . writeChan ch $ msg

-- | Infix form of 'send'
(◁) :: Address -> Message -> ActorM ()
(◁) = send
    
-- | Infix form of 'send' with the arguments flipped
(▷) :: Message -> Address -> ActorM ()
(▷) = flip send

-- | Spawns a new actor, with the given flags set
spawn' :: [Flag] -> Actor -> IO Address
spawn' fs act = do
    ch <- liftIO newChan
    ls <- newMVar empty
    fl <- newMVar $ foldl (flip setF) 0x00 fs
    let cx = Ctxt ls ch fl
    let orig = runReaderT act cx >> throwIO ActorExitNormal
        wrap = orig `catches` [E.Handler remoteExH, E.Handler someExH]
        remoteExH :: RemoteException -> IO ()
        remoteExH e@(RemoteException a _) = do
            modifyMVar_ ls (return . delete a)
            me  <- myThreadId 
            let se = toException e
            forward (RemoteException (Addr me cx) se)
        someExH :: SomeException -> IO ()
        someExH e = do
            me  <- myThreadId
            forward (RemoteException (Addr me cx) e)
        forward :: RemoteException -> IO ()
        forward e = do
            lset <- withMVar ls return
            mapM_ (($ e) . throwTo . thId) $ elems lset
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
    let ls = lSet. ctxt $ addr
    liftIO $ modifyMVar_ ls (return . insert me)

-- | Like `monitor`, but bi-directional
link :: Address -> ActorM ()
link addr = do
    monitor addr
    ls <- asks lSet
    liftIO $ modifyMVar_ ls (return . insert addr)

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

testFlag :: Flag -> ActorM Bool
testFlag flag = do 
    fs <- asks flags
    liftIO $ withMVar fs (return . isSetF flag)
